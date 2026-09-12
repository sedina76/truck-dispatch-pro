-- ============================================================================
-- TEST_0130_RECORD_UNRESOLVED_DIRECT.sql -- disposable database only.
-- Run via TEST_0130_0133_run.sh.
--
-- Direct, authenticated-context tests of public.record_unresolved_carrier_
-- record() (correction #2 -- "structurally identical" indirect coverage was
-- not sufficient). Exercises every role, cross-org rejection, idempotency,
-- the resolved/archived lifecycle, and the record_id-fabrication guard.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0130 RECORD_UNRESOLVED DIRECT  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql

\echo '----- direct authorization tests -----'

-- 1. Authorized user (owner) can create an unresolved record inside their
--    own organization.
do $t$
declare v_id uuid; v_cnt int;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);  -- Owner A
  v_id := public.record_unresolved_carrier_record(
    '11111111-1111-1111-1111-111111111111', 'load',
    '10000000-0000-0000-0000-000000000001', 'owner test', '{}'::jsonb);
  assert v_id is not null, 'owner should be able to create an unresolved record';
  select count(*) into v_cnt from public.unresolved_carrier_records where id = v_id;
  assert v_cnt = 1, 'row was not actually created';
  perform set_config('test.current_uid', '', true);
  raise notice 'OK: authorized (owner) user creates an unresolved record in their own org';
end
$t$;

-- 2. User CANNOT create one for another organization (p_organization_id
--    mismatch while authenticated as an Org A user).
do $t$
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);  -- Owner A
  begin
    perform public.record_unresolved_carrier_record(
      '22222222-2222-2222-2222-222222222222', 'load',       -- Org B's id as the target org
      'b0000000-0000-0000-0000-00000000000b', 'cross-org attempt', '{}'::jsonb);
    raise exception 'TEST FAIL: cross-org p_organization_id was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-org p_organization_id rejected (%)', sqlerrm;
  end;
  perform set_config('test.current_uid', '', true);
end
$t$;

-- 3. Dispatcher and accountant ARE permitted (as designed).
do $t$
declare v_id uuid;
begin
  perform set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', true);  -- Dispatcher A
  v_id := public.record_unresolved_carrier_record(
    '11111111-1111-1111-1111-111111111111', 'load',
    '20000000-0000-0000-0000-000000000002', 'dispatcher test', '{}'::jsonb);
  assert v_id is not null, 'dispatcher should be able to create an unresolved record';

  perform set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', true);  -- Accountant A
  v_id := public.record_unresolved_carrier_record(
    '11111111-1111-1111-1111-111111111111', 'load',
    '50000000-0000-0000-0000-000000000005', 'accountant test', '{}'::jsonb);
  assert v_id is not null, 'accountant should be able to create an unresolved record';
  perform set_config('test.current_uid', '', true);
  raise notice 'OK: dispatcher and accountant are both permitted, as designed';
end
$t$;

-- 4. Driver and viewer are REJECTED.
do $t$
begin
  perform set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', true);  -- Driver A
  begin
    perform public.record_unresolved_carrier_record(
      '11111111-1111-1111-1111-111111111111', 'load',
      '30000000-0000-0000-0000-000000000003', 'driver attempt', '{}'::jsonb);
    raise exception 'TEST FAIL: driver role was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: driver role rejected (%)', sqlerrm;
  end;

  perform set_config('test.current_uid', 'ffff0000-0000-0000-0000-000000000001', true);  -- Viewer A
  begin
    perform public.record_unresolved_carrier_record(
      '11111111-1111-1111-1111-111111111111', 'load',
      '30000000-0000-0000-0000-000000000003', 'viewer attempt', '{}'::jsonb);
    raise exception 'TEST FAIL: viewer role was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: viewer role rejected (%)', sqlerrm;
  end;
  perform set_config('test.current_uid', '', true);
end
$t$;

-- 5. Repeated creation for the SAME OPEN (record_type, record_id) is
--    idempotent -- no duplicate row.
do $t$
declare v_id1 uuid; v_id2 uuid; v_id3 uuid; v_cnt int;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  v_id1 := public.record_unresolved_carrier_record('11111111-1111-1111-1111-111111111111', 'load', '30000000-0000-0000-0000-000000000003', 'first call', '{}'::jsonb);
  v_id2 := public.record_unresolved_carrier_record('11111111-1111-1111-1111-111111111111', 'load', '30000000-0000-0000-0000-000000000003', 'second call, different reason text', '{}'::jsonb);
  v_id3 := public.record_unresolved_carrier_record('11111111-1111-1111-1111-111111111111', 'load', '30000000-0000-0000-0000-000000000003', 'third call', '{}'::jsonb);
  assert v_id1 = v_id2 and v_id2 = v_id3, format('idempotency broken: %s / %s / %s', v_id1, v_id2, v_id3);
  select count(*) into v_cnt from public.unresolved_carrier_records where record_type='load' and record_id='30000000-0000-0000-0000-000000000003';
  assert v_cnt = 1, format('expected exactly 1 open row for L3, got %s (an open row must not be duplicated)', v_cnt);
  perform set_config('test.current_uid', '', true);
  raise notice 'OK: repeated creation for an OPEN record is idempotent -- no duplicate';
end
$t$;

-- 6. Resolved/archived lifecycle: once a row is resolved, calling again for
--    the SAME (record_type, record_id) creates a NEW open row (the old
--    problem is resolved; a fresh, unrelated recurrence gets its own
--    tracked exception rather than being hidden behind the resolved one).
do $t$
declare v_id_first uuid; v_id_after uuid; v_cnt int;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  select id into v_id_first from public.unresolved_carrier_records
    where record_type='load' and record_id='30000000-0000-0000-0000-000000000003' and status='unresolved';

  update public.unresolved_carrier_records
  set status='manually_resolved', resolved_by='aaaa0000-0000-0000-0000-000000000001', resolved_at=now(), resolution_note='resolved for this test'
  where id = v_id_first;

  v_id_after := public.record_unresolved_carrier_record('11111111-1111-1111-1111-111111111111', 'load', '30000000-0000-0000-0000-000000000003', 'recurrence after resolution', '{}'::jsonb);
  assert v_id_after is not null and v_id_after <> v_id_first,
    format('expected a NEW open row after the prior one was resolved, got same id %s', v_id_after);

  select count(*) into v_cnt from public.unresolved_carrier_records where record_type='load' and record_id='30000000-0000-0000-0000-000000000003';
  assert v_cnt = 2, format('expected 2 total rows for L3 (1 resolved + 1 new open), got %s', v_cnt);
  assert (select status from public.unresolved_carrier_records where id = v_id_first) = 'manually_resolved',
    'the resolved row must remain resolved -- never re-opened by a later call';
  assert (select status from public.unresolved_carrier_records where id = v_id_after) = 'unresolved',
    'the new row must be open';
  perform set_config('test.current_uid', '', true);
  raise notice 'OK: resolved-lifecycle handled correctly -- a fresh open row is created, the resolved row is left alone';
end
$t$;

-- 7. archived_legacy also does not block a fresh open row.
do $t$
declare v_id1 uuid; v_id2 uuid;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  v_id1 := public.record_unresolved_carrier_record('11111111-1111-1111-1111-111111111111', 'load', '40000000-0000-0000-0000-000000000004', 'first', '{}'::jsonb);
  update public.unresolved_carrier_records set status='archived_legacy', resolution_note='parked' where id = v_id1;
  v_id2 := public.record_unresolved_carrier_record('11111111-1111-1111-1111-111111111111', 'load', '40000000-0000-0000-0000-000000000004', 'second', '{}'::jsonb);
  assert v_id2 is not null and v_id2 <> v_id1, 'archived_legacy row must not block a fresh open row';
  perform set_config('test.current_uid', '', true);
  raise notice 'OK: archived_legacy handled the same way as manually_resolved';
end
$t$;

-- 8. record_type other than 'load' is REJECTED for an interactive caller in
--    this phase (Phase 3A can only validate record_id against loads).
do $t$
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  begin
    perform public.record_unresolved_carrier_record(
      '11111111-1111-1111-1111-111111111111', 'trailer',
      'e1000000-0000-0000-0000-000000000001', 'trailer attempt', '{}'::jsonb);
    raise exception 'TEST FAIL: record_type=trailer was NOT rejected for an interactive caller';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: record_type <> load rejected for an interactive caller (%)', sqlerrm;
  end;
  perform set_config('test.current_uid', '', true);
end
$t$;

-- 9. THE KEY FABRICATION TEST: caller cannot attach a record_id belonging
--    to ANOTHER organization's load, even when p_organization_id is their
--    OWN (valid) org -- the record_id itself is independently verified.
do $t$
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);  -- Owner A
  begin
    perform public.record_unresolved_carrier_record(
      '11111111-1111-1111-1111-111111111111',      -- caller's own (valid) org
      'load',
      'b0000000-0000-0000-0000-00000000000b',        -- but this load belongs to ORG B
      'fabrication attempt', '{}'::jsonb);
    raise exception 'TEST FAIL: a record_id belonging to another organization''s load was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: record_id belonging to another organization''s load rejected (%)', sqlerrm;
  end;
  perform set_config('test.current_uid', '', true);
end
$t$;

-- 10. migration/service context (auth.uid() IS NULL) remains trusted for
--     any record_type -- required by 0133's own usage. Sanity re-check here.
do $t$
declare v_id uuid;
begin
  -- no set_config: auth.uid() is NULL in this session by default
  v_id := public.record_unresolved_carrier_record(
    '11111111-1111-1111-1111-111111111111', 'trailer',
    'e1000000-0000-0000-0000-000000000001', 'service-context call', '{}'::jsonb);
  assert v_id is not null, 'a trusted service-context caller must still be able to report any record_type';
  raise notice 'OK: service-context (auth.uid() NULL) caller remains trusted for any record_type';
end
$t$;

\echo '################  TEST 0130 RECORD_UNRESOLVED DIRECT PASSED  ################'
