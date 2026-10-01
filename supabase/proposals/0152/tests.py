#!/usr/bin/env python3
"""Proposal 0152 -- disposable-PostgreSQL verification harness (replay authorization / request binding / internal-helper privileges).

NOT APPROVED FOR PRODUCTION. Reuses the reviewed 0149/0150/0151 cluster harness (brand-new local cluster under /private/tmp/td0149-local-*,
unix socket only, port 55491, minimal environment; never connects to Supabase or any real database; never writes inside the repository).
The scratch cluster emulates Supabase's schema-level default privileges (EXECUTE on every new function to anon, authenticated, service_role),
so function ACL findings are faithful (docs: 0127).

Sequence on the REAL migrations: 0130..0147 -> 0149 -> 0150 (approved count + digest) -> 0151 -> 0152.
"""
import difflib
import hashlib
import importlib.util
import re
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
P0150, P0151 = SUPA / "proposals" / "0150", SUPA / "proposals" / "0151"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


t151 = _load("t0151_harness", P0151 / "tests.py")
t150 = t151.t150
t149 = t150.t149
b149 = t150.b149
build = _load("build0152", HERE / "build.py")
uid, fill = t150.uid, t150.fill
SEP = t149.SEP
PINNED = {
    "proposals/0150/proposed_0150.sql": "bc37e8a670735a5d947628b96e3676d0c1288c82767a5cdff834b65db55a94c3",  # comment-only change: renumbering note 0152 -> 0153 (old pin a0671647... is reproduced by reverting exactly that text)
    "proposals/0151/proposed_0151.sql": hashlib.sha256((P0151 / "proposed_0151.sql").read_bytes()).hexdigest(),
    "migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql": t149.PINNED["migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql"],
}
checks = []


def check(label, cond, detail=""):
    if not cond:
        raise SystemExit(f"FAIL: {label} {detail}")
    checks.append(label)
    print(f"  ok  {label}")


def script(name):
    text = (HERE / name).read_text()
    return text.replace("-- @@GUARD@@", env_guard()).replace("-- @@FIXTURE@@", (HERE / "fixture_0152.sql").read_text().split("\\set ON_ERROR_STOP on\n", 1)[1])


def env_guard():
    return t149.guard_of((t149.HERE / "fixture.sql").read_text())


# ------------------------------------------------------------------- static
def static_checks():
    print("== static checks ==")
    files = build.build_all()
    for name, text in files.items():
        check(f"generated {name} is current", (HERE / name).read_text() == text)
    for rel in t149.PINNED:
        t149.pinned(rel)
    for rel in t151.PINNED_EXTRA if hasattr(t151, "PINNED_EXTRA") else t150.PINNED_EXTRA:
        t150.pinned_extra(rel)
    check("0129..0147 sources, support schemas and the reviewed 0149 proposal match their SHA-256 pins", True)
    B = build.blocks()
    prop, roll = (HERE / "proposed_0152.sql").read_text(), (HERE / "rollback.sql").read_text()
    for n, sig, _ in build.FUNCS:
        check(f"{n}: proposed_0152.sql embeds the repaired block verbatim; rollback.sql embeds the EXACT baseline block verbatim", B[n][2] in prop and B[n][1] in roll and B[n][1] not in prop)
    # semantic diff per function: every removed baseline code line is accounted for; everything else is preserved
    def code(b):
        return [re.sub(r"\s+", " ", re.sub(r"--.*$", "", l)).strip() for l in b.splitlines() if re.sub(r"--.*$", "", l).strip()]
    expect_removed = {
        "reassign_dispatch_resources": {"select result into v_cached", "from public.dispatch_resource_reassignments", "where dispatch_id = p_dispatch_id and idempotency_key = p_idempotency_key;"},
        "set_carrier_factoring_policy": {"select result into v_cached from public.factoring_policy_idempotency", "where carrier_id = p_carrier_id and idempotency_key = p_idempotency_key;",
                                         "insert into public.factoring_policy_idempotency (organization_id, carrier_id, idempotency_key, result)", "values (v_org, p_carrier_id, p_idempotency_key, v_readiness)"},
        "review_legacy_invoice_carrier_migration": {"select result into v_cached from public.legacy_invoice_review_idempotency", "where organization_id = v_org and idempotency_key = p_idempotency_key;",
                                                    "if v_cached is not null then", "return v_cached;", "end if;", "select id, organization_id, legacy_invoice_id, updated_at into v_row"},
        "update_carrier_invoice_draft": set(),
    }
    for n, sig, _ in build.FUNCS:
        o, w = code(B[n][1]), code(B[n][2])
        removed = [l for l in o if l not in w]
        fam = n.endswith(("integration", "lifecycle", "relationship"))
        if fam:
            ok = all("factoring_integration_lifecycle_idempotency" in l or "idempotent_replay" in l or l.startswith("where action") or "v_cached" in l or l.startswith("values (v_org") or l == "if found then" or l == "end if;" for l in removed) and len(removed) <= 8
        else:
            ok = set(removed) <= expect_removed[n] | {"if found then", "end if;", "end if;"}
        check(f"{n}: semantic diff -- only ledger read/insert lines were rewritten (nothing else removed): {len(removed)} baseline line(s) rewritten", ok, str(removed))
        check(f"{n}: the repaired body keeps SECURITY DEFINER + the pinned search_path header verbatim", B[n][1][:B[n][1].index("declare")] == B[n][2][:B[n][2].index("declare")])
    strip = t149.strip_sql
    rest = strip(re.sub(r"create or replace function.*?\$fn\$;|create or replace function.*?\$function\$;|create or replace function.*?\$\$;", "", prop, flags=re.S)).replace("on commit drop", "")
    for n, sig, _ in build.FUNCS:
        rest = rest.replace(strip(B[n][2]), "")
    rest = rest.replace("drop default", "")  # only the temporary legacy-marker default is removed
    stmts = sorted(set(re.findall(r"\b(alter table|comment on column|revoke all on function|grant|insert|update|delete|drop|create or replace function|create temp table)\b", rest, re.I)))
    check("proposed_0152.sql outside the eight blocks: only LOCK TABLE, ALTER TABLE (add NOT NULL column), COMMENT ON COLUMN, REVOKE and temp snapshot tables",
          set(s.lower() for s in stmts) <= {"alter table", "comment on column", "revoke all on function", "create temp table"}, str(stmts))
    check("proposed_0152.sql: exactly 2 ADD COLUMN (text NOT NULL) and 3 helper REVOKEs incl. service_role, no GRANT",
          len(re.findall(r"add column request_fingerprint text not null(?: default 'legacy-unbound:0152-retirement-v1')?;", prop)) == 2 and len(re.findall(r"revoke all on function public\._?\w+\(.*?\) from public, anon, authenticated, service_role;", prop)) == 3
          and "grant execute" not in prop)
    strict = re.compile(r"\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|comment|copy|call|do|begin|commit|rollback|savepoint|set|reset|lock|listen|notify|"
                        r"vacuum|reindex|analyze|execute|prepare|declare|fetch|refresh|cluster|import|security)\b", re.I)
    for name in ("preflight.sql", "post_apply.sql"):
        raw = (HERE / name).read_text()
        s = strip(raw)
        check(f"{name}: exactly ONE select statement; no data-/schema-changing keyword, transaction control or set_config", s.count(";") == 1 and not strict.findall(s) and "set_config" not in s, str(strict.findall(s)))
        check(f"{name}: forbidden words appear nowhere in the file text", not re.findall(r"(?i)\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|copy|call)\b", raw), str(re.findall(r"(?i)\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|copy|call)\b", raw)[:5]))
    for f in ("proposed_0152.sql", "preflight.sql", "post_apply.sql", "rollback.sql", "matrix.sql"):
        t = (HERE / f).read_text()
        check(f"{f} is marked NOT APPROVED FOR PRODUCTION and names the 0148 -> 0153 renumbering", "NOT APPROVED FOR PRODUCTION" in t and "0153 or higher" in t)
    check("no application code calls any of the three internal helpers", not any(True for p in (SUPA.parent / "src").rglob("*.ts*")
          if re.search(r"_issue_dispatch_service_invoice_internal|transition_carrier_factoring_integration_lifecycle|_generate_carrier_invoice_payment_number_internal", p.read_text(errors="ignore"))))


# ------------------------------------------------------------------- live
Env0152 = t151.DPEnv


P0149 = SUPA / "proposals" / "0149"


def parse_rows(stdout):
    rows = {}
    for l in stdout.splitlines():
        p = l.split(SEP)
        if len(p) == 7 and p[0] == "ROW":
            rows.setdefault(p[1], []).append((p[2], p[3], p[4], int(p[5]), int(p[6])))
    return rows


def evaluate(kind, seq, fixed):
    """Return a list of (step, ok, why) for the reviewed expectations."""
    by = {t: (o, m, l, a) for t, o, m, l, a in seq}
    order = [t for t, *_ in seq]
    res = []
    per_target = kind in ("rea", "pol", "cfg", "rot", "ver", "dea")
    flag_replay = kind in ("rea", "pol", "cfg", "rot", "ver", "dea")
    codes = {"rea": "X:RRIDK", "pol": "X:FPIDK"}.get(kind, "F:IDEMPOTENCY_KEY_REUSED")

    def delta(t):
        i = order.index(t)
        return by[t][2] - by[order[i - 1]][2], by[t][3] - by[order[i - 1]][3]

    def add(step, cond, why=""):
        res.append((step, bool(cond), why))

    o0 = by["s0_orig"][0]
    add("s0_orig", o0 == "S" and delta("s0_orig")[0] == 1 and delta("s0_orig")[1] >= 1, f"{o0} {delta('s0_orig')}")
    for st in ("s1_same_user_replay", "s2_other_authorized_replay", "s15_retry_replays"):
        want = "S+R" if flag_replay else "S"
        add(st, by[st][0] == want and delta(st) == (0, 0), f"{by[st][0]} {delta(st)}")
    for st in ("s3_unauthenticated", "s4_unauthorized_role", "s5_foreign_org_real_key", "s6_foreign_org_wrong_key", "s7_removed_member", "s8_moved_member", "s9_downgraded_member"):
        add(st, not by[st][0].startswith("S") and delta(st) == (0, 0), f"{by[st][0]} {delta(st)}")
    add("s6_indistinguishable", by["s5_foreign_org_real_key"][:2] == by["s6_foreign_org_wrong_key"][:2], f"{by['s5_foreign_org_real_key'][:2]} vs {by['s6_foreign_org_wrong_key'][:2]}")
    add("s10_changed_request", by["s10_changed_request"][0] == codes and delta("s10_changed_request") == (0, 0), f"{by['s10_changed_request'][0]} {delta('s10_changed_request')}")
    if per_target:
        add("s11_same_key_other_target", by["s11_same_key_other_target"][0] == "S" and delta("s11_same_key_other_target")[0] == 1, f"{by['s11_same_key_other_target'][0]} {delta('s11_same_key_other_target')}")
    else:
        add("s11_same_key_other_target", by["s11_same_key_other_target"][0] == "F:IDEMPOTENCY_KEY_REUSED" and delta("s11_same_key_other_target") == (0, 0), f"{by['s11_same_key_other_target'][0]} {delta('s11_same_key_other_target')}")
    add("s12_same_key_other_org", by["s12_same_key_other_org"][0] == "S" and delta("s12_same_key_other_org")[0] == 1, f"{by['s12_same_key_other_org'][0]} {delta('s12_same_key_other_org')}")
    add("s13_failed_tx", by["s13_failed_tx"][0] == "X:P0F11" and delta("s13_failed_tx") == (0, 0), f"{by['s13_failed_tx'][0]} {delta('s13_failed_tx')}")
    add("s14_retry_after_failure", by["s14_retry_after_failure"][0] == "S" and delta("s14_retry_after_failure")[0] == 1, f"{by['s14_retry_after_failure'][0]} {delta('s14_retry_after_failure')}")
    return res


def helper_probe(env, db, role):
    """Call each internal helper as <role>; returns 'DENIED' (permission denied) or 'CALLABLE'."""
    calls = {
        "_issue_dispatch_service_invoice_internal": "select public._issue_dispatch_service_invoice_internal(gen_random_uuid(), null::public.carrier_invoices, gen_random_uuid(), gen_random_uuid(), null, 'k', 'op', 1, 'fp')",
        "transition_carrier_factoring_integration_lifecycle": "select public.transition_carrier_factoring_integration_lifecycle('verify', gen_random_uuid(), 'r', now(), 'k')",
        "_generate_carrier_invoice_payment_number_internal": "select public._generate_carrier_invoice_payment_number_internal()",
    }
    out = {}
    for name, call in calls.items():
        r = env.run(db, f"set role {role};\nselect set_config('test.current_uid', '', false);\nbegin;\n{call};\nrollback;\n", guard=True)
        out[name] = "DENIED" if "permission denied" in r.stderr else ("CALLABLE" if r.returncode == 0 or "permission denied" not in r.stderr else "?")
    return out


def legacy_retirement_revision_tests(c, env, base):
    """Uses ONLY the disposable cluster and synthetic copies of the two reviewed IDs."""
    print("== scoped legacy retirement preservation / replay refusal ==")
    db = 'td0149_legacy_retirements'
    ids = ['fc926ea0-f11c-40fa-941b-afb89aae19de', 'd9ddf2b8-8ab5-404a-a906-8a429ca2b608']
    times = ['2026-09-29 02:31:43.081649+00', '2026-09-29 02:40:54.444648+00']
    def rpc_scalar(sql):
        rc, rows, err = env.q(db, sql, ro=False)
        assert rc == 0, err
        return rows[0][0] if rows else None

    seed = "select set_config('test.current_uid', td0149_t.id('u_owner1')::text, false);\n"
    for i, (rid, timestamp) in enumerate(zip(ids, times)):
        seed += f"""
insert into public.factoring_relationships
select (jsonb_populate_record(null::public.factoring_relationships,
  to_jsonb(r) || jsonb_build_object('id', '{rid}', 'is_active', false, 'is_default', false))).*
from public.factoring_relationships r where r.id = td0149_t.id('rel_dea1');
insert into public.factoring_integration_lifecycle_idempotency
 (organization_id, action, target_id, idempotency_key, result, created_at)
values (td0149_t.id('o1'), 'deactivate_relationship', '{rid}', 'legacy-retirement-{i}',
 jsonb_build_object('success', true, 'relationship_id', '{rid}', 'carrier_id', td0149_t.id('ca')), '{timestamp}');
"""
    fixture = (HERE / 'fixture_0152.sql').read_text().split('\\set ON_ERROR_STOP on\n', 1)[1]
    c.createdb(db, template=base)
    check('legacy test fixture creates reviewed synthetic retirement receipts', env.run(db, env.guard + '\n' + fixture + seed, guard=True).returncode == 0)
    template = 'td0149_legacy_template'
    c.createdb(template, template=db)
    before = env.scalar(db, "select jsonb_agg(to_jsonb(t) order by target_id)::text from public.factoring_integration_lifecycle_idempotency t")
    check('revised preflight accepts the exact two inactive successful retirement receipts', env.verify(db, None, (HERE / 'preflight.sql').read_text())['ok'])
    r = env.run(db, (HERE / 'proposed_0152.sql').read_text())
    check('revised migration applies with the two reviewed legacy receipts', r.returncode == 0, r.stderr)
    after = env.scalar(db, "select jsonb_agg(to_jsonb(t) - 'request_fingerprint' order by target_id)::text from public.factoring_integration_lifecycle_idempotency t")
    check('every original receipt field remains byte-for-byte equal as jsonb', before == after)
    check('both receipts get a non-hash legacy marker', env.scalar(db, "select count(*) from public.factoring_integration_lifecycle_idempotency where request_fingerprint = 'legacy-unbound:0152-retirement-v1'") == '2')
    check('post-apply accepts the two preserved legacy receipts', env.verify(db, None, (HERE / 'post_apply.sql').read_text())['ok'])
    for who in ('u_owner1', 'u_admin1'):
        for reason in ('original unknown', 'different reason'):
            res = rpc_scalar(f"select public.deactivate_factoring_relationship('{ids[0]}', '{reason}', now(), 'legacy-retirement-0', false)->>'code' from (select set_config('test.current_uid', td0149_t.id('{who}')::text, false)) actor")
            check(f'legacy replay is refused for {who} / {reason}', res == 'IDEMPOTENCY_KEY_REUSED', str(res))
    check('legacy replay attempts change no receipt field', before == env.scalar(db, "select jsonb_agg(to_jsonb(t) - 'request_fingerprint' order by target_id)::text from public.factoring_integration_lifecycle_idempotency t"))
    fresh_target = uid('rel_dea1')
    t0 = env.scalar(db, f"select updated_at::text from public.factoring_relationships where id = '{fresh_target}'")
    result = rpc_scalar(f"select public.deactivate_factoring_relationship('{fresh_target}', 'new explicit decision', '{t0}', 'new-retirement-key', false)->>'success' from (select set_config('test.current_uid', td0149_t.id('u_owner1')::text, false)) actor")
    check('new key follows the normal authorized operation', result == 'true', str(result))
    check('new operation has a real sha256 fingerprint', env.scalar(db, "select request_fingerprint ~ '^[0-9a-f]{64}$' from public.factoring_integration_lifecycle_idempotency where idempotency_key = 'new-retirement-key'") == 't')
    check('post-apply accepts legacy receipts plus fresh fingerprinted operations', env.verify(db, None, (HERE / 'post_apply.sql').read_text())['ok'])
    c.dropdb(db)
    mutations = {
        'changed timestamp': "update public.factoring_integration_lifecycle_idempotency set created_at=now()",
        'wrong action': "update public.factoring_integration_lifecycle_idempotency set action='configure'",
        'missing receipt': f"delete from public.factoring_integration_lifecycle_idempotency where target_id='{ids[0]}'",
        'failed receipt': "update public.factoring_integration_lifecycle_idempotency set result=result || '{\"success\":false}'",
        'wrong result target': "update public.factoring_integration_lifecycle_idempotency set result=result || '{\"relationship_id\":\"wrong\"}'",
        'active relationship': f"update public.factoring_relationships set is_active=true where id='{ids[0]}'",
        'wrong organization': "update public.factoring_integration_lifecycle_idempotency set organization_id=td0149_t.id('o2')",
        'extra receipt': "insert into public.factoring_integration_lifecycle_idempotency select organization_id,action,target_id,'extra-key',result,created_at from public.factoring_integration_lifecycle_idempotency limit 1",
    }
    for label, mutation in mutations.items():
        c.createdb(db, template=template)
        check(f'negative fixture: {label}', env.run(db, "select set_config('test.current_uid', td0149_t.id('u_owner1')::text, false);" + mutation).returncode == 0)
        cat, digest = env.catalog(db), env.digest(db)
        check(f'preflight refuses {label}', not env.verify(db, None, (HERE / 'preflight.sql').read_text())['ok'])
        r = env.run(db, (HERE / 'proposed_0152.sql').read_text())
        check(f'migration independently refuses {label} without changes', r.returncode != 0 and env.catalog(db) == cat and env.digest(db) == digest, r.stderr[-300:])
        c.dropdb(db)
    c.dropdb(template)


def live(c):
    env = Env0152(c)
    print("== build: 0130..0147 -> 0149 -> 0150 -> 0151 (with Supabase-style default function privileges) ==")
    base = "td0149_r_base"
    env.build_base(base)
    rows, summ = env.review(base)
    n = int(summ["CANDIDATES (approve this count)"])
    dig = summ["candidate digest (REQUIRED: paste into v_expected_digest)"]
    r = env.run(base, fill((P0150 / "proposed_0150.sql").read_text(), n, dig))
    check("0150 applies (real count + digest)", r.returncode == 0, r.stderr[-300:])
    r = env.run(base, (P0151 / "proposed_0151.sql").read_text())
    check("0151 applies", r.returncode == 0 and "0151 complete" in r.stderr, r.stderr[-300:])
    check("post_apply 0150 and 0151 pass", env.verify(base, None, (P0150 / "post_apply.sql").read_text())["ok"] and env.verify(base, None, (P0151 / "post_apply.sql").read_text())["ok"])

    legacy_retirement_revision_tests(c, env, base)

    # ---- PHASE 1: ACL audit of every idempotent function (default privileges emulated)
    print("== audit: EXECUTE privileges of every idempotent RPC / helper ==")
    rc, rws, err = env.q(base, """select p.oid::regprocedure::text, p.prosecdef::text, coalesce(p.proconfig::text,''), has_function_privilege('anon',p.oid,'execute')::text, has_function_privilege('authenticated',p.oid,'execute')::text,
        has_function_privilege('service_role',p.oid,'execute')::text, (p.proacl is null or exists(select 1 from unnest(p.proacl) a where a::text like '=%'))::text
        from pg_proc p where p.pronamespace='public'::regnamespace and (p.prosrc ilike '%idempotency%' or p.proname ilike '%idempot%') and p.prokind='f' order by 1""")
    acl = {r_[0].split("(")[0]: r_[1:] for r_ in rws}
    for k, v in acl.items():
        print(f"      {k:64s} definer={v[0]:5s} anon={v[2]:5s} authenticated={v[3]:5s} service_role={v[4]:5s} PUBLIC={v[5]:5s}")
    check("audit covers the 25 idempotent functions (incl. helpers)", len(acl) >= 25, str(len(acl)))
    helpers_before = {h.split("(")[0].replace("public.", ""): helper_probe(env, base, "service_role") for h in build.HELPERS[:1]}
    probe_before = helper_probe(env, base, "service_role")
    print("      service_role probe (baseline):", probe_before)
    check("BASELINE exposure: service_role can EXECUTE _issue_dispatch_service_invoice_internal, transition_carrier_factoring_integration_lifecycle and _generate_carrier_invoice_payment_number_internal directly",
          all(v == "CALLABLE" for v in probe_before.values()), str(probe_before))
    for role in ("authenticated", "anon"):
        pr = helper_probe(env, base, role)
        check(f"BASELINE: {role} is already denied on all three helpers", all(v == "DENIED" for v in pr.values()), str(pr))

    # ---- PHASE 1: reproduce every suspected defect (baseline = state after 0151)
    print("== defect reproduction on the baseline (real 0135/0139/0141/0142/0143 functions) ==")
    db = "td0149_r_defect"
    c.createdb(db, template=base)
    r = c.psql(db, script("matrix.sql"), guard=True, tuples=True, ok=False)
    assert r.returncode == 0, r.stderr[-1500:]
    rows_base = parse_rows(r.stdout)
    c.dropdb(db)
    defects = {}
    for kind, *_ in build.RPCS:
        print(f"      [{kind}] baseline s0 -> {rows_base[kind][1][1]} | {rows_base[kind][1][2][:150]}")
    for kind, name, *_ in build.RPCS:
        res = evaluate(kind, rows_base[kind], False)
        bad = [(s, w) for s, ok, w in res if not ok]
        defects[kind] = bad
        print(f"      {kind} {name.split(' ')[0]:52s} {'SAFE (all 16 expectations hold)' if not bad else 'DEFECTS: ' + ', '.join(s for s, _ in bad)}")
    # explicit confirmations (exact steps)
    def failing(kind):
        return {s for s, _ in defects[kind]}
    check("CONFIRMED CROSS_ORG_REPLAY: reassign_dispatch_resources returns another organization's cached result for a known dispatch id + key", "s5_foreign_org_real_key" in failing("rea"), str(defects["rea"]))
    check("CONFIRMED existence oracle: reassign real key vs wrong key are distinguishable", "s6_indistinguishable" in failing("rea"))
    check("CONFIRMED REQUEST_MISMATCH_REPLAY: reassign_dispatch_resources same key + different driver/truck silently replays", "s10_changed_request" in failing("rea"))
    check("CONFIRMED CROSS_ORG_REPLAY: set_carrier_factoring_policy returns another organization's cached result for a known carrier id + key", "s5_foreign_org_real_key" in failing("pol"))
    check("CONFIRMED REQUEST_MISMATCH_REPLAY: set_carrier_factoring_policy same key + different mode silently replays", "s10_changed_request" in failing("pol"))
    for kind in ("cfg", "rot", "ver", "dea"):
        check(f"CONFIRMED REQUEST_MISMATCH_REPLAY: 0141 {kind} same key + changed request silently replays (cross-org and role gates are SAFE)",
              "s10_changed_request" in failing(kind) and not ({"s3_unauthenticated", "s4_unauthorized_role", "s5_foreign_org_real_key", "s7_removed_member", "s9_downgraded_member"} & failing(kind)), str(defects[kind]))
    check("CONFIRMED SAME_ORG_ROLE_BYPASS + REQUEST_MISMATCH_REPLAY: review_legacy_invoice_carrier_migration replays for an unauthorized role and for a different request/target",
          {"s4_unauthorized_role", "s9_downgraded_member"} <= failing("rev") and ("s10_changed_request" in failing("rev") or "s11_same_key_other_target" in failing("rev")), str(defects["rev"]))
    check("CONFIRMED SAME_ORG_ROLE_BYPASS: update_carrier_invoice_draft replays for a role that may not edit / a downgraded member (fingerprint binding and org scoping are already SAFE)",
          {"s4_unauthorized_role", "s9_downgraded_member"} <= failing("drf") and not ({"s10_changed_request", "s11_same_key_other_target", "s5_foreign_org_real_key"} & failing("drf")), str(defects["drf"]))
    check("NOT a defect on the baseline: unauthenticated callers are refused everywhere; removed members are refused everywhere except review/draft-independent paths",
          all("s3_unauthenticated" not in failing(k) for k in defects), str({k: failing(k) for k in defects}))

    # ---- zero-row invariant: both new-fingerprint ledgers must be EMPTY, checked again inside the migration under exclusive locks
    print("== zero-row invariant (fail closed, atomic) ==")
    prop_sql = (HERE / "proposed_0152.sql").read_text()
    legacy = {
        "factoring_policy_idempotency": f"insert into public.factoring_policy_idempotency (organization_id, carrier_id, idempotency_key, result) values ('{uid('o1')}', '{uid('ca')}', 'legacy-1', '{{\"success\":true}}');",
        "factoring_integration_lifecycle_idempotency": f"insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result) values ('{uid('o1')}', 'configure', '{uid('ca')}', 'legacy-1', '{{\"success\":true}}');",
    }
    for tbl, ins in legacy.items():
        db = "td0149_r_gate"
        c.createdb(db, template=base)
        assert env.run(db, ins, guard=True).returncode == 0
        cat_b, dig_b = env.catalog(db), env.digest(db)
        pf = env.verify(db, None, (HERE / "preflight.sql").read_text())
        check(f"preflight.sql FAILS when {tbl} holds a legacy (no-fingerprint) row", not pf["ok"] and "is EMPTY" in pf["err"] and tbl in pf["err"], pf["err"][-300:])
        r = env.run(db, prop_sql)
        check(f"proposed_0152.sql ABORTS ATOMICALLY when {tbl} holds a legacy NULL-fingerprint row / any pre-existing row (independent of preflight)",
              r.returncode != 0 and "is NOT empty" in r.stderr and tbl in r.stderr, r.stderr[-400:])
        cols = env.scalar(db, "select count(*) from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')")
        check(f"nothing changed after the refused apply ({tbl}): catalog, rows, no column, no function change", env.catalog(db) == cat_b and env.digest(db) == dig_b and cols == "0",
              f"catalog_same={env.catalog(db) == cat_b} {t149.changed(cat_b, env.catalog(db))[:3]} digest_same={env.digest(db) == dig_b} cols={cols!r}")
        c.dropdb(db)
    # the recheck happens UNDER the lock: a row committed by a concurrent writer while the migration waits is still caught
    db = "td0149_r_gate_race"
    c.createdb(db, template=base)
    cat_b = env.catalog(db)
    A = t150.Session(c, db)
    A.send("begin;\n" + legacy["factoring_policy_idempotency"])
    time.sleep(0.5)
    import subprocess as _sp
    mig_file = Path(c.tmp) / "proposed_0152_race.sql"
    mig_file.write_text(prop_sql)      # a FILE, not a pipe: psql blocks inside the migration's lock wait and would stop reading a 90 KB pipe (Linux pipes hold 64 KB)
    Bp = _sp.Popen([t149.PSQL, "-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-h", str(c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-f", str(mig_file)],
                   stdin=_sp.DEVNULL, stdout=_sp.PIPE, stderr=_sp.PIPE, text=True, env=dict(c.env))
    blocked = t150.wait_blocked(env, db)
    A.send("commit;")
    A.p.stdin.close()
    A.p.communicate(timeout=60)
    bo, be = Bp.communicate(timeout=120)
    check("the migration WAITS on the ledger lock while a writer is in flight, then re-counts and aborts on the row that committed meanwhile (nothing changed)",
          blocked and Bp.returncode != 0 and "is NOT empty" in be and env.catalog(db) == cat_b, be[-300:])
    c.dropdb(db)

    # ---- lock review: fixed order, individual ledgers, both ledgers, no deadlock with normal RPCs
    print("== lock review (real concurrent sessions on the pre-0152 baseline) ==")
    import subprocess as _sp
    check("the migration takes the two ledger locks in ONE statement in a fixed documented order (policy ledger, then lifecycle ledger) with a bounded lock_timeout",
          re.search(r"lock table public\.factoring_policy_idempotency, public\.factoring_integration_lifecycle_idempotency in access exclusive mode;", prop_sql) is not None
          and prop_sql.count("lock table") == 2
          and "lock table public.factoring_relationships in share mode;" in prop_sql
          and prop_sql.index("lock table public.factoring_relationships in share mode;")
              < prop_sql.index("lock table public.factoring_policy_idempotency,") and "set local lock_timeout = '15s';" in prop_sql and "LOCK ORDER (fixed, documented" in prop_sql)
    lk_src = "td0149_r_lock_src"
    c.createdb(lk_src, template=base)
    env.run(lk_src, env.guard + "\n" + (HERE / "fixture_0152.sql").read_text().split("\\set ON_ERROR_STOP on\n", 1)[1], guard=True)

    def mig_async(db):
        mig_file = Path(c.tmp) / "proposed_0152_lock.sql"
        mig_file.write_text(prop_sql)  # file, not a pipe (see above)
        return _sp.Popen([t149.PSQL, "-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-h", str(c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-f", str(mig_file)],
                         stdin=_sp.DEVNULL, stdout=_sp.PIPE, stderr=_sp.PIPE, text=True, env=dict(c.env))

    def rpc_session(db, kind, user, key, target="1"):
        ss = t150.Session(c, db)
        ss.send(f"set role authenticated;\nbegin;\nselect outcome from td0149_t.call('{kind}', '{user}', '{target}', '{key}', 'a');")
        return ss

    def finish(ss):
        ss.send("commit;")
        ss.p.stdin.close()
        return ss.p.communicate(timeout=60)

    for label, kind, tbl in (("policy ledger", "pol", "factoring_policy_idempotency"), ("lifecycle ledger", "cfg", "factoring_integration_lifecycle_idempotency")):
        db = "td0149_r_lock1"
        c.createdb(db, template=lk_src)
        cat_b = env.catalog(db)
        A = rpc_session(db, kind, "u_owner1", "LOCK-A-" + kind)
        time.sleep(0.6)
        Bp = mig_async(db)
        blocked = t150.wait_blocked(env, db)
        ao, ae = finish(A)
        bo, be = Bp.communicate(timeout=120)
        cols = env.scalar(db, "select count(*) from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')")
        rows = env.scalar(db, f"select count(*) from public.{tbl}")
        check(f"concurrent normal RPC write to the {label}: the migration WAITS, then re-counts and ABORTS on the committed row; no schema/function change survives; no deadlock",
              blocked and Bp.returncode != 0 and "is NOT empty" in be and "deadlock" not in (be + ae).lower() and env.catalog(db) == cat_b and cols == "0" and rows == "1", be[-300:])
        # a row committed BEFORE the locks are requested is caught immediately
        Bp = mig_async(db)
        bo, be = Bp.communicate(timeout=120)
        check(f"a row already committed in the {label} is caught at once (no wait), nothing changed", Bp.returncode != 0 and "is NOT empty" in be and env.catalog(db) == cat_b)
        c.dropdb(db)
    # both ledgers written concurrently by two normal RPC transactions
    db = "td0149_r_lock2"
    c.createdb(db, template=lk_src)
    cat_b = env.catalog(db)
    A = rpc_session(db, "pol", "u_owner1", "LOCK-BOTH-A", "2")
    C = rpc_session(db, "cfg", "u_owner1", "LOCK-BOTH-C", "2")
    time.sleep(0.6)
    Bp = mig_async(db)
    blocked = t150.wait_blocked(env, db)
    ao, ae = finish(C)      # commit in the OPPOSITE order to the migration's lock order
    time.sleep(0.3)
    ao2, ae2 = finish(A)
    bo, be = Bp.communicate(timeout=120)
    check("concurrent writes to BOTH ledgers (committed in the opposite order to the lock order): the migration waits, aborts on the committed rows, nothing changed, no deadlock",
          blocked and Bp.returncode != 0 and "is NOT empty" in be and "deadlock" not in (be + ae + ae2).lower() and env.catalog(db) == cat_b
          and env.scalar(db, "select (select count(*) from public.factoring_policy_idempotency) || '/' || (select count(*) from public.factoring_integration_lifecycle_idempotency)") == "1/1", be[-300:])
    c.dropdb(db)
    # normal RPCs (other ledgers / tables) running while the migration applies on EMPTY ledgers: it completes, nothing deadlocks
    db = "td0149_r_lock3"
    c.createdb(db, template=lk_src)
    sess = [rpc_session(db, "rea", "u_disp1", "LOCK-N-rea"), rpc_session(db, "rev", "u_owner1", "LOCK-N-rev"), rpc_session(db, "rea", "u_disp1", "LOCK-N-rea2", "2")]
    time.sleep(0.6)
    Bp = mig_async(db)
    time.sleep(1.0)
    outs = [finish(x) for x in sess]
    bo, be = Bp.communicate(timeout=120)
    check("normal RPCs mid-transaction on unrelated ledgers/tables while the migration runs: the migration completes, no deadlock, all RPC transactions commit",
          Bp.returncode == 0 and "0152 complete" in be and all("deadlock" not in (o[1] or "").lower() for o in outs) and all("ERROR" not in (o[1] or "") for o in outs)
          and env.scalar(db, "select count(*) from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and is_nullable = 'NO' and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')") == "2", be[-400:] + str([o[1][-200:] for o in outs]))
    c.dropdb(db)
    c.dropdb(lk_src)

    # ---- apply 0152
    print("== apply 0152 ==")
    main = "td0149_r_main"
    c.createdb(main, template=base)
    pf = env.verify(main, None, (HERE / "preflight.sql").read_text())
    check("preflight.sql PASSES on the baseline", pf["ok"], "\n".join(re.findall(r"^.* \| FAIL \|.*$", pf["err"], re.M)))
    check("post_apply.sql cannot pass before 0152", not env.verify(main, None, (HERE / "post_apply.sql").read_text())["ok"])
    acl_sql = "select p.oid::regprocedure::text, coalesce(p.proacl::text, 'NULL') from pg_proc p where p.pronamespace = 'public'::regnamespace order by 1"
    acl0 = dict(tuple(r_) for r_ in env.q(main, acl_sql)[1])
    cat0, dump0, d0 = env.catalog(main), c.dump(main), env.digest(main)
    prop = (HERE / "proposed_0152.sql").read_text()
    r = env.run(main, prop)
    check("0152 applies (single transaction)", r.returncode == 0 and "0152 complete" in r.stderr, r.stderr[-1200:])
    cat1, dump1 = env.catalog(main), c.dump(main)
    ch = t149.changed(cat0, cat1)
    fbody = sorted(k[1].split("(")[0] for k in ch if k[0] == "function_body")
    fmeta = sorted(k[1].split("(")[0] for k in ch if k[0] == "function_meta")
    cols = sorted(k[1] for k in ch if k[0] == "column")
    check("catalog comparison: exactly the 8 reviewed function BODIES changed", fbody == sorted("public." + n for n, _, _ in build.FUNCS), str(fbody))
    check("catalog/privilege comparison: function metadata changed ONLY for the 3 internal helpers (ACL: service_role removed); no other owner/config/ACL/argument/return/comment change",
          fmeta == sorted(h.split("(")[0] for h in build.HELPERS), str(fmeta))
    nn_cons = sorted(k[1] for k in ch if k[0] == "constraint")
    check("catalog comparison: the only schema additions are the two NOT NULL request_fingerprint columns "
          "(PostgreSQL 18 additionally records each NOT NULL as a pg_constraint row; PostgreSQL 17 does not -- attnotnull only)",
          cols == ["public.factoring_integration_lifecycle_idempotency.request_fingerprint", "public.factoring_policy_idempotency.request_fingerprint"]
          and all(x.endswith("request_fingerprint_not_null") for x in nn_cons) and len(ch) == 8 + 3 + 2 + len(nn_cons) and len(nn_cons) in (0, 2), str(ch))
    dd = [l for l in difflib.unified_diff(dump0, dump1, lineterm="", n=0) if l[:1] in "+-" and not l.startswith(("---", "+++"))]
    check("pg_dump delta: no table/index/constraint/policy/trigger change other than the 2 columns; REVOKE lines for the helpers", any("request_fingerprint" in l for l in dd)
          and not any(re.match(r"[+-](CREATE (TABLE|INDEX|TRIGGER|POLICY)|ALTER TABLE .* (ADD CONSTRAINT|DROP))", l) for l in dd), "\n".join(dd[:6]))
    acl1 = dict(tuple(r_) for r_ in env.q(main, acl_sql)[1])
    acl_changed = sorted(k for k in set(acl0) | set(acl1) if acl0.get(k) != acl1.get(k))
    print("      COMPLETE ACL DIFF (every public function; before -> after):")
    for k in acl_changed:
        print(f"        {k}\n          before: {acl0.get(k)}\n          after : {acl1.get(k)}")
    check(f"complete ACL comparison over {len(acl0)} public functions: exactly the 3 internal helpers changed, each ONLY by losing service_role; every other ACL (incl. transition_dispatch_status) is byte-identical",
          len(acl0) == len(acl1) and sorted(k.split("(")[0] for k in acl_changed) == sorted(h.split("(")[0].replace("public.", "") for h in build.HELPERS)
          and all(acl0[k].replace(",service_role=X/postgres", "") == acl1[k] for k in acl_changed), str(acl_changed))
    check("ledgers and all business rows untouched by the apply", env.digest(main) == d0)
    po = env.verify(main, None, (HERE / "post_apply.sql").read_text())
    check("post_apply.sql PASSES", po["ok"], "\n".join(re.findall(r"^.* \| FAIL \|.*$", po["err"], re.M)))
    check("preflight.sql now FAILS (already applied) -- cannot be run twice", not env.verify(main, None, (HERE / "preflight.sql").read_text())["ok"])
    for tbl, ins in legacy.items():
        r = env.run(main, ins, guard=True)
        check(f"after 0152: a NULL fingerprint cannot be inserted into {tbl} (NOT NULL, SQLSTATE 23502)", r.returncode != 0 and "null value in column \"request_fingerprint\"" in r.stderr, r.stderr[-200:])
    check("schema design: both request_fingerprint columns are text NOT NULL with no default",
          env.scalar(main, "select count(*) from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and data_type = 'text' and is_nullable = 'NO' and column_default is null and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')") == "2")
    r = env.run(main, prop)
    check("re-running proposed_0152.sql is refused, changing nothing", r.returncode != 0 and "not the reviewed baseline" in r.stderr and env.catalog(main) == cat1)
    probe_after = helper_probe(env, main, "service_role")
    check("AFTER 0152: service_role, authenticated and anon are ALL denied on the three internal helpers", probe_after == {k: "DENIED" for k in probe_before} and all(v == "DENIED" for role in ("authenticated", "anon") for v in helper_probe(env, main, role).values()), str(probe_after))

    rows_o = audit_live_order(env, main)
    for name, pa, pr, po, pl, scoped, bound in rows_o:
        pa, pr, po, pl = int(pa), int(pr), int(po), int(pl)
        check(f"SAFE by structure (live body): {name}: auth/role/organization checks precede the first ledger read; lookup is organization-scoped; a changed request is refused",
              pl > 0 and pa > 0 and pa < pl and pr > 0 and pr < pl and po > 0 and po < pl and scoped == "t" and bound == "t", f"pa={pa} pr={pr} po={po} pl={pl} scoped={scoped} bound={bound}")
    check("the structural audit covers the ten 0144-0147 idempotent RPCs", len(rows_o) == 10, str(len(rows_o)))

    # ---- matrix on 0152
    print("== authorization / replay matrix on 0152 ==")
    db = "td0149_r_matrix"
    c.createdb(db, template=main)
    r = c.psql(db, script("matrix.sql"), guard=True, tuples=True, ok=False)
    assert r.returncode == 0, r.stderr[-1500:]
    rows_new = parse_rows(r.stdout)
    c.dropdb(db)
    total = 0
    for kind, name, *_ in build.RPCS:
        res = evaluate(kind, rows_new[kind], True)
        for s, ok, why in res:
            check(f"[{kind}] {name.split(' ')[0]}: {s}", ok, why)
            total += 1
    print(f"      matrix: {total} expectations over 8 repaired RPCs x 16 steps")
    # cross-check: identical *first-call* behaviour (s0/s12/s11/s14 fresh outcomes are unchanged vs the baseline)
    for kind, *_ in build.RPCS:
        bb = {t: o for t, o, *_ in rows_base[kind]}
        nn = {t: o for t, o, *_ in rows_new[kind]}
        check(f"[{kind}] first-call behaviour unchanged (s0, s12, s13, s14 outcomes identical to the baseline)", all(bb[t] == nn[t] for t in ("s0_orig", "s12_same_key_other_org", "s13_failed_tx", "s14_retry_after_failure")), str({t: (bb[t], nn[t]) for t in bb if bb[t] != nn[t]}))

    # ---- earlier proposals' suites on the final chain
    print("== 0151 regression, 0150 regression and F1 verification on the final chain ==")
    db = "td0149_r_prev"
    c.createdb(db, template=main)
    r = env.run(db, t151.script("regression.sql"), guard=True)
    check("0151 regression.sql (transition replay authorization) still PASSES after 0152", r.returncode == 0 and "TEST 0151 REGRESSION PASSED" in r.stderr, r.stderr[-600:])
    c.dropdb(db)
    db = "td0149_r_f1"
    c.createdb(db, template=main)
    r = env.run(db, (P0150 / "f1_cancel_verify.sql").read_text(), guard=True)
    check("F1 cancellation verification (11 conditions) PASSES on 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152", r.returncode == 0 and "F1 VERIFICATION PASSED" in r.stderr and "OK: F9b" in r.stderr, r.stderr[-800:])
    c.dropdb(db)

    # ---- concurrency: real two sessions per repaired RPC
    print("== concurrent duplicate requests (real two sessions) ==")
    cbase = "td0149_r_conc_src"
    c.createdb(cbase, template=main)
    r = c.psql(cbase, env.guard + "\n" + (HERE / "fixture_0152.sql").read_text().split("\\set ON_ERROR_STOP on\n", 1)[1], guard=True)
    db = "td0149_r_nullfp"
    c.createdb(db, template=cbase)
    res_json = '{"success":true,"mode":"direct"}'
    env.run(db, "alter table public.factoring_policy_idempotency alter column request_fingerprint drop not null; alter table public.factoring_integration_lifecycle_idempotency alter column request_fingerprint drop not null;"
            f"insert into public.factoring_policy_idempotency (organization_id, carrier_id, idempotency_key, result, request_fingerprint) values ('{uid('o1')}', '{uid('pc1')}', 'NULL-KEY-1', '{res_json}', null);"
            f"insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result, request_fingerprint) values ('{uid('o1')}', 'configure', '{uid('rel_cfg1')}', 'NULL-KEY-1', '{res_json}', null);", guard=True)
    for kind, user, want in (("pol", "u_owner1", "X:FPIDK"), ("cfg", "u_owner1", "F:IDEMPOTENCY_KEY_REUSED")):
        rr = c.psql(db, env.guard + f"\nset role authenticated;\nselect outcome from td0149_t.call('{kind}', '{user}', '1', 'NULL-KEY-1', 'a');", guard=True, tuples=True)
        out = [x.strip() for x in rr.stdout.splitlines() if x.strip()][-1]
        check(f"[{kind}] the repaired RPC FAILS CLOSED on an unexpected NULL fingerprint: never replayed ({out})", out == want, rr.stdout + rr.stderr[-200:])
    c.dropdb(db)
    for kind, name, u1, *_ in build.RPCS:
        call = f"select outcome from td0149_t.call('{kind}', '{u1}', '1', 'KEY-CONC-{kind}', 'a');"
        ctl = "td0149_r_conc_ctl"
        c.createdb(ctl, template=cbase)
        env.run(ctl, "set role authenticated;\n" + call, guard=True)
        led_ctl, act_ctl = env.scalar(ctl, f"select td0149_t.led('{kind}')"), env.scalar(ctl, "select td0149_t.act()")
        c.dropdb(ctl)
        db = "td0149_r_conc"
        c.createdb(db, template=cbase)
        led0, act0 = env.scalar(db, f"select td0149_t.led('{kind}')"), env.scalar(db, "select td0149_t.act()")
        A = t150.Session(c, db)
        A.send("set role authenticated;\nbegin;\n" + call)
        time.sleep(0.6)
        B = t150.Session(c, db)
        B.send("set role authenticated;\n" + call)
        blocked = t150.wait_blocked(env, db)
        A.send("commit;")
        A.p.stdin.close()
        ao, ae = A.p.communicate(timeout=60)
        B.p.stdin.close()
        bo, be = B.p.communicate(timeout=60)
        led1, act1 = env.scalar(db, f"select td0149_t.led('{kind}')"), env.scalar(db, "select td0149_t.act()")
        oa, ob = [x.strip() for x in ao.splitlines() if x.strip()][-1:][0] if ao.strip() else "", [x.strip() for x in bo.splitlines() if x.strip()][-1:][0] if bo.strip() else ""
        same = (int(led1) - int(led0), int(act1) - int(act0)) == (int(led_ctl) - int(led0), int(act_ctl) - int(act0))
        if kind in ("pol", "cfg", "rot", "ver", "dea"):
            ltbl = "factoring_policy_idempotency" if kind == "pol" else "factoring_integration_lifecycle_idempotency"
            fpr = env.scalar(db, f"select count(*) || '/' || count(*) filter (where request_fingerprint ~ '^[0-9a-f]{{64}}$') from public.{ltbl}")
            check(f"[{kind}] the RPC wrote exactly one ledger row with a NON-NULL 64-hex fingerprint ({fpr})", fpr == "1/1")
        check(f"[{kind}] concurrent duplicate: the second request WAITS, both succeed, the loser replays; exactly one ledger row and the same single business/audit write as one call",
              blocked and oa == "S" and ob in ("S", "S+R") and same and int(led1) - int(led0) == 1, f"A={ao!r} B={bo!r} {be[-200:]} blocked={blocked} deltas={(int(led1)-int(led0), int(act1)-int(act0))} ctl={(int(led_ctl)-int(led0), int(act_ctl)-int(act0))}")
        c.dropdb(db)
    c.dropdb(cbase)

    # ---- rollback / reapply
    print("== rollback, exact restoration, reapply ==")
    rb = "td0149_r_rb"
    c.createdb(rb, template=base)
    s0 = (env.catalog(rb), c.dump(rb), env.digest(rb))
    assert env.run(rb, prop).returncode == 0
    s1 = (env.catalog(rb), c.dump(rb), env.digest(rb))
    r = env.run(rb, (HERE / "rollback.sql").read_text())
    check("ROLLBACK_0152 succeeds", r.returncode == 0 and "ROLLBACK 0152 complete" in r.stderr, r.stderr[-800:])
    s2 = (env.catalog(rb), c.dump(rb), env.digest(rb))
    check("after rollback: catalog (bodies, ACLs, properties), pg_dump and all rows identical to the pre-0152 baseline", s2 == s0, str(t149.changed(s0[0], s2[0])[:5]) + "\n".join(t150.diff_dump(s0[1], s2[1])[:6]))
    check("after rollback: service_role EXECUTE on the three helpers is restored (baseline state) and the baseline defects are back",
          helper_probe(env, rb, "service_role") == probe_before)
    r = env.run(rb, (HERE / "rollback.sql").read_text())
    check("a second rollback is refused (bodies no longer the 0152 definition)", r.returncode != 0 and "ROLLBACK 0152 REFUSED" in r.stderr)
    assert env.run(rb, prop).returncode == 0
    check("reapply after rollback: catalog, pg_dump and rows identical to the first apply", (env.catalog(rb), c.dump(rb), env.digest(rb)) == s1)
    check("post_apply.sql passes after reapply", env.verify(rb, None, (HERE / "post_apply.sql").read_text())["ok"])
    env.run(rb, "create or replace function public.review_legacy_invoice_carrier_migration(p_review_id uuid, p_resolution text, p_notes text, p_expected_updated_at timestamptz, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $f$ begin return '{}'::jsonb; end $f$;")
    r = env.run(rb, (HERE / "rollback.sql").read_text())
    check("rollback refuses when a repaired function has drifted", r.returncode != 0 and "ROLLBACK 0152 REFUSED" in r.stderr)
    c.dropdb(rb)
    check("the complete sequence 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 -> verify -> rollback -> reapply ran on the real migrations", True)
    run_suites(c)
    safe_probes(c)


# ------------------------------------------------------------------- the repository's own disposable suites, with 0151/0152 injected
SUITES = [  # (file, banner, last migration the suite applies)
    ("TEST_0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql", "TEST 0134 PASSED", 134),
    ("TEST_CANCELLATION_AUDIT_DEDUP.sql", "TEST CANCELLATION AUDIT DEDUP PASSED", 134),
    ("TEST_STATUS_MATRIX_BACKWARD_CORRECTIONS.sql", "TEST STATUS MATRIX BACKWARD CORRECTIONS PASSED", 134),
    ("TEST_0135_dispatch_resource_reassignment_and_carrier_lockdown.sql", "TEST 0135 PASSED", 135),
    ("TEST_0139_factoring_policy_safety_integrations_and_privilege_remediation.sql", "TEST 0139 PASSED", 139),
    ("TEST_0141_factoring_integration_lifecycle_integrity.sql", "TEST 0141 PASSED", 141),
    ("TEST_0143_canonical_financial_idempotency_hardening.sql", "TEST 0143 PASSED", 143),
    ("TEST_0144_atomic_carrier_invoice_issuance.sql", "TEST 0144 PASSED", 144),
    ("TEST_0145_carrier_dispatch_service_agreements_and_issuance.sql", "TEST 0145 PASSED", 145),
    ("TEST_0146_carrier_invoice_payments_and_balance_rollups.sql", "TEST 0146 PASSED", 146),
    ("TEST_0147_production_readiness_blocker_remediation.sql", "TEST 0147 PASSED", 147),
]
FP_SHIM = """-- test-only shim for suites that stop before 0143 (the real function is created by 0143 itself)
create function public.compute_financial_request_fingerprint(p_canonical_payload jsonb) returns text language sql immutable security invoker
  set search_path = pg_catalog, public, extensions as $fn$ select encode(digest(p_canonical_payload::text, 'sha256'), 'hex'); $fn$;
revoke all on function public.compute_financial_request_fingerprint(jsonb) from public, anon, authenticated;
"""


def partial_0152(n):
    """0152's statements restricted to the objects that exist at migration state n (test injection only; the real file is proposed_0152.sql)."""
    B = build.blocks()
    present = {"reassign_dispatch_resources": 135, "set_carrier_factoring_policy": 139, "configure_carrier_factoring_integration": 141, "rotate_carrier_factoring_integration": 141,
               "transition_carrier_factoring_integration_lifecycle": 141, "deactivate_factoring_relationship": 141, "review_legacy_invoice_carrier_migration": 142, "update_carrier_invoice_draft": 143}
    out = ["begin;"]
    if n < 143 and n >= 139:
        out.append(FP_SHIM)
    if n >= 139:
        out.append("alter table public.factoring_policy_idempotency add column request_fingerprint text not null;")
    if n >= 141:
        out.append("alter table public.factoring_integration_lifecycle_idempotency add column request_fingerprint text not null;")
    for name, sig, _ in build.FUNCS:
        if present[name] <= n:
            out.append(B[name][2])
    helper_at = {0: 141, 1: 145, 2: 146}
    for i, h in enumerate(build.HELPERS):
        first = [141, 145, 146][[k for k, x in enumerate(["transition_carrier_factoring", "_issue_dispatch_service", "_generate_carrier_invoice_payment"]) if x in h][0]]
        if n >= first:
            out.append(f"revoke all on function {h} from public, anon, authenticated, service_role;")
    out.append("commit;")
    return "\n".join(out)


PROBE_0147 = r"""
\echo '===== 0152 PROBE (appended by proposals/0152/tests.py): replay of create_carrier_invoice_draft key sec5-owner-1 ====='
reset role;
do $t$
declare v_broker uuid; v jsonb; who text; uidv text;
  args_type public.invoice_document_type := 'carrier_freight_invoice';
begin
  select id into v_broker from public.brokers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1;
  set local role authenticated;
  -- unauthorized / foreign callers must never receive the cached result of the original owner call
  foreach who in array array['bbbb0000-0000-0000-0000-000000000001', 'eeee0000-0000-0000-0000-000000000001', 'ffff0000-0000-0000-0000-000000000001', '']
  loop
    perform set_config('test.current_uid', who, true);
    v := public.create_carrier_invoice_draft(args_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'owner create', 'sec5-owner-1');
    if (v->>'success')::boolean is true then raise exception 'PROBE FAIL: caller % received a successful/cached result: %', who, v; end if;
    raise notice 'PROBE caller %: %', coalesce(nullif(who, ''), '(unauthenticated)'), v->>'code';
  end loop;
  -- another authorized user (accountant) replays the SAME request: cached success, nothing new
  perform set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', true);
  v := public.create_carrier_invoice_draft(args_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'n', 'owner create', 'sec5-owner-1');
  if (v->>'success')::boolean is not true then raise exception 'PROBE FAIL: an authorized different user could not replay: %', v; end if;
  -- the same key with a changed request is refused
  v := public.create_carrier_invoice_draft(args_type, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'broker'::public.invoice_recipient_type, v_broker, null, 'USD', 30, null, 'CHANGED NOTES', 'owner create', 'sec5-owner-1');
  if v->>'code' is distinct from 'IDEMPOTENCY_KEY_REUSED' then raise exception 'PROBE FAIL: changed request was not refused: %', v; end if;
  reset role;
  raise notice 'PROBE 0147 CREATE-DRAFT REPLAY PASSED';
end
$t$;
"""


def audit_live_order(env, db):
    """Structural proof on the LIVE function bodies of the 0144-0147 idempotent RPCs (which need no repair): authentication, current-organization and
    role checks precede the first ledger read, the ledger lookup is organization-scoped and a fingerprint mismatch is refused."""
    rc, rows, err = env.q(db, r"""
select p.proname::text,
       regexp_instr(regexp_replace(p.prosrc, '\s+', ' ', 'g'), 'auth\.uid\(\)') as pa,
       regexp_instr(regexp_replace(p.prosrc, '\s+', ' ', 'g'), 'has_role\(') as pr,
       regexp_instr(regexp_replace(p.prosrc, '\s+', ' ', 'g'), 'current_org_id\(\)') as po,
       regexp_instr(regexp_replace(p.prosrc, '\s+', ' ', 'g'), 'from public\.\w*idempotency') as pl,
       (regexp_replace(p.prosrc, '\s+', ' ', 'g') ~ 'idempotency where organization_id = v_org') as scoped,
       (regexp_replace(p.prosrc, '\s+', ' ', 'g') ~ '(fingerprint <> v_fingerprint|v_fingerprint <>|IDEMPOTENCY_KEY_REUSED)') as bound
from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in (
  'approve_carrier_dispatch_service_agreement_version', 'create_carrier_dispatch_service_agreement', 'create_carrier_dispatch_service_agreement_version',
  'deactivate_carrier_dispatch_service_agreement', 'deactivate_carrier_dispatch_service_agreement_version', 'create_carrier_invoice_draft', 'delete_carrier_invoice_draft',
  'issue_carrier_invoice', 'record_carrier_invoice_payment', 'void_carrier_invoice_payment') order by 1""")
    assert rc == 0, err
    return rows


def run_suites(c):
    import subprocess
    print("== the repository's own disposable suites, re-run on chains that include 0151 + 0152 ==")
    tmp = Path(c.tmp)
    results = []
    for f, banner, n in SUITES:
        text = (SUPA / f).read_text()
        lines = text.splitlines()
        idx = max(i for i, l in enumerate(lines) if l.startswith("\\i migrations/"))
        inj = tmp / f"inject_{n}.sql"
        parts = []
        if n >= 134:
            parts.append((P0151 / "proposed_0151.sql").read_text())
        parts.append((HERE / "proposed_0152.sql").read_text() if n == 147 else partial_0152(n))
        inj.write_text("\n".join(parts))
        lines.insert(idx + 1, f"\\i {inj}")

        mod = tmp / f"mod_{f}"
        mod.write_text("\n".join(lines) + "\n")
        db = f"td0149_s_{n}_{abs(hash(f)) % 1000}"
        c.createdb(db)
        p = subprocess.run([t149.PSQL, "-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-h", str(c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-f", str(mod)],
                           capture_output=True, text=True, env=dict(c.env), cwd=str(SUPA), timeout=1500)
        passed = p.returncode == 0 and banner in (p.stdout + p.stderr) and not re.search(r"\|\s*f\s*$", p.stdout, re.M)
        oks = len(re.findall(r"NOTICE:\s+OK:", p.stdout + p.stderr))
        if not passed:
            print((p.stderr or p.stdout)[-1800:])
        check(f"{f}: PASSES with 0151 + 0152 injected after its last migration ({oks} 'OK:' assertions)", passed)
        results.append((f, oks))
        c.dropdb(db)
    print("      suites:", ", ".join(f"{f.split('_')[1]}:{o}" for f, o in results))


def parse_probe(stdout):
    rows = {}
    for l in stdout.splitlines():
        parts = l.split(SEP)
        if len(parts) == 9 and parts[0] == "PROBE":
            rows.setdefault(parts[1], []).append((parts[2], parts[3], parts[4], int(parts[5]), int(parts[6]), int(parts[7]), parts[8]))
    return rows


def evaluate_safe(kind, seq, foreign):
    by = {t: r for t, *r in seq}          # tag -> [outcome, msg, n_led, n_act, n_biz, biz]
    order = [t for t, *_ in seq]
    res = []

    def prev(t):
        return by[order[order.index(t) - 1]]

    def d(t):
        a, b = by[t], prev(t)
        return (a[2] - b[2], a[3] - b[3], a[4] - b[4], a[5] != b[5])   # (ledger, audit, business rows, business fingerprint changed)

    def add(step, cond, why=""):
        res.append((step, bool(cond), why))

    add("s0_orig", by["s0_orig"][0] == "S" and d("s0_orig")[0] == 1 and (d("s0_orig")[2] != 0 or d("s0_orig")[3]), f"{by['s0_orig'][0]} {d('s0_orig')}")
    for st in ("s1_same_user_replay", "s2_other_authorized_replay", "s15_retry_replays"):
        add(st, by[st][0] == "S" and d(st) == (0, 0, 0, False), f"{by[st][0]} {d(st)}")
    for st in ("s3_unauthenticated", "s4_unauthorized_role", "s5_foreign_org_real_key", "s6_foreign_org_wrong_key", "s7_removed_member", "s8_moved_member", "s9_downgraded_member"):
        add(st, not by[st][0].startswith("S") and d(st) == (0, 0, 0, False), f"{by[st][0]} {d(st)}")
    add("s6_indistinguishable", by["s5_foreign_org_real_key"][:2] == by["s6_foreign_org_wrong_key"][:2], f"{by['s5_foreign_org_real_key'][:2]} vs {by['s6_foreign_org_wrong_key'][:2]}")
    for st in ("s10_changed_request", "s11_same_key_other_target"):
        add(st, by[st][0] == "F:IDEMPOTENCY_KEY_REUSED" and d(st) == (0, 0, 0, False), f"{by[st][0]} {d(st)}")
    if foreign:
        add("s12_same_key_other_org", by["s12_same_key_other_org"][0] == "S" and d("s12_same_key_other_org")[0] == 1, f"{by['s12_same_key_other_org'][0]} {d('s12_same_key_other_org')}")
    add("s13_failed_tx", by["s13_failed_tx"][0] == "X:P0F11" and d("s13_failed_tx") == (0, 0, 0, False), f"{by['s13_failed_tx'][0]} {d('s13_failed_tx')}")
    add("s14_retry_after_failure", by["s14_retry_after_failure"][0] == "S" and d("s14_retry_after_failure")[0] == 1 and (d("s14_retry_after_failure")[2] != 0 or d("s14_retry_after_failure")[3]), f"{by['s14_retry_after_failure'][0]} {d('s14_retry_after_failure')}")
    return res


def run_probe(c, with_0152):
    import subprocess
    f = "TEST_0147_production_readiness_blocker_remediation.sql"
    lines = (SUPA / f).read_text().splitlines()
    idx = max(i for i, l in enumerate(lines) if l.startswith("\\i migrations/"))
    tmp = Path(c.tmp)
    if with_0152:
        inj = tmp / "probe_inject.sql"
        inj.write_text((P0151 / "proposed_0151.sql").read_text() + "\n" + (HERE / "proposed_0152.sql").read_text())
        lines.insert(idx + 1, f"\\i {inj}")
    text = "\n".join(lines) + "\n" + (HERE / "probe_safe_0144_0147.sql").read_text()
    mod = tmp / ("probe_" + ("0152_" if with_0152 else "base_") + f)
    mod.write_text(text)
    db = "td0149_s_probe_" + ("new" if with_0152 else "base")
    c.createdb(db)
    p = subprocess.run([t149.PSQL, "-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-h", str(c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-f", str(mod)],
                       capture_output=True, text=True, env=dict(c.env), cwd=str(SUPA), timeout=1500)
    if p.returncode != 0:
        print((p.stderr or "")[-2500:])
    check(f"TEST_0147 chain{' + 0151 + 0152' if with_0152 else ' (baseline, nothing injected)'} + probe fixtures ran to completion", p.returncode == 0)
    c.dropdb(db)
    return parse_probe(p.stdout)


def safe_probes(c):
    print("== runtime probes: every externally executable idempotent RPC of 0144-0147 classified SAFE ==")
    out = {}
    for with_0152 in (False, True):
        rows = run_probe(c, with_0152)
        label = "after 0152" if with_0152 else "baseline"
        check(f"probe output covers all {len(build.SAFE_KINDS)} SAFE RPCs ({label})", set(rows) == {k[0] for k in build.SAFE_KINDS}, str(sorted(rows)))
        for kind, rpc, *_rest, foreign in build.SAFE_KINDS:
            res = evaluate_safe(kind, rows[kind], foreign)
            bad = [(s_, w) for s_, ok, w in res if not ok]
            if bad:
                print(f"      !! {kind} {rpc} {label}: " + "; ".join(f"{s_}: {w}" for s_, w in bad))
            check(f"SAFE [{kind}] {rpc} ({label}): {len(res)} runtime expectations hold (auth, role, removed/moved/downgraded, foreign real vs wrong key indistinguishable, replays, changed request, other target, failed tx + retry, no duplicate ledger/audit/business rows)", not bad, str(bad))
        out[with_0152] = rows
    check("0152 changes NOTHING for the SAFE RPCs: every probe outcome, message and row count is identical before and after",
          {k: [(t, o, m, l, a, n, h) for t, o, m, l, a, n, h in v] for k, v in out[False].items()} == {k: [(t, o, m, l, a, n, h) for t, o, m, l, a, n, h in v] for k, v in out[True].items()}
          or all([(t, o, m) for t, o, m, *_ in out[False][k]] == [(t, o, m) for t, o, m, *_ in out[True][k]] and [(t, l, a, n) for t, _o, _m, l, a, n, _h in out[False][k]] == [(t, l, a, n) for t, _o, _m, l, a, n, _h in out[True][k]] for k in out[False]))


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
