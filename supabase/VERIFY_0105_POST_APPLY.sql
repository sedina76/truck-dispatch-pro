-- =============================================================================
-- VERIFY_0105_POST_APPLY.sql
-- Phase 2P.4E -- read-only except for the two intentional evaluator calls
-- (queries 6 and 7), consistent with this project's established post-apply
-- discipline. Run immediately after applying 0105.
-- =============================================================================

-- 1. Function signature/security/search_path unchanged.
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef as security_definer, p.provolatile,
  (select setting from unnest(p.proconfig) as setting where setting like 'search_path=%') as search_path_setting
from pg_proc p where p.proname = 'sync_time_based_exceptions';
-- Expected: identical to the 0105 preflight's own row.

-- 2. Grants unchanged (this function has never had a direct GRANT EXECUTE
-- -- it runs only via pg_cron under its own SECURITY DEFINER identity).
select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_name = 'sync_time_based_exceptions';
-- Expected: identical to before (likely zero rows).

-- 3. Cron job registration untouched.
select jobname, schedule, active from cron.job where jobname = 'sync-time-based-exceptions';
-- Expected: identical to the 0105 preflight's own row.

-- 4. Live source now contains all three repairs together, and neither old
-- bug's exact text remains.
select pg_get_functiondef(oid) as live_source
from pg_proc where proname = 'sync_time_based_exceptions';
-- Confirm in the returned source:
--   (a) 0104 cast preserved: "replace(r.item_type::text, '_', ' ')" present.
--   (b) 0105 detention fix present: the DETENTION open loop's
--       log_activity call is now guarded by "if r.dispatch_id is not
--       null then ... else ... log_activity('load'::public.entity_type,
--       r.load_id, ...) ... end if" (both open and resolve loops).
--   (c) 0105 notification fix present: the notification block's final
--       filter now reads "oe.id = any (v_newly_opened_ids)" -- the literal
--       substring "first_detected_at >= now() - interval '1 minute'"
--       must NOT appear anywhere in the source.
--   (d) v_newly_opened_ids is declared and appended to at each loop's own
--       v_was_insert=true point (gps_stale, detention, compliance).

-- 5. Confirm the 3 real production compliance exceptions are untouched
-- (same ids/titles/severities as the 0105 preflight's own snapshot;
-- last_detected_at may legitimately advance on the evaluator calls below
-- -- that is normal re-confirmation behavior, not a mutation of substance).
select id, title, severity, status from public.operational_exceptions
where source_type = 'compliance_item' order by first_detected_at;
-- Expected: same 3 ids, same titles/severities/status as the preflight.

-- 6. Invoke the evaluator -- must succeed with no error.
select public.sync_time_based_exceptions();

-- 7. Invoke it again immediately -- idempotency, and (critically) no
-- duplicate notification for whatever it opened on the previous call.
select public.sync_time_based_exceptions();

-- 8. Notification sanity -- for any exception opened by call 6/7 above,
-- there must be at most one notification row (not two), since neither
-- call could have inserted the SAME exception twice (the dedup index
-- already guarantees that), and the new v_newly_opened_ids mechanism only
-- ever includes ids THAT SPECIFIC invocation genuinely inserted.
select entity_id, count(*) from public.notifications
where type = 'system' and created_at >= now() - interval '5 minutes'
group by entity_id having count(*) > 1;
-- Expected: zero rows.
