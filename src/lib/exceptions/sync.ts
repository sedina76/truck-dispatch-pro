// =============================================================================
// Phase 2E exception sync orchestrator -- the ONE place DETECTION facts
// (read from existing Phase 2A-2D/compliance source tables) become
// NORMALIZED operational_exceptions episodes. See the Phase 2E pre-migration
// report(s) for the full architecture rationale. This file must never
// re-derive detection math (geofence/GPS/route/detention formulas) -- it
// only reads the trusted source tables' already-computed results.
//
//   DETECTION (existing systems) -> NORMALIZATION (this file) -> EXCEPTION
//   -> ACKNOWLEDGE/ASSIGN/RESOLVE (actions.ts) -> AUDIT HISTORY (activity_logs)
//
// REVISED (architecture review round): this file now owns ONLY the
// EVENT-DRIVEN types -- off_route, late, at_risk, pod_missing. Each has a
// genuine "meaningful transition" write path elsewhere in the app that
// calls into this module right after it happens (see the call sites in
// evaluate-route-deviation.ts, evaluate-route.ts, board-actions.ts,
// loads/pod-actions.ts, and the driver-portal upload-pod route).
//
// detention, gps_stale, and compliance are NOT computed here anymore.
// They are fundamentally TIME-based (the condition becomes true because
// time passed, not because any event fired) -- no ping, upload, or status
// change can announce "5 minutes of silence have now elapsed." Those three
// are owned entirely by a scheduled SQL evaluator
// (public.sync_time_based_exceptions(), migration 0063), run via pg_cron
// every 5 minutes. See the migration file for that function and the
// revised pre-migration report for the full reasoning.
//
// Two entry points here:
//   syncExceptionsForDispatch()     -- one dispatch, cheap, called from an
//                                       event-driven write path right after
//                                       a MEANINGFUL transition (never on
//                                       every GPS ping).
//   syncExceptionsForOrganization() -- every eligible dispatch in an org,
//                                       called on Exception Center page
//                                       load as a SECONDARY safety net (not
//                                       the primary lifecycle engine for
//                                       any type anymore).
// =============================================================================
import "server-only";
import { classifyExceptionSeverity } from "./severity";
import { computePodStatus } from "@/lib/documents/pod-status";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import type { ExceptionSeverity, ExceptionType } from "./types";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ServiceRoleClient = any; // matches this codebase's established untyped-client convention (see latest-document.ts)

const TERMINAL_STATUSES = new Set(["delivered", "completed", "cancelled"]); // mirrors src/lib/routing/next-stop.ts's private constant
const DELIVERED_LIKE = new Set(["delivered", "completed"]); // mirrors dispatch/board/page.tsx
// Bound on how far back to proactively look for a "recently delivered,
// still no POD" dispatch during an org-wide sweep -- unbounded would mean
// scanning an org's entire multi-year history on every page load. A
// dispatch that ALREADY has an active pod_missing exception is always
// reconsidered regardless of age (see fetchDispatchUniverse) so this bound
// only affects how far back a brand-new episode can first be OPENED by
// the sweep -- the event-driven hook (board-actions.ts, on the delivered
// transition itself) is what actually catches it promptly in practice.
const POD_RECENCY_WINDOW_DAYS = 30;

type OpenCondition = {
  type: ExceptionType;
  title: string;
  summary: string | null;
  metadata: Record<string, unknown>;
  severityCtx: Parameters<typeof classifyExceptionSeverity>[0];
};

type DispatchRow = {
  id: string;
  organizationId: string;
  loadId: string;
  loadNumber: string;
  status: string;
};

type SourceGroup = { sourceType: string; sourceId: string; dispatchId: string | null; loadId: string | null; conditions: OpenCondition[] };

// ---------------------------------------------------------------------------
// Table-missing detection (spec section 41: graceful pre-migration
// behavior). A single, reused probe -- every public entry point calls this
// first and returns a controlled "unavailable" result instead of letting a
// Postgres "relation does not exist" error propagate as a 500.
// ---------------------------------------------------------------------------
export async function operationalExceptionsTableExists(supabase: ServiceRoleClient): Promise<boolean> {
  const { error } = await supabase.from("operational_exceptions").select("id").limit(1);
  // A raw Postgres client reports an undefined-table error as code 42P01
  // with a "relation ... does not exist" message, but PostgREST -- what
  // this codebase's Supabase client actually talks to -- wraps a
  // schema-cache miss in its OWN shape: code 'PGRST205', message "Could
  // not find the table '...' in the schema cache". Match what is ACTUALLY
  // returned (root-caused live during the first pre-migration smoke test
  // round), not just the raw-Postgres shape.
  if (error && (error.code === "42P01" || error.code === "PGRST205" || /relation .* does not exist/i.test(error.message ?? "") || /Could not find the table/i.test(error.message ?? ""))) return false;
  return true;
}

// ---------------------------------------------------------------------------
// Dispatch universe: which dispatches are even worth checking, and for
// which of the (now two) TS-owned condition families each one is eligible.
//
// A dispatch qualifies for the off_route/late/at_risk check if it's
// non-terminal (those conditions are meaningless once a dispatch is done).
// A dispatch qualifies for the pod_missing check if its status is
// delivered-like, EITHER recently (POD_RECENCY_WINDOW_DAYS, for freshly
// opening a new episode) OR at any age if it already has an active
// pod_missing episode (so an old one can still be resolved once a POD
// finally shows up, or manually resolved).
//
// Critically: a dispatch that no longer qualifies for EITHER family but
// still has an existing active dispatch-scoped exception (e.g. it was
// cancelled while off-route) is ALSO always included, with correctly
// computed (here, necessarily empty) conditions -- this is what makes
// auto-resolution converge instead of leaving orphaned open exceptions
// behind forever. Found and fixed during the architecture review: the
// original design silently dropped terminal dispatches from
// consideration entirely, which meant NEITHER pod_missing could ever be
// detected for a delivered dispatch (delivered IS terminal) NOR could
// off_route/late/at_risk ever auto-resolve once a dispatch went terminal.
// ---------------------------------------------------------------------------
async function fetchDispatchUniverse(supabase: ServiceRoleClient, organizationId: string, restrictToIds?: string[]): Promise<DispatchRow[]> {
  const recencyCutoff = new Date(Date.now() - POD_RECENCY_WINDOW_DAYS * 86_400_000).toISOString();

  let activeQuery = supabase.from("dispatches").select("id").eq("organization_id", organizationId).not("status", "in", `(${[...TERMINAL_STATUSES].join(",")})`);
  let deliveredQuery = supabase.from("dispatches").select("id").eq("organization_id", organizationId).in("status", [...DELIVERED_LIKE]).gte("dispatched_at", recencyCutoff);
  let existingExceptionQuery = supabase.from("operational_exceptions").select("dispatch_id").eq("organization_id", organizationId).eq("source_type", "dispatch").neq("status", "resolved").not("dispatch_id", "is", null);
  // pod_missing's own source is now "load", not "dispatch" -- also pull
  // those forward so an old, still-open pod_missing episode is always
  // reconsidered regardless of the dispatch's age/status.
  const existingLoadExceptionQuery = supabase.from("operational_exceptions").select("load_id").eq("organization_id", organizationId).eq("source_type", "load").neq("status", "resolved").not("load_id", "is", null);
  if (restrictToIds) {
    activeQuery = activeQuery.in("id", restrictToIds);
    deliveredQuery = deliveredQuery.in("id", restrictToIds);
    existingExceptionQuery = existingExceptionQuery.in("dispatch_id", restrictToIds);
  }

  const [{ data: activeRows }, { data: deliveredRows }, { data: existingRows }, { data: existingLoadRows }] = await Promise.all([activeQuery, deliveredQuery, existingExceptionQuery, existingLoadExceptionQuery]);
  const idSet = new Set<string>([...(activeRows ?? []).map((r: { id: string }) => r.id), ...(deliveredRows ?? []).map((r: { id: string }) => r.id), ...(existingRows ?? []).map((r: { dispatch_id: string }) => r.dispatch_id)]);

  // A load with an existing pod_missing episode needs its CURRENT dispatch
  // pulled in too, if it has one -- resolved via a small follow-up lookup
  // (bounded by however many loads that is, never unbounded).
  const orphanedLoadIds = (existingLoadRows ?? []).map((r: { load_id: string }) => r.load_id);
  if (orphanedLoadIds.length > 0) {
    const { data: dispatchesForLoads } = await supabase.from("dispatches").select("id").in("load_id", orphanedLoadIds);
    for (const row of dispatchesForLoads ?? []) idSet.add(row.id);
  }

  if (idSet.size === 0) return [];
  const { data, error } = await supabase.from("dispatches").select("id, organization_id, load_id, status, dispatched_at, loads:loads!dispatches_load_id_fkey(load_number)").in("id", [...idSet]);
  if (error) console.error("[exceptions sync] dispatch load lookup failed:", error);
  return ((data ?? []) as unknown as Array<{ id: string; organization_id: string; load_id: string; status: string; loads: { load_number: string } | null }>).map((d) => ({
    id: d.id,
    organizationId: d.organization_id,
    loadId: d.load_id,
    loadNumber: d.loads?.load_number ?? "Load",
    status: d.status,
  }));
}

// ---------------------------------------------------------------------------
// OFF ROUTE / LATE / AT RISK -- source of truth: dispatch_route_deviation_
// state (0062) / dispatch_route_intelligence (0060). Both tables keep a row
// per (dispatch, target_stop) FOREVER (Phase 2D's own design -- old target
// stops' rows are deliberately preserved as history, never deleted). Only
// the MOST RECENTLY UPDATED row per dispatch reflects the CURRENT target
// stop -- found and fixed during the architecture review: the original
// off_route query had no such ordering/dedup at all (unlike the
// route-intelligence query right next to it, which already did), so a
// long-resolved off_route episode from an ABANDONED target stop (e.g.
// Pickup 1, after the dispatch moved on to Pickup 2) could be read as
// "currently true" forever, since nothing ever revisits or clears that old
// row's state field once the target moves on.
// ---------------------------------------------------------------------------
async function computeOffRouteAndEtaConditions(supabase: ServiceRoleClient, dispatchIds: string[]): Promise<Map<string, { offRoute?: OpenCondition; late?: OpenCondition; atRisk?: OpenCondition }>> {
  const result = new Map<string, { offRoute?: OpenCondition; late?: OpenCondition; atRisk?: OpenCondition }>();
  if (dispatchIds.length === 0) return result;

  const { data: devRows, error: devErr } = await supabase
    .from("dispatch_route_deviation_state")
    .select("dispatch_id, state, calculation_status, distance_from_route_m, confirmed_at, dismissed_at, target_stop_id, updated_at")
    .in("dispatch_id", dispatchIds)
    .order("updated_at", { ascending: false });
  if (devErr) console.warn("[exceptions/sync] dispatch_route_deviation_state unavailable (Phase 2D migration 0062 not applied?):", devErr.message);

  const seenDeviation = new Set<string>();
  for (const row of devRows ?? []) {
    if (seenDeviation.has(row.dispatch_id)) continue; // most-recent row (current target stop) only
    seenDeviation.add(row.dispatch_id);
    if (row.state !== "off_route" || row.calculation_status !== "ok" || row.dismissed_at) continue;
    result.set(row.dispatch_id, {
      ...result.get(row.dispatch_id),
      offRoute: {
        type: "off_route",
        title: "Off Route",
        summary: row.distance_from_route_m != null ? `${(row.distance_from_route_m / 1609.344).toFixed(1)} mi from the expected route.` : "Vehicle is off the expected route.",
        metadata: { distance_from_route_m: row.distance_from_route_m, confirmed_at: row.confirmed_at, target_stop_id: row.target_stop_id },
        severityCtx: { exceptionType: "off_route" },
      },
    });
  }

  const { data: routeRows, error: routeErr } = await supabase
    .from("dispatch_route_intelligence")
    .select("dispatch_id, target_stop_id, risk_status, schedule_variance_minutes, estimated_arrival_at, calculation_status, updated_at")
    .in("dispatch_id", dispatchIds)
    .order("updated_at", { ascending: false });
  if (routeErr) console.warn("[exceptions/sync] dispatch_route_intelligence unavailable (Phase 2C migration 0060 not applied?):", routeErr.message);

  const seenRoute = new Set<string>();
  for (const row of routeRows ?? []) {
    if (seenRoute.has(row.dispatch_id)) continue; // most-recent row (current target stop) only
    seenRoute.add(row.dispatch_id);
    if (row.calculation_status !== "ok") continue;
    const existing = result.get(row.dispatch_id) ?? {};
    if (row.risk_status === "late") {
      const minutesLate = row.schedule_variance_minutes != null ? -row.schedule_variance_minutes : null;
      result.set(row.dispatch_id, {
        ...existing,
        late: {
          type: "late",
          title: "Late",
          summary: minutesLate != null ? `Projected ${minutesLate}m late.` : "Projected late.",
          metadata: { schedule_variance_minutes: row.schedule_variance_minutes, estimated_arrival_at: row.estimated_arrival_at, target_stop_id: row.target_stop_id },
          severityCtx: { exceptionType: "late" },
        },
      });
    } else if (row.risk_status === "at_risk") {
      result.set(row.dispatch_id, {
        ...existing,
        atRisk: {
          type: "at_risk",
          title: "At Risk",
          summary: "Projected to arrive close to the appointment window -- monitor.",
          metadata: { schedule_variance_minutes: row.schedule_variance_minutes, estimated_arrival_at: row.estimated_arrival_at, target_stop_id: row.target_stop_id },
          severityCtx: { exceptionType: "at_risk" },
        },
      });
    }
  }

  return result;
}

// ---------------------------------------------------------------------------
// POD MISSING -- source of truth: the existing, mature POD workflow
// (getLatestDocument(s)ByEntity / computePodStatus, src/lib/documents/).
// Source identity is the LOAD, not the dispatch (spec review item 3: a POD
// is fundamentally a load-level document -- getLatestDocument's own
// entity_type is "load" -- and this avoids any ambiguity if a load is ever
// re-dispatched to a different carrier/truck over its lifecycle).
//
// Semantics (spec review item 2, reasoned from the existing 4-state model):
//   OPEN    when computePodStatus() is 'missing' OR 'rejected'. A rejected
//           POD does NOT satisfy the requirement -- the load still has no
//           valid proof of delivery on file, which is the actual
//           operational fact this exception represents.
//   RESOLVED when computePodStatus() is 'uploaded' OR 'verified'. An
//           uploaded-but-not-yet-verified POD ends the "missing document"
//           problem (something IS now on file that could satisfy the
//           requirement) -- verification review is a separate, lower-
//           urgency workflow already owned by the Documents page, not
//           something this phase turns into its own exception type
//           (deliberately not adding a new "PENDING VERIFICATION"
//           exception type here -- see the revised report's reasoning).
// ---------------------------------------------------------------------------
async function computePodMissingConditions(supabase: ServiceRoleClient, dispatches: DispatchRow[]): Promise<Map<string, OpenCondition>> {
  const result = new Map<string, OpenCondition>();
  const eligible = dispatches.filter((d) => DELIVERED_LIKE.has(d.status));
  if (eligible.length === 0) return result;
  const loadIds = [...new Set(eligible.map((d) => d.loadId))];

  const podByLoad = await getLatestDocumentsByEntity(supabase, "load", "pod", loadIds);
  for (const d of eligible) {
    const status = computePodStatus(podByLoad.get(d.loadId) ?? null);
    if (status !== "missing" && status !== "rejected") continue;
    result.set(d.loadId, {
      type: "pod_missing",
      title: "POD Missing",
      summary: status === "rejected" ? "The most recent proof of delivery was rejected -- a valid POD is still needed." : "Load marked delivered but no proof of delivery is on file.",
      metadata: { pod_status: status },
      severityCtx: { exceptionType: "pod_missing" },
    });
  }
  return result;
}

// ---------------------------------------------------------------------------
// The upsert/reconcile core -- shared by both entry points. Given a set of
// CURRENTLY TRUE conditions per source, and the org's existing active
// episodes FOR THOSE SOURCE TYPES, opens new episodes, updates/escalates
// existing ones, and auto-resolves episodes whose condition cleared. This
// is the only place operational_exceptions is written from TypeScript
// (the scheduled SQL evaluator, migration 0063, writes detention/gps_stale/
// compliance rows independently -- see that migration).
// ---------------------------------------------------------------------------
async function reconcile(supabase: ServiceRoleClient, organizationId: string, conditionsBySource: Map<string, SourceGroup>, ownedSourceTypes: string[]) {
  let opened = 0,
    updated = 0,
    escalated = 0,
    resolved = 0;

  const sourceIds = [...conditionsBySource.values()].map((v) => v.sourceId);
  const { data: existingRows } = await supabase
    .from("operational_exceptions")
    .select("id, source_type, source_id, exception_type, status, severity, first_detected_at, title")
    .eq("organization_id", organizationId)
    .in("source_type", ownedSourceTypes)
    .in("source_id", sourceIds.length > 0 ? sourceIds : ["00000000-0000-0000-0000-000000000000"])
    .neq("status", "resolved");

  const existingByKey = new Map<string, (typeof existingRows)[number]>();
  for (const row of existingRows ?? []) existingByKey.set(`${row.source_type}:${row.source_id}:${row.exception_type}`, row);

  const now = new Date().toISOString();

  for (const { sourceType, sourceId, dispatchId, loadId, conditions } of conditionsBySource.values()) {
    const activeTypesThisSource = new Set(conditions.map((c) => c.type));

    for (const cond of conditions) {
      // Compound severity awareness (spec section 8/9): does off_route
      // have an active late sibling right now, or vice versa?
      const severityCtx = {
        ...cond.severityCtx,
        hasActiveOffRouteSibling: cond.type === "late" && activeTypesThisSource.has("off_route"),
        hasActiveLateSibling: cond.type === "off_route" && activeTypesThisSource.has("late"),
      };
      const severity = classifyExceptionSeverity(severityCtx);
      const key = `${sourceType}:${sourceId}:${cond.type}`;
      const existing = existingByKey.get(key);

      if (!existing) {
        const { data: inserted } = await supabase
          .from("operational_exceptions")
          .insert({
            organization_id: organizationId,
            source_type: sourceType,
            source_id: sourceId,
            dispatch_id: dispatchId,
            load_id: loadId,
            exception_type: cond.type,
            severity,
            status: "open",
            title: cond.title,
            summary: cond.summary,
            first_detected_at: now,
            last_detected_at: now,
            metadata: cond.metadata,
          })
          .select("id")
          .maybeSingle();
        opened++;
        if (inserted) {
          await logExceptionActivity(supabase, organizationId, dispatchId, inserted.id, "exception_opened", { exception_type: cond.type, severity });
          if (severity !== "low") await notifyOffice(supabase, organizationId, `${cond.title} -- ${severity.toUpperCase()}`, cond.summary ?? cond.title, dispatchId);
        }
        continue;
      }

      const severityIncreased = severityRank(severity) > severityRank(existing.severity as ExceptionSeverity);
      await supabase
        .from("operational_exceptions")
        .update({ last_detected_at: now, metadata: cond.metadata, summary: cond.summary, ...(severityIncreased ? { severity } : {}) })
        .eq("id", existing.id);
      updated++;
      if (severityIncreased) {
        escalated++;
        await logExceptionActivity(supabase, organizationId, dispatchId, existing.id, "exception_escalated", { from: existing.severity, to: severity });
        if (severity === "critical") await notifyOffice(supabase, organizationId, `${existing.title} escalated to CRITICAL`, cond.summary ?? existing.title, dispatchId);
      }
    }

    for (const [key, existing] of existingByKey) {
      if (!key.startsWith(`${sourceType}:${sourceId}:`)) continue;
      if (activeTypesThisSource.has(existing.exception_type as ExceptionType)) continue;
      await supabase.from("operational_exceptions").update({ status: "resolved", resolved_at: now, resolved_by: null, resolution_code: "auto_resolved" }).eq("id", existing.id).eq("status", existing.status);
      resolved++;
      await logExceptionActivity(supabase, organizationId, dispatchId, existing.id, "exception_resolved", { exception_type: existing.exception_type, auto: true });
    }
  }

  return { opened, updated, escalated, resolved };
}

function severityRank(s: ExceptionSeverity): number {
  return { low: 1, medium: 2, high: 3, critical: 4 }[s];
}

async function logExceptionActivity(supabase: ServiceRoleClient, organizationId: string, dispatchId: string | null, exceptionId: string, action: string, changes: Record<string, unknown>) {
  if (!dispatchId) return;
  const { error } = await supabase.rpc("log_activity", {
    p_entity_type: "dispatch",
    p_entity_id: dispatchId,
    p_action: action,
    p_changes: { exception_id: exceptionId, source: "system:exceptions", ...changes },
    p_organization_id: organizationId,
  });
  if (error) console.error("[exceptions/sync] log_activity failed:", error);
}

async function notifyOffice(supabase: ServiceRoleClient, organizationId: string, title: string, body: string, dispatchId: string | null) {
  const { data: recipients } = await supabase.from("profiles").select("id").eq("organization_id", organizationId).in("role", ["owner", "admin", "dispatcher"]).eq("is_active", true);
  if (!recipients || recipients.length === 0) return;
  const rows = recipients.map((r: { id: string }) => ({ organization_id: organizationId, profile_id: r.id, type: "system" as const, title, body, entity_type: "dispatch" as const, entity_id: dispatchId }));
  const { error } = await supabase.from("notifications").insert(rows);
  if (error) console.error("[exceptions/sync] notification insert failed:", error);
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

export async function syncExceptionsForDispatch(supabase: ServiceRoleClient, organizationId: string, dispatchId: string): Promise<void> {
  if (!(await operationalExceptionsTableExists(supabase))) return; // graceful no-op pre-migration
  const dispatches = await fetchDispatchUniverse(supabase, organizationId, [dispatchId]);
  if (dispatches.length === 0) return;
  await syncForDispatches(supabase, organizationId, dispatches);
}

export async function syncExceptionsForOrganization(supabase: ServiceRoleClient, organizationId: string): Promise<{ opened: number; updated: number; escalated: number; resolved: number } | { unavailable: true }> {
  if (!(await operationalExceptionsTableExists(supabase))) return { unavailable: true };
  const dispatches = await fetchDispatchUniverse(supabase, organizationId);
  return syncForDispatches(supabase, organizationId, dispatches);
}

async function syncForDispatches(supabase: ServiceRoleClient, organizationId: string, dispatches: DispatchRow[]) {
  const nonTerminalIds = dispatches.filter((d) => !TERMINAL_STATUSES.has(d.status)).map((d) => d.id);
  const [etaConditions, podConditions] = await Promise.all([computeOffRouteAndEtaConditions(supabase, nonTerminalIds), computePodMissingConditions(supabase, dispatches)]);

  const conditionsBySource = new Map<string, SourceGroup>();

  for (const d of dispatches) {
    // off_route/late/at_risk are only ever computed for non-terminal
    // dispatches (see nonTerminalIds above) -- for a terminal one, this is
    // correctly an empty group, which is exactly what lets any
    // still-open episode from before it went terminal auto-resolve.
    const eta = etaConditions.get(d.id);
    const conditions: OpenCondition[] = [];
    if (eta?.offRoute) conditions.push(eta.offRoute);
    if (eta?.late) conditions.push(eta.late);
    if (eta?.atRisk) conditions.push(eta.atRisk);
    conditionsBySource.set(`dispatch:${d.id}`, { sourceType: "dispatch", sourceId: d.id, dispatchId: d.id, loadId: d.loadId, conditions });
  }

  // pod_missing is LOAD-scoped (not dispatch-scoped) -- group separately.
  // A load with no current condition still needs an entry (empty
  // conditions) if it has an existing active episode, for auto-resolution;
  // dispatches were already fetched to cover exactly that case (see
  // fetchDispatchUniverse's existingLoadExceptionQuery).
  const loadToDispatch = new Map<string, string>();
  for (const d of dispatches) if (!loadToDispatch.has(d.loadId)) loadToDispatch.set(d.loadId, d.id);
  for (const [loadId, dispatchId] of loadToDispatch) {
    const cond = podConditions.get(loadId);
    conditionsBySource.set(`load:${loadId}`, { sourceType: "load", sourceId: loadId, dispatchId, loadId, conditions: cond ? [cond] : [] });
  }

  return reconcile(supabase, organizationId, conditionsBySource, ["dispatch", "load"]);
}
