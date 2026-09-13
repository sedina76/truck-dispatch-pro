-- ============================================================================
-- 0144 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0144. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'carrier_invoice_line_item_type enum exists with exactly freight_charge/dispatch_service_fee',
      to_regtype('public.carrier_invoice_line_item_type') is not null
      and (select array_agg(enumlabel::text order by enumsortorder) from pg_enum where enumtypid = 'public.carrier_invoice_line_item_type'::regtype)
          = array['freight_charge','dispatch_service_fee']),

  (2, 'carrier_invoice_line_items gained line_type (not null, default freight_charge), source_load_id, source_dispatch_id',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='line_type' and is_nullable='NO')
      and exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='source_load_id')
      and exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='source_dispatch_id')),

  (3, 'civli_amounts_nonnegative constraint exists on carrier_invoice_line_items',
      exists (select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid where t.relname = 'carrier_invoice_line_items' and c.conname = 'civli_amounts_nonnegative')),

  (4, 'guard_carrier_invoice_line_item_mutability() now locks the parent invoice row and checks line_type/document_type consistency',
      (select prosrc from pg_proc where proname = 'guard_carrier_invoice_line_item_mutability' and pronamespace = 'public'::regnamespace) ilike '%for update%'
      and (select prosrc from pg_proc where proname = 'guard_carrier_invoice_line_item_mutability' and pronamespace = 'public'::regnamespace) ilike '%dispatch_service_fee%'),

  (5, 'guard_carrier_invoice_load_mutability() now locks the parent invoice row',
      (select prosrc from pg_proc where proname = 'guard_carrier_invoice_load_mutability' and pronamespace = 'public'::regnamespace) ilike '%for update%'),

  (6, 'issue_carrier_invoice(uuid,timestamptz,text,text) exists, is EXECUTE-able by authenticated, not by anon/public',
      to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is not null
      and has_function_privilege('authenticated', 'public.issue_carrier_invoice(uuid,timestamptz,text,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.issue_carrier_invoice(uuid,timestamptz,text,text)', 'EXECUTE')
      and not has_function_privilege('public', 'public.issue_carrier_invoice(uuid,timestamptz,text,text)', 'EXECUTE')),

  (7, 'issue_carrier_invoice() calls compute_financial_request_fingerprint(), acquires an advisory lock, and locks the invoice row FOR UPDATE',
      (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%compute_financial_request_fingerprint%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%pg_advisory_xact_lock%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%for update%'),

  (8, 'issue_carrier_invoice() never references md5() and never accepts a client-supplied total/subtotal parameter',
      (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%md5(%'
      and (select pg_get_function_arguments('public.issue_carrier_invoice(uuid,timestamptz,text,text)'::regprocedure)) not ilike '%total%'),

  (9, 'issue_carrier_invoice() rejects dispatch_service_invoice with DISPATCH_SERVICE_AGREEMENT_REQUIRED and never references an email/WhatsApp/PDF/QuickBooks/factoring-transmission concept',
      (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%DISPATCH_SERVICE_AGREEMENT_REQUIRED%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%sendgrid%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%whatsapp%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%quickbooks%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%pdf%'),

  (10, 'issue_carrier_invoice() never field-accesses .secret_reference (the only way its own source could leak it) and validates the snapshot via jsonb_contains_forbidden_key(..., array[...''secret_reference''...])',
      (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%.secret_reference%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%jsonb_contains_forbidden_key%'
      and (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''secret_reference''%'),

  (11, 'carrier_invoice_issuance_snapshots remains empty and carrier_invoices has zero issued rows -- this migration never inserts data',
      (select count(*) from public.carrier_invoice_issuance_snapshots) = 0
      and (select count(*) from public.carrier_invoices where issuance_status = 'issued') = 0),

  (12, 'no client role has direct INSERT on carrier_invoice_issuance_snapshots -- only the SECURITY DEFINER RPC can ever write one',
      not has_table_privilege('authenticated', 'public.carrier_invoice_issuance_snapshots', 'INSERT')
      and not has_table_privilege('anon', 'public.carrier_invoice_issuance_snapshots', 'INSERT')),

  (13, 'issue_carrier_invoice() checks role via has_role(owner/admin/accountant) -- dispatcher/driver/viewer are not in that set',
      (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%has_role(array[''owner'', ''admin'', ''accountant'']%'),

  (14, '_generate_carrier_invoice_number_internal(...) still has zero EXECUTE grant for any client role (0142 lockdown untouched)',
      not has_function_privilege('authenticated', 'public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)', 'EXECUTE'))

) as t(check_no, label, ok)
order by check_no;
