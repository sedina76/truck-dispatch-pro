-- Phase 2Q.2B -- run AFTER applying 0109_driver_carrier_binding_and_w9.sql.

select table_name, column_name, data_type from information_schema.columns
where table_schema = 'public' and table_name in ('driver_applications', 'drivers')
  and column_name in ('carrier_id', 'worker_type')
order by table_name, column_name;
-- expect: 3 rows (driver_applications.carrier_id, driver_applications.worker_type, drivers.worker_type)

select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('driver_w9s', 'driver_w9_pii_access_log');
-- expect: 2 rows

select tablename, policyname, cmd from pg_policies where tablename = 'driver_w9s';
-- expect: driver_w9s_select only

select proname, pronargs from pg_proc
where proname in (
  'create_driver_w9_draft','update_driver_w9_draft','set_driver_w9_tin','certify_driver_w9',
  'finalize_driver_w9','fail_driver_w9','void_driver_w9','delete_driver_w9_draft','reveal_driver_w9_tin'
) and pronamespace = 'public'::regnamespace
order by proname;
-- expect: all 9 present

select column_name, privilege_type from information_schema.column_privileges
where table_schema = 'public' and table_name = 'driver_applications' and grantee = 'authenticated'
  and column_name in ('carrier_id', 'worker_type')
order by column_name, privilege_type;
-- expect: carrier_id -> INSERT, SELECT only (no UPDATE); worker_type -> INSERT, SELECT, UPDATE

select id.exists as bucket_exists from (select true as exists from storage.buckets where id = 'driver-w9s') id;
-- expect: true

select id, status, escalated_at from public.operational_exceptions
where id in ('cd58ae7a-9ea7-415a-b299-700a87b803fd', '70cd450c-40bb-4497-b658-fa3714a128bf', '8f624ba6-a816-4f4b-87ec-24c1d12a4a0f');
-- expect: identical to the PREFLIGHT capture
