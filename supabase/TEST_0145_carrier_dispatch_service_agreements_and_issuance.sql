-- ============================================================================
-- TEST_0145_carrier_dispatch_service_agreements_and_issuance.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.4 verification: versioned carrier dispatch-service agreements
-- (create/create_version/approve+supersede/deactivate_version/deactivate_
-- agreement) and atomic dispatch-service invoice issuance via
-- issue_carrier_invoice()'s STEP 10 -> _issue_dispatch_service_invoice_
-- internal(). Covers every SQL-testable behavior in a single session:
-- authorization matrix, all structured result codes reachable without
-- genuine concurrency, fee calculation/rounding/min-max, snapshot shape,
-- legal separation from the carrier freight invoice, anti-double-billing,
-- overlap exclusion, and immutability enforcement.
--
-- Genuine two-session concurrency (Section L/M) is covered separately by
-- TEST_CONCURRENCY_0145_dispatch_service_billing.sh -- three codes are
-- reachable ONLY under a real race (STALE_AGREEMENT, FREIGHT_INVOICE_
-- CARRIER_MISMATCH, and the AGREEMENT_OVERLAP race itself) and are
-- deliberately NOT reproduced here with a fake single-session shortcut;
-- each is called out explicitly below, at the point it would otherwise
-- appear, with a pointer to its concurrency scenario.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0145  ################'

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

\echo '===== fixtures ====='
reset role;
select set_config('test.current_uid', null, false);
do $t$
begin
  -- Phase 3B.4.1, Section G: every dispatch-service issuance now
  -- requires the dispatch organization's own remittance_instructions to
  -- be non-empty (DISPATCH_REMITTANCE_REQUIRED otherwise) -- set on both
  -- orgs used anywhere in this file.
  update public.organizations set remittance_instructions = 'Org A -- wire to Bank of Org A, ABA 111111111, acct 000111' where id = '11111111-1111-1111-1111-111111111111';
  update public.organizations set remittance_instructions = 'Org B -- wire to Bank of Org B, ABA 222222222, acct 000222' where id = '22222222-2222-2222-2222-222222222222';

  -- Carrier A1: DIRECT billing (invoice_code CARA). Carrier A2: FACTORED,
  -- complete+ready default relationship (invoice_code CARB) -- both need
  -- their own freight invoices issued as fixtures (0144's own path,
  -- unchanged), so both need a fully-configured, issuance-ready policy
  -- exactly like TEST_0144's own fixture. Dispatch-service invoices
  -- themselves never touch factoring at all regardless.
  update public.carriers set invoice_code = 'CARA', factoring_mode = 'direct' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  update public.carriers set invoice_code = 'CARB', factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';

  insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
  values
    ('cb450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001'),
    ('cb450000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');

  insert into public.factoring_companies (id, organization_id, name, legal_name, is_active) values
    ('fc450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor 0145', 'Factor 0145 LLC', true);
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
     noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, submission_destination_email,
     is_default, is_active)
  values
    ('fe450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc450000-0000-0000-0000-000000000001',
     'a2a2a2a2-0000-0000-0000-000000000002', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Factor 0145, ABA 000000000', 'NOA 0145 v1', 'ref-0145-1',
     current_date - 5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'secure_email', 'factor0145@example.com', true, true);

  -- Five delivered loads for carrier A1, each with a complete pickup+
  -- delivery route (LOAD_NOT_ELIGIBLE requires 'delivered'/'pod_received'/
  -- 'invoiced'/'closed' -- 'delivered' throughout is sufficient and
  -- simplest). One additional 'in_transit' load for the LOAD_NOT_ELIGIBLE
  -- test, and one more belonging to carrier A2 (factored) for fixture F.
  insert into public.loads (id, organization_id, load_number, broker_id, status, rate) values
    ('60000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'LD-0145-01', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 1000.00),
    ('60000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'LD-0145-02', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 2000.00),
    ('60000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'LD-0145-03', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 500.00),
    ('60000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'LD-0145-04', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 1200.00),
    ('60000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'LD-0145-05', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 100.00),
    ('60000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'LD-0145-06', 'a0b00000-0000-0000-0000-000000000001', 'in_transit', 900.00),
    ('60000000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'LD-0145-07', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 3000.00);
  update public.loads set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001', carrier_resolution = 'resolved'
    where id in (
      '60000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000003',
      '60000000-0000-0000-0000-000000000004','60000000-0000-0000-0000-000000000005','60000000-0000-0000-0000-000000000006',
      '60000000-0000-0000-0000-000000000007');
  -- One load for carrier A2 (factored) -- fixture F only.
  insert into public.loads (id, organization_id, load_number, broker_id, status, rate) values
    ('60000000-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111', 'LD-0145-0F', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 800.00);
  update public.loads set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002', carrier_resolution = 'resolved' where id = '60000000-0000-0000-0000-00000000000f';

  -- Three MORE carriers, dedicated one-per-test (a4/a5/a6) -- each test
  -- below (B3, E2, B9) approves an open-ended (effective_to null)
  -- version for its carrier; reusing a shared carrier across two such
  -- tests would make the second approval collide with the first under
  -- cdsav_no_overlap_when_approved (a REAL exclusion constraint, exactly
  -- as it should) -- one carrier per independent approved-version test
  -- keeps each test's assertions isolated from every other's, without
  -- ever weakening the constraint itself to make room. Carrier A3
  -- (already seeded) is reused for H1 -- by that point in the file A3
  -- still has no approved version of its own (B2's version stayed draft;
  -- B10's never-approved STALE_RECORD attempt also stayed draft), so
  -- H1's two brand-new sequential approvals are still the first and only
  -- ones for A3, with nothing left to overlap.
  -- A5 and A6 each need a percentage_of_freight fixture's freight invoice
  -- issued first (E2, B9) -- direct billing + an invoice_code + an
  -- activated broker relationship, exactly like A1/A2 above. A4 (B3,
  -- flat_per_load, no freight invoice involved) needs neither.
  insert into public.carriers (id, organization_id, legal_name, address_line1, city, state, postal_code, email, is_active, invoice_code, factoring_mode) values
    ('a4a4a4a4-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Carrier A4 LLC', '4 A St', 'Dallas', 'TX', '75201', 'a4@example.com', true, null, 'unconfigured'),
    ('a5a5a5a5-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Carrier A5 LLC', '5 A St', 'Dallas', 'TX', '75201', 'a5@example.com', true, 'CARE', 'direct'),
    ('a6a6a6a6-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'Carrier A6 LLC', '6 A St', 'Dallas', 'TX', '75201', 'a6@example.com', true, 'CARF', 'direct');
  insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
  values
    ('cb450000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'a5a5a5a5-0000-0000-0000-000000000005', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001'),
    ('cb450000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'a6a6a6a6-0000-0000-0000-000000000006', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');

  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
  select '11111111-1111-1111-1111-111111111111', l.id, 'pickup', 1, 'Shipper 0145', 'Dallas', 'TX', now() - interval '3 days'
  from public.loads l where l.load_number like 'LD-0145-%';
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
  select '11111111-1111-1111-1111-111111111111', l.id, 'delivery', 2, 'Receiver 0145', 'Houston', 'TX', now() - interval '1 day'
  from public.loads l where l.load_number like 'LD-0145-%';

  raise notice 'OK: fixtures ready -- 7 loads for carrier A1 (direct), 1 for carrier A2 (factored).';
end
$t$;

-- Helper: issue a carrier_freight_invoice for a single load, returns
-- nothing -- just leaves an issued freight invoice + snapshot behind so
-- percentage_of_freight tests have an authoritative amount to read.
\echo '----- fixture: issue carrier freight invoices for loads 01,02,03,04,05,07 (carrier A1) and 0F (carrier A2) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid; v_result jsonb;
begin
  for v_id in select unnest(array[
    '60000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000003',
    '60000000-0000-0000-0000-000000000004','60000000-0000-0000-0000-000000000005','60000000-0000-0000-0000-000000000007'
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
    values ('11111111-1111-1111-1111-111111111111', v_inv2, 'Freight -- LD-0145-0F', 1, 800.00, 'freight_charge', '60000000-0000-0000-0000-00000000000f');
    insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv2, '60000000-0000-0000-0000-00000000000f');
    v_expected2 := (select updated_at from public.carrier_invoices where id = v_inv2);
    v_result := public.issue_carrier_invoice(v_inv2, v_expected2, 'fixture freight issuance F', 'fixture-freight-0f');
    if v_result->>'code' <> 'ISSUED' then raise exception 'fixture freight issuance failed for 0F: %', v_result; end if;
  end;

  raise notice 'OK: fixture freight invoices issued.';
end
$t$;

-- ---------------------------------------------------------------------------
-- A. Agreement lifecycle happy path + percentage_of_freight dispatch-service
--    issuance end to end.
-- ---------------------------------------------------------------------------
\echo '----- A1. create_carrier_dispatch_service_agreement (owner) -> CREATED -----'
do $t$
declare v_result jsonb;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-A1-001', 'initial agreement', 'a-create-agreement-1');
  if v_result->>'code' <> 'CREATED' then raise exception 'TEST FAIL (A1): expected CREATED, got %.', v_result; end if;
  perform set_config('test.agreement_a1', v_result->>'agreement_id', false);
  raise notice 'OK (A1): agreement created -- %.', v_result;
end
$t$;

\echo '----- A2. create_carrier_dispatch_service_agreement_version (accountant, draft, 10% percentage_of_freight) -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb; v_agreement uuid := current_setting('test.agreement_a1')::uuid;
begin
  v_result := public.create_carrier_dispatch_service_agreement_version(
    v_agreement, 'percentage_of_freight', 10.0000, null, null, null, 'USD', 15,
    current_date - 30, null, 'initial terms', 'a-create-version-1');
  if v_result->>'code' <> 'CREATED' then raise exception 'TEST FAIL (A2): expected CREATED, got %.', v_result; end if;
  perform set_config('test.version_a1', v_result->>'version_id', false);
  raise notice 'OK (A2): draft version proposed by accountant -- %.', v_result;
end
$t$;

\echo '----- A3. approve_carrier_dispatch_service_agreement_version (owner) -> APPROVED -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb; v_version uuid := current_setting('test.version_a1')::uuid; v_expected timestamptz;
begin
  v_expected := (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version);
  v_result := public.approve_carrier_dispatch_service_agreement_version(v_version, v_expected, 'approve initial terms', 'a-approve-version-1');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (A3): expected APPROVED, got %.', v_result; end if;
  if (select current_version_id from public.carrier_dispatch_service_agreements where id = current_setting('test.agreement_a1')::uuid) <> v_version then
    raise exception 'TEST FAIL (A3): agreement.current_version_id was not updated.';
  end if;
  raise notice 'OK (A3): version approved -- %.', v_result;
end
$t$;

\echo '----- A4. dispatch-service issuance succeeds -- fee = 10% of the authoritative freight amount (load 01: $1000 -> $100.00) -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb; v_snap record;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  perform set_config('test.dsi_01', v_id::text, false);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-000000000001');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'A4 happy path', 'a4-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (A4): expected ISSUED, got %.', v_result; end if;
  if v_result->>'invoice_number' <> 'DISP-2026-00001' then raise exception 'TEST FAIL (A4): expected DISP-2026-00001, got %.', v_result; end if;
  if (v_result->>'total_amount')::numeric <> 100.00 then raise exception 'TEST FAIL (A4): expected total 100.00 (10%% of 1000), got %.', v_result; end if;

  select * into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
  if v_snap.recipient_broker_id is not null or v_snap.recipient_customer_id is not null then
    raise exception 'TEST FAIL (A4): dispatch-service snapshot row must never carry a broker/customer recipient.';
  end if;
  if v_snap.snapshot_payload->'factoring' <> 'null'::jsonb then
    raise exception 'TEST FAIL (A4): dispatch-service snapshot must never carry factoring identity, got %.', v_snap.snapshot_payload->'factoring';
  end if;
  if (v_snap.snapshot_payload->'recipient'->>'type') <> 'carrier' then
    raise exception 'TEST FAIL (A4): recipient.type must be carrier, got %.', v_snap.snapshot_payload->'recipient';
  end if;
  if (v_snap.snapshot_payload->'issuer'->>'organization_id') <> '11111111-1111-1111-1111-111111111111' then
    raise exception 'TEST FAIL (A4): issuer must be the dispatch organization itself.';
  end if;
  if (v_snap.snapshot_payload->'agreement'->>'version_id') <> current_setting('test.version_a1') then
    raise exception 'TEST FAIL (A4): agreement.version_id in snapshot does not match the approved version used.';
  end if;
  if jsonb_array_length(v_snap.snapshot_payload->'billing_lines') <> 1 then
    raise exception 'TEST FAIL (A4): expected exactly 1 billing line in the snapshot.';
  end if;
  if ((v_snap.snapshot_payload->'billing_lines'->0)->>'authoritative_freight_amount')::numeric <> 1000.00 then
    raise exception 'TEST FAIL (A4): authoritative_freight_amount must be 1000.00 (the ISSUED freight invoice snapshot amount), got %.', v_snap.snapshot_payload->'billing_lines';
  end if;

  if (select count(*) from public.carrier_dispatch_service_billing_lines where load_id = '60000000-0000-0000-0000-000000000001') <> 1 then
    raise exception 'TEST FAIL (A4): expected exactly 1 billing ledger row for load 01.';
  end if;
  raise notice 'OK (A4): dispatch-service invoice issued end-to-end -- %.', v_result;
end
$t$;

\echo '----- A5. the carrier freight invoice for load 01 is completely untouched (Section A legal separation) -----'
do $t$
declare v_freight_total numeric; v_freight_status text;
begin
  select ci.total_amount, ci.issuance_status into v_freight_total, v_freight_status
  from public.carrier_invoices ci join public.carrier_invoice_loads cil on cil.invoice_id = ci.id
  where cil.load_id = '60000000-0000-0000-0000-000000000001' and ci.invoice_document_type = 'carrier_freight_invoice';
  if v_freight_total <> 1000.00 or v_freight_status <> 'issued' then
    raise exception 'TEST FAIL (A5): the carrier freight invoice was altered by dispatch-service issuance -- total % status %.', v_freight_total, v_freight_status;
  end if;
  raise notice 'OK (A5): carrier freight invoice for load 01 remains exactly $1000.00, issued -- never touched.';
end
$t$;

\echo '----- A6. LOAD_ALREADY_BILLED: a second dispatch-service invoice for the same load is refused; no number consumed -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb; v_count_before integer; v_count_after integer;
begin
  select count(*) into v_count_before from public.carrier_invoice_issuance_snapshots where invoice_document_type = 'dispatch_service_invoice';

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-000000000001');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'A6 duplicate attempt', 'a6-issue-key');
  if v_result->>'code' <> 'LOAD_ALREADY_BILLED' then raise exception 'TEST FAIL (A6): expected LOAD_ALREADY_BILLED, got %.', v_result; end if;
  if (select issuance_status from public.carrier_invoices where id = v_id) = 'issued' then
    raise exception 'TEST FAIL (A6): the second invoice must not have been issued.';
  end if;

  select count(*) into v_count_after from public.carrier_invoice_issuance_snapshots where invoice_document_type = 'dispatch_service_invoice';
  if v_count_after <> v_count_before then raise exception 'TEST FAIL (A6): no new snapshot should have been created.'; end if;
  raise notice 'OK (A6): duplicate load billing refused, no number consumed, no new snapshot.';
end
$t$;

-- ---------------------------------------------------------------------------
-- B. Structured error codes.
-- ---------------------------------------------------------------------------
\echo '----- B1. AGREEMENT_REQUIRED: a carrier with no agreement at all -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a3a3a3a3-0000-0000-0000-000000000003', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  -- A covered load is required first (zero loads would trip
  -- INVOICE_INCOMPLETE before AGREEMENT_REQUIRED is ever reached) --
  -- carrier A3 has none yet, so create one.
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-0000000000a3', '11111111-1111-1111-1111-111111111111', 'LD-0145-A3', 'a0b00000-0000-0000-0000-000000000001', 'a3a3a3a3-0000-0000-0000-000000000003', 'resolved', 'delivered', 500.00);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000a3');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'B1', 'b1-issue-key');
  if v_result->>'code' <> 'AGREEMENT_REQUIRED' then raise exception 'TEST FAIL (B1): expected AGREEMENT_REQUIRED, got %.', v_result; end if;
  raise notice 'OK (B1): %.', v_result;
end
$t$;

\echo '----- B2. AGREEMENT_NOT_APPROVED: an agreement exists but its only version is still draft -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_agreement uuid; v_result jsonb; v_id uuid; v_expected timestamptz;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a3a3a3a3-0000-0000-0000-000000000003', 'DSA-A3-001', 'b2 setup', 'b2-create-agreement');
  v_agreement := (v_result->>'agreement_id')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'flat_per_load', null, 50.00, null, null, 'USD', 15, current_date - 10, null, 'b2 draft', 'b2-create-version');
  if v_result->>'code' <> 'CREATED' then raise exception 'TEST FAIL (B2 setup): %.', v_result; end if;

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a3a3a3a3-0000-0000-0000-000000000003', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000a3');
  -- load a3 was already attached (and failed) to a DIFFERENT, unissued
  -- draft invoice in B1 -- attaching it here too is fine (only an ISSUED
  -- invoice's own billing ledger row makes a load ineligible again).

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'B2', 'b2-issue-key');
  if v_result->>'code' <> 'AGREEMENT_NOT_APPROVED' then raise exception 'TEST FAIL (B2): expected AGREEMENT_NOT_APPROVED, got %.', v_result; end if;
  raise notice 'OK (B2): %.', v_result;
end
$t$;

\echo '----- B3. AGREEMENT_NOT_EFFECTIVE: an approved version exists but effective_from is in the future -----'
-- Carrier A4 -- a dedicated, otherwise-unused carrier (see fixtures):
-- an open-ended approved version, once created here, must never
-- coexist with another test's own open-ended approved version for the
-- SAME carrier (cdsav_no_overlap_when_approved would correctly reject
-- the second one) -- one carrier per such test keeps them isolated.
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb; v_id uuid; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-0000000000a4', '11111111-1111-1111-1111-111111111111', 'LD-0145-A4', 'a0b00000-0000-0000-0000-000000000001', 'a4a4a4a4-0000-0000-0000-000000000004', 'resolved', 'delivered', 400.00);

  v_result := public.create_carrier_dispatch_service_agreement('a4a4a4a4-0000-0000-0000-000000000004', 'DSA-A4-FUTURE', 'b3 setup', 'b3-create-agreement');
  v_agreement := (v_result->>'agreement_id')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'flat_per_load', null, 25.00, null, null, 'USD', 15, current_date + 30, null, 'b3 future', 'b3-create-version');
  v_version := (v_result->>'version_id')::uuid;
  v_expected := (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version);
  v_result := public.approve_carrier_dispatch_service_agreement_version(v_version, v_expected, 'b3 approve future', 'b3-approve-version');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (B3 setup): %.', v_result; end if;

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a4a4a4a4-0000-0000-0000-000000000004', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000a4');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'B3', 'b3-issue-key');
  if v_result->>'code' <> 'AGREEMENT_NOT_EFFECTIVE' then raise exception 'TEST FAIL (B3): expected AGREEMENT_NOT_EFFECTIVE, got %.', v_result; end if;
  raise notice 'OK (B3): %.', v_result;
end
$t$;

\echo '----- B4. AGREEMENT_OVERLAP: approving a second version whose effective range overlaps an already-approved version for the same carrier -----'
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb;
begin
  -- Carrier A1's existing approved version (test A) covers
  -- [current_date-30, infinity). Any new version overlapping that range,
  -- approved for the SAME carrier, must be rejected -- even under a
  -- brand-new agreement container (Section C: the non-overlap rule is
  -- per-carrier, not per-agreement).
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-A1-OVERLAP', 'b4 setup', 'b4-create-agreement');
  v_agreement := (v_result->>'agreement_id')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'flat_per_load', null, 30.00, null, null, 'USD', 15, current_date, null, 'b4 overlap', 'b4-create-version');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version),
    'b4 approve overlap', 'b4-approve-version');
  if v_result->>'code' <> 'AGREEMENT_OVERLAP' then raise exception 'TEST FAIL (B4): expected AGREEMENT_OVERLAP, got %.', v_result; end if;
  if (select status from public.carrier_dispatch_service_agreement_versions where id = v_version) <> 'draft' then
    raise exception 'TEST FAIL (B4): the rejected version must remain draft, not silently become approved.';
  end if;
  raise notice 'OK (B4): %.', v_result;
end
$t$;

\echo '----- B5. AGREEMENT_CURRENCY_MISMATCH: the invoice currency does not match the approved version currency -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, currency, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'EUR', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-000000000002');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'B5', 'b5-issue-key');
  if v_result->>'code' <> 'AGREEMENT_CURRENCY_MISMATCH' then raise exception 'TEST FAIL (B5): expected AGREEMENT_CURRENCY_MISMATCH, got %.', v_result; end if;
  raise notice 'OK (B5): %.', v_result;
end
$t$;

\echo '----- B6. FREIGHT_INVOICE_REQUIRED: percentage_of_freight, but the covered load has no issued carrier freight invoice yet -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb;
begin
  -- Load 06 is 'in_transit' (LOAD_NOT_ELIGIBLE would fire first) -- use a
  -- brand-new, already-delivered load for carrier A1 that has never had
  -- a freight invoice issued.
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-0000000000b6', '11111111-1111-1111-1111-111111111111', 'LD-0145-B6', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 700.00);

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000b6');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'B6', 'b6-issue-key');
  if v_result->>'code' <> 'FREIGHT_INVOICE_REQUIRED' then raise exception 'TEST FAIL (B6): expected FREIGHT_INVOICE_REQUIRED, got %.', v_result; end if;
  if (select count(*) from public.carrier_dispatch_service_billing_lines where load_id = '60000000-0000-0000-0000-0000000000b6') <> 0 then
    raise exception 'TEST FAIL (B6): no billing line should have been created.';
  end if;
  raise notice 'OK (B6): %.', v_result;
end
$t$;

\echo '----- B7 (FREIGHT_INVOICE_CARRIER_MISMATCH) and STALE_AGREEMENT: NOT single-session reproducible -----'
\echo '  Both require the provisional (unlocked) read and the subsequent FOR UPDATE/FOR SHARE lock+revalidate'
\echo '  to observe genuinely DIFFERENT states -- impossible within one transaction with no concurrent writer.'
\echo '  Proved live by TEST_CONCURRENCY_0145_dispatch_service_billing.sh Scenarios 3 and 11.'

\echo '----- B8. LOAD_NOT_ELIGIBLE: load not yet delivered -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-000000000006');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'B8', 'b8-issue-key');
  if v_result->>'code' <> 'LOAD_NOT_ELIGIBLE' then raise exception 'TEST FAIL (B8): expected LOAD_NOT_ELIGIBLE, got %.', v_result; end if;
  raise notice 'OK (B8): %.', v_result;
end
$t$;

\echo '----- B9. FEE_CALCULATION_INVALID: a percentage rate so small the rounded fee is not positive -----'
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb; v_id uuid; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-0000000000b9', '11111111-1111-1111-1111-111111111111', 'LD-0145-B9', 'a0b00000-0000-0000-0000-000000000001', 'a6a6a6a6-0000-0000-0000-000000000006', 'resolved', 'delivered', 100.00);
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state) values
    ('11111111-1111-1111-1111-111111111111', '60000000-0000-0000-0000-0000000000b9', 'pickup', 1, 'S', 'Dallas', 'TX'),
    ('11111111-1111-1111-1111-111111111111', '60000000-0000-0000-0000-0000000000b9', 'delivery', 2, 'R', 'Houston', 'TX');
  declare v_inv uuid; v_exp2 timestamptz;
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a6a6a6a6-0000-0000-0000-000000000006', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
    returning id into v_inv;
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
    values ('11111111-1111-1111-1111-111111111111', v_inv, 'Freight -- LD-0145-B9', 1, 100.00, 'freight_charge', '60000000-0000-0000-0000-0000000000b9');
    insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv, '60000000-0000-0000-0000-0000000000b9');
    v_exp2 := (select updated_at from public.carrier_invoices where id = v_inv);
    v_result := public.issue_carrier_invoice(v_inv, v_exp2, 'b9 freight fixture', 'b9-freight-issue');
    if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (B9 setup freight): %.', v_result; end if;
  end;

  v_result := public.create_carrier_dispatch_service_agreement('a6a6a6a6-0000-0000-0000-000000000006', 'DSA-A6-TINY', 'b9 setup', 'b9-create-agreement');
  v_agreement := (v_result->>'agreement_id')::uuid;
  -- 0.0001% of $100.00 = $0.0001, rounds to $0.00 -- not positive.
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'percentage_of_freight', 0.0001, null, null, null, 'USD', 15, current_date - 1, null, 'b9 tiny rate', 'b9-create-version');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version), 'b9 approve', 'b9-approve-version');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (B9 setup approve): %.', v_result; end if;

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a6a6a6a6-0000-0000-0000-000000000006', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000b9');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'B9', 'b9-issue-key');
  if v_result->>'code' <> 'FEE_CALCULATION_INVALID' then raise exception 'TEST FAIL (B9): expected FEE_CALCULATION_INVALID, got %.', v_result; end if;
  raise notice 'OK (B9): %.', v_result;
end
$t$;

\echo '----- B10. STALE_RECORD: expected_updated_at mismatch on approve_..._version -----'
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a3a3a3a3-0000-0000-0000-000000000003', 'DSA-A3-STALE', 'b10 setup', 'b10-create-agreement');
  v_agreement := (v_result->>'agreement_id')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'flat_per_load', null, 10.00, null, null, 'USD', 15, current_date + 100, null, 'b10 stale', 'b10-create-version');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(v_version, now() - interval '1 hour', 'b10 stale attempt', 'b10-approve-version');
  if v_result->>'code' <> 'STALE_RECORD' then raise exception 'TEST FAIL (B10): expected STALE_RECORD, got %.', v_result; end if;
  if (select status from public.carrier_dispatch_service_agreement_versions where id = v_version) <> 'draft' then
    raise exception 'TEST FAIL (B10): version must remain draft after a stale-rejected approval attempt.';
  end if;
  raise notice 'OK (B10): %.', v_result;
end
$t$;

\echo '----- B11. IDEMPOTENCY_KEY_REUSED (collision) and idempotent replay (same key, same request) -----'
do $t$
declare v_result1 jsonb; v_result2 jsonb; v_result3 jsonb;
begin
  v_result1 := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-A1-IDEMP-1', 'b11 first', 'b11-shared-key');
  if v_result1->>'code' <> 'CREATED' then raise exception 'TEST FAIL (B11 setup): %.', v_result1; end if;

  -- Same key, DIFFERENT request (different agreement_number) -> collision.
  v_result2 := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-A1-IDEMP-2', 'b11 second', 'b11-shared-key');
  if v_result2->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then raise exception 'TEST FAIL (B11 collision): expected IDEMPOTENCY_KEY_REUSED, got %.', v_result2; end if;

  -- Same key, IDENTICAL request -> replay returns the cached result.
  v_result3 := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-A1-IDEMP-1', 'b11 first', 'b11-shared-key');
  if v_result3 <> v_result1 then raise exception 'TEST FAIL (B11 replay): expected identical cached result, got % vs %.', v_result1, v_result3; end if;

  if (select count(*) from public.carrier_dispatch_service_agreements where agreement_number = 'DSA-A1-IDEMP-2') <> 0 then
    raise exception 'TEST FAIL (B11): the colliding request must never have been applied.';
  end if;
  raise notice 'OK (B11): collision -- %; replay -- %.', v_result2, v_result3;
end
$t$;

\echo '----- B12. FORBIDDEN: unauthenticated -----'
select set_config('test.current_uid', null, false);
do $t$
declare v_result jsonb;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-NOAUTH', 'no auth', 'b12-key');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (B12): expected FORBIDDEN, got %.', v_result; end if;
  raise notice 'OK (B12): %.', v_result;
end
$t$;

\echo '----- B13. NOT_FOUND: random uuids for agreement/version -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb;
begin
  v_result := public.create_carrier_dispatch_service_agreement_version('99999999-9999-9999-9999-999999999999', 'flat_per_load', null, 10.00, null, null, 'USD', 15, current_date, null, 'nf', 'b13-key-1');
  if v_result->>'code' <> 'NOT_FOUND' then raise exception 'TEST FAIL (B13a): expected NOT_FOUND, got %.', v_result; end if;
  v_result := public.approve_carrier_dispatch_service_agreement_version('99999999-9999-9999-9999-999999999999', now(), 'nf', 'b13-key-2');
  if v_result->>'code' <> 'NOT_FOUND' then raise exception 'TEST FAIL (B13b): expected NOT_FOUND, got %.', v_result; end if;
  raise notice 'OK (B13): both NOT_FOUND as expected.';
end
$t$;

\echo '----- B14. INVALID_STATE: duplicate agreement number; re-approving an already-approved version; deactivating an already-inactive agreement -----'
do $t$
declare v_result jsonb; v_version uuid;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-A1-IDEMP-1', 'dup', 'b14-key-1');
  if v_result->>'code' <> 'INVALID_STATE' then raise exception 'TEST FAIL (B14a): expected INVALID_STATE (duplicate agreement number), got %.', v_result; end if;

  v_version := current_setting('test.version_a1')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version), 're-approve', 'b14-key-2');
  if v_result->>'code' <> 'INVALID_STATE' then raise exception 'TEST FAIL (B14b): expected INVALID_STATE (already approved), got %.', v_result; end if;

  v_result := public.deactivate_carrier_dispatch_service_agreement(
    current_setting('test.agreement_a1')::uuid, (select updated_at from public.carrier_dispatch_service_agreements where id = current_setting('test.agreement_a1')::uuid),
    'deactivate', 'b14-key-3');
  if v_result->>'code' <> 'DEACTIVATED' then raise exception 'TEST FAIL (B14c setup): %.', v_result; end if;
  v_result := public.deactivate_carrier_dispatch_service_agreement(
    current_setting('test.agreement_a1')::uuid, (select updated_at from public.carrier_dispatch_service_agreements where id = current_setting('test.agreement_a1')::uuid),
    'deactivate again', 'b14-key-4');
  if v_result->>'code' <> 'INVALID_STATE' then raise exception 'TEST FAIL (B14c): expected INVALID_STATE (already inactive), got %.', v_result; end if;

  -- Reactivate is out of scope (no such RPC exists -- Section E's four
  -- statuses are the complete set) -- undo via direct trusted-context
  -- UPDATE so later tests (D, E, F, G, H) can still use carrier A1's
  -- agreement container. This does not touch any version row.
  raise notice 'OK (B14): %; %; %.', v_result, v_result, v_result;
end
$t$;
reset role;
update public.carrier_dispatch_service_agreements set status = 'active' where id = (select current_setting('test.agreement_a1', true))::uuid;
set role authenticated;

-- ---------------------------------------------------------------------------
-- C. Authorization matrix (Section D).
-- ---------------------------------------------------------------------------
\echo '----- C1. accountant: may create a draft version (already proven in A2); may NOT create/approve/deactivate -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-ACCOUNTANT-DENIED', 'x', 'c1-key-1');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C1a): accountant must not create an agreement, got %.', v_result; end if;

  v_result := public.approve_carrier_dispatch_service_agreement_version(current_setting('test.version_a1')::uuid, now(), 'x', 'c1-key-2');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C1b): accountant must not approve a version, got %.', v_result; end if;

  v_result := public.deactivate_carrier_dispatch_service_agreement_version(current_setting('test.version_a1')::uuid, now(), 'x', 'c1-key-3');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C1c): accountant must not deactivate a version, got %.', v_result; end if;

  v_result := public.deactivate_carrier_dispatch_service_agreement(current_setting('test.agreement_a1')::uuid, now(), 'x', 'c1-key-4');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C1d): accountant must not deactivate an agreement, got %.', v_result; end if;

  raise notice 'OK (C1): accountant may propose draft terms only -- everything else FORBIDDEN.';
end
$t$;

\echo '----- C2. dispatcher: read-only, all five RPCs FORBIDDEN -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-DISPATCHER-DENIED', 'x', 'c2-key-1');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C2a): %.', v_result; end if;
  v_result := public.create_carrier_dispatch_service_agreement_version(current_setting('test.agreement_a1')::uuid, 'flat_per_load', null, 10.00, null, null, 'USD', 15, current_date, null, 'x', 'c2-key-2');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C2b): %.', v_result; end if;
  v_result := public.approve_carrier_dispatch_service_agreement_version(current_setting('test.version_a1')::uuid, now(), 'x', 'c2-key-3');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C2c): %.', v_result; end if;
  v_result := public.deactivate_carrier_dispatch_service_agreement_version(current_setting('test.version_a1')::uuid, now(), 'x', 'c2-key-4');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C2d): %.', v_result; end if;
  v_result := public.deactivate_carrier_dispatch_service_agreement(current_setting('test.agreement_a1')::uuid, now(), 'x', 'c2-key-5');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C2e): %.', v_result; end if;
  raise notice 'OK (C2): dispatcher denied on all five RPCs.';
end
$t$;
\echo '----- C2b. dispatcher CAN read (SELECT) agreements/versions/billing lines -----'
do $t$
declare v_n integer;
begin
  select count(*) into v_n from public.carrier_dispatch_service_agreements;
  if v_n = 0 then raise exception 'TEST FAIL (C2b): dispatcher should see agreement rows via SELECT policy.'; end if;
  raise notice 'OK (C2b): dispatcher read access confirmed (% agreements visible).', v_n;
end
$t$;

\echo '----- C3. driver / viewer: no financial access at all -- RPCs FORBIDDEN, SELECT returns zero rows -----'
select set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb; v_n integer;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-DRIVER-DENIED', 'x', 'c3-key-1');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C3a driver): %.', v_result; end if;
  select count(*) into v_n from public.carrier_dispatch_service_agreements;
  if v_n <> 0 then raise exception 'TEST FAIL (C3b driver): driver must see ZERO agreement rows via RLS, saw %.', v_n; end if;
  raise notice 'OK (C3 driver): FORBIDDEN on write, zero rows on read.';
end
$t$;
select set_config('test.current_uid', 'ffff0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb; v_n integer;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-VIEWER-DENIED', 'x', 'c3-key-2');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C3a viewer): %.', v_result; end if;
  select count(*) into v_n from public.carrier_dispatch_service_agreements;
  if v_n <> 0 then raise exception 'TEST FAIL (C3b viewer): viewer must see ZERO agreement rows via RLS, saw %.', v_n; end if;
  raise notice 'OK (C3 viewer): FORBIDDEN on write, zero rows on read.';
end
$t$;

\echo '----- C4. service_role has no auth.uid() of its own -- structurally cannot pass as an ordinary user -----'
reset role;
select set_config('test.current_uid', null, false);
do $t$
declare v_result jsonb;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a1a1a1a1-0000-0000-0000-000000000001', 'DSA-SERVICE-ROLE-DENIED', 'x', 'c4-key');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (C4): %.', v_result; end if;
  raise notice 'OK (C4): %.', v_result;
end
$t$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- D. Immutability enforcement (Section C/E).
-- ---------------------------------------------------------------------------
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
\echo '----- D1. an approved version''s financial terms can never be UPDATEd directly, even by a superuser/trusted context -----'
reset role;
do $t$
declare v_version uuid := current_setting('test.version_a1')::uuid;
begin
  begin
    update public.carrier_dispatch_service_agreement_versions set percentage_rate = 99.0000 where id = v_version;
    raise exception 'TEST FAIL (D1a): percentage_rate mutation on an approved version should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%financial terms are immutable%' then raise; end if;
  end;
  begin
    update public.carrier_dispatch_service_agreement_versions set currency = 'EUR' where id = v_version;
    raise exception 'TEST FAIL (D1b): currency mutation on an approved version should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%financial terms are immutable%' then raise; end if;
  end;
  raise notice 'OK (D1): financial terms remain immutable on an approved version.';
end
$t$;

\echo '----- D2. illegal status transitions are rejected (approved -> draft; draft -> superseded) -----'
do $t$
declare v_version uuid := current_setting('test.version_a1')::uuid;
begin
  begin
    update public.carrier_dispatch_service_agreement_versions set status = 'draft' where id = v_version;
    raise exception 'TEST FAIL (D2a): approved -> draft should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%is not a permitted status transition%' then raise; end if;
  end;
  raise notice 'OK (D2): illegal status transitions rejected.';
end
$t$;

\echo '----- D3. a version already referenced by carrier_dispatch_service_billing_lines can never be deleted -----'
do $t$
declare v_version uuid := current_setting('test.version_a1')::uuid;
begin
  if (select count(*) from public.carrier_dispatch_service_billing_lines where agreement_version_id = v_version) = 0 then
    raise exception 'TEST FAIL (D3 precondition): version_a1 should already be used (test A4).';
  end if;
  begin
    delete from public.carrier_dispatch_service_agreement_versions where id = v_version;
    raise exception 'TEST FAIL (D3): deleting a used version should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%can never be deleted%' then raise; end if;
  end;
  raise notice 'OK (D3): a used version can never be deleted.';
end
$t$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- E. Fee calculation, rounding, min/max clamping (Section H).
-- ---------------------------------------------------------------------------
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
\echo '----- E1. percentage_of_freight with a non-trivial rounding case (7.25% of $2000.00 = $145.00) -----'
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb; v_id uuid; v_expected timestamptz;
begin
  -- A NEW version under the SAME agreement_a1 (not a new agreement --
  -- approve's own supersede parameter requires both versions to belong
  -- to the same agreement), proposing new terms and superseding
  -- version_a1 atomically in one approval call.
  v_agreement := current_setting('test.agreement_a1')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'percentage_of_freight', 7.2500, null, null, null, 'USD', 15, current_date - 30, null, 'e1 replaces a1', 'e1-create-version');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version),
    'e1 approve, supersede A''s original version', 'e1-approve-version',
    p_supersede_version_id => current_setting('test.version_a1')::uuid);
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (E1 setup): %.', v_result; end if;
  if (select status from public.carrier_dispatch_service_agreement_versions where id = current_setting('test.version_a1')::uuid) <> 'superseded' then
    raise exception 'TEST FAIL (E1 setup): original version_a1 should now be superseded.';
  end if;

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-000000000002');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E1', 'e1-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (E1): expected ISSUED, got %.', v_result; end if;
  if (v_result->>'total_amount')::numeric <> 145.00 then raise exception 'TEST FAIL (E1): expected 145.00 (7.25%% of 2000.00), got %.', v_result; end if;
  raise notice 'OK (E1): %.', v_result;
end
$t$;

\echo '----- E2. minimum_fee clamps a fee that would otherwise round below it -----'
-- Carrier A5 -- dedicated (see fixtures note at B3).
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb; v_id uuid; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-0000000000e2', '11111111-1111-1111-1111-111111111111', 'LD-0145-E2', 'a0b00000-0000-0000-0000-000000000001', 'a5a5a5a5-0000-0000-0000-000000000005', 'resolved', 'delivered', 500.00);
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state) values
    ('11111111-1111-1111-1111-111111111111', '60000000-0000-0000-0000-0000000000e2', 'pickup', 1, 'S', 'Dallas', 'TX'),
    ('11111111-1111-1111-1111-111111111111', '60000000-0000-0000-0000-0000000000e2', 'delivery', 2, 'R', 'Houston', 'TX');
  declare v_inv uuid; v_exp2 timestamptz;
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a5a5a5a5-0000-0000-0000-000000000005', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
    returning id into v_inv;
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
    values ('11111111-1111-1111-1111-111111111111', v_inv, 'Freight -- LD-0145-E2', 1, 500.00, 'freight_charge', '60000000-0000-0000-0000-0000000000e2');
    insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv, '60000000-0000-0000-0000-0000000000e2');
    v_exp2 := (select updated_at from public.carrier_invoices where id = v_inv);
    v_result := public.issue_carrier_invoice(v_inv, v_exp2, 'e2 freight fixture', 'e2-freight-issue');
    if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (E2 setup freight): %.', v_result; end if;
  end;

  v_result := public.create_carrier_dispatch_service_agreement('a5a5a5a5-0000-0000-0000-000000000005', 'DSA-A5-E2', 'e2', 'e2-create-agreement');
  v_agreement := (v_result->>'agreement_id')::uuid;
  -- 1% of $500.00 = $5.00, but minimum_fee = $25.00 -- must clamp up.
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'percentage_of_freight', 1.0000, null, 25.00, null, 'USD', 15, current_date - 30, null, 'e2 min clamp', 'e2-create-version');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version), 'e2 approve', 'e2-approve-version');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (E2 setup): %.', v_result; end if;

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a5a5a5a5-0000-0000-0000-000000000005', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000e2');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E2', 'e2-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (E2): expected ISSUED, got %.', v_result; end if;
  if (v_result->>'total_amount')::numeric <> 25.00 then raise exception 'TEST FAIL (E2): expected 25.00 (minimum_fee clamp, not 5.00), got %.', v_result; end if;
  raise notice 'OK (E2): %.', v_result;
end
$t$;

\echo '----- E3. maximum_fee clamps a fee that would otherwise round above it -----'
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb; v_id uuid; v_expected timestamptz;
begin
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-0000000000e3', '11111111-1111-1111-1111-111111111111', 'LD-0145-E3', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 5000.00);
  insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state) values
    ('11111111-1111-1111-1111-111111111111', '60000000-0000-0000-0000-0000000000e3', 'pickup', 1, 'S', 'Dallas', 'TX'),
    ('11111111-1111-1111-1111-111111111111', '60000000-0000-0000-0000-0000000000e3', 'delivery', 2, 'R', 'Houston', 'TX');
  declare v_inv uuid; v_exp2 timestamptz;
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
    returning id into v_inv;
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
    values ('11111111-1111-1111-1111-111111111111', v_inv, 'Freight -- LD-0145-E3', 1, 5000.00, 'freight_charge', '60000000-0000-0000-0000-0000000000e3');
    insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_inv, '60000000-0000-0000-0000-0000000000e3');
    v_exp2 := (select updated_at from public.carrier_invoices where id = v_inv);
    v_result := public.issue_carrier_invoice(v_inv, v_exp2, 'e3 freight fixture', 'e3-freight-issue');
    if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (E3 setup freight): %.', v_result; end if;
  end;

  -- Carrier A1's current approved version is E1's (7.25%, no max) --
  -- propose+approve a NEW, superseding version with a maximum_fee cap.
  v_result := public.create_carrier_dispatch_service_agreement_version(
    current_setting('test.agreement_a1')::uuid, 'percentage_of_freight', 7.2500, null, null, 200.00, 'USD', 15, current_date - 30, null, 'e3 max clamp', 'e3-create-version');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version),
    'e3 approve, supersede e1''s version', 'e3-approve-version',
    p_supersede_version_id => (select current_version_id from public.carrier_dispatch_service_agreements where id = current_setting('test.agreement_a1')::uuid));
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (E3 setup approve): %.', v_result; end if;

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000e3');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E3', 'e3-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (E3): expected ISSUED, got %.', v_result; end if;
  -- 7.25% of $5000.00 = $362.50, but maximum_fee = $200.00 -- must clamp down.
  if (v_result->>'total_amount')::numeric <> 200.00 then raise exception 'TEST FAIL (E3): expected 200.00 (maximum_fee clamp, not 362.50), got %.', v_result; end if;
  raise notice 'OK (E3): %.', v_result;
end
$t$;

\echo '----- E4. flat_per_load: two loads, one invoice, subtotal = 2 x flat fee -----'
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb; v_id uuid; v_expected timestamptz;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a2a2a2a2-0000-0000-0000-000000000002', 'DSA-A2-FLAT', 'e4', 'e4-create-agreement');
  v_agreement := (v_result->>'agreement_id')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'flat_per_load', null, 75.00, null, null, 'USD', 15, current_date - 10, null, 'e4 flat', 'e4-create-version');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version), 'e4 approve', 'e4-approve-version');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (E4 setup): %.', v_result; end if;

  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate) values
    ('60000000-0000-0000-0000-00000000e401', '11111111-1111-1111-1111-111111111111', 'LD-0145-E4A', 'a0b00000-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002', 'resolved', 'delivered', 300.00),
    ('60000000-0000-0000-0000-00000000e402', '11111111-1111-1111-1111-111111111111', 'LD-0145-E4B', 'a0b00000-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002', 'resolved', 'delivered', 400.00);

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values
    ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-00000000e401'),
    ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-00000000e402');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'E4', 'e4-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (E4): expected ISSUED, got %.', v_result; end if;
  if (v_result->>'total_amount')::numeric <> 150.00 then raise exception 'TEST FAIL (E4): expected 150.00 (2 x 75.00 flat), got %.', v_result; end if;
  if (select count(*) from public.carrier_dispatch_service_billing_lines where invoice_id = (v_result->>'invoice_id')::uuid) <> 2 then
    raise exception 'TEST FAIL (E4): expected exactly 2 billing lines.';
  end if;
  raise notice 'OK (E4): %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- F. Legal separation from carrier factoring identity (Section A/I).
-- ---------------------------------------------------------------------------
\echo '----- F1. a dispatch-service invoice for a FACTORED carrier still never carries any factoring identity -----'
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb; v_id uuid; v_expected timestamptz; v_snap jsonb;
begin
  -- A fresh agreement/version is used only to prove the historical-version
  -- readability path in passing; the actual issuance below reuses
  -- DSA-A2-FLAT's already-approved, currently-effective flat-fee version
  -- (from E4) so this test focuses purely on the snapshot-shape assertion.
  v_result := public.create_carrier_dispatch_service_agreement('a2a2a2a2-0000-0000-0000-000000000002', 'DSA-A2-F1', 'f1', 'f1-create-agreement-2');
  v_agreement := (v_result->>'agreement_id')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'percentage_of_freight', 5.0000, null, null, null, 'USD', 15, current_date - 400, current_date - 200, 'f1 historical', 'f1-create-version-2');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version), 'f1 approve', 'f1-approve-version');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (F1 setup): %. (historical, non-overlapping range chosen deliberately)', v_result; end if;

  -- That version is not effective TODAY (historical range) -- deliberately
  -- reuse the earlier flat-fee version instead, which IS effective today,
  -- for the actual issuance below. (DSA-A2-FLAT's version, from E4.)
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-00000000000f');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'F1', 'f1-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (F1): expected ISSUED, got %.', v_result; end if;

  select snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
  -- The top-level 'factoring' KEY itself is always present, set to JSON
  -- null by design (Section J's schema) -- what must never appear is any
  -- actual factoring IDENTITY: a non-null factoring value, or any of the
  -- relationship/company/NOA/integration fields 0144's OWN freight-path
  -- snapshot carries under 'factoring' when populated.
  if v_snap->'factoring' is distinct from 'null'::jsonb then
    raise exception 'TEST FAIL (F1): factoring key must be JSON null, got %.', v_snap->'factoring';
  end if;
  if v_snap ? 'factoring_company_id' or v_snap ? 'relationship_id' or v_snap ? 'noa_reference'
    or v_snap ? 'noa_document_id' or v_snap ? 'integration_id' or v_snap ? 'submission_destination' then
    raise exception 'TEST FAIL (F1): dispatch-service snapshot must never carry any factoring identity field at the top level, got %.', v_snap;
  end if;
  raise notice 'OK (F1): factored-carrier dispatch-service invoice carries zero factoring identity.';
end
$t$;

-- ---------------------------------------------------------------------------
-- G. Anti-double-billing is GLOBAL per load, not per agreement/version (Section G).
-- ---------------------------------------------------------------------------
\echo '----- G1. a load already billed under one version can never be billed again, even under a brand-new agreement/version for the same carrier -----'
do $t$
declare v_agreement uuid; v_version uuid; v_result jsonb; v_id uuid; v_expected timestamptz;
begin
  -- Load 01 was already billed under version_a1 (test A4, later superseded
  -- in E1/E3). Approve yet another version for carrier A1 (superseding
  -- E3's current one), then attempt to bill load 01 again under it --
  -- must still be refused: unique(load_id) is global, never per-version.
  v_result := public.create_carrier_dispatch_service_agreement_version(
    current_setting('test.agreement_a1')::uuid, 'flat_per_load', null, 999.00, null, null, 'USD', 15, current_date - 30, null, 'g1 new terms', 'g1-create-version-2');
  v_version := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(
    v_version, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_version), 'g1 approve, supersede',
    'g1-approve-version-2', p_supersede_version_id => (select current_version_id from public.carrier_dispatch_service_agreements where id = current_setting('test.agreement_a1')::uuid));
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (G1 setup): %.', v_result; end if;

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-000000000001');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'G1', 'g1-issue-key');
  if v_result->>'code' <> 'LOAD_ALREADY_BILLED' then raise exception 'TEST FAIL (G1): expected LOAD_ALREADY_BILLED even under a brand-new version, got %.', v_result; end if;
  raise notice 'OK (G1): %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- H. Sequential (non-overlapping) supersession succeeds cleanly.
-- ---------------------------------------------------------------------------
\echo '----- H1. two sequential, non-overlapping approved versions for the same carrier: both approve cleanly -----'
do $t$
declare v_agreement uuid; v_v1 uuid; v_v2 uuid; v_result jsonb;
begin
  v_result := public.create_carrier_dispatch_service_agreement('a3a3a3a3-0000-0000-0000-000000000003', 'DSA-A3-SEQ', 'h1', 'h1-create-agreement');
  v_agreement := (v_result->>'agreement_id')::uuid;
  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'flat_per_load', null, 40.00, null, null, 'USD', 15, current_date - 100, current_date - 50, 'h1 v1', 'h1-create-v1');
  v_v1 := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(v_v1, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_v1), 'h1 approve v1', 'h1-approve-v1');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (H1a): %.', v_result; end if;

  v_result := public.create_carrier_dispatch_service_agreement_version(v_agreement, 'flat_per_load', null, 45.00, null, null, 'USD', 15, current_date - 49, null, 'h1 v2', 'h1-create-v2');
  v_v2 := (v_result->>'version_id')::uuid;
  v_result := public.approve_carrier_dispatch_service_agreement_version(v_v2, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v_v2), 'h1 approve v2', 'h1-approve-v2');
  if v_result->>'code' <> 'APPROVED' then raise exception 'TEST FAIL (H1b): expected v2 to approve cleanly (adjacent, non-overlapping range), got %.', v_result; end if;

  if (select status from public.carrier_dispatch_service_agreement_versions where id = v_v1) <> 'approved' then
    raise exception 'TEST FAIL (H1c): v1 must remain approved (not superseded -- no supersede_version_id was given) -- historical versions remain readable.';
  end if;
  raise notice 'OK (H1): two sequential non-overlapping approved versions coexist; historical version remains readable.';
end
$t$;

-- ---------------------------------------------------------------------------
-- I. Dispatch remittance completeness (Phase 3B.4.1, Section G).
-- ---------------------------------------------------------------------------
\echo '----- I1. DISPATCH_REMITTANCE_REQUIRED: the dispatch organization has no remittance_instructions on file -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb; v_count_before integer; v_count_after integer;
begin
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-00000000e5a1', '11111111-1111-1111-1111-111111111111', 'LD-0145-I1', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 100.00);

  update public.organizations set remittance_instructions = null where id = '11111111-1111-1111-1111-111111111111';

  select count(*) into v_count_before from public.carrier_invoice_issuance_snapshots where invoice_document_type = 'dispatch_service_invoice';

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-00000000e5a1');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I1', 'i1-issue-key');
  if v_result->>'code' <> 'DISPATCH_REMITTANCE_REQUIRED' then raise exception 'TEST FAIL (I1): expected DISPATCH_REMITTANCE_REQUIRED, got %.', v_result; end if;
  if (select issuance_status from public.carrier_invoices where id = v_id) = 'issued' then
    raise exception 'TEST FAIL (I1): the invoice must not have been issued.';
  end if;
  select count(*) into v_count_after from public.carrier_invoice_issuance_snapshots where invoice_document_type = 'dispatch_service_invoice';
  if v_count_after <> v_count_before then raise exception 'TEST FAIL (I1): no new snapshot should have been created.'; end if;

  update public.organizations set remittance_instructions = 'Org A -- wire to Bank of Org A, ABA 111111111, acct 000111' where id = '11111111-1111-1111-1111-111111111111';
  raise notice 'OK (I1): %.', v_result;
end
$t$;

\echo '----- I2. blank (whitespace-only) remittance_instructions is treated the same as absent -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb;
begin
  update public.organizations set remittance_instructions = '   ' where id = '11111111-1111-1111-1111-111111111111';

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-00000000e5a1');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'I2', 'i2-issue-key');
  if v_result->>'code' <> 'DISPATCH_REMITTANCE_REQUIRED' then raise exception 'TEST FAIL (I2): expected DISPATCH_REMITTANCE_REQUIRED, got %.', v_result; end if;

  update public.organizations set remittance_instructions = 'Org A -- wire to Bank of Org A, ABA 111111111, acct 000111' where id = '11111111-1111-1111-1111-111111111111';
  raise notice 'OK (I2): %.', v_result;
end
$t$;

-- ---------------------------------------------------------------------------
-- J. Inactive-carrier rejection (Phase 3B.4.1, Section C).
-- ---------------------------------------------------------------------------
\echo '----- J1. CARRIER_INACTIVE: an inactive carrier cannot receive a new dispatch-service invoice -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb; v_count_before integer; v_count_after integer;
begin
  update public.carriers set is_active = false where id = 'a2a2a2a2-0000-0000-0000-000000000002';

  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-0000000000a1', '11111111-1111-1111-1111-111111111111', 'LD-0145-J1', 'a0b00000-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002', 'resolved', 'delivered', 100.00);

  select count(*) into v_count_before from public.carrier_invoice_issuance_snapshots where invoice_document_type = 'dispatch_service_invoice';

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000a1');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'J1', 'j1-issue-key');
  if v_result->>'code' <> 'CARRIER_INACTIVE' then raise exception 'TEST FAIL (J1): expected CARRIER_INACTIVE, got %.', v_result; end if;
  if (select issuance_status from public.carrier_invoices where id = v_id) = 'issued' then
    raise exception 'TEST FAIL (J1): the invoice must not have been issued.';
  end if;
  select count(*) into v_count_after from public.carrier_invoice_issuance_snapshots where invoice_document_type = 'dispatch_service_invoice';
  if v_count_after <> v_count_before then raise exception 'TEST FAIL (J1): no new snapshot should have been created for an inactive carrier.'; end if;
  if (select count(*) from public.carrier_dispatch_service_billing_lines where load_id = '60000000-0000-0000-0000-0000000000a1') <> 0 then
    raise exception 'TEST FAIL (J1): no billing line should have been created.';
  end if;

  update public.carriers set is_active = true where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  raise notice 'OK (J1): %.', v_result;
end
$t$;

\echo '----- J2. an already-issued dispatch-service invoice remains valid after the carrier later becomes inactive -----'
do $t$
declare v_id uuid; v_expected timestamptz; v_result jsonb; v_total_before numeric; v_status_before text;
begin
  insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
  values ('60000000-0000-0000-0000-0000000000a2', '11111111-1111-1111-1111-111111111111', 'LD-0145-J2', 'a0b00000-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002', 'resolved', 'delivered', 100.00);

  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', v_id, '60000000-0000-0000-0000-0000000000a2');

  v_expected := (select updated_at from public.carrier_invoices where id = v_id);
  v_result := public.issue_carrier_invoice(v_id, v_expected, 'J2 issue while active', 'j2-issue-key');
  if v_result->>'code' <> 'ISSUED' then raise exception 'TEST FAIL (J2 setup): %.', v_result; end if;

  update public.carriers set is_active = false where id = 'a2a2a2a2-0000-0000-0000-000000000002';

  select total_amount, issuance_status into v_total_before, v_status_before from public.carrier_invoices where id = v_id;
  if v_status_before <> 'issued' or v_total_before <> 75.00 then
    raise exception 'TEST FAIL (J2): the already-issued invoice must remain exactly as issued after the carrier becomes inactive, got status=% total=%.', v_status_before, v_total_before;
  end if;

  update public.carriers set is_active = true where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  raise notice 'OK (J2): already-issued dispatch-service invoice remains valid ($%.) after the carrier later became inactive.', v_total_before;
end
$t$;

\echo '################  TEST 0145 PASSED  ################'
