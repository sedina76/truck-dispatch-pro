-- VERIFY_0161_POST_APPLY.sql -- READ-ONLY. Run after 0161. Expected: every row PASS.
select 'encryption key: no client role (anon / signed-in / service_role) can read it' as check,
       case when not has_function_privilege('anon', 'public.get_app_encryption_key(text)'::regprocedure, 'execute')
             and not has_function_privilege('authenticated', 'public.get_app_encryption_key(text)'::regprocedure, 'execute')
             and not has_function_privilege('service_role', 'public.get_app_encryption_key(text)'::regprocedure, 'execute')
            then 'PASS' else 'FAIL' end as result
union all
select 'signed out: no SECURITY DEFINER function callable except the RLS identity helpers',
       coalesce((select 'FAIL: ' || string_agg(p.oid::regprocedure::text, ', ')
                 from pg_proc p
                 where p.pronamespace = 'public'::regnamespace and p.prosecdef
                   and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
                   and p.proname not in ('current_org_id', 'current_role', 'has_role', 'is_platform_admin',
                                         'carrier_ids_authorized_for_current_user', 'carrier_ids_selectable_for_new_records')
                   and has_function_privilege('anon', p.oid, 'execute')), 'PASS')
union all
select 'server-only functions: not callable by signed-in users',
       case when not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                               and p.proname in ('verify_driver_portal_login', 'submit_driver_application', 'refresh_compliance_statuses', 'sync_time_based_exceptions')
                               and has_function_privilege('authenticated', p.oid, 'execute'))
            then 'PASS' else 'FAIL' end
union all
select 'app server keeps driver login + driver applications (service_role)',
       case when has_function_privilege('service_role', 'public.verify_driver_portal_login(text,text)'::regprocedure, 'execute')
             and exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'submit_driver_application' and has_function_privilege('service_role', oid, 'execute'))
            then 'PASS' else 'FAIL' end
union all
select 'signed-in app functions keep access (sample: deduct, reveal PII, signup, driver PIN)',
       case when has_function_privilege('authenticated', 'public.deduct_pending_advances_into_invoice(uuid)'::regprocedure, 'execute')
             and has_function_privilege('authenticated', 'public.reveal_driver_pii(uuid,text,text)'::regprocedure, 'execute')
             and has_function_privilege('authenticated', 'public.create_organization_with_owner(text,text)'::regprocedure, 'execute')
             and has_function_privilege('authenticated', 'public.set_driver_portal_pin(uuid,text,text)'::regprocedure, 'execute')
            then 'PASS' else 'FAIL' end
union all
select 'advance deductions check the caller''s organization',
       case when position('current_org_id' in (select prosrc from pg_proc where oid = 'public.deduct_pending_advances_into_invoice(uuid)'::regprocedure)) > 0
             and position('current_org_id' in (select prosrc from pg_proc where oid = 'public.deduct_pending_advances_into_settlement(uuid)'::regprocedure)) > 0
            then 'PASS' else 'FAIL' end;
