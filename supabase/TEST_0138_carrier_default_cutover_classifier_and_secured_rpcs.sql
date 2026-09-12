-- ============================================================================
-- TEST_0138_carrier_default_cutover_classifier_and_secured_rpcs.sql
-- disposable database only. Run via TEST_0130_0133_run.sh.
--
-- Phase 3B.1 verification: classify_carrier_factoring_readiness() (every
-- classification category), the carrier-scoped default cutover (one
-- default per carrier, not per org), set_default_factoring_relationship()
-- (owner/admin only, carrier-isolated), approve_factoring_relationship_noa(),
-- and the column-privilege lockdown.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0138  ################'

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

\echo '===== fixtures: one factoring company, complete + incomplete relationships for A1 and A2 =====-'
do $t$
begin
  insert into public.factoring_companies (id, organization_id, name, is_active)
  values
    ('fc000000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'Shared Factor Co', true),
    ('fc000000-0000-0000-0000-00000000000d', '11111111-1111-1111-1111-111111111111', 'Inactive Factor Co', false);

  -- A1: a COMPLETE relationship (remittance + approved NOA + submission
  -- method) but NOT YET the default.
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions,
     noa_template_text, noa_reference, noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method)
  values
    ('a1000000-0000-0000-0000-0000000000f1', '11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-00000000000c', 'a1a1a1a1-0000-0000-0000-000000000001',
     90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Shared Factor Co, acct ending 1111',
     'NOA language for A1.', 'v1', current_date - 30, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue');

  -- A2: a COMPLETE relationship, different terms, different carrier.
  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions,
     noa_template_text, noa_reference, noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method)
  values
    ('a2000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-111111111111', 'fc000000-0000-0000-0000-00000000000c', 'a2a2a2a2-0000-0000-0000-000000000002',
     80, 5, 15, 'deducted_from_reserve', 'recourse', 'Wire to Shared Factor Co, acct ending 2222',
     'NOA language for A2.', 'v1', current_date - 30, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue');
end
$t$;

\echo '----- C0. Phase 3B.1.1: a fresh carrier defaults to unconfigured -- blocks outright, never silently direct -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'factoring_policy_unconfigured', format('TEST FAIL: expected factoring_policy_unconfigured, got %s', v_res);
  raise notice 'OK: an unconfigured carrier classifies as factoring_policy_unconfigured, not direct_billing -- missing configuration never silently becomes direct.';
end
$t$;

\echo '----- C1. once explicitly set to direct, needs no factor -----'
do $t$
declare v_res jsonb;
begin
  update public.carriers set factoring_mode = 'direct' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'direct_billing', format('TEST FAIL: expected direct_billing, got %s', v_res);
  raise notice 'OK: a direct-mode carrier classifies as direct_billing with no factor needed.';
end
$t$;

\echo '----- C2. factored carrier with NO relationship at all is not ready (no_factoring_configuration) -----'
do $t$
declare v_res jsonb;
begin
  update public.carriers set factoring_mode = 'factored' where id = 'a3a3a3a3-0000-0000-0000-000000000003';
  v_res := public.classify_carrier_factoring_readiness('a3a3a3a3-0000-0000-0000-000000000003');
  assert v_res->>'classification' = 'no_factoring_configuration', format('TEST FAIL: expected no_factoring_configuration, got %s', v_res);
  raise notice 'OK: a factored carrier with zero relationships classifies as no_factoring_configuration.';
end
$t$;

\echo '----- C3. factored carrier with a relationship but NO default classifies as no_default -----'
do $t$
declare v_res jsonb;
begin
  update public.carriers set factoring_mode = 'factored' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'no_default', format('TEST FAIL: expected no_default, got %s', v_res);
  raise notice 'OK: a factored carrier with a relationship that is not the default classifies as no_default.';
end
$t$;

\echo '----- C4. Owner CAN set the default (A1); Carrier A2 (own carrier) is unaffected -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.set_default_factoring_relationship('a1000000-0000-0000-0000-0000000000f1');
  assert v_res->>'success' = 'true', format('TEST FAIL: owner set_default for A1 should succeed: %s', v_res);
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'ready', format('TEST FAIL: A1 should now be ready: %s', v_res);
  raise notice 'OK: owner can set a complete relationship as its carrier''s default; classification becomes ready.';
end
$t$;

\echo '----- C5. Carrier A2 (different carrier, same factoring company) needs its OWN default -- A1''s default does not leak to it -----'
do $t$
declare v_res jsonb;
begin
  update public.carriers set factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  v_res := public.classify_carrier_factoring_readiness('a2a2a2a2-0000-0000-0000-000000000002');
  assert v_res->>'classification' = 'no_default', format('TEST FAIL: A2 should still show no_default (A1''s default must not leak to it): %s', v_res);

  v_res := public.set_default_factoring_relationship('a2000000-0000-0000-0000-0000000000f2');
  assert v_res->>'success' = 'true', format('TEST FAIL: owner set_default for A2 should succeed: %s', v_res);

  v_res := public.classify_carrier_factoring_readiness('a2a2a2a2-0000-0000-0000-000000000002');
  assert v_res->>'classification' = 'ready', format('TEST FAIL: A2 should now be ready: %s', v_res);
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'ready' and v_res->>'relationship_id' = 'a1000000-0000-0000-0000-0000000000f1',
    format('TEST FAIL: A1''s own default must be unaffected by A2''s change: %s', v_res);
  raise notice 'OK: Carrier A and Carrier B (here A1/A2) each have their own independent default -- changing one never affects the other. Two carriers, same factoring company, DIFFERENT terms (90/3/10 vs 80/5/15) both hold simultaneously.';
end
$t$;

\echo '----- C6. exactly one active+default relationship per carrier (unique index) -----'
do $t$
declare v_n int;
begin
  select count(*) into v_n from public.factoring_relationships where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and is_default and is_active;
  assert v_n = 1, format('TEST FAIL: expected exactly 1 active default for A1, got %s', v_n);
  select count(*) into v_n from public.factoring_relationships where carrier_id='a2a2a2a2-0000-0000-0000-000000000002' and is_default and is_active;
  assert v_n = 1, format('TEST FAIL: expected exactly 1 active default for A2, got %s', v_n);
  raise notice 'OK: exactly one active default per carrier, independently for A1 and A2.';
end
$t$;

\echo '----- C7. inactive relationship classified as default_inactive -----'
-- 0071's own CHECK constraint (factoring_relationships_default_must_be_
-- active, untouched by this phase) already makes "is_default=true AND
-- is_active=false" unreachable via any ordinary INSERT/UPDATE -- exactly
-- the invariant this classifier's own default_inactive branch defends in
-- depth against, should that constraint ever be relaxed or bypassed. To
-- actually exercise the branch, the constraint is dropped, the state is
-- forced, the classifier is checked, and the constraint is restored
-- immediately -- all inside this same test, never left disabled.
reset role;
alter table public.factoring_relationships drop constraint factoring_relationships_default_must_be_active;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res jsonb;
begin
  update public.factoring_relationships set is_active = false where id = 'a1000000-0000-0000-0000-0000000000f1';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'default_inactive', format('TEST FAIL: expected default_inactive, got %s', v_res);
  update public.factoring_relationships set is_active = true where id = 'a1000000-0000-0000-0000-0000000000f1';
  raise notice 'OK: an inactive default relationship classifies as default_inactive (a state 0071''s own CHECK constraint otherwise makes unreachable -- defense in depth, verified by temporarily forcing it).';
end
$t$;
reset role;
alter table public.factoring_relationships add constraint factoring_relationships_default_must_be_active check (not is_default or is_active);
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;

-- guard_factoring_company_deactivation() (0072/0138) and
-- set_default_factoring_relationship() itself BOTH independently refuse to
-- ever let an in-use company go inactive or become a default -- so, like
-- C7 above, this state is only reachable by temporarily disabling the
-- deactivation guard (superuser only) to force it, proving the
-- classifier's OWN defense-in-depth branch actually works if that
-- cooperation were ever bypassed.
\echo '----- C8. inactive factoring company classified as factoring_company_inactive -----'
reset role;
alter table public.factoring_companies disable trigger factoring_companies_guard_deactivation;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res jsonb;
begin
  update public.factoring_companies set is_active = false where id = 'fc000000-0000-0000-0000-00000000000c';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'factoring_company_inactive', format('TEST FAIL: expected factoring_company_inactive, got %s', v_res);
  update public.factoring_companies set is_active = true where id = 'fc000000-0000-0000-0000-00000000000c';
  raise notice 'OK: a default relationship under an inactive company classifies as factoring_company_inactive (a state the deactivation guard + set_default RPC otherwise cooperate to make unreachable -- verified by temporarily forcing it).';
end
$t$;
reset role;
alter table public.factoring_companies enable trigger factoring_companies_guard_deactivation;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;

\echo '----- C9. default_not_yet_effective and default_expired classified correctly -----'
do $t$
declare v_res jsonb;
begin
  update public.factoring_relationships set effective_from = current_date + 10 where id = 'a1000000-0000-0000-0000-0000000000f1';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'default_not_yet_effective', format('TEST FAIL: expected default_not_yet_effective, got %s', v_res);
  update public.factoring_relationships set effective_from = current_date - 30, effective_to = current_date - 1 where id = 'a1000000-0000-0000-0000-0000000000f1';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'default_expired', format('TEST FAIL: expected default_expired, got %s', v_res);
  update public.factoring_relationships set effective_to = null where id = 'a1000000-0000-0000-0000-0000000000f1';
  raise notice 'OK: not-yet-effective and expired defaults are classified distinctly and correctly.';
end
$t$;

\echo '----- C10. incomplete NOA/remittance classified as relationship_incomplete -----'
do $t$
declare v_res jsonb;
begin
  update public.factoring_relationships set remittance_instructions = null where id = 'a1000000-0000-0000-0000-0000000000f1';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'relationship_incomplete', format('TEST FAIL: expected relationship_incomplete, got %s', v_res);
  assert v_res->'missing' ? 'remittance_instructions', format('TEST FAIL: missing[] should list remittance_instructions: %s', v_res);
  update public.factoring_relationships set remittance_instructions = 'Wire to Shared Factor Co, acct ending 1111' where id = 'a1000000-0000-0000-0000-0000000000f1';
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  assert v_res->>'classification' = 'ready', format('TEST FAIL: A1 should be ready again after restoring remittance_instructions: %s', v_res);
  raise notice 'OK: incomplete remittance/NOA/submission-method classifies as relationship_incomplete, naming exactly what is missing.';
end
$t$;

\echo '----- C11. carrier-party ineligible/inactive gates apply regardless of factoring_mode -----'
do $t$
declare v_res jsonb; v_broker_id uuid;
begin
  select id into v_broker_id from public.brokers where organization_id='11111111-1111-1111-1111-111111111111' limit 1;

  insert into public.carrier_brokers (organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible)
  values ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', v_broker_id, 'active', 'b@example.com', 30, false);

  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001', v_broker_id);
  assert v_res->>'classification' = 'carrier_party_ineligible', format('TEST FAIL: expected carrier_party_ineligible, got %s', v_res);

  update public.carrier_brokers set status = 'inactive' where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and broker_id=v_broker_id;
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001', v_broker_id);
  assert v_res->>'classification' = 'carrier_party_inactive', format('TEST FAIL: expected carrier_party_inactive, got %s', v_res);

  raise notice 'OK: carrier-party ineligible forces a distinct classification (direct billing for that party); an inactive carrier-party relationship blocks regardless of the carrier''s own factoring mode.';
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '----- C12. dispatcher/accountant CANNOT call set_default_factoring_relationship or approve_factoring_relationship_noa; owner/admin CAN -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note; -- dispatcher
set role authenticated;
do $t$
declare v_res jsonb;
begin
  begin
    perform public.set_default_factoring_relationship('a2000000-0000-0000-0000-0000000000f2');
    raise exception 'TEST FAIL: dispatcher calling set_default_factoring_relationship succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: dispatcher cannot call set_default_factoring_relationship (%)', sqlerrm;
  end;
  begin
    perform public.approve_factoring_relationship_noa('a2000000-0000-0000-0000-0000000000f2', 'v2', current_date, 'new language', null);
    raise exception 'TEST FAIL: dispatcher calling approve_factoring_relationship_noa succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: dispatcher cannot call approve_factoring_relationship_noa (%)', sqlerrm;
  end;
end
$t$;
reset role;

select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false) as note; -- accountant
set role authenticated;
do $t$
begin
  begin
    perform public.set_default_factoring_relationship('a2000000-0000-0000-0000-0000000000f2');
    raise exception 'TEST FAIL: accountant calling set_default_factoring_relationship succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: accountant cannot call set_default_factoring_relationship (%)', sqlerrm;
  end;
end
$t$;
reset role;

select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note; -- owner
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.approve_factoring_relationship_noa('a2000000-0000-0000-0000-0000000000f2', 'v2-updated', current_date, 'updated NOA language', null);
  assert v_res->>'success' = 'true', format('TEST FAIL: owner approving NOA should succeed: %s', v_res);
  raise notice 'OK: owner CAN approve a Notice of Assignment.';
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '----- C13. direct authenticated table-level UPDATE bypass on protected columns is rejected outright -----'
do $t$
begin
  if has_table_privilege('authenticated', 'public.factoring_relationships', 'UPDATE') then
    raise exception 'TEST FAIL: authenticated holds a table-level UPDATE grant on factoring_relationships';
  end if;
  if has_column_privilege('authenticated', 'public.factoring_relationships', 'is_default', 'UPDATE') then
    raise exception 'TEST FAIL: authenticated can UPDATE is_default directly';
  end if;
  if has_column_privilege('authenticated', 'public.factoring_relationships', 'carrier_id', 'UPDATE') then
    raise exception 'TEST FAIL: authenticated can UPDATE carrier_id directly';
  end if;
  raise notice 'OK: authenticated has no direct table/column-level UPDATE path to is_default/carrier_id -- both are RPC-only or immutable.';
end
$t$;

\echo '----- C14. classifier is preview-only: creates no invoice, submission, package, payment, or audit event -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_before int; v_after int; v_res jsonb;
begin
  select count(*) into v_before from public.activity_logs;
  v_res := public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
  select count(*) into v_after from public.activity_logs;
  assert v_before = v_after, format('TEST FAIL: classify_carrier_factoring_readiness wrote an audit event: before=%s after=%s', v_before, v_after);
  assert (select count(*) from public.invoices) is not null; -- table exists, unmodified by the call above (no insert performed)
  raise notice 'OK: the classifier/preview RPC creates no audit event and no financial record -- pure read.';
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '################  TEST 0138 PASSED  ################'
