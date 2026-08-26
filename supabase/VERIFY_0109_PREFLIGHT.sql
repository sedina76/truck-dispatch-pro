-- Phase 2Q.2B -- run BEFORE applying 0109_driver_carrier_binding_and_w9.sql.

select column_name from information_schema.columns
where table_schema = 'public' and table_name in ('driver_applications', 'drivers')
  and column_name in ('carrier_id', 'worker_type');
-- expect: 0 rows

select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('driver_w9s', 'driver_w9_pii_access_log');
-- expect: 0 rows

select pg_get_functiondef(oid) from pg_proc
where proname = 'convert_driver_application_to_driver' and pronamespace = 'public'::regnamespace;
-- for before/after comparison -- confirms current signature is (uuid, uuid), not (uuid, uuid default null)

select id, status, escalated_at from public.operational_exceptions
where id in ('cd58ae7a-9ea7-415a-b299-700a87b803fd', '70cd450c-40bb-4497-b658-fa3714a128bf', '8f624ba6-a816-4f4b-87ec-24c1d12a4a0f');
