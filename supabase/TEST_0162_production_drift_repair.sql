-- =============================================================================
-- TEST_0162_production_drift_repair.sql -- PRODUCTION TWIN ONLY
-- (supabase/ci/twin-db.sh builds every migration incl. 0162). NEVER run on a
-- real database. One transaction, ends in ROLLBACK.
--
--   P1  a signed-in owner can save and reveal a driver SSN (pgcrypto found)
--   D1  a dispatcher creates a dispatch on own load (works despite 0135)
--   D2  another company's owner gets "load could not be found"; nothing written
--   D3  own load + another company's carrier/driver/truck is refused
--   N1  quick note: dispatcher reads + upserts dispatch_internal_notes (RLS)
--   S1  profile share refuses a document type outside the allowlist
--   M1  mileage columns exist; dispatches.notes does not
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values
 ('aaaaaaaa-0000-0000-0000-00000000162a', 'a162@test.invalid', 'authenticated', 'authenticated'),
 ('bbbbbbbb-0000-0000-0000-00000000162b', 'b162@test.invalid', 'authenticated', 'authenticated'),
 ('cccccccc-0000-0000-0000-00000000162c', 'd162@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000162a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T162 Org A', 't162-org-a'); reset role;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000162b","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T162 Org B', 't162-org-b'); reset role;
set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = (select id from public.organizations where slug = 't162-org-a'), role = 'dispatcher'
 where id = 'cccccccc-0000-0000-0000-00000000162c';
set local app.bypass_profile_guard = 'false';

create temp table f as select (select id from public.organizations where slug = 't162-org-a') a, (select id from public.organizations where slug = 't162-org-b') b;
grant select on f to authenticated;
-- each org: carrier, driver, truck, booked load (superuser fixture)
insert into public.carriers (id, organization_id, legal_name) select '0162a000-0000-0000-0000-000000000001', a, 'A Carrier' from f;
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) select '0162a000-0000-0000-0000-000000000002', a, '0162a000-0000-0000-0000-000000000001', 'Al', 'A' from f;
insert into public.trucks (id, organization_id, carrier_id, unit_number) select '0162a000-0000-0000-0000-000000000003', a, '0162a000-0000-0000-0000-000000000001', 'A-1' from f;
insert into public.loads (id, organization_id, load_number, status, carrier_id) select '0162a000-0000-0000-0000-000000000004', a, 'T162-A-1', 'booked', '0162a000-0000-0000-0000-000000000001' from f;
insert into public.load_financials (load_id, organization_id, rate) select '0162a000-0000-0000-0000-000000000004', a, 7500 from f;
insert into public.carriers (id, organization_id, legal_name) select '0162b000-0000-0000-0000-000000000001', b, 'B Carrier' from f;
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) select '0162b000-0000-0000-0000-000000000002', b, '0162b000-0000-0000-0000-000000000001', 'Bo', 'B' from f;
insert into public.trucks (id, organization_id, carrier_id, unit_number) select '0162b000-0000-0000-0000-000000000003', b, '0162b000-0000-0000-0000-000000000001', 'B-1' from f;
insert into public.loads (id, organization_id, load_number, status, carrier_id) select '0162b000-0000-0000-0000-000000000004', b, 'T162-B-1', 'booked', '0162b000-0000-0000-0000-000000000001' from f;
insert into public.load_financials (load_id, organization_id, rate) select '0162b000-0000-0000-0000-000000000004', b, 1000 from f;

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
declare r text; v_disp uuid;
begin
  -- P1
  r := pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000162a', $q$select public.set_driver_pii('0162a000-0000-0000-0000-000000000002', 'ssn', '123-45-6789')::text$q$);
  if r not like 'ok:%' then raise exception 'FAIL P1 set: %', r; end if;
  r := pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000162a', $q$select public.reveal_driver_pii('0162a000-0000-0000-0000-000000000002', 'ssn', 'test')$q$);
  if r <> 'ok:123-45-6789' then raise exception 'FAIL P1 reveal: %', r; end if;
  raise notice 'OK P1: driver SSN saves and reveals (pgcrypto reachable).';

  -- D2 first (load must still be undispatched)
  r := pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000162b', $q$select public.create_dispatch('0162a000-0000-0000-0000-000000000004', '0162a000-0000-0000-0000-000000000001', '0162a000-0000-0000-0000-000000000003', '0162a000-0000-0000-0000-000000000002', null, 10, null)::text$q$);
  if r not like 'err:That load could not be found.%' then raise exception 'FAIL D2: cross-company dispatch: %', r; end if;
  if exists (select 1 from public.dispatches where load_id = '0162a000-0000-0000-0000-000000000004') then raise exception 'FAIL D2: a dispatch was written'; end if;
  raise notice 'OK D2: another company cannot dispatch this load ("not found"); nothing written.';

  -- D3: own load, other company's equipment
  r := pg_temp.as_user('cccccccc-0000-0000-0000-00000000162c', $q$select public.create_dispatch('0162a000-0000-0000-0000-000000000004', '0162b000-0000-0000-0000-000000000001', '0162b000-0000-0000-0000-000000000003', '0162b000-0000-0000-0000-000000000002', null, 10, null)::text$q$);
  if r not like 'err:%' then raise exception 'FAIL D3: foreign carrier/driver/truck accepted'; end if;
  raise notice 'OK D3: another company''s carrier/driver/truck is refused (%).', left(r, 80);

  -- D1
  r := pg_temp.as_user('cccccccc-0000-0000-0000-00000000162c', $q$select public.create_dispatch('0162a000-0000-0000-0000-000000000004', '0162a000-0000-0000-0000-000000000001', '0162a000-0000-0000-0000-000000000003', '0162a000-0000-0000-0000-000000000002', null, 10, 'first note')::text$q$);
  if r not like 'ok:%' then raise exception 'FAIL D1: own dispatch: %', r; end if;
  v_disp := substr(r, 4)::uuid;
  if (select status::text from public.loads where id = '0162a000-0000-0000-0000-000000000004') <> 'dispatched' then raise exception 'FAIL D1: load not dispatched'; end if;
  raise notice 'OK D1: dispatcher creates a dispatch on own load; load is dispatched.';

  -- N1: the app's quick-note path (read, then upsert on dispatch_id)
  r := pg_temp.as_user('cccccccc-0000-0000-0000-00000000162c', format($q$select notes from public.dispatch_internal_notes where dispatch_id = %L$q$, v_disp));
  if r <> 'ok:first note' then raise exception 'FAIL N1 read: %', r; end if;
  r := pg_temp.as_user('cccccccc-0000-0000-0000-00000000162c', format($q$insert into public.dispatch_internal_notes (dispatch_id, organization_id, notes) values (%L, %L, 'first note' || chr(10) || '[t] second') on conflict (dispatch_id) do update set notes = excluded.notes returning notes$q$, v_disp, (select a from f)));
  if r not like 'ok:first note%second' then raise exception 'FAIL N1 upsert: %', r; end if;
  r := pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000162b', format($q$select count(*)::text from public.dispatch_internal_notes where dispatch_id = %L$q$, v_disp));
  if r <> 'ok:0' then raise exception 'FAIL N1: other company sees the notes: %', r; end if;
  raise notice 'OK N1: quick note reads/appends via dispatch_internal_notes; other companies cannot see it.';

  -- S1
  if position('not eligible for external profile sharing' in (select prosrc from pg_proc where oid = 'public.guard_profile_share_org()'::regprocedure)) = 0 then
    raise exception 'FAIL S1: profile-share allowlist missing';
  end if;
  raise notice 'OK S1: profile share allowlist (0043) in place.';

  -- M1
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'loads'
      and column_name in ('route_miles', 'route_miles_calculated_at', 'actual_miles', 'actual_miles_recorded_at')) <> 4
     or exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'dispatches' and column_name = 'notes') then
    raise exception 'FAIL M1';
  end if;
  raise notice 'OK M1: mileage columns present; dispatches.notes absent.';
  raise notice 'ALL 0162 CHECKS PASSED';
end $$;
rollback;
