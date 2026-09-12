-- ============================================================================
-- 0138 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0138. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'new carrier-scoped default index present',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_carrier')),
  (2, 'old org-scoped default index is GONE',
      not exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_org')),

  (3, 'classify_carrier_factoring_readiness(...) present, SECURITY DEFINER, STABLE, pinned search_path',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='classify_carrier_factoring_readiness'
                and p.prosecdef and p.provolatile='s'
                and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')),
  (4, 'authenticated holds EXECUTE on classify_carrier_factoring_readiness(...)',
      has_function_privilege('authenticated','public.classify_carrier_factoring_readiness(uuid,uuid,uuid)','EXECUTE')),

  (5, 'set_default_factoring_relationship(uuid) present, SECURITY DEFINER, pinned search_path, returns jsonb',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='set_default_factoring_relationship'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%'
                and p.prorettype = 'jsonb'::regtype)),
  (6, 'authenticated holds EXECUTE on set_default_factoring_relationship(uuid)',
      has_function_privilege('authenticated','public.set_default_factoring_relationship(uuid)','EXECUTE')),

  (7, 'approve_factoring_relationship_noa(...) present, SECURITY DEFINER, pinned search_path',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='approve_factoring_relationship_noa'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')),
  (8, 'authenticated holds EXECUTE on approve_factoring_relationship_noa(...)',
      has_function_privilege('authenticated','public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)','EXECUTE')),

  -- ---- column-privilege lockdown ----
  (9, 'authenticated holds NO table-level UPDATE grant on factoring_relationships',
      not has_table_privilege('authenticated','public.factoring_relationships','UPDATE')),
  (10, 'authenticated has NO UPDATE on is_default',
      not has_column_privilege('authenticated','public.factoring_relationships','is_default','UPDATE')),
  (11, 'authenticated has NO UPDATE on carrier_id',
      not has_column_privilege('authenticated','public.factoring_relationships','carrier_id','UPDATE')),
  (12, 'authenticated has NO UPDATE on factoring_company_id',
      not has_column_privilege('authenticated','public.factoring_relationships','factoring_company_id','UPDATE')),
  (13, 'authenticated has NO UPDATE on noa_approved / noa_approved_by / noa_approved_at',
      not has_column_privilege('authenticated','public.factoring_relationships','noa_approved','UPDATE')
      and not has_column_privilege('authenticated','public.factoring_relationships','noa_approved_by','UPDATE')
      and not has_column_privilege('authenticated','public.factoring_relationships','noa_approved_at','UPDATE')),
  (14, 'authenticated HAS UPDATE on operational fields (default_advance_percentage, is_active, submission_method, remittance_instructions -- owner/admin-gated by trigger, not this grant)',
      has_column_privilege('authenticated','public.factoring_relationships','default_advance_percentage','UPDATE')
      and has_column_privilege('authenticated','public.factoring_relationships','is_active','UPDATE')
      and has_column_privilege('authenticated','public.factoring_relationships','remittance_instructions','UPDATE')
      and has_column_privilege('authenticated','public.factoring_relationships','submission_method','UPDATE')),

  -- ---- untouched: 0071/0072 objects still present in some form ----
  (15, 'factored_invoices / factoring_events still present',
      to_regclass('public.factored_invoices') is not null and to_regclass('public.factoring_events') is not null),
  (16, 'guard_factoring_company_deactivation trigger still attached to factoring_companies',
      exists (select 1 from pg_trigger where tgname='factoring_companies_guard_deactivation' and tgrelid='public.factoring_companies'::regclass and not tgisinternal)),

  -- ---- global invariant this migration protects ----
  (17, 'GLOBAL: no carrier has more than one active+default factoring_relationships row',
      not exists (
        select 1 from public.factoring_relationships
        where is_default and is_active and carrier_id is not null
        group by carrier_id having count(*) > 1)),
  (18, 'GLOBAL: no active+default relationship has a null carrier_id',
      not exists (select 1 from public.factoring_relationships where is_default and is_active and carrier_id is null))

) as t(check_no, label, ok)
order by check_no;
