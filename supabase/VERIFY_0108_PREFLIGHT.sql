-- Phase 2Q.2 -- run BEFORE applying 0108_carrier_driver_onboarding.sql.
-- Confirms the baseline this migration assumes is actually true. Read-only.

-- 1. Current enum values (expect exactly: submitted, under_review,
--    interview, approved, rejected, converted -- none of the 5 new ones yet).
select enumlabel from pg_enum
where enumtypid = 'public.driver_application_status'::regtype
order by enumsortorder;

-- 2. driver_applications does not yet have the new columns.
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'driver_applications'
  and column_name in ('invited_by', 'correction_reason');
-- expect: 0 rows

-- 2b. Current INSERT grant on driver_applications (expect this to show
--     either no rows, or the full blanket column set Supabase originally
--     granted at table creation -- confirms whether the narrowing in
--     0108 is actually changing anything real).
select grantee, privilege_type, column_name from information_schema.column_privileges
where table_schema = 'public' and table_name = 'driver_applications' and privilege_type = 'INSERT' and grantee in ('authenticated', 'anon')
order by grantee, column_name;

-- 3. The two new tables do not exist yet.
select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('driver_onboarding_invitations', 'driver_onboarding_sessions');
-- expect: 0 rows

-- 4. convert_driver_application_to_driver's current definition (for
--    before/after comparison -- confirms it does NOT yet require
--    status = 'approved').
select pg_get_functiondef(oid) from pg_proc
where proname = 'convert_driver_application_to_driver' and pronamespace = 'public'::regnamespace;

-- 5. Record the three real production compliance exceptions' state
--    (standing engagement rule -- this migration does not touch them, but
--    every phase records before/after regardless).
select id, status, escalated_at from public.operational_exceptions
where id in ('cd58ae7a-9ea7-415a-b299-700a87b803fd', '70cd450c-40bb-4497-b658-fa3714a128bf', '8f624ba6-a816-4f4b-87ec-24c1d12a4a0f');
