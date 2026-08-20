"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { syncExceptionsForOrganization, operationalExceptionsTableExists } from "@/lib/exceptions/sync";
import type { ExceptionListRow, ExceptionSeverity, ExceptionStatus, ExceptionType } from "@/lib/exceptions/types";

const PAGE_SIZE = 25;

export type ExceptionFilters = {
  severity?: ExceptionSeverity | "all";
  status?: ExceptionStatus | "all";
  type?: ExceptionType | "all";
  assignment?: "all" | "mine" | "unassigned";
  q?: string;
  page?: number;
  sort?: "severity" | "age" | "load" | "driver" | "status";
};

export type ExceptionCenterResult =
  | { ok: true; unavailable?: false; rows: ExceptionListRow[]; total: number; page: number; pageSize: number; kpis: { active: number; critical: number; unacknowledged: number; assignedToMe: number; resolvedToday: number } }
  | { ok: false; unavailable: true; error: string };

// ---------------------------------------------------------------------------
// getExceptionCenterData -- the Exception Center page's single data-loading
// action. Runs a fresh org-wide sync (spec's "pull" trigger for detention/
// GPS-stale/POD-missing/compliance, which have no push-style transition
// event of their own -- see the Phase 2E pre-migration report) BEFORE
// reading, so the page a dispatcher is actually looking at is current.
// Degrades to { unavailable: true } if migration 0063 hasn't been applied
// yet -- never throws/500s (spec section 41).
// ---------------------------------------------------------------------------
export async function getExceptionCenterData(filters: ExceptionFilters): Promise<ExceptionCenterResult> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, unavailable: true, error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, unavailable: true, error: "No organization on this account." };
  }

  const serviceSupabase = createServiceRoleClient();
  if (!(await operationalExceptionsTableExists(serviceSupabase))) {
    return { ok: false, unavailable: true, error: "Exception Center database migration has not been applied." };
  }

  await syncExceptionsForOrganization(serviceSupabase, organizationId);

  const page = Math.max(1, filters.page ?? 1);
  const from = (page - 1) * PAGE_SIZE;
  const to = from + PAGE_SIZE - 1;

  // Queries operational_exceptions_grouped (migration 0063), NOT the raw
  // table -- one row per INCIDENT, not per episode, computed deterministically
  // at the SQL layer so a compound "OFF ROUTE + LATE" incident can never be
  // split or duplicated across a pagination boundary (spec review item 4).
  // resolved incidents are naturally absent from this view (it's built
  // from `where status <> 'resolved'`), so an explicit status='resolved'
  // filter falls back to the raw table -- history browsing doesn't need
  // compound grouping (a resolved episode no longer has any active
  // siblings to group with by definition).
  const wantsResolvedOnly = filters.status === "resolved";
  const table = wantsResolvedOnly ? "operational_exceptions" : "operational_exceptions_grouped";
  const severityCol = wantsResolvedOnly ? "severity" : "max_severity";
  const statusCol = wantsResolvedOnly ? "status" : "primary_status";

  // select("*", ...) rather than an interpolated column list -- a
  // template-string select against a dynamically-chosen table name (raw vs
  // grouped view) makes Supabase's generated return type combinatorially
  // explode (TS2590); the manual field-by-field mapping below already
  // reads whichever of the two shapes actually came back, so nothing is
  // lost by fetching every column.
  let query = supabase
    .from(table)
    .select("*, dispatches(loads(load_number), trucks(unit_number), drivers(first_name, last_name))", { count: "exact" })
    .eq("organization_id", organizationId);

  if (filters.severity && filters.severity !== "all") query = query.eq(severityCol, filters.severity);
  if (wantsResolvedOnly) query = query.eq("status", "resolved");
  else if (filters.status && filters.status !== "all") query = query.eq(statusCol, filters.status);
  if (filters.type && filters.type !== "all") {
    query = wantsResolvedOnly ? query.eq("exception_type", filters.type) : query.contains("exception_types", [filters.type]);
  }
  if (filters.assignment === "mine") query = query.eq("assigned_to", user.id);
  else if (filters.assignment === "unassigned") query = query.is("assigned_to", null);

  // Default operational ordering (spec section 23): severity desc, then
  // unacknowledged before acknowledged, then oldest-unresolved first.
  // PostgREST can't express "unacknowledged first" as a single order
  // clause over a nullable timestamp without a computed column, so that
  // tie-break is applied client-side below within an otherwise
  // severity-sorted, server-paginated page.
  switch (filters.sort) {
    case "age":
      query = query.order("first_detected_at", { ascending: true });
      break;
    case "status":
      query = query.order(statusCol, { ascending: true }).order(severityCol, { ascending: false });
      break;
    default:
      query = query.order(severityCol, { ascending: false }).order("first_detected_at", { ascending: true });
  }

  const { data, count, error } = await query.range(from, to);
  if (error) {
    console.error("[exceptions] list query failed:", error);
    return { ok: false, unavailable: true, error: "Could not load exceptions." };
  }

  let rows = ((data ?? []) as unknown as Array<{
    [key: string]: unknown;
    exception_types?: ExceptionType[];
    severity?: ExceptionSeverity;
    max_severity?: ExceptionSeverity;
    status?: ExceptionStatus;
    primary_status?: ExceptionStatus;
    exception_type?: ExceptionType;
    primary_exception_type?: ExceptionType;
    id?: string;
    primary_exception_id?: string;
    title: string;
    summary: string | null;
    dispatch_id: string | null;
    first_detected_at: string;
    last_detected_at: string;
    assigned_to: string | null;
    acknowledged_at: string | null;
    dispatches: { loads: { load_number: string } | null; trucks: { unit_number: string } | null; drivers: { first_name: string; last_name: string } | null } | null;
  }>).map((r) => {
    const primaryType = (r.primary_exception_type ?? r.exception_type) as ExceptionType;
    return {
      id: (r.primary_exception_id ?? r.id) as string,
      exceptionType: primaryType,
      exceptionTypes: r.exception_types ?? [primaryType],
      severity: (r.max_severity ?? r.severity) as ExceptionSeverity,
      status: (r.primary_status ?? r.status) as ExceptionStatus,
      title: r.title,
      summary: r.summary,
      dispatchId: r.dispatch_id,
      loadNumber: r.dispatches?.loads?.load_number ?? null,
      truckUnit: r.dispatches?.trucks?.unit_number ?? null,
      driverName: r.dispatches?.drivers ? `${r.dispatches.drivers.first_name} ${r.dispatches.drivers.last_name}` : null,
      firstDetectedAt: r.first_detected_at,
      lastDetectedAt: r.last_detected_at,
      assignedTo: r.assigned_to,
      assignedToName: null as string | null, // filled below
      acknowledgedAt: r.acknowledged_at,
    };
  });

  const assignedIds = [...new Set(rows.map((r) => r.assignedTo).filter((v): v is string => v != null))];
  if (assignedIds.length > 0) {
    const { data: staff } = await supabase.from("profiles").select("id, first_name, last_name").in("id", assignedIds);
    const nameById = new Map((staff ?? []).map((s: { id: string; first_name: string; last_name: string }) => [s.id, `${s.first_name} ${s.last_name}`]));
    rows = rows.map((r) => ({ ...r, assignedToName: r.assignedTo ? (nameById.get(r.assignedTo) ?? null) : null }));
  }

  if (filters.q && filters.q.trim()) {
    const q = filters.q.trim().toLowerCase();
    rows = rows.filter((r) => r.loadNumber?.toLowerCase().includes(q) || r.truckUnit?.toLowerCase().includes(q) || r.driverName?.toLowerCase().includes(q));
  }

  // KPI counts -- separate, cheap head-count queries against the SAME
  // grouped view (spec section 19: counts must match what's actually
  // displayed, so a compound incident counts once, not twice).
  const startOfToday = new Date();
  startOfToday.setHours(0, 0, 0, 0);
  const [{ count: active }, { count: critical }, { count: unacknowledged }, { count: assignedToMe }, { count: resolvedToday }] = await Promise.all([
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId).eq("max_severity", "critical"),
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId).eq("primary_status", "open"),
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId).eq("assigned_to", user.id),
    supabase.from("operational_exceptions").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "resolved").gte("resolved_at", startOfToday.toISOString()),
  ]);

  return {
    ok: true,
    rows,
    total: count ?? 0,
    page,
    pageSize: PAGE_SIZE,
    kpis: { active: active ?? 0, critical: critical ?? 0, unacknowledged: unacknowledged ?? 0, assignedToMe: assignedToMe ?? 0, resolvedToday: resolvedToday ?? 0 },
  };
}

// ---------------------------------------------------------------------------
// Ownership helper -- mirrors board-actions.ts's requireStopOwnership()
// exactly: verify the authenticated staff session, resolve organizationId
// from it (never the client), and confirm the exception row genuinely
// belongs to this org before any mutation.
// ---------------------------------------------------------------------------
async function requireExceptionOwnership(exceptionId: string) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false as const, error: "No organization on this account." };
  }

  const { data: profile } = await supabase.from("profiles").select("id, first_name, last_name, role").eq("id", user.id).maybeSingle();
  if (!profile || !["owner", "admin", "dispatcher"].includes(profile.role)) return { ok: false as const, error: "Not authorized." };

  const { data: row } = await supabase.from("operational_exceptions").select("id, dispatch_id, status, exception_type, title").eq("id", exceptionId).eq("organization_id", organizationId).maybeSingle();
  if (!row) return { ok: false as const, error: "Exception not found." };

  return { ok: true as const, organizationId, profile, row, serviceSupabase: createServiceRoleClient() };
}

async function logActivity(supabase: ReturnType<typeof createServiceRoleClient>, organizationId: string, dispatchId: string | null, action: string, changes: Record<string, unknown>) {
  if (!dispatchId) return;
  await supabase.rpc("log_activity", { p_entity_type: "dispatch", p_entity_id: dispatchId, p_action: action, p_changes: changes, p_organization_id: organizationId });
}

type ActionResult = { ok: true } | { ok: false; error: string };

// Acknowledge (spec section 12) -- idempotent: acknowledging an already-
// acknowledged (or resolved) exception is a harmless no-op, never
// duplicate history. Never touches GPS/routing/geofence source state.
export async function acknowledgeException(exceptionId: string): Promise<ActionResult> {
  const auth = await requireExceptionOwnership(exceptionId);
  if (!auth.ok) return auth;
  if (auth.row.status !== "open") {
    revalidatePath("/dispatch/exceptions");
    return { ok: true }; // idempotent -- already acknowledged/resolved
  }

  const { error } = await auth.serviceSupabase
    .from("operational_exceptions")
    .update({ status: "acknowledged", acknowledged_at: new Date().toISOString(), acknowledged_by: auth.profile.id })
    .eq("id", exceptionId)
    .eq("status", "open"); // guards a concurrent double-click race
  if (error) return { ok: false, error: "Could not acknowledge this exception." };

  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row.dispatch_id, "exception_acknowledged", { exception_id: exceptionId, by: `${auth.profile.first_name} ${auth.profile.last_name}` });
  revalidatePath("/dispatch/exceptions");
  return { ok: true };
}

export async function assignException(exceptionId: string, assigneeId: string): Promise<ActionResult> {
  const auth = await requireExceptionOwnership(exceptionId);
  if (!auth.ok) return auth;

  // Cross-organization assignment must be impossible (spec section 13/37)
  // -- verify the assignee is genuine staff in THIS org, never trust the
  // client-supplied id alone.
  const { data: assignee } = await auth.serviceSupabase.from("profiles").select("id, first_name, last_name, organization_id").eq("id", assigneeId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!assignee) return { ok: false, error: "That person is not a member of your organization." };

  const { error } = await auth.serviceSupabase.from("operational_exceptions").update({ assigned_to: assigneeId, assigned_at: new Date().toISOString(), assigned_by: auth.profile.id }).eq("id", exceptionId);
  if (error) return { ok: false, error: "Could not assign this exception." };

  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row.dispatch_id, "exception_assigned", {
    exception_id: exceptionId,
    to: `${assignee.first_name} ${assignee.last_name}`,
    by: `${auth.profile.first_name} ${auth.profile.last_name}`,
  });
  revalidatePath("/dispatch/exceptions");
  return { ok: true };
}

export async function resolveException(exceptionId: string, resolutionCode: string, resolutionNote: string | null): Promise<ActionResult> {
  const auth = await requireExceptionOwnership(exceptionId);
  if (!auth.ok) return auth;
  if (auth.row.status === "resolved") return { ok: true }; // idempotent

  const { error } = await auth.serviceSupabase
    .from("operational_exceptions")
    .update({ status: "resolved", resolved_at: new Date().toISOString(), resolved_by: auth.profile.id, resolution_code: resolutionCode, resolution_note: resolutionNote })
    .eq("id", exceptionId)
    .neq("status", "resolved");
  if (error) return { ok: false, error: "Could not resolve this exception." };

  // Deliberately does NOT touch dispatch_route_deviation_state,
  // dispatch_route_intelligence, load_stops, or any other source table
  // (spec section 14: manual resolution must never falsify source-of-truth
  // operational data). If the source condition is still active, the very
  // next sync will re-open a NEW episode -- which is correct: a
  // dispatcher can resolve "I've handled this" as an operational matter
  // while the underlying GPS/ETA fact remains whatever it actually is.
  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row.dispatch_id, "exception_resolved", {
    exception_id: exceptionId,
    resolution_code: resolutionCode,
    manual: true,
    by: `${auth.profile.first_name} ${auth.profile.last_name}`,
  });
  revalidatePath("/dispatch/exceptions");
  return { ok: true };
}

export async function addExceptionNote(exceptionId: string, body: string): Promise<ActionResult> {
  const auth = await requireExceptionOwnership(exceptionId);
  if (!auth.ok) return auth;
  const trimmed = body.trim();
  if (!trimmed) return { ok: false, error: "Note cannot be empty." };

  const { error } = await auth.serviceSupabase.from("operational_exception_notes").insert({ organization_id: auth.organizationId, exception_id: exceptionId, author_id: auth.profile.id, body: trimmed });
  if (error) return { ok: false, error: "Could not add note." };

  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row.dispatch_id, "exception_note_added", { exception_id: exceptionId, by: `${auth.profile.first_name} ${auth.profile.last_name}` });
  revalidatePath("/dispatch/exceptions");
  return { ok: true };
}

// ---------------------------------------------------------------------------
// getExceptionDetail -- powers the drawer (spec section 25). Fetches the
// episode row, its notes, its dispatch-scoped activity slice, and org
// staff (for the assignment dropdown) in a small number of scoped queries.
// Live source-specific detail (current route/ETA/detention/GPS) is
// re-fetched from the REAL source tables here too, never trusted from the
// exception row's own denormalized metadata (spec section 3/26-30).
// ---------------------------------------------------------------------------
export async function getExceptionDetail(exceptionId: string) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, error: "Not authenticated." };
  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false as const, error: "No organization on this account." };
  }

  const { data: row } = await supabase
    .from("operational_exceptions")
    .select(
      `*, dispatches(id, status, loads(load_number, load_stops(id, stop_type, stop_sequence, facility_name, city, state, scheduled_at, scheduled_window_end, timezone, arrived_at, departed_at)), trucks(unit_number), drivers(first_name, last_name))`
    )
    .eq("id", exceptionId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (!row) return { ok: false as const, error: "Exception not found." };

  const [{ data: notes }, { data: activity }, { data: staff }, { data: siblingRows }] = await Promise.all([
    supabase.from("operational_exception_notes").select("id, body, created_at, author_id, profiles(first_name, last_name)").eq("exception_id", exceptionId).order("created_at", { ascending: false }),
    row.dispatch_id
      ? supabase.from("activity_logs").select("id, action, actor_id, changes, created_at").eq("entity_id", row.dispatch_id).order("created_at", { ascending: false }).limit(30)
      : Promise.resolve({ data: [] }),
    supabase.from("profiles").select("id, first_name, last_name, role").eq("organization_id", organizationId).in("role", ["owner", "admin", "dispatcher"]).eq("is_active", true),
    // Other active exceptions on the SAME dispatch (spec section 8: "the
    // detail drawer must still show all contributing conditions" -- the
    // main table only shows the leading/highest-severity one).
    row.dispatch_id
      ? supabase.from("operational_exceptions").select("id, exception_type, severity, status, title").eq("dispatch_id", row.dispatch_id).neq("status", "resolved").neq("id", exceptionId)
      : Promise.resolve({ data: [] }),
  ]);

  // Live route-deviation/route-intelligence re-fetch, scoped to this
  // dispatch's current target stop -- same tables the Drawer/Live Map
  // already read, never a second copy of the math.
  let liveRouteDeviation = null;
  let liveRouteIntelligence = null;
  if (row.dispatch_id) {
    const { data: routeRow } = await supabase
      .from("dispatch_route_intelligence")
      .select("target_stop_id, risk_status, schedule_variance_minutes, estimated_arrival_at, route_distance_meters, calculation_status")
      .eq("dispatch_id", row.dispatch_id)
      .order("updated_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    liveRouteIntelligence = routeRow ?? null;
    if (routeRow?.target_stop_id) {
      const { data: devRow } = await supabase
        .from("dispatch_route_deviation_state")
        .select("state, calculation_status, distance_from_route_m, confirmed_at, recovered_at, last_location_at")
        .eq("dispatch_id", row.dispatch_id)
        .eq("target_stop_id", routeRow.target_stop_id)
        .maybeSingle();
      liveRouteDeviation = devRow ?? null;
    }
  }

  return { ok: true as const, row, notes: notes ?? [], activity: activity ?? [], staff: staff ?? [], liveRouteDeviation, liveRouteIntelligence, currentUserId: user.id, siblingExceptions: siblingRows ?? [] };
}
