-- =============================================================================
-- VERIFY_0105_PREFLIGHT.sql
-- Phase 2P.4E -- read-only preflight for
-- supabase/migrations/0105_sync_time_based_exceptions_detention_notification_repair.sql.
-- Run this BEFORE applying 0105. A deliberate evaluator reproduction
-- appears in query 4 -- everything else is a plain SELECT.
-- =============================================================================

-- 1. Function exists and 0104's enum casts are live (must NOT regress).
select pg_get_functiondef(oid) as live_source
from pg_proc where proname = 'sync_time_based_exceptions';
-- Expected: 1 row. In the returned source, confirm:
--   (a) "replace(r.item_type::text, '_', ' ')" appears (0104's cast fix,
--       must still be present) -- NOT the old uncast form.
--   (b) the DETENTION open loop's log_activity call is still the OLD,
--       unconditional "perform public.log_activity('dispatch'::public.
--       entity_type, r.dispatch_id, 'exception_opened', ...)" with no
--       null-guard -- i.e. the first defect this migration fixes is still
--       present.
--   (c) the notification block's final filter is still the OLD wall-clock
--       form "oe.first_detected_at >= now() - interval '1 minute'" -- i.e.
--       the second defect this migration fixes is still present.
-- If either (b) or (c) is already absent, STOP -- something has already
-- changed and 0105 should not be applied blindly on top of an assumption
-- that no longer holds.

-- 2. Confirm 'load' is a valid public.entity_type value (the chosen
-- fallback target when a detention exception has no active dispatch).
select enumlabel from pg_enum where enumtypid = 'public.entity_type'::regtype order by enumsortorder;
-- Expected: includes 'load' (and 'dispatch', 'carrier', already relied on
-- elsewhere in this function).

-- 3. Confirm load_stops.load_id and operational_exceptions.load_id are
-- both NOT NULL-safe for this repair's purposes (load_stops.load_id has a
-- NOT NULL constraint; operational_exceptions.load_id is nullable at the
-- table level but the DETENTION open loop already always supplies it).
select column_name, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'load_stops' and column_name = 'load_id';
-- Expected: is_nullable = 'NO'.

select column_name, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'operational_exceptions' and column_name = 'load_id';
-- Expected: is_nullable = 'YES' at the table level (fine -- the DETENTION
-- loop itself always populates it; this migration's resolve-loop repair
-- additionally SELECTs oe.load_id, which requires nothing further).

-- 4. activity_logs.entity_id -- confirm it is genuinely NOT NULL (the
-- exact constraint both live defects violate).
select column_name, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'activity_logs' and column_name = 'entity_id';
-- Expected: is_nullable = 'NO'.

-- 5. Cron job registration -- confirm untouched, for later post-apply
-- comparison (0105 must not need to re-register or alter this).
select jobname, schedule, active from cron.job where jobname = 'sync-time-based-exceptions';

-- 6. Confirm the 3 known real production compliance exceptions (from
-- 2P.4D) are still present and open -- baseline snapshot before 0105,
-- to prove afterward they were never touched by this repair.
select id, title, severity, status from public.operational_exceptions
where source_type = 'compliance_item' order by first_detected_at;
-- Expected: exactly 3 rows, unchanged from the 0104 post-apply record
-- (2x "cdl expiry Expired", 1x "annual inspection Expired", all high/open).
