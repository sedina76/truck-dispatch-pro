-- ============================================================================
-- 0147 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0147. Requires 0146 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- 0146/0142/0143/0130 landmarks 0147 depends on ----
  (1, '0146 landmark: record_carrier_invoice_payment(...) exists',
      to_regprocedure('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)') is not null),
  (2, '0142 landmark: classify_legacy_invoice_for_carrier_migration(uuid) exists',
      to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)') is not null),
  (3, '0142 landmark: scan_legacy_invoices_for_carrier_migration() exists',
      to_regprocedure('public.scan_legacy_invoices_for_carrier_migration()') is not null),
  (4, '0142 landmark: review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text) exists (exact signature)',
      to_regprocedure('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)') is not null),
  (5, '0143 landmark: update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) exists (exact signature)',
      to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is not null),
  (6, '0001 landmark: public.dispatches exists with load_id/carrier_id/status columns (the classifier''s live evidence source)',
      to_regclass('public.dispatches') is not null
      and (select count(*) from information_schema.columns where table_schema='public' and table_name='dispatches' and column_name in ('load_id','carrier_id','status')) = 3),
  (7, '0130 landmark: carrier_ids_selectable_for_new_records() exists',
      to_regprocedure('public.carrier_ids_selectable_for_new_records()') is not null),
  (8, '0009/0046 landmark: log_activity(entity_type,uuid,text,jsonb,uuid) exists',
      to_regprocedure('public.log_activity(public.entity_type,uuid,text,jsonb,uuid)') is not null),
  (9, '0142 landmark: carrier_invoices exists with a0142_guard_delete trigger installed',
      to_regclass('public.carrier_invoices') is not null
      and exists (select 1 from pg_trigger where tgname = 'a0142_guard_delete' and not tgisinternal)),

  -- ---- the seven vulnerable pre-0147 conditions have the expected shape ----
  (10, 'BLOCKER 1 pre-shape: classifier source still tests the impossible carrier_resolution=''conflicting'' literal',
      (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%carrier_resolution = ''conflicting''%'),
  (11, 'BLOCKER 2 pre-shape: authenticated currently has direct INSERT on carrier_invoices',
      has_table_privilege('authenticated', 'public.carrier_invoices', 'INSERT')),
  (12, 'BLOCKER 3 pre-shape: authenticated currently has direct DELETE on carrier_invoices',
      has_table_privilege('authenticated', 'public.carrier_invoices', 'DELETE')),
  (13, 'BLOCKER 4 pre-shape: PUBLIC/anon can currently EXECUTE update_carrier_invoice_draft',
      has_function_privilege('anon', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE')),
  (14, 'BLOCKER 5 pre-shape: PUBLIC/anon can currently EXECUTE review_legacy_invoice_carrier_migration',
      has_function_privilege('anon', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE')),
  (15, 'BLOCKER 6 pre-shape: PUBLIC/anon can currently EXECUTE scan_legacy_invoices_for_carrier_migration',
      has_function_privilege('anon', 'public.scan_legacy_invoices_for_carrier_migration()', 'EXECUTE')),
  (16, 'BLOCKER 7 pre-shape: scan source uses the bare `not public.has_role` pattern (no auth.uid()/current_org_id() null guard yet)',
      (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%if not public.has_role%'
      and (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) not ilike '%auth.uid() is null%'),

  -- ---- no unexpected overloads exist ----
  (17, 'exactly one classify_legacy_invoice_for_carrier_migration overload',
      (select count(*) from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) = 1),
  (18, 'exactly one scan_legacy_invoices_for_carrier_migration overload',
      (select count(*) from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) = 1),
  (19, 'exactly one update_carrier_invoice_draft overload',
      (select count(*) from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) = 1),
  (20, 'exactly one review_legacy_invoice_carrier_migration overload',
      (select count(*) from pg_proc where proname = 'review_legacy_invoice_carrier_migration' and pronamespace = 'public'::regnamespace) = 1),

  -- ---- no later migration objects exist ----
  (21, 'no 0147 objects exist yet',
      to_regclass('public.carrier_invoice_draft_create_idempotency') is null
      and to_regclass('public.carrier_invoice_draft_delete_idempotency') is null
      and to_regprocedure('public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)') is null
      and to_regprocedure('public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)') is null),

  -- ---- classifier dependencies match expected types/columns ----
  (22, 'loads.carrier_resolution CHECK still permits only resolved/backfilled/unresolved',
      exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='loads' and c.conname='loads_carrier_resolution_values')
      and (select pg_get_constraintdef(c.oid) from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='loads' and c.conname='loads_carrier_resolution_values') !~ 'conflicting'),
  (23, 'loads.financial_dispatch_id exists (the classifier''s live controller-evidence column)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id')),
  (24, 'public.invoices has load_id/broker_id/customer_id/status/amount_paid/total_amount columns',
      (select count(*) from information_schema.columns where table_schema='public' and table_name='invoices' and column_name in ('load_id','broker_id','customer_id','status','amount_paid','total_amount')) = 6),

  -- ---- carrier-invoice grants/policies/triggers match the supported boundary ----
  (25, 'carrier_invoices_insert / carrier_invoices_delete policies currently exist (about to be dropped)',
      exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_invoices' and policyname='carrier_invoices_insert')
      and exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_invoices' and policyname='carrier_invoices_delete')),
  (26, 'authenticated currently has UPDATE(notes)-only on carrier_invoices (unaffected by this migration)',
      has_column_privilege('authenticated', 'public.carrier_invoices', 'notes', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.carrier_invoices', 'UPDATE')),
  (27, 'RLS currently enabled on carrier_invoices',
      (select relrowsecurity from pg_class where oid = 'public.carrier_invoices'::regclass)),
  (28, 'carrier_invoice_line_items_insert / carrier_invoice_loads_insert policies already exist (untouched by 0147)',
      exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_invoice_line_items' and policyname='carrier_invoice_line_items_insert')
      and exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_invoice_loads' and policyname='carrier_invoice_loads_insert')),

  -- ---- idempotency/audit dependencies required by the new RPCs exist ----
  (29, 'pgcrypto (digest/gen_random_uuid) available',
      exists (select 1 from pg_extension where extname = 'pgcrypto')),
  (30, 'organizations/brokers/customers tables exist for FK targets',
      to_regclass('public.organizations') is not null and to_regclass('public.brokers') is not null and to_regclass('public.customers') is not null)

) as checks(check_no, label, ok)
order by check_no;
