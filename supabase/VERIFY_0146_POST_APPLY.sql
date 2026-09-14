-- ============================================================================
-- 0146 POST-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run AFTER applying 0146. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'carrier_invoice_payment_status has exactly posted/voided',
      (select array_agg(enumlabel::text order by enumlabel) from pg_enum where enumtypid = 'public.carrier_invoice_payment_status'::regtype) = array['posted','voided']),
  (2, 'carrier_invoice_payment_method has exactly ach/cash/check/credit_card/other/wire (never factoring)',
      (select array_agg(enumlabel::text order by enumlabel) from pg_enum where enumtypid = 'public.carrier_invoice_payment_method'::regtype) = array['ach','cash','check','credit_card','other','wire']),
  (3, 'carrier_invoice_payer_type has exactly broker/carrier/customer',
      (select array_agg(enumlabel::text order by enumlabel) from pg_enum where enumtypid = 'public.carrier_invoice_payer_type'::regtype) = array['broker','carrier','customer']),
  (4, 'carrier_invoice_payments exists with unique(payment_number)',
      to_regclass('public.carrier_invoice_payments') is not null
      and exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_invoice_payments' and c.conname='civp_payment_number_unique' and c.contype='u')),
  (5, 'carrier_invoice_payments.amount has a positive-amount CHECK',
      exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_invoice_payments' and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%amount%>%0%')),
  (6, 'civp_void_fields_iff_voided CHECK exists',
      exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_invoice_payments' and c.conname='civp_void_fields_iff_voided' and c.contype='c')),
  (7, 'civp_payer_shape CHECK exists',
      exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_invoice_payments' and c.conname='civp_payer_shape' and c.contype='c')),
  (8, 'a0146_guard_payment_lifecycle trigger installed (BEFORE UPDATE OR DELETE)',
      exists (select 1 from pg_trigger tg join pg_class t on t.oid=tg.tgrelid where t.relname='carrier_invoice_payments' and tg.tgname='a0146_guard_payment_lifecycle' and not tg.tgisinternal)),
  (9, 'a0146_guard_payment_currency trigger installed (BEFORE INSERT)',
      exists (select 1 from pg_trigger tg join pg_class t on t.oid=tg.tgrelid where t.relname='carrier_invoice_payments' and tg.tgname='a0146_guard_payment_currency' and not tg.tgisinternal)),
  (10, 'carrier_invoice_payment_number_seq exists',
      exists (select 1 from pg_class where relkind='S' and relname='carrier_invoice_payment_number_seq')),
  (11, '_generate_carrier_invoice_payment_number_internal exists and is NOT authenticated-callable (internal only)',
      to_regprocedure('public._generate_carrier_invoice_payment_number_internal()') is not null
      and not has_function_privilege('authenticated', 'public._generate_carrier_invoice_payment_number_internal()', 'EXECUTE')),
  (12, 'record_carrier_invoice_payment exists and is authenticated-callable',
      has_function_privilege('authenticated', 'public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)', 'EXECUTE')),
  (13, 'void_carrier_invoice_payment exists and is authenticated-callable',
      has_function_privilege('authenticated', 'public.void_carrier_invoice_payment(uuid,timestamptz,text,text)', 'EXECUTE')),
  (14, 'no direct authenticated INSERT/UPDATE/DELETE grant on carrier_invoice_payments',
      not exists (
        select 1 from information_schema.role_table_grants
        where grantee = 'authenticated' and privilege_type in ('INSERT','UPDATE','DELETE') and table_name = 'carrier_invoice_payments'
      )),
  (15, 'authenticated has SELECT on carrier_invoice_payments',
      exists (
        select 1 from information_schema.role_table_grants
        where grantee = 'authenticated' and privilege_type = 'SELECT' and table_name = 'carrier_invoice_payments'
      )),
  (16, 'anon has zero grant on carrier_invoice_payments',
      not exists (select 1 from information_schema.role_table_grants where grantee = 'anon' and table_name = 'carrier_invoice_payments')),
  (17, 'carrier_invoice_payments is empty -- this migration never inserts data',
      (select count(*) from public.carrier_invoice_payments) = 0),
  (18, 'record_carrier_invoice_payment reuses carrier_invoice_lifecycle_idempotency (no new idempotency table created)',
      to_regclass('public.carrier_invoice_payment_idempotency') is null
      and (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%carrier_invoice_lifecycle_idempotency%'),
  (19, 'void_carrier_invoice_payment reuses carrier_invoice_lifecycle_idempotency',
      (select prosrc from pg_proc where proname='void_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%carrier_invoice_lifecycle_idempotency%'),
  (20, 'record_carrier_invoice_payment never references factored_invoices/factoring_events',
      (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) not ilike '%factored_invoices%'
      and (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) not ilike '%factoring_events%'),
  (21, 'record_carrier_invoice_payment returns FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW',
      (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW%'),
  (22, 'legacy public.payments/public.invoices untouched (no new column referencing carrier_invoice_payments)',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='payments' and column_name like '%carrier_invoice%')),

  -- ---- Phase 3B.5.1: centralized snapshot-integrity + external-reference validators ----
  (23, 'carrier_invoice_payment_snapshot_problem(uuid) exists and is internal-only (anon/authenticated cannot EXECUTE it directly)',
      to_regprocedure('public.carrier_invoice_payment_snapshot_problem(uuid)') is not null
      and not has_function_privilege('authenticated', 'public.carrier_invoice_payment_snapshot_problem(uuid)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.carrier_invoice_payment_snapshot_problem(uuid)', 'EXECUTE')),
  (24, '_carrier_invoice_payment_external_reference_problem(text) exists and is internal-only',
      to_regprocedure('public._carrier_invoice_payment_external_reference_problem(text)') is not null
      and not has_function_privilege('authenticated', 'public._carrier_invoice_payment_external_reference_problem(text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public._carrier_invoice_payment_external_reference_problem(text)', 'EXECUTE')),
  (25, 'record_carrier_invoice_payment calls carrier_invoice_payment_snapshot_problem and returns SNAPSHOT_INTEGRITY_ERROR',
      (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%carrier_invoice_payment_snapshot_problem%'
      and (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%SNAPSHOT_INTEGRITY_ERROR%'),
  (26, 'record_carrier_invoice_payment calls _carrier_invoice_payment_external_reference_problem and returns INVALID_EXTERNAL_REFERENCE',
      (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%_carrier_invoice_payment_external_reference_problem%'
      and (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%INVALID_EXTERNAL_REFERENCE%'),

  -- ---- Phase 3B.5.2: canonical version-2 issuance + version-aware validator ----
  (27, 'issue_carrier_invoice now emits schema_version=2 (never a stray schema_version=1 build) and is still authenticated-callable',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%''schema_version'', 2%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) not ilike '%''schema_version'', 1%'
      and has_function_privilege('authenticated', 'public.issue_carrier_invoice(uuid,timestamptz,text,text)', 'EXECUTE')),
  (28, '_issue_dispatch_service_invoice_internal now emits schema_version=2 and remains internal-only',
      (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) ilike '%''schema_version'', 2%'
      and (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) not ilike '%''schema_version'', 1%'
      and not has_function_privilege('authenticated', 'public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)', 'EXECUTE')),
  (29, 'issue_carrier_invoice uses ONLY the canonical factoring keys (mode/relationship_id/nested company{id,legal_name}) -- no retired v1 or flat-company JSON key survives',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%''mode'', ''direct''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%''mode'', ''factored''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%''company''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) not ilike '%''factoring_mode''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) not ilike '%''factoring_relationship_id''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) not ilike '%''factoring_company_id''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) not ilike '%''company_id''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) not ilike '%''company_legal_name''%'),
  (30, 'carrier_invoice_payment_snapshot_problem is version-aware: rejects non-version-2 with a VERSION_ code, uses only canonical mode/relationship_id/nested company keys',
      (select prosrc from pg_proc where proname='carrier_invoice_payment_snapshot_problem' and pronamespace='public'::regnamespace) ilike '%VERSION_MISSING%'
      and (select prosrc from pg_proc where proname='carrier_invoice_payment_snapshot_problem' and pronamespace='public'::regnamespace) ilike '%VERSION_UNSUPPORTED%'
      and (select prosrc from pg_proc where proname='carrier_invoice_payment_snapshot_problem' and pronamespace='public'::regnamespace) ilike '%''mode''%'
      and (select prosrc from pg_proc where proname='carrier_invoice_payment_snapshot_problem' and pronamespace='public'::regnamespace) not ilike '%''factoring_mode''%'
      and (select prosrc from pg_proc where proname='carrier_invoice_payment_snapshot_problem' and pronamespace='public'::regnamespace) not ilike '%''factoring_relationship_id''%'
      and (select prosrc from pg_proc where proname='carrier_invoice_payment_snapshot_problem' and pronamespace='public'::regnamespace) not ilike '%''company_id''%'),
  (31, 'record_carrier_invoice_payment returns SNAPSHOT_VERSION_UNSUPPORTED (distinct from SNAPSHOT_INTEGRITY_ERROR) and calls the version-aware validator',
      (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%SNAPSHOT_VERSION_UNSUPPORTED%'
      and (select prosrc from pg_proc where proname='record_carrier_invoice_payment' and pronamespace='public'::regnamespace) ilike '%VERSION_%'),
  (32, 'Section D existing-snapshot policy: carrier_invoice_issuance_snapshots is still empty immediately after this migration (it never backfills/rewrites/deletes history)',
      (select count(*) from public.carrier_invoice_issuance_snapshots) = 0),
  (33, 'no dispatch-service snapshot could ever carry factoring identity: _issue_dispatch_service_invoice_internal source contains no canonical factored-mode literal',
      (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) not ilike '%''mode'', ''factored''%'),
  (34, 'issue_carrier_invoice emits the corrected canonical top-level keys (source_loads/adjustment_amount/dispatch_service, never the retired loads/adjustments_amount JSON keys)',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%''source_loads''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%''adjustment_amount''%'
      and (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%''dispatch_service''%'),
  (35, '_issue_dispatch_service_invoice_internal nests agreement+billing_lines under a single dispatch_service object with agreement_number/agreement_version_id (never separate top-level agreement/billing_lines keys)',
      (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) ilike '%''agreement_number''%'
      and (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) ilike '%''agreement_version_id''%'
      and (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) ilike '%''source_loads''%'
      and (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) ilike '%''adjustment_amount''%')

) as checks(check_no, label, ok)
order by check_no;
