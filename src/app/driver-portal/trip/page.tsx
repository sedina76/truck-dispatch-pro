import Link from "next/link";
import { redirect } from "next/navigation";
import { MapPin, History } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentDispatch, getTripStops, DISPATCH_STATUS_ORDER } from "@/lib/driver-portal/dashboard-data";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";
import { StatusBadge } from "@/components/ui/status-badge";
import { StatusUpdateControl } from "@/components/driver-portal/status-update-control";
import { LocationSharing } from "@/components/driver-portal/location-sharing";
import { GeofenceStatusCard, type GeofenceStopInfo } from "@/components/driver-portal/geofence-status";
import { formatMiles } from "@/lib/routing/risk";

const DRIVER_RISK_LABEL: Record<string, string> = { on_time: "On Time", at_risk: "At Risk", late: "Late" };

function fmtDateTime(iso: string | null): string {
  if (!iso) return "--";
  return new Date(iso).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

// Trip Overview / Stops / Status History / Location Sharing (spec section
// 4). Documents and Expenses live on their own nav tabs already, so this
// page links to them rather than duplicating those sections.
export default async function DriverPortalTripPage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const dispatch = await getCurrentDispatch(supabase, identity.driverId);

  // Resolved server-side so a page refresh mid-trip doesn't drop back to a
  // false "off" state -- the browser's watchPosition is gone after any
  // reload regardless, but the driver_tracking_sessions row (and the
  // driver's own intent to be sharing) persists across it.
  const { data: activeSession } = await supabase
    .from("driver_tracking_sessions")
    .select("id")
    .eq("driver_id", identity.driverId)
    .eq("status", "active")
    .maybeSingle();
  const hasActiveSession = !!activeSession;

  if (!dispatch) {
    return (
      <div className="flex flex-1 flex-col gap-4">
        <h1 className="text-lg font-semibold tracking-tight">Current Trip</h1>
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">No active dispatch right now.</p>
        </div>
        <LocationSharing currentLoadNumber={null} initiallyActive={hasActiveSession} />
      </div>
    );
  }

  const [stops, pod, { data: load }, { data: events }] = await Promise.all([
    getTripStops(supabase, dispatch.load_id),
    getLatestDocument(supabase, "load", dispatch.load_id, "pod"),
    supabase.from("loads").select("special_instructions, rate_confirmation_number").eq("id", dispatch.load_id).single(),
    supabase
      .from("load_tracking_events")
      .select("id, status, source, occurred_at, notes")
      .eq("load_id", dispatch.load_id)
      .order("occurred_at", { ascending: false })
      .limit(10),
  ]);
  const podStatus = computePodStatus(pod);
  const pickupStop = stops.find((s) => s.stop_type === "pickup");
  const deliveryStop = [...stops].reverse().find((s) => s.stop_type === "delivery");
  const route =
    pickupStop || deliveryStop
      ? `${pickupStop ? [pickupStop.city, pickupStop.state].filter(Boolean).join(", ") : "--"} → ${
          deliveryStop ? [deliveryStop.city, deliveryStop.state].filter(Boolean).join(", ") : "--"
        }`
      : null;

  // Phase 2B geofence status (spec section 22) -- best-effort: any failure
  // here (including migration 0059 not being applied yet) just means the
  // card doesn't render, never a broken trip page. Not batched into the
  // Promise.all above since it needs dispatch.organization_id-scoped
  // queries the other four don't.
  const geofence = await getGeofenceStatusForTrip(supabase, dispatch.id, dispatch.load_id, identity.organizationId);

  // Phase 2C (spec section 24): driver-relevant route intelligence only --
  // next stop, distance remaining, ETA, appointment, and a simple risk
  // word. Never margin/profit/rates -- this reads only the columns that
  // exist (no financial fields are even present on dispatch_route_
  // intelligence, so there's nothing to accidentally leak here).
  const routeIntel = await getRouteIntelForTrip(supabase, dispatch.id);

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold tracking-tight">{dispatch.load_number}</h1>
        <StatusBadge status={dispatch.status} />
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">Trip Overview</p>
        <div className="grid grid-cols-2 gap-y-2 text-sm">
          <Field label="Truck" value={dispatch.truck_unit ?? "--"} />
          <Field label="Trailer" value={dispatch.trailer_unit ?? "--"} />
          <Field label="Commodity" value={dispatch.commodity ?? "--"} />
          <Field label="Miles" value={dispatch.total_miles != null ? String(dispatch.total_miles) : "--"} />
          {load?.rate_confirmation_number && <Field label="Rate Con #" value={load.rate_confirmation_number} />}
        </div>
        {load?.special_instructions && (
          <div className="mt-3 border-t border-border pt-3">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Special Instructions</p>
            <p className="mt-1 text-sm">{load.special_instructions}</p>
          </div>
        )}
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="mb-2 flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-muted-foreground">
          <MapPin className="size-3.5" /> Stops
        </p>
        <div className="space-y-3">
          {stops.map((stop, i) => (
            <div key={i} className="text-sm">
              <p className="font-medium capitalize">
                {stop.stop_sequence}. {stop.stop_type} -- {stop.facility_name ?? "Unnamed facility"}
              </p>
              <p className="text-xs text-muted-foreground">
                {stop.city ?? "--"}, {stop.state ?? "--"} &middot; {fmtDateTime(stop.scheduled_at)}
                {stop.reference_number && ` · Ref: ${stop.reference_number}`}
              </p>
            </div>
          ))}
          {stops.length === 0 && <p className="text-sm text-muted-foreground">No stops on file.</p>}
        </div>
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <StatusUpdateControl dispatchId={dispatch.id} currentStatus={dispatch.status} order={DISPATCH_STATUS_ORDER} podVerified={podStatus === "verified"} />
      </div>

      {routeIntel && routeIntel.riskStatus !== "arrived" && (
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">Next Stop</p>
          {routeIntel.calculationStatus === "no_coordinates" ? (
            <p className="text-sm text-muted-foreground">Route ETA unavailable -- stop coordinates missing.</p>
          ) : routeIntel.estimatedArrivalAtLabel ? (
            <>
              <p className="text-sm font-medium">{routeIntel.targetStopLabel ?? "--"}</p>
              <div className="mt-2 grid grid-cols-2 gap-y-2 text-sm">
                <Field label="Distance Remaining" value={routeIntel.milesLabel} />
                <Field label="Estimated Arrival" value={routeIntel.estimatedArrivalAtLabel} />
                <Field label="Appointment" value={routeIntel.appointmentLabel} />
              </div>
              {routeIntel.riskStatus !== "unknown" && (
                <p className={`mt-2 text-sm font-bold ${routeIntel.riskStatus === "late" ? "text-danger" : routeIntel.riskStatus === "at_risk" ? "text-warning" : "text-success"}`}>
                  {DRIVER_RISK_LABEL[routeIntel.riskStatus]}
                </p>
              )}
            </>
          ) : (
            <p className="text-sm text-muted-foreground">Route ETA unavailable.</p>
          )}
        </div>
      )}

      {geofence && (
        <GeofenceStatusCard
          dispatchStatus={dispatch.status}
          pickup={geofence.pickup}
          delivery={geofence.delivery}
          automationMode={geofence.automationMode}
        />
      )}

      <div className="grid grid-cols-2 gap-2.5">
        <Link href="/driver-portal/documents" className="flex h-11 items-center justify-center rounded-xl border border-border text-sm font-medium">
          Documents
        </Link>
        <Link href="/driver-portal/expenses" className="flex h-11 items-center justify-center rounded-xl border border-border text-sm font-medium">
          Expenses
        </Link>
      </div>

      {events && events.length > 0 && (
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="mb-2 flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            <History className="size-3.5" /> Status History
          </p>
          <div className="space-y-2">
            {events.map((e) => (
              <div key={e.id} className="flex items-center justify-between text-sm">
                {e.status ? <StatusBadge status={e.status} /> : <span className="capitalize">{e.notes ?? "--"}</span>}
                <span className="text-xs text-muted-foreground">{fmtDateTime(e.occurred_at)}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      <LocationSharing currentLoadNumber={dispatch.load_number} route={route} initiallyActive={hasActiveSession} />
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="font-medium">{value}</p>
    </div>
  );
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function getGeofenceStatusForTrip(supabase: any, dispatchId: string, loadId: string, organizationId: string) {
  try {
    const [{ data: org, error: orgError }, { data: stopRows, error: stopsError }] = await Promise.all([
      supabase.from("organizations").select("gps_automation_mode").eq("id", organizationId).maybeSingle(),
      supabase.from("load_stops").select("id, stop_type, stop_sequence, facility_name, city, state, latitude, longitude").eq("load_id", loadId).order("stop_sequence"),
    ]);
    if (orgError || stopsError || !org) return null;

    const rows = (stopRows ?? []) as { id: string; stop_type: string; facility_name: string | null; city: string | null; state: string | null; latitude: number | null; longitude: number | null }[];
    const pickupRow = rows.filter((s) => s.stop_type === "pickup")[0] ?? null;
    const deliveryRow = rows.filter((s) => s.stop_type === "delivery").slice(-1)[0] ?? null;
    const stopIds = [pickupRow?.id, deliveryRow?.id].filter(Boolean) as string[];

    const { data: geofenceRows } = stopIds.length
      ? await supabase.from("dispatch_geofence_state").select("load_stop_id, state, last_distance_m, status_applied_at").eq("dispatch_id", dispatchId).in("load_stop_id", stopIds)
      : { data: [] };
    const byStopId = new Map((geofenceRows ?? []).map((r: { load_stop_id: string }) => [r.load_stop_id, r]));

    const { data: orgRadii } = await supabase.from("organizations").select("pickup_geofence_radius_m, delivery_geofence_radius_m").eq("id", organizationId).maybeSingle();

    function toInfo(row: typeof pickupRow, radiusM: number): GeofenceStopInfo | null {
      if (!row) return null;
      const g = byStopId.get(row.id) as { state: string; last_distance_m: number | null; status_applied_at: string | null } | undefined;
      return {
        loadStopId: row.id,
        companyName: row.facility_name,
        city: row.city,
        state: row.state,
        hasCoordinates: row.latitude != null && row.longitude != null,
        geofenceState: (g?.state as GeofenceStopInfo["geofenceState"]) ?? null,
        distanceM: g?.last_distance_m ?? null,
        radiusM,
        statusApplied: !!g?.status_applied_at,
      };
    }

    return {
      automationMode: (org.gps_automation_mode ?? "off") as "off" | "suggest" | "automatic",
      pickup: toInfo(pickupRow, orgRadii?.pickup_geofence_radius_m ?? 300),
      delivery: toInfo(deliveryRow, orgRadii?.delivery_geofence_radius_m ?? 300),
    };
  } catch (err) {
    console.warn("[driver-portal] geofence status unavailable:", err);
    return null;
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function getRouteIntelForTrip(supabase: any, dispatchId: string) {
  try {
    const { data: row, error } = await supabase
      .from("dispatch_route_intelligence")
      .select("target_stop_id, route_distance_meters, estimated_arrival_at, appointment_at, appointment_window_end, risk_status, calculation_status")
      .eq("dispatch_id", dispatchId)
      .order("updated_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error || !row) return null;

    const { data: stopRow } = await supabase.from("load_stops").select("facility_name, city, state").eq("id", row.target_stop_id).maybeSingle();
    const targetStopLabel = stopRow ? stopRow.facility_name || [stopRow.city, stopRow.state].filter(Boolean).join(", ") || null : null;
    const fmtTime = (iso: string | null) => (iso ? new Date(iso).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }) : null);

    return {
      targetStopLabel,
      milesLabel: formatMiles(row.route_distance_meters),
      estimatedArrivalAtLabel: fmtTime(row.estimated_arrival_at),
      appointmentLabel: row.appointment_window_end
        ? `${fmtTime(row.appointment_at) ?? "--"} - ${fmtTime(row.appointment_window_end)}`
        : (fmtTime(row.appointment_at) ?? "Not set"),
      riskStatus: row.risk_status as "unknown" | "on_time" | "at_risk" | "late" | "arrived",
      calculationStatus: row.calculation_status as string,
    };
  } catch (err) {
    console.warn("[driver-portal] route intelligence unavailable:", err);
    return null;
  }
}
