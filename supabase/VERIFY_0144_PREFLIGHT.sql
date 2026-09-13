-- ============================================================================
-- 0144 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0144. Requires 0143 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0143 landmark: compute_financial_request_fingerprint(jsonb) exists',
      to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is not null),
  (2, '0143 landmark: carrier_invoice_lifecycle_idempotency.operation column exists (0143 applied)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='operation')),
  (3, '0142 landmark: carrier_invoice_line_items exists',
      to_regclass('public.carrier_invoice_line_items') is not null),
  (4, '0142 landmark: carrier_invoice_number_counters + _generate_carrier_invoice_number_internal exist',
      to_regclass('public.carrier_invoice_number_counters') is not null
      and to_regprocedure('public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)') is not null),
  (5, '0142 landmark: the three read-only problem classifiers exist',
      to_regprocedure('public.carrier_invoice_recipient_problem(uuid)') is not null
      and to_regprocedure('public.carrier_invoice_factoring_readiness_problem(uuid)') is not null
      and to_regprocedure('public.carrier_invoice_issuance_problem(uuid)') is not null),

  -- ---- objects 0144 introduces do not exist yet ----
  (6, 'carrier_invoice_line_items.line_type does not exist yet',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='line_type')),
  (7, 'carrier_invoice_line_items.source_load_id does not exist yet',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='source_load_id')),
  (8, 'carrier_invoice_line_item_type enum does not exist yet',
      to_regtype('public.carrier_invoice_line_item_type') is null),
  (9, 'issue_carrier_invoice(uuid,timestamptz,text,text) does not exist yet',
      to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is null),
  (10, 'guard_carrier_invoice_line_item_mutability() does not yet lock the parent invoice row (confirms this preflight runs at the correct pre-0144 boundary)',
      (select prosrc from pg_proc where proname = 'guard_carrier_invoice_line_item_mutability' and pronamespace = 'public'::regnamespace) not ilike '%for update%'),

  -- ---- no carrier_invoices row is issued yet anywhere (there should be
  -- none in a genuinely fresh environment, but this is informational/
  -- structural, not itself a hard gate -- 0144 does not refuse to apply
  -- based on this the way 0143 refuses on a non-empty idempotency table,
  -- since an already-issued invoice from a hypothetical prior manual
  -- simulation is not a compatibility hazard for 0144's own additive
  -- schema changes) ----
  (11, 'carrier_invoice_issuance_snapshots exists (0142) -- the table 0144''s RPC will insert into',
      to_regclass('public.carrier_invoice_issuance_snapshots') is not null)

) as t(check_no, label, ok)
order by check_no;
