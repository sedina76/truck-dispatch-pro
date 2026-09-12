-- ============================================================================
-- TEST_0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
-- disposable database only. Run via TEST_0130_0133_run.sh.
--
-- Phase 3A.1 hotfix verification: trailer column privileges (item A) and
-- transition_dispatch_status() (items B/C/D).
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0134  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql
\i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql

\echo '===== PART A: trailer column privileges ====='

\echo '----- A1. catalog proof: primary key / organization / creation timestamp / ownership are NOT authenticated-updatable -----'
do $t$
declare v_pk boolean; v_org boolean; v_created boolean; v_updated boolean; v_carrier boolean; v_scope boolean; v_unit boolean;
begin
  select has_column_privilege('authenticated','public.trailers','id','UPDATE') into v_pk;
  select has_column_privilege('authenticated','public.trailers','organization_id','UPDATE') into v_org;
  select has_column_privilege('authenticated','public.trailers','created_at','UPDATE') into v_created;
  select has_column_privilege('authenticated','public.trailers','updated_at','UPDATE') into v_updated;
  select has_column_privilege('authenticated','public.trailers','carrier_id','UPDATE') into v_carrier;
  select has_column_privilege('authenticated','public.trailers','ownership_scope','UPDATE') into v_scope;
  select has_column_privilege('authenticated','public.trailers','unit_number','UPDATE') into v_unit;
  assert v_pk = false, 'TEST FAIL: authenticated can update trailers.id';
  assert v_org = false, 'TEST FAIL: authenticated can update trailers.organization_id';
  assert v_created = false, 'TEST FAIL: authenticated can update trailers.created_at';
  assert v_updated = false, 'TEST FAIL: authenticated can update trailers.updated_at';
  assert v_carrier = false, 'TEST FAIL: authenticated can update trailers.carrier_id';
  assert v_scope = false, 'TEST FAIL: authenticated can update trailers.ownership_scope';
  assert v_unit = true, 'TEST FAIL: authenticated cannot update trailers.unit_number (should be able to)';
  raise notice 'OK: id/organization_id/created_at/updated_at/carrier_id/ownership_scope all NOT authenticated-updatable; unit_number is.';
end
$t$;

\echo '----- A2. legitimate trailer edits still work (as an authenticated dispatcher, every field the real edit form submits) -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_after record;
begin
  -- exactly the field set src/app/(app)/trailers/actions.ts's trailerValues()
  -- submits on a real edit, MINUS carrier_id (the compatibility fix -- see
  -- PART A3 below for proof that including it would fail).
  update public.trailers set
    unit_number = 'TRL-A1-EDITED',
    trailer_type = 'reefer',
    length_ft = 48,
    license_plate = 'TX-999',
    license_state = 'TX',
    ownership_type = 'leased',
    status = 'active',
    registration_expiry_date = current_date + interval '6 months',
    annual_inspection_expiry_date = current_date + interval '3 months'
  where id = 'e1000000-0000-0000-0000-000000000001';
  select unit_number, trailer_type, ownership_type into v_after from public.trailers where id = 'e1000000-0000-0000-0000-000000000001';
  assert v_after.unit_number = 'TRL-A1-EDITED' and v_after.trailer_type = 'reefer' and v_after.ownership_type = 'leased',
    format('TEST FAIL: a legitimate multi-field trailer edit did not fully apply, got %s', v_after);
  raise notice 'OK: a legitimate trailer edit (exactly the real form''s field set) succeeds in full.';
end
$t$;

\echo '----- A3. the pre-existing compatibility bug this hotfix would have hit: including carrier_id in an ordinary edit payload -----'
do $t$
begin
  begin
    update public.trailers set unit_number = 'TRL-A1-EDITED-2', carrier_id = carrier_id where id = 'e1000000-0000-0000-0000-000000000001';
    raise exception 'TEST FAIL: an UPDATE naming carrier_id in its SET list succeeded for an ordinary dispatcher, even though the value is unchanged -- this proves the application-layer fix (removing carrier_id from updateTrailer''s payload) is NECESSARY, not optional.';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK (confirms the compatibility bug this hotfix''s application fix addresses): naming carrier_id in the SET list rejects the WHOLE statement even when the value is unchanged (%) -- column privilege is checked against the SET list, not the actual value delta.', sqlerrm;
  end;
end
$t$;

\echo '----- A4. vin and notes remain updatable (schema columns, not yet exposed by any form, left open) -----'
do $t$
begin
  update public.trailers set vin = '1FTFW1ET1EKA12345', notes = 'routine note' where id = 'e1000000-0000-0000-0000-000000000001';
  raise notice 'OK: vin and notes remain updatable.';
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '===== PART B/C/D: transition_dispatch_status() ====='

\echo '----- D1. transition matrix -- direct, isolated proof (all combinations that matter) -----'
do $t$
begin
  assert public.is_valid_dispatch_status_transition('assigned','accepted');
  assert public.is_valid_dispatch_status_transition('accepted','assigned');       -- backward correction preserved
  assert public.is_valid_dispatch_status_transition('loaded','assigned');         -- multi-step backward correction preserved
  assert public.is_valid_dispatch_status_transition('assigned','loaded');         -- multi-step forward (board free-drag) preserved
  assert public.is_valid_dispatch_status_transition('at_delivery','delivered');
  assert public.is_valid_dispatch_status_transition('delivered','at_delivery');   -- documented "moving out of delivered" correction
  assert public.is_valid_dispatch_status_transition('delivered','completed');
  assert not public.is_valid_dispatch_status_transition('completed','delivered'); -- completed is terminal
  assert not public.is_valid_dispatch_status_transition('completed','assigned');
  assert not public.is_valid_dispatch_status_transition('assigned','completed');  -- completed only reachable from delivered
  assert public.is_valid_dispatch_status_transition('assigned','cancelled');
  assert public.is_valid_dispatch_status_transition('delivered','cancelled');     -- matrix permits attempting it; cancel_dispatch() itself is the authority that will actually reject it
  assert public.is_valid_dispatch_status_transition('cancelled','assigned');      -- the ONE permitted reactivation shape
  assert not public.is_valid_dispatch_status_transition('cancelled','loaded');
  assert not public.is_valid_dispatch_status_transition('cancelled','en_route_to_pickup');
  assert public.is_valid_dispatch_status_transition('assigned','assigned');       -- idempotent no-op shape
  raise notice 'OK: transition matrix matches the documented design exactly.';
end
$t$;

\echo '----- B/C2. fixture: two loads/dispatches for RPC behavior tests -----'
do $t$
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('e0000000-0000-0000-0000-00000000000e', '11111111-1111-1111-1111-111111111111', 'LD-E1', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('e0d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e0000000-0000-0000-0000-00000000000e',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');
  raise notice 'OK: fixture E1/e0d1 created (load claimed carrier A1 via the atomic-claim guard).';
end
$t$;

\echo '----- B/C3. unauthenticated call rejected -----'
select set_config('test.current_uid', '', false) as note;
set role authenticated;
do $t$
begin
  begin
    perform public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'accepted');
    raise exception 'TEST FAIL: unauthenticated call succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: unauthenticated call rejected (%)', sqlerrm;
  end;
end
$t$;
reset role;

-- catalog proof the EXECUTE grant genuinely covers `authenticated` (not
-- merely working because these tests happen to run as a superuser)
do $t$
begin
  assert has_function_privilege('authenticated', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'EXECUTE'),
    'TEST FAIL: authenticated lacks EXECUTE on transition_dispatch_status(...)';
  raise notice 'OK: authenticated genuinely holds EXECUTE on transition_dispatch_status(...) (catalog-confirmed, not just tested by proxy).';
end
$t$;

\echo '----- B/C4. ordinary forward transition succeeds, stamps the right timestamp, writes an audit event -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res jsonb; v_ts timestamptz; v_audit_cnt int;
begin
  select count(*) into v_audit_cnt from public.activity_logs where entity_id='e0d10000-0000-0000-0000-000000000001' and action='status_changed';
  v_res := public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'accepted');
  assert v_res->>'success' = 'true' and v_res->>'old_status'='assigned' and v_res->>'new_status'='accepted' and (v_res->>'no_op')::boolean = false,
    format('TEST FAIL: unexpected result for assigned->accepted: %s', v_res);

  v_res := public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'en_route_to_pickup');
  select en_route_pickup_at into v_ts from public.dispatches where id='e0d10000-0000-0000-0000-000000000001';
  assert v_ts is not null, 'TEST FAIL: en_route_pickup_at was not stamped';

  assert (select count(*) from public.activity_logs where entity_id='e0d10000-0000-0000-0000-000000000001' and action='status_changed') = v_audit_cnt + 2,
    'TEST FAIL: expected exactly 2 new audit events for the 2 transitions above';
  raise notice 'OK: ordinary forward transitions succeed, stamp the right operational timestamp, write exactly one audit event each.';
end
$t$;

\echo '----- B/C5. idempotent replay via p_idempotency_key -----'
do $t$
declare v_res1 jsonb; v_res2 jsonb; v_audit_before int; v_audit_after int;
begin
  select count(*) into v_audit_before from public.activity_logs where entity_id='e0d10000-0000-0000-0000-000000000001' and action='status_changed';
  v_res1 := public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'at_pickup', null, 'idem-key-1');
  v_res2 := public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'at_pickup', null, 'idem-key-1');
  select count(*) into v_audit_after from public.activity_logs where entity_id='e0d10000-0000-0000-0000-000000000001' and action='status_changed';
  assert v_audit_after = v_audit_before + 1, format('TEST FAIL: expected exactly 1 new audit event across BOTH calls (the second is a pure replay), got %s new', v_audit_after - v_audit_before);
  assert v_res2->>'idempotent_replay' = 'true', 'TEST FAIL: the second call was not flagged as an idempotent replay';
  assert v_res1->>'new_status' = v_res2->>'new_status', 'TEST FAIL: replayed result differs from the original';
  raise notice 'OK: a retried call with the same idempotency key replays the cached result -- exactly one audit event, exactly one status change, for two calls.';
end
$t$;

\echo '----- B/C6. invalid transition shape rejected (matrix) -----'
do $t$
begin
  begin
    perform public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'completed');
    raise exception 'TEST FAIL: at_pickup -> completed succeeded (matrix should reject: completed only reachable from delivered)';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: invalid transition shape rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- B/C7. ordinary dispatcher CANNOT reactivate a cancelled dispatch -----'
do $t$
begin
  perform public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'cancelled', 'test cancellation');
  begin
    perform public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'assigned', 'dispatcher trying to reactivate');
    raise exception 'TEST FAIL: an ordinary dispatcher reactivated a cancelled dispatch';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: ordinary dispatcher cannot reactivate a cancelled dispatch (%)', sqlerrm;
  end;
end
$t$;
reset role;

\echo '----- B/C8. owner/admin reactivation requires a reason -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
begin
  begin
    perform public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'assigned');
    raise exception 'TEST FAIL: owner reactivated without a reason';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: owner reactivation without a reason is rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- B/C9. owner/admin reactivation succeeds with a reason (same carrier) -----'
do $t$
declare v_res jsonb;
begin
  v_res := public.transition_dispatch_status('e0d10000-0000-0000-0000-000000000001', 'assigned', 'owner-approved reactivation, adversarial test suite');
  assert v_res->>'success'='true' and (v_res->>'reactivated')::boolean = true and v_res->>'new_status'='assigned',
    format('TEST FAIL: owner reactivation with a reason should have succeeded, got %s', v_res);
  raise notice 'OK: owner/admin reactivation with a reason succeeds.';
end
$t$;

\echo '----- B/C10. reactivation onto a load whose carrier has since moved on is rejected -----'
do $t$
declare v_load2 uuid := 'e2000000-0000-0000-0000-00000000000e';
declare v_disp_old uuid := 'e2d10000-0000-0000-0000-000000000001';
declare v_disp_new uuid := 'e2d20000-0000-0000-0000-000000000002';
begin
  -- fresh A1 equipment: the B/C2 fixture (e0d1...) is active again after
  -- B/C9's reactivation and already holds the standard A1 driver/truck --
  -- 0054's partial unique indexes (faithfully reproduced) forbid a second
  -- simultaneously-active dispatch on them.
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  values ('d1000000-0000-0000-0000-0000000000e2', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-E2');
  insert into public.trucks (id, organization_id, carrier_id, unit_number)
  values ('c1000000-0000-0000-0000-0000000000e2', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-E2');

  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values (v_load2, '11111111-1111-1111-1111-111111111111', 'LD-E2', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values (v_disp_old, '11111111-1111-1111-1111-111111111111', v_load2,
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000e2', 'd1000000-0000-0000-0000-0000000000e2', 'assigned');
  perform public.transition_dispatch_status(v_disp_old, 'cancelled', 'making room for a same-load same-carrier reassignment scenario');
end
$t$;

-- NOTE: loads.carrier_id is now permanently A1 (immutable once claimed,
-- decision 1) -- there is no live path to make a SECOND, different-
-- carrier dispatch exist on this same load to test the "carrier moved
-- on" mismatch directly via ordinary writes; the guard trigger correctly
-- rejects it too, exactly as it should. Simulate the historical-
-- inconsistency case the only way it could ever arise (raw, out-of-band
-- data, guard trigger disabled) -- superuser-only, so drop back out of
-- `authenticated` for this one corruption-injection statement, then
-- resume as the SAME authenticated owner session for the actual test.
reset role;
alter table public.dispatches disable trigger dispatches_guard_carrier_scope;
update public.dispatches
   set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002',
       truck_id = 'c2000000-0000-0000-0000-000000000002',
       driver_id = 'd2000000-0000-0000-0000-000000000002'
 where id = 'e2d10000-0000-0000-0000-000000000001';
alter table public.dispatches enable trigger dispatches_guard_carrier_scope;
set role authenticated;

do $t$
declare v_disp_old uuid := 'e2d10000-0000-0000-0000-000000000001';
begin
  begin
    perform public.transition_dispatch_status(v_disp_old, 'assigned', 'attempting reactivation onto a mismatched carrier');
    raise exception 'TEST FAIL: reactivation succeeded despite the dispatch''s carrier no longer matching the load''s carrier';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: reactivation is rejected when the dispatch''s carrier no longer matches the load''s carrier (%)', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '----- B/C11. delegation to cancel_dispatch(): a delivered dispatch cannot be "cancelled" via this RPC either (no duplicated/weakened rule) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_load3 uuid := 'e3000000-0000-0000-0000-00000000000e';
declare v_disp3 uuid := 'e3d10000-0000-0000-0000-000000000001';
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values (v_load3, '11111111-1111-1111-1111-111111111111', 'LD-E3', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values (v_disp3, '11111111-1111-1111-1111-111111111111', v_load3,
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'delivered');
  begin
    perform public.transition_dispatch_status(v_disp3, 'cancelled', 'attempting to cancel a delivered dispatch');
    raise exception 'TEST FAIL: a delivered dispatch was cancelled via transition_dispatch_status()';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    assert sqlerrm like '%delivered or completed%', format('TEST FAIL: rejected for the wrong reason: %s', sqlerrm);
    raise notice 'OK: cancel_dispatch()''s own terminal-status rule is inherited verbatim, not duplicated or weakened (%)', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '----- B/C12. cross-tenant dispatch_id reported identically to not-found -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
begin
  begin
    perform public.transition_dispatch_status('dbdb0000-0000-0000-0000-00000000000b', 'accepted');  -- Org B's dispatch
    raise exception 'TEST FAIL: an Org-A dispatcher transitioned an Org-B dispatch';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    assert sqlerrm like '%not found%', format('TEST FAIL: cross-tenant access was not reported as not-found: %s', sqlerrm);
    raise notice 'OK: cross-tenant dispatch is reported as not-found, never confirming existence (%)', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '################  TEST 0134 PASSED  ################'
