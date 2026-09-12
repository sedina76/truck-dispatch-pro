-- ============================================================================
-- TEST_0131 -- disposable database only. Run via TEST_0130_0133_run.sh.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0131  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql

\echo '----- VERIFY_0131_POST_APPLY matrix (every ok must be t) -----'
\i VERIFY_0131_POST_APPLY.sql

\echo '----- behavior tests -----'

-- 1. activate_carrier_party: happy path (broker) -> active row.
do $t$
declare v_res jsonb; v_status public.carrier_party_status;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  v_res := public.activate_carrier_party(
    'a1a1a1a1-0000-0000-0000-000000000001',
    'a0b00000-0000-0000-0000-000000000001',
    null,
    '{"billing_email":"ap@brokera.com","payment_terms_days":30,"factoring_eligible":true,"document_requirements":["pod","rate_confirmation"]}'::jsonb);
  assert v_res->>'success' = 'true', format('expected success, got %s', v_res);
  assert v_res->>'status'  = 'active', format('expected status active, got %s', v_res);
  select status into v_status from public.carrier_brokers
   where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and broker_id='a0b00000-0000-0000-0000-000000000001';
  assert v_status = 'active', format('carrier_brokers row status = %s', v_status);
  assert (select factoring_eligible from public.carrier_brokers
          where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and broker_id='a0b00000-0000-0000-0000-000000000001'),
         'factoring_eligible not persisted';
  assert (select document_requirements from public.carrier_brokers
          where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and broker_id='a0b00000-0000-0000-0000-000000000001')
         = array['pod','rate_confirmation']::public.document_type[], 'document_requirements not persisted';
  raise notice 'OK: activate_carrier_party happy path';
end
$t$;

-- 1b. accountant role can ALSO activate a carrier-party relationship
-- (billing_email/payment_terms/factoring_eligible/QuickBooks mapping are
-- accounts-payable/receivable data -- accountant is a deliberate write role,
-- not just owner/admin/dispatcher).
do $t$
declare v_res jsonb;
begin
  perform set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', true);  -- Accountant A
  v_res := public.activate_carrier_party(
    'a2a2a2a2-0000-0000-0000-000000000002',
    null,
    'a0c00000-0000-0000-0000-000000000001',
    '{"billing_email":"ar@customera.com","payment_terms_days":45}'::jsonb);
  assert v_res->>'success' = 'true' and v_res->>'status' = 'active',
    format('accountant activate_carrier_party expected success, got %s', v_res);
  assert exists (select 1 from public.carrier_customers
                 where carrier_id='a2a2a2a2-0000-0000-0000-000000000002' and customer_id='a0c00000-0000-0000-0000-000000000001' and status='active'),
    'accountant-activated carrier_customers row missing/not active';
  perform set_config('test.current_uid', '', true);
  raise notice 'OK: accountant role can activate a carrier-party relationship';
end
$t$;

-- 2. activate_carrier_party: incomplete billing -> structured blocked, NO row.
do $t$
declare v_res jsonb; v_cnt int;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  v_res := public.activate_carrier_party(
    'a2a2a2a2-0000-0000-0000-000000000002',
    'a0b00000-0000-0000-0000-000000000001',
    null,
    '{"billing_email":""}'::jsonb);   -- no email, no terms
  assert v_res->>'success' = 'false', format('expected success=false, got %s', v_res);
  assert v_res->>'status'  = 'blocked', format('expected status=blocked, got %s', v_res);
  assert v_res->>'reason'  = 'incomplete_billing_setup', format('unexpected reason %s', v_res);
  select count(*) into v_cnt from public.carrier_brokers
   where carrier_id='a2a2a2a2-0000-0000-0000-000000000002';
  assert v_cnt = 0, 'blocked activation must not write a carrier_brokers row';
  raise notice 'OK: activate_carrier_party blocked path writes nothing';
end
$t$;

-- 3. same-org guard: carrier (Org A) + broker (Org B) -> rejected.
do $t$
begin
  begin
    insert into public.carrier_brokers (organization_id, carrier_id, broker_id, status)
    values ('11111111-1111-1111-1111-111111111111',
            'a1a1a1a1-0000-0000-0000-000000000001',
            'b0b00000-0000-0000-0000-000000000001', 'draft');
    raise exception 'TEST FAIL: cross-org carrier_brokers insert was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-org carrier<->broker rejected (%)', sqlerrm;
  end;
end
$t$;

-- 4. active_requires_billing CHECK: status='active' with NULL billing_email.
do $t$
begin
  begin
    insert into public.carrier_customers (organization_id, carrier_id, customer_id, status)
    values ('11111111-1111-1111-1111-111111111111',
            'a1a1a1a1-0000-0000-0000-000000000001',
            'a0c00000-0000-0000-0000-000000000001', 'active');
    raise exception 'TEST FAIL: active row without billing_email was NOT rejected';
  exception when check_violation then
    raise notice 'OK: active-without-billing rejected by CHECK';
  end;
end
$t$;

-- 5. doc_req_no_nulls CHECK.
do $t$
begin
  begin
    insert into public.carrier_customers (organization_id, carrier_id, customer_id, document_requirements)
    values ('11111111-1111-1111-1111-111111111111',
            'a1a1a1a1-0000-0000-0000-000000000001',
            'a0c00000-0000-0000-0000-000000000001',
            array['pod', null]::public.document_type[]);
    raise exception 'TEST FAIL: NULL element in document_requirements was NOT rejected';
  exception when check_violation then
    raise notice 'OK: NULL document_requirements element rejected by CHECK';
  end;
end
$t$;

\echo '################  TEST 0131 PASSED  ################'
