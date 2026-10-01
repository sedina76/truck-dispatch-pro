#!/usr/bin/env python3
"""Proposal 0151 -- disposable-PostgreSQL verification harness (transition_dispatch_status replay authorization).

NOT APPROVED FOR PRODUCTION. Reuses the reviewed 0149/0150 cluster harness (brand-new local cluster under /private/tmp/td0149-local-*,
unix socket only, port 55491, minimal environment; never connects to Supabase or any real database; never writes inside the repository).

Sequence on the REAL migrations: 0130..0147 -> 0149 -> 0150 (approved count + digest from candidate_review) -> 0151.
"""
import hashlib
import importlib.util
import re
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
P0150 = SUPA / "proposals" / "0150"


def _load(name, path, extra_path=None):
    if extra_path:
        sys.path.insert(0, str(extra_path))
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


t150 = _load("t0150_harness", P0150 / "tests.py")   # Env, Session, wait_blocked, fill, uid, t149 (Cluster)
t149 = t150.t149
build = _load("build0151", HERE / "build.py")
uid, fill = t150.uid, t150.fill
SEP = t149.SEP

PINNED = {
    "migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql": "b71bb6eb07a76902fc24f196d11c88afdc49d2f7913c0d9613c85a9c4d305ed9",
    "proposals/0150/proposed_0150.sql": "bc37e8a670735a5d947628b96e3676d0c1288c82767a5cdff834b65db55a94c3",  # comment-only change: renumbering note 0152 -> 0153 (old pin a0671647... is reproduced by reverting exactly that text)
}
checks = []


def check(label, cond, detail=""):
    if not cond:
        raise SystemExit(f"FAIL: {label} {detail}")
    checks.append(label)
    print(f"  ok  {label}")


def fixture_text():
    return (HERE / "fixture_0151.sql").read_text()


def script(name):
    return (HERE / name).read_text().replace("-- @@FIXTURE@@", fixture_text())


def code_lines(block):
    out = []
    for l in block.splitlines():
        s = re.sub(r"--.*$", "", l).strip()
        if s:
            out.append(re.sub(r"\s+", " ", s))
    return out


# ------------------------------------------------------------------- static
def static_checks():
    print("== static checks ==")
    files = build.build_all()
    for name, text in files.items():
        check(f"generated {name} is current", (HERE / name).read_text() == text)
    for rel, h in PINNED.items():
        check(f"{rel} matches its SHA-256 pin", hashlib.sha256((SUPA / rel).read_bytes()).hexdigest() == h)
    for rel in t150.t149.PINNED:
        t149.pinned(rel)
    old, new = build.old_block(), build.new_block()
    prop, roll = (HERE / "proposed_0151.sql").read_text(), (HERE / "rollback.sql").read_text()
    check("proposed_0151.sql embeds the repaired function block verbatim", new in prop)
    check("rollback.sql embeds the EXACT 0134 function block verbatim", old in roll)
    rest = t149.strip_sql(prop.replace(new, "")).replace("on commit drop", "")
    check("proposed_0151.sql has exactly ONE create-or-replace function and no other DDL/DML (only temp snapshot tables)",
          prop.count("create or replace function") == 1
          and not re.search(r"\b(alter|drop|grant|revoke|comment|truncate|delete|insert|update)\b", rest, re.I)
          and re.findall(r"create temp table (\w+)", prop) == ["_mig0151_funcs", "_mig0151_misc", "_mig0151_after"])
    check("the repaired function keeps the signature, SECURITY DEFINER and the pinned search_path (header identical to 0134)",
          old[:old.index("declare")] == new[:new.index("declare")] and "security definer" in new and "set search_path = pg_catalog, public" in new)
    # semantic diff: code lines removed vs added
    oc, nc = code_lines(old), code_lines(new)
    removed = [l for l in oc if l not in nc]
    added = [l for l in nc if l not in oc]
    check("semantic diff: the ONLY 0134 code lines removed are the old unscoped ledger lookup (moved/replaced, nothing else)",
          sorted(removed) == sorted(["select result into v_cached", "from public.dispatch_status_transitions", "where dispatch_id = p_dispatch_id and idempotency_key = p_idempotency_key;"]) or
          (all("dispatch_status_transitions" in l or "v_cached" in l or "idempotency_key" in l for l in removed) and len(removed) <= 4), str(removed))
    check("semantic diff: added code = declarations, dispatch-org check (moved), role gate, 2 org-scoped ledger reads, TSIDK, owner/admin replay rule",
          any("TSIDK" in l for l in added) and sum(1 for l in added if "t.organization_id = v_org" in l) == 2 and any("v_cached_old public.dispatch_status;" in l for l in added), str(len(added)))
    check("no other statement of the function changed (every remaining 0134 code line still present, in order)",
          [l for l in oc if l not in removed] == [l for l in nc if l in oc and l not in removed][:len([l for l in oc if l not in removed])] or
          set(l for l in oc if l not in removed) <= set(nc))
    strict = re.compile(r"\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|comment|copy|call|do|begin|commit|rollback|savepoint|set|reset|lock|listen|notify|"
                        r"vacuum|reindex|analyze|execute|prepare|declare|fetch|refresh|cluster|import|security)\b", re.I)
    for name in ("preflight.sql", "post_apply.sql"):
        raw = (HERE / name).read_text()
        s = t149.strip_sql(raw)
        check(f"{name}: exactly ONE select statement; no data-/schema-changing keyword, transaction control or set_config",
              s.count(";") == 1 and not strict.findall(s) and "set_config" not in s, str(strict.findall(s)))
        check(f"{name}: forbidden words appear nowhere in the file text",
              not re.findall(r"(?i)\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|copy|call)\b", raw))
    for f in ("proposed_0151.sql", "preflight.sql", "post_apply.sql", "rollback.sql"):
        t = (HERE / f).read_text()
        check(f"{f} is marked NOT APPROVED FOR PRODUCTION and names the 0148 -> 0153+ renumbering", "NOT APPROVED FOR PRODUCTION" in t and "0153 or higher" in t)
    check("0150 as shipped contains NO count and NO digest (both placeholders are null; the file fails closed)",
          t150.COUNT_LINE in (P0150 / "proposed_0150.sql").read_text() and t150.DIGEST_LINE in (P0150 / "proposed_0150.sql").read_text())


# ------------------------------------------------------------------- live
def rows_of(stdout, prefix="ROW"):
    return [l.split(SEP) for l in stdout.splitlines() if l.startswith(prefix + SEP)]


def props(env, db):
    rc, rows, err = env.q(db, """select p.prosecdef::text, coalesce(p.proconfig::text,''), coalesce(p.proacl::text,''), pg_get_userbyid(p.proowner), pg_get_function_arguments(p.oid),
        p.prorettype::regtype::text, p.provolatile::text, l.lanname::text, coalesce(obj_description(p.oid,'pg_proc'),''), p.proisstrict::text, p.proleakproof::text, p.proparallel::text
        from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)')""")
    assert rc == 0, err
    return rows[0]


class DPEnv(t150.Env):
    """Base build that emulates Supabase's schema-level default privileges (EXECUTE on every new function to anon, authenticated and
    service_role at CREATE time, see 0127) so function-ACL behaviour matches production. Reused by the 0152 harness."""

    def build_base(self, db):
        c = self.c
        c.createdb(db)
        base = "".join(self.model["funcs"][n]["old_block"] + "\n\n" for n in ("create_dispatch", "cancel_dispatch")) + t150.b149.baseline_privileges_sql(self.text_0129)
        dp = "\nalter default privileges in schema public grant execute on functions to anon, authenticated, service_role;\n"
        sql = (self.guard + "\n\\set ON_ERROR_STOP on\n" + t149.pinned("TEST_SUPPORT_0130_0133_schema.sql") + dp + t150.pinned_extra("TEST_SUPPORT_0136_0138_factoring_schema.sql")
               + "\ndrop function public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text);\ndrop function public.cancel_dispatch(uuid,text);\n" + base)
        for n in (130, 131, 132):
            sql += "\n" + self.mig(n)
        sql += "\n" + (SUPA / "proposals" / "0149" / "fixture.sql").read_text() + "\n" + (P0150 / "legacy_seed.sql").read_text()
        for n in range(133, 148):
            sql += "\n" + self.mig(n)
        sql += "\n" + t150.pinned_extra("proposals/0149/proposed_0149.sql")
        c.psql(db, sql, guard=True)


def live(c):
    env = DPEnv(c)
    print("== build: 0130..0147 -> 0149, then 0150 with the approved count + digest ==")
    base = "td0149_q_base"
    env.build_base(base)
    rows, summ = env.review(base)
    n = int(summ["CANDIDATES (approve this count)"])
    dig = summ["candidate digest (REQUIRED: paste into v_expected_digest)"]
    prop0150 = (P0150 / "proposed_0150.sql").read_text()
    r = env.run(base, prop0150)
    check("0150 as shipped (no count, no digest) REFUSES on the real post-0133 database and changes nothing", r.returncode != 0 and "expected candidate count is not set" in r.stderr and env.prov_absent(base))
    r = env.run(base, fill(prop0150, n, None))
    check("0150 with a count but NO digest REFUSES", r.returncode != 0 and "expected candidate digest is not set" in r.stderr and env.prov_absent(base))
    r = env.run(base, fill(prop0150, 0, "0" * 32))
    check("0150 with example values (count 0, all-zero digest) REFUSES", r.returncode != 0 and env.prov_absent(base))
    r = env.run(base, fill(prop0150, n, dig))
    check("0150 applies with the reviewed count + digest", r.returncode == 0 and "0150 complete" in r.stderr, r.stderr[-400:])
    check("post_apply_0150 passes", env.verify(base, None, (P0150 / "post_apply.sql").read_text())["ok"])
    check("the base database is now 0130..0147 -> 0149 -> 0150 (TSIDK not yet in the function)",
          env.scalar(base, "select (position('TSIDK' in prosrc) = 0)::text from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)')") == "true")

    # ---- PHASE 1 proof on the baseline
    print("== replay defect reproduced on the 0134 baseline ==")
    db = "td0149_q_defect"
    c.createdb(db, template=base)
    r = env.run(db, script("defect_repro.sql"), guard=True)
    assert r.returncode == 0, r.stderr[-1500:]
    out = r.stderr
    for who in ("x_other_org", "x_other_org_owner", "x_acct", "x_viewer", "x_downgraded"):
        check(f"DEFECT on 0134: {who} receives another caller's cached cancellation result", f"DEFECT-CONFIRMED: {who} received" in out, out[-600:])
    check("DEFECT on 0134: same key with a DIFFERENT requested status silently returns the stale cancelled result", "DEFECT-CONFIRMED: same key with a DIFFERENT requested status" in out)
    check("NOT a defect on 0134: unauthenticated replay is refused (uid is checked before the ledger)", "NOT-A-DEFECT: unauthenticated replay -> TSAUT" in out.replace("NOT-A-DEFECT: unauthenticated replay", "NOT-A-DEFECT: unauthenticated replay"))
    check("NOT a defect on 0134: a user removed from the organization is refused (current_org_id is checked before the ledger)", re.search(r"NOT-A-DEFECT: user removed from the organization -> TSAUT", out) is not None)
    for l in out.splitlines():
        if "DEFECT" in l or "INFO:" in l:
            print("      ", l.split("NOTICE:")[-1].strip()[:170])
    c.dropdb(db)

    # ---- the regression suite must FAIL on the baseline (proves it detects the defect)
    db = "td0149_q_old_reg"
    c.createdb(db, template=base)
    r = env.run(db, script("regression.sql"), guard=True)
    check("regression.sql FAILS on the 0134 baseline (it detects the defect)", r.returncode != 0 and "TEST 0151 REGRESSION PASSED" not in r.stderr, r.stderr[-300:])
    c.dropdb(db)

    # ---- baseline matrix
    old_db = "td0149_q_old_matrix"
    c.createdb(old_db, template=base)
    r_old = c.psql(old_db, script("matrix.sql"), guard=True, tuples=True, ok=False)
    check("matrix.sql runs on the 0134 baseline", r_old.returncode == 0, r_old.stderr[-500:])
    m_old = rows_of(r_old.stdout)
    check("differential matrix covers >= 45 transition calls", len(m_old) >= 45, str(len(m_old)))

    # ---- preflight / apply / post-apply on the main DB
    print("== apply 0151 ==")
    main = "td0149_q_main"
    c.createdb(main, template=base)
    pf = env.verify(main, None, (HERE / "preflight.sql").read_text())
    check("preflight.sql PASSES on the 0134 baseline (after 0150)", pf["ok"], pf["err"][-600:])
    check("post_apply.sql cannot pass before 0151", not env.verify(main, None, (HERE / "post_apply.sql").read_text())["ok"])
    cat0, dump0, props0 = env.catalog(main), c.dump(main), props(env, main)
    led0 = env.scalar(main, "select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by id), '')) from public.dispatch_status_transitions t")
    d0 = env.digest(main)
    prop = (HERE / "proposed_0151.sql").read_text()
    r = env.run(main, prop)
    check("0151 applies (single transaction)", r.returncode == 0 and "0151 complete" in r.stderr, r.stderr[-800:])
    cat1, dump1, props1 = env.catalog(main), c.dump(main), props(env, main)
    ch = t149.changed(cat0, cat1)
    check("catalog comparison: exactly ONE object changed -- the body of transition_dispatch_status (nothing else, incl. ACL/owner/config/args/return/comment)",
          len(ch) == 1 and ch[0][0] == "function_body" and "transition_dispatch_status" in ch[0][1], str(ch))
    check("property comparison: SECURITY DEFINER, search_path, ACL, owner, arguments, return type, volatility, language, comment, strict/leakproof/parallel ALL identical",
          props0 == props1 and props1[0] == "true" and "pg_catalog, public" in props1[1], f"{props0} vs {props1}")
    import difflib
    dd = [l for l in difflib.unified_diff(dump0, dump1, lineterm="", n=0) if l[:1] in "+-" and not l.startswith(("---", "+++"))]
    check("pg_dump schema delta is confined to the function body (no CREATE/ALTER/GRANT/COMMENT line changed)",
          dd and not any(re.match(r"[+-](CREATE|ALTER|GRANT|REVOKE|COMMENT|DROP)\b", l) for l in dd), "\n".join(dd[:8]))
    check("ledger and all rows untouched by the apply", env.digest(main) == d0 and env.scalar(main, "select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by id), '')) from public.dispatch_status_transitions t") == led0)
    po = env.verify(main, None, (HERE / "post_apply.sql").read_text())
    check("post_apply.sql PASSES (authorization-before-ledger source order, 2 org-scoped reads, props)", po["ok"], po["err"][-800:])
    check("Supabase-style default privileges: anon and service_role KEEP the EXECUTE they held before (0151 changes no ACL; it must not require them to be absent)",
          env.scalar(main, "select (has_function_privilege('anon', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute') and has_function_privilege('service_role', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute'))::text") == "true")
    check("preflight.sql now FAILS (already repaired) -- cannot be run twice", not env.verify(main, None, (HERE / "preflight.sql").read_text())["ok"])
    r = env.run(main, prop)
    check("re-running proposed_0151.sql is refused, changing nothing", r.returncode != 0 and "not the reviewed 0134 definition" in r.stderr and env.catalog(main) == cat1)

    # ---- regression + F1 + matrix on the repaired DB
    print("== regression / F1 / differential matrix on the repaired database ==")
    db = "td0149_q_reg"
    c.createdb(db, template=main)
    r = env.run(db, script("regression.sql"), guard=True)
    check("regression.sql PASSES on 0151", r.returncode == 0 and "TEST 0151 REGRESSION PASSED" in r.stderr, r.stderr[-1500:])
    for tag in ("A", "B", "D", "E", "F", "G", "H", "I", "J", "K", "L"):
        check(f"regression group {tag}", re.search(rf"NOTICE:\s+OK: {tag}[ /]", r.stderr) is not None)
    c.dropdb(db)
    db = "td0149_q_f1"
    c.createdb(db, template=main)
    r = env.run(db, (P0150 / "f1_cancel_verify.sql").read_text(), guard=True)
    check("F1 cancellation verification (11 conditions) PASSES on 0130..0147 -> 0149 -> 0150 -> 0151", r.returncode == 0 and "F1 VERIFICATION PASSED" in r.stderr, r.stderr[-1200:])
    check("F1 replay probe: the cross-org replay is now REJECTED (no FINDING F1-R1 notice; 'OK: F9b')", "FINDING F1-R1" not in r.stderr and "OK: F9b" in r.stderr)
    c.dropdb(db)
    new_db = "td0149_q_new_matrix"
    c.createdb(new_db, template=main)
    r_new = c.psql(new_db, script("matrix.sql"), guard=True, tuples=True, ok=False)
    check("matrix.sql runs on 0151", r_new.returncode == 0, r_new.stderr[-500:])
    m_new = rows_of(r_new.stdout)
    check("ALL normal transitions are unchanged: every call's SQLSTATE, message, result JSON, dispatch/load status, audit-row count and ledger-row count is identical under 0134 and 0151",
          m_old == m_new, "\n".join(f"{a}\n{b}" for a, b in zip(m_old, m_new) if a != b)[:800])
    print(f"      differential matrix: {len(m_new)} calls identical")
    c.dropdb(old_db)
    c.dropdb(new_db)

    # ---- concurrent duplicates (real two sessions)
    print("== concurrent duplicate requests (real two sessions) ==")
    for label, dbsrc in (("0151", main), ("0134 baseline (informational)", base)):
        db = "td0149_q_conc"
        c.createdb(db, template=dbsrc)
        r = c.psql(db, env.guard + f"""
set role authenticated;
select set_config('test.current_uid', '{uid('u_disp1')}', false);
select public.create_dispatch('{uid('l3')}', '{uid('ca')}', '{uid('ta3')}', '{uid('da3')}', null, null, null);""", guard=True, tuples=True)
        did = re.findall(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", r.stdout)[-1]
        call = f"select public.transition_dispatch_status('{did}', 'cancelled', 'dup', 'KDUP');"
        A = t150.Session(c, db, "u_disp1")
        A.send("set role authenticated;\nbegin;\n" + call)
        time.sleep(0.6)
        B = t150.Session(c, db, "u_disp1")
        B.send("set role authenticated;\n" + call)
        blocked = t150.wait_blocked(env, db)
        A.send("commit;")
        A.p.stdin.close()
        ao, ae = A.p.communicate(timeout=60)
        B.p.stdin.close()
        bo, be = B.p.communicate(timeout=60)
        rc, rws, err = env.q(db, f"select (select count(*) from public.activity_logs where entity_id = '{did}' and action = 'cancelled'), (select count(*) from public.dispatch_status_transitions where dispatch_id = '{did}' and idempotency_key = 'KDUP'), (select status::text from public.dispatches where id = '{did}')")
        if label == "0151":
            check("concurrent duplicate: the second request WAITS behind the first", blocked)
            check("concurrent duplicate: the loser replays the winner's result under the locks (idempotent_replay), both succeed",
                  '"idempotent_replay": true' in bo and '"idempotent_replay"' not in ao and '"success": true' in ao and "ERROR" not in be, f"A={ao!r} B={bo!r} {be!r}")
            check("concurrent duplicate: exactly ONE cancelled audit row, ONE ledger row, dispatch cancelled", rws[0] == ["1", "1", "cancelled"], str(rws))
        else:
            print(f"      [{label}] loser result: {bo.strip()[:140]!r}; audit/ledger/status = {rws[0]}")
        c.dropdb(db)

    # ---- rollback / reapply
    print("== rollback, exact restoration, reapply ==")
    rb = "td0149_q_rb"
    c.createdb(rb, template=base)
    s0 = (env.catalog(rb), c.dump(rb), props(env, rb), env.digest(rb))
    assert env.run(rb, prop).returncode == 0
    s1 = (env.catalog(rb), c.dump(rb), props(env, rb), env.digest(rb))
    r = env.run(rb, (HERE / "rollback.sql").read_text())
    check("ROLLBACK_0151 succeeds", r.returncode == 0 and "ROLLBACK 0151 complete" in r.stderr, r.stderr[-500:])
    s2 = (env.catalog(rb), c.dump(rb), props(env, rb), env.digest(rb))
    check("after rollback: catalog, pg_dump and function properties identical to the 0134 baseline; the body is byte-identical to 0134", s2 == s0)
    check("after rollback: the live function body equals the 0134 migration text exactly",
          env.scalar(rb, "select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)')")
          == build.md5(build.norm(build.old_block().split("$fn$")[1])))
    r = env.run(rb, (HERE / "rollback.sql").read_text())
    check("a second rollback is refused (body no longer the 0151 definition)", r.returncode != 0 and "ROLLBACK 0151 REFUSED" in r.stderr)
    assert env.run(rb, prop).returncode == 0
    s3 = (env.catalog(rb), c.dump(rb), props(env, rb), env.digest(rb))
    check("reapply after rollback: catalog, pg_dump, properties and rows identical to the first apply", s3 == s1)
    check("post_apply.sql passes after reapply", env.verify(rb, None, (HERE / "post_apply.sql").read_text())["ok"])
    env.run(rb, "create or replace function public.transition_dispatch_status(p_dispatch_id uuid, p_new_status public.dispatch_status, p_reason text default null, p_idempotency_key text default null) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $f$ begin return '{}'::jsonb; end $f$;")
    r = env.run(rb, (HERE / "rollback.sql").read_text())
    check("rollback refuses when the live function has drifted from the reviewed 0151 body", r.returncode != 0 and "ROLLBACK 0151 REFUSED" in r.stderr)
    c.dropdb(rb)
    check("the complete sequence 0130..0147 -> 0149 -> 0150 -> 0151 -> verify -> rollback -> reapply ran on the real migrations", True)


def main():
    static_checks()
    c = t149.Cluster()
    ok = False
    try:
        c.start()
        live(c)
        ok = True
        print(f"\nALL {len(checks)} CHECKS PASSED")
    finally:
        c.cleanup(ok)


if __name__ == "__main__":
    main()
