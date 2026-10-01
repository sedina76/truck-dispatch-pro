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
-- regression.sql -- PROPOSAL 0151 disposable-database script.
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY. Run through tests.py only (it substitutes the fixture marker below).
-- Runs on the REAL 0130..0147 + 0149 + 0150 chain; ONE transaction that ENDS IN ROLLBACK.
-- =============================================================================
\set ON_ERROR_STOP on
begin;
set client_min_messages = notice;
-- @@FIXTURE@@

create function td0149_t.boom() returns trigger language plpgsql as $$
begin
  if current_setting('td0149.boom', true) = tg_table_name then raise exception 'FORCED downstream failure in %', tg_table_name using errcode = 'P0F11'; end if;
  return new;
end $$;
create trigger td0149_boom before insert on public.activity_logs for each row execute function td0149_t.boom();
create trigger td0149_boom before insert on public.dispatch_status_transitions for each row execute function td0149_t.boom();

set role authenticated;
select td0149_t.mk('d1', 1);
select td0149_t.mk('d2', 2);
select td0149_t.mk('d4', 4);
select td0149_t.mk('d5', 5);
select td0149_t.mk('d6', 6);
select td0149_t.mk('d7', 7);
select td0149_t.mk('d8', 8);
select td0149_t.mk('d9', 9);
reset role;
-- an organization-2 dispatch through the real create_dispatch (its load LD-299001 was normalised by 0150)
set role authenticated;
do $t$
declare v uuid;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp2')::text, false);
  v := public.create_dispatch(td0149_t.id('l_o2'), td0149_t.id('cx'), td0149_t.id('ftx2'), td0149_t.id('fdx2'), null, null, null);
  insert into td0149_t.f1 (tag, result) values ('do2', jsonb_build_object('id', v));
end $t$;
reset role;

-- ===== A: original success + cached cancellation result ===========================================
set role authenticated;
select td0149_t.tr('a', 'u_disp1', td0149_t.did('d1'), 'cancelled', 'customer withdrew', 'K1');
reset role;
do $t$
begin
  assert td0149_t.st('a') is null and (td0149_t.res('a') ->> 'success') = 'true' and (td0149_t.res('a') ->> 'new_status') = 'cancelled', 'A: original cancel failed: ' || coalesce(td0149_t.st('a'), '');
  assert td0149_t.n_log(td0149_t.did('d1'), 'cancelled') = 1 and td0149_t.n_led(td0149_t.did('d1'), 'K1') = 1, 'A: one audit + one ledger row expected';
  raise notice 'OK: A original cancellation succeeds; exactly one audit row and one ledger row';
end $t$;

-- ===== B/C: authorized retries (same user; different owner/admin/dispatcher) replay; nothing written ============
set role authenticated;
select td0149_t.tr('b', 'u_disp1', td0149_t.did('d1'), 'cancelled', 'a DIFFERENT reason text', 'K1');
select td0149_t.tr('c_owner', 'u_owner1', td0149_t.did('d1'), 'cancelled', null, 'K1');
select td0149_t.tr('c_admin', 'u_admin1', td0149_t.did('d1'), 'cancelled', null, 'K1');
select td0149_t.tr('c_disp', 'u_disp1b', td0149_t.did('d1'), 'cancelled', null, 'K1');
reset role;
do $t$
declare t text;
begin
  foreach t in array array['b','c_owner','c_admin','c_disp'] loop
    assert td0149_t.st(t) is null, format('B/C: %s must replay, got %s %s', t, td0149_t.st(t), td0149_t.msg(t));
    assert (td0149_t.res(t) ->> 'idempotent_replay') = 'true' and (td0149_t.res(t) - 'idempotent_replay') = td0149_t.res('a'), format('B/C: %s must return the ORIGINAL result flagged as a replay', t);
  end loop;
  assert td0149_t.n_log(td0149_t.did('d1'), 'cancelled') = 1 and td0149_t.n_led(td0149_t.did('d1'), 'K1') = 1, 'B/C: replays must not add audit or ledger rows';
  assert (select notes from public.dispatches where id = td0149_t.did('d1')) like '%customer withdrew%' and (select notes from public.dispatches where id = td0149_t.did('d1')) not like '%DIFFERENT%', 'B: the original reason stands';
  raise notice 'OK: B same-user retry and C different authorized owner/admin/dispatcher retry replay the original result with no duplicate audit/ledger rows (POLICY: actor is not bound)';
end $t$;

-- ===== D: unauthenticated / no profile ==================================================================
set role authenticated;
select td0149_t.tr('e_anon', null, td0149_t.did('d1'), 'cancelled', null, 'K1');
select td0149_t.tr('e_noprofile', 'u_ghost', td0149_t.did('d1'), 'cancelled', null, 'K1');
reset role;
do $t$
begin
  assert td0149_t.st('e_anon') = 'TSAUT' and td0149_t.st('e_noprofile') = 'TSAUT', format('D: unauthenticated/no-organization callers must get TSAUT (%s / %s)', td0149_t.st('e_anon'), td0149_t.st('e_noprofile'));
  assert td0149_t.res('e_anon') is null and td0149_t.res('e_noprofile') is null, 'D: nothing may be returned';
  raise notice 'OK: D unauthenticated and organization-less callers are refused (TSAUT) before any ledger read';
end $t$;

-- ===== E: cross-organization replay with the known dispatch UUID and the known key ========================
set role authenticated;
select td0149_t.tr('f_disp', 'u_disp2', td0149_t.did('d1'), 'cancelled', null, 'K1');
select td0149_t.tr('f_owner', 'u_owner2', td0149_t.did('d1'), 'cancelled', null, 'K1');
select td0149_t.tr('f_nokey', 'u_disp2', td0149_t.did('d1'), 'cancelled', null, 'NO-SUCH-KEY');
select td0149_t.tr('f_ghost', 'u_disp2', td0149_t.id('no-such-dispatch'), 'cancelled', null, 'K1');
reset role;
do $t$
declare t text;
begin
  foreach t in array array['f_disp','f_owner','f_nokey','f_ghost'] loop
    assert td0149_t.st(t) = 'TSDNF' and td0149_t.res(t) is null, format('E: %s must be TSDNF with no result (got %s)', t, td0149_t.st(t));
  end loop;
  assert replace(td0149_t.msg('f_disp'), td0149_t.did('d1')::text, '<id>') = replace(td0149_t.msg('f_nokey'), td0149_t.did('d1')::text, '<id>')
     and replace(td0149_t.msg('f_disp'), td0149_t.did('d1')::text, '<id>') = replace(td0149_t.msg('f_ghost'), td0149_t.id('no-such-dispatch')::text, '<id>'), 'E: a real key, a fake key and a missing dispatch must be indistinguishable';
  raise notice 'OK: E cross-organization replay (dispatcher and owner, real key) is TSDNF and indistinguishable from a wrong key or a missing dispatch';
end $t$;

-- ===== F: membership removed / moved / role downgraded after the original success ============================
update public.profiles set organization_id = null where id = td0149_t.id('u_disp1b');
set role authenticated; select td0149_t.tr('g_removed', 'u_disp1b', td0149_t.did('d1'), 'cancelled', null, 'K1'); reset role;
update public.profiles set organization_id = td0149_t.id('o2') where id = td0149_t.id('u_disp1b');
set role authenticated; select td0149_t.tr('g_moved', 'u_disp1b', td0149_t.did('d1'), 'cancelled', null, 'K1'); reset role;
update public.profiles set organization_id = td0149_t.id('o1'), role = 'accountant' where id = td0149_t.id('u_disp1b');
set role authenticated; select td0149_t.tr('h_acct', 'u_disp1b', td0149_t.did('d1'), 'cancelled', null, 'K1'); reset role;
update public.profiles set role = 'viewer' where id = td0149_t.id('u_disp1b');
set role authenticated; select td0149_t.tr('h_viewer', 'u_disp1b', td0149_t.did('d1'), 'cancelled', null, 'K1'); reset role;
update public.profiles set role = 'driver' where id = td0149_t.id('u_disp1b');
set role authenticated; select td0149_t.tr('h_driver', 'u_disp1b', td0149_t.did('d1'), 'cancelled', null, 'K1'); reset role;
update public.profiles set role = 'dispatcher' where id = td0149_t.id('u_disp1b');
set role authenticated; select td0149_t.tr('h_restored', 'u_disp1b', td0149_t.did('d1'), 'cancelled', null, 'K1'); reset role;
do $t$
begin
  assert td0149_t.st('g_removed') = 'TSAUT', 'F: a user removed from the organization must get TSAUT, got ' || coalesce(td0149_t.st('g_removed'), 'success');
  assert td0149_t.st('g_moved') = 'TSDNF', 'F: a user moved to ANOTHER organization must get TSDNF, got ' || coalesce(td0149_t.st('g_moved'), 'success');
  assert td0149_t.st('h_acct') = 'TSROL' and td0149_t.st('h_viewer') = 'TSROL' and td0149_t.st('h_driver') = 'TSROL', format('F: downgraded roles must get TSROL (%s/%s/%s)', td0149_t.st('h_acct'), td0149_t.st('h_viewer'), td0149_t.st('h_driver'));
  assert td0149_t.res('g_removed') is null and td0149_t.res('g_moved') is null and td0149_t.res('h_acct') is null and td0149_t.res('h_viewer') is null and td0149_t.res('h_driver') is null, 'F: no cached result may be returned';
  assert td0149_t.st('h_restored') is null and (td0149_t.res('h_restored') ->> 'idempotent_replay') = 'true', 'F: once the role is restored the replay works again';
  raise notice 'OK: F removed member -> TSAUT; moved to another organization -> TSDNF; downgraded to accountant/viewer/driver -> TSROL; restored dispatcher replays again';
end $t$;

-- ===== G: same key on a DIFFERENT dispatch, and in a DIFFERENT organization ===================================
set role authenticated;
select td0149_t.tr('i_other_dispatch', 'u_disp1', td0149_t.did('d2'), 'cancelled', 'second', 'K1');
select td0149_t.tr('j_other_org', 'u_disp2', (td0149_t.res('do2') ->> 'id')::uuid, 'cancelled', 'org two', 'K1');
reset role;
do $t$
begin
  assert td0149_t.st('i_other_dispatch') is null and (td0149_t.res('i_other_dispatch') ->> 'idempotent_replay') is null and (td0149_t.res('i_other_dispatch') ->> 'dispatch_id') = td0149_t.did('d2')::text, 'G: the same key on ANOTHER dispatch is a fresh, independent operation';
  assert (select status from public.dispatches where id = td0149_t.did('d2')) = 'cancelled', 'G: d2 must actually be cancelled';
  assert td0149_t.st('j_other_org') is null and (td0149_t.res('j_other_org') ->> 'idempotent_replay') is null, 'G: the same key in ANOTHER organization is independent';
  assert (select status from public.dispatches where id = (td0149_t.res('do2') ->> 'id')::uuid) = 'cancelled', 'G: the org-2 dispatch is cancelled';
  assert (select count(*) from public.dispatch_status_transitions where idempotency_key = 'K1') = 3, 'G: one ledger row per (dispatch, key): d1, d2 and the org-2 dispatch';
  assert (select count(distinct organization_id) from public.dispatch_status_transitions where idempotency_key = 'K1') = 2, 'G: rows carry their own organization';
  raise notice 'OK: G same key on a different dispatch and in a different organization are independent operations (3 ledger rows)';
end $t$;

-- ===== H: the key is bound to the original request (requested status) =======================================
set role authenticated;
select td0149_t.tr('k1', 'u_disp1', td0149_t.did('d5'), 'accepted', null, 'K5');
select td0149_t.tr('k2', 'u_disp1', td0149_t.did('d5'), 'cancelled', 'x', 'K5');
select td0149_t.tr('k3', 'u_disp1', td0149_t.did('d5'), 'accepted', null, 'K5');
reset role;
do $t$
begin
  assert td0149_t.st('k1') is null and td0149_t.st('k2') = 'TSIDK', format('H: same key + different status must be TSIDK, got %s', coalesce(td0149_t.st('k2'), 'success'));
  assert (select status from public.dispatches where id = td0149_t.did('d5')) = 'accepted', 'H: the mismatched request must change nothing';
  assert td0149_t.st('k3') is null and (td0149_t.res('k3') ->> 'idempotent_replay') = 'true', 'H: the original request still replays';
  assert td0149_t.n_led(td0149_t.did('d5'), 'K5') = 1, 'H: one ledger row';
  raise notice 'OK: H the key is bound to the original requested status (TSIDK on mismatch, nothing changed, original still replays)';
end $t$;

-- ===== I: replays of a reactivation / backward correction need CURRENT owner/admin =============================
set role authenticated;
select td0149_t.tr('r_reopen', 'u_owner1', td0149_t.did('d1'), 'assigned', 'customer changed their mind', 'KR');
select td0149_t.tr('r_disp', 'u_disp1', td0149_t.did('d1'), 'assigned', null, 'KR');
select td0149_t.tr('r_admin', 'u_admin1', td0149_t.did('d1'), 'assigned', null, 'KR');
reset role;
set local session_replication_role = replica; update public.dispatches set status = 'loaded' where id = td0149_t.did('d4'); reset session_replication_role;
set role authenticated;
select td0149_t.tr('b_fix', 'u_owner1', td0149_t.did('d4'), 'assigned', 'wrong status entered', 'KB');
select td0149_t.tr('b_disp', 'u_disp1', td0149_t.did('d4'), 'assigned', null, 'KB');
select td0149_t.tr('b_owner', 'u_owner1', td0149_t.did('d4'), 'assigned', null, 'KB');
reset role;
do $t$
begin
  assert td0149_t.st('r_reopen') is null and (td0149_t.res('r_reopen') ->> 'reactivated') = 'true', 'I: owner reactivation failed: ' || coalesce(td0149_t.st('r_reopen'), '');
  assert td0149_t.st('r_disp') = 'TSROL' and td0149_t.res('r_disp') is null, 'I: a dispatcher may NOT replay a reactivation, got ' || coalesce(td0149_t.st('r_disp'), 'success');
  assert td0149_t.st('r_admin') is null and (td0149_t.res('r_admin') ->> 'idempotent_replay') = 'true', 'I: an admin may replay it';
  assert td0149_t.st('b_fix') is null, 'I: owner backward correction failed: ' || coalesce(td0149_t.st('b_fix'), '');
  assert td0149_t.st('b_disp') = 'TSROL' and td0149_t.st('b_owner') is null, 'I: a dispatcher may not replay a backward correction; the owner may';
  raise notice 'OK: I replaying a reactivation or backward correction requires CURRENT owner/admin authority (dispatcher TSROL; owner/admin replay)';
end $t$;

-- ===== J: role gate also covers the no-op (already-in-status) path ==========================================
update public.profiles set role = 'accountant' where id = td0149_t.id('u_disp1b');
set role authenticated; select td0149_t.tr('n_acct', 'u_disp1b', td0149_t.did('d2'), 'cancelled', null, null); reset role;
update public.profiles set role = 'dispatcher' where id = td0149_t.id('u_disp1b');
do $t$
begin
  assert td0149_t.st('n_acct') = 'TSROL', 'J: an accountant hitting an already-cancelled dispatch must get TSROL (0134 returned a no-op success), got ' || coalesce(td0149_t.st('n_acct'), 'success');
  raise notice 'OK: J the allowed-role gate also covers the idempotent no-op path';
end $t$;

-- ===== K: failed transaction, then retry with the same key ==================================================
set td0149.boom = 'activity_logs';
set role authenticated; select td0149_t.tr('z_fail', 'u_disp1', td0149_t.did('d6'), 'cancelled', 'will fail', 'K6'); reset role;
set td0149.boom = 'dispatch_status_transitions';
set role authenticated; select td0149_t.tr('z_fail2', 'u_disp1', td0149_t.did('d7'), 'cancelled', 'will fail late', 'K7'); reset role;
set td0149.boom = '';
do $t$
begin
  assert td0149_t.st('z_fail') = 'P0F11' and td0149_t.st('z_fail2') = 'P0F11', 'K: forced failures must surface';
  assert (select status from public.dispatches where id = td0149_t.did('d6')) = 'assigned' and (select status from public.dispatches where id = td0149_t.did('d7')) = 'assigned', 'K: failed cancels must change nothing';
  assert td0149_t.n_led(td0149_t.did('d6'), 'K6') = 0 and td0149_t.n_led(td0149_t.did('d7'), 'K7') = 0 and td0149_t.n_log(td0149_t.did('d6'), 'cancelled') = 0 and td0149_t.n_log(td0149_t.did('d7'), 'cancelled') = 0, 'K: no ledger or audit row survives';
end $t$;
set role authenticated;
select td0149_t.tr('z_retry', 'u_disp1', td0149_t.did('d6'), 'cancelled', 'retry', 'K6');
select td0149_t.tr('z_retry2', 'u_disp1', td0149_t.did('d7'), 'cancelled', 'retry', 'K7');
select td0149_t.tr('z_again', 'u_disp1', td0149_t.did('d6'), 'cancelled', 'retry', 'K6');
reset role;
do $t$
begin
  assert td0149_t.st('z_retry') is null and td0149_t.st('z_retry2') is null and (td0149_t.res('z_retry') ->> 'idempotent_replay') is null, 'K: the retry after a rolled-back failure is a normal, successful operation';
  assert (td0149_t.res('z_again') ->> 'idempotent_replay') = 'true', 'K: and the next retry replays';
  assert td0149_t.n_led(td0149_t.did('d6'), 'K6') = 1 and td0149_t.n_led(td0149_t.did('d7'), 'K7') = 1 and td0149_t.n_log(td0149_t.did('d6'), 'cancelled') = 1, 'K: exactly one ledger + one audit row after the retry';
  raise notice 'OK: K failed transaction (audit insert / ledger insert) rolls back everything; retry with the same key succeeds once; further retries replay';
end $t$;

-- ===== L: no duplicate rows anywhere ===================================================================
do $t$
begin
  assert (select count(*) from (select dispatch_id, idempotency_key from public.dispatch_status_transitions group by 1, 2 having count(*) > 1) x) = 0, 'L: duplicate ledger rows';
  assert (select count(*) from (select entity_id, action, count(*) from public.activity_logs where action = 'cancelled' group by 1, 2 having count(*) > 1) x) = 0, 'L: a dispatch has two cancelled audit rows';
  raise notice 'OK: L no duplicate ledger rows and no duplicate cancelled audit rows anywhere in the run';
end $t$;

do $t$ begin raise notice 'TEST 0151 REGRESSION PASSED'; end $t$;
rollback;
