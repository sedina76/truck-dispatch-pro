-- =============================================================================
-- defect_repro.sql -- PROPOSAL 0149: reproduces the live defect on the 0129 BASELINE.
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY.
-- Run through tests.py only, while the DEFECTIVE (0129) functions are installed.
-- One transaction that ENDS IN ROLLBACK.
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

do $t$
declare
  v_state text; v_msg text; v_hint text;
  v_dispatch uuid := td0149_t.id('d_repro');
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);

  -- create_dispatch on a perfectly valid request fails at step 5 with the reported error.
  begin
    perform public.create_dispatch(td0149_t.id('l1'), td0149_t.id('ca'), td0149_t.id('ta1'), td0149_t.id('da1'));
    raise exception 'DEFECT_NOT_REPRODUCED: create_dispatch succeeded on the 0129 baseline';
  exception when others then
    if sqlerrm like 'DEFECT_NOT_REPRODUCED%' then raise; end if;
    get stacked diagnostics v_state := returned_sqlstate, v_msg := message_text, v_hint := pg_exception_hint;
  end;
  assert v_state = '42883' and v_msg = 'operator does not exist: dispatch_status = text',
    format('create_dispatch did not fail with the reported error (got %s / %s)', v_state, v_msg);
  assert not exists (select 1 from public.dispatches where load_id = td0149_t.id('l1')), 'failed create left a dispatch row';
  raise notice 'REPRO create_dispatch: % / % / hint=%', v_state, v_msg, v_hint;

  -- cancel_dispatch fails the same way at its load-revert UPDATE.
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values (v_dispatch, td0149_t.id('o1'), td0149_t.id('l2'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'), 'assigned');
  begin
    perform public.cancel_dispatch(v_dispatch, 'repro');
    raise exception 'DEFECT_NOT_REPRODUCED: cancel_dispatch succeeded on the 0129 baseline';
  exception when others then
    if sqlerrm like 'DEFECT_NOT_REPRODUCED%' then raise; end if;
    get stacked diagnostics v_state := returned_sqlstate, v_msg := message_text, v_hint := pg_exception_hint;
  end;
  assert v_state = '42883' and v_msg = 'operator does not exist: dispatch_status = text',
    format('cancel_dispatch did not fail with the reported error (got %s / %s)', v_state, v_msg);
  assert (select status from public.dispatches where id = v_dispatch) = 'assigned', 'failed cancel changed the dispatch (atomicity)';
  raise notice 'REPRO cancel_dispatch: % / %', v_state, v_msg;
  raise notice 'DEFECT REPRODUCED ON BASELINE';
end $t$;
rollback;
