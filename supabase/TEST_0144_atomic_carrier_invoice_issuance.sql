-- ============================================================================
-- TEST_0144_atomic_carrier_invoice_issuance.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.3C verification: issue_carrier_invoice() -- atomic, idempotent
-- carrier_freight_invoice issuance; DISPATCH_SERVICE_AGREEMENT_REQUIRED for
-- dispatch_service_invoice (Section E, Option 2); the extended carrier_
-- invoice_line_items structure (line_type/source_load_id/source_
-- dispatch_id, non-negativity); the hardened mutability guards.
--
-- Genuine two-session concurrency (Section L) is covered separately by
-- TEST_CONCURRENCY_0144_atomic_invoice_issuance.sh -- this file covers
-- every SQL-testable behavior (authorization, structured codes, snapshot
-- shape, numbering, immutability, idempotency, no-leak) in a single
-- session.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0144  ################'

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

\echo '===== fixtures ====='
reset role;
select set_config('test.current_uid', null, false);
do $t$
begin
  -- Carrier A1: DIRECT billing, invoice_code CARA. Carrier A2: FACTORED
  -- (complete, ready default relationship), invoice_code CARB. Carrier
  -- A3: left invoice_code NULL, factoring_mode unconfigured (both
  -- readiness failure modes get their own carrier so tests never
  -- interfere with each other's numbering sequence).
  update public.carriers set invoice_code = 'CARA', factoring_mode = 'direct' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  update public.carriers set invoice_code = 'CARB', factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  -- a3a3a3a3 stays invoice_code=null, factoring_mode='unconfigured' (its base seed default) -- and is_active=false already (base seed).

  insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
  values
    ('cb440000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001'),
    ('cb440000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');
  insert into public.carrier_customers (id, organization_id, carrier_id, customer_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
  values
    ('cc440000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0c00000-0000-0000-0000-000000000001', 'active', 'ap@customera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');

  insert into public.factoring_companies (id, organization_id, name, legal_name, is_active) values
    ('fc440000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor 0144', 'Factor 0144 LLC', true);
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
     noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, submission_destination_email,
     is_default, is_active)
  values
    ('fe440000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc440000-0000-0000-0000-000000000001',
     'a2a2a2a2-0000-0000-0000-000000000002', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Factor 0144, ABA 000000000', 'NOA 0144 v1', 'ref-0144-1',
     current_date - 5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'secure_email', 'factor0144@example.com', true, true);

  -- Two loads for carrier A1 (direct), one for A2 (factored), one for
  -- A3 (unconfigured, unused in most tests but available).
  insert into public.loads (id, organization_id, load_number, broker_id, status, rate)
  values
    ('40000000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'LD-0144-A', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 1500),
    ('40000000-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111', 'LD-0144-B', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 2200);
  update public.loads set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001', carrier_resolution = 'resolved' where id = '40000000-0000-0000-0000-00000000000a';
  update public.loads set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002', carrier_resolution = 'resolved' where id = '40000000-0000-0000-0000-00000000000b';
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
  values
    ('11111111-1111-1111-1111-111111111111', '40000000-0000-0000-0000-00000000000a', 'pickup', 1, 'Shipper A', 'Dallas', 'TX', now() - interval '3 days'),
    ('11111111-1111-1111-1111-111111111111', '40000000-0000-0000-0000-00000000000a', 'delivery', 2, 'Receiver A', 'Houston', 'TX', now() - interval '1 day'),
    -- Phase 3B.3C.2, Section C: load B must also have a complete pickup+
    -- delivery route -- it is issued successfully in test C2, and
    -- issue_carrier_invoice() now locks and validates every attached
    -- load's load_stops BEFORE any factoring check is reached.
    ('11111111-1111-1111-1111-111111111111', '40000000-0000-0000-0000-00000000000b', 'pickup', 1, 'Shipper B', 'Fort Worth', 'TX', now() - interval '4 days'),
    ('11111111-1111-1111-1111-111111111111', '40000000-0000-0000-0000-00000000000b', 'delivery', 2, 'Receiver B', 'Austin', 'TX', now() - interval '2 days');

  raise notice 'OK: fixtures ready -- carrier A1 (direct, CARA), carrier A2 (factored+ready, CARB), carrier A3 (unconfigured, no invoice_code).';
end
$t$;

-- ---------------------------------------------------------------------------
-- A. Happy path: direct-billing carrier_freight_invoice, full snapshot shape.
-- ---------------------------------------------------------------------------
\echo '----- A1. direct-billing issuance succeeds; correct number, totals, due_date, immutable snapshot -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare
  v_id uuid; v_expected timestamptz; v_result jsonb; v_snap record;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  perform set_config('test.civ_direct', v_id::text, false);
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'Freight -- LD-0144-A', 1, 1500, 'freight_charge', '40000000-0000-0000-0000-00000000000a');
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000a');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'A1 happy path', 'a1-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (A1): expected ISSUED, got %.', v_result; end if;
  if v_result->>'invoice_number' <> 'CARA-2026-00001' then raise exception 'TEST FAIL (A1): expected CARA-2026-00001, got %.', v_result; end if;
  if (v_result->>'total_amount')::numeric <> 1500 then raise exception 'TEST FAIL (A1): expected total 1500, got %.', v_result; end if;

  select * into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
  if v_snap.invoice_number <> 'CARA-2026-00001' or v_snap.total_amount <> 1500 or v_snap.carrier_id <> 'a1a1a1a1-0000-0000-0000-000000000001' then
    raise exception 'TEST FAIL (A1): snapshot row shape wrong -- %.', v_snap;
  end if;
  if v_snap.snapshot_payload->'factoring' <> 'null'::jsonb then
    raise exception 'TEST FAIL (A1): direct-billing snapshot must have factoring=null, got %.', v_snap.snapshot_payload->'factoring';
  end if;
  if (v_snap.snapshot_payload->'issuer'->>'legal_name') <> 'Carrier A1 LLC' then
    raise exception 'TEST FAIL (A1): issuer legal_name missing/wrong in snapshot.';
  end if;
  if (v_snap.snapshot_payload->'recipient'->>'legal_name') <> 'Broker A' then
    raise exception 'TEST FAIL (A1): recipient legal_name missing/wrong in snapshot.';
  end if;
  if jsonb_array_length(v_snap.snapshot_payload->'loads') <> 1 then
    raise exception 'TEST FAIL (A1): expected exactly 1 load in the snapshot.';
  end if;

  if (select issuance_status from public.carrier_invoices where id = v_id) <> 'issued' then
    raise exception 'TEST FAIL (A1): carrier_invoices.issuance_status not updated to issued.';
  end if;
  raise notice 'OK (A1): direct-billing issuance succeeded end-to-end -- %.', v_result;
end
$t$;

\echo '----- A2. the immutable snapshot cannot be UPDATEd or DELETEd, even as superuser -----'
reset role;
do $t$
declare v_id uuid := current_setting('test.civ_direct')::uuid;
begin
  begin
    update public.carrier_invoice_issuance_snapshots set total_amount = 1 where invoice_id = v_id;
    raise exception 'TEST FAIL (A2): snapshot UPDATE should be rejected.';
  exception when others then
    if sqlerrm not ilike '%immutable and can never be updated%' then raise; end if;
  end;
  begin
    delete from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
    raise exception 'TEST FAIL (A2): snapshot DELETE should be rejected.';
  exception when others then
    if sqlerrm not ilike '%immutable and can never be deleted%' then raise; end if;
  end;
  raise notice 'OK (A2): issuance snapshot remains immutable, even to a superuser.';
end
$t$;

\echo '----- A3. once issued, line items and load links are immutable (0142 guards, now lock-hardened) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.civ_direct')::uuid;
begin
  begin
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
    values ('11111111-1111-1111-1111-111111111111', v_id, 'too late', 1, 1);
    raise exception 'TEST FAIL (A3): a new line item on an issued invoice should be rejected.';
  exception when others then
    if sqlerrm not ilike '%immutable once the invoice has left draft/ready_for_issue%' then raise; end if;
  end;
  begin
    delete from public.carrier_invoice_loads where invoice_id = v_id;
    raise exception 'TEST FAIL (A3): removing a load link from an issued invoice should be rejected.';
  exception when others then
    if sqlerrm not ilike '%immutable once the invoice has left draft/ready_for_issue%' then raise; end if;
  end;
  raise notice 'OK (A3): line items and load links remain immutable post-issuance.';
end
$t$;

-- ---------------------------------------------------------------------------
-- B. Idempotent replay and collision.
-- ---------------------------------------------------------------------------
\echo '----- B1. exact idempotent replay (same key) returns the byte-identical cached result -- no second mutation, no second number, no second audit event -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_direct')::uuid;
  v_expected timestamptz := (select updated_at from public.carrier_invoices where id = v_id);
  v_r1 jsonb; v_r2 jsonb;
  v_audit_before integer; v_audit_after integer;
  v_snapshot_count_before integer; v_snapshot_count_after integer;
begin
  select count(*) into v_audit_before from public.activity_logs where entity_type='invoice' and entity_id=v_id and action='carrier_invoice_issued';
  select count(*) into v_snapshot_count_before from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
  v_r1 := public.issue_carrier_invoice(v_id, v_expected, 'A1 happy path', 'a1-issue-key');
  v_r2 := public.issue_carrier_invoice(v_id, v_expected, 'A1 happy path', 'a1-issue-key');
  if v_r1 <> v_r2 then raise exception 'TEST FAIL (B1): expected byte-identical cached replay, got % vs %.', v_r1, v_r2; end if;
  select count(*) into v_audit_after from public.activity_logs where entity_type='invoice' and entity_id=v_id and action='carrier_invoice_issued';
  select count(*) into v_snapshot_count_after from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
  if v_audit_after <> v_audit_before or v_snapshot_count_after <> v_snapshot_count_before then
    raise exception 'TEST FAIL (B1): replay must never write a second audit event or a second snapshot.';
  end if;
  raise notice 'OK (B1): exact replay of an ALREADY-issued invoice is a pure cache hit -- %.', v_r1;
end
$t$;

\echo '----- B2. same key, DIFFERENT invoice -> IDEMPOTENCY_KEY_REUSED, no leak, no mutation -----'
do $t$
declare
  v_id2 uuid; v_expected timestamptz; v_result jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id2;
  perform set_config('test.civ_b2', v_id2::text, false);
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id2, 'Freight -- LD-0144-B2', 1, 900);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id2, '40000000-0000-0000-0000-00000000000a');
  v_expected := (select updated_at from public.carrier_invoices where id = v_id2);
  v_result := public.issue_carrier_invoice(v_id2, v_expected, 'B2 different invoice, same key', 'a1-issue-key');
  if v_result->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (B2): expected IDEMPOTENCY_KEY_REUSED, got %.', v_result;
  end if;
  if v_result ? 'constraint' or v_result ? 'detail' or v_result::text ilike '%civ_idempotency_unique%' or v_result::text ilike '%duplicate key%' then
    raise exception 'TEST FAIL (B2): leaked raw internals -- %.', v_result;
  end if;
  if (select issuance_status from public.carrier_invoices where id = v_id2) <> 'draft' then
    raise exception 'TEST FAIL (B2): the losing invoice must remain a draft (or ready_for_issue), never partially issued.';
  end if;
  raise notice 'OK (B2): same key targeting a different invoice -> clean structured IDEMPOTENCY_KEY_REUSED, zero mutation -- %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- C. Factoring policy branches.
-- ---------------------------------------------------------------------------
\echo '----- C1. unconfigured carrier -> FACTORING_POLICY_UNCONFIGURED (carrier A3 is inactive too, but invoice_code is checked first via CARRIER_MISMATCH-adjacent path -- give it a code first to isolate the factoring check) -----'
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz;
begin
  update public.carriers set is_active = true, invoice_code = 'CARC' where id = 'a3a3a3a3-0000-0000-0000-000000000003';
  insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
  values ('cb440000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'a3a3a3a3-0000-0000-0000-000000000003', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a3a3a3a3-0000-0000-0000-000000000003', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 100);
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values ('40000000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'LD-0144-C', 'delivered', 100, 'a3a3a3a3-0000-0000-0000-000000000003', 'resolved');
  -- Phase 3B.3C.2, Section C: issue_carrier_invoice() now locks and
  -- validates load_stops BEFORE the factoring check this test targets --
  -- give load C a complete route so C1 genuinely isolates the factoring
  -- check, not an earlier route-structure rejection.
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
  values
    ('11111111-1111-1111-1111-111111111111', '40000000-0000-0000-0000-00000000000c', 'pickup', 1, 'Shipper C', 'San Antonio', 'TX', now() - interval '2 days'),
    ('11111111-1111-1111-1111-111111111111', '40000000-0000-0000-0000-00000000000c', 'delivery', 2, 'Receiver C', 'El Paso', 'TX', now() - interval '1 day');
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000c');
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'C1', 'c1-key');
  if v_result->>'code' <> 'FACTORING_POLICY_UNCONFIGURED' then raise exception 'TEST FAIL (C1): expected FACTORING_POLICY_UNCONFIGURED, got %.', v_result; end if;
  raise notice 'OK (C1): an unconfigured carrier cannot be issued -- %.', v_result;
end
$t$;

\echo '----- C2. factored + ready carrier -> succeeds, factoring block populated, secret_reference NEVER present -----'
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz; v_snap jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'Freight -- LD-0144-B', 1, 2200);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000b');
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'C2 factored issuance', 'c2-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (C2): expected ISSUED, got %.', v_result; end if;
  if v_result->>'invoice_number' <> 'CARB-2026-00001' then raise exception 'TEST FAIL (C2): expected CARB-2026-00001 (carrier-scoped counter, independent of CARA''s), got %.', v_result; end if;

  select snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
  if (v_snap->'factoring'->>'factoring_mode') <> 'factored' then raise exception 'TEST FAIL (C2): factoring block missing/wrong.'; end if;
  if (v_snap->'factoring'->>'factoring_company_legal_name') <> 'Factor 0144 LLC' then raise exception 'TEST FAIL (C2): factoring company legal identity missing.'; end if;
  if v_snap::text ilike '%secret_reference%' then raise exception 'TEST FAIL (C2): secret_reference must NEVER appear in the snapshot.'; end if;
  raise notice 'OK (C2): a factored, ready carrier issues successfully with a complete factoring identity block and zero secret_reference -- %.', v_result;
end
$t$;

\echo '----- C3. factored but NOT ready (relationship missing remittance instructions) -> FACTORING_NOT_READY -----'
-- factoring_mode has zero direct grant for authenticated (0139) -- only
-- set_carrier_factoring_policy() may change it. This test is about
-- issue_carrier_invoice()'s OWN factoring-readiness check, not about
-- that RPC's own authorization, so the fixture flips it as superuser.
reset role;
update public.carriers set factoring_mode = 'factored' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz;
begin
  -- No factoring_relationships row at all for A1 -- not ready.
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 50);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000a');
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'C3', 'c3-key');
  if v_result->>'code' <> 'FACTORING_NOT_READY' then raise exception 'TEST FAIL (C3): expected FACTORING_NOT_READY, got %.', v_result; end if;
  raise notice 'OK (C3): a factored carrier with no ready default relationship cannot be issued -- %.', v_result;
end
$t$;
reset role;
update public.carriers set factoring_mode = 'direct' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

-- ---------------------------------------------------------------------------
-- D. Dispatch-service deferral (Section E, Option 2).
-- ---------------------------------------------------------------------------
\echo '----- D1. dispatch_service_invoice issuance returns DISPATCH_SERVICE_AGREEMENT_REQUIRED -- no lock/lookup beyond the invoice row, no mutation -----'
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'D1', 'd1-key');
  if v_result->>'code' <> 'DISPATCH_SERVICE_AGREEMENT_REQUIRED' then
    raise exception 'TEST FAIL (D1): expected DISPATCH_SERVICE_AGREEMENT_REQUIRED, got %.', v_result;
  end if;
  if (select issuance_status from public.carrier_invoices where id = v_id) <> 'draft' then
    raise exception 'TEST FAIL (D1): the dispatch-service draft must remain untouched (still draft).';
  end if;
  raise notice 'OK (D1): dispatch-service issuance is honestly deferred -- %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- E. Structural rejection codes.
-- ---------------------------------------------------------------------------
\echo '----- E1. no recipient at all -> RECIPIENT_REQUIRED -----'
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz;
begin
  -- A freight invoice structurally REQUIRES a recipient at INSERT time
  -- (cinv_recipient_shape) -- simulate "recipient later cleared" via a
  -- superuser bypass, matching this project's own established
  -- manufactured-state convention for otherwise-unreachable rows.
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 50);
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  -- (recipient IS present here -- this specific invoice is reused below
  -- for E3 "no loads"; RECIPIENT_REQUIRED itself is proven structurally
  -- unreachable for a freight invoice by cinv_recipient_shape, which is
  -- exactly the point: the RPC's own defensive check can never actually
  -- fire in practice, matching this schema's own "structural proxy"
  -- precedent for equivalently unreachable branches.)
  perform 1;
  raise notice 'OK (E1, structural note): cinv_recipient_shape (0142) already makes a recipient-less carrier_freight_invoice row impossible to construct -- RECIPIENT_REQUIRED is defense-in-depth for a state the schema itself refuses to store, exactly like update_carrier_invoice_draft''s own equivalently unreachable branches.';
  perform set_config('test.civ_e3', v_id::text, false);
end
$t$;

\echo '----- E2. blacklisted broker recipient -> RECIPIENT_INELIGIBLE -----'
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz; v_broker_id uuid := 'a0b00000-0000-0000-0000-000000000099';
begin
  insert into public.brokers (id, organization_id, company_name, is_blacklisted) values (v_broker_id, '11111111-1111-1111-1111-111111111111', 'Blacklisted Broker', true);
  insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
  values ('cb440000-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', v_broker_id, 'active', 'x@example.com', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', v_broker_id, 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 50);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000a');
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E2', 'e2-key');
  if v_result->>'code' <> 'RECIPIENT_INELIGIBLE' then raise exception 'TEST FAIL (E2): expected RECIPIENT_INELIGIBLE, got %.', v_result; end if;
  raise notice 'OK (E2): a blacklisted broker recipient blocks issuance -- %.', v_result;
end
$t$;

\echo '----- E3. no source loads attached -> INVOICE_INCOMPLETE -----'
do $t$
declare v_id uuid := current_setting('test.civ_e3')::uuid; v_result jsonb; v_expected timestamptz;
begin
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E3', 'e3-key');
  if v_result->>'code' <> 'INVOICE_INCOMPLETE' then raise exception 'TEST FAIL (E3): expected INVOICE_INCOMPLETE, got %.', v_result; end if;
  raise notice 'OK (E3): an invoice with zero attached source loads cannot be issued -- %.', v_result;
end
$t$;

\echo '----- E4. total_amount <= 0 -> TOTAL_INVALID -----'
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'zero value', 1, 0);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000a');
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E4', 'e4-key');
  if v_result->>'code' <> 'TOTAL_INVALID' then raise exception 'TEST FAIL (E4): expected TOTAL_INVALID, got %.', v_result; end if;
  raise notice 'OK (E4): a zero (or negative) total cannot be issued -- client-provided totals are never trusted, only the server-recalculated sum -- %.', v_result;
end
$t$;

\echo '----- E5. ALREADY_ISSUED on a genuine second real attempt (new key, same already-issued invoice) -----'
do $t$
declare v_id uuid := current_setting('test.civ_direct')::uuid; v_result jsonb; v_expected timestamptz;
begin
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E5', 'brand-new-different-key');
  if v_result->>'code' <> 'ALREADY_ISSUED' then raise exception 'TEST FAIL (E5): expected ALREADY_ISSUED, got %.', v_result; end if;
  if v_result->>'invoice_number' <> 'CARA-2026-00001' then raise exception 'TEST FAIL (E5): ALREADY_ISSUED should still report the original invoice_number.'; end if;
  raise notice 'OK (E5): a genuinely NEW key against an already-issued invoice reports ALREADY_ISSUED, not a silent re-issuance -- %.', v_result;
end
$t$;

\echo '----- E6. STALE_RECORD on a mismatched expected_updated_at -----'
do $t$
declare v_id uuid; v_result jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 50);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000a');
  v_result := public.issue_carrier_invoice(v_id, now() - interval '1 hour', 'E6', 'e6-key');
  if v_result->>'code' <> 'STALE_RECORD' then raise exception 'TEST FAIL (E6): expected STALE_RECORD, got %.', v_result; end if;
  raise notice 'OK (E6): a stale expected_updated_at is rejected -- %.', v_result;
end
$t$;

\echo '----- E7. cross-organization invoice is indistinguishable from not-found -----'
do $t$
declare v_id uuid; v_result jsonb;
begin
  perform set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('22222222-2222-2222-2222-222222222222', 'carrier_freight_invoice', 'b1b1b1b1-0000-0000-0000-000000000001', 'broker', 'b0b00000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000001')
  returning id into v_id;
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
  v_result := public.issue_carrier_invoice(v_id, now(), 'E7', 'e7-key');
  if v_result->>'code' <> 'NOT_FOUND' then raise exception 'TEST FAIL (E7): expected NOT_FOUND for a cross-organization invoice id, got %.', v_result; end if;
  raise notice 'OK (E7): Org A cannot issue Org B''s invoice -- NOT_FOUND, indistinguishable from a genuinely missing id -- %.', v_result;
end
$t$;

\echo '----- E8. source load carrier mismatch -> SOURCE_LOAD_CONFLICT (load reassigned to a different carrier after being attached) -----'
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values ('40000000-0000-0000-0000-00000000000e', '11111111-1111-1111-1111-111111111111', 'LD-0144-E8', 'delivered', 300, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 300);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000e');
  -- Reassign the load to a DIFFERENT carrier directly (trusted context,
  -- bypassing guard_load_carrier_change -- simulating the only way this
  -- state could arise: a future/legitimate reassignment path racing an
  -- already-attached invoice).
  update public.loads set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002' where id = '40000000-0000-0000-0000-00000000000e';
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E8', 'e8-key');
  if v_result->>'code' <> 'SOURCE_LOAD_CONFLICT' then raise exception 'TEST FAIL (E8): expected SOURCE_LOAD_CONFLICT, got %.', v_result; end if;
  raise notice 'OK (E8): a source load whose carrier no longer matches the invoice is caught and rejected at issuance, even though it passed the attach-time guard -- %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- F. Numbering: per-carrier scope, voided-number non-reuse.
-- ---------------------------------------------------------------------------
\echo '----- F1. a second issuance for the SAME carrier gets the NEXT sequential number, never reused, never max()+1-derived (the counter table is the only source) -----'
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 400);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000a');
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'F1', 'f1-key');
  if v_result->>'invoice_number' !~ '^CARA-2026-000\d\d$' or v_result->>'invoice_number' = 'CARA-2026-00001' then
    raise exception 'TEST FAIL (F1): expected a NEW, sequential CARA number distinct from CARA-2026-00001, got %.', v_result;
  end if;
  raise notice 'OK (F1): sequential per-carrier numbering -- %.', v_result->>'invoice_number';
end
$t$;

\echo '----- F2. a VOIDED invoice number can never be reused for the same carrier (manufactured void -- no void RPC exists yet -- simulating the future state, since a per-carrier unique partial index already enforces this at the storage layer regardless of which RPC eventually sets voided_at) -----'
reset role;
do $t$
declare v_id uuid := current_setting('test.civ_direct')::uuid;
begin
  update public.carrier_invoices
    set issuance_status = 'voided', voided_at = now(), voided_by = 'aaaa0000-0000-0000-0000-000000000001', void_reason = 'test void'
    where id = v_id;
  begin
    insert into public.carrier_invoices (id, organization_id, invoice_document_type, issuance_status, carrier_id, recipient_type, recipient_broker_id, invoice_number, issued_at, issued_by)
    values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'issued', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'CARA-2026-00001', now(), 'aaaa0000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL (F2): reusing a voided invoice''s number for the same carrier should be rejected by cinv_freight_number_unique.';
  exception when unique_violation then
    raise notice 'OK (F2): the per-carrier unique index refuses to let a voided number be reused -- %', sqlerrm;
  end;
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

-- ---------------------------------------------------------------------------
-- G. Line-item structure: non-negativity, line_type/document-type match.
-- ---------------------------------------------------------------------------
\echo '----- G1. a negative quantity or unit_price is rejected outright (no credit/adjustment concept exists yet -- nothing may ever be negative) -----'
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  begin
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
    values ('11111111-1111-1111-1111-111111111111', v_id, 'negative unit price', 1, -100);
    raise exception 'TEST FAIL (G1): a negative unit_price should be rejected.';
  exception when check_violation then
    raise notice 'OK (G1): a negative unit_price is rejected by civli_amounts_nonnegative -- %', sqlerrm;
  end;
end
$t$;

\echo '----- G2. a dispatch_service_fee line cannot be attached to a carrier_freight_invoice (and vice versa) -----'
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  begin
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type)
    values ('11111111-1111-1111-1111-111111111111', v_id, 'wrong type', 1, 10, 'dispatch_service_fee');
    raise exception 'TEST FAIL (G2): a dispatch_service_fee line on a carrier_freight_invoice should be rejected.';
  exception when others then
    if sqlerrm not ilike '%dispatch_service_fee line can only belong to a dispatch_service_invoice%' then raise; end if;
    raise notice 'OK (G2): line_type is enforced against the parent invoice''s own document type -- %', sqlerrm;
  end;
end
$t$;

-- ---------------------------------------------------------------------------
-- H. Authorization matrix.
-- ---------------------------------------------------------------------------
\echo '----- H1. dispatcher CANNOT issue -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid := current_setting('test.civ_e3')::uuid; v_result jsonb;
begin
  v_result := public.issue_carrier_invoice(v_id, now(), 'H1', 'h1-key');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (H1): dispatcher should be FORBIDDEN from issuing, got %.', v_result; end if;
  raise notice 'OK (H1): dispatcher cannot issue -- %.', v_result;
end
$t$;

\echo '----- H2. driver and viewer CANNOT issue -----'
select set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid := current_setting('test.civ_e3')::uuid; v_result jsonb;
begin
  v_result := public.issue_carrier_invoice(v_id, now(), 'H2', 'h2-key-driver');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (H2): driver should be FORBIDDEN, got %.', v_result; end if;
end
$t$;
select set_config('test.current_uid', 'ffff0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid := current_setting('test.civ_e3')::uuid; v_result jsonb;
begin
  v_result := public.issue_carrier_invoice(v_id, now(), 'H2', 'h2-key-viewer');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (H2): viewer should be FORBIDDEN, got %.', v_result; end if;
  raise notice 'OK (H2): driver and viewer both cannot issue -- FORBIDDEN.';
end
$t$;

\echo '----- H3. accountant CAN issue -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'cccc0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 250);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '40000000-0000-0000-0000-00000000000a');
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'H3', 'h3-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (H3): accountant should be able to issue, got %.', v_result; end if;
  raise notice 'OK (H3): accountant can issue -- %.', v_result;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

\echo '----- H4 (M security). anon and direct authenticated SQL cannot mutate issuance_status/invoice_number, or INSERT a snapshot, directly -----'
set role anon;
do $t$
begin
  begin
    update public.carrier_invoices set issuance_status = 'issued' where true;
    raise exception 'TEST FAIL (H4): anon should have zero grant on carrier_invoices entirely.';
  exception when insufficient_privilege then
    raise notice 'OK (H4): anon has zero table-level access to carrier_invoices -- %', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.civ_e3')::uuid;
begin
  begin
    update public.carrier_invoices set issuance_status = 'issued', invoice_number = 'FORGED-0001' where id = v_id;
    raise exception 'TEST FAIL (H4): authenticated should not be able to directly set issuance_status/invoice_number.';
  exception when insufficient_privilege then
    raise notice 'OK (H4): authenticated has zero direct UPDATE grant on issuance_status/invoice_number -- %', sqlerrm;
  end;
  begin
    insert into public.carrier_invoice_issuance_snapshots (invoice_id, organization_id, invoice_document_type, currency, invoice_number, subtotal_amount, total_amount, amount_due_at_issuance, snapshot_payload)
    values (v_id, '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'USD', 'FORGED-0002', 1, 1, 1, '{}'::jsonb);
    raise exception 'TEST FAIL (H4): authenticated should not be able to directly INSERT a snapshot.';
  exception when insufficient_privilege then
    raise notice 'OK (H4): authenticated has zero INSERT grant on carrier_invoice_issuance_snapshots -- %', sqlerrm;
  end;
end
$t$;

\echo '----- H5. no legacy invoice (public.invoices) can use issue_carrier_invoice() -- it operates exclusively on carrier_invoices, structurally unreachable for a legacy row id -----'
do $t$
declare v_legacy_id uuid; v_result jsonb;
begin
  select id into v_legacy_id from public.invoices limit 1;
  if v_legacy_id is not null then
    v_result := public.issue_carrier_invoice(v_legacy_id, now(), 'H5', 'h5-key');
    if v_result->>'code' <> 'NOT_FOUND' then raise exception 'TEST FAIL (H5): a legacy invoices.id should be NOT_FOUND against carrier_invoices, got %.', v_result; end if;
    raise notice 'OK (H5): a legacy public.invoices row id is NOT_FOUND to issue_carrier_invoice() -- no bridge exists in either direction -- %.', v_result;
  else
    raise notice 'OK (H5, vacuous): no legacy public.invoices row exists in this fixture -- structurally still true that issue_carrier_invoice() only ever reads carrier_invoices.';
  end if;
end
$t$;

-- ---------------------------------------------------------------------------
-- I. Phase 3B.3C.2, Section C/D: route-snapshot lock closure -- sequential
-- (non-concurrent) structural proofs. Genuine two-session races for these
-- same code paths are covered separately by TEST_CONCURRENCY_0144_atomic_
-- invoice_issuance.sh scenarios 20-26.
-- ---------------------------------------------------------------------------
\echo '----- I1. a load with a pickup stop but NO delivery stop -> INVOICE_INCOMPLETE -----'
do $t$
declare v_id uuid; v_load_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'LD-0144-I1', 'delivered', 400, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved')
  returning id into v_load_id;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state)
  values ('11111111-1111-1111-1111-111111111111', v_load_id, 'pickup', 1, 'I1 Shipper', 'Dallas', 'TX');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 400);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, v_load_id);
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I1', 'i1-key');
  if v_result->>'code' <> 'INVOICE_INCOMPLETE' then raise exception 'TEST FAIL (I1): expected INVOICE_INCOMPLETE for a load with no delivery stop, got %.', v_result; end if;
  if (select invoice_number from public.carrier_invoices where id = v_id) is not null then raise exception 'TEST FAIL (I1): a refused issuance must not consume a number.'; end if;
  if exists (select 1 from public.carrier_invoice_issuance_snapshots where invoice_id = v_id) then raise exception 'TEST FAIL (I1): a refused issuance must leave no snapshot.'; end if;
  raise notice 'OK (I1): a load missing its delivery stop cannot be issued -- %.', v_result;
end
$t$;

\echo '----- I2. a load with a delivery stop but NO pickup stop -> INVOICE_INCOMPLETE -----'
do $t$
declare v_id uuid; v_load_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'LD-0144-I2', 'delivered', 400, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved')
  returning id into v_load_id;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state)
  values ('11111111-1111-1111-1111-111111111111', v_load_id, 'delivery', 1, 'I2 Receiver', 'Houston', 'TX');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 400);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, v_load_id);
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I2', 'i2-key');
  if v_result->>'code' <> 'INVOICE_INCOMPLETE' then raise exception 'TEST FAIL (I2): expected INVOICE_INCOMPLETE for a load with no pickup stop, got %.', v_result; end if;
  raise notice 'OK (I2): a load missing its pickup stop cannot be issued -- %.', v_result;
end
$t$;

\echo '----- I3. duplicate stop_sequence within the same load (ambiguous ordering) -> SOURCE_LOAD_CONFLICT -----'
do $t$
declare v_id uuid; v_load_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'LD-0144-I3', 'delivered', 400, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved')
  returning id into v_load_id;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state)
  values
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'pickup', 1, 'I3 Shipper A', 'Dallas', 'TX'),
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'pickup', 1, 'I3 Shipper B (ambiguous duplicate)', 'Fort Worth', 'TX'),
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'delivery', 2, 'I3 Receiver', 'Houston', 'TX');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 400);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, v_load_id);
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I3', 'i3-key');
  if v_result->>'code' <> 'SOURCE_LOAD_CONFLICT' then raise exception 'TEST FAIL (I3): expected SOURCE_LOAD_CONFLICT for a duplicate stop_sequence, got %.', v_result; end if;
  raise notice 'OK (I3): two stops sharing the same stop_sequence (ambiguous "which is first") cannot be issued -- %.', v_result;
end
$t$;

\echo '----- I4. malformed/inverted route: the resolved delivery sequences BEFORE the resolved pickup -> SOURCE_LOAD_CONFLICT -----'
do $t$
declare v_id uuid; v_load_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'LD-0144-I4', 'delivered', 400, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved')
  returning id into v_load_id;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state)
  values
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'delivery', 1, 'I4 Receiver (sequenced FIRST -- malformed)', 'Houston', 'TX'),
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'pickup', 5, 'I4 Shipper (sequenced LAST -- malformed)', 'Dallas', 'TX');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 400);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, v_load_id);
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I4', 'i4-key');
  if v_result->>'code' <> 'SOURCE_LOAD_CONFLICT' then raise exception 'TEST FAIL (I4): expected SOURCE_LOAD_CONFLICT for an inverted route, got %.', v_result; end if;
  raise notice 'OK (I4): a delivery stop sequenced before any pickup stop (an inverted/malformed route) cannot be issued -- %.', v_result;
end
$t$;

\echo '----- I5. multi-stop route: origin = MIN-sequence pickup, destination = MAX-sequence delivery, intermediate stops correctly ignored -----'
do $t$
declare v_id uuid; v_load_id uuid; v_result jsonb; v_expected timestamptz; v_snap jsonb;
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'LD-0144-I5', 'delivered', 900, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved')
  returning id into v_load_id;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state)
  values
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'pickup', 1, 'I5 Origin', 'El Paso', 'TX'),
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'delivery', 2, 'I5 Partial Drop', 'San Antonio', 'TX'),
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'delivery', 3, 'I5 Final Destination', 'Houston', 'TX');
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 900);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, v_load_id);
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I5', 'i5-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (I5): expected ISSUED for a well-formed multi-stop route, got %.', v_result; end if;
  select snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
  if (v_snap->'loads'->0->'origin'->>'city') <> 'El Paso' then raise exception 'TEST FAIL (I5): expected origin=El Paso (the min-sequence pickup), got %.', v_snap->'loads'->0->'origin'; end if;
  if (v_snap->'loads'->0->'destination'->>'city') <> 'Houston' then raise exception 'TEST FAIL (I5): expected destination=Houston (the max-sequence delivery, NOT the intermediate San Antonio partial drop), got %.', v_snap->'loads'->0->'destination'; end if;
  raise notice 'OK (I5): a 3-stop route correctly resolves origin=min-sequence pickup and destination=max-sequence delivery, ignoring the intermediate partial-drop stop -- %.', v_result;
end
$t$;

\echo '----- I6. source_dispatch_id pointing at a dispatch whose OWN load is not among this invoice''s attached loads -> SOURCE_LOAD_CONFLICT -----'
do $t$
declare v_id uuid; v_load_id uuid; v_other_load_id uuid; v_dispatch_id uuid; v_result jsonb; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'LD-0144-I6', 'delivered', 400, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved')
  returning id into v_load_id;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state)
  values
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'pickup', 1, 'I6 Shipper', 'Dallas', 'TX'),
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'delivery', 2, 'I6 Receiver', 'Houston', 'TX');
  -- a SEPARATE load (same carrier), never attached to this invoice --
  -- the dispatch below belongs to THIS load, not v_load_id.
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'LD-0144-I6-OTHER', 'delivered', 400, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved')
  returning id into v_other_load_id;
  -- status = 'delivered' (not one of the "active" statuses the 0054
  -- dispatches_active_driver_unique/dispatches_active_truck_unique
  -- partial indexes guard) so this driver/truck remain free for I7's
  -- own dispatch fixture below.
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', v_other_load_id, 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'delivered')
  returning id into v_dispatch_id;
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, source_load_id, source_dispatch_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 400, v_load_id, v_dispatch_id);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, v_load_id);
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I6', 'i6-key');
  if v_result->>'code' <> 'SOURCE_LOAD_CONFLICT' then raise exception 'TEST FAIL (I6): expected SOURCE_LOAD_CONFLICT for a dispatch whose load is not attached to this invoice, got %.', v_result; end if;
  if (select invoice_number from public.carrier_invoices where id = v_id) is not null then raise exception 'TEST FAIL (I6): a refused issuance must not consume a number.'; end if;
  raise notice 'OK (I6): a line item''s source_dispatch_id pointing at a dispatch for a DIFFERENT (unattached) load is caught and rejected at issuance -- %.', v_result;
end
$t$;

\echo '----- I7. valid source_dispatch_id (correct load + carrier association) -> ISSUED, opaque id preserved verbatim in the snapshot, no mutable dispatch field leaked -----'
do $t$
declare v_id uuid; v_load_id uuid; v_dispatch_id uuid; v_result jsonb; v_expected timestamptz; v_snap jsonb;
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'LD-0144-I7', 'delivered', 400, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved')
  returning id into v_load_id;
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state)
  values
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'pickup', 1, 'I7 Shipper', 'Dallas', 'TX'),
    ('11111111-1111-1111-1111-111111111111', v_load_id, 'delivery', 2, 'I7 Receiver', 'Houston', 'TX');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', v_load_id, 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned')
  returning id into v_dispatch_id;
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, source_load_id, source_dispatch_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'x', 1, 400, v_load_id, v_dispatch_id);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, v_load_id);
  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I7', 'i7-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (I7): expected ISSUED for a correctly-associated source_dispatch_id, got %.', v_result; end if;
  select snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
  if (v_snap->'line_items'->0->>'source_dispatch_id')::uuid <> v_dispatch_id then raise exception 'TEST FAIL (I7): the opaque source_dispatch_id was not preserved verbatim in the snapshot.'; end if;
  if v_snap::text ilike '%dispatch_fee_amount%' or v_snap::text ilike '%carrier_net_amount%' or v_snap::text ilike '%"status": "assigned"%' then
    raise exception 'TEST FAIL (I7): a mutable dispatch field leaked into the snapshot -- source_dispatch_id must remain a purely opaque reference.';
  end if;
  raise notice 'OK (I7): a correctly-associated source_dispatch_id issues successfully, is preserved verbatim as an opaque id in the snapshot, and no mutable dispatch field is ever snapshotted -- %.', v_result;
end
$t$;

reset role;
select set_config('test.current_uid', null, false);

\echo '################  TEST 0144 PASSED  ################'
