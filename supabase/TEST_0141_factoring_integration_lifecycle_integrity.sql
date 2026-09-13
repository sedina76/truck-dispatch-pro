-- ============================================================================
-- TEST_0141_factoring_integration_lifecycle_integrity.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.2 verification: the six-state integration lifecycle, the eight
-- new owner/admin-only RPCs, the row-level organization-scoped dependency
-- guard (Phase 3B.2.1: narrowed from statement-level), the readiness
-- classifier extension, and the preflight refusal path.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0141  ################'

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

\echo '===== fixtures (pre-0141): one factor, one carrier, one COMPLETE default relationship ====='
-- (pre-0141, 0136's own constraint still requires an org-level
-- integration_settings row for any submission_method='api' relationship --
-- 0141 removes that requirement; this legacy row satisfies the OLD rule
-- for these fixtures created before 0141 has applied.)
reset role;
do $t$
declare v_legacy_integration_id uuid;
begin
  insert into public.integration_settings (organization_id, provider, is_enabled) values
    ('11111111-1111-1111-1111-111111111111', 'factoring_api', true)
  returning id into v_legacy_integration_id;

  insert into public.factoring_companies (id, organization_id, name, is_active) values
    ('fc410000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor 141', true);
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions,
     noa_template_text, noa_reference, noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, submission_integration_id, is_default, is_active)
  values
    ('fe410000-0000-0000-0000-0000000000a1', '11111111-1111-1111-1111-111111111111', 'fc410000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
     90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire A1', 'NOA A1', 'v1', current_date - 10, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'api', v_legacy_integration_id, true, true),
    ('fe410000-0000-0000-0000-0000000000a2', '11111111-1111-1111-1111-111111111111', 'fc410000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
     85, 4, 12, 'deducted_at_funding', 'non_recourse', 'Wire A1 ALT', 'NOA A1 ALT', 'v1', current_date - 10, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'api', v_legacy_integration_id, false, true);
  update public.carriers set factoring_mode = 'factored' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
end
$t$;

\echo '===== R0 (preflight refusal): seed a row 0141 must refuse, confirm apply rolls back, then remove it and apply for real ====='
do $t$
begin
  insert into public.carrier_factoring_integrations
    (id, organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, provider,
     secret_reference, external_account_identifier, configuration_status, is_active, created_by, approved_by, approved_at)
  values
    ('9f410000-0000-0000-0000-000000000bad', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001',
     'fe410000-0000-0000-0000-0000000000a2', 'fc410000-0000-0000-0000-000000000001', 'api', 'factoring_api',
     'legacy-raw-secret-shaped-value', 'BAD-ACCT', 'active', true, 'aaaa0000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001', now());
end
$t$;
\echo '----- attempting to apply 0141 over an existing active-but-nondefault integration row -- must refuse -----'
\set ON_ERROR_STOP off
\i migrations/0141_factoring_integration_lifecycle_integrity.sql
\set ON_ERROR_STOP on
do $t$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_factoring_integrations' and column_name='configuration_status' and data_type<>'USER-DEFINED') then
    raise exception 'TEST FAIL: 0141 appears to have applied despite an unsafe existing row -- it should have refused and rolled back.';
  end if;
  if not exists (select 1 from public.carrier_factoring_integrations where id = '9f410000-0000-0000-0000-000000000bad') then
    raise exception 'TEST FAIL: the seeded bad row is gone -- 0141''s refusal must never delete/repair existing rows.';
  end if;
  raise notice 'OK: 0141 refused to apply over an unsafe existing row (active-but-nondefault integration), left it completely untouched, and made no partial schema change.';
end
$t$;

\echo '----- removing the seeded bad row and applying 0141 for real -----'
delete from public.carrier_factoring_integrations where id = '9f410000-0000-0000-0000-000000000bad';
\i migrations/0141_factoring_integration_lifecycle_integrity.sql

-- ---------------------------------------------------------------------------
-- Section A: authorization matrix
-- ---------------------------------------------------------------------------
\echo '----- A1. dispatcher cannot call any of the eight new RPCs -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a1', 'vault://11111111-1111-1111-1111-111111111111', 'ACCT-D', 'factoring_api', null,
    'dispatcher attempt', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a1'), 'idem-a1-configure');
  assert (v_res->>'code') = 'FORBIDDEN', format('TEST FAIL: dispatcher configure should be FORBIDDEN, got %s', v_res);
  v_res := public.deactivate_factoring_relationship('fe410000-0000-0000-0000-0000000000a1', 'dispatcher attempt', now(), 'idem-a1-deact', false);
  assert (v_res->>'code') = 'FORBIDDEN', format('TEST FAIL: dispatcher deactivate_relationship should be FORBIDDEN, got %s', v_res);
  raise notice 'OK: dispatcher cannot configure an integration or deactivate a relationship.';
end
$t$;
reset role;

\echo '----- A2. accountant cannot call any of the eight new RPCs either -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a1', 'vault://11111111-1111-1111-1111-111111111111', 'ACCT-C', 'factoring_api', null,
    'accountant attempt', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a1'), 'idem-a2-configure');
  assert (v_res->>'code') = 'FORBIDDEN', format('TEST FAIL: accountant configure should be FORBIDDEN, got %s', v_res);
  raise notice 'OK: accountant cannot configure a factoring integration (matrix: owner/admin only).';
end
$t$;
reset role;

-- ---------------------------------------------------------------------------
-- Section B: full lifecycle path + state machine
-- ---------------------------------------------------------------------------
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '----- B1. configure creates a draft row; is_active=false -----'
do $t$
declare v_res jsonb; v_id uuid;
begin
  v_res := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a1', 'vault://11111111-1111-1111-1111-111111111111', 'ACCT-1', 'factoring_api', null,
    'Initial setup', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a1'), 'idem-b-configure');
  assert (v_res->>'success')::boolean, format('TEST FAIL: configure did not succeed, got %s', v_res);
  assert v_res->>'configuration_status' = 'draft', format('TEST FAIL: expected draft, got %s', v_res);
  v_id := (v_res->>'integration_id')::uuid;
  perform set_config('test.b1_integration_id', v_id::text, false);
  assert exists (select 1 from public.carrier_factoring_integrations where id = v_id and configuration_status='draft' and not is_active),
    'TEST FAIL: new row is not draft/is_active=false.';
  raise notice 'OK: configure_carrier_factoring_integration creates a draft, inactive row.';
end
$t$;

\echo '----- B2. an invalid transition (draft -> ready, skipping verification) is rejected at the trigger level -----'
do $t$
declare v_id uuid := current_setting('test.b1_integration_id')::uuid;
begin
  begin
    update public.carrier_factoring_integrations set configuration_status = 'ready', is_active = true where id = v_id;
    raise exception 'TEST FAIL: draft -> ready direct UPDATE should have been rejected by guard_factoring_integration_lifecycle_transition.';
  exception when others then
    if sqlerrm not ilike '%Invalid factoring integration lifecycle transition%' and sqlerrm not ilike '%permission denied%' then raise; end if;
    raise notice 'OK: an invalid direct transition is rejected (%).', sqlerrm;
  end;
end
$t$;

\echo '----- B3. verify -> pending_verification -----'
do $t$
declare v_id uuid := current_setting('test.b1_integration_id')::uuid; v_res jsonb;
begin
  v_res := public.verify_carrier_factoring_integration(v_id, 'Manual review begun', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-b-verify');
  assert (v_res->>'success')::boolean and v_res->>'configuration_status' = 'pending_verification', format('TEST FAIL: verify did not reach pending_verification, got %s', v_res);
  raise notice 'OK: verify_carrier_factoring_integration moves draft -> pending_verification.';
end
$t$;

\echo '----- B4. activate -> ready, is_active=true -----'
do $t$
declare v_id uuid := current_setting('test.b1_integration_id')::uuid; v_res jsonb;
begin
  v_res := public.activate_carrier_factoring_integration(v_id, 'Verified externally', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-b-activate');
  assert (v_res->>'success')::boolean and v_res->>'configuration_status' = 'ready', format('TEST FAIL: activate did not reach ready, got %s', v_res);
  assert (select is_active from public.carrier_factoring_integrations where id = v_id), 'TEST FAIL: is_active is not true after activation.';
  raise notice 'OK: activate_carrier_factoring_integration moves pending_verification -> ready, is_active=true.';
end
$t$;

\echo '----- B5. classify_carrier_factoring_readiness reports ready -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'ready', format('TEST FAIL: expected classification=ready, got %s', v_res);
  raise notice 'OK: classify_carrier_factoring_readiness reports ready once the integration is active and problem-free.';
end
$t$;

\echo '----- B6. a second integration cannot ALSO become ready for the same relationship -----'
do $t$
declare v_res jsonb; v_second_id uuid;
begin
  v_res := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a1', 'vault://22222222-2222-2222-2222-222222222222', 'ACCT-1B', 'factoring_api', null,
    'second integration', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a1'), 'idem-b6-configure');
  v_second_id := (v_res->>'integration_id')::uuid;
  v_res := public.verify_carrier_factoring_integration(v_second_id, 'begin review', (select updated_at from public.carrier_factoring_integrations where id=v_second_id), 'idem-b6-verify');
  v_res := public.activate_carrier_factoring_integration(v_second_id, 'attempt second activation', (select updated_at from public.carrier_factoring_integrations where id=v_second_id), 'idem-b6-activate');
  assert (v_res->>'success')::boolean = false and v_res->>'code' = 'ACTIVE_INTEGRATION_DEPENDENCY', format('TEST FAIL: second activation should be rejected as ACTIVE_INTEGRATION_DEPENDENCY, got %s', v_res);
  perform set_config('test.b6_integration_id', v_second_id::text, false);
  raise notice 'OK: only one active/ready integration can govern a relationship -- a second activation attempt is rejected.';
end
$t$;

\echo '----- B7. deactivate -> suspended -----'
do $t$
declare v_id uuid := current_setting('test.b1_integration_id')::uuid; v_res jsonb;
begin
  v_res := public.deactivate_carrier_factoring_integration(v_id, 'planned rotation', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-b-deactivate');
  assert (v_res->>'success')::boolean and v_res->>'configuration_status' = 'suspended', format('TEST FAIL: deactivate did not reach suspended, got %s', v_res);
  assert not (select is_active from public.carrier_factoring_integrations where id = v_id), 'TEST FAIL: is_active is still true after deactivation.';
  raise notice 'OK: deactivate_carrier_factoring_integration moves ready -> suspended, is_active=false.';
end
$t$;

\echo '----- B8. rotate: revokes the old row, creates a fresh draft, preserves history -----'
do $t$
declare v_id uuid := current_setting('test.b1_integration_id')::uuid; v_res jsonb; v_new_id uuid;
begin
  v_res := public.rotate_carrier_factoring_integration(v_id, 'vault://33333333-3333-3333-3333-333333333333', 'ACCT-1-ROTATED', 'factoring_api', null,
    'credential rotation', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-b-rotate');
  assert (v_res->>'success')::boolean, format('TEST FAIL: rotate did not succeed, got %s', v_res);
  v_new_id := (v_res->>'integration_id')::uuid;
  assert (v_res->>'replaced_integration_id')::uuid = v_id, 'TEST FAIL: rotate did not report the replaced integration id.';
  assert (select configuration_status from public.carrier_factoring_integrations where id = v_id) = 'revoked', 'TEST FAIL: old row is not revoked after rotation.';
  assert (select configuration_status from public.carrier_factoring_integrations where id = v_new_id) = 'draft', 'TEST FAIL: new row is not draft after rotation.';
  assert (select external_account_identifier from public.carrier_factoring_integrations where id = v_id) = 'ACCT-1', 'TEST FAIL: rotation must never overwrite the OLD row''s own historical identity.';
  perform set_config('test.b8_new_integration_id', v_new_id::text, false);
  raise notice 'OK: rotate_carrier_factoring_integration revokes the old row (history preserved, unchanged) and creates a fresh draft replacement.';
end
$t$;

\echo '----- B9. revoke is terminal -- any further transition is rejected -----'
do $t$
declare v_id uuid := current_setting('test.b1_integration_id')::uuid; v_res jsonb;
begin
  v_res := public.verify_carrier_factoring_integration(v_id, 'attempt after revoke', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-b9-verify');
  assert (v_res->>'success')::boolean = false and v_res->>'code' = 'REVOKED_TERMINAL', format('TEST FAIL: expected REVOKED_TERMINAL, got %s', v_res);
  raise notice 'OK: a revoked integration is terminal -- no further transition is accepted.';
end
$t$;

-- ---------------------------------------------------------------------------
-- Section C: readiness invariants block activation
-- ---------------------------------------------------------------------------
\echo '----- C1. activation blocked when the relationship is not the current default -----'
do $t$
declare v_res jsonb; v_id uuid;
begin
  v_res := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a2', 'vault://44444444-4444-4444-4444-444444444444', 'ACCT-2', 'factoring_api', null,
    'nondefault relationship', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a2'), 'idem-c1-configure');
  v_id := (v_res->>'integration_id')::uuid;
  v_res := public.verify_carrier_factoring_integration(v_id, 'review of configuration', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-c1-verify');
  v_res := public.activate_carrier_factoring_integration(v_id, 'attempt on nondefault relationship', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-c1-activate');
  assert (v_res->>'success')::boolean = false and v_res->>'code' = 'NOT_READY' and v_res->>'problem' = 'relationship_not_default',
    format('TEST FAIL: expected NOT_READY/relationship_not_default, got %s', v_res);
  raise notice 'OK: activation is blocked when the governing relationship is not the carrier''s current default.';
end
$t$;

\echo '----- C2. activation blocked when the carrier policy is not factored -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'C2 test setup',
    (select updated_at from public.carriers where id='a1a1a1a1-0000-0000-0000-000000000001'), null);
  assert (v_res->>'success')::boolean, format('TEST FAIL: could not switch carrier to direct for C2 setup, got %s', v_res);
end
$t$;
do $t$
declare v_id uuid := current_setting('test.b8_new_integration_id')::uuid; v_res jsonb;
begin
  v_res := public.verify_carrier_factoring_integration(v_id, 'review of configuration', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-c2-verify');
  assert (v_res->>'success')::boolean, format('TEST FAIL: verify (setup for C2) did not succeed, got %s', v_res);
  v_res := public.activate_carrier_factoring_integration(v_id, 'attempt while carrier is direct', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-c2-activate');
  assert (v_res->>'success')::boolean = false and v_res->>'code' = 'NOT_READY' and v_res->>'problem' = 'carrier_not_factored',
    format('TEST FAIL: expected NOT_READY/carrier_not_factored, got %s', v_res);
  raise notice 'OK: activation is blocked when the carrier''s own policy is not factored.';
end
$t$;
do $t$
declare v_res jsonb;
begin
  v_res := public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'factored', 'C2 test teardown',
    (select updated_at from public.carriers where id='a1a1a1a1-0000-0000-0000-000000000001'), null);
  assert (v_res->>'success')::boolean, format('TEST FAIL: could not switch carrier back to factored after C2, got %s', v_res);
end
$t$;

\echo '----- C3. activation blocked for a finite effective_to (no scheduler exists to clear it) -----'
-- Direct write access to carrier_factoring_integrations is revoked from
-- authenticated (Section F below); as superuser we set up this one
-- fixture field directly, matching this project's own established
-- convention for test-only privileged setup between authenticated blocks.
reset role;
do $t$
declare v_id uuid := current_setting('test.b8_new_integration_id')::uuid;
begin
  update public.carrier_factoring_integrations set effective_to = current_date + 30 where id = v_id;
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.b8_new_integration_id')::uuid; v_res jsonb;
begin
  v_res := public.activate_carrier_factoring_integration(v_id, 'attempt with finite effective_to', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-c3-activate');
  assert (v_res->>'success')::boolean = false and v_res->>'problem' = 'finite_expiry_requires_lifecycle_scheduler',
    format('TEST FAIL: expected finite_expiry_requires_lifecycle_scheduler, got %s', v_res);
  raise notice 'OK: activation refuses a finite effective_to on the integration itself -- no background worker exists to clear it later.';
end
$t$;
reset role;
do $t$
declare v_id uuid := current_setting('test.b8_new_integration_id')::uuid;
begin
  update public.carrier_factoring_integrations set effective_to = null where id = v_id;
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '----- C4. activation blocked when NOA is not approved -----'
-- set_default_factoring_relationship() itself REFUSES to promote an
-- incomplete (no approved NOA) relationship to default -- exactly the
-- state this test needs to reach -- and is_default is column-privilege
-- locked (0138/0139: RPC-only, not even owner/admin may UPDATE it
-- directly). This state is therefore UNREACHABLE via any sanctioned
-- path, exactly like 0138's own "default_inactive"/"factoring_company_
-- inactive" classifier branches -- tested there (see TEST_0138) by
-- temporarily forcing the state as superuser, the same established
-- convention followed here.
reset role;
do $t$
begin
  update public.factoring_relationships set is_default = false where id = 'fe410000-0000-0000-0000-0000000000a1';
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, submission_method, is_default, is_active)
  values
    ('fe410000-0000-0000-0000-0000000000a3', '11111111-1111-1111-1111-111111111111', 'fc410000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
     90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire A3', 'api', true, true);
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid; v_res jsonb;
begin
  v_res := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a3', 'vault://55555555-5555-5555-5555-555555555555', 'ACCT-3', 'factoring_api', null,
    'no NOA yet', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a3'), 'idem-c4-configure');
  v_id := (v_res->>'integration_id')::uuid;
  v_res := public.verify_carrier_factoring_integration(v_id, 'review of configuration', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-c4-verify');
  v_res := public.activate_carrier_factoring_integration(v_id, 'attempt with no approved NOA', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-c4-activate');
  assert (v_res->>'success')::boolean = false and v_res->>'problem' = 'noa_not_approved', format('TEST FAIL: expected noa_not_approved, got %s', v_res);
  raise notice 'OK: activation is blocked while the governing relationship has no approved Notice of Assignment.';
end
$t$;
-- restore fe410000...a1 as the default for later sections (same forced
-- reset, since is_default is RPC-only for a real caller).
reset role;
do $t$
begin
  update public.factoring_relationships set is_default = false where id = 'fe410000-0000-0000-0000-0000000000a3';
  update public.factoring_relationships set is_default = true where id = 'fe410000-0000-0000-0000-0000000000a1';
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '----- C5. activation blocked when required API metadata is incomplete -----'
do $t$
declare v_res jsonb; v_id uuid;
begin
  v_res := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a1', null, null, null, null,
    'no api metadata at all', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a1'), 'idem-c5-configure');
  assert (v_res->>'success')::boolean = false and v_res->>'code' = 'API_METADATA_REQUIRED', format('TEST FAIL: expected API_METADATA_REQUIRED at configure time for an api-method relationship, got %s', v_res);
  raise notice 'OK: configure itself refuses incomplete API metadata for an api-method relationship.';
end
$t$;

-- ---------------------------------------------------------------------------
-- Section D: idempotency
-- ---------------------------------------------------------------------------
\echo '----- D1. same idempotency key replay returns the ORIGINAL cached result, even after the version is stale -----'
do $t$
declare v_id uuid; v_res1 jsonb; v_res2 jsonb; v_stale_version timestamptz;
begin
  v_res1 := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a1', 'vault://66666666-6666-6666-6666-666666666666', 'ACCT-D1', 'factoring_api', null,
    'idempotency test', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a1'), 'idem-d1-configure');
  v_id := (v_res1->>'integration_id')::uuid;
  v_stale_version := (v_res1->>'updated_at')::timestamptz;
  v_res1 := public.verify_carrier_factoring_integration(v_id, 'begin review', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-d1-verify');
  -- replay with the SAME key but a now-STALE expected_updated_at -- must
  -- return the cached original result, never STALE_RECORD.
  v_res2 := public.verify_carrier_factoring_integration(v_id, 'begin review', v_stale_version, 'idem-d1-verify');
  assert v_res2->>'idempotent_replay' = 'true', format('TEST FAIL: replay with the same key should return the cached result, got %s', v_res2);
  assert v_res2->>'configuration_status' = 'pending_verification', format('TEST FAIL: replayed result has wrong configuration_status, got %s', v_res2);
  raise notice 'OK: an identical idempotency-key replay returns the original cached result, even with a stale expected_updated_at.';
end
$t$;

\echo '----- D2. a DIFFERENT idempotency key against an already-satisfied request returns a real (non-cached) structured result -----'
do $t$
declare v_id uuid; v_res jsonb;
begin
  select (result->>'integration_id')::uuid into v_id from public.factoring_integration_lifecycle_idempotency where idempotency_key = 'idem-d1-configure';
  v_res := public.verify_carrier_factoring_integration(v_id, 'second caller, different key', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-d2-verify-different-key');
  assert (v_res->>'success')::boolean = false and v_res->>'code' = 'ALREADY_IN_STATE', format('TEST FAIL: expected ALREADY_IN_STATE (not idempotent_replay), got %s', v_res);
  assert v_res->>'idempotent_replay' is null, 'TEST FAIL: a different idempotency key must never be treated as a replay.';
  raise notice 'OK: a different idempotency key against the same already-satisfied request gets its own real, non-cached, deterministic rejection.';
end
$t$;

-- ---------------------------------------------------------------------------
-- Section E: relationship deactivation dependency
-- ---------------------------------------------------------------------------
\echo '----- E0. re-activate an integration on fe...a1 so Section E has something to depend on -----'
-- fe...a1's original integration was deactivated+rotated away in B7/B8;
-- the rotation replacement (b8_new_integration_id) is still pending_
-- verification (C2/C3 only exercised, then reversed, its rejection
-- paths) -- activate it for real now that the relationship/carrier are
-- back in a fully ready state.
do $t$
declare v_id uuid := current_setting('test.b8_new_integration_id')::uuid; v_res jsonb;
begin
  v_res := public.activate_carrier_factoring_integration(v_id, 'activate for Section E', (select updated_at from public.carrier_factoring_integrations where id=v_id), 'idem-e0-activate');
  assert (v_res->>'success')::boolean, format('TEST FAIL: could not activate the integration ahead of Section E, got %s', v_res);
  raise notice 'OK: fe...a1 has an active/ready integration again ahead of Section E.';
end
$t$;

\echo '----- E1. deactivate_factoring_relationship rejects while an active integration depends on it -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.deactivate_factoring_relationship('fe410000-0000-0000-0000-0000000000a1', 'attempt without coordination', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a1'), 'idem-e1-deact', false);
  assert (v_res->>'success')::boolean = false and v_res->>'code' = 'ACTIVE_INTEGRATION_DEPENDENCY', format('TEST FAIL: expected ACTIVE_INTEGRATION_DEPENDENCY, got %s', v_res);
  raise notice 'OK: relationship deactivation rejects outright while an active integration depends on it.';
end
$t$;

\echo '----- E2. a direct UPDATE deactivating the relationship is ALSO rejected (the row-level dependency guard, not just the RPC) -----'
-- An active/ready integration always implies its relationship IS the
-- carrier's current default (factoring_relationship_lifecycle_problem
-- requires is_default for readiness) -- so a direct deactivation attempt
-- here hits the pre-existing factoring_relationships_default_must_be_
-- active CHECK constraint (0071) BEFORE my new AFTER-ROW guard even
-- runs (CHECK constraints fire before AFTER triggers, row-level or
-- statement-level alike). Both are
-- legitimate, and together they mean this direct UPDATE can never
-- succeed either way -- accept either rejection as proof the rule
-- cannot be bypassed.
do $t$
begin
  begin
    update public.factoring_relationships set is_active = false where id = 'fe410000-0000-0000-0000-0000000000a1';
    raise exception 'TEST FAIL: a direct UPDATE deactivating a relationship with an active integration should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%Active factoring integration dependency%' and sqlerrm not ilike '%factoring_relationships_default_must_be_active%' then raise; end if;
    raise notice 'OK: a direct UPDATE cannot bypass the dependency invariant either -- rejected by (%).', sqlerrm;
  end;
end
$t$;

\echo '----- E2b. deactivating the FACTORING COMPANY behind an active integration is ALSO rejected -----'
-- 0138's own guard_factoring_company_deactivation already blocks this
-- (the company is still some carrier's active default) before my new
-- row-level dependency guard would even get a chance to -- both
-- protections point at the same outcome; accept either.
do $t$
begin
  begin
    update public.factoring_companies set is_active = false where id = 'fc410000-0000-0000-0000-000000000001';
    raise exception 'TEST FAIL: deactivating the factoring company behind an active integration should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%Active factoring integration dependency%' and sqlerrm not ilike '%carrier''s default%' then raise; end if;
    raise notice 'OK: a factoring company behind an active integration cannot be deactivated either (%).', sqlerrm;
  end;
end
$t$;

\echo '----- E3. deactivate_factoring_relationship with p_coordinated=true suspends the integration and deactivates the relationship atomically -----'
do $t$
declare v_res jsonb; v_active_id uuid;
begin
  select id into v_active_id from public.carrier_factoring_integrations where factoring_relationship_id = 'fe410000-0000-0000-0000-0000000000a1' and is_active;
  v_res := public.deactivate_factoring_relationship('fe410000-0000-0000-0000-0000000000a1', 'coordinated maintenance', (select updated_at from public.factoring_relationships where id='fe410000-0000-0000-0000-0000000000a1'), 'idem-e3-deact', true);
  assert (v_res->>'success')::boolean and (v_res->>'suspended_integrations')::int = 1, format('TEST FAIL: coordinated deactivation did not succeed as expected, got %s', v_res);
  assert not (select is_active from public.factoring_relationships where id = 'fe410000-0000-0000-0000-0000000000a1'), 'TEST FAIL: relationship is still active.';
  assert (select configuration_status from public.carrier_factoring_integrations where id = v_active_id) = 'suspended', 'TEST FAIL: the integration was not suspended.';
  raise notice 'OK: p_coordinated=true suspends the active integration and deactivates the relationship together, atomically, with one audit event.';
end
$t$;

-- ---------------------------------------------------------------------------
-- Section F: cross-tenant / cross-carrier tampering and direct-write lockdown
-- ---------------------------------------------------------------------------
\echo '----- F1. org B cannot configure an integration against org A''s relationship -----'
reset role;
select set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.configure_carrier_factoring_integration('fe410000-0000-0000-0000-0000000000a1', 'vault://77777777-7777-7777-7777-777777777777', 'ACCT-X', 'factoring_api', null,
    'cross-org attempt', now(), 'idem-f1-configure');
  assert (v_res->>'code') in ('NOT_FOUND', 'FORBIDDEN'), format('TEST FAIL: cross-org configure should be NOT_FOUND/FORBIDDEN, got %s', v_res);
  raise notice 'OK: a caller from a different organization cannot configure an integration against org A''s relationship.';
end
$t$;
reset role;

\echo '----- F2. direct INSERT/UPDATE on carrier_factoring_integrations is refused for authenticated -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    insert into public.carrier_factoring_integrations (organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, created_by)
    values ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'fe410000-0000-0000-0000-0000000000a1', 'fc410000-0000-0000-0000-000000000001', 'api', 'aaaa0000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: a direct INSERT into carrier_factoring_integrations should be refused.';
  exception when others then
    if sqlerrm not ilike '%permission denied%' then raise; end if;
    raise notice 'OK: a direct INSERT is refused (%).', sqlerrm;
  end;
  begin
    update public.carrier_factoring_integrations set is_active = true where organization_id = '11111111-1111-1111-1111-111111111111';
    raise exception 'TEST FAIL: a direct UPDATE on carrier_factoring_integrations should be refused.';
  exception when others then
    if sqlerrm not ilike '%permission denied%' then raise; end if;
    raise notice 'OK: a direct UPDATE is refused (%).', sqlerrm;
  end;
end
$t$;
reset role;

\echo '----- F3. no secret_reference reaches the browser via the existing status reader -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_status jsonb;
begin
  v_status := public.get_carrier_factoring_integration_status('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_status::text not ilike '%secret_reference%' and v_status::text not ilike '%vault://%', format('TEST FAIL: secret_reference leaked into the status reader''s payload: %s', v_status);
  raise notice 'OK: accountant''s status read never includes secret_reference or any credential-reference value.';
end
$t$;
reset role;

\echo '----- F4 (static): no lifecycle function ever packages secret_reference into its jsonb/text result -----'
-- factoring_integration_lifecycle_problem() and transition_carrier_
-- factoring_integration_lifecycle() both legitimately CHECK
-- secret_reference's null-ness (a precondition, e.g. "is a credential
-- reference configured at all") -- that is not a leak. The actual
-- invariant is that secret_reference is never packaged as a VALUE into a
-- jsonb_build_object(...) result or otherwise handed back to the caller
-- -- which the code never does (both functions' own jsonb results only
-- ever include success/code/integration_id/relationship_id/carrier_id/
-- configuration_status/updated_at/problem/message).
do $t$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'factoring_integration_lifecycle_problem' and pronamespace = 'public'::regnamespace;
  assert v_src not ilike '%''secret_reference'',%' and v_src not ilike '%to_jsonb(i)%' and v_src not ilike '%row_to_json%',
    'TEST FAIL: factoring_integration_lifecycle_problem must never package secret_reference into a returned value.';
  select prosrc into v_src from pg_proc where proname = 'transition_carrier_factoring_integration_lifecycle' and pronamespace = 'public'::regnamespace;
  assert v_src not ilike '%''secret_reference'',%' and v_src not ilike '%to_jsonb(v_integration)%' and v_src not ilike '%row_to_json%',
    'TEST FAIL: the shared transition function must never package secret_reference into its jsonb result.';
  raise notice 'OK: no lifecycle function ever packages secret_reference into a value it returns to the caller.';
end
$t$;

-- ---------------------------------------------------------------------------
-- Section G (Phase 3B.2.1, Section C): dependency-guard multi-organization
-- isolation -- the guard is now row-level and organization-scoped
-- (guard_factoring_lifecycle_dependencies); prove it directly, not just via
-- query-plan inspection.
-- ---------------------------------------------------------------------------
\echo '----- G1. seed org B with its own ready, factored, fully-active integration -----'
reset role;
-- `reset role` restores the Postgres role to superuser for this fixture
-- insert, but it does NOT clear the `test.current_uid` session GUC left
-- over from whatever section last set it (line 535: an org-A, non-owner
-- uid). guard_factoring_relationship_protected_fields() only bypasses its
-- owner/admin check when auth.uid() (i.e. test.current_uid) is NULL --
-- superuser status alone does not exempt a NON-NULL uid from the check.
-- Clear it explicitly so this privileged fixture insert is treated the
-- same as a migration/service context, exactly like every other
-- superuser-fixture block in this file relies on implicitly at the very
-- start (before any set_config call has ever run).
select set_config('test.current_uid', null, false);
do $t$
begin
  insert into public.factoring_companies (id, organization_id, name, is_active) values
    ('fc0f0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Factor B', true);
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
     noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active)
  values
    ('fe0f0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'fc0f0000-0000-0000-0000-000000000001',
     'b1b1b1b1-0000-0000-0000-000000000001', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire B', 'NOA B v1', 'v1',
     current_date - 5, true, 'bbbb0000-0000-0000-0000-000000000001', now(), 'internal_queue', true, true);
  update public.carriers set factoring_mode = 'factored' where id = 'b1b1b1b1-0000-0000-0000-000000000001';
end
$t$;
select set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_res jsonb; v_iid uuid;
begin
  v_res := public.configure_carrier_factoring_integration('fe0f0000-0000-0000-0000-000000000001', null, null, null, null,
    'org B seed integration', (select updated_at from public.factoring_relationships where id='fe0f0000-0000-0000-0000-000000000001'), 'org-b-configure');
  v_iid := (v_res->>'integration_id')::uuid;
  perform public.verify_carrier_factoring_integration(v_iid, 'org B review', (select updated_at from public.carrier_factoring_integrations where id=v_iid), 'org-b-verify');
  v_res := public.activate_carrier_factoring_integration(v_iid, 'org B activation', (select updated_at from public.carrier_factoring_integrations where id=v_iid), 'org-b-activate');
  assert (v_res->>'success')::boolean, format('TEST FAIL: org B integration did not activate, got %s', v_res);
  perform set_config('test.org_b_integration_id', v_iid::text, false);
  raise notice 'OK: org B has its own independent active/ready integration.';
end
$t$;
reset role;

\echo '----- G2 (live): the guard never scans across organizations -- a live cross-org mutation while org B''s integration is active, plus a genuine attempt to invalidate org B''s OWN integration -----'
do $t$
begin
  -- Break org B's own dependency on purpose (superuser, direct -- this is
  -- a controlled test setup, not a reachable application path) so that if
  -- ANY unrelated mutation anywhere ever re-evaluated org B's rows, it
  -- would immediately raise. It must NOT raise when org A's own,
  -- unrelated carrier is touched.
  update public.carriers set factoring_mode = 'direct' where id = 'b1b1b1b1-0000-0000-0000-000000000001';
  -- the UPDATE above is itself org B's own mutation and WILL be evaluated
  -- against org B's own now-active integration -- confirm THAT part still
  -- works (own-org detection is not disabled by the narrowing):
  raise exception 'TEST FAIL: expected the direct UPDATE above to have already been rejected by the row-level guard for org B''s own integration -- it should never have reached this line.';
exception
  when others then
    if sqlerrm not ilike '%Active factoring integration dependency%' then raise; end if;
    raise notice 'OK: org B''s OWN mutation against its OWN active integration is still correctly caught (own-org detection unaffected by the narrowing).';
end
$t$;
do $t$
begin
  -- Now touch ORG A's carrier (a completely unrelated organization) --
  -- this must succeed or fail based ONLY on org A's own state, and must
  -- never even look at, let alone be blocked by, org B's still-intact
  -- active integration.
  update public.carriers set notes = 'isolation probe -- org A only' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  raise notice 'OK: a completely unrelated write to org A''s carrier succeeded without ever touching or being affected by org B''s active integration -- cross-organization isolation confirmed live, not just by query-plan inspection.';
end
$t$;
do $t$
declare v_problem text;
begin
  -- The attempted factoring_mode change above was itself rejected and
  -- rolled back in full (the guard raising aborts the WHOLE statement,
  -- not just the trigger's own effect) -- org B's carrier is therefore
  -- still 'factored' and its integration is still perfectly healthy.
  select public.factoring_integration_lifecycle_problem(id) into strict v_problem
  from public.carrier_factoring_integrations where id = current_setting('test.org_b_integration_id')::uuid;
  assert v_problem is null, format('TEST FAIL: org B''s integration should still be problem-free (its own invalidating mutation was rejected and rolled back in full), got %s', v_problem);
  raise notice 'OK: org B''s integration remains fully healthy -- its own invalidating mutation attempt was rejected AND rolled back in its entirety, and org A''s own unrelated write never touched or was affected by it either way.';
end
$t$;

\echo '################  TEST 0141 PASSED  ################'
