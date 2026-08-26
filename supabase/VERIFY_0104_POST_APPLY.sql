-- =============================================================================
-- VERIFY_0104_POST_APPLY.sql
-- Phase 2P.4D -- read-only except for the two intentional evaluator calls
-- (queries 4 and 5 below), consistent with this project's established
-- post-apply discipline of actually invoking a repaired scheduled
-- function rather than only inspecting its text. Run immediately after
-- applying 0104.
-- =============================================================================

-- 1. Live source now contains the cast -- both occurrences fixed, no
-- occurrence of the broken uncast form remains.
select pg_get_functiondef(oid) as live_source
from pg_proc where proname = 'sync_time_based_exceptions';
-- Expected: the COMPLIANCE loop's case expression now reads
-- "replace(r.item_type::text, '_', ' ')" at both occurrences, and a
-- text-search of this same source for the literal substring
-- "replace(r.item_type, " (without ::text immediately after item_type)
-- should find zero matches.

-- 2. Exact function signature/security/volatility unchanged from before
-- 0104 (a CREATE OR REPLACE with the identical signature never changes
-- these, but confirm literally).
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef as security_definer, p.provolatile,
  (select setting from unnest(p.proconfig) as setting where setting like 'search_path=%') as search_path_setting
from pg_proc p where p.proname = 'sync_time_based_exceptions';
-- Expected: args = '', security_definer = true, search_path_setting
-- mentions 'public' -- identical to the 0063/pre-0104 preflight's own row.

-- 3. Grants unchanged (0104 grants nothing new -- this function was never
-- directly grantable to authenticated in the first place; it runs only
-- via pg_cron as its definer).
select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_name = 'sync_time_based_exceptions';
-- Expected: whatever this returned before 0104 (likely no rows, since
-- this function has no explicit GRANT EXECUTE statement in 0063 either --
-- it is invoked only by pg_cron under its own SECURITY DEFINER identity).

-- 4. Cron job registration untouched.
select jobname, schedule, active from cron.job where jobname = 'sync-time-based-exceptions';
-- Expected: identical to the 0104 preflight's own row -- 0104 never
-- touches cron.schedule()/cron.unschedule().

-- 5. Invoke the evaluator -- must now succeed (previously failed with
-- 42883 on the immediately-preceding preflight run).
select public.sync_time_based_exceptions();

-- 6. Invoke it a second time immediately -- idempotency: no duplicate
-- exceptions, no error on repeated invocation.
select public.sync_time_based_exceptions();

-- 7. Confirm the 3 known live compliance_items rows identified during
-- 2P.4C diagnosis produced exactly one exception each (not duplicated by
-- the two consecutive calls above), and that severity/title reflect their
-- expired status correctly with a readable (space-separated, not
-- underscore-separated) item_type in the title.
select oe.id, oe.source_id, oe.severity, oe.status, oe.title, oe.summary
from public.operational_exceptions oe
where oe.source_type = 'compliance_item'
order by oe.first_detected_at desc;
-- Expected: exactly 3 rows (matching the 3 compliance_items rows found
-- live in 2P.4C: 2x cdl_expiry, 1x annual_inspection, all expired),
-- titles reading "Cdl Expiry Expired"/"Annual Inspection Expired" (space-
-- separated, proving the cast+replace() actually executed), severity =
-- 'high' for all three (they were already past-due, not merely
-- expiring-soon).

-- 8. Dedup sanity -- no source_id appears more than once among active rows.
select source_id, count(*) from public.operational_exceptions
where source_type = 'compliance_item' and status <> 'resolved'
group by source_id having count(*) > 1;
-- Expected: zero rows.
