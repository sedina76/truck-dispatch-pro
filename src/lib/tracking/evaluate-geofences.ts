import "server-only";
import { revalidatePath } from "next/cache";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { calculateDetention } from "@/lib/dispatch/detention";
import { evaluateGeofencePing, resolveStopCoordinates, type GeofenceStateRow } from "@/lib/tracking/geofence";

// ---------------------------------------------------------------------------
// The DB-orchestration half of Phase 2B geofencing: fetches the dispatch/
// stop/org context, runs the pure state machine (geofence.ts) against the
// pickup and delivery stop, persists the result, and applies (or suggests)
// the arrival/departure automation those transitions imply. Called from
// /api/driver-portal/location's POST handler after a ping is accepted, and
// from confirmGeofenceArrival() (driver taps "Confirm Arrival" in 'suggest'
// mode). Every write here uses the service-role client -- the caller has
// already verified the driver's own portal session server-side before this
// is ever reached (spec section 9: never trust the browser's "I arrived").
// ---------------------------------------------------------------------------

type ServiceRoleClient = ReturnType<typeof createServiceRoleClient>;
type TransitionSource = "system:gps" | "driver:confirm";

type PingInput = {
  dispatchId: string;
  organizationId: string;
  latitude: number;
  longitude: number;
  accuracyMeters: number | null;
  recordedAt: string;
};

async function logActivity(
  supabase: ServiceRoleClient,
  params: { organizationId: string; dispatchId: string; action: string; changes: Record<string, unknown> }
) {
  const { error } = await supabase.from("activity_logs").insert({
    organization_id: params.organizationId,
    entity_type: "dispatch",
    entity_id: params.dispatchId,
    action: params.action,
    actor_id: null, // system/GPS-originated -- never attributed to a human user (spec section 23)
    changes: params.changes,
  });
  if (error) console.error(`[geofence] activity_logs insert failed (action=${params.action}):`, error);
}

type DispatchCore = {
  id: string;
  status: string;
  load_id: string;
  en_route_pickup_at: string | null;
  loaded_at: string | null;
  in_transit_at: string | null;
  delivered_at: string | null;
  cancelled_at: string | null;
  timestampsAvailable: boolean;
};

// Same "core fields must never fail, 0057 timestamp columns are optional
// and degrade to null" split already established in board-actions.ts --
// reused here rather than reinvented.
async function fetchDispatchCore(supabase: ServiceRoleClient, dispatchId: string): Promise<DispatchCore | null> {
  const { data, error } = await supabase
    .from("dispatches")
    .select("id, status, load_id, en_route_pickup_at, loaded_at, in_transit_at, delivered_at, cancelled_at")
    .eq("id", dispatchId)
    .maybeSingle();
  if (!error && data) return { ...data, timestampsAvailable: true } as DispatchCore;

  const { data: fallback } = await supabase.from("dispatches").select("id, status, load_id").eq("id", dispatchId).maybeSingle();
  if (!fallback) return null;
  return { ...fallback, en_route_pickup_at: null, loaded_at: null, in_transit_at: null, delivered_at: null, cancelled_at: null, timestampsAvailable: false };
}

type TransitionMeta = {
  organizationId: string;
  dispatchId: string;
  loadStopId: string;
  distanceM: number;
  accuracyM: number | null;
  now: string;
  source: TransitionSource;
};

function baseMetadata(m: TransitionMeta) {
  return {
    stop_id: m.loadStopId,
    distance_m: Math.round(m.distanceM),
    accuracy_m: m.accuracyM != null ? Math.round(m.accuracyM) : null,
    timestamp: m.now,
    source: m.source,
  };
}

async function markStatusApplied(supabase: ServiceRoleClient, m: TransitionMeta) {
  await supabase
    .from("dispatch_geofence_state")
    .update({ status_applied_at: m.now, driver_confirmed_at: m.source === "driver:confirm" ? m.now : null })
    .eq("dispatch_id", m.dispatchId)
    .eq("load_stop_id", m.loadStopId);
}

// ---------------------------------------------------------------------------
// Pickup arrival (spec section 10). Only actually applies the status move
// when the dispatch is 'en_route_to_pickup' -- anything earlier (assigned/
// accepted) is surfaced as an exception rather than silently skipping a
// stage; anything already at_pickup or later is a no-op. `forceApply`
// decides whether a confirmed arrival is actually written (automatic mode,
// or an explicit driver confirm) or only logged as a suggestion.
// ---------------------------------------------------------------------------
export async function applyPickupArrival(supabase: ServiceRoleClient, m: TransitionMeta, forceApply: boolean): Promise<{ arrivedAt: string | null }> {
  const dispatch = await fetchDispatchCore(supabase, m.dispatchId);
  const { data: stop } = await supabase.from("load_stops").select("arrived_at").eq("id", m.loadStopId).maybeSingle();
  if (!dispatch || !stop) return { arrivedAt: stop?.arrived_at ?? null };

  const meta = baseMetadata(m);

  if (dispatch.status === "assigned" || dispatch.status === "accepted") {
    await logActivity(supabase, {
      organizationId: m.organizationId,
      dispatchId: m.dispatchId,
      action: "gps_exception",
      changes: { type: "arrived_before_en_route", label: "GPS arrived at pickup but load still Assigned", ...meta },
    });
    return { arrivedAt: stop.arrived_at };
  }

  if (dispatch.status !== "en_route_to_pickup") {
    // Already at_pickup or later -- a redundant confirmation, not an event.
    return { arrivedAt: stop.arrived_at };
  }

  if (!forceApply) {
    await logActivity(supabase, {
      organizationId: m.organizationId,
      dispatchId: m.dispatchId,
      action: "gps_arrival_suggested",
      changes: { stop_type: "pickup", label: "GPS arrival detected -- awaiting driver confirmation", ...meta },
    });
    return { arrivedAt: stop.arrived_at };
  }

  const arrivedAt = stop.arrived_at ?? m.now;
  if (!stop.arrived_at) await supabase.from("load_stops").update({ arrived_at: m.now }).eq("id", m.loadStopId);
  await supabase.from("dispatches").update({ status: "at_pickup" }).eq("id", m.dispatchId);
  await markStatusApplied(supabase, m);
  await logActivity(supabase, {
    organizationId: m.organizationId,
    dispatchId: m.dispatchId,
    action: "status_changed",
    changes: { field: "status", old_value: dispatch.status, new_value: "at_pickup", label: "System detected driver arrival at pickup via GPS geofence.", ...meta },
  });
  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${m.dispatchId}`);
  return { arrivedAt };
}

// ---------------------------------------------------------------------------
// Pickup departure (spec section 11). Only moves to en_route_to_delivery
// when the dispatch was already 'loaded' -- leaving before Loaded is
// flagged as an exception, never silently advanced.
// ---------------------------------------------------------------------------
export async function applyPickupDeparture(supabase: ServiceRoleClient, m: TransitionMeta, forceApply: boolean): Promise<void> {
  const dispatch = await fetchDispatchCore(supabase, m.dispatchId);
  const { data: stop } = await supabase.from("load_stops").select("departed_at").eq("id", m.loadStopId).maybeSingle();
  if (!dispatch || !stop) return;

  const meta = baseMetadata(m);

  if (dispatch.status === "at_pickup") {
    await logActivity(supabase, {
      organizationId: m.organizationId,
      dispatchId: m.dispatchId,
      action: "gps_exception",
      changes: { type: "left_before_loaded", label: "Left pickup before Loaded", ...meta },
    });
    return;
  }

  if (dispatch.status !== "loaded") return; // already in transit or beyond -- nothing to do

  if (!forceApply) {
    await logActivity(supabase, {
      organizationId: m.organizationId,
      dispatchId: m.dispatchId,
      action: "gps_departure_suggested",
      changes: { stop_type: "pickup", label: "GPS departure detected -- awaiting confirmation", ...meta },
    });
    return;
  }

  if (!stop.departed_at) await supabase.from("load_stops").update({ departed_at: m.now }).eq("id", m.loadStopId);
  const dispatchUpdates: Record<string, string> = { status: "en_route_to_delivery" };
  if (dispatch.timestampsAvailable && !dispatch.in_transit_at) dispatchUpdates.in_transit_at = m.now;
  await supabase.from("dispatches").update(dispatchUpdates).eq("id", m.dispatchId);
  await markStatusApplied(supabase, m);
  await logActivity(supabase, {
    organizationId: m.organizationId,
    dispatchId: m.dispatchId,
    action: "status_changed",
    changes: { field: "status", old_value: dispatch.status, new_value: "en_route_to_delivery", label: "Pickup departure detected via GPS geofence.", ...meta },
  });
  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${m.dispatchId}`);
}

// ---------------------------------------------------------------------------
// Delivery arrival (spec section 12). Begins the delivery detention clock
// implicitly -- setting load_stops.arrived_at is all detention tracking
// ever needed (calculateDetention already reads it), no separate "start
// detention" action exists.
// ---------------------------------------------------------------------------
export async function applyDeliveryArrival(supabase: ServiceRoleClient, m: TransitionMeta, forceApply: boolean): Promise<{ arrivedAt: string | null }> {
  const dispatch = await fetchDispatchCore(supabase, m.dispatchId);
  const { data: stop } = await supabase.from("load_stops").select("arrived_at").eq("id", m.loadStopId).maybeSingle();
  if (!dispatch || !stop) return { arrivedAt: stop?.arrived_at ?? null };

  const meta = baseMetadata(m);
  const beforeInTransit = new Set(["assigned", "accepted", "en_route_to_pickup", "at_pickup", "loaded"]);

  if (beforeInTransit.has(dispatch.status)) {
    await logActivity(supabase, {
      organizationId: m.organizationId,
      dispatchId: m.dispatchId,
      action: "gps_exception",
      changes: { type: "arrived_before_in_transit", label: "Arrived delivery before In Transit", ...meta },
    });
    return { arrivedAt: stop.arrived_at };
  }

  if (dispatch.status !== "en_route_to_delivery") {
    return { arrivedAt: stop.arrived_at }; // already at_delivery or later
  }

  if (!forceApply) {
    await logActivity(supabase, {
      organizationId: m.organizationId,
      dispatchId: m.dispatchId,
      action: "gps_arrival_suggested",
      changes: { stop_type: "delivery", label: "GPS arrival detected -- awaiting driver confirmation", ...meta },
    });
    return { arrivedAt: stop.arrived_at };
  }

  const arrivedAt = stop.arrived_at ?? m.now;
  if (!stop.arrived_at) await supabase.from("load_stops").update({ arrived_at: m.now }).eq("id", m.loadStopId);
  await supabase.from("dispatches").update({ status: "at_delivery" }).eq("id", m.dispatchId);
  await markStatusApplied(supabase, m);
  await logActivity(supabase, {
    organizationId: m.organizationId,
    dispatchId: m.dispatchId,
    action: "status_changed",
    changes: { field: "status", old_value: dispatch.status, new_value: "at_delivery", label: "System detected driver arrival at delivery via GPS geofence.", ...meta },
  });
  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${m.dispatchId}`);
  return { arrivedAt };
}

// ---------------------------------------------------------------------------
// Delivery exit (spec section 13): NEVER auto-marks Delivered. Informational
// only -- flagged as an exception if the driver left before dispatch/staff
// ever marked Delivered, otherwise just a quiet audit entry.
// ---------------------------------------------------------------------------
export async function logDeliveryExit(supabase: ServiceRoleClient, m: TransitionMeta): Promise<void> {
  const dispatch = await fetchDispatchCore(supabase, m.dispatchId);
  if (!dispatch) return;
  const meta = baseMetadata(m);

  if (dispatch.status === "at_delivery") {
    await logActivity(supabase, {
      organizationId: m.organizationId,
      dispatchId: m.dispatchId,
      action: "gps_exception",
      changes: { type: "left_before_delivered", label: "Left delivery before Delivered", ...meta },
    });
  } else {
    await logActivity(supabase, {
      organizationId: m.organizationId,
      dispatchId: m.dispatchId,
      action: "gps_geofence_confirmed_exit",
      changes: { stop_type: "delivery", ...meta },
    });
  }
}

// ---------------------------------------------------------------------------
// Detention notifications (spec section 18): 30 min before, on start, and
// at 60+ min, each firing at most once per stop (deduped via the
// dispatch_geofence_state row itself). In-app only (notifications table),
// fanned out to every owner/admin/dispatcher profile in the org -- no
// external SMS/email infrastructure exists in this app to reuse.
// ---------------------------------------------------------------------------
async function maybeNotifyDetention(
  supabase: ServiceRoleClient,
  ctx: {
    organizationId: string;
    dispatchId: string;
    geofenceStateId: string;
    stopType: "pickup" | "delivery";
    arrivedAt: string | null;
    freeMinutes: number;
    now: string;
    already: { warning: boolean; started: boolean; sixty: boolean };
  }
) {
  if (!ctx.arrivedAt) return;
  const now = new Date(ctx.now);
  const elapsedMinutes = Math.floor((now.getTime() - new Date(ctx.arrivedAt).getTime()) / 60000);
  const remaining = ctx.freeMinutes - elapsedMinutes;
  const detention = calculateDetention(ctx.arrivedAt, null, ctx.freeMinutes, now);

  const events: { key: "warning" | "started" | "sixty"; title: string; body: string }[] = [];
  if (remaining > 0 && remaining <= 30 && !ctx.already.warning) {
    events.push({ key: "warning", title: "Detention starting soon", body: `Free time at ${ctx.stopType} ends in ${remaining}m.` });
  }
  if (detention?.inDetention && !ctx.already.started) {
    events.push({ key: "started", title: "Detention started", body: `Truck is now in detention at ${ctx.stopType}.` });
  }
  if (detention?.inDetention && detention.minutes >= 60 && !ctx.already.sixty) {
    events.push({ key: "sixty", title: "Detention over 60 minutes", body: `Detention at ${ctx.stopType} has passed 60 minutes.` });
  }
  if (events.length === 0) return;

  const { data: recipients } = await supabase
    .from("profiles")
    .select("id")
    .eq("organization_id", ctx.organizationId)
    .in("role", ["owner", "admin", "dispatcher"])
    .eq("is_active", true);

  if (recipients && recipients.length > 0) {
    for (const ev of events) {
      const rows = recipients.map((r) => ({
        organization_id: ctx.organizationId,
        profile_id: r.id,
        type: "system" as const,
        title: ev.title,
        body: ev.body,
        entity_type: "dispatch" as const,
        entity_id: ctx.dispatchId,
      }));
      const { error } = await supabase.from("notifications").insert(rows);
      if (error) console.error(`[geofence] detention notification insert failed (${ev.key}):`, error);
    }
  }

  const dedupeUpdate: Record<string, string> = {};
  if (events.some((e) => e.key === "warning")) dedupeUpdate.detention_warning_notified_at = ctx.now;
  if (events.some((e) => e.key === "started")) dedupeUpdate.detention_started_notified_at = ctx.now;
  if (events.some((e) => e.key === "sixty")) dedupeUpdate.detention_60min_notified_at = ctx.now;
  await supabase.from("dispatch_geofence_state").update(dedupeUpdate).eq("id", ctx.geofenceStateId);
}

// ---------------------------------------------------------------------------
// Entry point, called from the location-ping route after a ping is
// accepted. Best-effort by design: any failure here (including migration
// 0059 not being applied yet) is logged and swallowed -- it must never
// break the underlying "record a GPS ping" request, which already
// succeeded before this is called.
// ---------------------------------------------------------------------------
export async function evaluateGeofencesForDispatch(input: PingInput): Promise<void> {
  try {
    const supabase = createServiceRoleClient();

    const { data: org, error: orgError } = await supabase
      .from("organizations")
      .select("pickup_geofence_radius_m, delivery_geofence_radius_m, gps_automation_mode, pickup_detention_free_minutes, delivery_detention_free_minutes")
      .eq("id", input.organizationId)
      .maybeSingle();
    if (orgError || !org) {
      if (orgError) console.warn("[geofence] org settings unavailable (likely migration 0059 not applied yet), skipping evaluation:", orgError.message);
      return;
    }
    if (org.gps_automation_mode === "off") return;

    const dispatch = await fetchDispatchCore(supabase, input.dispatchId);
    if (!dispatch) return;

    const { data: stopsRaw, error: stopsError } = await supabase
      .from("load_stops")
      .select("id, stop_type, stop_sequence, latitude, longitude, arrived_at, departed_at")
      .eq("load_id", dispatch.load_id)
      .order("stop_sequence");
    if (stopsError || !stopsRaw) {
      if (stopsError) console.warn("[geofence] load_stops query failed, skipping evaluation:", stopsError.message);
      return;
    }
    const pickupStop = stopsRaw.filter((s) => s.stop_type === "pickup")[0] ?? null;
    const deliveryStop = stopsRaw.filter((s) => s.stop_type === "delivery").slice(-1)[0] ?? null;

    const targets = [
      { stop: pickupStop, stopType: "pickup" as const, radius: org.pickup_geofence_radius_m, freeMinutes: org.pickup_detention_free_minutes ?? 120 },
      { stop: deliveryStop, stopType: "delivery" as const, radius: org.delivery_geofence_radius_m, freeMinutes: org.delivery_detention_free_minutes ?? 120 },
    ];

    for (const target of targets) {
      if (!target.stop) continue;
      const coords = resolveStopCoordinates(target.stop);
      if (!coords) continue; // "Geofence unavailable -- stop coordinates missing" -- surfaced in the UI, not here.

      const { data: existingRow } = await supabase
        .from("dispatch_geofence_state")
        .select("id, state, inside_confirmations, outside_confirmations, first_inside_at, confirmed_inside_at, confirmed_outside_at, detention_warning_notified_at, detention_started_notified_at, detention_60min_notified_at")
        .eq("dispatch_id", input.dispatchId)
        .eq("load_stop_id", target.stop.id)
        .maybeSingle();

      const result = evaluateGeofencePing(
        existingRow as GeofenceStateRow | null,
        { latitude: input.latitude, longitude: input.longitude, accuracyMeters: input.accuracyMeters, recordedAt: input.recordedAt },
        coords,
        target.radius
      );

      const { data: savedRow, error: upsertError } = await supabase
        .from("dispatch_geofence_state")
        .upsert(
          {
            organization_id: input.organizationId,
            dispatch_id: input.dispatchId,
            load_stop_id: target.stop.id,
            stop_type: target.stopType,
            state: result.state,
            inside_confirmations: result.inside_confirmations,
            outside_confirmations: result.outside_confirmations,
            first_inside_at: result.first_inside_at,
            confirmed_inside_at: result.confirmed_inside_at,
            confirmed_outside_at: result.confirmed_outside_at,
            last_distance_m: result.last_distance_m,
            last_accuracy_m: result.last_accuracy_m,
            last_location_at: result.last_location_at,
          },
          { onConflict: "dispatch_id,load_stop_id" }
        )
        .select("id")
        .single();
      if (upsertError || !savedRow) {
        console.warn("[geofence] dispatch_geofence_state upsert failed, skipping automation for this stop:", upsertError?.message);
        continue;
      }

      const forceApply = org.gps_automation_mode === "automatic";
      const meta: TransitionMeta = {
        organizationId: input.organizationId,
        dispatchId: input.dispatchId,
        loadStopId: target.stop.id,
        distanceM: result.last_distance_m,
        accuracyM: result.last_accuracy_m,
        now: input.recordedAt,
        source: "system:gps",
      };

      let effectiveArrivedAt = target.stop.arrived_at as string | null;

      if (result.justConfirmedInside) {
        const outcome =
          target.stopType === "pickup" ? await applyPickupArrival(supabase, meta, forceApply) : await applyDeliveryArrival(supabase, meta, forceApply);
        effectiveArrivedAt = outcome.arrivedAt;
      }
      if (result.justConfirmedOutside) {
        if (target.stopType === "pickup") await applyPickupDeparture(supabase, meta, forceApply);
        else await logDeliveryExit(supabase, meta);
      }

      if (result.state === "inside") {
        await maybeNotifyDetention(supabase, {
          organizationId: input.organizationId,
          dispatchId: input.dispatchId,
          geofenceStateId: savedRow.id,
          stopType: target.stopType,
          arrivedAt: effectiveArrivedAt,
          freeMinutes: target.freeMinutes,
          now: input.recordedAt,
          already: {
            warning: !!existingRow?.detention_warning_notified_at,
            started: !!existingRow?.detention_started_notified_at,
            sixty: !!existingRow?.detention_60min_notified_at,
          },
        });
      }
    }
  } catch (err) {
    console.error("[geofence] evaluateGeofencesForDispatch failed:", err);
  }
}
