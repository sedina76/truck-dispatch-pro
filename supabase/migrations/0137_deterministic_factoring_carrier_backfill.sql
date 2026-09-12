-- =============================================================================
-- 0137_deterministic_factoring_carrier_backfill.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0136 live. Phase 3B.1, part 2 of 3. The ONLY data migration in
-- this phase -- mirrors 0133's own posture exactly (deterministic-carrier-
-- backfill.sql): NEVER GUESS. Every factoring_relationships.carrier_id was
-- added NULL by 0136 and stays null here unless a resolution rule below
-- proves a single, unambiguous answer.
--
-- Since carrier_id is BRAND NEW (0136 added it; nothing has written to it
-- yet), this migration is structurally simpler than 0133 -- there is no
-- "PRE_EXISTING value written by something else" case to validate around;
-- every row this migration touches starts from NULL.
--
-- RESOLUTION (first rule that yields a single answer):
--   R1 single_carrier_org        : the relationship's organization has
--                                  EXACTLY ONE carrier row (any status) ->
--                                  that carrier. Not a "guess" -- there is
--                                  no other value it could possibly be.
--   R2 multi_carrier_org_provable: the organization has 2+ carriers, but
--                                  every factored_invoices row citing this
--                                  relationship resolves (via its invoice's
--                                  dispatch_id -> dispatches.carrier_id, or
--                                  load_id -> loads.carrier_id) to EXACTLY
--                                  ONE distinct carrier_id -> that carrier.
--   R3 unresolved_no_evidence    : organization has 2+ carriers and this
--                                  relationship has NO factored_invoices
--                                  evidence at all (or none with a
--                                  resolvable carrier). carrier_id stays
--                                  NULL; recorded in
--                                  unresolved_carrier_records.
--   R4 unresolved_multiple       : organization has 2+ carriers and this
--                                  relationship's evidence resolves to 2+
--                                  DISTINCT carrier_ids (used across more
--                                  than one carrier's invoices over time --
--                                  genuinely ambiguous, not a data error).
--                                  carrier_id stays NULL; recorded in
--                                  unresolved_carrier_records.
--
-- ABORT (RAISE -> full rollback, ZERO writes) -- structural blockers, never
-- silently classified as merely "unresolved" (same posture as 0133's C1
-- controller-conflict abort):
--   * a SINGLE factored_invoices row's own invoice resolves to DIFFERENT
--     carriers via dispatch_id vs. load_id (should be structurally
--     impossible given guard_dispatch_carrier_scope, 0132 -- reported and
--     aborted, never guessed past)
--   * more than one factoring_relationships row org-wide currently has
--     is_default = true and is_active = true (should be structurally
--     impossible given 0071's own partial unique index -- a defensive
--     re-check, not something this migration expects to ever actually see)
--   * carrier_id column is not all-NULL (rerun guard / 0136 not actually
--     the immediately-preceding state)
--
-- INFORMATIONAL ONLY (never blocks backfill; recorded in the preflight/
-- post-apply report so 0138's classifier and a human reviewer both know
-- what to expect): expired relationships (effective_to < current_date),
-- relationships whose factoring_company.is_active = false, and every row's
-- "incomplete new fields" state (remittance/NOA/submission-method columns
-- 0136 added are NULLABLE and blank on every pre-existing row -- expected,
-- not a defect; an owner/admin fills them in later, gated by 0136's
-- protected-fields guard).
--
-- Historical funded factored invoices are NEVER touched, recalculated, or
-- rewritten by this migration -- it writes ONLY factoring_relationships.
-- carrier_id (plus its own provenance/exception rows). Every numeric
-- snapshot on factored_invoices remains byte-for-byte what it already was.
-- =============================================================================

begin;

-- ======================= PHASE 0 -- READ-ONLY PREFLIGHT REPORT ==============
-- Printed via RAISE NOTICE so it is visible in the apply log even though
-- this whole migration is one transaction -- mirrors 0133's own PHASE 0.
do $mig$
declare
  v_total int;
  v_single_org int;
  v_multi_provable int;
  v_multi_no_evidence int;
  v_multi_ambiguous int;
  v_expired int;
  v_inactive_company int;
begin
  if to_regclass('public.factoring_relationships') is null then
    raise exception '0137 precondition: public.factoring_relationships missing -- apply 0071 first. STOP.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id') then
    raise exception '0137 precondition: factoring_relationships.carrier_id missing -- apply 0136 first. STOP.';
  end if;
  if (select count(*) from public.factoring_relationships where carrier_id is not null) <> 0 then
    raise exception '0137 precondition: factoring_relationships.carrier_id is not all-NULL -- 0137 already applied, or something else has written to it. STOP.';
  end if;
  if to_regclass('public.carrier_backfill_0137_provenance') is not null then
    raise exception '0137 precondition: table public.carrier_backfill_0137_provenance already exists -- partial apply? STOP.';
  end if;

  -- Structural blocker: more than one org-wide active default (should be
  -- impossible given 0071's own index -- defensive re-check).
  if exists (
    select organization_id from public.factoring_relationships
    where is_default and is_active
    group by organization_id having count(*) > 1
  ) then
    raise exception '0137 precondition ABORT: more than one active default factoring_relationships row exists for the same organization -- structurally impossible under 0071''s own unique index; investigate before proceeding. STOP.';
  end if;

  select count(*) into v_total from public.factoring_relationships;
  select count(*) into v_expired from public.factoring_relationships where effective_to is not null and effective_to < current_date;
  select count(*) into v_inactive_company from public.factoring_relationships fr
    join public.factoring_companies fc on fc.id = fr.factoring_company_id where not fc.is_active;

  raise notice '0137 PHASE 0: % total factoring_relationships row(s), % expired (effective_to < today, informational only), % under an inactive factoring company (informational only).', v_total, v_expired, v_inactive_company;
  raise notice '0137 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 1 -- BUILD THE PLAN (temp table) ============
create temporary table _mig0137_plan (
  relationship_id uuid primary key,
  organization_id uuid not null,
  org_carrier_count int not null,
  evidence_carrier_ids uuid[] not null,
  evidence_count int not null,
  has_internal_conflict boolean not null,
  resolved_carrier_id uuid,
  resolution text not null
) on commit drop;

with org_carrier_counts as (
  select organization_id, count(*) as n_carriers
  from public.carriers
  group by organization_id
),
-- Per (relationship, factored_invoice) resolved carrier, and whether that
-- SINGLE invoice's own dispatch-derived and load-derived carriers disagree
-- (a structural impossibility this migration refuses to guess past).
invoice_evidence as (
  select
    fr.id as relationship_id,
    fi.id as factored_invoice_id,
    d.carrier_id as dispatch_carrier_id,
    l.carrier_id as load_carrier_id,
    (d.carrier_id is not null and l.carrier_id is not null and d.carrier_id <> l.carrier_id) as internal_conflict,
    coalesce(d.carrier_id, l.carrier_id) as resolved_invoice_carrier_id
  from public.factoring_relationships fr
  join public.factored_invoices fi on fi.factoring_relationship_id = fr.id
  join public.invoices i on i.id = fi.invoice_id
  left join public.dispatches d on d.id = i.dispatch_id
  left join public.loads l on l.id = i.load_id
),
per_relationship as (
  select
    fr.id as relationship_id,
    fr.organization_id,
    coalesce(occ.n_carriers, 0) as org_carrier_count,
    coalesce(array_agg(distinct ie.resolved_invoice_carrier_id) filter (where ie.resolved_invoice_carrier_id is not null), '{}'::uuid[]) as evidence_carrier_ids,
    coalesce(bool_or(ie.internal_conflict), false) as has_internal_conflict
  from public.factoring_relationships fr
  left join org_carrier_counts occ on occ.organization_id = fr.organization_id
  left join invoice_evidence ie on ie.relationship_id = fr.id
  group by fr.id, fr.organization_id, occ.n_carriers
)
insert into _mig0137_plan (relationship_id, organization_id, org_carrier_count, evidence_carrier_ids, evidence_count, has_internal_conflict, resolved_carrier_id, resolution)
select
  pr.relationship_id,
  pr.organization_id,
  pr.org_carrier_count,
  pr.evidence_carrier_ids,
  coalesce(array_length(pr.evidence_carrier_ids, 1), 0),
  pr.has_internal_conflict,
  case
    when pr.org_carrier_count = 1 then (select id from public.carriers where organization_id = pr.organization_id limit 1)
    when array_length(pr.evidence_carrier_ids, 1) = 1 then pr.evidence_carrier_ids[1]
    else null
  end,
  case
    when pr.org_carrier_count = 1 then 'single_carrier_org'
    when array_length(pr.evidence_carrier_ids, 1) = 1 then 'multi_carrier_org_provable'
    when coalesce(array_length(pr.evidence_carrier_ids, 1), 0) = 0 then 'unresolved_no_evidence'
    else 'unresolved_multiple'
  end
from per_relationship pr;

-- Structural abort: any single invoice's own dispatch-vs-load carrier
-- disagreement. Reported by relationship_id so it can be corrected
-- out-of-band (matches 0133's C1 controller-conflict abort posture
-- exactly: fail closed, name the row, never guess past it).
do $mig$
declare v_n int; v_ids uuid[];
begin
  select count(*), array_agg(relationship_id) into v_n, v_ids from _mig0137_plan where has_internal_conflict;
  if v_n > 0 then
    raise exception '0137 ABORT: % factoring_relationships row(s) have a factored_invoice whose own dispatch-derived and load-derived carrier disagree (structurally impossible under 0132''s guards) -- relationship_id(s): %. Correct out-of-band and rerun. STOP.', v_n, v_ids;
  end if;
end
$mig$;

-- ======================= PHASE 2 -- APPLY THE PLAN ==========================

update public.factoring_relationships fr
set carrier_id = p.resolved_carrier_id
from _mig0137_plan p
where p.relationship_id = fr.id and p.resolved_carrier_id is not null;

-- Record every UNRESOLVED relationship via the SAME audited entry point
-- 0130 established (record_unresolved_carrier_record) -- record_type=
-- 'factoring_relationship' was already reserved for exactly this in 0130's
-- own CHECK constraint. Runs as a migration/service context (auth.uid() is
-- null inside this transaction), which record_unresolved_carrier_record()
-- already trusts, matching 0133's own usage.
do $mig$
declare
  v_row record;
begin
  for v_row in select * from _mig0137_plan where resolved_carrier_id is null loop
    perform public.record_unresolved_carrier_record(
      v_row.organization_id,
      'factoring_relationship',
      v_row.relationship_id,
      case
        when v_row.resolution = 'unresolved_no_evidence' then 'Factoring relationship carrier ownership could not be determined: organization has multiple carriers and no factored-invoice evidence links this relationship to exactly one of them.'
        else 'Factoring relationship carrier ownership could not be determined: organization has multiple carriers and this relationship''s factored-invoice evidence points to more than one carrier.'
      end,
      jsonb_build_object(
        'org_carrier_count', v_row.org_carrier_count,
        'evidence_carrier_ids', to_jsonb(v_row.evidence_carrier_ids),
        'resolution', v_row.resolution
      )
    );
  end loop;
end
$mig$;

-- Permanent, immutable-after-insert provenance -- ONE row per relationship
-- this migration actually touched (resolved_carrier_id is not null) OR
-- recorded as unresolved. Nothing here is ever updated again after commit;
-- ROLLBACK_0137 acts strictly off this table, so it can only ever undo
-- exactly what 0137 itself did.
create table public.carrier_backfill_0137_provenance (
  relationship_id              uuid primary key references public.factoring_relationships (id) on delete cascade,
  organization_id              uuid not null references public.organizations (id) on delete cascade,
  carrier_id                   uuid,
  resolution                   text not null check (resolution in ('single_carrier_org','multi_carrier_org_provable','unresolved_no_evidence','unresolved_multiple')),
  evidence_carrier_ids         uuid[] not null default '{}'::uuid[],
  unresolved_carrier_record_id uuid references public.unresolved_carrier_records (id) on delete set null,
  applied_at                   timestamptz not null default now()
);

comment on table public.carrier_backfill_0137_provenance is
  'Permanent record of exactly what migration 0137 wrote (or deliberately left unresolved) for every factoring_relationships row. Select-only for the app; removed only by a full, successful ROLLBACK_0137.';

alter table public.carrier_backfill_0137_provenance enable row level security;

create policy carrier_backfill_0137_provenance_select on public.carrier_backfill_0137_provenance
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','accountant']::public.org_role[])
  );

-- Phase 3B.1 item 9: Supabase's default privilege configuration (ALTER
-- DEFAULT PRIVILEGES ... GRANT ... TO authenticated, faithfully reproduced
-- in TEST_SUPPORT) means a freshly-CREATEd table inherits INSERT/UPDATE/
-- DELETE for authenticated automatically, regardless of what this
-- migration explicitly grants afterward. RLS-enabled-with-no-write-policy
-- (0133's own precedent for its provenance table) already makes those
-- writes a no-op via RLS's implicit deny-when-no-policy-matches, but this
-- migration closes the gap explicitly rather than relying on that alone --
-- both layers now agree, and has_table_privilege() itself (not just "does
-- a write actually go through") reports the true, intended state.
revoke all on public.carrier_backfill_0137_provenance from anon;
revoke insert, update, delete on public.carrier_backfill_0137_provenance from authenticated;
grant select on public.carrier_backfill_0137_provenance to authenticated;

insert into public.carrier_backfill_0137_provenance
  (relationship_id, organization_id, carrier_id, resolution, evidence_carrier_ids, unresolved_carrier_record_id)
select
  p.relationship_id,
  p.organization_id,
  p.resolved_carrier_id,
  p.resolution,
  p.evidence_carrier_ids,
  u.id
from _mig0137_plan p
left join public.unresolved_carrier_records u
  on u.record_type = 'factoring_relationship' and u.record_id = p.relationship_id and u.status = 'unresolved';

-- ======================= PHASE 3 -- POSTCONDITIONS + REPORT =================
do $mig$
declare
  v_resolved int;
  v_unresolved int;
  v_single_org int;
  v_multi_provable int;
begin
  select count(*) into v_resolved from public.factoring_relationships where carrier_id is not null;
  select count(*) into v_unresolved from public.factoring_relationships where carrier_id is null;
  select count(*) into v_single_org from public.carrier_backfill_0137_provenance where resolution = 'single_carrier_org';
  select count(*) into v_multi_provable from public.carrier_backfill_0137_provenance where resolution = 'multi_carrier_org_provable';

  if (select count(*) from public.carrier_backfill_0137_provenance) <> (select count(*) from public.factoring_relationships) then
    raise exception '0137 postcondition: provenance row count does not match factoring_relationships row count -- every row must have exactly one provenance entry.';
  end if;
  if exists (
    select 1 from public.carrier_backfill_0137_provenance pv
    join public.factoring_relationships fr on fr.id = pv.relationship_id
    where (pv.carrier_id is null) <> (fr.carrier_id is null) or pv.carrier_id is distinct from fr.carrier_id
  ) then
    raise exception '0137 postcondition: a provenance row disagrees with the actual factoring_relationships.carrier_id it describes.';
  end if;
  if exists (
    select 1 from public.carrier_backfill_0137_provenance pv
    where pv.resolution in ('unresolved_no_evidence','unresolved_multiple') and pv.unresolved_carrier_record_id is null
  ) then
    raise exception '0137 postcondition: an unresolved relationship has no matching unresolved_carrier_records row.';
  end if;

  raise notice '0137 complete: % of % factoring_relationships row(s) resolved (% via single-carrier-org, % via multi-carrier provable invoice evidence); % left unresolved (carrier_id null, recorded in unresolved_carrier_records). No factored_invoices row was touched -- every historical numeric snapshot is unchanged.', v_resolved, (v_resolved + v_unresolved), v_single_org, v_multi_provable, v_unresolved;
end
$mig$;

commit;
