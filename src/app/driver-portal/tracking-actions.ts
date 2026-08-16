"use server";

import { revalidatePath } from "next/cache";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { getCurrentDispatch } from "@/lib/driver-portal/dashboard-data";
import { applyPickupArrival, applyDeliveryArrival } from "@/lib/tracking/evaluate-geofences";

// Start Trip / Stop Trip -- creates/ends the formal driver_tracking_sessions
// row (0058_driver_phone_gps.sql). Kept separate from the raw GPS-ping
// route (/api/driver-portal/location, unchanged) since this is session
// lifecycle, not a location report. Same security model as that route:
// identity comes only from the server-verified portal session cookie,
// never from anything the client sends.

export type TrackingSessionResult =
  | { ok: true; sessionId: string; dispatchId: string; truckId: string | null }
  | { ok: false; error: string };

export async function startTrackingSession(): Promise<TrackingSessionResult> {
  const identity = await getDriverPortalSession();
  if (!identity) return { ok: false, error: "Not logged in." };

  const supabase = createServiceRoleClient();

  // The driver's active dispatch, resolved server-side by the same
  // canonical resolver every other portal page uses -- never trusts a
  // dispatch id the client might send.
  const dispatch = await getCurrentDispatch(supabase, identity.driverId);
  if (!dispatch || !isActiveStatus(dispatch.status)) {
    return { ok: false, error: "No active dispatch to track right now." };
  }

  const { data: dispatchRow } = await supabase.from("dispatches").select("truck_id").eq("id", dispatch.id).maybeSingle();
  const truckId = dispatchRow?.truck_id ?? null;

  // Resume an existing active session for this driver if one is already
  // open (e.g. a second tab, or the page reloaded mid-trip) rather than
  // creating a second row -- the partial unique index would reject a
  // second active insert anyway, but resuming is the correct UX, not an
  // error.
  const { data: existing } = await supabase
    .from("driver_tracking_sessions")
    .select("id, dispatch_id, truck_id")
    .eq("driver_id", identity.driverId)
    .eq("status", "active")
    .maybeSingle();

  if (existing) {
    // The active dispatch changed since the session was opened (rare --
    // driver finished one load and started another without stopping
    // sharing in between); keep the session but point it at the current
    // dispatch/truck so new pings attribute correctly.
    if (existing.dispatch_id !== dispatch.id || existing.truck_id !== truckId) {
      await supabase.from("driver_tracking_sessions").update({ dispatch_id: dispatch.id, truck_id: truckId }).eq("id", existing.id);
    }
    return { ok: true, sessionId: existing.id, dispatchId: dispatch.id, truckId };
  }

  const { data: created, error } = await supabase
    .from("driver_tracking_sessions")
    .insert({
      organization_id: identity.organizationId,
      driver_id: identity.driverId,
      dispatch_id: dispatch.id,
      truck_id: truckId,
      status: "active",
    })
    .select("id")
    .single();

  if (error || !created) {
    console.error("[driver-portal] startTrackingSession failed:", error);
    return { ok: false, error: "Could not start location sharing. Please try again." };
  }

  return { ok: true, sessionId: created.id, dispatchId: dispatch.id, truckId };
}

export async function stopTrackingSession(): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getDriverPortalSession();
  if (!identity) return { ok: false, error: "Not logged in." };

  const supabase = createServiceRoleClient();
  const { error } = await supabase
    .from("driver_tracking_sessions")
    .update({ status: "stopped", stopped_at: new Date().toISOString() })
    .eq("driver_id", identity.driverId)
    .eq("status", "active");

  if (error) {
    console.error("[driver-portal] stopTrackingSession failed:", error);
    return { ok: false, error: "Could not stop location sharing." };
  }
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Phase 2B: the driver's own "Confirm Arrival" tap in 'suggest' automation
// mode (spec section 14). Never trusts the browser's claim of which stop --
// re-derives the driver's own current active dispatch server-side and only
// accepts a load_stop_id that belongs to it. Only applies if the server has
// independently, multi-ping-confirmed GPS presence at this stop already
// (dispatch_geofence_state.state === 'inside') -- a driver tapping the
// button cannot fabricate an arrival the phone's GPS never actually
// reported.
// ---------------------------------------------------------------------------
export async function confirmGeofenceArrival(loadStopId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getDriverPortalSession();
  if (!identity) return { ok: false, error: "Not logged in." };

  const supabase = createServiceRoleClient();
  const dispatch = await getCurrentDispatch(supabase, identity.driverId);
  if (!dispatch) return { ok: false, error: "No active trip." };

  const { data: stop } = await supabase.from("load_stops").select("id, stop_type, load_id").eq("id", loadStopId).maybeSingle();
  if (!stop || stop.load_id !== dispatch.load_id) return { ok: false, error: "This stop is not part of your active trip." };
  if (stop.stop_type !== "pickup" && stop.stop_type !== "delivery") return { ok: false, error: "Unsupported stop type." };

  const { data: geofenceRow } = await supabase
    .from("dispatch_geofence_state")
    .select("state, confirmed_inside_at, status_applied_at, last_distance_m, last_accuracy_m, organization_id, dispatch_id")
    .eq("dispatch_id", dispatch.id)
    .eq("load_stop_id", loadStopId)
    .maybeSingle();

  if (!geofenceRow || geofenceRow.state !== "inside" || !geofenceRow.confirmed_inside_at) {
    return { ok: false, error: "GPS hasn't confirmed your arrival at this stop yet." };
  }
  if (geofenceRow.status_applied_at) return { ok: true }; // already applied (e.g. a second tap) -- idempotent, not an error

  const meta = {
    organizationId: identity.organizationId,
    dispatchId: dispatch.id,
    loadStopId,
    distanceM: geofenceRow.last_distance_m ?? 0,
    accuracyM: geofenceRow.last_accuracy_m ?? null,
    now: new Date().toISOString(),
    source: "driver:confirm" as const,
  };

  if (stop.stop_type === "pickup") await applyPickupArrival(supabase, meta, true);
  else await applyDeliveryArrival(supabase, meta, true);

  revalidatePath("/driver-portal/trip");
  return { ok: true };
}

const ACTIVE_DISPATCH_STATUSES = new Set([
  "assigned",
  "accepted",
  "en_route_to_pickup",
  "at_pickup",
  "loaded",
  "en_route_to_delivery",
  "at_delivery",
]);

function isActiveStatus(status: string): boolean {
  return ACTIVE_DISPATCH_STATUSES.has(status);
}
