-- preflight.sql
-- PROPOSAL 0156 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0154 -> 0155 -> 0156 (this); unrelated 0148 -> 0153 or 0157+. Finding F-08.
-- READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row;
-- otherwise the statement RAISES (invalid input syntax for type integer: "PREFLIGHT 0156 FAIL ...") whose text is the complete report.
with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'PRECONDITION', 'proposal 0155 is applied', case when to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is not null and to_regclass('public.carrier_inference_review_0155') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'PRECONDITION', 'exactly one submit_invoice_to_factor exists (no overload)', case when (select count(*) from pg_proc where proname = 'submit_invoice_to_factor') = 1 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 112, 'PRECONDITION', 'live submit_invoice_to_factor is the reviewed 0140 universal-rejection definition', case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)')) = 'd620bf87dcc57f377a14a0da44c4c607' then 'PASS' else 'FAIL' end, 'md5'
  union all select 113, 'PRECONDITION', 'approve_factoring_relationship_noa is the corrected 0140 version (finding F-07: the 0138/0139 versions are weaker or buggy)', case when position('v_doc_snapshot_file_name' in coalesce((select prosrc from pg_proc where oid = to_regprocedure('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)')), '')) > 0 then 'PASS' else 'FAIL' end, 'source marker'
  union all select 114, 'PRECONDITION', 'no 0156 object exists yet', case when to_regclass('public.factoring_submission_gate') is null and to_regclass('public.factored_invoice_carrier_snapshot_0156') is null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 115, 'PRECONDITION', 'classify_carrier_factoring_readiness exists', case when to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120, 'EXPOSURE (informational)', 'submit_invoice_to_factor EXECUTE: anon / authenticated / service_role / PUBLIC', 'INFO', has_function_privilege('anon', to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'), 'execute')::text || ' / ' || has_function_privilege('authenticated', to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'), 'execute')::text || ' / ' || has_function_privilege('service_role', to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'), 'execute')::text || ' / ' || (select (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))::text from pg_proc p where p.oid = to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'))
  union all select 121, 'DATA (informational)', 'factored_invoices rows (never modified by 0156)', 'INFO', (select count(*)::text from public.factored_invoices)
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('PREFLIGHT 0156 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', 'PREFLIGHT 0156: baseline is the reviewed 0140 definition and 0155 is applied', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
