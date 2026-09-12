-- ============================================================================
-- 0130 POST-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No DO block, no transaction control, no RPC execution. Safe on production.
--
-- Run AFTER applying 0130_carrier_context_foundation.sql.
-- Every row of the matrix must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- enum ----
  (1, 'unresolved_record_status = (unresolved, manually_resolved, archived_legacy)',
      (select string_agg(e.enumlabel, ',' order by e.enumsortorder)
       from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
       where n.nspname='public' and t.typname='unresolved_record_status')
      = 'unresolved,manually_resolved,archived_legacy'),

  -- ---- carriers columns ----
  (2, 'carriers.invoice_code is (text, nullable, no default)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers'
              and column_name='invoice_code' and data_type='text' and is_nullable='YES' and column_default is null)),
  (3, 'CHECK carriers_invoice_code_format present',
      exists (select 1 from pg_constraint where conname='carriers_invoice_code_format' and conrelid='public.carriers'::regclass)),
  (4, 'carriers.dispatch_service_terms_days is (integer, nullable, no default)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers'
              and column_name='dispatch_service_terms_days' and data_type='integer' and is_nullable='YES' and column_default is null)),
  (5, 'partial UNIQUE index carriers_org_invoice_code_uq present',
      exists (select 1 from pg_index i join pg_class ic on ic.oid=i.indexrelid
              where ic.relname='carriers_org_invoice_code_uq' and i.indisunique and i.indpred is not null)),

  -- ---- platform_settings columns + observed values ----
  (6, 'platform_settings.dispatch_service_terms_days is (integer, NOT NULL, DEFAULT 15)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings'
              and column_name='dispatch_service_terms_days' and data_type='integer' and is_nullable='NO' and column_default='15')),
  (7, 'the platform_settings row observes dispatch_service_terms_days = 15 (Net 15)',
      (select dispatch_service_terms_days from public.platform_settings where id=true) = 15),
  (8, 'platform_settings.multi_carrier_ui_enabled is (boolean, NOT NULL, DEFAULT false) and observed FALSE',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings'
              and column_name='multi_carrier_ui_enabled' and data_type='boolean' and is_nullable='NO' and column_default='false')
      and (select not multi_carrier_ui_enabled from public.platform_settings where id=true)),
  (9, 'platform_settings.carrier_dashboards_enabled is (boolean, NOT NULL, DEFAULT false) and observed FALSE',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings'
              and column_name='carrier_dashboards_enabled' and data_type='boolean' and is_nullable='NO' and column_default='false')
      and (select not carrier_dashboards_enabled from public.platform_settings where id=true)),
  (10, 'Model A still disabled (platform_settings.model_a_enabled = false)',
      (select model_a_enabled from public.platform_settings where id=true) = false),

  -- ---- carrier_remittance_profiles ----
  (11, 'carrier_remittance_profiles exists with RLS enabled',
      to_regclass('public.carrier_remittance_profiles') is not null
      and (select relrowsecurity from pg_class where oid='public.carrier_remittance_profiles'::regclass)),
  (12, 'carrier_remittance_profiles has one row per carrier',
      (select count(*) from public.carrier_remittance_profiles) = (select count(*) from public.carriers)),
  (13, 'every carrier_remittance_profiles row has organization_id = its carrier org',
      not exists (select 1 from public.carrier_remittance_profiles p join public.carriers c on c.id=p.carrier_id
                  where p.organization_id <> c.organization_id)),
  (14, 'every seeded carrier_remittance_profiles row has show_ein_on_pdf = false AND show_bank_details_on_pdf = false',
      not exists (select 1 from public.carrier_remittance_profiles where show_ein_on_pdf or show_bank_details_on_pdf)),
  (15, 'carrier_remittance_profiles has NO delete/all policy',
      not exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_remittance_profiles' and cmd in ('DELETE','ALL'))),
  (16, 'trigger carrier_remittance_profiles_guard_org is BEFORE INSERT OR UPDATE',
      exists (select 1 from pg_trigger where tgname='carrier_remittance_profiles_guard_org'
              and tgrelid='public.carrier_remittance_profiles'::regclass and not tgisinternal
              and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%')),

  -- ---- unresolved_carrier_records ----
  (17, 'unresolved_carrier_records exists, RLS on, EMPTY',
      to_regclass('public.unresolved_carrier_records') is not null
      and (select relrowsecurity from pg_class where oid='public.unresolved_carrier_records'::regclass)
      and (select count(*) from public.unresolved_carrier_records) = 0),
  (18, 'unresolved_carrier_records has NO insert/delete/all policy',
      not exists (select 1 from pg_policies where schemaname='public' and tablename='unresolved_carrier_records' and cmd in ('INSERT','DELETE','ALL'))),
  (19, 'partial UNIQUE index unresolved_carrier_records_one_open_per_record present',
      exists (select 1 from pg_index i join pg_class ic on ic.oid=i.indexrelid
              where ic.relname='unresolved_carrier_records_one_open_per_record' and i.indisunique and i.indpred is not null)),

  -- ---- financial_idempotency_keys ----
  (20, 'financial_idempotency_keys exists, RLS on, EMPTY',
      to_regclass('public.financial_idempotency_keys') is not null
      and (select relrowsecurity from pg_class where oid='public.financial_idempotency_keys'::regclass)
      and (select count(*) from public.financial_idempotency_keys) = 0),
  (21, 'UNIQUE (organization_id, scope, idempotency_key) present (per-org, correction G)',
      exists (select 1 from pg_constraint where conname='financial_idempotency_keys_org_scope_key_uq'
              and conrelid='public.financial_idempotency_keys'::regclass and contype='u')),
  (22, 'financial_idempotency_keys has NO write policy for authenticated',
      not exists (select 1 from pg_policies where schemaname='public' and tablename='financial_idempotency_keys' and cmd in ('INSERT','UPDATE','DELETE','ALL'))),
  (23, 'financial_idempotency_keys.state CHECK allows exactly processing/succeeded/blocked/failed',
      (select pg_get_constraintdef(oid) from pg_constraint
       where conrelid='public.financial_idempotency_keys'::regclass and contype='c'
         and pg_get_constraintdef(oid) ilike '%state%') ilike '%''processing''%''succeeded''%''blocked''%''failed''%'),

  -- ---- functions: security definer, pinned search_path, not PUBLIC-executable ----
  (24, 'carrier_ids_authorized_for_current_user() is SECURITY DEFINER + pinned search_path',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='carrier_ids_authorized_for_current_user'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')),
  (25, 'carrier_ids_authorized_for_current_user() NOT EXECUTE-able by PUBLIC; authenticated CAN execute',
      not has_function_privilege('public','public.carrier_ids_authorized_for_current_user()'::regprocedure,'EXECUTE')
      and has_function_privilege('authenticated','public.carrier_ids_authorized_for_current_user()'::regprocedure,'EXECUTE')),
  (26, 'carrier_ids_selectable_for_new_records() is SECURITY DEFINER + pinned search_path',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='carrier_ids_selectable_for_new_records'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')),
  (27, 'carrier_ids_selectable_for_new_records() NOT EXECUTE-able by PUBLIC; authenticated CAN execute',
      not has_function_privilege('public','public.carrier_ids_selectable_for_new_records()'::regprocedure,'EXECUTE')
      and has_function_privilege('authenticated','public.carrier_ids_selectable_for_new_records()'::regprocedure,'EXECUTE')),
  (28, 'the two carrier-visibility helpers are DISTINCT functions (never one reused for both purposes)',
      'public.carrier_ids_authorized_for_current_user()'::regprocedure <> 'public.carrier_ids_selectable_for_new_records()'::regprocedure),
  (29, 'record_unresolved_carrier_record(...) is SECURITY DEFINER + pinned search_path, not PUBLIC-executable',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='record_unresolved_carrier_record'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')
      and not has_function_privilege('public','public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)'::regprocedure,'EXECUTE')),

  -- ---- landmarks intact ----
  (30, '0129 create_dispatch(...) still present',
      to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is not null),
  (31, '0068/0129 auto_generate_invoice_on_delivery trigger still present',
      exists (select 1 from pg_trigger where tgname='auto_generate_invoice_on_delivery' and tgrelid='public.loads'::regclass and not tgisinternal)),
  (32, '0125 dispatches_assign_financial_controller trigger still present',
      exists (select 1 from pg_trigger where tgname='dispatches_assign_financial_controller' and tgrelid='public.dispatches'::regclass and not tgisinternal))

) as t(check_no, label, ok)
order by check_no;
