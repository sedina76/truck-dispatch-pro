-- ============================================================================
-- TEST_0139_factoring_policy_safety_integrations_and_privilege_remediation.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.1.1 verification: set_carrier_factoring_policy() (role, reason,
-- optimistic concurrency, readiness gate, factored->direct block, audit,
-- idempotency), carrier_factoring_integrations (per-carrier config,
-- cross-carrier/cross-org rejection, secret never returned), the corrected
-- classifier (api_integration_missing/not_ready, carrier-party explicit
-- exception), approve_factoring_relationship_noa()'s carrier-ownership/
-- type/verification checks and snapshotting, the 0133 provenance privilege
-- fix (and the rest of the privilege matrix), and the NOT VALID cutover
-- constraint on factoring_relationships.carrier_id.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0139  ################'

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

\echo '===== a genuinely PRE-EXISTING (pre-0139) null-carrier legacy relationship, inserted BEFORE the NOT VALID constraint exists -- proves grandfathering, not just rejection of a fresh insert ====='
do $t$
begin
  insert into public.factoring_companies (id, organization_id, name, is_active)
  values ('fc000000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'Shared Factor Co', true);

  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, is_default, is_active)
  values
    ('9a000000-0000-0000-0000-00000000fc01', '11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-00000000000c', null,
     80, 5, 15, 'deducted_from_reserve', 'recourse', false, true);
end
$t$;

\i migrations/0139_factoring_policy_safety_integrations_and_privilege_remediation.sql

\echo '===== fixtures: one complete relationship for A1 (not yet default) -- factoring_companies row already inserted above ====='
reset role;
do $t$
begin
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions,
     noa_template_text, noa_reference, noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method)
  values
    ('a1000000-0000-0000-0000-0000000000f1', '11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-00000000000c', 'a1a1a1a1-0000-0000-0000-000000000001',
     90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Shared Factor Co, acct ending 1111',
     'NOA language for A1.', 'v1', current_date - 30, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue');

  update public.factoring_relationships set is_default = true where id = 'a1000000-0000-0000-0000-0000000000f1';
end
$t$;

-- ---------------------------------------------------------------------------
-- P1. set_carrier_factoring_policy(): role, reason, optimistic concurrency
-- ---------------------------------------------------------------------------
\echo '----- P1. dispatcher/accountant cannot change policy -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    perform public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'dispatcher trying', now(), null);
    raise exception 'TEST FAIL: dispatcher was able to change factoring policy.';
  exception when others then
    if sqlerrm not like '%owner or admin%' then raise; end if;
    raise notice 'OK: dispatcher blocked from changing factoring policy (%).', sqlstate;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    perform public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'accountant trying', now(), null);
    raise exception 'TEST FAIL: accountant was able to change factoring policy.';
  exception when others then
    if sqlerrm not like '%owner or admin%' then raise; end if;
    raise notice 'OK: accountant blocked from changing factoring policy (%).', sqlstate;
  end;
end
$t$;
reset role;

\echo '----- P2. owner: reason required -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    perform public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', '', now(), null);
    raise exception 'TEST FAIL: empty reason was accepted.';
  exception when others then
    if sqlerrm not like '%reason is required%' then raise; end if;
    raise notice 'OK: empty reason rejected.';
  end;
end
$t$;

\echo '----- P3. owner: missing expected_updated_at returns a structured (non-exception) result -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'go direct', null, null);
  assert v_res->>'expected_version_required' = 'true', format('TEST FAIL: expected expected_version_required, got %s', v_res);
  raise notice 'OK: missing expected_updated_at returns a structured error, not an exception.';
end
$t$;

\echo '----- P4. owner: stale expected_updated_at is rejected structurally -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'go direct', '2000-01-01'::timestamptz, null);
  assert v_res->>'stale_record' = 'true', format('TEST FAIL: expected stale_record, got %s', v_res);
  raise notice 'OK: stale expected_updated_at rejected with a structured result.';
end
$t$;

\echo '----- P5. owner: explicitly sets direct (correct version) -----'
do $t$
declare v_updated_at timestamptz; v_res jsonb;
begin
  select updated_at into v_updated_at from public.carriers where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  v_res := public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'owner reviewed: pay this carrier directly', v_updated_at, 'idem-key-1');
  assert v_res->>'success' = 'true', format('TEST FAIL: %s', v_res);
  assert (select factoring_mode::text from public.carriers where id = 'a1a1a1a1-0000-0000-0000-000000000001') = 'direct', 'TEST FAIL: factoring_mode not set to direct.';
  assert exists (select 1 from public.activity_logs where entity_id = 'a1a1a1a1-0000-0000-0000-000000000001' and action = 'factoring_policy_changed'), 'TEST FAIL: no audit event written.';
  raise notice 'OK: owner explicitly set direct, audit event written.';
end
$t$;

\echo '----- P6. idempotency: replaying the same key returns the cached result, no error -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'owner reviewed: pay this carrier directly', '2000-01-01'::timestamptz, 'idem-key-1');
  assert v_res->>'idempotent_replay' = 'true', format('TEST FAIL: expected idempotent_replay, got %s', v_res);
  raise notice 'OK: replaying an idempotency key returns the cached result even with a stale expected_updated_at.';
end
$t$;

\echo '----- P7. owner: cannot set factored while not ready (A2 has no configuration at all) -----'
do $t$
declare v_updated_at timestamptz; v_res jsonb;
begin
  select updated_at into v_updated_at from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  v_res := public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002', 'factored', 'trying factored with nothing configured', v_updated_at, null);
  assert v_res->>'not_ready' = 'true', format('TEST FAIL: expected not_ready, got %s', v_res);
  assert (select factoring_mode::text from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002') = 'unconfigured', 'TEST FAIL: factoring_mode changed despite not_ready.';
  raise notice 'OK: cannot set factored until the classifier would call this carrier ready.';
end
$t$;

\echo '----- P8. owner: sets factored only once ready (A2 gets a complete default relationship) -----'
reset role;
do $t$
begin
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions,
     noa_template_text, noa_reference, noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default)
  values
    ('a2000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-00000000000c', 'a2a2a2a2-0000-0000-0000-000000000002',
     80, 5, 15, 'deducted_from_reserve', 'recourse', 'Wire to Shared Factor Co, acct ending 2222',
     'NOA language for A2.', 'v1', current_date - 30, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true);
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_updated_at timestamptz; v_res jsonb;
begin
  select updated_at into v_updated_at from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  v_res := public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002', 'factored', 'A2 is ready -- complete default relationship exists', v_updated_at, null);
  assert v_res->>'success' = 'true', format('TEST FAIL: %s', v_res);
  assert (select factoring_mode::text from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002') = 'factored', 'TEST FAIL: factoring_mode not set to factored.';
  raise notice 'OK: owner set factored once the classifier would call it ready.';
end
$t$;

\echo '----- P9. authenticated cannot UPDATE carriers.factoring_mode directly -----'
do $t$
begin
  begin
    update public.carriers set factoring_mode = 'direct' where id = 'a2a2a2a2-0000-0000-0000-000000000002';
    raise exception 'TEST FAIL: direct UPDATE of factoring_mode succeeded.';
  exception when insufficient_privilege then
    raise notice 'OK: direct UPDATE of carriers.factoring_mode rejected (insufficient_privilege).';
  end;
end
$t$;
-- operational carriers columns remain directly editable (unaffected by the lockdown)
do $t$
begin
  update public.carriers set notes = 'still editable' where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  raise notice 'OK: carriers.notes (an unrelated operational column) remains directly editable.';
end
$t$;

-- Phase 3B.1.2 (Section B) regression: mirrors the EXACT column set
-- src/app/(app)/carriers/actions.ts's carrierValues()/updateCarrier() ->
-- updateRecord("carriers", ...) writes as the `authenticated` role (the
-- app's real Supabase client uses the anon key + user session, never
-- service_role, for this path) -- proves the one legitimate application
-- mutation against carriers this migration's column-privilege lockdown
-- could plausibly have broken still succeeds in full, in one statement,
-- exactly as the app issues it.
do $t$
begin
  update public.carriers set
    legal_name = 'Carrier A2 LLC (updated)',
    dba_name = 'A2 DBA',
    mc_number = 'MC-123456',
    dot_number = 'DOT-654321',
    contact_name = 'Jane Dispatcher',
    phone = '555-0100',
    email = 'a2-updated@example.com',
    city = 'Austin',
    state = 'TX'
  where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  raise notice 'OK: the application''s carrierValues()/updateCarrier() write shape (legal_name/dba_name/mc_number/dot_number/contact_name/phone/email/city/state) succeeds in full for authenticated after 0139''s column-privilege lockdown.';
end
$t$;
reset role;

\echo '----- P10. factored -> direct is blocked while an open factored invoice exists -----'
do $t$
begin
  insert into public.invoices (id, organization_id, invoice_number)
  values ('9a000000-0000-0000-0000-00000000fa01', '11111111-1111-1111-1111-111111111111', 'INV-FA-1');
  insert into public.factored_invoices
    (id, organization_id, invoice_id, factoring_company_id, factoring_relationship_id, status,
     invoice_face_value, advance_percentage, expected_advance_amount, factoring_fee_percentage, factoring_fee_amount,
     reserve_percentage, reserve_amount, fee_timing, expected_funding_amount)
  values
    ('9a000000-0000-0000-0000-00000000fb01', '11111111-1111-1111-1111-111111111111', '9a000000-0000-0000-0000-00000000fa01',
     'fc000000-0000-0000-0000-00000000000c', 'a2000000-0000-0000-0000-0000000000f2', 'approved',
     1000, 80, 800, 5, 50, 15, 150, 'deducted_from_reserve', 800);
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_updated_at timestamptz; v_res jsonb;
begin
  select updated_at into v_updated_at from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  v_res := public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002', 'direct', 'trying to flip while a factored invoice is open', v_updated_at, null);
  assert v_res->>'blocked' = 'true' and v_res->>'reason' = 'open_factored_activity', format('TEST FAIL: expected blocked/open_factored_activity, got %s', v_res);
  assert (select factoring_mode::text from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002') = 'factored', 'TEST FAIL: factoring_mode changed despite an open factored invoice.';
  raise notice 'OK: factored -> direct blocked while an open factored invoice exists.';
end
$t$;
reset role;
-- close it out, then confirm the transition is allowed
do $t$ begin update public.factored_invoices set status = 'closed' where id = '9a000000-0000-0000-0000-00000000fb01'; end $t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_updated_at timestamptz; v_res jsonb;
begin
  select updated_at into v_updated_at from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  v_res := public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002', 'direct', 'now closed, allow the switch', v_updated_at, null);
  assert v_res->>'success' = 'true', format('TEST FAIL: %s', v_res);
  raise notice 'OK: factored -> direct allowed once the factored invoice is closed.';
end
$t$;
reset role;
-- revert A2 back to factored for the remaining tests below
do $t$ begin update public.carriers set factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002'; end $t$;

-- ---------------------------------------------------------------------------
-- P11. carrier_factoring_integrations: per-carrier config, cross-carrier/
-- cross-org rejection, secret never exposed by the status reader.
-- ---------------------------------------------------------------------------
\echo '----- P11. Carrier A1 and Carrier A2 each get their own integration on the SAME factor, different credentials -----'
do $t$
begin
  insert into public.carrier_factoring_integrations
    (id, organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method,
     secret_reference, external_account_identifier, configuration_status, is_active, approved_by, approved_at, created_by)
  values
    ('cf100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002',
     'a2000000-0000-0000-0000-0000000000f2', 'fc000000-0000-0000-0000-00000000000c', 'api',
     'vault://factoring/a2-cred', 'ACCT-A2-001', 'active', true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'aaaa0000-0000-0000-0000-000000000001');
end
$t$;

\echo '----- P12. cross-carrier integration rejected (relationship belongs to A2, not A1) -----'
do $t$
begin
  begin
    insert into public.carrier_factoring_integrations
      (organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, secret_reference)
    values
      ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001',
       'a2000000-0000-0000-0000-0000000000f2', 'fc000000-0000-0000-0000-00000000000c', 'api', 'vault://x');
    raise exception 'TEST FAIL: cross-carrier integration was accepted.';
  exception when others then
    if sqlerrm not like '%SAME carrier%' then raise; end if;
    raise notice 'OK: cross-carrier integration rejected (Carrier A1 cannot use Carrier A2''s relationship).';
  end;
end
$t$;

\echo '----- P13. cross-organization integration rejected (Org B carrier/relationship do not exist in Org A) -----'
do $t$
begin
  begin
    insert into public.carrier_factoring_integrations
      (organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, secret_reference)
    values
      ('11111111-1111-1111-1111-111111111111', 'b1b1b1b1-0000-0000-0000-000000000001',
       'a2000000-0000-0000-0000-0000000000f2', 'fc000000-0000-0000-0000-00000000000c', 'api', 'vault://x');
    raise exception 'TEST FAIL: cross-organization carrier was accepted.';
  exception when others then
    if sqlerrm not like '%same organization%' then raise; end if;
    raise notice 'OK: cross-organization carrier/relationship rejected.';
  end;
end
$t$;

\echo '----- P14. get_carrier_factoring_integration_status(): dispatcher/accountant see status, never secret_reference -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.get_carrier_factoring_integration_status('a2a2a2a2-0000-0000-0000-000000000002');
  assert v_res->>'success' = 'true', format('TEST FAIL: %s', v_res);
  assert v_res->'integrations'->0->>'configuration_status' = 'active', format('TEST FAIL: %s', v_res);
  assert not (v_res::text like '%vault://%'), format('TEST FAIL: secret_reference leaked to dispatcher: %s', v_res);
  raise notice 'OK: dispatcher sees non-secret integration status, no secret_reference in the payload.';
end
$t$;
reset role;

\echo '----- P15. driver/viewer get no access via the status function -----'
select set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.get_carrier_factoring_integration_status('a2a2a2a2-0000-0000-0000-000000000002');
  assert v_res->>'success' = 'false', format('TEST FAIL: driver was granted access: %s', v_res);
  raise notice 'OK: driver denied by get_carrier_factoring_integration_status().';
end
$t$;
reset role;

\echo '----- P16. accountant/dispatcher cannot SELECT the raw carrier_factoring_integrations table (RLS) -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_n int;
begin
  select count(*) into v_n from public.carrier_factoring_integrations where carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002';
  assert v_n = 0, format('TEST FAIL: accountant could read %s row(s) directly from carrier_factoring_integrations.', v_n);
  raise notice 'OK: accountant cannot read the raw carrier_factoring_integrations table directly (RLS restricts to owner/admin).';
end
$t$;
reset role;

-- ---------------------------------------------------------------------------
-- P17-P19. classifier: api_integration_missing / not_ready / ready
-- ---------------------------------------------------------------------------
\echo '----- P17. api_integration_missing: A1 factored + api method (org-level integration_settings enabled) but no carrier_factoring_integrations row -----'
reset role;
do $t$
begin
  -- The org-level "we have an API connection to this factor" registration
  -- (0008/0136) -- carrier_factoring_integrations (0139) is the layer ON
  -- TOP of this that carries the PER-CARRIER account/credentials within
  -- it, so Carrier D could share this same integration_settings row with
  -- different carrier_factoring_integrations credentials of its own.
  insert into public.integration_settings (id, organization_id, provider, is_enabled)
  values ('15000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'factoring_api', true);
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb; v_updated_at timestamptz;
begin
  update public.factoring_relationships set submission_method = 'api', submission_destination_email = null, submission_integration_id = '15000000-0000-0000-0000-000000000001' where id = 'a1000000-0000-0000-0000-0000000000f1';
  select updated_at into v_updated_at from public.carriers where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  perform public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'factored', 'A1 also goes factored, api method, no integration yet', v_updated_at, null);
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'api_integration_missing', format('TEST FAIL: expected api_integration_missing, got %s', v_res);
  raise notice 'OK: api submission method with no carrier_factoring_integrations row classifies as api_integration_missing.';
end
$t$;

\echo '----- P18. api_integration_not_ready: integration exists but is draft/not active -----'
do $t$
begin
  insert into public.carrier_factoring_integrations
    (organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method,
     secret_reference, configuration_status, is_active)
  values
    ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001',
     'a1000000-0000-0000-0000-0000000000f1', 'fc000000-0000-0000-0000-00000000000c', 'api',
     'vault://factoring/a1-cred', 'draft', false);
end
$t$;
do $t$
declare v_res jsonb;
begin
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'api_integration_not_ready', format('TEST FAIL: expected api_integration_not_ready, got %s', v_res);
  raise notice 'OK: an inactive/unapproved integration classifies as api_integration_not_ready.';
end
$t$;

\echo '----- P19. ready: once the integration is approved and active -----'
do $t$
begin
  update public.carrier_factoring_integrations
  set configuration_status = 'active', is_active = true, approved_by = 'aaaa0000-0000-0000-0000-000000000001', approved_at = now()
  where factoring_relationship_id = 'a1000000-0000-0000-0000-0000000000f1';
end
$t$;
do $t$
declare v_res jsonb;
begin
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'ready', format('TEST FAIL: expected ready, got %s', v_res);
  raise notice 'OK: classifies as ready once the api integration is approved and active.';
end
$t$;
reset role;

-- ---------------------------------------------------------------------------
-- P20-P22. carrier-party explicit direct-billing exception
-- ---------------------------------------------------------------------------
\echo '----- P20. ineligible broker relationship blocks (not an automatic direct-billing guess) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  insert into public.carrier_brokers (organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible)
  values ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', 'billing@a1.example', 30, false);
end
$t$;
do $t$
declare v_res jsonb;
begin
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'carrier_party_ineligible', format('TEST FAIL: expected carrier_party_ineligible, got %s', v_res);
  raise notice 'OK: an ineligible party with no approved exception blocks -- never an automatic direct-billing guess.';
end
$t$;

\echo '----- P21. dispatcher cannot approve the direct-billing exception -----'
reset role;
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    update public.carrier_brokers set factoring_ineligible_direct_billing_approved = true, factoring_ineligible_direct_billing_approved_by = 'dddd0000-0000-0000-0000-000000000001', factoring_ineligible_direct_billing_approved_at = now()
    where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' and broker_id = 'a0b00000-0000-0000-0000-000000000001';
    raise exception 'TEST FAIL: dispatcher approved the direct-billing exception.';
  exception when others then
    if sqlerrm not like '%owner or admin%' then raise; end if;
    raise notice 'OK: dispatcher blocked from approving the direct-billing exception.';
  end;
end
$t$;
reset role;

\echo '----- P22. owner approves the exception -> carrier_party_direct_billing_exception -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  update public.carrier_brokers set factoring_ineligible_direct_billing_approved = true, factoring_ineligible_direct_billing_approved_by = 'aaaa0000-0000-0000-0000-000000000001', factoring_ineligible_direct_billing_approved_at = now()
  where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' and broker_id = 'a0b00000-0000-0000-0000-000000000001';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'carrier_party_direct_billing_exception', format('TEST FAIL: expected carrier_party_direct_billing_exception, got %s', v_res);
  raise notice 'OK: owner-approved exception reports carrier_party_direct_billing_exception, distinct from a blocking ineligible state.';
end
$t$;
reset role;

-- ---------------------------------------------------------------------------
-- P23-P25. approve_factoring_relationship_noa(): carrier ownership, document
-- type, verification -- Carrier A cannot approve Carrier B's document.
-- ---------------------------------------------------------------------------
\echo '----- P23. NOA document must belong to the SAME carrier (A2''s doc cannot approve A1''s relationship) -----'
reset role;
do $t$
begin
  insert into public.documents (id, organization_id, entity_type, entity_id, document_type, file_name, file_path, is_verified)
  values ('d0c00000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'carrier', 'a2a2a2a2-0000-0000-0000-000000000002', 'notice_of_assignment', 'a2-noa.pdf', '/docs/a2-noa.pdf', true);
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    perform public.approve_factoring_relationship_noa('a1000000-0000-0000-0000-0000000000f1', 'v2', current_date, null, 'd0c00000-0000-0000-0000-00000000000a');
    raise exception 'TEST FAIL: Carrier A1''s relationship was approved using Carrier A2''s document.';
  exception when others then
    if sqlerrm not like '%own carrier%' then raise; end if;
    raise notice 'OK: cross-carrier NOA document rejected -- Carrier A1 cannot approve using Carrier A2''s document.';
  end;
end
$t$;
reset role;

\echo '----- P24. unverified document rejected -----'
do $t$
begin
  insert into public.documents (id, organization_id, entity_type, entity_id, document_type, file_name, file_path, is_verified)
  values ('d0c00000-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111', 'carrier', 'a1a1a1a1-0000-0000-0000-000000000001', 'notice_of_assignment', 'a1-noa-unverified.pdf', '/docs/a1-noa-unverified.pdf', false);
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    perform public.approve_factoring_relationship_noa('a1000000-0000-0000-0000-0000000000f1', 'v2', current_date, null, 'd0c00000-0000-0000-0000-00000000000b');
    raise exception 'TEST FAIL: an unverified document was accepted as an approved NOA.';
  exception when others then
    if sqlerrm not like '%verified%' then raise; end if;
    raise notice 'OK: unverified document rejected.';
  end;
end
$t$;
reset role;

\echo '----- P25. verified, same-carrier document is accepted and snapshotted -----'
do $t$ begin update public.documents set is_verified = true where id = 'd0c00000-0000-0000-0000-00000000000b'; end $t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb; v_snap_name text;
begin
  v_res := public.approve_factoring_relationship_noa('a1000000-0000-0000-0000-0000000000f1', 'v2', current_date, null, 'd0c00000-0000-0000-0000-00000000000b');
  assert v_res->>'success' = 'true', format('TEST FAIL: %s', v_res);
  select noa_document_snapshot_file_name into v_snap_name from public.factoring_relationships where id = 'a1000000-0000-0000-0000-0000000000f1';
  assert v_snap_name = 'a1-noa-unverified.pdf', format('TEST FAIL: snapshot file name not recorded, got %s', v_snap_name);
  raise notice 'OK: verified same-carrier NOA document approved, file identity snapshotted onto the relationship.';
end
$t$;
reset role;
-- Now edit the underlying document -- the snapshot must NOT change.
do $t$ begin update public.documents set file_name = 'renamed-after-approval.pdf' where id = 'd0c00000-0000-0000-0000-00000000000b'; end $t$;
do $t$
declare v_snap_name text;
begin
  select noa_document_snapshot_file_name into v_snap_name from public.factoring_relationships where id = 'a1000000-0000-0000-0000-0000000000f1';
  assert v_snap_name = 'a1-noa-unverified.pdf', format('TEST FAIL: snapshot changed after the underlying document was edited, got %s', v_snap_name);
  raise notice 'OK: editing the underlying document after approval does not alter the frozen snapshot.';
end
$t$;

-- ---------------------------------------------------------------------------
-- P26-P27. cutover safety: NOT VALID constraint on factoring_relationships
-- ---------------------------------------------------------------------------
\echo '----- P26. a legacy NULL-carrier relationship (grandfathered pre-0139, inserted before the migration chain reached 0139) is IMMUTABLE for any future write -----'
do $t$
begin
  assert (select carrier_id from public.factoring_relationships where id = '9a000000-0000-0000-0000-00000000fc01') is null,
    'TEST SETUP FAIL: the pre-0139 legacy fixture row is missing or already has a carrier_id.';
end
$t$;
do $t$
begin
  begin
    update public.factoring_relationships set submission_notes = 'trying to touch an unresolved legacy row' where id = '9a000000-0000-0000-0000-00000000fc01';
    raise exception 'TEST FAIL: a write to a null-carrier legacy relationship succeeded.';
  exception when check_violation then
    raise notice 'OK: any future write to a null-carrier legacy relationship is rejected (check_violation) -- immutable until resolved.';
  end;
end
$t$;

\echo '----- P27. resolving carrier_id in the SAME write is allowed (the sanctioned resolution path) -----'
do $t$
begin
  update public.factoring_relationships set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' where id = '9a000000-0000-0000-0000-00000000fc01';
  raise notice 'OK: resolving carrier_id in the same write is permitted -- this is how a legacy row is deliberately corrected.';
end
$t$;
-- (this relationship is now resolved but is_default=false / incomplete -- it never became a carrier's default without going through the classifier-checked RPC path, matching item 8's own posture)

\echo '----- P27b (Phase 3B.1.3, Section B): a BRAND NEW factoring_relationships row with carrier_id explicitly NULL is rejected outright -- no null-carrier relationship can be created after the cutover, confirming migration 0140 is unnecessary for this gap -----'
do $t$
begin
  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type)
    values
      ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-00000000000c', null, 90, 3, 10, 'deducted_at_funding', 'non_recourse');
    raise exception 'TEST FAIL: a fresh null-carrier factoring_relationships row was created after the cutover.';
  exception when check_violation then
    raise notice 'OK: a brand new null-carrier relationship is rejected by factoring_relationships_new_writes_need_carrier -- the database contract alone already closes this gap, application-layer or not.';
  end;
end
$t$;

-- ---------------------------------------------------------------------------
-- P28-P31. privilege matrix: 0133 provenance + the rest of the fixed gaps
-- ---------------------------------------------------------------------------
\echo '----- P28. authenticated cannot write carrier_backfill_0133_provenance -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    insert into public.carrier_backfill_0133_provenance (load_id, organization_id, carrier_id, carrier_resolution)
    values ('10000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved');
    raise exception 'TEST FAIL: authenticated inserted into carrier_backfill_0133_provenance.';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated cannot INSERT into carrier_backfill_0133_provenance.';
  end;
end
$t$;
reset role;

\echo '----- P29. authenticated cannot write unresolved_carrier_records (insert/delete), UPDATE still permitted (owner/admin resolution path) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason)
    values ('11111111-1111-1111-1111-111111111111', 'factoring_relationship', gen_random_uuid(), 'forged directly');
    raise exception 'TEST FAIL: authenticated inserted into unresolved_carrier_records directly.';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated cannot INSERT into unresolved_carrier_records directly.';
  end;
end
$t$;
reset role;

\echo '----- P30. authenticated cannot write financial_idempotency_keys -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    insert into public.financial_idempotency_keys (organization_id, scope, idempotency_key, result) values ('11111111-1111-1111-1111-111111111111', 'factoring_submission', 'y', '{}'::jsonb);
    raise exception 'TEST FAIL: authenticated inserted into financial_idempotency_keys.';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated cannot INSERT into financial_idempotency_keys.';
  end;
end
$t$;
reset role;

\echo '----- P31. catalog check: every table this migration touched has NO stray authenticated write grant beyond what is documented -----'
do $t$
declare v_bad text;
begin
  select string_agg(table_name || ':' || privilege_type, ', ') into v_bad
  from information_schema.role_table_grants
  where grantee = 'authenticated'
    and table_schema = 'public'
    and (
      (table_name = 'unresolved_carrier_records' and privilege_type in ('INSERT','DELETE'))
      or (table_name = 'financial_idempotency_keys' and privilege_type in ('INSERT','UPDATE','DELETE'))
      or (table_name = 'carrier_backfill_0133_provenance' and privilege_type in ('INSERT','UPDATE','DELETE'))
      or (table_name in ('carrier_remittance_profiles','carrier_brokers','carrier_customers') and privilege_type = 'DELETE')
      or (table_name = 'factoring_policy_idempotency' and privilege_type in ('INSERT','UPDATE','DELETE'))
    );
  assert v_bad is null, format('TEST FAIL: unexpected authenticated grant(s) remain: %s', v_bad);
  raise notice 'OK: catalog confirms none of the fixed privilege-matrix gaps remain granted to authenticated.';
end
$t$;

-- P32 (Phase 3B.1.3's own version of this test) asserted that a dispatcher
-- COULD create a carrier-scoped factoring_relationship via their own
-- session -- an accurate description of 0139's own behavior at the time
-- (0139 never touched factoring_companies/factoring_relationships base
-- CRUD authorization at all), but Phase 3B.1.4 explicitly identified that
-- exact permissiveness as a gap to CLOSE, not a behavior to keep proving
-- correct going forward. Removed here (rather than left describing now-
-- undesired behavior) -- its replacement (proving dispatcher creation is
-- REJECTED, owner/admin creation succeeds, and dispatcher retains read-
-- only visibility) lives in TEST_0140, alongside the migration that
-- actually changes this.

\echo '################  TEST 0139 PASSED  ################'
