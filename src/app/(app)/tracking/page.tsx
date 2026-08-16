import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { EmptyState } from "@/components/ui/empty-state";
import { LiveMap, type DriverMarker, type DispatchStopCoords } from "@/components/tracking/live-map";

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

  const [{ data: drivers }, { data: dispatches }] = await Promise.all([
    driverIds.length > 0
      ? supabase.from("drivers").select("id, first_name, last_name").in("id", driverIds)
      : Promise.resolve({ data: [] }),
    dispatchIds.length > 0
      ? supabase.from("dispatches").select("id, status, loads(load_number), trucks(unit_number)").in("id", dispatchIds)
      : Promise.resolve({ data: [] }),
  ]);

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
      truckUnit: dispatch?.trucks?.unit_number ?? null,
      dispatchStatus: dispatch?.status ?? null,
      dispatchId: row.dispatch_id,
    };
  });

  const fifteenMinAgo = Date.now() - 15 * 60 * 1000;
  const reportingNow = markers.filter((m) => new Date(m.recordedAt).getTime() >= fifteenMinAgo).length;

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

  return (
    <div className="space-y-6">
      <PageHeader
        title="Live Tracking"
        description="Real GPS pings reported from each driver's phone while they have the driver portal open."
      />

      <KpiRow>
        <KpiCard label="Drivers Reporting Live" value={reportingNow} tone={reportingNow > 0 ? "success" : "neutral"} />
        <KpiCard label="Total Active Drivers" value={activeDriversCount ?? 0} />
        <KpiCard label="Locations Tracked" value={markers.length} />
      </KpiRow>

      {markers.length === 0 ? (
        <EmptyState
          title="No live locations yet"
          description="Locations appear here once a driver signs in at /driver-portal and starts a trip."
        />
      ) : (
        <LiveMap initialMarkers={markers} organizationId={organizationId} initialDispatchStops={initialDispatchStops} geofenceRadii={geofenceRadii} />
      )}
    </div>
  );
}
