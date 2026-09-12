-- ============================================================================
-- TEST_0130 -- disposable database only. Run via TEST_0130_0133_run.sh.
-- Bootstraps the faithful pre-0130 schema, APPLIES 0130 (its in-transaction
-- PHASE 1/3 gates are themselves assertions), prints the POST_APPLY matrix,
-- then exercises post-commit behavior. ON_ERROR_STOP => any failure aborts
-- non-zero.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0130  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql

\echo '----- VERIFY_0130_POST_APPLY matrix (every ok must be t) -----'
\i VERIFY_0130_POST_APPLY.sql

\echo '----- behavior tests -----'
do $t$
declare
  v_id1 uuid; v_id2 uuid; v_cnt int;
  v_authorized uuid[]; v_selectable uuid[];
begin
  -- 1. record_unresolved_carrier_record is idempotent for an OPEN (type,id)
  v_id1 := public.record_unresolved_carrier_record(
    '11111111-1111-1111-1111-111111111111', 'load',
    '40000000-0000-0000-0000-000000000004', 'test: zero dispatch', '{"k":1}'::jsonb);
  v_id2 := public.record_unresolved_carrier_record(
    '11111111-1111-1111-1111-111111111111', 'load',
    '40000000-0000-0000-0000-000000000004', 'test: called again', '{"k":2}'::jsonb);
  assert v_id1 is not null, 'record_unresolved_carrier_record returned NULL';
  assert v_id1 = v_id2, 'record_unresolved_carrier_record not idempotent for an OPEN row';
  select count(*) into v_cnt from public.unresolved_carrier_records
   where record_type='load' and record_id='40000000-0000-0000-0000-000000000004';
  assert v_cnt = 1, format('expected exactly 1 unresolved row, got %s', v_cnt);

  -- 2a. carrier_ids_selectable_for_new_records(): ACTIVE carriers of the
  --     caller's org only (A1, A2) -- NOT the inactive A3, NOT Org B's B1.
  --     This is the ONLY helper a new-load/new-dispatch picker may use.
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  select array_agg(v order by v) into v_selectable from public.carrier_ids_selectable_for_new_records() as v;
  assert v_selectable = array['a1a1a1a1-0000-0000-0000-000000000001','a2a2a2a2-0000-0000-0000-000000000002']::uuid[],
    format('carrier_ids_selectable_for_new_records() = %s (expected A1,A2 only)', v_selectable);

  -- 2b. carrier_ids_authorized_for_current_user(): EVERY carrier of the
  --     caller's org, INCLUDING the inactive A3 -- historical read paths
  --     (invoices/payments/factoring/settlements/documents/reports/audit)
  --     must use THIS one so deactivating a carrier never hides its history.
  --     Still NOT Org B's B1 (org boundary always applies).
  select array_agg(v order by v) into v_authorized from public.carrier_ids_authorized_for_current_user() as v;
  assert v_authorized = array[
      'a1a1a1a1-0000-0000-0000-000000000001',
      'a2a2a2a2-0000-0000-0000-000000000002',
      'a3a3a3a3-0000-0000-0000-000000000003'  -- inactive, but authorized (historical visibility)
    ]::uuid[],
    format('carrier_ids_authorized_for_current_user() = %s (expected A1,A2,A3 -- inactive A3 included)', v_authorized);
  assert not ('b1b1b1b1-0000-0000-0000-000000000001'::uuid = any(v_authorized)),
    'carrier_ids_authorized_for_current_user() leaked a carrier from another organization';
  perform set_config('test.current_uid', '', true);

  raise notice 'OK: idempotent exception writer; selectable=active-only, authorized=all-including-inactive, both org-scoped';
end
$t$;

-- 3. financial_idempotency_keys: same (scope,key) in DIFFERENT orgs is fine;
--    duplicate within one org is rejected.
do $t$
begin
  insert into public.financial_idempotency_keys (organization_id, scope, idempotency_key)
  values ('11111111-1111-1111-1111-111111111111', 'freight_invoice', 'K1');
  insert into public.financial_idempotency_keys (organization_id, scope, idempotency_key)
  values ('22222222-2222-2222-2222-222222222222', 'freight_invoice', 'K1');  -- different org: OK
  begin
    insert into public.financial_idempotency_keys (organization_id, scope, idempotency_key)
    values ('11111111-1111-1111-1111-111111111111', 'freight_invoice', 'K1');  -- dup: reject
    raise exception 'TEST FAIL: duplicate (org,scope,key) was NOT rejected';
  exception when unique_violation then
    raise notice 'OK: duplicate (org,scope,key) rejected; cross-org same key allowed';
  end;
end
$t$;

-- 4. carrier_remittance_profiles same-org guard.
do $t$
begin
  begin
    insert into public.carrier_remittance_profiles (carrier_id, organization_id)
    values ('a1a1a1a1-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');
    raise exception 'TEST FAIL: cross-org carrier_remittance_profiles insert was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-org carrier_remittance_profiles insert rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '################  TEST 0130 PASSED  ################'
