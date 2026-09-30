-- =============================================================================
-- regression.sql -- PROPOSAL 0149 functional regression suite.
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY.
-- Run through tests.py only, against the REPAIRED (post-0149) functions.
-- One transaction that ENDS IN ROLLBACK; it creates and mutates fixture rows.
-- =============================================================================
-- BEGIN_GUARD
do $g$
begin
  if coalesce(current_setting('app.zzz_0149_test', true), '') <> 'scratch-ok' then
    raise exception 'TEST_0149 refused: set app.zzz_0149_test = ''scratch-ok'' -- and ONLY on the disposable cluster tests.py creates.';
  end if;
  if inet_server_addr() is not null
     or current_setting('listen_addresses') <> ''
     or current_user <> 'postgres'
     or current_database() !~ '^td0149_'
     or current_setting('port') <> '55491'
     or current_setting('data_directory') !~ '^/private/tmp/td0149-local-[A-Za-z0-9_]+/data$'
     or current_setting('unix_socket_directories') <> regexp_replace(current_setting('data_directory'), '/data$', '/socket')
  then
    raise exception 'TEST_0149 refused: not the disposable local td0149 cluster (never run this against Supabase/production).';
  end if;
end
$g$;
-- END_GUARD
\set ON_ERROR_STOP on
begin;
set client_min_messages = notice;

-- The suite asserts the REPAIRED shape first: if the defect is still present it must not pass.
do $t$
begin
  assert position('c_active constant public.dispatch_status[]' in pg_get_functiondef('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure)) > 0, 'create_dispatch is not the repaired definition';
  assert position('c_active constant public.dispatch_status[]' in pg_get_functiondef('public.cancel_dispatch(uuid,text)'::regprocedure)) > 0, 'cancel_dispatch is not the repaired definition';
  raise notice 'OK: T0 both functions carry the repaired enum-typed c_active';
end $t$;

create table td0149_t.snaps (tag text primary key, snap text not null);
create function td0149_t.snapshot(p_load uuid) returns text language sql stable as $$
  select (select count(*) from public.dispatches)::text || '|' || (select count(*) from public.dispatch_financials)::text
      || '|' || (select count(*) from public.dispatch_internal_notes)::text || '|' || (select count(*) from public.activity_logs)::text
      || '|' || (select concat_ws(',', l.status::text, coalesce(l.carrier_id::text, '-'), coalesce(l.carrier_resolution::text, '-'), coalesce(l.financial_dispatch_id::text, '-'))
                 from public.loads l where l.id = p_load) $$;

-- ============================ T1: successful create ==========================
set role authenticated;
select td0149_t.run_create('T1', 'u_disp1', td0149_t.id('l1'), td0149_t.id('ca'), td0149_t.id('ta1'), td0149_t.id('da1'), td0149_t.id('ra1'), 12.5, 'first note');
select td0149_t.run_create('T1b', 'u_disp1', td0149_t.id('l15'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'), null, null, '   ');
reset role;
do $t$
declare r td0149_t.results; d public.dispatches; l public.loads; n int;
begin
  select * into r from td0149_t.results where tag = 'T1';
  assert r.state is null and r.new_id is not null, format('T1: create failed: %s %s', r.state, r.msg);
  select * into d from public.dispatches where id = r.new_id;
  assert d.status = 'assigned' and d.carrier_id = td0149_t.id('ca') and d.driver_id = td0149_t.id('da1')
     and d.truck_id = td0149_t.id('ta1') and d.trailer_id = td0149_t.id('ra1') and d.organization_id = td0149_t.id('o1'), 'T1: dispatch row wrong';
  assert (select dispatch_fee_percentage from public.dispatch_financials where dispatch_id = r.new_id) = 12.5, 'T1: fee not stored';
  assert (select notes from public.dispatch_internal_notes where dispatch_id = r.new_id) = 'first note', 'T1: notes not stored';
  select * into l from public.loads where id = td0149_t.id('l1');
  assert l.status = 'dispatched', 'T1: load.status must become dispatched (got ' || l.status || ')';
  assert l.carrier_id = td0149_t.id('ca') and l.carrier_resolution = 'resolved', 'T1: 0132 first-dispatch carrier claim missing';
  assert l.financial_dispatch_id = r.new_id, 'T1: 0125 financial controller not assigned';
  select count(*) into n from public.activity_logs where entity_id = r.new_id and action = 'created';
  assert n = 1, 'T1: expected exactly one created audit row';
  raise notice 'OK: T1 create_dispatch succeeds: dispatch + financials + notes + load=dispatched + carrier claim + audit, all present';

  select * into r from td0149_t.results where tag = 'T1b';
  assert r.state is null and r.new_id is not null, 'T1b: create failed';
  assert (select dispatch_fee_percentage from public.dispatch_financials where dispatch_id = r.new_id) = 10, 'T1b: default fee must be 10';
  assert not exists (select 1 from public.dispatch_internal_notes where dispatch_id = r.new_id), 'T1b: blank notes must not create a notes row';
  raise notice 'OK: T1b null fee defaults to 10; blank notes create no notes row';
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  perform td0149_t.try_cancel(r.new_id, 'cleanup T1b');
end $t$;

-- ============================ T2: cancel (Dispatch Board path) ==============
-- The board/app path is transition_dispatch_status(..., 'cancelled') (0134, SECURITY DEFINER), which delegates to
-- cancel_dispatch(); it runs cancel_dispatch with the function owner's privileges.
set role authenticated;
select td0149_t.run_transition('T2', 'u_disp1', (select new_id from td0149_t.results where tag = 'T1'), 'cancelled', 'no longer needed');
select td0149_t.run_transition('T2again', 'u_disp1', (select new_id from td0149_t.results where tag = 'T1'), 'cancelled', 'again');
reset role;
do $t$
declare r td0149_t.results; did uuid := (select new_id from td0149_t.results where tag = 'T1'); n int;
begin
  select * into r from td0149_t.results where tag = 'T2';
  assert r.state is null, format('T2: cancel failed: %s %s', r.state, r.msg);
  assert (select status from public.dispatches where id = did) = 'cancelled', 'T2: dispatch not cancelled';
  assert (select cancelled_at from public.dispatches where id = did) is not null, 'T2: cancelled_at not set';
  assert (select notes from public.dispatches where id = did) like '%[Cancelled: no longer needed]%', 'T2: cancel note not appended';
  assert (select status from public.loads where id = td0149_t.id('l1')) = 'booked', 'T2: load must return to booked';
  assert (select financial_dispatch_id from public.loads where id = td0149_t.id('l1')) = did, 'T2: financial_dispatch_id must be preserved';
  assert exists (select 1 from public.dispatch_financials where dispatch_id = did), 'T2: financials must remain (history)';
  select count(*) into n from public.activity_logs where entity_id = did and action = 'cancelled';
  assert n = 1, 'T2: expected exactly one cancelled audit row (second cancel is a no-op)';
  select * into r from td0149_t.results where tag = 'T2again';
  assert r.state is null, 'T2: second cancel must be an idempotent no-op';
  raise notice 'OK: T2 cancel via transition_dispatch_status -> cancel_dispatch succeeds, load returns to booked, idempotent, history preserved';
end $t$;

-- T2c CHARACTERIZATION (pre-existing, NOT changed or fixed by 0149): cancel_dispatch() is SECURITY INVOKER, and 0135
-- left `authenticated` with UPDATE on dispatches.notes ONLY -- so a DIRECT authenticated call to the RPC (which is what
-- the app's cancelDispatch server action does) is refused by the column-privilege check before it ever reaches the
-- repaired comparison. This test pins that behaviour so 0149 provably neither causes nor hides it.
set role authenticated;
select td0149_t.run_create('T2c_setup', 'u_disp1', td0149_t.id('l17'), td0149_t.id('ca'), td0149_t.id('ta1'), td0149_t.id('da1'));
select td0149_t.run_cancel('T2c', 'u_disp1', (select new_id from td0149_t.results where tag = 'T2c_setup'), 'direct rpc');
reset role;
do $t$
declare d uuid := (select new_id from td0149_t.results where tag = 'T2c_setup');
begin
  assert d is not null, 'T2c: setup create failed';
  assert (select state from td0149_t.results where tag = 'T2c') = '42501', format('T2c: expected the pre-existing 42501 privilege refusal, got %s / %s',
    (select state from td0149_t.results where tag = 'T2c'), (select msg from td0149_t.results where tag = 'T2c'));
  assert (select status from public.dispatches where id = d) = 'assigned', 'T2c: refused cancel must leave the dispatch untouched';
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  perform td0149_t.try_cancel(d, 'cleanup T2c');
  assert (select status from public.dispatches where id = d) = 'cancelled', 'T2c: owner-context cancel_dispatch must work';
  raise notice 'OK: T2c direct authenticated cancel_dispatch is refused by the pre-existing 0135 column lockdown (42501) -- unchanged by 0149; owner-context cancel works';
end $t$;

-- T2b: cancel while ANOTHER active dispatch still holds the load -> load stays dispatched
-- (this is the load-revert `NOT EXISTS ... d.status = any(c_active)` site with a TRUE match).
set role authenticated;
select td0149_t.run_create('T2b', 'u_disp1', td0149_t.id('l2'), td0149_t.id('ca'), td0149_t.id('ta1'), td0149_t.id('da1'));
reset role;
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values (td0149_t.id('d2b'), td0149_t.id('o1'), td0149_t.id('l2'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'), 'assigned');
set role authenticated;
select td0149_t.run_transition('T2b_c1', 'u_disp1', (select new_id from td0149_t.results where tag = 'T2b'), 'cancelled', 'first');
reset role;
do $t$
begin
  assert (select state from td0149_t.results where tag = 'T2b_c1') is null, 'T2b: first cancel failed';
  assert (select status from public.loads where id = td0149_t.id('l2')) = 'dispatched', 'T2b: load must stay dispatched while another active dispatch holds it';
  raise notice 'OK: T2b cancel keeps load dispatched while another ACTIVE dispatch holds it (c_active match)';
end $t$;
set role authenticated;
select td0149_t.run_transition('T2b_c2', 'u_disp1', td0149_t.id('d2b'), 'cancelled', 'second');
reset role;
do $t$
begin
  assert (select state from td0149_t.results where tag = 'T2b_c2') is null, 'T2b: second cancel failed';
  assert (select status from public.loads where id = td0149_t.id('l2')) = 'booked', 'T2b: load must return to booked once no active dispatch remains';
  raise notice 'OK: T2b load returns to booked once the last active dispatch is cancelled';
end $t$;

-- ============================ T3-T6: conflicts, every status ================
set role authenticated;
select td0149_t.run_create('T3', 'u_disp1', td0149_t.id('l3'), td0149_t.id('ca'), td0149_t.id('ta1'), td0149_t.id('da1'), td0149_t.id('ra1'));
reset role;
do $t$
declare d3 uuid := (select new_id from td0149_t.results where tag = 'T3'); s text; r record; n int := 0;
begin
  assert d3 is not null, 'T3: setup create failed';
  -- create_dispatch checks load status (TDLND) BEFORE the one-active-dispatch-per-load check (TDDUP), so the
  -- TDDUP branch is only reachable while the load still reads dispatchable: put l3 back to booked.
  update public.loads set status = 'booked' where id = td0149_t.id('l3');
  -- all 7 ACTIVE statuses must hold driver, truck, trailer and the load
  foreach s in array array['assigned','accepted','en_route_to_pickup','at_pickup','loaded','en_route_to_delivery','at_delivery'] loop
    update public.dispatches set status = s::public.dispatch_status where id = d3;
    select * into r from td0149_t.probe_create('u_disp1', td0149_t.id('l4'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da1'));
    assert r.state = 'TDDRV' and r.detail = d3::text and r.msg like '%is already assigned to active load LD-100003%', format('T4[%s]: driver conflict wrong: %s / %s', s, r.state, r.msg);
    select * into r from td0149_t.probe_create('u_disp1', td0149_t.id('l4'), td0149_t.id('ca'), td0149_t.id('ta1'), td0149_t.id('da2'));
    assert r.state = 'TDTRK' and r.detail = d3::text and r.msg like 'Truck TA-1 is already assigned to active load LD-100003.', format('T5[%s]: truck conflict wrong: %s / %s', s, r.state, r.msg);
    select * into r from td0149_t.probe_create('u_disp1', td0149_t.id('l4'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'), td0149_t.id('ra1'));
    assert r.state = 'TDTRL' and r.detail = d3::text and r.msg like 'Trailer RA-1 is already assigned to active load LD-100003.', format('T6[%s]: trailer conflict wrong: %s / %s', s, r.state, r.msg);
    select * into r from td0149_t.probe_create('u_disp1', td0149_t.id('l3'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'));
    assert r.state = 'TDDUP' and r.detail = d3::text, format('T3[%s]: same-load duplicate wrong: %s / %s', s, r.state, r.msg);
    n := n + 1;
  end loop;
  raise notice 'OK: T3/T4/T5/T6 all 7 active statuses raise TDDUP/TDDRV/TDTRK/TDTRL with the conflicting dispatch id in DETAIL (% statuses)', n;
  -- the 3 non-active statuses must NOT conflict
  foreach s in array array['delivered','completed','cancelled'] loop
    update public.dispatches set status = s::public.dispatch_status where id = d3;
    select * into r from td0149_t.probe_create('u_disp1', td0149_t.id('l3'), td0149_t.id('ca'), td0149_t.id('ta1'), td0149_t.id('da1'), td0149_t.id('ra1'));
    assert r.state is null and r.created, format('T3[%s]: a %s dispatch must not block reuse (got %s / %s)', s, s, r.state, r.msg);
  end loop;
  update public.dispatches set status = 'assigned' where id = d3;
  perform td0149_t.probe_create('u_disp1', td0149_t.id('l3'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'));
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  perform td0149_t.try_cancel(d3, 'cleanup T3');
  raise notice 'OK: T3 delivered/completed/cancelled dispatches never block their driver/truck/trailer/load';
end $t$;

-- ============================ T7: 0132 carrier lockdown =====================
set role authenticated;
select td0149_t.run_create('T7a', 'u_disp1', td0149_t.id('l5'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'));
select td0149_t.run_transition('T7b', 'u_disp1', (select new_id from td0149_t.results where tag = 'T7a'), 'cancelled', 'reroute');
reset role;
insert into td0149_t.snaps values ('T7_before', td0149_t.snapshot(td0149_t.id('l5')));
set role authenticated;
select td0149_t.run_create('T7c', 'u_disp1', td0149_t.id('l5'), td0149_t.id('cb'), td0149_t.id('tb1'), td0149_t.id('db1'));
reset role;
insert into td0149_t.snaps values ('T7_after', td0149_t.snapshot(td0149_t.id('l5')));
do $t$
declare r td0149_t.results;
begin
  select * into r from td0149_t.results where tag = 'T7c';
  assert r.state = '23514' and r.msg ~ '^dispatch carrier .+ does not match load .+ carrier .+ -- a conflicting carrier can never coexist', format('T7: carrier mismatch must be rejected by the 0132 guard (got %s / %s)', r.state, r.msg);
  assert (select snap from td0149_t.snaps where tag = 'T7_before') = (select snap from td0149_t.snaps where tag = 'T7_after'), 'T7: rejected carrier mismatch left partial writes';
  raise notice 'OK: T7 carrier mismatch still rejected by guard_dispatch_carrier_scope (23514); no partial writes';
end $t$;

-- T7d/T7e: unresolved carrier / unresolved trailer are still rejected by the 0132 guard.
update public.loads set carrier_resolution = 'unresolved' where id = td0149_t.id('l6');
set role authenticated;
select td0149_t.run_create('T7d', 'u_disp1', td0149_t.id('l6'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'));
select td0149_t.run_create('T7e', 'u_disp1', td0149_t.id('l7'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'), td0149_t.id('r_unres'));
reset role;
do $t$
declare r td0149_t.results;
begin
  select * into r from td0149_t.results where tag = 'T7d';
  assert r.state = '23514' and r.msg like '%has an unresolved carrier%', format('T7d: got %s / %s', r.state, r.msg);
  select * into r from td0149_t.results where tag = 'T7e';
  assert r.state = '23514' and r.msg like '%has unresolved ownership%', format('T7e: got %s / %s', r.state, r.msg);
  raise notice 'OK: T7d/T7e unresolved-carrier and unresolved-trailer guards still reject';
end $t$;

-- ============================ T8: authorization / tenant isolation ==========
insert into td0149_t.snaps values ('T8_before_o1', td0149_t.snapshot(td0149_t.id('l7'))), ('T8_before_o2', td0149_t.snapshot(td0149_t.id('l_o2')));
set role authenticated;
select td0149_t.run_create('T8a', 'u_disp2', td0149_t.id('l7'), td0149_t.id('cx'), td0149_t.id('tx1'), td0149_t.id('dx1'));
select td0149_t.run_create('T8b', 'u_disp2', td0149_t.id('l_o2'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'));
select td0149_t.run_create('T8c', 'u_disp2', td0149_t.id('l_o2'), td0149_t.id('cx'), td0149_t.id('ta3'), td0149_t.id('dx1'));
select td0149_t.run_create('T8d', 'u_acct1', td0149_t.id('l7'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'));
select td0149_t.run_create('T8e', null, td0149_t.id('l7'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'));
select td0149_t.run_create('T8f', 'u_disp1', td0149_t.id('l_delivered'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'));
reset role;
insert into td0149_t.snaps values ('T8_after_o1', td0149_t.snapshot(td0149_t.id('l7'))), ('T8_after_o2', td0149_t.snapshot(td0149_t.id('l_o2')));
do $t$
declare r td0149_t.results;
begin
  select * into r from td0149_t.results where tag = 'T8a';
  assert r.state = 'TDLNF', format('T8a: another org''s load must be TDLNF (got %s / %s)', r.state, r.msg);
  select * into r from td0149_t.results where tag = 'T8b';
  assert (r.state = '23514' and r.msg like 'loads.carrier_id % org % <> load org %') or (r.state = 'P0001' and r.msg like '%must belong to the same organization%'),
    format('T8b: cross-org carrier must be rejected by the org guards (got %s / %s)', r.state, r.msg);
  raise notice 'INFO: T8b cross-org carrier was rejected by: % / %', r.state, left(r.msg, 60);
  select * into r from td0149_t.results where tag = 'T8c';
  assert r.state = 'P0001' and r.msg like '%must belong to the same organization%', format('T8c: cross-org truck must be rejected (got %s / %s)', r.state, r.msg);
  select * into r from td0149_t.results where tag = 'T8d';
  assert r.state = 'TDROL', format('T8d: accountant must be TDROL (got %s / %s)', r.state, r.msg);
  select * into r from td0149_t.results where tag = 'T8e';
  assert r.state = 'TDAUT', format('T8e: unauthenticated must be TDAUT (got %s / %s)', r.state, r.msg);
  select * into r from td0149_t.results where tag = 'T8f';
  assert r.state = 'TDLND', format('T8f: delivered load must be TDLND (got %s / %s)', r.state, r.msg);
  assert (select snap from td0149_t.snaps where tag = 'T8_before_o1') = (select snap from td0149_t.snaps where tag = 'T8_after_o1'), 'T8: org1 load changed by rejected calls';
  assert (select snap from td0149_t.snaps where tag = 'T8_before_o2') = (select snap from td0149_t.snaps where tag = 'T8_after_o2'), 'T8: org2 load (incl. 0132 carrier claim) changed by rejected cross-org call';
  raise notice 'OK: T8 cross-organization/role/auth/status rejections intact; rejected calls (even after the 0132 carrier-claim ran) leave nothing behind';
end $t$;

-- ============================ T9: forced downstream failure => full rollback ==
create function td0149_t.inject_fail() returns trigger language plpgsql as $$
begin
  if current_setting('td0149.inject', true) = tg_argv[0] then
    raise exception 'TD0149 injected failure: %', tg_argv[0];
  end if;
  return new;
end $$;
create trigger zz_inject_fin  before insert on public.dispatch_financials    for each row execute function td0149_t.inject_fail('fin');
create trigger zz_inject_note before insert on public.dispatch_internal_notes for each row execute function td0149_t.inject_fail('notes');
create trigger zz_inject_load_dispatched before update on public.loads for each row
  when (new.status = 'dispatched' and old.status is distinct from new.status) execute function td0149_t.inject_fail('load_dispatched');
create trigger zz_inject_load_booked before update on public.loads for each row
  when (new.status = 'booked' and old.status is distinct from new.status) execute function td0149_t.inject_fail('load_booked');
create trigger zz_inject_log_created before insert on public.activity_logs for each row
  when (new.action = 'created') execute function td0149_t.inject_fail('log_created');
create trigger zz_inject_log_cancelled before insert on public.activity_logs for each row
  when (new.action = 'cancelled') execute function td0149_t.inject_fail('log_cancelled');

-- create_dispatch: every write step 7..10 failing must roll back ALL earlier writes; retry then creates exactly one.
do $t$
declare
  pt record; r record; ld uuid; snap_before text; snap_after text; n int; d uuid;
  pts text[][] := array[['fin','l8'],['notes','l9'],['load_dispatched','l10'],['log_created','l11']];
  i int;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  for i in 1 .. array_length(pts, 1) loop
    ld := td0149_t.id(pts[i][2]);
    snap_before := td0149_t.snapshot(ld);
    perform set_config('td0149.inject', pts[i][1], false);
    select * into r from td0149_t.try_create(ld, td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'), td0149_t.id('ra2'), 11, 'inject note');
    assert r.state = 'P0001' and r.msg = 'TD0149 injected failure: ' || pts[i][1], format('T9[%s]: injected failure not surfaced (%s / %s)', pts[i][1], r.state, r.msg);
    snap_after := td0149_t.snapshot(ld);
    assert snap_before = snap_after, format('T9[%s]: PARTIAL WRITES after failure: before=%s after=%s', pts[i][1], snap_before, snap_after);
    assert not exists (select 1 from public.dispatches where load_id = ld), format('T9[%s]: dispatch row survived', pts[i][1]);
    -- retry without the fault: exactly ONE dispatch results
    perform set_config('td0149.inject', '', false);
    select * into r from td0149_t.try_create(ld, td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'), td0149_t.id('ra2'), 11, 'inject note');
    assert r.state is null and r.new_id is not null, format('T9[%s]: retry after failure did not succeed (%s / %s)', pts[i][1], r.state, r.msg);
    select count(*) into n from public.dispatches where load_id = ld;
    assert n = 1, format('T9[%s]: retry must create exactly one dispatch (found %s)', pts[i][1], n);
    assert (select count(*) from public.dispatch_financials where dispatch_id = r.new_id) = 1
       and (select count(*) from public.activity_logs where entity_id = r.new_id and action = 'created') = 1, format('T9[%s]: duplicate financials/audit rows', pts[i][1]);
    -- free the resources for the next round
    perform td0149_t.try_cancel(r.new_id, 'cleanup');
    raise notice 'OK: T9 create_dispatch failure at [%] rolls back every write (dispatch, financials, notes, load status, carrier claim, financial controller, audit); retry creates exactly one dispatch', pts[i][1];
  end loop;
end $t$;

-- cancel_dispatch: failure at the load revert (mid) and at the final audit row must roll back the dispatch update too.
do $t$
declare r record; d uuid; ld uuid := td0149_t.id('l12'); before_d text; after_d text; pt text; snap_b text; snap_a text;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  select * into r from td0149_t.try_create(ld, td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'), null, null, null);
  assert r.state is null, 'T9c: setup create failed';
  d := r.new_id;
  foreach pt in array array['load_booked', 'log_cancelled'] loop
    select status::text || '|' || coalesce(notes, '') || '|' || coalesce(cancelled_at::text, '-') into before_d from public.dispatches where id = d;
    snap_b := td0149_t.snapshot(ld);
    perform set_config('td0149.inject', pt, false);
    select * into r from td0149_t.try_cancel(d, 'will fail');
    assert r.state = 'P0001' and r.msg = 'TD0149 injected failure: ' || pt, format('T9c[%s]: injected failure not surfaced (%s / %s)', pt, r.state, r.msg);
    select status::text || '|' || coalesce(notes, '') || '|' || coalesce(cancelled_at::text, '-') into after_d from public.dispatches where id = d;
    snap_a := td0149_t.snapshot(ld);
    assert before_d = after_d and snap_b = snap_a, format('T9c[%s]: PARTIAL WRITES after failed cancel: %s -> %s / %s -> %s', pt, before_d, after_d, snap_b, snap_a);
    assert (select status from public.dispatches where id = d) = 'assigned', 'T9c: dispatch must still be active';
    raise notice 'OK: T9c cancel_dispatch failure at [%] rolls back the dispatch update and load revert', pt;
  end loop;
  perform set_config('td0149.inject', '', false);
  select * into r from td0149_t.try_cancel(d, 'now for real');
  assert r.state is null and (select status from public.dispatches where id = d) = 'cancelled', 'T9c: cancel after failures must succeed';
end $t$;

-- ============================ T10: duplicate submission / idempotency =======
-- After a successful create the load reads 'dispatched', so a double-click / retry is rejected by the
-- load-status gate (TDLND) -- nothing further is written. The step-5 TDDUP check is exercised too by
-- forcing the load back to a dispatchable status while its dispatch is still active.
set role authenticated;
select td0149_t.run_create('T10a', 'u_disp1', td0149_t.id('l13'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'), null, 9, 'dup test');
select td0149_t.run_create('T10b', 'u_disp1', td0149_t.id('l13'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'), null, 9, 'dup test');
select td0149_t.run_create('T10c', 'u_disp1', td0149_t.id('l13'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'), null, 9, 'dup test');
reset role;
do $t$
declare a td0149_t.results; b td0149_t.results; c td0149_t.results; r record;
begin
  select * into a from td0149_t.results where tag = 'T10a';
  select * into b from td0149_t.results where tag = 'T10b';
  select * into c from td0149_t.results where tag = 'T10c';
  assert a.new_id is not null, 'T10: first submission failed';
  assert b.state = 'TDLND' and b.detail = 'dispatched', format('T10: identical resubmission must be rejected (TDLND) (got %s / %s)', b.state, b.detail);
  assert c.state = 'TDLND', 'T10: same load with different resources must also be rejected';
  assert (select count(*) from public.dispatches where load_id = td0149_t.id('l13')) = 1, 'T10: duplicate submission created a second dispatch';
  assert (select count(*) from public.dispatch_financials f join public.dispatches d on d.id = f.dispatch_id where d.load_id = td0149_t.id('l13')) = 1, 'T10: duplicate financials';
  assert (select count(*) from public.activity_logs where entity_id = a.new_id and action = 'created') = 1, 'T10: duplicate audit row';
  update public.loads set status = 'booked' where id = td0149_t.id('l13');
  select * into r from td0149_t.probe_create('u_disp1', td0149_t.id('l13'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'));
  assert r.state = 'TDDUP' and r.detail = a.new_id::text, format('T10: step-5 duplicate check must raise TDDUP (got %s / %s)', r.state, r.msg);
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  perform td0149_t.try_cancel(a.new_id, 'cleanup T10');
  raise notice 'OK: T10 duplicate submission/double-click creates exactly one dispatch and one set of side effects (TDLND, and TDDUP when status is dispatchable)';
end $t$;

-- (The 0054 race-backstop handler needs a REAL second session; tests.py exercises it separately.)
do $t$ begin raise notice 'TEST 0149 REGRESSION PASSED'; end $t$;
rollback;
