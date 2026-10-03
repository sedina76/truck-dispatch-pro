-- =============================================================================
-- TEST_0169_carrier_factor_package_sender.sql -- PRODUCTION TWIN ONLY. Ends in ROLLBACK.
--   P1  default: we send the paperwork
--   P2  a dispatcher cannot change it; nobody can update the column directly
--   P3  an accountant (and owner/admin) can, through the setting
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;
insert into auth.users (id, email, aud, role) values
 ('16900000-0000-0000-0000-00000000000a', 'o169@test.invalid', 'authenticated', 'authenticated'),
 ('16900000-0000-0000-0000-00000000000c', 'a169@test.invalid', 'authenticated', 'authenticated'),
 ('16900000-0000-0000-0000-00000000000d', 'd169@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"16900000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T169 Org', 't169-org') is not null; reset role;
select id as org from public.organizations where slug = 't169-org' \gset
set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = :'org', role = 'accountant' where id = '16900000-0000-0000-0000-00000000000c';
update public.profiles set organization_id = :'org', role = 'dispatcher' where id = '16900000-0000-0000-0000-00000000000d';
set local app.bypass_profile_guard = 'false';
insert into public.carriers (id, organization_id, legal_name) values ('16900000-0000-0000-0000-0000000000c1', :'org', 'Paper Carrier');

create or replace function pg_temp.as_user(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql into v;
    execute 'reset role';
    return 'ok:' || coalesce(v, '');
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $$;

do $$
declare r text; c uuid := '16900000-0000-0000-0000-0000000000c1';
begin
  if (select factor_package_sent_by from public.carriers where id = c) <> 'dispatcher' then raise exception 'FAIL P1'; end if;
  r := pg_temp.as_user('16900000-0000-0000-0000-00000000000a', format($q$select factor_package_sent_by from public.carriers where id = %L$q$, c));
  if r <> 'ok:dispatcher' then raise exception 'FAIL P1 read: %', r; end if;
  raise notice 'OK P1: default is "we send the paperwork" (readable by staff).';

  r := pg_temp.as_user('16900000-0000-0000-0000-00000000000d', format($q$select public.set_carrier_factor_package_sender(%L, 'carrier')::text$q$, c));
  if r not like 'err:%owner, admin or accountant%' then raise exception 'FAIL P2 dispatcher: %', r; end if;
  r := pg_temp.as_user('16900000-0000-0000-0000-00000000000a', format($q$update public.carriers set factor_package_sent_by = 'carrier' where id = %L returning 1$q$, c));
  if r not like 'err:%Who sends the paperwork%' and r not like 'err:permission denied%' then raise exception 'FAIL P2 direct: %', r; end if;
  raise notice 'OK P2: a dispatcher cannot change it; no direct update.';

  r := pg_temp.as_user('16900000-0000-0000-0000-00000000000c', format($q$select public.set_carrier_factor_package_sender(%L, 'carrier')::text$q$, c));
  if r not like 'ok:%' or (select factor_package_sent_by from public.carriers where id = c) <> 'carrier' then raise exception 'FAIL P3: %', r; end if;
  raise notice 'OK P3: an accountant switched it to "the carrier sends it".';
end $$;

do $$ begin raise notice 'ALL 0169 CHECKS PASSED'; end $$;
rollback;
