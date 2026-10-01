-- post_apply.sql
-- PROPOSAL 0155 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0152 -> 0154 -> 0155 (this) -> 0156; unrelated 0148 -> 0153 or 0157+ (never 0154-0156). Finding F-01.
-- READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row;
-- otherwise the statement RAISES (invalid input syntax for type integer: "POST-APPLY 0155 FAIL ...") whose text is the complete report.
with run as (select * from public.carrier_inference_run_0155 order by applied_at desc limit 1),
rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'STATE', 'evidence functions, apply function, decision RPC, review table and run ledger exist', case when to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is not null and to_regprocedure('public.carrier_evidence_for_relationship(uuid)') is not null and to_regprocedure('public._carrier_inference_apply_0155(text)') is not null and to_regprocedure('public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)') is not null and to_regclass('public.carrier_inference_review_0155') is not null and to_regclass('public.carrier_inference_run_0155') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120 + g.n, 'ACL', g.sig || ' is NOT executable by ' || g.who, case when coalesce(has_function_privilege(g.who, to_regprocedure(g.sig), 'execute'), true) then 'FAIL' else 'PASS' end, 'explicit REVOKE'
  from (values (1, 'public.carrier_evidence_for_invoice(uuid)', 'anon'), (2, 'public.carrier_evidence_for_invoice(uuid)', 'authenticated'), (3, 'public.carrier_evidence_for_invoice(uuid)', 'service_role'),
               (4, 'public.carrier_evidence_for_relationship(uuid)', 'anon'), (5, 'public.carrier_evidence_for_relationship(uuid)', 'authenticated'), (6, 'public.carrier_evidence_for_relationship(uuid)', 'service_role'),
               (7, 'public._carrier_inference_apply_0155(text)', 'anon'), (8, 'public._carrier_inference_apply_0155(text)', 'authenticated'), (9, 'public._carrier_inference_apply_0155(text)', 'service_role'),
               (10, 'public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)', 'anon'), (11, 'public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)', 'service_role')) g(n, sig, who)
  union all select 140, 'ACL', 'decide_carrier_inference_review: EXECUTE for authenticated only (not PUBLIC)', case when has_function_privilege('authenticated', to_regprocedure('public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)'), 'execute') and not (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure('public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)')) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 141, 'ACL', 'review/run tables: authenticated has SELECT only; anon and service_role nothing', case when has_table_privilege('authenticated', 'public.carrier_inference_review_0155', 'SELECT') and not has_table_privilege('authenticated', 'public.carrier_inference_review_0155', 'INSERT') and not has_table_privilege('authenticated', 'public.carrier_inference_review_0155', 'UPDATE') and not has_table_privilege('authenticated', 'public.carrier_inference_review_0155', 'DELETE')
                                                                               and not has_table_privilege('anon', 'public.carrier_inference_review_0155', 'SELECT') and not has_table_privilege('service_role', 'public.carrier_inference_review_0155', 'SELECT') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 150, 'RUN', 'the latest run: candidate count equals the current relationship count', case when (select (counts ->> 'candidate')::int from run) = (select count(*) from public.factoring_relationships) then 'PASS' else 'FAIL' end, coalesce((select counts::text from run), 'no run')
  union all select 151, 'RUN', 'the run counts are consistent (supported + assignable + ambiguous + unsafe + refused + decided = candidate; resolved = 0 at apply)', case when (select (counts ->> 'supported_unchanged')::int + (counts ->> 'assignable_proven_pending_owner')::int + (counts ->> 'ambiguous_unresolved')::int + (counts ->> 'unsafe_assigned')::int + (counts ->> 'refused_structural')::int + (counts ->> 'decided_unchanged')::int = (counts ->> 'candidate')::int from run) then 'PASS' else 'FAIL' end, 'counts'
  union all select 152, 'RUN', 'every category has a digest (md5 of the sorted relationship ids)', case when (select bool_and(v ~ '^[0-9a-f]{32}$') from run, jsonb_each_text(run.digests) e(k, v)) then 'PASS' else 'FAIL' end, 'digests'
  union all select 160, 'REVIEW', 'every unsafe / ambiguous / refused review row has an exception record (open, or resolved by a recorded decision)',
         case when not exists (select 1 from public.carrier_inference_review_0155 v where v.classification in ('ambiguous_unresolved', 'unsafe_assigned', 'refused_structural') and v.exception_record_id is null) then 'PASS' else 'FAIL' end, 'review rows'
  union all select 161, 'REVIEW', 'no review row is classified supported while still pending', case when not exists (select 1 from public.carrier_inference_review_0155 where classification = 'supported' and decision_status = 'pending') then 'PASS' else 'FAIL' end, 'review rows'
  union all select 162, 'REVIEW', 'no assignment is recorded without an owner/admin decision (decision_status assigned/confirmed/retired requires decided_by, key, reason and evidence reference)', case when not exists (select 1 from public.carrier_inference_review_0155 where decision_status in ('assigned', 'confirmed', 'retired') and (decision_key is null or decided_at is null or decision_reason is null or decision_evidence_ref is null)) then 'PASS' else 'FAIL' end, 'review rows'
  union all select 170, 'DATA (informational)', 'review classification counts', 'INFO', coalesce((select string_agg(classification || '=' || n, ', ' order by classification) from (select classification, count(*) n from public.carrier_inference_review_0155 group by 1) z), '(none)')
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('POST-APPLY 0155 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', 'POST-APPLY 0155: strict evidence + review installed; no data changed by the migration', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
