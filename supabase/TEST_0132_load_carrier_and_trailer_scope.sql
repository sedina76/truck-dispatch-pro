-- ============================================================================
-- TEST_0132 -- disposable database only. Run via TEST_0130_0133_run.sh.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0132  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql

\echo '----- VERIFY_0132_POST_APPLY matrix (every ok must be t) -----'
\i VERIFY_0132_POST_APPLY.sql

\echo '----- behavior tests -----'

-- 1. deterministic trailer backfill.
do $t$
begin
  assert (select ownership_scope from public.trailers where id='e1000000-0000-0000-0000-000000000001') = 'carrier',
    'TRL-A1 (has carrier) should be ownership_scope=carrier';
  assert (select ownership_scope from public.trailers where id='e9000000-0000-0000-0000-000000000009') = 'unresolved',
    'TRL-SHARED (carrier_id NULL) should be ownership_scope=unresolved, NOT organization_shared';
  assert not exists (select 1 from public.trailers where ownership_scope='organization_shared'),
    'backfill must not produce organization_shared';
  raise notice 'OK: trailer ownership_scope backfill (carrier / unresolved only)';
end
$t$;

-- 2. derive trigger on new trailers.
do $t$
begin
  insert into public.trailers (id, organization_id, carrier_id, unit_number)
  values ('e2000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
          'a1a1a1a1-0000-0000-0000-000000000001', 'TRL-NEW-C');
  insert into public.trailers (id, organization_id, carrier_id, unit_number)
  values ('e3000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
          null, 'TRL-NEW-N');
  assert (select ownership_scope from public.trailers where id='e2000000-0000-0000-0000-000000000002') = 'carrier',
    'new trailer with carrier -> carrier';
  assert (select ownership_scope from public.trailers where id='e3000000-0000-0000-0000-000000000003') = 'unresolved',
    'new trailer without carrier -> unresolved';
  raise notice 'OK: trailers_derive_ownership_scope on INSERT';
end
$t$;

-- 3. consistency CHECK.
do $t$
begin
  begin
    insert into public.trailers (organization_id, carrier_id, unit_number, ownership_scope)
    values ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRL-BAD1', 'organization_shared');
    raise exception 'TEST FAIL: organization_shared + carrier_id NOT rejected';
  exception when check_violation then raise notice 'OK: organization_shared requires NULL carrier_id'; end;
  begin
    insert into public.trailers (organization_id, carrier_id, unit_number, ownership_scope)
    values ('11111111-1111-1111-1111-111111111111', null, 'TRL-BAD2', 'carrier');
    raise exception 'TEST FAIL: carrier scope + NULL carrier_id NOT rejected';
  exception when check_violation then raise notice 'OK: carrier scope requires a carrier_id'; end;
end
$t$;

-- 4. guard_dispatch_carrier_scope: unresolved trailer cannot be dispatched.
--    (loads have no carrier_id yet -- the cross-carrier arm is a no-op here.)
do $t$
begin
  begin
    insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id, trailer_id, status)
    values ('11111111-1111-1111-1111-111111111111',
            '20000000-0000-0000-0000-000000000002',
            'a2a2a2a2-0000-0000-0000-000000000002',
            'c2000000-0000-0000-0000-000000000002',
            'd2000000-0000-0000-0000-000000000002',
            'e9000000-0000-0000-0000-000000000009',  -- TRL-SHARED = unresolved
            'assigned');
    raise exception 'TEST FAIL: dispatch with an unresolved trailer was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: unresolved-trailer dispatch rejected (%)', sqlerrm;
  end;
end
$t$;

-- 5. guard_load_carrier_change: NULL->value allowed; value->different-value
--    allowed only with zero activity; value->NULL never allowed;
--    cross-org carrier rejected.
do $t$
begin
  -- L4 has zero dispatches, carrier_id NULL: NULL -> A1 allowed
  update public.loads set carrier_id='a1a1a1a1-0000-0000-0000-000000000001'
   where id='40000000-0000-0000-0000-000000000004';
  -- A1 -> A2 allowed (still zero activity)
  update public.loads set carrier_id='a2a2a2a2-0000-0000-0000-000000000002'
   where id='40000000-0000-0000-0000-000000000004';
  raise notice 'OK: zero-activity load carrier assignment / reassignment allowed';

  -- clearing an assigned carrier -> rejected
  begin
    update public.loads set carrier_id=null where id='40000000-0000-0000-0000-000000000004';
    raise exception 'TEST FAIL: clearing an assigned load carrier was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: clearing an assigned load carrier rejected (%)', sqlerrm;
  end;

  -- cross-org carrier -> rejected
  begin
    update public.loads set carrier_id='b1b1b1b1-0000-0000-0000-000000000001'
     where id='40000000-0000-0000-0000-000000000004';
    raise exception 'TEST FAIL: cross-org load carrier was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-org load carrier rejected (%)', sqlerrm;
  end;

  -- reassigning a carrier on a load WITH a dispatch -> rejected.
  -- L1 has dispatch D1 (carrier A1) + a financial controller; assign then move.
  update public.loads set carrier_id='a1a1a1a1-0000-0000-0000-000000000001'
   where id='10000000-0000-0000-0000-000000000001';
  begin
    update public.loads set carrier_id='a2a2a2a2-0000-0000-0000-000000000002'
     where id='10000000-0000-0000-0000-000000000001';
    raise exception 'TEST FAIL: reassigning carrier on a load with dispatches was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: carrier reassignment blocked while load has dispatches (%)', sqlerrm;
  end;
end
$t$;

-- 6. cross-carrier dispatch guard: set L2.carrier_id = A2, then try a dispatch
--    on L2 with carrier A1 (+ A1 equipment so the 0055 guard passes first).
do $t$
begin
  update public.loads set carrier_id='a2a2a2a2-0000-0000-0000-000000000002'
   where id='20000000-0000-0000-0000-000000000002';
  begin
    insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id, status)
    values ('11111111-1111-1111-1111-111111111111',
            '20000000-0000-0000-0000-000000000002',
            'a1a1a1a1-0000-0000-0000-000000000001',
            'c1000000-0000-0000-0000-000000000001',
            'd1000000-0000-0000-0000-000000000001',
            'assigned');
    raise exception 'TEST FAIL: cross-carrier dispatch (load carrier A2, dispatch carrier A1) was NOT rejected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-carrier dispatch rejected (%)', sqlerrm;
  end;
end
$t$;

-- 6b. CANCEL-THEN-REDISPATCH -- the exact 7-step scenario from the Phase 3A
--     clarification round ("cancel-then-redispatch contradiction"). A prior
--     round's report incorrectly claimed different-carrier redispatch after
--     cancellation "remains fully supported" -- direct testing proved that
--     FALSE (loads.carrier_id, once claimed, is unconditionally
--     authoritative per guard_dispatch_carrier_scope() priority step 1; a
--     cancelled dispatch does not clear it). This test locks in the
--     corrected, confirmed rule as a permanent regression check.
do $t$
declare v_after_cancel record; v_final record;
begin
  -- step 1: create load, no carrier
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('69000000-0000-0000-0000-000000000069', '11111111-1111-1111-1111-111111111111', 'LD-69', 'a0b00000-0000-0000-0000-000000000001', 'booked');

  -- step 2: dispatch to Carrier A
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('69d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '69000000-0000-0000-0000-000000000069',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');

  -- step 3: confirm loads.carrier_id becomes Carrier A
  assert (select carrier_id from public.loads where id='69000000-0000-0000-0000-000000000069') = 'a1a1a1a1-0000-0000-0000-000000000001',
    'step 3: loads.carrier_id should be Carrier A after the first dispatch';

  -- step 4: cancel Carrier A's dispatch
  update public.dispatches set status='cancelled', cancelled_at=now() where id='69d10000-0000-0000-0000-000000000001';
  select carrier_id, carrier_resolution, financial_dispatch_id into v_after_cancel from public.loads where id='69000000-0000-0000-0000-000000000069';
  assert v_after_cancel.carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'
     and v_after_cancel.carrier_resolution = 'resolved'
     and v_after_cancel.financial_dispatch_id = '69d10000-0000-0000-0000-000000000001',
    format('step 4: cancellation must NOT clear/change loads.carrier_id / carrier_resolution / financial_dispatch_id, got %s', v_after_cancel);
  raise notice 'OK (step 4): cancelling the dispatch left loads.carrier_id=A1, carrier_resolution=resolved, financial_dispatch_id unchanged -- cancellation is a dispatch-status change only.';

  -- step 5/6: attempt to dispatch the SAME load to Carrier B -> must FAIL
  begin
    insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
    values ('69d20000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '69000000-0000-0000-0000-000000000069',
            'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'assigned');
    raise exception 'TEST FAIL: different-carrier redispatch after cancellation SUCCEEDED -- this must be rejected until a Phase 3B reassign_load_carrier() RPC exists.';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK (steps 5-6): different-carrier redispatch after cancellation REJECTED, confirming the corrected rule (%)', sqlerrm;
  end;

  -- same-carrier redispatch after cancellation must still SUCCEED
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('69d30000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '69000000-0000-0000-0000-000000000069',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');
  raise notice 'OK: SAME-carrier redispatch after cancellation succeeds normally.';

  -- step 7: final state -- loads.carrier_id/resolution/financial_dispatch_id
  -- unchanged from step 4; exactly 2 dispatches (1 cancelled A1, 1 assigned
  -- A1); zero B dispatches ever persisted.
  select carrier_id, carrier_resolution, financial_dispatch_id into v_final from public.loads where id='69000000-0000-0000-0000-000000000069';
  assert v_final.carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'
     and v_final.carrier_resolution = 'resolved'
     and v_final.financial_dispatch_id = '69d10000-0000-0000-0000-000000000001',
    format('step 7: final load state must be unchanged from step 4, got %s', v_final);
  assert (select count(*) from public.dispatches where load_id='69000000-0000-0000-0000-000000000069') = 2,
    'step 7: exactly 2 dispatches (cancelled A1, assigned A1) should exist; the rejected B dispatch must never have persisted';
  assert (select count(*) from public.dispatches where load_id='69000000-0000-0000-0000-000000000069' and carrier_id <> 'a1a1a1a1-0000-0000-0000-000000000001') = 0,
    'step 7: zero dispatches of any carrier other than A1 should exist on this load';
  raise notice 'OK (step 7): final state confirmed -- carrier_id=A1, carrier_resolution=resolved, financial_dispatch_id=original A1 dispatch, 2 dispatches total (1 cancelled, 1 assigned), both carrier A1.';

  -- cleanup: all of this test's own assertions are done -- free the
  -- standard A1 driver/truck (0054's partial unique indexes, faithfully
  -- reproduced, forbid them holding TWO simultaneously-active dispatches;
  -- later tests in this file reuse this same "standard" equipment for
  -- their own, unrelated fixtures).
  update public.dispatches set status='cancelled', cancelled_at=now() where id='69d30000-0000-0000-0000-000000000003';
end
$t$;

-- 7. correction #6: reassigning an ALREADY-SET carrier requires owner/admin;
--    the initial NULL -> value assignment stays open to dispatcher. Uses a
--    FRESH load (L4's carrier_id was already touched by test 5 above).
do $t$
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('70000000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'LD-7', 'a0b00000-0000-0000-0000-000000000001', 'booked');

  perform set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', true);  -- Dispatcher A
  update public.loads set carrier_id='a1a1a1a1-0000-0000-0000-000000000001'
   where id='70000000-0000-0000-0000-000000000007';  -- L7, zero activity: NULL -> value, dispatcher OK
  raise notice 'OK: dispatcher may perform the initial NULL -> value carrier assignment';

  begin
    update public.loads set carrier_id='a2a2a2a2-0000-0000-0000-000000000002'
     where id='70000000-0000-0000-0000-000000000007';  -- reassignment, still dispatcher
    raise exception 'TEST FAIL: dispatcher was able to REASSIGN an already-set carrier_id';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: dispatcher reassignment of an already-set carrier rejected (%)', sqlerrm;
  end;

  perform set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', true);  -- Accountant A
  begin
    update public.loads set carrier_id='a2a2a2a2-0000-0000-0000-000000000002'
     where id='70000000-0000-0000-0000-000000000007';
    raise exception 'TEST FAIL: accountant was able to REASSIGN an already-set carrier_id';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: accountant reassignment of an already-set carrier rejected (%)', sqlerrm;
  end;

  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);  -- Owner A
  update public.loads set carrier_id='a2a2a2a2-0000-0000-0000-000000000002'
   where id='70000000-0000-0000-0000-000000000007';
  assert (select carrier_id from public.loads where id='70000000-0000-0000-0000-000000000007') = 'a2a2a2a2-0000-0000-0000-000000000002',
    'owner reassignment should have succeeded';
  raise notice 'OK: owner MAY reassign an already-set carrier (zero dependent activity)';
  perform set_config('test.current_uid', '', true);
end
$t$;

-- 8. correction #4: shared-trailer approval -- role tests + direct-update lockout.
do $t$
declare v_res jsonb; v_scope public.trailer_ownership_scope; v_audit_cnt int;
begin
  -- dispatcher CANNOT approve unresolved -> organization_shared
  perform set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', true);
  begin
    perform public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'organization_shared', 'dispatcher attempt');
    raise exception 'TEST FAIL: dispatcher was able to approve organization_shared';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: dispatcher cannot approve unresolved -> organization_shared (%)', sqlerrm;
  end;

  -- accountant CANNOT approve it either
  perform set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', true);
  begin
    perform public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'organization_shared', 'accountant attempt');
    raise exception 'TEST FAIL: accountant was able to approve organization_shared';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: accountant cannot approve unresolved -> organization_shared (%)', sqlerrm;
  end;

  -- driver / viewer cannot even reach the role check meaningfully rejected too
  perform set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', true);
  begin
    perform public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'organization_shared', 'driver attempt');
    raise exception 'TEST FAIL: driver was able to approve organization_shared';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: driver cannot approve organization_shared (%)', sqlerrm;
  end;

  -- a reason is required, even for owner
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', true);
  begin
    perform public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'organization_shared', '');
    raise exception 'TEST FAIL: an empty reason was accepted';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: an empty reason is rejected even for owner (%)', sqlerrm;
  end;

  -- owner CAN approve, with a reason -- audit row is written
  v_res := public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'organization_shared', 'reviewed: genuinely shared yard trailer');
  assert v_res->>'success' = 'true', format('expected success, got %s', v_res);
  select ownership_scope into v_scope from public.trailers where id='e9000000-0000-0000-0000-000000000009';
  assert v_scope = 'organization_shared', format('trailer ownership_scope = %s, expected organization_shared', v_scope);
  select count(*) into v_audit_cnt from public.trailer_ownership_scope_audit
   where trailer_id='e9000000-0000-0000-0000-000000000009' and ownership_scope_after='organization_shared' and reason like 'reviewed:%';
  assert v_audit_cnt = 1, format('expected exactly 1 matching audit row, got %s', v_audit_cnt);
  raise notice 'OK: owner approves unresolved -> organization_shared with a reason; audit row written';

  -- direct table UPDATE (even as owner) is REJECTED -- must go through the RPC
  begin
    update public.trailers set ownership_scope='carrier', carrier_id='a1a1a1a1-0000-0000-0000-000000000001'
     where id='e9000000-0000-0000-0000-000000000009';
    raise exception 'TEST FAIL: a direct UPDATE to ownership_scope succeeded -- the lockout was bypassed';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: direct table UPDATE to ownership_scope/carrier_id rejected even for owner (%)', sqlerrm;
  end;

  -- the now-shared trailer CAN be assigned across carriers (A1's dispatch, since it's approved-shared)
  insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id, trailer_id, status)
  values ('11111111-1111-1111-1111-111111111111',
          '50000000-0000-0000-0000-000000000005',
          'a1a1a1a1-0000-0000-0000-000000000001',
          'c1000000-0000-0000-0000-000000000001',
          'd1000000-0000-0000-0000-000000000001',
          'e9000000-0000-0000-0000-000000000009',
          'assigned');
  raise notice 'OK: an approved organization_shared trailer can now be assigned to a dispatch';

  -- cleanup: free the standard A1 driver/truck for test 9 below (0054's
  -- partial unique indexes, faithfully reproduced, forbid holding two
  -- simultaneously-active dispatches).
  update public.dispatches set status='cancelled', cancelled_at=now()
   where organization_id='11111111-1111-1111-1111-111111111111' and load_id='50000000-0000-0000-0000-000000000005'
     and driver_id='d1000000-0000-0000-0000-000000000001' and status<>'cancelled';

  perform set_config('test.current_uid', '', true);
end
$t$;

-- 9. correction #5: a load explicitly classified carrier_resolution =
--    'unresolved' (simulating 0133's own classification) rejects a NEW
--    dispatch that would silently become its financial controller.
do $t$
begin
  update public.loads set carrier_resolution = 'unresolved'
   where id = '30000000-0000-0000-0000-000000000003';  -- L3: no carrier_id, no controller yet
  assert (select financial_dispatch_id from public.loads where id='30000000-0000-0000-0000-000000000003') is null,
    'L3 must have no financial controller for this test to be meaningful';

  begin
    insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id, status)
    values ('11111111-1111-1111-1111-111111111111',
            '30000000-0000-0000-0000-000000000003',
            'a1a1a1a1-0000-0000-0000-000000000001',
            'c1000000-0000-0000-0000-000000000001',
            'd1000000-0000-0000-0000-000000000001',
            'assigned');
    raise exception 'TEST FAIL: a new dispatch was allowed to become financial controller of an unresolved-carrier load';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: new dispatch rejected -- cannot become financial controller of an unresolved-carrier load (%)', sqlerrm;
  end;

end
$t$;

\echo '################  TEST 0132 PASSED  ################'
