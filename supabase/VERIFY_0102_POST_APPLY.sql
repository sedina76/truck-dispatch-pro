-- =============================================================================
-- VERIFY_0102_POST_APPLY.sql
-- Phase 2P.2 -- read-only post-apply verification for
-- supabase/migrations/0102_carrier_compliance_foundation.sql.
-- Run this immediately after applying 0102. Every query here is a plain
-- SELECT -- nothing here mutates anything.
-- =============================================================================

-- 1. New objects exist.
select
  to_regclass('public.compliance_requirement_definitions') is not null as definitions_table,
  to_regclass('public.carrier_suspensions') is not null as suspensions_table,
  to_regclass('public.compliance_overrides') is not null as overrides_table,
  to_regtype('public.compliance_enforcement_mode') is not null as enforcement_mode_enum,
  (select count(*) > 0 from pg_proc where proname = 'carrier_dispatch_readiness') as readiness_function,
  (select count(*) > 0 from pg_proc where proname = 'suspend_carrier') as suspend_function,
  (select count(*) > 0 from pg_proc where proname = 'lift_carrier_suspension') as lift_function,
  (select count(*) > 0 from pg_proc where proname = 'create_compliance_override') as create_override_function,
  (select count(*) > 0 from pg_proc where proname = 'revoke_compliance_override') as revoke_override_function;
-- Expected: every column true.

-- 2. compliance_items extension.
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'compliance_items'
  and column_name in ('requirement_definition_id', 'verified_by', 'verified_at')
order by column_name;
-- Expected: 3 rows, all is_nullable = YES.

select conname from pg_constraint where conrelid = 'public.compliance_items'::regclass and conname = 'compliance_items_verification_shape';
-- Expected: 1 row.

-- 3. Existing compliance_items rows are untouched (both new columns NULL
-- for every pre-existing row -- run this and confirm the count matches the
-- preflight's own compliance_item_count with zero having a non-null value
-- in either new column).
select count(*) as total_items, count(requirement_definition_id) as items_with_definition, count(verified_by) as items_with_verifier
from public.compliance_items;
-- Expected: items_with_definition = 0 and items_with_verifier = 0 immediately
-- post-apply (no backfill happened).

-- 4. organizations.compliance_enforcement_mode: every organization,
-- existing and new, defaults to audit_only.
select compliance_enforcement_mode, count(*) from public.organizations group by 1;
-- Expected: exactly one row, mode = 'audit_only', count = the same total
-- organization_count the preflight reported.

-- 5. Seed definitions.
select requirement_key, classification, resolution_source, resolution_key, expiration_required, warning_days, verification_required, overridable, is_active
from public.compliance_requirement_definitions
where organization_id is null
order by requirement_key;
-- Expected: exactly 7 rows -- w9, carrier_agreement, cargo_insurance,
-- general_liability_insurance, workers_compensation_insurance,
-- physical_damage_insurance, operating_identifier.

-- 6. Function signatures/security properties.
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef as security_definer, p.provolatile,
  (select setting from unnest(p.proconfig) as setting where setting like 'search_path=%') as search_path_setting
from pg_proc p
where p.proname in ('carrier_dispatch_readiness', 'suspend_carrier', 'lift_carrier_suspension', 'create_compliance_override', 'revoke_compliance_override', 'guard_carrier_suspension_relationships', 'guard_compliance_override_relationships')
order by p.proname;
-- Expected: carrier_dispatch_readiness -- security_definer=true, provolatile='s' (stable),
-- search_path_setting mentions 'public'. The four RPC functions --
-- security_definer=true. The two guard trigger functions -- plain
-- language plpgsql, no security definer needed (they run under whatever
-- role performs the INSERT, matching guard_carrier_w9_relationships()'s
-- own precedent of NOT being security definer).

-- 7. Grants -- authenticated only, never anon/public.
select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_name in ('carrier_dispatch_readiness', 'suspend_carrier', 'lift_carrier_suspension', 'create_compliance_override', 'revoke_compliance_override')
order by routine_name, grantee;
-- Expected: grantee = authenticated only for every row, privilege_type = EXECUTE.

-- 8. RLS enabled + policies present on all three new tables.
select relname, relrowsecurity
from pg_class
where relname in ('compliance_requirement_definitions', 'carrier_suspensions', 'compliance_overrides')
order by relname;
-- Expected: relrowsecurity = true for all three.

select tablename, policyname, cmd
from pg_policies
where tablename in ('compliance_requirement_definitions', 'carrier_suspensions', 'compliance_overrides')
order by tablename, policyname;
-- Expected: compliance_requirement_definitions -- select/insert/update (no delete);
-- carrier_suspensions -- select only; compliance_overrides -- select only.

-- 9. Indexes present.
select indexname, tablename from pg_indexes
where tablename in ('compliance_requirement_definitions', 'carrier_suspensions', 'compliance_overrides')
order by tablename, indexname;
-- Expected: the two partial unique indexes + lookup index on
-- compliance_requirement_definitions; the one-active-per-carrier unique
-- index + lookup index on carrier_suspensions; the carrier lookup index
-- on compliance_overrides (plus each table's own primary key index).

-- 10. No dispatch enforcement trigger exists -- 0102 adds none.
select tgname, tgenabled from pg_trigger where tgrelid = 'public.dispatches'::regclass and not tgisinternal order by tgname;
-- Expected: byte-for-byte identical to the preflight's own output for this
-- same query -- guard_dispatch_org and whatever else existed before, and
-- nothing new.

-- 11. Relationship guard triggers present on the two new tables that need them.
select tgname, tgrelid::regclass, tgtype from pg_trigger
where tgname in ('carrier_suspensions_relationships_guard', 'compliance_overrides_relationships_guard')
order by tgname;
-- Expected: 2 rows, both BEFORE INSERT only (not UPDATE -- see migration comment).

-- 12. carriers.is_active completely untouched -- structural proof, not just
-- absence of a migration statement: compare row counts/values against the
-- preflight snapshot for a few real rows if you want an extra manual check;
-- structurally, 0102 contains zero ALTER/UPDATE statement referencing
-- public.carriers at all (grep the migration file itself to confirm).
