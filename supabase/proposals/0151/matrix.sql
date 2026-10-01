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
-- matrix.sql -- PROPOSAL 0151 differential matrix: NORMAL transitions must behave identically under 0134 and 0151.
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY. Run through tests.py only, once against the 0134 function and once
-- against the 0151 function on identical databases; tests.py compares the printed rows. ONE transaction that ENDS IN ROLLBACK.
-- Deliberately EXCLUDED (intended behaviour changes): replay by another organization / removed / downgraded caller, same key with a
-- different status, and an unauthorized role hitting the no-op path.
-- =============================================================================
\set ON_ERROR_STOP on
begin;
set client_min_messages = notice;
-- @@FIXTURE@@

create table td0149_t.mx (seq bigserial primary key, tag text, state text, msg text, result jsonb, dstatus text, lstatus text, nlog bigint, nled bigint);
grant select, insert on td0149_t.mx to authenticated;
grant usage on sequence td0149_t.mx_seq_seq to authenticated;
-- t(): call the RPC exactly as tr() does, then record the observable outcome (dispatch ids are random, so results are normalised)
create function td0149_t.t(p_tag text, p_user text, p_dispatch uuid, p_status public.dispatch_status, p_reason text default null, p_key text default null) returns void
language plpgsql as $$
declare v_state text; v_msg text; v_res jsonb; v_ds text; v_ls text; v_nl bigint; v_nk bigint;
begin
  perform set_config('test.current_uid', case when p_user is null then '' else td0149_t.id(p_user)::text end, false);
  begin
    v_res := public.transition_dispatch_status(p_dispatch, p_status, p_reason, p_key);
  exception when others then
    get stacked diagnostics v_state := returned_sqlstate, v_msg := message_text;
  end;
  select d.status::text, l.status::text into v_ds, v_ls from public.dispatches d left join public.loads l on l.id = d.load_id where d.id = p_dispatch;
  select count(*) into v_nl from public.activity_logs where entity_id = p_dispatch;
  select count(*) into v_nk from public.dispatch_status_transitions where dispatch_id = p_dispatch;
  insert into td0149_t.mx (tag, state, msg, result, dstatus, lstatus, nlog, nled)
  values (p_tag, v_state, regexp_replace(coalesce(v_msg, ''), '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<uuid>', 'g'), v_res - 'dispatch_id', v_ds, v_ls, v_nl, v_nk);
end $$;
grant execute on function td0149_t.t(text, text, uuid, public.dispatch_status, text, text) to authenticated;

set role authenticated;
select td0149_t.mk('d' || g, g) from generate_series(1, 14) g;
reset role;

-- S1 forward chain (dispatcher) with and without keys, then invalid shapes
set role authenticated;
select td0149_t.t('s1_accepted', 'u_disp1', td0149_t.did('d1'), 'accepted', null, 'S1-K1');
select td0149_t.t('s1_replay', 'u_disp1', td0149_t.did('d1'), 'accepted', null, 'S1-K1');
select td0149_t.t('s1_noop', 'u_disp1', td0149_t.did('d1'), 'accepted', null, null);
select td0149_t.t('s1_pickup', 'u_disp1', td0149_t.did('d1'), 'en_route_to_pickup');
select td0149_t.t('s1_at_pickup', 'u_owner1', td0149_t.did('d1'), 'at_pickup', null, 'S1-K2');
select td0149_t.t('s1_loaded', 'u_admin1', td0149_t.did('d1'), 'loaded');
select td0149_t.t('s1_transit', 'u_disp1', td0149_t.did('d1'), 'en_route_to_delivery');
select td0149_t.t('s1_at_delivery', 'u_disp1', td0149_t.did('d1'), 'at_delivery');
select td0149_t.t('s1_delivered', 'u_disp1', td0149_t.did('d1'), 'delivered', null, 'S1-K3');
select td0149_t.t('s1_completed', 'u_disp1', td0149_t.did('d1'), 'completed');
select td0149_t.t('s1_invalid_back', 'u_owner1', td0149_t.did('d1'), 'loaded', 'x');
select td0149_t.t('s1_cancel_completed', 'u_disp1', td0149_t.did('d1'), 'cancelled', 'x');
reset role;

-- S2 backward corrections
set local session_replication_role = replica; update public.dispatches set status = 'loaded' where id = td0149_t.did('d2'); reset session_replication_role;
set role authenticated;
select td0149_t.t('s2_disp_back', 'u_disp1', td0149_t.did('d2'), 'assigned', 'oops');
select td0149_t.t('s2_owner_noreason', 'u_owner1', td0149_t.did('d2'), 'assigned');
select td0149_t.t('s2_owner_blank', 'u_owner1', td0149_t.did('d2'), 'assigned', '   ');
select td0149_t.t('s2_owner_ok', 'u_owner1', td0149_t.did('d2'), 'assigned', 'entered wrong status', 'S2-K1');
select td0149_t.t('s2_owner_replay', 'u_owner1', td0149_t.did('d2'), 'assigned', 'entered wrong status', 'S2-K1');

-- S3 cancellations by every role
select td0149_t.t('s3_disp_cancel', 'u_disp1', td0149_t.did('d3'), 'cancelled', 'gone', 'S3-K1');
select td0149_t.t('s3_replay', 'u_disp1', td0149_t.did('d3'), 'cancelled', 'gone', 'S3-K1');
select td0149_t.t('s3_again_newkey', 'u_disp1', td0149_t.did('d3'), 'cancelled', 'gone again', 'S3-K2');
select td0149_t.t('s3_again_nokey', 'u_disp1', td0149_t.did('d3'), 'cancelled');
select td0149_t.t('s3_owner_cancel', 'u_owner1', td0149_t.did('d4'), 'cancelled', 'owner cancel');
select td0149_t.t('s3_admin_cancel', 'u_admin1', td0149_t.did('d5'), 'cancelled', null, 'S3-K3');
select td0149_t.t('s3_acct', 'u_acct1', td0149_t.did('d6'), 'cancelled', 'x', 'S3-K4');
select td0149_t.t('s3_viewer', 'u_viewer1', td0149_t.did('d6'), 'cancelled');
select td0149_t.t('s3_driver', 'u_driver1', td0149_t.did('d6'), 'cancelled');
select td0149_t.t('s3_anon', null, td0149_t.did('d6'), 'cancelled');
reset role;
set local session_replication_role = replica; update public.dispatches set status = 'delivered' where id = td0149_t.did('d7'); reset session_replication_role;
set role authenticated;
select td0149_t.t('s3_cancel_delivered', 'u_disp1', td0149_t.did('d7'), 'cancelled', 'x');

-- S4 reactivation
select td0149_t.t('s4_disp_reopen', 'u_disp1', td0149_t.did('d3'), 'assigned', 'reopen');
select td0149_t.t('s4_owner_noreason', 'u_owner1', td0149_t.did('d3'), 'assigned');
select td0149_t.t('s4_owner_reopen', 'u_owner1', td0149_t.did('d3'), 'assigned', 'customer back', 'S4-K1');
select td0149_t.t('s4_owner_replay', 'u_owner1', td0149_t.did('d3'), 'assigned', 'customer back', 'S4-K1');
select td0149_t.t('s4_forward_after', 'u_disp1', td0149_t.did('d3'), 'accepted');

-- S5 not found / cross-org / no auth (no keys)
select td0149_t.t('s5_missing', 'u_disp1', td0149_t.id('nope'), 'cancelled');
select td0149_t.t('s5_cross_org', 'u_disp2', td0149_t.did('d8'), 'cancelled', 'x');
select td0149_t.t('s5_cross_owner', 'u_owner2', td0149_t.did('d8'), 'accepted');
select td0149_t.t('s5_anon', null, td0149_t.did('d8'), 'accepted');

-- S6 unauthorized roles on real (non-no-op) transitions
select td0149_t.t('s6_acct', 'u_acct1', td0149_t.did('d9'), 'accepted');
select td0149_t.t('s6_viewer', 'u_viewer1', td0149_t.did('d9'), 'accepted', null, 'S6-K1');
select td0149_t.t('s6_driver', 'u_driver1', td0149_t.did('d9'), 'accepted');

-- S7 keys: same user / different authorized user / no key
select td0149_t.t('s7_first', 'u_disp1', td0149_t.did('d10'), 'accepted', null, 'S7-K1');
select td0149_t.t('s7_same_user', 'u_disp1', td0149_t.did('d10'), 'accepted', null, 'S7-K1');
select td0149_t.t('s7_other_user', 'u_owner1', td0149_t.did('d10'), 'accepted', null, 'S7-K1');
select td0149_t.t('s7_next', 'u_disp1', td0149_t.did('d10'), 'en_route_to_pickup', null, 'S7-K2');
select td0149_t.t('s7_no_key_twice_a', 'u_disp1', td0149_t.did('d11'), 'accepted');
select td0149_t.t('s7_no_key_twice_b', 'u_disp1', td0149_t.did('d11'), 'accepted');
select td0149_t.t('s7_cancel_no_key', 'u_disp1', td0149_t.did('d12'), 'cancelled', 'no key');
reset role;

select 'ROW', seq, tag, coalesce(state, ''), msg, coalesce(result::text, ''), coalesce(dstatus, ''), coalesce(lstatus, ''), nlog, nled from td0149_t.mx order by seq;
rollback;
