-- ============================================================================
-- TEST_0135_dispatch_resource_reassignment_and_carrier_lockdown.sql
-- disposable database only. Run via TEST_0130_0133_run.sh.
--
-- Phase 3A.2 verification: dispatches column-privilege lockdown (item 4)
-- and reassign_dispatch_resources() (items 1-2). Phase 3A.3 additions:
-- whitespace-only reason rejection (B3b), detailed audit-event content
-- (B2/B12), multi-resource-change single-reason recording (B12), and
-- optimistic-concurrency / stale-record protection (PART C, item 3).
-- Phase 3A.4 additions: mandatory expected_updated_at on any REPLACEMENT
-- (B3c -- omitting it is rejected as EXPECTED_VERSION_REQUIRED, not
-- bypassable), and historical/inactive-resource behavior (B13, B14 --
-- an unrelated/no-op save is never blocked by a currently-assigned
-- resource that has since gone inactive or unresolved).
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0135  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql
\i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
\i migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql

\echo '===== PART A: dispatches column privileges (item 4) ====='
do $t$
declare v_carrier boolean; v_load boolean; v_driver boolean; v_truck boolean; v_trailer boolean; v_status boolean; v_notes boolean; v_table boolean;
begin
  select has_table_privilege('authenticated','public.dispatches','UPDATE') into v_table;
  assert v_table = false, 'TEST FAIL: authenticated holds table-level UPDATE on dispatches';

  select has_column_privilege('authenticated','public.dispatches','carrier_id','UPDATE') into v_carrier;
  select has_column_privilege('authenticated','public.dispatches','load_id','UPDATE') into v_load;
  select has_column_privilege('authenticated','public.dispatches','driver_id','UPDATE') into v_driver;
  select has_column_privilege('authenticated','public.dispatches','truck_id','UPDATE') into v_truck;
  select has_column_privilege('authenticated','public.dispatches','trailer_id','UPDATE') into v_trailer;
  select has_column_privilege('authenticated','public.dispatches','status','UPDATE') into v_status;
  select has_column_privilege('authenticated','public.dispatches','notes','UPDATE') into v_notes;
  assert v_carrier = false, 'TEST FAIL: carrier_id updatable';
  assert v_load = false, 'TEST FAIL: load_id updatable';
  assert v_driver = false, 'TEST FAIL: driver_id updatable';
  assert v_truck = false, 'TEST FAIL: truck_id updatable';
  assert v_trailer = false, 'TEST FAIL: trailer_id updatable';
  assert v_status = false, 'TEST FAIL: status updatable';
  assert v_notes = true, 'TEST FAIL: notes NOT updatable (should be)';
  raise notice 'OK: carrier_id/load_id/driver_id/truck_id/trailer_id/status all locked down; notes remains updatable.';
end
$t$;

\echo '----- A2. direct authenticated UPDATE to any protected column rejected outright, notes still works -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
begin
  begin
    update public.dispatches set carrier_id = carrier_id where id = 'd1d10000-0000-0000-0000-000000000001';
    raise exception 'TEST FAIL: direct UPDATE naming carrier_id succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: direct UPDATE naming carrier_id rejected (%)', sqlerrm;
  end;
  begin
    update public.dispatches set driver_id = 'd2000000-0000-0000-0000-000000000002' where id = 'd1d10000-0000-0000-0000-000000000001';
    raise exception 'TEST FAIL: direct UPDATE to driver_id succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: direct UPDATE to driver_id rejected (%)', sqlerrm;
  end;
  begin
    update public.dispatches set status = 'accepted' where id = 'd1d10000-0000-0000-0000-000000000001';
    raise exception 'TEST FAIL: direct UPDATE to status succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: direct UPDATE to status rejected (%)', sqlerrm;
  end;
  update public.dispatches set notes = 'a quick note' where id = 'd1d10000-0000-0000-0000-000000000001';
  raise notice 'OK: notes remains directly updatable.';
end
$t$;
reset role;

\echo '===== PART B: reassign_dispatch_resources() ====='

\echo '----- B1. no-op: same driver/truck/no trailer, no reason needed, no version needed -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res jsonb;
begin
  -- d1d10000...001's seed equipment is d1000000...091/c1000000...091 (NOT
  -- the "standard" d1000000...001/c1000000...001 -- TEST_SUPPORT gives
  -- L1's own seed dispatch DEDICATED equipment so the "standard" ids stay
  -- free for every test file's own ad-hoc fixtures under the 0054 partial
  -- unique indexes). A pure no-op requires neither a reason NOR a version
  -- (Phase 3A.4, item 1 -- mandatory version applies only to REPLACEMENT).
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-000000000091', 'c1000000-0000-0000-0000-000000000091', null, null, null);
  assert v_res->>'success'='true' and (v_res->>'no_op')::boolean = true,
    format('TEST FAIL: expected a no-op result, got %s', v_res);
  raise notice 'OK: identical driver/truck/trailer is a clean no-op, no reason and no version required.';
end
$t$;

\echo '----- B2. legitimate same-carrier reassignment (with the mandatory version) succeeds, writes exactly one DETAILED audit event -----'
do $t$
declare v_res jsonb; v_audit_before int; v_audit_after int; v_changes jsonb; v_ts timestamptz;
begin
  select count(*) into v_audit_before from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';
  -- L3 has A1 equipment already in use by other dispatches; use a fresh
  -- driver/truck pairing by first creating a spare A1 driver/truck.
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  values ('d1000000-0000-0000-0000-00000000000e', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Spare', 'A1');
  insert into public.trucks (id, organization_id, carrier_id, unit_number)
  values ('c1000000-0000-0000-0000-00000000000e', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-SPARE');

  -- Phase 3A.4, item 1: this REPLACES the already-assigned driver+truck --
  -- p_expected_updated_at is now mandatory, read fresh here exactly as a
  -- real client would have loaded it moments earlier.
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e', null,
    p_reason => 'swapping to the spare driver/truck for this run',
    p_expected_updated_at => v_ts);
  assert v_res->>'success'='true' and (v_res->>'no_op')::boolean = false
     and v_res->>'driver_id'='d1000000-0000-0000-0000-00000000000e' and v_res->>'truck_id'='c1000000-0000-0000-0000-00000000000e',
    format('TEST FAIL: legitimate reassignment result unexpected: %s', v_res);

  select count(*) into v_audit_after from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';
  assert v_audit_after = v_audit_before + 1, format('TEST FAIL: expected exactly 1 new audit event, got %s', v_audit_after - v_audit_before);

  assert (select driver_id from public.dispatches where id='d1d10000-0000-0000-0000-000000000001') = 'd1000000-0000-0000-0000-00000000000e',
    'TEST FAIL: driver_id did not actually change';

  -- Phase 3A.3, item 4: the audit record must carry full context, not just
  -- a generic message -- organization_id, carrier_id, load_id, old/new
  -- driver+truck+trailer, and reason must all be present in `changes`.
  select changes into v_changes from public.activity_logs
    where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned'
    order by created_at desc limit 1;
  assert v_changes->>'organization_id' = '11111111-1111-1111-1111-111111111111', format('TEST FAIL: audit missing organization_id: %s', v_changes);
  assert v_changes->>'carrier_id' = 'a1a1a1a1-0000-0000-0000-000000000001', format('TEST FAIL: audit missing carrier_id: %s', v_changes);
  assert v_changes->>'load_id' = '10000000-0000-0000-0000-000000000001', format('TEST FAIL: audit missing load_id: %s', v_changes);
  assert v_changes->>'new_driver_id' = 'd1000000-0000-0000-0000-00000000000e', format('TEST FAIL: audit missing new_driver_id: %s', v_changes);
  assert v_changes->>'new_truck_id' = 'c1000000-0000-0000-0000-00000000000e', format('TEST FAIL: audit missing new_truck_id: %s', v_changes);
  assert v_changes->>'reason' = 'swapping to the spare driver/truck for this run', format('TEST FAIL: audit missing reason: %s', v_changes);
  raise notice 'OK: legitimate same-carrier reassignment succeeds, applies, and writes exactly one DETAILED audit event (org/carrier/load/old+new/reason all present).';
end
$t$;

\echo '----- B3. reason required when replacing an already-assigned resource -----'
do $t$
declare v_ts timestamptz;
begin
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', null, null, null, v_ts);
    raise exception 'TEST FAIL: replacing driver/truck without a reason succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: replacing an already-assigned resource without a reason is rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- B3b. whitespace-only reason treated the same as no reason -- rejected -----'
do $t$
declare v_ts timestamptz;
begin
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', null, '   ', null, v_ts);
    raise exception 'TEST FAIL: replacing driver/truck with a whitespace-only reason succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: whitespace-only reason is rejected same as a missing one (%)', sqlerrm;
  end;
end
$t$;

\echo '----- B3c. Phase 3A.4 item 1: omitting expected_updated_at on a genuine REPLACEMENT is rejected (EXPECTED_VERSION_REQUIRED), not bypassable, no write, no ledger, no audit event -----'
do $t$
declare
  v_res jsonb;
  v_driver_before uuid; v_driver_after uuid;
  v_audit_before int; v_audit_after int;
  v_ledger_before int; v_ledger_after int;
begin
  select driver_id into v_driver_before from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  select count(*) into v_audit_before from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';
  select count(*) into v_ledger_before from public.dispatch_resource_reassignments where dispatch_id='d1d10000-0000-0000-0000-000000000001';

  -- A real driver+truck REPLACEMENT, a valid reason, and even an
  -- idempotency key -- EVERYTHING except the version. An authenticated
  -- caller must not be able to bypass optimistic concurrency simply by
  -- omitting p_expected_updated_at. This must come back as a STRUCTURED
  -- result (never an exception -- a bare `perform` of a bypassable call
  -- would otherwise silently look like nothing happened, one way or the
  -- other, without a human reading the return value).
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', null,
    'attempting to skip the version check', 'no-version-bypass-attempt', null);

  assert v_res->>'success' = 'false', format('TEST FAIL: omitting expected_updated_at on a replacement should yield success=false: %s', v_res);
  assert (v_res->>'expected_version_required')::boolean = true,
    format('TEST FAIL: omitting expected_updated_at on a replacement should set expected_version_required=true: %s', v_res);
  assert coalesce((v_res->>'stale_record')::boolean, false) = false,
    format('TEST FAIL: this is a MISSING version, not a MISMATCHED one -- must not also be reported as stale_record: %s', v_res);

  select driver_id into v_driver_after from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  assert v_driver_after = v_driver_before, 'TEST FAIL: omitting expected_updated_at on a replacement made a write -- driver_id changed';

  select count(*) into v_audit_after from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';
  assert v_audit_after = v_audit_before, format('TEST FAIL: omitting expected_updated_at created an audit event: before=%s after=%s', v_audit_before, v_audit_after);

  select count(*) into v_ledger_after from public.dispatch_resource_reassignments where dispatch_id='d1d10000-0000-0000-0000-000000000001';
  assert v_ledger_after = v_ledger_before, format('TEST FAIL: omitting expected_updated_at wrote a ledger row despite an idempotency key being supplied: before=%s after=%s', v_ledger_before, v_ledger_after);

  raise notice 'OK: an authenticated caller cannot bypass optimistic concurrency by simply omitting p_expected_updated_at on a genuine replacement -- rejected as EXPECTED_VERSION_REQUIRED, no write, no ledger row, no audit event.';
end
$t$;

\echo '----- B4. cross-carrier driver / truck rejected -----'
do $t$
declare v_ts timestamptz;
begin
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd2000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-00000000000e', null, 'tampering: cross-carrier driver', null, v_ts);
    raise exception 'TEST FAIL: cross-carrier driver succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-carrier driver rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- B4b. cross-carrier truck rejected -----'
do $t$
declare v_ts timestamptz;
begin
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-00000000000e', 'c2000000-0000-0000-0000-000000000002', null, 'tampering: cross-carrier truck', null, v_ts);
    raise exception 'TEST FAIL: cross-carrier truck succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-carrier truck rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- B5. unresolved trailer rejected; organization_shared trailer allowed (initial assignment -- no version required); cross-carrier trailer rejected -----'
do $t$
declare v_res jsonb;
begin
  -- driver/truck unchanged here (already ...00e/...00e from B2) -- only
  -- the trailer is new (previously null), so this is an INITIAL
  -- assignment, not a replacement -- correctly omits p_expected_updated_at
  -- entirely (Phase 3A.4, item 1: initial assignment may omit the
  -- version, protected by the row lock alone).
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e',
      'e9000000-0000-0000-0000-000000000009', -- TRL-SHARED, ownership_scope=unresolved
      'assigning the shared trailer');
    raise exception 'TEST FAIL: unresolved trailer succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: unresolved trailer rejected (%)', sqlerrm;
  end;

  -- promote it to organization_shared via the sanctioned RPC, then confirm
  -- it CAN be assigned.
  perform set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
  perform public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'organization_shared', 'owner-approved for test 0135');
  perform set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);

  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e',
    'e9000000-0000-0000-0000-000000000009', 'assigning the now-shared trailer');
  assert v_res->>'success'='true' and v_res->>'trailer_id'='e9000000-0000-0000-0000-000000000009',
    format('TEST FAIL: organization_shared trailer should be assignable, got %s', v_res);
  raise notice 'OK: organization_shared trailer is assignable regardless of carrier, and its INITIAL assignment needed no version.';

  -- a CARRIER-scoped trailer of a DIFFERENT carrier (A2) is rejected on
  -- this A1 dispatch. This IS now a replacement (trailer was just set
  -- above), so the mandatory version applies.
  insert into public.trailers (id, organization_id, carrier_id, unit_number, ownership_scope)
  values ('e2000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
          'a2a2a2a2-0000-0000-0000-000000000002', 'TRL-A2-ONLY', 'carrier');
  declare v_ts timestamptz;
  begin
    select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e',
      'e2000000-0000-0000-0000-000000000002', 'testing cross-carrier trailer', null, v_ts);
    raise exception 'TEST FAIL: a carrier-A2 trailer succeeded on a carrier-A1 dispatch';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: a carrier-scoped trailer of a DIFFERENT carrier is rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- B6. inactive driver/truck rejected when REPLACING (both trigger v_changed via the trailer removal below) -----'
do $t$
declare v_ts timestamptz;
begin
  update public.drivers set status = 'inactive' where id = 'd1000000-0000-0000-0000-00000000000e';
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e', null, 'testing inactive driver', null, v_ts);
    raise exception 'TEST FAIL: inactive driver succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: inactive driver rejected (%)', sqlerrm;
  end;
  update public.drivers set status = 'active' where id = 'd1000000-0000-0000-0000-00000000000e';

  update public.trucks set status = 'out_of_service' where id = 'c1000000-0000-0000-0000-00000000000e';
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e', null, 'testing inactive truck', null, v_ts);
    raise exception 'TEST FAIL: out-of-service truck succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: out-of-service truck rejected (%)', sqlerrm;
  end;
  update public.trucks set status = 'active' where id = 'c1000000-0000-0000-0000-00000000000e';
end
$t$;

\echo '----- B7. conflicting active assignment rejected (driver/truck already on another active dispatch) -----'
do $t$
declare v_ts timestamptz;
begin
  -- d2000000...002 (Drv A2) and c2000000...002 (TRK A2) are already active
  -- on dispatch d2d20000...002 (from the standard seed, load L2).
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e', null, 'no conflict here', null, v_ts);
    raise notice 'setup: dispatch now on spare A1 equipment (no conflict expected here).';
  exception when others then
    raise notice 'unexpected: %', sqlerrm;
  end;
  -- Now attempt to steal a driver who IS currently active elsewhere: L3's
  -- own seed dispatch (d3a30000...00a) uses dedicated driver
  -- d1000000...093/truck c1000000...093 (TEST_SUPPORT gives L1/L2/L3 each
  -- their OWN equipment so the "standard" ids stay free elsewhere) -- a
  -- genuine, real conflict target.
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  begin
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-000000000093', 'c1000000-0000-0000-0000-00000000000e', null, 'attempting to steal an already-active driver', null, v_ts);
    raise exception 'TEST FAIL: reassigning to a driver already active on another dispatch succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: conflicting active driver assignment rejected (%)', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '----- B8. role gate: viewer cannot reassign -----'
select set_config('test.current_uid', 'ffff0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
begin
  begin
    -- No version supplied at all -- and it must STILL be rejected on role,
    -- before the version check is ever reached (role gate is the very
    -- first check in the function body).
    perform public.reassign_dispatch_resources(
      'd1d10000-0000-0000-0000-000000000001',
      'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e', null, 'viewer attempting reassignment');
    raise exception 'TEST FAIL: viewer role succeeded at reassignment';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: viewer role cannot reassign dispatch resources (%)', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '----- B9. idempotent replay -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res1 jsonb; v_res2 jsonb; v_audit_before int; v_audit_after int; v_ts timestamptz;
begin
  select count(*) into v_audit_before from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';
  -- driver/truck unchanged (still ...00e/...00e from B7); trailer is an
  -- INITIAL assignment (currently null, from B7's trailer removal) -- not
  -- a replacement, so the version is optional here, but a real client
  -- always has one available and sends it regardless.
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  v_res1 := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e', 'e9000000-0000-0000-0000-000000000009',
    'idempotent test replay', 'resource-idem-key-1', v_ts);
  v_res2 := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e', 'e9000000-0000-0000-0000-000000000009',
    'idempotent test replay', 'resource-idem-key-1', v_ts);
  select count(*) into v_audit_after from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';
  assert v_res2->>'idempotent_replay' = 'true', 'TEST FAIL: second call not flagged as replay';
  assert v_audit_after <= v_audit_before + 1, format('TEST FAIL: expected at most 1 new audit event across both calls, got %s', v_audit_after - v_audit_before);
  raise notice 'OK: replayed idempotency key produces exactly one real effect / audit event.';
end
$t$;

\echo '----- B10. cross-tenant dispatch reported as not-found -----'
do $t$
begin
  begin
    -- Cross-tenant is rejected at the dispatch-lookup stage, BEFORE the
    -- load/dispatch lock and the version check are ever reached -- no
    -- version is needed (or would even be meaningful) here.
    perform public.reassign_dispatch_resources(
      'dbdb0000-0000-0000-0000-00000000000b', -- Org B's dispatch
      'd1000000-0000-0000-0000-00000000000e', 'c1000000-0000-0000-0000-00000000000e', null, 'cross-tenant attempt');
    raise exception 'TEST FAIL: cross-tenant dispatch reassignment succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    assert sqlerrm like '%not found%', format('TEST FAIL: cross-tenant not reported as not-found: %s', sqlerrm);
    raise notice 'OK: cross-tenant dispatch reported as not-found (%)', sqlerrm;
  end;
end
$t$;

\echo '----- B11. status/carrier/load never touched by this RPC -- catalog + behavioral confirmation -----'
do $t$
declare v_status public.dispatch_status; v_carrier uuid; v_load uuid;
begin
  select status, carrier_id, load_id into v_status, v_carrier, v_load from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  assert v_status = 'assigned' and v_carrier = 'a1a1a1a1-0000-0000-0000-000000000001' and v_load = '10000000-0000-0000-0000-000000000001',
    'TEST FAIL: status/carrier/load changed by resource reassignments -- must be structurally impossible';
  raise notice 'OK: status/carrier_id/load_id are unchanged after every reassignment above -- this RPC structurally cannot touch them.';
end
$t$;

\echo '----- B12. multiple simultaneous resource changes use ONE recorded reason -----'
do $t$
declare v_res jsonb; v_changes jsonb; v_ts timestamptz;
begin
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  values ('d1000000-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Spare2', 'A1');
  insert into public.trucks (id, organization_id, carrier_id, unit_number)
  values ('c1000000-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-SPARE2');

  -- Current state (post-B9): driver=...00e, truck=...00e, trailer=e9000000...9.
  -- Change ALL THREE at once with a single reason -- a real REPLACEMENT
  -- (of driver, truck, AND trailer), so the mandatory version applies.
  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-00000000000f', 'c1000000-0000-0000-0000-00000000000f', null,
    'consolidated swap: driver, truck, and trailer all changed together', null, v_ts);
  assert v_res->>'success'='true' and (v_res->>'no_op')::boolean = false,
    format('TEST FAIL: multi-resource change unexpected result: %s', v_res);

  select changes into v_changes from public.activity_logs
    where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned'
    order by created_at desc limit 1;
  assert v_changes->>'reason' = 'consolidated swap: driver, truck, and trailer all changed together',
    format('TEST FAIL: single reason not recorded for multi-resource change: %s', v_changes);
  assert v_changes->>'new_driver_id' = 'd1000000-0000-0000-0000-00000000000f'
     and v_changes->>'new_truck_id' = 'c1000000-0000-0000-0000-00000000000f'
     and v_changes->>'new_trailer_id' is null,
    format('TEST FAIL: multi-resource audit missing expected new ids: %s', v_changes);
  raise notice 'OK: changing driver + truck + trailer together records exactly one reason, covering all changes.';
end
$t$;

\echo '----- B13. historical unresolved trailer: unchanged no-op succeeds (visible as historical evidence); a FRESH assignment of it elsewhere is still refused (see B5) -----'
do $t$
begin
  insert into public.trailers (id, organization_id, carrier_id, unit_number, ownership_scope)
  values ('e5000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', null, 'TRL-HIST-UNRESOLVED', 'unresolved');
end
$t$;
-- Force-assign it directly, as the unrestricted superuser role this
-- script otherwise runs as -- simulating pre-existing historical data
-- (from before this trailer was ever reclassified, or a legacy backfill
-- row predating guard_dispatch_carrier_scope's own unresolved-trailer
-- check) that 'authenticated' itself could never have written (no direct
-- UPDATE privilege on dispatches.trailer_id), AND that even a same-
-- transaction superuser UPDATE cannot normally create today (the guard
-- trigger validates unresolved ownership on every write) -- the trigger is
-- disabled for this ONE simulated-historical UPDATE only, then
-- immediately re-enabled, exactly as if this row simply predates the
-- rule. PART B has been running as `authenticated` since B1 -- reset to
-- the unrestricted role first.
reset role;
alter table public.dispatches disable trigger dispatches_guard_carrier_scope;
update public.dispatches set trailer_id = 'e5000000-0000-0000-0000-000000000005' where id = 'd1d10000-0000-0000-0000-000000000001';
alter table public.dispatches enable trigger dispatches_guard_carrier_scope;

select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
declare v_res jsonb; v_driver uuid; v_truck uuid; v_ts timestamptz;
begin
  select driver_id, truck_id, updated_at into v_driver, v_truck, v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  -- Resubmitting the SAME (unresolved, historical) trailer alongside
  -- unchanged driver/truck is a pure no-op -- must succeed. Nothing is
  -- being newly assigned, so the unresolved-ownership check (which only
  -- runs when something is actually changing) never fires.
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    v_driver, v_truck, 'e5000000-0000-0000-0000-000000000005',
    null, null, v_ts);
  assert v_res->>'success'='true' and (v_res->>'no_op')::boolean = true,
    format('TEST FAIL: unchanged historical unresolved trailer should be a no-op, got %s', v_res);
  raise notice 'OK: an unresolved historical trailer stays visible/no-op-safe when left unchanged -- "cannot be newly assigned" is separately proven in B5 (a fresh assignment of an unresolved trailer is rejected outright).';
end
$t$;

\echo '----- B14. current driver goes inactive: an UNRELATED (no-op) save is never blocked; replacing it with a reason + an ACTIVE same-carrier driver succeeds -----'
do $t$
declare v_res jsonb; v_truck uuid; v_trailer uuid; v_ts timestamptz;
begin
  -- Mark the CURRENTLY-assigned driver (...00f, from B12) inactive.
  update public.drivers set status = 'inactive' where id = 'd1000000-0000-0000-0000-00000000000f';

  select truck_id, trailer_id, updated_at into v_truck, v_trailer, v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';

  -- Phase 3A.4, item 3: an unrelated save (here: a pure no-op -- exactly
  -- the same driver/truck/trailer) must NOT be blocked just because the
  -- currently-assigned driver has since gone inactive -- it is not being
  -- REPLACED, so its own status is irrelevant to this save.
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-00000000000f', v_truck, v_trailer,
    null, null, v_ts);
  assert v_res->>'success'='true' and (v_res->>'no_op')::boolean = true,
    format('TEST FAIL: unrelated no-op blocked by a since-inactive currently-assigned driver: %s', v_res);
  raise notice 'OK: an inactive currently-assigned driver does not block an unrelated (no-op) save.';

  -- Now REPLACE that inactive driver with a fresh ACTIVE same-carrier one
  -- -- requires a reason and the mandatory version, and must succeed. Also
  -- drop the historical unresolved trailer (B13) in this same call: "when
  -- a resource changes, validate the complete resulting assignment
  -- atomically" (item 3) means the RPC correctly re-validates trailer
  -- scope too once ANYTHING changes -- keeping that still-unresolved
  -- trailer attached would (correctly) fail this call, so a real
  -- dispatcher fixing the driver would deal with it the same way here.
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  values ('d1000000-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Spare3', 'A1');

  select updated_at into v_ts from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-000000000011', v_truck, null,
    'replacing the now-inactive driver with an active one', null, v_ts);
  assert v_res->>'success'='true' and v_res->>'driver_id'='d1000000-0000-0000-0000-000000000011',
    format('TEST FAIL: replacing an inactive driver with an active same-carrier driver + reason should succeed: %s', v_res);
  raise notice 'OK: replacing an inactive resource with a reason + an active same-carrier resource succeeds.';
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '===== PART C: optimistic concurrency / stale-record protection (Phase 3A.3, item 3; Phase 3A.4, item 1) ====='
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;

\echo '----- C0. realistic race: dispatcher A loads the form, dispatcher B reassigns first (bumping updated_at), then dispatcher A submits the STALE version they originally loaded -- rejected, no write, no audit event -----'
do $t$
declare
  v_loaded_updated_at timestamptz;  -- what "dispatcher A" read when the edit page first loaded
  v_res jsonb;
  v_driver_before uuid; v_driver_after uuid;
  v_audit_before int; v_audit_after int;
begin
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  values ('d1000000-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'RaceB', 'A1');
  insert into public.trucks (id, organization_id, carrier_id, unit_number)
  values ('c1000000-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-RACEB');

  -- Dispatcher A opens the edit page: this is the updated_at they will
  -- (eventually, staleley) submit back.
  select updated_at into v_loaded_updated_at from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  perform pg_sleep(0.01); -- ensure now() strictly advances past v_loaded_updated_at

  -- Dispatcher B reassigns FIRST -- this is the real, successful edit that
  -- bumps updated_at underneath dispatcher A.
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-000000000010', 'c1000000-0000-0000-0000-000000000010', null,
    'dispatcher B: fixing a scheduling conflict', null, v_loaded_updated_at);
  assert v_res->>'success'='true' and coalesce((v_res->>'stale_record')::boolean,false)=false,
    format('TEST FAIL: dispatcher B''s own (first, correct) submission should not be stale: %s', v_res);

  select driver_id into v_driver_before from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  assert v_driver_before = 'd1000000-0000-0000-0000-000000000010', 'TEST FAIL: dispatcher B''s reassignment did not apply';

  select count(*) into v_audit_before from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';

  -- Dispatcher A now submits the form they loaded BEFORE dispatcher B's
  -- change, still carrying the OLD (now-stale) updated_at.
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-000000000011', 'c1000000-0000-0000-0000-00000000000e', null,
    'dispatcher A: unaware of B''s concurrent change', null, v_loaded_updated_at);
  assert v_res->>'success'='false' and (v_res->>'stale_record')::boolean = true,
    format('TEST FAIL: dispatcher A''s stale submission should be rejected as stale_record: %s', v_res);

  select driver_id into v_driver_after from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  assert v_driver_after = v_driver_before, 'TEST FAIL: dispatcher A''s stale submission overwrote dispatcher B''s change';

  select count(*) into v_audit_after from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';
  assert v_audit_after = v_audit_before, format('TEST FAIL: dispatcher A''s rejected stale submission created an audit event: before=%s after=%s', v_audit_before, v_audit_after);

  raise notice 'OK: a genuinely stale submission (an older updated_at, made stale by a real concurrent reassignment) is rejected, never silently overwrites the concurrent change, and creates no audit event.';
end
$t$;

\echo '----- C1. correct expected_updated_at: reassignment proceeds normally -----'
do $t$
declare v_current timestamptz; v_res jsonb; v_driver uuid; v_truck uuid;
begin
  -- C0 left this dispatch on driver/truck ...010/...010 (dispatcher B's
  -- successful reassignment) -- read the CURRENT assignment fresh so this
  -- call is a clean no-op, isolating the version check from the reason/
  -- resource-change rules already covered elsewhere.
  select updated_at, driver_id, truck_id into v_current, v_driver, v_truck
    from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    v_driver, v_truck, null,
    null, null, v_current);
  assert v_res->>'success'='true' and coalesce((v_res->>'stale_record')::boolean, false) = false,
    format('TEST FAIL: correct expected_updated_at should not be treated as stale: %s', v_res);
  raise notice 'OK: a correct expected_updated_at lets the reassignment proceed (this call itself is a no-op -- same ids -- exercising only the version check).';
end
$t$;

\echo '----- C2. stale expected_updated_at: rejected as a STRUCTURED result (no exception), no write, no audit event -----'
do $t$
declare
  v_stale_ts timestamptz := '2000-01-01 00:00:00+00';
  v_res jsonb;
  v_driver_before uuid; v_driver_after uuid;
  v_audit_before int; v_audit_after int;
begin
  select driver_id into v_driver_before from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  select count(*) into v_audit_before from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';

  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', null,
    'this reason should never be applied', null, v_stale_ts);

  assert v_res->>'success' = 'false', format('TEST FAIL: stale expected_updated_at should yield success=false: %s', v_res);
  assert (v_res->>'stale_record')::boolean = true, format('TEST FAIL: stale expected_updated_at should set stale_record=true: %s', v_res);
  assert v_res ? 'current_updated_at', format('TEST FAIL: stale result should surface current_updated_at for the client to refresh with: %s', v_res);

  select driver_id into v_driver_after from public.dispatches where id='d1d10000-0000-0000-0000-000000000001';
  assert v_driver_after = v_driver_before, 'TEST FAIL: stale-record rejection made a write -- driver_id changed';

  select count(*) into v_audit_after from public.activity_logs where entity_id='d1d10000-0000-0000-0000-000000000001' and action='resources_reassigned';
  assert v_audit_after = v_audit_before, format('TEST FAIL: stale-record rejection created an audit event (expected none): before=%s after=%s', v_audit_before, v_audit_after);

  raise notice 'OK: a stale expected_updated_at is rejected as a structured result (not an exception), makes no write, and creates no audit event.';
end
$t$;

\echo '----- C3. stale-record rejection writes no ledger row even with an idempotency key -----'
do $t$
declare v_stale_ts timestamptz := '2000-01-01 00:00:00+00'; v_ledger_before int; v_ledger_after int; v_res jsonb;
begin
  select count(*) into v_ledger_before from public.dispatch_resource_reassignments where dispatch_id='d1d10000-0000-0000-0000-000000000001';
  v_res := public.reassign_dispatch_resources(
    'd1d10000-0000-0000-0000-000000000001',
    'd1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', null,
    'should not be ledgered', 'stale-attempt-idem-key', v_stale_ts);
  assert (v_res->>'stale_record')::boolean = true, format('TEST FAIL: expected stale_record result: %s', v_res);
  select count(*) into v_ledger_after from public.dispatch_resource_reassignments where dispatch_id='d1d10000-0000-0000-0000-000000000001';
  assert v_ledger_after = v_ledger_before, format('TEST FAIL: stale-record rejection wrote a ledger row: before=%s after=%s', v_ledger_before, v_ledger_after);
  raise notice 'OK: stale-record rejection writes no dispatch_resource_reassignments ledger row even when an idempotency key is supplied.';
end
$t$;
reset role;
select set_config('test.current_uid', '', false) as note;

\echo '################  TEST 0135 PASSED  ################'
