"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { syncExceptionsForOrganization, operationalExceptionsTableExists } from "@/lib/exceptions/sync";
import type { ExceptionListRow, ExceptionSeverity, ExceptionStatus, ExceptionType } from "@/lib/exceptions/types";

const PAGE_SIZE = 25;

// Phase 2P.7 -- operational work-queue priority, applied within a single
// fetched page (see the query-building comment on why this can't be a
// single PostgREST .order() clause). Escalated exceptions surface first
// regardless of severity tier boundary within the page; unacknowledged
// (status='open') sorts before acknowledged; the DB's own severity-desc/
// age-asc ordering is preserved as the stable secondary sort within each
// tier (Array.prototype.sort is a stable sort per the ECMAScript spec).
// Never reorders across a page boundary -- a known, disclosed limitation
// for organizations with more open exceptions than fit on one page (see
// the 2P.7 report), not solved here since it would need either fetching
// every matching row up front or a computed sort column in the view
// (a migration), neither authorized this phase.
function applyOperationalPriority<T extends { escalated: boolean; status: ExceptionStatus }>(rows: T[]): T[] {
  const tier = (r: T): number => {
    if (r.status === "resolved") return 2; // shouldn't normally appear in this view, kept last defensively
    if (r.status === "acknowledged") return 1;
    return r.escalated ? -1 : 0; // escalated-and-open sorts ahead of plain open
  };
  return rows
    .map((row, index) => ({ row, index }))
    .sort((a, b) => tier(a.row) - tier(b.row) || a.index - b.index)
    .map(({ row }) => row);
}

export type ExceptionFilters = {
  severity?: ExceptionSeverity | "all";
  status?: ExceptionStatus | "all";
  type?: ExceptionType | "all";
  assignment?: "all" | "mine" | "unassigned";
  // Phase 2P.7 -- quick filter for exceptions that have escalated
  // (0107, escalated_at not null). Off by default.
  escalatedOnly?: boolean;
  q?: string;
  page?: number;
  sort?: "severity" | "age" | "load" | "driver" | "status";
};

export type ExceptionCenterResult =
  | { ok: true; unavailable?: false; rows: ExceptionListRow[]; total: number; page: number; pageSize: number; kpis: { active: number; critical: number; unacknowledged: number; unassigned: number; assignedToMe: number; resolvedToday: number } }
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

  // Phase 2P.5B -- explicit role check, independent of the page-level
  // requireRole() guard: a Server Action is its own callable endpoint and
  // must not rely solely on which page happened to render the button that
  // calls it. Database RLS (0063 + 0106) remains the authoritative
  // boundary either way; this is defense-in-depth, matching
  // requireExceptionOwnership()'s own role list exactly.
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!profile || !["owner", "admin", "dispatcher"].includes(profile.role)) {
    return { ok: false, unavailable: true, error: "Not authorized." };
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

  // Phase 2P.7 -- "Escalated only". escalated_at (0107) isn't exposed by
  // operational_exceptions_grouped (added after that view was created) --
  // resolved as a real DB-level filter (not a post-fetch trim, so
  // pagination stays correct) by first collecting the matching ids from
  // the raw table, then restricting the main query to them.
  if (filters.escalatedOnly) {
    const { data: escalatedRows } = await supabase.from("operational_exceptions").select("id").eq("organization_id", organizationId).not("escalated_at", "is", null).neq("status", "resolved");
    const escalatedIds = (escalatedRows ?? []).map((r) => r.id);
    const idCol = wantsResolvedOnly ? "id" : "primary_exception_id";
    query = query.in(idCol, escalatedIds.length > 0 ? escalatedIds : ["00000000-0000-0000-0000-000000000000"]);
  }

  // Default operational ordering (spec section 23/2P.7): severity desc,
  // then unacknowledged before acknowledged, then oldest-unresolved
  // first. PostgREST can't express "unacknowledged first" as a single
  // order clause over a nullable timestamp without a computed column, so
  // the DB only sorts by severity/age here -- the acknowledged-last and
  // escalated-first tie-breaks are applied client-side below (see
  // applyOperationalPriority()), correctly within the fetched page.
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
      escalated: false, // filled below
    };
  });

  const assignedIds = [...new Set(rows.map((r) => r.assignedTo).filter((v): v is string => v != null))];
  if (assignedIds.length > 0) {
    // Phase 2P.6A: profiles has full_name only -- no first_name/last_name
    // (that split shape only exists on drivers, a different table).
    // Cosmetic query: a failure here must not break the whole list, but
    // must not be silently pretended-successful either -- log it, then
    // every row's assignedToName correctly falls back to null (rendered
    // as "Unassigned"-looking, never "undefined undefined").
    const { data: staff, error: staffError } = await supabase.from("profiles").select("id, full_name").in("id", assignedIds);
    if (staffError) console.error("[exceptions] assignee name lookup failed:", staffError.code);
    const nameById = new Map((staff ?? []).map((s: { id: string; full_name: string }) => [s.id, s.full_name]));
    rows = rows.map((r) => ({ ...r, assignedToName: r.assignedTo ? (nameById.get(r.assignedTo) ?? null) : null }));
  }

  // Phase 2P.7 -- escalated_at supplementary lookup (see the query-building
  // comment above for why the grouped view can't expose it directly).
  if (rows.length > 0) {
    const { data: escalatedRows, error: escalatedError } = await supabase.from("operational_exceptions").select("id, escalated_at").in("id", rows.map((r) => r.id));
    if (escalatedError) console.error("[exceptions] escalated_at lookup failed:", escalatedError.code);
    const escalatedById = new Set((escalatedRows ?? []).filter((r) => r.escalated_at !== null).map((r) => r.id));
    rows = rows.map((r) => ({ ...r, escalated: escalatedById.has(r.id) }));
  }

  if (filters.q && filters.q.trim()) {
    const q = filters.q.trim().toLowerCase();
    rows = rows.filter((r) => r.title?.toLowerCase().includes(q) || r.loadNumber?.toLowerCase().includes(q) || r.truckUnit?.toLowerCase().includes(q) || r.driverName?.toLowerCase().includes(q));
  }

  // Phase 2P.7 -- operational priority within the fetched page: escalated
  // first, then unacknowledged before acknowledged, preserving the DB's
  // own severity/age ordering as the underlying stable sort (Array.sort
  // is stable per spec) -- only applied for the default severity sort,
  // never for an explicit age/status sort the dispatcher chose themselves.
  if (!filters.sort || filters.sort === "severity") {
    rows = applyOperationalPriority(rows);
  }

  // KPI counts -- separate, cheap head-count queries against the SAME
  // grouped view (spec section 19: counts must match what's actually
  // displayed, so a compound incident counts once, not twice).
  const startOfToday = new Date();
  startOfToday.setHours(0, 0, 0, 0);
  const [{ count: active }, { count: critical }, { count: unacknowledged }, { count: unassigned }, { count: assignedToMe }, { count: resolvedToday }] = await Promise.all([
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId).eq("max_severity", "critical"),
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId).eq("primary_status", "open"),
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId).is("assigned_to", null),
    supabase.from("operational_exceptions_grouped").select("group_key", { count: "exact", head: true }).eq("organization_id", organizationId).eq("assigned_to", user.id),
    supabase.from("operational_exceptions").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "resolved").gte("resolved_at", startOfToday.toISOString()),
  ]);

  return {
    ok: true,
    rows,
    total: count ?? 0,
    page,
    pageSize: PAGE_SIZE,
    kpis: { active: active ?? 0, critical: critical ?? 0, unacknowledged: unacknowledged ?? 0, unassigned: unassigned ?? 0, assignedToMe: assignedToMe ?? 0, resolvedToday: resolvedToday ?? 0 },
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

  // Phase 2P.6A: profiles has full_name only -- no first_name/last_name.
  // This is the shared authorization gate for every mutation below, so an
  // unexpected query failure must be distinguished from an ordinary role
  // denial: silently falling through "no profile -> not authorized" (the
  // pre-2P.6A bug) makes a genuine DB/query error indistinguishable from a
  // legitimate deny, with zero observability. Fail closed either way --
  // never grant access on an error -- but log the failure so it can be
  // diagnosed, and never expose the code/details to the caller.
  const { data: profile, error: profileError } = await supabase.from("profiles").select("id, full_name, role").eq("id", user.id).maybeSingle();
  if (profileError) {
    console.error("[exceptions] ownership role lookup failed:", profileError.code);
    return { ok: false as const, error: "Unable to verify authorization." };
  }
  if (!profile || !["owner", "admin", "dispatcher"].includes(profile.role)) return { ok: false as const, error: "Not authorized." };

  const { data: row } = await supabase
    .from("operational_exceptions")
    .select("id, dispatch_id, source_type, status, exception_type, title, summary, severity, metadata, assigned_to")
    .eq("id", exceptionId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (!row) return { ok: false as const, error: "Exception not found." };

  return { ok: true as const, organizationId, profile, row, serviceSupabase: createServiceRoleClient() };
}

// Phase 2P.6B -- shared with logActivity() below: which real entity a
// notification/activity event about this exception should target.
// Dispatch-scoped types (off_route/late/at_risk/detention/gps_stale/
// pod_missing) carry dispatch_id directly; the 2P.4 carrier-sourced types
// carry carrier_id in their own metadata snapshot instead. Never
// fabricates an id -- returns null if neither applies.
function resolveNotificationEntity(row: { dispatch_id: string | null; source_type: string; metadata: Record<string, unknown> | null }): { entityType: "dispatch" | "carrier"; entityId: string } | null {
  if (row.dispatch_id) return { entityType: "dispatch", entityId: row.dispatch_id };
  const carrierId = row.metadata?.carrier_id;
  if ((row.source_type === "compliance_item" || row.source_type === "insurance_policy") && typeof carrierId === "string") {
    return { entityType: "carrier", entityId: carrierId };
  }
  return null;
}

// Phase 2P.6B -- assignment/reassignment notification. Uses the 0107
// exception_id + notification_event architecture: the partial unique
// index on (exception_id, profile_id, notification_event) is the
// database-level idempotency guarantee, not a client-side check-then-
// insert. supabase-js's upsert() cannot target a PARTIAL unique index (it
// generates a bare `ON CONFLICT (columns)` with no WHERE clause, which
// Postgres will not match against a partial index) -- so this uses a
// plain INSERT and treats a 23505 unique-violation as the expected,
// harmless "already notified" outcome, exactly equivalent in effect to
// the migration's own `ON CONFLICT ... DO NOTHING`. The uniqueness itself
// is still fully DB-enforced either way; this only changes how the
// resulting rejection is handled in application code.
//
// KNOWN, DISCLOSED LIMITATION (2P.6B architecture audit): this key can
// safely represent one full reassignment cycle -- including the
// illustrative A -> B -> A sequence (A's first notification is tagged
// 'assigned', its second is tagged 'reassigned', since a prior assignee
// existed by then -- different keys, no collision). It does NOT scale to
// EXTENDED ping-ponging (e.g. A -> B -> A -> B): the second notification
// to a given recipient always reuses the SAME 'reassigned' tag for that
// exception, so a THIRD notification to that same recipient for the same
// exception would collide with the second and be silently suppressed.
// This is a narrow, disclosed constraint of the current schema, not
// fixed here -- see the Phase 2P.6B report. A monotonic per-assignment
// sequence/episode column would be required to remove it entirely, and
// is not built without explicit authorization.
async function notifyAssignee(
  supabase: ReturnType<typeof createServiceRoleClient>,
  organizationId: string,
  row: { dispatch_id: string | null; source_type: string; metadata: Record<string, unknown> | null; title: string; summary: string | null; severity: string },
  exceptionId: string,
  assigneeProfileId: string,
  notificationEvent: "assigned" | "reassigned"
) {
  const entity = resolveNotificationEntity(row);
  const title = notificationEvent === "assigned" ? `Exception assigned to you: ${row.title}` : `Exception reassigned to you: ${row.title}`;
  const { error } = await supabase.from("notifications").insert({
    organization_id: organizationId,
    profile_id: assigneeProfileId,
    type: "system",
    title,
    body: row.summary ?? row.title,
    entity_type: entity?.entityType ?? null,
    entity_id: entity?.entityId ?? null,
    exception_id: exceptionId,
    notification_event: notificationEvent,
  });
  // 23505 = the recipient already has an effective notification for this
  // (exception, event) pair -- harmless, expected, not logged as an error.
  if (error && error.code !== "23505") console.error("[exceptions] assignment notification insert failed:", error.code);
}

// Phase 2P.5: entity-aware activity logging. Every exception has SOME
// affected entity worth logging against -- dispatch-scoped types
// (off_route/late/at_risk/detention/gps_stale/pod_missing) already carry
// dispatch_id; the 2P.4 carrier-sourced types (source_type='compliance_item'
// or 'insurance_policy', written by sync_time_based_exceptions()) never
// have a dispatch_id but DO carry carrier_id in their own metadata
// snapshot (0103's own insert -- informational-only, safe to read for
// this purpose since we're only choosing a log target, not trusting it as
// live fact). Only truly falls through to a no-op if neither applies,
// which should not happen for any exception type this function currently
// knows about -- never fabricates an entity_id.
async function logActivity(
  supabase: ReturnType<typeof createServiceRoleClient>,
  organizationId: string,
  row: { dispatch_id: string | null; source_type: string; metadata: Record<string, unknown> | null },
  action: string,
  changes: Record<string, unknown>
) {
  const entity = resolveNotificationEntity(row);
  if (!entity) return;
  await supabase.rpc("log_activity", { p_entity_type: entity.entityType, p_entity_id: entity.entityId, p_action: action, p_changes: changes, p_organization_id: organizationId });
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

  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row, "exception_acknowledged", { exception_id: exceptionId, by: auth.profile.full_name });
  revalidatePath("/dispatch/exceptions");
  return { ok: true };
}

export async function assignException(exceptionId: string, assigneeId: string): Promise<ActionResult> {
  const auth = await requireExceptionOwnership(exceptionId);
  if (!auth.ok) return auth;

  // Phase 2P.6B section B(3) -- reassigning to the SAME current assignee
  // is not an effective transition: no mutation, no activity, no
  // notification. Idempotent, same convention as acknowledge/resolve.
  if (auth.row.assigned_to === assigneeId) return { ok: true };
  const previousAssignee = auth.row.assigned_to;

  // Cross-organization assignment must be impossible (spec section 13/37)
  // -- verify the assignee is genuine staff in THIS org, never trust the
  // client-supplied id alone. Phase 2P.6A: profiles has full_name only;
  // an unexpected query error here must not be reported as the misleading
  // "not a member of your organization" (a real denial reason), so it's
  // checked and logged explicitly, same as requireExceptionOwnership().
  const { data: assignee, error: assigneeError } = await auth.serviceSupabase.from("profiles").select("id, full_name, organization_id").eq("id", assigneeId).eq("organization_id", auth.organizationId).maybeSingle();
  if (assigneeError) {
    console.error("[exceptions] assignee lookup failed:", assigneeError.code);
    return { ok: false, error: "Unable to verify that assignee." };
  }
  if (!assignee) return { ok: false, error: "That person is not a member of your organization." };

  const { error } = await auth.serviceSupabase.from("operational_exceptions").update({ assigned_to: assigneeId, assigned_at: new Date().toISOString(), assigned_by: auth.profile.id }).eq("id", exceptionId);
  if (error) return { ok: false, error: "Could not assign this exception." };

  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row, "exception_assigned", {
    exception_id: exceptionId,
    to: assignee.full_name,
    by: auth.profile.full_name,
  });

  // Notify the NEW assignee only -- never the previous assignee, never
  // unrelated Owner/Admin/Dispatcher. 'assigned' if this exception had no
  // prior assignee, 'reassigned' if it did (see notifyAssignee()'s own
  // comment for the exact idempotency-key tradeoff this distinction makes).
  await notifyAssignee(auth.serviceSupabase, auth.organizationId, auth.row, exceptionId, assigneeId, previousAssignee ? "reassigned" : "assigned");

  revalidatePath("/dispatch/exceptions");
  return { ok: true };
}

// Phase 2P.5B -- the operational workflow needs a way back to Unassigned,
// not just reassignment to a different person. Idempotent (unassigning an
// already-unassigned exception is a harmless no-op, same convention as
// acknowledgeException/resolveException above).
export async function unassignException(exceptionId: string): Promise<ActionResult> {
  const auth = await requireExceptionOwnership(exceptionId);
  if (!auth.ok) return auth;

  const { data: current } = await auth.serviceSupabase.from("operational_exceptions").select("assigned_to").eq("id", exceptionId).maybeSingle();
  if (!current?.assigned_to) return { ok: true }; // idempotent -- already unassigned

  const { error } = await auth.serviceSupabase.from("operational_exceptions").update({ assigned_to: null, assigned_at: null, assigned_by: null }).eq("id", exceptionId);
  if (error) return { ok: false, error: "Could not unassign this exception." };

  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row, "exception_unassigned", { exception_id: exceptionId, by: auth.profile.full_name });
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
  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row, "exception_resolved", {
    exception_id: exceptionId,
    resolution_code: resolutionCode,
    manual: true,
    by: auth.profile.full_name,
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

  await logActivity(auth.serviceSupabase, auth.organizationId, auth.row, "exception_note_added", { exception_id: exceptionId, by: auth.profile.full_name });
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

  // Phase 2P.5B -- same defense-in-depth role check as getExceptionCenterData().
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!profile || !["owner", "admin", "dispatcher"].includes(profile.role)) {
    return { ok: false as const, error: "Not authorized." };
  }

  const { data: row } = await supabase
    .from("operational_exceptions")
    .select(
      `*, dispatches(id, status, loads(id, load_number, load_stops(id, stop_type, stop_sequence, facility_name, city, state, scheduled_at, scheduled_window_end, timezone, arrived_at, departed_at)), trucks(unit_number), drivers(id, first_name, last_name))`
    )
    .eq("id", exceptionId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (!row) return { ok: false as const, error: "Exception not found." };

  // Phase 2P.5: the 2P.4 carrier-sourced types (source_type='compliance_item'
  // or 'insurance_policy') have no dispatch_id but DO have a carrier_id in
  // their own metadata snapshot -- used only to pick the activity-log
  // entity to read, same as logActivity()'s own choice when writing it.
  const metadataCarrierId = row.metadata && typeof row.metadata === "object" ? (row.metadata as Record<string, unknown>).carrier_id : undefined;
  const activityEntityId = row.dispatch_id ?? (typeof metadataCarrierId === "string" ? metadataCarrierId : null);

  // Phase 2P.6A: profiles has full_name only -- no first_name/last_name.
  // Both queries below are cosmetic (notes/staff-list display, not
  // authorization) -- a failure must not break the whole drawer, but must
  // be logged rather than silently pretended-successful.
  const [{ data: notes, error: notesError }, { data: activity }, { data: staff, error: staffError }, { data: siblingRows }] = await Promise.all([
    supabase.from("operational_exception_notes").select("id, body, created_at, author_id, profiles(full_name)").eq("exception_id", exceptionId).order("created_at", { ascending: false }),
    activityEntityId
      ? supabase.from("activity_logs").select("id, action, actor_id, changes, created_at").eq("entity_id", activityEntityId).order("created_at", { ascending: false }).limit(30)
      : Promise.resolve({ data: [] }),
    supabase.from("profiles").select("id, full_name, role").eq("organization_id", organizationId).in("role", ["owner", "admin", "dispatcher"]).eq("is_active", true),
    // Other active exceptions on the SAME dispatch (spec section 8: "the
    // detail drawer must still show all contributing conditions" -- the
    // main table only shows the leading/highest-severity one).
    row.dispatch_id
      ? supabase.from("operational_exceptions").select("id, exception_type, severity, status, title").eq("dispatch_id", row.dispatch_id).neq("status", "resolved").neq("id", exceptionId)
      : Promise.resolve({ data: [] }),
  ]);
  if (notesError) console.error("[exceptions] note-author lookup failed:", notesError.code);
  if (staffError) console.error("[exceptions] staff list lookup failed:", staffError.code);

  // Phase 2P.5 -- carrier-sourced exception detail. Always re-fetched live
  // from the real source table (insurance_policies / compliance_items),
  // never trusted from the exception row's own denormalized metadata
  // snapshot (same discipline as the route-deviation/route-intelligence
  // re-fetch below) -- metadata is only ever used here to know WHICH
  // carrier/policy/item to look up, never as the displayed fact itself.
  let carrierContext: { id: string; legalName: string } | null = null;
  let liveInsurancePolicy: { policy_type: string; expiry_date: string | null; effective_date: string | null } | null = null;
  let liveComplianceItem: { item_type: string; expiry_date: string | null; status: string } | null = null;
  if (typeof metadataCarrierId === "string") {
    const { data: carrierRow } = await supabase.from("carriers").select("id, legal_name").eq("id", metadataCarrierId).eq("organization_id", organizationId).maybeSingle();
    if (carrierRow) carrierContext = { id: carrierRow.id, legalName: carrierRow.legal_name };
  }
  if (row.source_type === "insurance_policy" && carrierContext) {
    const { data: policyRow } = await supabase.from("insurance_policies").select("policy_type, expiry_date, effective_date").eq("id", row.source_id).eq("organization_id", organizationId).maybeSingle();
    liveInsurancePolicy = policyRow ?? null;
  } else if (row.source_type === "compliance_item") {
    const { data: itemRow } = await supabase.from("compliance_items").select("item_type, expiry_date, status").eq("id", row.source_id).eq("organization_id", organizationId).maybeSingle();
    liveComplianceItem = itemRow ?? null;
  }

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

  return {
    ok: true as const,
    row,
    notes: notes ?? [],
    activity: activity ?? [],
    staff: staff ?? [],
    liveRouteDeviation,
    liveRouteIntelligence,
    currentUserId: user.id,
    siblingExceptions: siblingRows ?? [],
    carrierContext,
    liveInsurancePolicy,
    liveComplianceItem,
  };
}
