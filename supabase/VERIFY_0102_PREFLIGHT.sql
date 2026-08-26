-- =============================================================================
-- VERIFY_0102_PREFLIGHT.sql
-- Phase 2P.2 -- read-only preflight for
-- supabase/migrations/0102_carrier_compliance_foundation.sql.
-- Run this BEFORE applying 0102. Every query here is a plain SELECT --
-- nothing here mutates anything.
-- =============================================================================

-- 1. Existing compliance enums have exactly the values 0102 depends on.
select enumlabel from pg_enum where enumtypid = 'public.compliance_status'::regtype order by enumsortorder;
-- Expected: valid, expiring_soon, expired, missing, waived.

select enumlabel from pg_enum where enumtypid = 'public.compliance_item_type'::regtype order by enumsortorder;
-- Expected: the 0001 baseline + 0014 additions (cdl_expiry, medical_card_expiry,
-- insurance_expiry, registration_expiry, authority_expiry, annual_inspection,
-- drug_test, ifta_renewal, other, dot_inspection, twic_expiry, hazmat_expiry,
-- passport_expiry, work_authorization_expiry, background_check). 0102 does
-- NOT add to this enum -- confirms that decision is still valid.

select enumlabel from pg_enum where enumtypid = 'public.entity_type'::regtype order by enumsortorder;
-- Expected: includes 'carrier'.

select enumlabel from pg_enum where enumtypid = 'public.insurance_policy_type'::regtype order by enumsortorder;
-- Expected: general_liability, cargo, physical_damage, workers_compensation.
-- No auto_liability value -- confirms 0102 must not claim one exists.

select enumlabel from pg_enum where enumtypid = 'public.carrier_agreement_signing_status'::regtype order by enumsortorder;
-- Expected: assigned, in_progress, completed, voided.

-- 2. compliance_items current columns (0102 adds three nullable columns; none
-- of these should already exist).
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'compliance_items'
order by ordinal_position;

-- 3. organizations current columns (0102 adds one enum column with a safe
-- default; confirm the gps_automation_mode precedent this migration mirrors
-- is present, and that no compliance_enforcement_mode column already exists).
select column_name, data_type, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'organizations'
  and column_name in ('gps_automation_mode', 'compliance_enforcement_mode', 'pickup_detention_free_minutes');

-- 4. carriers current columns (0102 does not alter this table at all --
-- confirms no is_active mutation risk).
select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'carriers' and column_name in ('id', 'is_active', 'mc_number', 'dot_number');

-- 5. carrier_w9s status model (0102's W-9 adapter depends on exactly this shape).
select enumlabel from pg_enum where enumtypid = 'public.carrier_w9_status'::regtype order by enumsortorder;
-- Expected: draft, completed, superseded, voided, failed.

-- 6. Agreement relationship chain 0102's agreement adapter depends on.
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'carrier_onboarding_applications' and column_name = 'converted_carrier_id';
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'carrier_agreement_signings' and column_name in ('application_id', 'agreement_template_id', 'status');
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'carrier_agreement_templates' and column_name in ('is_required_for_onboarding', 'status', 'template_key');

-- 7. insurance_policies shape 0102's insurance adapter depends on.
select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'insurance_policies'
order by ordinal_position;

-- 8. Existing helper functions 0102's new functions call.
select proname, pg_get_function_identity_arguments(oid) as args
from pg_proc
where proname in ('current_org_id', 'current_role', 'has_role', 'log_activity', 'set_updated_at')
order by proname, args;
-- Expected: log_activity shows TWO overloads -- the original 4-arg and the
-- 0044/0046 5-arg (..., p_organization_id uuid default null) overload 0102 uses.

-- 9. Dispatch path is untouched today -- confirms 0102 introduces no trigger
-- on this table (it shouldn't; this is a pre-check, re-run post-apply to
-- confirm nothing changed).
select tgname, tgenabled from pg_trigger where tgrelid = 'public.dispatches'::regclass and not tgisinternal order by tgname;

-- 10. No conflicting 0102 objects already exist.
select 'compliance_requirement_definitions table' as check_name, to_regclass('public.compliance_requirement_definitions') is not null as exists_already
union all select 'carrier_suspensions table', to_regclass('public.carrier_suspensions') is not null
union all select 'compliance_overrides table', to_regclass('public.compliance_overrides') is not null
union all select 'compliance_enforcement_mode enum', to_regtype('public.compliance_enforcement_mode') is not null
union all select 'carrier_dispatch_readiness function', (select count(*) > 0 from pg_proc where proname = 'carrier_dispatch_readiness')
union all select 'suspend_carrier function', (select count(*) > 0 from pg_proc where proname = 'suspend_carrier')
union all select 'lift_carrier_suspension function', (select count(*) > 0 from pg_proc where proname = 'lift_carrier_suspension')
union all select 'create_compliance_override function', (select count(*) > 0 from pg_proc where proname = 'create_compliance_override')
union all select 'revoke_compliance_override function', (select count(*) > 0 from pg_proc where proname = 'revoke_compliance_override');
-- Expected: every row's exists_already = false.

-- 11. Baseline row counts, purely informational -- confirms 0102's seed step
-- is additive against real, non-empty production data (existing compliance
-- items/carriers are never touched or required to change).
select (select count(*) from public.carriers) as carrier_count,
       (select count(*) from public.compliance_items) as compliance_item_count,
       (select count(*) from public.organizations) as organization_count,
       (select count(*) from public.insurance_policies) as insurance_policy_count;
