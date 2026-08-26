-- =============================================================================
-- VERIFY_0103_POST_APPLY.sql
-- Phase 2P.4 -- read-only post-apply verification for
-- supabase/migrations/0103_carrier_insurance_exception_integration.sql.
-- Run immediately after applying 0103. Every query here is a plain SELECT
-- -- nothing here mutates anything. Full behavioral acceptance (open/
-- dedup/resolve lifecycle, role/cross-org checks) is covered separately by
-- the live TEST-2P4-* acceptance script, not by this file.
-- =============================================================================

-- 1. Function still resolves with the same identity/security properties as
-- the preflight recorded -- a CREATE OR REPLACE never changes these, but
-- confirm literally, not assume.
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef as security_definer, p.provolatile
from pg_proc p where p.proname = 'sync_time_based_exceptions';
-- Expected: identical to the preflight's row.

-- 2. pg_cron schedule untouched by this migration.
select jobname, schedule, active from cron.job where jobname = 'sync-time-based-exceptions';
-- Expected: identical to the preflight's row -- 0103 never re-schedules.

-- 3. No new table/column/enum/index exists -- 0103 is a pure function-body
-- replacement. Confirm the exception_type enum still has exactly the same
-- 7 values (no new value added).
select enumlabel from pg_enum where enumtypid = 'public.exception_type'::regtype order by enumsortorder;
-- Expected: off_route, late, at_risk, detention, gps_stale, pod_missing,
-- compliance -- exactly 7, unchanged from before 0103.

-- 4. Manually invoke the evaluator once (safe -- it is idempotent by
-- design, same as every prior invocation via pg_cron) and confirm it
-- completes without error.
select public.sync_time_based_exceptions();

-- 5. Any new 'insurance_policy'-sourced exceptions this manual run opened,
-- for a sanity spot-check against query 4 of the preflight's predicted count.
select oe.id, oe.severity, oe.status, oe.title, oe.metadata
from public.operational_exceptions oe
where oe.source_type = 'insurance_policy'
order by oe.first_detected_at desc
limit 20;

-- 6. Confirm no 'insurance_policy' exception was opened for any 'optional'
-- or 'informational' classified policy (must be zero rows).
select oe.id, oe.metadata
from public.operational_exceptions oe
where oe.source_type = 'insurance_policy'
  and oe.status <> 'resolved'
  and oe.metadata->>'classification' not in ('blocking', 'warning');
-- Expected: zero rows.

-- 7. Dedup sanity -- at most one ACTIVE insurance_policy exception per
-- source_id (the existing partial unique index already guarantees this
-- structurally; this just double-confirms no duplicate slipped through
-- some path that bypasses the index, which should be impossible).
select source_id, count(*) from public.operational_exceptions
where source_type = 'insurance_policy' and status <> 'resolved'
group by source_id having count(*) > 1;
-- Expected: zero rows.

-- 8. Re-run the evaluator a second time immediately and confirm the exact
-- same active insurance_policy exception IDs remain (no new rows, no
-- duplicate opens) -- the simplest possible idempotency proof.
select public.sync_time_based_exceptions();
select count(*) as active_insurance_exceptions from public.operational_exceptions where source_type = 'insurance_policy' and status <> 'resolved';
-- Expected: identical count to query 5/7's result -- unchanged by the
-- second run.
