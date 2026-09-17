-- =============================================================================
-- 0147_production_readiness_blocker_remediation.sql
-- Phase 3C.1 -- remediates the seven independently-proven release BLOCKERs
-- from the committed Phase 3C.0 audit package (at the time this migration
-- was authored: PRODUCTION_PREFLIGHT_0130_0146_READONLY.sql / DEPLOYMENT_
-- RUNBOOK_0130_0146.md, later extended and renamed to the 0130_0147 files
-- by Phase 3C.2 once this migration was proven), "Preserved corrective-
-- migration backlog". Every fix below was designed
-- from direct re-inspection of the LIVE installed source (0130-0146, a
-- disposable catalog, and `src/`), not from the audit narrative alone.
--
-- src/ contains ZERO references to carrier_invoices, update_carrier_invoice_
-- draft, scan_legacy_invoices_for_carrier_migration, or review_legacy_
-- invoice_carrier_migration -- the entire carrier-invoice system (0130-0146)
-- is not yet wired into the application. This means no legitimate running
-- caller depends on any privilege this migration revokes; the only
-- "callers" are the disposable SQL test suites this same repository ships,
-- which this migration's own TEST_0147 file updates/extends alongside it.
--
-- ===========================================================================
-- SECTION A -- BLOCKER 1: unreachable 0142 classifier conflict branch
-- ===========================================================================
-- classify_legacy_invoice_for_carrier_migration(uuid) (0142) tests
-- `loads.carrier_resolution = 'conflicting'`, a value the 0132 CHECK
-- (loads_carrier_resolution_values) never permits -- only 'resolved',
-- 'backfilled', 'unresolved' are legal. The branch is dead code in any
-- constraint-valid database.
--
-- Direct re-inspection of 0133 (the ONLY writer of carrier_resolution)
-- shows its own per-load CTE derives the SAME resolved-vs-conflicting-vs-
-- missing distinction from purely relational evidence: financial_
-- dispatch_id's own carrier (the "controller"), the set of DISTINCT
-- carrier_id values among non-cancelled dispatches, and the set among ALL
-- dispatches for that load. This is the single authoritative source; it
-- is recomputed live below rather than trusted from any stored label.
--
-- Phase 3C.1's first attempt at this correction instead read 0133's
-- ONE-TIME diagnostic label, permanently recorded in public.unresolved_
-- carrier_records.detail->>'rule' via public.record_unresolved_carrier_
-- record() (0130), and treated 'C4_conflicting_carriers'/'C1_controller_
-- conflict' as proof of a live conflict. Phase 3C.1.1's adversarial review
-- rejected that design: unresolved_carrier_records.detail is an
-- unconstrained jsonb column (no CHECK, no schema, no immutability
-- guarantee) whose 'rule' key is populated once, purely as human-readable
-- diagnostic text -- not a contracted, versioned classification value.
-- Worse, it can go STALE: a dispatch's status can change after 0133 ran
-- (cancel_dispatch(), 0129), which changes the live "non-cancelled
-- carriers" set this determination depends on, while the stored label
-- never updates. A load correctly flagged C4_conflicting_carriers at
-- backfill time could have its contending dispatch cancelled afterward,
-- leaving a single live non-cancelled candidate -- genuinely resolvable
-- evidence the old design would still report as "conflicting" forever.
--
-- Correction (Phase 3C.1.1): classify_legacy_invoice_for_carrier_
-- migration(uuid) keeps its EXACT signature and its EXACT 9 output
-- labels. For a load whose carrier_id is null, it now recomputes 0133's
-- own C1/C2/C3/C4 resolution CASE LIVE against public.dispatches --
-- never reading unresolved_carrier_records at all, which makes every one
-- of the following structurally irrelevant rather than merely handled:
-- a missing, closed, duplicate, cross-organization, or malformed-detail
-- exception row; a stale rule string; row-selection order. Precedence
-- (void -> paid/partial -> factoring -> recipient conflict -> missing
-- recipient -> missing load -> carrier evidence -> safely identifiable)
-- is unchanged.
--
-- DISCLOSED BEHAVIOR CHANGE (Section D, "disclose exact before/after"):
-- the ORIGINAL (0142) code's carrier-evidence branch was:
--   if carrier_resolution = 'conflicting' then conflicting_carrier_evidence
--   if carrier_resolution = 'unresolved'  then missing_carrier_evidence
--   [implicit fallthrough]                     safely_identifiable_legacy
-- A load whose carrier_id is NULL and whose carrier_resolution is NULL
-- itself (0132's comment: "NULL only for loads created before 0133 ran
-- that a later slice has not yet classified") matched NEITHER explicit
-- branch and fell through to safely_identifiable_legacy -- incorrect: a
-- load with no carrier_id has no carrier evidence at all. The corrected
-- code checks carrier_id IS NOT NULL first (-> safely_identifiable_legacy)
-- and otherwise recomputes live evidence, which can ALSO independently
-- resolve to safely_identifiable_legacy (a clean single live candidate
-- exists even though the carrier_id column itself was never persisted),
-- conflicting_carrier_evidence (a live, current, genuine disagreement),
-- or missing_carrier_evidence (zero dispatches on record) -- never a
-- guess, and never stale relative to the current dispatch table state.
--
-- ===========================================================================
-- SECTION B -- BLOCKERS 2 & 3: direct authenticated INSERT/DELETE on
-- carrier_invoices
-- ===========================================================================
-- 0142 revokes only UPDATE from authenticated on carrier_invoices
-- (`revoke update ...; grant update (notes) ...`) -- INSERT and DELETE
-- survive from 0010's blanket "grant full CRUD to authenticated on every
-- new table" convention. The RLS policies carrier_invoices_insert /
-- carrier_invoices_delete are real, deliberately-scoped policies (Section
-- K's own comments confirm intent: owner/admin/accountant may create any
-- draft, dispatcher only a draft; owner/admin/accountant may delete) --
-- but a POLICY only NARROWS an existing GRANT, it cannot substitute for
-- one being absent. With the table-level grant present, an authenticated
-- session matching the policy's role condition can INSERT/DELETE the row
-- DIRECTLY:
--   * INSERT: the policy does not restrict issuance_status for owner/
--     admin/accountant, and INSERT has no column-level grant at all (only
--     UPDATE does) -- any column, including issuance_status='issued' and a
--     self-chosen invoice_number, can be set in one client-supplied INSERT,
--     forging a "legal" invoice with no snapshot, no allocation, no audit
--     event. issue_carrier_invoice() (0144/0145) is completely bypassed.
--   * DELETE: guard_carrier_invoice_delete() (0142) already narrows this to
--     draft/ready_for_issue invoices (an issued/voided invoice cannot be
--     deleted by anyone, trigger-enforced) -- but within that window an
--     owner/admin/accountant can destroy real, unissued work-in-progress
--     with a bare DELETE: no reason captured, no idempotency, no audit
--     event, no optimistic-concurrency check against a stale client view.
--
-- src/ has no caller of carrier_invoices at all (see file header) and
-- issue_carrier_invoice(p_invoice_id, ...) (0144/0145) takes an EXISTING
-- row id -- it never creates one. There is therefore currently NO OTHER
-- path, RPC or otherwise, by which a carrier_invoices draft could ever be
-- created once direct INSERT is revoked. Revoke-only would not merely
-- close a hole, it would make the entire carrier-invoice feature
-- permanently uncreatable -- "silently destroying legitimate draft-
-- management capability" the mission explicitly forbids. This migration
-- therefore adds two new guarded SECURITY DEFINER RPCs,
-- create_carrier_invoice_draft(...) and delete_carrier_invoice_draft(...),
-- reusing this schema's own established RPC conventions (organization/
-- identity derivation, advisory-lock-before-row-lock via hashtextextended +
-- pg_advisory_xact_lock -- the exact pattern update_carrier_invoice_draft
-- (0143) already uses, operation-scoped idempotency tables, one
-- log_activity() event per success, structured jsonb-only failures), then
-- revokes the raw table-level INSERT/DELETE entirely.
--
-- Role matrix (mirrors the EXISTING RLS policies' own already-documented
-- intent -- not invented fresh): create_carrier_invoice_draft is reachable
-- by owner/admin/accountant/dispatcher (identical to carrier_invoices_
-- insert's own condition, since every row this RPC creates IS a draft);
-- delete_carrier_invoice_draft is reachable by owner/admin/accountant only
-- (identical to carrier_invoices_delete's own condition -- dispatcher was
-- never in that policy and is not added here).
--
-- DELIBERATE NARROWING (Section E: "do not copy the current exploit window
-- as policy without review"): delete_carrier_invoice_draft only accepts
-- issuance_status = 'draft', strictly narrower than guard_carrier_invoice_
-- delete's own draft-OR-ready_for_issue allowance. No RPC in 0130-0146 ever
-- transitions a draft to ready_for_issue (that transition is, per 0142's
-- own comment, "fully deferred" and still has zero implementation), so
-- ready_for_issue is unreachable through any legitimate path today -- this
-- narrowing removes no currently-usable capability. It is deliberately
-- stricter because "reviewed and about to be issued" should not be
-- silently deletable without first reverting to draft, once that state
-- becomes reachable. The underlying trigger's broader draft-OR-ready_for_
-- issue allowance remains as defense-in-depth for any other future write
-- path; it is not loosened or relied upon by this RPC.
--
-- ===========================================================================
-- SECTION C -- BLOCKERS 4/5/6: PUBLIC/anon EXECUTE on three legacy/draft RPCs
-- ===========================================================================
-- update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) (0143),
-- review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)
-- (0142), and scan_legacy_invoices_for_carrier_migration() (0142) were each
-- given `grant execute ... to authenticated` but PUBLIC's default EXECUTE
-- grant (every new function is PUBLIC-executable by default in Postgres
-- unless revoked) was never explicitly revoked, and neither was anon's
-- (anon inherits from PUBLIC). All three remain callable by an
-- unauthenticated request. Two of the three already fail closed in
-- practice for a null identity (see Section D); the third does not (that
-- is BLOCKER 7, fixed below) -- but "fails closed today" is not the same
-- guarantee as "cannot be called at all", and every sibling client RPC in
-- this schema explicitly revokes PUBLIC/anon. This migration revokes ALL
-- from public and anon on the three exact installed signatures above (re-
-- verified directly against the disposable catalog, not assumed from
-- names), and re-grants EXECUTE to authenticated only, matching every
-- other client RPC in 0138-0146.
--
-- ===========================================================================
-- SECTION D -- BLOCKER 7: null-identity fail-open in
-- scan_legacy_invoices_for_carrier_migration()
-- ===========================================================================
-- public.has_role(p_roles) = `select current_role() = any(p_roles)`, and
-- current_role() = `select role from profiles where id = auth.uid()`. For
-- a null-identity caller (anon, or authenticated with no profile row),
-- current_role() returns NULL, so has_role(...) returns NULL (SQL three-
-- valued logic), never false. scan_legacy_invoices_for_carrier_migration's
-- own guard is `if not public.has_role(...) then raise exception`; `not
-- NULL` is NULL, and PL/pgSQL's `IF NULL THEN` does not execute -- the
-- exception is silently skipped. Execution falls through to `for v_row in
-- select ... where organization_id = public.current_org_id() loop`; for a
-- null identity current_org_id() is also NULL, so the WHERE clause matches
-- zero rows (NULL never equals anything) and the function returns 0 --
-- a "successful", misleadingly-empty scan instead of the intended FORBIDDEN.
--
-- update_carrier_invoice_draft and review_legacy_invoice_carrier_migration
-- do NOT share this defect (confirmed by direct source read, Section G's
-- own audit trail for the sibling-defect check below): both derive
-- v_org := current_org_id() and return a structured NO_ORGANIZATION failure
-- BEFORE ever reaching a role check, closing the null-identity path first.
-- update_carrier_invoice_draft's own role check is additionally an
-- IF/ELSIF/ELSE chain that falls through to an explicit FORBIDDEN ELSE
-- branch on a NULL has_role() result, rather than a bare `IF NOT
-- nullable_boolean` -- fail-closed by construction, not by accident.
--
-- Correction: scan_legacy_invoices_for_carrier_migration gains the SAME
-- explicit auth.uid()/current_org_id() null checks its siblings already
-- have, PLUS a null-safe `IS NOT TRUE` role test (fail-closed even if a
-- future has_role() change ever returns NULL again). The function's own
-- established error contract (RAISE EXCEPTION with errcode 42501 -- it
-- returns integer, not jsonb, so a structured jsonb failure is not an
-- option without a breaking signature change) is preserved exactly.
--
-- Sibling-defect audit (Section G instruction: audit every function body
-- touched by this migration for the same NOT-nullable-boolean pattern):
-- classify_legacy_invoice_for_carrier_migration (Section A) is STABLE,
-- read-only, and has no role check of its own (callers gate authorization);
-- update_carrier_invoice_draft/review_legacy_invoice_carrier_migration are
-- touched only for their GRANT (Section C), not their body, and were
-- already re-confirmed safe above; the two new RPCs (Section B) are
-- written with explicit auth.uid()/current_org_id() checks before any role
-- test and never use a bare `NOT has_role(...)` as their sole gate. No
-- sibling defect found among the functions this migration actually
-- touches; none is reported.
--
-- ===========================================================================
-- SECTION E -- WARNING excluded from scope
-- ===========================================================================
-- FUNC_RAISE_LEAKS_CONTEXT (five 0130-0135 RPCs raising a raw exception
-- instead of a structured result) remains a WARNING, untouched here: it is
-- not inseparable from any of the seven BLOCKERs above, and broadening
-- those five functions' error contracts is explicitly out of scope for a
-- blocker-remediation migration.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
begin
  if to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)') is null then
    raise exception '0147 precondition: classify_legacy_invoice_for_carrier_migration(uuid) (0142) missing. STOP.';
  end if;
  if to_regprocedure('public.scan_legacy_invoices_for_carrier_migration()') is null then
    raise exception '0147 precondition: scan_legacy_invoices_for_carrier_migration() (0142) missing. STOP.';
  end if;
  if to_regprocedure('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)') is null then
    raise exception '0147 precondition: review_legacy_invoice_carrier_migration(...) (0142) missing. STOP.';
  end if;
  if to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is null then
    raise exception '0147 precondition: update_carrier_invoice_draft(...) (0143) missing. STOP.';
  end if;
  if to_regclass('public.carrier_invoices') is null then
    raise exception '0147 precondition: carrier_invoices (0142) missing. STOP.';
  end if;
  if to_regclass('public.dispatches') is null then
    raise exception '0147 precondition: public.dispatches (0001) missing. STOP.';
  end if;
  if to_regclass('public.carrier_invoice_draft_create_idempotency') is not null
     or to_regclass('public.carrier_invoice_draft_delete_idempotency') is not null then
    raise exception '0147 precondition: a 0147 object already exists. STOP (already applied?).';
  end if;
  if to_regprocedure('public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)') is not null then
    raise exception '0147 precondition: create_carrier_invoice_draft(...) already exists. STOP (already applied?).';
  end if;
end
$mig$;

-- ======================= PHASE 2 -- CLASSIFIER CORRECTION (BLOCKER 1) ======
create or replace function public.classify_legacy_invoice_for_carrier_migration(p_invoice_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_inv record;
  v_load record;
  v_factored_count integer;
  v_fdi_carrier uuid;
  v_noncanc_carriers uuid[];
  v_all_carriers uuid[];
  v_n_disp integer;
  v_c1_safe boolean;
  v_resolved_carrier_id uuid;
begin
  select id, organization_id, status, load_id, broker_id, customer_id, amount_paid, total_amount
    into v_inv
  from public.invoices where id = p_invoice_id;
  if v_inv.id is null then
    return 'not_found';
  end if;

  if v_inv.status = 'void' then
    return 'voided_cancelled';
  end if;
  if v_inv.status = 'paid' or (v_inv.amount_paid > 0 and v_inv.amount_paid < v_inv.total_amount) then
    return 'paid_or_partially_paid';
  end if;

  select count(*) into v_factored_count from public.factored_invoices where invoice_id = p_invoice_id;
  if v_factored_count > 0 then
    return 'existing_factoring_activity';
  end if;

  if v_inv.broker_id is not null and v_inv.customer_id is not null then
    return 'conflicting_recipient_evidence';
  end if;
  if v_inv.broker_id is null and v_inv.customer_id is null then
    return 'missing_recipient';
  end if;

  if v_inv.load_id is null then
    return 'missing_carrier_evidence';
  end if;

  select id, carrier_id, financial_dispatch_id into v_load from public.loads where id = v_inv.load_id;
  if v_load.id is null then
    -- The referenced load no longer exists -- no carrier evidence at all.
    return 'missing_carrier_evidence';
  end if;
  if v_load.carrier_id is not null then
    return 'safely_identifiable_legacy';
  end if;

  -- carrier_id is null: derive conflicting-vs-missing-vs-actually-
  -- resolvable-now LIVE and directly from the same authoritative
  -- dispatch/financial-controller relationships 0133's own per-load CTE
  -- uses (0133_deterministic_carrier_backfill.sql, PHASE 1) -- see this
  -- migration's own file header (Section A) for why a stored diagnostic
  -- label was rejected in favor of this live recomputation. Deterministic:
  -- cardinality of a DISTINCT array does not depend on row order.
  select d.carrier_id into v_fdi_carrier
    from public.dispatches d where d.id = v_load.financial_dispatch_id and d.load_id = v_load.id;

  select coalesce(array_agg(distinct d.carrier_id), '{}'::uuid[]) into v_noncanc_carriers
    from public.dispatches d where d.load_id = v_load.id and d.status <> 'cancelled';

  select coalesce(array_agg(distinct d.carrier_id), '{}'::uuid[]) into v_all_carriers
    from public.dispatches d where d.load_id = v_load.id;

  select count(*) into v_n_disp from public.dispatches d where d.load_id = v_load.id;

  -- Exact mirror of 0133's own c1_safe/resolved_carrier_id CASE (PRE_
  -- EXISTING branch omitted -- carrier_id is already known null here).
  v_c1_safe := v_fdi_carrier is not null
    and (array_length(v_noncanc_carriers, 1) is null
         or (array_length(v_noncanc_carriers, 1) = 1 and v_noncanc_carriers[1] = v_fdi_carrier));

  v_resolved_carrier_id := case
    when v_fdi_carrier is not null and v_c1_safe then v_fdi_carrier                                    -- C1
    when v_fdi_carrier is null and array_length(v_noncanc_carriers, 1) = 1 then v_noncanc_carriers[1]   -- C2
    when v_fdi_carrier is null and array_length(v_noncanc_carriers, 1) is null
         and array_length(v_all_carriers, 1) = 1 then v_all_carriers[1]                                 -- C3
    else null                                                                                           -- C4 (incl. C1 conflict)
  end;

  if v_resolved_carrier_id is not null then
    -- A single, unambiguous, live carrier candidate exists even though
    -- loads.carrier_id was never actually set (e.g. this load predates
    -- 0133's one-time backfill window, or its resolution has not been
    -- persisted for some other reason) -- genuinely usable evidence.
    return 'safely_identifiable_legacy';
  end if;
  if v_n_disp = 0 then
    return 'missing_carrier_evidence';
  end if;
  -- resolved_carrier_id is null with at least one dispatch on record:
  -- either the financial controller is contradicted by a live non-
  -- cancelled dispatch (C1 conflict), or 2+ distinct carriers remain
  -- live candidates (C4 conflict) -- both are genuine, current, reachable
  -- conflicting evidence, never a guess.
  return 'conflicting_carrier_evidence';
end;
$fn$;

revoke all on function public.classify_legacy_invoice_for_carrier_migration(uuid) from public, anon, authenticated;

comment on function public.classify_legacy_invoice_for_carrier_migration(uuid) is
  'Phase 3C.1.1 correction (supersedes the Phase 3C.1 unresolved_carrier_records.detail-based approach after adversarial review found it stale-prone): conflicting_carrier_evidence vs missing_carrier_evidence vs safely_identifiable_legacy for a load whose carrier_id is null is now derived LIVE from public.dispatches (financial_dispatch_id controller + non-cancelled/all carrier sets), an exact mirror of 0133''s own per-load resolution CASE, never from a frozen diagnostic string. Same 9 output labels, same precedence, same signature as 0142. Read-only, STABLE. Never mutates public.invoices, public.loads, or unresolved_carrier_records.';

-- ======================= PHASE 3 -- NULL-IDENTITY FIX (BLOCKER 7) ==========
create or replace function public.scan_legacy_invoices_for_carrier_migration()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_row record;
  v_classification text;
  v_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'scan_legacy_invoices_for_carrier_migration: authentication required.' using errcode = '42501';
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'scan_legacy_invoices_for_carrier_migration: no organization on this account.' using errcode = '42501';
  end if;

  if public.has_role(array['owner', 'admin']::public.org_role[]) is not true then
    raise exception 'scan_legacy_invoices_for_carrier_migration: owner or admin only.' using errcode = '42501';
  end if;

  for v_row in select id, organization_id from public.invoices where organization_id = v_org loop
    v_classification := public.classify_legacy_invoice_for_carrier_migration(v_row.id);
    insert into public.legacy_invoice_carrier_migration_review (organization_id, legacy_invoice_id, classification)
    values (v_row.organization_id, v_row.id, v_classification)
    on conflict (legacy_invoice_id) do update set classification = excluded.classification, updated_at = now();
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$fn$;

comment on function public.scan_legacy_invoices_for_carrier_migration() is
  'Phase 3C.1 (0147) correction: explicit auth.uid()/current_org_id() null checks now precede the role check, and the role check itself uses `IS NOT TRUE` (never a bare `NOT nullable_boolean`) -- a null-identity or no-profile caller now reliably raises FORBIDDEN (errcode 42501) instead of silently returning 0. Owner/admin only, explicitly invoked, never automatic. Same signature and same review-table-write behavior as 0142.';

-- ======================= PHASE 4 -- EXECUTE HARDENING (BLOCKERS 4/5/6) =====
revoke all on function public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) from public, anon;
grant execute on function public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) to authenticated;

revoke all on function public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text) from public, anon;
grant execute on function public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text) to authenticated;

revoke all on function public.scan_legacy_invoices_for_carrier_migration() from public, anon;
grant execute on function public.scan_legacy_invoices_for_carrier_migration() to authenticated;

-- ======================= PHASE 5 -- CARRIER_INVOICES DIRECT-WRITE LOCKDOWN =
-- (BLOCKERS 2 & 3) -- guarded RPCs below replace this capability entirely.
drop policy if exists carrier_invoices_insert on public.carrier_invoices;
drop policy if exists carrier_invoices_delete on public.carrier_invoices;

revoke insert, delete on public.carrier_invoices from authenticated;
revoke insert, delete on public.carrier_invoices from anon;

comment on table public.carrier_invoices is
  'Phase 3B.3A foundation; Phase 3C.1 (0147) correction: authenticated/anon have zero direct INSERT/DELETE (and, since 0142, zero direct UPDATE beyond the single notes column). Draft creation/deletion go ONLY through create_carrier_invoice_draft()/delete_carrier_invoice_draft() (both SECURITY DEFINER, below); every other transition goes through update_carrier_invoice_draft()/issue_carrier_invoice()/void or payment RPCs. NEW, additive invoice-document model, entirely independent of the legacy public.invoices table.';

-- ======================= PHASE 6 -- GUARDED DRAFT CREATE/DELETE RPCs =======
create table public.carrier_invoice_draft_create_idempotency (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  idempotency_key text not null,
  request_fingerprint text not null,
  created_invoice_id uuid not null references public.carrier_invoices (id) on delete cascade,
  result jsonb not null,
  created_at timestamptz not null default now(),
  constraint civdraft_create_idempotency_unique unique (organization_id, idempotency_key)
);

revoke insert, update, delete on public.carrier_invoice_draft_create_idempotency from authenticated;
revoke all on public.carrier_invoice_draft_create_idempotency from anon;

alter table public.carrier_invoice_draft_create_idempotency enable row level security;

create policy carrier_invoice_draft_create_idempotency_select
  on public.carrier_invoice_draft_create_idempotency for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

comment on table public.carrier_invoice_draft_create_idempotency is
  'Phase 3C.1 (0147). Operation-scoped idempotency for create_carrier_invoice_draft() -- a dedicated table (never shared with update_carrier_invoice_draft''s own carrier_invoice_lifecycle_idempotency, which durably references an EXISTING invoice_id and cannot represent "no row created yet"). No client INSERT/UPDATE/DELETE policy -- writable only via the SECURITY DEFINER RPC.';

create table public.carrier_invoice_draft_delete_idempotency (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  idempotency_key text not null,
  request_fingerprint text not null,
  deleted_invoice_id uuid not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  constraint civdraft_delete_idempotency_unique unique (organization_id, idempotency_key)
);

revoke insert, update, delete on public.carrier_invoice_draft_delete_idempotency from authenticated;
revoke all on public.carrier_invoice_draft_delete_idempotency from anon;

alter table public.carrier_invoice_draft_delete_idempotency enable row level security;

create policy carrier_invoice_draft_delete_idempotency_select
  on public.carrier_invoice_draft_delete_idempotency for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]));

comment on table public.carrier_invoice_draft_delete_idempotency is
  'Phase 3C.1 (0147). Operation-scoped idempotency for delete_carrier_invoice_draft(). deleted_invoice_id is NOT a foreign key (the referenced row is gone by the time this row is written) -- it is retained purely as a durable pointer for audit/idempotency-replay purposes. No client INSERT/UPDATE/DELETE policy -- writable only via the SECURITY DEFINER RPC.';

-- ---------------------------------------------------------------------------
-- create_carrier_invoice_draft: the sole guarded path to create a
-- carrier_invoices row. Always issuance_status='draft' -- there is no
-- parameter for it. Reachable by owner/admin/accountant/dispatcher,
-- matching carrier_invoices_insert's own already-documented role
-- condition (every row this RPC creates is exactly the case that policy
-- already permitted dispatcher to create). Line items and source loads are
-- added afterward through their OWN existing, already-correctly-scoped
-- RLS INSERT policies (carrier_invoice_line_items_insert / carrier_invoice_
-- loads_insert, both 0142) -- this RPC only creates the header row.
-- ---------------------------------------------------------------------------
create function public.create_carrier_invoice_draft(
  p_invoice_document_type public.invoice_document_type,
  p_carrier_id uuid,
  p_recipient_type public.invoice_recipient_type default null,
  p_recipient_broker_id uuid default null,
  p_recipient_customer_id uuid default null,
  p_currency text default 'USD',
  p_payment_terms_days integer default null,
  p_due_date date default null,
  p_notes text default null,
  p_reason text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_uid uuid;
  v_lock_key bigint;
  v_fingerprint text;
  v_canonical jsonb;
  v_cached jsonb;
  v_new_id uuid;
  v_result jsonb;
  v_operation constant text := 'create_carrier_invoice_draft';
  v_schema_version constant integer := 1;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'NO_ORGANIZATION', 'message', 'No organization on this account.');
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A reason is required.');
  end if;
  if p_invoice_document_type is null or p_carrier_id is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'invoice_document_type and carrier_id are required.');
  end if;
  if p_currency !~ '^[A-Z]{3}$' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'currency must be a 3-letter uppercase code.');
  end if;
  if p_payment_terms_days is not null and (p_payment_terms_days < 0 or p_payment_terms_days > 365) then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days must be between 0 and 365.');
  end if;

  if public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) is true then
    null; -- may create any document type
  elsif public.has_role(array['dispatcher']::public.org_role[]) is true then
    null; -- may create a draft too (every row this RPC creates is a draft)
  else
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to create a carrier invoice draft.');
  end if;

  v_canonical := jsonb_build_object(
    'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
    'invoice_document_type', p_invoice_document_type, 'carrier_id', p_carrier_id,
    'recipient_type', p_recipient_type, 'recipient_broker_id', p_recipient_broker_id,
    'recipient_customer_id', p_recipient_customer_id, 'currency', p_currency,
    'payment_terms_days', p_payment_terms_days, 'due_date', p_due_date,
    'notes', p_notes, 'reason', btrim(p_reason)
  );
  v_fingerprint := encode(digest(v_canonical::text, 'sha256'), 'hex');

  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select result, request_fingerprint into v_cached, v_fingerprint
  from public.carrier_invoice_draft_create_idempotency
  where organization_id = v_org and idempotency_key = p_idempotency_key;
  if v_cached is not null then
    if (select request_fingerprint from public.carrier_invoice_draft_create_idempotency where organization_id = v_org and idempotency_key = p_idempotency_key) <> encode(digest(v_canonical::text, 'sha256'), 'hex') then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached;
  end if;
  v_fingerprint := encode(digest(v_canonical::text, 'sha256'), 'hex');

  if not exists (select 1 from public.carrier_ids_selectable_for_new_records() c where c = p_carrier_id) then
    return jsonb_build_object('success', false, 'code', 'INVALID_CARRIER', 'message', 'Carrier not found, inactive, or not in your organization.');
  end if;

  if p_invoice_document_type = 'carrier_freight_invoice' then
    if not (
      (p_recipient_type = 'broker' and p_recipient_broker_id is not null and p_recipient_customer_id is null)
      or (p_recipient_type = 'customer' and p_recipient_customer_id is not null and p_recipient_broker_id is null)
    ) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A carrier freight invoice needs exactly one recipient (broker or customer).');
    end if;
    if p_recipient_broker_id is not null and not exists (select 1 from public.brokers where id = p_recipient_broker_id and organization_id = v_org) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'recipient_broker_id not found in your organization.');
    end if;
    if p_recipient_customer_id is not null and not exists (select 1 from public.customers where id = p_recipient_customer_id and organization_id = v_org) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'recipient_customer_id not found in your organization.');
    end if;
  elsif p_invoice_document_type = 'dispatch_service_invoice' then
    if p_recipient_type is not null or p_recipient_broker_id is not null or p_recipient_customer_id is not null then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A dispatch-service invoice must not specify a recipient (the carrier is always the recipient).');
    end if;
  end if;

  begin
    insert into public.carrier_invoices (
      organization_id, invoice_document_type, issuance_status, carrier_id,
      recipient_type, recipient_broker_id, recipient_customer_id,
      currency, payment_terms_days, due_date, notes, created_by
    ) values (
      v_org, p_invoice_document_type, 'draft', p_carrier_id,
      p_recipient_type, p_recipient_broker_id, p_recipient_customer_id,
      p_currency, p_payment_terms_days, p_due_date, p_notes, v_uid
    )
    returning id into v_new_id;
  exception when others then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'The requested draft could not be created.');
  end;

  perform public.log_activity('invoice'::public.entity_type, v_new_id, 'carrier_invoice_draft_created',
    jsonb_build_object('invoice_document_type', p_invoice_document_type, 'carrier_id', p_carrier_id, 'reason', btrim(p_reason)));

  v_result := jsonb_build_object('success', true, 'code', 'CREATED', 'invoice_id', v_new_id);

  insert into public.carrier_invoice_draft_create_idempotency
    (organization_id, idempotency_key, request_fingerprint, created_invoice_id, result)
  values (v_org, p_idempotency_key, v_fingerprint, v_new_id, v_result);

  return v_result;
end;
$fn$;

revoke all on function public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text) from public, anon;
grant execute on function public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text) to authenticated;

comment on function public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text) is
  'Phase 3C.1 (0147). The sole guarded path to create a carrier_invoices row (always issuance_status=''draft''). Owner/admin/accountant may create either document type; dispatcher may also create one (matches carrier_invoices_insert''s own pre-0147 role condition). Organization/actor derived from auth context; carrier validated via carrier_ids_selectable_for_new_records(); recipient shape validated per document type; operation-scoped idempotency + advisory lock; exactly one log_activity() event per success; structured jsonb failures only, never a raw SQL error.';

-- ---------------------------------------------------------------------------
-- delete_carrier_invoice_draft: the sole guarded path to delete a
-- carrier_invoices row. Owner/admin/accountant only (matches carrier_
-- invoices_delete's own pre-0147 role condition -- dispatcher was never
-- included). Deliberately narrower than the underlying trigger: only
-- issuance_status='draft' (see file header for why ready_for_issue is
-- excluded here even though the trigger alone would still permit it).
-- ---------------------------------------------------------------------------
create function public.delete_carrier_invoice_draft(
  p_invoice_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_uid uuid;
  v_lock_key bigint;
  v_fingerprint text;
  v_canonical jsonb;
  v_cached jsonb;
  v_row record;
  v_result jsonb;
  v_operation constant text := 'delete_carrier_invoice_draft';
  v_schema_version constant integer := 1;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'NO_ORGANIZATION', 'message', 'No organization on this account.');
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A reason is required.');
  end if;
  if p_invoice_id is null or p_expected_updated_at is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'invoice_id and expected_updated_at are required.');
  end if;

  if public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) is not true then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to delete a carrier invoice draft.');
  end if;

  v_canonical := jsonb_build_object(
    'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
    'invoice_id', p_invoice_id, 'expected_updated_at', p_expected_updated_at, 'reason', btrim(p_reason)
  );
  v_fingerprint := encode(digest(v_canonical::text, 'sha256'), 'hex');

  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select result into v_cached
  from public.carrier_invoice_draft_delete_idempotency
  where organization_id = v_org and idempotency_key = p_idempotency_key;
  if v_cached is not null then
    if (select request_fingerprint from public.carrier_invoice_draft_delete_idempotency where organization_id = v_org and idempotency_key = p_idempotency_key) <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached;
  end if;

  -- Row-lock BEFORE the org/staleness/status checks -- same convention as
  -- review_legacy_invoice_carrier_migration/update_carrier_invoice_draft.
  select id, organization_id, issuance_status, updated_at into v_row
  from public.carrier_invoices where id = p_invoice_id for update;

  if v_row.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;
  if v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;
  if v_row.updated_at <> p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This invoice has changed since you loaded it. Reload and try again.');
  end if;
  if v_row.issuance_status <> 'draft' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Only a draft invoice can be deleted this way.');
  end if;

  begin
    delete from public.carrier_invoices where id = p_invoice_id;
  exception when others then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'This invoice could not be deleted.');
  end;

  perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'carrier_invoice_draft_deleted',
    jsonb_build_object('reason', btrim(p_reason)));

  v_result := jsonb_build_object('success', true, 'code', 'DELETED', 'invoice_id', p_invoice_id);

  insert into public.carrier_invoice_draft_delete_idempotency
    (organization_id, idempotency_key, request_fingerprint, deleted_invoice_id, result)
  values (v_org, p_idempotency_key, v_fingerprint, p_invoice_id, v_result);

  return v_result;
end;
$fn$;

revoke all on function public.delete_carrier_invoice_draft(uuid,timestamptz,text,text) from public, anon;
grant execute on function public.delete_carrier_invoice_draft(uuid,timestamptz,text,text) to authenticated;

comment on function public.delete_carrier_invoice_draft(uuid,timestamptz,text,text) is
  'Phase 3C.1 (0147). The sole guarded path to delete a carrier_invoices row. Owner/admin/accountant only (matches carrier_invoices_delete''s own pre-0147 role condition). Deliberately narrower than guard_carrier_invoice_delete() itself: only issuance_status=''draft'' (ready_for_issue is excluded -- see migration header). Organization derived from the target row; optimistic concurrency via expected_updated_at; operation-scoped idempotency + advisory lock; exactly one log_activity() event per success; structured jsonb failures only, including NOT_FOUND for a cross-organization id (indistinguishable from a genuinely missing row).';

-- ======================= PHASE 7 -- POSTCONDITIONS ==========================
do $mig$
begin
  -- Blocker 1: classifier signature preserved, source updated.
  if to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)') is null then
    raise exception '0147 postcondition: classify_legacy_invoice_for_carrier_migration(uuid) missing.';
  end if;
  if (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%carrier_resolution = ''conflicting''%' then
    raise exception '0147 postcondition: classify_legacy_invoice_for_carrier_migration still tests the impossible carrier_resolution=''conflicting'' literal.';
  end if;
  if (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%unresolved_carrier_records%' then
    raise exception '0147 postcondition: classify_legacy_invoice_for_carrier_migration must NOT consult unresolved_carrier_records (Phase 3C.1.1: that column is an unconstrained, stale-prone diagnostic log, not an authoritative contract).';
  end if;
  if (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) not ilike '%public.dispatches%' then
    raise exception '0147 postcondition: classify_legacy_invoice_for_carrier_migration does not derive carrier evidence live from public.dispatches.';
  end if;

  -- Blockers 2/3: carrier_invoices direct INSERT/DELETE gone for every role.
  if has_table_privilege('authenticated', 'public.carrier_invoices', 'INSERT') then
    raise exception '0147 postcondition: authenticated still has direct INSERT on carrier_invoices.';
  end if;
  if has_table_privilege('authenticated', 'public.carrier_invoices', 'DELETE') then
    raise exception '0147 postcondition: authenticated still has direct DELETE on carrier_invoices.';
  end if;
  if has_table_privilege('anon', 'public.carrier_invoices', 'INSERT') or has_table_privilege('anon', 'public.carrier_invoices', 'DELETE') then
    raise exception '0147 postcondition: anon has a direct INSERT/DELETE on carrier_invoices.';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'carrier_invoices' and policyname in ('carrier_invoices_insert', 'carrier_invoices_delete')) then
    raise exception '0147 postcondition: a stale carrier_invoices_insert/delete policy still exists.';
  end if;
  if to_regprocedure('public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)') is null then
    raise exception '0147 postcondition: create_carrier_invoice_draft(...) missing.';
  end if;
  if to_regprocedure('public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)') is null then
    raise exception '0147 postcondition: delete_carrier_invoice_draft(...) missing.';
  end if;
  if not has_function_privilege('authenticated', 'public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)', 'EXECUTE') then
    raise exception '0147 postcondition: authenticated cannot EXECUTE create_carrier_invoice_draft.';
  end if;
  if not has_function_privilege('authenticated', 'public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)', 'EXECUTE') then
    raise exception '0147 postcondition: authenticated cannot EXECUTE delete_carrier_invoice_draft.';
  end if;
  if has_function_privilege('anon', 'public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)', 'EXECUTE') then
    raise exception '0147 postcondition: anon can EXECUTE a new draft RPC.';
  end if;

  -- Blockers 4/5/6: exact three signatures hardened, no lingering PUBLIC/anon.
  if has_function_privilege('anon', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE') then
    raise exception '0147 postcondition: anon can still EXECUTE update_carrier_invoice_draft.';
  end if;
  if has_function_privilege('anon', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE') then
    raise exception '0147 postcondition: anon can still EXECUTE review_legacy_invoice_carrier_migration.';
  end if;
  if has_function_privilege('anon', 'public.scan_legacy_invoices_for_carrier_migration()', 'EXECUTE') then
    raise exception '0147 postcondition: anon can still EXECUTE scan_legacy_invoices_for_carrier_migration.';
  end if;
  if not has_function_privilege('authenticated', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.scan_legacy_invoices_for_carrier_migration()', 'EXECUTE') then
    raise exception '0147 postcondition: authenticated lost EXECUTE on one of the three hardened RPCs.';
  end if;

  -- Blocker 7: null-identity source shape.
  if (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) not ilike '%auth.uid() is null%' then
    raise exception '0147 postcondition: scan_legacy_invoices_for_carrier_migration does not check auth.uid() IS NULL.';
  end if;
  if (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) not ilike '%is not true%' then
    raise exception '0147 postcondition: scan_legacy_invoices_for_carrier_migration does not use a null-safe (IS NOT TRUE) role check.';
  end if;

  -- Search-path pinning + ownership hygiene for everything this migration
  -- created or replaced.
  if exists (
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and p.proname in ('classify_legacy_invoice_for_carrier_migration','scan_legacy_invoices_for_carrier_migration','create_carrier_invoice_draft','delete_carrier_invoice_draft')
      and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')
  ) then
    raise exception '0147 postcondition: a function this migration created/replaced has no pinned search_path.';
  end if;

  -- No default-privilege regression: a brand new table should still not be
  -- auto-grantable to authenticated for INSERT/DELETE-shaped privileges
  -- beyond what this schema already deliberately allows elsewhere.
  if has_table_privilege('authenticated', 'public.carrier_invoice_draft_create_idempotency', 'INSERT')
     or has_table_privilege('authenticated', 'public.carrier_invoice_draft_delete_idempotency', 'INSERT') then
    raise exception '0147 postcondition: authenticated has direct INSERT on a new idempotency table.';
  end if;
  if has_table_privilege('anon', 'public.carrier_invoice_draft_create_idempotency', 'SELECT')
     or has_table_privilege('anon', 'public.carrier_invoice_draft_delete_idempotency', 'SELECT') then
    raise exception '0147 postcondition: anon has a grant on a new idempotency table.';
  end if;

  -- RLS remains enabled on carrier_invoices; existing guards untouched.
  if not (select relrowsecurity from pg_class where oid = 'public.carrier_invoices'::regclass) then
    raise exception '0147 postcondition: RLS disabled on carrier_invoices.';
  end if;
  if (select count(*) from pg_trigger where tgrelid = 'public.carrier_invoices'::regclass and not tgisinternal) <> 4 then
    raise exception '0147 postcondition: carrier_invoices trigger count changed unexpectedly (expected 4: set_updated_at, guard_org_consistency, guard_lifecycle_transition, guard_delete).';
  end if;
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is null then
    raise exception '0147 postcondition: issue_carrier_invoice unexpectedly missing.';
  end if;
  if to_regprocedure('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)') is null then
    raise exception '0147 postcondition: record_carrier_invoice_payment unexpectedly missing.';
  end if;

  -- No application-facing role can execute the internal numbering helper.
  if has_function_privilege('authenticated', 'public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)', 'EXECUTE') then
    raise exception '0147 postcondition: authenticated has EXECUTE on an internal helper.';
  end if;

  raise notice '0147 complete (Phase 3C.1, corrected by Phase 3C.1.1 adversarial review): classify_legacy_invoice_for_carrier_migration derives conflicting-vs-missing-vs-safely-identifiable carrier evidence LIVE from public.dispatches (mirroring 0133''s own per-load resolution CASE) instead of an impossible enum literal or a stale diagnostic string (same signature, same 9 labels); scan_legacy_invoices_for_carrier_migration fails closed for a null identity (explicit auth.uid()/current_org_id() checks + IS NOT TRUE role test); update_carrier_invoice_draft/review_legacy_invoice_carrier_migration/scan_legacy_invoices_for_carrier_migration have PUBLIC/anon EXECUTE revoked (authenticated-only); carrier_invoices authenticated/anon direct INSERT/DELETE revoked, replaced by create_carrier_invoice_draft()/delete_carrier_invoice_draft() (SECURITY DEFINER, role-matched to the pre-0147 RLS policies'' own intent, operation-scoped idempotency, advisory-lock-before-row-lock, one audit event per success, structured-only failures). All seven Phase 3C.0 release BLOCKERs independently remediated. Migrations 0001-0146 untouched. No production/Supabase contact.';
end
$mig$;

commit;
