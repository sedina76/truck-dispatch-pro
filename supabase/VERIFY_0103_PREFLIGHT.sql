-- =============================================================================
-- VERIFY_0103_PREFLIGHT.sql
-- Phase 2P.4G -- read-only preflight for
-- supabase/migrations/0103_carrier_insurance_exception_integration.sql,
-- re-authored against the NOW-LIVE 0063 + 0104 + 0105 baseline (this file's
-- original version predated all three and asserted the table/function did
-- not exist -- that assumption no longer holds and has been corrected
-- here, not weakened). Every query here is a plain SELECT -- nothing here
-- mutates anything. 0103 only replaces one existing function body
-- (public.sync_time_based_exceptions()) -- no table/column/enum/index
-- change.
-- =============================================================================

-- 1. Foundation objects exist (0063).
select to_regclass('public.operational_exceptions') as operational_exceptions_table,
       to_regclass('public.operational_exception_notes') as operational_exception_notes_table,
       to_regclass('public.operational_exceptions_grouped') as operational_exceptions_grouped_view;
-- Expected: all three non-null.

-- 2. Function exists with the expected signature/security/schedule.
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef as security_definer, p.provolatile
from pg_proc p where p.proname = 'sync_time_based_exceptions';
-- Expected: 1 row, args = '', security_definer = true.

select jobname, schedule, command, active from cron.job where jobname = 'sync-time-based-exceptions';
-- Expected: 1 row, schedule = '*/5 * * * *', active = true. 0103 does not
-- touch this job -- confirm it still reads exactly this after applying.

-- 3. 0104 cast repair AND 0105 detention/notification repairs are live in
-- the CURRENT function source -- 0103 must be layering on top of this
-- exact baseline, not the original buggy 0063 body.
select pg_get_functiondef(oid) as live_source
from pg_proc where proname = 'sync_time_based_exceptions';
-- In the returned source, confirm ALL of:
--   (a) "replace(r.item_type::text, '_', ' ')" present (0104).
--   (b) the DETENTION open AND resolve loops both contain
--       "if r.dispatch_id is not null then ... else ... 'load'::public.
--       entity_type ... end if" (0105).
--   (c) "v_newly_opened_ids" is declared and the notification block's
--       final filter reads "oe.id = any (v_newly_opened_ids)" -- the
--       literal substring "first_detected_at >= now() - interval '1
--       minute'" must NOT appear anywhere (0105).
-- If any of (a)/(b)/(c) is missing, STOP -- 0103 would be layered on the
-- wrong baseline and must not be applied.

-- 4. operational_exceptions -- current distribution by source_type/
-- exception_type. Confirm 'insurance_policy' does NOT already exist as a
-- source_type (it shouldn't -- nothing writes it before 0103), and no
-- other object 0103 would create already exists under this name.
select source_type, exception_type, status, count(*) from public.operational_exceptions group by 1, 2, 3 order by 1, 2, 3;

-- 5. Dedup index still exactly as 0063 created it (0103 relies on this
-- exact index via ON CONFLICT for its own new insurance_policy rows).
select indexname, indexdef from pg_indexes
where tablename = 'operational_exceptions' and indexname = 'operational_exceptions_one_active_per_source';
-- Expected: 1 row, definition scoped to (source_type, source_id,
-- exception_type) where status <> 'resolved'.

-- 6. insurance_policies -- how many carrier-scoped rows with a non-null
-- expiry_date exist right now (the entire eligible population 0103's new
-- loop will evaluate on its very first post-apply run), and confirm the
-- live enum values 0103's loop keys off of.
select enumlabel from pg_enum where enumtypid = 'public.insurance_policy_type'::regtype order by enumsortorder;
-- Expected: cargo, general_liability, physical_damage, workers_compensation.

select policy_type, count(*) as total, count(*) filter (where expiry_date is not null) as with_expiry
from public.insurance_policies
where carrier_id is not null
group by 1 order by 1;

-- 7. How many of those are already within the 30-day/expired window today
-- (a rough prediction of how many exceptions 0103's first run will open --
-- exact count also depends on each org's classification, checked in query 8).
select count(*) from public.insurance_policies
where carrier_id is not null and expiry_date is not null and expiry_date <= current_date + interval '30 days';

-- 8. compliance_requirement_definitions -- confirm the 4 insurance
-- resolution_key values and their live classifications (system rows;
-- any org-specific overrides are additional rows with organization_id set).
select organization_id is null as is_system_row, resolution_key, classification, warning_days
from public.compliance_requirement_definitions
where entity_type = 'carrier' and resolution_source = 'insurance'
order by resolution_key, is_system_row desc;
-- Expected (system rows): cargo/general_liability = blocking,
-- workers_compensation = warning, physical_damage = optional.

-- 9. notifications table -- confirm entity_type/entity_id nullability
-- (the notification block's insurance_policy branch must never attempt to
-- insert a null into a NOT NULL column -- both are nullable, so this is a
-- non-issue either way, but confirm rather than assume).
select column_name, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'notifications' and column_name in ('entity_type', 'entity_id');

-- 10. The 3 real production compliance exceptions (2P.4D) -- baseline
-- snapshot immediately before 0103, to prove afterward they were never
-- touched by the insurance extension.
select id, title, severity, status from public.operational_exceptions
where source_type = 'compliance_item' order by first_detected_at;
-- Expected: exactly 3 rows, unchanged from every prior snapshot.
