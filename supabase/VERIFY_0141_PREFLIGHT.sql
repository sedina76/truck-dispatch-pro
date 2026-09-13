-- ============================================================================
-- 0141 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0141. Requires 0140 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0140 landmark: submit_invoice_to_factor(uuid,uuid) returns jsonb',
      to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)') is not null
      and (select data_type from information_schema.routines where routine_schema='public' and routine_name='submit_invoice_to_factor' limit 1) = 'jsonb'),
  (2, 'carrier_factoring_integrations present (0139)',
      to_regclass('public.carrier_factoring_integrations') is not null),
  (3, 'configuration_status is still the pre-0141 enum type (0141 not yet applied)',
      (select data_type from information_schema.columns where table_schema='public' and table_name='carrier_factoring_integrations' and column_name='configuration_status') = 'USER-DEFINED'),

  -- ---- objects 0141 introduces do not exist yet ----
  (4, 'the six new RPCs do not exist yet',
      to_regprocedure('public.configure_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)') is null
      and to_regprocedure('public.activate_carrier_factoring_integration(uuid,text,timestamptz,text)') is null
      and to_regprocedure('public.deactivate_factoring_relationship(uuid,text,timestamptz,text,boolean)') is null),
  (5, 'factoring_integration_lifecycle_idempotency does not exist yet',
      to_regclass('public.factoring_integration_lifecycle_idempotency') is null),
  (6, 'authenticated currently still has table-level INSERT/UPDATE on carrier_factoring_integrations (the gap 0141 closes)',
      has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'INSERT')
      and has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'UPDATE')),
  (7, 'the row-level dependency guard trigger does not exist yet',
      not exists (select 1 from pg_trigger where tgname = 'z0141_lifecycle_dependencies'))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): how many existing carrier_factoring_integrations
-- rows are currently active, and how many are of each legacy
-- configuration_status -- purely informational. 0141's own preflight
-- (inside the migration transaction) performs the authoritative,
-- refuse-on-unsafe-data check; this is a preview of what it will see.
select
  (select count(*) from public.carrier_factoring_integrations) as total_integrations,
  (select count(*) from public.carrier_factoring_integrations where is_active) as currently_active_integrations,
  (select count(*) from public.carrier_factoring_integrations where configuration_status::text <> 'draft') as non_draft_legacy_rows;

-- Context (not a gate): Phase 3B.2.1 Section D -- how many EXISTING rows
-- carry a finite effective_to and would be affected by 0141's temporary
-- "activation requires open-ended validity" limitation (see the
-- migration's own header comment for the exact required wording). This is
-- purely informational -- 0141 never modifies effective_to on any row; it
-- only refuses to ACTIVATE a relationship/integration that has one.
select
  (select count(*) from public.factoring_relationships where effective_to is not null) as relationships_with_finite_expiry,
  (select count(*) from public.factoring_relationships where effective_to is not null and submission_method = 'api'::public.factoring_submission_method) as api_relationships_with_finite_expiry,
  (select count(*) from public.carrier_factoring_integrations where effective_to is not null) as legacy_integrations_with_finite_expiry;
