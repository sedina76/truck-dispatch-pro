-- ============================================================================
-- TEST_0133_HISTORICAL_CONFLICTS.sql -- disposable database only.
-- Run via TEST_0130_0133_run.sh.
--
-- Correction (item 9, "test historical conflicts"): fixtures for every
-- listed scenario, injected BEFORE 0132's guard_dispatch_carrier_scope
-- exists (exactly how such data could only ever arise -- the guard makes
-- these states unreachable going forward), then migrated through 0132+0133
-- and checked against VERIFY_0133_POST_APPLY.sql's global invariants.
--
-- Fixture 1 (controller contradicted by a LIVE dispatch) is handled
-- separately, FIRST, and is now an ABORT proof rather than a coexisting-
-- classification proof (Phase 3A clarification round, item 2: "C1
-- controller-conflict contradiction" -- 0133 refuses to apply at all while
-- such a conflict exists anywhere, rather than silently writing an
-- unresolved-with-a-controller row). It is proven to abort the WHOLE
-- migration with zero writes, then explicitly, manually corrected (exactly
-- the "no automatic clearing" workflow VERIFY_0133_PREFLIGHT.sql documents)
-- BEFORE fixtures 2-4 are injected and 0133 is applied for real.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0133 HISTORICAL CONFLICTS  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql

\echo '----- Fixture 1: financial controller A1 + a LIVE (non-cancelled) dispatch of A2, injected pre-0132 -----'
do $t$
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('f1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'LD-F1', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('f1d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'f1000000-0000-0000-0000-000000000001',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('f1d20000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'f1000000-0000-0000-0000-000000000001',
          'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'assigned');
  raise notice 'OK: fixture 1 injected (pre-0132, unguarded)';
end
$t$;

\echo '----- spare driver/truck records for fixtures 2-4: each ACTIVE dispatch needs its OWN equipment now that the 0054 partial unique indexes are faithfully reproduced (at most one active dispatch per driver/truck) -- fixture 1 already claims the standard A1/A2 pair -----'
do $t$
begin
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
    ('d1000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-F2'),
    ('d1000000-0000-0000-0000-0000000000f3', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-F3a'),
    ('d1000000-0000-0000-0000-0000000000f4', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-F3b'),
    ('d1000000-0000-0000-0000-0000000000f5', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-F4'),
    ('d2000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'Drv', 'A2-F4');
  insert into public.trucks (id, organization_id, carrier_id, unit_number) values
    ('c1000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-F2'),
    ('c1000000-0000-0000-0000-0000000000f3', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-F3a'),
    ('c1000000-0000-0000-0000-0000000000f4', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-F3b'),
    ('c1000000-0000-0000-0000-0000000000f5', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-F4'),
    ('c2000000-0000-0000-0000-0000000000f2', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'TRK-A2-F4');
end
$t$;

\echo '----- injecting fixtures 2-4, ALSO pre-0132 (their historical shapes -- e.g. a cancelled dispatch inserted directly with a different carrier -- are unreachable once the guard is live even for a same-transaction INSERT of an already-cancelled row) -----'
do $t$
begin
  -- Fixture 2: financial controller Carrier A1 PLUS a CANCELLED historical
  -- dispatch of Carrier A2 -- expected: 0133 classifies 'resolved'/A1 (the
  -- cancelled dispatch of a different carrier is legitimate history and
  -- does NOT block C1).
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('f2000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'LD-F2', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('f2d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'f2000000-0000-0000-0000-000000000002',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000f2', 'd1000000-0000-0000-0000-0000000000f2', 'assigned');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('f2d20000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'f2000000-0000-0000-0000-000000000002',
          'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'cancelled');

  -- Fixture 3: multiple ACTIVE dispatches, all the SAME carrier (A1), no
  -- controller (nulled below) -- expected: 0133 classifies 'backfilled'/A1
  -- (C2, deterministic -- they agree). Two DIFFERENT A1 driver/truck pairs
  -- (a real driver can only physically be on one dispatch at a time, and
  -- 0054's own unique indexes already made "same equipment, two active
  -- dispatches" structurally impossible in production even before this
  -- correction -- using distinct equipment here is a fidelity fix, not
  -- merely a workaround).
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('f3000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'LD-F3', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('f3d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'f3000000-0000-0000-0000-000000000003',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000f3', 'd1000000-0000-0000-0000-0000000000f3', 'assigned');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('f3d20000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'f3000000-0000-0000-0000-000000000003',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000f4', 'd1000000-0000-0000-0000-0000000000f4', 'accepted');
  update public.loads set financial_dispatch_id = null where id = 'f3000000-0000-0000-0000-000000000003';

  -- Fixture 4: multiple ACTIVE dispatches, DIFFERENT carriers, no controller
  -- -- expected: 0133 classifies 'unresolved' (C4_conflicting_carriers).
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('f4000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'LD-F4', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('f4d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'f4000000-0000-0000-0000-000000000004',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000f5', 'd1000000-0000-0000-0000-0000000000f5', 'assigned');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('f4d20000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'f4000000-0000-0000-0000-000000000004',
          'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-0000000000f2', 'd2000000-0000-0000-0000-0000000000f2', 'accepted');
  update public.loads set financial_dispatch_id = null where id = 'f4000000-0000-0000-0000-000000000004';

  raise notice 'OK: fixtures 2-4 injected (pre-0132, unguarded)';
end
$t$;

\echo '----- applying 0132 (fixture 1-4''s states now unreachable via any live write, but not retroactively touched) -----'
\i migrations/0132_load_carrier_and_trailer_scope.sql

\echo '----- VERIFY_0133_PREFLIGHT check 13 must GATE (ok=f) on fixture 1, and its diagnostic must name LD-F1 exactly -----'
do $t$
declare v_ok boolean;
begin
  select
    not exists (
      select 1 from public.loads l
      join public.dispatches fd on fd.id = l.financial_dispatch_id and fd.load_id = l.id
      where l.carrier_id is null
        and exists (
          select 1 from public.dispatches d
          where d.load_id = l.id and d.status <> 'cancelled' and d.carrier_id <> fd.carrier_id
        ))
    into v_ok;
  assert v_ok = false, 'preflight check 13''s own condition should be FALSE (gated) while fixture 1 stands';
  assert exists (
    select 1 from public.loads l
    join public.dispatches fd on fd.id = l.financial_dispatch_id and fd.load_id = l.id
    where l.id = 'f1000000-0000-0000-0000-000000000001'
      and exists (select 1 from public.dispatches d where d.load_id=l.id and d.status<>'cancelled' and d.carrier_id<>fd.carrier_id)
  ), 'preflight''s diagnostic listing must include LD-F1';
  raise notice 'OK: VERIFY_0133_PREFLIGHT check 13 correctly gates on fixture 1, diagnostic correctly identifies LD-F1.';
end
$t$;

\echo '----- attempting 0133 while fixture 1 stands -- MUST ABORT, zero writes anywhere -----'
create temp table _f1_pre_counts as select
  (select count(*) from public.loads) as n_loads,
  (select count(*) from public.dispatches) as n_dispatches;
\set ON_ERROR_STOP off
\i migrations/0133_deterministic_carrier_backfill.sql
\set ON_ERROR_STOP on
do $t$
declare c record;
begin
  if to_regclass('public.carrier_backfill_0133_provenance') is not null then
    raise exception 'TEST FAIL: carrier_backfill_0133_provenance exists -- 0133 did NOT abort on fixture 1.';
  end if;
  select * into c from _f1_pre_counts;
  if (select count(*) from public.loads) <> c.n_loads or (select count(*) from public.dispatches) <> c.n_dispatches then
    raise exception 'TEST FAIL: row counts changed despite the expected 0133 abort on fixture 1.';
  end if;
  if (select carrier_id from public.loads where id='f1000000-0000-0000-0000-000000000001') is not null then
    raise exception 'TEST FAIL: LD-F1 has a carrier_id despite the expected 0133 abort.';
  end if;
  raise notice 'OK: 0133 aborted with ZERO writes anywhere while fixture 1 stood -- fail-closed confirmed, exactly as VERIFY_0133_PREFLIGHT check 13 warned.';
end
$t$;

\echo '----- explicit, controlled, manual correction of fixture 1 (cancel the contradicting A2 dispatch) -- NOT an automatic 0133 action -----'
do $t$
begin
  update public.dispatches set status = 'cancelled', cancelled_at = now()
   where id = 'f1d20000-0000-0000-0000-000000000002';
  raise notice 'OK: fixture 1 manually corrected -- controller A1 is no longer contradicted by any live dispatch.';
end
$t$;

\echo '----- VERIFY_0133_PREFLIGHT check 13 must now pass (ok=t) after the correction -----'
do $t$
declare v_ok boolean;
begin
  select
    not exists (
      select 1 from public.loads l
      join public.dispatches fd on fd.id = l.financial_dispatch_id and fd.load_id = l.id
      where l.carrier_id is null
        and exists (
          select 1 from public.dispatches d
          where d.load_id = l.id and d.status <> 'cancelled' and d.carrier_id <> fd.carrier_id
        ))
    into v_ok;
  assert v_ok = true, 'preflight check 13 should now be TRUE (clean) after the manual correction';
  raise notice 'OK: VERIFY_0133_PREFLIGHT check 13 now passes -- 0133 may be applied.';
end
$t$;

-- Fixture 7: controller deleted/set-null edge case -- financial_dispatch_id
-- is ON DELETE RESTRICT (0125); a controlling dispatch can never be deleted.
do $t$
begin
  begin
    delete from public.dispatches where id = 'f2d10000-0000-0000-0000-000000000001';  -- LD-F2's controller
    raise exception 'TEST FAIL: a financial-controller dispatch was deleted -- ON DELETE RESTRICT did not hold';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: deleting a financial-controller dispatch is rejected (ON DELETE RESTRICT) (%)', sqlerrm;
  end;
end
$t$;

\echo '----- applying 0133 -----'
\i migrations/0133_deterministic_carrier_backfill.sql

\echo '----- VERIFY_0133_POST_APPLY: EVERY global invariant must hold, including across the conflict fixtures -----'
\i VERIFY_0133_POST_APPLY.sql

\echo '----- per-fixture classification checks -----'
do $t$
declare r record;
begin
  -- Fixture 1: after its abort proof + manual correction (cancelling the
  -- contradicting A2 dispatch) above, this is now the SAME pattern as
  -- fixture 2 -- controller A1, cancelled-different-carrier history ->
  -- resolved deterministically via the (now-uncontradicted) controller.
  select carrier_id, carrier_resolution, carrier_locked_at into r from public.loads where id='f1000000-0000-0000-0000-000000000001';
  assert r.carrier_resolution = 'resolved' and r.carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' and r.carrier_locked_at is not null,
    format('Fixture 1 (post-correction) expected resolved/A1/locked, got %s', r);
  assert (select status from public.dispatches where id='f1d20000-0000-0000-0000-000000000002') = 'cancelled',
    'Fixture 1''s manually-cancelled dispatch must remain cancelled';
  assert not exists (select 1 from public.unresolved_carrier_records where record_id='f1000000-0000-0000-0000-000000000001'),
    'Fixture 1 must NOT have any unresolved_carrier_records row -- it was corrected before 0133 ran';

  -- Fixture 2: cancelled-different-carrier history -> resolved deterministically via controller
  select carrier_id, carrier_resolution, carrier_locked_at into r from public.loads where id='f2000000-0000-0000-0000-000000000002';
  assert r.carrier_resolution = 'resolved' and r.carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' and r.carrier_locked_at is not null,
    format('Fixture 2 (cancelled-different-carrier history) expected resolved/A1/locked, got %s', r);
  -- the cancelled dispatch of a DIFFERENT carrier remains, unmolested, in history
  assert (select carrier_id from public.dispatches where id='f2d20000-0000-0000-0000-000000000002') = 'a2a2a2a2-0000-0000-0000-000000000002',
    'Fixture 2''s cancelled historical dispatch must retain its original (different) carrier';
  assert (select status from public.dispatches where id='f2d20000-0000-0000-0000-000000000002') = 'cancelled',
    'Fixture 2''s historical dispatch must remain cancelled';

  -- Fixture 3: same-carrier multi-dispatch, no controller -> deterministic backfilled
  select carrier_id, carrier_resolution into r from public.loads where id='f3000000-0000-0000-0000-000000000003';
  assert r.carrier_resolution = 'backfilled' and r.carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001',
    format('Fixture 3 (same-carrier multi-dispatch) expected backfilled/A1, got %s', r);

  -- Fixture 4: cross-carrier multi-dispatch, no controller -> unresolved (never silently resolved)
  select carrier_id, carrier_resolution into r from public.loads where id='f4000000-0000-0000-0000-000000000004';
  assert r.carrier_resolution = 'unresolved' and r.carrier_id is null,
    format('Fixture 4 (cross-carrier multi-dispatch) expected unresolved/NULL, got %s', r);
  assert exists (select 1 from public.unresolved_carrier_records where record_id='f4000000-0000-0000-0000-000000000004' and detail->>'rule'='C4_conflicting_carriers'),
    'Fixture 4 must be tagged C4_conflicting_carriers';

  raise notice 'OK: fixture 1 (post-abort-and-correction) and fixtures 2-4 all classified correctly.';
end
$t$;

-- Fixture 5: financial_dispatch_id pointing to ANOTHER load -- structural
-- abort, proven via a FRESH attempt (the live DB already has 0133 applied,
-- so re-verify the preflight-time structural guard would have caught this
-- by checking VERIFY_0133_PREFLIGHT's own logic against a synthetic case).
do $t$
declare v_bad_fdi_load int;
begin
  -- Simulate what PHASE 1's structural check computes: a load whose
  -- financial_dispatch_id points at a dispatch of a DIFFERENT load. This
  -- state cannot be constructed here without violating the 0125 guard
  -- (guard_load_financial_dispatch_ref), which is exactly the point --
  -- confirm that guard is still what prevents it.
  begin
    update public.loads set financial_dispatch_id = 'f1d10000-0000-0000-0000-000000000001'  -- belongs to LD-F1
     where id = 'f2000000-0000-0000-0000-000000000002';  -- LD-F2, a DIFFERENT load
    raise exception 'TEST FAIL: financial_dispatch_id was set to a dispatch of a DIFFERENT load -- structural guard did not hold';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: financial_dispatch_id cannot reference another load''s dispatch (0125 guard_load_financial_dispatch_ref) (%)', sqlerrm;
  end;
end
$t$;

\echo '################  TEST 0133 HISTORICAL CONFLICTS PASSED  ################'
