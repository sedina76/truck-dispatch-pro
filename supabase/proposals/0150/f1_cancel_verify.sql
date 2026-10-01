-- =============================================================================
-- f1_cancel_verify.sql -- BLOCKER F1 verification (Cancel button via transition_dispatch_status).
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY. NOT A MIGRATION.
-- Run through tests.py only, on the REAL 0130..0147 chain + 0149, after the 0149 fixture.
-- One transaction that ENDS IN ROLLBACK. Verifies the 11 conditions the F1 app change relies on.
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

-- ---- extra fixture (rolled back with the transaction) --------------------------------------------------
insert into auth.users (id) select td0149_t.id(n) from unnest(array['u_owner1','u_admin1','u_driver1','u_viewer1','u_owner2']) n;
insert into public.profiles (id, organization_id, full_name, email, role) values
  (td0149_t.id('u_owner1'),  td0149_t.id('o1'), 'Olive Owner',   'owner1@example.invalid',  'owner'),
  (td0149_t.id('u_admin1'),  td0149_t.id('o1'), 'Adam Admin',    'admin1@example.invalid',  'admin'),
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

-- tr(): the exact call the app will make -- transition_dispatch_status(id,'cancelled',reason,key); captures outcome + jsonb result.
create table td0149_t.f1 (seq bigserial primary key, tag text, state text, msg text, result jsonb);
grant select, insert on td0149_t.f1 to authenticated;
grant usage on sequence td0149_t.f1_seq_seq to authenticated;
create function td0149_t.tr(p_tag text, p_user text, p_dispatch uuid, p_reason text, p_key text default null,
                            p_status public.dispatch_status default 'cancelled') returns void
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
grant execute on function td0149_t.tr(text, text, uuid, text, text, public.dispatch_status) to authenticated;

-- dsn(i): fixture ids for the i-th dispatch (load fi, driver fdi, truck fti, trailer fri)
-- setup_status(): create through the REAL create_dispatch, then force the status as a superuser (triggers off for the setup write only).
create function td0149_t.mk(p_tag text, p_i int, p_status public.dispatch_status default 'assigned', p_notes text default null) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  v_id := public.create_dispatch(td0149_t.id('f' || p_i), td0149_t.id('ca'), td0149_t.id('ft' || p_i), td0149_t.id('fd' || p_i), td0149_t.id('fr' || p_i), null, p_notes);
  insert into td0149_t.f1 (tag, result) values (p_tag, jsonb_build_object('id', v_id));
  return v_id;
end $$;
grant execute on function td0149_t.mk(text, int, public.dispatch_status, text) to authenticated;
create function td0149_t.did(p_tag text) returns uuid language sql stable as $$ select (result ->> 'id')::uuid from td0149_t.f1 where tag = p_tag $$;
create function td0149_t.st(p_tag text) returns text language sql stable as $$ select state from td0149_t.f1 where tag = p_tag order by seq desc limit 1 $$;
grant execute on function td0149_t.did(text), td0149_t.st(text) to authenticated;

-- ===== 0. baseline facts: the chain really is 0130..0147 + 0149 ======================================
do $t$
begin
  assert to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is not null, 'transition_dispatch_status missing (0134)';
  assert to_regclass('public.dispatch_status_transitions') is not null, 'idempotency ledger missing';
  assert to_regclass('public.carrier_invoices') is not null, '0142 not applied (chain incomplete)';
  assert position('c_active constant public.dispatch_status[]' in pg_get_functiondef('public.cancel_dispatch(uuid,text)'::regprocedure)) > 0, '0149 not applied';
  raise notice 'OK: F0 real chain 0130..0147 + 0149 present';
end $t$;

-- ===== conditions 1 + 2: reaches cancel_dispatch (SECURITY INVOKER) through the DEFINER; privileges stay locked ============
do $t$
declare a record; b record;
begin
  select prosecdef, proconfig, pg_get_userbyid(proowner) o into a from pg_proc where oid = 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)'::regprocedure;
  select prosecdef into b from pg_proc where oid = 'public.cancel_dispatch(uuid,text)'::regprocedure;
  assert a.prosecdef, 'transition_dispatch_status must be SECURITY DEFINER';
  assert a.proconfig::text like '%search_path=pg_catalog, public%', 'transition_dispatch_status search_path must be pinned: ' || a.proconfig::text;
  assert not b.prosecdef, 'cancel_dispatch is expected to be SECURITY INVOKER (the F1 premise)';
  assert has_function_privilege('authenticated', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute'), 'authenticated must be able to call transition';
  assert not has_function_privilege('public', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute'), 'PUBLIC must not call transition';  -- (anon may hold EXECUTE via Supabase default privileges; it is refused in-function: TSAUT, see F10)
  assert not has_table_privilege('authenticated', 'public.dispatches', 'update'), 'authenticated must NOT hold table-level UPDATE on dispatches';
  assert not exists (select 1 from information_schema.column_privileges where table_schema = 'public' and table_name = 'dispatches'
                     and grantee = 'authenticated' and privilege_type = 'UPDATE' and column_name <> 'notes'), 'authenticated UPDATE must be limited to notes';
  assert not exists (select 1 from pg_class where oid in ('public.dispatches'::regclass, 'public.loads'::regclass, 'public.dispatch_status_transitions'::regclass) and relforcerowsecurity),
    'FORCE RLS on a touched table would break the owner-context write';
  raise notice 'OK: F2 transition is SECURITY DEFINER (pinned search_path), cancel_dispatch is INVOKER, authenticated cannot UPDATE dispatches directly';
end $t$;

set role authenticated;
select td0149_t.mk('c1', 1);
do $t$
begin
  begin update public.dispatches set status = 'cancelled' where id = td0149_t.did('c1'); assert false, 'direct UPDATE status must be refused';
  exception when insufficient_privilege then null; end;
end $t$;
do $t$
declare v_state text;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  begin perform public.cancel_dispatch(td0149_t.did('c1'), 'direct'); exception when others then get stacked diagnostics v_state := returned_sqlstate; end;
  assert v_state = '42501', 'direct authenticated cancel_dispatch must stay refused (42501), got ' || coalesce(v_state, 'success');
end $t$;
select td0149_t.tr('c1_tr', 'u_disp1', td0149_t.did('c1'), 'customer withdrew', 'key-c1');
reset role;
do $t$
declare r record;
begin
  assert td0149_t.st('c1_tr') is null, 'condition 1: transition cancel failed: ' || coalesce(td0149_t.st('c1_tr'), '') || ' ' || coalesce((select msg from td0149_t.f1 where tag = 'c1_tr'), '');
  assert (select status from public.dispatches where id = td0149_t.did('c1')) = 'cancelled', 'condition 1: dispatch not cancelled';
  assert (select result ->> 'success' from td0149_t.f1 where tag = 'c1_tr') = 'true', 'result jsonb success expected';
  raise notice 'OK: F1/F2 authenticated -> transition_dispatch_status(cancelled) reaches cancel_dispatch and succeeds although direct UPDATE and direct cancel_dispatch are refused (42501)';
end $t$;

-- ===== condition 3: reason storage ====================================================================
set role authenticated;
select td0149_t.mk('r1', 2, 'assigned', 'internal-only note');
select td0149_t.mk('r2', 3);
select td0149_t.mk('r3', 4);
reset role;
update public.dispatches set notes = 'existing dispatcher note' where id = td0149_t.did('r1');   -- setup: a pre-existing notes value to prove APPEND
set role authenticated;
select td0149_t.tr('r1_tr', 'u_disp1', td0149_t.did('r1'), E'  Customer said "no" -- it''s O''Brien\nline two; ; drop table x;  ', 'key-r1');
select td0149_t.tr('r2_tr', 'u_disp1', td0149_t.did('r2'), '   ', 'key-r2');
select td0149_t.tr('r3_tr', 'u_disp1', td0149_t.did('r3'), null, 'key-r3');
reset role;
do $t$
declare v_notes text; v_chg jsonb; v_reason text := E'Customer said "no" -- it''s O''Brien\nline two; ; drop table x;';
begin
  assert td0149_t.st('r1_tr') is null and td0149_t.st('r2_tr') is null and td0149_t.st('r3_tr') is null, 'reason cases must all succeed';
  select notes into v_notes from public.dispatches where id = td0149_t.did('r1');
  assert v_notes = 'existing dispatcher note' || E'\n' || '[Cancelled: ' || v_reason || ']', 'reason must be stored (trimmed, otherwise verbatim) appended to dispatches.notes: ' || v_notes;
  select changes into v_chg from public.activity_logs where entity_id = td0149_t.did('r1') and action = 'cancelled';
  assert v_chg ->> 'reason' = v_reason, 'reason must reach the activity log unchanged (trim only)';
  assert (select notes from public.dispatch_internal_notes where dispatch_id = td0149_t.did('r1')) = 'internal-only note', 'internal notes (dispatch_internal_notes) must be untouched';
  assert (select notes from public.dispatches where id = td0149_t.did('r2')) = '[Cancelled]', 'blank reason -> plain [Cancelled] marker';
  assert (select changes from public.activity_logs where entity_id = td0149_t.did('r2') and action = 'cancelled') is null, 'blank reason -> no reason in log';
  assert (select notes from public.dispatches where id = td0149_t.did('r3')) = '[Cancelled]', 'null reason -> plain [Cancelled] marker';
  raise notice 'OK: F3 reason stored in dispatches.notes ("[Cancelled: <reason>]", appended after existing notes) and activity_logs.changes.reason; quotes/newlines/SQL text inert; blank/null handled';
end $t$;

-- ===== condition 4: source-status matrix ================================================================
create table td0149_t.sm (st public.dispatch_status primary key, did uuid, i int);
do $t$
declare s public.dispatch_status; i int := 5; v uuid;
begin
  foreach s in array enum_range(null::public.dispatch_status) loop
    if s = 'cancelled' then continue; end if;
    v := td0149_t.mk('sm_' || s, i);
    insert into td0149_t.sm values (s, v, i);
    i := i + 1;
  end loop;
end $t$;
set local session_replication_role = replica;   -- setup-only: force each dispatch into its status without re-firing triggers
update public.dispatches d set status = sm.st from td0149_t.sm sm where d.id = sm.did and sm.st <> 'assigned';
reset session_replication_role;
grant select on td0149_t.sm to authenticated;
set role authenticated;
select td0149_t.tr('sm_' || st, 'u_disp1', did, 'matrix', null) from td0149_t.sm order by i;
reset role;
do $t$
declare r record; ok_n int := 0; bad_n int := 0;
begin
  for r in select * from td0149_t.sm order by i loop
    if r.st in ('delivered','completed') then
      assert td0149_t.st('sm_' || r.st) in ('TDTRM','TSINV'), format('%s must be rejected, got %s', r.st, td0149_t.st('sm_' || r.st));
      assert (select status from public.dispatches where id = r.did) = r.st, r.st || ' must be untouched after rejection';
      bad_n := bad_n + 1;
    else
      assert td0149_t.st('sm_' || r.st) is null, format('%s must be cancellable, got %s', r.st, td0149_t.st('sm_' || r.st));
      assert (select status from public.dispatches where id = r.did) = 'cancelled', r.st || ' must end cancelled';
      ok_n := ok_n + 1;
    end if;
  end loop;
  assert ok_n = 7 and bad_n = 2, format('expected 7 cancellable / 2 rejected, got %s/%s', ok_n, bad_n);
  raise notice 'OK: F4 the 7 active statuses cancel; delivered (%) and completed (%) are rejected and untouched', td0149_t.st('sm_delivered'), td0149_t.st('sm_completed');
end $t$;
set role authenticated;
select td0149_t.tr('sm_cancelled_again', 'u_disp1', (select did from td0149_t.sm where st = 'assigned'), 'again', null);
reset role;
do $t$
begin
  assert td0149_t.st('sm_cancelled_again') is null, 'cancelled -> cancelled must be an idempotent no-op';
  assert (select result ->> 'no_op' from td0149_t.f1 where tag = 'sm_cancelled_again') = 'true', 'no_op flag expected';
  assert (select count(*) from public.activity_logs where entity_id = (select did from td0149_t.sm where st = 'assigned') and action = 'cancelled') = 1, 'no second audit row';
  raise notice 'OK: F4b cancelled -> cancelled is a no-op with no extra audit row';
end $t$;

-- ===== conditions 5 + 6: resources released, load synchronised ==========================================
do $t$
declare r record; v_new uuid;
begin
  -- every cancelled dispatch from the matrix must have freed its driver/truck/trailer (0054 partial unique indexes ignore cancelled)
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  for r in select sm.*, d.load_id, d.driver_id, d.truck_id, d.trailer_id from td0149_t.sm sm join public.dispatches d on d.id = sm.did where sm.st not in ('delivered','completed') loop
    assert (select status from public.loads where id = r.load_id) = 'booked', 'load must return to booked after cancel of ' || r.st;
    assert not exists (select 1 from public.dispatches x where x.id <> r.did and x.driver_id = r.driver_id and x.status not in ('cancelled','delivered','completed')), 'driver still held';
  end loop;
  raise notice 'OK: F6 load returns to booked for all 7 cancelled active states';
end $t$;
-- re-dispatch the SAME driver/truck/trailer on a fresh load -> only possible if the cancel released them
insert into public.loads (id, organization_id, load_number, status) values (td0149_t.id('f_re'), td0149_t.id('o1'), 'LD-FRE', 'booked');
set role authenticated;
do $t$
declare r record;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  perform public.create_dispatch(td0149_t.id('f_re'), td0149_t.id('ca'), td0149_t.id('ft6'), td0149_t.id('fd6'), td0149_t.id('fr6'), null, null);
  raise notice 'OK: F5 the cancelled dispatch''s driver, truck and trailer are immediately re-dispatchable (resources released)';
end $t$;
reset role;
-- the load must NOT return to booked while another ACTIVE dispatch holds it, and must not be touched once past delivery
insert into public.loads (id, organization_id, load_number, status) values
  (td0149_t.id('f_multi'), td0149_t.id('o1'), 'LD-FMU', 'booked'), (td0149_t.id('f_inv'), td0149_t.id('o1'), 'LD-FIN', 'booked');
do $t$
declare a uuid; b uuid;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  a := public.create_dispatch(td0149_t.id('f_multi'), td0149_t.id('ca'), td0149_t.id('ft30'), td0149_t.id('fd30'), td0149_t.id('fr30'), null, null);
  insert into td0149_t.f1 (tag, result) values ('m_a', jsonb_build_object('id', a));
  -- second active dispatch on the same load (allowed by the schema; guard permits same carrier): force via superuser insert, triggers off
  set local session_replication_role = replica;
  insert into public.dispatches (id, organization_id, load_id, carrier_id, driver_id, truck_id, status)
    values (td0149_t.id('m_b'), td0149_t.id('o1'), td0149_t.id('f_multi'), td0149_t.id('ca'), td0149_t.id('fd31'), td0149_t.id('ft31'), 'en_route_to_pickup');
  reset session_replication_role;
  a := public.create_dispatch(td0149_t.id('f_inv'), td0149_t.id('ca'), td0149_t.id('ft32'), td0149_t.id('fd32'), td0149_t.id('fr32'), null, null);
  insert into td0149_t.f1 (tag, result) values ('inv_a', jsonb_build_object('id', a));
  update public.loads set status = 'invoiced' where id = td0149_t.id('f_inv');
end $t$;
set role authenticated;
select td0149_t.tr('m_tr', 'u_disp1', td0149_t.did('m_a'), 'first of two', null);
select td0149_t.tr('inv_tr', 'u_disp1', td0149_t.did('inv_a'), 'after invoicing', null);
reset role;
do $t$
begin
  assert td0149_t.st('m_tr') is null and td0149_t.st('inv_tr') is null, 'sync cases must succeed';
  assert (select status from public.loads where id = td0149_t.id('f_multi')) = 'dispatched', 'load must stay dispatched while another active dispatch holds it';
  assert (select status from public.loads where id = td0149_t.id('f_inv')) = 'invoiced', 'a load past delivery must not be pulled back to booked';
  raise notice 'OK: F6b load stays dispatched while another active dispatch exists; invoiced load is not regressed';
end $t$;

-- ===== condition 7: exactly one audit event ==================================================================
do $t$
declare r record; n int;
begin
  for r in select 'c1' t union all select 'r1' union all select 'r2' union all select 'r3' loop
    select count(*) into n from public.activity_logs where entity_id = td0149_t.did(r.t) and action = 'cancelled';
    assert n = 1, format('%s: expected exactly one cancelled audit row, got %s', r.t, n);
    assert not exists (select 1 from public.activity_logs where entity_id = td0149_t.did(r.t) and action = 'status_changed'), r.t || ': no extra status_changed row on cancel';
    assert (select actor_id from public.activity_logs where entity_id = td0149_t.did(r.t) and action = 'cancelled') = td0149_t.id('u_disp1'), 'actor must be the calling user';
    assert (select organization_id from public.activity_logs where entity_id = td0149_t.did(r.t) and action = 'cancelled') = td0149_t.id('o1'), 'audit org must be the dispatch org';
  end loop;
  raise notice 'OK: F7 exactly one "cancelled" activity row per cancellation (actor = caller, org = dispatch org), no duplicate status_changed row';
end $t$;

-- ===== condition 8: idempotency =======================================================================
set role authenticated;
select td0149_t.mk('i1', 20, 'assigned', 'n0');
select td0149_t.tr('i1_a', 'u_disp1', td0149_t.did('i1'), 'first reason', 'K-1');
reset role;
create table td0149_t.isnap as select d.notes, d.cancelled_at, d.updated_at, (select count(*) from public.activity_logs where entity_id = d.id) n_log,
  (select count(*) from public.dispatch_status_transitions where dispatch_id = d.id) n_led from public.dispatches d where d.id = td0149_t.did('i1');
set role authenticated;
select td0149_t.tr('i1_b', 'u_disp1', td0149_t.did('i1'), 'DIFFERENT reason', 'K-1');   -- same key: replay
select td0149_t.tr('i1_c', 'u_disp1', td0149_t.did('i1'), 'yet another', 'K-2');         -- new key on an already-cancelled dispatch: no-op
reset role;
do $t$
declare s record; d public.dispatches; a jsonb; b jsonb;
begin
  select * into s from td0149_t.isnap; select * into d from public.dispatches where id = td0149_t.did('i1');
  select result into a from td0149_t.f1 where tag = 'i1_a'; select result into b from td0149_t.f1 where tag = 'i1_b';
  assert td0149_t.st('i1_b') is null and (b ->> 'idempotent_replay') = 'true', 'replay must be flagged idempotent_replay';
  assert (b - 'idempotent_replay') = a, 'replay must return the SAME outcome as the original';
  assert d.notes is not distinct from s.notes and d.cancelled_at is not distinct from s.cancelled_at and d.updated_at is not distinct from s.updated_at, 'replay must not touch the dispatch';
  assert (select count(*) from public.activity_logs where entity_id = d.id) = s.n_log, 'replay must not add audit rows';
  assert d.notes like '%first reason%' and d.notes not like '%DIFFERENT%', 'the ORIGINAL reason stands';
  assert td0149_t.st('i1_c') is null and (select result ->> 'no_op' from td0149_t.f1 where tag = 'i1_c') = 'true', 'new key on cancelled dispatch = no-op';
  assert (select count(*) from public.activity_logs where entity_id = d.id) = s.n_log, 'no-op must not add audit rows';
  assert (select count(*) from public.dispatch_status_transitions where dispatch_id = d.id and idempotency_key = 'K-1') = 1, 'exactly one ledger row per key';
  raise notice 'OK: F8 same key replays the original result with no second write/audit; different key on a cancelled dispatch is a no-op';
end $t$;

-- ===== condition 9: cross-organisation ============================================================
set role authenticated;
select td0149_t.mk('x1', 21);
select td0149_t.tr('x_disp2', 'u_disp2', td0149_t.did('x1'), 'hostile', 'XK-1');
select td0149_t.tr('x_owner2', 'u_owner2', td0149_t.did('x1'), 'hostile owner', 'XK-2');
select td0149_t.tr('x_missing', 'u_disp1', td0149_t.id('no-such-dispatch'), 'ghost', 'XK-3');
reset role;
do $t$
begin
  assert td0149_t.st('x_disp2') = 'TSDNF' and td0149_t.st('x_owner2') = 'TSDNF', 'cross-org must be TSDNF (identical to not-found): ' || coalesce(td0149_t.st('x_disp2'), 'success');
  assert td0149_t.st('x_missing') = 'TSDNF', 'missing dispatch must be TSDNF';
  assert (select msg from td0149_t.f1 where tag = 'x_disp2') = (select replace(msg, td0149_t.id('no-such-dispatch')::text, td0149_t.did('x1')::text) from td0149_t.f1 where tag = 'x_missing'), 'cross-org and not-found messages must be indistinguishable';
  assert (select status from public.dispatches where id = td0149_t.did('x1')) = 'assigned', 'cross-org attempt must not change anything';
  assert not exists (select 1 from public.activity_logs where entity_id = td0149_t.did('x1') and action = 'cancelled'), 'no audit row for the rejected attempt';
  raise notice 'OK: F9 other-organisation dispatcher AND owner get TSDNF (indistinguishable from not found); nothing changes';
end $t$;
-- replay-leak probe: can another org obtain a cached result by supplying a victim dispatch id + its key?
set role authenticated;
select td0149_t.tr('leak_victim', 'u_disp1', td0149_t.did('x1'), 'victim cancel', 'LEAK-KEY');
select td0149_t.tr('leak_probe', 'u_disp2', td0149_t.did('x1'), 'probe', 'LEAK-KEY');
reset role;
do $t$
begin
  if td0149_t.st('leak_probe') is null then
    raise notice 'FINDING F1-R1: a cross-org caller who already knows BOTH a victim dispatch UUID and its idempotency key receives the cached result JSON (%); the idempotency short-circuit runs before the org check (0134 lines ~319-327). Result carries only status names/ids the caller already supplied. NOT changed by this proposal.', (select result::text from td0149_t.f1 where tag = 'leak_probe');
  else
    raise notice 'OK: F9b replay probe by another org rejected (%)', td0149_t.st('leak_probe');
  end if;
end $t$;

-- ===== condition 10: roles ============================================================================
set role authenticated;
select td0149_t.mk('p_' || n, 21 + i) from (values (1,'owner'),(2,'admin'),(3,'dispatcher'),(4,'accountant'),(5,'driver'),(6,'viewer')) v(i, n);
select td0149_t.tr('role_owner', 'u_owner1', td0149_t.did('p_owner'), 'r', null);
select td0149_t.tr('role_admin', 'u_admin1', td0149_t.did('p_admin'), 'r', null);
select td0149_t.tr('role_dispatcher', 'u_disp1', td0149_t.did('p_dispatcher'), 'r', null);
select td0149_t.tr('role_accountant', 'u_acct1', td0149_t.did('p_accountant'), 'r', null);
select td0149_t.tr('role_driver', 'u_driver1', td0149_t.did('p_driver'), 'r', null);
select td0149_t.tr('role_viewer', 'u_viewer1', td0149_t.did('p_viewer'), 'r', null);
select td0149_t.tr('role_anon', null, td0149_t.did('p_viewer'), 'r', null);
reset role;
do $t$
declare r text;
begin
  foreach r in array array['owner','admin','dispatcher'] loop
    assert td0149_t.st('role_' || r) is null, r || ' must be able to cancel: ' || coalesce(td0149_t.st('role_' || r), '');
    assert (select status from public.dispatches where id = td0149_t.did('p_' || r)) = 'cancelled', r || ' cancel must persist';
  end loop;
  foreach r in array array['accountant','driver','viewer'] loop
    assert td0149_t.st('role_' || r) = 'TSROL', r || ' must be refused with TSROL, got ' || coalesce(td0149_t.st('role_' || r), 'success');
    assert (select status from public.dispatches where id = td0149_t.did('p_' || r)) = 'assigned', r || ' refusal must leave the dispatch untouched';
  end loop;
  assert td0149_t.st('role_anon') = 'TSAUT', 'no auth.uid() must be TSAUT, got ' || coalesce(td0149_t.st('role_anon'), 'success');
  raise notice 'OK: F10 owner/admin/dispatcher cancel; accountant/driver/viewer refused (TSROL); unauthenticated refused (TSAUT)';
end $t$;

-- ===== condition 11: forced downstream error rolls the whole cancellation back =============================
-- (a) failure at the LAST step inside cancel_dispatch (audit insert); (b) failure AFTER cancel_dispatch returned (idempotency ledger insert).
create function td0149_t.boom() returns trigger language plpgsql as $$
begin
  if current_setting('td0149.boom', true) = tg_table_name then raise exception 'FORCED downstream failure in %', tg_table_name using errcode = 'P0F11'; end if;
  return new;
end $$;
create trigger td0149_boom before insert on public.activity_logs for each row execute function td0149_t.boom();
create trigger td0149_boom before insert on public.dispatch_status_transitions for each row execute function td0149_t.boom();
set role authenticated;
select td0149_t.mk('b1', 28, 'assigned', 'keep me');
select td0149_t.mk('b2', 29, 'assigned', 'keep me too');
reset role;
create table td0149_t.bsnap as
  select d.id, d.status, d.notes, d.cancelled_at, d.updated_at, l.status as load_status, l.updated_at as load_updated_at,
         (select count(*) from public.activity_logs where entity_id = d.id) n_log, (select count(*) from public.dispatch_status_transitions where dispatch_id = d.id) n_led
  from public.dispatches d join public.loads l on l.id = d.load_id where d.id in (td0149_t.did('b1'), td0149_t.did('b2'));
set td0149.boom = 'activity_logs';
set role authenticated;
select td0149_t.tr('boom_a', 'u_disp1', td0149_t.did('b1'), 'will fail', 'BK-1');
reset role;
set td0149.boom = 'dispatch_status_transitions';
set role authenticated;
select td0149_t.tr('boom_b', 'u_disp1', td0149_t.did('b2'), 'will fail late', 'BK-2');
reset role;
set td0149.boom = '';
do $t$
declare s record; d record; l record;
begin
  assert td0149_t.st('boom_a') = 'P0F11' and td0149_t.st('boom_b') = 'P0F11', 'the forced failures must surface: ' || coalesce(td0149_t.st('boom_a'), 'ok') || ' / ' || coalesce(td0149_t.st('boom_b'), 'ok');
  for s in select * from td0149_t.bsnap loop
    select * into d from public.dispatches where id = s.id;
    select status, updated_at into l from public.loads where id = d.load_id;
    assert d.status = s.status and d.notes is not distinct from s.notes and d.cancelled_at is not distinct from s.cancelled_at and d.updated_at is not distinct from s.updated_at,
      'dispatch must be byte-identical after the rolled-back cancel (' || s.id || ')';
    assert l.status = s.load_status and l.updated_at is not distinct from s.load_updated_at, 'load must be untouched after the rolled-back cancel';
    assert (select count(*) from public.activity_logs where entity_id = s.id) = s.n_log, 'no audit row may survive';
    assert (select count(*) from public.dispatch_status_transitions where dispatch_id = s.id) = s.n_led, 'no ledger row may survive';
  end loop;
  raise notice 'OK: F11 a failure inside cancel_dispatch (audit insert) and a failure after it (ledger insert) each roll back the WHOLE cancellation: dispatch, notes, cancelled_at, load status, audit and ledger all unchanged';
end $t$;
-- retry after the transient failure must succeed with the same key (no poisoned ledger)
set role authenticated;
select td0149_t.tr('boom_retry', 'u_disp1', td0149_t.did('b2'), 'retry', 'BK-2');
reset role;
do $t$
begin
  assert td0149_t.st('boom_retry') is null and (select status from public.dispatches where id = td0149_t.did('b2')) = 'cancelled', 'a retry with the same key after a rolled-back failure must succeed';
  assert (select count(*) from public.dispatch_status_transitions where dispatch_id = td0149_t.did('b2') and idempotency_key = 'BK-2') = 1, 'one ledger row after the successful retry';
  raise notice 'OK: F11b retry with the SAME key after a rolled-back failure succeeds (ledger not poisoned)';
end $t$;

do $t$ begin raise notice 'F1 VERIFICATION PASSED'; end $t$;
rollback;
