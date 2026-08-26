-- =============================================================================
-- VERIFY_0063_LATE_APPLY_PREFLIGHT.sql
-- Phase 2P.4B -- read-only preflight for the LATE application of the
-- historical migration supabase/migrations/0063_operational_exceptions.sql
-- (authored in an earlier phase, confirmed via live behavioral probes in
-- 2P.4A to have never actually been run against this project). Every
-- query here is a plain SELECT/introspection -- nothing here mutates
-- anything, and 0063 itself is not modified by any of this.
-- =============================================================================

-- 1. TARGET OBJECTS MUST NOT ALREADY EXIST (else 0063 would fail or
-- silently collide). If ANY of these come back non-empty/true, STOP --
-- do not apply 0063.
select to_regclass('public.operational_exceptions') as operational_exceptions_table,
       to_regclass('public.operational_exception_notes') as operational_exception_notes_table,
       to_regclass('public.operational_exceptions_grouped') as operational_exceptions_grouped_view;
-- Expected: all three NULL (none exist yet).

select typname from pg_type where typname in ('exception_type', 'exception_severity', 'exception_status');
-- Expected: zero rows -- none of the three enum types 0063 creates exist
-- yet under any name, orphaned or otherwise.

select proname, pg_get_function_identity_arguments(oid) as args from pg_proc where proname = 'sync_time_based_exceptions';
-- Expected: zero rows.

select jobname from cron.job where jobname = 'sync-time-based-exceptions';
-- Expected: zero rows -- no pre-existing job to collide with (0063 also
-- self-guards this with an unschedule-if-exists block, but confirm here
-- too rather than relying solely on that).

-- 2. PREREQUISITE TABLES/COLUMNS 0063 READS OR WRITES MUST EXIST WITH THE
-- EXPECTED SHAPE.
select
  to_regclass('public.organizations') is not null as organizations_ok,
  to_regclass('public.profiles') is not null as profiles_ok,
  to_regclass('public.dispatches') is not null as dispatches_ok,
  to_regclass('public.driver_latest_locations') is not null as driver_latest_locations_ok,
  to_regclass('public.load_stops') is not null as load_stops_ok,
  to_regclass('public.loads') is not null as loads_ok,
  to_regclass('public.compliance_items') is not null as compliance_items_ok,
  to_regclass('public.notifications') is not null as notifications_ok;
-- Expected: every column true.

select column_name, data_type from information_schema.columns
where table_schema = 'public' and table_name = 'organizations' and column_name in ('pickup_detention_free_minutes', 'delivery_detention_free_minutes');
-- Expected: 2 rows.

select column_name, data_type, udt_name from information_schema.columns
where table_schema = 'public' and table_name = 'compliance_items'
  and column_name in ('id', 'organization_id', 'entity_type', 'entity_id', 'item_type', 'expiry_date', 'status');
-- Expected: 7 rows; status/entity_type/item_type should show udt_name
-- 'compliance_status'/'entity_type'/'compliance_item_type' respectively.

select column_name, data_type, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'notifications'
  and column_name in ('organization_id', 'profile_id', 'type', 'title', 'body', 'entity_type', 'entity_id');
-- Expected: 7 rows; entity_type/entity_id nullable (already confirmed in
-- the 0103 preflight), organization_id/profile_id/type/title not null.

-- 3. REQUIRED ENUM VALUES ALREADY LIVE (0063 does not create these --
-- it only USES them).
select enumlabel from pg_enum where enumtypid = 'public.entity_type'::regtype order by enumsortorder;
-- Expected: includes 'dispatch' and 'carrier'.

select enumlabel from pg_enum where enumtypid = 'public.compliance_status'::regtype order by enumsortorder;
-- Expected: includes 'waived'.

select enumlabel from pg_enum where enumtypid = 'public.notification_type'::regtype order by enumsortorder;
-- Expected: includes 'system'.

-- 4. log_activity() -- 0063 calls the 5-argument overload
-- (entity_type, uuid, text, jsonb, uuid) positionally. Confirm it exists
-- and resolves unambiguously (i.e. there is exactly one 5-arg overload,
-- not two competing ones).
select pg_get_function_identity_arguments(oid) as args, count(*) over () as overload_count
from pg_proc where proname = 'log_activity' order by args;
-- Expected: 2 rows total -- a 4-arg and a 5-arg overload, each appearing
-- exactly once (overload_count = 2 on every row).

-- 5. set_updated_at() trigger function exists (0063 attaches it to
-- operational_exceptions).
select proname from pg_proc where proname = 'set_updated_at';
-- Expected: 1 row.

-- 6. has_role()/current_org_id() exist with the signatures 0063's RLS
-- policies call.
select proname, pg_get_function_identity_arguments(oid) as args from pg_proc where proname in ('has_role', 'current_org_id');
-- Expected: both present.

-- 7. pg_cron is enabled (0063 does not create the extension -- 0001 already
-- does, `create extension if not exists pg_cron` -- this just confirms it
-- actually took).
select extname, extversion from pg_extension where extname = 'pg_cron';
-- Expected: 1 row.

-- 8. Sanity: current live counts this migration's very first scheduled run
-- will immediately act on, so POST_APPLY has something to compare against.
select count(*) as non_terminal_dispatches_with_recent_gps
from public.dispatches d join public.driver_latest_locations dll on dll.dispatch_id = d.id
where d.status not in ('delivered', 'completed', 'cancelled');

select count(*) as open_load_stops_awaiting_departure
from public.load_stops where arrived_at is not null and departed_at is null;

select count(*) as compliance_items_within_30d_or_expired
from public.compliance_items where expiry_date is not null and status <> 'waived' and expiry_date <= current_date + interval '30 days';
