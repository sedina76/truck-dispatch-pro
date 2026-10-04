import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import type { DriverMarker, DispatchStopCoords } from "@/components/tracking/live-map";
import { TrackingBoard } from "@/components/tracking/tracking-board";
import type { FleetRow, FleetRisk } from "@/lib/tracking/fleet";
import { stopLabel } from "@/lib/geo/stop-point";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

export default async function TrackingPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("organization_id").eq("id", user!.id).single();
  const organizationId = profile?.organization_id ?? "";

  // driver_latest_locations (0058_driver_phone_gps.sql) -- one row per
  // driver, kept in sync by a trigger on every driver_locations insert --
  // the Live Tracking screen reads this indexed table instead of scanning/
  // deduping raw ping history.
  const [{ data: latest }, { count: activeDriversCount }] = await Promise.all([
    supabase
      .from("driver_latest_locations")
      .select("driver_id, truck_id, dispatch_id, latitude, longitude, accuracy_meters, speed_kph, recorded_at"),
    supabase.from("drivers").select("id", { count: "exact", head: true }).eq("status", "active"),
  ]);

  const rows = latest ?? [];
  const driverIds = rows.map((r) => r.driver_id);
  const dispatchIds = Array.from(new Set(rows.map((r) => r.dispatch_id).filter(Boolean))) as string[];

  const truckIds = Array.from(new Set(rows.map((r) => r.truck_id).filter(Boolean))) as string[];
  const [{ data: drivers }, { data: dispatches }, { data: trucks }] = await Promise.all([
    driverIds.length > 0
      ? supabase.from("drivers").select("id, first_name, last_name").in("id", driverIds)
      : Promise.resolve({ data: [] }),
    dispatchIds.length > 0
      ? supabase.from("dispatches").select("id, status, loads:loads!dispatches_load_id_fkey(load_number), trucks(unit_number)").in("id", dispatchIds)
      : Promise.resolve({ data: [] }),
    truckIds.length > 0 ? supabase.from("trucks").select("id, unit_number").in("id", truckIds) : Promise.resolve({ data: [] }),
  ]);
  const truckUnitById = new Map(((trucks ?? []) as { id: string; unit_number: string }[]).map((t) => [t.id, t.unit_number]));

  const driverNameById = new Map((drivers ?? []).map((d) => [d.id, `${d.first_name} ${d.last_name}`]));
  const dispatchById = new Map(
    ((dispatches ?? []) as unknown as {
      id: string;
      status: string;
      loads: { load_number: string } | null;
      trucks: { unit_number: string } | null;
    }[]).map((d) => [d.id, d])
  );

  const markers: DriverMarker[] = rows.map((row) => {
    const dispatch = row.dispatch_id ? dispatchById.get(row.dispatch_id) : undefined;
    return {
      driverId: row.driver_id,
      driverName: driverNameById.get(row.driver_id) ?? "Driver",
      latitude: row.latitude,
      longitude: row.longitude,
      recordedAt: row.recorded_at,
      accuracyMeters: row.accuracy_meters,
      speedKph: row.speed_kph,
      loadNumber: dispatch?.loads?.load_number ?? null,
      truckUnit: dispatch?.trucks?.unit_number ?? (row.truck_id ? truckUnitById.get(row.truck_id) ?? null : null),
      dispatchStatus: dispatch?.status ?? null,
      dispatchId: row.dispatch_id,
    };
  });


  // Phase 2B (spec section 21): pickup/delivery geofence circles for every
  // dispatch currently on the map, plus the org's configured radii. Both
  // are best-effort -- a not-yet-applied migration 0059 just means no
  // circles draw, never a broken map (dispatchIds already resolved above).
  let initialDispatchStops: Record<string, DispatchStopCoords> = {};
  let geofenceRadii = { pickup: 300, delivery: 300 };
  if (dispatchIds.length > 0) {
    const [{ data: orgRadii }, { data: loadIdsRows }] = await Promise.all([
      supabase.from("organizations").select("pickup_geofence_radius_m, delivery_geofence_radius_m").eq("id", organizationId).maybeSingle(),
      supabase.from("dispatches").select("id, load_id").in("id", dispatchIds),
    ]);
    if (orgRadii) geofenceRadii = { pickup: orgRadii.pickup_geofence_radius_m ?? 300, delivery: orgRadii.delivery_geofence_radius_m ?? 300 };

    const loadIdByDispatchId = new Map((loadIdsRows ?? []).map((r) => [r.id, r.load_id]));
    const loadIds = Array.from(new Set(Array.from(loadIdByDispatchId.values())));
    if (loadIds.length > 0) {
      const { data: stopRows } = await supabase.from("load_stops").select("load_id, stop_type, stop_sequence, latitude, longitude").in("load_id", loadIds).order("stop_sequence");
      const rows = (stopRows ?? []) as { load_id: string; stop_type: string; latitude: number | null; longitude: number | null }[];
      initialDispatchStops = Object.fromEntries(
        Array.from(loadIdByDispatchId.entries()).map(([dispatchId, loadId]) => {
          const forLoad = rows.filter((r) => r.load_id === loadId);
          const p = forLoad.filter((s) => s.stop_type === "pickup")[0] ?? null;
          const d = forLoad.filter((s) => s.stop_type === "delivery").slice(-1)[0] ?? null;
          const coords: DispatchStopCoords = {
            pickup: p?.latitude != null && p?.longitude != null ? { latitude: p.latitude, longitude: p.longitude } : null,
            delivery: d?.latitude != null && d?.longitude != null ? { latitude: d.latitude, longitude: d.longitude } : null,
          };
          return [dispatchId, coords];
        })
      );
    }
  }

  // Truck list: each truck's latest route calculation (next stop, miles,
  // ETA, late / at risk) -- the same dispatch_route_intelligence rows the
  // dispatch panel and the map panel read.
  type RouteRow = {
    dispatch_id: string;
    target_stop_id: string | null;
    route_distance_meters: number | null;
    route_duration_seconds: number | null;
    estimated_arrival_at: string | null;
    appointment_at: string | null;
    appointment_window_end: string | null;
    schedule_variance_minutes: number | null;
    risk_status: string | null;
    calculation_status: string | null;
    updated_at: string;
  };
  const routeByDispatch = new Map<string, RouteRow>();
  const stopById = new Map<string, { facility_name: string | null; city: string | null; state: string | null; timezone: string | null; geocode_source: string | null }>();
  let orgTimezone: string | null = null;
  if (dispatchIds.length > 0) {
    const [{ data: routeRows, error: routeError }, { data: orgRow }] = await Promise.all([
      supabase
        .from("dispatch_route_intelligence")
        .select("dispatch_id, target_stop_id, route_distance_meters, route_duration_seconds, estimated_arrival_at, appointment_at, appointment_window_end, schedule_variance_minutes, risk_status, calculation_status, updated_at")
        .in("dispatch_id", dispatchIds),
      supabase.from("organizations").select("timezone").eq("id", organizationId).maybeSingle(),
    ]);
    if (routeError) console.warn("[tracking] route intelligence unavailable:", routeError.message);
    orgTimezone = (orgRow as { timezone?: string | null } | null)?.timezone ?? null;
    for (const r of (routeRows ?? []) as RouteRow[]) {
      const prev = routeByDispatch.get(r.dispatch_id);
      if (!prev || r.updated_at > prev.updated_at) routeByDispatch.set(r.dispatch_id, r);
    }
    const targetIds = Array.from(new Set(Array.from(routeByDispatch.values()).map((r) => r.target_stop_id).filter(Boolean))) as string[];
    if (targetIds.length > 0) {
      const { data: stops } = await supabase.from("load_stops").select("id, facility_name, city, state, timezone, geocode_source").in("id", targetIds);
      for (const st of (stops ?? []) as ({ id: string } & { facility_name: string | null; city: string | null; state: string | null; timezone: string | null; geocode_source: string | null })[]) stopById.set(st.id, st);
    }
  }
  const RISKS: FleetRisk[] = ["late", "at_risk", "on_time", "arrived", "unknown"];
  const fleetRows: FleetRow[] = markers.map((m) => {
    const route = m.dispatchId ? routeByDispatch.get(m.dispatchId) : undefined;
    const stop = route?.target_stop_id ? stopById.get(route.target_stop_id) : undefined;
    const risk = (RISKS as string[]).includes(route?.risk_status ?? "") ? (route!.risk_status as FleetRisk) : "unknown";
    return {
      driverId: m.driverId,
      driverName: m.driverName,
      dispatchId: m.dispatchId,
      loadNumber: m.loadNumber,
      truckUnit: m.truckUnit,
      dispatchStatus: m.dispatchStatus,
      recordedAt: m.recordedAt,
      speedMph: m.speedKph != null ? Math.round(m.speedKph * 0.621371) : null,
      nextStop: stop ? stopLabel(stop) : null,
      milesLeftMeters: route?.route_distance_meters ?? null,
      drivingSeconds: route?.route_duration_seconds ?? null,
      etaAt: route?.estimated_arrival_at ?? null,
      appointmentAt: route?.appointment_at ?? null,
      appointmentWindowEnd: route?.appointment_window_end ?? null,
      stopTimezone: resolveStopTimezone(stop?.timezone ?? null, orgTimezone).timezone,
      risk,
      varianceMinutes: route?.schedule_variance_minutes ?? null,
      calcStatus: route?.calculation_status ?? null,
    };
  });

  return (
    <div className="space-y-6">
      <PageHeader
        title="Live Tracking"
        description={`Where every truck is, where it's headed and when it gets there -- from each driver's phone while the driver app is open.${activeDriversCount ? ` ${activeDriversCount} active driver${activeDriversCount === 1 ? "" : "s"}.` : ""}`}
      />

      {markers.length === 0 ? (
        <EmptyState
          title="No live locations yet"
          description="Locations appear here once a driver signs in at /driver-portal and starts a trip."
        />
      ) : (
        <TrackingBoard
          rows={fleetRows}
          markers={markers}
          organizationId={organizationId}
          initialDispatchStops={initialDispatchStops}
          geofenceRadii={geofenceRadii}
          renderedAt={Date.now()}
        />
      )}
    </div>
  );
}
