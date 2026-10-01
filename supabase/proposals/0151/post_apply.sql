-- =============================================================================
-- post_apply.sql
-- PROPOSAL 0151 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 (enum repair) -> 0150 (zero-evidence loads) -> 0151 (this). Current proposal 0148 is unrelated and MUST be
-- renumbered to 0153 or higher before promotion.
--
-- Run AFTER applying 0151 (and any time later). READ-ONLY: ONE select statement. RESULT: rows INFO/PASS + a final RESULT | PASS row, or a
-- raised error ("POST-APPLY 0151 FAIL ...") whose text is the complete report.
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
  union all select 200, 'BODY', 'live body is the reviewed 0151 definition',
         case when (select body_md5 from f) = '7d56b97529af95eece84b2f0dab2e83c' then 'PASS' else 'FAIL' end, coalesce((select body_md5 from f), 'MISSING')
  union all select 201, 'BODY', 'authorization precedes the ledger read: dispatch-org check, role gate, then the ledger lookup (source order)',
         case when (select position('tsdnf' in norm) > 0 and position('tsdnf' in norm) < position('frompublic.dispatch_status_transitionst' in norm)
                          and position('has_role(array[''owner'',''admin'',''dispatcher'']' in norm) > 0
                          and position('has_role(array[''owner'',''admin'',''dispatcher'']' in norm) < position('frompublic.dispatch_status_transitionst' in norm)
                    from f) then 'PASS' else 'FAIL' end, 'source order'
  union all select 202, 'BODY', 'ledger lookups are organization-scoped and status-bound (organization_id = v_org; TSIDK present)',
         case when (select position('t.organization_id=v_org' in norm) > 0 and position('tsidk' in norm) > 0 from f) then 'PASS' else 'FAIL' end, 'source'
  union all select 203, 'BODY', 'exactly two organization-scoped ledger reads (pre-lock and under the locks) and no unscoped ledger read',
         case when (select (length(norm) - length(replace(norm, 'frompublic.dispatch_status_transitionst', ''))) / length('frompublic.dispatch_status_transitionst') from f) = 2
                   and (select (length(norm) - length(replace(norm, 't.organization_id=v_org', ''))) / length('t.organization_id=v_org') from f) = 2 then 'PASS' else 'FAIL' end, 'source'
  union all select 300, 'LEDGER', 'ledger rows (0151 never writes them)', 'INFO', (select count(*) from public.dispatch_status_transitions)::text
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('POST-APPLY 0151 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate   -- a deliberate cast error: raises only when a check fails
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', 'POST-APPLY 0151: transition_dispatch_status() authorizes before any replay', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
