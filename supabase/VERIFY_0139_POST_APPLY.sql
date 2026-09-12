-- ============================================================================
-- 0139 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0139. Every row must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- A. privilege remediation ----
  (1, 'unresolved_carrier_records: authenticated has neither INSERT nor DELETE (UPDATE still intentionally granted)',
      not has_table_privilege('authenticated','public.unresolved_carrier_records','INSERT')
      and not has_table_privilege('authenticated','public.unresolved_carrier_records','DELETE')
      and has_table_privilege('authenticated','public.unresolved_carrier_records','UPDATE')),
  (2, 'financial_idempotency_keys: authenticated has no INSERT/UPDATE/DELETE',
      not has_table_privilege('authenticated','public.financial_idempotency_keys','INSERT')
      and not has_table_privilege('authenticated','public.financial_idempotency_keys','UPDATE')
      and not has_table_privilege('authenticated','public.financial_idempotency_keys','DELETE')),
  (3, 'carrier_backfill_0133_provenance: authenticated has no INSERT/UPDATE/DELETE',
      not has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','INSERT')
      and not has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','UPDATE')
      and not has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','DELETE')),
  (4, 'carrier_remittance_profiles/carrier_brokers/carrier_customers: authenticated has no DELETE',
      not has_table_privilege('authenticated','public.carrier_remittance_profiles','DELETE')
      and not has_table_privilege('authenticated','public.carrier_brokers','DELETE')
      and not has_table_privilege('authenticated','public.carrier_customers','DELETE')),
  (5, 'carriers: authenticated has no TABLE-LEVEL UPDATE (column-scoped only, factoring_mode excluded)',
      not has_table_privilege('authenticated','public.carriers','UPDATE')
      and not has_column_privilege('authenticated','public.carriers','factoring_mode','UPDATE')
      and has_column_privilege('authenticated','public.carriers','is_active','UPDATE')),

  -- ---- B. cutover safety ----
  (6, 'factoring_relationships_new_writes_need_carrier NOT VALID constraint present',
      exists (select 1 from pg_constraint where conname='factoring_relationships_new_writes_need_carrier' and not convalidated is true)
      or exists (select 1 from pg_constraint where conname='factoring_relationships_new_writes_need_carrier')),

  -- ---- C. carrier-party direct-billing exception ----
  (7, 'carrier_brokers/carrier_customers gained the 3 direct-billing-exception columns',
      (select count(*) from information_schema.columns where table_schema='public' and table_name='carrier_brokers'
        and column_name in ('factoring_ineligible_direct_billing_approved','factoring_ineligible_direct_billing_approved_by','factoring_ineligible_direct_billing_approved_at')) = 3
      and
      (select count(*) from information_schema.columns where table_schema='public' and table_name='carrier_customers'
        and column_name in ('factoring_ineligible_direct_billing_approved','factoring_ineligible_direct_billing_approved_by','factoring_ineligible_direct_billing_approved_at')) = 3),
  (8, 'guard_carrier_party_direct_billing_exception fires on both carrier_brokers and carrier_customers',
      exists (select 1 from pg_trigger where tgname='carrier_brokers_guard_direct_billing_exception' and tgrelid='public.carrier_brokers'::regclass and not tgisinternal)
      and exists (select 1 from pg_trigger where tgname='carrier_customers_guard_direct_billing_exception' and tgrelid='public.carrier_customers'::regclass and not tgisinternal)),
  (9, 'no existing carrier_brokers/carrier_customers row was silently marked as an approved exception',
      (select count(*) from public.carrier_brokers where factoring_ineligible_direct_billing_approved) = 0
      and (select count(*) from public.carrier_customers where factoring_ineligible_direct_billing_approved) = 0),

  -- ---- D. carrier_factoring_integrations ----
  (10, 'carrier_factoring_integrations exists with RLS enabled',
      to_regclass('public.carrier_factoring_integrations') is not null
      and (select relrowsecurity from pg_class where oid = 'public.carrier_factoring_integrations'::regclass)),
  (11, 'exactly one owner/admin-only SELECT policy on carrier_factoring_integrations',
      (select count(*) from pg_policies where schemaname='public' and tablename='carrier_factoring_integrations' and cmd='SELECT') = 1
      and exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_factoring_integrations' and policyname='carrier_factoring_integrations_select' and cmd='SELECT')),
  (12, 'cfi_one_active_per_relationship unique partial index present',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='carrier_factoring_integrations' and indexname='cfi_one_active_per_relationship')),
  (13, 'get_carrier_factoring_integration_status(uuid) present and executable by authenticated',
      to_regprocedure('public.get_carrier_factoring_integration_status(uuid)') is not null
      and has_function_privilege('authenticated', 'public.get_carrier_factoring_integration_status(uuid)', 'EXECUTE')),

  -- ---- E. set_carrier_factoring_policy ----
  (14, 'set_carrier_factoring_policy(...) present and executable by authenticated',
      to_regprocedure('public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)') is not null
      and has_function_privilege('authenticated', 'public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)', 'EXECUTE')),
  (15, 'factoring_policy_idempotency exists, RLS enabled, authenticated has read-only access',
      to_regclass('public.factoring_policy_idempotency') is not null
      and (select relrowsecurity from pg_class where oid = 'public.factoring_policy_idempotency'::regclass)
      and has_table_privilege('authenticated','public.factoring_policy_idempotency','SELECT')
      and not has_table_privilege('authenticated','public.factoring_policy_idempotency','INSERT')
      and not has_table_privilege('authenticated','public.factoring_policy_idempotency','UPDATE')
      and not has_table_privilege('authenticated','public.factoring_policy_idempotency','DELETE')),

  -- ---- F/G. classifier + NOA approval replaced ----
  (16, 'classify_carrier_factoring_readiness(...) still present after replace',
      to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null),
  (17, 'approve_factoring_relationship_noa(...) still present after replace',
      to_regprocedure('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)') is not null),
  (18, 'factoring_relationships gained the 2 NOA snapshot columns',
      (select count(*) from information_schema.columns where table_schema='public' and table_name='factoring_relationships'
        and column_name in ('noa_document_snapshot_file_name','noa_document_snapshot_file_path')) = 2),
  (19, 'no existing factoring_relationships row was retroactively snapshotted (only future approvals populate it)',
      (select count(*) from public.factoring_relationships where noa_document_snapshot_file_path is not null and noa_approved_at < now() - interval '1 minute') = 0
      or not exists (select 1 from public.factoring_relationships where noa_approved_at is not null)),

  -- ---- untouched: 0001-0135 and pre-0139 Phase 3B.1 objects ----
  (20, '0071/0072 factored_invoices / factoring_events untouched (still present)',
      to_regclass('public.factored_invoices') is not null and to_regclass('public.factoring_events') is not null),
  (21, '0138 carrier-scoped default-per-carrier index untouched',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_carrier'))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): every table this migration's privilege remediation
-- touched, with its final authenticated grant set -- eyeball this against
-- the privilege matrix in the Phase 3B.1.1 report.
select table_name, string_agg(privilege_type, ', ' order by privilege_type) as authenticated_grants
from information_schema.role_table_grants
where grantee = 'authenticated' and table_schema = 'public'
  and table_name in (
    'unresolved_carrier_records', 'financial_idempotency_keys', 'carrier_backfill_0133_provenance',
    'carrier_remittance_profiles', 'carrier_brokers', 'carrier_customers',
    'carrier_factoring_integrations', 'factoring_policy_idempotency', 'carriers'
  )
group by table_name
order by table_name;
