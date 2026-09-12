-- ============================================================================
-- 0130 PRE-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No ALTER/CREATE/DROP/INSERT/UPDATE/DELETE/GRANT/REVOKE. No DO block. No
-- transaction control. Never executes any RPC. Safe on production.
--
-- Run BEFORE applying supabase/migrations/0130_carrier_context_foundation.sql.
-- Every row of the matrix must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- baseline objects that must already exist ----
  (1,  'public.organizations exists',            to_regclass('public.organizations')     is not null),
  (2,  'public.carriers exists',                 to_regclass('public.carriers')          is not null),
  (3,  'public.brokers exists',                  to_regclass('public.brokers')           is not null),
  (4,  'public.customers exists',                to_regclass('public.customers')         is not null),
  (5,  'public.loads exists',                    to_regclass('public.loads')             is not null),
  (6,  'public.dispatches exists',               to_regclass('public.dispatches')        is not null),
  (7,  'public.platform_settings exists (0125)', to_regclass('public.platform_settings') is not null),
  (8,  'public.current_org_id() exists',         to_regprocedure('public.current_org_id()') is not null),
  (9,  'public.has_role(org_role[]) exists',     to_regprocedure('public.has_role(public.org_role[])') is not null),
  (10, 'public.set_updated_at() exists',         to_regprocedure('public.set_updated_at()') is not null),

  -- ---- correct baseline (0125 + 0129) ----
  (11, '0125 landmark: loads.financial_dispatch_id present',
       exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id')),
  (12, '0125 landmark: platform_settings.model_a_enabled present',
       exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='platform_settings' and column_name='model_a_enabled')),
  (13, '0129 landmark: public.create_dispatch(...) present',
       to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is not null),
  (14, 'platform_settings has exactly one row',
       (select count(*) from public.platform_settings) = 1),

  -- ---- carriers has the columns the remittance seed reads ----
  (15, 'carriers has legal_name / address_line1 / city / state / postal_code / country / email / is_active',
       (select count(*) from information_schema.columns
        where table_schema='public' and table_name='carriers'
          and column_name in ('legal_name','address_line1','city','state','postal_code','country','email','is_active')) = 8),

  -- ---- objects 0130 CREATES must be ABSENT (fail-closed) ----
  (16, 'type public.unresolved_record_status does NOT exist yet',
       not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
                   where n.nspname='public' and t.typname='unresolved_record_status')),
  (17, 'table public.carrier_remittance_profiles does NOT exist yet', to_regclass('public.carrier_remittance_profiles') is null),
  (18, 'table public.unresolved_carrier_records does NOT exist yet',  to_regclass('public.unresolved_carrier_records')  is null),
  (19, 'table public.financial_idempotency_keys does NOT exist yet',  to_regclass('public.financial_idempotency_keys')  is null),
  (20, 'function public.carrier_ids_authorized_for_current_user() does NOT exist yet',
       to_regprocedure('public.carrier_ids_authorized_for_current_user()') is null),
  (21, 'function public.carrier_ids_selectable_for_new_records() does NOT exist yet',
       to_regprocedure('public.carrier_ids_selectable_for_new_records()') is null),
  (22, 'function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) does NOT exist yet',
       to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)') is null),
  (23, 'carriers.invoice_code does NOT exist yet',
       not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='invoice_code')),
  (24, 'carriers.dispatch_service_terms_days does NOT exist yet',
       not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='dispatch_service_terms_days')),
  (25, 'platform_settings.dispatch_service_terms_days does NOT exist yet',
       not exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='dispatch_service_terms_days')),
  (26, 'platform_settings.multi_carrier_ui_enabled does NOT exist yet',
       not exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='multi_carrier_ui_enabled')),
  (27, 'platform_settings.carrier_dashboards_enabled does NOT exist yet',
       not exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='carrier_dashboards_enabled'))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): how many carrier_remittance_profiles rows 0130 will seed.
select 'carrier_remittance_profiles rows 0130 will seed' as note, count(*) as expected_seed from public.carriers;
