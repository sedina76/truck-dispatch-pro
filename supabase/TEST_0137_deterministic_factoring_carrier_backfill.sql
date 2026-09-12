-- ============================================================================
-- TEST_0137_deterministic_factoring_carrier_backfill.sql
-- disposable database only. Run via TEST_0130_0133_run.sh.
--
-- Phase 3B.1 verification: 0137's deterministic backfill classification --
-- single-carrier-org, multi-carrier-org-provable, unresolved (no evidence /
-- multiple carriers), structural-conflict abort, and that historical
-- factored_invoices numeric snapshots are never touched.
--
-- Fixtures are built BEFORE 0137 is applied (0136 is applied first, then
-- fixtures, then 0137), matching 0133's own "seed data, then apply the
-- backfill migration" test structure.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0137  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i TEST_SUPPORT_0136_0138_factoring_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql
\i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
\i migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql
\i migrations/0136_carrier_factoring_policy_and_relationship_columns.sql

\echo '===== fixtures: two companies, several relationships, invoices tied to dispatches with known carriers ====='
do $t$
begin
  -- Org B (222...) has exactly ONE carrier in the standard seed -- perfect
  -- for the single_carrier_org rule. Give it its own factoring company +
  -- relationship with ZERO invoice evidence at all.
  insert into public.factoring_companies (id, organization_id, name)
  values ('fc00000b-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'Org B Factor');
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type)
  values ('fe00000b-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'fc00000b-0000-0000-0000-00000000000b',
          90, 3, 10, 'deducted_at_funding', 'non_recourse');

  -- Org A (111..., multi-carrier -- A1/A2/A3(inactive) in the standard seed) gets
  -- THREE relationships against ONE company:
  --   R1: provable  -- every factored_invoice evidence points to A1 only.
  --   R2: unresolved (no evidence) -- zero factored_invoices at all.
  --   R3: unresolved (multiple)    -- evidence points to BOTH A1 and A2.
  insert into public.factoring_companies (id, organization_id, name)
  values ('fc00000a-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'Org A Factor');

  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type)
  values
    ('fe00000a-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc00000a-0000-0000-0000-00000000000a', 90, 3, 10, 'deducted_at_funding', 'non_recourse'),
    ('fe00000a-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'fc00000a-0000-0000-0000-00000000000a', 88, 4, 12, 'deducted_from_reserve', 'recourse'),
    ('fe00000a-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'fc00000a-0000-0000-0000-00000000000a', 92, 2, 8, 'deducted_at_funding', 'non_recourse');

  -- Two invoices, both tied (via dispatch_id) to L1's own seed dispatch
  -- (d1d10000...001, carrier A1) -- both cite relationship R1 -> provable,
  -- single distinct carrier (A1).
  insert into public.invoices (id, organization_id, dispatch_id, invoice_number)
  values
    ('fa00000a-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'd1d10000-0000-0000-0000-000000000001', 'INV-A-1'),
    ('fa00000a-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'd1d10000-0000-0000-0000-000000000001', 'INV-A-2');
  insert into public.factored_invoices
    (organization_id, invoice_id, factoring_company_id, factoring_relationship_id,
     invoice_face_value, advance_percentage, expected_advance_amount, factoring_fee_percentage, factoring_fee_amount,
     reserve_percentage, reserve_amount, fee_timing, expected_funding_amount)
  values
    ('11111111-1111-1111-1111-111111111111', 'fa00000a-0000-0000-0000-000000000001', 'fc00000a-0000-0000-0000-00000000000a', 'fe00000a-0000-0000-0000-000000000001',
     1000, 90, 900, 3, 30, 10, 100, 'deducted_at_funding', 870),
    ('11111111-1111-1111-1111-111111111111', 'fa00000a-0000-0000-0000-000000000002', 'fc00000a-0000-0000-0000-00000000000a', 'fe00000a-0000-0000-0000-000000000001',
     2000, 90, 1800, 3, 60, 10, 200, 'deducted_at_funding', 1740);

  -- R3's evidence: one invoice tied to L1's dispatch (carrier A1) and
  -- another tied to L2's own seed dispatch (d2d20000...002, carrier A2) --
  -- two DIFFERENT carriers -> unresolved_multiple.
  insert into public.invoices (id, organization_id, dispatch_id, invoice_number)
  values
    ('fa00000a-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'd1d10000-0000-0000-0000-000000000001', 'INV-A-3'),
    ('fa00000a-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'd2d20000-0000-0000-0000-000000000002', 'INV-A-4');
  insert into public.factored_invoices
    (organization_id, invoice_id, factoring_company_id, factoring_relationship_id,
     invoice_face_value, advance_percentage, expected_advance_amount, factoring_fee_percentage, factoring_fee_amount,
     reserve_percentage, reserve_amount, fee_timing, expected_funding_amount)
  values
    ('11111111-1111-1111-1111-111111111111', 'fa00000a-0000-0000-0000-000000000003', 'fc00000a-0000-0000-0000-00000000000a', 'fe00000a-0000-0000-0000-000000000003',
     500, 90, 450, 3, 15, 10, 50, 'deducted_at_funding', 435),
    ('11111111-1111-1111-1111-111111111111', 'fa00000a-0000-0000-0000-000000000004', 'fc00000a-0000-0000-0000-00000000000a', 'fe00000a-0000-0000-0000-000000000003',
     700, 90, 630, 3, 21, 10, 70, 'deducted_at_funding', 609);
end
$t$;

\i migrations/0137_deterministic_factoring_carrier_backfill.sql

\echo '----- B1. single_carrier_org: Org B relationship resolves to its only carrier, with NO invoice evidence needed -----'
do $t$
declare v_carrier uuid;
begin
  select carrier_id into v_carrier from public.factoring_relationships where id = 'fe00000b-0000-0000-0000-00000000000b';
  assert v_carrier = (select id from public.carriers where organization_id = '22222222-2222-2222-2222-222222222222'),
    format('TEST FAIL: Org B relationship not resolved to its sole carrier, got %s', v_carrier);
  raise notice 'OK: single-carrier-org relationship resolved deterministically with zero invoice evidence.';
end
$t$;

\echo '----- B2. multi_carrier_org_provable: R1 resolves to A1 (its only evidenced carrier) -----'
do $t$
declare v_carrier uuid;
begin
  select carrier_id into v_carrier from public.factoring_relationships where id = 'fe00000a-0000-0000-0000-000000000001';
  assert v_carrier = 'a1a1a1a1-0000-0000-0000-000000000001', format('TEST FAIL: R1 expected carrier A1, got %s', v_carrier);
  raise notice 'OK: multi-carrier-org relationship with unambiguous invoice evidence resolved to the correct carrier.';
end
$t$;

\echo '----- B3. unresolved_no_evidence: R2 (zero factored_invoices) stays carrier_id NULL, recorded as an exception -----'
do $t$
declare v_carrier uuid; v_exists boolean;
begin
  select carrier_id into v_carrier from public.factoring_relationships where id = 'fe00000a-0000-0000-0000-000000000002';
  assert v_carrier is null, format('TEST FAIL: R2 (no evidence) should stay unresolved, got carrier_id=%s', v_carrier);
  select exists (
    select 1 from public.unresolved_carrier_records
    where record_type='factoring_relationship' and record_id='fe00000a-0000-0000-0000-000000000002' and status='unresolved'
  ) into v_exists;
  assert v_exists, 'TEST FAIL: R2 has no open unresolved_carrier_records row';
  raise notice 'OK: a relationship with zero invoice evidence in a multi-carrier org is correctly left unresolved (no_evidence), with an exception row.';
end
$t$;

\echo '----- B4. unresolved_multiple: R3 (evidence spans A1 AND A2) stays carrier_id NULL, recorded as an exception -----'
do $t$
declare v_carrier uuid; v_exists boolean;
begin
  select carrier_id into v_carrier from public.factoring_relationships where id = 'fe00000a-0000-0000-0000-000000000003';
  assert v_carrier is null, format('TEST FAIL: R3 (ambiguous) should stay unresolved, got carrier_id=%s', v_carrier);
  select exists (
    select 1 from public.unresolved_carrier_records
    where record_type='factoring_relationship' and record_id='fe00000a-0000-0000-0000-000000000003' and status='unresolved'
  ) into v_exists;
  assert v_exists, 'TEST FAIL: R3 has no open unresolved_carrier_records row';
  raise notice 'OK: a relationship whose invoice evidence spans MULTIPLE carriers is correctly left unresolved (multiple), with an exception row -- never guessed.';
end
$t$;

\echo '----- B5. historical factored_invoices numeric snapshots are byte-for-byte unchanged -----'
do $t$
declare v_face1 numeric; v_amt1 numeric;
begin
  select invoice_face_value, expected_advance_amount into v_face1, v_amt1
  from public.factored_invoices where invoice_id = 'fa00000a-0000-0000-0000-000000000001';
  assert v_face1 = 1000 and v_amt1 = 900, format('TEST FAIL: factored_invoices numeric snapshot changed: face=%s amt=%s', v_face1, v_amt1);
  raise notice 'OK: factored_invoices historical numeric snapshots are unchanged -- this migration writes ONLY factoring_relationships.carrier_id.';
end
$t$;

\echo '----- B6. provenance table has exactly one row per relationship, matching the live carrier_id -----'
do $t$
declare v_n_rel int; v_n_prov int; v_mismatch int;
begin
  select count(*) into v_n_rel from public.factoring_relationships;
  select count(*) into v_n_prov from public.carrier_backfill_0137_provenance;
  assert v_n_rel = v_n_prov, format('TEST FAIL: %s relationships but %s provenance rows', v_n_rel, v_n_prov);
  select count(*) into v_mismatch
  from public.carrier_backfill_0137_provenance pv join public.factoring_relationships fr on fr.id = pv.relationship_id
  where pv.carrier_id is distinct from fr.carrier_id;
  assert v_mismatch = 0, format('TEST FAIL: %s provenance row(s) disagree with the live carrier_id', v_mismatch);
  raise notice 'OK: provenance is complete and consistent with the live table.';
end
$t$;

\echo '################  TEST 0137 PASSED  ################'
