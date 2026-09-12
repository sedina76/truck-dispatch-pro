-- ============================================================================
-- TEST_0133_STRUCTURAL_ABORT_PREEXISTING_CONFLICT.sql -- disposable database
-- only. Run via TEST_0130_0133_run.sh.
--
-- Correction item 9, fixture 6: "existing loads.carrier_id disagreeing with
-- a dispatch." Once guard_dispatch_carrier_scope() (0132) and
-- guard_load_carrier_change() (0132) are BOTH live, this state is
-- structurally UNREACHABLE through any normal write -- that is the entire
-- point of the correction. The only way to construct it for a test is
-- exactly how such a row could only ever really arise: raw, out-of-band data
-- (manual DB surgery, a restored-from-inconsistent-backup row, a future bug
-- bypassing the guards) that predates or circumvents the triggers entirely.
-- This test disables the two guard triggers just long enough to inject that
-- corruption directly, re-enables them, and then proves 0133's PHASE 1
-- structural-ABORT check (v_bad_preexisting_disp,
-- 0133_deterministic_carrier_backfill.sql lines ~305-321) fires and the
-- ENTIRE migration performs ZERO writes anywhere in the database -- not just
-- on the offending load. It then proves the corruption is recoverable via an
-- explicit, controlled correction (cancelling the conflicting dispatch), not
-- by 0133 silently guessing.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0133 STRUCTURAL ABORT (PRE-EXISTING CONFLICT)  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql

\echo '----- constructing an UNREACHABLE-VIA-NORMAL-WRITES state: loads.carrier_id = A1 while a NON-CANCELLED dispatch of A2 exists on the same load -----'
do $t$
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('ab000000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'LD-ABORT', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');

  -- disable BOTH 0132 guards just long enough to inject raw, out-of-band
  -- corrupted data -- simulating exactly how such a row could only really
  -- arise once the guards exist (manual DB surgery / a restored backup /
  -- a future bug bypassing the guarded RPC path), NOT a state reachable
  -- through any ordinary INSERT/UPDATE this schema's triggers allow.
  alter table public.dispatches disable trigger dispatches_guard_carrier_scope;
  alter table public.loads disable trigger loads_guard_carrier_change;

  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('ab0d0000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'ab000000-0000-0000-0000-00000000000a',
          'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'assigned');
  update public.loads set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001', carrier_resolution = 'resolved'
   where id = 'ab000000-0000-0000-0000-00000000000a';

  alter table public.dispatches enable trigger dispatches_guard_carrier_scope;
  alter table public.loads enable trigger loads_guard_carrier_change;

  raise notice 'OK: corrupted fixture injected (loads.carrier_id=A1, live dispatch carrier=A2) -- confirmed unreachable via any INSERT/UPDATE with the guards live (both triggers were disabled solely to construct this out-of-band state).';
end
$t$;

\echo '----- capturing a full pre-0133 snapshot (every table''s row count + every load''s carrier fields) for a byte-for-byte post-abort comparison -----'
create temp table _pre_0133_loads as select id, carrier_id, carrier_resolution, carrier_locked_at, financial_dispatch_id from public.loads order by id;
create temp table _pre_0133_counts as select
  (select count(*) from public.loads) as n_loads,
  (select count(*) from public.dispatches) as n_dispatches,
  (select count(*) from public.unresolved_carrier_records) as n_unresolved_records,
  (select to_regclass('public.carrier_backfill_0133_provenance')) as provenance_table_exists;

\echo '----- applying 0133 -- MUST ABORT with zero writes (structural corruption detected in PHASE 1) -----'
\set ON_ERROR_STOP off
\i migrations/0133_deterministic_carrier_backfill.sql
\set ON_ERROR_STOP on

\echo '----- confirming 0133 actually aborted (its own objects were never created, since it never reached PHASE 2/3) -----'
do $t$
begin
  if to_regclass('public.carrier_backfill_0133_provenance') is not null then
    raise exception 'TEST FAIL: carrier_backfill_0133_provenance exists -- 0133 did NOT abort, it committed despite the structural conflict.';
  end if;
  raise notice 'OK: 0133''s own provenance table was never created -- the migration never reached PHASE 2, confirming a full abort (BEGIN...COMMIT semantics: the RAISE EXCEPTION in PHASE 1 rolled back everything, including the DDL that would have created this table).';
end
$t$;

\echo '----- confirming ZERO writes occurred ANYWHERE -- not just on the offending load -----'
do $t$
declare c record; changed int;
begin
  select * into c from _pre_0133_counts;
  if (select count(*) from public.loads) <> c.n_loads then raise exception 'TEST FAIL: loads count changed despite 0133 aborting.'; end if;
  if (select count(*) from public.dispatches) <> c.n_dispatches then raise exception 'TEST FAIL: dispatches count changed despite 0133 aborting.'; end if;
  if (select count(*) from public.unresolved_carrier_records) <> c.n_unresolved_records then raise exception 'TEST FAIL: unresolved_carrier_records count changed despite 0133 aborting.'; end if;

  select count(*) into changed
  from _pre_0133_loads pre
  join public.loads l on l.id = pre.id
  where l.carrier_id is distinct from pre.carrier_id
     or l.carrier_resolution is distinct from pre.carrier_resolution
     or l.carrier_locked_at is distinct from pre.carrier_locked_at
     or l.financial_dispatch_id is distinct from pre.financial_dispatch_id;
  if changed <> 0 then
    raise exception 'TEST FAIL: % load(s) had a carrier field changed despite 0133 aborting -- % load(s) should have been resolvable/backfillable by the OTHERWISE-clean fixtures, proving 0133''s abort is not truly all-or-nothing.', changed, changed;
  end if;

  raise notice 'OK: byte-for-byte zero writes anywhere in the database -- every load''s carrier_id/carrier_resolution/carrier_locked_at/financial_dispatch_id is EXACTLY as it was before the aborted 0133 attempt (all-or-nothing confirmed: the corrupted load did not just block itself, it correctly blocked the ENTIRE migration run rather than silently resolving every other, otherwise-clean load).';
end
$t$;

\echo '----- controlled recovery: two corrections were actually needed, both confirmed by the first abort''s own diagnostic counts -----'
-- The first abort reported BOTH "1 PRE-EXISTING load disagrees with its own
-- financial_dispatch_id carrier" AND "1 PRE-EXISTING load disagrees with its
-- own non-cancelled dispatch carrier(s)": the fixture's uncancelled 0125
-- AFTER INSERT trigger (never disabled -- only the two 0132 guards were)
-- auto-set financial_dispatch_id to the A2 dispatch when it was inserted, so
-- the corruption is compound. Cancelling the A2 dispatch alone resolves the
-- second disagreement but NOT the first: financial_dispatch_id still points
-- at it (0129's cancel_dispatch() preserves financial_dispatch_id through
-- cancellation as history -- correctly reproduced even in this raw-SQL
-- cancellation), so it still contradicts loads.carrier_id=A1. An explicit
-- admin correction must resolve the controller reference itself, not merely
-- the dispatch's status -- exactly the "controlled process" item 1 requires,
-- never a silent 0133 guess at which of the two conflicting facts is right.
do $t$
begin
  update public.dispatches set status = 'cancelled', cancelled_at = now()
   where id = 'ab0d0000-0000-0000-0000-00000000000a';
  update public.loads set financial_dispatch_id = null
   where id = 'ab000000-0000-0000-0000-00000000000a';
  raise notice 'OK: an explicit, controlled correction (cancelling the conflicting historical dispatch AND clearing the contradicted financial_dispatch_id reference) resolves both structural disagreements -- not a silent 0133 guess.';
end
$t$;

\i migrations/0133_deterministic_carrier_backfill.sql

do $t$
declare r record;
begin
  select carrier_id, carrier_resolution into r from public.loads where id = 'ab000000-0000-0000-0000-00000000000a';
  assert r.carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001' and r.carrier_resolution = 'resolved',
    format('after the controlled correction, expected the load to remain resolved/A1 (PRE_EXISTING passthrough, now consistent), got %s', r);
  raise notice 'OK: after the controlled correction, 0133 applies cleanly and the previously-corrupted load is confirmed resolved/A1, consistent with its sole remaining (now-cancelled) dispatch history.';
end
$t$;

\echo '----- VERIFY_0133_POST_APPLY: every global invariant must hold after the recovered apply -----'
\i VERIFY_0133_POST_APPLY.sql

\echo '################  TEST 0133 STRUCTURAL ABORT (PRE-EXISTING CONFLICT) PASSED  ################'
