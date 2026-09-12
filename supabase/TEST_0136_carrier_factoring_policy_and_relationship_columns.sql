-- ============================================================================
-- TEST_0136_carrier_factoring_policy_and_relationship_columns.sql
-- disposable database only. Run via TEST_0130_0133_run.sh.
--
-- Phase 3B.1 verification: carriers.factoring_mode, factoring_relationships'
-- new columns/constraints, the extended org-consistency guard, and the new
-- owner/admin-only protected-fields guard.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0136  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i TEST_SUPPORT_0136_0138_factoring_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql
\i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
\i migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql
\i migrations/0136_carrier_factoring_policy_and_relationship_columns.sql

\echo '===== fixtures: a company + a same-org carrier + a cross-org carrier =====-'
do $t$
begin
  insert into public.factoring_companies (id, organization_id, name)
  values ('fc000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Acme Factoring');
  -- A1/A2 carriers already exist in the standard seed (org 111...).
  -- A cross-org carrier (org B, 222...) for the tampering test.
  insert into public.carriers (id, organization_id, legal_name)
  values ('c9000000-0000-0000-0000-000000000009', '22222222-2222-2222-2222-222222222222', 'Org B Carrier');
end
$t$;

\echo '----- A1. every existing carrier defaulted to factoring_mode=unconfigured (Phase 3B.1.1: never silently direct) -----'
do $t$
declare v_n int;
begin
  select count(*) into v_n from public.carriers where factoring_mode <> 'unconfigured';
  assert v_n = 0, format('TEST FAIL: %s carrier(s) not defaulted to unconfigured', v_n);
  raise notice 'OK: every carrier defaults to factoring_mode=unconfigured -- missing configuration never silently becomes direct billing.';
end
$t$;

\echo '----- A2. cross-organization carrier_id rejected on insert -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
begin
  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
       default_reserve_percentage, fee_timing, recourse_type)
    values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'c9000000-0000-0000-0000-000000000009',
            90, 3, 10, 'deducted_at_funding', 'non_recourse');
    raise exception 'TEST FAIL: cross-org carrier_id on a new relationship succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-org carrier_id rejected (%)', sqlerrm;
  end;
end
$t$;
reset role;

\echo '----- A3. direct authenticated write cannot set is_default=true on insert (dispatcher/accountant); owner/admin can -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note; -- dispatcher
set role authenticated;
do $t$
begin
  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
       default_reserve_percentage, fee_timing, recourse_type, is_default)
    values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
            90, 3, 10, 'deducted_at_funding', 'non_recourse', true);
    raise exception 'TEST FAIL: dispatcher inserting an already-default relationship succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: dispatcher cannot insert an already-default relationship (%)', sqlerrm;
  end;
end
$t$;
reset role;

select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note; -- owner
set role authenticated;
do $t$
declare v_id uuid;
begin
  insert into public.factoring_relationships
    (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, is_default)
  values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
          90, 3, 10, 'deducted_at_funding', 'non_recourse', true)
  returning id into v_id;
  assert v_id is not null, 'TEST FAIL: owner insert of a default relationship did not succeed';
  raise notice 'OK: owner can insert an already-default relationship (%)', v_id;
end
$t$;
reset role;

\echo '----- A4. dispatcher/accountant cannot set noa_approved / remittance via direct UPDATE; owner/admin can -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false) as note; -- accountant
set role authenticated;
do $t$
declare v_rel_id uuid;
begin
  select id into v_rel_id from public.factoring_relationships where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' limit 1;
  begin
    update public.factoring_relationships set noa_approved = true, noa_approved_by = null, noa_approved_at = now(), noa_reference = 'v1' where id = v_rel_id;
    raise exception 'TEST FAIL: accountant approving NOA via direct UPDATE succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: accountant cannot approve NOA via direct UPDATE (%)', sqlerrm;
  end;
  begin
    update public.factoring_relationships set remittance_instructions = 'wire to X' where id = v_rel_id;
    raise exception 'TEST FAIL: accountant editing remittance_instructions via direct UPDATE succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: accountant cannot edit remittance_instructions via direct UPDATE (%)', sqlerrm;
  end;
end
$t$;
reset role;

select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note; -- owner
set role authenticated;
do $t$
declare v_rel_id uuid;
begin
  select id into v_rel_id from public.factoring_relationships where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' limit 1;
  update public.factoring_relationships
  set remittance_instructions = 'Wire to Acme Bank, account ending 1234',
      noa_template_text = 'Notice of Assignment: pay Acme Factoring directly.',
      noa_reference = 'v1', noa_effective_date = current_date,
      noa_approved = true, noa_approved_by = auth.uid(), noa_approved_at = now(),
      submission_method = 'internal_queue'
  where id = v_rel_id;
  assert (select noa_approved from public.factoring_relationships where id = v_rel_id) = true,
    'TEST FAIL: owner direct UPDATE of NOA/remittance fields did not apply';
  raise notice 'OK: owner CAN set NOA/remittance fields via direct UPDATE.';
end
$t$;
reset role;

\echo '----- A5. NOA-approval-complete CHECK: cannot flip noa_approved=true with neither template nor document -----'
do $t$
begin
  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
       default_reserve_percentage, fee_timing, recourse_type, noa_approved, noa_approved_by, noa_approved_at, noa_reference, noa_effective_date)
    values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
            90, 3, 10, 'deducted_at_funding', 'non_recourse', true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'v2', current_date);
    raise exception 'TEST FAIL: noa_approved=true with neither template text nor document succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: noa_approved=true requires template text or a document reference (%)', sqlerrm;
  end;
end
$t$;

\echo '----- A6. submission_method=secure_email requires a valid destination email; api requires an integration reference -----'
do $t$
begin
  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
       default_reserve_percentage, fee_timing, recourse_type, submission_method)
    values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
            90, 3, 10, 'deducted_at_funding', 'non_recourse', 'secure_email');
    raise exception 'TEST FAIL: submission_method=secure_email with no destination email succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: secure_email requires a destination email (%)', sqlerrm;
  end;
  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
       default_reserve_percentage, fee_timing, recourse_type, submission_method)
    values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
            90, 3, 10, 'deducted_at_funding', 'non_recourse', 'api');
    raise exception 'TEST FAIL: submission_method=api with no integration reference succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: api requires an integration reference (%)', sqlerrm;
  end;
end
$t$;

\echo '----- A7. submission_integration_id must be enabled, same-org, provider=factoring_api -----'
do $t$
begin
  insert into public.integration_settings (id, organization_id, provider, is_enabled)
  values ('1e000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'quickbooks', true);
  -- integration_settings has a real UNIQUE(organization_id, provider)
  -- constraint (0008) -- one row serves BOTH the "disabled" and (after
  -- flipping it) "enabled" sub-tests below, rather than two factoring_api
  -- rows in the same org (which the constraint would reject outright).
  insert into public.integration_settings (id, organization_id, provider, is_enabled)
  values ('1e000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'factoring_api', false);

  begin
    perform 1 from (select 1) x;
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
       default_reserve_percentage, fee_timing, recourse_type, submission_method, submission_integration_id)
    values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
            90, 3, 10, 'deducted_at_funding', 'non_recourse', 'api', '1e000000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: submission_integration_id pointing at a non-factoring_api provider succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: submission_integration_id must be a factoring_api provider (%)', sqlerrm;
  end;

  begin
    insert into public.factoring_relationships
      (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
       default_reserve_percentage, fee_timing, recourse_type, submission_method, submission_integration_id)
    values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
            90, 3, 10, 'deducted_at_funding', 'non_recourse', 'api', '1e000000-0000-0000-0000-000000000002');
    raise exception 'TEST FAIL: submission_integration_id pointing at a DISABLED integration succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: submission_integration_id must be enabled (%)', sqlerrm;
  end;

  update public.integration_settings set is_enabled = true where id = '1e000000-0000-0000-0000-000000000002';

  insert into public.factoring_relationships
    (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, submission_method, submission_integration_id)
  values ('11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001',
          90, 3, 10, 'deducted_at_funding', 'non_recourse', 'api', '1e000000-0000-0000-0000-000000000002');
  raise notice 'OK: an enabled factoring_api integration reference succeeds.';
end
$t$;

\echo '----- A8. no secret-shaped fields exist in factoring_relationships -----'
do $t$
declare v_n int;
begin
  select count(*) into v_n from information_schema.columns
    where table_schema='public' and table_name='factoring_relationships'
      and (column_name ilike '%secret%' or column_name ilike '%password%' or column_name ilike '%api_key%'
           or column_name ilike '%access_token%' or column_name ilike '%credential%');
  assert v_n = 0, format('TEST FAIL: found %s secret-shaped column(s) on factoring_relationships', v_n);
  raise notice 'OK: no secret/credential/token-shaped columns exist on factoring_relationships.';
end
$t$;

\echo '################  TEST 0136 PASSED  ################'
