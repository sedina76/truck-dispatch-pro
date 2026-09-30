#!/usr/bin/env python3
"""Proposal 0151 generator. NOT APPROVED FOR PRODUCTION.

Derives the repaired public.transition_dispatch_status() from the AUTHORITATIVE 0134 text by anchored, asserted
edits (so the semantic diff is exactly the edits below and nothing else), and writes proposed_0151.sql, preflight.sql,
post_apply.sql, rollback.sql and function_diff.patch.

    python3 build.py           # (re)write the generated files
    python3 build.py --check   # exit 1 if any generated file is stale
"""
import difflib
import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
SRC = SUPA / "migrations" / "0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql"
HEADER = "create or replace function public.transition_dispatch_status("
SIG = "public.transition_dispatch_status(uuid,public.dispatch_status,text,text)"


def norm(body):
    return re.sub(r"\s+", "", re.sub(r"--[^\n]*", "", body).lower())


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def q(s):
    return "'" + s.replace("'", "''") + "'"


def old_block():
    t = SRC.read_text()
    a = t.index(HEADER)
    b = t.index("$fn$;", t.index("$fn$", a) + 4) + len("$fn$;")
    blk = t[a:b]
    assert blk.count("$fn$") == 2
    return blk


def replay_snippet(where):
    return f"""  if p_idempotency_key is not null then
    select t.old_status, t.new_status, t.result into v_cached_old, v_cached_new, v_cached
    from public.dispatch_status_transitions t
    where t.dispatch_id = p_dispatch_id and t.idempotency_key = p_idempotency_key and t.organization_id = v_org;
    if found then
      -- ({where}) the key is bound to the ORIGINAL request: a different requested status is a client bug, never a silent stale result.
      if v_cached_new is distinct from p_new_status then
        raise exception 'transition_dispatch_status: this idempotency key was already used for a different request.' using errcode = 'TSIDK';
      end if;
      -- A replay never grants more than the original operation needed: replaying a reactivation or a backward correction
      -- requires CURRENT owner/admin authority, exactly as performing it does.
      if (v_cached_old = 'cancelled' and v_cached_new <> 'cancelled')
         or (public.dispatch_status_sequence_rank(v_cached_old) is not null and public.dispatch_status_sequence_rank(v_cached_new) is not null
             and public.dispatch_status_sequence_rank(v_cached_new) < public.dispatch_status_sequence_rank(v_cached_old)) then
        if not public.has_role(array['owner','admin']::public.org_role[]) then
          raise exception 'transition_dispatch_status: replaying a reactivation or a backward correction requires owner/admin authority.' using errcode = 'TSROL';
        end if;
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;
"""


def new_block():
    blk = old_block()

    # A1 declarations
    a1 = "  v_cached jsonb;\n"
    assert blk.count(a1) == 1
    blk = blk.replace(a1, a1 + "  v_cached_old public.dispatch_status;\n  v_cached_new public.dispatch_status;\n")

    # A2 (ledger short-circuit) -> authenticated + org-verified + role-gated BEFORE any ledger read
    s = blk.index("  -- Idempotency short-circuit -- BEFORE any lock, any validation, any")
    e = blk.index("  -- Resolve dispatch -> load_id WITHOUT locking yet")
    old_a2 = blk[s:e]
    assert "from public.dispatch_status_transitions" in old_a2 and old_a2.count("return v_cached") == 1
    new_a2 = """  -- 0151: AUTHORIZATION BEFORE ANY LEDGER READ. Order: authenticated (above) -> caller has an organization (above)
  -- -> the target dispatch belongs to THAT organization (else exactly the same TSDNF a missing dispatch gets, so neither a
  -- foreign dispatch nor a foreign idempotency key is ever confirmed) -> the caller CURRENTLY holds an allowed role.
  -- Only then is the replay ledger consulted (org-scoped, key bound to the original requested status).
  select organization_id, load_id into v_dispatch_org, v_load_id
  from public.dispatches where id = p_dispatch_id;
  if v_dispatch_org is null or v_dispatch_org <> v_org then
    -- cross-tenant reported identically to "not found" -- never confirm
    -- existence of another organization's row.
    raise exception 'transition_dispatch_status: dispatch % not found.', p_dispatch_id using errcode = 'TSDNF';
  end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'transition_dispatch_status: only an owner, admin, or dispatcher may change dispatch status.' using errcode = 'TSROL';
  end if;

  -- Idempotency short-circuit -- AFTER authorization, BEFORE any lock, validation or write. A retried call with the SAME
  -- (dispatch_id, idempotency_key) in the caller's organization replays the ORIGINAL cached result verbatim, never
  -- re-validating against however the row looks now.
""" + replay_snippet("pre-lock")
    blk = blk[:s] + new_a2 + "\n" + blk[e:]

    # A3 old resolve block removed (moved above the ledger read)
    s = blk.index("  -- Resolve dispatch -> load_id WITHOUT locking yet")
    e = blk.index("  -- ===== STEP 1: LOCK THE LOAD FIRST")
    old_a3 = blk[s:e]
    assert "TSDNF" in old_a3 and "from public.dispatches where id = p_dispatch_id" in old_a3
    blk = blk[:s] + "  -- (the dispatch's organization and load_id were resolved and verified above, before any ledger read)\n\n" + blk[e:]

    # A4 post-lock re-check: a concurrent duplicate that queued behind the winner replays the winner's result
    a4 = """  select status, carrier_id into v_old_status, v_dispatch_carrier
  from public.dispatches where id = p_dispatch_id for update;
"""
    assert blk.count(a4) == 1
    blk = blk.replace(a4, a4 + """
  -- 0151: re-check the ledger UNDER the locks. Two concurrent identical requests both miss the pre-lock lookup; the loser waits
  -- on the load/dispatch lock here and must then replay the winner's committed result (same authorization, same rules) rather
  -- than re-evaluating against the moved row.
""" + replay_snippet("post-lock"))
    return blk


def file_header(title):
    return f"""-- =============================================================================
-- {title}
-- PROPOSAL 0151 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 (enum repair) -> 0150 (zero-evidence loads) -> 0151 (this). Current proposal 0148 is unrelated and MUST be
-- renumbered to 0153 or higher before promotion."""


PROPS = """
    coalesce(p.prosecdef::text, 'MISSING') as secdef,
    coalesce(p.proconfig::text, '(none)') as config,
    coalesce(l.lanname::text, 'MISSING') as lang,
    coalesce(p.prorettype::regtype::text, 'MISSING') as rettype,
    coalesce(p.provolatile::text, 'MISSING') as vol,
    coalesce(pg_get_function_identity_arguments(p.oid), 'MISSING') as ident,
    coalesce(pg_get_function_arguments(p.oid), 'MISSING') as args"""


def proposed():
    old, new = old_block(), new_block()
    return f"""{file_header("proposed_0151.sql -- BLOCKER F1-R1: authorize BEFORE any idempotency replay in transition_dispatch_status()")}
--
-- DEFECT (0134): the ledger was read after only `auth.uid() IS NOT NULL` and `current_org_id() IS NOT NULL`, keyed by
-- (dispatch_id, idempotency_key) with NO organization or role check. A caller from ANY organization (any role) who knew a
-- foreign dispatch UUID and its key received that dispatch's cached result, and a caller whose role had been downgraded still
-- received cached results. The same call with a different requested status silently returned the stale result.
--
-- FIX (function body only; no schema change, no data change, signature/SECURITY DEFINER/search_path/ACL/comment untouched):
--   1. authenticated + has an organization (unchanged)  2. dispatch belongs to the caller's organization, else the SAME TSDNF as
--   "not found"  3. caller CURRENTLY holds owner/admin/dispatcher (else TSROL)  4. ONLY THEN the ledger lookup, scoped by
--   organization_id + dispatch_id + key, bound to the original requested status (mismatch -> TSIDK), replays of a reactivation /
--   backward correction still require owner/admin  5. a second ledger check under the load+dispatch locks so a concurrent
--   duplicate replays the winner's result. All transition, cancellation, audit and rollback semantics are unchanged.
-- POLICY: a DIFFERENT authorized owner/admin/dispatcher of the same organization may replay a cached result (the ledger row is
-- organization data they can already read); actor is NOT bound. Cross-organization, unauthorized-role and mismatched-request
-- replays are all refused.
-- =============================================================================
begin;

-- ======================= PHASE 1 -- PRECONDITIONS ==============================
do $mig$
declare
  v_md5 text;
begin
  if to_regprocedure({q(SIG)}) is null then raise exception '0151 precondition: transition_dispatch_status(...) missing -- apply 0134 first. STOP.'; end if;
  if to_regclass('public.dispatch_status_transitions') is null then raise exception '0151 precondition: the idempotency ledger is missing. STOP.'; end if;
  if to_regprocedure('public.dispatch_status_sequence_rank(public.dispatch_status)') is null
     or to_regprocedure('public.current_org_id()') is null or to_regprocedure('public.has_role(public.org_role[])') is null then
    raise exception '0151 precondition: a helper function is missing. STOP.';
  end if;
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure({q(SIG)});
  if v_md5 is distinct from {q(md5(norm(old_block().split("$fn$")[1])))} then
    raise exception '0151 precondition: the live transition_dispatch_status() is not the reviewed 0134 definition (md5 %) -- already repaired, or drifted. STOP.', v_md5;
  end if;
  if not (select p.prosecdef and p.proconfig::text = '{{"search_path=pg_catalog, public"}}' from pg_proc p where p.oid = to_regprocedure({q(SIG)})) then
    raise exception '0151 precondition: transition_dispatch_status() is not SECURITY DEFINER with the pinned search_path. STOP.';
  end if;

  -- snapshots (dropped at commit) for the Phase 3 "nothing else changed" proofs
  create temp table _mig0151_funcs on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config,
           p.prosecdef, p.proowner, p.prorettype, p.provolatile, pg_get_function_arguments(p.oid) as args, coalesce(obj_description(p.oid, 'pg_proc'), '') as descr
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
  create temp table _mig0151_misc on commit drop as
    select (select count(*) from public.dispatch_status_transitions) as n_ledger,
           (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.dispatch_status_transitions t) as ledger_md5,
           has_function_privilege('authenticated', {q(SIG)}, 'execute') as priv_auth, has_function_privilege('anon', {q(SIG)}, 'execute') as priv_anon,
           has_function_privilege('service_role', {q(SIG)}, 'execute') as priv_svc, (select (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure({q(SIG)})) as priv_pub;
  raise notice '0151 PHASE 1 passed.';
end
$mig$;

-- ======================= PHASE 2 -- THE ONE FUNCTION ===========================
{new}

-- ======================= PHASE 3 -- POSTCONDITIONS =============================
do $mig$
declare
  v_new text := {q(md5(norm(new.split("$fn$")[1])))};
  v_md5 text;
  v_bad integer;
  m record;
begin
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure({q(SIG)});
  if v_md5 is distinct from v_new then raise exception '0151 postcondition: live body md5 % <> expected %.', v_md5, v_new; end if;

  -- exactly one public function body changed (this one); every property of every function (owner, ACL, config, args, return, volatility, comment, SECURITY DEFINER) identical
  create temp table _mig0151_after on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config,
           p.prosecdef, p.proowner, p.prorettype, p.provolatile, pg_get_function_arguments(p.oid) as args, coalesce(obj_description(p.oid, 'pg_proc'), '') as descr
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
  select count(*) into v_bad from _mig0151_funcs o full join _mig0151_after n using (sig)
   where o.sig is null or n.sig is null
      or (o.acl, o.config, o.prosecdef, o.proowner, o.prorettype, o.provolatile, o.args, o.descr) is distinct from (n.acl, n.config, n.prosecdef, n.proowner, n.prorettype, n.provolatile, n.args, n.descr);
  if v_bad <> 0 then raise exception '0151 postcondition: % function(s) added/removed or with changed properties.', v_bad; end if;
  select count(*) into v_bad from _mig0151_funcs o join _mig0151_after n using (sig) where o.body_md5 is distinct from n.body_md5 and o.sig not like '%transition_dispatch_status(%';
  if v_bad <> 0 then raise exception '0151 postcondition: % OTHER function body(ies) changed.', v_bad; end if;
  select count(*) into v_bad from _mig0151_funcs o join _mig0151_after n using (sig) where o.body_md5 is distinct from n.body_md5;
  if v_bad <> 1 then raise exception '0151 postcondition: expected exactly ONE changed function body, found %.', v_bad; end if;
  if not exists (select 1 from pg_proc p where p.oid = to_regprocedure({q(SIG)}) and p.prosecdef and p.proconfig::text = '{{"search_path=pg_catalog, public"}}') then
    raise exception '0151 postcondition: SECURITY DEFINER / pinned search_path lost.';
  end if;
  select * into m from _mig0151_misc;
  if (has_function_privilege('authenticated', {q(SIG)}, 'execute'), has_function_privilege('anon', {q(SIG)}, 'execute'), has_function_privilege('service_role', {q(SIG)}, 'execute'), (select (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure({q(SIG)})))
     is distinct from (m.priv_auth, m.priv_anon, m.priv_svc, m.priv_pub) or not m.priv_auth then
    raise exception '0151 postcondition: EXECUTE privileges changed (they must be exactly what they were before this migration).';
  end if;

  select * into m from _mig0151_misc;
  if (select count(*) from public.dispatch_status_transitions) <> m.n_ledger
     or (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.dispatch_status_transitions t) <> m.ledger_md5 then
    raise exception '0151 postcondition: the idempotency ledger changed (0151 never writes it).';
  end if;
  raise notice '0151 complete: transition_dispatch_status() now authorizes (organization + current role) before any idempotency replay. Signature, SECURITY DEFINER, search_path, ACL, comment, ledger and every other function unchanged.';
end
$mig$;

commit;
"""


def verifier_tail(title, label):
    return f"""verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ({q(label + ' FAIL: ')} || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\\n' order by ord))::int
         end as gate   -- a deliberate cast error: raises only when a check fails
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', {q(title)}, 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
"""


def live_cte():
    return f"""f as (
  select p.oid, p.prosecdef, p.proconfig, p.proacl, p.provolatile, l.lanname::text as lang, p.prorettype::regtype::text as rettype,
         pg_get_function_identity_arguments(p.oid) as ident, pg_get_function_arguments(p.oid) as args, p.proowner::regrole::text as owner,
         md5(regexp_replace(lower(regexp_replace(p.prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) as body_md5,
         regexp_replace(lower(regexp_replace(p.prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g') as norm
  from (select 1) d left join pg_proc p on p.oid = to_regprocedure({q(SIG)}) left join pg_language l on l.oid = p.prolang
)"""


def props_rows(base):
    return f"""  union all select {base+1}, 'FUNCTION', 'transition_dispatch_status exists', case when (select oid from f) is not null then 'PASS' else 'FAIL' end, coalesce((select ident from f), 'MISSING')
  union all select {base+2}, 'FUNCTION', 'SECURITY DEFINER with pinned search_path (pg_catalog, public)',
         case when (select prosecdef and proconfig::text = '{{"search_path=pg_catalog, public"}}' from f) then 'PASS' else 'FAIL' end, coalesce((select proconfig::text from f), 'MISSING')
  union all select {base+3}, 'FUNCTION', 'signature, return type, language, volatility unchanged (jsonb / plpgsql / volatile)',
         case when (select rettype = 'jsonb' and lang = 'plpgsql' and provolatile = 'v' from f) then 'PASS' else 'FAIL' end,
         coalesce((select rettype || ' / ' || lang || ' / ' || provolatile::text from f), 'MISSING')
  union all select {base+4}, 'FUNCTION', 'arguments (p_dispatch_id uuid, p_new_status dispatch_status, p_reason text default null, p_idempotency_key text default null)',
         case when (select lower(regexp_replace(args, '\\s+', ' ', 'g')) = 'p_dispatch_id uuid, p_new_status dispatch_status, p_reason text default null::text, p_idempotency_key text default null::text' from f) then 'PASS' else 'FAIL' end,
         coalesce((select args from f), 'MISSING')
  union all select {base+5}, 'FUNCTION', 'EXECUTE: authenticated yes, PUBLIC no (anon / service_role: see the INFO row -- Supabase default privileges may give them EXECUTE)',
         case when (select has_function_privilege('authenticated', oid, 'execute')
                           and not (proacl is null or exists (select 1 from unnest(proacl) a where a::text like '=%')) from f) then 'PASS' else 'FAIL' end,
         coalesce((select proacl::text from f), 'MISSING')
  union all select {base+7}, 'FUNCTION', 'anon / service_role EXECUTE (INFO; unchanged by 0151)', 'INFO',
         coalesce((select has_function_privilege('anon', oid, 'execute')::text || ' / ' || has_function_privilege('service_role', oid, 'execute')::text from f), 'MISSING')
  union all select {base+6}, 'FUNCTION', 'owner', 'INFO', coalesce((select owner from f), 'MISSING')"""


def preflight():
    old = old_block()
    return f"""{file_header("preflight.sql")}
--
-- Run BEFORE applying 0151. READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no
-- transaction control, no temporary object. RESULT: every row INFO or PASS and a final RESULT | PASS row; otherwise the statement RAISES
-- (invalid input syntax for type integer: "PREFLIGHT 0151 FAIL ...") whose text is the complete report.
-- =============================================================================
with
{live_cte()},
rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
{props_rows(100)}
  union all select 200, 'BODY', 'live body is the reviewed 0134 definition (NOT yet repaired)',
         case when (select body_md5 from f) = {q(md5(norm(old.split("$fn$")[1])))} then 'PASS' else 'FAIL' end, coalesce((select body_md5 from f), 'MISSING')
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
{verifier_tail('PREFLIGHT 0151: live transition_dispatch_status() is the reviewed 0134 baseline', 'PREFLIGHT 0151')}"""


def post_apply():
    new = new_block()
    return f"""{file_header("post_apply.sql")}
--
-- Run AFTER applying 0151 (and any time later). READ-ONLY: ONE select statement. RESULT: rows INFO/PASS + a final RESULT | PASS row, or a
-- raised error ("POST-APPLY 0151 FAIL ...") whose text is the complete report.
-- =============================================================================
with
{live_cte()},
rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
{props_rows(100)}
  union all select 200, 'BODY', 'live body is the reviewed 0151 definition',
         case when (select body_md5 from f) = {q(md5(norm(new.split("$fn$")[1])))} then 'PASS' else 'FAIL' end, coalesce((select body_md5 from f), 'MISSING')
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
{verifier_tail('POST-APPLY 0151: transition_dispatch_status() authorizes before any replay', 'POST-APPLY 0151')}"""


def rollback():
    old = old_block()
    new = new_block()
    return f"""{file_header("rollback.sql -- EMERGENCY reversal of proposal 0151")}
--
-- Restores the EXACT 0134 function body (verbatim from migration 0134). WARNING: this re-introduces the replay-before-authorization
-- defect; use only if 0151 itself misbehaves. Refuses unless the live body is exactly the reviewed 0151 definition (anything else = drift).
-- The ledger and every other object are untouched. Single transaction.
-- =============================================================================
begin;

do $mig$
declare v_md5 text;
begin
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure({q(SIG)});
  if v_md5 is distinct from {q(md5(norm(new.split("$fn$")[1])))} then
    raise exception 'ROLLBACK 0151 REFUSED: the live transition_dispatch_status() is not the reviewed 0151 definition (md5 %) -- nothing changed.', v_md5;
  end if;
  create temp table _rb0151_funcs on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config, p.prosecdef, p.proowner
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
end
$mig$;

{old}

do $mig$
declare v_md5 text; v_bad integer;
begin
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure({q(SIG)});
  if v_md5 is distinct from {q(md5(norm(old.split("$fn$")[1])))} then raise exception 'ROLLBACK 0151 postcondition: body md5 % is not the 0134 baseline.', v_md5; end if;
  select count(*) into v_bad from _rb0151_funcs o join pg_proc p on p.oid::regprocedure::text = o.sig
   where (o.acl, o.config, o.prosecdef, o.proowner) is distinct from (coalesce(p.proacl::text, ''), coalesce(p.proconfig::text, ''), p.prosecdef, p.proowner);
  if v_bad <> 0 then raise exception 'ROLLBACK 0151 postcondition: % function propert(ies) changed.', v_bad; end if;
  raise notice 'ROLLBACK 0151 complete: transition_dispatch_status() restored to the exact 0134 body (replay-before-authorization defect is back).';
end
$mig$;

commit;
"""


def patch():
    o, n = old_block().splitlines(), new_block().splitlines()
    return "\n".join(difflib.unified_diff(o, n, "0134 (authoritative)", "0151 (proposed)", lineterm="", n=2)) + "\n"


def build_all():
    return {"proposed_0151.sql": proposed(), "preflight.sql": preflight(), "post_apply.sql": post_apply(), "rollback.sql": rollback(), "function_diff.patch": patch()}


if __name__ == "__main__":
    files = build_all()
    if "--check" in sys.argv:
        stale = [n for n, t in files.items() if not (HERE / n).exists() or (HERE / n).read_text() != t]
        print("stale: " + ", ".join(stale) if stale else "all generated files are current")
        sys.exit(1 if stale else 0)
    for n, t in files.items():
        (HERE / n).write_text(t)
        print(f"wrote {n} ({len(t)} bytes, sha256 {hashlib.sha256(t.encode()).hexdigest()[:16]})")
