-- ============================================================================
-- TEST_STATUS_MATRIX_BACKWARD_CORRECTIONS.sql -- disposable database only.
-- Run via TEST_0130_0133_run.sh.
--
-- Phase 3A.2 clarification round, item 8 ("status matrix review"):
--   * ordinary dispatchers may move FORWARD (or to cancelled) freely, but
--     a BACKWARD move requires owner/admin authority AND a reason.
--   * timestamps are PRESERVED as historical facts across a backward
--     correction -- never cleared, and never overwritten on re-entry.
--   * 'delivered'/'completed' still cannot move backward through an
--     ordinary drag (already enforced -- completed is fully terminal;
--     delivered is subject to the SAME backward-correction gate as any
--     other sequence status, not a special case).
--   * driver-portal/geofence automation remain forward-only (unaffected --
--     they do not call transition_dispatch_status() at all).
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST STATUS MATRIX BACKWARD CORRECTIONS  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql
\i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql

\echo '----- fixture -----'
do $t$
begin
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  values ('d1000000-0000-0000-0000-0000000000b1', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'B1');
  insert into public.trucks (id, organization_id, carrier_id, unit_number)
  values ('c1000000-0000-0000-0000-0000000000b1', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-B1');
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('bb000000-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111', 'LD-BACK', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('bbd10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'bb000000-0000-0000-0000-00000000000b',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000b1', 'd1000000-0000-0000-0000-0000000000b1', 'assigned');
  raise notice 'OK: fixture created.';
end
$t$;

\echo '----- forward progress: ordinary dispatcher, no reason needed, advances all the way to loaded (stamping loaded_at) -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'accepted');
  assert v_res->>'success'='true', format('%s', v_res);
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'en_route_to_pickup');
  assert v_res->>'success'='true', format('%s', v_res);
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'at_pickup');
  assert v_res->>'success'='true', format('%s', v_res);
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'loaded');
  assert v_res->>'success'='true', format('%s', v_res);
  raise notice 'OK: an ordinary dispatcher advances forward through the whole sequence with no reason required at any step.';
end
$t$;

\echo '----- backward correction WITHOUT a reason, as an ordinary dispatcher: rejected -----'
do $t$
begin
  begin
    perform public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'at_pickup');
    raise exception 'TEST FAIL: an ordinary dispatcher moved backward (loaded -> at_pickup) without a reason';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: an ordinary dispatcher cannot move backward at all -- rejected on role, before reason is even considered (%)', sqlerrm;
  end;
end
$t$;
reset role;

\echo '----- backward correction WITHOUT a reason, as OWNER: still rejected (role alone is not enough -- a reason is also required) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
begin
  begin
    perform public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'at_pickup');
    raise exception 'TEST FAIL: owner moved backward without a reason';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: even owner/admin needs a REASON for a backward correction, not just the role (%)', sqlerrm;
  end;
end
$t$;

\echo '----- backward correction WITH a reason, as owner: succeeds; loaded_at is PRESERVED (historical fact, not cleared) -----'
do $t$
declare v_loaded_at_before timestamptz; v_loaded_at_after timestamptz; v_res jsonb;
begin
  select loaded_at into v_loaded_at_before from public.dispatches where id='bbd10000-0000-0000-0000-000000000001';
  assert v_loaded_at_before is not null, 'setup: loaded_at should already be stamped from the forward pass above';

  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'at_pickup', 'dragged too far by mistake, correcting');
  assert v_res->>'success'='true' and v_res->>'new_status'='at_pickup', format('TEST FAIL: backward correction with a reason should have succeeded, got %s', v_res);

  select loaded_at into v_loaded_at_after from public.dispatches where id='bbd10000-0000-0000-0000-000000000001';
  assert v_loaded_at_after = v_loaded_at_before,
    format('TEST FAIL: loaded_at changed on a backward correction (before=%s after=%s) -- timestamps must be preserved as historical facts, never cleared', v_loaded_at_before, v_loaded_at_after);
  raise notice 'OK: owner/admin backward correction with a reason succeeds; loaded_at is PRESERVED unchanged (a historical fact, not cleared by moving back out of that status).';
end
$t$;

\echo '----- moving forward again through the SAME status does not overwrite the preserved historical timestamp -----'
do $t$
declare v_loaded_at_1 timestamptz; v_loaded_at_2 timestamptz; v_res jsonb;
begin
  select loaded_at into v_loaded_at_1 from public.dispatches where id='bbd10000-0000-0000-0000-000000000001';
  perform pg_sleep(1.1);
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'loaded', 'moving forward again after the correction');
  assert v_res->>'success'='true', format('%s', v_res);
  select loaded_at into v_loaded_at_2 from public.dispatches where id='bbd10000-0000-0000-0000-000000000001';
  assert v_loaded_at_1 = v_loaded_at_2,
    format('TEST FAIL: loaded_at was overwritten on re-entry (1=%s 2=%s) -- must stay the ORIGINAL historical moment', v_loaded_at_1, v_loaded_at_2);
  raise notice 'OK: re-entering "loaded" a second time does NOT overwrite the original loaded_at -- confirmed idempotent, historical-fact semantics hold across a full backward-then-forward cycle.';
end
$t$;

\echo '----- delivered -> an earlier active status also requires owner/admin + reason (not a special case, same gate) -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'en_route_to_delivery');
  assert v_res->>'success'='true', format('%s', v_res);
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'at_delivery');
  assert v_res->>'success'='true', format('%s', v_res);
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'delivered');
  assert v_res->>'success'='true', format('%s', v_res);
end
$t$;
reset role;

select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
begin
  begin
    perform public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'at_delivery');
    raise exception 'TEST FAIL: an ordinary dispatcher moved delivered -> at_delivery (backward) without owner/admin + reason';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: delivered -> at_delivery (backward) is rejected for an ordinary dispatcher, same gate as any other backward move -- delivered is not a silently-permissive special case (%)', sqlerrm;
  end;
end
$t$;
reset role;

\echo '----- completed remains fully terminal regardless of role/reason (owner/admin cannot move it backward either) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res jsonb;
begin
  v_res := public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'completed', 'settling this dispatch');
  assert v_res->>'success'='true', format('%s', v_res);
  begin
    perform public.transition_dispatch_status('bbd10000-0000-0000-0000-000000000001', 'delivered', 'even owner/admin cannot undo completed');
    raise exception 'TEST FAIL: completed -> delivered succeeded, even for owner/admin with a reason -- completed must be fully terminal';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: completed remains fully terminal even for owner/admin with a reason (%)', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '################  TEST STATUS MATRIX BACKWARD CORRECTIONS PASSED  ################'
