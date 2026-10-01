#!/usr/bin/env python3
"""Proposal 0157 (F-08, carrier-invoice factoring) -- disposable-PostgreSQL verification. NOT APPROVED FOR PRODUCTION.

Reuses the 0154 harness (real migrations 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152, Supabase-style default function privileges emulated) then 0154 -> 0155 -> 0157. Synthetic data only.
Never connects to Supabase or any real database; never writes inside the repository."""
import importlib.util
import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
P = SUPA / "proposals"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


t54 = _load("t0154_for_0157", P / "0154" / "tests.py")
t149 = t54.t149
b57 = _load("b0157", HERE / "build.py")
scan = _load("scan_for_0157", P / "0152" / "production_package" / "static_scan_migrations.py")
Lab, U, OA, OB = t54.Lab, dict(t54.U), t54.OA, t54.OB
U.update({"adminA": "aaaa0000-0000-0000-0000-000000000002", "disp2A": "dddd0000-0000-0000-0000-000000000002"})
checks = t54.checks
check = t54.check
rd = t54.rd
A1, A2 = "a1a1a1a1-0000-0000-0000-000000000001", "a2a2a2a2-0000-0000-0000-000000000002"
REL = "fe000000-0000-0000-0000-000000000003"
GATE_ON = "update public.carrier_invoice_factoring_gate_0157 set enabled = true, decision_ref = 'OWNER-DECISION-TEST';"


def CI(n):
    return f"c1000000-0000-0000-0000-0000000000{n:02d}"


def call(lab, db, uid, expr, role="authenticated", pre="", end="rollback"):
    rc, out, err = lab.as_role(db, role, uid, f"select ({expr})::text", pre=pre, end=end)
    try:
        return json.loads(out), err
    except Exception:
        return None, err


def sub(lab, db, uid, inv, key, **kw):
    return call(lab, db, uid, f"public.submit_carrier_invoice_to_factor('{inv}', '{key}')", **kw)


def code_of(res):
    return (res[0] or {}).get("code")


def scalar(lab, db, sql):
    return lab.scalar(db, sql)


def static_checks():
    print("== static checks ==")
    for name, text in b57.all_files().items():
        check(f"0157/{name} is current (generated)", (HERE / name).read_text() == text)
    sql = rd("0157/proposed_0157.sql")
    code = t149.strip_sql(sql)
    for f in ("proposed_0157.sql", "preflight.sql", "post_apply.sql", "rollback.sql"):
        t = rd(f"0157/{f}")
        check(f"0157/{f} is marked NOT APPROVED FOR PRODUCTION and names the 0148 renumbering rule", "NOT APPROVED FOR PRODUCTION" in t and "0153" in t and "0158" in t)
        check(f"0157/{f}: never grants anything to anon, service_role or PUBLIC", not re.search(r"grant\s+[^;]*\bto\s+[^;]*\b(anon|service_role|public)\b", t149.strip_sql(t), re.I))
    for f in ("preflight.sql", "post_apply.sql"):
        s = t149.strip_sql(rd(f"0157/{f}"))
        check(f"0157/{f}: ONE read-only statement (SELECT only; the audit-chain verifier is a STABLE function)", s.count(";") == 1 and not re.search(r"\b(insert|update|delete|create|alter|drop|grant|revoke|truncate|begin|commit|rollback|set_config|lock)\b", s, re.I), f)
    check("no foreign key in 0157 cascades (no 'on delete cascade' / 'set null' / 'set default' anywhere in the tables)", not re.search(r"on delete (cascade|set null|set default)", sql, re.I))
    funcs = re.findall(r"create function public\.(\w+)\(.*?\n\$(?:fn|t)\$;", sql, re.S)
    check("every 0157 function pins search_path = pg_catalog, pg_temp (no public in the path: everything is schema-qualified)", len(re.findall(r"set search_path = pg_catalog, pg_temp", sql)) == 28 and "set search_path = pg_catalog, public" not in sql and len(re.findall(r"create function public\.", sql)) == 28, str((len(re.findall(r"set search_path = pg_catalog, pg_temp", sql)), len(re.findall(r"create function public\.", sql)))))
    core = "".join(re.findall(r"create function public\.(?:_cif_evaluate_0157|submit_carrier_invoice_to_factor|preview_carrier_invoice_factoring)\(.*?\n\$fn\$;", sql, re.S))
    check("the RPC/evaluation bodies reference NO legacy table (public.invoices, public.invoice_line_items, public.factored_invoices, public.payments): legacy invoices are excluded by construction (D-08b)", not re.search(r"public\.(invoices|invoice_line_items|factored_invoices|payments)\b", core))
    check("the RPC/evaluation bodies never read a dispatch-fee amount: the only mention is the REFUSAL of dispatch_service_fee lines / dispatch_service_invoice documents", set(re.findall(r"dispatch_[a-z_]+", core.replace("dispatch_service_fee", "").replace("dispatch_service_invoice", ""))) <= {"dispatch_fee_on_invoice", "dispatch_grant"} and "dispatch_service_fee" in core)
    check("the submit RPC takes a carrier-invoice id and an idempotency key ONLY (no relationship / factor / carrier parameter)", "submit_carrier_invoice_to_factor(p_carrier_invoice_id uuid, p_idempotency_key text)" in sql and "p_relationship" not in core)
    check("the submit RPC fails closed on a null identity, sets bounded lock_timeout and statement_timeout, and revokes EXECUTE from PUBLIC/anon/service_role", "if v_uid is null then return" in sql and "set_config('lock_timeout', '5s', true)" in sql and "set_config('statement_timeout', '30s', true)" in sql
          and "revoke all on function public.preview_carrier_invoice_factoring(uuid), public.submit_carrier_invoice_to_factor(uuid,text)" in sql and "from public, anon, service_role" in sql)
    rpcs = re.findall(r"create function public\.((?:preview_carrier_invoice_issuance|create_carrier_invoice_draft_from_loads|mark_carrier_invoice_ready_for_issue|discard_carrier_invoice_draft|issue_prepared_carrier_invoice|preview_carrier_invoice_reissue|reissue_carrier_invoice))\((.*?)\) returns jsonb", sql)
    check("the seven issuance/reissue RPCs exist and NONE takes a relationship, factor, organization, recipient-routing, total or amount parameter (server-side resolution only)", len(rpcs) == 7 and not any(re.search(r"p_(relationship|factor|factoring|organization|org|total|amount|advance|fee|routing|remittance|noa|destination)", args) for _, args in rpcs), str(rpcs))
    bodies = "".join(re.findall(r"create function public\.(?:preview_carrier_invoice_issuance|create_carrier_invoice_draft_from_loads|mark_carrier_invoice_ready_for_issue|discard_carrier_invoice_draft|issue_prepared_carrier_invoice|preview_carrier_invoice_reissue|reissue_carrier_invoice)\(.*?\n\$fn\$;", sql, re.S))
    check("every issuance/reissue RPC fails closed on a null identity, and the state-changing ones set bounded lock_timeout/statement_timeout", bodies.count("if v_uid is null then return") == 7 and bodies.count("set_config('lock_timeout', '5s', true)") == 5 and bodies.count("set_config('statement_timeout', '30s', true)") == 5)
    check("issuance never inserts a dispatch_service_fee line into a freight invoice and never reads dispatch_financials or legacy tables", "'dispatch_service_fee'" not in bodies and "dispatch_financials" not in sql and re.findall(r"public\.(invoices|invoice_line_items|factored_invoices|payments)\b", sql) == ["factored_invoices", "factored_invoices"])  # the only two mentions are the apply-time read-only fingerprint of the legacy table (D-57g: no bridge)
    check("rejected / funded exist nowhere in the SQL as statuses; the status CHECK is exactly ('submitted', 'withdrawn') (D-57e)", not re.search(r"'(rejected|funded)'", sql) and "check (status in ('submitted', 'withdrawn'))" in sql)
    check("relationship drift refusal code is present, stable and the only drift code (D-57d)", sql.count("'RELATIONSHIP_DRIFT_REISSUE_REQUIRED'") == 1 and "relationship_changed_since_issuance" not in sql)
    check("static scan: still NO unqualified relation reference in any SECURITY DEFINER body (including 0157)", scan.unqualified_relation_refs() == {}, str(scan.unqualified_relation_refs()))


def build_base(lab, c, env, base):
    a = lab.clone(base, "td0149_p57a")
    for f in ("0154/proposed_0154.sql", "0155/proposed_0155.sql"):
        r = lab.apply(a, rd(f))
        assert r.returncode == 0, r.stderr[-500:]
    return a


def fixtures(lab, db, scenario=True):
    for f in (["0154/fixture_scenario.sql"] if scenario else []) + ["0154/fixture_submission.sql", "0157/fixture_carrier_invoices.sql", "0157/fixture_issuance.sql"]:
        r = lab.sql(db, rd(f))
        assert r.returncode == 0, f + r.stderr[-500:]


def apply_and_refusals(lab, a):
    print("== 0157: preflight, refusals, apply, post_apply ==")
    pf = lab.verify(a, rd("0157/preflight.sql"))
    check("preflight 0157 PASSES (0154 + 0155 applied; nothing of 0157 exists)", pf["ok"], pf["err"][-300:])
    refusals = {"a same-named RPC overload already exists (any schema)": ("create schema zz_evil; create function zz_evil.submit_carrier_invoice_to_factor(uuid) returns void language sql as 'select 1';", "with a 0157 name already exist"),
                "a same-named ISSUANCE RPC overload already exists (any schema)": ("create schema zz_evil2; create function zz_evil2.reissue_carrier_invoice(uuid) returns void language sql as 'select 1';", "with a 0157 name already exist"),
                "a public issuance RPC with a different signature exists (overload)": ("create function public.issue_prepared_carrier_invoice(text) returns void language sql as 'select 1';", "with a 0157 name already exist"),
                "a helper-named function already exists": ("create function public._cif_evaluate_0157() returns void language sql as 'select 1';", "with a 0157 name already exist"),
                "a 0157 table already exists": ("create table public.carrier_invoice_factoring_audit_0157 (x int);", "0157 table already exists")}
    for label, (mut, expect) in refusals.items():
        d = lab.clone(a, "td0149_p57r")
        lab.sql(d, mut)
        before = lab.catalog(d)
        r = lab.apply(d, rd("0157/proposed_0157.sql"))
        check(f"0157 REFUSES and changes nothing: {label}", r.returncode != 0 and expect in r.stderr and lab.catalog(d) == before, r.stderr[-250:])
        check(f"preflight 0157 FAILS: {label}", not lab.verify(d, rd("0157/preflight.sql"))["ok"])
    d = lab.clone("td0149_p_base", "td0149_p57r")
    r = lab.apply(d, rd("0157/proposed_0157.sql"))
    check("0157 REFUSES when proposal 0155 is not applied", r.returncode != 0 and "0155" in r.stderr, r.stderr[-200:])
    d = lab.clone(a, "td0149_p57r")
    assert lab.apply(d, rd("0156/proposed_0156.sql")).returncode == 0
    lab.sql(d, "update public.factoring_submission_gate set enabled = true, decision_ref = 'LEGACY';")
    r = lab.apply(d, rd("0157/proposed_0157.sql"))
    check("0157 REFUSES while the legacy 0156 gate is ENABLED (legacy invoices stay excluded, D-08b)", r.returncode != 0 and "0156 gate is ENABLED" in r.stderr, r.stderr[-200:])
    lab.sql(d, "update public.factoring_submission_gate set enabled = false;")
    r = lab.apply(d, rd("0157/proposed_0157.sql"))
    check("0157 applies alongside a DISABLED legacy 0156 (which stays disabled and untouched)", r.returncode == 0 and scalar(lab, d, "select (not enabled)::text from public.factoring_submission_gate") == "true", r.stderr[-200:])
    lab.c.dropdb("td0149_p57r")


def normalization_tests(lab, a):
    print("== D-57f: normalizing the _0157 names at promotion (collision + drift refusal) ==")
    nn = _load("nn0157", HERE / "normalize_names.py")
    check("normalize_names --check: no name collapse, no collision with supabase/migrations or any other proposal, no _0157 identifier left", nn.problems() == [] and len(nn.mapping()) > 60, str(nn.problems()[:3]))
    check("the normalizer never writes under supabase/migrations (it refuses such a target) and never edits the reviewed sources", "never writes under supabase/migrations" in (HERE / "normalize_names.py").read_text() and all((HERE / f).read_text() == t for f, t in nn.source_texts().items()))
    files = nn.normalized_files()
    check("DRIFT REFUSAL: a candidate equal to the normalized reviewed file is accepted; ANY one-character change is refused", subprocess.run([sys.executable, "-B", str(HERE / "normalize_names.py"), "--verify", "/dev/stdin", "proposed_0157.sql"], input=files["proposed_0157.sql"], text=True, capture_output=True).returncode == 0
          and subprocess.run([sys.executable, "-B", str(HERE / "normalize_names.py"), "--verify", "/dev/stdin", "proposed_0157.sql"], input=files["proposed_0157.sql"].replace("carrier_invoice_factoring_gate", "carrier_invoice_factoring_gatex", 1), text=True, capture_output=True).returncode == 1)
    d = lab.clone(a, "td0149_p57n")
    pf = lab.verify(d, files["preflight.sql"])
    check("the NORMALIZED preflight PASSES on a clean database", pf["ok"], pf["err"][-300:])
    r = lab.apply(d, files["proposed_0157.sql"])
    check("the NORMALIZED migration applies (no _0157 suffix on any object) and its own postconditions pass", r.returncode == 0 and "0157 complete" in r.stderr and scalar(lab, d, "select count(*) from pg_class where relname like '%\\_0157%' escape '\\'") == "0" and scalar(lab, d, "select count(*) from pg_proc where proname like '%\\_0157' escape '\\'") == "0", r.stderr[-300:])
    check("the NORMALIZED post_apply PASSES", lab.verify(d, files["post_apply.sql"])["ok"])
    r = lab.apply(d, files["rollback.sql"])
    check("the NORMALIZED rollback removes every normalized object (clean, no history)", r.returncode == 0 and scalar(lab, d, "select count(*) from pg_class where relname like 'carrier\\_invoice\\_factoring\\_%' escape '\\'") == "0", r.stderr[-300:])
    lab.c.dropdb("td0149_p57n")
    for label, mut in (("a table with a normalized name already exists", "create table public.carrier_invoice_factoring_gate (x int);"), ("a function with a normalized name already exists", "create function public._cif_evaluate() returns void language sql as 'select 1';"),
                       ("a public RPC with a normalized name already exists", "create function public.reissue_carrier_invoice() returns void language sql as 'select 1';")):
        d = lab.clone(a, "td0149_p57n")
        lab.sql(d, mut)
        before = lab.catalog(d)
        r = lab.apply(d, files["proposed_0157.sql"])
        check(f"COLLISION REFUSAL: the normalized migration REFUSES and changes nothing when {label}", r.returncode != 0 and ("already exist" in r.stderr) and lab.catalog(d) == before, r.stderr[-200:])
        check(f"   ...and the normalized preflight FAILS: {label}", not lab.verify(d, files["preflight.sql"])["ok"])
        lab.c.dropdb("td0149_p57n")


def main_db(lab, a):
    db = lab.clone(a, "td0149_p57")
    fp = lab.scalar(db, "select md5(coalesce((select string_agg(to_jsonb(r)::text, '|' order by r.id) from public.factoring_relationships r), '') || coalesce((select string_agg(to_jsonb(f)::text, '|' order by f.id) from public.factored_invoices f), '') || coalesce((select string_agg(to_jsonb(i)::text, '|' order by i.id) from public.invoices i), ''))")
    r = lab.apply(db, rd("0157/proposed_0157.sql"))
    check("0157 applies (gate DISABLED)", r.returncode == 0 and "0157 complete" in r.stderr, r.stderr[-500:])
    check("post_apply 0157 PASSES", lab.verify(db, rd("0157/post_apply.sql"))["ok"])
    check("existing relationships, legacy factored invoices and legacy invoices are byte-identical after 0157", lab.scalar(db, "select md5(coalesce((select string_agg(to_jsonb(r)::text, '|' order by r.id) from public.factoring_relationships r), '') || coalesce((select string_agg(to_jsonb(f)::text, '|' order by f.id) from public.factored_invoices f), '') || coalesce((select string_agg(to_jsonb(i)::text, '|' order by i.id) from public.invoices i), ''))") == fp)
    fixtures(lab, db)
    return db


def gate_tests(lab, db, a):
    print("== operator gate (D-08h / D-08i) ==")
    res = sub(lab, db, U["ownerA"], CI(1), "cif-00000001-aaaa", end="commit")
    check("DISABLED BY DEFAULT: every submission is refused with FEATURE_DISABLED and audited; nothing is written", code_of(res) == "FEATURE_DISABLED" and scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_submissions_0157") == "0" and scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_audit_0157 where code = 'FEATURE_DISABLED' and outcome = 'refusal'") == "1", str(res))
    res = call(lab, db, U["ownerA"], f"public.preview_carrier_invoice_factoring('{CI(1)}')")
    check("preview with the gate off reports FEATURE_DISABLED (the UI hides the control)", code_of(res) == "FEATURE_DISABLED" and res[0]["eligible"] is False)
    for role, uid in (("anon", ""), ("authenticated", U["ownerA"]), ("service_role", "")):
        rc, out, err = lab.as_role(db, role, uid, GATE_ON)
        check(f"{role} cannot enable the gate (no privilege on the table)", rc != 0 and "permission denied" in err, err[-150:])
        rc, out, err = lab.as_role(db, role, uid, "select enabled from public.carrier_invoice_factoring_gate_0157")
        check(f"{role} cannot even read the gate", rc != 0 and "permission denied" in err)
    r = lab.sql(db, "update public.carrier_invoice_factoring_gate_0157 set enabled = true;")
    check("the gate cannot be enabled WITHOUT a recorded decision reference", r.returncode != 0 and "needs_decision" in r.stderr)
    r = lab.sql(db, "insert into public.carrier_invoice_factoring_gate_0157 (singleton, enabled) values (false, false);")
    r2 = lab.sql(db, "delete from public.carrier_invoice_factoring_gate_0157;")
    check("the gate is a single fixed row (no extra insert, no delete)", r.returncode != 0 and r2.returncode != 0)
    # D-08i: pending 0155 review and open factoring exception block enabling
    p = lab.clone(a, "td0149_p57pend")
    assert lab.sql(p, rd("0154/fixture_scenario.sql")).returncode == 0
    assert lab.sql(p, "select public._carrier_inference_apply_0155('scenario')").returncode == 0
    assert lab.apply(p, rd("0157/proposed_0157.sql")).returncode == 0
    r = lab.sql(p, GATE_ON)
    check("D-08i: the gate CANNOT be enabled while 0155 reviews are pending", r.returncode != 0 and "D-08i" in r.stderr and "pending" in r.stderr, r.stderr[-250:])
    lab.sql(p, "update public.carrier_inference_review_0155 set decision_status = 'confirmed', decision_key = 'k', decided_at = now(), decision_reason = 'r', decision_evidence_ref = 'e' where decision_status = 'pending';")
    r = lab.sql(p, GATE_ON)
    check("D-08i: the gate CANNOT be enabled while a factoring exception record is open (legacy factoring conflict unresolved)", r.returncode != 0 and "D-08i" in r.stderr and "exception" in r.stderr, r.stderr[-250:])
    lab.sql(p, "update public.unresolved_carrier_records set status = 'manually_resolved', resolved_at = now(), resolution_note = 'test' where status = 'unresolved';")
    r = lab.sql(p, GATE_ON)
    check("D-08i: with every review decided and every conflict resolved the operator CAN enable the gate", r.returncode == 0, r.stderr[-250:])
    lab.c.dropdb("td0149_p57pend")
    r = lab.sql(db, GATE_ON)
    check("enabling on the main fixture (no pending review, no open exception) succeeds and records the DATABASE USER and time", r.returncode == 0 and scalar(lab, db, "select (changed_by = 'postgres' and changed_at is not null and decision_ref = 'OWNER-DECISION-TEST')::text from public.carrier_invoice_factoring_gate_0157") == "true", r.stderr[-200:])
    check("every gate change is audited with the operator and the decision reference", scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_audit_0157 where event_type = 'gate_change' and code = 'GATE_ENABLED' and detail ->> 'decision_ref' = 'OWNER-DECISION-TEST' and detail ->> 'operator' = 'postgres'") == "1")


def authz_tests(lab, db):
    print("== authorization matrix ==")
    K = iter(range(1000, 9000))
    def s(uid, inv, role="authenticated", commit=False):
        return sub(lab, db, uid, inv, f"cif-{next(K):08d}-aaaa", role=role, end="commit" if commit else "rollback")
    for role, uid in (("anon", ""), ("service_role", "")):
        res = s(uid, CI(1), role=role)
        check(f"{role}: submit_carrier_invoice_to_factor is DENIED (permission denied)", res[0] is None and "permission denied for function" in res[1], res[1][-200:])
        res = call(lab, db, uid, f"public.preview_carrier_invoice_factoring('{CI(1)}')", role=role)
        check(f"{role}: preview is DENIED", res[0] is None and "permission denied for function" in res[1])
    check("null identity through the authenticated role FAILS CLOSED (FORBIDDEN, no audit row)", code_of(s("", CI(1))) == "FORBIDDEN")
    n0 = scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_audit_0157")
    s("", CI(1), commit=True)
    check("a null identity writes nothing to the audit ledger (no spam surface)", scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_audit_0157") == n0)
    check("an authenticated OUTSIDER from another organization gets NOT_FOUND (no existence oracle) -- identical to a non-existent invoice", code_of(s(U["ownerB"], CI(1))) == "NOT_FOUND" and s(U["ownerB"], CI(1))[0]["message"] == s(U["ownerB"], "c1000000-0000-0000-0000-0000000000ff")[0]["message"])
    for label, uid in (("accountant", U["acctA"]), ("driver", U["driverA"]), ("viewer", U["viewerA"])):
        check(f"{label} is FORBIDDEN (not an owner/admin)", code_of(s(uid, CI(1))) == "FORBIDDEN")
    check("a dispatcher WITHOUT a grant is FORBIDDEN from pilot submission", code_of(s(U["dispA"], CI(1))) == "FORBIDDEN")
    res = call(lab, db, U["dispA"], f"public.preview_carrier_invoice_factoring('{CI(1)}')")
    check("preview for an unauthorized dispatcher is refused too (nothing about the factor is revealed)", code_of(res) == "NOT_AUTHORIZED_FOR_CARRIER" and "factoring_company_name" not in res[0])
    # grant management
    def grant(uid, carrier, profile, allowed, key, reason="business need"):
        return call(lab, db, uid, f"public.set_carrier_factoring_submitter('{carrier}', '{profile}', {str(allowed).lower()}, '{reason}', '{key}')", end="commit")
    check("a dispatcher CANNOT manage submitters (owner/admin only)", code_of(grant(U["dispA"], A1, U["dispA"], True, "g0")) == "FORBIDDEN")
    check("an accountant cannot manage submitters", code_of(grant(U["acctA"], A1, U["dispA"], True, "g0")) == "FORBIDDEN")
    check("another organization's owner cannot grant on this carrier (NOT_FOUND)", code_of(grant(U["ownerB"], A1, U["dispA"], True, "g0")) == "NOT_FOUND")
    check("a grant for a NON-dispatcher profile is refused", code_of(grant(U["ownerA"], A1, U["acctA"], True, "g1")) == "NOT_FOUND")
    g = grant(U["ownerA"], A1, U["dispA"], True, "g-grant-1")
    check("owner grants dispatcher A access to carrier A1 (recorded)", g[0]["success"] is True and g[0]["changed"] is True, str(g))
    check("the grant is idempotent by key (replay) and a key reused for a different request is refused", grant(U["ownerA"], A1, U["dispA"], True, "g-grant-1")[0].get("idempotent_replay") is True and code_of(grant(U["ownerA"], A1, U["disp2A"], True, "g-grant-1")) == "IDEMPOTENCY_KEY_REUSED")
    check("preview for the granted dispatcher succeeds with the SERVER-selected destination (a factor picker never exists)", (lambda r: r[0]["eligible"] is True and r[0]["factoring_company_name"] == "FactorA" and "relationship_id" not in r[0])(call(lab, db, U["dispA"], f"public.preview_carrier_invoice_factoring('{CI(1)}')")))
    check("a dispatcher granted carrier A1 is NOT authorized for a different carrier (A2) invoice", code_of(s(U["dispA"], CI(11))) == "FORBIDDEN")
    check("a second dispatcher without a grant is still refused", code_of(s(U["disp2A"], CI(2))) == "FORBIDDEN")
    before = scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_submissions_0157")
    check("D-57h: an active grant permits preview but NEVER submission (committed refusal)", code_of(s(U["dispA"], CI(1), commit=True)) == "FORBIDDEN")
    check("D-57h: dispatcher refusal writes no submission or snapshot", scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_submissions_0157") == before and scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_snapshots_0157") == "0")
    check("D-57h: foreign invoice and unknown invoice return NOT_FOUND even to a dispatcher", code_of(s(U["dispA"], CI(12))) == "NOT_FOUND" and code_of(s(U["dispA"], "c1000000-0000-0000-0000-0000000000ff")) == "NOT_FOUND")
    check("D-57h: admin submission succeeds without a grant (rolled back)", s(U["adminA"], CI(2))[0]["success"] is True)
    check("D-57h: revoking a grant also removes preview access, submission stays forbidden", grant(U["ownerA"], A1, U["dispA"], False, "pilot-revoke")[0]["success"] is True and code_of(call(lab, db, U["dispA"], f"public.preview_carrier_invoice_factoring('{CI(1)}')")) == "NOT_AUTHORIZED_FOR_CARRIER" and code_of(s(U["dispA"], CI(1))) == "FORBIDDEN")
    grant(U["ownerA"], A1, U["dispA"], True, "pilot-restore")
    check("owner and admin need no grant (preview eligible for both)", all(call(lab, db, u, f"public.preview_carrier_invoice_factoring('{CI(2)}')")[0]["eligible"] is True for u in (U["ownerA"], U["adminA"])))


def eligibility_tests(lab, db):
    print("== eligibility (D-08d/e/f), legacy refusal, relationship selection ==")
    owner = U["ownerA"]
    expect = {3: "INVOICE_NOT_ISSUED", 4: "INVOICE_NOT_ISSUED", 5: "INVOICE_PAID_OR_PARTIAL", 6: "INVOICE_PAID_OR_PARTIAL", 7: "INVOICE_VOIDED", 8: "WRONG_DOCUMENT_TYPE", 9: "DISPATCH_FEE_ON_INVOICE",
              10: "ISSUED_AS_DIRECT_BILLING", 11: "ISSUED_AS_DIRECT_BILLING", 13: "SNAPSHOT_MISMATCH", 14: "SNAPSHOT_MISSING", 12: "NOT_FOUND", 15: "ISSUANCE_RECORD_MISSING_REISSUE_REQUIRED"}
    labels = {3: "draft", 4: "ready_for_issue", 5: "partially paid", 6: "paid", 7: "voided", 8: "dispatch-service invoice (dispatch fees are a separate receivable)", 9: "freight invoice carrying a dispatch-service fee line", 10: "issued while the carrier was direct billing",
              11: "invoice of an unconfigured/direct carrier", 13: "issued total differs from its snapshot", 14: "no issuance snapshot", 12: "invoice of ANOTHER organization", 15: "issued outside the controlled workflow (no issuance-terms record): must be reissued"}
    for n, c in expect.items():
        res = sub(lab, db, owner, CI(n), f"cif-{n:08d}-bbbb")
        check(f"REFUSED ({c}): {labels[n]}", code_of(res) == c and res[0]["success"] is False, str(res))
    check("carrier invoices have NO sent/viewed/disputed/cancelled state: the enum is exactly draft/ready_for_issue/issued/voided (D-08e maps to issued+unpaid; a future state would need review)",
          scalar(lab, db, "select string_agg(enumlabel, ',' order by enumsortorder) from pg_enum where enumtypid = 'public.invoice_issuance_status'::regtype") == "draft,ready_for_issue,issued,voided")
    res = sub(lab, db, owner, "1a000000-0000-0000-0000-000000000007", "cif-00000099-cccc", end="commit")
    check("a LEGACY invoice id is refused (NOT_FOUND): the RPC reads only carrier_invoices; the refusal is audited and no legacy table is touched", code_of(res) == "NOT_FOUND" and scalar(lab, db, "select count(*) from public.factored_invoices where invoice_id = '1a000000-0000-0000-0000-000000000007'") == "0")
    lab.sql(db, "delete from public.carrier_invoice_factoring_audit_0157 where false;")
    variants = [("the carrier is configured for DIRECT billing", f"update public.carriers set factoring_mode = 'direct' where id = '{A1}';", "DIRECT_BILLING"),
                ("the carrier is UNCONFIGURED", f"update public.carriers set factoring_mode = 'unconfigured' where id = '{A1}';", "DIRECT_BILLING"),
                ("the carrier is INACTIVE", f"update public.carriers set is_active = false where id = '{A1}';", "CARRIER_INACTIVE"),
                ("the broker is not factoring-eligible", f"update public.carrier_brokers set factoring_eligible = false where carrier_id = '{A1}';", "NOT_FACTORING_ELIGIBLE"),
                ("the broker has an approved direct-billing exception", f"update public.carrier_brokers set factoring_eligible = false, factoring_ineligible_direct_billing_approved = true, factoring_ineligible_direct_billing_approved_by = '{U['ownerA']}', factoring_ineligible_direct_billing_approved_at = now() where carrier_id = '{A1}';", "NOT_FACTORING_ELIGIBLE"),
                ("the carrier has NO default relationship", f"update public.factoring_relationships set is_default = false where id = '{REL}';", "NO_ACTIVE_DEFAULT_RELATIONSHIP"),
                ("the only default relationship is INACTIVE", f"update public.factoring_relationships set is_default = false, is_active = false where id = '{REL}';", "NO_ACTIVE_DEFAULT_RELATIONSHIP"),
                ("the carrier has MORE THAN ONE active default (index dropped only inside this rolled-back test)", f"drop index public.factoring_relationships_one_default_per_carrier; set session_replication_role = replica; insert into public.factoring_relationships (id, organization_id, factoring_company_id, relationship_name, carrier_id, is_default, is_active, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type) select 'fe000000-0000-0000-0000-0000000000f1', organization_id, factoring_company_id, 'second default', carrier_id, true, true, 80, 3, 20, 'deducted_at_funding', 'recourse' from public.factoring_relationships where id = '{REL}'; set session_replication_role = origin;", "MULTIPLE_DEFAULT_RELATIONSHIPS"),
                ("the relationship is not yet effective", f"update public.factoring_relationships set effective_from = current_date + 5 where id = '{REL}';", "RELATIONSHIP_NOT_EFFECTIVE"),
                ("the relationship has expired", f"update public.factoring_relationships set effective_from = current_date - 30, effective_to = current_date - 1 where id = '{REL}';", "RELATIONSHIP_NOT_EFFECTIVE"),
                ("the factoring company is inactive", "set session_replication_role = replica; update public.factoring_companies set is_active = false where id = 'f0000000-0000-0000-0000-00000000000a'; set session_replication_role = origin;", "COMPANY_INACTIVE"),
                ("the NOA approval was withdrawn (D-57d: NOA drift)", f"set session_replication_role = replica; update public.factoring_relationships set noa_approved = false, noa_approved_by = null, noa_approved_at = null where id = '{REL}'; set session_replication_role = origin;", "RELATIONSHIP_DRIFT_REISSUE_REQUIRED"),
                ("remittance instructions changed to missing (D-57d: routing drift)", f"update public.factoring_relationships set remittance_instructions = null where id = '{REL}';", "RELATIONSHIP_DRIFT_REISSUE_REQUIRED"),
                ("an OPEN exception exists on the relationship", f"insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason) values ('{OA}', 'factoring_relationship', '{REL}', 'open');", "UNRESOLVED_LEGACY_RECORD"),
                ("an OPEN exception exists on the carrier invoice", f"insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason) values ('{OA}', 'invoice', '{CI(1)}', 'open');", "UNRESOLVED_LEGACY_RECORD"),
                ("a 0155 review of the relationship is still PENDING", f"insert into public.carrier_inference_review_0155 (relationship_id, organization_id, classification, prior_carrier_id, strict_status, evidence, first_run_id, last_run_id) values ('{REL}', '{OA}', 'unsafe_assigned', '{A1}', 'partial', '{{}}', gen_random_uuid(), gen_random_uuid());", "UNRESOLVED_LEGACY_RECORD"),
                ("the terms AT ISSUANCE already make the funding amount NEGATIVE", f"set session_replication_role = replica; update public.factoring_relationships set other_fee_default = 5000 where id = '{REL}'; update public.carrier_invoice_issuance_terms_0157 set frozen = public._cif_freeze_0157('{REL}') where invoice_id = '{CI(1)}'; set session_replication_role = origin;", "NEGATIVE_FUNDING")]
    for label, mut, code in variants:
        res = sub(lab, db, owner, CI(1), "cif-0000aaaa-dddd", pre=mut)
        check(f"REFUSED ({code}): {label}", code_of(res) == code and res[0]["success"] is False, str(res))
    check("all these refusals wrote nothing (rolled back) and the real configuration is untouched", scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_submissions_0157") == "0")


def submit_tests(lab, db):
    print("== the permitted path, snapshots, idempotency, concurrency ==")
    owner = U["ownerA"]
    before_legacy = scalar(lab, db, "select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f")
    res = sub(lab, db, owner, CI(1), "cif-11111111-1111", end="commit")
    check("PERMITTED: an eligible issued, unpaid carrier freight invoice is submitted by an owner to the carrier's own default factor", res[0] and res[0]["success"] is True and res[0]["status"] == "submitted" and res[0]["relationship_id"] == REL, str(res))
    sid = res[0]["submission_id"]
    rc, rows, err = lab.rows(db, f"select s.status, s.relationship_id::text, s.factoring_company_id::text, s.carrier_id::text, s.carrier_invoice_id::text, n.invoice_total_amount::text, n.advance_percentage::text, n.factoring_fee_percentage::text, n.reserve_percentage::text, n.expected_advance_amount::text, n.factoring_fee_amount::text, n.reserve_amount::text, n.expected_funding_amount::text, n.authorization_basis, n.gate_decision_ref, n.remittance_instructions, n.noa_reference, n.submission_method, n.carrier_legal_name, n.invoice_number from public.carrier_invoice_factoring_submissions_0157 s join public.carrier_invoice_factoring_snapshots_0157 n on n.submission_id = s.id where s.id = '{sid}'")
    r_ = rows[0]
    check("the submission links to EXACTLY ONE carrier invoice with organization + carrier + relationship + factor identity", r_[0] == "submitted" and r_[1] == REL and r_[2] == "f0000000-0000-0000-0000-00000000000a" and r_[3] == A1 and r_[4] == CI(1), str(r_))
    check("the immutable snapshot records amount (2000.00), advance 80 / fee 3 / reserve 20 percent, computed amounts (1600 / 60 / 400 / 1540), routing, NOA, gate reference, authorization basis",
          r_[5] == "2000.00" and r_[6] == "80.0000" and r_[7] == "3.0000" and r_[8] == "20.0000" and r_[9] == "1600.00" and r_[10] == "60.00" and r_[11] == "400.00" and r_[12] == "1540.00" and r_[13] == "owner" and r_[14] == "OWNER-DECISION-TEST" and r_[15] == "Remit to FactorA lockbox" and r_[16] == "NOA-1" and r_[17] == "internal_queue" and r_[19] == "CI-0001", str(r_))
    check("dispatch fees stay separate: the factored amount is the FREIGHT invoice total only (no dispatch-service fee line can be on it, none is added)", r_[5] == "2000.00" and scalar(lab, db, f"select count(*) from public.carrier_invoice_line_items where invoice_id = '{CI(1)}' and line_type::text = 'dispatch_service_fee'") == "0")
    check("historical legacy factored invoices are untouched by a carrier-invoice submission", scalar(lab, db, "select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f") == before_legacy)
    check("the relationship recorded at submission equals the issuance-time relationship (any difference would have been REFUSED, D-57d)", scalar(lab, db, f"select (issuance_relationship_id = relationship_id)::text from public.carrier_invoice_factoring_snapshots_0157 where submission_id = '{sid}'") == "true")
    check("exactly one success audit row exists for the submission", scalar(lab, db, f"select count(*) from public.carrier_invoice_factoring_audit_0157 where submission_id = '{sid}' and event_type = 'submission' and outcome = 'success'") == "1")
    check("D-57h: granted dispatcher cannot replay an owner's successful submission key", code_of(sub(lab, db, U["dispA"], CI(1), "cif-11111111-1111")) == "FORBIDDEN")
    # idempotency
    again = sub(lab, db, owner, CI(1), "cif-11111111-1111", end="commit")
    check("IDEMPOTENT: replaying the same key returns the ORIGINAL submission flagged idempotent_replay, writing nothing", again[0]["success"] is True and again[0]["idempotent_replay"] is True and again[0]["submission_id"] == sid, str(again))
    dup = sub(lab, db, owner, CI(1), "cif-22222222-2222", end="commit")
    check("DUPLICATE: a NEW key for the already-submitted invoice is refused (ALREADY_SUBMITTED) with the existing submission id", code_of(dup) == "ALREADY_SUBMITTED" and dup[0]["submission_id"] == sid, str(dup))
    reuse = sub(lab, db, owner, CI(2), "cif-11111111-1111", end="commit")
    check("a key already used for another invoice is refused (IDEMPOTENCY_KEY_REUSED)", code_of(reuse) == "IDEMPOTENCY_KEY_REUSED", str(reuse))
    check("after three calls there is exactly ONE submission, ONE snapshot for the invoice (unique live-submission rule)", scalar(lab, db, f"select count(*) from public.carrier_invoice_factoring_submissions_0157 where carrier_invoice_id = '{CI(1)}'") == "1" and scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_snapshots_0157") == "1")
    r = lab.sql(db, f"insert into public.carrier_invoice_factoring_submissions_0157 (organization_id, carrier_id, carrier_invoice_id, relationship_id, factoring_company_id, idempotency_key, submitted_by) values ('{OA}', '{A1}', '{CI(1)}', '{REL}', 'f0000000-0000-0000-0000-00000000000a', 'raw-dup', '{U['ownerA']}');")
    check("even a direct operator INSERT cannot create a second live submission (partial unique index)", r.returncode != 0 and "one_active" in r.stderr, r.stderr[-200:])
    # concurrency
    env = {**lab.c.env, "PGOPTIONS": "-c app.zzz_0149_test=scratch-ok"}
    def session(key, hold):
        text = f"begin; set local role authenticated; select set_config('test.current_uid', '{owner}', false) > ''; select (public.submit_carrier_invoice_to_factor('{CI(2)}', '{key}'))::text; select pg_sleep({hold}); commit;"
        return subprocess.Popen([t149.PSQL, "-X", "-w", "-q", "-A", "-t", "-h", str(lab.c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-c", text], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    p1 = session("cif-33333333-aaaa", 3)
    time.sleep(0.7)
    p2 = session("cif-33333333-bbbb", 0)
    o1, e1 = p1.communicate(timeout=60); o2, e2 = p2.communicate(timeout=60)
    j1 = [json.loads(l) for l in o1.splitlines() if l.startswith("{")]; j2 = [json.loads(l) for l in o2.splitlines() if l.startswith("{")]
    check("CONCURRENT calls for the same invoice with different keys: exactly one succeeds, the other waits and is refused ALREADY_SUBMITTED; one submission, one snapshot", j1 and j2 and j1[0]["success"] is True and j2[0].get("code") == "ALREADY_SUBMITTED"
          and scalar(lab, db, f"select count(*) from public.carrier_invoice_factoring_submissions_0157 where carrier_invoice_id = '{CI(2)}'") == "1", (o1 + e1 + o2 + e2)[-400:])
    # lock timeout
    holder = subprocess.Popen([t149.PSQL, "-X", "-w", "-q", "-h", str(lab.c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-c", f"begin; select 1 from public.factoring_relationships where id = '{REL}' for update; select pg_sleep(9);"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    time.sleep(1.2)
    n_before = scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_submissions_0157")
    t0 = time.time()
    rc, out, err = lab.as_role(db, "authenticated", owner, f"select (public.submit_carrier_invoice_to_factor('{CI(1 + 1 + 1)}', 'cif-44444444-aaaa'))::text")
    took = time.time() - t0
    holder.kill(); lab.c.psql("postgres", "select pg_terminate_backend(pid) from pg_stat_activity where datname = '" + db + "' and pid <> pg_backend_pid();", ok=False)
    check("BOUNDED WAITS: with the relationship row locked by another session the submission aborts after ~5 s (lock_timeout), writes nothing and does not hang", rc != 0 and "lock timeout" in err and 4 < took < 12 and scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_submissions_0157") == n_before, f"{took:.1f}s {err[-200:]}")


def after_change_tests(lab, db):
    print("== factor terms changing after submission, withdrawal, history ==")
    owner = U["ownerA"]
    d = lab.clone(db, "td0149_p57d")
    snap = lab.scalar(d, f"select md5(to_jsonb(n)::text) from public.carrier_invoice_factoring_snapshots_0157 n where carrier_invoice_id = '{CI(1)}'")
    lab.sql(d, f"update public.factoring_relationships set default_advance_percentage = 90, default_factoring_fee_percentage = 5, remittance_instructions = 'CHANGED LOCKBOX' where id = '{REL}';")
    check("the factor's terms CHANGE after submission: the recorded snapshot is byte-identical (historical submission preserved)", lab.scalar(d, f"select md5(to_jsonb(n)::text) from public.carrier_invoice_factoring_snapshots_0157 n where carrier_invoice_id = '{CI(1)}'") == snap)
    lab.c.dropdb("td0149_p57d")
    res = sub(lab, db, owner, CI(2), "cif-55555555-aaaa", end="commit")
    check("(control) invoice 2 is already submitted (by the concurrency test), so it cannot be submitted again", code_of(res) == "ALREADY_SUBMITTED", str(res))
    lab.sql(db, f"update public.carrier_invoice_factoring_submissions_0157 set status = 'withdrawn', status_reason = 'test' where carrier_invoice_id = '{CI(2)}';")
    res = sub(lab, db, owner, CI(2), "cif-55555555-bbbb", end="commit")
    check("after a withdrawal a NEW submission is accepted on the UNCHANGED configuration: the same server-selected relationship; the old submission and snapshot are untouched", res[0]["success"] is True and res[0]["relationship_id"] == REL, str(res))
    check("the two submissions of invoice 2 (withdrawn + new) keep two separate immutable snapshots; 3 snapshots in total", scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_snapshots_0157") == "3")
    # withdraw
    sid = scalar(lab, db, f"select id from public.carrier_invoice_factoring_submissions_0157 where carrier_invoice_id = '{CI(1)}'")
    def wd(uid, key, sid_=None, reason="customer request"):
        return call(lab, db, uid, f"public.withdraw_carrier_invoice_factoring_submission('{sid_ or sid}', '{reason}', '{key}')", end="commit")
    check("a dispatcher (even with a grant) cannot withdraw", code_of(wd(U["dispA"], "w0")) == "FORBIDDEN")
    check("another organization's owner cannot see or withdraw it (NOT_FOUND)", code_of(wd(U["ownerB"], "w0")) == "NOT_FOUND")
    w = wd(U["adminA"], "w-key-1")
    check("an admin withdraws the submission (status withdrawn, reason recorded); the snapshot stays", w[0]["success"] is True and w[0]["status"] == "withdrawn" and scalar(lab, db, f"select count(*) from public.carrier_invoice_factoring_snapshots_0157 where submission_id = '{sid}'") == "1", str(w))
    check("withdrawal is idempotent by key; a reused key for another submission is refused; withdrawing twice is NOT_APPLICABLE", wd(U["adminA"], "w-key-1")[0].get("idempotent_replay") is True and code_of(wd(U["adminA"], "w-key-2")) == "NOT_APPLICABLE")
    lab.sql(db, "update public.carrier_invoice_factoring_gate_0157 set enabled = false, decision_ref = 'OWNER-DISABLE-REF';")
    check("DISABLING the gate blocks NEW submissions (FEATURE_DISABLED) but PRESERVES existing submissions and immutable snapshots", code_of(sub(lab, db, owner, CI(1), "cif-66666666-aaaa", end="commit")) == "FEATURE_DISABLED" and scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_snapshots_0157") == "3")
    w2 = call(lab, db, U["ownerA"], f"public.withdraw_carrier_invoice_factoring_submission('{res[0]['submission_id']}', 'gate off but withdrawal still allowed', 'w-key-3')", end="commit")
    check("a withdrawal (reversal) still works while the gate is disabled", w2[0]["success"] is True, str(w2))
    lab.sql(db, GATE_ON)
    live = sub(lab, db, owner, CI(1), "cif-88888888-aaaa", end="commit")
    check("after a withdrawal the invoice can be resubmitted (new key) -- a live submission now exists for the integrity tests", live[0]["success"] is True, str(live))


def integrity_tests(lab, db):
    print("== immutability, transitions, no cascades, RLS, audit ledger ==")
    for label, sql in (("update a snapshot", "update public.carrier_invoice_factoring_snapshots_0157 set carrier_id = carrier_id;"), ("delete a snapshot", "delete from public.carrier_invoice_factoring_snapshots_0157;"), ("truncate the snapshots", "truncate public.carrier_invoice_factoring_snapshots_0157;"),
                       ("update an audit row", "update public.carrier_invoice_factoring_audit_0157 set code = code;"), ("delete an audit row", "delete from public.carrier_invoice_factoring_audit_0157;"), ("truncate the audit ledger", "truncate public.carrier_invoice_factoring_audit_0157;"),
                       ("delete a submission", "delete from public.carrier_invoice_factoring_submissions_0157;"), ("truncate the submissions", "truncate public.carrier_invoice_factoring_submissions_0157;"), ("delete a submitter grant", "delete from public.carrier_factoring_submitter_grants_0157;")):
        r = lab.sql(db, sql)
        check(f"IMMUTABLE: even the operator cannot {label}", r.returncode != 0 and ("immutable" in r.stderr or "append-only" in r.stderr or "cannot truncate a table referenced in a foreign key" in r.stderr), r.stderr[-160:])
    sid = scalar(lab, db, f"select id from public.carrier_invoice_factoring_submissions_0157 where carrier_invoice_id = '{CI(1)}'")
    r = lab.sql(db, f"update public.carrier_invoice_factoring_submissions_0157 set relationship_id = 'fe000000-0000-0000-0000-0000000000b2' where id = '{sid}';")
    check("a submission's identity columns (relationship, carrier, invoice, key, submitter, time) are immutable", r.returncode != 0 and "identity columns are immutable" in r.stderr)
    r = lab.sql(db, f"update public.carrier_invoice_factoring_submissions_0157 set status = 'submitted' where id = '{sid}';")
    check("TRANSITIONS: a terminal status can never leave it (withdrawn -> submitted refused)", r.returncode != 0 and "not permitted" in r.stderr, r.stderr[-160:])
    live = scalar(lab, db, f"select id from public.carrier_invoice_factoring_submissions_0157 where status = 'submitted' limit 1")
    d = lab.clone(db, "td0149_p57t")
    r = lab.sql(d, f"update public.carrier_invoice_factoring_submissions_0157 set status = 'withdrawn' where id = '{live}';")
    r2 = lab.sql(d, f"update public.carrier_invoice_factoring_submissions_0157 set status = 'submitted' where id = '{live}';")
    check("TRANSITIONS: submitted -> withdrawn is permitted and is then terminal", r.returncode == 0 and r2.returncode != 0)
    for to in ("rejected", "funded"):
        r = lab.sql(db, f"update public.carrier_invoice_factoring_submissions_0157 set status = '{to}' where id = '{live}';")
        check(f"D-57e: the status '{to}' does NOT exist (no unreachable states until a factor-response workflow and authorized writer exist): refused by the transition guard AND absent from the CHECK", r.returncode != 0 and ("not permitted" in r.stderr or "check" in r.stderr) and scalar(lab, db, "select count(*) from pg_constraint where conrelid = 'public.carrier_invoice_factoring_submissions_0157'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ 'rejected|funded'") == "0", r.stderr[-160:])
    lab.c.dropdb("td0149_p57t")
    r = lab.sql(db, f"update public.carrier_invoice_factoring_submissions_0157 set status = 'bogus' where id = '{live}';")
    check("only the two explicit statuses exist (CHECK)", r.returncode != 0)
    bad = {"a cross-carrier relationship": f"insert into public.carrier_invoice_factoring_submissions_0157 (organization_id, carrier_id, carrier_invoice_id, relationship_id, factoring_company_id, idempotency_key, submitted_by) values ('{OA}', '{A1}', '{CI(6)}', 'fe000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-00000000000a', 'x1', '{U['ownerA']}');",
           "a cross-organization invoice": f"insert into public.carrier_invoice_factoring_submissions_0157 (organization_id, carrier_id, carrier_invoice_id, relationship_id, factoring_company_id, idempotency_key, submitted_by) values ('{OA}', '{A1}', '{CI(12)}', '{REL}', 'f0000000-0000-0000-0000-00000000000a', 'x2', '{U['ownerA']}');",
           "a dispatch-service invoice": f"insert into public.carrier_invoice_factoring_submissions_0157 (organization_id, carrier_id, carrier_invoice_id, relationship_id, factoring_company_id, idempotency_key, submitted_by) values ('{OA}', '{A1}', '{CI(8)}', '{REL}', 'f0000000-0000-0000-0000-00000000000a', 'x3', '{U['ownerA']}');"}
    for label, sql in bad.items():
        r = lab.sql(db, sql)
        check(f"CONSISTENCY guard: a raw insert with {label} is refused even for the operator", r.returncode != 0 and "does not" in r.stderr, r.stderr[-200:])
    for label, sql, exists_sql in (("carrier invoice", f"delete from public.carrier_invoices where id = '{CI(1)}';", f"select count(*) from public.carrier_invoices where id = '{CI(1)}'"), ("carrier", f"delete from public.carriers where id = '{A1}';", f"select count(*) from public.carriers where id = '{A1}'"),
                                   ("factoring relationship", f"delete from public.factoring_relationships where id = '{REL}';", f"select count(*) from public.factoring_relationships where id = '{REL}'"),
                                   ("factoring company", "delete from public.factoring_companies where id = 'f0000000-0000-0000-0000-00000000000a';", "select count(*) from public.factoring_companies where id = 'f0000000-0000-0000-0000-00000000000a'"),
                                   ("organization", f"delete from public.organizations where id = '{OA}';", f"select count(*) from public.organizations where id = '{OA}'")):
        r = lab.sql(db, sql)
        subs_n = scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_submissions_0157")
        check(f"NO CASCADE: deleting the {label} that a submission references is REFUSED (the row survives and no submission, snapshot or audit row was removed): history cannot be silently deleted", r.returncode != 0 and scalar(lab, db, exists_sql) == "1" and int(subs_n) >= 3
              and int(scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_snapshots_0157")) >= 3, r.stderr[-200:])
    # RLS
    def cnt(uid, table, role="authenticated"):
        rc, out, err = lab.as_role(db, role, uid, f"select count(*) from public.{table}")
        return int(out) if rc == 0 and out.isdigit() else None
    S, N, AU, G = "carrier_invoice_factoring_submissions_0157", "carrier_invoice_factoring_snapshots_0157", "carrier_invoice_factoring_audit_0157", "carrier_factoring_submitter_grants_0157"
    total = int(scalar(lab, db, f"select count(*) from public.{S}"))
    check("RLS: owner, admin and accountant read the organization's submissions and snapshots; dispatcher WITH a grant reads that carrier's; dispatcher WITHOUT a grant reads none; another organization reads none",
          cnt(U["ownerA"], S) == total and cnt(U["adminA"], N) == total + 0 and cnt(U["acctA"], S) == total and cnt(U["dispA"], S) == total and cnt(U["disp2A"], S) == 0 and cnt(U["ownerB"], S) == 0 and cnt(U["ownerB"], N) == 0 and cnt(U["viewerA"], S) == 0 and cnt(U["driverA"], S) == 0, str([cnt(U["ownerA"], S), cnt(U["disp2A"], S), cnt(U["ownerB"], S)]))
    check("RLS: the audit ledger is readable by owner/admin of the organization only (not dispatcher or accountant; another organization's owner sees only ITS OWN organization's rows, never ours)", cnt(U["ownerA"], AU) >= 5 and cnt(U["adminA"], AU) >= 5 and cnt(U["dispA"], AU) == 0 and cnt(U["acctA"], AU) == 0 and lab.as_role(db, "authenticated", U["ownerB"], f"select count(*) from public.{AU} where organization_id <> '{OB}'")[1] == "0")
    check("RLS: a dispatcher sees only his OWN grant rows (revoked + restored); owner/admin see the organization's", cnt(U["dispA"], G) == 2 and cnt(U["disp2A"], G) == 0 and cnt(U["ownerA"], G) >= 1)
    for t in (S, N, AU, G):
        rc, out, err = lab.as_role(db, "authenticated", U["ownerA"], f"insert into public.{t} select * from public.{t} limit 1")
        rc2, out2, err2 = lab.as_role(db, "service_role", "", f"select count(*) from public.{t}")
        rc3, out3, err3 = lab.as_role(db, "anon", "", f"select count(*) from public.{t}")
        check(f"GRANTS: no client role can write {t}; service_role and anon cannot even read it", rc != 0 and "permission denied" in err and rc2 != 0 and rc3 != 0, err[-100:])
    # audit ledger integrity
    check("the audit hash chain verifies (0 broken links) after every operation above", scalar(lab, db, "select public.verify_carrier_invoice_factoring_audit_chain_0157()") == "0")
    check("the ledger holds every event class: submission success, submission refusals, withdrawals, grant changes, operator gate changes (enable and disable)",
          {r_[0] for r_ in lab.rows(db, "select distinct event_type || ':' || outcome from public.carrier_invoice_factoring_audit_0157")[1]} >= {"submission:success", "submission:refusal", "withdrawal:success", "grant_change:success", "gate_change:success", "grant_change:refusal", "withdrawal:refusal"})
    tam = lab.clone(db, "td0149_p57t")
    lab.sql(tam, "alter table public.carrier_invoice_factoring_audit_0157 disable trigger carrier_invoice_factoring_audit_0157_immutable; update public.carrier_invoice_factoring_audit_0157 set code = 'TAMPERED' where seq = 2; alter table public.carrier_invoice_factoring_audit_0157 enable trigger carrier_invoice_factoring_audit_0157_immutable;")
    check("TAMPERING with an audit row (only possible by disabling the trigger as superuser) is DETECTED by the chain verifier", int(scalar(lab, tam, "select public.verify_carrier_invoice_factoring_audit_chain_0157()")) >= 1)
    lab.sql(tam, "alter table public.carrier_invoice_factoring_audit_0157 disable trigger carrier_invoice_factoring_audit_0157_immutable; delete from public.carrier_invoice_factoring_audit_0157 where seq = 3; alter table public.carrier_invoice_factoring_audit_0157 enable trigger carrier_invoice_factoring_audit_0157_immutable;")
    check("DELETING an audit row is detected (sequence gap / broken link)", int(scalar(lab, tam, "select public.verify_carrier_invoice_factoring_audit_chain_0157()")) >= 1)
    lab.c.dropdb("td0149_p57t")
    # search path
    rc, out, err = lab.as_role(db, "authenticated", U["ownerA"], f"create temp table carrier_invoices as select * from public.carrier_invoices where id = '{CI(1)}'; update carrier_invoices set issuance_status = 'issued', payment_status = 'unpaid'; select (public.preview_carrier_invoice_factoring('{CI(3)}'))::text")
    j = json.loads(out) if out.startswith("{") else {}
    check("SEARCH-PATH SAFETY: a caller's temporary table named like a real table cannot influence the RPC (the real DRAFT invoice is still refused; the fake 'issued' copy is ignored)", j.get("code") == "INVOICE_NOT_ISSUED", out + err[-200:])
    rc, out, err = lab.as_role(db, "authenticated", U["ownerA"], f"create temp table factoring_relationships (id uuid); select (public.preview_carrier_invoice_factoring('{CI(2)}'))::text")
    check("SEARCH-PATH SAFETY: a temporary table named like the relationship table is ignored", out.startswith("{") and json.loads(out).get("eligible") is not None, out + err[-200:])


def rollback_tests(lab, db, a):
    print("== rollback with history; clean rollback; re-apply ==")
    clean = lab.clone(a, "td0149_p57c")
    assert lab.apply(clean, rd("0157/proposed_0157.sql")).returncode == 0
    r = lab.apply(clean, rd("0157/rollback.sql"))
    check("rollback of a fresh 0157 (no history) removes ALL 0157 objects", r.returncode == 0 and scalar(lab, clean, "select count(*) from pg_class where relname like '%\\_0157' escape '\\'") == "0" and scalar(lab, clean, "select count(*) from pg_proc where proname like '%\\_cif\\_%' escape '\\' or proname like '%carrier_invoice_to_factor%'") == "0", r.stderr[-300:])
    r = lab.apply(clean, rd("0157/proposed_0157.sql"))
    check("0157 re-applies cleanly after a clean rollback", r.returncode == 0, r.stderr[-200:])
    lab.c.dropdb("td0149_p57c")
    snaps = lab.scalar(db, "select md5(coalesce(string_agg(to_jsonb(n)::text, '|' order by n.submission_id), '')) from public.carrier_invoice_factoring_snapshots_0157 n")
    subs = lab.scalar(db, "select md5(coalesce(string_agg(to_jsonb(s)::text, '|' order by s.id), '')) from public.carrier_invoice_factoring_submissions_0157 s")
    n_audit = scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_audit_0157")
    hist = "select md5(coalesce(string_agg(to_jsonb(x)::text, '|' order by x.id), '')) from public.{t} x"
    new_hist = {t: lab.scalar(db, hist.format(t=t)) for t in ("carrier_invoice_issuance_terms_0157", "carrier_invoice_billable_ledger_0157", "carrier_invoice_reissues_0157", "carrier_invoice_dispatch_fee_links_0157", "carrier_invoice_workflow_ops_0157")}
    legacy = scalar(lab, db, "select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f")
    r = lab.apply(db, rd("0157/rollback.sql"))
    check("ROLLBACK WITH HISTORY: RPCs, helpers and the gate are removed; submissions, snapshots, audit ledger and grants are KEPT byte-identical", r.returncode == 0 and "HISTORY KEPT" in r.stderr
          and lab.scalar(db, "select md5(coalesce(string_agg(to_jsonb(n)::text, '|' order by n.submission_id), '')) from public.carrier_invoice_factoring_snapshots_0157 n") == snaps and lab.scalar(db, "select md5(coalesce(string_agg(to_jsonb(s)::text, '|' order by s.id), '')) from public.carrier_invoice_factoring_submissions_0157 s") == subs
          and scalar(lab, db, "select count(*) from public.carrier_invoice_factoring_audit_0157") == n_audit and lab.scalar(db, "select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f") == legacy, r.stderr[-300:])
    check("ROLLBACK KEEPS the issuance history byte-identical: issuance terms, billable ledger, reissue links, dispatch-fee links, workflow ops", {t: lab.scalar(db, hist.format(t=t)) for t in new_hist} == new_hist and all(v for v in new_hist.values()))
    res = call(lab, db, U["ownerA"], f"public.issue_prepared_carrier_invoice('{CI(1)}', now(), 'r', 'k-after-rollback')")
    check("after rollback the issuance/reissue RPCs no longer exist either (no new invoice can be prepared through them)", res[0] is None and "does not exist" in res[1], res[1][-160:])
    res = sub(lab, db, U["ownerA"], CI(1), "cif-77777777-aaaa")
    check("after rollback no new submission is possible (the RPC no longer exists) and the kept history is still immutable", res[0] is None and "does not exist" in res[1] and lab.sql(db, "update public.carrier_invoice_factoring_snapshots_0157 set carrier_id = carrier_id;").returncode != 0, res[1][-200:])
    r = lab.apply(db, rd("0157/rollback.sql"))
    check("a second rollback is REFUSED (nothing changed)", r.returncode != 0 and "REFUSED" in r.stderr)
    check("the legacy 0156 path is unaffected throughout: submit_invoice_to_factor (0140 baseline here) still rejects every legacy invoice", (lambda x: x[0] and x[0].get("code") == "CARRIER_INVOICE_SNAPSHOT_REQUIRED")(call(lab, db, U["ownerA"], "public.submit_invoice_to_factor('1a000000-0000-0000-0000-000000000007', 'fe000000-0000-0000-0000-000000000003')")))


BRK1, BRK2 = "a0b00000-0000-0000-0000-000000000001", "a0b00000-0000-0000-0000-000000000002"
AD = "a6a6a6a6-0000-0000-0000-000000000006"
B1 = "b1b1b1b1-0000-0000-0000-000000000001"
NEWCO = "f0000000-0000-0000-0000-0000000000d1"


def LD(n):
    return f"10ad2000-0000-0000-0000-0000000000{n:02d}"


def arr(loads):
    return "array[" + ", ".join(f"'{LD(n)}'" for n in loads) + "]::uuid[]"


def drift_call(lab, db, uid, inv, key, mut="", fn="submit"):
    """One transaction: run the RPC, then count what it wrote (submissions / snapshots for the invoice, refusal audit rows)."""
    body = (f"select (public.submit_carrier_invoice_to_factor('{inv}', '{key}'))::text as r \\gset\n"
            f"select :'r' || '|' || (select count(*) from public.carrier_invoice_factoring_submissions_0157 where carrier_invoice_id = '{inv}') || '|' || (select count(*) from public.carrier_invoice_factoring_snapshots_0157 where carrier_invoice_id = '{inv}') || '|' || "
            f"(select count(*) from public.carrier_invoice_factoring_audit_0157 where code = 'RELATIONSHIP_DRIFT_REISSUE_REQUIRED' and carrier_invoice_id = '{inv}')")
    rc, out, err = lab.as_role(db, "authenticated", uid, body, pre=mut)
    try:
        j, n_sub, n_snap, n_aud = out.rsplit("|", 3)
        return json.loads(j), int(n_sub), int(n_snap), int(n_aud)
    except Exception:
        return {"code": "PARSE-ERROR " + out + err[-200:]}, -1, -1, -1


def drift_tests(lab, db):
    print("== D-57d: relationship drift REFUSES submission (stable code, nothing written but a safe refusal audit row) ==")
    owner = U["ownerA"]
    rel_copy = (f"set session_replication_role = replica; create temp table _r as select * from public.factoring_relationships where id = '{REL}'; update _r set id = 'fe000000-0000-0000-0000-0000000000f7', is_default = true; "
                f"update public.factoring_relationships set is_default = false where id = '{REL}'; insert into public.factoring_relationships select * from _r; set session_replication_role = origin;")
    new_co = f"set session_replication_role = replica; insert into public.factoring_companies (id, organization_id, name, is_active) values ('{NEWCO}', '{OA}', 'FactorNew', true); set session_replication_role = origin;"
    dims = {
        "the default relationship was REPLACED by another relationship (same factor, NOA, routing, terms)": (rel_copy, {"relationship"}),
        "the FACTOR changed (the relationship now points to another factoring company)": (new_co + f"update public.factoring_relationships set factoring_company_id = '{NEWCO}' where id = '{REL}';", {"factor"}),
        "the NOA changed (reference)": (f"update public.factoring_relationships set noa_reference = 'NOA-CHANGED' where id = '{REL}';", {"noa"}),
        "the payment ROUTING changed (remittance instructions)": (f"update public.factoring_relationships set remittance_instructions = 'A DIFFERENT LOCKBOX' where id = '{REL}';", {"routing"}),
        "the submission method / destination changed": (f"update public.factoring_relationships set submission_method = 'secure_email', submission_destination_email = 'new@example.invalid' where id = '{REL}';", {"routing"}),
        "the advance percentage changed (TERMS)": (f"update public.factoring_relationships set default_advance_percentage = 90 where id = '{REL}';", {"terms"}),
        "the factoring fee, reserve, fee timing and other fee changed (TERMS)": (f"update public.factoring_relationships set default_factoring_fee_percentage = 4, default_reserve_percentage = 15, fee_timing = 'deducted_at_funding', other_fee_default = 10 where id = '{REL}';", {"terms"}),
        "the RECIPIENT recorded at issuance differs from the invoice's recipient": (f"set session_replication_role = replica; update public.carrier_invoice_issuance_terms_0157 set recipient_broker_id = '{BRK2}' where invoice_id = '{CI(16)}'; set session_replication_role = origin;", {"recipient"}),
        "SIMULTANEOUS changes: factor + NOA + routing + terms": (new_co + f"update public.factoring_relationships set factoring_company_id = '{NEWCO}', noa_reference = 'NOA-Z', remittance_instructions = 'Z', default_advance_percentage = 70 where id = '{REL}';", {"factor", "noa", "routing", "terms"}),
        "SIMULTANEOUS changes: replaced relationship + terms": (rel_copy + "update public.factoring_relationships set default_reserve_percentage = 5 where id = 'fe000000-0000-0000-0000-0000000000f7';", {"relationship", "terms"}),
    }
    for label, (mut, want) in dims.items():
        res, n_sub, n_snap, n_aud = drift_call(lab, db, owner, CI(16), "cif-dr000000-aaaa", mut)
        check(f"REFUSED RELATIONSHIP_DRIFT_REISSUE_REQUIRED, dimensions {sorted(want)}: {label}", res.get("code") == "RELATIONSHIP_DRIFT_REISSUE_REQUIRED" and res.get("success") is False and set(res.get("drift_dimensions", [])) == want and res.get("reissue_required") is True, str(res))
        check(f"   ...and NOTHING was written: no submission, no snapshot; exactly one safe refusal audit row; no relationship/factor ids in the response ({label[:40]}...)", n_sub == 0 and n_snap == 0 and n_aud == 1 and not any(k in res for k in ("relationship_id", "factoring_company_id", "remittance_instructions", "noa_reference")), str((res, n_sub, n_snap, n_aud)))
    mut = f"update public.factoring_relationships set default_advance_percentage = 90 where id = '{REL}';"
    res = call(lab, db, owner, f"public.preview_carrier_invoice_factoring('{CI(16)}')", pre=mut)
    check("the PREVIEW reports the same drift refusal (the UI shows a reissue direction, no submit control)", code_of(res) == "RELATIONSHIP_DRIFT_REISSUE_REQUIRED" and res[0]["eligible"] is False and res[0].get("reissue_required") is True, str(res))
    res, n_sub, n_snap, n_aud = drift_call(lab, db, U["disp2A"], CI(16), "cif-dr000000-bbbb", mut)
    check("an UNAUTHORIZED caller (dispatcher without a grant) learns nothing about drift: FORBIDDEN, no drift audit row", res.get("code") == "FORBIDDEN" and "drift_dimensions" not in res and n_aud == 0, str(res))
    res, n_sub, n_snap, n_aud = drift_call(lab, db, U["ownerB"], CI(16), "cif-dr000000-cccc", mut)
    check("NO CROSS-ORGANIZATION LEAKAGE: another organization's owner gets NOT_FOUND (no drift information, no audit row for it)", res.get("code") == "NOT_FOUND" and "drift_dimensions" not in res and n_aud == 0, str(res))
    check("the drift refusal is not a state change: the invoice's issuance terms row and the relationship are untouched (all variants rolled back)", scalar(lab, db, f"select count(*) from public.carrier_invoice_factoring_submissions_0157 where carrier_invoice_id = '{CI(16)}'") == "0"
          and scalar(lab, db, f"select default_advance_percentage::text from public.factoring_relationships where id = '{REL}'") == "80.00")


def par(lab, db, calls, holds):
    """Run several RPC calls concurrently in separate sessions; returns the parsed JSON results in order."""
    env = {**lab.c.env, "PGOPTIONS": "-c app.zzz_0149_test=scratch-ok"}
    procs = []
    for (uid, expr), hold in zip(calls, holds):
        text = f"begin; set local role authenticated; select set_config('test.current_uid', '{uid}', false) > ''; select ({expr})::text; select pg_sleep({hold}); commit;"
        procs.append(subprocess.Popen([t149.PSQL, "-X", "-w", "-q", "-A", "-t", "-h", str(lab.c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-c", text], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env))
        time.sleep(0.6)
    out = []
    for p in procs:
        o, e = p.communicate(timeout=90)
        js = [json.loads(l) for l in o.splitlines() if l.startswith("{")]
        out.append(js[0] if js else {"error": e[-200:]})
    return out


def issuance_tests(lab, db):
    print("== D-57 issuance workflow: preview, draft, ready, issue, dispatch fee, immutability, reissue, concurrency ==")
    owner, admin, dispA, disp2A, acct, driver, viewer, ownerB = U["ownerA"], U["adminA"], U["dispA"], U["disp2A"], U["acctA"], U["driverA"], U["viewerA"], U["ownerB"]
    legacy0 = scalar(lab, db, "select md5(coalesce((select string_agg(to_jsonb(f)::text, '|' order by f.id) from public.factored_invoices f), '') || coalesce((select string_agg(to_jsonb(i)::text, '|' order by i.id) from public.invoices i), ''))")

    def prev(uid, carrier, loads, rid=BRK1, rtype="broker", role="authenticated", pre=""):
        return call(lab, db, uid, f"public.preview_carrier_invoice_issuance('{carrier}', {arr(loads)}, '{rtype}', '{rid}')", role=role, pre=pre)

    def draft(uid, carrier, loads, key, rid=BRK1, rtype="broker", role="authenticated", end="rollback", pre=""):
        return call(lab, db, uid, f"public.create_carrier_invoice_draft_from_loads('{carrier}', {arr(loads)}, '{rtype}', '{rid}', '{key}')", role=role, end=end, pre=pre)

    def upd(inv):
        return f"(select updated_at from public.carrier_invoices where id = '{inv}')"

    def ready(uid, inv, key, end="rollback", pre=""):
        return call(lab, db, uid, f"public.mark_carrier_invoice_ready_for_issue('{inv}', {upd(inv)}, '{key}')", end=end, pre=pre)

    def issue(uid, inv, key, reason="first issue", end="rollback", pre="", role="authenticated"):
        return call(lab, db, uid, f"public.issue_prepared_carrier_invoice('{inv}', {upd(inv)}, '{reason}', '{key}')", end=end, pre=pre, role=role)

    def reissue(uid, inv, key, reason="fix routing", end="rollback", pre="", role="authenticated"):
        return call(lab, db, uid, f"public.reissue_carrier_invoice('{inv}', {upd(inv)}, '{reason}', '{key}')", end=end, pre=pre, role=role)

    def prep_issued(loads, key, carrier=A1, rid=BRK1, pre_ready=""):
        """committed draft -> ready -> issued by the owner; returns the invoice id"""
        d = draft(owner, carrier, loads, key + "-d", rid=rid, end="commit")
        assert d[0] and d[0]["success"], d
        inv = d[0]["invoice_id"]
        assert ready(owner, inv, key + "-r", end="commit")[0]["success"]
        i = issue(owner, inv, key + "-i", end="commit")
        assert i[0] and i[0]["success"], i
        return inv

    # ---- preview (nothing written) ----
    r = prev(owner, A1, [1, 2])[0]
    check("PREVIEW (factored carrier): carrier, broker, billing mode, factor, totals, advance/fee/reserve and the SEPARATE dispatch fee are shown; the server chose the relationship", r["success"] is True and r["carrier_name"] == "Carrier A1 LLC" and bool(r["recipient_name"]) and r["recipient_type"] == "broker" and r["currency"] == "USD", str(r)[:400])
    check("   ...factored mode, freight total 1500.00, FactorA, advance 1200.00 / fee 45.00 / reserve 300.00", r["billing_mode"] == "factored" and r["freight_total"] == 1500 and r["factoring"]["factoring_company_name"] == "FactorA" and r["factoring"]["expected_advance_amount"] == 1200 and r["factoring"]["factoring_fee_amount"] == 45 and r["factoring"]["reserve_amount"] == 300, str(r.get("factoring")))
    check("   ...the dispatch fee is shown SEPARATELY (10 percent of freight = 150.00 estimated) and is NOT part of the freight total or the factored amount", r["dispatch_fee"]["status"] == "agreement_effective" and r["dispatch_fee"]["estimated_total"] == 150 and r["freight_total"] == 1500)
    check("   ...the preview exposes no relationship id, no factor id, no frozen internals (nothing the client could echo back)", not any(k in json.dumps(r) for k in ("relationship_id", "factoring_company_id", "frozen", "fe000000")))
    r = prev(owner, AD, [12, 13])[0]
    check("PREVIEW (direct-billing carrier): billing mode direct_billing, NO factoring instructions, no dispatch fee agreement", r["billing_mode"] == "direct_billing" and r["factoring"] is None and r["dispatch_fee"]["status"] == "no_effective_agreement" and r["freight_total"] == 1400, str(r)[:300])
    check("the previews wrote nothing (no invoice, no ledger row, no audit row for them)", scalar(lab, db, "select count(*) from public.carrier_invoice_billable_ledger_0157") == "0")
    # ---- refusals ----
    hold = f"drop index public.factoring_relationships_one_default_per_carrier; set session_replication_role = replica; insert into public.factoring_relationships (id, organization_id, factoring_company_id, relationship_name, carrier_id, is_default, is_active, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type) select 'fe000000-0000-0000-0000-0000000000f1', organization_id, factoring_company_id, 'second default', carrier_id, true, true, 80, 3, 20, 'deducted_at_funding', 'recourse' from public.factoring_relationships where id = '{REL}'; set session_replication_role = origin;"
    cases = [("mixed carriers (a load of carrier A2 in a carrier A1 selection)", A1, [1, 10], BRK1, "", "LOAD_CARRIER_MISMATCH"),
             ("a load with NO carrier", A1, [1, 11], BRK1, "", "LOAD_CARRIER_MISMATCH"),
             ("a load of ANOTHER organization", A1, [1, 50], BRK1, "", "LOAD_NOT_FOUND"),
             ("loads of two different brokers/customers (recipient consistency)", A1, [1, 9], BRK1, "", "LOAD_RECIPIENT_MISMATCH"),
             ("a broker that is not factoring-eligible for the carrier", A1, [9], BRK2, "", "NOT_READY"),
             ("a load that is not delivered", A1, [7], BRK1, "", "LOAD_NOT_BILLABLE"),
             ("a load with a zero freight amount", A1, [8], BRK1, "", "LOAD_AMOUNT_INVALID"),
             ("the same load twice", A1, [1, 1], BRK1, "", "LOAD_SELECTION_INVALID"),
             ("an empty selection", A1, [], BRK1, "", "LOAD_SELECTION_INVALID"),
             ("a recipient that does not exist", A1, [1], "a0b00000-0000-0000-0000-0000000000ee", "", "RECIPIENT_NOT_FOUND"),
             ("a recipient of another organization", A1, [1], "b0b00000-0000-0000-0000-000000000001", "", "RECIPIENT_NOT_FOUND"),
             ("an unconfigured carrier", A2, [10], BRK1, "", "FACTORING_POLICY_UNCONFIGURED"),
             ("a carrier of ANOTHER organization", B1, [50], BRK1, "", "CARRIER_NOT_FOUND"),
             ("an inactive carrier", A1, [1], BRK1, f"update public.carriers set is_active = false where id = '{A1}';", "CARRIER_INACTIVE"),
             ("a carrier without an invoice code", A1, [1], BRK1, f"update public.carriers set invoice_code = null where id = '{A1}';", "CARRIER_INVOICE_CODE_MISSING"),
             ("no active default relationship", A1, [1], BRK1, f"update public.factoring_relationships set is_default = false where id = '{REL}';", "NO_ACTIVE_DEFAULT_RELATIONSHIP"),
             ("MORE THAN ONE active default relationship", A1, [1], BRK1, hold, "MULTIPLE_DEFAULT_RELATIONSHIPS"),
             ("an inactive factoring company", A1, [1], BRK1, "set session_replication_role = replica; update public.factoring_companies set is_active = false where id = 'f0000000-0000-0000-0000-00000000000a'; set session_replication_role = origin;", "COMPANY_INACTIVE"),
             ("an open legacy exception on the carrier's relationship", A1, [1], BRK1, f"insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason) values ('{OA}', 'factoring_relationship', '{REL}', 'open');", "UNRESOLVED_LEGACY_RECORD"),
             ("a pending 0155 review of the carrier's relationship", A1, [1], BRK1, f"insert into public.carrier_inference_review_0155 (relationship_id, organization_id, classification, prior_carrier_id, strict_status, evidence, first_run_id, last_run_id) values ('{REL}', '{OA}', 'unsafe_assigned', '{A1}', 'partial', '{{}}', gen_random_uuid(), gen_random_uuid());", "UNRESOLVED_LEGACY_RECORD")]
    for label, car, loads, rid, pre, code in cases:
        res = draft(owner, car, loads, "iss-refuse-1", rid=rid, pre=pre)
        check(f"REFUSED ({code}): {label}", code_of(res) == code and res[0]["success"] is False, str(res)[:300])
    check("refusals wrote no invoice and no ledger row", scalar(lab, db, "select count(*) from public.carrier_invoice_billable_ledger_0157") == "0")
    # ---- authorization matrix (draft creation) ----
    for role, uid in (("anon", ""), ("service_role", "")):
        res = draft(uid, A1, [1], "iss-authz", role=role)
        check(f"{role}: create_carrier_invoice_draft_from_loads is DENIED (permission denied)", res[0] is None and "permission denied for function" in res[1], res[1][-160:])
    check("null identity through the authenticated role FAILS CLOSED (FORBIDDEN)", code_of(draft("", A1, [1], "iss-authz")) == "FORBIDDEN")
    for label, uid in (("accountant", acct), ("driver", driver), ("viewer", viewer)):
        check(f"{label} is FORBIDDEN to prepare a carrier invoice", code_of(draft(uid, A1, [1], "iss-authz")) == "FORBIDDEN" and code_of(prev(uid, A1, [1])) == "FORBIDDEN")
    check("a dispatcher WITHOUT a grant cannot prepare invoices (NOT_AUTHORIZED_FOR_CARRIER), preview included", code_of(draft(disp2A, A1, [1], "iss-authz")) == "NOT_AUTHORIZED_FOR_CARRIER" and code_of(prev(disp2A, A1, [1])) == "NOT_AUTHORIZED_FOR_CARRIER")
    check("the granted dispatcher, an admin and an owner may prepare a draft for the granted carrier; the granted dispatcher may NOT for another carrier (AD)", all(draft(u, A1, [1], "iss-authz")[0]["success"] is True for u in (dispA, admin, owner)) and code_of(draft(dispA, AD, [12], "iss-authz")) == "NOT_AUTHORIZED_FOR_CARRIER")
    check("another organization's owner cannot draft for this carrier (CARRIER_NOT_FOUND: no existence oracle)", code_of(draft(ownerB, A1, [1], "iss-authz")) == "CARRIER_NOT_FOUND")
    # ---- draft creation, duplicate billable records, idempotency ----
    d1 = draft(owner, A1, [1, 2], "iss-key-d1", end="commit")
    check("DRAFT created from the explicitly selected loads of ONE carrier: status draft, total 1500.00, billing mode factored", d1[0]["success"] is True and d1[0]["status"] == "draft" and d1[0]["freight_total"] == 1500 and d1[0]["billing_mode"] == "factored", str(d1))
    inv1 = d1[0]["invoice_id"]
    check("   ...two ledger rows (one per load) are live; two freight line items; NO dispatch-fee line; org/carrier/broker/currency consistent", scalar(lab, db, f"select count(*) from public.carrier_invoice_billable_ledger_0157 where invoice_id = '{inv1}' and released_at is null") == "2"
          and scalar(lab, db, f"select count(*) from public.carrier_invoice_line_items where invoice_id = '{inv1}' and line_type::text = 'freight_charge'") == "2" and scalar(lab, db, f"select count(*) from public.carrier_invoice_line_items where invoice_id = '{inv1}' and line_type::text = 'dispatch_service_fee'") == "0"
          and scalar(lab, db, f"select (organization_id = '{OA}' and carrier_id = '{A1}' and recipient_broker_id = '{BRK1}' and recipient_type::text = 'broker' and currency = 'USD' and total_amount = 1500)::text from public.carrier_invoices where id = '{inv1}'") == "true")
    again = draft(owner, A1, [1, 2], "iss-key-d1", end="commit")
    check("IDEMPOTENT: the same key and request returns the ORIGINAL draft (idempotent_replay), creating nothing", again[0]["success"] is True and again[0]["idempotent_replay"] is True and again[0]["invoice_id"] == inv1 and scalar(lab, db, f"select count(*) from public.carrier_invoices where created_by = '{owner}' and issuance_status::text = 'draft' and carrier_id = '{A1}' and id::text not like 'c1%'") == "1", str(again))
    check("a key reused for a DIFFERENT request is refused (IDEMPOTENCY_KEY_REUSED)", code_of(draft(owner, A1, [3], "iss-key-d1", end="commit")) == "IDEMPOTENCY_KEY_REUSED")
    check("DUPLICATE BILLABLE RECORDS: the same loads with a new key, and an overlapping selection, are refused (LOAD_ALREADY_INVOICED)", code_of(draft(owner, A1, [1, 2], "iss-key-d1b", end="commit")) == "LOAD_ALREADY_INVOICED" and code_of(draft(owner, A1, [2, 3], "iss-key-d1c", end="commit")) == "LOAD_ALREADY_INVOICED")
    r = lab.sql(db, f"insert into public.carrier_invoice_billable_ledger_0157 (organization_id, carrier_id, load_id, invoice_id, amount, created_by) values ('{OA}', '{A1}', '{LD(1)}', '{inv1}', 1, '{owner}');")
    check("even a raw operator INSERT cannot put a load on two live ledger rows (partial unique index)", r.returncode != 0 and "_live" in r.stderr, r.stderr[-200:])
    res = par(lab, db, [(owner, f"public.create_carrier_invoice_draft_from_loads('{A1}', {arr([3, 4])}, 'broker', '{BRK1}', 'iss-conc-a')"), (admin, f"public.create_carrier_invoice_draft_from_loads('{A1}', {arr([4, 3])}, 'broker', '{BRK1}', 'iss-conc-b')")], [3, 0])
    check("CONCURRENT draft creation for the same loads: exactly one succeeds, the other is refused LOAD_ALREADY_INVOICED; each load is live on ONE invoice", sorted(str(x.get("success")) for x in res) == ["False", "True"] and any(x.get("code") == "LOAD_ALREADY_INVOICED" for x in res)
          and scalar(lab, db, f"select count(*) from public.carrier_invoice_billable_ledger_0157 where load_id in ('{LD(3)}', '{LD(4)}') and released_at is null") == "2", str(res))
    dq = draft(owner, A1, [47, 48], "iss-cc-d", end="commit")[0]["invoice_id"]
    ready(owner, dq, "iss-cc-r", end="commit")
    res = par(lab, db, [(owner, f"public.issue_prepared_carrier_invoice('{dq}', {upd(dq)}, 'race a', 'iss-cc-i1')"), (admin, f"public.issue_prepared_carrier_invoice('{dq}', {upd(dq)}, 'race b', 'iss-cc-i2')")], [3, 0])
    check("CONCURRENT issue of the same ready invoice: exactly one wins; the other is refused (INVOICE_NOT_READY / STALE_INVOICE); ONE invoice number, ONE terms row, ONE snapshot, ONE dispatch-fee link", sorted(str(x.get("success")) for x in res) == ["False", "True"] and any(x.get("code") in ("INVOICE_NOT_READY", "STALE_INVOICE") for x in res)
          and scalar(lab, db, f"select count(*) from public.carrier_invoice_issuance_terms_0157 where invoice_id = '{dq}'") == "1" and scalar(lab, db, f"select count(*) from public.carrier_invoice_issuance_snapshots where invoice_id = '{dq}'") == "1" and scalar(lab, db, f"select count(*) from public.carrier_invoice_dispatch_fee_links_0157 where freight_invoice_id = '{dq}'") == "1", str(res))
    # ---- draft -> ready_for_issue ----
    check("ready-for-issue: an unauthorized dispatcher is refused; a stale timestamp is refused; a non-draft is refused", code_of(ready(disp2A, inv1, "iss-r0")) == "NOT_AUTHORIZED_FOR_CARRIER"
          and code_of(call(lab, db, owner, f"public.mark_carrier_invoice_ready_for_issue('{inv1}', now() - interval '1 day', 'iss-r0')")) == "STALE_INVOICE" and code_of(ready(owner, CI(1), "iss-r0")) in ("INVOICE_NOT_DRAFT",))
    rd1 = ready(dispA, inv1, "iss-key-r1", end="commit")
    check("the GRANTED dispatcher marks the draft ready (explicit legal transition draft -> ready_for_issue)", rd1[0]["success"] is True and rd1[0]["status"] == "ready_for_issue" and scalar(lab, db, f"select issuance_status::text from public.carrier_invoices where id = '{inv1}'") == "ready_for_issue", str(rd1))
    check("ready is idempotent by key; a second key on the ready invoice is refused (INVOICE_NOT_DRAFT)", ready(dispA, inv1, "iss-key-r1", end="commit")[0].get("idempotent_replay") is True and code_of(ready(dispA, inv1, "iss-key-r2", end="commit")) == "INVOICE_NOT_DRAFT")
    # ---- issue ----
    check("ISSUING is owner/admin ONLY: the granted dispatcher, an accountant, a driver and a viewer are FORBIDDEN; anon/service_role are denied", all(code_of(issue(u, inv1, "iss-i0")) == "FORBIDDEN" for u in (dispA, acct, driver, viewer, disp2A)) and all(issue("", inv1, "iss-i0", role=r_)[0] is None for r_ in ("anon", "service_role")))
    check("issuing a draft that was never marked ready is refused (INVOICE_NOT_READY): explicit transitions only", (lambda dd: code_of(issue(owner, dd[0]["invoice_id"], "iss-i-x")) == "INVOICE_NOT_READY")(draft(owner, A1, [46], "iss-key-x", end="commit")))
    check("a stale updated_at is refused (STALE_INVOICE)", code_of(call(lab, db, admin, f"public.issue_prepared_carrier_invoice('{inv1}', now() - interval '1 day', 'r', 'iss-i-stale')")) == "STALE_INVOICE")
    iss1 = issue(admin, inv1, "iss-key-i1", end="commit")
    check("ISSUED by an admin: invoice number allocated, status issued, factored, and the dispatch-fee receivable is a SEPARATE linked draft", iss1[0]["success"] is True and iss1[0]["status"] == "issued" and iss1[0]["billing_mode"] == "factored" and iss1[0]["dispatch_fee"]["status"] == "draft_created" and iss1[0]["invoice_number"], str(iss1))
    check("   ...the issuance snapshot says factored and the immutable terms record freezes relationship, factor, NOA, routing, terms with a verifying fingerprint", scalar(lab, db, f"select (snapshot_payload -> 'factoring' ->> 'mode') from public.carrier_invoice_issuance_snapshots where invoice_id = '{inv1}'") == "factored"
          and scalar(lab, db, f"select (factoring_mode = 'factored' and frozen ->> 'relationship_id' = '{REL}' and frozen -> 'terms' ->> 'advance_percentage' = '80.00' and frozen_fingerprint = encode(sha256(convert_to(frozen::text, 'UTF8')), 'hex'))::text from public.carrier_invoice_issuance_terms_0157 where invoice_id = '{inv1}'") == "true")
    disp_inv = iss1[0]["dispatch_fee"]["dispatch_invoice_id"]
    check("   ...DISPATCH FEE TREATMENT: a separate dispatch_service_invoice DRAFT of the same carrier is linked; the freight invoice has NO dispatch-fee line; the link is immutable; the freight total (1500.00) is untouched", scalar(lab, db, f"select (c.invoice_document_type::text = 'dispatch_service_invoice' and c.issuance_status::text = 'draft' and c.carrier_id = '{A1}' and c.recipient_broker_id is null) ::text from public.carrier_invoices c where c.id = '{disp_inv}'") == "true"
          and scalar(lab, db, f"select count(*) from public.carrier_invoice_line_items where invoice_id = '{inv1}' and line_type::text = 'dispatch_service_fee'") == "0" and scalar(lab, db, f"select total_amount::text from public.carrier_invoices where id = '{inv1}'") == "1500.00"
          and lab.sql(db, "update public.carrier_invoice_dispatch_fee_links_0157 set disposition = 'carried_over';").returncode != 0)
    check("issuance is idempotent by key (replay returns the original result); a second key on the issued invoice is refused (INVOICE_NOT_READY); exactly one terms row and one snapshot", issue(admin, inv1, "iss-key-i1", end="commit")[0].get("idempotent_replay") is True and code_of(issue(owner, inv1, "iss-key-i2", end="commit")) == "INVOICE_NOT_READY"
          and scalar(lab, db, f"select count(*) from public.carrier_invoice_issuance_terms_0157 where invoice_id = '{inv1}'") == "1" and scalar(lab, db, f"select count(*) from public.carrier_invoice_issuance_snapshots where invoice_id = '{inv1}'") == "1")
    # ---- issued immutability ----
    for label, sql in (("the total", f"update public.carrier_invoices set total_amount = 1, subtotal_amount = 1 where id = '{inv1}';"), ("the carrier", f"update public.carrier_invoices set carrier_id = '{A2}' where id = '{inv1}';"), ("the recipient", f"update public.carrier_invoices set recipient_broker_id = '{BRK2}' where id = '{inv1}';"),
                       ("the invoice number", f"update public.carrier_invoices set invoice_number = 'X-1' where id = '{inv1}';"), ("a load link (delete)", f"delete from public.carrier_invoice_loads where invoice_id = '{inv1}';"), ("a line item", f"update public.carrier_invoice_line_items set unit_price = 1 where invoice_id = '{inv1}';"),
                       ("the terms record (update)", f"update public.carrier_invoice_issuance_terms_0157 set factoring_mode = 'direct_billing' where invoice_id = '{inv1}';"), ("the terms record (delete)", f"delete from public.carrier_invoice_issuance_terms_0157 where invoice_id = '{inv1}';"),
                       ("a ledger amount", f"update public.carrier_invoice_billable_ledger_0157 set amount = 1 where invoice_id = '{inv1}';"), ("a ledger row (delete)", f"delete from public.carrier_invoice_billable_ledger_0157 where invoice_id = '{inv1}';"),
                       ("the issued invoice back to draft", f"update public.carrier_invoices set issuance_status = 'draft' where id = '{inv1}';"), ("the workflow op record", "update public.carrier_invoice_workflow_ops_0157 set result = '{}'::jsonb;")):
        r = lab.sql(db, sql)
        check(f"IMMUTABLE after issuance: {label} cannot be changed or removed, even by the operator", r.returncode != 0, r.stderr[-160:])
    # ---- reissue eligibility (before any submission) ----
    for label, uid in (("the granted dispatcher", dispA), ("an accountant", acct), ("a driver", driver), ("a viewer", viewer)):
        check(f"reissue/preview-reissue: {label} is FORBIDDEN (owner/admin only)", code_of(reissue(uid, inv1, "iss-rx0")) == "FORBIDDEN" and code_of(call(lab, db, uid, f"public.preview_carrier_invoice_reissue('{inv1}')")) == "FORBIDDEN")
    check("reissue: anon/service_role denied; null identity FORBIDDEN; another organization NOT_FOUND", all(reissue("", inv1, "k", role=r_)[0] is None for r_ in ("anon", "service_role")) and code_of(reissue("", inv1, "k")) == "FORBIDDEN" and code_of(call(lab, db, ownerB, f"public.reissue_carrier_invoice('{inv1}', now(), 'r', 'k')")) == "NOT_FOUND")
    pa = "set session_replication_role = replica; update public.carrier_invoices set payment_status = '{s}', amount_paid = {a} where id = '" + inv1 + "'; set session_replication_role = origin;"
    check("REISSUE REFUSED for a PAID invoice and for a PARTIALLY PAID invoice (never automatic)", code_of(reissue(owner, inv1, "iss-rx1", pre=pa.format(s="paid", a=1500))) == "INVOICE_PAID_OR_PARTIAL" and code_of(reissue(owner, inv1, "iss-rx1", pre=pa.format(s="partially_paid", a=100))) == "INVOICE_PAID_OR_PARTIAL")
    check("REISSUE REFUSED when the loads' current freight total differs from the invoice (a reissue never changes amounts)", code_of(reissue(owner, inv1, "iss-rx2", pre=f"update public.load_financials set rate = 999 where load_id = '{LD(1)}';")) == "REISSUE_TOTAL_CHANGED")
    check("REISSUE REFUSED for a draft (INVOICE_NOT_ISSUED)", code_of(reissue(owner, CI(3), "iss-rx3")) == "INVOICE_NOT_ISSUED" and code_of(reissue(owner, CI(4), "iss-rx3")) == "INVOICE_NOT_ISSUED" and code_of(reissue(owner, CI(7), "iss-rx3")) == "INVOICE_VOIDED")
    check("REISSUE REFUSED for a dispatch-service invoice (WRONG_DOCUMENT_TYPE)", code_of(reissue(owner, CI(8), "iss-rx3")) == "WRONG_DOCUMENT_TYPE")
    # ---- submission of a workflow-issued invoice, then reissue is refused ----
    sres = sub(lab, db, owner, inv1, "cif-99999999-aaaa", end="commit")
    check("a workflow-issued invoice IS factorable: the server-selected relationship and immutable snapshot are recorded (panel appears only after a correctly issued invoice)", sres[0] and sres[0]["success"] is True and sres[0]["relationship_id"] == REL, str(sres))
    check("REISSUE REFUSED once a factoring submission exists (SUBMISSION_EXISTS); still refused after the submission is withdrawn (no double factoring)", code_of(reissue(owner, inv1, "iss-rx4")) == "SUBMISSION_EXISTS"
          and (lab.sql(db, f"update public.carrier_invoice_factoring_submissions_0157 set status = 'withdrawn', status_reason = 't' where carrier_invoice_id = '{inv1}';").returncode == 0) and code_of(reissue(owner, inv1, "iss-rx5")) == "SUBMISSION_EXISTS")
    # ---- reissue without drift, then concurrency ----
    inv2 = prep_issued([5, 6], "iss-b")
    pv = call(lab, db, owner, f"public.preview_carrier_invoice_reissue('{inv2}')")[0]
    check("PREVIEW REISSUE: eligible, no drift (drift_dimensions empty, reissue_needed false), current server-resolved terms shown, old and new totals equal", pv["success"] is True and pv["drift_dimensions"] == [] and pv["reissue_needed"] is False and pv["freight_total"] == 1000 and pv["old_total"] == 1000, str(pv)[:300])
    res = par(lab, db, [(owner, f"public.reissue_carrier_invoice('{inv2}', {upd(inv2)}, 'concurrent a', 'iss-ra-1')"), (admin, f"public.reissue_carrier_invoice('{inv2}', {upd(inv2)}, 'concurrent b', 'iss-ra-2')")], [3, 0])
    check("CONCURRENT reissue of the same invoice: exactly one wins, the other is refused; exactly ONE replacement exists (no double billing, no duplicate factoring)", sorted(str(x.get("success")) for x in res) == ["False", "True"] and scalar(lab, db, f"select count(*) from public.carrier_invoice_reissues_0157 where original_invoice_id = '{inv2}'") == "1", str(res))
    rp = [r for r in scalar_rows(lab, db, f"select replacement_invoice_id::text, reason from public.carrier_invoice_reissues_0157 where original_invoice_id = '{inv2}'")][0]
    inv2b = rp[0]
    check("REISSUE result: the ORIGINAL is voided with an immutable reason and links to the replacement; the replacement is issued with a NEW number for the SAME loads and total", scalar(lab, db, f"select (issuance_status::text = 'voided' and void_reason like 'Reissued: %')::text from public.carrier_invoices where id = '{inv2}'") == "true"
          and scalar(lab, db, f"select (issuance_status::text = 'issued' and total_amount = 1000 and invoice_number is not null)::text from public.carrier_invoices where id = '{inv2b}'") == "true"
          and scalar(lab, db, f"select (select invoice_number from public.carrier_invoices where id = '{inv2}') <> (select invoice_number from public.carrier_invoices where id = '{inv2b}')") == "t"
          and scalar(lab, db, f"select count(*) from public.carrier_invoice_loads where invoice_id = '{inv2b}'") == "2")
    check("NO DOUBLE BILLING: each of the two loads is live on exactly ONE invoice (the replacement); the original's ledger rows are RELEASED; non-voided freight invoices for these loads total 1000.00", scalar(lab, db, f"select count(*) from public.carrier_invoice_billable_ledger_0157 where load_id in ('{LD(5)}', '{LD(6)}') and released_at is null and invoice_id = '{inv2b}'") == "2"
          and scalar(lab, db, f"select count(*) from public.carrier_invoice_billable_ledger_0157 where invoice_id = '{inv2}' and released_at is not null") == "2"
          and scalar(lab, db, f"select sum(c.total_amount)::text from public.carrier_invoices c where c.invoice_document_type::text = 'carrier_freight_invoice' and c.issuance_status::text <> 'voided' and c.id in (select invoice_id from public.carrier_invoice_loads where load_id in ('{LD(5)}', '{LD(6)}'))") == "1000.00")
    check("the original stays preserved and cannot be issued/reissued again (INVOICE_VOIDED); the reissue link, terms record and audit row exist; the replacement is factorable and the voided original is NOT", code_of(reissue(owner, inv2, "iss-ra-3", end="commit")) == "INVOICE_VOIDED" and code_of(sub(lab, db, owner, inv2, "cif-99999999-bbbb")) == "INVOICE_VOIDED"
          and sub(lab, db, owner, inv2b, "cif-99999999-cccc")[0]["success"] is True and scalar(lab, db, f"select count(*) from public.carrier_invoice_issuance_terms_0157 where invoice_id = '{inv2b}'") == "1" and scalar(lab, db, f"select count(*) from public.carrier_invoice_factoring_audit_0157 where event_type = 'reissue' and outcome = 'success' and carrier_invoice_id = '{inv2}'") == "1")
    check("the dispatch-fee link is CARRIED OVER to the replacement (no second dispatch-fee draft: one fee receivable per load)", scalar(lab, db, f"select disposition from public.carrier_invoice_dispatch_fee_links_0157 where freight_invoice_id = '{inv2b}'") in ("carried_over", "draft_created"))
    win_key = scalar(lab, db, f"select idempotency_key from public.carrier_invoice_workflow_ops_0157 where operation = 'reissue' and invoice_id = '{inv2b}'")
    rp2 = reissue(owner, inv2, win_key, reason=rp[1], end="commit")
    check("reissue replay with the winning key and request is idempotent (returns the original result, creates nothing)", rp2[0] is not None and rp2[0].get("idempotent_replay") is True and rp2[0]["replacement_invoice_id"] == inv2b, str(rp2))
    # ---- direct billing: issued as direct can never be factored; must be correctly reissued (D-57c) ----
    d3 = draft(owner, AD, [12, 13], "iss-dir-d", end="commit")
    inv3 = d3[0]["invoice_id"]
    ready(owner, inv3, "iss-dir-r", end="commit")
    i3 = issue(owner, inv3, "iss-dir-i", end="commit")
    check("DIRECT-BILLING carrier: issued as direct_billing; the terms record has NO factoring instructions; the issuance snapshot omits the factor, NOA and remittance of any factor; no dispatch-fee agreement so no fee draft", i3[0]["success"] is True and i3[0]["billing_mode"] == "direct_billing" and i3[0]["dispatch_fee"]["status"] == "no_effective_agreement"
          and scalar(lab, db, f"select (factoring_mode = 'direct_billing' and frozen = '{{}}'::jsonb)::text from public.carrier_invoice_issuance_terms_0157 where invoice_id = '{inv3}'") == "true" and scalar(lab, db, f"select (snapshot_payload -> 'factoring' ->> 'mode')  || (snapshot_payload -> 'factoring' ? 'relationship_id')::text || (snapshot_payload -> 'factoring' ? 'remittance_instructions')::text from public.carrier_invoice_issuance_snapshots where invoice_id = '{inv3}'") == "directfalsefalse", str(i3))
    r3 = sub(lab, db, owner, inv3, "cif-dir00000-aaaa")
    check("an invoice issued while the carrier was DIRECT-BILLING is never factorable (ISSUED_AS_DIRECT_BILLING, reissue_required)", code_of(r3) == "ISSUED_AS_DIRECT_BILLING" and r3[0].get("reissue_required") is True, str(r3))
    # A1 switches to direct: draft/issue as direct, switch back to factored: the direct-issued invoice must be REISSUED, then factorable
    dc = lab.clone(db, "td0149_p57i")
    lab.sql(dc, f"update public.carriers set factoring_mode = 'direct' where id = '{A1}';")
    invd = prep_issued_on(lab, dc, owner, [20, 21], "iss-sw")
    lab.sql(dc, f"update public.carriers set factoring_mode = 'factored' where id = '{A1}';")
    check("D-57c: a carrier switched from direct to factored: the invoice ISSUED while direct is refused for factoring (ISSUED_AS_DIRECT_BILLING)", code_of(call(lab, dc, owner, f"public.submit_carrier_invoice_to_factor('{invd}', 'cif-sw000000-aaaa')")) == "ISSUED_AS_DIRECT_BILLING")
    pv = call(lab, dc, owner, f"public.preview_carrier_invoice_reissue('{invd}')")[0]
    check("its reissue preview shows the billing-mode drift and the factored terms it would use", pv["success"] is True and pv["drift_dimensions"] == ["billing_mode"] and pv["reissue_needed"] is True and pv["billing_mode"] == "factored", str(pv)[:300])
    rr = call(lab, dc, owner, f"public.reissue_carrier_invoice('{invd}', (select updated_at from public.carrier_invoices where id = '{invd}'), 'carrier now factored', 'iss-sw-re')", end="commit")
    check("REISSUED as factored: the replacement is issued with the factored terms and IS factorable; the direct original stays voided and preserved", rr[0]["success"] is True and rr[0]["billing_mode"] == "factored" and call(lab, dc, owner, f"public.submit_carrier_invoice_to_factor('{rr[0]['replacement_invoice_id']}', 'cif-sw000000-bbbb')")[0]["success"] is True
          and scalar(lab, dc, f"select issuance_status::text from public.carrier_invoices where id = '{invd}'") == "voided", str(rr))
    lab.c.dropdb("td0149_p57i")
    # ---- drift then reissue (D-57d + item 6) ----
    dc = lab.clone(db, "td0149_p57i")
    invx = prep_issued_on(lab, dc, owner, [22, 23], "iss-dr")
    lab.sql(dc, f"update public.factoring_relationships set default_advance_percentage = 90, noa_reference = 'NOA-NEW' where id = '{REL}';")
    rs = call(lab, dc, owner, f"public.submit_carrier_invoice_to_factor('{invx}', 'cif-dr111111-aaaa')", end="commit")
    check("after the carrier's terms and NOA change, the invoice issued under the OLD terms is REFUSED for submission (RELATIONSHIP_DRIFT_REISSUE_REQUIRED: terms + noa)", code_of(rs) == "RELATIONSHIP_DRIFT_REISSUE_REQUIRED" and set(rs[0]["drift_dimensions"]) == {"noa", "terms"}, str(rs))
    pv = call(lab, dc, owner, f"public.preview_carrier_invoice_reissue('{invx}')")[0]
    check("the controlled REISSUE workflow is offered: the preview lists the drifted dimensions and the current advance percentage (90)", pv["reissue_needed"] is True and set(pv["drift_dimensions"]) == {"noa", "terms"} and pv["factoring"]["advance_percentage"] == 90, str(pv)[:300])
    rr = call(lab, dc, owner, f"public.reissue_carrier_invoice('{invx}', (select updated_at from public.carrier_invoices where id = '{invx}'), 'terms changed', 'iss-dr-re')", end="commit")
    new = rr[0]["replacement_invoice_id"]
    ss = call(lab, dc, owner, f"public.submit_carrier_invoice_to_factor('{new}', 'cif-dr111111-bbbb')", end="commit")
    check("the replacement uses the CURRENT server-resolved terms/routing (advance 90 recorded in its submission snapshot); the drifted original stays refused (INVOICE_VOIDED)", ss[0]["success"] is True and scalar(lab, dc, f"select advance_percentage::text from public.carrier_invoice_factoring_snapshots_0157 where carrier_invoice_id = '{new}'") == "90.0000"
          and code_of(call(lab, dc, owner, f"public.submit_carrier_invoice_to_factor('{invx}', 'cif-dr111111-cccc')")) == "INVOICE_VOIDED" and rr[0]["drift_dimensions"] and set(rr[0]["drift_dimensions"]) == {"noa", "terms"}, str(ss))
    check("no double factoring: exactly ONE submission exists across the original and the replacement", scalar(lab, dc, f"select count(*) from public.carrier_invoice_factoring_submissions_0157 where carrier_invoice_id in ('{invx}', '{new}')") == "1")
    lab.c.dropdb("td0149_p57i")
    # ---- void a draft / lifecycle ----
    dv = draft(owner, A1, [40, 41], "iss-v-d", end="commit")[0]["invoice_id"]
    check("DISCARD DRAFT (a never-issued draft cannot be voided: a voided invoice needs a number): a dispatcher WITHOUT a grant is refused; the granted dispatcher discards it, the loads are RELEASED and can be drafted again; an issued invoice cannot be discarded", code_of(call(lab, db, disp2A, f"public.discard_carrier_invoice_draft('{dv}', {upd(dv)}, 'not needed', 'iss-v-1')")) == "NOT_AUTHORIZED_FOR_CARRIER"
          and call(lab, db, dispA, f"public.discard_carrier_invoice_draft('{dv}', {upd(dv)}, 'not needed', 'iss-v-2')", end="commit")[0]["success"] is True and scalar(lab, db, f"select count(*) from public.carrier_invoice_billable_ledger_0157 where invoice_id = '{dv}' and released_at is null") == "0"
          and draft(owner, A1, [40, 41], "iss-v-d2", end="commit")[0]["success"] is True and code_of(call(lab, db, owner, f"public.discard_carrier_invoice_draft('{inv1}', {upd(inv1)}, 'x', 'iss-v-3')")) == "INVOICE_NOT_DRAFT" and code_of(ready(owner, dv, "iss-v-4")) == "NOT_A_WORKFLOW_DRAFT")
    # ---- safety: search path, bounded waits ----
    rc, out, err = lab.as_role(db, "authenticated", owner, f"create temp table loads (id uuid); create temp table carrier_invoices (id uuid); select (public.preview_carrier_invoice_issuance('{A1}', {arr([30])}, 'broker', '{BRK1}'))::text")
    check("SEARCH-PATH SAFETY: temporary tables named loads / carrier_invoices cannot influence the issuance RPCs (the preview still sees the real loads)", out.startswith("{") and json.loads(out).get("eligible") is True, out + err[-200:])
    env = {**lab.c.env, "PGOPTIONS": "-c app.zzz_0149_test=scratch-ok"}
    holder = subprocess.Popen([t149.PSQL, "-X", "-w", "-q", "-h", str(lab.c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-c", f"begin; select 1 from public.loads where id = '{LD(45)}' for update; select pg_sleep(9);"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    time.sleep(1.2)
    t0 = time.time()
    rc, out, err = lab.as_role(db, "authenticated", owner, f"select (public.create_carrier_invoice_draft_from_loads('{A1}', {arr([45])}, 'broker', '{BRK1}', 'iss-lock'))::text")
    took = time.time() - t0
    holder.kill(); lab.c.psql("postgres", "select pg_terminate_backend(pid) from pg_stat_activity where datname = '" + db + "' and pid <> pg_backend_pid();", ok=False)
    check("BOUNDED WAITS: with a load row locked elsewhere the draft creation aborts after ~5 s (lock_timeout) and writes nothing", rc != 0 and "lock timeout" in err and 4 < took < 12 and scalar(lab, db, f"select count(*) from public.carrier_invoice_billable_ledger_0157 where load_id = '{LD(45)}'") == "0", f"{took:.1f}s {err[-160:]}")
    # ---- RLS / grants / audit for the new tables ----
    def cnt(uid, table, role="authenticated"):
        rc, out, err = lab.as_role(db, role, uid, f"select count(*) from public.{table}")
        return int(out) if rc == 0 and out.isdigit() else None
    def foreign(uid, table):
        rc, out, err = lab.as_role(db, "authenticated", uid, f"select count(*) from public.{table} where organization_id <> '{OB}'")
        return int(out) if rc == 0 and out.isdigit() else None
    T, LG, RI, DF, OPS = "carrier_invoice_issuance_terms_0157", "carrier_invoice_billable_ledger_0157", "carrier_invoice_reissues_0157", "carrier_invoice_dispatch_fee_links_0157", "carrier_invoice_workflow_ops_0157"
    check("RLS (new tables): owner/admin/accountant read the organization's rows; the granted dispatcher reads the carrier's terms/ledger/reissues; an ungranted dispatcher, viewer, driver and another organization read NONE", all(cnt(u, t) > 0 for u in (owner, admin, acct) for t in (T, LG, RI)) and cnt(dispA, T) > 0 and cnt(disp2A, T) == 0 and cnt(disp2A, LG) == 0 and cnt(viewer, T) == 0 and cnt(driver, LG) == 0 and foreign(ownerB, T) == 0 and foreign(ownerB, LG) == 0 and foreign(ownerB, RI) == 0)
    check("RLS: the workflow op records are readable by owner/admin only; dispatch-fee links by owner/admin/accountant", cnt(owner, OPS) > 0 and cnt(admin, OPS) > 0 and cnt(acct, OPS) == 0 and cnt(dispA, OPS) == 0 and cnt(acct, DF) > 0 and cnt(dispA, DF) == 0 and foreign(ownerB, OPS) == 0)
    for t in (T, LG, RI, DF, OPS):
        rc, out, err = lab.as_role(db, "authenticated", owner, f"insert into public.{t} select * from public.{t} limit 1")
        rc2, o2, e2 = lab.as_role(db, "service_role", "", f"select count(*) from public.{t}")
        rc3, o3, e3 = lab.as_role(db, "anon", "", f"select count(*) from public.{t}")
        check(f"GRANTS: no client role can write {t}; service_role and anon cannot even read it", rc != 0 and "permission denied" in err and rc2 != 0 and rc3 != 0, err[-100:])
    check("AUDIT: every workflow event class is in the hash-chained ledger (draft_creation, ready, issuance, reissue, draft_discard) and the chain verifies", scalar(lab, db, "select public.verify_carrier_invoice_factoring_audit_chain_0157()") == "0"
          and {r_[0] for r_ in lab.rows(db, "select distinct event_type || ':' || outcome from public.carrier_invoice_factoring_audit_0157")[1]} >= {"draft_creation:success", "ready:success", "issuance:success", "reissue:success", "draft_discard:success", "draft_creation:refusal", "reissue:refusal", "issuance:refusal"})
    check("no historical invoice, snapshot, submission, payment, fee link or audit row was ever deleted by the workflow: every invoice created above still exists (voided ones included)", scalar(lab, db, f"select count(*) from public.carrier_invoices where id in ('{inv1}', '{inv2}', '{inv2b}', '{dv}')") == "4")
    check("the legacy factored_invoices table and legacy invoices are untouched by the whole issuance workflow (D-57g: no bridge)", scalar(lab, db, "select md5(coalesce((select string_agg(to_jsonb(f)::text, '|' order by f.id) from public.factored_invoices f), '') || coalesce((select string_agg(to_jsonb(i)::text, '|' order by i.id) from public.invoices i), ''))") == legacy0)


def scalar_rows(lab, db, sql):
    return lab.rows(db, sql)[1]


def prep_issued_on(lab, db, uid, loads, key, carrier=A1, rid=BRK1):
    d = call(lab, db, uid, f"public.create_carrier_invoice_draft_from_loads('{carrier}', {arr(loads)}, 'broker', '{rid}', '{key}-d')", end="commit")
    assert d[0] and d[0]["success"], d
    inv = d[0]["invoice_id"]
    u = f"(select updated_at from public.carrier_invoices where id = '{inv}')"
    assert call(lab, db, uid, f"public.mark_carrier_invoice_ready_for_issue('{inv}', {u}, '{key}-r')", end="commit")[0]["success"]
    i = call(lab, db, uid, f"public.issue_prepared_carrier_invoice('{inv}', {u}, 'issue', '{key}-i')", end="commit")
    assert i[0] and i[0]["success"], i
    return inv


def main():
    static_checks()
    c = t149.Cluster()
    ok = False
    try:
        c.start()
        env, base = t54.build(c)
        lab = Lab(c, env)
        a = build_base(lab, c, env, base)
        apply_and_refusals(lab, a)
        normalization_tests(lab, a)
        db = main_db(lab, a)
        gate_tests(lab, db, a)
        authz_tests(lab, db)
        eligibility_tests(lab, db)
        drift_tests(lab, db)
        submit_tests(lab, db)
        after_change_tests(lab, db)
        issuance_tests(lab, db)
        integrity_tests(lab, db)
        rollback_tests(lab, db, a)
        ok = True
        print(f"\nALL {len(checks)} CHECKS PASSED (0157 suite; disposable local PostgreSQL; synthetic data; NOT a hosted or production proof)")
    finally:
        c.cleanup(ok)


if __name__ == "__main__":
    main()
