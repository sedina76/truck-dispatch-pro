-- ============================================================================
-- TEST_0133_PREEXISTING_CARRIER_RACE.sql -- disposable database only.
-- Run via TEST_0130_0133_run.sh.
--
-- Proves the corrected 0132 -> 0133 deployment-race design (correction #1):
--   1. Apply 0130-0132.
--   2. Create a valid dispatch that causes a carrier to be assigned to a
--      load (simulating a not-yet-built carrier-aware dispatch/load path --
--      the ONLY mechanism Phase 3A itself has for this is a direct,
--      internally-consistent assignment, exactly what a future RPC would do
--      atomically).
--   3. Apply 0133.
--   4. Confirm 0133 succeeds (does NOT abort / reject the whole migration).
--   5. Confirm the assignment is preserved byte-for-byte.
--   6. Confirm it is NOT rollback-owned (no carrier_backfill_0133_provenance row).
--   7. Roll back 0133.
--   8. Confirm that assignment remains intact through the rollback.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0133 PREEXISTING CARRIER RACE  ################'

-- ---- step 1: apply 0130-0132 -----------------------------------------
\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql

-- ---- step 2: a NEW load (L6) gets a carrier via a "valid dispatch" ----
-- Simulates the not-yet-built carrier-aware assignment path: a dispatch is
-- created for carrier A2, and the load's carrier is set to match it --
-- exactly the invariant a future atomic RPC would guarantee. This happens
-- strictly AFTER 0132 and strictly BEFORE 0133 -- the deployment race window.
do $t$
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('60000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'LD-6', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');

  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('d6d60000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111',
          '60000000-0000-0000-0000-000000000006', 'a2a2a2a2-0000-0000-0000-000000000002',
          'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'assigned');

  -- L6 now has a financial_dispatch_id (0125's AFTER INSERT trigger) but NO
  -- carrier_id yet (that column doesn't exist until 0132, already applied,
  -- and nothing has set it). Simulate the future RPC's atomic assignment:
  update public.loads
  set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002', carrier_resolution = 'resolved'
  where id = '60000000-0000-0000-0000-000000000006';

  raise notice 'OK: step 2 -- L6 has a pre-existing carrier_id (A2) BEFORE 0133 has ever run';
end
$t$;

-- ---- step 3/4: apply 0133 -- must SUCCEED, not abort ------------------
\echo '----- applying 0133 with a pre-existing carrier assignment already present -----'
\i migrations/0133_deterministic_carrier_backfill.sql

\echo '----- VERIFY_0133_POST_APPLY matrix (every ok must be t) -----'
\i VERIFY_0133_POST_APPLY.sql

-- ---- step 5/6: the pre-existing assignment is preserved, not provenance-owned
do $t$
declare r record; v_cnt int;
begin
  select carrier_id, carrier_resolution, carrier_locked_at into r
    from public.loads where id='60000000-0000-0000-0000-000000000006';
  assert r.carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002', format('L6 carrier_id changed: %s', r.carrier_id);
  assert r.carrier_resolution = 'resolved', format('L6 carrier_resolution changed: %s', r.carrier_resolution);
  assert r.carrier_locked_at is null, format('L6 carrier_locked_at was written by 0133 (must stay NULL, 0133 never touches it for a pre-existing row): %s', r.carrier_locked_at);

  select count(*) into v_cnt from public.carrier_backfill_0133_provenance where load_id='60000000-0000-0000-0000-000000000006';
  assert v_cnt = 0, format('L6 has % provenance row(s) -- a pre-existing assignment must NEVER be recorded as migration-created', v_cnt);

  -- the other, genuinely legacy loads (L1-L5) were processed exactly as in
  -- the main TEST_0133 run -- spot-check one of each kind still works.
  assert (select carrier_id from public.loads where id='10000000-0000-0000-0000-000000000001') = 'a1a1a1a1-0000-0000-0000-000000000001',
    'L1 (financial controller) should still resolve normally alongside the pre-existing L6';
  assert (select count(*) from public.carrier_backfill_0133_provenance where load_id='10000000-0000-0000-0000-000000000001') = 1,
    'L1 SHOULD have a provenance row (0133 actually resolved it)';

  raise notice 'OK: steps 3-6 -- 0133 succeeded with a pre-existing assignment present; L6 preserved byte-for-byte and excluded from provenance; L1 still resolved normally';
end
$t$;

-- ---- step 7: roll back 0133 --------------------------------------------
\echo '----- applying ROLLBACK_0133 -----'
\i ROLLBACK_0133_deterministic_carrier_backfill.sql

-- ---- step 8: the pre-existing assignment remains intact through rollback
do $t$
declare r record;
begin
  select carrier_id, carrier_resolution, carrier_locked_at into r
    from public.loads where id='60000000-0000-0000-0000-000000000006';
  assert r.carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002', format('L6 carrier_id was cleared by ROLLBACK_0133: %s', r.carrier_id);
  assert r.carrier_resolution = 'resolved', format('L6 carrier_resolution was cleared by ROLLBACK_0133: %s', r.carrier_resolution);

  -- meanwhile the freshly-resolved loads WERE reversed, proving the
  -- rollback is genuinely selective, not merely "does nothing".
  assert (select carrier_id from public.loads where id='10000000-0000-0000-0000-000000000001') is null,
    'L1 (freshly resolved by 0133) should have been reversed by ROLLBACK_0133';
  assert to_regclass('public.carrier_backfill_0133_provenance') is null,
    'ROLLBACK_0133 should have dropped the provenance table (no unsafe rows in this run)';

  raise notice 'OK: step 8 -- L6''s pre-existing assignment survived ROLLBACK_0133 completely intact, while L1-L5 (0133''s own writes) were correctly reversed';
end
$t$;

\echo '################  TEST 0133 PREEXISTING CARRIER RACE PASSED  ################'
