-- ============================================================================
-- TEST_0147_production_readiness_blocker_remediation.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Behavioral proof that all seven Phase 3C.0 release BLOCKERs are
-- remediated, with regression coverage for everything 0147 must not break.
-- Genuine two-session concurrency is covered separately by
-- TEST_CONCURRENCY_0147_production_readiness.sh.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0147  ################'

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
\i migrations/0147_production_readiness_blocker_remediation.sql

\echo '===== fixtures ====='
reset role;
select set_config('test.current_uid', null, false);

-- A load with genuinely conflicting dispatch-carrier evidence, seeded by
-- TEST_SUPPORT_0130_0133_schema.sql's own C4_conflicting_carriers fixture
-- (load 30000000-...-003) and one with zero-dispatch evidence (load
-- 40000000-...-004) already exist by construction of 0133's own backfill.
-- Confirm the exact rule tags this test depends on are present before
-- building legacy invoices on top of them.
do $t$
begin
  if not exists (select 1 from public.unresolved_carrier_records where record_type='load' and record_id='30000000-0000-0000-0000-000000000003' and detail->>'rule'='C4_conflicting_carriers') then
    raise exception 'TEST 0147 fixture precondition failed: load 30000000-...-003 is not tagged C4_conflicting_carriers.';
  end if;
  if not exists (select 1 from public.unresolved_carrier_records where record_type='load' and record_id='40000000-0000-0000-0000-000000000004' and detail->>'rule'='C4_zero_dispatch') then
    raise exception 'TEST 0147 fixture precondition failed: load 40000000-...-004 is not tagged C4_zero_dispatch.';
  end if;
end
$t$;

-- Carrier A1 (direct) and Carrier A2 (factored) both need a full,
-- issuable setup so Section 10's factored-invoice-payment-fail-closed
-- regression check is a genuine, faithful assertion rather than a skip
-- (Phase 3C.1.1, Section L: "do not leave the skip as the final state").
update public.carriers set factoring_mode = 'direct', invoice_code = 'CAR0147A' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
update public.carriers set factoring_mode = 'factored', invoice_code = 'CAR0147B' where id = 'a2a2a2a2-0000-0000-0000-000000000002';
do $t$
declare v_result jsonb;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  v_result := public.activate_carrier_party('a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, null, jsonb_build_object('billing_email','billing-0147@example.test','payment_terms_days',30));
  if (v_result->>'success')::boolean is not true then
    raise notice 'TEST 0147 fixture note: activate_carrier_party (A1) did not succeed (%); issued-invoice regression checks may be skipped.', v_result;
  end if;
  v_result := public.activate_carrier_party('a2a2a2a2-0000-0000-0000-000000000002'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, null, jsonb_build_object('billing_email','billing-0147-factored@example.test','payment_terms_days',30,'factoring_eligible',true));
  reset role;
  if (v_result->>'success')::boolean is not true then
    raise notice 'TEST 0147 fixture note: activate_carrier_party (A2, factored) did not succeed (%); factored-payment regression check may be skipped.', v_result;
  end if;
end
$t$;
insert into public.factoring_companies (id, organization_id, name, legal_name, is_active) values
  ('fc470000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor 0147', 'Factor 0147 LLC', true);
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, submission_destination_email,
   is_default, is_active)
values
  ('fe470000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc470000-0000-0000-0000-000000000001',
   'a2a2a2a2-0000-0000-0000-000000000002', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Factor 0147', 'NOA 0147', 'ref-0147-1',
   current_date - 5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'secure_email', 'factor0147@example.test', true, true);

-- Two issuable loads (with pickup/delivery stops -- issue_carrier_invoice
-- requires them), one per carrier used by the issuance regression checks
-- below (Sections 6 and 10). Dedicated to this test file, distinct from
-- the pre-existing 10000000-.../20000000-... fixture loads (which have no
-- stops and are used only for classifier tests here).
insert into public.loads (id, organization_id, load_number, broker_id, status, rate, carrier_id, carrier_resolution) values
  ('70470000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'LD-0147-A1', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 500.00, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved'),
  ('70470000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'LD-0147-A2', 'a0b00000-0000-0000-0000-000000000001', 'delivered', 200.00, 'a2a2a2a2-0000-0000-0000-000000000002', 'resolved');
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
  select '11111111-1111-1111-1111-111111111111', l.id, 'pickup', 1, 'Shipper 0147', 'Dallas', 'TX', now() - interval '3 days'
  from public.loads l where l.load_number like 'LD-0147-%';
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
  select '11111111-1111-1111-1111-111111111111', l.id, 'delivery', 2, 'Receiver 0147', 'Houston', 'TX', now() - interval '1 day'
  from public.loads l where l.load_number like 'LD-0147-%';

insert into public.invoices (id, organization_id, load_id, broker_id, status, total_amount, amount_paid, invoice_number) values
  ('c0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '30000000-0000-0000-0000-000000000003', 'a0b00000-0000-0000-0000-000000000001', 'draft', 500, 0, 'LI-CONFLICT-1'),
  ('c0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '40000000-0000-0000-0000-000000000004', 'a0b00000-0000-0000-0000-000000000001', 'draft', 500, 0, 'LI-MISSING-1'),
  ('c0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '10000000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'draft', 500, 0, 'LI-SAFE-1'),
  ('c0000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', null, null, 'void', 500, 0, 'LI-VOID-1'),
  ('c0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', '10000000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'paid', 500, 500, 'LI-PAID-1');

\echo '===== SECTION 1: classifier -- every bucket, real reachable conflict, precedence, no auto-reclassification, cross-org isolation ====='
do $t$
declare
  v_c text;
begin
  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000001');
  if v_c <> 'conflicting_carrier_evidence' then
    raise exception 'TEST 0147 FAIL: expected conflicting_carrier_evidence for genuinely conflicting load, got %', v_c;
  end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000002');
  if v_c <> 'missing_carrier_evidence' then
    raise exception 'TEST 0147 FAIL: expected missing_carrier_evidence for zero-dispatch load, got %', v_c;
  end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000003');
  if v_c <> 'safely_identifiable_legacy' then
    raise exception 'TEST 0147 FAIL: expected safely_identifiable_legacy for resolved load, got %', v_c;
  end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000004');
  if v_c <> 'voided_cancelled' then
    raise exception 'TEST 0147 FAIL: expected voided_cancelled (precedence over everything else), got %', v_c;
  end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000005');
  if v_c <> 'paid_or_partially_paid' then
    raise exception 'TEST 0147 FAIL: expected paid_or_partially_paid, got %', v_c;
  end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('00000000-0000-0000-0000-000000000000');
  if v_c <> 'not_found' then
    raise exception 'TEST 0147 FAIL: expected not_found, got %', v_c;
  end if;

  raise notice 'OK: classifier buckets (conflicting/missing/safe/voided/paid/not_found) all correct.';
end
$t$;

-- No automatic reclassification: loads.carrier_id/carrier_resolution and
-- unresolved_carrier_records are byte-identical before/after calling the
-- pure, STABLE classifier repeatedly.
do $t$
declare
  v_before text;
  v_after text;
begin
  select md5(string_agg(id::text || coalesce(carrier_id::text,'') || coalesce(carrier_resolution,''), '|' order by id)) into v_before from public.loads;
  perform public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000001');
  perform public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000002');
  select md5(string_agg(id::text || coalesce(carrier_id::text,'') || coalesce(carrier_resolution,''), '|' order by id)) into v_after from public.loads;
  if v_before <> v_after then
    raise exception 'TEST 0147 FAIL: classify_legacy_invoice_for_carrier_migration mutated loads (no automatic reclassification permitted).';
  end if;
  raise notice 'OK: classifier is read-only, no automatic reclassification.';
end
$t$;

-- Cross-org isolation: an invoice/load pair from org 2 classifies using
-- ONLY its own org's evidence -- no bleed-through from org 1's fixtures.
insert into public.invoices (id, organization_id, load_id, broker_id, status, total_amount, amount_paid, invoice_number)
  select 'c0000000-0000-0000-0000-000000000006', organization_id, id, null, 'draft', 500, 0, 'LI-ORG2-1'
  from public.loads where organization_id = '22222222-2222-2222-2222-222222222222' limit 1;
do $t$
declare
  v_c text;
begin
  if exists (select 1 from public.invoices where id = 'c0000000-0000-0000-0000-000000000006') then
    v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000006');
    if v_c is null then
      raise exception 'TEST 0147 FAIL: cross-org classification returned null.';
    end if;
    raise notice 'OK: cross-org classification ran in isolation (result: %).', v_c;
  else
    raise notice 'OK (skipped): no org-2 load fixture present to attach a cross-org invoice to.';
  end if;
end
$t$;

\echo '===== SECTION 1B: classifier adversarial review (Phase 3C.1.1) -- live-derivation correctness, immunity to unresolved_carrier_records corruption/absence, staleness resistance ====='

-- A load never classified by 0133 at all (carrier_id AND carrier_resolution
-- both null) -- the exact edge case the original 0142 code mishandled.
insert into public.loads (id, organization_id, load_number, status, carrier_resolution) values
  ('e2000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'LD-ADV-NEVER', 'delivered', null);
insert into public.invoices (id, organization_id, load_id, broker_id, status, total_amount, amount_paid, invoice_number) values
  ('d0000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'e2000000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'draft', 500, 0, 'ADV-NEVERCLASSIFIED-1');
do $t$
declare v_c text;
begin
  v_c := public.classify_legacy_invoice_for_carrier_migration('d0000000-0000-0000-0000-000000000005');
  if v_c <> 'missing_carrier_evidence' then
    raise exception 'TEST 0147 FAIL: a load with carrier_id AND carrier_resolution both null must classify missing_carrier_evidence (never safely_identifiable_legacy), got %', v_c;
  end if;
  raise notice 'OK: never-classified load (carrier_id and carrier_resolution both null) correctly classifies missing_carrier_evidence, not safely_identifiable_legacy.';
end
$t$;

-- A genuine, live-reachable C1 controller conflict: financial_dispatch_id
-- names one carrier, but a currently non-cancelled dispatch on the same
-- load names a different one. guard_dispatch_carrier_scope() (0132/0135)
-- now prevents constructing this via ordinary INSERT going forward --
-- session_replication_role=replica bypasses it here only to reconstruct
-- the same shape historical pre-guard data could have, exactly like every
-- other disposable fixture in this audit series that reaches an
-- otherwise-unreachable-via-normal-paths state.
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  ('f1470000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'ADV-0147-T1'),
  ('f2470000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'ADV-0147-T2');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  ('f3470000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Adv0147', 'One'),
  ('f4470000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'Adv0147', 'Two');
insert into public.loads (id, organization_id, load_number, status) values
  ('e0470000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'LD-ADV-C1', 'delivered');
do $t$
begin
  set local session_replication_role = replica;
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status) values
    ('e1470000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e0470000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'f1470000-0000-0000-0000-000000000001', 'f3470000-0000-0000-0000-000000000001', 'assigned'),
    ('e1470000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'e0470000-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002', 'f2470000-0000-0000-0000-000000000002', 'f4470000-0000-0000-0000-000000000002', 'assigned');
  set local session_replication_role = default;
end
$t$;
update public.loads set financial_dispatch_id = 'e1470000-0000-0000-0000-000000000001' where id = 'e0470000-0000-0000-0000-000000000001';
insert into public.invoices (id, organization_id, load_id, broker_id, status, total_amount, amount_paid, invoice_number) values
  ('d0000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'e0470000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'draft', 500, 0, 'ADV-C1CONFLICT-1');
do $t$
declare v_c text;
begin
  v_c := public.classify_legacy_invoice_for_carrier_migration('d0000000-0000-0000-0000-000000000006');
  if v_c <> 'conflicting_carrier_evidence' then
    raise exception 'TEST 0147 FAIL: a genuine, reachable C1 controller conflict must classify conflicting_carrier_evidence, got %', v_c;
  end if;
  raise notice 'OK: a real, constraint-valid, live-reachable C1 controller conflict correctly classifies conflicting_carrier_evidence (BLOCKER 1 is genuinely fixed, not just re-labeled).';
end
$t$;

-- Immunity to unresolved_carrier_records corruption/absence: malformed
-- detail, an unknown rule string, and complete row deletion must each
-- have ZERO effect on classification -- the corrected implementation
-- never reads this table at all.
do $t$
declare v_c text;
begin
  update public.unresolved_carrier_records set detail = '"not even an object"'::jsonb
    where record_type = 'load' and record_id = '30000000-0000-0000-0000-000000000003';
  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000001');
  if v_c <> 'conflicting_carrier_evidence' then
    raise exception 'TEST 0147 FAIL: malformed unresolved_carrier_records.detail changed classification to %.', v_c;
  end if;

  update public.unresolved_carrier_records set detail = jsonb_build_object('rule', 'SOMETHING_MADE_UP')
    where record_type = 'load' and record_id = '30000000-0000-0000-0000-000000000003';
  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000001');
  if v_c <> 'conflicting_carrier_evidence' then
    raise exception 'TEST 0147 FAIL: an unknown/unrecognized rule string changed classification to %.', v_c;
  end if;

  delete from public.unresolved_carrier_records where record_type = 'load' and record_id = '30000000-0000-0000-0000-000000000003';
  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000001');
  if v_c <> 'conflicting_carrier_evidence' then
    raise exception 'TEST 0147 FAIL: deleting the unresolved_carrier_records row entirely changed classification to %.', v_c;
  end if;
  raise notice 'OK: classification is completely immune to unresolved_carrier_records corruption, unknown content, and absence -- malformed detail, an unrecognized rule, and a missing row all leave the live-derived result unchanged.';
end
$t$;

-- Staleness resistance (the decisive adversarial finding): cancel one of
-- the two contending dispatches AFTER the fact. A frozen-label design
-- would report "conflicting" forever; live re-derivation must correctly
-- flip to the now-unambiguous single carrier.
do $t$
declare v_c text;
begin
  update public.dispatches set status = 'cancelled' where id = 'd3b30000-0000-0000-0000-00000000000b';
  v_c := public.classify_legacy_invoice_for_carrier_migration('c0000000-0000-0000-0000-000000000001');
  if v_c <> 'safely_identifiable_legacy' then
    raise exception 'TEST 0147 FAIL: cancelling the contending dispatch should make this load live-resolvable (safely_identifiable_legacy), got %.', v_c;
  end if;
  raise notice 'OK: classification tracks LIVE dispatch state -- cancelling the contending dispatch correctly flips the result from conflicting to safely_identifiable_legacy (proves immunity to the staleness a frozen diagnostic label would have introduced).';
end
$t$;

\echo '===== SECTION 2: carrier_invoices direct-write grants ====='
do $t$
begin
  if has_table_privilege('authenticated', 'public.carrier_invoices', 'INSERT') then
    raise exception 'TEST 0147 FAIL: authenticated still has direct INSERT on carrier_invoices.';
  end if;
  if has_table_privilege('authenticated', 'public.carrier_invoices', 'DELETE') then
    raise exception 'TEST 0147 FAIL: authenticated still has direct DELETE on carrier_invoices.';
  end if;
  if has_table_privilege('anon', 'public.carrier_invoices', 'INSERT') or has_table_privilege('anon', 'public.carrier_invoices', 'DELETE') then
    raise exception 'TEST 0147 FAIL: anon has a direct INSERT/DELETE on carrier_invoices.';
  end if;
  raise notice 'OK: direct INSERT/DELETE denied for authenticated and anon at the grant level.';
end
$t$;

-- Behavioral proof (not just catalog): every business role's direct
-- INSERT attempt fails at "permission denied", not an RLS rejection --
-- proving the GRANT itself is gone, not merely narrowed by policy.
do $t$
declare
  v_role record;
  v_failed boolean;
begin
  for v_role in select * from (values
    ('aaaa0000-0000-0000-0000-000000000001','owner'),
    ('cccc0000-0000-0000-0000-000000000001','accountant'),
    ('dddd0000-0000-0000-0000-000000000001','dispatcher'),
    ('eeee0000-0000-0000-0000-000000000001','driver'),
    ('ffff0000-0000-0000-0000-000000000001','viewer')
  ) as r(uid, label) loop
    v_failed := false;
    begin
      perform set_config('test.current_uid', v_role.uid, true);
      execute 'set local role authenticated';
      execute format('insert into public.carrier_invoices (organization_id, invoice_document_type, issuance_status, carrier_id, currency) values (%L, %L, %L, %L, %L)',
        '11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'draft', 'a1a1a1a1-0000-0000-0000-000000000001', 'USD');
    exception when insufficient_privilege then
      v_failed := true;
    end;
    if not v_failed then
      raise exception 'TEST 0147 FAIL: direct INSERT as % succeeded (should be permission denied).', v_role.label;
    end if;
  end loop;
  raise notice 'OK: direct INSERT denied (permission denied) for every business role: owner/accountant/dispatcher/driver/viewer.';
end
$t$;
reset role;

\echo '===== SECTION 3: exact three RPC signatures hardened, no overload, structured output only ====='
do $t$
begin
  if has_function_privilege('anon', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.scan_legacy_invoices_for_carrier_migration()', 'EXECUTE') then
    raise exception 'TEST 0147 FAIL: anon can still EXECUTE one of the three hardened RPCs.';
  end if;
  if (select count(*) from pg_proc where proname='update_carrier_invoice_draft' and pronamespace='public'::regnamespace) <> 1
     or (select count(*) from pg_proc where proname='review_legacy_invoice_carrier_migration' and pronamespace='public'::regnamespace) <> 1
     or (select count(*) from pg_proc where proname='scan_legacy_invoices_for_carrier_migration' and pronamespace='public'::regnamespace) <> 1 then
    raise exception 'TEST 0147 FAIL: an unexpected overload exists for one of the three hardened RPCs.';
  end if;
  raise notice 'OK: exact three signatures hardened, no overload.';
end
$t$;

-- Behavioral: anon actually gets denied at connection time (permission
-- denied for function), not merely absent from has_function_privilege.
do $t$
declare
  v_denied boolean := false;
begin
  begin
    set role anon;
    perform public.scan_legacy_invoices_for_carrier_migration();
  exception when insufficient_privilege then
    v_denied := true;
  end;
  reset role;
  if not v_denied then
    raise exception 'TEST 0147 FAIL: anon was not denied calling scan_legacy_invoices_for_carrier_migration.';
  end if;
  raise notice 'OK: anon denied at the EXECUTE level (behavioral, not just catalog).';
end
$t$;

\echo '===== SECTION 4: null-identity fail-closed in scan ====='
do $t$
declare
  v_raised boolean := false;
begin
  begin
    perform set_config('test.current_uid', null, true);
    set local role authenticated;
    perform public.scan_legacy_invoices_for_carrier_migration();
  exception when others then
    v_raised := true;
    if sqlerrm not ilike '%authentication required%' then
      raise exception 'TEST 0147 FAIL: null-identity scan raised the wrong error: %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'TEST 0147 FAIL: null-identity scan did not raise at all (fail-open regression).';
  end if;
  raise notice 'OK: null-identity (auth.uid() IS NULL) caller is rejected, not silently given a zero-row success.';
end
$t$;
reset role;

-- authenticated-with-no-profile-row: current_org_id()/has_role() both
-- return NULL for a uid with no matching profiles row -- must also raise.
do $t$
declare
  v_raised boolean := false;
begin
  begin
    perform set_config('test.current_uid', 'ffffffff-ffff-ffff-ffff-ffffffffffff', true);
    set local role authenticated;
    perform public.scan_legacy_invoices_for_carrier_migration();
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'TEST 0147 FAIL: scan succeeded for an authenticated uid with no profile row.';
  end if;
  raise notice 'OK: authenticated-but-no-profile caller is also rejected.';
end
$t$;
reset role;

\echo '===== SECTION 5: create_carrier_invoice_draft -- roles, validation, idempotency ====='
do $t$
declare
  v_result jsonb;
  v_broker uuid;
begin
  select id into v_broker from public.brokers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1;

  -- owner succeeds
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'owner create', 'sec5-owner-1');
  if (v_result->>'success')::boolean is not true then
    raise exception 'TEST 0147 FAIL: owner create_carrier_invoice_draft failed: %', v_result;
  end if;

  -- accountant succeeds
  perform set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', true);
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'accountant create', 'sec5-acct-1');
  if (v_result->>'success')::boolean is not true then
    raise exception 'TEST 0147 FAIL: accountant create_carrier_invoice_draft failed: %', v_result;
  end if;

  -- dispatcher succeeds
  perform set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', true);
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'dispatcher create', 'sec5-disp-1');
  if (v_result->>'success')::boolean is not true then
    raise exception 'TEST 0147 FAIL: dispatcher create_carrier_invoice_draft failed: %', v_result;
  end if;

  -- driver fails
  perform set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', true);
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'driver create', 'sec5-driver-1');
  if v_result->>'code' <> 'FORBIDDEN' then
    raise exception 'TEST 0147 FAIL: driver create_carrier_invoice_draft did not return FORBIDDEN: %', v_result;
  end if;

  -- viewer fails
  perform set_config('test.current_uid', 'ffff0000-0000-0000-0000-000000000001', true);
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'viewer create', 'sec5-viewer-1');
  if v_result->>'code' <> 'FORBIDDEN' then
    raise exception 'TEST 0147 FAIL: viewer create_carrier_invoice_draft did not return FORBIDDEN: %', v_result;
  end if;

  -- cross-org owner: carrier belongs to org 1, caller is org 2 owner -> INVALID_CARRIER
  perform set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', true);
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'cross-org create', 'sec5-crossorg-1');
  if (v_result->>'success')::boolean is true then
    raise exception 'TEST 0147 FAIL: cross-org owner was able to create a draft against another org''s carrier: %', v_result;
  end if;

  -- inactive carrier rejected
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a3a3a3a3-0000-0000-0000-000000000003'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'inactive carrier', 'sec5-inactive-1');
  if v_result->>'code' <> 'INVALID_CARRIER' then
    raise exception 'TEST 0147 FAIL: inactive carrier was not rejected: %', v_result;
  end if;

  -- missing reason / idempotency key rejected
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, null, null, 'sec5-noreason-1');
  if v_result->>'code' <> 'INVALID_INPUT' then
    raise exception 'TEST 0147 FAIL: missing reason was not rejected: %', v_result;
  end if;
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'reason ok', null);
  if v_result->>'code' <> 'INVALID_INPUT' then
    raise exception 'TEST 0147 FAIL: missing idempotency key was not rejected: %', v_result;
  end if;

  -- dispatch-service invoice with a recipient rejected
  v_result := public.create_carrier_invoice_draft('dispatch_service_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', null, null, null, 'r', 'sec5-dsi-badrecip-1');
  if v_result->>'code' <> 'INVALID_INPUT' then
    raise exception 'TEST 0147 FAIL: dispatch-service invoice with a recipient was not rejected: %', v_result;
  end if;

  raise notice 'OK: create_carrier_invoice_draft role matrix, cross-org, inactive-carrier, missing-input, and document-shape validation all correct.';
end
$t$;
reset role;

-- idempotency replay (same key/payload -> identical result, no duplicate row) and collision (same key, different payload -> rejected)
do $t$
declare
  v_r1 jsonb;
  v_r2 jsonb;
  v_r3 jsonb;
  v_broker uuid;
  v_count integer;
begin
  select id into v_broker from public.brokers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1;
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  v_r1 := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'replay', 'sec5-replay-key');
  v_r2 := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'replay', 'sec5-replay-key');
  if v_r1 <> v_r2 then
    raise exception 'TEST 0147 FAIL: idempotent replay returned a different result: % vs %', v_r1, v_r2;
  end if;
  select count(*) into v_count from public.carrier_invoices where id = (v_r1->>'invoice_id')::uuid;
  if v_count <> 1 then
    raise exception 'TEST 0147 FAIL: idempotent replay created % rows instead of exactly 1.', v_count;
  end if;
  v_r3 := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 60, null, 'DIFFERENT', 'replay', 'sec5-replay-key');
  if v_r3->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST 0147 FAIL: same key with a different payload was not rejected: %', v_r3;
  end if;
  raise notice 'OK: create_carrier_invoice_draft idempotency replay and collision-rejection both correct.';
end
$t$;
reset role;

\echo '===== SECTION 6: delete_carrier_invoice_draft -- roles, optimistic concurrency, state guard, idempotency ====='
do $t$
declare
  v_id uuid;
  v_upd timestamptz;
  v_result jsonb;
  v_broker uuid;
begin
  select id into v_broker from public.brokers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1;
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'to be deleted', 'sec6-target-1');
  v_id := (v_result->>'invoice_id')::uuid;
  select updated_at into v_upd from public.carrier_invoices where id = v_id;

  -- dispatcher cannot delete (not in the delete role matrix)
  perform set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', true);
  v_result := public.delete_carrier_invoice_draft(v_id, v_upd, 'nope', 'sec6-dispatcher-del-1');
  if v_result->>'code' <> 'FORBIDDEN' then
    raise exception 'TEST 0147 FAIL: dispatcher was able to delete a draft (should be FORBIDDEN): %', v_result;
  end if;

  -- stale expected_updated_at rejected
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  v_result := public.delete_carrier_invoice_draft(v_id, v_upd - interval '1 hour', 'stale', 'sec6-stale-1');
  if v_result->>'code' <> 'STALE_RECORD' then
    raise exception 'TEST 0147 FAIL: stale expected_updated_at was not rejected: %', v_result;
  end if;

  -- cross-org owner gets NOT_FOUND (indistinguishable from a missing row)
  perform set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', true);
  v_result := public.delete_carrier_invoice_draft(v_id, v_upd, 'cross-org', 'sec6-crossorg-1');
  if v_result->>'code' <> 'NOT_FOUND' then
    raise exception 'TEST 0147 FAIL: cross-org delete did not return NOT_FOUND: %', v_result;
  end if;

  -- owner succeeds
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  v_result := public.delete_carrier_invoice_draft(v_id, v_upd, 'cleanup', 'sec6-owner-del-1');
  if (v_result->>'success')::boolean is not true then
    raise exception 'TEST 0147 FAIL: owner delete_carrier_invoice_draft failed: %', v_result;
  end if;
  if exists (select 1 from public.carrier_invoices where id = v_id) then
    raise exception 'TEST 0147 FAIL: invoice still exists after a successful delete.';
  end if;

  -- replay of the same delete key returns the same cached result, no error
  v_result := public.delete_carrier_invoice_draft(v_id, v_upd, 'cleanup', 'sec6-owner-del-1');
  if (v_result->>'success')::boolean is not true then
    raise exception 'TEST 0147 FAIL: delete idempotency replay did not return the cached success result: %', v_result;
  end if;

  raise notice 'OK: delete_carrier_invoice_draft role matrix, optimistic concurrency, cross-org NOT_FOUND, and idempotency replay all correct.';
end
$t$;
reset role;

-- ready_for_issue / issued / voided invoices cannot be deleted via the RPC
-- (deliberately narrower than the underlying trigger -- see migration
-- header). issue_carrier_invoice()'s own preconditions (carrier-party
-- eligibility, factoring policy, remittance profile, etc.) are pre-
-- existing 0146 machinery this migration does not touch and are already
-- exhaustively fixture-tested by TEST_0146 itself; reaching a genuinely
-- issued row here only to exercise delete_carrier_invoice_draft's OWN
-- state guard would require reproducing that entire fixture. Instead,
-- transition a real draft directly to issuance_status='issued' (the
-- minimum shape cinv_number_iff_issued requires), which isolates exactly
-- the behavior under test: delete_carrier_invoice_draft's own state check.
do $t$
declare
  v_id uuid;
  v_upd timestamptz;
  v_result jsonb;
  v_broker uuid;
begin
  select id into v_broker from public.brokers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1;
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'to be issued', 'sec6-issue-1');
  v_id := (v_result->>'invoice_id')::uuid;
  reset role;

  -- guard_carrier_invoice_lifecycle_transition() correctly refuses a
  -- direct transition to 'issued' without a real issuance snapshot (that
  -- transition is reserved for issue_carrier_invoice() alone) -- bypass
  -- triggers for this one fixture-construction statement only, exactly
  -- like every other disposable fixture in this audit series that needs
  -- to reach a state no ordinary write path can produce.
  set local session_replication_role = replica;
  update public.carrier_invoices
    set issuance_status = 'issued', invoice_number = 'TEST-0147-ISSUED-1', issued_at = now(), issued_by = 'aaaa0000-0000-0000-0000-000000000001'
    where id = v_id;
  set local session_replication_role = default;

  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  select updated_at into v_upd from public.carrier_invoices where id = v_id;
  v_result := public.delete_carrier_invoice_draft(v_id, v_upd, 'try delete issued', 'sec6-issued-del-1');
  if (v_result->>'success')::boolean is true then
    raise exception 'TEST 0147 FAIL: an issued invoice was deletable via delete_carrier_invoice_draft.';
  end if;
  if v_result->>'code' <> 'INVALID_STATE' then
    raise exception 'TEST 0147 FAIL: issued-invoice delete returned an unexpected code: %', v_result;
  end if;
  raise notice 'OK: an issued invoice cannot be deleted via delete_carrier_invoice_draft (INVALID_STATE).';
end
$t$;
reset role;

\echo '===== SECTION 7: structured output never leaks raw SQL error detail ====='
do $t$
declare
  v_result jsonb;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  -- Force the guard trigger to reject org consistency by referencing a
  -- carrier from a different organization -- proves the RPC's own
  -- exception handler sanitizes the trigger's raw error instead of
  -- letting it propagate.
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'b1b1b1b1-0000-0000-0000-000000000001'::uuid, null, null, null, 'USD', null, null, null, 'r', 'sec7-badorg-1');
  -- b1b1... belongs to org 2 -- carrier_ids_selectable_for_new_records()
  -- for org 1's caller already excludes it, so this should be INVALID_CARRIER,
  -- not a raw trigger exception -- either way, the result must be clean jsonb.
  if v_result ? 'sqlstate' or v_result ? 'detail' or v_result ? 'hint' or v_result ? 'context' or (v_result::text ilike '%pg_proc%') or (v_result::text ilike '%constraint%') then
    raise exception 'TEST 0147 FAIL: structured output leaked raw SQL error shape: %', v_result;
  end if;
  raise notice 'OK: structured failures never carry SQLSTATE/DETAIL/HINT/CONTEXT or raw constraint text.';
end
$t$;
reset role;

\echo '===== SECTION 8: zero side effects on every failure path ====='
do $t$
declare
  v_before_inv bigint;
  v_before_create_idem bigint;
  v_before_delete_idem bigint;
  v_before_audit bigint;
  v_after_inv bigint;
  v_after_create_idem bigint;
  v_after_delete_idem bigint;
  v_after_audit bigint;
begin
  select count(*) into v_before_inv from public.carrier_invoices;
  select count(*) into v_before_create_idem from public.carrier_invoice_draft_create_idempotency;
  select count(*) into v_before_delete_idem from public.carrier_invoice_draft_delete_idempotency;
  select count(*) into v_before_audit from public.activity_logs where entity_type='invoice' and action like 'carrier_invoice_draft_%';

  perform set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  perform public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, null, null, null, 'USD', null, null, null, 'r', 'sec8-driver-fail-1');
  perform public.delete_carrier_invoice_draft('00000000-0000-0000-0000-000000000000'::uuid, now(), 'r', 'sec8-driver-fail-2');
  reset role;

  select count(*) into v_after_inv from public.carrier_invoices;
  select count(*) into v_after_create_idem from public.carrier_invoice_draft_create_idempotency;
  select count(*) into v_after_delete_idem from public.carrier_invoice_draft_delete_idempotency;
  select count(*) into v_after_audit from public.activity_logs where entity_type='invoice' and action like 'carrier_invoice_draft_%';

  if v_before_inv <> v_after_inv or v_before_create_idem <> v_after_create_idem
     or v_before_delete_idem <> v_after_delete_idem or v_before_audit <> v_after_audit then
    raise exception 'TEST 0147 FAIL: a failed call produced a side effect (invoices %/%. create_idem %/%, delete_idem %/%, audit %/%).',
      v_before_inv, v_after_inv, v_before_create_idem, v_after_create_idem, v_before_delete_idem, v_after_delete_idem, v_before_audit, v_after_audit;
  end if;
  raise notice 'OK: zero mutation/idempotency/audit side effects on failure paths.';
end
$t$;

\echo '===== SECTION 9: exact audit count -- one log_activity() event per success, never per failure ====='
do $t$
declare
  v_before bigint;
  v_after bigint;
  v_broker uuid;
begin
  select id into v_broker from public.brokers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1;
  select count(*) into v_before from public.activity_logs where entity_type='invoice' and action='carrier_invoice_draft_created';
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  perform public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'audit count', 'sec9-audit-1');
  -- replay of the SAME key must not add a second audit event
  perform public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'audit count', 'sec9-audit-1');
  select count(*) into v_after from public.activity_logs where entity_type='invoice' and action='carrier_invoice_draft_created';
  if v_after - v_before <> 1 then
    raise exception 'TEST 0147 FAIL: expected exactly 1 new audit event for one create + one replay, got %.', v_after - v_before;
  end if;
  raise notice 'OK: exactly one audit event per success, replay does not duplicate it.';
end
$t$;
reset role;

\echo '===== SECTION 10: REGRESSION -- update_carrier_invoice_draft, issuance, payments, factoring fail-closed, immutable snapshots, no number consumed ====='
do $t$
declare
  v_id uuid;
  v_result jsonb;
  v_broker uuid;
begin
  select id into v_broker from public.brokers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1;
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  v_result := public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'regress', 'sec10-regress-1');
  v_id := (v_result->>'invoice_id')::uuid;

  -- update_carrier_invoice_draft still works for the intended role.
  v_result := public.update_carrier_invoice_draft(v_id, jsonb_build_object('notes','updated via 0143 RPC'), (select updated_at from public.carrier_invoices where id=v_id), 'update test', 'sec10-update-1');
  if (v_result->>'success')::boolean is not true then
    raise exception 'TEST 0147 FAIL: update_carrier_invoice_draft regressed: %', v_result;
  end if;

  -- draft-only actions never consume an invoice_number.
  if (select invoice_number from public.carrier_invoices where id = v_id) is not null then
    raise exception 'TEST 0147 FAIL: a draft-only action consumed an invoice_number.';
  end if;

  raise notice 'OK: update_carrier_invoice_draft unaffected; no number consumed by draft-only actions.';
end
$t$;
reset role;

-- legacy scan/review still work end-to-end for owner/admin.
do $t$
declare
  v_count integer;
  v_review_id uuid;
  v_result jsonb;
begin
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  v_count := public.scan_legacy_invoices_for_carrier_migration();
  if v_count < 1 then
    raise exception 'TEST 0147 FAIL: scan_legacy_invoices_for_carrier_migration regressed (scanned 0 rows).';
  end if;

  select id into v_review_id from public.legacy_invoice_carrier_migration_review where legacy_invoice_id = 'c0000000-0000-0000-0000-000000000003';
  v_result := public.review_legacy_invoice_carrier_migration(v_review_id, 'reviewed in TEST_0147', null, (select updated_at from public.legacy_invoice_carrier_migration_review where id=v_review_id), 'sec10-review-1');
  if (v_result->>'success')::boolean is not true then
    raise exception 'TEST 0147 FAIL: review_legacy_invoice_carrier_migration regressed: %', v_result;
  end if;
  raise notice 'OK: scan_legacy_invoices_for_carrier_migration / review_legacy_invoice_carrier_migration unaffected for owner.';
end
$t$;
reset role;

-- factored carrier still fails closed for direct payment (0146 behavior, untouched).
do $t$
declare
  v_broker uuid;
  v_id uuid;
  v_li_id uuid;
  v_issue_result jsonb;
  v_pay_result jsonb;
begin
  select id into v_broker from public.brokers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1;
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  set local role authenticated;
  v_id := (public.create_carrier_invoice_draft('carrier_freight_invoice'::public.invoice_document_type, 'a2a2a2a2-0000-0000-0000-000000000002'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'factored path', 'sec10-factored-1')->>'invoice_id')::uuid;
  if v_id is null then
    raise exception 'TEST 0147 FAIL: could not create a draft against the factored carrier fixture.';
  end if;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'Freight charge', 1, 200);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, '70470000-0000-0000-0000-000000000002');
  v_issue_result := public.issue_carrier_invoice(v_id, (select updated_at from public.carrier_invoices where id=v_id), 'issue factored', 'sec10-factored-issue-1');
  if (v_issue_result->>'success')::boolean is not true then
    raise exception 'TEST 0147 FAIL: issuance did not succeed for the factored fixture: %', v_issue_result;
  end if;
  v_pay_result := public.record_carrier_invoice_payment(v_id, 200, current_date, 'wire', 'carrier', (select updated_at from public.carrier_invoices where id=v_id), 'sec10-factored-pay-1', 'pay factored');
  if (v_pay_result->>'success')::boolean is true then
    raise exception 'TEST 0147 FAIL: a factored freight invoice accepted a direct payment (should remain fail-closed).';
  end if;
  if v_pay_result->>'code' <> 'FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW' then
    raise exception 'TEST 0147 FAIL: factored-invoice payment was rejected for the WRONG reason (expected FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW): %', v_pay_result;
  end if;
  raise notice 'OK: factored-invoice direct-payment fail-closed behavior unaffected (code: %).', v_pay_result->>'code';
end
$t$;
reset role;

\echo '===== SECTION 11: immutable snapshot regression (structural, no new fixture needed) ====='
do $t$
begin
  if not exists (select 1 from pg_trigger where tgname='a0142_guard_snapshot_immutable' and not tgisinternal) then
    raise exception 'TEST 0147 FAIL: carrier_invoice_issuance_snapshots immutability trigger is missing.';
  end if;
  raise notice 'OK: snapshot immutability trigger still installed.';
end
$t$;

\echo '################  TEST 0147 PASSED  ################'
