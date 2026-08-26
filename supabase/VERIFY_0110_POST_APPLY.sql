-- Phase 2Q.2C -- run AFTER applying 0110_driver_w9_grant_and_conversion_gate_repair.sql.

-- 1. The three columns are now granted.
select column_name from information_schema.column_privileges
where table_schema = 'public' and table_name = 'driver_w9s' and privilege_type = 'SELECT' and grantee = 'authenticated'
  and column_name in ('generated_by', 'voided_by', 'created_by')
order by column_name;
-- expect: 3 rows

-- 2. A full DRIVER_W9_STAFF_SAFE_COLUMNS-shaped select as the authenticated
--    role now succeeds (fixture-only -- replace with a real TEST-2Q2C-*
--    application id belonging to your own org, or skip and rely on the
--    live acceptance test instead).
-- select id, organization_id, application_id, driver_id, carrier_id, version, status, form_revision,
--   name_on_tax_return, business_name, tax_classification, llc_classification, other_classification_description,
--   has_foreign_partners_owners, exempt_payee_code, fatca_exemption_code,
--   address_line1, city, state, postal_code, requester_name_address, account_numbers,
--   tin_type, tin_last4, certified_name, certified_title, certified_at, certification_version,
--   generated_storage_path, generated_pdf_sha256, generated_file_size_bytes, page_count, generated_at, generated_by,
--   superseded_by, superseded_at, voided_at, voided_by, void_reason, failure_reason, created_at, updated_at, created_by
-- from public.driver_w9s where application_id = '<TEST application id>';
-- expect: the row returns instead of a permission-denied error

-- 3. convert_driver_application_to_driver() now references driver_w9s.
select pg_get_functiondef(oid) like '%driver_w9s%' as has_w9_check from pg_proc
where proname = 'convert_driver_application_to_driver' and pronamespace = 'public'::regnamespace;
-- expect: true

select id, status, escalated_at from public.operational_exceptions
where id in ('cd58ae7a-9ea7-415a-b299-700a87b803fd', '70cd450c-40bb-4497-b658-fa3714a128bf', '8f624ba6-a816-4f4b-87ec-24c1d12a4a0f');
-- expect: identical to the PREFLIGHT capture
