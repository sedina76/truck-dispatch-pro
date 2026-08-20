import "server-only";
import { revalidatePath } from "next/cache";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { distanceMeters } from "@/lib/geo/distance";
import { getRoutingProvider } from "./provider";
import { getNextOperationalStop, type OperationalStop } from "./next-stop";
import { classifyRisk, classifyConfidence, type RiskStatus } from "./risk";
import { RoutingProviderError } from "./types";
import { resolveStopTimezone } from "@/lib/timezone/resolve";
import { formatStopDateTime } from "@/lib/timezone/format";
import { syncExceptionsForDispatch } from "@/lib/exceptions/sync";

type ServiceRoleClient = ReturnType<typeof createServiceRoleClient>;

// ---------------------------------------------------------------------------
// Recalculation thresholds (spec section 12) -- centralized here, not
// scattered. Chosen from the middle of each suggested range.
// ---------------------------------------------------------------------------
const RECALC_MIN_INTERVAL_MS = 7 * 60 * 1000; // ~5-10 min
const RECALC_MIN_DISTANCE_MOVED_METERS = 8 * 1609.344; // ~5-10 road miles (straight-line proxy -- see note below)
const MANUAL_REFRESH_COOLDOWN_MS = 45 * 1000; // spec section 34: 30-60s anti-spam

type PingInput = {
  dispatchId: string;
  organizationId: string;
  latitude: number;
  longitude: number;
  accuracyMeters: number | null;
  recordedAt: string;
};

type DispatchCore = { id: string; status: string; load_id: string; driver_id: string; truck_id: string | null };

async function fetchDispatchCore(supabase: ServiceRoleClient, dispatchId: string): Promise<DispatchCore | null> {
  const { data, error } = await supabase.from("dispatches").select("id, status, load_id, driver_id, truck_id").eq("id", dispatchId).maybeSingle();
  if (error || !data) return null;
  return data as DispatchCore;
}

type RouteRow = {
  id: string;
  target_stop_id: string;
  origin_latitude: number | null;
  origin_longitude: number | null;
  route_distance_meters: number | null;
  route_duration_seconds: number | null;
  route_geometry: unknown;
  initial_distance_meters: number | null;
  estimated_arrival_at: string | null;
  appointment_at: string | null;
  appointment_window_end: string | null;
  schedule_variance_minutes: number | null;
  risk_status: RiskStatus;
  confidence: string;
  calculation_status: string;
  calculated_at: string | null;
};

async function fetchExistingRow(supabase: ServiceRoleClient, dispatchId: string, targetStopId: string): Promise<RouteRow | null> {
  const { data, error } = await supabase.from("dispatch_route_intelligence").select("*").eq("dispatch_id", dispatchId).eq("target_stop_id", targetStopId).maybeSingle();
  if (error) console.warn("[route-intel] dispatch_route_intelligence unavailable (likely migration 0060 not applied yet):", error.message);
  return (data as unknown as RouteRow) ?? null;
}

async function logActivity(supabase: ServiceRoleClient, params: { organizationId: string; dispatchId: string; action: string; changes: Record<string, unknown> }) {
  const { error } = await supabase.from("activity_logs").insert({
    organization_id: params.organizationId,
    entity_type: "dispatch",
    entity_id: params.dispatchId,
    action: params.action,
    actor_id: null,
    changes: params.changes,
  });
  if (error) console.error(`[route-intel] activity_logs insert failed (action=${params.action}):`, error);
}

const ALERTABLE_TRANSITIONS = new Set(["on_time->at_risk", "at_risk->late", "late->at_risk", "at_risk->on_time"]);

async function maybeAlertRiskTransition(
  supabase: ServiceRoleClient,
  ctx: { organizationId: string; dispatchId: string; loadNumber: string | null },
  from: RiskStatus | null,
  to: RiskStatus,
  etaLabel: string | null,
  appointmentLabel: string | null
) {
  if (!from || from === to) return;
  const key = `${from}->${to}`;
  if (!ALERTABLE_TRANSITIONS.has(key)) return;

  const RISK_LABEL: Record<RiskStatus, string> = { unknown: "Unknown", on_time: "On Time", at_risk: "At Risk", late: "Late", arrived: "Arrived" };
  const title = `Load ${ctx.loadNumber ?? ""} is now ${RISK_LABEL[to].toUpperCase()}`.trim();
  const body =
    to === "late" && etaLabel && appointmentLabel
      ? `Projected late. ETA ${etaLabel} for ${appointmentLabel} appointment.`
      : etaLabel && appointmentLabel
        ? `ETA ${etaLabel} for ${appointmentLabel} appointment.`
        : `Risk changed from ${RISK_LABEL[from]} to ${RISK_LABEL[to]}.`;

  const { data: recipients } = await supabase.from("profiles").select("id").eq("organization_id", ctx.organizationId).in("role", ["owner", "admin", "dispatcher"]).eq("is_active", true);
  if (recipients && recipients.length > 0) {
    const rows = recipients.map((r) => ({ organization_id: ctx.organizationId, profile_id: r.id, type: "system" as const, title, body, entity_type: "dispatch" as const, entity_id: ctx.dispatchId }));
    const { error } = await supabase.from("notifications").insert(rows);
    if (error) console.error("[route-intel] risk transition notification insert failed:", error);
  }

  await logActivity(supabase, { organizationId: ctx.organizationId, dispatchId: ctx.dispatchId, action: "eta_risk_changed", changes: { from, to, source: "system:route" } });

  // Phase 2E push-hook -- same restraint as Phase 2D's own hook in
  // evaluate-route-deviation.ts: only on an alertable transition (already
  // gated above), never on every recalculation. Fire-and-forget +
  // isolated: a failure here must never break ETA/risk evaluation.
  syncExceptionsForDispatch(supabase, ctx.organizationId, ctx.dispatchId).catch((err) => console.warn("[route-intel] exception sync failed:", err));
}

function shouldRecalculate(existing: RouteRow | null, currentLat: number, currentLon: number, nowIso: string, forceRecalc: boolean): boolean {
  if (forceRecalc) return true;
  if (!existing || existing.calculated_at == null) return true;
  if (existing.origin_latitude == null || existing.origin_longitude == null) return true;

  const elapsedMs = new Date(nowIso).getTime() - new Date(existing.calculated_at).getTime();
  if (elapsedMs >= RECALC_MIN_INTERVAL_MS) return true;

  const movedMeters = distanceMeters(existing.origin_latitude, existing.origin_longitude, currentLat, currentLon);
  if (movedMeters >= RECALC_MIN_DISTANCE_MOVED_METERS) return true;

  return false;
}

type RunResult = { ok: true } | { ok: false; error: string };

async function runEvaluation(supabase: ServiceRoleClient, input: PingInput, forceRecalc: boolean): Promise<RunResult> {
  const dispatch = await fetchDispatchCore(supabase, input.dispatchId);
  if (!dispatch) return { ok: false, error: "Dispatch not found." };

  const { data: stopsRaw, error: stopsError } = await supabase
    .from("load_stops")
    .select("id, stop_type, stop_sequence, latitude, longitude, arrived_at, departed_at, scheduled_at, scheduled_window_end, timezone")
    .eq("load_id", dispatch.load_id)
    .order("stop_sequence");
  if (stopsError || !stopsRaw) return { ok: false, error: "Could not load stops." };

  const targetStop = getNextOperationalStop(dispatch.status, stopsRaw as OperationalStop[]);
  if (!targetStop) return { ok: true }; // trip complete / no stops -- nothing to calculate

  const { data: loadRow } = await supabase.from("loads").select("load_number").eq("id", dispatch.load_id).maybeSingle();
  // Phase 2C.1: ETA/appointment in alerts must render in the TARGET
  // STOP's own timezone, never the server process's local zone (the
  // exact same class of bug this whole phase exists to fix -- this one
  // was freshly introduced by Phase 2C's own alert text, caught here
  // before it ever reached a live notification).
  const { data: orgRowForTz } = await supabase.from("organizations").select("timezone").eq("id", input.organizationId).maybeSingle();
  const targetStopTimezone = resolveStopTimezone(targetStop.timezone ?? null, orgRowForTz?.timezone ?? null).timezone;

  const existing = await fetchExistingRow(supabase, input.dispatchId, targetStop.id);

  // ARRIVED short-circuit (spec section 28): the geofence system already
  // confirmed presence and set arrived_at -- no route call needed for a
  // truck that's already there. Risk becomes 'arrived' immediately.
  if (targetStop.arrived_at) {
    const { data: saved, error: upsertError } = await supabase
      .from("dispatch_route_intelligence")
      .upsert(
        {
          organization_id: input.organizationId,
          dispatch_id: input.dispatchId,
          driver_id: dispatch.driver_id,
          truck_id: dispatch.truck_id,
          target_stop_id: targetStop.id,
          risk_status: "arrived",
          appointment_at: targetStop.scheduled_at,
          appointment_window_end: targetStop.scheduled_window_end,
          source_location_at: input.recordedAt,
        },
        { onConflict: "dispatch_id,target_stop_id" }
      )
      .select("id")
      .single();
    if (!upsertError && saved) {
      await maybeAlertRiskTransition(supabase, { organizationId: input.organizationId, dispatchId: input.dispatchId, loadNumber: loadRow?.load_number ?? null }, existing?.risk_status ?? null, "arrived", null, null);
      revalidatePath("/dispatch/board");
      revalidatePath(`/dispatch/${input.dispatchId}`);
    }
    return { ok: true };
  }

  const targetCoords = targetStop.latitude != null && targetStop.longitude != null ? { latitude: targetStop.latitude, longitude: targetStop.longitude } : null;
  if (!targetCoords) {
    // "Stop coordinates missing" -- same philosophy as the geofence
    // system's identical case (0059): a lightweight row so the UI can
    // render a specific, honest reason instead of nothing.
    const { error: noCoordError } = await supabase.from("dispatch_route_intelligence").upsert(
      {
        organization_id: input.organizationId,
        dispatch_id: input.dispatchId,
        driver_id: dispatch.driver_id,
        truck_id: dispatch.truck_id,
        target_stop_id: targetStop.id,
        calculation_status: "no_coordinates",
        risk_status: "unknown",
        appointment_at: targetStop.scheduled_at,
        appointment_window_end: targetStop.scheduled_window_end,
        source_location_at: input.recordedAt,
      },
      { onConflict: "dispatch_id,target_stop_id" }
    );
    if (noCoordError) console.warn("[route-intel] no_coordinates row write failed (likely migration 0060 not applied yet):", noCoordError.message);
    return { ok: true };
  }

  if (!shouldRecalculate(existing, input.latitude, input.longitude, input.recordedAt, forceRecalc)) {
    return { ok: true }; // cached route intelligence is still fresh enough -- no provider call
  }

  const provider = getRoutingProvider();
  const startMs = Date.now();

  if (!provider) {
    console.log("[route-intel] no routing provider configured (ROUTING_PROVIDER=none) -- skipping calculation", { organization_id: input.organizationId, dispatch_id: input.dispatchId });
    const { error: noProviderError } = await supabase.from("dispatch_route_intelligence").upsert(
      {
        organization_id: input.organizationId,
        dispatch_id: input.dispatchId,
        driver_id: dispatch.driver_id,
        truck_id: dispatch.truck_id,
        target_stop_id: targetStop.id,
        calculation_status: "provider_unavailable",
        appointment_at: targetStop.scheduled_at,
        appointment_window_end: targetStop.scheduled_window_end,
        source_location_at: input.recordedAt,
      },
      { onConflict: "dispatch_id,target_stop_id" }
    );
    if (noProviderError) console.warn("[route-intel] provider_unavailable row write failed (likely migration 0060 not applied yet):", noProviderError.message);
    return { ok: true };
  }

  try {
    const result = await provider.getRoute({ origin: { latitude: input.latitude, longitude: input.longitude }, destination: targetCoords });
    const calculationMs = Date.now() - startMs;
    console.log("[route-intel] calculation ok", {
      organization_id: input.organizationId,
      dispatch_id: input.dispatchId,
      target_stop_id: targetStop.id,
      provider: result.provider,
      distance_m: Math.round(result.distanceMeters),
      duration_s: Math.round(result.durationSeconds),
      calculation_ms: calculationMs,
      result: "ok",
    });

    const estimatedArrivalAt = new Date(new Date(result.calculatedAt).getTime() + result.durationSeconds * 1000).toISOString();
    const appointmentAt = targetStop.scheduled_at ? new Date(targetStop.scheduled_at) : null;
    const appointmentWindowEnd = targetStop.scheduled_window_end ? new Date(targetStop.scheduled_window_end) : null;
    const { status: riskStatus, scheduleVarianceMinutes } = classifyRisk(new Date(estimatedArrivalAt), appointmentAt, appointmentWindowEnd, false);
    const confidence = classifyConfidence({ gpsAgeMinutes: 0, gpsAccuracyMeters: input.accuracyMeters, routeAgeMinutes: 0, distanceRemainingMeters: result.distanceMeters });
    const initialDistanceMeters = existing?.initial_distance_meters ?? result.distanceMeters;

    const { data: saved, error: upsertError } = await supabase
      .from("dispatch_route_intelligence")
      .upsert(
        {
          organization_id: input.organizationId,
          dispatch_id: input.dispatchId,
          driver_id: dispatch.driver_id,
          truck_id: dispatch.truck_id,
          target_stop_id: targetStop.id,
          origin_latitude: input.latitude,
          origin_longitude: input.longitude,
          destination_latitude: targetCoords.latitude,
          destination_longitude: targetCoords.longitude,
          route_distance_meters: result.distanceMeters,
          route_duration_seconds: Math.round(result.durationSeconds),
          route_geometry: result.geometry,
          initial_distance_meters: initialDistanceMeters,
          estimated_arrival_at: estimatedArrivalAt,
          appointment_at: targetStop.scheduled_at,
          appointment_window_end: targetStop.scheduled_window_end,
          schedule_variance_minutes: scheduleVarianceMinutes,
          risk_status: riskStatus,
          confidence,
          provider: result.provider,
          calculation_status: "ok",
          calculated_at: result.calculatedAt,
          source_location_at: input.recordedAt,
        },
        { onConflict: "dispatch_id,target_stop_id" }
      )
      .select("id")
      .single();

    if (upsertError || !saved) {
      console.error("[route-intel] upsert failed:", upsertError);
      return { ok: false, error: "Could not save route intelligence." };
    }

    const etaLabel = formatStopDateTime(estimatedArrivalAt, targetStopTimezone, { timeOnly: true });
    const appointmentLabel = appointmentAt ? formatStopDateTime(appointmentAt.toISOString(), targetStopTimezone, { timeOnly: true }) : null;
    await maybeAlertRiskTransition(supabase, { organizationId: input.organizationId, dispatchId: input.dispatchId, loadNumber: loadRow?.load_number ?? null }, existing?.risk_status ?? null, riskStatus, etaLabel, appointmentLabel);

    // "Next operational stop changed" (spec section 30): fires once, the
    // first time THIS target stop gets a row, if a prior row for a
    // DIFFERENT target stop already existed for this dispatch.
    if (!existing) {
      const { data: priorForOtherStop } = await supabase
        .from("dispatch_route_intelligence")
        .select("target_stop_id")
        .eq("dispatch_id", input.dispatchId)
        .neq("target_stop_id", targetStop.id)
        .order("updated_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (priorForOtherStop) {
        await logActivity(supabase, { organizationId: input.organizationId, dispatchId: input.dispatchId, action: "next_stop_changed", changes: { new_target_stop_id: targetStop.id, source: "system:route" } });
      }
    }

    revalidatePath("/dispatch/board");
    revalidatePath(`/dispatch/${input.dispatchId}`);
    revalidatePath("/tracking");
    return { ok: true };
  } catch (err) {
    const calculationMs = Date.now() - startMs;
    const errorCode = err instanceof RoutingProviderError ? err.code : "unknown";
    console.error("[route-intel] calculation failed", {
      organization_id: input.organizationId,
      dispatch_id: input.dispatchId,
      target_stop_id: targetStop.id,
      calculation_ms: calculationMs,
      result: "error",
      error_code: errorCode,
      message: err instanceof Error ? err.message : String(err),
    });

    const wasOk = !existing || existing.calculation_status === "ok";
    // Keep prior route numbers/risk_status untouched (spec section 27) --
    // only the failure marker + confidence degrade.
    await supabase
      .from("dispatch_route_intelligence")
      .upsert(
        {
          organization_id: input.organizationId,
          dispatch_id: input.dispatchId,
          driver_id: dispatch.driver_id,
          truck_id: dispatch.truck_id,
          target_stop_id: targetStop.id,
          calculation_status: "provider_unavailable",
          confidence: "low",
          appointment_at: targetStop.scheduled_at,
          appointment_window_end: targetStop.scheduled_window_end,
          source_location_at: input.recordedAt,
        },
        { onConflict: "dispatch_id,target_stop_id" }
      );

    if (wasOk) {
      await logActivity(supabase, { organizationId: input.organizationId, dispatchId: input.dispatchId, action: "route_unavailable", changes: { error_code: errorCode, source: "system:route" } });
    }
    return { ok: true }; // a routing failure is never a failed GPS ping (spec section 14) -- always ok from the caller's perspective
  }
}

// Called from the location-ping route, best-effort, after geofence
// evaluation already ran (spec section 14's architecture diagram). Never
// throws -- a routing failure must never break GPS tracking.
export async function evaluateRouteIntelligence(input: PingInput): Promise<void> {
  try {
    const supabase = createServiceRoleClient();
    await runEvaluation(supabase, input, false);
  } catch (err) {
    console.error("[route-intel] evaluateRouteIntelligence failed:", err);
  }
}

// Dispatcher-facing "Refresh ETA" (spec section 34) -- bypasses the normal
// TTL/distance thresholds but keeps its own short anti-spam cooldown
// against the last successful-or-attempted calculation, regardless of
// caller.
export async function forceRefreshRouteIntelligence(dispatchId: string, organizationId: string): Promise<RunResult> {
  const supabase = createServiceRoleClient();

  const dispatch = await fetchDispatchCore(supabase, dispatchId);
  if (!dispatch) return { ok: false, error: "Dispatch not found." };

  const { data: latest } = await supabase.from("driver_latest_locations").select("latitude, longitude, accuracy_meters, recorded_at").eq("driver_id", dispatch.driver_id).maybeSingle();
  if (!latest) return { ok: false, error: "No current GPS location for this driver." };

  const { data: stopsRaw } = await supabase
    .from("load_stops")
    .select("id, stop_type, stop_sequence, latitude, longitude, arrived_at, departed_at, scheduled_at, scheduled_window_end")
    .eq("load_id", dispatch.load_id)
    .order("stop_sequence");
  const targetStop = getNextOperationalStop(dispatch.status, (stopsRaw ?? []) as OperationalStop[]);
  if (targetStop) {
    const existing = await fetchExistingRow(supabase, dispatchId, targetStop.id);
    if (existing?.calculated_at && Date.now() - new Date(existing.calculated_at).getTime() < MANUAL_REFRESH_COOLDOWN_MS) {
      const waitSeconds = Math.ceil((MANUAL_REFRESH_COOLDOWN_MS - (Date.now() - new Date(existing.calculated_at).getTime())) / 1000);
      return { ok: false, error: `Please wait ${waitSeconds}s before refreshing again.` };
    }
  }

  return runEvaluation(
    supabase,
    { dispatchId, organizationId, latitude: latest.latitude, longitude: latest.longitude, accuracyMeters: latest.accuracy_meters, recordedAt: latest.recorded_at },
    true
  );
}
