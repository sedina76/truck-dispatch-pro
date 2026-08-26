-- =============================================================================
-- VERIFY_0107_POST_APPLY.sql
-- Phase 2P.6 -- read-only except for two intentional evaluator calls
-- (queries 7/8), consistent with this project's established post-apply
-- discipline. Run immediately after applying 0107.
-- =============================================================================

-- 1. New columns exist with the right shape.
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'notifications' and column_name in ('exception_id', 'notification_event')
order by column_name;
-- Expected: 2 rows, both nullable; exception_id uuid, notification_event text.

select column_name, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'operational_exceptions' and column_name = 'escalated_at';
-- Expected: 1 row, nullable.

select column_name, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'organizations'
  and column_name in ('critical_exception_escalation_minutes', 'high_exception_escalation_minutes');
-- Expected: 2 rows, both nullable.

-- 2. New unique index exists with the expected definition.
select indexname, indexdef from pg_indexes where indexname = 'notifications_exception_event_recipient_unique';
-- Expected: 1 row, unique, on (exception_id, profile_id, notification_event)
-- where exception_id is not null.

-- 3. Every existing organization defaults to escalation DISABLED (NULL) --
-- opt-in, zero behavior change until explicitly configured.
select
  count(*) as total_orgs,
  count(critical_exception_escalation_minutes) as orgs_with_critical_threshold,
  count(high_exception_escalation_minutes) as orgs_with_high_threshold
from public.organizations;
-- Expected: orgs_with_critical_threshold = 0 and orgs_with_high_threshold = 0
-- immediately post-apply (no org has configured either yet).

-- 4. Every existing operational_exceptions row has escalated_at = NULL
-- (plain ADD COLUMN, no backfill).
select count(*) as total, count(escalated_at) as with_escalated_at from public.operational_exceptions;
-- Expected: with_escalated_at = 0.

-- 5. notifications RLS/grants unchanged.
select policyname, cmd, qual from pg_policies where tablename = 'notifications';
-- Expected: identical to the preflight's own query-3 result.

-- 6. The three real production compliance exceptions -- confirm identical
-- ids/organization/status/severity to the preflight snapshot, and
-- escalated_at is NULL for them too (they were never touched).
select id, organization_id, status, severity, escalated_at
from public.operational_exceptions
where source_type = 'compliance_item'
order by first_detected_at;
-- Expected: same 3 ids/org/status/severity as the preflight, escalated_at
-- null for all three.

-- 7. Invoke the evaluator once -- must succeed with no error (confirms the
-- new escalation pass and the ON CONFLICT-guarded notification insert are
-- both syntactically/semantically sound against live data).
select public.sync_time_based_exceptions();

-- 8. Invoke it again immediately -- idempotency: no duplicate notifications,
-- no duplicate escalations (nothing should escalate yet regardless, since
-- every org's thresholds are still NULL from query 3 above -- this proves
-- the opt-in default is inert, not merely configured to look inert).
select public.sync_time_based_exceptions();

select notification_event, count(*) from public.notifications
where exception_id is not null
group by notification_event;
-- Informational -- shows how many 'opened' notifications exist so far
-- (should be 0 'escalated' rows, since no organization has a threshold
-- configured yet).

select exception_id, profile_id, notification_event, count(*)
from public.notifications
where exception_id is not null
group by exception_id, profile_id, notification_event
having count(*) > 1;
-- Expected: zero rows -- the unique index structurally guarantees this,
-- this query just double-confirms nothing slipped through.

-- 9. Cron job unchanged.
select jobname, schedule, active from cron.job where jobname = 'sync-time-based-exceptions';
