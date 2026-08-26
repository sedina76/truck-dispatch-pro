-- =============================================================================
-- VERIFY_0104_PREFLIGHT.sql
-- Phase 2P.4D -- read-only preflight for
-- supabase/migrations/0104_sync_time_based_exceptions_enum_cast_repair.sql.
-- Run this BEFORE applying 0104. Every query here is a plain SELECT --
-- nothing here mutates anything.
-- =============================================================================

-- 1. The function exists (from 0063) and confirm its live source still
-- contains the broken, uncast expression this migration is about to fix.
select pg_get_functiondef(oid) as live_source
from pg_proc where proname = 'sync_time_based_exceptions';
-- Expected: 1 row. In the returned source, confirm the COMPLIANCE loop's
-- case expression still reads literally "replace(r.item_type, '_', ' ')"
-- (uncast) at both occurrences -- i.e. the defect is still present,
-- confirming 0104 has something real to fix and hasn't already been
-- applied under a different number.

-- 2. Confirm compliance_items.item_type is genuinely the enum type this
-- defect depends on (not, say, already text).
select column_name, data_type, udt_name
from information_schema.columns
where table_schema = 'public' and table_name = 'compliance_items' and column_name = 'item_type';
-- Expected: data_type = 'USER-DEFINED', udt_name = 'compliance_item_type'.

-- 3. Confirm replace() has only the (text, text, text) overload -- i.e.
-- there genuinely is no (compliance_item_type, text, text) overload that
-- could have made the original call resolve by some other path.
select pg_get_function_identity_arguments(oid) as args
from pg_proc where proname = 'replace' and pronamespace = 'pg_catalog'::regnamespace;
-- Expected: only text-based overloads (e.g. "text, text, text" and
-- "text, text"), nothing accepting compliance_item_type.

-- 4. Reproduce the live failure one more time immediately before applying
-- the fix, for an unambiguous before/after record.
select public.sync_time_based_exceptions();
-- Expected: fails with 42883 "function replace(compliance_item_type,
-- unknown, unknown) does not exist" -- if this UNEXPECTEDLY succeeds,
-- STOP -- something has already changed and 0104 should not be applied
-- blindly on top of an assumption that no longer holds.

-- 5. Confirm no 0104 object exists yet (this migration only replaces an
-- existing function -- it creates nothing new -- so this is a light
-- sanity check, not a real collision risk).
select count(*) from pg_proc where proname = 'sync_time_based_exceptions' having count(*) > 1;
-- Expected: zero rows (no duplicate/ambiguous overload of this function
-- exists -- CREATE OR REPLACE must target exactly one).

-- 6. Current operational_exceptions state -- should still be empty (or
-- close to it), consistent with the 2P.4C finding that every invocation
-- since 0063 was applied has been rolling back entirely.
select count(*) from public.operational_exceptions;

-- 7. Cron job registration -- confirm untouched, for later post-apply
-- comparison (0104 must not need to re-register or alter this).
select jobname, schedule, active from cron.job where jobname = 'sync-time-based-exceptions';
