"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { checkOperationalAccess } from "@/lib/billing/operational-access";
import { forceRefreshRouteIntelligence } from "@/lib/routing/evaluate-route";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

// ---------------------------------------------------------------------------
// refreshDispatchEta -- the dispatcher-facing "Refresh ETA" button (spec
// section 34). Staff-auth + org-ownership checked here exactly like every
// other dispatch action in this file's sibling board-actions.ts; the
// actual bypass-TTL-but-respect-cooldown logic lives in
// forceRefreshRouteIntelligence() (src/lib/routing/evaluate-route.ts) so
// it's shared with nothing else -- this is its only caller.
// ---------------------------------------------------------------------------
export type LiveTrackingRouteInfo = {
  loadNumber: string;
  driverName: string;
  truckUnit: string;
  status: string;
  targetStopLabel: string | null;
  targetStopTimezone: string;
  routeDistanceMeters: number | null;
  routeGeometry: [number, number][] | null;
  estimatedArrivalAt: string | null;
  appointmentAt: string | null;
  appointmentWindowEnd: string | null;
  scheduleVarianceMinutes: number | null;
  riskStatus: "unknown" | "on_time" | "at_risk" | "late" | "arrived";
  calculationStatus: string;
  calculatedAt: string | null;
  // Phase 2D (0062_route_deviation.sql) -- null when the migration isn't
  // applied, monitoring is off for this org, or nothing has evaluated yet
  // (same degrade-to-null philosophy as everything else here).
  deviation: {
    state: "on_route" | "candidate" | "off_route" | "recovering" | "recovered";
    calculationStatus: "ok" | "no_geometry" | "low_accuracy" | "stale_gps" | "arrived";
    distanceFromRouteMeters: number | null;
    confirmedAt: string | null;
    recoveredAt: string | null;
    dismissedAt: string | null;
    // See board-actions.ts's RouteDeviationInfo.stale for why this is
    // computed at read time rather than trusted from calculation_status.
    stale: boolean;
  } | null;
  // Phase 2E (0063_operational_exceptions.sql) -- null when the migration
  // isn't applied yet (spec section 41: existing systems, this one
  // included, must keep working regardless).
  exceptions: { activeCount: number; highestSeverity: string | null; highestTitle: string | null } | null;
};

const STALE_LOCATION_MINUTES = 5; // matches board-actions.ts's own constant

// ---------------------------------------------------------------------------
// getRouteIntelligenceForDispatch -- feeds the Live Tracking page's
// selected-truck panel (spec section 19) when a dispatcher clicks a
// marker. Org-scoped exactly like every other staff-facing dispatch read
// in this file/board-actions.ts; the client only ever supplies a
// dispatchId, never trusted to also supply organization_id.
// ---------------------------------------------------------------------------
export async function getRouteIntelligenceForDispatch(dispatchId: string): Promise<LiveTrackingRouteInfo | { error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { error: "No organization on this account." };
  }

  const { data: dispatch } = await supabase
    .from("dispatches")
    .select("status, loads(load_number), trucks(unit_number), drivers(first_name, last_name)")
    .eq("id", dispatchId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (!dispatch) return { error: "Dispatch not found." };
  const d = dispatch as unknown as { status: string; loads: { load_number: string } | null; trucks: { unit_number: string } | null; drivers: { first_name: string; last_name: string } | null };

  const { data: routeRow } = await supabase
    .from("dispatch_route_intelligence")
    .select(
      "target_stop_id, route_distance_meters, route_geometry, estimated_arrival_at, appointment_at, appointment_window_end, schedule_variance_minutes, risk_status, calculation_status, calculated_at"
    )
    .eq("dispatch_id", dispatchId)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  let targetStopLabel: string | null = null;
  let targetStopTimezone = "UTC";
  if (routeRow?.target_stop_id) {
    const [{ data: stopRow }, { data: orgRow }] = await Promise.all([
      supabase.from("load_stops").select("facility_name, city, state, timezone").eq("id", routeRow.target_stop_id).maybeSingle(),
      supabase.from("organizations").select("timezone").eq("id", organizationId).maybeSingle(),
    ]);
    targetStopLabel = stopRow ? stopRow.facility_name || [stopRow.city, stopRow.state].filter(Boolean).join(", ") || null : null;
    targetStopTimezone = resolveStopTimezone(stopRow?.timezone ?? null, orgRow?.timezone ?? null).timezone;
  }

  // Phase 2D -- same target stop, separate query (not bundled) so a
  // not-yet-applied migration 0062 can never take the rest of the panel
  // down with it.
  let deviation: LiveTrackingRouteInfo["deviation"] = null;
  if (routeRow?.target_stop_id) {
    const { data: devRow } = await supabase
      .from("dispatch_route_deviation_state")
      .select("state, calculation_status, distance_from_route_m, confirmed_at, recovered_at, dismissed_at, last_location_at")
      .eq("dispatch_id", dispatchId)
      .eq("target_stop_id", routeRow.target_stop_id)
      .maybeSingle();
    if (devRow) {
      const devAgeMinutes = devRow.last_location_at ? (Date.now() - new Date(devRow.last_location_at).getTime()) / 60_000 : null;
      deviation = {
        state: devRow.state,
        calculationStatus: devRow.calculation_status,
        distanceFromRouteMeters: devRow.distance_from_route_m,
        confirmedAt: devRow.confirmed_at,
        recoveredAt: devRow.recovered_at,
        stale: devAgeMinutes != null && devAgeMinutes > STALE_LOCATION_MINUTES,
        dismissedAt: devRow.dismissed_at,
      };
    }
  }

  // Phase 2E -- same separate-query/graceful-degrade pattern as deviation
  // above (0063 landing independently of everything else must never take
  // the panel down). Highest severity active exception summarized only --
  // full detail lives in the Exception Center drawer via "View Exceptions".
  let exceptions: LiveTrackingRouteInfo["exceptions"] = null;
  {
    const { data: excRows, error: excErr } = await supabase
      .from("operational_exceptions")
      .select("severity, title")
      .eq("dispatch_id", dispatchId)
      .neq("status", "resolved");
    if (!excErr) {
      const rank: Record<string, number> = { critical: 4, high: 3, medium: 2, low: 1 };
      const highest = (excRows ?? []).reduce((best: { severity: string; title: string } | null, r: { severity: string; title: string }) => (!best || rank[r.severity] > rank[best.severity] ? r : best), null);
      exceptions = { activeCount: excRows?.length ?? 0, highestSeverity: highest?.severity ?? null, highestTitle: highest?.title ?? null };
    }
  }

  return {
    loadNumber: d.loads?.load_number ?? "Load",
    driverName: d.drivers ? `${d.drivers.first_name} ${d.drivers.last_name}` : "--",
    truckUnit: d.trucks?.unit_number ?? "--",
    status: d.status,
    targetStopLabel,
    targetStopTimezone,
    routeDistanceMeters: routeRow?.route_distance_meters ?? null,
    routeGeometry: (routeRow?.route_geometry as [number, number][] | null) ?? null,
    estimatedArrivalAt: routeRow?.estimated_arrival_at ?? null,
    appointmentAt: routeRow?.appointment_at ?? null,
    appointmentWindowEnd: routeRow?.appointment_window_end ?? null,
    scheduleVarianceMinutes: routeRow?.schedule_variance_minutes ?? null,
    riskStatus: (routeRow?.risk_status as LiveTrackingRouteInfo["riskStatus"]) ?? "unknown",
    calculationStatus: routeRow?.calculation_status ?? "no_target_stop",
    calculatedAt: routeRow?.calculated_at ?? null,
    deviation,
    exceptions,
  };
}

export async function refreshDispatchEta(dispatchId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  const billingAccess = await checkOperationalAccess(); // D.2.11 SaaS paywall.
  if (!billingAccess.ok) return { ok: false, error: "Your organization's subscription does not permit this action." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, error: "No organization on this account." };
  }

  const { data: dispatch } = await supabase.from("dispatches").select("id").eq("id", dispatchId).eq("organization_id", organizationId).maybeSingle();
  if (!dispatch) return { ok: false, error: "Dispatch not found." };

  const result = await forceRefreshRouteIntelligence(dispatchId, organizationId);
  if (result.ok) {
    revalidatePath("/dispatch/board");
    revalidatePath(`/dispatch/${dispatchId}`);
    revalidatePath("/tracking");
  }
  return result;
}
