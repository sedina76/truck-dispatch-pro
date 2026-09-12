-- ============================================================================
-- TEST_CANCELLATION_AUDIT_DEDUP.sql -- disposable database only.
-- Run via TEST_0130_0133_run.sh.
--
-- Phase 3A.2 clarification round, item 7: "cancellation audit duplication
-- check." transition_dispatch_status() (0134) delegates cancellation
-- entirely to cancel_dispatch() (0129), which ALREADY writes its own
-- log_activity('dispatch', ..., 'cancelled', {reason}, ...) event
-- (confirmed by reading 0129's body, not assumed). An earlier draft of
-- transition_dispatch_status() ALSO wrote an unconditional 'status_changed'
-- event afterward regardless of path -- a real bug producing TWO
-- activity_logs rows per cancellation, found and fixed during this round.
-- This test asserts, by EXACT count, that exactly ONE authoritative
-- cancellation audit event is ever written, through every reachable path.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST CANCELLATION AUDIT DEDUP  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql
\i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
\i migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql

\echo '----- fixture: a fresh, live dispatch -----'
do $t$
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('ca000000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'LD-CADUP', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('ca0d0000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'ca000000-0000-0000-0000-00000000000a',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');
  raise notice 'OK: fixture created.';
end
$t$;

\echo '----- cancel via transition_dispatch_status() (the board''s own path) -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
do $t$
declare
  v_before_activity int;
  v_after_activity int;
  v_cancelled_rows int;
  v_status_changed_rows int;
  v_res jsonb;
begin
  select count(*) into v_before_activity from public.activity_logs where entity_id='ca0d0000-0000-0000-0000-00000000000a';

  v_res := public.transition_dispatch_status('ca0d0000-0000-0000-0000-00000000000a', 'cancelled', 'exact-count dedup test');
  assert v_res->>'success' = 'true', format('setup: cancellation itself should succeed, got %s', v_res);

  select count(*) into v_after_activity from public.activity_logs where entity_id='ca0d0000-0000-0000-0000-00000000000a';
  select count(*) into v_cancelled_rows from public.activity_logs where entity_id='ca0d0000-0000-0000-0000-00000000000a' and action='cancelled';
  select count(*) into v_status_changed_rows from public.activity_logs where entity_id='ca0d0000-0000-0000-0000-00000000000a' and action='status_changed';

  assert v_after_activity - v_before_activity = 1,
    format('TEST FAIL: expected EXACTLY 1 new activity_logs row for this cancellation, got %s (duplicate audit event bug)', v_after_activity - v_before_activity);
  assert v_cancelled_rows = 1,
    format('TEST FAIL: expected exactly 1 "cancelled" activity_logs row (written by cancel_dispatch() itself), got %s', v_cancelled_rows);
  assert v_status_changed_rows = 0,
    format('TEST FAIL: transition_dispatch_status() must NOT ALSO write a "status_changed" row for a cancellation -- found %s (this is the exact bug this test exists to catch)', v_status_changed_rows);

  raise notice 'OK: exactly ONE activity_logs row for the cancellation (action=cancelled, written by cancel_dispatch() itself) -- transition_dispatch_status() does not duplicate it.';
end
$t$;

\echo '----- confirm the reason reached the SOLE audit row (proves it is cancel_dispatch()''s own row, not a lost/replaced one) -----'
do $t$
declare v_changes jsonb;
begin
  select changes into v_changes from public.activity_logs where entity_id='ca0d0000-0000-0000-0000-00000000000a' and action='cancelled';
  assert v_changes->>'reason' = 'exact-count dedup test', format('TEST FAIL: the sole cancellation audit row does not carry the reason, got %s', v_changes);
  raise notice 'OK: the sole audit row carries the reason, confirming it is cancel_dispatch()''s own authoritative event.';
end
$t$;

\echo '----- other categories item 7 asks about: no duplicate transition-ledger / status-timestamp writes either -----'
do $t$
declare v_ledger_rows int; v_cancelled_at_1 timestamptz; v_cancelled_at_2 timestamptz;
begin
  -- transition-ledger (dispatch_status_transitions) is written ONLY when an
  -- idempotency key is supplied -- confirm zero rows here (none was passed
  -- above), i.e. no ledger row masquerading as a second audit trail.
  select count(*) into v_ledger_rows from public.dispatch_status_transitions where dispatch_id='ca0d0000-0000-0000-0000-00000000000a';
  assert v_ledger_rows = 0, format('TEST FAIL: expected 0 dispatch_status_transitions rows (no idempotency key was used), got %s', v_ledger_rows);

  -- cancelled_at is idempotent (coalesce) even across a second, no-op
  -- cancellation attempt -- not a "second cancellation timestamp".
  select cancelled_at into v_cancelled_at_1 from public.dispatches where id='ca0d0000-0000-0000-0000-00000000000a';
  perform public.transition_dispatch_status('ca0d0000-0000-0000-0000-00000000000a', 'cancelled', 'redundant cancel attempt');
  select cancelled_at into v_cancelled_at_2 from public.dispatches where id='ca0d0000-0000-0000-0000-00000000000a';
  assert v_cancelled_at_1 = v_cancelled_at_2, 'TEST FAIL: cancelled_at changed on a redundant (already-cancelled) cancellation call';

  -- and that redundant no-op call must not have written ANOTHER audit row either.
  declare v_total_activity int;
  begin
    select count(*) into v_total_activity from public.activity_logs where entity_id='ca0d0000-0000-0000-0000-00000000000a';
    assert v_total_activity = 1, format('TEST FAIL: a redundant (already-cancelled) cancellation call wrote an additional audit row -- total is %s, expected 1', v_total_activity);
  end;

  raise notice 'OK: no duplicate transition-ledger row, no duplicate/altered cancelled_at, no duplicate audit row on a redundant re-cancel attempt.';
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '################  TEST CANCELLATION AUDIT DEDUP PASSED  ################'
