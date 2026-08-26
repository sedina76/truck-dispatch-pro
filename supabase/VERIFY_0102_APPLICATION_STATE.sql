-- =============================================================================
-- VERIFY_0102_APPLICATION_STATE.sql
-- Phase 2P.2B -- read-only live-state diagnostic for
-- supabase/migrations/0102_carrier_compliance_foundation.sql, run after a
-- reported "type ... already exists" error on a SECOND execution attempt.
-- Every query here is a plain SELECT -- nothing here mutates anything.
--
-- Behavioral (supabase-js/service-role) checks already run this session
-- confirmed every table, every added column, all five RPCs (by successful
-- resolution -- each returned its OWN internal business-logic error on
-- dummy input, never "function does not exist" or "not unique"), and all
-- 7 seed rows are present and correct, with all 38 live organizations
-- correctly defaulted to audit_only. This file exists to let you
-- independently confirm the pg_catalog-level detail (exact indexes,
-- constraints, triggers, RLS policy text, grants) that a REST-API-based
-- check cannot see directly.
-- =============================================================================

-- 1. The enum that raised the error, and its exact values.
select enumlabel from pg_enum where enumtypid = 'public.compliance_enforcement_mode'::regtype order by enumsortorder;
-- Expected: audit_only, warning, enforced -- exactly 3 values, in this order.

-- 2. organizations.compliance_enforcement_mode -- shape and live distribution.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'organizations' and column_name = 'compliance_enforcement_mode';

select compliance_enforcement_mode, count(*) from public.organizations group by 1;
-- Expected: one row, mode = 'audit_only', count = every organization that exists.

-- 3. New tables exist with the right row-level security state.
select relname, relrowsecurity
from pg_class
where relname in ('compliance_requirement_definitions', 'carrier_suspensions', 'compliance_overrides')
order by relname;
-- Expected: 3 rows, relrowsecurity = true for all.

-- 4. compliance_requirement_definitions -- full column list.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'compliance_requirement_definitions'
order by ordinal_position;

-- 5. compliance_requirement_definitions -- constraints.
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.compliance_requirement_definitions'::regclass
order by conname;
-- Expected: primary key + compliance_requirement_definitions_informational_shape,
-- _insurance_needs_key, _expiration_source, _w9_agreement_no_key, plus the
-- three not-null-check CHECKs on requirement_key/display_name/classification/
-- resolution_source, plus the organization_id FK.

-- 6. compliance_requirement_definitions -- indexes.
select indexname, indexdef from pg_indexes
where tablename = 'compliance_requirement_definitions' order by indexname;
-- Expected: primary key index, compliance_requirement_definitions_system_key
-- (unique, partial where organization_id is null), _org_key (unique, partial
-- where organization_id is not null), _org_lookup (partial where
-- organization_id is not null and is_active).

-- 7. compliance_requirement_definitions -- RLS policies.
select policyname, cmd, qual, with_check from pg_policies
where tablename = 'compliance_requirement_definitions' order by policyname;
-- Expected: select (using organization_id = current_org_id() OR organization_id
-- is null), insert, update -- no delete policy.

-- 8. compliance_requirement_definitions -- trigger.
select tgname, tgtype from pg_trigger
where tgrelid = 'public.compliance_requirement_definitions'::regclass and not tgisinternal;
-- Expected: set_updated_at (before update).

-- 9. Seven seed rows, exact shape.
select requirement_key, display_name, classification, resolution_source, resolution_key,
  expiration_required, warning_days, verification_required, overridable, is_active, organization_id is null as is_system_row
from public.compliance_requirement_definitions
order by requirement_key;
-- Expected: exactly 7 rows, all is_system_row = true, matching the values in
-- 0102's PART 7 insert statement exactly.

-- 10. compliance_items extension -- columns and constraint.
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'compliance_items'
  and column_name in ('requirement_definition_id', 'verified_by', 'verified_at')
order by column_name;

select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.compliance_items'::regclass and conname = 'compliance_items_verification_shape';

-- 11. Existing compliance_items rows are untouched by the extension.
select count(*) as total_items, count(requirement_definition_id) as items_with_definition, count(verified_by) as items_with_verifier
from public.compliance_items;
-- Expected: items_with_definition = 0 and items_with_verifier = 0 (no backfill).

-- 12. carrier_suspensions -- full shape, constraints, indexes, RLS, triggers.
select column_name, data_type, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'carrier_suspensions' order by ordinal_position;
select conname, pg_get_constraintdef(oid) as definition from pg_constraint
where conrelid = 'public.carrier_suspensions'::regclass order by conname;
select indexname, indexdef from pg_indexes where tablename = 'carrier_suspensions' order by indexname;
select policyname, cmd from pg_policies where tablename = 'carrier_suspensions' order by policyname;
select tgname from pg_trigger where tgrelid = 'public.carrier_suspensions'::regclass and not tgisinternal order by tgname;
-- Expected: reason/carrier_id/organization_id not-null CHECKs, the lift-shape
-- CHECK, carrier_suspensions_one_active_per_carrier (unique, partial where
-- lifted_at is null), carrier_suspensions_carrier_lookup, one select-only RLS
-- policy, set_updated_at + carrier_suspensions_relationships_guard triggers.
-- Zero rows expected in the table itself (nothing in 0102 inserts into it).
select count(*) from public.carrier_suspensions;

-- 13. compliance_overrides -- full shape, constraints, indexes, RLS, triggers.
select column_name, data_type, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'compliance_overrides' order by ordinal_position;
select conname, pg_get_constraintdef(oid) as definition from pg_constraint
where conrelid = 'public.compliance_overrides'::regclass order by conname;
select indexname, indexdef from pg_indexes where tablename = 'compliance_overrides' order by indexname;
select policyname, cmd from pg_policies where tablename = 'compliance_overrides' order by policyname;
select tgname from pg_trigger where tgrelid = 'public.compliance_overrides'::regclass and not tgisinternal order by tgname;
-- Expected: reason/carrier_id/organization_id not-null CHECKs, the expiry-shape
-- CHECK, compliance_overrides_carrier_lookup (partial where revoked_at is
-- null), one select-only RLS policy, compliance_overrides_relationships_guard
-- trigger only (no set_updated_at -- this table has no updated_at column).
-- Zero rows expected.
select count(*) from public.compliance_overrides;

-- 14. All five 0102 RPCs -- exact live signatures, security/volatility, grants.
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef as security_definer, p.provolatile,
  (select setting from unnest(p.proconfig) as setting where setting like 'search_path=%') as search_path_setting
from pg_proc p
where p.proname in ('carrier_dispatch_readiness', 'suspend_carrier', 'lift_carrier_suspension', 'create_compliance_override', 'revoke_compliance_override')
order by p.proname;
-- Expected exact args: carrier_dispatch_readiness(p_carrier_id uuid, p_load_id
-- uuid DEFAULT NULL::uuid); suspend_carrier(p_carrier_id uuid, p_reason text);
-- lift_carrier_suspension(p_carrier_id uuid, p_reason text DEFAULT NULL::text);
-- create_compliance_override(p_carrier_id uuid, p_reason text,
-- p_requirement_definition_id uuid DEFAULT NULL::uuid, p_load_id uuid DEFAULT
-- NULL::uuid, p_expires_at timestamp with time zone DEFAULT NULL::timestamp
-- with time zone); revoke_compliance_override(p_override_id uuid, p_reason
-- text DEFAULT NULL::text). All five: security_definer = true.

-- Also confirm no unexpected overload exists for any of the five.
select proname, count(*) from pg_proc
where proname in ('carrier_dispatch_readiness', 'suspend_carrier', 'lift_carrier_suspension', 'create_compliance_override', 'revoke_compliance_override')
group by proname having count(*) > 1;
-- Expected: zero rows (no name has more than one signature live).

select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_name in ('carrier_dispatch_readiness', 'suspend_carrier', 'lift_carrier_suspension', 'create_compliance_override', 'revoke_compliance_override')
order by routine_name, grantee;
-- Expected: grantee = authenticated only, privilege_type = EXECUTE, for every row.

-- 15. The two guard/relationship trigger FUNCTIONS themselves (not just the
-- triggers already checked in 12/13).
select proname, prosecdef from pg_proc
where proname in ('guard_carrier_suspension_relationships', 'guard_compliance_override_relationships')
order by proname;
-- Expected: 2 rows, prosecdef = false for both (plain plpgsql, not security
-- definer -- matches guard_carrier_w9_relationships()'s own precedent).

-- 16. No dispatch enforcement trigger exists -- 0102 must never have added one.
select tgname, tgenabled from pg_trigger where tgrelid = 'public.dispatches'::regclass and not tgisinternal order by tgname;
-- Expected: whatever existed before 0102 (e.g. guard_dispatch_org) and
-- nothing else -- no new trigger referencing readiness/compliance/suspension.

-- 17. carriers.is_active -- untouched, structural spot-check (row count and
-- distribution should be identical to whatever it was before 0102 was ever
-- applied -- compare against your own records if you have a pre-0102 count).
select is_active, count(*) from public.carriers group by 1;
