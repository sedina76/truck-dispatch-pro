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
-- defect_repro.sql -- PROPOSAL 0151 disposable-database script.
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY. Run through tests.py only (it substitutes the fixture marker below).
-- Runs on the REAL 0130..0147 + 0149 + 0150 chain; ONE transaction that ENDS IN ROLLBACK.
-- =============================================================================
\set ON_ERROR_STOP on
begin;
set client_min_messages = notice;
-- @@FIXTURE@@

-- Runs against the BASELINE (0134) function. Each block prints DEFECT-CONFIRMED (replay before authorization) or NOT-A-DEFECT.
-- "Victim" = a dispatcher of org 1 who cancels a dispatch with a random key; "attacker" = someone who knows BOTH the dispatch UUID and the key.
set role authenticated;
select td0149_t.mk('v1', 1);
select td0149_t.tr('v_orig', 'u_disp1', td0149_t.did('v1'), 'cancelled', 'victim reason', 'KEY-VICTIM-0001');
select td0149_t.tr('x_other_org', 'u_disp2', td0149_t.did('v1'), 'cancelled', 'probe', 'KEY-VICTIM-0001');       -- another organization
select td0149_t.tr('x_other_org_owner', 'u_owner2', td0149_t.did('v1'), 'cancelled', 'probe', 'KEY-VICTIM-0001');
select td0149_t.tr('x_acct', 'u_acct1', td0149_t.did('v1'), 'cancelled', 'probe', 'KEY-VICTIM-0001');              -- same org, role not allowed to transition
select td0149_t.tr('x_viewer', 'u_viewer1', td0149_t.did('v1'), 'cancelled', 'probe', 'KEY-VICTIM-0001');
select td0149_t.tr('x_wrong_status', 'u_disp1', td0149_t.did('v1'), 'accepted', null, 'KEY-VICTIM-0001');          -- same key, DIFFERENT requested status
select td0149_t.tr('x_unauth', null, td0149_t.did('v1'), 'cancelled', 'probe', 'KEY-VICTIM-0001');
select td0149_t.tr('x_nokey_other_org', 'u_disp2', td0149_t.did('v1'), 'cancelled', 'probe', 'NO-SUCH-KEY-000000');    -- foreign dispatch, key that does not exist
reset role;
-- role downgraded AFTER the original success
update public.profiles set role = 'viewer' where id = td0149_t.id('u_disp1b');
set role authenticated;
select td0149_t.tr('x_downgraded', 'u_disp1b', td0149_t.did('v1'), 'cancelled', 'probe', 'KEY-VICTIM-0001');
reset role;
update public.profiles set organization_id = null where id = td0149_t.id('u_disp1b');
set role authenticated;
select td0149_t.tr('x_removed', 'u_disp1b', td0149_t.did('v1'), 'cancelled', 'probe', 'KEY-VICTIM-0001');
reset role;
do $t$
declare t text; r jsonb;
begin
  assert td0149_t.st('v_orig') is null, 'setup: the original cancel must succeed';
  for t in select unnest(array['x_other_org','x_other_org_owner','x_acct','x_viewer','x_downgraded']) loop
    if td0149_t.st(t) is null and (td0149_t.res(t) ->> 'idempotent_replay') = 'true' then
      raise notice 'DEFECT-CONFIRMED: % received the cached result of another caller''s cancellation: %', t, td0149_t.res(t);
    else
      raise notice 'NOT-A-DEFECT: % was refused (%)', t, td0149_t.st(t);
    end if;
  end loop;
  if td0149_t.st('x_wrong_status') is null and (td0149_t.res('x_wrong_status') ->> 'new_status') = 'cancelled' then
    raise notice 'DEFECT-CONFIRMED: same key with a DIFFERENT requested status (accepted) silently returned the stale cancelled result';
  else raise notice 'NOT-A-DEFECT: x_wrong_status refused (%)', td0149_t.st('x_wrong_status'); end if;
  raise notice '%: unauthenticated replay -> %', case when td0149_t.st('x_unauth') is null then 'DEFECT-CONFIRMED' else 'NOT-A-DEFECT' end, coalesce(td0149_t.st('x_unauth'), 'success');
  raise notice '%: user removed from the organization -> %', case when td0149_t.st('x_removed') is null then 'DEFECT-CONFIRMED' else 'NOT-A-DEFECT' end, coalesce(td0149_t.st('x_removed'), 'success');
  raise notice 'INFO: cross-org replay message with a REAL key vs a NON-EXISTENT key: [%] vs [%]', coalesce(td0149_t.st('x_other_org'), 'success'), coalesce(td0149_t.st('x_nokey_other_org'), 'success');
end $t$;
rollback;
