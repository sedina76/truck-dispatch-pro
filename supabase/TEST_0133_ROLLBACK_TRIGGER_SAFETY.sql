-- ============================================================================
-- TEST_0133_ROLLBACK_TRIGGER_SAFETY.sql -- disposable database only.
-- Run via TEST_0130_0133_run.sh.
--
-- Demonstrates, directly and independently of ROLLBACK_0133's own logic,
-- the PostgreSQL guarantee that ROLLBACK_0133 relies on: ALTER TABLE ...
-- DISABLE TRIGGER is ordinary transactional DDL. If a transaction that
-- disabled a trigger fails or is rolled back for ANY reason before COMMIT,
-- PostgreSQL reverts the disable along with everything else -- the trigger
-- can never be left disabled by a crashed/aborted transaction.
--
-- This is a GENERAL Postgres property (not specific to our function bodies),
-- demonstrated here against the actual loads_guard_carrier_change trigger
-- with the actual DISABLE/ENABLE statements ROLLBACK_0133 uses, so the
-- proof is concrete rather than assumed.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0133 ROLLBACK TRIGGER SAFETY  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql

-- Baseline: the trigger is enabled after 0132.
do $t$
begin
  assert (select tgenabled from pg_trigger where tgname='loads_guard_carrier_change' and tgrelid='public.loads'::regclass) = 'O',
    'baseline: loads_guard_carrier_change must be ENABLED before the test';
  raise notice 'baseline OK: loads_guard_carrier_change enabled (tgenabled=O)';
end
$t$;

-- Deliberate failure INSIDE an explicit transaction, AFTER disabling the
-- trigger -- exactly the shape ROLLBACK_0133 uses -- followed by an explicit
-- ROLLBACK (simulating the automatic abort psql performs on an ERROR).
\echo '----- BEGIN; disable trigger; deliberately fail; ROLLBACK -----'
\set ON_ERROR_STOP off
BEGIN;
ALTER TABLE public.loads DISABLE TRIGGER loads_guard_carrier_change;
-- sanity check WHILE INSIDE the still-open transaction: really disabled now.
DO $$
begin
  if (select tgenabled from pg_trigger where tgname='loads_guard_carrier_change' and tgrelid='public.loads'::regclass) <> 'D' then
    raise exception 'TEST SETUP FAILED: trigger was not actually disabled mid-transaction';
  end if;
  raise notice 'mid-transaction: trigger is disabled (tgenabled=D), as expected, before the deliberate failure';
end
$$;
-- the deliberate failure: an ordinary RAISE EXCEPTION, aborting this transaction
DO $$
begin
  raise exception 'DELIBERATE TEST FAILURE -- demonstrates transactional DDL rollback of ALTER TABLE ... DISABLE TRIGGER';
end
$$;
ROLLBACK;
\set ON_ERROR_STOP on

-- Postcondition: reconnect-fresh state (new statement, new implicit
-- transaction) shows the trigger is ENABLED again -- Postgres rolled the
-- DISABLE back along with the rest of the aborted transaction.
do $t$
begin
  assert (select tgenabled from pg_trigger where tgname='loads_guard_carrier_change' and tgrelid='public.loads'::regclass) = 'O',
    'FAIL: loads_guard_carrier_change is NOT enabled after the aborted transaction -- a crashed rollback would have left production guarded loads writable without the carrier guard.';
  raise notice 'OK: after ROLLBACK of a transaction that disabled the trigger and then failed, the trigger is ENABLED again (tgenabled=O). PostgreSQL guarantees ALTER TABLE ... DISABLE/ENABLE TRIGGER cannot be left half-applied.';
end
$t$;

-- Behavioral confirmation: the guard is ACTUALLY enforcing again (not just
-- the catalog flag) -- an illegal carrier clear is rejected.
do $t$
begin
  update public.loads set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' where id = '40000000-0000-0000-0000-000000000004';
  begin
    update public.loads set carrier_id = null where id = '40000000-0000-0000-0000-000000000004';
    raise exception 'TEST FAIL: clearing carrier_id succeeded -- the guard trigger is NOT actually enforcing after the rollback';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: guard_load_carrier_change is actively enforcing again (rejected clearing carrier_id): %', sqlerrm;
  end;
end
$t$;

\echo '################  TEST 0133 ROLLBACK TRIGGER SAFETY PASSED  ################'
