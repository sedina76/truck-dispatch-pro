-- =============================================================================
-- VERIFY_0101_PREFLIGHT.sql
-- Phase 2O.1 -- read-only preflight for
-- supabase/migrations/0101_driver_photo_shareable_insert_grant.sql.
-- Run this BEFORE applying 0101. Every query here is a plain SELECT --
-- nothing here mutates anything.
-- =============================================================================

-- 1. public.drivers exists.
select count(*) as drivers_table_exists
from information_schema.tables
where table_schema = 'public' and table_name = 'drivers';
-- Expected: 1.

-- 2. RLS is enabled on public.drivers.
select relrowsecurity as rls_enabled
from pg_class
where oid = 'public.drivers'::regclass;
-- Expected: true.

-- 3. photo_shareable column exists, with the expected shape.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'drivers' and column_name = 'photo_shareable';
-- Expected: one row, boolean, not null, default false.

-- 4/5/6. The exact three-verb gap this migration closes.
select
  has_column_privilege('authenticated', 'public.drivers', 'photo_shareable', 'SELECT') as has_select,
  has_column_privilege('authenticated', 'public.drivers', 'photo_shareable', 'UPDATE') as has_update,
  has_column_privilege('authenticated', 'public.drivers', 'photo_shareable', 'INSERT') as has_insert_before_0101;
-- Expected: has_select = true, has_update = true, has_insert_before_0101 = false.
-- If has_insert_before_0101 is already true, 0101 has either already been
-- applied or something else already granted it -- STOP and investigate
-- before applying (GRANT is idempotent so re-running is harmless, but the
-- discrepancy itself should be understood first).

-- 7. Sensitive encrypted columns remain outside ordinary INSERT/SELECT/
-- UPDATE privileges -- must all be false, for every verb, both before and
-- after 0101 (0101 never references these columns).
select
  col,
  has_column_privilege('authenticated', 'public.drivers', col, 'SELECT') as can_select,
  has_column_privilege('authenticated', 'public.drivers', col, 'INSERT') as can_insert,
  has_column_privilege('authenticated', 'public.drivers', col, 'UPDATE') as can_update
from unnest(array['ssn_encrypted', 'direct_deposit_account_encrypted', 'direct_deposit_routing_encrypted']) as col;
-- Expected: every one of the 9 booleans is false.

-- 8. drivers_insert RLS policy still contains the intended roles
-- (owner/admin/dispatcher, org-scoped) -- informational text match, since
-- pg_policies stores the compiled qual/with_check expression.
select policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'drivers' and policyname = 'drivers_insert';
-- Expected: one row, cmd = 'INSERT', with_check mentioning
-- current_org_id() and has_role(... 'owner','admin','dispatcher' ...).

-- 9. No conflicting/unexpected grant state: full column-privilege map for
-- every INSERT-relevant column on drivers, for cross-check against the
-- exact list createDriver() sends (organization_id, carrier_id,
-- first_name, middle_name, last_name, phone, email, status,
-- employee_number, department, hire_date, home_terminal_city,
-- home_terminal_state, date_of_birth, gender, address_line1, city, state,
-- postal_code, emergency_contact_name, emergency_contact_phone,
-- photo_url, photo_shareable, cdl_number, cdl_state, cdl_class,
-- cdl_restrictions, cdl_endorsements, cdl_expiry_date,
-- medical_card_number, medical_card_expiry_date, drug_test_date,
-- drug_test_expiry_date, background_check_date, background_check_status,
-- mvr_date, mvr_status, twic_expiry_date, hazmat_endorsement_expiry_date,
-- passport_number, passport_expiry_date, work_authorization_status,
-- work_authorization_expiry_date, direct_deposit_bank_name, notes).
select grantee, table_name, column_name, privilege_type
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'drivers' and grantee = 'authenticated' and privilege_type = 'INSERT'
order by column_name;
-- Expected: every column in the list above EXCEPT photo_shareable present;
-- photo_shareable absent (that's exactly the gap 0101 closes). No
-- encrypted PII column present. No unexpected extra column present.
