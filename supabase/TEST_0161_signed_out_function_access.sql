-- =============================================================================
-- TEST_0161_signed_out_function_access.sql
--
-- NEVER RUN ON PRODUCTION. Disposable PostgreSQL only: migrations 0001..0119
-- plus 0161 on the Supabase stand-in. Supabase's default function grants
-- (EXECUTE to anon/authenticated/service_role) are emulated BEFORE 0161 by
-- the runner (see supabase/ci/run-db-tests.sh). ONE transaction, ends in
-- ROLLBACK.
--
-- Proves:
--   S1  signed out: get_app_encryption_key refused (it returned the master key)
--   S2  signed in:  get_app_encryption_key refused
--   S3  a SECURITY DEFINER caller still reaches the key (nested call works)
--   S4  signed out: no public SECURITY DEFINER function is executable except
--       the RLS identity helpers
--   S5  server-only functions refused for signed-in users; service_role keeps
--       verify_driver_portal_login / submit_driver_application
--   D1  deduct into ANOTHER org's settlement -> "not found", nothing written
--   D2  a viewer cannot deduct in own org
--   D3  own-org dispatcher deducts: line item added, advance marked deducted
--   L1  signed-in app functions keep access (signup RPC still works)
-- =============================================================================
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if (select count(*) from public.organizations) > 20 then
    raise exception 'REFUSING: this database has > 20 organizations -- looks like a real database.';
  end if;
end $$;

insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-00000000161a', 'owner-a@test.invalid', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-00000000161b', 'owner-b@test.invalid', 'authenticated', 'authenticated'),
  ('cccccccc-0000-0000-0000-00000000161c', 'disp-a@test.invalid',  'authenticated', 'authenticated'),
  ('dddddddd-0000-0000-0000-00000000161d', 'viewer-a@test.invalid', 'authenticated', 'authenticated');

-- L1: signup RPC still works for a signed-in user after 0161
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000161a","role":"authenticated"}', true);
set local role authenticated;
select public.create_organization_with_owner('Org A 161', 'org-a-161');
reset role;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000161b","role":"authenticated"}', true);
set local role authenticated;
select public.create_organization_with_owner('Org B 161', 'org-b-161');
reset role;

set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = (select id from public.organizations where slug = 'org-a-161'), role = 'dispatcher'
 where id = 'cccccccc-0000-0000-0000-00000000161c';
update public.profiles set organization_id = (select id from public.organizations where slug = 'org-a-161'), role = 'viewer'
 where id = 'dddddddd-0000-0000-0000-00000000161d';
set local app.bypass_profile_guard = 'false';

create temp table f as
select (select id from public.organizations where slug = 'org-a-161') as org_a,
       (select id from public.organizations where slug = 'org-b-161') as org_b,
       gen_random_uuid() as carrier_a, gen_random_uuid() as carrier_b,
       gen_random_uuid() as settle_a, gen_random_uuid() as settle_b,
       gen_random_uuid() as adv_a, gen_random_uuid() as adv_b;
grant select on f to authenticated, anon;

insert into public.carriers (id, organization_id, legal_name) select carrier_a, org_a, 'Carrier A' from f;
insert into public.carriers (id, organization_id, legal_name) select carrier_b, org_b, 'Carrier B' from f;
insert into public.settlements (id, organization_id, settlement_number, carrier_id) select settle_a, org_a, 'S-A-1', carrier_a from f;
insert into public.settlements (id, organization_id, settlement_number, carrier_id) select settle_b, org_b, 'S-B-1', carrier_b from f;
insert into public.dispatch_advances (id, organization_id, carrier_id, expense_type, amount) select adv_a, org_a, carrier_a, 'fuel', 150 from f;
insert into public.dispatch_advances (id, organization_id, carrier_id, expense_type, amount) select adv_b, org_b, carrier_b, 'fuel', 250 from f;

create or replace function pg_temp.try_as(p_role text, p_user uuid, p_sql text) returns text
language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', case when p_user is null then '' else json_build_object('sub', p_user, 'role', p_role)::text end, true);
  execute format('set local role %I', p_role);
  begin
    execute p_sql into v;
    execute 'reset role';
    return 'allowed:' || coalesce(v, '');
  exception when others then
    execute 'reset role';
    return 'refused:' || sqlerrm;
  end;
end $$;

-- S3 support: a definer function owned like the real callers (created before any role switch)
create function public.zz_test_0161_nested_key() returns text language sql security definer set search_path = public
as $f$ select left(public.get_app_encryption_key('driver_pii_key'), 4) $f$;
revoke execute on function public.zz_test_0161_nested_key() from public, anon;
grant execute on function public.zz_test_0161_nested_key() to authenticated;

do $$
declare r text; v_bad text; a uuid; b uuid; sa uuid; sb uuid; aa uuid; ab uuid; n int;
begin
  select org_a, org_b, settle_a, settle_b, adv_a, adv_b into a, b, sa, sb, aa, ab from f;

  r := pg_temp.try_as('anon', null, 'select public.get_app_encryption_key(''driver_pii_key'')');
  if r not like 'refused:%permission denied%' then raise exception 'FAIL S1: signed-out caller got %', r; end if;
  raise notice 'OK S1: signed out cannot read the encryption key.';

  r := pg_temp.try_as('authenticated', 'aaaaaaaa-0000-0000-0000-00000000161a', 'select public.get_app_encryption_key(''driver_pii_key'')');
  if r not like 'refused:%permission denied%' then raise exception 'FAIL S2: signed-in owner got %', r; end if;
  r := pg_temp.try_as('service_role', null, 'select public.get_app_encryption_key(''driver_pii_key'')');
  if r not like 'refused:%permission denied%' then raise exception 'FAIL S2: service_role got %', r; end if;
  raise notice 'OK S2: signed-in users and service_role cannot read the encryption key.';

  r := pg_temp.try_as('authenticated', 'aaaaaaaa-0000-0000-0000-00000000161a', 'select public.zz_test_0161_nested_key()');
  if r not like 'allowed:____' then raise exception 'FAIL S3: definer caller could not reach the key: %', r; end if;
  raise notice 'OK S3: SECURITY DEFINER callers (reveal/set PII, QuickBooks) still reach the key.';

  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prosecdef and p.prorettype <> 'trigger'::regtype
    and p.proname not in ('current_org_id', 'current_role', 'has_role', 'is_platform_admin',
                          'carrier_ids_authorized_for_current_user', 'carrier_ids_selectable_for_new_records')
    and has_function_privilege('anon', p.oid, 'execute');
  if v_bad is not null then raise exception 'FAIL S4: still executable signed out: %', v_bad; end if;
  raise notice 'OK S4: signed out can execute no SECURITY DEFINER function except the RLS identity helpers.';

  if has_function_privilege('authenticated', 'public.verify_driver_portal_login(text,text)'::regprocedure, 'execute')
     or has_function_privilege('authenticated', 'public.refresh_compliance_statuses()'::regprocedure, 'execute')
     or has_function_privilege('authenticated', 'public.sync_time_based_exceptions()'::regprocedure, 'execute')
     or exists (select 1 from pg_proc where proname = 'submit_driver_application' and has_function_privilege('authenticated', oid, 'execute')) then
    raise exception 'FAIL S5: a server-only function is still callable by signed-in users';
  end if;
  if not has_function_privilege('service_role', 'public.verify_driver_portal_login(text,text)'::regprocedure, 'execute')
     or not exists (select 1 from pg_proc where proname = 'submit_driver_application' and has_function_privilege('service_role', oid, 'execute')) then
    raise exception 'FAIL S5: service_role lost a function the app server calls';
  end if;
  raise notice 'OK S5: server-only functions refused to users; the app server (service_role) keeps driver login + applications.';

  -- D1: owner of org B targets org A's settlement
  r := pg_temp.try_as('authenticated', 'bbbbbbbb-0000-0000-0000-00000000161b', format('select public.deduct_pending_advances_into_settlement(%L)::text', sa));
  if r not like 'refused:%not found%' then raise exception 'FAIL D1: cross-org deduction %', r; end if;
  if (select count(*) from public.settlement_line_items where settlement_id = sa) <> 0
     or (select status::text from public.dispatch_advances where id = aa) <> 'pending' then
    raise exception 'FAIL D1: cross-org call wrote data';
  end if;
  r := pg_temp.try_as('anon', null, format('select public.deduct_pending_advances_into_settlement(%L)::text', sa));
  if r not like 'refused:%permission denied%' then raise exception 'FAIL D1: signed-out deduction %', r; end if;
  raise notice 'OK D1: another organization (or a signed-out caller) cannot add deductions; nothing written.';

  r := pg_temp.try_as('authenticated', 'dddddddd-0000-0000-0000-00000000161d', format('select public.deduct_pending_advances_into_settlement(%L)::text', sa));
  if r not like 'refused:%permission%' then raise exception 'FAIL D2: viewer deduction %', r; end if;
  raise notice 'OK D2: a viewer cannot deduct advances.';

  r := pg_temp.try_as('authenticated', 'cccccccc-0000-0000-0000-00000000161c', format('select public.deduct_pending_advances_into_settlement(%L)::text', sa));
  if r <> 'allowed:1' then raise exception 'FAIL D3: own-org dispatcher deduction %', r; end if;
  if (select count(*) from public.settlement_line_items where settlement_id = sa and item_type = 'deduction' and amount = 150) <> 1
     or (select status::text from public.dispatch_advances where id = aa) <> 'deducted'
     or (select status::text from public.dispatch_advances where id = ab) <> 'pending' then
    raise exception 'FAIL D3: deduction result wrong';
  end if;
  raise notice 'OK D3: own-org dispatcher deduction works exactly as before (org B untouched).';

  raise notice 'ALL 0161 CHECKS PASSED';
end $$;

rollback;
