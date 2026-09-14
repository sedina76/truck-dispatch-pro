-- ============================================================================
-- TEST_0146_carrier_invoice_payments_and_balance_rollups.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.5 verification: record_carrier_invoice_payment()/void_carrier_
-- invoice_payment() -- atomic, idempotent payment posting/voiding for
-- carrier_invoices (freight AND dispatch-service), with the pre-existing
-- 0142 generated balance_due/CHECK invariants as the ultimate backstop.
--
-- Genuine two-session concurrency (Section L) is covered separately by
-- TEST_CONCURRENCY_0146_carrier_invoice_payments.sh -- this file covers
-- every SQL-testable behavior (authorization, structured codes, balance
-- math, immutability, idempotency, factored-invoice rejection) in a
-- single session.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0146  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i TEST_SUPPORT_0136_0138_factoring_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql
\i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
\i migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql
\i migrations/0136_carrier_factoring_policy_and_relationship_columns.sql
\i migrations/0137_deterministic_factoring_carrier_backfill.sql
\i migrations/0138_carrier_default_cutover_classifier_and_secured_rpcs.sql
\i migrations/0139_factoring_policy_safety_integrations_and_privilege_remediation.sql
\i migrations/0140_factoring_authorization_and_submission_safety.sql
\i migrations/0141_factoring_integration_lifecycle_integrity.sql
\i migrations/0142_immutable_carrier_invoice_foundation.sql
\i migrations/0143_canonical_financial_idempotency_hardening.sql
\i migrations/0144_atomic_carrier_invoice_issuance.sql
\i migrations/0145_carrier_dispatch_service_agreements_and_issuance.sql
\i migrations/0146_carrier_invoice_payments_and_balance_rollups.sql

\echo '===== fixtures ====='
reset role;
select set_config('test.current_uid', null, false);
do $t$
begin
  update public.organizations set remittance_instructions = 'Org A -- wire to Bank of Org A' where id = '11111111-1111-1111-1111-111111111111';

  -- Carrier A1: DIRECT billing (freight tests). Carrier A2: FACTORED,
  -- complete+ready default relationship (factored-rejection test).
  update public.carriers set invoice_code = 'CARA', factoring_mode = 'direct' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  update public.carriers set invoice_code = 'CARB', factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';

  insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by) values
    ('cb480000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001'),
    ('cb480000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');

  insert into public.factoring_companies (id, organization_id, name, legal_name, is_active) values
    ('fc480000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor 0146', 'Factor 0146 LLC', true);
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
     noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, submission_destination_email,
     is_default, is_active)
  values
    ('fe480000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc480000-0000-0000-0000-000000000001',
     'a2a2a2a2-0000-0000-0000-000000000002', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Factor 0146', 'NOA 0146', 'ref-0146-1',
     current_date - 5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'secure_email', 'factor0146@example.com', true, true);

  -- Loads for carrier A1 (direct) and A2 (factored), each with a route.
  insert into public.loads (id, organization_id, load_number, broker_id, status, rate) values
    ('60480000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'LD-0146-01', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 1000.00),
    ('60480000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'LD-0146-02', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 500.00),
    ('60480000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'LD-0146-03', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 300.00);
  update public.loads set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001', carrier_resolution = 'resolved'
    where id in ('60480000-0000-0000-0000-000000000001', '60480000-0000-0000-0000-000000000002', '60480000-0000-0000-0000-000000000003');
  insert into public.loads (id, organization_id, load_number, broker_id, status, rate) values
    ('60480000-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111', 'LD-0146-0F', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 800.00);
  update public.loads set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002', carrier_resolution = 'resolved' where id = '60480000-0000-0000-0000-00000000000f';

  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
  select '11111111-1111-1111-1111-111111111111', l.id, 'pickup', 1, 'Shipper 0146', 'Dallas', 'TX', now() - interval '3 days'
  from public.loads l where l.load_number like 'LD-0146-%';
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
  select '11111111-1111-1111-1111-111111111111', l.id, 'delivery', 2, 'Receiver 0146', 'Houston', 'TX', now() - interval '1 day'
  from public.loads l where l.load_number like 'LD-0146-%';

  -- Carrier A1's own dispatch-service agreement (flat $50/load, approved)
  -- for the dispatch-service payer test (E).
  raise notice 'OK: fixtures ready.';
end
$t$;

\echo '----- fixture: issue freight invoices for loads 01/02/03 (A1, direct) and 0F (A2, factored) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid; v_result jsonb;
begin
  for v_id in select unnest(array[
    '60480000-0000-0000-0000-000000000001','60480000-0000-0000-0000-000000000002','60480000-0000-0000-0000-000000000003'
  ]::uuid[])
  loop
    declare v_inv uuid; v_expected timestamptz;
    begin
      insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
      values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
      returning id into v_inv;
      insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
      select '11111111-1111-1111-1111-111111111111', v_inv, 'Freight -- '||l.load_number, 1, l.rate, 'freight_charge', l.id from public.loads l where l.id = v_id;
      insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv, v_id);
      v_expected := (select updated_at from public.carrier_invoices where id = v_inv);
      v_result := public.issue_carrier_invoice(v_inv, v_expected, 'fixture freight issuance', 'fixture-freight-'||v_id::text);
      if v_result->>'code' <> 'ISSUED' then raise exception 'fixture freight issuance failed for %: %', v_id, v_result; end if;
    end;
  end loop;

  -- Carrier A2 (factored) load 0F.
  declare v_inv2 uuid; v_expected2 timestamptz;
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
    returning id into v_inv2;
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
    values ('11111111-1111-1111-1111-111111111111', v_inv2, 'Freight -- LD-0146-0F', 1, 800.00, 'freight_charge', '60480000-0000-0000-0000-00000000000f');
    insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv2, '60480000-0000-0000-0000-00000000000f');
    v_expected2 := (select updated_at from public.carrier_invoices where id = v_inv2);
    v_result := public.issue_carrier_invoice(v_inv2, v_expected2, 'fixture freight issuance F', 'fixture-freight-0f');
    if v_result->>'code' <> 'ISSUED' then raise exception 'fixture freight issuance failed for 0F: %', v_result; end if;
  end;

  perform set_config('test.freight_01', (select id::text from public.carrier_invoices where recipient_type='broker' and organization_id='11111111-1111-1111-1111-111111111111' and carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and id in (select invoice_id from public.carrier_invoice_loads where load_id='60480000-0000-0000-0000-000000000001')), false);
  perform set_config('test.freight_02', (select id::text from public.carrier_invoices where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and id in (select invoice_id from public.carrier_invoice_loads where load_id='60480000-0000-0000-0000-000000000002')), false);
  perform set_config('test.freight_03', (select id::text from public.carrier_invoices where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and id in (select invoice_id from public.carrier_invoice_loads where load_id='60480000-0000-0000-0000-000000000003')), false);
  perform set_config('test.freight_0f', (select id::text from public.carrier_invoices where carrier_id='a2a2a2a2-0000-0000-0000-000000000002' and id in (select invoice_id from public.carrier_invoice_loads where load_id='60480000-0000-0000-0000-00000000000f')), false);
  raise notice 'OK: fixture freight invoices issued -- 01=$1000, 02=$500, 03=$300, 0F=$800(factored).';
end
$t$;

-- ---------------------------------------------------------------------------
-- A0. Phase 3B.5.2, Section F items 2/5: the REAL issue_carrier_invoice()
-- RPC (never a fabricated snapshot) emits schema_version=2 with the exact
-- canonical factoring shape for both direct and factored freight.
-- ---------------------------------------------------------------------------
\echo '----- A0a. direct freight snapshot: schema_version=2, factoring={"mode":"direct"} exactly -----'
do $t$
declare v_inv uuid := current_setting('test.freight_01')::uuid; v_snap jsonb;
begin
  select snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  if (v_snap->>'schema_version')::int <> 2 then
    raise exception 'TEST FAIL (A0a): expected schema_version=2, got %.', v_snap->'schema_version';
  end if;
  if v_snap->'factoring' is distinct from '{"mode":"direct"}'::jsonb then
    raise exception 'TEST FAIL (A0a): expected exactly {"mode":"direct"}, got %.', v_snap->'factoring';
  end if;
  if v_snap ? 'issuing_user_id' or jsonb_typeof(v_snap->'dispatch_service') is distinct from 'null' then
    raise exception 'TEST FAIL (A0a): issuing_user_id must be absent and canonical dispatch_service must be JSON null for freight.';
  end if;
  raise notice 'OK (A0a): schema_version=2, factoring=%.', v_snap->'factoring';
end
$t$;

\echo '----- A0b. factored freight snapshot: schema_version=2, factoring.mode=factored with canonical identity keys -----'
do $t$
declare v_inv uuid := current_setting('test.freight_0f')::uuid; v_snap jsonb; v_factoring jsonb;
begin
  select snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_factoring := v_snap->'factoring';
  if (v_snap->>'schema_version')::int <> 2 then
    raise exception 'TEST FAIL (A0b): expected schema_version=2, got %.', v_snap->'schema_version';
  end if;
  if v_factoring->>'mode' <> 'factored' then
    raise exception 'TEST FAIL (A0b): expected factoring.mode=factored, got %.', v_factoring;
  end if;
  if (v_factoring->>'relationship_id')::uuid <> 'fe480000-0000-0000-0000-000000000001' then
    raise exception 'TEST FAIL (A0b): expected canonical relationship_id, got %.', v_factoring;
  end if;
  if (v_factoring->'company'->>'id')::uuid <> 'fc480000-0000-0000-0000-000000000001' then
    raise exception 'TEST FAIL (A0b): expected canonical company.id, got %.', v_factoring;
  end if;
  if v_factoring->'company'->>'legal_name' is null then
    raise exception 'TEST FAIL (A0b): expected company.legal_name to be populated.';
  end if;
  if v_factoring ? 'factoring_mode' or v_factoring ? 'factoring_relationship_id' or v_factoring ? 'factoring_company_id'
     or v_factoring ? 'company_id' or v_factoring ? 'company_legal_name' then
    raise exception 'TEST FAIL (A0b): retired v1 or flat company keys must never appear in a v2 factored object, got %.', v_factoring;
  end if;
  if not (v_factoring ? 'noa') or not (v_factoring ? 'submission') then
    raise exception 'TEST FAIL (A0b): expected nested noa/submission objects, got %.', v_factoring;
  end if;
  if (v_factoring->'noa'->>'approved')::boolean is distinct from true then
    raise exception 'TEST FAIL (A0b): expected noa.approved=true, got %.', v_factoring;
  end if;
  raise notice 'OK (A0b): schema_version=2, factoring=%.', v_factoring;
end
$t$;

-- ---------------------------------------------------------------------------
-- A. Happy path: partial then full payment, balance/status math.
-- ---------------------------------------------------------------------------
\echo '----- A1. partial payment succeeds -- correct amount_paid/balance_due/payment_status, correct payer derivation -----'
do $t$
declare v_inv uuid := current_setting('test.freight_01')::uuid; v_result jsonb; v_payment_id uuid;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 400.00, current_date, 'ach', 'WIRE-001',
    (select updated_at from public.carrier_invoices where id = v_inv), 'A1 partial', 'a1-pay-key');
  if v_result->>'code' <> 'PAYMENT_RECORDED' then raise exception 'TEST FAIL (A1): expected PAYMENT_RECORDED, got %.', v_result; end if;
  if (v_result->>'amount_paid')::numeric <> 400.00 then raise exception 'TEST FAIL (A1): expected amount_paid 400.00, got %.', v_result; end if;
  if v_result->>'payment_status' <> 'partially_paid' then raise exception 'TEST FAIL (A1): expected partially_paid, got %.', v_result; end if;

  v_payment_id := (v_result->>'payment_id')::uuid;
  perform set_config('test.payment_a1_partial', v_payment_id::text, false);

  if (select row(amount_paid, payment_status, balance_due) from public.carrier_invoices where id = v_inv) is distinct from row(400.00, 'partially_paid'::public.invoice_payment_status, 600.00) then
    raise exception 'TEST FAIL (A1): carrier_invoices row not correctly rolled up.';
  end if;
  if (select payer_type from public.carrier_invoice_payments where id = v_payment_id) <> 'broker' then
    raise exception 'TEST FAIL (A1): payer_type should be broker (the invoice''s own snapshotted recipient).';
  end if;
  if (select payer_broker_id from public.carrier_invoice_payments where id = v_payment_id) <> 'a0b00000-0000-0000-0000-000000000001' then
    raise exception 'TEST FAIL (A1): payer_broker_id should match the invoice''s recipient_broker_id.';
  end if;
  if (select payment_number from public.carrier_invoice_payments where id = v_payment_id) !~ '^CPAY-[0-9]{8}$' then
    raise exception 'TEST FAIL (A1): payment_number does not match the expected CPAY-######## shape.';
  end if;
  raise notice 'OK (A1): %.', v_result;
end
$t$;

\echo '----- A2. full payment (remaining balance) succeeds -- payment_status becomes paid -----'
do $t$
declare v_inv uuid := current_setting('test.freight_01')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 600.00, current_date, 'wire', 'WIRE-002',
    (select updated_at from public.carrier_invoices where id = v_inv), 'A2 final', 'a2-pay-key');
  if v_result->>'code' <> 'PAYMENT_RECORDED' then raise exception 'TEST FAIL (A2): expected PAYMENT_RECORDED, got %.', v_result; end if;
  if (v_result->>'amount_paid')::numeric <> 1000.00 or v_result->>'payment_status' <> 'paid' or (v_result->>'balance_due')::numeric <> 0 then
    raise exception 'TEST FAIL (A2): expected fully paid, got %.', v_result;
  end if;
  perform set_config('test.payment_a1_full', (v_result->>'payment_id'), false);
  raise notice 'OK (A2): %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- B. Structured error codes.
-- ---------------------------------------------------------------------------
\echo '----- B1. ALREADY_PAID: invoice is already fully paid -----'
do $t$
declare v_inv uuid := current_setting('test.freight_01')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 10.00, current_date, 'cash', null,
    (select updated_at from public.carrier_invoices where id = v_inv), 'B1', 'b1-pay-key');
  if v_result->>'code' <> 'ALREADY_PAID' then raise exception 'TEST FAIL (B1): expected ALREADY_PAID, got %.', v_result; end if;
  raise notice 'OK (B1): %.', v_result;
end
$t$;

\echo '----- B2. OVERPAYMENT: amount exceeds remaining balance -----'
do $t$
declare v_inv uuid := current_setting('test.freight_02')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 501.00, current_date, 'ach', null,
    (select updated_at from public.carrier_invoices where id = v_inv), 'B2', 'b2-pay-key');
  if v_result->>'code' <> 'OVERPAYMENT' then raise exception 'TEST FAIL (B2): expected OVERPAYMENT, got %.', v_result; end if;
  if (select amount_paid from public.carrier_invoices where id = v_inv) <> 0 then raise exception 'TEST FAIL (B2): amount_paid must remain 0.'; end if;
  raise notice 'OK (B2): %.', v_result;
end
$t$;

\echo '----- B3. INVALID_AMOUNT: zero/negative amount -----'
do $t$
declare v_inv uuid := current_setting('test.freight_02')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 0, current_date, 'ach', null,
    (select updated_at from public.carrier_invoices where id = v_inv), 'B3a', 'b3a-pay-key');
  if v_result->>'code' <> 'INVALID_AMOUNT' then raise exception 'TEST FAIL (B3a): expected INVALID_AMOUNT, got %.', v_result; end if;
  v_result := public.record_carrier_invoice_payment(
    v_inv, -50.00, current_date, 'ach', null,
    (select updated_at from public.carrier_invoices where id = v_inv), 'B3b', 'b3b-pay-key');
  if v_result->>'code' <> 'INVALID_AMOUNT' then raise exception 'TEST FAIL (B3b): expected INVALID_AMOUNT, got %.', v_result; end if;
  raise notice 'OK (B3): negative and zero amounts both rejected.';
end
$t$;

\echo '----- B4. INVALID_STATE: invoice not yet issued (draft) -----'
do $t$
declare v_id uuid; v_result jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  v_result := public.record_carrier_invoice_payment(
    v_id, 10.00, current_date, 'ach', null,
    (select updated_at from public.carrier_invoices where id = v_id), 'B4', 'b4-pay-key');
  if v_result->>'code' <> 'INVALID_STATE' then raise exception 'TEST FAIL (B4): expected INVALID_STATE, got %.', v_result; end if;
  raise notice 'OK (B4): %.', v_result;
end
$t$;

\echo '----- B5. INVALID_STATE: voided invoice (direct/trusted-context simulation -- no void-invoice RPC exists yet) -----'
-- A DEDICATED, disposable invoice -- 'voided' is a TERMINAL issuance
-- state (0142's own state machine: no path ever leaves it), so this
-- cannot be simulated on an invoice any later test still needs issued.
do $t$
declare v_id uuid; v_inv uuid; v_result jsonb;
begin
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60480000-0000-0000-0000-0000000000b5', '11111111-1111-1111-1111-111111111111', 'LD-0146-B5', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 100.00)
  returning id into v_id;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state) values
    ('11111111-1111-1111-1111-111111111111', v_id, 'pickup', 1, 'S', 'Dallas', 'TX'),
    ('11111111-1111-1111-1111-111111111111', v_id, 'delivery', 2, 'R', 'Houston', 'TX');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_inv;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
  values ('11111111-1111-1111-1111-111111111111', v_inv, 'Freight -- LD-0146-B5', 1, 100.00, 'freight_charge', v_id);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv, v_id);
  v_result := public.issue_carrier_invoice(v_inv, (select updated_at from public.carrier_invoices where id = v_inv), 'b5 setup issue', 'b5-setup-issue');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (B5 setup): %.', v_result; end if;

  reset role;
  update public.carrier_invoices set issuance_status = 'voided', voided_at = now(), voided_by = 'aaaa0000-0000-0000-0000-000000000001', void_reason = 'test simulation' where id = v_inv;
  set role authenticated;
  v_result := public.record_carrier_invoice_payment(
    v_inv, 10.00, current_date, 'ach', null,
    (select updated_at from public.carrier_invoices where id = v_inv), 'B5', 'b5-pay-key');
  if v_result->>'code' <> 'INVALID_STATE' then raise exception 'TEST FAIL (B5): expected INVALID_STATE, got %.', v_result; end if;
  raise notice 'OK (B5): %.', v_result;
end
$t$;

\echo '----- B6. FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW -----'
do $t$
declare v_inv uuid := current_setting('test.freight_0f')::uuid; v_result jsonb; v_count_before integer; v_count_after integer; v_audit_before integer; v_audit_after integer;
begin
  select count(*) into v_count_before from public.carrier_invoice_payments;
  select count(*) into v_audit_before from public.activity_logs where entity_type = 'invoice' and entity_id = v_inv and action = 'carrier_invoice_payment_recorded';
  v_result := public.record_carrier_invoice_payment(
    v_inv, 100.00, current_date, 'ach', null,
    (select updated_at from public.carrier_invoices where id = v_inv), 'B6', 'b6-pay-key');
  if v_result->>'code' <> 'FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW' then raise exception 'TEST FAIL (B6): expected FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW, got %.', v_result; end if;
  select count(*) into v_count_after from public.carrier_invoice_payments;
  if v_count_after <> v_count_before then raise exception 'TEST FAIL (B6): no payment row should have been created.'; end if;
  if (select amount_paid from public.carrier_invoices where id = v_inv) <> 0 then raise exception 'TEST FAIL (B6): factored invoice amount_paid must remain 0.'; end if;
  select count(*) into v_audit_after from public.activity_logs where entity_type = 'invoice' and entity_id = v_inv and action = 'carrier_invoice_payment_recorded';
  if v_audit_after <> v_audit_before then raise exception 'TEST FAIL (B6): no carrier_invoice_payment_recorded audit event should have been written.'; end if;
  raise notice 'OK (B6): % -- zero payment row, zero amount_paid change, zero audit event.', v_result;
end
$t$;

\echo '----- B7. IDEMPOTENCY_KEY_REUSED (collision) and idempotent replay -----'
do $t$
declare v_inv uuid := current_setting('test.freight_02')::uuid; v_result1 jsonb; v_result2 jsonb; v_result3 jsonb; v_expected timestamptz;
begin
  -- Captured ONCE -- a genuine retry resends the SAME expected_updated_at
  -- it originally read (the fingerprint hashes this field too, so a
  -- freshly-re-read, now-different value would itself look like a
  -- different request, not a replay).
  v_expected := (select updated_at from public.carrier_invoices where id = v_inv);

  v_result1 := public.record_carrier_invoice_payment(
    v_inv, 200.00, current_date, 'ach', 'REF-1',
    v_expected, 'B7 first', 'b7-shared-key');
  if v_result1->>'code' <> 'PAYMENT_RECORDED' then raise exception 'TEST FAIL (B7 setup): %.', v_result1; end if;

  -- Same key, DIFFERENT amount -> collision. Re-reads the now-current
  -- updated_at (irrelevant here -- the idempotency check fires before
  -- the staleness check either way, and the fingerprint mismatch alone
  -- is enough to produce IDEMPOTENCY_KEY_REUSED).
  v_result2 := public.record_carrier_invoice_payment(
    v_inv, 300.00, current_date, 'ach', 'REF-1',
    (select updated_at from public.carrier_invoices where id = v_inv), 'B7 second', 'b7-shared-key');
  if v_result2->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then raise exception 'TEST FAIL (B7 collision): expected IDEMPOTENCY_KEY_REUSED, got %.', v_result2; end if;

  -- Same key, IDENTICAL request (including the SAME originally-read
  -- v_expected) -> replay returns the cached result.
  v_result3 := public.record_carrier_invoice_payment(
    v_inv, 200.00, current_date, 'ach', 'REF-1',
    v_expected, 'B7 first', 'b7-shared-key');
  if v_result3 <> v_result1 then raise exception 'TEST FAIL (B7 replay): expected identical cached result, got % vs %.', v_result1, v_result3; end if;

  if (select count(*) from public.carrier_invoice_payments where carrier_invoice_id = v_inv) <> 1 then
    raise exception 'TEST FAIL (B7): the colliding/replayed request must never have created a second payment row.';
  end if;
  raise notice 'OK (B7): collision -- %; replay -- %.', v_result2, v_result3;
end
$t$;

\echo '----- B8. NOT_FOUND: random uuid, and a LEGACY public.invoices id passed to the new RPC -----'
do $t$
declare v_result jsonb; v_legacy_id uuid;
begin
  v_result := public.record_carrier_invoice_payment(
    '99999999-9999-9999-9999-999999999999'::uuid, 10.00, current_date, 'ach', null, now(), 'B8a', 'b8a-pay-key');
  if v_result->>'code' <> 'NOT_FOUND' then raise exception 'TEST FAIL (B8a): expected NOT_FOUND, got %.', v_result; end if;

  -- A real legacy public.invoices row -- structurally a different id
  -- space entirely; the new RPC must not find it and must not error
  -- confusingly.
  insert into public.invoices (organization_id, invoice_number, total_amount)
  values ('11111111-1111-1111-1111-111111111111', 'LEGACY-0146-TEST', 500.00)
  returning id into v_legacy_id;
  v_result := public.record_carrier_invoice_payment(v_legacy_id, 10.00, current_date, 'ach', null, now(), 'B8b', 'b8b-pay-key');
  if v_result->>'code' <> 'NOT_FOUND' then raise exception 'TEST FAIL (B8b): expected NOT_FOUND for a legacy invoices id, got %.', v_result; end if;
  raise notice 'OK (B8): both NOT_FOUND as expected.';
end
$t$;

\echo '----- B9. FORBIDDEN: unauthenticated, and dispatcher/driver/viewer -----'
select set_config('test.current_uid', null, false);
do $t$
declare v_result jsonb; v_inv uuid := current_setting('test.freight_02')::uuid;
begin
  v_result := public.record_carrier_invoice_payment(v_inv, 10.00, current_date, 'ach', null, now(), 'B9', 'b9-pay-key-0');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (B9 unauth): expected FORBIDDEN, got %.', v_result; end if;
  raise notice 'OK (B9 unauth): %.', v_result;
end
$t$;
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb; v_inv uuid := current_setting('test.freight_02')::uuid;
begin
  v_result := public.record_carrier_invoice_payment(v_inv, 10.00, current_date, 'ach', null, now(), 'B9 dispatcher', 'b9-pay-key-1');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (B9 dispatcher): expected FORBIDDEN, got %.', v_result; end if;
  raise notice 'OK (B9 dispatcher): %.', v_result;
end
$t$;
select set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb; v_inv uuid := current_setting('test.freight_02')::uuid; v_n integer;
begin
  v_result := public.record_carrier_invoice_payment(v_inv, 10.00, current_date, 'ach', null, now(), 'B9 driver', 'b9-pay-key-2');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (B9 driver): expected FORBIDDEN, got %.', v_result; end if;
  select count(*) into v_n from public.carrier_invoice_payments;
  if v_n <> 0 then raise exception 'TEST FAIL (B9 driver): driver must see ZERO payment rows via RLS, saw %.', v_n; end if;
  raise notice 'OK (B9 driver): FORBIDDEN on write, zero rows on read.';
end
$t$;

\echo '----- B10. STALE_RECORD on record_ and void_ -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_inv uuid := current_setting('test.freight_02')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 10.00, current_date, 'ach', null, now() - interval '1 hour', 'B10a', 'b10a-pay-key');
  if v_result->>'code' <> 'STALE_RECORD' then raise exception 'TEST FAIL (B10a): expected STALE_RECORD, got %.', v_result; end if;

  v_result := public.void_carrier_invoice_payment(
    current_setting('test.payment_a1_partial')::uuid, now() - interval '1 hour', 'stale void attempt', 'b10b-void-key');
  if v_result->>'code' <> 'STALE_RECORD' then raise exception 'TEST FAIL (B10b): expected STALE_RECORD, got %.', v_result; end if;
  raise notice 'OK (B10): both STALE_RECORD as expected.';
end
$t$;

\echo '----- B11. void: INVALID_STATE for empty/null reason; PAYMENT_ALREADY_VOIDED on double-void -----'
do $t$
declare v_payment uuid := current_setting('test.payment_a1_full')::uuid; v_result jsonb;
begin
  v_result := public.void_carrier_invoice_payment(
    v_payment, (select updated_at from public.carrier_invoice_payments where id = v_payment), '   ', 'b11a-void-key');
  if v_result->>'code' <> 'INVALID_STATE' then raise exception 'TEST FAIL (B11a): expected INVALID_STATE, got %.', v_result; end if;

  v_result := public.void_carrier_invoice_payment(
    v_payment, (select updated_at from public.carrier_invoice_payments where id = v_payment), 'wire reversed', 'b11b-void-key');
  if v_result->>'code' <> 'PAYMENT_VOIDED' then raise exception 'TEST FAIL (B11b setup): %.', v_result; end if;

  v_result := public.void_carrier_invoice_payment(
    v_payment, (select updated_at from public.carrier_invoice_payments where id = v_payment), 'void again', 'b11c-void-key');
  if v_result->>'code' <> 'PAYMENT_ALREADY_VOIDED' then raise exception 'TEST FAIL (B11c): expected PAYMENT_ALREADY_VOIDED, got %.', v_result; end if;

  -- Voiding the FULL payment must reopen the invoice's balance.
  if (select row(amount_paid, payment_status) from public.carrier_invoices where id = current_setting('test.freight_01')::uuid) is distinct from row(400.00, 'partially_paid'::public.invoice_payment_status) then
    raise exception 'TEST FAIL (B11): voiding the full payment should have reopened the invoice to partially_paid/$400.';
  end if;
  raise notice 'OK (B11): void reason required; double-void refused; voiding the full payment reopened the balance.';
end
$t$;

-- ---------------------------------------------------------------------------
-- C. Authorization matrix.
-- ---------------------------------------------------------------------------
\echo '----- C1. accountant: may record AND void -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
do $t$
declare v_inv uuid := current_setting('test.freight_03')::uuid; v_result jsonb; v_payment uuid;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 100.00, current_date, 'check', 'CHK-100',
    (select updated_at from public.carrier_invoices where id = v_inv), 'C1 accountant record', 'c1-pay-key');
  if v_result->>'code' <> 'PAYMENT_RECORDED' then raise exception 'TEST FAIL (C1 record): expected PAYMENT_RECORDED, got %.', v_result; end if;
  v_payment := (v_result->>'payment_id')::uuid;

  v_result := public.void_carrier_invoice_payment(
    v_payment, (select updated_at from public.carrier_invoice_payments where id = v_payment), 'accountant void', 'c1-void-key');
  if v_result->>'code' <> 'PAYMENT_VOIDED' then raise exception 'TEST FAIL (C1 void): expected PAYMENT_VOIDED, got %.', v_result; end if;
  raise notice 'OK (C1): accountant may both record and void.';
end
$t$;

\echo '----- C2. dispatcher: read-only -- both RPCs FORBIDDEN, SELECT works -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb; v_inv uuid := current_setting('test.freight_03')::uuid; v_n integer;
begin
  v_result := public.record_carrier_invoice_payment(v_inv, 10.00, current_date, 'ach', null, now(), 'C2', 'c2-pay-key');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C2 record): %.', v_result; end if;
  v_result := public.void_carrier_invoice_payment(current_setting('test.payment_a1_partial')::uuid, now(), 'C2', 'c2-void-key');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C2 void): %.', v_result; end if;
  select count(*) into v_n from public.carrier_invoice_payments;
  if v_n = 0 then raise exception 'TEST FAIL (C2): dispatcher should see existing payment rows via SELECT.'; end if;
  raise notice 'OK (C2): dispatcher denied on both RPCs, % row(s) visible via SELECT.', v_n;
end
$t$;

\echo '----- C3. service_role has no auth.uid() -- structurally cannot pass -----'
reset role;
select set_config('test.current_uid', null, false);
do $t$
declare v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment('00000000-0000-0000-0000-000000000000'::uuid, 10.00, current_date, 'ach', null, now(), 'C3', 'c3-pay-key');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C3): %.', v_result; end if;
  raise notice 'OK (C3): %.', v_result;
end
$t$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- D. Immutability enforcement.
-- ---------------------------------------------------------------------------
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
\echo '----- D1. financial identity is immutable, even for a superuser/trusted context -----'
reset role;
do $t$
declare v_payment uuid := current_setting('test.payment_a1_partial')::uuid;
begin
  begin
    update public.carrier_invoice_payments set amount = 99999.00 where id = v_payment;
    raise exception 'TEST FAIL (D1a): amount mutation should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%financial identity is immutable%' then raise; end if;
  end;
  begin
    update public.carrier_invoice_payments set carrier_invoice_id = gen_random_uuid() where id = v_payment;
    raise exception 'TEST FAIL (D1b): carrier_invoice_id mutation should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%financial identity is immutable%' then raise; end if;
  end;
  raise notice 'OK (D1): financial identity remains immutable.';
end
$t$;

\echo '----- D2. voided payment can never be reactivated -----'
do $t$
declare v_payment uuid := current_setting('test.payment_a1_full')::uuid;
begin
  if (select status from public.carrier_invoice_payments where id = v_payment) <> 'voided' then
    raise exception 'TEST FAIL (D2 precondition): payment_a1_full should already be voided (test B11).';
  end if;
  begin
    update public.carrier_invoice_payments set status = 'posted' where id = v_payment;
    raise exception 'TEST FAIL (D2): reactivation should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%not a permitted status transition%' then raise; end if;
  end;
  raise notice 'OK (D2): a voided payment can never be reactivated.';
end
$t$;

\echo '----- D3. a payment can never be deleted, posted or voided -----'
do $t$
declare v_posted uuid := current_setting('test.payment_a1_partial')::uuid; v_voided uuid := current_setting('test.payment_a1_full')::uuid;
begin
  begin
    delete from public.carrier_invoice_payments where id = v_posted;
    raise exception 'TEST FAIL (D3a): deleting a posted payment should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%can never be deleted%' then raise; end if;
  end;
  begin
    delete from public.carrier_invoice_payments where id = v_voided;
    raise exception 'TEST FAIL (D3b): deleting a voided payment should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%can never be deleted%' then raise; end if;
  end;
  raise notice 'OK (D3): neither a posted nor a voided payment can ever be deleted.';
end
$t$;

\echo '----- D4. cross-table currency backstop (direct-context INSERT bypass) -----'
do $t$
begin
  begin
    insert into public.carrier_invoice_payments
      (organization_id, carrier_invoice_id, payment_date, amount, currency, payment_method, payer_type, payer_broker_id, recorded_by)
    values
      ('11111111-1111-1111-1111-111111111111', current_setting('test.freight_02')::uuid, current_date, 10.00, 'EUR', 'ach', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL (D4): a mismatched-currency direct INSERT should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%currency must equal its invoice%' then raise; end if;
  end;
  raise notice 'OK (D4): the cross-table currency backstop trigger rejects a mismatched-currency direct write.';
end
$t$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- E. Dispatch-service invoice payment (payer = carrier).
-- ---------------------------------------------------------------------------
\echo '----- E1. dispatch-service invoice payment: payer_type=carrier, full payment -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_agr uuid; v_ver uuid; v_result jsonb; v_load uuid; v_inv uuid; v_payment_id uuid;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'DSA-0146-E1', 'e1', 'e1-agree');
  v_agr := (v_result->>'agreement_id')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agr, 'flat_per_load', null, 60.00, null, null, 'USD', 15, current_date - 10, null, 'e1', 'e1-version');
  v_ver := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(v_ver, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_ver), 'e1 approve', 'e1-approve');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (E1 setup): %.', v_result; end if;

  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60480000-0000-0000-0000-0000000000e1', '11111111-1111-1111-1111-111111111111', 'LD-0146-E1', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 200.00)
  returning id into v_load;

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_inv;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv, v_load);
  v_result := public.issue_carrier_invoice(v_inv, (select updated_at from public.carrier_invoices where id = v_inv), 'e1 issue dsi', 'e1-issue-dsi');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (E1 setup issue): %.', v_result; end if;

  -- Phase 3B.5.2, Section F item 8: schema_version=2, factoring JSON null exactly.
  declare v_snap jsonb;
  begin
    select snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
    if (v_snap->>'schema_version')::int <> 2 then
      raise exception 'TEST FAIL (E1 setup): expected schema_version=2, got %.', v_snap->'schema_version';
    end if;
    if jsonb_typeof(v_snap->'factoring') is distinct from 'null' then
      raise exception 'TEST FAIL (E1 setup): expected factoring=null exactly, got %.', v_snap->'factoring';
    end if;
    if v_snap ? 'issuing_user_id' then
      raise exception 'TEST FAIL (E1 setup): vestigial v1 issuing_user_id key must not appear in v2.';
    end if;
  end;

  v_result := public.record_carrier_invoice_payment(
    v_inv, 60.00, current_date, 'ach', 'DSI-PAY-1',
    (select updated_at from public.carrier_invoices where id = v_inv), 'E1 pay dsi', 'e1-pay-key');
  if v_result->>'code' <> 'PAYMENT_RECORDED' then raise exception 'TEST FAIL (E1): expected PAYMENT_RECORDED, got %.', v_result; end if;
  if v_result->>'payment_status' <> 'paid' then raise exception 'TEST FAIL (E1): expected paid, got %.', v_result; end if;
  v_payment_id := (v_result->>'payment_id')::uuid;
  if (select payer_type from public.carrier_invoice_payments where id = v_payment_id) <> 'carrier' then
    raise exception 'TEST FAIL (E1): payer_type should be carrier for a dispatch-service invoice.';
  end if;
  if (select payer_carrier_id from public.carrier_invoice_payments where id = v_payment_id) <> 'a1a1a1a1-0000-0000-0000-000000000001' then
    raise exception 'TEST FAIL (E1): payer_carrier_id should match the invoice''s own carrier_id.';
  end if;
  perform set_config('test.e1_inv', v_inv::text, false);
  perform set_config('test.e1_payment', v_payment_id::text, false);
  raise notice 'OK (E1): %.', v_result;
end
$t$;

\echo '----- E2. void the dispatch-service payment -- balance/payment_status correctly reopen -----'
do $t$
declare v_inv uuid := current_setting('test.e1_inv')::uuid; v_payment uuid := current_setting('test.e1_payment')::uuid; v_result jsonb;
begin
  v_result := public.void_carrier_invoice_payment(
    v_payment, (select updated_at from public.carrier_invoice_payments where id = v_payment), 'E2 void dsi payment', 'e2-void-key');
  if v_result->>'code' <> 'PAYMENT_VOIDED' then raise exception 'TEST FAIL (E2): expected PAYMENT_VOIDED, got %.', v_result; end if;
  if (select row(amount_paid, payment_status, balance_due) from public.carrier_invoices where id = v_inv)
     is distinct from row(0.00, 'unpaid'::public.invoice_payment_status, 60.00) then
    raise exception 'TEST FAIL (E2): voiding the full dispatch-service payment must reopen the balance to unpaid/$0 paid/$60 due.';
  end if;
  if (select issuance_status from public.carrier_invoices where id = v_inv) <> 'issued' then
    raise exception 'TEST FAIL (E2): issuance_status must remain issued.';
  end if;
  raise notice 'OK (E2): %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- F. Payment activity never touches issuance_status or the immutable snapshot.
-- ---------------------------------------------------------------------------
\echo '----- F1. issuance_status and the issuance snapshot are untouched by payment activity -----'
do $t$
declare v_inv uuid := current_setting('test.freight_02')::uuid; v_snap_before jsonb; v_snap_after jsonb;
begin
  select snapshot_payload into v_snap_before from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  perform public.record_carrier_invoice_payment(
    v_inv, 50.00, current_date, 'ach', 'REF-F1',
    (select updated_at from public.carrier_invoices where id = v_inv), 'F1', 'f1-pay-key');
  select snapshot_payload into v_snap_after from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  if v_snap_before is distinct from v_snap_after then
    raise exception 'TEST FAIL (F1): the immutable issuance snapshot must never change due to payment activity.';
  end if;
  if (select issuance_status from public.carrier_invoices where id = v_inv) <> 'issued' then
    raise exception 'TEST FAIL (F1): issuance_status must remain issued.';
  end if;
  raise notice 'OK (F1): issuance_status and the immutable snapshot are untouched by payment activity.';
end
$t$;

-- ---------------------------------------------------------------------------
-- G. Malformed-snapshot integrity tests (Phase 3B.5.1, Section D). Every
-- case is manufactured via a TRUSTED, disposable-test-only direct bypass of
-- the immutable-snapshot trigger (a0142_guard_snapshot_immutable), against
-- DEDICATED base invoices created here and never reused for anything else
-- in this file. Every case must fail closed with SNAPSHOT_INTEGRITY_ERROR
-- before any payment row is inserted, with zero raw snapshot/JSON content
-- leaked in the structured result -- and the snapshot is always restored to
-- its pristine, genuinely-issued state immediately afterward.
-- ---------------------------------------------------------------------------
\echo '----- G0. dedicated base invoices for malformed-snapshot tests -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_inv uuid; v_dsi uuid; v_load uuid; v_agr uuid; v_ver uuid; v_result jsonb;
begin
  -- Dedicated freight invoice (direct carrier A1), $100.
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60480000-0000-0000-0000-00000000d001', '11111111-1111-1111-1111-111111111111', 'LD-0146-G1', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 100.00)
  returning id into v_load;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at) values
    ('11111111-1111-1111-1111-111111111111', v_load, 'pickup', 1, 'Shipper G', 'Dallas', 'TX', now() - interval '3 days'),
    ('11111111-1111-1111-1111-111111111111', v_load, 'delivery', 2, 'Receiver G', 'Houston', 'TX', now() - interval '1 day');

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_inv;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
  values ('11111111-1111-1111-1111-111111111111', v_inv, 'Freight -- LD-0146-G1', 1, 100.00, 'freight_charge', v_load);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv, v_load);
  v_result := public.issue_carrier_invoice(v_inv, (select updated_at from public.carrier_invoices where id = v_inv), 'g fixture issue', 'g-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (G0 freight setup): %.', v_result; end if;

  -- Dedicated dispatch-service invoice (carrier A1) -- reuses the SAME
  -- already-approved agreement version E1 created (flat $60/load; a new,
  -- separately-dated agreement for the same carrier would illegally
  -- overlap it, cdsav_no_overlap_when_approved) against a brand-new load.
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60480000-0000-0000-0000-00000000d002', '11111111-1111-1111-1111-111111111111', 'LD-0146-G2', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 200.00)
  returning id into v_load;
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_dsi;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_dsi, v_load);
  v_result := public.issue_carrier_invoice(v_dsi, (select updated_at from public.carrier_invoices where id = v_dsi), 'g fixture issue dsi', 'g-issue-dsi-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (G0 dsi setup issue): %.', v_result; end if;

  perform set_config('test.g_freight', v_inv::text, false);
  perform set_config('test.g_dsi', v_dsi::text, false);
  perform set_config('test.g_freight_pristine', (select snapshot_payload::text from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv), false);
  perform set_config('test.g_dsi_pristine', (select snapshot_payload::text from public.carrier_invoice_issuance_snapshots where invoice_id = v_dsi), false);
  raise notice 'OK: G0 dedicated base invoices ready (freight=$100, dsi=$60).';
end
$t$;

-- Reusable helper (session-temp, auto-dropped with this connection): applies
-- a trusted-context snapshot corruption, calls record_carrier_invoice_payment,
-- asserts the expected structured code + zero leakage + zero payment row,
-- then restores the snapshot to its original value -- every G-case below is
-- a thin, explicit wrapper around this, matching this file's own
-- established fully-explicit style everywhere else while avoiding 11x
-- verbatim repetition of the disable-trigger/corrupt/enable-trigger dance.
create function pg_temp.g_check_malformed(p_inv uuid, p_new_snapshot jsonb, p_label text, p_expected_code text) returns jsonb
language plpgsql
as $fn$
declare
  v_orig jsonb;
  v_result jsonb;
  v_count_before integer;
  v_count_after integer;
  v_audit_before integer;
  v_audit_after integer;
  v_idem_key text := 'g-key-' || p_label;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = p_inv;
  select count(*) into v_count_before from public.carrier_invoice_payments;
  select count(*) into v_audit_before from public.activity_logs where entity_type = 'invoice' and entity_id = p_inv and action = 'carrier_invoice_payment_recorded';

  execute 'reset role';
  alter table public.carrier_invoice_issuance_snapshots disable trigger a0142_guard_snapshot_immutable;
  update public.carrier_invoice_issuance_snapshots set snapshot_payload = p_new_snapshot where invoice_id = p_inv;
  alter table public.carrier_invoice_issuance_snapshots enable trigger a0142_guard_snapshot_immutable;
  execute 'set role authenticated';

  v_result := public.record_carrier_invoice_payment(
    p_inv, 1.00, current_date, 'ach', null,
    (select updated_at from public.carrier_invoices where id = p_inv), p_label, v_idem_key);

  if v_result->>'code' is distinct from p_expected_code then
    raise exception 'TEST FAIL (%): expected %, got %.', p_label, p_expected_code, v_result;
  end if;
  if p_expected_code in ('SNAPSHOT_INTEGRITY_ERROR', 'SNAPSHOT_VERSION_UNSUPPORTED')
     and (v_result ? 'reason' or v_result ? 'detail' or v_result ? 'problem_code' or v_result::text ilike '%snapshot_payload%')
  then
    raise exception 'TEST FAIL (%): structured error leaked an internal field/snapshot content, got %.', p_label, v_result;
  end if;

  select count(*) into v_count_after from public.carrier_invoice_payments;
  if v_count_after <> v_count_before then
    raise exception 'TEST FAIL (%): no payment row should have been created, got %.', p_label, v_result;
  end if;
  select count(*) into v_audit_after from public.activity_logs where entity_type = 'invoice' and entity_id = p_inv and action = 'carrier_invoice_payment_recorded';
  if v_audit_after <> v_audit_before then
    raise exception 'TEST FAIL (%): no carrier_invoice_payment_recorded audit event should have been written, got %.', p_label, v_result;
  end if;
  if exists (
    select 1 from public.carrier_invoice_lifecycle_idempotency
    where operation = 'record_carrier_invoice_payment' and idempotency_key = v_idem_key
  ) then
    raise exception 'TEST FAIL (%): no idempotency success row should have been stored for a rejected request, got %.', p_label, v_result;
  end if;

  execute 'reset role';
  alter table public.carrier_invoice_issuance_snapshots disable trigger a0142_guard_snapshot_immutable;
  update public.carrier_invoice_issuance_snapshots set snapshot_payload = v_orig where invoice_id = p_inv;
  alter table public.carrier_invoice_issuance_snapshots enable trigger a0142_guard_snapshot_immutable;
  execute 'set role authenticated';

  return v_result;
end;
$fn$;

\echo '----- G1. factoring object missing -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, v_orig - 'factoring', 'G1', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G1): %.', v_result;
end
$t$;

\echo '----- G2. factoring mode missing (factoring present but empty) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{factoring}', '{}'::jsonb), 'G2', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G2): %.', v_result;
end
$t$;

\echo '----- G3. unknown factoring mode (canonical key, bogus value) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{factoring}', '{"mode":"bogus"}'::jsonb), 'G3', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G3): %.', v_result;
end
$t$;

\echo '----- G4. wrong carrier ID (issuer.carrier_id disagrees with the relational carrier_id) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{issuer,carrier_id}', to_jsonb('00000000-0000-0000-0000-000000000099'::uuid)), 'G4', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G4): %.', v_result;
end
$t$;

\echo '----- G5. wrong invoice ID (snapshot invoice_id disagrees with the row being paid) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{invoice_id}', to_jsonb('00000000-0000-0000-0000-000000000098'::uuid)), 'G5', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G5): %.', v_result;
end
$t$;

\echo '----- G6. wrong document type (snapshot disagrees with the relational invoice_document_type column) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{invoice_document_type}', '"dispatch_service_invoice"'::jsonb), 'G6', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G6): %.', v_result;
end
$t$;

\echo '----- G7. wrong currency (snapshot disagrees with the relational currency column) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{currency}', '"EUR"'::jsonb), 'G7', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G7): %.', v_result;
end
$t$;

\echo '----- G8. wrong total (snapshot disagrees with the relational total_amount column) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{total_amount}', '999999.99'::jsonb), 'G8', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G8): %.', v_result;
end
$t$;

\echo '----- G9. factor object present on a dispatch-service invoice -----'
do $t$
declare v_inv uuid := current_setting('test.g_dsi')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(
    v_inv,
    jsonb_set(v_orig, '{factoring}', '{"mode":"factored","relationship_id":"fe480000-0000-0000-0000-000000000001","company_id":"fc480000-0000-0000-0000-000000000001"}'::jsonb),
    'G9', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G9): %.', v_result;
end
$t$;

\echo '----- G10. factoring null on a freight invoice (freight NEVER legitimately encodes direct as null -- SECTION A.1) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{factoring}', 'null'::jsonb), 'G10', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G10): %.', v_result;
end
$t$;

\echo '----- G11. recipient payer type inconsistent with the invoice (snapshot says customer, relational recipient_type is broker) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{recipient,type}', '"customer"'::jsonb), 'G11', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (G11): %.', v_result;
end
$t$;

\echo '----- G12. every base invoice''s snapshot is back to its pristine, genuinely-issued state -----'
do $t$
declare v_freight uuid := current_setting('test.g_freight')::uuid; v_dsi uuid := current_setting('test.g_dsi')::uuid;
begin
  if (select snapshot_payload from public.carrier_invoice_issuance_snapshots where invoice_id = v_freight)::text
     <> current_setting('test.g_freight_pristine') then
    raise exception 'TEST FAIL (G12): the freight base invoice''s snapshot was not fully restored.';
  end if;
  if (select snapshot_payload from public.carrier_invoice_issuance_snapshots where invoice_id = v_dsi)::text
     <> current_setting('test.g_dsi_pristine') then
    raise exception 'TEST FAIL (G12): the dispatch-service base invoice''s snapshot was not fully restored.';
  end if;
  if (select amount_paid from public.carrier_invoices where id = v_freight) <> 0
     or (select amount_paid from public.carrier_invoices where id = v_dsi) <> 0 then
    raise exception 'TEST FAIL (G12): a malformed-snapshot case must never have posted a real payment.';
  end if;
  raise notice 'OK (G12): both base invoices'' snapshots restored exactly; zero real payment ever posted across all 11 malformed cases.';
end
$t$;

-- ---------------------------------------------------------------------------
-- H. External-reference hygiene (Phase 3B.5.1, Section F). No real
-- sensitive data is embedded -- "4111111111111111" is the industry-standard
-- PUBLIC test-only Visa number (never a real card); the rest are
-- synthetic/obviously-fake strings shaped like the thing being rejected.
-- ---------------------------------------------------------------------------
\echo '----- H1. external reference shaped like a card number -> INVALID_EXTERNAL_REFERENCE -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 1.00, current_date, 'credit_card', '4111 1111 1111 1111',
    (select updated_at from public.carrier_invoices where id = v_inv), 'H1', 'h1-key');
  if v_result->>'code' <> 'INVALID_EXTERNAL_REFERENCE' then raise exception 'TEST FAIL (H1): expected INVALID_EXTERNAL_REFERENCE, got %.', v_result; end if;
  if v_result::text ilike '%4111%' then raise exception 'TEST FAIL (H1): the submitted reference must never be echoed back, got %.', v_result; end if;
  raise notice 'OK (H1): %.', v_result;
end
$t$;

\echo '----- H2. external reference shaped like a routing+account number -> INVALID_EXTERNAL_REFERENCE -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 1.00, current_date, 'ach', '021000021-1234567890123',
    (select updated_at from public.carrier_invoices where id = v_inv), 'H2', 'h2-key');
  if v_result->>'code' <> 'INVALID_EXTERNAL_REFERENCE' then raise exception 'TEST FAIL (H2): expected INVALID_EXTERNAL_REFERENCE, got %.', v_result; end if;
  raise notice 'OK (H2): %.', v_result;
end
$t$;

\echo '----- H3. external reference containing a control character -> INVALID_EXTERNAL_REFERENCE -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 1.00, current_date, 'check', 'CHK-000' || chr(7) || '123',
    (select updated_at from public.carrier_invoices where id = v_inv), 'H3', 'h3-key');
  if v_result->>'code' <> 'INVALID_EXTERNAL_REFERENCE' then raise exception 'TEST FAIL (H3): expected INVALID_EXTERNAL_REFERENCE, got %.', v_result; end if;
  raise notice 'OK (H3): %.', v_result;
end
$t$;

\echo '----- H4. external reference containing a labeled credential keyword -> INVALID_EXTERNAL_REFERENCE -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 1.00, current_date, 'credit_card', 'CVV 123 on file',
    (select updated_at from public.carrier_invoices where id = v_inv), 'H4', 'h4-key');
  if v_result->>'code' <> 'INVALID_EXTERNAL_REFERENCE' then raise exception 'TEST FAIL (H4): expected INVALID_EXTERNAL_REFERENCE, got %.', v_result; end if;
  raise notice 'OK (H4): %.', v_result;
end
$t$;

\echo '----- H5. external reference shaped like an API token -> INVALID_EXTERNAL_REFERENCE -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_result jsonb;
begin
  -- Constructed dynamically so repository secret scanners do not mistake
  -- this synthetic negative-test value for a real credential.
  v_result := public.record_carrier_invoice_payment(
    v_inv, 1.00, current_date, 'other', concat('sk_', 'live_', 'FAKE_TEST_TOKEN_0146'),
    (select updated_at from public.carrier_invoices where id = v_inv), 'H5', 'h5-key');
  if v_result->>'code' <> 'INVALID_EXTERNAL_REFERENCE' then raise exception 'TEST FAIL (H5): expected INVALID_EXTERNAL_REFERENCE, got %.', v_result; end if;
  raise notice 'OK (H5): %.', v_result;
end
$t$;

\echo '----- H6. external reference too long (>100 chars) -> INVALID_EXTERNAL_REFERENCE -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 1.00, current_date, 'wire', repeat('X', 101),
    (select updated_at from public.carrier_invoices where id = v_inv), 'H6', 'h6-key');
  if v_result->>'code' <> 'INVALID_EXTERNAL_REFERENCE' then raise exception 'TEST FAIL (H6): expected INVALID_EXTERNAL_REFERENCE, got %.', v_result; end if;
  raise notice 'OK (H6): %.', v_result;
end
$t$;

\echo '----- H7. an ordinary short check/wire reference is accepted normally (no false positive) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_result jsonb;
begin
  v_result := public.record_carrier_invoice_payment(
    v_inv, 5.00, current_date, 'check', 'CHK-000123',
    (select updated_at from public.carrier_invoices where id = v_inv), 'H7', 'h7-key');
  if v_result->>'code' <> 'PAYMENT_RECORDED' then raise exception 'TEST FAIL (H7): expected PAYMENT_RECORDED for an ordinary reference, got %.', v_result; end if;
  if (select external_reference from public.carrier_invoice_payments where id = (v_result->>'payment_id')::uuid) <> 'CHK-000123' then
    raise exception 'TEST FAIL (H7): the normalized reference should be stored verbatim (trimmed).';
  end if;
  raise notice 'OK (H7): %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- I. Version failure tests (Phase 3B.5.2, Section G). Every case fails
-- closed BEFORE the version-gate lets shape validation run; each expects
-- exactly SNAPSHOT_VERSION_UNSUPPORTED, never SNAPSHOT_INTEGRITY_ERROR --
-- distinguishing "wrong/unknown version" from "version 2 but malformed"
-- is the entire point of this section. pg_temp.g_check_malformed already
-- asserts zero payment row/zero audit event/zero idempotency-success row
-- for every case.
-- ---------------------------------------------------------------------------
\echo '----- I1. version 1, exact 0144-original shape (direct=null factoring) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_corrupt jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_corrupt := jsonb_set(jsonb_set(v_orig, '{schema_version}', '1'::jsonb), '{factoring}', 'null'::jsonb);
  v_result := pg_temp.g_check_malformed(v_inv, v_corrupt, 'I1', 'SNAPSHOT_VERSION_UNSUPPORTED');
  raise notice 'OK (I1): %.', v_result;
end
$t$;

\echo '----- I2. version 1, exact 0145-redefinition shape (direct={"factoring_mode":"direct"}) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_corrupt jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_corrupt := jsonb_set(jsonb_set(v_orig, '{schema_version}', '1'::jsonb), '{factoring}', '{"factoring_mode":"direct"}'::jsonb);
  v_result := pg_temp.g_check_malformed(v_inv, v_corrupt, 'I2', 'SNAPSHOT_VERSION_UNSUPPORTED');
  raise notice 'OK (I2): %.', v_result;
end
$t$;

\echo '----- I3. version 1, dispatch-service shape -----'
do $t$
declare v_inv uuid := current_setting('test.g_dsi')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{schema_version}', '1'::jsonb), 'I3', 'SNAPSHOT_VERSION_UNSUPPORTED');
  raise notice 'OK (I3): %.', v_result;
end
$t$;

\echo '----- I4. schema_version key missing entirely -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, v_orig - 'schema_version', 'I4', 'SNAPSHOT_VERSION_UNSUPPORTED');
  raise notice 'OK (I4): %.', v_result;
end
$t$;

\echo '----- I5. schema_version is JSON null -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{schema_version}', 'null'::jsonb), 'I5', 'SNAPSHOT_VERSION_UNSUPPORTED');
  raise notice 'OK (I5): %.', v_result;
end
$t$;

\echo '----- I6. schema_version is a string, not a number -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{schema_version}', '"2"'::jsonb), 'I6', 'SNAPSHOT_VERSION_UNSUPPORTED');
  raise notice 'OK (I6): %.', v_result;
end
$t$;

\echo '----- I7. schema_version 3 / unknown future version -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{schema_version}', '3'::jsonb), 'I7', 'SNAPSHOT_VERSION_UNSUPPORTED');
  raise notice 'OK (I7): %.', v_result;
end
$t$;

\echo '----- I8. malformed version 2 (version passes the gate, shape is broken) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, v_orig - 'issuer', 'I8', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (I8): %.', v_result;
end
$t$;

\echo '----- I9. alias field factoring_mode instead of canonical mode (version 2, no accidental alias support) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(v_inv, jsonb_set(v_orig, '{factoring}', '{"factoring_mode":"direct"}'::jsonb), 'I9', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (I9): %.', v_result;
end
$t$;

\echo '----- I10. mixed version-1/version-2 fields (schema_version=2, old relationship-id key name) -----'
do $t$
declare v_inv uuid := current_setting('test.g_freight')::uuid; v_orig jsonb; v_result jsonb;
begin
  select snapshot_payload into v_orig from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  v_result := pg_temp.g_check_malformed(
    v_inv,
    jsonb_set(v_orig, '{factoring}', '{"mode":"factored","factoring_relationship_id":"fe480000-0000-0000-0000-000000000001","company_legal_name":"Factor 0146 LLC"}'::jsonb),
    'I10', 'SNAPSHOT_INTEGRITY_ERROR');
  raise notice 'OK (I10): %.', v_result;
end
$t$;

\echo '----- I11. both base invoices'' snapshots and balances remain pristine after all version-failure cases -----'
do $t$
declare v_freight uuid := current_setting('test.g_freight')::uuid; v_dsi uuid := current_setting('test.g_dsi')::uuid;
begin
  if (select snapshot_payload from public.carrier_invoice_issuance_snapshots where invoice_id = v_freight)::text
     <> current_setting('test.g_freight_pristine') then
    raise exception 'TEST FAIL (I11): the freight base invoice''s snapshot was not fully restored.';
  end if;
  if (select snapshot_payload from public.carrier_invoice_issuance_snapshots where invoice_id = v_dsi)::text
     <> current_setting('test.g_dsi_pristine') then
    raise exception 'TEST FAIL (I11): the dispatch-service base invoice''s snapshot was not fully restored.';
  end if;
  raise notice 'OK (I11): both base invoices'' snapshots restored exactly across all version-failure cases.';
end
$t$;

drop function pg_temp.g_check_malformed(uuid, jsonb, text, text);

\echo '################  TEST 0146 PASSED  ################'
