-- =============================================================================
-- VERIFY_0107_PREFLIGHT.sql
-- Phase 2P.6 -- read-only preflight for
-- supabase/migrations/0107_exception_notifications_escalation.sql.
-- Every query here is a plain SELECT/introspection -- nothing here
-- mutates, sends, or reads any real notification content.
-- =============================================================================

-- 1. Target columns/index must not already exist.
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'notifications' and column_name in ('exception_id', 'notification_event');
-- Expected: zero rows.

select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'operational_exceptions' and column_name = 'escalated_at';
-- Expected: zero rows.

select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'organizations' and column_name in ('critical_exception_escalation_minutes', 'high_exception_escalation_minutes');
-- Expected: zero rows.

select indexname from pg_indexes where indexname = 'notifications_exception_event_recipient_unique';
-- Expected: zero rows.

-- 2. Current live function baseline -- confirm 0103/0104/0105 are exactly
-- what 0107 is layering on top of (must contain the enum cast, the
-- detention null-dispatch fallback, and v_newly_opened_ids -- NOT the old
-- wall-clock heuristic).
select pg_get_functiondef(oid) as live_source
from pg_proc where proname = 'sync_time_based_exceptions';
-- Confirm: "replace(r.item_type::text, ...)" present; DETENTION open/resolve
-- both contain "if r.dispatch_id is not null then ... else ...
-- 'load'::public.entity_type ..."; "v_newly_opened_ids" declared and used
-- as "oe.id = any (v_newly_opened_ids)"; the CARRIER INSURANCE loop pair
-- present. If any of these is missing or different, STOP -- 0107 would be
-- layered on the wrong baseline.

-- 3. notifications table -- current RLS/grants (must remain exactly as-is;
-- 0107 adds columns only, no policy change).
select policyname, cmd, qual from pg_policies where tablename = 'notifications';
-- Expected: notifications_select/update/delete, all profile_id = auth.uid()
-- -- no authenticated INSERT policy (delivery is service-role/SECURITY
-- DEFINER only).

-- 4. Existing notification volume/shape sanity (informational).
select type, count(*) from public.notifications group by 1 order by 1;
select count(*) as unread_count from public.notifications where read_at is null;

-- 5. organizations -- confirm the two existing analogous "opt-in
-- nullable config" precedents this migration's new columns follow.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'organizations'
  and column_name in ('compliance_enforcement_mode', 'pickup_detention_free_minutes', 'delivery_detention_free_minutes');

-- 6. The three real production compliance exceptions -- read-only
-- snapshot before 0107 (must remain untouched by escalated_at/notification
-- changes; escalated_at will be added as NULL for every existing row,
-- including these three, since it is a plain ADD COLUMN with no default
-- expression -- confirm this explicitly after apply too).
select id, organization_id, status, severity, first_detected_at
from public.operational_exceptions
where source_type = 'compliance_item'
order by first_detected_at;

-- 7. Cron job unaffected (0107 adds no cron.schedule/unschedule call).
select jobname, schedule, active from cron.job where jobname = 'sync-time-based-exceptions';
