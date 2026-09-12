-- ============================================================================
-- 0132 POST-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No DO block, no transaction control, no RPC execution. Safe on production.
--
-- Run AFTER applying 0132_load_carrier_and_trailer_scope.sql.
-- Every row of the matrix must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'trailer_ownership_scope = (carrier, organization_shared, unresolved)',
      (select string_agg(e.enumlabel, ',' order by e.enumsortorder)
       from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
       where n.nspname='public' and t.typname='trailer_ownership_scope') = 'carrier,organization_shared,unresolved'),

  -- ---- loads columns (added, NOT backfilled by 0132) ----
  (2, 'loads.carrier_id is (uuid, nullable, no default)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads'
              and column_name='carrier_id' and data_type='uuid' and is_nullable='YES' and column_default is null)),
  (3, 'loads.carrier_id FK -> carriers(id) ON DELETE RESTRICT',
      exists (select 1 from pg_constraint c where c.conrelid='public.loads'::regclass and c.contype='f'
              and c.confrelid='public.carriers'::regclass and c.confdeltype='r'
              and (select array_agg(a.attname order by k.ord)
                   from unnest(c.conkey) with ordinality as k(attnum,ord)
                   join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum) = array['carrier_id']::name[])),
  (4, 'CHECK loads_carrier_resolution_values present',
      exists (select 1 from pg_constraint where conname='loads_carrier_resolution_values' and conrelid='public.loads'::regclass)),
  (5, 'loads.carrier_locked_at is (timestamptz, nullable)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads'
              and column_name='carrier_locked_at' and data_type='timestamp with time zone' and is_nullable='YES')),
  (6, '0132 did NOT backfill loads: every load has carrier_id / carrier_resolution / carrier_locked_at = NULL',
      not exists (select 1 from public.loads where carrier_id is not null or carrier_resolution is not null or carrier_locked_at is not null)),

  -- ---- trailers.ownership_scope (backfilled) ----
  (7, 'trailers.ownership_scope is (trailer_ownership_scope, NOT NULL)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='trailers'
              and column_name='ownership_scope' and udt_name='trailer_ownership_scope' and is_nullable='NO')),
  (8, 'CHECK trailers_ownership_scope_consistency present AND validated',
      exists (select 1 from pg_constraint where conname='trailers_ownership_scope_consistency'
              and conrelid='public.trailers'::regclass and contype='c' and convalidated)),
  (9, 'every trailer: carrier_id present <-> ownership_scope = carrier ; carrier_id NULL <-> ownership_scope = unresolved',
      not exists (select 1 from public.trailers
                  where (carrier_id is not null and ownership_scope <> 'carrier')
                     or (carrier_id is null and ownership_scope <> 'unresolved'))),
  (10, 'backfill produced ZERO organization_shared trailers',
      not exists (select 1 from public.trailers where ownership_scope = 'organization_shared')),
  (11, 'trigger trailers_derive_ownership_scope is BEFORE INSERT',
      exists (select 1 from pg_trigger where tgname='trailers_derive_ownership_scope' and tgrelid='public.trailers'::regclass
              and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT%')),

  -- ---- guards ----
  (12, 'trigger loads_guard_carrier_change is BEFORE INSERT OR UPDATE',
      exists (select 1 from pg_trigger where tgname='loads_guard_carrier_change' and tgrelid='public.loads'::regclass
              and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%')),
  (13, 'trigger dispatches_guard_carrier_scope is BEFORE INSERT OR UPDATE',
      exists (select 1 from pg_trigger where tgname='dispatches_guard_carrier_scope' and tgrelid='public.dispatches'::regclass
              and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE%')),
  (14, 'guard_load_carrier_change / guard_dispatch_carrier_scope / trailers_derive_ownership_scope are SECURITY DEFINER + pinned search_path',
      not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public'
                    and p.proname in ('guard_load_carrier_change','guard_dispatch_carrier_scope','trailers_derive_ownership_scope')
                    and (not p.prosecdef or array_to_string(coalesce(p.proconfig,'{}'::text[]),',') not like '%search_path=%'))),

  -- ---- untouched neighbours ----
  (15, '0055 dispatches_guard_org trigger still present',
      exists (select 1 from pg_trigger where tgname='dispatches_guard_org' and tgrelid='public.dispatches'::regclass and not tgisinternal)),
  (16, '0125 dispatches_assign_financial_controller trigger still present',
      exists (select 1 from pg_trigger where tgname='dispatches_assign_financial_controller' and tgrelid='public.dispatches'::regclass and not tgisinternal)),
  (17, 'auto_generate_invoice_from_delivered_load() body does NOT reference carrier_id',
      (select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) not ilike '%carrier_id%'),
  (18, '0130/0131 landmarks intact (carrier_remittance_profiles + carrier_brokers present)',
      to_regclass('public.carrier_remittance_profiles') is not null and to_regclass('public.carrier_brokers') is not null),

  -- ---- correction #5: financial-controller-on-unresolved invariant ----
  -- Enforced by guard_dispatch_carrier_scope() (write-time), NOT a CHECK
  -- constraint -- see migration 0132 section A2 for why a blanket CHECK is
  -- wrong once 0133 must represent a discovered historical conflict.
  (19, 'no load currently has carrier_resolution=unresolved AND a financial_dispatch_id (immediately after 0132, nothing has classified any load yet)',
      not exists (select 1 from public.loads where carrier_resolution = 'unresolved' and financial_dispatch_id is not null)),
  (20, 'guard_dispatch_carrier_scope() body actually locks the load row (FOR UPDATE) before evaluating carrier ownership -- the authoritative-locking correction',
      (select pg_get_functiondef(to_regprocedure('public.guard_dispatch_carrier_scope()'))) ilike '%for update%'),

  -- ---- correction #4: shared-trailer approval infrastructure ----
  (21, 'trailer_ownership_scope_audit exists, RLS on, EMPTY, no write policy for authenticated',
      to_regclass('public.trailer_ownership_scope_audit') is not null
      and (select relrowsecurity from pg_class where oid='public.trailer_ownership_scope_audit'::regclass)
      and (select count(*) from public.trailer_ownership_scope_audit) = 0
      and not exists (select 1 from pg_policies where schemaname='public' and tablename='trailer_ownership_scope_audit' and cmd in ('INSERT','UPDATE','DELETE','ALL'))),
  (22, 'approve_trailer_ownership_scope(...) exists, SECURITY DEFINER + pinned search_path, not PUBLIC-executable',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='approve_trailer_ownership_scope'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')
      and not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                       where n.nspname='public' and p.proname='approve_trailer_ownership_scope'
                         and has_function_privilege('public', p.oid, 'execute'))),
  (23, 'trigger trailers_guard_ownership_scope_change is BEFORE UPDATE, SECURITY DEFINER + pinned search_path',
      exists (select 1 from pg_trigger where tgname='trailers_guard_ownership_scope_change' and tgrelid='public.trailers'::regclass
              and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE UPDATE%')
      and exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public' and p.proname='guard_trailer_ownership_scope_change'
                    and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%'))

) as t(check_no, label, ok)
order by check_no;

-- Context: the ownership_scope distribution after backfill.
select ownership_scope, count(*) as n from public.trailers group by ownership_scope order by ownership_scope;
