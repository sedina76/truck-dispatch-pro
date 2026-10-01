-- post_apply.sql
-- PROPOSAL 0154 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0152 -> 0154 (this) -> 0155 -> 0156; unrelated 0148 -> 0153 or 0157+ (never 0154-0156).
-- READ-ONLY: ONE select statement over catalogs; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row; otherwise the
-- statement RAISES (invalid input syntax for type integer: "POST-APPLY 0154 FAIL ...") whose text is the complete report.
with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'STATE', 'exactly the two reviewed functions exist (no overload, no twin)', case when (select count(*) from pg_proc p where p.proname in ('record_unresolved_carrier_record', '_record_unresolved_carrier_record_trusted')) = 2 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'STATE', 'record_unresolved_carrier_record body is the reviewed 0154 replacement', case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')) = 'c7f9a4c2c34fc44639b2ee96cd348c4e' then 'PASS' else 'FAIL' end, 'md5'
  union all select 112, 'STATE', '_record_unresolved_carrier_record_trusted body is the reviewed 0154 definition', case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)')) = '37655d439bb9cef6225b6f65c1358a8b' then 'PASS' else 'FAIL' end, 'md5'
  union all select 113, 'STATE', 'both are SECURITY DEFINER; public one keeps search_path pg_catalog, public; trusted one is pg_catalog, pg_temp', case when (select bool_and(p.prosecdef) and bool_or(p.proconfig::text = '{"search_path=pg_catalog, public"}') and bool_or(p.proconfig::text = '{"search_path=pg_catalog, pg_temp"}') from pg_proc p where p.oid in (to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)'), to_regprocedure('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)'))) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120 + g.n, 'ACL', g.sig || ' is NOT executable by ' || g.who, case when (case g.who when 'PUBLIC' then coalesce((select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure(g.sig)), true)
                                                     else coalesce(has_function_privilege(g.who, to_regprocedure(g.sig), 'execute'), true) end) then 'FAIL' else 'PASS' end, 'explicit REVOKE; independent of default privileges'
  from (values (1, 'public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)', 'anon'), (2, 'public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)', 'authenticated'), (3, 'public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)', 'service_role'), (4, 'public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)', 'PUBLIC'), (5, 'public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)', 'anon'), (6, 'public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)', 'authenticated'), (7, 'public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)', 'service_role'), (8, 'public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)', 'PUBLIC')) g(n, sig, who)
  union all select 130, 'ACL', 'unresolved_carrier_records: authenticated has NO table-level UPDATE and no UPDATE on record_id/detail/organization_id; UPDATE on status/resolution columns only', case when not has_table_privilege('authenticated', 'public.unresolved_carrier_records', 'UPDATE') and not has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'record_id', 'UPDATE') and not has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'organization_id', 'UPDATE') and not has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'detail', 'UPDATE') and has_column_privilege('authenticated', 'public.unresolved_carrier_records', 'status', 'UPDATE') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 200, 'DATA', 'open exception rows (informational; compare with the preflight value: 0154 changes none)', 'INFO', (select count(*)::text from public.unresolved_carrier_records where status = 'unresolved')
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('POST-APPLY 0154 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', 'POST-APPLY 0154: F-05 closed: fail-closed body, owner-only functions', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
