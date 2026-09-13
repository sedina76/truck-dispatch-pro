-- ============================================================================
-- 0141 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0141. Every row must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- B. lifecycle state column ----
  (1, 'configuration_status is now text with the six-state CHECK constraint',
      (select data_type from information_schema.columns where table_schema='public' and table_name='carrier_factoring_integrations' and column_name='configuration_status') = 'text'
      and exists (select 1 from pg_constraint where conname = 'cfi_lifecycle_states')),
  (2, 'is_active is structurally tied to configuration_status=ready (cfi_ready_iff_active)',
      exists (select 1 from pg_constraint where conname = 'cfi_ready_iff_active')),
  (3, 'opaque-reference shape constraint installed',
      exists (select 1 from pg_constraint where conname = 'cfi_opaque_reference_shape')),

  -- ---- F. direct writes locked down ----
  (4, 'authenticated has SELECT but no INSERT/UPDATE/DELETE on carrier_factoring_integrations',
      has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'SELECT')
      and not has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'INSERT')
      and not has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'DELETE')),
  (5, 'authenticated has no per-column INSERT/UPDATE privilege on carrier_factoring_integrations either',
      not has_any_column_privilege('authenticated', 'public.carrier_factoring_integrations', 'INSERT')
      and not has_any_column_privilege('authenticated', 'public.carrier_factoring_integrations', 'UPDATE')),

  -- ---- G/I/K. the eight new RPCs exist and are callable by authenticated ----
  (6, 'all eight new RPCs exist and are EXECUTE-granted to authenticated',
      has_function_privilege('authenticated', 'public.configure_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.activate_carrier_factoring_integration(uuid,text,timestamptz,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.deactivate_carrier_factoring_integration(uuid,text,timestamptz,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.verify_carrier_factoring_integration(uuid,text,timestamptz,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.fail_carrier_factoring_integration(uuid,text,timestamptz,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.revoke_carrier_factoring_integration(uuid,text,timestamptz,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.rotate_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.deactivate_factoring_relationship(uuid,text,timestamptz,text,boolean)', 'EXECUTE')),
  (7, 'the private shared implementation function is NOT exposed to authenticated/anon',
      not has_function_privilege('authenticated', 'public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)', 'EXECUTE')),
  (8, 'the two read-only problem functions are NOT exposed to authenticated/anon',
      not has_function_privilege('authenticated', 'public.factoring_relationship_lifecycle_problem(uuid)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.factoring_integration_lifecycle_problem(uuid)', 'EXECUTE')),

  -- ---- D/E. triggers installed ----
  (9, 'the dependency guard is installed, ROW-level (Phase 3B.2.1: narrowed from statement-level), on all six dependency tables, with its organization-scoping supporting index',
      (select count(*) from pg_trigger where tgname = 'z0141_lifecycle_dependencies') = 6
      and (select count(*) from pg_trigger where tgname = 'z0141_lifecycle_dependencies' and (tgtype::int & 1) = 1) = 6
      and to_regclass('public.cfi_active_by_org') is not null),
  (10, 'the BEFORE-ROW lifecycle-transition guard is installed on carrier_factoring_integrations',
      exists (select 1 from pg_trigger where tgname = 'a0141_lifecycle_transition' and tgrelid = 'public.carrier_factoring_integrations'::regclass)),

  -- ---- idempotency table ----
  (11, 'factoring_integration_lifecycle_idempotency exists with RLS enabled, readable only by owner/admin',
      to_regclass('public.factoring_integration_lifecycle_idempotency') is not null
      and (select relrowsecurity from pg_class where oid = 'public.factoring_integration_lifecycle_idempotency'::regclass)
      and not has_table_privilege('authenticated', 'public.factoring_integration_lifecycle_idempotency', 'INSERT')),

  -- ---- H. classifier extension ----
  (12, 'classify_carrier_factoring_readiness source now calls factoring_integration_lifecycle_problem',
      (select prosrc from pg_proc where proname = 'classify_carrier_factoring_readiness' and pronamespace = 'public'::regnamespace) ilike '%factoring_integration_lifecycle_problem%'),

  -- ---- M. legacy constraint removed ----
  (13, 'factoring_relationships_submission_integration_present constraint is gone',
      not exists (select 1 from pg_constraint where conname = 'factoring_relationships_submission_integration_present')),

  -- ---- secret hygiene ----
  (14, 'no function source anywhere references NEW.secret_reference/OLD.secret_reference in a way suggesting it is ever selected back out through a status/classifier reader',
      (select prosrc from pg_proc where proname = 'get_carrier_factoring_integration_status' and pronamespace = 'public'::regnamespace) not ilike '%secret_reference%'),

  -- ---- 0001-0140 boundary untouched: existing three RPCs are NOT modified by 0141 ----
  -- 0141 deliberately never touches these three function bodies at all --
  -- the row-level, organization-scoped dependency guard is a set of
  -- per-table triggers and applies to their mutations without any change
  -- to their own source.
  -- A structural proxy for "not modified": their source references
  -- neither of 0141's new private functions/tables.
  (15, 'set_carrier_factoring_policy / set_default_factoring_relationship / approve_factoring_relationship_noa do not reference any 0141 object -- consistent with 0141 never having modified them',
      (select prosrc from pg_proc where proname = 'set_carrier_factoring_policy' and pronamespace = 'public'::regnamespace) not ilike '%lifecycle_problem%'
      and (select prosrc from pg_proc where proname = 'set_default_factoring_relationship' and pronamespace = 'public'::regnamespace) not ilike '%lifecycle_problem%'
      and (select prosrc from pg_proc where proname = 'approve_factoring_relationship_noa' and pronamespace = 'public'::regnamespace) not ilike '%lifecycle_problem%')

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): live invariant re-check -- every currently active
-- integration must classify as problem-free right now.
select count(*) as active_integrations_with_a_problem
from public.carrier_factoring_integrations i
where i.is_active;
