-- =============================================================================
-- fixture_0151.sql -- PROPOSAL 0151 disposable-database script.
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY. Run through tests.py only (it substitutes the fixture marker below).
-- Runs on the REAL 0130..0147 + 0149 + 0150 chain; ONE transaction that ENDS IN ROLLBACK.
-- =============================================================================
-- ---- extra fixture (users, loads, resources, helpers) ------------------------------------------------
insert into auth.users (id) select td0149_t.id(n) from unnest(array['u_owner1','u_admin1','u_driver1','u_viewer1','u_owner2','u_disp1b']) n;
insert into public.profiles (id, organization_id, full_name, email, role) values
  (td0149_t.id('u_owner1'),  td0149_t.id('o1'), 'Olive Owner',   'owner1@example.invalid',  'owner'),
  (td0149_t.id('u_admin1'),  td0149_t.id('o1'), 'Adam Admin',    'admin1@example.invalid',  'admin'),
  (td0149_t.id('u_disp1b'),  td0149_t.id('o1'), 'Dora Dispatch', 'disp1b@example.invalid',  'dispatcher'),
  (td0149_t.id('u_driver1'), td0149_t.id('o1'), 'Dave Driver',   'driver1@example.invalid', 'driver'),
  (td0149_t.id('u_viewer1'), td0149_t.id('o1'), 'Vic Viewer',    'viewer1@example.invalid', 'viewer'),
  (td0149_t.id('u_owner2'),  td0149_t.id('o2'), 'Orin Otherorg', 'owner2@example.invalid',  'owner');
insert into public.loads (id, organization_id, load_number, status)
  select td0149_t.id('f' || g), td0149_t.id('o1'), 'LD-F' || (1000 + g), 'booked' from generate_series(1, 40) g;
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  select td0149_t.id('fd' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'F', 'D' || g from generate_series(1, 40) g;
insert into public.trucks (id, organization_id, carrier_id, unit_number)
  select td0149_t.id('ft' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'FT-' || g from generate_series(1, 40) g;
insert into public.trailers (id, organization_id, carrier_id, unit_number)
  select td0149_t.id('fr' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'FR-' || g from generate_series(1, 40) g;

insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values (td0149_t.id('fdx2'), td0149_t.id('o2'), td0149_t.id('cx'), 'X', 'X2');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values (td0149_t.id('ftx2'), td0149_t.id('o2'), td0149_t.id('cx'), 'FTX-2');

create table td0149_t.f1 (seq bigserial primary key, tag text, state text, msg text, result jsonb);
grant select, insert on td0149_t.f1 to authenticated;
grant usage on sequence td0149_t.f1_seq_seq to authenticated;

-- tr(): the exact call the app makes; captures SQLSTATE / message / jsonb result under <tag>.
create function td0149_t.tr(p_tag text, p_user text, p_dispatch uuid, p_status public.dispatch_status, p_reason text default null, p_key text default null) returns void
language plpgsql as $$
declare v_state text; v_msg text; v_res jsonb;
begin
  perform set_config('test.current_uid', case when p_user is null then '' else td0149_t.id(p_user)::text end, false);
  begin
    v_res := public.transition_dispatch_status(p_dispatch, p_status, p_reason, p_key);
  exception when others then
    get stacked diagnostics v_state := returned_sqlstate, v_msg := message_text;
  end;
  insert into td0149_t.f1 (tag, state, msg, result) values (p_tag, v_state, v_msg, v_res);
end $$;
grant execute on function td0149_t.tr(text, text, uuid, public.dispatch_status, text, text) to authenticated;

-- mk(): a dispatch through the REAL create_dispatch (org 1, carrier ca, load fN, driver fdN, truck ftN, trailer frN).
create function td0149_t.mk(p_tag text, p_i int) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  v_id := public.create_dispatch(td0149_t.id('f' || p_i), td0149_t.id('ca'), td0149_t.id('ft' || p_i), td0149_t.id('fd' || p_i), td0149_t.id('fr' || p_i), null, null);
  insert into td0149_t.f1 (tag, result) values (p_tag, jsonb_build_object('id', v_id));
  return v_id;
end $$;
grant execute on function td0149_t.mk(text, int) to authenticated;
create function td0149_t.did(p_tag text) returns uuid language sql stable as $$ select (result ->> 'id')::uuid from td0149_t.f1 where tag = p_tag $$;
create function td0149_t.st(p_tag text) returns text language sql stable as $$ select state from td0149_t.f1 where tag = p_tag order by seq desc limit 1 $$;
create function td0149_t.msg(p_tag text) returns text language sql stable as $$ select msg from td0149_t.f1 where tag = p_tag order by seq desc limit 1 $$;
create function td0149_t.res(p_tag text) returns jsonb language sql stable as $$ select result from td0149_t.f1 where tag = p_tag order by seq desc limit 1 $$;
grant execute on function td0149_t.did(text), td0149_t.st(text), td0149_t.msg(text), td0149_t.res(text) to authenticated;
create function td0149_t.n_log(p_dispatch uuid, p_action text) returns bigint language sql stable security definer as $$ select count(*) from public.activity_logs where entity_id = p_dispatch and action = p_action $$;
create function td0149_t.n_led(p_dispatch uuid, p_key text) returns bigint language sql stable security definer as $$ select count(*) from public.dispatch_status_transitions where dispatch_id = p_dispatch and idempotency_key = p_key $$;
grant execute on function td0149_t.n_log(uuid, text), td0149_t.n_led(uuid, text) to authenticated;
