-- ============================================================================
-- 0134 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0134. Every row must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- trailer column privileges (item A) ----
  (1, 'authenticated has NO UPDATE on trailers.id',
      not has_column_privilege('authenticated','public.trailers','id','UPDATE')),
  (2, 'authenticated has NO UPDATE on trailers.organization_id',
      not has_column_privilege('authenticated','public.trailers','organization_id','UPDATE')),
  (3, 'authenticated has NO UPDATE on trailers.created_at',
      not has_column_privilege('authenticated','public.trailers','created_at','UPDATE')),
  (4, 'authenticated has NO UPDATE on trailers.updated_at',
      not has_column_privilege('authenticated','public.trailers','updated_at','UPDATE')),
  (5, 'authenticated has NO UPDATE on trailers.carrier_id',
      not has_column_privilege('authenticated','public.trailers','carrier_id','UPDATE')),
  (6, 'authenticated has NO UPDATE on trailers.ownership_scope',
      not has_column_privilege('authenticated','public.trailers','ownership_scope','UPDATE')),
  (7, 'authenticated HAS UPDATE on every one of the 11 permitted columns',
      (select count(*) from information_schema.column_privileges
       where table_schema='public' and table_name='trailers' and grantee='authenticated' and privilege_type='UPDATE'
         and column_name in ('unit_number','vin','trailer_type','length_ft','license_plate','license_state',
                              'ownership_type','status','registration_expiry_date','annual_inspection_expiry_date','notes')) = 11),
  (8, 'authenticated has EXACTLY 11 UPDATE-grantable trailers columns (nothing extra)',
      (select count(*) from information_schema.column_privileges
       where table_schema='public' and table_name='trailers' and grantee='authenticated' and privilege_type='UPDATE') = 11),
  (9, 'authenticated holds NO table-level UPDATE grant on trailers',
      not has_table_privilege('authenticated','public.trailers','UPDATE')),

  -- ---- RPC + matrix + ledger (items B/C/D) ----
  (10, 'function public.transition_dispatch_status(...) present, SECURITY DEFINER, pinned search_path',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='transition_dispatch_status'
                and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=%')),
  (11, 'authenticated holds EXECUTE on transition_dispatch_status(...)',
      has_function_privilege('authenticated','public.transition_dispatch_status(uuid,public.dispatch_status,text,text)','EXECUTE')),
  (12, 'function public.is_valid_dispatch_status_transition(...) present',
      to_regprocedure('public.is_valid_dispatch_status_transition(public.dispatch_status,public.dispatch_status)') is not null),
  (13, 'matrix: cancelled -> assigned permitted (the one reactivation shape)',
      public.is_valid_dispatch_status_transition('cancelled','assigned')),
  (14, 'matrix: cancelled -> anything else is NOT permitted',
      not exists (select 1 from unnest(enum_range(null::public.dispatch_status)) s(v)
                  where v <> 'assigned' and v <> 'cancelled'
                    and public.is_valid_dispatch_status_transition('cancelled', v))),
  (15, 'matrix: completed is terminal (no outbound transition except cancelled, which cancel_dispatch() itself will reject)',
      not exists (select 1 from unnest(enum_range(null::public.dispatch_status)) s(v)
                  where v <> 'completed' and v <> 'cancelled'
                    and public.is_valid_dispatch_status_transition('completed', v))),
  (16, 'table public.dispatch_status_transitions present, RLS on, no client write policy, no table-level write grant',
      to_regclass('public.dispatch_status_transitions') is not null
      and (select relrowsecurity from pg_class where oid = 'public.dispatch_status_transitions'::regclass)
      and not exists (select 1 from pg_policies where schemaname='public' and tablename='dispatch_status_transitions' and cmd in ('INSERT','UPDATE','DELETE','ALL'))
      and not exists (select 1 from information_schema.role_table_grants
                       where table_schema='public' and table_name='dispatch_status_transitions'
                         and grantee='authenticated' and privilege_type in ('INSERT','UPDATE','DELETE'))),

  -- ---- untouched: 0129/0132 functions/triggers still present and unmodified in shape ----
  (17, '0129 cancel_dispatch(uuid,text) still present',
      to_regprocedure('public.cancel_dispatch(uuid,text)') is not null),
  (18, '0132 guard_dispatch_carrier_scope trigger still present on dispatches',
      exists (select 1 from pg_trigger where tgname='dispatches_guard_carrier_scope' and tgrelid='public.dispatches'::regclass and not tgisinternal))

) as t(check_no, label, ok)
order by check_no;
