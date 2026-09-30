#!/usr/bin/env python3
"""Generates the proposal-0149 SQL artifacts from the authoritative 0129 source.

NOT APPROVED FOR PRODUCTION. Local file generation only: reads
supabase/migrations/0129_atomic_dispatch_lifecycle.sql, writes SQL files next
to this script. Touches no database.

Every function body in proposed_0149.sql / rollback.sql is EXTRACTED from
0129 (never retyped). The only transformation is replacing the single
defective `c_active` declaration in each function, so "only two declarations
changed" holds by construction and is re-proven by tests.py.

  python3 build.py          write the four generated SQL files
  python3 build.py --check  fail if any committed file differs from a rebuild
"""
import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SRC_0129 = REPO / "supabase" / "migrations" / "0129_atomic_dispatch_lifecycle.sql"

CREATE_SIG = "public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)"
CANCEL_SIG = "public.cancel_dispatch(uuid,text)"
FUNCS = {
    "create_dispatch": {"sig": CREATE_SIG, "rettype": "uuid", "usages": 7, "c_active_total": 8,
                        "args": "p_load_id uuid, p_carrier_id uuid, p_truck_id uuid, p_driver_id uuid, "
                                "p_trailer_id uuid DEFAULT NULL::uuid, p_dispatch_fee_percentage numeric DEFAULT NULL::numeric, "
                                "p_notes text DEFAULT NULL::text"},
    "cancel_dispatch": {"sig": CANCEL_SIG, "rettype": "void", "usages": 1, "c_active_total": 2,
                        "args": "p_dispatch_id uuid, p_reason text DEFAULT NULL::text"},
}

OLD_DECL = ("  c_active constant text[] := array[\n"
            "    'assigned','accepted','en_route_to_pickup','at_pickup','loaded',\n"
            "    'en_route_to_delivery','at_delivery'];\n")
NEW_DECL = ("  c_active constant public.dispatch_status[] := array[\n"
            "    'assigned','accepted','en_route_to_pickup','at_pickup','loaded',\n"
            "    'en_route_to_delivery','at_delivery']::public.dispatch_status[];\n")
ACTIVE = ["assigned", "accepted", "en_route_to_pickup", "at_pickup", "loaded", "en_route_to_delivery", "at_delivery"]
ENUM_ALL = sorted(ACTIVE + ["cancelled", "completed", "delivered"])
GENERATED = ["proposed_0149.sql", "rollback.sql", "preflight.sql", "post_apply.sql"]


def norm(s: str) -> str:
    """Same normalisation the SQL verifiers apply: strip -- comments, drop all
    whitespace, lowercase. Immune to harmless formatting/comment drift."""
    return re.sub(r"\s+", "", re.sub(r"--[^\n]*", "", s)).lower()


def fingerprint(body: str) -> str:
    return hashlib.md5(norm(body).encode()).hexdigest()


def source() -> str:
    return SRC_0129.read_text(encoding="utf-8")


def extract_block(text: str, name: str) -> str:
    head = f"create function public.{name}("
    if text.count(head) != 1:
        raise RuntimeError(f"0129 must define {name} exactly once")
    start = text.index(head)
    end = text.index("$fn$;", start) + len("$fn$;")
    return text[start:end]


def body_of(block: str) -> str:
    return block[block.index("$fn$") + 4:block.rindex("$fn$")]


def as_replace(block: str) -> str:
    assert block.startswith("create function public.")
    return "create or replace function public." + block[len("create function public."):]


def extract_comment(text: str, sig: str) -> str:
    head = f"comment on function {sig} is\n  '"
    i = text.index(head) + len(head)
    out = []
    while True:
        c = text[i]
        if c == "'":
            if text[i + 1] == "'":
                out.append("'")
                i += 2
                continue
            break
        out.append(c)
        i += 1
    return "".join(out)


def baseline_privileges_sql(text: str) -> str:
    """0129 section E (grants + comments) verbatim -- used only by the test
    harness to install the 0129 baseline; CREATE OR REPLACE preserves both."""
    s = text.index("revoke execute on function public.create_dispatch(")
    e = text.index("-- ======================= PHASE 3 -- POSTCONDITIONS", s)
    return text[s:e]


def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def model():
    text = source()
    m = {"text": text, "funcs": {}}
    for name, meta in FUNCS.items():
        old = extract_block(text, name)
        if old.count(OLD_DECL) != 1:
            raise RuntimeError(f"{name}: defective declaration must appear exactly once")
        new = old.replace(OLD_DECL, NEW_DECL)
        m["funcs"][name] = {
            **meta,
            "old_block": old, "new_block": new,
            "old_body": body_of(old), "new_body": body_of(new),
            "old_fp": fingerprint(body_of(old)), "new_fp": fingerprint(body_of(new)),
            "comment_md5": hashlib.md5(extract_comment(text, meta["sig"]).encode()).hexdigest(),
        }
        b = m["funcs"][name]
        n_old = norm(b["old_body"])
        assert n_old.count("d.status=any(c_active)") == meta["usages"], name
        assert n_old.count("c_active") == meta["c_active_total"], name
    return m


# --------------------------------------------------------------------------
# Live-catalog report (ONE template shared by preflight.sql, post_apply.sql and
# the migration's own PHASE 1 / PHASE 3, so they cannot diverge).
# Every row is (ord, section, item, result, detail); result is INFO | PASS | FAIL.
# --------------------------------------------------------------------------
def expect_values(state, m):
    out = []
    for idx, (fname, meta) in enumerate(FUNCS.items(), 1):
        f = m["funcs"][fname]
        fp = f["old_fp" if state == "baseline" else "new_fp"]
        decl = "text[]" if state == "baseline" else "public.dispatch_status[]"
        out.append(f"    ({idx}, {q(fname)}, {q(meta['sig'])}, {q(meta['rettype'])}, {q(meta['args'].lower())}, "
                   f"{q(f['comment_md5'])}, {q(fp)}, {q(decl)}, {meta['usages']}, {meta['c_active_total']})")
    return ",\n".join(out)


def occ(needle):
    return f"((length(p.norm) - length(replace(p.norm, {q(needle)}, ''))) / {len(needle)})"


def report_cte(state, m):
    """`with expect, p, rows` -- read-only catalog queries only."""
    assert state in ("baseline", "fixed")
    fixed = state == "fixed"
    label = "0149 repaired" if fixed else "0129 baseline"
    decl_title = "public.dispatch_status[] (repaired)" if fixed else "text[] (the defect)"
    old_n, new_n = norm(OLD_DECL), norm(NEW_DECL)
    active = "array[" + ",".join(q(x) for x in ACTIVE) + "]::text[]"
    labels = "array[" + ",".join(q(x) for x in ENUM_ALL) + "]::text[]"
    arr = "array[" + ",".join(q(x) for x in ACTIVE) + "]::public.dispatch_status[]"

    per_func_info = f"""  -- per-function facts read from the LIVE pg_proc row
  select 1000 + 100 * p.idx + v.n, 'FUNCTION', p.fname || ': ' || v.k, 'INFO', v.d
  from p cross join lateral (values
    (1,  'identity',                  coalesce(p.identity, 'MISSING')::text),
    (2,  'identity arguments',        coalesce(p.identity_args, 'MISSING')::text),
    (3,  'arguments with defaults',   coalesce(p.args, 'MISSING')::text),
    (4,  'returns',                   coalesce(p.rettype, 'MISSING')::text),
    (5,  'language',                  coalesce(p.lang, 'MISSING')::text),
    (6,  'volatility',                coalesce(case p.vol when 'v' then 'VOLATILE' when 's' then 'STABLE' when 'i' then 'IMMUTABLE' else p.vol end, 'MISSING')::text),
    (7,  'parallel safety',           coalesce(case p.par when 'u' then 'UNSAFE' when 's' then 'SAFE' when 'r' then 'RESTRICTED' else p.par end, 'MISSING')::text),
    (8,  'security mode',             coalesce(case when p.prosecdef then 'SECURITY DEFINER' else 'SECURITY INVOKER' end, 'MISSING')::text),
    (9,  'strict / leakproof',        coalesce(p.proisstrict::text || ' / ' || p.proleakproof::text, 'MISSING')::text),
    (10, 'configuration (search_path)', coalesce(p.proconfig::text, '(none)')::text),
    (11, 'owner',                     coalesce(p.owner, 'MISSING')::text),
    (12, 'raw ACL',                   coalesce(p.proacl::text, 'NULL (defaults apply: PUBLIC may execute)')::text),
    (13, 'EXECUTE privilege',         coalesce('authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text
                                        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
                                        || ' service_role=' || has_function_privilege('service_role', p.oid, 'EXECUTE')::text
                                        || ' PUBLIC=' || (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%'))::text, 'MISSING')::text),
    (14, 'declared c_active type',    coalesce(nullif(split_part(split_part(p.norm, 'c_activeconstant', 2), ':=', 1), ''), '(no c_active declaration)')::text),
    (15, 'live body md5 (normalised)', coalesce(md5(p.norm) || '  (expected ' || p.exp_body_md5 || ')', 'MISSING')::text),
    (16, 'live source length',        coalesce(p.src_len::text || ' chars', 'MISSING')::text)
  ) v(n, k, d)"""

    per_func_checks = f"""  -- per-function checks (PASS / FAIL)
  select 3000 + 100 * p.idx + c.n, 'CHECK', p.fname || ': ' || c.title,
         case when coalesce(c.ok, false) then 'PASS' else 'FAIL' end, coalesce(c.d, 'null')::text
  from p cross join lateral (values
    (1,  'exact signature exists in the live database',
         p.oid is not null, coalesce(p.identity, 'MISSING')::text),
    (2,  'single overload by name',
         (select count(*) from pg_proc y where y.pronamespace = 'public'::regnamespace and y.proname = p.fname) = 1,
         (select count(*) from pg_proc y where y.pronamespace = 'public'::regnamespace and y.proname = p.fname)::text),
    (3,  'plpgsql, SECURITY INVOKER, VOLATILE, PARALLEL UNSAFE, not strict, not leakproof, expected return type',
         p.lang = 'plpgsql' and not p.prosecdef and p.vol = 'v' and p.par = 'u' and not p.proisstrict and not p.proleakproof and p.rettype = p.exp_rettype,
         p.lang || ' definer=' || p.prosecdef::text || ' vol=' || p.vol || ' par=' || p.par || ' returns=' || p.rettype),
    (4,  'search_path is exactly public (sole configuration entry)',
         p.proconfig = array['search_path=public']::text[], coalesce(p.proconfig::text, '(none)')),
    (5,  'argument list and defaults unchanged',
         p.args = p.exp_args, coalesce(p.args, 'MISSING')),
    (6,  'EXECUTE granted to authenticated only (not PUBLIC, anon or service_role)',
         p.proacl is not null
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
           and not has_function_privilege('anon', p.oid, 'EXECUTE')
           and not has_function_privilege('service_role', p.oid, 'EXECUTE')
           and not exists (select 1 from unnest(p.proacl) a where a::text like '=%'),
         coalesce(p.proacl::text, 'NULL')),
    (7,  'function description unchanged from 0129',
         md5(p.descr) = p.exp_descr_md5, coalesce(md5(p.descr), 'MISSING')),
    (8,  'body fingerprint matches {label} (comments and whitespace ignored)',
         md5(p.norm) = p.exp_body_md5, 'live=' || coalesce(md5(p.norm), 'MISSING') || ' expected=' || p.exp_body_md5),
    (9,  'declares c_active as {decl_title} exactly once',
         (split_part(split_part(p.norm, 'c_activeconstant', 2), ':=', 1) = p.exp_decl) and {occ('c_activeconstant')} = 1,
         coalesce(split_part(split_part(p.norm, 'c_activeconstant', 2), ':=', 1), 'MISSING') || ' x' || {occ('c_activeconstant')}::text),
    (10, 'unchanged use count: d.status = any(c_active) sites and c_active tokens',
         {occ('d.status=any(c_active)')} = p.n_use and {occ('c_active')} = p.n_tok,
         {occ('d.status=any(c_active)')}::text || ' sites / ' || {occ('c_active')}::text || ' tokens (expected ' || p.n_use::text || ' / ' || p.n_tok::text || ')'),
    (11, 'dispatches.status is never cast to text',
         {occ('status::text')} = 0 and {occ('status::varchar')} = 0, {occ('status::text')}::text)
  ) c(n, title, ok, d)"""

    rows = f"""rows as (
  -- server
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 101, 'SERVER', 'server_version_num', 'INFO', current_setting('server_version_num')::text
  union all select 102, 'SERVER', 'version()', 'INFO', version()::text
  union all
{per_func_info}
  union all
  -- dispatches.status and the enum
  select 2000, 'DISPATCHES', 'dispatches.status column type', 'INFO',
         coalesce((select format_type(a.atttypid, a.atttypmod) from pg_attribute a
                    where a.attrelid = to_regclass('public.dispatches') and a.attname = 'status' and not a.attisdropped), 'MISSING')::text
  union all
  select 2001, 'DISPATCHES', 'dispatch_status enum values (in sort order)', 'INFO',
         coalesce((select string_agg(e.enumlabel::text, ', ' order by e.enumsortorder) from pg_enum e
                    where e.enumtypid = to_regtype('public.dispatch_status')), 'MISSING')::text
  union all
  select 2002, 'BLAST RADIUS', 'public functions declaring c_active constant text[]', 'INFO',
         coalesce((select string_agg(x.proname::text, ', ' order by x.proname) from pg_proc x
                    where x.pronamespace = 'public'::regnamespace
                      and regexp_replace(x.prosrc, '\\s+', '', 'g') like '%c\\_activeconstanttext[]%'), '(none)')::text
  union all
{per_func_checks}
  union all
  -- global checks
  select 4001, 'CHECK', 'server supports every catalog column this report reads (>= 9.6)',
         case when current_setting('server_version_num')::int >= 90600 then 'PASS' else 'FAIL' end, current_setting('server_version')::text
  union all
  select 4002, 'CHECK', 'dispatches.status is public.dispatch_status',
         case when coalesce((select a.atttypid = to_regtype('public.dispatch_status') from pg_attribute a
                              where a.attrelid = to_regclass('public.dispatches') and a.attname = 'status' and not a.attisdropped), false) then 'PASS' else 'FAIL' end,
         coalesce((select format_type(a.atttypid, a.atttypmod) from pg_attribute a
                    where a.attrelid = to_regclass('public.dispatches') and a.attname = 'status' and not a.attisdropped), 'MISSING')::text
  union all
  select 4003, 'CHECK', 'dispatch_status has exactly the expected 10 labels',
         case when coalesce((select array_agg(e.enumlabel::text order by e.enumlabel::text) from pg_enum e
                              where e.enumtypid = to_regtype('public.dispatch_status')) = {labels}, false) then 'PASS' else 'FAIL' end,
         coalesce((select string_agg(e.enumlabel::text, ',' order by e.enumsortorder) from pg_enum e where e.enumtypid = to_regtype('public.dispatch_status')), 'MISSING')::text
  union all
  select 4004, 'CHECK', 'dispatch_status contains all 7 active values',
         case when (select count(*) from pg_enum e where e.enumtypid = to_regtype('public.dispatch_status') and e.enumlabel::text = any({active})) = 7 then 'PASS' else 'FAIL' end,
         (select count(*) from pg_enum e where e.enumtypid = to_regtype('public.dispatch_status') and e.enumlabel::text = any({active}))::text
  union all
  select 4005, 'CHECK', 'blast radius: number of public functions declaring c_active constant text[] is {"0" if fixed else "2"}',
         case when (select count(*) from pg_proc x where x.pronamespace = 'public'::regnamespace
                     and regexp_replace(x.prosrc, '\\s+', '', 'g') like '%c\\_activeconstanttext[]%') = {"0" if fixed else "2"} then 'PASS' else 'FAIL' end,
         (select count(*) from pg_proc x where x.pronamespace = 'public'::regnamespace
           and regexp_replace(x.prosrc, '\\s+', '', 'g') like '%c\\_activeconstanttext[]%')::text
  union all
  select 4006, 'CHECK', '0054 partial unique indexes (driver, truck, trailer) present',
         case when (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'dispatches' and indexname in
                     ('dispatches_active_driver_unique', 'dispatches_active_truck_unique', 'dispatches_active_trailer_unique')) = 3 then 'PASS' else 'FAIL' end,
         (select count(*) from pg_indexes where schemaname = 'public' and tablename = 'dispatches' and indexname like 'dispatches_active_%')::text
  union all
  select 4007, 'CHECK', '0132 trigger dispatches_guard_carrier_scope present on public.dispatches',
         case when exists (select 1 from pg_trigger t where t.tgrelid = to_regclass('public.dispatches')
                            and t.tgname = 'dispatches_guard_carrier_scope' and not t.tgisinternal) then 'PASS' else 'FAIL' end,
         (select count(*) from pg_trigger t where t.tgrelid = to_regclass('public.dispatches') and not t.tgisinternal)::text || ' user triggers on dispatches'"""
    if fixed:
        rows += f"""
  union all
  select 4008, 'CHECK', 'enum-array comparison against live dispatches.status executes (read-only probe)',
         case when (select count(*) from public.dispatches d where d.status = any({arr})) >= 0 then 'PASS' else 'FAIL' end,
         (select count(*) from public.dispatches d where d.status = any({arr}))::text || ' rows currently in an active status'"""
    rows += "\n)"

    return ("with expect(idx, fname, sig, rettype, args, descr_md5, body_md5, decl, n_use, n_tok) as (values\n"
            + expect_values(state, m) + "\n),\n"
            "p as (\n"
            "  select e.idx, e.fname, e.sig, e.rettype as exp_rettype, e.args as exp_args, e.descr_md5 as exp_descr_md5,\n"
            "         e.body_md5 as exp_body_md5, e.decl as exp_decl, e.n_use, e.n_tok,\n"
            "         x.oid, x.oid::regprocedure::text as identity, pg_get_function_identity_arguments(x.oid) as identity_args,\n"
            "         lower(regexp_replace(pg_get_function_arguments(x.oid), '\\s+', ' ', 'g')) as args,\n"
            "         x.prorettype::regtype::text as rettype, l.lanname::text as lang, x.prosecdef,\n"
            "         x.provolatile::text as vol, x.proparallel::text as par, x.proisstrict, x.proleakproof,\n"
            "         x.proconfig, x.proacl, x.proowner::regrole::text as owner,\n"
            "         obj_description(x.oid, 'pg_proc') as descr, length(x.prosrc) as src_len,\n"
            "         regexp_replace(lower(regexp_replace(x.prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g') as norm\n"
            "  from expect e\n"
            "  left join pg_proc x on x.oid = to_regprocedure(e.sig)\n"
            "  left join pg_language l on l.oid = x.prolang\n"
            "),\n" + rows)


def meta_hash_sql():
    """Scalar subquery: hash of owner/ACL/description/config/arguments/flags of both functions (read-only)."""
    return ("(select md5(string_agg(x.proname::text || '|' || x.proowner::regrole::text || '|' || coalesce(x.proacl::text, '') || '|' || "
            "coalesce(obj_description(x.oid, 'pg_proc'), '') || '|' || coalesce(x.proconfig::text, '') || '|' || pg_get_function_arguments(x.oid) || '|' || "
            "x.prorettype::regtype::text || '|' || x.provolatile::text || x.proparallel::text || x.prosecdef::text || x.proisstrict::text || x.proleakproof::text, "
            "E'\\n' order by x.proname)) from pg_proc x where x.oid in (to_regprocedure('" + CREATE_SIG + "'), to_regprocedure('" + CANCEL_SIG + "')))")


def do_block(kind, state, m):
    label = "precondition" if kind == "pre" else "postcondition"
    cap = chk = ""
    if kind == "pre":
        cap = ("  -- capture owner/ACL/description/config/args so PHASE 3 can prove they are byte-identical after the replace\n"
               f"  perform set_config('td0149.meta', {meta_hash_sql()}, true);\n")
    else:
        chk = (f"  if {meta_hash_sql()} is distinct from current_setting('td0149.meta', true) then\n"
               f"    raise exception '0149 postcondition: owner/ACL/description/search_path/argument metadata changed -- CREATE OR REPLACE must preserve all of it.';\n"
               f"  end if;\n")
    return (f"do $mig$\ndeclare r record; v_fail text := '';\nbegin\n"
            f"  for r in\n{report_cte(state, m)}\n  select ord, section, item, result, detail from rows order by ord\n  loop\n"
            f"    if r.result = 'FAIL' then v_fail := v_fail || E'\\n  - ' || r.item || ' [' || r.detail || ']'; end if;\n"
            f"  end loop;\n"
            f"  if v_fail <> '' then raise exception '0149 {label} failed (fail closed -- nothing was changed by this step):%', v_fail; end if;\n"
            f"{cap}{chk}"
            f"  raise notice '0149 {'PHASE 1 preconditions' if kind == 'pre' else 'PHASE 3 postconditions'} passed.';\n"
            f"end\n$mig$;\n")


def verifier_sql(label, state, m):
    """Single read-only SELECT. PASS -> full report + RESULT row. FAIL -> raises an error whose message carries the full report."""
    return (report_cte(state, m) + f""",
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass,
         count(*) filter (where result = 'FAIL') as n_fail,
         count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('{label} FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\\n' order by ord))::int
         end as gate   -- a deliberate cast error: raises only when a check fails
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail
from rows r cross join verdict v
where v.gate = 0
union all
select 9000, 'RESULT', '{label}: live definitions are the {'0149 repaired' if state == 'fixed' else '0129 baseline'} state', 'PASS',
       v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows'
from verdict v
where v.gate = 0
order by 1;
""")


# --------------------------------------------------------------------------
# File assembly
# --------------------------------------------------------------------------
BANNER = ("-- =============================================================================\n"
          "-- {name}\n"
          "-- PROPOSAL 0149 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION.\n"
          "-- Generated by build.py from supabase/migrations/0129_atomic_dispatch_lifecycle.sql.\n")


def proposed(m):
    c, k = m["funcs"]["create_dispatch"], m["funcs"]["cancel_dispatch"]
    head = BANNER.format(name="proposed_0149.sql") + """--
-- Forward-only corrective proposal for a LIVE defect in two functions defined
-- by 0129: `c_active` is declared `text[]` and compared with
--   d.status = any(c_active)
-- where d.status is public.dispatch_status (an enum) => PostgreSQL raises
--   42883: operator does not exist: dispatch_status = text
-- whenever a statement using it executes (PL/pgSQL type-checks each statement
-- only when it first runs, so CREATE FUNCTION in 0129 succeeded).
-- create_dispatch() reaches it unconditionally at step 5; cancel_dispatch() at
-- its load-revert UPDATE. So every call that reaches those statements fails.
--
-- SCOPE NOTE: this proposal changes NO privileges. Separately, 0135 left
-- `authenticated` with UPDATE on dispatches.notes only, so a DIRECT authenticated
-- call to the SECURITY INVOKER cancel_dispatch() RPC is expected to be refused
-- earlier (42501; confirmed in a disposable database, NOT yet verified in
-- production). That is a separate follow-up blocker, not addressed here; the
-- board path transition_dispatch_status() (SECURITY DEFINER) delegates to
-- cancel_dispatch() and is repaired by this proposal. See README.md, BLOCKER F1.
--
-- THE ONLY SEMANTIC CHANGE: in each of the two functions the declaration
--     c_active constant text[] := array['assigned', ... 'at_delivery'];
-- becomes
--     c_active constant public.dispatch_status[] := array['assigned', ... 'at_delivery']::public.dispatch_status[];
-- Every other byte of each body is the 0129 text (extracted, not retyped).
-- dispatches.status is NOT cast to text (that would defeat the typed 0054
-- partial-unique-index predicates' planner match and the type safety).
--
-- CREATE OR REPLACE keeps the function OIDs, owner, ACL and comment; nothing
-- else is created, altered or dropped (no table/data/enum/index/RLS/policy/
-- trigger/grant/application change).
--
-- NUMBERING: proposal number 0149. It lives ONLY under supabase/proposals/0149/.
-- If 0149 is applied before the separate, unapproved 0148 proposal, that 0148
-- proposal must be renumbered above 0149 before promotion. Do not renumber now.
--
-- One transaction. PHASE 1 fails closed on any drift and writes nothing.
-- =============================================================================
begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
"""
    return (head + do_block("pre", "baseline", m)
            + "\n-- ======================= PHASE 2 -- MUTATION (two CREATE OR REPLACE) =========\n\n"
            + as_replace(c["new_block"]) + "\n\n" + as_replace(k["new_block"]) + "\n\n"
            + "-- ======================= PHASE 3 -- POSTCONDITIONS =========================\n"
            + do_block("post", "fixed", m) + "\ncommit;\n")


def rollback(m):
    c, k = m["funcs"]["create_dispatch"], m["funcs"]["cancel_dispatch"]
    head = BANNER.format(name="rollback.sql") + """--
-- Restores the EXACT pre-0149 (0129) definitions of create_dispatch() and
-- cancel_dispatch() -- i.e. it RE-INTRODUCES the 42883 defect. It exists only
-- so a bad 0149 apply can be reversed to the recorded baseline. After running
-- it, dispatch creation/cancellation is broken again; re-run preflight.sql to
-- confirm the baseline was restored. Fails closed unless the live functions
-- are exactly the 0149-repaired ones. One transaction.
-- =============================================================================
begin;

"""
    return (head + do_block("pre", "fixed", m)
            + "\n" + as_replace(c["old_block"]) + "\n\n" + as_replace(k["old_block"]) + "\n\n"
            + do_block("post", "baseline", m) + "\ncommit;\n")


def verifier(name, label, state, m, purpose):
    head = BANNER.format(name=name) + f"""--
-- {purpose}
-- READ-ONLY: ONE select statement over the system catalogs. It contains no
-- data-changing or schema-changing statement, no transaction control, no
-- temporary object, and no routine other than built-in catalog-inspection
-- functions. It reads the LIVE database (pg_proc, pg_enum, pg_attribute, ...).
-- Expected values embedded below are fingerprints of the 0129 source text.
-- RESULT: on success every row is INFO or PASS and the last row is
-- RESULT | {label} | PASS. If any check fails the statement RAISES AN ERROR
-- (invalid input syntax for type integer: "{label} FAIL ...") whose text is the
-- complete report -- paste that error text back. Remarks (dash-dash text) and
-- whitespace inside function bodies are ignored (md5 of remark-free, whitespace-free text).
-- =============================================================================
"""
    return head + verifier_sql(label, state, m)


def build_all():
    m = model()
    return {
        "proposed_0149.sql": proposed(m),
        "rollback.sql": rollback(m),
        "preflight.sql": verifier("preflight.sql", "PREFLIGHT", "baseline", m,
                                  "Run BEFORE applying 0149: proves the live functions are exactly the defective 0129 baseline (and re-run AFTER rollback to prove restoration)."),
        "post_apply.sql": verifier("post_apply.sql", "POST_APPLY", "fixed", m,
                                   "Run AFTER applying 0149: proves the live functions are exactly the repaired definitions with metadata intact."),
    }


def main():
    files = build_all()
    if "--check" in sys.argv:
        bad = [n for n, t in files.items() if not (HERE / n).exists() or (HERE / n).read_text() != t]
        if bad:
            print("STALE generated files:", bad)
            sys.exit(1)
        print("generated files are current")
        return
    for n, t in files.items():
        (HERE / n).write_text(t)
        print("wrote", n, len(t), "bytes")


if __name__ == "__main__":
    main()
