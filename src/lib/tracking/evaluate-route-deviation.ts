import "server-only";
import { revalidatePath } from "next/cache";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { nearestPointOnRoute, type RouteGeometryPoint } from "@/lib/geo/route-distance";
import {
  evaluateDeviationPing,
  DEVIATION_ACCURACY_LIMIT_M,
  type DeviationStateRow,
  type DeviationThresholds,
} from "@/lib/tracking/route-deviation";
import { getNextOperationalStop, type OperationalStop } from "@/lib/routing/next-stop";
import { forceRefreshRouteIntelligence } from "@/lib/routing/evaluate-route";
import { formatMiles } from "@/lib/routing/risk";
import { syncExceptionsForDispatch } from "@/lib/exceptions/sync";

// ---------------------------------------------------------------------------
// Route Deviation orchestration (Phase 2D). Same role as
// evaluate-geofences.ts / evaluate-route.ts's runEvaluation(): fetches the
// dispatch/stop/org/route context, runs the pure state machine
// (route-deviation.ts) against the current GPS ping, persists the result,
// and applies the operational side effects a confirmed transition implies
// (dispatcher notification, activity log, forced ETA recalculation).
//
// Called from /api/driver-portal/location's POST handler, AFTER geofence
// and route-intelligence evaluation (spec section 17's pipeline: route
// intelligence may recalculate geometry that this step needs to be current
// against). Entirely best-effort -- never throws, never turns a valid GPS
// ping into a failed request.
// ---------------------------------------------------------------------------

const STALE_GPS_MINUTES = 5; // matches STALE_LOCATION_MINUTES (board-actions.ts) / STALE_MINUTES (live-map.tsx) / risk.ts's confidence threshold

type ServiceRoleClient = ReturnType<typeof createServiceRoleClient>;
type PingInput = {
  dispatchId: string;
  organizationId: string;
  latitude: number;
  longitude: number;
  accuracyMeters: number | null;
  recordedAt: string;
};

type DispatchCore = { id: string; status: string; load_id: string };

async function fetchDispatchCore(supabase: ServiceRoleClient, dispatchId: string): Promise<DispatchCore | null> {
  const { data } = await supabase.from("dispatches").select("id, status, load_id").eq("id", dispatchId).maybeSingle();
  return (data as DispatchCore) ?? null;
}

async function logActivity(supabase: ServiceRoleClient, params: { organizationId: string; dispatchId: string; action: string; changes: Record<string, unknown> }) {
  const { error } = await supabase.from("activity_logs").insert({
    organization_id: params.organizationId,
    entity_type: "dispatch",
    entity_id: params.dispatchId,
    action: params.action,
    actor_id: null, // system/GPS-originated, never attributed to a human (matches geofence.ts/evaluate-route.ts)
    changes: params.changes,
  });
  if (error) console.error(`[route-deviation] activity_logs insert failed (action=${params.action}):`, error);
}

async function notifyOfficeStaff(supabase: ServiceRoleClient, organizationId: string, dispatchId: string, title: string, body: string) {
  const { data: recipients } = await supabase.from("profiles").select("id").eq("organization_id", organizationId).in("role", ["owner", "admin", "dispatcher"]).eq("is_active", true);
  if (!recipients || recipients.length === 0) return;
  const rows = recipients.map((r) => ({ organization_id: organizationId, profile_id: r.id, type: "system" as const, title, body, entity_type: "dispatch" as const, entity_id: dispatchId }));
  const { error } = await supabase.from("notifications").insert(rows);
  if (error) console.error("[route-deviation] notification insert failed:", error);
}

type ExistingRow = DeviationStateRow & {
  id: string;
  calculation_status: string;
  route_intelligence_id: string | null;
  route_calculated_at: string | null;
  last_location_at: string | null;
};

async function fetchExistingRow(supabase: ServiceRoleClient, dispatchId: string, targetStopId: string): Promise<ExistingRow | null> {
  const { data, error } = await supabase
    .from("dispatch_route_deviation_state")
    .select(
      "id, state, calculation_status, candidate_started_at, candidate_ping_count, confirmed_at, recovery_started_at, recovery_ping_count, recovered_at, route_intelligence_id, route_calculated_at, last_location_at"
    )
    .eq("dispatch_id", dispatchId)
    .eq("target_stop_id", targetStopId)
    .maybeSingle();
  if (error) console.warn("[route-deviation] dispatch_route_deviation_state unavailable (likely migration 0062 not applied yet):", error.message);
  return (data as unknown as ExistingRow) ?? null;
}

async function upsertRow(
  supabase: ServiceRoleClient,
  base: { organizationId: string; dispatchId: string; targetStopId: string },
  fields: Record<string, unknown>
) {
  const { error } = await supabase.from("dispatch_route_deviation_state").upsert(
    { organization_id: base.organizationId, dispatch_id: base.dispatchId, target_stop_id: base.targetStopId, ...fields },
    { onConflict: "dispatch_id,target_stop_id" }
  );
  if (error) console.warn("[route-deviation] dispatch_route_deviation_state upsert failed (likely migration 0062 not applied yet):", error.message);
}

async function runEvaluation(supabase: ServiceRoleClient, input: PingInput): Promise<void> {
  const { data: org, error: orgError } = await supabase
    .from("organizations")
    .select("route_deviation_enabled, route_deviation_warning_m, route_deviation_confirmed_m, route_deviation_recovery_m, timezone")
    .eq("id", input.organizationId)
    .maybeSingle();
  if (orgError || !org) {
    if (orgError) console.warn("[route-deviation] org settings unavailable (likely migration 0062 not applied yet), skipping evaluation:", orgError.message);
    return;
  }
  if (!org.route_deviation_enabled) return; // feature toggle (spec section 39) -- conservative default off

  const dispatch = await fetchDispatchCore(supabase, input.dispatchId);
  if (!dispatch) return;

  const { data: stopsRaw } = await supabase
    .from("load_stops")
    .select("id, stop_type, stop_sequence, latitude, longitude, arrived_at, departed_at, scheduled_at, scheduled_window_end, timezone")
    .eq("load_id", dispatch.load_id)
    .order("stop_sequence");
  const targetStop = getNextOperationalStop(dispatch.status, (stopsRaw ?? []) as OperationalStop[]);
  if (!targetStop) return; // trip complete / no stops -- nothing to evaluate (spec section 19)

  const existing = await fetchExistingRow(supabase, input.dispatchId, targetStop.id);
  const base = { organizationId: input.organizationId, dispatchId: input.dispatchId, targetStopId: targetStop.id };

  // Out-of-order ping guard (spec section 47): a ping older than the last
  // one this row was evaluated against must never regress current state.
  // Silently ignored, not even a calculation_status write -- there is
  // nothing meaningful to record about a ping we're refusing to act on.
  if (existing?.last_location_at && new Date(input.recordedAt).getTime() <= new Date(existing.last_location_at).getTime()) {
    return;
  }

  // ARRIVED short-circuit (spec sections 20-21): once the geofence system
  // has confirmed physical presence at the target stop, wandering a large
  // facility yard must never read as "off route". Mirrors evaluate-route.ts's
  // identical arrived_at short-circuit exactly. State is left untouched
  // (still visible/auditable); only calculation_status changes.
  if (targetStop.arrived_at) {
    await upsertRow(supabase, base, { calculation_status: "arrived", last_evaluated_at: input.recordedAt, last_location_at: input.recordedAt, last_accuracy_m: input.accuracyMeters });
    return;
  }

  const { data: routeRow } = await supabase
    .from("dispatch_route_intelligence")
    .select("id, route_geometry, calculation_status, calculated_at")
    .eq("dispatch_id", input.dispatchId)
    .eq("target_stop_id", targetStop.id)
    .maybeSingle();
  const geometry = (routeRow?.route_geometry as RouteGeometryPoint[] | null) ?? null;
  if (!routeRow || routeRow.calculation_status !== "ok" || !geometry || geometry.length === 0) {
    // No usable route geometry yet (never calculated, or last attempt
    // failed) -- honest "unavailable", never a fabricated on/off-route
    // answer (spec section 18).
    await upsertRow(supabase, base, { calculation_status: "no_geometry", last_evaluated_at: input.recordedAt, last_location_at: input.recordedAt, last_accuracy_m: input.accuracyMeters });
    return;
  }

  // Stale GPS (spec section 7): reuse the app's established ~5-minute
  // threshold rather than inventing a new one. Distance is still computed
  // and stored for diagnostic visibility (spec section 6), but never fed
  // into the state machine.
  const ageMinutes = (Date.now() - new Date(input.recordedAt).getTime()) / 60000;
  const nearest = nearestPointOnRoute(input.latitude, input.longitude, geometry);
  if (ageMinutes > STALE_GPS_MINUTES) {
    await upsertRow(supabase, base, {
      calculation_status: "stale_gps",
      distance_from_route_m: nearest?.distanceMeters ?? null,
      last_evaluated_at: input.recordedAt,
      last_location_at: input.recordedAt,
      last_accuracy_m: input.accuracyMeters,
    });
    return;
  }

  // GPS quality gate (spec section 6): a low-accuracy ping keeps tracking
  // (the raw ping is already recorded elsewhere) but must never move the
  // deviation state machine -- e.g. a 900m-accuracy fix reading 700m from
  // the route is not proof of anything.
  const accuracyEligible = input.accuracyMeters == null || input.accuracyMeters <= DEVIATION_ACCURACY_LIMIT_M;
  if (!accuracyEligible) {
    await upsertRow(supabase, base, {
      calculation_status: "low_accuracy",
      distance_from_route_m: nearest?.distanceMeters ?? null,
      last_evaluated_at: input.recordedAt,
      last_location_at: input.recordedAt,
      last_accuracy_m: input.accuracyMeters,
    });
    return;
  }

  if (!nearest) {
    await upsertRow(supabase, base, { calculation_status: "no_geometry", last_evaluated_at: input.recordedAt, last_location_at: input.recordedAt, last_accuracy_m: input.accuracyMeters });
    return;
  }

  // Route-version awareness (spec section 15 -- "critical"). A route
  // recalculation since our last evaluation is detected by comparing
  // dispatch_route_intelligence's calculated_at -- NOT its id. That row is
  // upserted onConflict(dispatch_id,target_stop_id) on every recalculation
  // (see evaluate-route.ts), so its id is stable for the row's entire
  // lifetime and would never change even across many real recalculations;
  // calculated_at is the field that actually advances on every successful
  // new calculation, making it the correct version signal. An IN-PROGRESS
  // (not yet confirmed) candidate episode is reset when this changes --
  // its evidence was gathered against geometry that no longer represents
  // the expected route, and spec section 55 explicitly requires it not
  // silently confirm against new geometry. A CONFIRMED off_route/recovering
  // episode is left alone: that historical fact doesn't un-happen just
  // because the route recalculated (spec section 16) -- ordinary recovery
  // hysteresis (still fully intact below) is what clears it, never an
  // instant reset.
  const routeChanged = existing != null && existing.route_calculated_at != null && existing.route_calculated_at !== routeRow.calculated_at;
  let effectiveExisting: DeviationStateRow | null = existing;
  if (routeChanged && existing?.state === "candidate") {
    effectiveExisting = { state: "on_route", candidate_started_at: null, candidate_ping_count: 0, confirmed_at: existing.confirmed_at, recovery_started_at: existing.recovery_started_at, recovery_ping_count: existing.recovery_ping_count, recovered_at: existing.recovered_at };
  }
  if (routeChanged && (existing?.state === "off_route" || existing?.state === "recovering")) {
    await logActivity(supabase, { organizationId: input.organizationId, dispatchId: input.dispatchId, action: "route_recalculated_while_off_route", changes: { stop_id: targetStop.id, source: "system:route" } });
  }

  const wasHardCandidate = effectiveExisting?.state === "candidate" && effectiveExisting.candidate_ping_count > 0;

  const thresholds: DeviationThresholds = { warningM: org.route_deviation_warning_m, confirmedM: org.route_deviation_confirmed_m, recoveryM: org.route_deviation_recovery_m };
  const result = evaluateDeviationPing(effectiveExisting, nearest.distanceMeters, input.recordedAt, thresholds);

  await upsertRow(supabase, base, {
    state: result.state,
    calculation_status: "ok",
    distance_from_route_m: result.distance_from_route_m,
    candidate_started_at: result.candidate_started_at,
    candidate_ping_count: result.candidate_ping_count,
    confirmed_at: result.confirmed_at,
    recovery_started_at: result.recovery_started_at,
    recovery_ping_count: result.recovery_ping_count,
    recovered_at: result.recovered_at,
    route_intelligence_id: routeRow.id,
    route_calculated_at: routeRow.calculated_at,
    last_evaluated_at: input.recordedAt,
    last_location_at: input.recordedAt,
    last_accuracy_m: input.accuracyMeters,
  });

  // First ping to start a genuine (hard) candidate episode -- informational
  // audit entry only, no notification (spec section 22/24: candidate never
  // notifies).
  const isNowHardCandidate = result.state === "candidate" && result.candidate_ping_count === 1;
  if (isNowHardCandidate && !wasHardCandidate) {
    await logActivity(supabase, { organizationId: input.organizationId, dispatchId: input.dispatchId, action: "route_deviation_candidate_started", changes: { stop_id: targetStop.id, distance_m: Math.round(result.distance_from_route_m), source: "system:gps" } });
  }

  if (result.justConfirmedOffRoute) {
    const [{ data: loadRow }, { data: dispatchLabel }] = await Promise.all([
      supabase.from("loads").select("load_number").eq("id", dispatch.load_id).maybeSingle(),
      supabase.from("dispatches").select("trucks(unit_number)").eq("id", input.dispatchId).maybeSingle(),
    ]);
    const targetLabel = targetStop.stop_type === "pickup" ? "pickup" : "delivery";
    const truckUnit = (dispatchLabel as unknown as { trucks: { unit_number: string } | null } | null)?.trucks?.unit_number ?? null;
    const title = `${loadRow?.load_number ?? "Load"} is off route`;
    const body = `${truckUnit ? `Truck ${truckUnit}` : "Truck"} is approximately ${formatMiles(result.distance_from_route_m)} from the expected route to ${targetLabel}.`;
    await notifyOfficeStaff(supabase, input.organizationId, input.dispatchId, title, body);
    await logActivity(supabase, {
      organizationId: input.organizationId,
      dispatchId: input.dispatchId,
      action: "route_deviation_confirmed",
      changes: { stop_id: targetStop.id, distance_m: Math.round(result.distance_from_route_m), source: "system:gps" },
    });

    // Force exactly one ETA recalculation from the truck's current position
    // (spec section 27) -- reuses the existing routing abstraction/cooldown
    // (forceRefreshRouteIntelligence already has its own 45s anti-spam
    // cooldown, spec section 28) rather than a second OSRM call site.
    forceRefreshRouteIntelligence(input.dispatchId, input.organizationId).catch((err) => console.warn("[route-deviation] forced ETA recalculation failed:", err));

    revalidatePath("/dispatch/board");
    revalidatePath(`/dispatch/${input.dispatchId}`);
    revalidatePath("/tracking");
  }

  if (result.justRecovered) {
    const { data: loadRow } = await supabase.from("loads").select("load_number").eq("id", dispatch.load_id).maybeSingle();
    const minutesOffRoute = result.confirmed_at ? Math.round((new Date(input.recordedAt).getTime() - new Date(result.confirmed_at).getTime()) / 60000) : null;
    await notifyOfficeStaff(
      supabase,
      input.organizationId,
      input.dispatchId,
      `${loadRow?.load_number ?? "Load"} returned to route`,
      minutesOffRoute != null ? `Vehicle returned to the expected route after ${minutesOffRoute} min.` : "Vehicle returned to the expected route."
    );
    await logActivity(supabase, { organizationId: input.organizationId, dispatchId: input.dispatchId, action: "route_deviation_recovered", changes: { stop_id: targetStop.id, minutes_off_route: minutesOffRoute, source: "system:gps" } });

    revalidatePath("/dispatch/board");
    revalidatePath(`/dispatch/${input.dispatchId}`);
    revalidatePath("/tracking");
  }

  // Phase 2E push-hook: sync operational_exceptions ONLY on a meaningful
  // transition (confirmed/recovered), never on every ping -- matches the
  // exact same restraint the notification/activity-log calls above
  // already apply. Fire-and-forget + fully isolated try/catch: a failure
  // here must never break GPS ping processing (spec section 41), and
  // sync.ts itself already no-ops gracefully if migration 0063 isn't
  // applied.
  if (result.justConfirmedOffRoute || result.justRecovered) {
    syncExceptionsForDispatch(supabase, input.organizationId, input.dispatchId).catch((err) => console.warn("[route-deviation] exception sync failed:", err));
  }
}

// Called from the location-ping route, best-effort, after geofence AND
// route-intelligence evaluation already ran (spec section 17's pipeline).
// Never throws -- a deviation-evaluation failure must never break GPS
// tracking or route intelligence, both of which already succeeded before
// this is ever reached.
export async function evaluateRouteDeviation(input: PingInput): Promise<void> {
  try {
    const supabase = createServiceRoleClient();
    await runEvaluation(supabase, input);
  } catch (err) {
    console.error("[route-deviation] evaluateRouteDeviation failed:", err);
  }
}
