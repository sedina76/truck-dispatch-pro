-- ============================================================================
-- 0146 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0146. Requires 0145 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0144 landmark: issue_carrier_invoice(uuid,timestamptz,text,text) exists',
      to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is not null),
  (2, '0145 (Phase 3B.4.1) landmark: _carrier_dispatch_service_agreement_effective_dates_lock_key exists',
      to_regprocedure('public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)') is not null),
  (3, '0142/0143 landmark: carrier_invoice_lifecycle_idempotency exists',
      to_regclass('public.carrier_invoice_lifecycle_idempotency') is not null),
  (4, '0142 landmark: carrier_invoices.balance_due is already a generated column',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoices' and column_name='balance_due' and is_generated='ALWAYS')),
  (5, '0142 landmark: cinv_payment_status_consistency constraint already exists',
      exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_invoices' and c.conname='cinv_payment_status_consistency')),

  -- ---- objects 0146 introduces do not exist yet ----
  (6, 'carrier_invoice_payments does not exist yet',
      to_regclass('public.carrier_invoice_payments') is null),
  (7, 'carrier_invoice_payment_status type does not exist yet',
      to_regtype('public.carrier_invoice_payment_status') is null),
  (8, 'carrier_invoice_payment_method type does not exist yet',
      to_regtype('public.carrier_invoice_payment_method') is null),
  (9, 'carrier_invoice_payer_type type does not exist yet',
      to_regtype('public.carrier_invoice_payer_type') is null),
  (10, 'record_carrier_invoice_payment(...) does not exist yet',
      to_regprocedure('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)') is null),
  (11, 'void_carrier_invoice_payment(...) does not exist yet',
      to_regprocedure('public.void_carrier_invoice_payment(uuid,timestamptz,text,text)') is null),
  (12, 'carrier_invoice_payment_number_seq does not exist yet',
      not exists (select 1 from pg_class where relkind='S' and relname='carrier_invoice_payment_number_seq')),
  (13, 'carrier_invoice_payment_snapshot_problem(uuid) does not exist yet (Phase 3B.5.1)',
      to_regprocedure('public.carrier_invoice_payment_snapshot_problem(uuid)') is null),
  (14, '_carrier_invoice_payment_external_reference_problem(text) does not exist yet (Phase 3B.5.1)',
      to_regprocedure('public._carrier_invoice_payment_external_reference_problem(text)') is null),

  -- ---- existing-data safety (Section M): report, never assume empty ----
  (15, 'every existing carrier_invoices row currently shows amount_paid = 0 (expected -- no payment mechanism has existed before this migration)',
      not exists (select 1 from public.carrier_invoices where amount_paid > 0)),

  -- ---- Phase 3B.5.2: pre-replacement (0145) issuance snapshot state ----
  (16, '0145 landmark: _issue_dispatch_service_invoice_internal(...) exists (about to be replaced in place)',
      to_regprocedure('public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)') is not null),
  (17, 'issue_carrier_invoice currently still emits schema_version=1 (the installed 0145 shape, not yet replaced)',
      (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''schema_version'', 1%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''schema_version'', 2%'),
  (18, '_issue_dispatch_service_invoice_internal currently still emits schema_version=1 (the installed 0145 shape, not yet replaced)',
      (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) ilike '%''schema_version'', 1%'
      and (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%''schema_version'', 2%'),
  (19, 'Section D existing-snapshot policy: zero carrier_invoice_issuance_snapshots rows exist (schema_version=2 cannot legitimately exist yet, so any existing row would refuse this migration)',
      (select count(*) from public.carrier_invoice_issuance_snapshots) = 0)

) as checks(check_no, label, ok)
order by check_no;
