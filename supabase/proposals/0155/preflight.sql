-- preflight.sql
-- PROPOSAL 0155 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0152 -> 0154 -> 0155 (this) -> 0156; unrelated 0148 -> 0153 or 0157+ (never 0154-0156). Finding F-01.
-- READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row;
-- otherwise the statement RAISES (invalid input syntax for type integer: "PREFLIGHT 0155 FAIL ...") whose text is the complete report.
with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'PRECONDITION', 'proposal 0154 is applied (owner-only exception writer present, fail-closed public function)', case when to_regprocedure('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)') is not null and (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')) = 'c7f9a4c2c34fc44639b2ee96cd348c4e' then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'PRECONDITION', '0137 provenance table exists', case when to_regclass('public.carrier_backfill_0137_provenance') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 112, 'PRECONDITION', 'factoring_relationships.carrier_id and carriers.is_active exist', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'factoring_relationships' and column_name = 'carrier_id') and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'carriers' and column_name = 'is_active') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 113, 'PRECONDITION', 'no 0155 object exists yet', case when to_regclass('public.carrier_inference_review_0155') is null and to_regclass('public.carrier_inference_run_0155') is null and to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is null and to_regprocedure('public.carrier_evidence_for_relationship(uuid)') is null and to_regprocedure('public._carrier_inference_apply_0155(text)') is null and to_regprocedure('public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)') is null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120, 'DATA (informational)', 'factoring_relationships total / with carrier_id / without carrier_id', 'INFO', (select count(*)::text || ' / ' || count(carrier_id)::text || ' / ' || (count(*) - count(carrier_id))::text from public.factoring_relationships)
  union all select 121, 'DATA (informational)', 'factored_invoices total', 'INFO', (select count(*)::text from public.factored_invoices)
  union all select 122, 'DATA (informational)', 'organizations whose ONLY carrier is inactive (0137 rule R1 would have assigned it; finding F-02)', 'INFO', (select count(*)::text from (select organization_id from public.carriers group by organization_id having count(*) = 1 and bool_and(not is_active)) x)
  union all select 123, 'DATA (informational)', 'open exception rows for factoring_relationship', 'INFO', (select count(*)::text from public.unresolved_carrier_records where record_type = 'factoring_relationship' and status = 'unresolved')
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('PREFLIGHT 0155 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', 'PREFLIGHT 0155: 0154 is applied and no 0155 object exists', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
