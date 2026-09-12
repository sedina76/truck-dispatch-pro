-- ============================================================================
-- 0135 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0135. Every row must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- dispatches column privileges (item 4) ----
  (1, 'authenticated holds NO table-level UPDATE grant on dispatches',
      not has_table_privilege('authenticated','public.dispatches','UPDATE')),
  (2, 'authenticated has NO UPDATE on dispatches.carrier_id',
      not has_column_privilege('authenticated','public.dispatches','carrier_id','UPDATE')),
  (3, 'authenticated has NO UPDATE on dispatches.load_id',
      not has_column_privilege('authenticated','public.dispatches','load_id','UPDATE')),
  (4, 'authenticated has NO UPDATE on dispatches.driver_id',
      not has_column_privilege('authenticated','public.dispatches','driver_id','UPDATE')),
  (5, 'authenticated has NO UPDATE on dispatches.truck_id',
      not has_column_privilege('authenticated','public.dispatches','truck_id','UPDATE')),
  (6, 'authenticated has NO UPDATE on dispatches.trailer_id',
      not has_column_privilege('authenticated','public.dispatches','trailer_id','UPDATE')),
  (7, 'authenticated has NO UPDATE on dispatches.status',
      not has_column_privilege('authenticated','public.dispatches','status','UPDATE')),
  (8, 'authenticated HAS UPDATE on dispatches.notes',
      has_column_privilege('authenticated','public.dispatches','notes','UPDATE')),
  (9, 'authenticated has EXACTLY 1 UPDATE-grantable dispatches column (notes)',
      (select count(*) from information_schema.column_privileges
       where table_schema='public' and table_name='dispatches' and grantee='authenticated' and privilege_type='UPDATE') = 1),

  -- ---- RPC + ledger (items 1-2) ----
  (10, 'function public.reassign_dispatch_resources(...) present, SECURITY DEFINER, pinned search_path',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='reassign_dispatch_resources'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')),
  (11, 'authenticated holds EXECUTE on reassign_dispatch_resources(...)',
      has_function_privilege('authenticated','public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)','EXECUTE')),
  (12, 'table public.dispatch_resource_reassignments present, RLS on, no client write policy, no table-level write grant',
      to_regclass('public.dispatch_resource_reassignments') is not null
      and (select relrowsecurity from pg_class where oid = 'public.dispatch_resource_reassignments'::regclass)
      and not exists (select 1 from pg_policies where schemaname='public' and tablename='dispatch_resource_reassignments' and cmd in ('INSERT','UPDATE','DELETE','ALL'))
      and not exists (select 1 from information_schema.role_table_grants
                       where table_schema='public' and table_name='dispatch_resource_reassignments'
                         and grantee='authenticated' and privilege_type in ('INSERT','UPDATE','DELETE'))),

  -- ---- Phase 3A.3, item 4: ledger carries carrier_id/load_id, both NOT NULL ----
  (12.1, 'dispatch_resource_reassignments.carrier_id present and NOT NULL',
      exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='dispatch_resource_reassignments'
                and column_name='carrier_id' and is_nullable='NO')),
  (12.2, 'dispatch_resource_reassignments.load_id present and NOT NULL',
      exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='dispatch_resource_reassignments'
                and column_name='load_id' and is_nullable='NO')),
  (12.3, 'dispatch_resource_reassignments is empty immediately post-apply (this migration writes no rows)',
      (select count(*) from public.dispatch_resource_reassignments) = 0),

  -- ---- untouched: 0055/0129/0132/0134 functions/triggers still present ----
  (13, '0055 guard_dispatch_org trigger still present on dispatches',
      exists (select 1 from pg_trigger where tgname='dispatches_guard_org' and tgrelid='public.dispatches'::regclass and not tgisinternal)),
  (14, '0129 cancel_dispatch(uuid,text) still present',
      to_regprocedure('public.cancel_dispatch(uuid,text)') is not null),
  (15, '0132 guard_dispatch_carrier_scope trigger still present on dispatches',
      exists (select 1 from pg_trigger where tgname='dispatches_guard_carrier_scope' and tgrelid='public.dispatches'::regclass and not tgisinternal)),
  (16, '0134 transition_dispatch_status(...) still present',
      to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is not null),

  -- ---- global invariant this migration protects: no dispatch's carrier
  -- disagrees with its load's carrier anywhere (this migration writes no
  -- data, so this should already hold from 0132/0133 -- reconfirmed here as
  -- a belt-and-braces check specific to this migration's own concern) ----
  (17, 'GLOBAL: no non-cancelled dispatch carrier disagrees with its load carrier',
      not exists (
        select 1 from public.loads l
        join public.dispatches d on d.load_id = l.id and d.status <> 'cancelled'
        where l.carrier_id is not null and d.carrier_id <> l.carrier_id))

) as t(check_no, label, ok)
order by check_no;
