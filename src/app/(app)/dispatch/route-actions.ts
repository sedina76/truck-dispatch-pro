"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
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
};

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
  };
}

export async function refreshDispatchEta(dispatchId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

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
