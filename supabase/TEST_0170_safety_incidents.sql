-- =============================================================================
-- TEST_0170_safety_incidents.sql -- PRODUCTION TWIN ONLY. Ends in ROLLBACK.
--   S1  a dispatcher records an incident for the org's own driver/truck/load
--   S2  another organization's driver, truck or load is refused; bad type/cost refused
--   S3  a driver-portal account and other organizations cannot read incidents
--   S4  a viewer cannot add; a dispatcher cannot delete; an owner can
--   S5  the organization and creator cannot be changed
--   S6  photos attach through the documents table (safety_incident / incident_photo)
--   S7  signed-out (anon) has no access
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;
insert into auth.users (id, email, aud, role) values
 ('17000000-0000-0000-0000-00000000000a', 'o170@test.invalid', 'authenticated', 'authenticated'),
 ('17000000-0000-0000-0000-00000000000d', 'd170@test.invalid', 'authenticated', 'authenticated'),
 ('17000000-0000-0000-0000-00000000000e', 'v170@test.invalid', 'authenticated', 'authenticated'),
 ('17000000-0000-0000-0000-00000000000f', 'r170@test.invalid', 'authenticated', 'authenticated'),
 ('17000000-0000-0000-0000-00000000000b', 'x170@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"17000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T170 Org', 't170-org') is not null; reset role;
select set_config('request.jwt.claims', '{"sub":"17000000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T170 Other', 't170-other') is not null; reset role;
select id as org from public.organizations where slug = 't170-org' \gset
select id as other from public.organizations where slug = 't170-other' \gset
set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = :'org', role = 'dispatcher' where id = '17000000-0000-0000-0000-00000000000d';
update public.profiles set organization_id = :'org', role = 'viewer' where id = '17000000-0000-0000-0000-00000000000e';
update public.profiles set organization_id = :'org', role = 'driver' where id = '17000000-0000-0000-0000-00000000000f';
set local app.bypass_profile_guard = 'false';

insert into public.carriers (id, organization_id, legal_name) values
 ('17000000-0000-0000-0000-0000000000c1', :'org', 'Safe Carrier'),
 ('17000000-0000-0000-0000-0000000000c2', :'other', 'Other Carrier');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name, status) values
 ('17000000-0000-0000-0000-0000000000a1', :'org', '17000000-0000-0000-0000-0000000000c1', 'Ann', 'Driver', 'active'),
 ('17000000-0000-0000-0000-0000000000a2', :'other', '17000000-0000-0000-0000-0000000000c2', 'Bob', 'Elsewhere', 'active');
insert into public.trucks (id, organization_id, carrier_id, unit_number, status) values
 ('17000000-0000-0000-0000-0000000000b1', :'org', '17000000-0000-0000-0000-0000000000c1', 'S-1', 'active'),
 ('17000000-0000-0000-0000-0000000000b2', :'other', '17000000-0000-0000-0000-0000000000c2', 'X-1', 'active');
insert into public.loads (id, organization_id, load_number, status) values
 ('17000000-0000-0000-0000-0000000000e1', :'org', 'T170-1', 'booked'),
 ('17000000-0000-0000-0000-0000000000e2', :'other', 'T170-2', 'booked');

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

create temp table t170 (k text primary key, v text);
grant all on t170 to authenticated;

do $$
declare
  r text;
  o uuid := (select id from public.organizations where slug = 't170-org');
  x uuid := (select id from public.organizations where slug = 't170-other');
  disp uuid := '17000000-0000-0000-0000-00000000000d';
  own uuid := '17000000-0000-0000-0000-00000000000a';
  viewer uuid := '17000000-0000-0000-0000-00000000000e';
  drv uuid := '17000000-0000-0000-0000-00000000000f';
  other_owner uuid := '17000000-0000-0000-0000-00000000000b';
  inc uuid;
begin
  -- S1
  r := pg_temp.as_user(disp, format($q$insert into public.safety_incidents (organization_id, incident_type, occurred_on, location, driver_id, truck_id, load_id, description, cost)
       values (%L, 'accident', '2026-10-01', 'I-80 MM 120, Laramie, WY', '17000000-0000-0000-0000-0000000000a1', '17000000-0000-0000-0000-0000000000b1', '17000000-0000-0000-0000-0000000000e1', 'Backed into a pole at the dock', 1250.50) returning id$q$, o));
  if r not like 'ok:%' then raise exception 'FAIL S1: %', r; end if;
  inc := substr(r, 4)::uuid;
  insert into t170 values ('inc', inc::text);
  if (select created_by from public.safety_incidents where id = inc) <> disp then raise exception 'FAIL S1 created_by'; end if;
  if (select status from public.safety_incidents where id = inc) <> 'open' then raise exception 'FAIL S1 status'; end if;
  r := pg_temp.as_user(disp, format($q$update public.safety_incidents set status = 'closed', cost = 900 where id = %L returning status$q$, inc));
  if r <> 'ok:closed' then raise exception 'FAIL S1 update: %', r; end if;
  raise notice 'OK S1: dispatcher recorded and closed an incident for the org''s own driver, truck and load.';

  -- S2
  r := pg_temp.as_user(disp, format($q$insert into public.safety_incidents (organization_id, incident_type, occurred_on, driver_id) values (%L, 'citation', '2026-10-01', '17000000-0000-0000-0000-0000000000a2') returning id$q$, o));
  if r not like 'err:%driver does not belong%' then raise exception 'FAIL S2 driver: %', r; end if;
  r := pg_temp.as_user(disp, format($q$insert into public.safety_incidents (organization_id, incident_type, occurred_on, truck_id) values (%L, 'citation', '2026-10-01', '17000000-0000-0000-0000-0000000000b2') returning id$q$, o));
  if r not like 'err:%truck does not belong%' then raise exception 'FAIL S2 truck: %', r; end if;
  r := pg_temp.as_user(disp, format($q$insert into public.safety_incidents (organization_id, incident_type, occurred_on, load_id) values (%L, 'cargo_claim', '2026-10-01', '17000000-0000-0000-0000-0000000000e2') returning id$q$, o));
  if r not like 'err:%load does not belong%' then raise exception 'FAIL S2 load: %', r; end if;
  r := pg_temp.as_user(disp, format($q$insert into public.safety_incidents (organization_id, incident_type, occurred_on) values (%L, 'speeding', '2026-10-01') returning id$q$, o));
  if r not like 'err:%safety_incidents_type_check%' then raise exception 'FAIL S2 type: %', r; end if;
  r := pg_temp.as_user(disp, format($q$insert into public.safety_incidents (organization_id, incident_type, occurred_on, cost) values (%L, 'citation', '2026-10-01', -5) returning id$q$, o));
  if r not like 'err:%safety_incidents_cost_check%' then raise exception 'FAIL S2 cost: %', r; end if;
  r := pg_temp.as_user(disp, format($q$insert into public.safety_incidents (organization_id, incident_type, occurred_on) values (%L, 'citation', '2026-10-01') returning id$q$, x));
  if r not like 'err:%row-level security%' then raise exception 'FAIL S2 other org: %', r; end if;
  raise notice 'OK S2: other organizations'' driver/truck/load, unknown types and negative costs are refused.';

  -- S3
  r := pg_temp.as_user(drv, 'select count(*)::text from public.safety_incidents');
  if r <> 'ok:0' then raise exception 'FAIL S3 driver sees: %', r; end if;
  r := pg_temp.as_user(other_owner, 'select count(*)::text from public.safety_incidents');
  if r <> 'ok:0' then raise exception 'FAIL S3 other org sees: %', r; end if;
  r := pg_temp.as_user(viewer, 'select count(*)::text from public.safety_incidents');
  if r <> 'ok:1' then raise exception 'FAIL S3 viewer: %', r; end if;
  raise notice 'OK S3: driver-portal accounts and other organizations see nothing; office staff see it.';

  -- S4
  r := pg_temp.as_user(viewer, format($q$insert into public.safety_incidents (organization_id, incident_type, occurred_on) values (%L, 'citation', '2026-10-01') returning id$q$, o));
  if r not like 'err:%row-level security%' then raise exception 'FAIL S4 viewer insert: %', r; end if;
  r := pg_temp.as_user(disp, format($q$with d as (delete from public.safety_incidents where id = %L returning 1) select count(*)::text from d$q$, inc));
  if r <> 'ok:0' then raise exception 'FAIL S4 dispatcher delete: %', r; end if;
  raise notice 'OK S4a: a viewer cannot add; a dispatcher cannot delete.';

  -- S5
  r := pg_temp.as_user(own, format($q$update public.safety_incidents set organization_id = %L where id = %L returning 1$q$, x, inc));
  if r not like 'err:%' then raise exception 'FAIL S5 org move: %', r; end if;
  r := pg_temp.as_user(own, format($q$update public.safety_incidents set created_by = %L where id = %L returning created_by::text$q$, own, inc));
  if r <> 'ok:' || disp then raise exception 'FAIL S5 created_by: %', r; end if;
  raise notice 'OK S5: organization and creator cannot be changed.';

  -- S6
  r := pg_temp.as_user(disp, format($q$insert into public.documents (organization_id, entity_type, entity_id, document_type, file_name, file_path, mime_type)
       values (%L, 'safety_incident', %L, 'incident_photo', 'dent.jpg', %L, 'image/jpeg') returning document_type::text$q$, o, inc, o::text || '/safety/' || inc::text || '/1_dent.jpg'));
  if r <> 'ok:incident_photo' then raise exception 'FAIL S6: %', r; end if;
  raise notice 'OK S6: incident photo recorded in documents.';

  -- S4b: owner deletes
  r := pg_temp.as_user(own, format($q$with d as (delete from public.safety_incidents where id = %L returning 1) select count(*)::text from d$q$, inc));
  if r <> 'ok:1' then raise exception 'FAIL S4 owner delete: %', r; end if;
  raise notice 'OK S4b: an owner can delete.';
end $$;

-- S7
set local role anon;
do $$ begin
  perform 1 from public.safety_incidents;
  raise exception 'FAIL S7: anon could read';
exception when insufficient_privilege then
  raise notice 'OK S7: signed-out users have no access.';
end $$;
reset role;

do $$ begin raise notice 'ALL 0170 CHECKS PASSED'; end $$;
rollback;
