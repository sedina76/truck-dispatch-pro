-- ============================================================================
-- PRODUCTION_AUDIT_factoring_readiness_READONLY.sql
--
-- Phase 3B.1.1 (item 5). 100% READ-ONLY. Run this directly against
-- production (or any real environment) at any time, in any order relative
-- to 0136-0139:
--   * BEFORE 0136-0139 are applied: every "new schema" section below
--     detects the columns/tables don't exist yet and reports the
--     PREVIEW mapping (mirroring 0137's own resolution algorithm exactly,
--     computed live from the CURRENT schema -- factoring_relationships,
--     factored_invoices, invoices, dispatches, loads, carriers) instead of
--     reading a column that isn't there yet.
--   * AFTER 0136-0139 are applied: the same sections read the real,
--     already-backfilled columns/tables directly.
--
-- GUARANTEES:
--   * No INSERT / UPDATE / DELETE / DDL anywhere in this file.
--   * No call to any function that writes, or that is documented as
--     having a side effect (record_unresolved_carrier_record(),
--     set_default_factoring_relationship(), set_carrier_factoring_policy(),
--     approve_factoring_relationship_noa(), activate_carrier_party(), etc.
--     are never invoked here).
--   * No temporary table is created -- every computation is a plain SELECT
--     / CTE, so nothing is written even to session-local storage.
--   * Every dynamic lookup uses to_regclass()/information_schema before
--     touching a table/column, so this script cannot itself error out on
--     an environment where 0136-0139 are (or are not yet) applied.
--
-- This script's own output is the ONLY thing that may turn a "Production
-- ... : unknown / not established" statement in the Phase 3B.1.1 report
-- into an actual number. Nobody should paraphrase or assume its result --
-- run it and read the NOTICEs.
--
-- Phase 3B.1.2 (Section C) hardening: wrapped in an explicit transaction
-- with `SET TRANSACTION READ ONLY` -- Postgres itself then rejects any
-- INSERT/UPDATE/DELETE/DDL/sequence-advancing call at the engine level for
-- the rest of this transaction, regardless of what this file's own SQL
-- text does or a future edit might accidentally introduce. Ends in
-- ROLLBACK (never COMMIT) as the strongest possible "definitely wrote
-- nothing" signal, even though a read-only transaction cannot commit a
-- write in the first place.
-- ============================================================================

begin;
set transaction isolation level read committed, read only;

do $audit$
declare
  v_has_factoring_mode        boolean;
  v_has_carrier_id            boolean;
  v_has_relationship_fields   boolean;  -- remittance/NOA/submission_method (0136)
  v_has_cfi                   boolean;  -- carrier_factoring_integrations (0139)

  v_total_carriers            int;
  v_carriers_unconfigured     int;
  v_carriers_direct           int;
  v_carriers_factored         int;

  v_total_companies           int;
  v_inactive_companies        int;
  v_relationships_under_inactive_company int;

  v_total_relationships       int;
  v_relationships_no_carrier  int;

  v_deterministic_mappings    int;  -- single_carrier_org + multi_carrier_org_provable
  v_single_carrier_org        int;
  v_multi_carrier_provable    int;
  v_ambiguous_mappings        int;  -- unresolved_multiple
  v_no_evidence_mappings      int;  -- unresolved_no_evidence
  v_structural_conflicts      int;  -- a single factored_invoice's dispatch-vs-load carrier disagree

  v_active_default_conflicts  int;  -- >1 active+default row per scope (org pre-cutover, carrier post-cutover)
  v_expired_defaults          int;

  v_incomplete_terms          int;
  v_missing_noa               int;
  v_missing_remittance        int;
  v_submission_method_counts  jsonb;

  v_missing_integration_config int;
  v_structural_conflict_ids   uuid[];
  v_rec record;
begin
  raise notice '================================================================';
  raise notice 'PRODUCTION FACTORING READINESS AUDIT -- READ ONLY -- run at %', now();
  raise notice '================================================================';

  ---------------------------------------------------------------------------
  -- 0. which schema state are we looking at?
  ---------------------------------------------------------------------------
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='factoring_mode') into v_has_factoring_mode;
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id') into v_has_carrier_id;
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='submission_method') into v_has_relationship_fields;
  select (to_regclass('public.carrier_factoring_integrations') is not null) into v_has_cfi;

  raise notice '0136 applied (carriers.factoring_mode / relationship remittance+NOA+submission columns present)? %', v_has_factoring_mode;
  raise notice '0137 applied (factoring_relationships.carrier_id backfilled)? %', v_has_carrier_id;
  raise notice '0139 applied (carrier_factoring_integrations present)? %', v_has_cfi;

  ---------------------------------------------------------------------------
  -- 1-2. total carriers / carriers by policy
  ---------------------------------------------------------------------------
  select count(*) into v_total_carriers from public.carriers;

  if v_has_factoring_mode then
    execute 'select count(*) filter (where factoring_mode = ''unconfigured''), count(*) filter (where factoring_mode = ''direct''), count(*) filter (where factoring_mode = ''factored'') from public.carriers'
      into v_carriers_unconfigured, v_carriers_direct, v_carriers_factored;
  end if;

  raise notice '--- 1-2. CARRIERS ---';
  raise notice 'Total carriers: %', v_total_carriers;
  if v_has_factoring_mode then
    raise notice 'Carriers by factoring policy: unconfigured=% / direct=% / factored=%', v_carriers_unconfigured, v_carriers_direct, v_carriers_factored;
  else
    raise notice 'Carriers by factoring policy: N/A -- 0136 not yet applied (carriers.factoring_mode does not exist). Every existing carrier will become ''unconfigured'' the moment 0136 applies (never ''direct'', per Phase 3B.1.1 item 1).';
  end if;

  ---------------------------------------------------------------------------
  -- 3. total factoring companies + inactive companies
  ---------------------------------------------------------------------------
  select count(*) into v_total_companies from public.factoring_companies;
  select count(*) into v_inactive_companies from public.factoring_companies where not is_active;
  select count(*) into v_relationships_under_inactive_company
    from public.factoring_relationships fr join public.factoring_companies fc on fc.id = fr.factoring_company_id
    where not fc.is_active;

  raise notice '--- 3. FACTORING COMPANIES ---';
  raise notice 'Total factoring companies: % (% inactive)', v_total_companies, v_inactive_companies;
  raise notice 'Relationships pointing at an inactive company: %', v_relationships_under_inactive_company;

  ---------------------------------------------------------------------------
  -- 4-5. total relationships / relationships lacking carrier ownership
  ---------------------------------------------------------------------------
  select count(*) into v_total_relationships from public.factoring_relationships;

  if v_has_carrier_id then
    execute 'select count(*) from public.factoring_relationships where carrier_id is null' into v_relationships_no_carrier;
  else
    v_relationships_no_carrier := v_total_relationships; -- the column does not exist yet -- every row is, by definition, not yet carrier-owned
  end if;

  raise notice '--- 4-5. FACTORING RELATIONSHIPS ---';
  raise notice 'Total factoring relationships: %', v_total_relationships;
  if v_has_carrier_id then
    raise notice 'Relationships lacking carrier ownership (carrier_id IS NULL, already backfilled by 0137): %', v_relationships_no_carrier;
  else
    raise notice 'Relationships lacking carrier ownership: N/A -- 0136/0137 not yet applied, so NONE currently carry a carrier_id at all (%). See the PREVIEW mapping below for what 0137''s deterministic backfill would resolve.', v_relationships_no_carrier;
  end if;

  ---------------------------------------------------------------------------
  -- 6-8. deterministic / ambiguous / structurally-conflicting mappings --
  -- mirrors 0137's own R1-R4 resolution algorithm EXACTLY, computed live
  -- from the CURRENT schema regardless of whether 0137 has run yet (if it
  -- has, this reproduces what it already did, as a live cross-check; if it
  -- has not, this is the actual preview of what it WOULD do).
  ---------------------------------------------------------------------------
  with org_carrier_counts as (
    select organization_id, count(*) as n_carriers from public.carriers group by organization_id
  ),
  invoice_evidence as (
    select
      fr.id as relationship_id,
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
  ),
  classified as (
    select
      pr.*,
      case
        when pr.org_carrier_count = 1 then 'single_carrier_org'
        when array_length(pr.evidence_carrier_ids, 1) = 1 then 'multi_carrier_org_provable'
        when coalesce(array_length(pr.evidence_carrier_ids, 1), 0) = 0 then 'unresolved_no_evidence'
        else 'unresolved_multiple'
      end as resolution
    from per_relationship pr
  )
  select
    count(*) filter (where resolution = 'single_carrier_org'),
    count(*) filter (where resolution = 'multi_carrier_org_provable'),
    count(*) filter (where resolution = 'unresolved_multiple'),
    count(*) filter (where resolution = 'unresolved_no_evidence'),
    count(*) filter (where has_internal_conflict)
  into v_single_carrier_org, v_multi_carrier_provable, v_ambiguous_mappings, v_no_evidence_mappings, v_structural_conflicts
  from classified;

  v_deterministic_mappings := v_single_carrier_org + v_multi_carrier_provable;

  raise notice '--- 6-8. CARRIER-MAPPING PREVIEW (mirrors 0137''s R1-R4 exactly) ---';
  raise notice 'Deterministic relationship mappings (single_carrier_org=% + multi_carrier_org_provable=%): %', v_single_carrier_org, v_multi_carrier_provable, v_deterministic_mappings;
  raise notice 'Ambiguous mappings (evidence points to 2+ distinct carriers -- would stay unresolved, recorded in unresolved_carrier_records): %', v_ambiguous_mappings;
  raise notice 'No-evidence mappings (multi-carrier org, no factored-invoice evidence at all -- would stay unresolved): %', v_no_evidence_mappings;
  raise notice 'STRUCTURAL CONFLICTS (a single factored_invoice''s own dispatch-derived vs. load-derived carrier disagree -- 0137 ABORTS on this, never guesses past it): %', v_structural_conflicts;
  if v_structural_conflicts > 0 then
    -- Identifiers needed for remediation (Section C) -- relationship_id
    -- only, no carrier/customer names, no PII, bounded to 20 -- enough to
    -- go investigate the specific rows without dumping unnecessary data.
    select array_agg(relationship_id order by relationship_id) into v_structural_conflict_ids
    from (
      select distinct fr.id as relationship_id
      from public.factoring_relationships fr
      join public.factored_invoices fi on fi.factoring_relationship_id = fr.id
      join public.invoices i on i.id = fi.invoice_id
      left join public.dispatches d on d.id = i.dispatch_id
      left join public.loads l on l.id = i.load_id
      where d.carrier_id is not null and l.carrier_id is not null and d.carrier_id <> l.carrier_id
      order by fr.id
      limit 20
    ) x;
    raise warning 'STRUCTURAL CONFLICTS > 0 -- 0137 WILL ABORT its entire transaction (zero writes) until every one of these is corrected out-of-band. Do not expect 0137 to apply cleanly until this is 0. Affected relationship_id(s) (up to 20 shown): %', v_structural_conflict_ids;
  end if;

  ---------------------------------------------------------------------------
  -- 9-10. active/default conflicts + expired defaults
  ---------------------------------------------------------------------------
  if v_has_carrier_id then
    -- post-0138 world: the invariant is per-CARRIER.
    execute $q$
      select coalesce(sum(c), 0) from (
        select count(*) as c from public.factoring_relationships
        where is_default and is_active and carrier_id is not null
        group by carrier_id having count(*) > 1
      ) x
    $q$ into v_active_default_conflicts;
  else
    -- pre-0138 world: the invariant is per-ORGANIZATION (0071's own index).
    select coalesce(sum(c), 0) into v_active_default_conflicts from (
      select count(*) as c from public.factoring_relationships
      where is_default and is_active
      group by organization_id having count(*) > 1
    ) x;
  end if;

  select count(*) into v_expired_defaults
  from public.factoring_relationships
  where is_default and effective_to is not null and effective_to < current_date;

  raise notice '--- 9-10. DEFAULT-FACTOR INTEGRITY ---';
  raise notice 'Active/default conflicts (more than one active+default relationship in the same scope -- should always be 0, defensive re-check): %', v_active_default_conflicts;
  raise notice 'Expired defaults (is_default=true but effective_to < today): %', v_expired_defaults;

  ---------------------------------------------------------------------------
  -- 11-14. incomplete terms / missing NOA / missing remittance / submission methods
  ---------------------------------------------------------------------------
  raise notice '--- 11-14. RELATIONSHIP COMPLETENESS ---';
  if v_has_relationship_fields then
    execute 'select count(*) from public.factoring_relationships where coalesce(remittance_instructions, '''') = '''' or not noa_approved or submission_method is null'
      into v_incomplete_terms;
    execute 'select count(*) from public.factoring_relationships where not noa_approved' into v_missing_noa;
    execute 'select count(*) from public.factoring_relationships where coalesce(remittance_instructions, '''') = ''''' into v_missing_remittance;

    v_submission_method_counts := '{}'::jsonb;
    for v_rec in execute 'select coalesce(submission_method::text, ''(none set)'') as m, count(*) as c from public.factoring_relationships group by 1 order by 1'
    loop
      v_submission_method_counts := v_submission_method_counts || jsonb_build_object(v_rec.m, v_rec.c);
    end loop;

    raise notice 'Incomplete terms (missing remittance instructions, or NOA not approved, or no submission method): %', v_incomplete_terms;
    raise notice 'Missing NOA (noa_approved = false): %', v_missing_noa;
    raise notice 'Missing remittance instructions: %', v_missing_remittance;
    raise notice 'Submission methods in use: %', v_submission_method_counts;
  else
    raise notice 'Incomplete terms / missing NOA / missing remittance / submission methods: N/A -- 0136 not yet applied (these columns do not exist yet). Every one of these will start out incomplete/blank the moment 0136 applies -- 0136 adds them all NULLABLE with no data populated, by design.';
  end if;

  ---------------------------------------------------------------------------
  -- 15. missing carrier-specific integration configuration
  ---------------------------------------------------------------------------
  raise notice '--- 15. PER-CARRIER INTEGRATION CONFIGURATION ---';
  if v_has_cfi and v_has_relationship_fields then
    execute $q$
      select count(*) from public.factoring_relationships fr
      where fr.submission_method = 'api'
        and not exists (
          select 1 from public.carrier_factoring_integrations cfi
          where cfi.factoring_relationship_id = fr.id and cfi.is_active and cfi.configuration_status = 'active'
        )
    $q$ into v_missing_integration_config;
    raise notice 'Relationships using submission_method=''api'' with no active/approved carrier_factoring_integrations row: %', v_missing_integration_config;
  else
    raise notice 'Missing carrier-specific integration configuration: N/A -- 0139 not yet applied (carrier_factoring_integrations does not exist yet).';
  end if;

  raise notice '================================================================';
  raise notice 'AUDIT COMPLETE. No row was written, updated, or deleted. No side-effecting function was called.';
  raise notice '================================================================';
end
$audit$;

-- Explicit ROLLBACK -- never COMMIT. The read-only transaction guarantees
-- no write could have occurred above regardless; this makes "ended
-- without writes" true by construction, not by review.
rollback;
