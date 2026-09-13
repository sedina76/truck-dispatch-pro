-- ============================================================================
-- 0142 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0142. Requires 0141 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0141 landmark: factoring_integration_lifecycle_problem(uuid) exists',
      to_regprocedure('public.factoring_integration_lifecycle_problem(uuid)') is not null),
  (2, 'classify_carrier_factoring_readiness(uuid,uuid,uuid) exists (0139/0141)',
      to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null),
  (3, 'carriers.invoice_code exists (0130) -- the carrier-scoped numbering prefix this migration relies on',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='invoice_code')),
  (4, 'platform_settings.dispatch_service_terms_days exists (0130)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='dispatch_service_terms_days')),

  -- ---- objects 0142 introduces do not exist yet ----
  (5, 'carrier_invoices does not exist yet',
      to_regclass('public.carrier_invoices') is null),
  (6, 'carrier_invoice_issuance_snapshots does not exist yet',
      to_regclass('public.carrier_invoice_issuance_snapshots') is null),
  (7, 'carrier_invoice_number_counters does not exist yet',
      to_regclass('public.carrier_invoice_number_counters') is null),
  (8, 'invoice_document_type enum does not exist yet',
      not exists (select 1 from pg_type where typname = 'invoice_document_type')),
  (9, 'legacy_invoice_carrier_migration_review does not exist yet',
      to_regclass('public.legacy_invoice_carrier_migration_review') is null),

  -- ---- legacy invoice architecture is exactly what 0142's header assumes ----
  (10, 'public.invoices has NO carrier_id column (confirms the single-carrier-era shape this migration deliberately does not touch)',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='invoices' and column_name='carrier_id')),
  (11, 'public.factored_invoices FKs to public.invoices(id) (confirms legacy factoring submission is invoices-table-shaped, independent of the new carrier_invoices model)',
      exists (
        select 1 from pg_constraint
        where conrelid = 'public.factored_invoices'::regclass
          and confrelid = 'public.invoices'::regclass
          and contype = 'f'
      ))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): how many existing legacy invoices exist and in
-- what status -- purely informational, mirrors VERIFY_0141_PREFLIGHT's own
-- "preview of what the migration will see" convention. 0142 never reads or
-- writes any of these rows itself.
select
  (select count(*) from public.invoices) as total_legacy_invoices,
  (select count(*) from public.invoices where status = 'void') as legacy_voided,
  (select count(*) from public.invoices where status = 'paid') as legacy_paid,
  (select count(*) from public.invoices where load_id is null) as legacy_no_load,
  (select count(*) from public.invoices where broker_id is not null and customer_id is not null) as legacy_conflicting_recipient,
  (select count(*) from public.invoices where broker_id is null and customer_id is null) as legacy_missing_recipient;
