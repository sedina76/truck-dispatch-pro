-- =============================================================================
-- 0133_deterministic_carrier_backfill.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0132 live. Phase 3A slice 4 (the only DATA migration in Phase 3A).
--
-- NO MAINTENANCE WINDOW IS REQUIRED BETWEEN 0132 AND 0133 (corrected from an
-- earlier draft that implied one). 0132 alone never writes loads.carrier_id
-- (verified by its own postcondition), so applying 0133 any time after 0132
-- -- seconds, hours, or days later -- is safe, INCLUDING if a not-yet-built
-- assignment path (a future load-creation/dispatch RPC, or a manual fix) has
-- ALREADY set loads.carrier_id on some rows in the meantime (correction:
-- "0132 -> 0133 deployment race"). This migration:
--   * processes ONLY rows where loads.carrier_id IS NULL
--   * PRESERVES every existing non-NULL loads.carrier_id byte-for-byte
--   * VALIDATES each pre-existing assignment (same-org, consistent with
--     financial_dispatch_id, consistent with every non-cancelled dispatch)
--     and ABORTS THE WHOLE MIGRATION (zero writes) if any is inconsistent --
--     it never guesses or silently reclassifies a pre-existing assignment
--   * does NOT record a pre-existing assignment in the rollback provenance
--     table -- ROLLBACK_0133 can therefore never touch it
--
-- DETERMINISTICALLY populates public.loads.carrier_id / carrier_resolution /
-- carrier_locked_at for every load that does NOT already have a carrier_id.
-- NEVER guesses: a load whose carrier cannot be proven is left carrier_id =
-- NULL, marked carrier_resolution = 'unresolved', and recorded in
-- public.unresolved_carrier_records so every downstream financial automation
-- stays blocked for it (decision 1).
--
-- RESOLUTION (first rule that yields a single answer; skipped entirely for a
-- load that already has a non-NULL carrier_id -- see PRE_EXISTING below):
--   C1 resolved   : loads.financial_dispatch_id is set and points to a
--                   dispatch of THIS load, AND every CURRENTLY non-cancelled
--                   dispatch on the load agrees with that dispatch's
--                   carrier_id (or there are none) -> that carrier_id.
--                   carrier_locked_at = now() (the load has a financial
--                   controller identity). financial_dispatch_id is NEVER
--                   blindly trusted over a live, contradicting dispatch --
--                   see "C1 controller-conflict ABORT" below.
--   C2 backfilled : no controller, but every NON-CANCELLED dispatch of the
--                   load shares exactly one carrier_id -> that carrier_id.
--   C3 backfilled : no controller, zero non-cancelled dispatches, but every
--                   (cancelled) dispatch shares exactly one carrier_id ->
--                   that carrier_id.
--   C4 unresolved : anything else -- zero dispatches, OR non-cancelled
--                   dispatches disagree on carrier. carrier_id stays NULL.
--   PRE_EXISTING  : loads.carrier_id is already non-NULL (set by something
--                   other than this migration, at any point after 0132).
--                   VALIDATED, NEVER OVERWRITTEN: same-org, and -- if
--                   financial_dispatch_id or any non-cancelled dispatch
--                   exists -- their carrier_id must agree with the existing
--                   loads.carrier_id. carrier_resolution is filled in with
--                   'resolved' ONLY if it is currently NULL (a label-only
--                   touch; carrier_id and carrier_locked_at are never
--                   written). NOT recorded in the rollback provenance table.
--
-- ABORT (RAISE -> full rollback, ZERO writes):
--   * loads.carrier_id already carries the 0133 backfill comment marker
--     (this migration has already succeeded once -- the sole rerun guard)
--   * a resolved/backfilled/PRE_EXISTING carrier_id whose carrier row is a
--     different org than the load (structural corruption -- should be
--     impossible given the 0055 guard_dispatch_org / 0132
--     guard_load_carrier_change triggers)
--   * loads.financial_dispatch_id points at a dispatch of a different load
--     (structural -- the 0125 guard prevents this)
--   * a PRE_EXISTING carrier_id disagrees with its own financial_dispatch_id
--     dispatch's carrier, OR with any of its own non-cancelled dispatches'
--     carrier -- this is the "existing inconsistent assignment" case; per
--     the corrected design it causes a PREFLIGHT FAILURE (full abort), never
--     a silent overwrite and never a guess
--   * C1 CONTROLLER-CONFLICT (Phase 3A clarification round, item 2): a load
--     whose loads.financial_dispatch_id names Carrier A while a currently
--     NON-CANCELLED dispatch on that same load names a DIFFERENT Carrier B.
--     THIS IS A FULL MIGRATION ABORT, not a silent 'unresolved'
--     classification -- an earlier draft of this migration instead wrote
--     such a load as carrier_resolution='unresolved' WITH financial_
--     dispatch_id left populated, an internally contradictory row this
--     round's clarification correctly rejected as unsafe to leave standing
--     (every downstream consumer that reads financial_dispatch_id without
--     ALSO re-checking carrier_resolution would silently trust the
--     contested controller). 0133 now REFUSES TO APPLY AT ALL while any
--     such conflict exists anywhere in the database (fail-closed,
--     preflight-style, exactly like every other structural abort above):
--     VERIFY_0133_PREFLIGHT.sql check 13 reports the exact conflicting
--     load_id(s) before you ever attempt to apply; each must be corrected
--     by an explicit, human, out-of-band action (e.g. cancelling the
--     dispatch that should never have been created, or correcting
--     financial_dispatch_id) -- 0133 performs NO automatic clearing of
--     financial_dispatch_id and NO automatic cancellation of any dispatch;
--     rerun the preflight until its conflict count is zero, then apply.
--     A financial controller contradicted ONLY by a CANCELLED dispatch of a
--     different carrier is unaffected by this and remains ordinary C1
--     resolved -- cancelled dispatches are legitimate history, not conflict.
--   NOTE: unlike 0126, an AMBIGUOUS (never-yet-assigned) load with NO
--   financial controller is NOT an abort here (that is ordinary C4
--   unresolved, classified and logged). Only a load whose controller is
--   ACTIVELY CONTRADICTED aborts the whole migration.
--
-- WHAT THIS MIGRATION WRITES:
--   * public.loads.carrier_id -- ONLY on rows where it was NULL
--   * public.loads.carrier_resolution -- on every row: freshly resolved for
--     carrier_id-IS-NULL rows; filled with 'resolved' ONLY IF NULL for
--     PRE_EXISTING rows (never overwrites an existing label)
--   * public.loads.carrier_locked_at -- ONLY on freshly-resolved C1 rows;
--     NEVER written for a PRE_EXISTING row
--   * public.unresolved_carrier_records (record_type='load') for each C4
--     load, via public.record_unresolved_carrier_record() (idempotent)
--   * public.carrier_backfill_0133_provenance -- a PERMANENT, one-row-per-
--     FRESHLY-RESOLVED-load record of exactly what THIS migration wrote
--     (its resolution, the carrier_id/resolution/locked_at values, and its
--     exception-row id when unresolved), with the transaction timestamp.
--     PRE_EXISTING rows are DELIBERATELY EXCLUDED -- this is the mechanism
--     that makes ROLLBACK_0133 (which acts ONLY on provenance rows) refuse
--     to ever touch a pre-existing assignment. Select-only for the app
--     (owner/admin/accountant); removed only by a full, successful
--     ROLLBACK_0133 run.
--   nothing else.
--
-- WHAT THIS MIGRATION DOES NOT TOUCH: dispatches, invoices, invoice_line_items,
--   payments, settlements, settlement_line_items, factored_invoices,
--   factoring_relationships, documents, trailers, loads.financial_dispatch_id,
--   any dispatches.proceeds_model, platform_settings.model_a_enabled, and it
--   does NOT create/replace/drop any function or trigger.
--
-- DATA EFFECT (honest): loads.carrier_id is written on the deterministically
--   resolvable NULL subset; loads.carrier_resolution is written on EVERY
--   existing load that lacks one (a value, including 'unresolved');
--   loads.carrier_locked_at is written on freshly-resolved C1 loads only.
--   loads.updated_at is bumped by the pre-existing shared set_updated_at
--   trigger on the rows written (including the PRE_EXISTING label-only fill,
--   if it applies). No amount / status / document / dispatch change.
--
-- STRUCTURE: PHASE 0 = rerun rejection + preconditions + baseline snapshots
-- (including a snapshot of every PRE-EXISTING carrier_id row, for PHASE 3 to
-- prove untouched). PHASE 1 (DO) = build the plan into a temp table and
-- RAISE only on the structural ABORT conditions. PHASE 2 = the writes.
-- PHASE 3 (DO) = postconditions + set the "backfilled" comment marker. One
-- transaction; any RAISE rolls back. NOT idempotent after success (PHASE 0
-- marker check).
-- =============================================================================

begin;

-- ======================= PHASE 0 -- PRECONDITIONS + SNAPSHOTS ===============
do $mig$
declare
  v_attnum smallint;
begin
  -- 0132 must be live
  select attnum into v_attnum from pg_attribute
  where attrelid='public.loads'::regclass and attname='carrier_id' and not attisdropped;
  if v_attnum is null then
    raise exception '0133 precondition: loads.carrier_id is missing -- apply 0132 first. STOP.';
  end if;
  if coalesce(col_description('public.loads'::regclass, v_attnum), '') ilike '%backfilled by migration 0133%' then
    raise exception '0133 precondition: loads.carrier_id comment already carries the 0133 backfill marker -- already applied. STOP.';
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
                 where n.nspname='public' and t.typname='trailer_ownership_scope') then
    raise exception '0133 precondition: type public.trailer_ownership_scope missing -- apply 0132 first. STOP.';
  end if;
  if to_regprocedure('public.guard_load_carrier_change()') is null then
    raise exception '0133 precondition: function public.guard_load_carrier_change() missing -- apply 0132 first. STOP.';
  end if;

  -- 0130 must be live (the exception writer + table)
  if to_regclass('public.unresolved_carrier_records') is null then
    raise exception '0133 precondition: public.unresolved_carrier_records missing -- apply 0130 first. STOP.';
  end if;
  if to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)') is null then
    raise exception '0133 precondition: public.record_unresolved_carrier_record(...) missing -- apply 0130 first. STOP.';
  end if;

  -- NOTE: unlike an earlier draft, a pre-existing non-NULL loads.carrier_id
  -- is NOT rejected here -- see the PRE_EXISTING rule above. The sole rerun
  -- guard is the comment-marker check above.
  if to_regclass('public.carrier_backfill_0133_provenance') is not null then
    raise exception '0133 precondition: table public.carrier_backfill_0133_provenance already exists -- partial apply? STOP.';
  end if;

  -- dispatch_status.cancelled must exist (used in the plan)
  if not exists (
    select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='dispatch_status' and e.enumlabel='cancelled'
  ) then
    raise exception '0133 precondition: enum public.dispatch_status has no ''cancelled'' member. STOP.';
  end if;

  create temp table _mig0133_counts on commit drop as
  select
    (select count(*) from public.loads)                as n_load,
    (select count(*) from public.dispatches)           as n_dispatch,
    (select count(*) from public.invoices)             as n_invoice,
    (select count(*) from public.invoice_line_items)   as n_invoice_li,
    (select count(*) from public.payments)             as n_payment,
    (select count(*) from public.settlements)          as n_settlement,
    (select count(*) from public.settlement_line_items) as n_sli,
    (select count(*) from public.trailers)             as n_trailer,
    (select count(*) from public.unresolved_carrier_records) as n_ucr_start,
    (select count(*) from public.loads where financial_dispatch_id is not null) as n_load_fdi,
    (select count(*) from public.loads where carrier_id is not null) as n_load_preexisting;

  create temp table _mig0133_fdi_snap on commit drop as
    select id, financial_dispatch_id from public.loads;

  -- Snapshot of every load that ALREADY has a carrier_id before this
  -- migration does anything. PHASE 3 proves every one of these rows is
  -- byte-for-byte unchanged.
  create temp table _mig0133_preexisting_snap on commit drop as
    select id as load_id, carrier_id, carrier_resolution, carrier_locked_at
    from public.loads
    where carrier_id is not null;

  raise notice '0133 PHASE 0 preconditions passed. Snapshots captured (% loads total, % with a financial controller, % already carrying a pre-existing carrier_id -- these will be validated and preserved, not overwritten).',
    (select n_load from _mig0133_counts), (select n_load_fdi from _mig0133_counts), (select n_load_preexisting from _mig0133_counts);
end
$mig$;

-- ======================= PHASE 1 -- BUILD PLAN + VALIDATE ===================
do $mig$
declare
  v_bad_org               integer;
  v_bad_fdi_load          integer;
  v_bad_preexisting_fdi   integer;
  v_bad_preexisting_disp  integer;
  v_bad_controller_conflict integer;
  v_bad_ids               text;
  v_conflict_ids          text;
begin
  create temp table _mig0133_plan on commit drop as
  with per_load as (
    select
      l.id                    as load_id,
      l.organization_id       as load_org,
      l.carrier_id            as existing_carrier_id,
      l.carrier_resolution    as existing_resolution,
      l.financial_dispatch_id as fdi,
      (select d.carrier_id from public.dispatches d
        where d.id = l.financial_dispatch_id and d.load_id = l.id)                       as fdi_carrier,
      coalesce((select array_agg(distinct d.carrier_id)
                from public.dispatches d where d.load_id = l.id), '{}'::uuid[])           as all_carriers,
      coalesce((select array_agg(distinct d.carrier_id)
                from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'), '{}'::uuid[]) as noncanc_carriers,
      coalesce((select count(*) from public.dispatches d where d.load_id = l.id), 0)      as n_disp,
      coalesce((select jsonb_agg(jsonb_build_object('dispatch_id', d.id, 'carrier_id', d.carrier_id, 'status', d.status) order by d.id)
                from public.dispatches d where d.load_id = l.id), '[]'::jsonb)            as disp_detail
    from public.loads l
  ),
  resolved as (
    select
      p.*,
      -- C1 is safe ONLY when the controller's carrier is not contradicted by
      -- any CURRENTLY non-cancelled dispatch (correction: "correct migration
      -- 0133 candidate rules" -- financial_dispatch_id is never blindly
      -- trusted). A cancelled dispatch of a different carrier is allowed to
      -- remain in history (0129's cancel_dispatch() preserves it) -- only a
      -- NON-cancelled disagreement disqualifies C1.
      (p.fdi_carrier is not null
       and (array_length(p.noncanc_carriers,1) is null
            or (array_length(p.noncanc_carriers,1) = 1 and p.noncanc_carriers[1] = p.fdi_carrier))
      ) as c1_safe,
      (p.existing_carrier_id is not null) as pre_existing,
      (case
         when p.existing_carrier_id is not null then p.existing_carrier_id                  -- PRE_EXISTING
         when p.fdi_carrier is not null
              and (array_length(p.noncanc_carriers,1) is null
                   or (array_length(p.noncanc_carriers,1) = 1 and p.noncanc_carriers[1] = p.fdi_carrier))
           then p.fdi_carrier                                                                -- C1 (validated)
         when p.fdi_carrier is null and array_length(p.noncanc_carriers, 1) = 1 then p.noncanc_carriers[1]  -- C2
         when p.fdi_carrier is null and array_length(p.noncanc_carriers, 1) is null
              and array_length(p.all_carriers, 1) = 1 then p.all_carriers[1]                 -- C3
         else null                                                                           -- C4 (incl. C1 conflict)
       end) as resolved_carrier_id,
      (case
         when p.existing_carrier_id is not null then coalesce(p.existing_resolution, 'resolved')
         when p.fdi_carrier is not null
              and (array_length(p.noncanc_carriers,1) is null
                   or (array_length(p.noncanc_carriers,1) = 1 and p.noncanc_carriers[1] = p.fdi_carrier))
           then 'resolved'
         when p.fdi_carrier is null and array_length(p.noncanc_carriers, 1) = 1 then 'backfilled'
         when p.fdi_carrier is null and array_length(p.noncanc_carriers, 1) is null
              and array_length(p.all_carriers, 1) = 1 then 'backfilled'
         else 'unresolved'
       end) as resolution,
      (case
         when p.existing_carrier_id is not null then 'PRE_EXISTING'
         when p.fdi_carrier is not null
              and (array_length(p.noncanc_carriers,1) is null
                   or (array_length(p.noncanc_carriers,1) = 1 and p.noncanc_carriers[1] = p.fdi_carrier))
           then 'C1_financial_controller'
         when p.fdi_carrier is not null then 'C1_controller_conflict'                        -- NEW: controller contradicted by a live dispatch
         when array_length(p.noncanc_carriers, 1) = 1 then 'C2_sole_noncancelled_carrier'
         when array_length(p.noncanc_carriers, 1) is null
              and array_length(p.all_carriers, 1) = 1 then 'C3_sole_cancelled_carrier'
         when p.n_disp = 0 then 'C4_zero_dispatch'
         else 'C4_conflicting_carriers'
       end) as rule_applied
    from per_load p
  )
  select
    r.load_id, r.load_org, r.existing_carrier_id, r.existing_resolution, r.fdi, r.fdi_carrier,
    r.n_disp, r.all_carriers, r.noncanc_carriers, r.disp_detail, r.pre_existing,
    r.resolved_carrier_id, r.resolution, r.rule_applied,
    (case when r.resolution = 'unresolved'
      then (case
              when r.rule_applied = 'C1_controller_conflict'
                then format('financial controller dispatch %s (carrier %s) is contradicted by a currently non-cancelled dispatch of a different carrier; never resolved by trusting the controller alone.', r.fdi, r.fdi_carrier)
              when r.n_disp = 0
                then 'No dispatch on this load; a responsible carrier cannot be determined.'
              else 'Multiple non-cancelled dispatches reference different carriers; carrier is ambiguous.'
            end)
      else null
    end) as unresolved_reason
  from resolved r;

  -- structural ABORT checks (NOT ambiguity) -- cover BOTH freshly-resolved
  -- and PRE_EXISTING rows (resolved_carrier_id is populated for both).
  select count(*) into v_bad_org
  from _mig0133_plan p
  join public.carriers c on c.id = p.resolved_carrier_id
  where p.resolved_carrier_id is not null and c.organization_id <> p.load_org;

  select count(*) into v_bad_fdi_load
  from _mig0133_plan p
  join public.dispatches d on d.id = p.fdi
  where p.fdi is not null and d.load_id <> p.load_id;

  -- NEW: a PRE_EXISTING carrier_id disagreeing with its own
  -- financial_dispatch_id dispatch's carrier -- inconsistent assignment,
  -- never silently overwritten or guessed. Full preflight failure.
  select count(*) into v_bad_preexisting_fdi
  from _mig0133_plan p
  where p.pre_existing and p.fdi_carrier is not null and p.fdi_carrier <> p.existing_carrier_id;

  -- NEW: a PRE_EXISTING carrier_id disagreeing with any of its own
  -- non-cancelled dispatches' carrier.
  select count(*) into v_bad_preexisting_disp
  from _mig0133_plan p
  where p.pre_existing
    and exists (select 1 from unnest(p.noncanc_carriers) as c(carrier_id) where c.carrier_id <> p.existing_carrier_id);

  -- NEW (Phase 3A clarification round, item 2 -- "C1 controller-conflict
  -- contradiction"): a FRESH (not pre_existing) load whose financial
  -- controller's carrier is contradicted by a currently non-cancelled
  -- dispatch of a DIFFERENT carrier is now a FULL PREFLIGHT-STYLE ABORT
  -- CONDITION, not a silent 'unresolved' classification. Rationale: an
  -- unresolved-with-a-populated-financial_dispatch_id row is an internally
  -- contradictory state to leave standing in the database -- every
  -- downstream consumer (invoice issuance, factoring, settlement, dispatch-
  -- service invoicing, reporting) that innocently reads financial_
  -- dispatch_id without ALSO re-checking carrier_resolution would silently
  -- treat the contested controller as authoritative. Fail-closed instead:
  -- 0133 refuses to write ANYTHING (the same all-or-nothing guarantee as
  -- every other structural abort here) until every such conflict is
  -- resolved by an explicit, human, out-of-band correction (e.g. cancelling
  -- the dispatch that should not have been created, or correcting
  -- financial_dispatch_id) -- never automatically, never by 0133 guessing
  -- which of the two contradictory facts is right. VERIFY_0133_PREFLIGHT.sql
  -- check 13 reports this exact same count and load list as a gate BEFORE
  -- apply, so this is never a surprise at apply time.
  select count(*) into v_bad_controller_conflict
  from _mig0133_plan
  where rule_applied = 'C1_controller_conflict';

  if v_bad_org > 0 or v_bad_fdi_load > 0 or v_bad_preexisting_fdi > 0 or v_bad_preexisting_disp > 0 or v_bad_controller_conflict > 0 then
    select string_agg(load_id::text, ', ') into v_bad_ids
    from _mig0133_plan
    where pre_existing and (
      (fdi_carrier is not null and fdi_carrier <> existing_carrier_id)
      or exists (select 1 from unnest(noncanc_carriers) as c(carrier_id) where c.carrier_id <> existing_carrier_id)
    );
    select string_agg(load_id::text, ', ') into v_conflict_ids
    from _mig0133_plan
    where rule_applied = 'C1_controller_conflict';
    raise exception E'0133 ABORT -- structural corruption / inconsistent pre-existing assignment / unresolved controller conflict: % load(s) resolve to a carrier of a different org; % load(s) have financial_dispatch_id pointing at another load''s dispatch; % PRE-EXISTING load(s) disagree with their own financial_dispatch_id carrier; % PRE-EXISTING load(s) disagree with their own non-cancelled dispatch carrier(s); % load(s) have a financial_dispatch_id CONTRADICTED by a currently non-cancelled dispatch of a different carrier (C1_controller_conflict -- must be manually corrected, then VERIFY_0133_PREFLIGHT.sql rerun, before 0133 can apply). No write performed. Offending pre-existing load_id(s): %. Offending controller-conflict load_id(s): %',
      v_bad_org, v_bad_fdi_load, v_bad_preexisting_fdi, v_bad_preexisting_disp, v_bad_controller_conflict,
      coalesce(v_bad_ids, '(none)'), coalesce(v_conflict_ids, '(none)');
  end if;

  raise notice '0133 PHASE 1: plan built. % pre-existing (preserved, not touched), resolved=%, backfilled=%, unresolved=% (of % loads total).',
    (select count(*) from _mig0133_plan where pre_existing),
    (select count(*) from _mig0133_plan where not pre_existing and rule_applied='C1_financial_controller'),
    (select count(*) from _mig0133_plan where not pre_existing and rule_applied in ('C2_sole_noncancelled_carrier','C3_sole_cancelled_carrier')),
    (select count(*) from _mig0133_plan where not pre_existing and resolution='unresolved'),
    (select count(*) from _mig0133_plan);
end
$mig$;

-- ======================= PHASE 2 -- THE WRITES =============================
-- 2a. FRESHLY resolved + backfilled loads only: set carrier_id + carrier_
--     resolution (+ carrier_locked_at for C1 only). The `l.carrier_id is
--     null` predicate is what makes this safe against the 0132->0133 race:
--     a load whose carrier_id was set by anything else between 0132 and now
--     no longer matches this predicate and is silently skipped here (its
--     PRE_EXISTING handling is entirely in 2a2 below). guard_load_carrier_
--     change re-checks same-org on every row; NULL -> value is allowed.
update public.loads l
set carrier_id        = p.resolved_carrier_id,
    carrier_resolution = p.resolution,
    carrier_locked_at  = case when p.rule_applied = 'C1_financial_controller' then now() else null end
from _mig0133_plan p
where l.id = p.load_id
  and not p.pre_existing
  and p.resolution <> 'unresolved'
  and l.carrier_id is null;

-- 2a2. PRE_EXISTING rows: label-only fill. NEVER touches carrier_id or
-- carrier_locked_at -- only fills carrier_resolution when it is currently
-- NULL (e.g. something set carrier_id directly without a label). A no-op
-- for any row whose carrier_resolution was already set by whatever assigned
-- carrier_id.
update public.loads l
set carrier_resolution = 'resolved'
where l.carrier_id is not null
  and l.carrier_resolution is null;

-- 2b. unresolved loads: record the classification only (carrier_id stays
-- NULL). Never true for a pre-existing row (see the resolution CASE above).
update public.loads l
set carrier_resolution = 'unresolved'
from _mig0133_plan p
where l.id = p.load_id
  and not p.pre_existing
  and p.resolution = 'unresolved'
  and l.carrier_resolution is null;

-- 2c. one exception row per unresolved load (idempotent via the helper)
do $mig$
declare
  r record;
begin
  for r in
    select p.load_id, p.load_org, p.rule_applied, p.unresolved_reason, p.disp_detail
    from _mig0133_plan p
    where not p.pre_existing and p.resolution = 'unresolved'
  loop
    perform public.record_unresolved_carrier_record(
      r.load_org,
      'load',
      r.load_id,
      coalesce(r.unresolved_reason, 'Carrier could not be determined for this load.'),
      jsonb_build_object('rule', r.rule_applied, 'dispatches', r.disp_detail)
    );
  end loop;
end
$mig$;

-- 2d. Permanent provenance -- ONE row per FRESHLY-RESOLVED load ONLY.
-- PRE_EXISTING rows are deliberately EXCLUDED (`where not p.pre_existing`)
-- -- this is what makes ROLLBACK_0133 (which acts strictly off this table)
-- structurally unable to ever touch an assignment 0133 did not itself make
-- (correction: "0132 -> 0133 deployment race" / rollback provenance).
-- Written from the SAME plan used for 2a/2b/2c, in the SAME transaction, so
-- it is guaranteed consistent with what was actually applied. now() is
-- transaction-stable, so applied_at here equals any carrier_locked_at set
-- above. Never written to again after this migration commits.
create table public.carrier_backfill_0133_provenance (
  load_id                        uuid primary key references public.loads (id) on delete cascade,
  organization_id                uuid not null references public.organizations (id) on delete cascade,
  carrier_id                     uuid,
  carrier_resolution             text not null check (carrier_resolution in ('resolved','backfilled','unresolved')),
  carrier_locked_at              timestamptz,
  unresolved_carrier_record_id   uuid references public.unresolved_carrier_records (id) on delete set null,
  applied_at                     timestamptz not null default now()
);

comment on table public.carrier_backfill_0133_provenance is
  'Permanent, immutable-after-insert record of exactly what migration 0133 wrote for each FRESHLY-RESOLVED load (a load whose carrier_id was NULL before 0133 ran): the resolution, the carrier_id/carrier_resolution/carrier_locked_at values, and (for an unresolved load) its exception-row id. A load whose carrier_id was ALREADY set before 0133 ran (PRE_EXISTING) has NO row here by design, so a rollback can never touch it. The ONLY reliable way a later emergency rollback can prove a load''s carrier fields have not been touched by anything else since 0133 ran before reversing them. Select-only for the app; removed only by a full, successful ROLLBACK_0133.';

alter table public.carrier_backfill_0133_provenance enable row level security;

create policy carrier_backfill_0133_provenance_select on public.carrier_backfill_0133_provenance
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','accountant']::public.org_role[])
  );
-- No INSERT/UPDATE/DELETE policy for authenticated: written once by this
-- migration; removed only by ROLLBACK_0133 (both run as the table owner).

revoke all on public.carrier_backfill_0133_provenance from anon;
grant select on public.carrier_backfill_0133_provenance to authenticated;

insert into public.carrier_backfill_0133_provenance
  (load_id, organization_id, carrier_id, carrier_resolution, carrier_locked_at, unresolved_carrier_record_id)
select
  p.load_id,
  p.load_org,
  p.resolved_carrier_id,
  p.resolution,
  (case when p.rule_applied = 'C1_financial_controller' then now() else null end),
  u.id
from _mig0133_plan p
left join public.unresolved_carrier_records u
  on u.record_type = 'load' and u.record_id = p.load_id and u.status = 'unresolved'
where not p.pre_existing;

-- ======================= PHASE 3 -- POSTCONDITIONS + MARKER ================
do $mig$
declare
  b record;
  v_n integer;
begin
  select * into b from _mig0133_counts;

  -- every existing load now has a carrier_resolution value
  select count(*) into v_n from public.loads where carrier_resolution is null;
  if v_n <> 0 then
    raise exception '0133 postcondition: % load(s) still have carrier_resolution = NULL.', v_n;
  end if;

  -- freshly-resolved C1: carrier_id set, locked_at set, carrier org matches, matches fdi carrier
  select count(*) into v_n
  from public.loads l join _mig0133_plan p on p.load_id = l.id
  where p.rule_applied = 'C1_financial_controller'
    and (l.carrier_id is distinct from p.resolved_carrier_id
         or l.carrier_locked_at is null
         or l.carrier_resolution <> 'resolved'
         or (select organization_id from public.carriers where id = l.carrier_id) <> l.organization_id
         or l.carrier_id is distinct from (select d.carrier_id from public.dispatches d where d.id = l.financial_dispatch_id));
  if v_n <> 0 then raise exception '0133 postcondition: % C1/resolved load(s) failed re-validation.', v_n; end if;

  -- freshly-backfilled C2/C3: carrier_id set, carrier org matches, carrier_locked_at NULL
  select count(*) into v_n
  from public.loads l join _mig0133_plan p on p.load_id = l.id
  where p.rule_applied in ('C2_sole_noncancelled_carrier','C3_sole_cancelled_carrier')
    and (l.carrier_id is distinct from p.resolved_carrier_id
         or l.carrier_resolution <> 'backfilled'
         or l.carrier_locked_at is not null
         or (select organization_id from public.carriers where id = l.carrier_id) <> l.organization_id);
  if v_n <> 0 then raise exception '0133 postcondition: % C2/C3/backfilled load(s) failed re-validation.', v_n; end if;

  -- freshly-unresolved C4: carrier_id NULL + exactly one OPEN exception row
  select count(*) into v_n
  from public.loads l join _mig0133_plan p on p.load_id = l.id
  where not p.pre_existing and p.resolution = 'unresolved'
    and (l.carrier_id is not null
         or l.carrier_resolution <> 'unresolved'
         or not exists (
           select 1 from public.unresolved_carrier_records u
           where u.record_type='load' and u.record_id = l.id and u.status='unresolved'
                 and u.organization_id = l.organization_id));
  if v_n <> 0 then raise exception '0133 postcondition: % unresolved load(s) missing carrier_id=NULL or an OPEN exception row.', v_n; end if;

  -- PRE_EXISTING: byte-for-byte unchanged vs the PHASE 0 snapshot, carrier_resolution filled if it was NULL
  select count(*) into v_n
  from public.loads l
  join _mig0133_preexisting_snap s on s.load_id = l.id
  where l.carrier_id is distinct from s.carrier_id
     or l.carrier_locked_at is distinct from s.carrier_locked_at
     or l.carrier_resolution is null
     or (s.carrier_resolution is not null and l.carrier_resolution is distinct from s.carrier_resolution);
  if v_n <> 0 then
    raise exception '0133 postcondition: % PRE-EXISTING load(s) were modified by this migration -- carrier_id/carrier_locked_at must be byte-for-byte unchanged and carrier_resolution must only ever be filled, never overwritten.', v_n;
  end if;
  -- PRE_EXISTING rows must NEVER appear in the rollback provenance table
  select count(*) into v_n
  from _mig0133_preexisting_snap s
  join public.carrier_backfill_0133_provenance pv on pv.load_id = s.load_id;
  if v_n <> 0 then
    raise exception '0133 postcondition: % PRE-EXISTING load(s) were incorrectly recorded in carrier_backfill_0133_provenance -- a rollback must never be able to touch them.', v_n;
  end if;

  -- exactly (freshly-unresolved load count) new rows, all record_type='load', all OPEN
  if (select count(*) from public.unresolved_carrier_records) - b.n_ucr_start
     <> (select count(*) from _mig0133_plan where not pre_existing and resolution='unresolved') then
    raise exception '0133 postcondition: unresolved_carrier_records delta (%) <> freshly-unresolved load count (%).',
      (select count(*) from public.unresolved_carrier_records) - b.n_ucr_start,
      (select count(*) from _mig0133_plan where not pre_existing and resolution='unresolved');
  end if;
  -- every OPEN 'load' exception row corresponds to a planned-unresolved load
  select count(*) into v_n
  from public.unresolved_carrier_records u
  where u.record_type = 'load' and u.status = 'unresolved'
    and not exists (select 1 from _mig0133_plan p where p.load_id = u.record_id and not p.pre_existing and p.resolution = 'unresolved');
  if v_n <> 0 then
    raise exception '0133 postcondition: % OPEN load exception row(s) do not map to a planned-unresolved load.', v_n;
  end if;

  -- provenance: exactly one row per FRESHLY-RESOLVED load (never pre-existing), and it matches the CURRENT row
  if (select count(*) from public.carrier_backfill_0133_provenance) <> (select count(*) from _mig0133_plan where not pre_existing) then
    raise exception '0133 postcondition: carrier_backfill_0133_provenance has % rows, expected one per freshly-resolved load (%).',
      (select count(*) from public.carrier_backfill_0133_provenance), (select count(*) from _mig0133_plan where not pre_existing);
  end if;
  select count(*) into v_n
  from public.loads l
  join public.carrier_backfill_0133_provenance pv on pv.load_id = l.id
  where l.carrier_id is distinct from pv.carrier_id
     or l.carrier_resolution is distinct from pv.carrier_resolution
     or l.carrier_locked_at is distinct from pv.carrier_locked_at
     or l.organization_id is distinct from pv.organization_id;
  if v_n <> 0 then
    raise exception '0133 postcondition: % provenance row(s) do not match the load row they describe.', v_n;
  end if;
  select count(*) into v_n
  from public.carrier_backfill_0133_provenance pv
  where pv.carrier_resolution = 'unresolved'
    and not exists (
      select 1 from public.unresolved_carrier_records u
      where u.id = pv.unresolved_carrier_record_id and u.record_type='load' and u.record_id = pv.load_id and u.status='unresolved');
  if v_n <> 0 then
    raise exception '0133 postcondition: % unresolved provenance row(s) do not reference a valid OPEN exception row.', v_n;
  end if;
  if exists (select 1 from public.carrier_backfill_0133_provenance where carrier_resolution <> 'unresolved' and unresolved_carrier_record_id is not null) then
    raise exception '0133 postcondition: a resolved/backfilled provenance row unexpectedly references an exception row.';
  end if;

  -- financial_dispatch_id untouched
  if exists (
    select 1 from public.loads l join _mig0133_fdi_snap s on s.id = l.id
    where l.financial_dispatch_id is distinct from s.financial_dispatch_id
  ) then
    raise exception '0133 postcondition: a loads.financial_dispatch_id value changed.';
  end if;

  -- protected counts preserved
  if (select count(*) from public.loads)                <> b.n_load       then raise exception '0133 postcondition: loads count changed.'; end if;
  if (select count(*) from public.dispatches)           <> b.n_dispatch   then raise exception '0133 postcondition: dispatches count changed.'; end if;
  if (select count(*) from public.invoices)             <> b.n_invoice    then raise exception '0133 postcondition: invoices count changed.'; end if;
  if (select count(*) from public.invoice_line_items)   <> b.n_invoice_li then raise exception '0133 postcondition: invoice_line_items count changed.'; end if;
  if (select count(*) from public.payments)             <> b.n_payment    then raise exception '0133 postcondition: payments count changed.'; end if;
  if (select count(*) from public.settlements)          <> b.n_settlement then raise exception '0133 postcondition: settlements count changed.'; end if;
  if (select count(*) from public.settlement_line_items) <> b.n_sli       then raise exception '0133 postcondition: settlement_line_items count changed.'; end if;
  if (select count(*) from public.trailers)             <> b.n_trailer    then raise exception '0133 postcondition: trailers count changed.'; end if;

  -- auto-invoice function untouched
  if (select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) ilike '%carrier_id%' then
    raise exception '0133 postcondition: auto_generate_invoice_from_delivered_load() now references carrier_id -- not this migration''s job.';
  end if;

  -- set the rerun comment marker
  execute format(
    'comment on column public.loads.carrier_id is %L',
    'The single responsible carrier for this load. Set for new loads by the load-creation RPC (later slice); legacy loads backfilled by migration 0133 on '
    || current_date::text
    || ' (financial_dispatch_id -> dispatch carrier; else unambiguous dispatch carrier; else NULL + unresolved_carrier_records; a pre-existing assignment made between 0132 and 0133 is validated and preserved untouched). Immutable while the load has dispatches / financial activity -- see guard_load_carrier_change().'
  );

  raise notice '0133 complete: % load(s) had a PRE-EXISTING carrier_id (validated, preserved, NOT in rollback provenance); carrier_id freshly set on % load(s) (% resolved via controller, % backfilled from an unambiguous dispatch carrier); % load(s) left unresolved with an exception row; % provenance row(s) recorded for a future rollback. No dispatch/invoice/payment/settlement/financial_dispatch_id data modified.',
    (select count(*) from _mig0133_plan where pre_existing),
    (select count(*) from _mig0133_plan where not pre_existing and resolution <> 'unresolved'),
    (select count(*) from _mig0133_plan where rule_applied='C1_financial_controller'),
    (select count(*) from _mig0133_plan where rule_applied in ('C2_sole_noncancelled_carrier','C3_sole_cancelled_carrier')),
    (select count(*) from _mig0133_plan where not pre_existing and resolution='unresolved'),
    (select count(*) from public.carrier_backfill_0133_provenance);
end
$mig$;

commit;
