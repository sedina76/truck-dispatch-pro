-- Phase 2Q.2 -- run AFTER applying 0108_carrier_driver_onboarding.sql.

-- 1. All 11 enum values now present.
select enumlabel from pg_enum
where enumtypid = 'public.driver_application_status'::regtype
order by enumsortorder;
-- expect: submitted, under_review, interview, approved, rejected, converted,
--         invited, in_progress, needs_correction, expired, cancelled

-- 2. New columns exist.
select column_name, data_type from information_schema.columns
where table_schema = 'public' and table_name = 'driver_applications'
  and column_name in ('invited_by', 'correction_reason');
-- expect: 2 rows

-- 3. New tables exist with RLS enabled and zero policies.
select relname, relrowsecurity from pg_class
where relname in ('driver_onboarding_invitations', 'driver_onboarding_sessions') and relnamespace = 'public'::regnamespace;
-- expect: relrowsecurity = true for both

select tablename, policyname from pg_policies
where tablename in ('driver_onboarding_invitations', 'driver_onboarding_sessions');
-- expect: 0 rows (service-role-only, mirrors carrier_onboarding_sessions)

select tablename, policyname, cmd from pg_policies
where tablename = 'driver_applications' order by policyname;
-- expect: driver_applications_insert_staff (new), driver_applications_select,
--         driver_applications_update (both pre-existing, unchanged)

-- 3b. Confirm the INSERT grant was actually narrowed (not left blanket).
select grantee, privilege_type, column_name from information_schema.column_privileges
where table_schema = 'public' and table_name = 'driver_applications' and privilege_type = 'INSERT' and grantee = 'authenticated'
order by column_name;
-- expect: exactly organization_id, status, first_name, middle_name,
--         last_name, email, phone, signature_name, invited_by -- not
--         every column (e.g. ssn_encrypted, converted_driver_id must NOT appear)

-- 4. convert_driver_application_to_driver now rejects a non-approved
--    application (fixture-only, disposable -- adjust the two ids below to
--    a real TEST-2Q2-* organization/application/carrier before running,
--    or skip this block and rely on the live acceptance test instead).
-- select public.convert_driver_application_to_driver('<TEST application id, status <> approved>', '<TEST carrier id>');
-- expect: raises "Only approved applications can be converted to a driver..."

-- 5. Compliance exceptions unchanged (standing rule).
select id, status, escalated_at from public.operational_exceptions
where id in ('cd58ae7a-9ea7-415a-b299-700a87b803fd', '70cd450c-40bb-4497-b658-fa3714a128bf', '8f624ba6-a816-4f4b-87ec-24c1d12a4a0f');
-- expect: identical to the PREFLIGHT capture
