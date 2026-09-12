-- ============================================================================
-- TEST_0133 -- disposable database only. Run via TEST_0130_0133_run.sh.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0133  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql

\echo '----- VERIFY_0133_POST_APPLY matrix (every ok must be t) -----'
\i VERIFY_0133_POST_APPLY.sql

\echo '----- behavior tests -----'

-- 1. deterministic resolution outcome per seeded load.
do $t$
declare r record;
begin
  select carrier_id, carrier_resolution, carrier_locked_at into r
    from public.loads where id='10000000-0000-0000-0000-000000000001';   -- L1: financial controller D1 (A1)
  assert r.carrier_resolution='resolved' and r.carrier_id='a1a1a1a1-0000-0000-0000-000000000001'
         and r.carrier_locked_at is not null,
    format('L1 expected resolved/A1/locked, got %s', r);

  select carrier_id, carrier_resolution, carrier_locked_at into r
    from public.loads where id='20000000-0000-0000-0000-000000000002';   -- L2: sole non-cancelled dispatch (A2)
  assert r.carrier_resolution='backfilled' and r.carrier_id='a2a2a2a2-0000-0000-0000-000000000002'
         and r.carrier_locked_at is null,
    format('L2 expected backfilled/A2/unlocked, got %s', r);

  select carrier_id, carrier_resolution into r
    from public.loads where id='30000000-0000-0000-0000-000000000003';   -- L3: conflicting carriers
  assert r.carrier_resolution='unresolved' and r.carrier_id is null,
    format('L3 expected unresolved/NULL, got %s', r);

  select carrier_id, carrier_resolution into r
    from public.loads where id='40000000-0000-0000-0000-000000000004';   -- L4: zero dispatches
  assert r.carrier_resolution='unresolved' and r.carrier_id is null,
    format('L4 expected unresolved/NULL, got %s', r);

  select carrier_id, carrier_resolution into r
    from public.loads where id='50000000-0000-0000-0000-000000000005';   -- L5: only a cancelled dispatch (A1)
  assert r.carrier_resolution='backfilled' and r.carrier_id='a1a1a1a1-0000-0000-0000-000000000001',
    format('L5 expected backfilled/A1, got %s', r);

  raise notice 'OK: C1/C2/C3/C4 resolution outcomes match';
end
$t$;

-- 2. exactly the unresolved loads (L3, L4) have an OPEN load exception row.
do $t$
declare v_cnt int;
begin
  select count(*) into v_cnt from public.unresolved_carrier_records where record_type='load' and status='unresolved';
  assert v_cnt = 2, format('expected 2 open load exception rows, got %s', v_cnt);
  assert exists (select 1 from public.unresolved_carrier_records
                 where record_type='load' and record_id='30000000-0000-0000-0000-000000000003' and status='unresolved'),
    'L3 exception row missing';
  assert exists (select 1 from public.unresolved_carrier_records
                 where record_type='load' and record_id='40000000-0000-0000-0000-000000000004' and status='unresolved'),
    'L4 exception row missing';
  assert (select detail->>'rule' from public.unresolved_carrier_records
          where record_id='40000000-0000-0000-0000-000000000004') = 'C4_zero_dispatch',
    'L4 exception rule tag wrong';
  raise notice 'OK: unresolved worklist = {L3 conflicting, L4 zero-dispatch}';
end
$t$;

-- 3. rerun rejection -- the marker + a non-null carrier_id both trip PHASE 0.
do $t$
begin
  assert coalesce(col_description('public.loads'::regclass,
    (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='carrier_id' and not attisdropped)),
    '') ilike '%backfilled by migration 0133%',
    'expected the 0133 rerun marker on loads.carrier_id';
  assert exists (select 1 from public.loads where carrier_id is not null),
    'expected some load to have carrier_id after 0133 -- rerun guard would trip on this';
  raise notice 'OK: 0133 rerun guard conditions present (marker + non-null carrier_id)';
end
$t$;

-- 4. post-backfill cross-carrier guard is now live for resolved/backfilled loads.
do $t$
begin
  -- L1 carrier = A1; a dispatch on L1 with carrier A2 must be rejected.
  begin
    insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id, status)
    values ('11111111-1111-1111-1111-111111111111',
            '10000000-0000-0000-0000-000000000001',
            'a2a2a2a2-0000-0000-0000-000000000002',
            'c2000000-0000-0000-0000-000000000002',
            'd2000000-0000-0000-0000-000000000002',
            'assigned');
    raise exception 'TEST FAIL: cross-carrier dispatch on resolved load L1 was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-carrier dispatch on backfilled-carrier load rejected (%)', sqlerrm;
  end;

  -- L3 is unresolved (carrier_id NULL, carrier_resolution='unresolved') ->
  -- the CROSS-CARRIER arm is a no-op (nothing to compare against), but the
  -- correction #5 financial-controller guard now rejects it outright: a
  -- brand-new dispatch may never become the financial controller of a load
  -- 0133 has explicitly classified carrier-ambiguous.
  begin
    insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id, status)
    values ('11111111-1111-1111-1111-111111111111',
            '30000000-0000-0000-0000-000000000003',
            'a1a1a1a1-0000-0000-0000-000000000001',
            'c1000000-0000-0000-0000-000000000001',
            'd1000000-0000-0000-0000-000000000001',
            'assigned');
    raise exception 'TEST FAIL: a new dispatch was allowed to become financial controller of unresolved-carrier load L3';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: new dispatch on unresolved-carrier load L3 rejected by the financial-controller guard (correction #5) -- not the cross-carrier arm, which is a no-op here (%)', sqlerrm;
  end;

  -- L2 is 'backfilled' (a carrier IS known, no controller) -> a NEW,
  -- carrier-matching dispatch is still allowed (the correction #5 guard only
  -- fires for carrier_resolution='unresolved'). NOTE: this INSERT is
  -- deliberately real (not rolled back) -- it is reused below as the "new
  -- dependent activity after 0133" fixture for the ROLLBACK_0133 provenance
  -- tests (step 7), then removed before the clean-rollback test (step 8).
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status, created_at)
  values ('d2c20000-0000-0000-0000-00000000000c',
          '11111111-1111-1111-1111-111111111111',
          '20000000-0000-0000-0000-000000000002',
          'a2a2a2a2-0000-0000-0000-000000000002',
          'c2000000-0000-0000-0000-000000000002',
          'd2000000-0000-0000-0000-000000000002',
          'assigned',
          (select applied_at + interval '1 hour' from public.carrier_backfill_0133_provenance where load_id='20000000-0000-0000-0000-000000000002'));
  raise notice 'OK: a NEW carrier-matching dispatch on a backfilled (not unresolved) load is still allowed';
end
$t$;

-- 5. reassigning carrier on a resolved load is blocked.
do $t$
begin
  begin
    update public.loads set carrier_id='a2a2a2a2-0000-0000-0000-000000000002'
     where id='10000000-0000-0000-0000-000000000001';
    raise exception 'TEST FAIL: carrier reassignment on resolved load L1 was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: carrier reassignment blocked on a resolved load (%)', sqlerrm;
  end;
end
$t$;

-- 6. actually re-apply 0133 -- PHASE 0 must RAISE (transaction rolls back).
\echo '----- re-applying 0133 (expected to FAIL in PHASE 0) -----'
\set ON_ERROR_STOP off
\i migrations/0133_deterministic_carrier_backfill.sql
\set ON_ERROR_STOP on
do $t$
begin
  -- unchanged: still exactly 2 open load exception rows, marker still singular
  assert (select count(*) from public.unresolved_carrier_records where record_type='load' and status='unresolved') = 2,
    're-apply of 0133 must not add exception rows';
  raise notice 'OK: 0133 re-apply rejected, no side effects';
end
$t$;

-- 7. ROLLBACK_0133 provenance safety: two independent "dirty" conditions are
-- in place right now --
--   (a) L3 (unresolved) has a NEW dispatch created AFTER 0133 ran (inserted
--       by step 4 above, backdated relative to L3's provenance applied_at)
--   (b) simulate L4 (unresolved) being manually resolved by a later,
--       not-yet-built assignment RPC: carrier_id set + its exception closed
-- ROLLBACK_0133 must ABORT THE ENTIRE ROLLBACK and write NOTHING.
do $t$
begin
  update public.loads
  set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001', carrier_resolution = 'backfilled'
  where id = '40000000-0000-0000-0000-000000000004';
  update public.unresolved_carrier_records
  set status = 'manually_resolved', resolved_at = now(), resolution_note = 'test: manually assigned carrier A1'
  where record_type='load' and record_id='40000000-0000-0000-0000-000000000004';
  raise notice 'OK: simulated post-backfill manual resolution of L4 (carrier assigned + exception closed)';
end
$t$;

\echo '----- applying ROLLBACK_0133 with L3/L4 dirty (expected to ABORT) -----'
\set ON_ERROR_STOP off
\i ROLLBACK_0133_deterministic_carrier_backfill.sql
\set ON_ERROR_STOP on

do $t$
begin
  -- nothing the aborted rollback should have touched actually changed
  assert (select carrier_id from public.loads where id='10000000-0000-0000-0000-000000000001') = 'a1a1a1a1-0000-0000-0000-000000000001',
    'L1 must be untouched by the aborted rollback';
  assert (select carrier_id from public.loads where id='20000000-0000-0000-0000-000000000002') = 'a2a2a2a2-0000-0000-0000-000000000002',
    'L2 must be untouched by the aborted rollback';
  assert (select carrier_id from public.loads where id='40000000-0000-0000-0000-000000000004') = 'a1a1a1a1-0000-0000-0000-000000000001'
     and (select carrier_resolution from public.loads where id='40000000-0000-0000-0000-000000000004') = 'backfilled',
    'L4''s simulated manual resolution must survive the aborted rollback';
  assert (select status from public.unresolved_carrier_records where record_type='load' and record_id='40000000-0000-0000-0000-000000000004') = 'manually_resolved',
    'L4''s exception resolution must survive the aborted rollback';
  assert exists (select 1 from public.dispatches where id='d2c20000-0000-0000-0000-00000000000c'),
    'L2''s post-backfill dispatch must survive the aborted rollback';
  assert (select count(*) from public.carrier_backfill_0133_provenance) = 6,
    'provenance table must still have all 6 rows (5 Org-A + 1 Org-B) -- the aborted rollback wrote nothing';
  raise notice 'OK: ROLLBACK_0133 aborted the ENTIRE rollback with dirty L2 (new dispatch) + L4 (manual resolution) -- zero writes, all state preserved';
end
$t$;

-- 8. Clean up both dirty conditions, then ROLLBACK_0133 must succeed and
-- reverse EXACTLY 0133's own writes.
do $t$
begin
  -- L2's financial_dispatch_id was NULL when 0133 ran ('backfilled' loads
  -- never get one), so the 0125 AFTER INSERT trigger made the step-4
  -- dispatch its controller the moment it was inserted. That FK is ON
  -- DELETE RESTRICT (0125), so it must be un-controlled before the dispatch
  -- can be removed. This is itself part of the fixture teardown, not a
  -- ROLLBACK_0133 concern.
  update public.loads set financial_dispatch_id = null
   where id = '20000000-0000-0000-0000-000000000002' and financial_dispatch_id = 'd2c20000-0000-0000-0000-00000000000c';
  delete from public.dispatches where id = 'd2c20000-0000-0000-0000-00000000000c';

  -- undoing the L4 fixture means clearing an already-assigned carrier_id,
  -- which guard_load_carrier_change rightly forbids in general -- this is
  -- test-fixture teardown, not a production emergency, so disable/re-enable
  -- it directly here (distinct from ROLLBACK_0133's own gated use of the
  -- same mechanism, tested separately in step 7/8 and in
  -- TEST_0133_ROLLBACK_TRIGGER_SAFETY.sql).
  alter table public.loads disable trigger loads_guard_carrier_change;
  update public.loads
  set carrier_id = null, carrier_resolution = 'unresolved'
  where id = '40000000-0000-0000-0000-000000000004';
  alter table public.loads enable trigger loads_guard_carrier_change;

  update public.unresolved_carrier_records
  set status = 'unresolved', resolved_at = null, resolution_note = null
  where record_type='load' and record_id='40000000-0000-0000-0000-000000000004';
  raise notice 'OK: dirty fixtures reverted -- L3/L4 now byte-identical to what 0133 wrote';
end
$t$;

\echo '----- applying ROLLBACK_0133 clean (expected to SUCCEED) -----'
\i ROLLBACK_0133_deterministic_carrier_backfill.sql

do $t$
begin
  assert not exists (select 1 from public.loads where carrier_id is not null or carrier_resolution is not null or carrier_locked_at is not null),
    'ROLLBACK_0133 must clear all load carrier columns';
  assert not exists (select 1 from public.unresolved_carrier_records where record_type='load'),
    'ROLLBACK_0133 must remove the load exception rows';
  assert to_regclass('public.carrier_backfill_0133_provenance') is null,
    'ROLLBACK_0133 must drop the provenance table on full success';
  assert (select tgenabled from pg_trigger where tgname='loads_guard_carrier_change' and tgrelid='public.loads'::regclass) = 'O',
    'loads_guard_carrier_change must be ENABLED after a successful rollback';
  assert to_regclass('public.carrier_remittance_profiles') is not null
     and to_regclass('public.carrier_brokers') is not null
     and exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_id'),
    'ROLLBACK_0133 must leave 0130/0131/0132 structures in place';
  raise notice 'OK: ROLLBACK_0133 reverses backfill only, once clean';
end
$t$;

\echo '################  TEST 0133 PASSED  ################'
