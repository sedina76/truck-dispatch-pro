-- ============================================================================
-- 0133 POST-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No DO block, no transaction control, no RPC execution. Safe on production.
--
-- Run AFTER applying 0133_deterministic_carrier_backfill.sql.
-- Every row of the matrix must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'loads.carrier_id comment now carries the 0133 backfill marker',
      coalesce(col_description('public.loads'::regclass,
        (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='carrier_id' and not attisdropped)),
        '') ilike '%backfilled by migration 0133%'),

  (2, 'EVERY load now has a carrier_resolution value (resolved / backfilled / unresolved)',
      not exists (select 1 from public.loads where carrier_resolution is null)),

  (3, 'carrier_resolution only ever holds the three allowed values',
      not exists (select 1 from public.loads where carrier_resolution not in ('resolved','backfilled','unresolved'))),

  -- ---- resolved (C1) -- SCOPED to loads 0133 ITSELF freshly resolved
  -- (proven by having a carrier_backfill_0133_provenance row). A
  -- PRE-EXISTING load (0132->0133 race, correction #1) may ALSO legitimately
  -- carry carrier_resolution='resolved' with carrier_locked_at left NULL and
  -- no financial_dispatch_id yet -- that is checked separately by check 19,
  -- not here (matching the migration's own PHASE 3, which scopes this
  -- exact check by rule_applied='C1_financial_controller', not by the
  -- resolution label alone).
  (4, 'every FRESHLY-RESOLVED (C1, in provenance) load: carrier_id set, carrier_locked_at set, carrier org = load org',
      not exists (
        select 1 from public.loads l
        join public.carrier_backfill_0133_provenance pv on pv.load_id = l.id
        where l.carrier_resolution = 'resolved'
          and (l.carrier_id is null or l.carrier_locked_at is null
               or (select organization_id from public.carriers where id = l.carrier_id) <> l.organization_id))),
  (5, 'every FRESHLY-RESOLVED (C1, in provenance) load: carrier_id = its financial controller dispatch''s carrier',
      not exists (
        select 1 from public.loads l
        join public.carrier_backfill_0133_provenance pv on pv.load_id = l.id
        where l.carrier_resolution = 'resolved'
          and l.carrier_id is distinct from (select d.carrier_id from public.dispatches d where d.id = l.financial_dispatch_id))),

  -- ---- backfilled (C2 / C3) -- same provenance scoping, same reason ----
  (6, 'every FRESHLY-backfilled (in provenance) load: carrier_id set, carrier_locked_at NULL, carrier org = load org',
      not exists (
        select 1 from public.loads l
        join public.carrier_backfill_0133_provenance pv on pv.load_id = l.id
        where l.carrier_resolution = 'backfilled'
          and (l.carrier_id is null or l.carrier_locked_at is not null
               or (select organization_id from public.carriers where id = l.carrier_id) <> l.organization_id))),
  (7, 'every FRESHLY-backfilled (in provenance) load: carrier_id is the single distinct carrier across its (non-cancelled, else all) dispatches',
      not exists (
        select 1 from public.loads l
        join public.carrier_backfill_0133_provenance pv on pv.load_id = l.id
        where l.carrier_resolution = 'backfilled'
          and l.carrier_id is distinct from coalesce(
            (select case when array_length(array_agg(distinct d.carrier_id),1) = 1 then (array_agg(distinct d.carrier_id))[1] end
               from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'),
            (select case when array_length(array_agg(distinct d.carrier_id),1) = 1 then (array_agg(distinct d.carrier_id))[1] end
               from public.dispatches d where d.load_id = l.id)))),

  -- ---- unresolved (C4) ----
  (8, 'every unresolved load: carrier_id IS NULL',
      not exists (select 1 from public.loads where carrier_resolution = 'unresolved' and carrier_id is not null)),
  (9, 'every unresolved load has exactly one OPEN unresolved_carrier_records row (record_type=load, same org)',
      not exists (
        select 1 from public.loads l
        where l.carrier_resolution = 'unresolved'
          and (select count(*) from public.unresolved_carrier_records u
               where u.record_type='load' and u.record_id=l.id and u.status='unresolved'
                 and u.organization_id=l.organization_id) <> 1)),
  (10, 'every OPEN load exception row maps to a load that is actually carrier_resolution = unresolved',
      not exists (
        select 1 from public.unresolved_carrier_records u
        where u.record_type='load' and u.status='unresolved'
          and not exists (select 1 from public.loads l where l.id = u.record_id and l.carrier_resolution = 'unresolved'))),

  -- ---- no collateral change ----
  (11, 'no load resolved/backfilled to a carrier of a different organization',
      not exists (select 1 from public.loads l join public.carriers c on c.id = l.carrier_id
                  where l.carrier_id is not null and c.organization_id <> l.organization_id)),
  (12, 'auto_generate_invoice_from_delivered_load() body still does NOT reference carrier_id',
      (select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) not ilike '%carrier_id%'),
  (13, '0125/0129/0130/0131/0132 landmarks intact',
      to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is not null
      and exists (select 1 from pg_trigger where tgname='auto_generate_invoice_on_delivery' and tgrelid='public.loads'::regclass and not tgisinternal)
      and to_regclass('public.carrier_remittance_profiles') is not null
      and to_regclass('public.carrier_brokers') is not null
      and to_regprocedure('public.guard_dispatch_carrier_scope()') is not null),
  (14, 'every non-cancelled dispatch of a resolved/backfilled load already shares that load''s carrier (cross-carrier guard will hold)',
      not exists (
        select 1 from public.loads l
        join public.dispatches d on d.load_id = l.id and d.status <> 'cancelled'
        where l.carrier_id is not null and d.carrier_id <> l.carrier_id)),

  -- ---- rollback provenance (correction: ROLLBACK 0133 data-safety review) ----
  -- NOTE: provenance covers ONLY freshly-resolved loads (this run's own
  -- writes) -- a PRE-EXISTING carrier_id assignment is deliberately EXCLUDED
  -- (correction: "0132 -> 0133 deployment race"), so provenance row count is
  -- NOT expected to equal total load count whenever any pre-existing
  -- assignment existed. See checks 19-21 below for that case specifically.
  (15, 'carrier_backfill_0133_provenance exists and never has more rows than there are loads',
      to_regclass('public.carrier_backfill_0133_provenance') is not null
      and (select count(*) from public.carrier_backfill_0133_provenance) <= (select count(*) from public.loads)),
  (16, 'every provenance row matches the load row it describes (carrier_id/resolution/locked_at/org)',
      not exists (
        select 1 from public.loads l
        join public.carrier_backfill_0133_provenance pv on pv.load_id = l.id
        where l.carrier_id is distinct from pv.carrier_id
           or l.carrier_resolution is distinct from pv.carrier_resolution
           or l.carrier_locked_at is distinct from pv.carrier_locked_at
           or l.organization_id is distinct from pv.organization_id)),
  (17, 'every unresolved provenance row references a valid OPEN exception row; no resolved/backfilled row references one',
      not exists (
        select 1 from public.carrier_backfill_0133_provenance pv
        where (pv.carrier_resolution = 'unresolved' and not exists (
                 select 1 from public.unresolved_carrier_records u
                 where u.id = pv.unresolved_carrier_record_id and u.record_type='load'
                   and u.record_id = pv.load_id and u.status='unresolved'))
           or (pv.carrier_resolution <> 'unresolved' and pv.unresolved_carrier_record_id is not null))),
  (18, 'carrier_backfill_0133_provenance has NO write policy for authenticated (select-only)',
      not exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_backfill_0133_provenance' and cmd in ('INSERT','UPDATE','DELETE','ALL'))),

  -- ---- 0132->0133 race: pre-existing carrier_id preservation (correction) ----
  (19, 'every load with a carrier_id but NO provenance row (a pre-existing assignment this run did not make) is internally consistent: same-org, agrees with financial_dispatch_id, agrees with every non-cancelled dispatch -- proving it was validated, not guessed, and confirming it can never be reached by ROLLBACK_0133 (which acts strictly off provenance)',
      not exists (
        select 1 from public.loads l
        where l.carrier_id is not null
          and not exists (select 1 from public.carrier_backfill_0133_provenance pv where pv.load_id = l.id)
          and (
            (select organization_id from public.carriers where id = l.carrier_id) <> l.organization_id
            or (l.financial_dispatch_id is not null
                and (select d.carrier_id from public.dispatches d where d.id = l.financial_dispatch_id) is distinct from l.carrier_id)
            or exists (select 1 from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled' and d.carrier_id <> l.carrier_id)
          ))),

  -- ================================================================
  -- GLOBAL INVARIANTS (correction: "cross-carrier integrity defect" /
  -- "add global post-apply invariants"). These are DATA-LEVEL READINESS
  -- FAILURES, not informational warnings -- any single `f` here means the
  -- database is NOT safe to proceed past this migration, regardless of
  -- whether every earlier check passed. They apply to EVERY load,
  -- unconditionally -- not scoped to provenance or to this run's own writes.
  -- ================================================================
  (20, 'GLOBAL: no resolved load has carrier_id NULL',
      not exists (select 1 from public.loads where carrier_resolution = 'resolved' and carrier_id is null)),
  -- Phase 3A clarification round, item 2 ("C1 controller-conflict
  -- contradiction"): an earlier draft of this migration/verifier pair let a
  -- load remain carrier_resolution='unresolved' WHILE financial_dispatch_id
  -- stayed populated (the "C1_controller_conflict" case) -- an internally
  -- contradictory row that this check then had to carve an exception out
  -- for, which is itself the exact contradiction flagged in review. That
  -- design is GONE: 0133's PHASE 1 now aborts the ENTIRE migration (zero
  -- writes) if any load's financial_dispatch_id is contradicted by a
  -- currently non-cancelled dispatch of a different carrier (see 0133's own
  -- header, "C1 CONTROLLER-CONFLICT" abort, and VERIFY_0133_PREFLIGHT.sql
  -- check 13). Consequently NO load can ever emerge from a successful 0133
  -- run in that state -- this is now a STRICT, UNCONDITIONAL invariant with
  -- no carve-out, exactly as the correction requested.
  (21, 'GLOBAL: no unresolved load has a non-NULL financial_dispatch_id (unconditional -- 0133 aborts rather than ever writing this combination; see 0133 header + VERIFY_0133_PREFLIGHT check 13)',
      not exists (
        select 1 from public.loads l
        where l.carrier_resolution = 'unresolved'
          and l.financial_dispatch_id is not null)),
  (22, 'GLOBAL: every load''s financial-controller-dispatch carrier equals loads.carrier_id (when both are set)',
      not exists (
        select 1 from public.loads l
        where l.carrier_id is not null and l.financial_dispatch_id is not null
          and (select d.carrier_id from public.dispatches d where d.id = l.financial_dispatch_id) is distinct from l.carrier_id)),
  (23, 'GLOBAL: every non-cancelled dispatch''s carrier equals its load''s carrier_id (when the load has one) -- THE invariant this correction round exists to guarantee',
      not exists (
        select 1 from public.loads l
        join public.dispatches d on d.load_id = l.id and d.status <> 'cancelled'
        where l.carrier_id is not null and d.carrier_id <> l.carrier_id)),
  (24, 'GLOBAL: no financial_dispatch_id references a dispatch belonging to a DIFFERENT load',
      not exists (
        select 1 from public.loads l
        join public.dispatches d on d.id = l.financial_dispatch_id
        where d.load_id <> l.id)),
  (25, 'GLOBAL: no cross-organization load/carrier relationship (loads.carrier_id)',
      not exists (
        select 1 from public.loads l join public.carriers c on c.id = l.carrier_id
        where l.carrier_id is not null and c.organization_id <> l.organization_id)),
  (26, 'GLOBAL: no cross-organization load/dispatch relationship',
      not exists (
        select 1 from public.loads l join public.dispatches d on d.load_id = l.id
        where d.organization_id <> l.organization_id)),
  (27, 'GLOBAL: no cross-organization dispatch/carrier relationship',
      not exists (
        select 1 from public.dispatches d join public.carriers c on c.id = d.carrier_id
        where d.organization_id <> c.organization_id)),
  (28, 'GLOBAL: no financial_dispatch_id is shared by more than one load (at most one active financial controller per dispatch)',
      not exists (
        select 1 from public.loads
        where financial_dispatch_id is not null
        group by financial_dispatch_id
        having count(*) > 1)),
  -- NOTE on "active dispatch on an unresolved load": a load legitimately
  -- classified 'unresolved' BECAUSE it has multiple disagreeing non-
  -- cancelled dispatches (C4_conflicting_carriers) NECESSARILY has
  -- non-cancelled dispatches -- that is WHY it is unresolved. (The other
  -- historical-conflict class, a controller contradicted by a live dispatch,
  -- can no longer reach this verifier at all as of the "C1
  -- controller-conflict" correction above -- 0133 aborts on it instead of
  -- ever writing 'unresolved' for it.) A blanket "zero non-cancelled
  -- dispatches" check would still be self-contradictory for
  -- C4_conflicting_carriers.
  -- The real invariant is WRITE-TIME, not a static data check: an unresolved
  -- load can never GAIN a NEW non-cancelled dispatch going forward -- that is
  -- enforced unconditionally by guard_dispatch_carrier_scope() (tested in
  -- TEST_0132_load_carrier_and_trailer_scope.sql, "new dispatch rejected --
  -- cannot become financial controller of an unresolved-carrier load").
  -- What IS a valid static check is the CONVERSE: a zero-dispatch unresolved
  -- load (C4_zero_dispatch) must actually have zero dispatches of any kind.
  (29, 'GLOBAL: every unresolved load classified for having ZERO dispatches actually has zero dispatches of any kind (sanity on the C4_zero_dispatch class specifically)',
      not exists (
        select 1 from public.loads l
        join public.carrier_backfill_0133_provenance pv on pv.load_id = l.id
        where l.carrier_resolution = 'unresolved'
          and pv.unresolved_carrier_record_id in (
            select id from public.unresolved_carrier_records where detail->>'rule' = 'C4_zero_dispatch')
          and exists (select 1 from public.dispatches d where d.load_id = l.id)))

) as t(check_no, label, ok)
order by check_no;

-- Context: final distribution + the unresolved worklist.
select carrier_resolution, count(*) as loads from public.loads group by carrier_resolution order by carrier_resolution;

-- Context: pre-existing (not in provenance, preserved) vs freshly-resolved (in provenance) split.
select
  count(*) filter (where l.carrier_id is not null and pv.load_id is null)  as preexisting_preserved,
  count(*) filter (where pv.load_id is not null)                          as freshly_resolved_by_this_run,
  count(*) filter (where l.carrier_id is null)                            as still_null
from public.loads l
left join public.carrier_backfill_0133_provenance pv on pv.load_id = l.id;

select u.id, u.record_id as load_id, u.reason, u.detail->>'rule' as rule, u.created_at
from public.unresolved_carrier_records u
where u.record_type='load' and u.status='unresolved'
order by u.created_at;
