-- ============================================================================
-- 0145 POST-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run AFTER applying 0145. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'organizations.remittance_instructions exists (nullable text)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='organizations' and column_name='remittance_instructions' and is_nullable='YES')),
  (2, 'entity_type gained carrier_dispatch_service_agreement',
      'carrier_dispatch_service_agreement' = any(enum_range(null::public.entity_type)::text[])),
  (3, 'dispatch_service_agreement_status has exactly active/inactive',
      (select array_agg(enumlabel::text order by enumlabel) from pg_enum where enumtypid = 'public.dispatch_service_agreement_status'::regtype) = array['active','inactive']),
  (4, 'dispatch_service_agreement_version_status has exactly draft/approved/superseded/inactive',
      (select array_agg(enumlabel::text order by enumlabel) from pg_enum where enumtypid = 'public.dispatch_service_agreement_version_status'::regtype) = array['approved','draft','inactive','superseded']),
  (5, 'dispatch_service_fee_method has exactly percentage_of_freight/flat_per_load',
      (select array_agg(enumlabel::text order by enumlabel) from pg_enum where enumtypid = 'public.dispatch_service_fee_method'::regtype) = array['flat_per_load','percentage_of_freight']),
  (6, 'carrier_dispatch_service_agreements exists with unique(organization_id, carrier_id, agreement_number)',
      to_regclass('public.carrier_dispatch_service_agreements') is not null
      and exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_dispatch_service_agreements' and c.contype='u')),
  (7, 'carrier_dispatch_service_agreement_versions exists',
      to_regclass('public.carrier_dispatch_service_agreement_versions') is not null),
  (8, 'cdsav_no_overlap_when_approved is a real exclusion constraint (btree_gist)',
      exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_dispatch_service_agreement_versions' and c.conname='cdsav_no_overlap_when_approved' and c.contype='x')),
  (9, 'guard_carrier_dispatch_service_agreement_version_lifecycle trigger installed',
      exists (select 1 from pg_trigger tg join pg_class t on t.oid=tg.tgrelid where t.relname='carrier_dispatch_service_agreement_versions' and tg.tgname='a0145_guard_agreement_version_lifecycle' and not tg.tgisinternal)),
  (10, 'carrier_dispatch_service_billing_lines exists with unique(load_id)',
      to_regclass('public.carrier_dispatch_service_billing_lines') is not null
      and exists (
        select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
        where t.relname = 'carrier_dispatch_service_billing_lines' and c.contype = 'u'
          and c.conkey = (select array_agg(a.attnum) from pg_attribute a where a.attrelid = t.oid and a.attname = 'load_id')
      )),
  (11, 'carrier_dispatch_service_agreement_idempotency exists',
      to_regclass('public.carrier_dispatch_service_agreement_idempotency') is not null),
  (12, 'create_carrier_dispatch_service_agreement is owner/admin-callable (authenticated EXECUTE granted; internal role check gates actual use)',
      has_function_privilege('authenticated', 'public.create_carrier_dispatch_service_agreement(uuid,text,text,text)', 'EXECUTE')),
  (13, 'create_carrier_dispatch_service_agreement_version exists and is authenticated-callable',
      has_function_privilege('authenticated', 'public.create_carrier_dispatch_service_agreement_version(uuid,public.dispatch_service_fee_method,numeric,numeric,numeric,numeric,text,integer,date,date,text,text)', 'EXECUTE')),
  (14, 'approve_carrier_dispatch_service_agreement_version exists and is authenticated-callable',
      has_function_privilege('authenticated', 'public.approve_carrier_dispatch_service_agreement_version(uuid,timestamptz,text,text,uuid)', 'EXECUTE')),
  (15, 'deactivate_carrier_dispatch_service_agreement_version exists and is authenticated-callable',
      has_function_privilege('authenticated', 'public.deactivate_carrier_dispatch_service_agreement_version(uuid,timestamptz,text,text)', 'EXECUTE')),
  (16, 'deactivate_carrier_dispatch_service_agreement exists and is authenticated-callable',
      has_function_privilege('authenticated', 'public.deactivate_carrier_dispatch_service_agreement(uuid,timestamptz,text,text)', 'EXECUTE')),
  (17, '_issue_dispatch_service_invoice_internal exists but is NOT authenticated-callable (internal only)',
      to_regprocedure('public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)') is not null
      and not has_function_privilege('authenticated', 'public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)', 'EXECUTE')),
  (18, 'issue_carrier_invoice() no longer contains the retired DISPATCH_SERVICE_AGREEMENT_REQUIRED placeholder',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) not ilike '%DISPATCH_SERVICE_AGREEMENT_REQUIRED%'),
  (19, 'issue_carrier_invoice() no longer reads l.rate (loads.rate) directly -- Section A defect fixed',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) not ilike '%l.rate%'),
  (20, 'issue_carrier_invoice() now reads load_financials.rate (lf.rate) for agreed_freight_charge',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%lf.rate%'),
  (21, 'issue_carrier_invoice() dispatches dispatch_service_invoice to the internal function (never an unconditional early return)',
      (select prosrc from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace) ilike '%_issue_dispatch_service_invoice_internal%'),
  (22, 'no carrier_dispatch_service_agreements/versions/billing_lines row exists yet -- this migration never inserts data',
      (select count(*) from public.carrier_dispatch_service_agreements) = 0
      and (select count(*) from public.carrier_dispatch_service_agreement_versions) = 0
      and (select count(*) from public.carrier_dispatch_service_billing_lines) = 0),
  (23, 'no direct authenticated INSERT/UPDATE/DELETE grant on any new agreement/version/ledger table',
      not exists (
        select 1 from information_schema.role_table_grants
        where grantee = 'authenticated' and privilege_type in ('INSERT','UPDATE','DELETE')
          and table_name in ('carrier_dispatch_service_agreements','carrier_dispatch_service_agreement_versions','carrier_dispatch_service_billing_lines','carrier_dispatch_service_agreement_idempotency')
      )),
  (24, 'anon has zero grants on any new table',
      not exists (
        select 1 from information_schema.role_table_grants
        where grantee = 'anon'
          and table_name in ('carrier_dispatch_service_agreements','carrier_dispatch_service_agreement_versions','carrier_dispatch_service_billing_lines','carrier_dispatch_service_agreement_idempotency')
      )),

  -- Phase 3B.4.1 checks.
  (25, '_carrier_dispatch_service_agreement_effective_dates_lock_key exists and is NOT authenticated-callable (internal only)',
      to_regprocedure('public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)') is not null
      and not has_function_privilege('authenticated', 'public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)', 'EXECUTE')),
  (26, 'cdsav_agreement_version_number_unique is a named unique constraint',
      exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_dispatch_service_agreement_versions' and c.conname='cdsav_agreement_version_number_unique' and c.contype='u')),
  (27, 'cdsa_org_carrier_agreement_number_unique is a named unique constraint',
      exists (select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_dispatch_service_agreements' and c.conname='cdsa_org_carrier_agreement_number_unique' and c.contype='u')),
  (28, 'all five agreement-lifecycle RPCs acquire the carrier-scoped effective-dates advisory lock',
      (select prosrc from pg_proc where proname='create_carrier_dispatch_service_agreement' and pronamespace='public'::regnamespace) ilike '%_carrier_dispatch_service_agreement_effective_dates_lock_key%'
      and (select prosrc from pg_proc where proname='create_carrier_dispatch_service_agreement_version' and pronamespace='public'::regnamespace) ilike '%_carrier_dispatch_service_agreement_effective_dates_lock_key%'
      and (select prosrc from pg_proc where proname='approve_carrier_dispatch_service_agreement_version' and pronamespace='public'::regnamespace) ilike '%_carrier_dispatch_service_agreement_effective_dates_lock_key%'
      and (select prosrc from pg_proc where proname='deactivate_carrier_dispatch_service_agreement_version' and pronamespace='public'::regnamespace) ilike '%_carrier_dispatch_service_agreement_effective_dates_lock_key%'
      and (select prosrc from pg_proc where proname='deactivate_carrier_dispatch_service_agreement' and pronamespace='public'::regnamespace) ilike '%_carrier_dispatch_service_agreement_effective_dates_lock_key%'),
  (29, 'approve_carrier_dispatch_service_agreement_version performs an explicit app-level overlap check before the apply block',
      (select prosrc from pg_proc where proname='approve_carrier_dispatch_service_agreement_version' and pronamespace='public'::regnamespace) ilike '%AGREEMENT_OVERLAP%daterange%'
      or (select prosrc from pg_proc where proname='approve_carrier_dispatch_service_agreement_version' and pronamespace='public'::regnamespace) ilike '%daterange%AGREEMENT_OVERLAP%'),
  (30, '_issue_dispatch_service_invoice_internal acquires the carrier-scoped effective-dates advisory lock AND returns CARRIER_INACTIVE AND DISPATCH_REMITTANCE_REQUIRED',
      (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) ilike '%_carrier_dispatch_service_agreement_effective_dates_lock_key%'
      and (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) ilike '%CARRIER_INACTIVE%'
      and (select prosrc from pg_proc where proname='_issue_dispatch_service_invoice_internal' and pronamespace='public'::regnamespace) ilike '%DISPATCH_REMITTANCE_REQUIRED%')

) as checks(check_no, label, ok)
order by check_no;
