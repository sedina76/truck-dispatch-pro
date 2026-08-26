-- Phase 2Q.2C -- run BEFORE applying 0110_driver_w9_grant_and_conversion_gate_repair.sql.

-- 1. Confirms the current (buggy) grant list is missing the three columns.
select column_name from information_schema.column_privileges
where table_schema = 'public' and table_name = 'driver_w9s' and privilege_type = 'SELECT' and grantee = 'authenticated'
  and column_name in ('generated_by', 'voided_by', 'created_by');
-- expect: 0 rows (this is the bug)

-- 2. Current convert_driver_application_to_driver() has no W-9 check yet.
select pg_get_functiondef(oid) from pg_proc
where proname = 'convert_driver_application_to_driver' and pronamespace = 'public'::regnamespace;
-- for before/after comparison -- confirms no driver_w9s reference exists yet

select id, status, escalated_at from public.operational_exceptions
where id in ('cd58ae7a-9ea7-415a-b299-700a87b803fd', '70cd450c-40bb-4497-b658-fa3714a128bf', '8f624ba6-a816-4f4b-87ec-24c1d12a4a0f');
