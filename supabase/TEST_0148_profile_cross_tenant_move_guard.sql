-- =============================================================================
-- TEST_0148_profile_cross_tenant_move_guard.sql
--
-- NEVER RUN ON PRODUCTION. Disposable PostgreSQL only: apply migrations
-- 0001..0119 (0120+ are pinned to production data) plus 0148 on top of a
-- Supabase auth/storage stand-in, then run this file. Everything is wrapped
-- in ONE transaction that ENDS IN ROLLBACK.
--
-- Proves:
--   ATTACKS (must be refused)
--     A1  a self-signup owner moves own profile into another org as owner
--     A2  a dispatcher promotes self to owner
--     A3  a dispatcher moves self into another org
--     A4  an org-less (just signed up, no company yet) user sets own org
--     A5  an owner changes the role of a profile in ANOTHER org
--   LEGITIMATE FLOWS (must still work)
--     L1  signup via create_organization_with_owner() (bypass path)
--     L2  owner changes a member's role in own org (Settings -> Users)
--     L3  admin (not owner) changes a member's role in own org
--     L4  any user edits own full_name / phone
-- =============================================================================
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if (select count(*) from public.organizations) > 20 then
    raise exception 'REFUSING: this database has > 20 organizations -- looks like a real database.';
  end if;
end $$;

-- ---- fixtures ---------------------------------------------------------------
insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'owner-a@test.invalid', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'owner-b@test.invalid', 'authenticated', 'authenticated'),
  ('cccccccc-0000-0000-0000-00000000000c', 'disp-a@test.invalid',  'authenticated', 'authenticated'),
  ('dddddddd-0000-0000-0000-00000000000d', 'admin-a@test.invalid', 'authenticated', 'authenticated'),
  ('eeeeeeee-0000-0000-0000-00000000000e', 'orgless@test.invalid', 'authenticated', 'authenticated'),
  ('ffffffff-0000-0000-0000-00000000000f', 'disp-b@test.invalid',  'authenticated', 'authenticated');

-- L1: both owners sign up through the real RPC (exercises the bypass path)
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
select public.create_organization_with_owner('Org A Freight', 'org-a-freight');
reset role;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
select public.create_organization_with_owner('Org B Logistics', 'org-b-logistics');
insert into public.loads (organization_id, load_number) values (public.current_org_id(), 'B-SECRET-LOAD');
reset role;

-- staff placed by the platform (superuser here, standing in for trusted paths)
set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = (select id from public.organizations where slug='org-a-freight'), role='dispatcher'
 where id = 'cccccccc-0000-0000-0000-00000000000c';
update public.profiles set organization_id = (select id from public.organizations where slug='org-a-freight'), role='admin'
 where id = 'dddddddd-0000-0000-0000-00000000000d';
update public.profiles set organization_id = (select id from public.organizations where slug='org-b-logistics'), role='dispatcher'
 where id = 'ffffffff-0000-0000-0000-00000000000f';
set local app.bypass_profile_guard = 'false';

create temp table ids as
select (select id from public.organizations where slug='org-a-freight')   as org_a,
       (select id from public.organizations where slug='org-b-logistics') as org_b;
grant select on ids to authenticated;

do $$
declare a uuid; b uuid;
begin
  select org_a, org_b into a, b from ids;
  if a is null or b is null then raise exception 'FAIL L1: signup did not create both orgs'; end if;
  if (select role::text from public.profiles where id='aaaaaaaa-0000-0000-0000-00000000000a') <> 'owner'
     or (select organization_id from public.profiles where id='aaaaaaaa-0000-0000-0000-00000000000a') <> a then
    raise exception 'FAIL L1: signup did not make A owner of org A';
  end if;
  raise notice 'OK L1: signup via create_organization_with_owner() still works (bypass path intact).';
end $$;

-- helper: run a statement as a user and report whether it was refused
create or replace function pg_temp.try_as(p_user uuid, p_sql text) returns text
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
    execute 'reset role';
    return 'allowed';
  exception when insufficient_privilege then
    execute 'reset role';
    return 'refused';
  end;
end $$;

do $$
declare a uuid; b uuid; r text; n int;
begin
  select org_a, org_b into a, b from ids;

  -- A1: the takeover
  r := pg_temp.try_as('aaaaaaaa-0000-0000-0000-00000000000a',
       format('update public.profiles set organization_id = %L, role = ''owner'' where id = auth.uid()', b));
  if r <> 'refused' then raise exception 'FAIL A1: owner of org A moved into org B (takeover still possible)'; end if;
  if (select organization_id from public.profiles where id='aaaaaaaa-0000-0000-0000-00000000000a') <> a then
    raise exception 'FAIL A1: A''s organization changed';
  end if;
  raise notice 'OK A1: self-signup owner can NOT move into another organization.';

  -- A1 follow-up: A still cannot see B's data
  perform set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
  execute 'set local role authenticated';
  select count(*) into n from public.loads where load_number = 'B-SECRET-LOAD';
  execute 'reset role';
  if n <> 0 then raise exception 'FAIL A1: A can see org B loads'; end if;
  raise notice 'OK A1: org A owner still sees 0 of org B''s loads.';

  -- A2: dispatcher self-promotion
  r := pg_temp.try_as('cccccccc-0000-0000-0000-00000000000c',
       'update public.profiles set role = ''owner'' where id = auth.uid()');
  if r <> 'refused' then raise exception 'FAIL A2: dispatcher promoted self to owner'; end if;
  raise notice 'OK A2: dispatcher can NOT promote self.';

  -- A3: dispatcher moves self
  r := pg_temp.try_as('cccccccc-0000-0000-0000-00000000000c',
       format('update public.profiles set organization_id = %L where id = auth.uid()', b));
  if r <> 'refused' then raise exception 'FAIL A3: dispatcher moved self into org B'; end if;
  raise notice 'OK A3: dispatcher can NOT move into another organization.';

  -- A4: org-less user claims an org
  r := pg_temp.try_as('eeeeeeee-0000-0000-0000-00000000000e',
       format('update public.profiles set organization_id = %L, role = ''owner'' where id = auth.uid()', b));
  if r <> 'refused' then raise exception 'FAIL A4: org-less user joined org B'; end if;
  if (select organization_id from public.profiles where id='eeeeeeee-0000-0000-0000-00000000000e') is not null then
    raise exception 'FAIL A4: org-less user now has an organization';
  end if;
  raise notice 'OK A4: a user with no company can NOT attach themselves to one.';

  -- A5: owner of A changes role of a profile in org B (RLS hides the row: 0 rows)
  perform pg_temp.try_as('aaaaaaaa-0000-0000-0000-00000000000a',
       'update public.profiles set role = ''viewer'' where id = ''ffffffff-0000-0000-0000-00000000000f''');
  if (select role::text from public.profiles where id='ffffffff-0000-0000-0000-00000000000f') <> 'dispatcher' then
    raise exception 'FAIL A5: owner of org A changed a role in org B';
  end if;
  raise notice 'OK A5: owner of org A can NOT change roles in org B.';

  -- L2: owner changes a member's role in own org (Settings -> Users)
  r := pg_temp.try_as('aaaaaaaa-0000-0000-0000-00000000000a',
       'update public.profiles set role = ''accountant'' where id = ''cccccccc-0000-0000-0000-00000000000c''');
  if r <> 'allowed' or (select role::text from public.profiles where id='cccccccc-0000-0000-0000-00000000000c') <> 'accountant' then
    raise exception 'FAIL L2: owner could not change a member role in own org (r=%)', r;
  end if;
  raise notice 'OK L2: owner can still change roles in own organization.';

  -- L3: admin (not owner) changes a member's role in own org
  r := pg_temp.try_as('dddddddd-0000-0000-0000-00000000000d',
       'update public.profiles set role = ''dispatcher'' where id = ''cccccccc-0000-0000-0000-00000000000c''');
  if r <> 'allowed' or (select role::text from public.profiles where id='cccccccc-0000-0000-0000-00000000000c') <> 'dispatcher' then
    raise exception 'FAIL L3: admin could not change a member role in own org (r=%)', r;
  end if;
  raise notice 'OK L3: admin can still change roles in own organization.';

  -- L4: ordinary self-edit of non-privileged columns
  r := pg_temp.try_as('cccccccc-0000-0000-0000-00000000000c',
       'update public.profiles set full_name = ''Disp A Renamed'', phone = ''555-0100'' where id = auth.uid()');
  if r <> 'allowed' or (select full_name from public.profiles where id='cccccccc-0000-0000-0000-00000000000c') <> 'Disp A Renamed' then
    raise exception 'FAIL L4: user could not edit own name/phone (r=%)', r;
  end if;
  raise notice 'OK L4: users can still edit their own name and phone.';
end $$;

\echo '################  TEST 0148 PASSED  ################'
rollback;
