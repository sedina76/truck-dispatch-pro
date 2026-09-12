-- ============================================================================
-- 0131 POST-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No DO block, no transaction control, no RPC execution. Safe on production.
--
-- Run AFTER applying 0131_carrier_party_relationships.sql.
-- Every row of the matrix must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'carrier_party_status = (draft, active, inactive)',
      (select string_agg(e.enumlabel, ',' order by e.enumsortorder)
       from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
       where n.nspname='public' and t.typname='carrier_party_status') = 'draft,active,inactive'),

  -- ---- carrier_brokers ----
  (2, 'carrier_brokers exists, RLS on, EMPTY',
      to_regclass('public.carrier_brokers') is not null
      and (select relrowsecurity from pg_class where oid='public.carrier_brokers'::regclass)
      and (select count(*) from public.carrier_brokers) = 0),
  (3, 'carrier_brokers UNIQUE (carrier_id, broker_id) present',
      exists (select 1 from pg_constraint where conname='carrier_brokers_carrier_broker_uq'
              and conrelid='public.carrier_brokers'::regclass and contype='u')),
  (4, 'carrier_brokers active_requires_billing CHECK present',
      exists (select 1 from pg_constraint where conname='carrier_brokers_active_requires_billing' and conrelid='public.carrier_brokers'::regclass)),
  (5, 'carrier_brokers doc_req_no_nulls CHECK present',
      exists (select 1 from pg_constraint where conname='carrier_brokers_doc_req_no_nulls' and conrelid='public.carrier_brokers'::regclass)),
  (6, 'carrier_brokers.document_requirements is public.document_type[]',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_brokers'
              and column_name='document_requirements' and udt_name='_document_type')),
  (7, 'carrier_brokers has exactly 3 policies (select/insert/update), NO delete/all',
      (select count(*) from pg_policies where schemaname='public' and tablename='carrier_brokers') = 3
      and not exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_brokers' and cmd in ('DELETE','ALL'))),
  (8, 'carrier_brokers broker_id FK is ON DELETE RESTRICT',
      exists (select 1 from pg_constraint c where c.conrelid='public.carrier_brokers'::regclass and c.contype='f'
              and c.confrelid='public.brokers'::regclass and c.confdeltype='r')),
  (9, 'trigger carrier_brokers_guard_org is BEFORE INSERT OR UPDATE',
      exists (select 1 from pg_trigger where tgname='carrier_brokers_guard_org' and tgrelid='public.carrier_brokers'::regclass
              and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%')),

  -- ---- carrier_customers ----
  (10, 'carrier_customers exists, RLS on, EMPTY',
      to_regclass('public.carrier_customers') is not null
      and (select relrowsecurity from pg_class where oid='public.carrier_customers'::regclass)
      and (select count(*) from public.carrier_customers) = 0),
  (11, 'carrier_customers UNIQUE (carrier_id, customer_id) present',
      exists (select 1 from pg_constraint where conname='carrier_customers_carrier_customer_uq'
              and conrelid='public.carrier_customers'::regclass and contype='u')),
  (12, 'carrier_customers active_requires_billing + doc_req_no_nulls CHECKs present',
      exists (select 1 from pg_constraint where conname='carrier_customers_active_requires_billing' and conrelid='public.carrier_customers'::regclass)
      and exists (select 1 from pg_constraint where conname='carrier_customers_doc_req_no_nulls' and conrelid='public.carrier_customers'::regclass)),
  (13, 'carrier_customers has exactly 3 policies, NO delete/all',
      (select count(*) from pg_policies where schemaname='public' and tablename='carrier_customers') = 3
      and not exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_customers' and cmd in ('DELETE','ALL'))),
  (14, 'carrier_customers customer_id FK is ON DELETE RESTRICT',
      exists (select 1 from pg_constraint c where c.conrelid='public.carrier_customers'::regclass and c.contype='f'
              and c.confrelid='public.customers'::regclass and c.confdeltype='r')),
  (15, 'trigger carrier_customers_guard_org is BEFORE INSERT OR UPDATE',
      exists (select 1 from pg_trigger where tgname='carrier_customers_guard_org' and tgrelid='public.carrier_customers'::regclass
              and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%')),

  -- ---- function hardening ----
  (16, 'activate_carrier_party(...) exists, SECURITY DEFINER + pinned search_path',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='activate_carrier_party'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')),
  (17, 'activate_carrier_party NOT EXECUTE-able by PUBLIC; authenticated CAN execute',
      not has_function_privilege('public','public.activate_carrier_party(uuid,uuid,uuid,jsonb)'::regprocedure,'EXECUTE')
      and has_function_privilege('authenticated','public.activate_carrier_party(uuid,uuid,uuid,jsonb)'::regprocedure,'EXECUTE')),
  (18, 'guard_carrier_party_org() is SECURITY DEFINER + pinned search_path',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='guard_carrier_party_org'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')),

  -- ---- 0130 landmark intact ----
  (19, '0130 carrier_remittance_profiles still present', to_regclass('public.carrier_remittance_profiles') is not null),
  (20, '0130 unresolved_carrier_records still present and EMPTY',
      to_regclass('public.unresolved_carrier_records') is not null
      and (select count(*) from public.unresolved_carrier_records) = 0)

) as t(check_no, label, ok)
order by check_no;
