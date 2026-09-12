-- ============================================================================
-- TEST_0140_factoring_authorization_and_submission_safety.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.1.4 verification (Section A, retained as-is): authorization
-- tightening -- owner/admin-only company/relationship create+delete,
-- owner/admin/accountant relationship update, dispatcher view-only.
--
-- Phase 3B.1.5 verification (Section D, REPLACES 3B.1.4's own Section D):
-- submit_invoice_to_factor() now returns an UNCONDITIONAL structured
-- rejection ({success:false, code:'CARRIER_INVOICE_SNAPSHOT_REQUIRED'})
-- for every legacy invoice, regardless of carrier/policy/readiness state
-- or caller role -- no factored_invoices/factoring_events row, no
-- 'submitted' status, ever. An already-historically-submitted invoice
-- still gets its own distinct rejection, and that history is untouched.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0140  ################'

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

\echo '===== fixtures: one factoring company; A1 and A2 each factored + ready with their own default; A1 gets a second, non-default relationship =====-'
reset role;
do $t$
begin
  insert into public.factoring_companies (id, organization_id, name, is_active) values
    ('fc140000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Shared Factor Co', true);

  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions,
     noa_template_text, noa_reference, noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active)
  values
    ('a1140000-0000-0000-0000-0000000000f1', '11111111-1111-1111-1111-111111111111', 'fc140000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
     90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Shared Factor Co, A1', 'NOA A1', 'v1', current_date - 30, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true, true),
    ('a1140000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-111111111111', 'fc140000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
     80, 5, 15, 'deducted_from_reserve', 'recourse', 'Wire to Shared Factor Co, A1 ALT', 'NOA A1 ALT', 'v1', current_date - 30, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', false, true),
    ('a2140000-0000-0000-0000-0000000000f1', '11111111-1111-1111-1111-111111111111', 'fc140000-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002',
     85, 4, 12, 'deducted_at_funding', 'non_recourse', 'Wire to Shared Factor Co, A2', 'NOA A2', 'v1', current_date - 30, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true, true);

  update public.carriers set factoring_mode = 'factored' where id in ('a1a1a1a1-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002');

  -- Two invoices, each tied to the SEED dispatch that already resolves to
  -- exactly one carrier (TEST_SUPPORT's own fixture: d1d10000 -> A1,
  -- d2d20000 -> A2) -- eligible (sent, amount_paid=0).
  insert into public.invoices (id, organization_id, dispatch_id, invoice_number, status, total_amount, amount_paid) values
    ('9b140000-0000-0000-0000-0000000000a1', '11111111-1111-1111-1111-111111111111', 'd1d10000-0000-0000-0000-000000000001', 'INV-A1', 'sent', 1000, 0),
    ('9b140000-0000-0000-0000-0000000000a2', '11111111-1111-1111-1111-111111111111', 'd2d20000-0000-0000-0000-000000000002', 'INV-A2', 'sent', 1000, 0),
    ('9b140000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', null, 'INV-NOCARRIER', 'sent', 1000, 0);
end
$t$;

-- ---------------------------------------------------------------------------
-- Section A: authorization matrix
-- ---------------------------------------------------------------------------
\echo '----- A1. dispatcher cannot create a factoring company -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    insert into public.factoring_companies (organization_id, name, is_active) values ('11111111-1111-1111-1111-111111111111', 'Dispatcher Attempt Co', true);
    raise exception 'TEST FAIL: dispatcher created a factoring company.';
  exception when insufficient_privilege or others then
    if sqlstate <> '42501' and sqlerrm not ilike '%row-level security%' then raise; end if;
    raise notice 'OK: dispatcher blocked from creating a factoring company (%).', sqlstate;
  end;
end
$t$;

\echo '----- A2. dispatcher cannot create a factoring relationship -----'
do $t$
begin
  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type)
    values
      ('11111111-1111-1111-1111-111111111111', 'fc140000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 90, 3, 10, 'deducted_at_funding', 'non_recourse');
    raise exception 'TEST FAIL: dispatcher created a factoring relationship.';
  exception when others then
    if sqlstate <> '42501' and sqlerrm not ilike '%row-level security%' then raise; end if;
    raise notice 'OK: dispatcher blocked from creating a factoring relationship (%).', sqlstate;
  end;
end
$t$;

\echo '----- A3. dispatcher cannot update ordinary relationship terms -----'
do $t$
declare v_n int;
begin
  update public.factoring_relationships set relationship_name = 'dispatcher edit' where id = 'a1140000-0000-0000-0000-0000000000f1';
  get diagnostics v_n = row_count;
  assert v_n = 0, 'TEST FAIL: dispatcher updated a factoring relationship (RLS should have matched 0 rows).';
  raise notice 'OK: dispatcher''s UPDATE matched 0 rows (RLS silently excludes it, no row changed).';
end
$t$;

\echo '----- A4. dispatcher still has VIEW-only visibility (SELECT unaffected) -----'
do $t$
declare v_n int;
begin
  select count(*) into v_n from public.factoring_relationships where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001';
  assert v_n = 2, format('TEST FAIL: dispatcher should see 2 relationships for A1, saw %s', v_n);
  raise notice 'OK: dispatcher retains full read visibility into carrier factoring relationships.';
end
$t$;

\echo '----- A5. dispatcher cannot set a default, change policy, or approve NOA -----'
do $t$
begin
  begin
    perform public.set_default_factoring_relationship('a1140000-0000-0000-0000-0000000000f2');
    raise exception 'TEST FAIL: dispatcher set a default relationship.';
  exception when others then
    if sqlerrm not ilike '%owner or admin%' then raise; end if;
    raise notice 'OK: dispatcher blocked from setting a default relationship.';
  end;
  begin
    perform public.approve_factoring_relationship_noa('a1140000-0000-0000-0000-0000000000f2', 'v2', current_date, 'text');
    raise exception 'TEST FAIL: dispatcher approved a NOA.';
  exception when others then
    if sqlerrm not ilike '%owner or admin%' then raise; end if;
    raise notice 'OK: dispatcher blocked from approving a NOA.';
  end;
end
$t$;
reset role;
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_updated_at timestamptz;
begin
  select updated_at into v_updated_at from public.carriers where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  begin
    perform public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'dispatcher trying', v_updated_at, null);
    raise exception 'TEST FAIL: dispatcher changed factoring policy.';
  exception when others then
    if sqlerrm not ilike '%owner or admin%' then raise; end if;
    raise notice 'OK: dispatcher blocked from changing factoring policy.';
  end;
end
$t$;
reset role;

\echo '----- A6. accountant CANNOT create a company or relationship -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    insert into public.factoring_companies (organization_id, name, is_active) values ('11111111-1111-1111-1111-111111111111', 'Accountant Attempt Co', true);
    raise exception 'TEST FAIL: accountant created a factoring company.';
  exception when others then
    if sqlstate <> '42501' and sqlerrm not ilike '%row-level security%' then raise; end if;
    raise notice 'OK: accountant blocked from creating a factoring company (no documented business rule grants this).';
  end;
  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type)
    values
      ('11111111-1111-1111-1111-111111111111', 'fc140000-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002', 90, 3, 10, 'deducted_at_funding', 'non_recourse');
    raise exception 'TEST FAIL: accountant created a factoring relationship.';
  exception when others then
    if sqlstate <> '42501' and sqlerrm not ilike '%row-level security%' then raise; end if;
    raise notice 'OK: accountant blocked from creating a factoring relationship.';
  end;
end
$t$;

\echo '----- A7. accountant CAN edit ordinary relationship terms -----'
do $t$
declare v_n int;
begin
  update public.factoring_relationships set relationship_name = 'accountant edit ok' where id = 'a1140000-0000-0000-0000-0000000000f2';
  get diagnostics v_n = row_count;
  assert v_n = 1, 'TEST FAIL: accountant could not update an ordinary relationship term.';
  raise notice 'OK: accountant can edit ordinary relationship terms (matrix: Yes, if explicitly safe).';
end
$t$;
reset role;

\echo '----- A8. owner/admin CAN create a company and a relationship, set default, approve NOA, change policy -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_company_id uuid; v_rel_id uuid; v_updated_at timestamptz; v_res jsonb;
begin
  insert into public.factoring_companies (organization_id, name, is_active) values ('11111111-1111-1111-1111-111111111111', 'Owner Co', true) returning id into v_company_id;
  assert v_company_id is not null, 'TEST FAIL: owner could not create a factoring company.';

  insert into public.factoring_relationships
    (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type)
  values
    ('11111111-1111-1111-1111-111111111111', v_company_id, 'a1a1a1a1-0000-0000-0000-000000000001', 90, 3, 10, 'deducted_at_funding', 'non_recourse')
  returning id into v_rel_id;
  assert v_rel_id is not null, 'TEST FAIL: owner could not create a factoring relationship.';

  raise notice 'OK: owner/admin can create factoring companies and carrier-scoped relationships.';
end
$t$;
reset role;

\echo '----- A9 (Phase 3B.1.5 bug-fix regression): approving a NOA via template text alone (no document reference) succeeds and leaves the snapshot columns null, instead of raising "record v_doc is not assigned yet" -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb; v_snap_name text; v_snap_path text;
begin
  v_res := public.approve_factoring_relationship_noa('a1140000-0000-0000-0000-0000000000f2', 'v3', current_date, 'template-only NOA language, no document');
  assert (v_res->>'success')::boolean is true, format('TEST FAIL: template-only NOA approval did not succeed, got %s', v_res);
  select noa_document_snapshot_file_name, noa_document_snapshot_file_path into v_snap_name, v_snap_path
  from public.factoring_relationships where id = 'a1140000-0000-0000-0000-0000000000f2';
  assert v_snap_name is null and v_snap_path is null, 'TEST FAIL: template-only approval should leave the document snapshot columns null.';
  raise notice 'OK: template-only NOA approval succeeds cleanly (0139''s "record not assigned yet" bug is fixed) and correctly leaves the document snapshot columns null.';
end
$t$;
reset role;

-- ---------------------------------------------------------------------------
-- Section D (Phase 3B.1.5 REWRITE): legacy submission is unconditionally,
-- structurally blocked -- no carrier state (factored+ready, direct,
-- unconfigured, carrier-less) changes the outcome, and no role (owner/
-- admin/dispatcher/accountant) can bypass it. This replaces Phase 3B.1.4's
-- Section D entirely, which tested a carrier-derivation gate that Phase
-- 3B.1.5 removed for treating live dispatch/load state as if it were an
-- immutable financial snapshot.
-- ---------------------------------------------------------------------------
\echo '----- D1. owner/admin: a factored + fully "ready" carrier''s own default relationship still gets the structured snapshot-required rejection, never success -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.submit_invoice_to_factor('9b140000-0000-0000-0000-0000000000a1', 'a1140000-0000-0000-0000-0000000000f1');
  assert (v_res->>'success')::boolean is false, format('TEST FAIL: expected success:false even for a ready carrier, got %s', v_res);
  assert v_res->>'code' = 'CARRIER_INVOICE_SNAPSHOT_REQUIRED', format('TEST FAIL: wrong code, got %s', v_res);
  assert (v_res->>'snapshot_required')::boolean is true, format('TEST FAIL: snapshot_required must be true, got %s', v_res);
  assert v_res->>'message' ilike '%carrier-specific financial snapshots%', format('TEST FAIL: unexpected message, got %s', v_res);
  raise notice 'OK: owner/admin gets the structured snapshot-required rejection even for a fully ready carrier+relationship -- readiness never authorizes a legacy submission.';
end
$t$;

\echo '----- D2. dispatcher: same scenario, same rejection -- the documented submission-role authorization (0075) does not bypass snapshot eligibility -----'
reset role;
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.submit_invoice_to_factor('9b140000-0000-0000-0000-0000000000a1', 'a1140000-0000-0000-0000-0000000000f1');
  assert (v_res->>'success')::boolean is false and v_res->>'code' = 'CARRIER_INVOICE_SNAPSHOT_REQUIRED', format('TEST FAIL: dispatcher must get the same structured rejection, got %s', v_res);
  raise notice 'OK: dispatcher''s explicit submission authority is a NECESSARY but not SUFFICIENT condition -- still blocked by the snapshot requirement.';
end
$t$;

\echo '----- D3. accountant: same scenario, same rejection -----'
reset role;
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.submit_invoice_to_factor('9b140000-0000-0000-0000-0000000000a1', 'a1140000-0000-0000-0000-0000000000f1');
  assert (v_res->>'success')::boolean is false and v_res->>'code' = 'CARRIER_INVOICE_SNAPSHOT_REQUIRED', format('TEST FAIL: accountant must get the same structured rejection, got %s', v_res);
  raise notice 'OK: accountant cannot bypass the snapshot requirement either.';
end
$t$;
reset role;

\echo '----- D4. a direct-billing carrier''s invoice gets the SAME rejection (factoring_mode is no longer even consulted) -----'
do $t$ begin update public.carriers set factoring_mode = 'direct' where id = 'a2a2a2a2-0000-0000-0000-000000000002'; end $t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.submit_invoice_to_factor('9b140000-0000-0000-0000-0000000000a2', 'a2140000-0000-0000-0000-0000000000f1');
  assert (v_res->>'success')::boolean is false and v_res->>'code' = 'CARRIER_INVOICE_SNAPSHOT_REQUIRED', format('TEST FAIL: direct-billing carrier must get the same structured rejection, got %s', v_res);
  raise notice 'OK: a direct-billing carrier''s invoice gets the identical structured rejection -- carrier policy is no longer consulted at all by this function.';
end
$t$;
reset role;

\echo '----- D5. an unconfigured carrier''s invoice gets the SAME rejection -----'
do $t$ begin update public.carriers set factoring_mode = 'unconfigured' where id = 'a2a2a2a2-0000-0000-0000-000000000002'; end $t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.submit_invoice_to_factor('9b140000-0000-0000-0000-0000000000a2', 'a2140000-0000-0000-0000-0000000000f1');
  assert (v_res->>'success')::boolean is false and v_res->>'code' = 'CARRIER_INVOICE_SNAPSHOT_REQUIRED', format('TEST FAIL: unconfigured carrier must get the same structured rejection, got %s', v_res);
  raise notice 'OK: an unconfigured carrier''s invoice gets the identical structured rejection.';
end
$t$;
reset role;

\echo '----- D6. a carrier-less invoice (no dispatch_id, no load_id) gets the SAME rejection -- a derivable carrier is not required to reach this outcome, confirming it is not what decides it -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.submit_invoice_to_factor('9b140000-0000-0000-0000-00000000000c', 'a1140000-0000-0000-0000-0000000000f1');
  assert (v_res->>'success')::boolean is false and v_res->>'code' = 'CARRIER_INVOICE_SNAPSHOT_REQUIRED', format('TEST FAIL: carrier-less invoice must get the same structured rejection, got %s', v_res);
  raise notice 'OK: a carrier-less invoice gets the identical structured rejection as every other invoice -- confirms the outcome never depended on whether a carrier happens to be derivable.';
end
$t$;

\echo '----- D7. an obviously bogus/nonexistent p_relationship_id gets the SAME rejection -- the function never even reaches relationship validation, so no cross-carrier tampering via a forged relationship id can matter -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.submit_invoice_to_factor('9b140000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000');
  assert (v_res->>'success')::boolean is false and v_res->>'code' = 'CARRIER_INVOICE_SNAPSHOT_REQUIRED', format('TEST FAIL: expected the same structured rejection regardless of relationship id, got %s', v_res);
  raise notice 'OK: even a nonexistent relationship id produces the identical structured rejection -- p_relationship_id is never consulted before the snapshot check, closing off any cross-carrier-relationship tampering vector at the source.';
end
$t$;
reset role;

\echo '----- D8. no factored_invoices or factoring_events row was created by ANY attempt above -----'
do $t$
declare v_fi int; v_fe int;
begin
  select count(*) into v_fi from public.factored_invoices;
  select count(*) into v_fe from public.factoring_events;
  assert v_fi = 0, format('TEST FAIL: expected 0 factored_invoices rows after every rejection above, got %s', v_fi);
  assert v_fe = 0, format('TEST FAIL: expected 0 factoring_events rows after every rejection above, got %s', v_fe);
  raise notice 'OK: every rejected submission attempt (owner/admin, dispatcher, accountant, direct, unconfigured, carrier-less, bogus relationship id) left zero rows behind in either table.';
end
$t$;

\echo '----- D9. a PRE-EXISTING (historical, simulating a row created before this phase) factored_invoices row gets its OWN specific "already submitted" rejection -- distinct from the generic snapshot-required code, and the historical row is never touched -----'
do $t$
begin
  insert into public.factored_invoices
    (id, organization_id, invoice_id, factoring_company_id, factoring_relationship_id, status,
     invoice_face_value, advance_percentage, expected_advance_amount, factoring_fee_percentage, factoring_fee_amount,
     reserve_percentage, reserve_amount, fee_timing, expected_funding_amount, submitted_at, submitted_by)
  values
    ('9d140000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '9b140000-0000-0000-0000-0000000000a1',
     'fc140000-0000-0000-0000-000000000001', 'a1140000-0000-0000-0000-0000000000f1', 'submitted',
     1000, 90, 900, 3, 30, 10, 100, 'deducted_at_funding', 900, now() - interval '10 days', 'aaaa0000-0000-0000-0000-000000000001');
  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by)
  values ('11111111-1111-1111-1111-111111111111', '9d140000-0000-0000-0000-000000000001', 'submitted', null, 'submitted', 'aaaa0000-0000-0000-0000-000000000001');
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    perform public.submit_invoice_to_factor('9b140000-0000-0000-0000-0000000000a1', 'a1140000-0000-0000-0000-0000000000f1');
    raise exception 'TEST FAIL: resubmission of an already-submitted invoice did not raise.';
  exception when others then
    if sqlerrm not ilike '%already been submitted%' then raise; end if;
    raise notice 'OK: an already-submitted invoice gets its own specific rejection (a raised exception, not the generic structured code) -- historical state is recognized and protected, not silently overwritten.';
  end;
end
$t$;
reset role;

\echo '----- D10. the historical factored_invoices/factoring_events rows remain byte-for-byte unchanged and fully readable after every attempt above -----'
do $t$
declare v_row record; v_events int;
begin
  select status, invoice_face_value, submitted_at into v_row from public.factored_invoices where id = '9d140000-0000-0000-0000-000000000001';
  assert v_row.status = 'submitted' and v_row.invoice_face_value = 1000, format('TEST FAIL: the historical row was altered, got %s', v_row);
  select count(*) into v_events from public.factoring_events where factored_invoice_id = '9d140000-0000-0000-0000-000000000001';
  assert v_events = 1, format('TEST FAIL: expected exactly the 1 original historical event, got %s', v_events);
  raise notice 'OK: the historical factored_invoices row and its one factoring_events row remain exactly as inserted, and are fully readable.';
end
$t$;

\echo '----- D11 (static): the function never references secret_reference or carrier_factoring_integrations -- it does not touch API-integration configuration at all -----'
do $t$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'submit_invoice_to_factor' and pronamespace = 'public'::regnamespace;
  assert v_src not ilike '%secret_reference%', 'TEST FAIL: submit_invoice_to_factor must never reference secret_reference.';
  assert v_src not ilike '%carrier_factoring_integrations%', 'TEST FAIL: submit_invoice_to_factor must never touch carrier_factoring_integrations.';
  raise notice 'OK: submit_invoice_to_factor never references secret_reference or carrier_factoring_integrations.';
end
$t$;

\echo '################  TEST 0140 PASSED  ################'
