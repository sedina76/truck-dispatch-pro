-- ============================================================================
-- 0145 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0145. Requires 0144 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0144 landmark: issue_carrier_invoice(uuid,timestamptz,text,text) exists',
      to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is not null),
  (2, '0144 landmark: guard_load_stops_parent_lock() exists',
      to_regprocedure('public.guard_load_stops_parent_lock()') is not null),
  (3, '0143 landmark: compute_financial_request_fingerprint(jsonb) exists',
      to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is not null),
  (4, '0067 landmark: public.load_financials exists (the real, authoritative post-0069 rate table)',
      to_regclass('public.load_financials') is not null),
  (5, 'issue_carrier_invoice() still contains the pre-0145 DISPATCH_SERVICE_AGREEMENT_REQUIRED early return (confirms this preflight runs at the correct pre-0145 boundary)',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%DISPATCH_SERVICE_AGREEMENT_REQUIRED%'),
  (6, 'issue_carrier_invoice() still reads l.rate (loads.rate) -- confirms the Section A defect is still present, unpatched, at this boundary',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%l.rate%'),

  -- ---- objects 0145 introduces do not exist yet ----
  (7, 'organizations.remittance_instructions does not exist yet',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='organizations' and column_name='remittance_instructions')),
  (8, 'carrier_dispatch_service_agreements does not exist yet',
      to_regclass('public.carrier_dispatch_service_agreements') is null),
  (9, 'carrier_dispatch_service_agreement_versions does not exist yet',
      to_regclass('public.carrier_dispatch_service_agreement_versions') is null),
  (10, 'carrier_dispatch_service_billing_lines does not exist yet',
      to_regclass('public.carrier_dispatch_service_billing_lines') is null),
  (11, 'carrier_dispatch_service_agreement_idempotency does not exist yet',
      to_regclass('public.carrier_dispatch_service_agreement_idempotency') is null),
  (12, 'dispatch_service_fee_method type does not exist yet',
      to_regtype('public.dispatch_service_fee_method') is null),
  (13, '_issue_dispatch_service_invoice_internal(...) does not exist yet',
      to_regprocedure('public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)') is null),
  (14, 'create_carrier_dispatch_service_agreement(...) does not exist yet',
      to_regprocedure('public.create_carrier_dispatch_service_agreement(uuid,text,text,text)') is null)

) as checks(check_no, label, ok)
order by check_no;
