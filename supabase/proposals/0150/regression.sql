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
-- =============================================================================
-- regression.sql -- PROPOSAL 0150 functional regression suite (AFTER 0150 is applied).
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY. Run through tests.py only.
-- One transaction that ENDS IN ROLLBACK. Uses the REAL create_dispatch / transition_dispatch_status / 0132 guard.
-- =============================================================================
\set ON_ERROR_STOP on
begin;
set client_min_messages = notice;

-- fresh, unbusy resources (legacy dispatches hold most of the fixture's drivers/trucks)
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  (td0149_t.id('rd_a1'), td0149_t.id('o1'), td0149_t.id('ca'), 'R', 'A1'), (td0149_t.id('rd_a2'), td0149_t.id('o1'), td0149_t.id('ca'), 'R', 'A2'),
  (td0149_t.id('rd_b1'), td0149_t.id('o1'), td0149_t.id('cb'), 'R', 'B1'), (td0149_t.id('rd_b2'), td0149_t.id('o1'), td0149_t.id('cb'), 'R', 'B2');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  (td0149_t.id('rt_a1'), td0149_t.id('o1'), td0149_t.id('ca'), 'RT-A1'), (td0149_t.id('rt_a2'), td0149_t.id('o1'), td0149_t.id('ca'), 'RT-A2'),
  (td0149_t.id('rt_b1'), td0149_t.id('o1'), td0149_t.id('cb'), 'RT-B1'), (td0149_t.id('rt_b2'), td0149_t.id('o1'), td0149_t.id('cb'), 'RT-B2');

-- ===== R0: post-state facts ===================================================
do $t$
declare n int;
begin
  assert not exists (select 1 from public.loads l where l.carrier_resolution = 'unresolved' and not exists (select 1 from public.dispatches d where d.load_id = l.id)), 'R0: a zero-dispatch load is still unresolved';
  select count(*) into n from public.loads where carrier_resolution is null and carrier_id is null;
  assert n = (select count(*) from public.carrier_backfill_0150_provenance), format('R0: NULL/NULL loads (%s) <> provenance rows', n);
  raise notice 'OK: R0 every normalised load is pending (NULL/NULL): %', n;
end $t$;

-- ===== R1/R2: first dispatch claims the SELECTED, AUTHORIZED carrier (either carrier may claim) =================
set role authenticated;
select td0149_t.run_create('R1', 'u_disp1', td0149_t.id('l1'), td0149_t.id('ca'), td0149_t.id('rt_a1'), td0149_t.id('rd_a1'), td0149_t.id('ra1'));
select td0149_t.run_create('R2', 'u_disp1', td0149_t.id('l2'), td0149_t.id('cb'), td0149_t.id('rt_b1'), td0149_t.id('rd_b1'), td0149_t.id('rb1'));
reset role;
do $t$
declare r td0149_t.results; l public.loads;
begin
  select * into r from td0149_t.results where tag = 'R1';
  assert r.state is null and r.new_id is not null, format('R1: first dispatch failed: %s %s', r.state, r.msg);
  select * into l from public.loads where id = td0149_t.id('l1');
  assert l.carrier_id = td0149_t.id('ca') and l.carrier_resolution = 'resolved' and l.status = 'dispatched', format('R1: claim wrong: carrier=%s res=%s status=%s', l.carrier_id, l.carrier_resolution, l.status);
  select * into r from td0149_t.results where tag = 'R2';
  assert r.state is null, format('R2: first dispatch (other carrier) failed: %s %s', r.state, r.msg);
  assert (select carrier_id from public.loads where id = td0149_t.id('l2')) = td0149_t.id('cb') and (select carrier_resolution from public.loads where id = td0149_t.id('l2')) = 'resolved', 'R2: claim wrong';
  raise notice 'OK: R1/R2 the first dispatch atomically claims the selected carrier (ca on l1, cb on l2); load dispatched';
end $t$;

-- ===== R3/R4: later different-carrier dispatch rejected; same-carrier redispatch works ======================
set role authenticated;
select td0149_t.run_transition('R3_cancel', 'u_disp1', (select new_id from td0149_t.results where tag = 'R1'), 'cancelled', 'reroute');
select td0149_t.run_create('R3', 'u_disp1', td0149_t.id('l1'), td0149_t.id('cb'), td0149_t.id('rt_b2'), td0149_t.id('rd_b2'));
select td0149_t.run_create('R4', 'u_disp1', td0149_t.id('l1'), td0149_t.id('ca'), td0149_t.id('rt_a2'), td0149_t.id('rd_a2'));
reset role;
do $t$
declare r td0149_t.results;
begin
  assert (select state from td0149_t.results where tag = 'R3_cancel') is null, 'R3: cancel failed';
  select * into r from td0149_t.results where tag = 'R3';
  assert r.state = '23514' and r.msg like '%does not match load%', format('R3: a different carrier must be rejected by the guard (got %s / %s)', r.state, r.msg);
  assert (select carrier_id from public.loads where id = td0149_t.id('l1')) = td0149_t.id('ca'), 'R3: load carrier must stay ca (cancel never clears it)';
  assert (select count(*) from public.dispatches where load_id = td0149_t.id('l1') and carrier_id = td0149_t.id('cb')) = 0, 'R3: rejected dispatch must leave no row';
  assert (select state from td0149_t.results where tag = 'R4') is null, format('R4: same-carrier redispatch failed: %s %s', (select state from td0149_t.results where tag = 'R4'), (select msg from td0149_t.results where tag = 'R4'));
  raise notice 'OK: R3 different carrier rejected after the claim (23514, no row); R4 same-carrier redispatch works';
end $t$;

-- ===== R5-R7: cross-org, wrong-carrier trailer, unresolved trailer: rejected AND the load stays pending (atomic) ======
set role authenticated;
select td0149_t.run_create('R5a', 'u_disp2', td0149_t.id('l3'), td0149_t.id('cx'), td0149_t.id('tx1'), td0149_t.id('dx1'));      -- other org's dispatcher on this org's load
select td0149_t.run_create('R5b', 'u_disp1', td0149_t.id('l3'), td0149_t.id('cx'), td0149_t.id('tx1'), td0149_t.id('dx1'));      -- this org's dispatcher naming the other org's carrier
select td0149_t.run_create('R6', 'u_disp1', td0149_t.id('l3'), td0149_t.id('ca'), td0149_t.id('rt_a1'), td0149_t.id('rd_a1'), td0149_t.id('rb1'));  -- trailer of carrier cb
select td0149_t.run_create('R7', 'u_disp1', td0149_t.id('l3'), td0149_t.id('ca'), td0149_t.id('rt_a1'), td0149_t.id('rd_a1'), td0149_t.id('r_unres'));
reset role;
do $t$
declare t text;
begin
  foreach t in array array['R5a','R5b','R6','R7'] loop
    assert (select state from td0149_t.results where tag = t) is not null, t || ': must be rejected';
  end loop;
  assert (select state from td0149_t.results where tag = 'R5a') in ('TDLNF','TDROL'), 'R5a: cross-org must look like not-found/forbidden, got ' || (select state from td0149_t.results where tag = 'R5a');
  assert (select carrier_id is null and carrier_resolution is null from public.loads where id = td0149_t.id('l3')), 'R5-R7: the rejected attempts must leave l3 pending (NULL/NULL)';
  assert not exists (select 1 from public.dispatches where load_id = td0149_t.id('l3')), 'R5-R7: no dispatch row may remain';
  raise notice 'OK: R5 cross-org (% / %), R6 wrong-carrier trailer (%), R7 unresolved trailer (%) all rejected; l3 still pending', (select state from td0149_t.results where tag = 'R5a'), (select state from td0149_t.results where tag = 'R5b'), (select state from td0149_t.results where tag = 'R6'), (select state from td0149_t.results where tag = 'R7');
end $t$;

-- ===== R8: loads 0150 must NOT have touched stay blocked ==========================================
set role authenticated;
select td0149_t.run_create('R8', 'u_disp1', td0149_t.id('k_c5'), td0149_t.id('ca'), td0149_t.id('rt_a1'), td0149_t.id('rd_a1'));
reset role;
do $t$
begin
  assert (select state from td0149_t.results where tag = 'R8') = '23514' and (select msg from td0149_t.results where tag = 'R8') like '%unresolved carrier%', format('R8: a load WITH dispatch history must stay blocked (got %s / %s)', (select state from td0149_t.results where tag = 'R8'), (select msg from td0149_t.results where tag = 'R8'));
  assert (select carrier_resolution from public.loads where id = td0149_t.id('k_c5')) = 'unresolved', 'R8: k_c5 must still be unresolved';
  assert (select count(*) from public.unresolved_carrier_records where record_type = 'load' and status = 'unresolved') = 3, 'R8: exactly the 3 loads with dispatches keep their open exception records';
  raise notice 'OK: R8 unresolved loads WITH dispatch history (incl. cancelled) are still blocked and keep their open exception records';
end $t$;

do $t$ begin raise notice 'TEST 0150 REGRESSION PASSED'; end $t$;
rollback;
