-- ============================================================================
-- 0142 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0142. Every row must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- new tables exist ----
  (1, 'carrier_invoices exists with RLS enabled',
      to_regclass('public.carrier_invoices') is not null
      and (select relrowsecurity from pg_class where oid = 'public.carrier_invoices'::regclass)),
  (2, 'carrier_invoice_line_items / carrier_invoice_loads exist with RLS enabled',
      to_regclass('public.carrier_invoice_line_items') is not null
      and (select relrowsecurity from pg_class where oid = 'public.carrier_invoice_line_items'::regclass)
      and to_regclass('public.carrier_invoice_loads') is not null
      and (select relrowsecurity from pg_class where oid = 'public.carrier_invoice_loads'::regclass)),
  (3, 'carrier_invoice_number_counters exists with RLS enabled, no client write policy',
      to_regclass('public.carrier_invoice_number_counters') is not null
      and (select relrowsecurity from pg_class where oid = 'public.carrier_invoice_number_counters'::regclass)
      and not has_table_privilege('authenticated', 'public.carrier_invoice_number_counters', 'INSERT')),
  (4, 'carrier_invoice_lifecycle_idempotency exists with RLS enabled, no client write policy',
      to_regclass('public.carrier_invoice_lifecycle_idempotency') is not null
      and (select relrowsecurity from pg_class where oid = 'public.carrier_invoice_lifecycle_idempotency'::regclass)
      and not has_table_privilege('authenticated', 'public.carrier_invoice_lifecycle_idempotency', 'INSERT')),
  (5, 'legacy_invoice_carrier_migration_review exists, empty, RLS enabled, and is READ-ONLY to authenticated (Phase 3B.3A.1: zero UPDATE grant, table or column -- review_legacy_invoice_carrier_migration() is the only mutation path)',
      to_regclass('public.legacy_invoice_carrier_migration_review') is not null
      and (select relrowsecurity from pg_class where oid = 'public.legacy_invoice_carrier_migration_review'::regclass)
      and (select count(*) from public.legacy_invoice_carrier_migration_review) = 0
      and not has_table_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'INSERT')
      and not has_table_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'DELETE')
      and not has_table_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'reviewed', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'reviewed_by', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'reviewed_at', 'UPDATE')),
  (18, 'review_legacy_invoice_carrier_migration() exists and is EXECUTE-able by authenticated (its own internal owner/admin check gates use); legacy_invoice_review_idempotency exists with no client write policy',
      to_regprocedure('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)') is not null
      and has_function_privilege('authenticated', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE')
      and to_regclass('public.legacy_invoice_review_idempotency') is not null
      and not has_table_privilege('authenticated', 'public.legacy_invoice_review_idempotency', 'INSERT')),
  (19, 'invoice_issuance_status / invoice_payment_status are two SEPARATE enums (Phase 3B.3A.1 Section A) -- the old mixed invoice_lifecycle_status no longer exists, and issuance_status never contains a payment or dispute value',
      exists (select 1 from pg_type where typname = 'invoice_issuance_status')
      and exists (select 1 from pg_type where typname = 'invoice_payment_status')
      and not exists (select 1 from pg_type where typname = 'invoice_lifecycle_status')
      and not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'invoice_issuance_status' and e.enumlabel in ('partially_paid', 'paid', 'disputed'))),
  (20, 'carrier_invoices column-privilege model (Phase 3B.3A.2 Section A): authenticated has EXACTLY ONE directly-grantable column (notes) -- every other column, including legal-identity/currency/due_date/payment_terms_days/issuance_status/void columns, has ZERO direct UPDATE grant for any role',
      not has_column_privilege('authenticated', 'public.carrier_invoices', 'organization_id', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'carrier_id', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'invoice_document_type', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'recipient_type', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'recipient_broker_id', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'recipient_customer_id', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'currency', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'due_date', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'payment_terms_days', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'invoice_number', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'issued_at', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'issuance_status', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'voided_at', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'voided_by', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'void_reason', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'payment_status', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'amount_paid', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'subtotal_amount', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'tax_amount', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'adjustments_amount', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'total_amount', 'UPDATE')
      and has_column_privilege('authenticated', 'public.carrier_invoices', 'notes', 'UPDATE')),
  (21, 'the snapshot secret/credential-key exclusion is recursive (jsonb_contains_forbidden_key exists) and civs_no_forbidden_keys / civs_payload_is_object constraints are installed',
      to_regprocedure('public.jsonb_contains_forbidden_key(jsonb,text[])') is not null
      and exists (select 1 from pg_constraint where conname = 'civs_no_forbidden_keys')
      and exists (select 1 from pg_constraint where conname = 'civs_payload_is_object')),
  (22, 'update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) exists and is EXECUTE-able by authenticated (its own internal role/field allowlist gates actual use)',
      to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is not null
      and has_function_privilege('authenticated', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE')),
  (23, 'carrier_invoice_lifecycle_idempotency.request_fingerprint exists (payload-mismatch detection for idempotent replay)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='request_fingerprint')),
  (24, 'update_carrier_invoice_draft() acquires an organization+operation+idempotency-key advisory lock (structural proxy: source references pg_advisory_xact_lock + hashtextextended) -- Phase 3B.3A.3 same-key/different-invoice collision closure',
      (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%pg_advisory_xact_lock%'
      and (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%hashtextextended%'),

  -- ---- immutable snapshot: zero INSERT/UPDATE/DELETE for any role ----
  (6, 'no role (including service_role) has direct INSERT/UPDATE/DELETE on carrier_invoice_issuance_snapshots',
      not has_table_privilege('authenticated', 'public.carrier_invoice_issuance_snapshots', 'INSERT')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_issuance_snapshots', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_issuance_snapshots', 'DELETE')
      and not has_table_privilege('service_role', 'public.carrier_invoice_issuance_snapshots', 'INSERT')
      and not has_table_privilege('service_role', 'public.carrier_invoice_issuance_snapshots', 'UPDATE')
      and not has_table_privilege('service_role', 'public.carrier_invoice_issuance_snapshots', 'DELETE')
      and not has_table_privilege('anon', 'public.carrier_invoice_issuance_snapshots', 'INSERT')),
  (7, 'the snapshot immutability trigger (BEFORE UPDATE OR DELETE) is installed',
      exists (select 1 from pg_trigger where tgname = 'a0142_guard_snapshot_immutable' and tgrelid = 'public.carrier_invoice_issuance_snapshots'::regclass)),

  -- ---- lifecycle + delete guards installed ----
  (8, 'the lifecycle transition guard (BEFORE UPDATE) is installed on carrier_invoices',
      exists (select 1 from pg_trigger where tgname = 'a0142_guard_lifecycle_transition' and tgrelid = 'public.carrier_invoices'::regclass)),
  (9, 'the delete guard (BEFORE DELETE) is installed on carrier_invoices',
      exists (select 1 from pg_trigger where tgname = 'a0142_guard_delete' and tgrelid = 'public.carrier_invoices'::regclass)),
  (10, 'org-consistency guard installed on carrier_invoices/carrier_invoice_loads',
      exists (select 1 from pg_trigger where tgname = 'a0142_guard_org_consistency' and tgrelid = 'public.carrier_invoices'::regclass)
      and exists (select 1 from pg_trigger where tgname = 'a0142_guard_load_consistency' and tgrelid = 'public.carrier_invoice_loads'::regclass)),
  (11, 'line-item / load-link mutability guards installed (immutable once issued)',
      exists (select 1 from pg_trigger where tgname = 'a0142_guard_line_item_mutability' and tgrelid = 'public.carrier_invoice_line_items'::regclass)
      and exists (select 1 from pg_trigger where tgname = 'a0142_guard_load_mutability' and tgrelid = 'public.carrier_invoice_loads'::regclass)),

  -- ---- numbering mechanism: private, no application-facing EXECUTE ----
  (12, 'the private numbering mechanism function exists and is not EXECUTE-able by anon/authenticated/service_role',
      to_regprocedure('public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)') is not null
      and not has_function_privilege('authenticated', 'public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)', 'EXECUTE')
      and not has_function_privilege('service_role', 'public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)', 'EXECUTE')),

  -- ---- both numbering uniqueness indexes exist, correctly scoped ----
  (13, 'freight numbers scoped per carrier, dispatch-service numbers scoped per organization (two separate partial unique indexes)',
      to_regclass('public.cinv_freight_number_unique') is not null
      and to_regclass('public.cinv_dispatch_number_unique') is not null),

  -- ---- problem/classifier functions exist, none exposed to clients ----
  (14, 'the three problem-classifier functions exist and are NOT exposed to authenticated/anon',
      to_regprocedure('public.carrier_invoice_recipient_problem(uuid)') is not null
      and to_regprocedure('public.carrier_invoice_factoring_readiness_problem(uuid)') is not null
      and to_regprocedure('public.carrier_invoice_issuance_problem(uuid)') is not null
      and not has_function_privilege('authenticated', 'public.carrier_invoice_recipient_problem(uuid)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.carrier_invoice_factoring_readiness_problem(uuid)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.carrier_invoice_issuance_problem(uuid)', 'EXECUTE')),
  (15, 'the legacy classifier is read-only-exposed correctly: classify_* not EXECUTE-able by authenticated, scan_* IS EXECUTE-able (owner/admin-gated internally)',
      to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)') is not null
      and not has_function_privilege('authenticated', 'public.classify_legacy_invoice_for_carrier_migration(uuid)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.scan_legacy_invoices_for_carrier_migration()', 'EXECUTE')),

  -- ---- 0001-0141 boundary untouched ----
  (16, 'public.invoices / factored_invoices are structurally untouched (no new column referencing carrier_invoices)',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='invoices' and column_name='carrier_id')
      and not exists (select 1 from information_schema.columns where table_schema='public' and table_name='invoices' and column_name='invoice_document_type')),
  (17, 'platform_settings.dispatch_invoice_prefix added, additive, with a default',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='dispatch_invoice_prefix' and column_default is not null))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): confirms zero rows were written by 0142 itself.
select
  (select count(*) from public.carrier_invoices) as carrier_invoices_rows,
  (select count(*) from public.carrier_invoice_issuance_snapshots) as snapshot_rows,
  (select count(*) from public.legacy_invoice_carrier_migration_review) as legacy_review_rows;
