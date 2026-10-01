-- post_apply.sql
-- PROPOSAL 0156 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0154 -> 0155 -> 0156 (this); unrelated 0148 -> 0153 or 0157+. Finding F-08.
-- READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row;
-- otherwise the statement RAISES (invalid input syntax for type integer: "POST-APPLY 0156 FAIL ...") whose text is the complete report.
with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'STATE', 'gate table has exactly one row', case when (select count(*) from public.factoring_submission_gate) = 1 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'STATE', 'gate is DISABLED as applied (INFO if the Owner has since enabled it with a decision reference)', case when (select enabled from public.factoring_submission_gate) then case when (select decision_ref from public.factoring_submission_gate) is not null then 'INFO' else 'FAIL' end else 'PASS' end, coalesce((select enabled::text || ' / ' || coalesce(decision_ref, '-') from public.factoring_submission_gate), 'no row')
  union all select 112, 'STATE', 'submit_invoice_to_factor is SECURITY DEFINER with search_path pg_catalog, pg_temp and returns jsonb', case when (select p.prosecdef and p.proconfig::text = '{"search_path=pg_catalog, pg_temp"}' and p.prorettype = 'jsonb'::regtype from pg_proc p where p.oid = to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)')) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 113, 'STATE', 'exactly one submit_invoice_to_factor exists', case when (select count(*) from pg_proc where proname = 'submit_invoice_to_factor') = 1 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120, 'ACL', 'submit_invoice_to_factor: EXECUTE for authenticated only (not anon, service_role, PUBLIC)', case when has_function_privilege('authenticated', to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'), 'execute') and not has_function_privilege('anon', to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'), 'execute') and not has_function_privilege('service_role', to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'), 'execute')
                                                                                           and not (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)')) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 121, 'ACL', 'gate table: no privilege for anon, authenticated or service_role', case when not has_table_privilege('anon', 'public.factoring_submission_gate', 'SELECT') and not has_table_privilege('authenticated', 'public.factoring_submission_gate', 'SELECT') and not has_table_privilege('service_role', 'public.factoring_submission_gate', 'SELECT') and not has_table_privilege('authenticated', 'public.factoring_submission_gate', 'UPDATE') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 122, 'ACL', 'snapshot table: authenticated SELECT only (RLS); no write for any client role', case when has_table_privilege('authenticated', 'public.factored_invoice_carrier_snapshot_0156', 'SELECT') and not has_table_privilege('authenticated', 'public.factored_invoice_carrier_snapshot_0156', 'INSERT') and not has_table_privilege('authenticated', 'public.factored_invoice_carrier_snapshot_0156', 'UPDATE') and not has_table_privilege('service_role', 'public.factored_invoice_carrier_snapshot_0156', 'INSERT') and not has_table_privilege('anon', 'public.factored_invoice_carrier_snapshot_0156', 'SELECT') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 123, 'STATE', 'the snapshot table is immutable (update/delete trigger present)', case when exists (select 1 from pg_trigger where tgrelid = 'public.factored_invoice_carrier_snapshot_0156'::regclass and tgname = 'factored_invoice_carrier_snapshot_0156_immutable' and not tgisinternal) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 130, 'DATA (informational)', 'factored_invoices / snapshot rows', 'INFO', (select count(*)::text from public.factored_invoices) || ' / ' || (select count(*)::text from public.factored_invoice_carrier_snapshot_0156)
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('POST-APPLY 0156 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', 'POST-APPLY 0156: F-08 candidate installed; gate state as recorded', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
