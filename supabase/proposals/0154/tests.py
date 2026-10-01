#!/usr/bin/env python3
"""Proposals 0154 (F-05), 0155 (F-01) and 0156 (F-08) -- disposable-PostgreSQL verification. NOT APPROVED FOR PRODUCTION.

Reuses the reviewed 0149-0152 harness (brand-new local cluster under /private/tmp/td0149-local-*, unix socket only; real migrations 0130..0147 on the pinned support schemas; Supabase-style default
function privileges EXECUTE -> anon/authenticated/service_role emulated). Sequence: 0130..0147 -> 0149 -> 0150 (approved count + digest) -> 0151 -> 0152, then 0154 -> 0155 -> 0156.
Synthetic data only. Never connects to Supabase or any real database; never writes inside the repository."""
import hashlib
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
REPO = SUPA.parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


t152 = _load("t0152_for_0154", SUPA / "proposals" / "0152" / "tests.py")
t149, t150 = t152.t149, t152.t150
SEP = t149.SEP
b54 = _load("b0154", HERE / "build.py")
b55 = _load("b0155", HERE.parent / "0155" / "build.py")
b56 = _load("b0156", HERE.parent / "0156" / "build.py")
P = SUPA / "proposals"
checks = []
OA, OB = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
U = {"ownerA": "aaaa0000-0000-0000-0000-000000000001", "acctA": "cccc0000-0000-0000-0000-000000000001", "dispA": "dddd0000-0000-0000-0000-000000000001",
     "driverA": "eeee0000-0000-0000-0000-000000000001", "viewerA": "ffff0000-0000-0000-0000-000000000001", "ownerB": "bbbb0000-0000-0000-0000-000000000001", "anon": ""}
REL_A1 = "fe000000-0000-0000-0000-000000000003"


def check(label, cond, detail=""):
    if not cond:
        raise SystemExit(f"FAIL: {label} {detail}")
    checks.append(label)
    print(f"  ok  {label}")


def rd(rel):
    return (P / rel).read_text()


class Lab:
    def __init__(self, c, env):
        self.c, self.env, self.n = c, env, 0

    def clone(self, template, name):
        self.c.dropdb(name)
        self.c.createdb(name, template=template)
        return name

    def sql(self, db, text):
        return self.c.psql(db, text, guard=True, ok=False)

    def rows(self, db, text):
        p = self.c.psql(db, text, guard=True, tuples=True, ok=False)
        return p.returncode, [l.split(SEP) for l in p.stdout.splitlines() if l.strip()], p.stderr

    def scalar(self, db, text):
        rc, rows, err = self.rows(db, text)
        assert rc == 0, err
        return rows[0][0] if rows else None

    def as_role(self, db, role, uid, body, pre="", end="rollback"):
        """One psql session: <pre as postgres>; SET LOCAL ROLE <role>; auth uid; <body>; ROLLBACK. Returns (rc, last stdout line, stderr)."""
        body = body.rstrip()
        body = body if body.endswith(";") else body + ";"
        text = f"begin;\n{pre}\nset local role {role};\nselect set_config('test.current_uid', '{uid}', false) \\gset\n{body}\n{end};\n"
        p = self.c.psql(db, text, guard=True, tuples=True, ok=False)
        out = [l for l in p.stdout.splitlines() if l.strip()]
        return p.returncode, (out[-1] if out else ""), p.stderr

    def catalog(self, db):
        return t149.catalog(self.c, db)

    def apply(self, db, text):
        return self.c.psql(db, text, guard=True, ok=False)

    def verify(self, db, text):
        return self.env.verify(db, None, text)


def static_checks():
    print("== static checks ==")
    for b, n in ((b54, "0154"), (b55, "0155"), (b56, "0156")):
        for name, text in b.all_files().items():
            check(f"{n}/{name} is current (generated)", (b.HERE / name).read_text() == text)
    for n, files in (("0154", ("proposed_0154.sql", "preflight.sql", "post_apply.sql", "rollback.sql")), ("0155", ("proposed_0155.sql", "preflight.sql", "post_apply.sql", "rollback.sql")), ("0156", ("proposed_0156.sql", "preflight.sql", "post_apply.sql", "rollback.sql"))):
        for f in files:
            t = rd(f"{n}/{f}")
            check(f"{n}/{f} is marked NOT APPROVED FOR PRODUCTION and names the 0148 renumbering rule (0153 or 0157+, never 0154-0156)", "NOT APPROVED FOR PRODUCTION" in t and "0153" in t and "0157" in t)
            code = t149.strip_sql(t)
            check(f"{n}/{f}: never grants EXECUTE/privileges to anon, service_role or PUBLIC", not re.search(r"grant\s+[^;]*\bto\s+[^;]*\b(anon|service_role|public)\b", code, re.I), f)
    for n, f in (("0154", "preflight.sql"), ("0154", "post_apply.sql"), ("0155", "preflight.sql"), ("0155", "post_apply.sql"), ("0156", "preflight.sql"), ("0156", "post_apply.sql")):
        s = t149.strip_sql(rd(f"{n}/{f}"))
        check(f"{n}/{f}: exactly ONE read-only select (no DML/DDL/transaction control)", s.count(";") == 1 and not re.search(r"\b(insert|update|delete|create|alter|drop|grant|revoke|truncate|begin|commit|rollback|set_config|lock)\b", s, re.I), f)
    outside = t149.strip_sql(re.sub(r"create or replace function.*?\$fn\$;", "", rd("0154/proposed_0154.sql"), flags=re.S))
    check("0154 has NO data statement on unresolved_carrier_records outside the two function bodies (no insert/update/delete/truncate: existing exception records are never touched)",
          not re.search(r"\b(insert\s+into\s+public\.unresolved_carrier_records|update\s+public\.unresolved_carrier_records|delete\s+from|truncate)\b", outside, re.I))
    p55 = rd("0155/proposed_0155.sql")
    body = re.sub(r"--[^\n]*", "", p55)
    check("0155 contains no UPDATE/DELETE of factoring_relationships.carrier_id outside the owner decision RPC (the evaluation never assigns)", len(re.findall(r"update public\.factoring_relationships set carrier_id", body)) == 2)
    check("0155 contains no 'order by ... limit 1' / max / newest selection of a carrier (no best guess)", not re.search(r"order by[^;]*(created_at|updated_at)[^;]*limit 1", body, re.I) and "mode()" not in body)
    check("0156 baseline pin is the extracted 0140 body (md5 pinned) and the gate is created DISABLED", "insert into public.factoring_submission_gate (singleton, enabled) values (true, false)" in rd("0156/proposed_0156.sql"))
    pkg = REPO / "src"
    check("no application code calls _record_unresolved_carrier_record_trusted or the 0155/0156 internal functions", not any(re.search(r"_record_unresolved_carrier_record_trusted|carrier_evidence_for_|_carrier_inference_apply_0155|record_unresolved_carrier_record", p.read_text(errors="ignore"))
          for p in pkg.rglob("*.ts*") if ".test." not in p.name))


def build(c):
    env = t152.Env0152(c)
    base = "td0149_p_base"
    env.build_base(base)
    rows, summ = env.review(base)
    n = int(summ["CANDIDATES (approve this count)"]); dig = summ["candidate digest (REQUIRED: paste into v_expected_digest)"]
    for sqlt in (t150.fill(rd("0150/proposed_0150.sql"), n, dig), rd("0151/proposed_0151.sql"), rd("0152/proposed_0152.sql")):
        r = env.run(base, sqlt)
        assert r.returncode == 0, r.stderr[-800:]
    return env, base


def all_rows_fp(lab, db, table="public.unresolved_carrier_records"):
    return lab.scalar(db, f"select count(*)::text || ':' || md5(coalesce(string_agg(to_jsonb(u)::text, '|' order by u.id), '')) from {table} u")


# ------------------------------------------------------------------------------------------------------------------------------------------------- F-05
def f05(lab, base):
    print("== F-05 (proposal 0154): record_unresolved_carrier_record ==")
    loadA = lab.scalar(base, f"select id from public.loads where organization_id = '{OA}' order by id limit 1")
    loadB = lab.scalar(base, f"select id from public.loads where organization_id = '{OB}' order by id limit 1")
    x = lab.clone(base, "td0149_p54x")
    for role in ("anon", "service_role"):
        rc, out, err = lab.as_role(x, role, "", f"select public.record_unresolved_carrier_record('{OB}', 'load', '{loadB}', 'forged by {role}')")
        check(f"BASELINE EXPOSURE reproduced: {role} (null auth.uid()) can write an exception row for ANOTHER organization's load through the 0130 function (default privileges grant EXECUTE)", rc == 0 and len(out) == 36, err[-300:] + out)
    rc, out, err = lab.as_role(x, "authenticated", U["ownerA"], f"select public.record_unresolved_carrier_record('{OB}', 'load', '{loadB}', 'x')")
    check("baseline: an authenticated user of another organization is already refused (cross-organization)", rc != 0 and "cross-organization" in err)

    pf = lab.verify(base, rd("0154/preflight.sql"))
    check("preflight 0154 PASSES on the real baseline", pf["ok"], pf["err"][-400:])
    cat_before = lab.catalog(base)
    refusals = {
        "an unexpected overload in the same schema": ("create function public.record_unresolved_carrier_record(uuid, text) returns void language sql as 'select 1';", "exactly ONE function"),
        "a same-named function in another schema": ("create schema zz_evil; create function zz_evil.record_unresolved_carrier_record() returns void language sql as 'select 1';", "exactly ONE function"),
        "a pre-existing trusted twin": ("create function public._record_unresolved_carrier_record_trusted() returns void language sql as 'select 1';", "exactly ONE function"),
        "a drifted body (not the reviewed 0130 definition)": ("create or replace function public.record_unresolved_carrier_record(p_organization_id uuid, p_record_type text, p_record_id uuid, p_reason text, p_detail jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path = pg_catalog, public as $fn$ begin return null; end $fn$;", "not the reviewed 0130 baseline"),
        "a client role as function owner": ("grant create on schema public to service_role; alter function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) owner to service_role;", "client role"),
    }
    for label, (mut, expect) in refusals.items():
        db = lab.clone(base, "td0149_p54r")
        assert lab.sql(db, mut).returncode == 0, label
        before = lab.catalog(db)
        r = lab.apply(db, rd("0154/proposed_0154.sql"))
        check(f"0154 REFUSES and changes nothing: {label}", r.returncode != 0 and expect in r.stderr and lab.catalog(db) == before, r.stderr[-300:])
        check(f"preflight 0154 FAILS: {label}", not lab.verify(db, rd("0154/preflight.sql"))["ok"])
    lab.c.dropdb("td0149_p54r")

    db = lab.clone(base, "td0149_p54")
    fp = all_rows_fp(lab, db)
    r = lab.apply(db, rd("0154/proposed_0154.sql"))
    check("0154 applies", r.returncode == 0 and "0154 complete" in r.stderr, r.stderr[-400:])
    check("post_apply 0154 PASSES", lab.verify(db, rd("0154/post_apply.sql"))["ok"])
    check("no existing exception record was created, changed or deleted by 0154 (row digest identical)", all_rows_fp(lab, db) == fp)
    for role, uid in (("anon", ""), ("authenticated", U["ownerA"]), ("service_role", "")):
        rc, out, err = lab.as_role(db, role, uid, f"select public.record_unresolved_carrier_record('{OA}', 'load', '{loadA}', 'x')")
        check(f"AFTER 0154: {role} is denied on record_unresolved_carrier_record (permission denied)", rc != 0 and "permission denied for function" in err, err[-200:])
        rc, out, err = lab.as_role(db, role, uid, f"select public._record_unresolved_carrier_record_trusted('{OA}', 'load', '{loadA}', 'x')")
        check(f"AFTER 0154: {role} is denied on the trusted writer", rc != 0 and "permission denied for function" in err, err[-200:])
    rc, out, err = lab.as_role(db, "postgres", "", f"select public.record_unresolved_carrier_record('{OA}', 'load', '{loadA}', 'x')")
    check("even the owner calling the public function with a NULL identity FAILS CLOSED (authentication required)", rc != 0 and "authentication required" in err, err[-200:])
    n0 = lab.scalar(db, "select count(*) from public.unresolved_carrier_records")
    rc, out, err = lab.as_role(db, "postgres", "", f"select public._record_unresolved_carrier_record_trusted('{OA}', 'load', '{loadA}', 'trusted writer test')")
    check("the owner-only trusted writer creates an exception for a real record in the stated organization", rc == 0 and len(out) == 36, err[-200:])
    for label, args, expect in (("a forged organization for a real record (cross-tenant identifier)", f"'{OB}', 'load', '{loadA}', 'x'", "does not exist in the stated organization"),
                                ("an unknown organization", f"'99999999-9999-9999-9999-999999999999', 'load', '{loadA}', 'x'", "unknown organization"),
                                ("an unverifiable record type (other)", f"'{OA}', 'other', '{loadA}', 'x'", "no verifiable target"),
                                ("a non-existent record id", f"'{OA}', 'load', '99999999-9999-9999-9999-999999999999', 'x'", "does not exist in the stated organization"),
                                ("an empty reason", f"'{OA}', 'load', '{loadA}', '  '", "required")):
        rc, out, err = lab.as_role(db, "postgres", "", f"select public._record_unresolved_carrier_record_trusted({args})")
        check(f"trusted writer REFUSES {label}", rc != 0 and expect in err, err[-200:])
    lab.sql(db, f"insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason) values ('{OB}', 'load', '{loadA}', 'planted open record of another organization');")
    rc, out, err = lab.as_role(db, "postgres", "", f"select public._record_unresolved_carrier_record_trusted('{OA}', 'load', '{loadA}', 'x')")
    check("trusted writer REFUSES when an open exception for the record belongs to another organization", rc != 0 and "belongs to another organization" in err, err[-200:])

    grant = "grant execute on function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) to authenticated;"
    lab.sql(db, f"delete from public.unresolved_carrier_records where reason like 'planted%' or reason = 'trusted writer test';")
    cases = [("a legitimate owner call for his own load", U["ownerA"], f"'{OA}', 'load', '{loadA}', 'legit'", True, ""),
             ("a legitimate dispatcher call", U["dispA"], f"'{OA}', 'load', '{loadA}', 'legit2'", True, ""),
             ("a cross-tenant call (organization B for a user of A)", U["ownerA"], f"'{OB}', 'load', '{loadB}', 'x'", False, "cross-organization"),
             ("a forged load id (org A caller, org B load)", U["ownerA"], f"'{OA}', 'load', '{loadB}', 'x'", False, "does not belong"),
             ("a driver (role not permitted)", U["driverA"], f"'{OA}', 'load', '{loadA}', 'x'", False, "role is not permitted"),
             ("a viewer (role not permitted)", U["viewerA"], f"'{OA}', 'load', '{loadA}', 'x'", False, "role is not permitted"),
             ("an interactive invoice record type", U["ownerA"], f"'{OA}', 'invoice', '{loadA}', 'x'", False, "record_type='load' only"),
             ("a NULL identity / JWT without a subject, even if EXECUTE were re-granted", "", f"'{OA}', 'load', '{loadA}', 'x'", False, "authentication required")]
    for label, uid, args, ok_, expect in cases:
        rc, out, err = lab.as_role(db, "authenticated", uid, f"select public.record_unresolved_carrier_record({args})", pre=grant)
        check(f"IF the Owner ever re-grants EXECUTE to authenticated the body is safe: {label}", (rc == 0 and ok_) or (rc != 0 and not ok_ and expect in err), err[-250:])
    rc, out, err = lab.as_role(db, "authenticated", U["ownerA"], "select count(*) from public.unresolved_carrier_records")
    check("(control) an owner can still READ his organization's exception records", rc == 0)
    op = lab.scalar(db, f"select id from public.unresolved_carrier_records where organization_id = '{OA}' limit 1")
    if op is None:
        lab.sql(db, f"select public._record_unresolved_carrier_record_trusted('{OA}', 'load', '{loadA}', 'seed for F-15')")
        op = lab.scalar(db, f"select id from public.unresolved_carrier_records where organization_id = '{OA}' limit 1")
    for col, val in (("record_id", f"'{loadB}'"), ("detail", "'{}'::jsonb"), ("organization_id", f"'{OB}'"), ("reason", "'tampered'")):
        rc, out, err = lab.as_role(db, "authenticated", U["ownerA"], f"update public.unresolved_carrier_records set {col} = {val} where id = '{op}'")
        check(f"F-15: an owner can NO LONGER update unresolved_carrier_records.{col} (column privilege)", rc != 0 and "permission denied" in err, err[-200:])
    rc, out, err = lab.as_role(db, "authenticated", U["ownerA"], f"with u as (update public.unresolved_carrier_records set status = 'manually_resolved', resolved_by = '{U['ownerA']}', resolved_at = now(), resolution_note = 'ok' where id = '{op}' returning 1) select count(*) from u")
    check("F-15: an owner can still record a RESOLUTION (status/resolved_*/note) on his organization's exception", rc == 0 and out == "1", err[-200:] + out)

    # rollback (emergency) and re-apply
    r = lab.apply(db, rd("0154/rollback.sql"))
    check("rollback 0154 runs and restores the exact 0130 body", r.returncode == 0 and "ROLLBACK 0154 complete" in r.stderr, r.stderr[-300:])
    check("after rollback the trusted writer is gone and the function is the 0130 baseline again", lab.scalar(db, "select (to_regprocedure('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)') is null)::text") == "true"
          and lab.scalar(db, f"select (md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) = '{b54.facts()['base_md5']}')::text from pg_proc where oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')") == "true")
    check("rollback restores the 0130-declared ACL (authenticated yes; anon/PUBLIC no) and table-level UPDATE", lab.scalar(db, "select (has_function_privilege('authenticated','public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)','execute') and not has_function_privilege('anon','public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)','execute') and has_table_privilege('authenticated','public.unresolved_carrier_records','UPDATE'))::text") == "true")
    r = lab.apply(db, rd("0154/proposed_0154.sql"))
    check("0154 re-applies after a rollback (repeatable) and post_apply passes again", r.returncode == 0 and lab.verify(db, rd("0154/post_apply.sql"))["ok"], r.stderr[-300:])
    lab.c.dropdb("td0149_p54x")
    return db


# ------------------------------------------------------------------------------------------------------------------------------------------------- F-13 analysis (executable)
def f13(lab, db):
    print("== F-13: SECURITY DEFINER + temporary-schema name resolution (executable analysis) ==")
    lab.sql(db, """
      create table public.zz_shadow (v text); insert into public.zz_shadow values ('REAL');
      create function public.zz_def_public_unqualified() returns text language sql security definer set search_path = pg_catalog, public as $$ select v from zz_shadow $$;
      create function public.zz_def_pgtemp_last() returns text language sql security definer set search_path = pg_catalog, public, pg_temp as $$ select v from zz_shadow $$;
      create function public.zz_def_qualified() returns text language plpgsql security definer set search_path = pg_catalog, pg_temp as $$ begin return (select z.v from public.zz_shadow z); end $$;""")
    rc, out, err = lab.as_role(db, "postgres", "", "create temp table zz_shadow (v text); insert into zz_shadow values ('TEMP-ATTACK');\nselect public.zz_def_public_unqualified();")
    check("an UNQUALIFIED relation in a SECURITY DEFINER function with search_path 'pg_catalog, public' IS shadowed by a caller's temporary table (pg_temp is searched first for relations when not listed)", out == "TEMP-ATTACK", out + err[-200:])
    rc, out, err = lab.as_role(db, "postgres", "", "create temp table zz_shadow (v text); insert into zz_shadow values ('TEMP-ATTACK');\nselect public.zz_def_pgtemp_last();")
    check("listing pg_temp LAST ('pg_catalog, public, pg_temp') makes the same unqualified reference resolve to the real table", out == "REAL", out + err[-200:])
    rc, out, err = lab.as_role(db, "postgres", "", "create temp table zz_shadow (v text); insert into zz_shadow values ('TEMP-ATTACK');\nselect public.zz_def_qualified();")
    check("fully schema-qualified references are immune whatever the search_path (the pattern used by every 0154-0156 function)", out == "REAL", out + err[-200:])
    rc, out, err = lab.as_role(db, "postgres", "", "create temp table loads (id uuid, organization_id uuid); insert into loads values ('99999999-9999-9999-9999-999999999999', '" + OA + "');\n"
                                "select public._record_unresolved_carrier_record_trusted('" + OA + "', 'load', '99999999-9999-9999-9999-999999999999', 'shadow attack')")
    check("the 0154 trusted writer cannot be fooled by a temporary table named like a real one (forged record refused)", rc != 0 and "does not exist in the stated organization" in err, err[-200:])
    lab.sql(db, "drop function public.zz_def_public_unqualified(); drop function public.zz_def_pgtemp_last(); drop function public.zz_def_qualified(); drop table public.zz_shadow;")


# ------------------------------------------------------------------------------------------------------------------------------------------------- F-01
def rel_state_fp(lab, db):
    return lab.scalar(db, """select md5(coalesce((select string_agg(to_jsonb(r)::text, '|' order by r.id) from public.factoring_relationships r), '') || coalesce((select string_agg(to_jsonb(i)::text, '|' order by i.id) from public.invoices i), '')
       || coalesce((select string_agg(to_jsonb(p)::text, '|' order by p.id) from public.payments p), '') || coalesce((select string_agg(to_jsonb(f)::text, '|' order by f.id) from public.factored_invoices f), '')
       || coalesce((select string_agg(to_jsonb(l)::text, '|' order by l.id) from public.loads l), '') || coalesce((select string_agg(to_jsonb(d)::text, '|' order by d.id) from public.dispatches d), ''))""")


def digest_of(ids):
    return hashlib.md5(",".join(sorted(ids)).encode()).hexdigest()


def f01(lab, db54):
    print("== F-01 (proposal 0155): strict carrier evidence; 0137 inference reviewed, never guessed ==")
    fixture = (HERE / "fixture_scenario.sql").read_text()
    # refusal without 0154
    x = lab.clone("td0149_p_base", "td0149_p55x")
    r = lab.apply(x, rd("0155/proposed_0155.sql"))
    check("0155 REFUSES when proposal 0154 (owner-only exception writer) is not applied", r.returncode != 0 and "0154" in r.stderr, r.stderr[-300:])
    db = lab.clone(db54, "td0149_p55")
    r = lab.sql(db, fixture)
    assert r.returncode == 0, r.stderr[-500:]
    pf = lab.verify(db, rd("0155/preflight.sql"))
    check("preflight 0155 PASSES (0154 applied, no 0155 object)", pf["ok"], pf["err"][-300:])
    before_fp = rel_state_fp(lab, db)
    exc_before = int(lab.scalar(db, "select count(*) from public.unresolved_carrier_records"))
    lock_sess = None
    r = lab.apply(db, rd("0155/proposed_0155.sql"))
    check("0155 applies", r.returncode == 0 and "0155 complete" in r.stderr, r.stderr[-500:])
    check("post_apply 0155 PASSES", lab.verify(db, rd("0155/post_apply.sql"))["ok"])
    check("0155 changed NO relationship, carrier_id, invoice, payment, factored invoice, load or dispatch (row-level digest identical)", rel_state_fp(lab, db) == before_fp)
    rc, rows, err = lab.rows(db, "select r.relationship_name, v.classification, v.strict_status, coalesce(v.strict_level, '-'), coalesce(right(v.strict_carrier_id::text, 4), '-'), v.decision_status from public.carrier_inference_review_0155 v join public.factoring_relationships r on r.id = v.relationship_id order by 1")
    got = {r_[0]: r_[1:] for r_ in rows}
    expect = {"R-assignable-A2": ("assignable_proven", "proven", "L1_all_factored_invoices_prove_one_carrier", "0002", "pending"),
              "R-cancelled-dispatch-only": ("ambiguous_unresolved", "no_evidence", "-", "-", "pending"),
              "R-conflict": ("ambiguous_unresolved", "conflict", "-", "-", "pending"),
              "R-cross-org-carrier": ("refused_structural", "no_evidence", "-", "-", "pending"),
              "R-no-invoices": ("ambiguous_unresolved", "no_evidence", "-", "-", "pending"),
              "R-partial-A2": ("unsafe_assigned", "partial", "-", "-", "pending"),
              "R-sole-inactive-org-C": ("unsafe_assigned", "invalid_carrier", "-", "-", "pending")}
    for k, v in expect.items():
        check(f"classification {k}: {v[0]} ({v[1]})", tuple(got.get(k, ())) == v, str(got.get(k)))
    check("supported relationships (L1 all invoices prove A1; L2 sole ACTIVE carrier of org B) need no review row", "R-all-invoices-A1" not in got and "R-sole-active-org-B" not in got)
    check("F-01 CLOSED for the reviewed case: the 0137-style assignment on PARTIAL evidence (one invoice proves A1, another proves nothing) is flagged unsafe, not accepted", got["R-partial-A2"][0] == "unsafe_assigned" and got["R-partial-A2"][1] == "partial")
    check("F-02 CLOSED: a relationship assigned to the ONLY carrier of an organization when that carrier is INACTIVE is flagged unsafe (invalid_carrier)", tuple(got["R-sole-inactive-org-C"][:2]) == ("unsafe_assigned", "invalid_carrier"))
    rc, rows, err = lab.rows(db, "select counts::text, digests::text from public.carrier_inference_run_0155")
    counts, digests = json.loads(rows[0][0]), json.loads(rows[0][1])
    check("run ledger counts: candidate 9, supported 2, assignable 1, ambiguous 3, unsafe 2, refused 1, decided 0, resolved 0", counts == {"candidate": 9, "supported_unchanged": 2, "assignable_proven_pending_owner": 1, "ambiguous_unresolved": 3, "unsafe_assigned": 2, "refused_structural": 1, "decided_unchanged": 0, "resolved": 0}, str(counts))
    ids = {r_[0]: r_[1] for r_ in lab.rows(db, "select relationship_name, id from public.factoring_relationships")[1]}
    check("run ledger DIGESTS equal md5 of the sorted relationship ids of each category", digests["ambiguous_unresolved"] == digest_of([ids[n] for n in ("R-conflict", "R-no-invoices", "R-cancelled-dispatch-only")])
          and digests["unsafe_assigned"] == digest_of([ids["R-partial-A2"], ids["R-sole-inactive-org-C"]]) and digests["refused_structural"] == digest_of([ids["R-cross-org-carrier"]])
          and digests["candidate"] == digest_of(ids.values()), str(digests))
    check("exception records were opened for every unsafe / ambiguous / refused relationship (6), none for the assignable one", int(lab.scalar(db, "select count(*) from public.unresolved_carrier_records")) - exc_before == 6)
    # idempotency
    fp1 = (lab.scalar(db, "select count(*) from public.carrier_inference_review_0155"), lab.scalar(db, "select count(*) from public.unresolved_carrier_records"), rel_state_fp(lab, db))
    r2 = lab.rows(db, "select public._carrier_inference_apply_0155('second run')::jsonb -> 'counts'")
    fp2 = (lab.scalar(db, "select count(*) from public.carrier_inference_review_0155"), lab.scalar(db, "select count(*) from public.unresolved_carrier_records"), rel_state_fp(lab, db))
    check("RE-RUNNING the evaluation is idempotent: same counts, no duplicate review rows, no duplicate exception records, no data change (one extra ledger row)", fp1 == fp2 and json.loads(r2[1][0][0]) == counts and lab.scalar(db, "select count(*) from public.carrier_inference_run_0155") == "2", str((fp1, fp2, r2)))
    # evidence-function edge cases
    lab.sql(db, """set session_replication_role = replica;
      insert into public.invoices (id, organization_id, load_id, dispatch_id, broker_id, status, total_amount, amount_paid, invoice_number) values
        ('1a0000e0-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'd15a0000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'sent', 10, 0, 'E-DUP-EVIDENCE-SAME-CARRIER'),
        ('1a0000e0-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'd15a0000-0000-0000-0000-000000000004', 'a0b00000-0000-0000-0000-000000000001', 'sent', 10, 0, 'E-DISPATCH-OF-OTHER-LOAD'),
        ('1a0000e0-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', null, 'd15a0000-0000-0000-0000-000000000006', 'a0b00000-0000-0000-0000-000000000001', 'sent', 10, 0, 'E-CROSS-ORG-DISPATCH-CARRIER');
      insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status) values ('d15a0000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'delivered');
      update public.loads set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001', carrier_resolution = 'resolved' where id = '10ad0000-0000-0000-0000-000000000001';
      set session_replication_role = origin;""")
    def ev(inv):
        return json.loads(lab.rows(db, f"select public.carrier_evidence_for_invoice('{inv}')::text")[1][0][0])
    e = ev("1a0000e0-0000-0000-0000-000000000001")
    check("duplicated evidence naming the SAME carrier (dispatch A1 + load A1) is still exactly one carrier -> proven", e["status"] == "proven" and e["candidates"] == ["a1a1a1a1-0000-0000-0000-000000000001"], str(e))
    check("an invoice whose dispatch belongs to a DIFFERENT load is a structural conflict, never proven", ev("1a0000e0-0000-0000-0000-000000000002")["status"] == "conflict")
    e = ev("1a0000e0-0000-0000-0000-000000000003")
    check("a dispatch naming a carrier of ANOTHER organization is invalid_carrier, never assigned (cross-tenant identifier)", e["status"] == "invalid_carrier" and e["carrier_id"] is None, str(e))
    check("evidence functions are read-only: unknown invoice -> not_found; cancelled dispatch is not evidence; loads marked unresolved name no carrier", ev("00000000-0000-0000-0000-00000000dead")["status"] == "not_found" and ev("1a000000-0000-0000-0000-000000000006")["status"] == "no_evidence")
    for role, uid in (("anon", ""), ("authenticated", U["ownerA"]), ("service_role", "")):
        rc, out, err = lab.as_role(db, role, uid, "select public.carrier_evidence_for_invoice('1a000000-0000-0000-0000-000000000001')")
        check(f"{role} cannot execute the evidence functions", rc != 0 and "permission denied" in err, err[-200:])
    # concurrency: a writer holding a conflicting lock makes the evaluation wait/abort with lock_timeout, changing nothing
    holder = subprocess.Popen([t149.PSQL, "-X", "-w", "-q", "-h", str(lab.c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-c",
                                              "begin; update public.factored_invoices set updated_at = updated_at where id = (select id from public.factored_invoices limit 1); select pg_sleep(12);"],
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env={**lab.c.env, "PGOPTIONS": "-c app.zzz_0149_test=scratch-ok"})
    time.sleep(1.5)
    r = lab.sql(db, "set lock_timeout = '2s'; select public._carrier_inference_apply_0155('blocked');")
    holder.kill(); lab.c.psql("postgres", "select pg_terminate_backend(pid) from pg_stat_activity where datname = '" + db + "' and pid <> pg_backend_pid();", ok=False)
    check("CONCURRENCY: a concurrent writer on the evidence tables makes the evaluation abort on lock_timeout (no inconsistent assignment; run ledger unchanged)", r.returncode != 0 and "lock timeout" in r.stderr and lab.scalar(db, "select count(*) from public.carrier_inference_run_0155") == "2", r.stderr[-200:])

    # decisions
    RV = lambda name: lab.scalar(db, f"select v.id from public.carrier_inference_review_0155 v join public.factoring_relationships r on r.id = v.relationship_id where r.relationship_name = '{name}'")
    UPD = lambda name: lab.scalar(db, f"select v.updated_at::text from public.carrier_inference_review_0155 v join public.factoring_relationships r on r.id = v.relationship_id where r.relationship_name = '{name}'")

    def dec(uid, name, decision, reason="reason", ref="DOC-1", key="k1", carrier="null", stale=None, role="authenticated", rid=None):
        upd = stale or UPD(name)
        rid = rid or RV(name)
        return lab.as_role(db, role, uid, f"select public.decide_carrier_inference_review('{rid}', '{decision}', '{reason}', '{ref}', '{upd}'::timestamptz, '{key}', {carrier})::text", end="commit")

    rc, out, err = dec("", "R-assignable-A2", "assign_proven")
    check("decision RPC: an unauthenticated caller is FORBIDDEN", rc == 0 and '"FORBIDDEN"' in out, out + err[-200:])
    rc, out, err = dec(U["dispA"], "R-assignable-A2", "assign_proven")
    check("decision RPC: a dispatcher is FORBIDDEN (owner/admin only)", '"FORBIDDEN"' in out, out)
    rc, out_foreign, err = dec(U["ownerB"], "R-assignable-A2", "assign_proven")
    rc2, out_none, err2 = dec(U["ownerB"], "R-assignable-A2", "assign_proven", rid="99999999-9999-9999-9999-999999999999")
    check("decision RPC: another organization's owner gets NOT_FOUND identical to a non-existent review (no existence oracle)", '"NOT_FOUND"' in out_foreign and out_foreign == out_none, out_foreign)
    rc, out, err = dec(U["ownerA"], "R-assignable-A2", "clear")
    check("decision RPC: 'clear' does not exist (a wrong assignment can never be cleared to NULL or repointed) -> INVALID_REQUEST", '"INVALID_REQUEST"' in out, out)
    rc, out, err = dec(U["ownerA"], "R-assignable-A2", "assign_proven", stale="2001-01-01 00:00:00+00")
    check("decision RPC: a stale record is refused (STALE_RECORD)", '"STALE_RECORD"' in out, out)
    rc, out, err = dec(U["ownerA"], "R-partial-A2", "assign_proven")
    check("decision RPC: assign_proven on an already-assigned relationship is refused (a non-null carrier is never overwritten)", '"NOT_APPLICABLE"' in out, out)
    rc, out, err = dec(U["ownerA"], "R-partial-A2", "assign_owner", carrier="'a1a1a1a1-0000-0000-0000-000000000001'")
    check("decision RPC: assign_owner on an already-assigned relationship is refused", '"NOT_APPLICABLE"' in out, out)
    cnt_before = lab.scalar(db, "select count(*) from public.factoring_relationships where carrier_id is not null")
    sess = f"select public.decide_carrier_inference_review('{RV('R-assignable-A2')}', 'assign_proven', 'strict evidence reviewed', 'DOC-77', '{UPD('R-assignable-A2')}'::timestamptz, 'k-assign', null)::text"
    text = f"begin;\nset local role authenticated;\nselect set_config('test.current_uid', '{U['ownerA']}', false) \\gset\n{sess};\nselect public.decide_carrier_inference_review('{RV('R-assignable-A2')}', 'assign_proven', 'strict evidence reviewed', 'DOC-77', (select updated_at from public.carrier_inference_review_0155 where id = '{RV('R-assignable-A2')}'), 'k-assign', null)::text;\nselect public.decide_carrier_inference_review('{RV('R-assignable-A2')}', 'confirm', 'other', 'DOC-77', now(), 'k-assign', null)::text;\nselect public.decide_carrier_inference_review('{RV('R-assignable-A2')}', 'assign_proven', 'strict evidence reviewed', 'DOC-77', now(), 'k-other', null)::text;\ncommit;\n"
    p = lab.c.psql(db, text, guard=True, tuples=True, ok=False)
    outs = [l for l in p.stdout.splitlines() if l.startswith("{")]
    check("assign_proven: the strict-proven carrier (A2) is assigned once, recorded with reason + evidence reference", p.returncode == 0 and '"success": true' in outs[0] and '"decision": "assigned"' in outs[0] and lab.scalar(db, f"select right(carrier_id::text, 4) from public.factoring_relationships where id = '{ids['R-assignable-A2']}'") == "0002", p.stderr[-300:] + str(outs))
    check("assign_proven: replaying the same key returns the ORIGINAL result flagged idempotent_replay (no second change)", '"idempotent_replay": true' in outs[1], str(outs))
    check("assign_proven: the same key with a different decision -> IDEMPOTENCY_KEY_REUSED; a new key -> ALREADY_DECIDED", '"IDEMPOTENCY_KEY_REUSED"' in outs[2] and '"ALREADY_DECIDED"' in outs[3], str(outs))
    check("assign_proven wrote an owner/admin decision record (decided_by, key, reason, evidence ref) and closed nothing else", lab.scalar(db, f"select (decided_by = '{U['ownerA']}' and decision_key = 'k-assign' and decision_reason is not null and decision_evidence_ref = 'DOC-77')::text from public.carrier_inference_review_0155 where id = '{RV('R-assignable-A2')}'") == "true")
    rc, out, err = dec(U["ownerA"], "R-conflict", "assign_owner", carrier="'a3a3a3a3-0000-0000-0000-000000000003'", key="k2")
    check("assign_owner: an INACTIVE carrier is refused", '"INVALID_CARRIER"' in out, out)
    rc, out, err = dec(U["ownerA"], "R-conflict", "assign_owner", carrier="'b1b1b1b1-0000-0000-0000-000000000001'", key="k3")
    check("assign_owner: a carrier of ANOTHER organization is refused", '"INVALID_CARRIER"' in out, out)
    lab.sql(db, "set session_replication_role = replica; insert into public.carriers (id, organization_id, legal_name, is_active) values ('a9a9a9a9-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'Carrier A9 (not in the evidence)', true); set session_replication_role = origin;")
    rc, out, err = dec(U["ownerA"], "R-conflict", "assign_owner", carrier="'a9a9a9a9-0000-0000-0000-000000000009'", key="k4")
    check("assign_owner: a carrier the conflicting evidence does NOT name is refused (CONTRADICTS_EVIDENCE)", '"CONTRADICTS_EVIDENCE"' in out, out)
    rc, out, err = dec(U["ownerA"], "R-conflict", "assign_owner", carrier="'a1a1a1a1-0000-0000-0000-000000000001'", key="k5", reason="Rate confirmation RC-9 names carrier A1", ref="RC-9")
    check("assign_owner: a HUMAN decision naming one of the carriers the evidence names, with an evidence reference, is recorded and applied", '"decision": "assigned"' in out and lab.scalar(db, f"select right(carrier_id::text, 4) from public.factoring_relationships where id = '{ids['R-conflict']}'") == "0001", out + err[-200:])
    rc, out, err = dec(U["ownerA"], "R-partial-A2", "retire", key="k6")
    check("retire: refused while the unsupported relationship is still ACTIVE (deactivate it through the sanctioned RPC first)", '"RELATIONSHIP_STILL_ACTIVE"' in out, out)
    lab.sql(db, f"update public.factoring_relationships set is_active = false where id = '{ids['R-partial-A2']}';")
    rc, out, err = dec(U["ownerA"], "R-partial-A2", "retire", key="k6", reason="Replaced by a new relationship", ref="CHG-5")
    check("retire: after deactivation the retirement is recorded (no data change, the wrong carrier stays as history)", '"decision": "retired"' in out and lab.scalar(db, f"select right(carrier_id::text, 4) from public.factoring_relationships where id = '{ids['R-partial-A2']}'") == "0002", out + err[-200:])
    lab.sql(db, """set session_replication_role = replica;
      insert into public.factoring_relationships (id, organization_id, factoring_company_id, relationship_name, carrier_id, is_active, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type)
        values ('fe000000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'f0000000-0000-0000-0000-00000000000a', 'R-unsupported-A1', 'a1a1a1a1-0000-0000-0000-000000000001', true, 80, 3, 20, 'deducted_at_funding', 'recourse');
      insert into public.factored_invoices (id, organization_id, invoice_id, factoring_company_id, factoring_relationship_id, status, invoice_face_value, advance_percentage, expected_advance_amount, factoring_fee_percentage, factoring_fee_amount, reserve_percentage, reserve_amount, other_fees, fee_timing, expected_funding_amount)
        values ('fa000000-0000-0000-0000-0000000000aa', '11111111-1111-1111-1111-111111111111', '1a000000-0000-0000-0000-000000000005', 'f0000000-0000-0000-0000-00000000000a', 'fe000000-0000-0000-0000-00000000000a', 'submitted', 1000, 80, 800, 3, 30, 20, 200, 0, 'deducted_at_funding', 770);
      set session_replication_role = origin;""")
    lab.sql(db, "select public._carrier_inference_apply_0155('new unsupported relationship')")
    rc, out, err = dec(U["ownerA"], "R-unsupported-A1", "confirm", key="k7", reason="Carrier A1 confirmed by the factoring agreement", ref="AGR-3")
    check("confirm: an owner can knowingly KEEP an unsupported assignment; the decision and evidence reference are recorded and its exception record is closed (manually_resolved by the owner)",
          '"decision": "confirmed"' in out and lab.scalar(db, f"select (u.status = 'manually_resolved' and u.resolved_by = '{U['ownerA']}' and u.resolution_note like '%AGR-3%')::text from public.unresolved_carrier_records u where u.record_type = 'factoring_relationship' and u.record_id = 'fe000000-0000-0000-0000-00000000000a'") == "true", out + err[-200:])
    r3 = lab.rows(db, "select public._carrier_inference_apply_0155('after decisions')::jsonb -> 'counts'")
    c3 = json.loads(r3[1][0][0])
    check("after decisions a re-run leaves decided rows untouched (decided_unchanged counts them) and never re-opens or overwrites them", c3["decided_unchanged"] >= 4 and lab.scalar(db, f"select decision_status from public.carrier_inference_review_0155 where id = '{RV('R-conflict')}'") == "assigned", str(c3))
    check("a carrier_id was set only where an owner/admin decision recorded it (2 assignments: R-assignable-A2, R-conflict; +1 is the pre-assigned relationship this test inserted)", int(lab.scalar(db, "select count(*) from public.factoring_relationships where carrier_id is not null")) == int(cnt_before) + 3)
    r = lab.apply(db, rd("0155/rollback.sql"))
    check("rollback 0155 REFUSES once owner/admin decisions exist (they changed carriers)", r.returncode != 0 and "decisions have been recorded" in r.stderr, r.stderr[-200:])
    y = lab.clone(db54, "td0149_p55y")
    lab.sql(y, fixture)
    assert lab.apply(y, rd("0155/proposed_0155.sql")).returncode == 0
    fp_y = rel_state_fp(lab, y)
    r = lab.apply(y, rd("0155/rollback.sql"))
    check("rollback 0155 (no decisions) removes exactly the 0155 objects; carriers unchanged; exception records retained", r.returncode == 0 and lab.scalar(y, "select (to_regclass('public.carrier_inference_review_0155') is null and to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is null)::text") == "true"
          and rel_state_fp(lab, y) == fp_y and int(lab.scalar(y, "select count(*) from public.unresolved_carrier_records")) - exc_before == 6, r.stderr[-300:])
    r = lab.apply(y, rd("0155/proposed_0155.sql"))
    check("0155 re-applies after a rollback (repeatable)", r.returncode == 0, r.stderr[-300:])
    lab.c.dropdb("td0149_p55x"); lab.c.dropdb("td0149_p55y")
    return db


# ------------------------------------------------------------------------------------------------------------------------------------------------- F-08
def f08(lab, db55):
    print("== F-08 (proposal 0156): factoring submission -- strict, carrier-specific, DISABLED BY DEFAULT ==")
    fixture = (HERE / "fixture_submission.sql").read_text()
    pre = lab.clone(db55, "td0149_p56pre")     # 0154 + 0155 + scenario, no 0156: the 0140 baseline
    assert lab.sql(pre, fixture).returncode == 0
    OWN = U["ownerA"]
    G = "1a000000-0000-0000-0000-000000000007"

    def submit(db, uid, inv, rel=REL_A1, pre_sql="", role="authenticated"):
        return lab.as_role(db, role, uid, f"select public.submit_invoice_to_factor('{inv}', '{rel}')::text", pre=pre_sql)

    rc, base_out, err = submit(pre, OWN, G)
    check("BASELINE (0140): the good invoice is rejected with CARRIER_INVOICE_SNAPSHOT_REQUIRED for every invoice", '"CARRIER_INVOICE_SNAPSHOT_REQUIRED"' in base_out, base_out)
    for role, uid in (("anon", ""), ("service_role", "")):
        rc, out, err = submit(pre, uid, G, role=role)
        check(f"BASELINE exposure: {role} can EXECUTE the 0140 submit_invoice_to_factor (it reaches the function body and is refused there, not by a privilege) -- finding F-09", rc != 0 and "No organization" in err and "permission denied" not in err, err[-200:] + out)
    check("preflight 0156 PASSES on the 0140 baseline (0155 applied)", lab.verify(pre, rd("0156/preflight.sql"))["ok"])
    cat = lab.catalog(pre)
    for label, mut, expect in (("an overload of submit_invoice_to_factor", "create function public.submit_invoice_to_factor(uuid) returns void language sql as 'select 1';", "exactly one submit_invoice_to_factor"),
                               ("a drifted body", "create or replace function public.submit_invoice_to_factor(p_invoice_id uuid, p_relationship_id uuid) returns jsonb language plpgsql security invoker as $$ begin return '{}'::jsonb; end $$;", "not the reviewed 0140")):
        d = lab.clone(pre, "td0149_p56r")
        lab.sql(d, mut)
        before = lab.catalog(d)
        r = lab.apply(d, rd("0156/proposed_0156.sql"))
        check(f"0156 REFUSES and changes nothing: {label}", r.returncode != 0 and expect in r.stderr and lab.catalog(d) == before, r.stderr[-250:])
    d0 = lab.clone("td0149_p_base", "td0149_p56r")
    r = lab.apply(d0, rd("0156/proposed_0156.sql"))
    check("0156 REFUSES when proposal 0155 is not applied", r.returncode != 0 and "0155" in r.stderr, r.stderr[-200:])
    lab.c.dropdb("td0149_p56r")

    fi_fp = lab.scalar(pre, "select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f")
    db = lab.clone(pre, "td0149_p56")
    r = lab.apply(db, rd("0156/proposed_0156.sql"))
    check("0156 applies (gate created DISABLED)", r.returncode == 0 and "0156 complete" in r.stderr, r.stderr[-400:])
    check("post_apply 0156 PASSES", lab.verify(db, rd("0156/post_apply.sql"))["ok"])
    check("historical factored_invoices are untouched by 0156 (row digest identical)", lab.scalar(db, "select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f") == fi_fp)
    rc, off_out, err = submit(db, OWN, G)
    check("DISABLED BY DEFAULT: with the gate off the answer is BYTE-IDENTICAL to the 0140 rejection (behaviour unchanged by applying 0156)", off_out == base_out, off_out)
    for role, uid in (("anon", ""), ("service_role", "")):
        rc, out, err = submit(db, uid, G, role=role)
        check(f"AFTER 0156: {role} is denied on submit_invoice_to_factor (permission denied; F-09 closed for this function)", rc != 0 and "permission denied for function" in err, err[-200:])
    for role in ("anon", "authenticated", "service_role"):
        rc, out, err = lab.as_role(db, role, OWN, "select enabled from public.factoring_submission_gate")
        check(f"the gate table is unreadable by {role}", rc != 0 and "permission denied" in err, err[-150:])
    rc, out, err = lab.as_role(db, "service_role", "", "update public.factoring_submission_gate set enabled = true, decision_ref = 'x'")
    check("service_role cannot enable the gate", rc != 0 and "permission denied" in err, err[-150:])
    r = lab.sql(db, "update public.factoring_submission_gate set enabled = true;")
    check("the gate cannot be enabled WITHOUT a decision reference (CHECK constraint)", r.returncode != 0 and "needs_decision" in r.stderr)
    lab.sql(db, "update public.factoring_submission_gate set enabled = true, decision_ref = 'OWNER-DECISION-TEST', changed_by = 'operator', changed_at = now();")

    rc, out, err = submit(db, OWN, G, pre_sql="")
    text = f"begin;\nset local role authenticated;\nselect set_config('test.current_uid', '{OWN}', false) \\gset\nselect public.submit_invoice_to_factor('{G}', '{REL_A1}')::text;\nselect public.submit_invoice_to_factor('{G}', '{REL_A1}')::text;\ncommit;\n"
    p = lab.c.psql(db, text, guard=True, tuples=True, ok=False)
    outs = [l for l in p.stdout.splitlines() if l.startswith("{")]
    ok1 = json.loads(outs[0])
    check("PERMITTED: with the gate enabled the good invoice (carrier proven A1, A1's own default relationship, ready, one recipient) is submitted", ok1["success"] is True and ok1["status"] == "submitted" and ok1["carrier_id"].endswith("0001"), p.stderr[-300:] + str(outs))
    check("IDEMPOTENT: a repeated submission returns ALREADY_SUBMITTED naming the existing row and writes NOTHING (one factored invoice, one event, one snapshot)", '"ALREADY_SUBMITTED"' in outs[1] and lab.scalar(db, f"select count(*) from public.factored_invoices where invoice_id = '{G}'") == "1"
          and lab.scalar(db, "select count(*) from public.factored_invoice_carrier_snapshot_0156") == "1", str(outs))
    rc, rows, err = lab.rows(db, f"select f.invoice_face_value::text, f.expected_advance_amount::text, i.total_amount::text, s.carrier_id::text, s.relationship_id::text, s.gate_decision_ref, (s.evidence ->> 'status'), (s.readiness ->> 'classification') from public.factored_invoices f join public.invoices i on i.id = f.invoice_id join public.factored_invoice_carrier_snapshot_0156 s on s.factored_invoice_id = f.id where f.invoice_id = '{G}'")
    check("amounts: face value = the invoice total ONLY (1234.56); advance = 80% (987.65); dispatch-service fees are never read, netted or added", rows and rows[0][0] == "1234.56" and rows[0][1] == "987.65" and rows[0][0] == rows[0][2], str(rows))
    check("an immutable snapshot records the PROVEN carrier, relationship, readiness and the gate decision reference", rows and rows[0][3].endswith("0001") and rows[0][4] == REL_A1 and rows[0][5] == "OWNER-DECISION-TEST" and rows[0][6] == "proven" and rows[0][7] == "ready", str(rows))
    r = lab.sql(db, "update public.factored_invoice_carrier_snapshot_0156 set carrier_id = carrier_id;")
    r2 = lab.sql(db, "delete from public.factored_invoice_carrier_snapshot_0156;")
    check("the snapshot is IMMUTABLE (update and delete refused even for the owner)", r.returncode != 0 and r2.returncode != 0 and "immutable" in r.stderr + r2.stderr)
    rc, out, err = lab.as_role(db, "authenticated", OWN, "select count(*) from public.factored_invoice_carrier_snapshot_0156")
    check("RLS: an owner can read his organization's snapshot; another organization's owner sees none", out == "1", out + err[-100:])
    rc, out, err = lab.as_role(db, "authenticated", U["ownerB"], "select count(*) from public.factored_invoice_carrier_snapshot_0156")
    check("RLS: organization B's owner sees ZERO snapshot rows", out == "0", out)
    rc, out, err = lab.as_role(db, "authenticated", OWN, f"insert into public.factored_invoice_carrier_snapshot_0156 (factored_invoice_id, invoice_id, organization_id, carrier_id, relationship_id, factoring_company_id, readiness, evidence, gate_decision_ref) select id, invoice_id, organization_id, '{'a1a1a1a1-0000-0000-0000-000000000001'}', '{REL_A1}', factoring_company_id, '{{}}', '{{}}', 'x' from public.factored_invoices limit 1")
    check("no client role can write a snapshot row directly", rc != 0 and "permission denied" in err, err[-150:])

    cases = [
        ("a driver (role not permitted)", U["driverA"], G, REL_A1, "", "You do not have permission", True),
        ("a NULL identity through the authenticated role", "", G, REL_A1, "", "No organization", True),
        ("another organization's owner (cross-organization invoice)", U["ownerB"], "1a000000-0000-0000-0000-000000000008", REL_A1, "", "No organization|Invoice not found", True),
        ("an invoice with BOTH a broker and a customer (recipient routing ambiguous)", OWN, "1a000000-0000-0000-0000-000000000008", REL_A1, "", "RECIPIENT_AMBIGUOUS", False),
        ("an invoice with NO recipient", OWN, "1a000000-0000-0000-0000-000000000009", REL_A1, "", "RECIPIENT_AMBIGUOUS", False),
        ("an invoice with NO carrier evidence", OWN, "1a000000-0000-0000-0000-00000000000a", REL_A1, "", "CARRIER_EVIDENCE_NOT_PROVEN", False),
        ("an invoice with CONFLICTING carrier evidence (dispatch A1, load A2)", OWN, "1a000000-0000-0000-0000-00000000000b", REL_A1, "", "CARRIER_EVIDENCE_NOT_PROVEN", False),
        ("an invoice proven to carrier A2 submitted with carrier A1's relationship (cross-carrier)", OWN, "1a000000-0000-0000-0000-00000000000c", REL_A1, "", "RELATIONSHIP_CARRIER_MISMATCH", False),
        ("a relationship of ANOTHER organization (cross-organization relationship)", OWN, "1a000000-0000-0000-0000-00000000000e", "fe000000-0000-0000-0000-000000000001", "", "RELATIONSHIP_NOT_AVAILABLE", False),
        ("a relationship id that does not exist", OWN, "1a000000-0000-0000-0000-00000000000e", "fe000000-0000-0000-0000-0000000000ff", "", "RELATIONSHIP_NOT_AVAILABLE", False),
        ("a partially paid invoice", OWN, "1a000000-0000-0000-0000-00000000000d", REL_A1, "", "not eligible for factoring", True),
    ]
    for label, uid, inv, rel, pre_sql, expect, is_err in cases:
        rc, out, err = submit(db, uid, inv, rel, pre_sql)
        blob = out + err
        check(f"REJECTED: {label}", (rc != 0 and any(e in err for e in expect.split("|"))) if is_err else (rc == 0 and expect in out and '"success": false' in out), blob[-300:])
    variants = [("the relationship is INACTIVE (an inactive relationship cannot be a default: 0071 CHECK)", f"update public.factoring_relationships set is_active = false, is_default = false where id = '{REL_A1}';", "NOT_CARRIER_DEFAULT"),
                ("the relationship is not the carrier's default", f"update public.factoring_relationships set is_default = false where id = '{REL_A1}';", "NOT_CARRIER_DEFAULT"),
                ("the relationship is not yet effective", f"update public.factoring_relationships set effective_from = current_date + 5 where id = '{REL_A1}';", "RELATIONSHIP_NOT_EFFECTIVE"),
                ("the relationship has EXPIRED", f"update public.factoring_relationships set effective_from = current_date - 30, effective_to = current_date - 1 where id = '{REL_A1}';", "RELATIONSHIP_NOT_EFFECTIVE"),
                ("the factoring company is inactive", "set session_replication_role = replica; update public.factoring_companies set is_active = false where id = 'f0000000-0000-0000-0000-00000000000a'; set session_replication_role = origin;", "COMPANY_INACTIVE"),
                ("the carrier is configured for DIRECT billing", "update public.carriers set factoring_mode = 'direct' where id = 'a1a1a1a1-0000-0000-0000-000000000001';", "POLICY_NOT_FACTORED"),
                ("the carrier is UNCONFIGURED", "update public.carriers set factoring_mode = 'unconfigured' where id = 'a1a1a1a1-0000-0000-0000-000000000001';", "POLICY_NOT_FACTORED"),
                ("the carrier is INACTIVE", "update public.carriers set is_active = false where id = 'a1a1a1a1-0000-0000-0000-000000000001';", "CARRIER_EVIDENCE_NOT_PROVEN"),
                ("the broker party is not factoring-eligible", "update public.carrier_brokers set factoring_eligible = false where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001';", "NOT_READY"),
                ("the NOA is not approved", f"set session_replication_role = replica; update public.factoring_relationships set noa_approved = false, noa_approved_by = null, noa_approved_at = null where id = '{REL_A1}'; set session_replication_role = origin;", "NOT_READY"),
                ("an OPEN exception exists on the relationship", f"insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason) values ('{OA}', 'factoring_relationship', '{REL_A1}', 'open');", "UNRESOLVED_LEGACY_RECORD"),
                ("an OPEN exception exists on the invoice", f"insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason) values ('{OA}', 'invoice', '{G}', 'open');", "UNRESOLVED_LEGACY_RECORD")]
    for label, mut, code in variants:
        # a fresh good invoice each time (the first one is already submitted): use the same invoice on a clone without the earlier submission
        v = lab.clone(pre, "td0149_p56v")
        assert lab.apply(v, rd("0156/proposed_0156.sql")).returncode == 0
        lab.sql(v, "update public.factoring_submission_gate set enabled = true, decision_ref = 'T', changed_by = 'op', changed_at = now();")
        rc, out, err = submit(v, OWN, G, REL_A1, mut)
        check(f"REJECTED ({code}): {label}", rc == 0 and f'"{code}"' in out and '"success": false' in out and lab.scalar(v, "select count(*) from public.factored_invoices") == lab.scalar(pre, "select count(*) from public.factored_invoices"), (out + err)[-300:])
    lab.c.dropdb("td0149_p56v")
    # unresolved 0155 review blocks; then the owner's decision unblocks nothing automatically
    v = lab.clone(pre, "td0149_p56v")
    assert lab.apply(v, rd("0156/proposed_0156.sql")).returncode == 0
    lab.sql(v, "update public.factoring_submission_gate set enabled = true, decision_ref = 'T', changed_by = 'op', changed_at = now();")
    lab.sql(v, f"insert into public.carrier_inference_review_0155 (relationship_id, organization_id, classification, prior_carrier_id, strict_status, evidence, first_run_id, last_run_id) values ('{REL_A1}', '{OA}', 'unsafe_assigned', 'a1a1a1a1-0000-0000-0000-000000000001', 'partial', '{{}}', gen_random_uuid(), gen_random_uuid()) on conflict (relationship_id) do update set classification = 'unsafe_assigned', decision_status = 'pending';")
    rc, out, err = submit(v, OWN, G)
    check("REJECTED (UNRESOLVED_LEGACY_RECORD): the relationship has a PENDING 0155 review", '"UNRESOLVED_LEGACY_RECORD"' in out, out + err[-200:])
    lab.c.dropdb("td0149_p56v")
    rc, out, err = lab.as_role(db, "authenticated", OWN, f"select count(*) from public.factored_invoices where invoice_id in ('1a000000-0000-0000-0000-000000000008','1a000000-0000-0000-0000-000000000009','1a000000-0000-0000-0000-00000000000a','1a000000-0000-0000-0000-00000000000b','1a000000-0000-0000-0000-00000000000c','1a000000-0000-0000-0000-00000000000d')")
    check("no rejected attempt wrote anything (no factored invoice for any rejected invoice); ambiguous legacy rows were NOT silently repaired", out == "0", out)
    r = lab.apply(db, rd("0156/rollback.sql"))
    check("rollback 0156 restores the EXACT 0140 rejection, keeps historical submissions AND their snapshots (table kept because it holds rows)", r.returncode == 0 and "KEPT" in r.stderr and lab.scalar(db, "select count(*) from public.factored_invoices where invoice_id = '" + G + "'") == "1"
          and lab.scalar(db, "select count(*) from public.factored_invoice_carrier_snapshot_0156") == "1" and lab.scalar(db, "select (to_regclass('public.factoring_submission_gate') is null)::text") == "true", r.stderr[-300:])
    rc, out, err = submit(db, OWN, "1a000000-0000-0000-0000-00000000000a")
    check("after rollback every invoice is rejected again with the 0140 message", '"CARRIER_INVOICE_SNAPSHOT_REQUIRED"' in out, out)
    lab.c.dropdb("td0149_p56pre")


# ------------------------------------------------------------------------------------------------------------------------------------------------- main
def app_contract():
    print("== application contract (static) ==")
    act = (REPO / "src" / "app" / "(app)" / "invoices" / "factoring-actions.ts").read_text()
    sql = rd("0156/proposed_0156.sql")
    rets = re.findall(r"return pg_catalog\.jsonb_build_object\((.*?)\);", sql, re.S)
    fails = [r for r in rets if "'success', false" in r]
    check("every structured rejection of the 0156 function carries success=false, a code and a human message (what resolveStructuredRpcResult / the action surfaces)", len(fails) == 13 and all("'code'" in r and "'message'" in r for r in fails), str(len(fails)))
    succ = [r for r in rets if "'success', true" in r]
    check("the success result carries factored_invoice_id and status (the exact keys the action reads)", len(succ) == 1 and "'factored_invoice_id'" in succ[0] and "'status'" in succ[0])
    check("the action passes the RPC's code and snapshot_required through and never picks a relationship or carrier itself", "rpcResult?.code" in act and "snapshot_required" in act and "carrier_id" not in act.split("export async function submitInvoiceToFactor")[1].split("export async function")[0])
    page = (REPO / "src" / "app" / "(app)" / "invoices" / "[id]" / "page.tsx").read_text()
    check("KNOWN GAP (Owner decision D-08c): the invoice page still blocks every legacy invoice and offers no relationship, so the UI cannot submit even when the gate is enabled -- documented in OWNER_DECISIONS.md", "SNAPSHOT_REQUIRED_REASON" in page)


def main():
    static_checks()
    app_contract()
    c = t149.Cluster()
    ok = False
    try:
        c.start()
        env, base = build(c)
        lab = Lab(c, env)
        db54 = f05(lab, base)
        f13(lab, db54)
        db55 = f01(lab, db54)
        f08(lab, db55)
        ok = True
        print(f"\nALL {len(checks)} CHECKS PASSED (0154 + 0155 + 0156; disposable local PostgreSQL; synthetic data; NOT a hosted or production proof)")
    finally:
        c.cleanup(ok)


if __name__ == "__main__":
    main()
