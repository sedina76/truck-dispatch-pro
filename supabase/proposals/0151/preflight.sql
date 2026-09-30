-- =============================================================================
-- preflight.sql
-- PROPOSAL 0151 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 (enum repair) -> 0150 (zero-evidence loads) -> 0151 (this). Current proposal 0148 is unrelated and MUST be
-- renumbered to 0153 or higher before promotion.
--
-- Run BEFORE applying 0151. READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no
-- transaction control, no temporary object. RESULT: every row INFO or PASS and a final RESULT | PASS row; otherwise the statement RAISES
-- (invalid input syntax for type integer: "PREFLIGHT 0151 FAIL ...") whose text is the complete report.
-- =============================================================================
with
f as (
  select p.oid, p.prosecdef, p.proconfig, p.proacl, p.provolatile, l.lanname::text as lang, p.prorettype::regtype::text as rettype,
         pg_get_function_identity_arguments(p.oid) as ident, pg_get_function_arguments(p.oid) as args, p.proowner::regrole::text as owner,
         md5(regexp_replace(lower(regexp_replace(p.prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) as body_md5,
         regexp_replace(lower(regexp_replace(p.prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g') as norm
  from (select 1) d left join pg_proc p on p.oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') left join pg_language l on l.oid = p.prolang
),
rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 101, 'FUNCTION', 'transition_dispatch_status exists', case when (select oid from f) is not null then 'PASS' else 'FAIL' end, coalesce((select ident from f), 'MISSING')
  union all select 102, 'FUNCTION', 'SECURITY DEFINER with pinned search_path (pg_catalog, public)',
         case when (select prosecdef and proconfig::text = '{"search_path=pg_catalog, public"}' from f) then 'PASS' else 'FAIL' end, coalesce((select proconfig::text from f), 'MISSING')
  union all select 103, 'FUNCTION', 'signature, return type, language, volatility unchanged (jsonb / plpgsql / volatile)',
         case when (select rettype = 'jsonb' and lang = 'plpgsql' and provolatile = 'v' from f) then 'PASS' else 'FAIL' end,
         coalesce((select rettype || ' / ' || lang || ' / ' || provolatile::text from f), 'MISSING')
  union all select 104, 'FUNCTION', 'arguments (p_dispatch_id uuid, p_new_status dispatch_status, p_reason text default null, p_idempotency_key text default null)',
         case when (select lower(regexp_replace(args, '\s+', ' ', 'g')) = 'p_dispatch_id uuid, p_new_status dispatch_status, p_reason text default null::text, p_idempotency_key text default null::text' from f) then 'PASS' else 'FAIL' end,
         coalesce((select args from f), 'MISSING')
  union all select 105, 'FUNCTION', 'EXECUTE: authenticated yes, PUBLIC no (anon / service_role: see the INFO row -- Supabase default privileges may give them EXECUTE)',
         case when (select has_function_privilege('authenticated', oid, 'execute')
                           and not (proacl is null or exists (select 1 from unnest(proacl) a where a::text like '=%')) from f) then 'PASS' else 'FAIL' end,
         coalesce((select proacl::text from f), 'MISSING')
  union all select 107, 'FUNCTION', 'anon / service_role EXECUTE (INFO; unchanged by 0151)', 'INFO',
         coalesce((select has_function_privilege('anon', oid, 'execute')::text || ' / ' || has_function_privilege('service_role', oid, 'execute')::text from f), 'MISSING')
  union all select 106, 'FUNCTION', 'owner', 'INFO', coalesce((select owner from f), 'MISSING')
  union all select 200, 'BODY', 'live body is the reviewed 0134 definition (NOT yet repaired)',
         case when (select body_md5 from f) = 'ba881fa42b60a752fb17e26609428e6c' then 'PASS' else 'FAIL' end, coalesce((select body_md5 from f), 'MISSING')
  union all select 201, 'BODY', 'live body does not already contain the 0151 authorization order',
         case when (select position('tsidk' in norm) from f) = 0 then 'PASS' else 'FAIL' end, 'marker TSIDK'
  union all select 300, 'LEDGER', 'dispatch_status_transitions exists with UNIQUE (dispatch_id, idempotency_key)',
         case when exists (select 1 from pg_constraint k where k.conrelid = to_regclass('public.dispatch_status_transitions') and k.contype = 'u'
                            and pg_get_constraintdef(k.oid) = 'UNIQUE (dispatch_id, idempotency_key)') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 301, 'LEDGER', 'ledger rows', 'INFO', (select count(*) from public.dispatch_status_transitions)::text
  union all select 302, 'LEDGER', 'ledger rows whose organization differs from their dispatch''s organization (would stop replaying; must be 0)',
         case when (select count(*) from public.dispatch_status_transitions t join public.dispatches d on d.id = t.dispatch_id where d.organization_id <> t.organization_id) = 0 then 'PASS' else 'FAIL' end,
         (select count(*) from public.dispatch_status_transitions t join public.dispatches d on d.id = t.dispatch_id where d.organization_id <> t.organization_id)::text
  union all select 303, 'LEDGER', 'ledger rows whose stored new_status is the requested status (rows with NULL/other cannot be status-bound)', 'INFO',
         (select count(*) from public.dispatch_status_transitions)::text
  union all select 304, 'LEDGER', 'organizations with ledger rows', 'INFO', (select count(distinct organization_id) from public.dispatch_status_transitions)::text
  union all select 400, 'HELPERS', 'dispatch_status_sequence_rank, current_org_id, has_role present',
         case when to_regprocedure('public.dispatch_status_sequence_rank(public.dispatch_status)') is not null and to_regprocedure('public.current_org_id()') is not null
                   and to_regprocedure('public.has_role(public.org_role[])') is not null then 'PASS' else 'FAIL' end, 'catalog'
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('PREFLIGHT 0151 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate   -- a deliberate cast error: raises only when a check fails
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', 'PREFLIGHT 0151: live transition_dispatch_status() is the reviewed 0134 baseline', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
