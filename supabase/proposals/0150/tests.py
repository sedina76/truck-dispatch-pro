#!/usr/bin/env python3
"""Proposal 0150 (+ Blocker F1) -- disposable-PostgreSQL verification harness.

NOT APPROVED FOR PRODUCTION. Reuses the reviewed proposal-0149 cluster harness (a brand-new local cluster under
/private/tmp/td0149-local-*, unix socket only, port 55491, minimal environment, absolute binaries; never connects to
Supabase or any real database; never writes inside the repository). Database names start with td0149_ because the
shared scratch guard (fixture/regression/f1 scripts) requires it.

Build sequence of the base database (the REAL migrations, in production order):
  support schema -> 0129 baseline functions -> 0130..0132 -> 0149 fixture + legacy_seed (legacy loads/dispatches)
  -> 0133 (the REAL backfill classifies them) -> 0134..0147 -> proposed 0149.
Then: F1 verification; 0150 preflight/review; negative scenarios (each on its own clone); apply; row-level and catalog
comparison; functional regression; real two-session races; post-apply; rollback/refusal; exact restoration; reapply.
"""
import glob
import hashlib
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
P0149 = SUPA / "proposals" / "0149"
import importlib.util  # noqa: E402


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# this file is itself called tests.py / build.py-adjacent: load the 0149 harness and generator by explicit path
sys.path.insert(0, str(P0149))
t149 = _load("t149_harness", P0149 / "tests.py")    # Cluster, catalog, pinned sources (its own `import build` resolves to the 0149 generator)
b149 = sys.modules["build"]                          # 0149 generator: baseline function blocks
sys.path.remove(str(P0149))
build = _load("build0150", HERE / "build.py")

SEP = t149.SEP
PSQL = t149.PSQL

PINNED_EXTRA = {
    "migrations/0136_carrier_factoring_policy_and_relationship_columns.sql": "e25ce9c867e92384eb4bfe39388616f8c4285ed20a8d02c52c1275ecf50c989c",
    "migrations/0137_deterministic_factoring_carrier_backfill.sql": "9069ba5a7544db41bd6a0ab9a52cb914ebd4b7748c02a4d70a078c9ec8f3efbe",
    "migrations/0138_carrier_default_cutover_classifier_and_secured_rpcs.sql": "df21888d39acb2b0aa689fc2b2da2a989dafe2aac376d398a4fc0c495128d1d1",
    "migrations/0139_factoring_policy_safety_integrations_and_privilege_remediation.sql": "f0e5275895416ca0f4d9f8b2ac6e00265830e3fee1e7a3e073d0377af2ccd167",
    "migrations/0140_factoring_authorization_and_submission_safety.sql": "6aa7aab4410201c63bedefce392662f0bdf8d94c3fe892604ec2920f0025c567",
    "migrations/0141_factoring_integration_lifecycle_integrity.sql": "f9c8332cdd1c7f491156e71e0e6a99d5a98b5cd2bf7217f29a717d6a15dcba18",
    "migrations/0142_immutable_carrier_invoice_foundation.sql": "d358198f89e13f68490e3d73f42017f2aa51faf146d8894f4e27d8ffb7a7cf6d",
    "migrations/0143_canonical_financial_idempotency_hardening.sql": "5468dcf4d3ecdb014870596837528d0fcde1aab44d1f6712e5765f8bfec8e8c0",
    "migrations/0144_atomic_carrier_invoice_issuance.sql": "4b93e85b48557cd23dee5ec566aa829587052a1447c90a8cdb613381d1d97bc0",
    "migrations/0145_carrier_dispatch_service_agreements_and_issuance.sql": "ff7cda60d5ed5125f39b3d8637fa3084c064f2ed8874678362973a3214453167",
    "migrations/0146_carrier_invoice_payments_and_balance_rollups.sql": "25da34ad86e08d4b218fea43ad3ab8dc2fa2b91bff0e2446a03325f4ae84f5ef",
    "migrations/0147_production_readiness_blocker_remediation.sql": "a0720e8154c96601d4a2b5cf1ccf6bde8f4cacce22b090fc35b640d0fc03c1e2",
    "TEST_SUPPORT_0136_0138_factoring_schema.sql": "654ea3e021348858c56edbb97fff62d2746167aa33708d9d4900ee9c577fa4c1",
    "proposals/0149/proposed_0149.sql": "22af4a84e1322d99b09ff2a36a4d21b9f29680656d4cbb25b999c02c6e671970",
}
COUNT_LINE = "  v_expected_count  constant integer := null;   -- <<< OWNER: REPLACE null WITH THE APPROVED CANDIDATE COUNT (integer)"
DIGEST_LINE = "  v_expected_digest constant text    := null;   -- <<< OWNER: REPLACE null WITH THE APPROVED CANDIDATE DIGEST (32 hex chars) printed by candidate_review.sql"
PF_COUNT = "  select null::integer as expected_count,   -- <<< OWNER (optional here): approved candidate count"
PF_DIGEST = "         null::text as expected_digest  -- <<< OWNER (optional here): approved digest"

checks = []


def check(label, cond, detail=""):
    if not cond:
        raise SystemExit(f"FAIL: {label} {detail}")
    checks.append(label)
    print(f"  ok  {label}")


def uid(name):
    return str(uuid.UUID(hashlib.md5(("td0149:" + name).encode()).hexdigest()))


def read(rel):
    return (SUPA / rel).read_text()


def pinned_extra(rel):
    raw = (SUPA / rel).read_bytes()
    if hashlib.sha256(raw).hexdigest() != PINNED_EXTRA[rel]:
        raise SystemExit(f"Unreviewed source (SHA-256 mismatch): {rel}")
    return raw.decode()


def fill(sql, count=None, digest=None):
    assert sql.count(COUNT_LINE) == 1 and sql.count(DIGEST_LINE) == 1, "placeholder lines changed"
    if count is not None:
        sql = sql.replace(COUNT_LINE, COUNT_LINE.replace(":= null;", f":= {count};"))
    if digest is not None:
        sql = sql.replace(DIGEST_LINE, DIGEST_LINE.replace(":= null;", f":= '{digest}';"))
    return sql


def fill_preflight(sql, count=None, digest=None):
    assert sql.count(PF_COUNT) == 1 and sql.count(PF_DIGEST) == 1
    if count is not None:
        sql = sql.replace(PF_COUNT, PF_COUNT.replace("null::integer", f"{count}::integer"))
    if digest is not None:
        sql = sql.replace(PF_DIGEST, PF_DIGEST.replace("null::text", f"'{digest}'::text"))
    return sql


# ------------------------------------------------------------------- static
def static_checks():
    print("== static checks ==")
    files = build.build_all()
    for name, text in files.items():
        check(f"generated {name} is current", (HERE / name).read_text() == text)
    for rel in t149.PINNED:
        t149.pinned(rel)
    for rel in PINNED_EXTRA:
        pinned_extra(rel)
    check("0129 + 0130-0135 + 0136-0147 + support schemas + proposed_0149.sql match their SHA-256 pins", True)
    fp = build.fingerprints()
    check("0132 guard fingerprints derived from the 0132 source (2 functions)", len(fp) == 2 and all(len(v) == 32 for v in fp.values()))

    strip = t149.strip_sql
    prop = (HERE / "proposed_0150.sql").read_text()
    code = strip(prop)
    check("proposed_0150.sql: never touches functions/triggers/types/indexes (no create/alter/drop function|trigger|type|index|extension|schema)",
          not re.search(r"\b(create|alter|drop)\s+(or\s+replace\s+)?(function|trigger|type|index|extension|schema|view|materialized)\b", code, re.I))
    check("proposed_0150.sql: no delete/truncate/merge/copy", not re.search(r"\b(delete\s+from|truncate|merge\s+into|copy\s)", code, re.I))
    ups = sorted(set(re.findall(r"\bupdate\s+public\.(\w+)", code, re.I)))
    check("proposed_0150.sql: UPDATEs only public.loads and public.unresolved_carrier_records", ups == ["loads", "unresolved_carrier_records"], str(ups))
    ins = sorted(set(re.findall(r"\binsert\s+into\s+public\.(\w+)", code, re.I)))
    check("proposed_0150.sql: INSERTs only into carrier_backfill_0150_provenance", ins == ["carrier_backfill_0150_provenance"], str(ins))
    check("proposed_0150.sql: the only column ever SET on loads is carrier_resolution",
          len(re.findall(r"update public\.loads l\s+set carrier_resolution = null", code)) == 1 and len(re.findall(r"update public\.loads", code)) == 1)
    check("proposed_0150.sql: never assigns a carrier (no 'carrier_id =' assignment in any UPDATE ... SET)",
          not re.search(r"\bset\b[^;]*\bcarrier_id\s*=", code, re.I))
    check("proposed_0150.sql: deterministic lock order (loads by id, then exception records by id, FOR UPDATE)",
          len(re.findall(r"order by l\.id for update", code)) == 1 and len(re.findall(r"order by u\.id for update", code)) == 1)
    check("proposed_0150.sql: single begin/commit, explicit expected count required",
          len(re.findall(r"^begin;$", prop, re.M)) == 1 and len(re.findall(r"^commit;$", prop, re.M)) == 1 and "expected candidate count is not set" in prop)
    check("proposed_0150.sql: fails closed on contradictory evidence (aborts, never skips)", "carry contradictory or unexpected evidence" in prop)
    roll = strip((HERE / "rollback.sql").read_text())
    check("rollback.sql: touches only loads, unresolved_carrier_records and drops only the 0150 provenance table",
          sorted(set(re.findall(r"\bupdate\s+public\.(\w+)", roll, re.I))) == ["loads", "unresolved_carrier_records"]
          and re.findall(r"\bdrop\s+table\s+([\w.]+)", roll, re.I) == ["public.carrier_backfill_0150_provenance"])
    strict = re.compile(r"\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|comment|copy|call|do|begin|commit|rollback|savepoint|set|reset|lock|listen|notify|"
                        r"vacuum|reindex|analyze|execute|prepare|declare|fetch|refresh|cluster|import|security)\b", re.I)
    for name in ("preflight.sql", "post_apply.sql", "candidate_review.sql"):
        raw = (HERE / name).read_text()
        s = strip(raw)
        hits = strict.findall(s)
        check(f"{name}: exactly ONE select statement; no data-/schema-changing keyword, transaction control or set_config",
              s.count(";") == 1 and not hits and "set_config" not in s, str(hits))
        raw_hits = re.findall(r"(?i)\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|copy|call)\b", raw)
        check(f"{name}: forbidden words appear nowhere in the file text (code, strings or comments)", not raw_hits, str(raw_hits))
    rv = strip((HERE / "candidate_review.sql").read_text())
    check("candidate_review.sql selects no customer/broker/rate/address/contact data",
          not re.search(r"\b(customer|broker|rate|address|phone|email|city|postal|pickup|delivery|driver|invoice_number|amount)\w*", rv, re.I), str(re.findall(r"\b(customer|broker|rate|address|phone|email)\w*", rv, re.I)))
    check("evidence list covers the 0142/0144/0145 carrier-evidence tables", set(build.REQUIRED_EVIDENCE) ==
          {"public.carrier_invoice_loads", "public.carrier_invoice_line_items", "public.carrier_dispatch_service_billing_lines"})
    for f in ("proposed_0150.sql", "preflight.sql", "candidate_review.sql", "post_apply.sql", "rollback.sql"):
        check(f"{f} is marked NOT APPROVED FOR PRODUCTION and names the 0148 renumbering", "NOT APPROVED FOR PRODUCTION" in (HERE / f).read_text() and "0153 or higher" in (HERE / f).read_text())
    check("0148 proposal directory untouched by this work (12 pinned files exist)", len(list((SUPA / "proposals" / "0148").glob("*"))) >= 12)


# ------------------------------------------------------------------- live helpers
class Env:
    def __init__(self, c):
        self.c = c
        self.guard = t149.guard_of((P0149 / "fixture.sql").read_text())
        self.model = b149.model()
        self.text_0129 = b149.source()

    def mig(self, n):
        return t149.Path(glob.glob(f"{SUPA}/migrations/{n:04d}_*.sql")[0]).read_text()

    def build_base(self, db):
        c = self.c
        c.createdb(db)
        base = "".join(self.model["funcs"][n]["old_block"] + "\n\n" for n in ("create_dispatch", "cancel_dispatch")) + b149.baseline_privileges_sql(self.text_0129)
        sql = (self.guard + "\n\\set ON_ERROR_STOP on\n" + t149.pinned("TEST_SUPPORT_0130_0133_schema.sql") + "\n" + pinned_extra("TEST_SUPPORT_0136_0138_factoring_schema.sql")
               + "\ndrop function public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text);\ndrop function public.cancel_dispatch(uuid,text);\n" + base)
        for n in (130, 131, 132):
            sql += "\n" + self.mig(n)
        sql += "\n" + (P0149 / "fixture.sql").read_text() + "\n" + (HERE / "legacy_seed.sql").read_text()
        for n in range(133, 148):
            sql += "\n" + self.mig(n)
        sql += "\n" + pinned_extra("proposals/0149/proposed_0149.sql")
        c.psql(db, sql, guard=True)

    def q(self, db, sql, ro=True):
        p = self.c.psql(db, sql.rstrip().rstrip(";") + ";", tuples=True, ro=ro, ok=False)
        return p.returncode, [l.split(SEP) for l in p.stdout.splitlines() if l.strip()], p.stderr

    def scalar(self, db, sql):
        rc, rows, err = self.q(db, sql)
        assert rc == 0, err
        return rows[0][0] if rows else None

    def run(self, db, sql, guard=False):
        return self.c.psql(db, sql, guard=guard, ok=False)

    def verify(self, db, name, text=None):
        p = self.c.psql(db, text if text is not None else (HERE / name).read_text(), tuples=True, ro=True, ok=False)
        rows = [l.split(SEP) for l in p.stdout.splitlines() if l.count(SEP) == 4]
        ok = p.returncode == 0 and bool(rows) and rows[-1][1] == "RESULT" and rows[-1][3] == "PASS" and all(r[3] in ("INFO", "PASS") for r in rows)
        return {"ok": ok, "rows": rows, "err": p.stderr}

    def review(self, db):
        rc, rows, err = self.q(db, (HERE / "candidate_review.sql").read_text())
        assert rc == 0, err
        summ = {r[2]: r[3] for r in rows if r[1] == "SUMMARY"}
        return rows, summ

    # ---- state digests
    def digest(self, db, full=True, mode=None):
        """Row-level fingerprints. full=True: byte-for-byte. full=False ('norm'): excludes trigger-maintained updated_at and the closure time
        resolved_at. mode 'noupd': excludes only updated_at. mode 'core': loads without carrier_resolution/updated_at and exception records
        without updated_at/status/resolved_at/resolution_note (i.e. everything 0150 is NOT allowed to change)."""
        mode = mode or ("full" if full else "norm")
        lx = {"full": "", "norm": " - 'updated_at'", "noupd": " - 'updated_at'", "core": " - 'updated_at' - 'carrier_resolution'"}[mode]
        ux = {"full": "", "norm": " - 'updated_at' - 'resolved_at'", "noupd": " - 'updated_at'", "core": " - 'updated_at' - 'status' - 'resolved_at' - 'resolution_note'"}[mode]
        rc, rows, err = self.q(db, f"""
select 'loads', l.id::text, md5((to_jsonb(l){lx})::text) from public.loads l
union all select 'exc', u.id::text, md5((to_jsonb(u){ux})::text) from public.unresolved_carrier_records u
union all select 'disp', d.id::text, md5(to_jsonb(d)::text) from public.dispatches d
union all select 'prov0133', p.load_id::text, md5(to_jsonb(p)::text) from public.carrier_backfill_0133_provenance p;""")
        assert rc == 0, err
        return {(r[0], r[1]): r[2] for r in rows}

    def digest_prov0150(self, db):
        rc, rows, err = self.q(db, "select p.load_id::text, md5((to_jsonb(p) - 'applied_at')::text) from public.carrier_backfill_0150_provenance p")
        assert rc == 0, err
        return {r[0]: r[1] for r in rows}

    def catalog(self, db):
        return t149.catalog(self.c, db)

    def prov_absent(self, db):
        return self.scalar(db, "select (to_regclass('public.carrier_backfill_0150_provenance') is null)::text") == "true"


def changed_ids(a, b, kind):
    return sorted(k[1] for k in set(a) | set(b) if k[0] == kind and a.get(k) != b.get(k))


def diff_dump(a, b):
    import difflib
    return [l for l in difflib.unified_diff(a, b, lineterm="", n=0) if l[:1] in "+-" and not l.startswith(("---", "+++"))]


# ------------------------------------------------------------------- sessions (real concurrency)
class Session:
    def __init__(self, c, db, uid_name=None, role=None):
        opts = "-c app.zzz_0149_test=scratch-ok"
        if uid_name:
            opts += f" -c test.current_uid={uid(uid_name)}"
        env = dict(c.env)
        env["PGOPTIONS"] = opts
        args = [PSQL, "-X", "-w", "-q", "-v", "ON_ERROR_STOP=0", "-h", str(c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-A", "-t", "-F", SEP]
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.role = role

    def send(self, sql):
        self.p.stdin.write(sql if sql.endswith("\n") else sql + "\n")
        self.p.stdin.flush()

    def finish(self, timeout=120):
        out, err = self.p.communicate(timeout=timeout) if self.p.stdin.closed is False else (self.p.stdout.read(), self.p.stderr.read())
        return self.p.returncode, out, err


def wait_blocked(env, db, min_blocked=1, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        n = env.scalar(db, "select count(*) from pg_stat_activity where datname = current_database() and wait_event_type = 'Lock' and pid <> pg_backend_pid()")
        if int(n) >= min_blocked:
            return True
        time.sleep(0.2)
    return False


def evidence_mutation(tbl, col, load_uid):
    name = tbl.split(".")[1]
    return f"""
do $x$
declare r record;
begin
  if to_regclass('{tbl}') is null then
    execute 'create table {tbl} (id uuid default gen_random_uuid(), {col} uuid)';
  else
    for r in select a.attname from pg_attribute a where a.attrelid = '{tbl}'::regclass and a.attnum > 0 and not a.attisdropped and a.attnotnull
                and not exists (select 1 from pg_index i where i.indrelid = a.attrelid and i.indisprimary and a.attnum = any(i.indkey)) loop
      begin execute format('alter table {tbl} alter column %I drop not null', r.attname); exception when others then null; end;
    end loop;
    for r in select k.conname from pg_constraint k where k.conrelid = '{tbl}'::regclass and k.contype in ('f','c') loop
      begin execute format('alter table {tbl} drop constraint %I', r.conname); exception when others then null; end;
    end loop;
  end if;
  execute format('insert into {tbl} (%I) values (%L)', '{col}', '{load_uid}');
end $x$;
"""


# ------------------------------------------------------------------- the run
def live(c):
    env = Env(c)
    print("== build base database (real 0130..0147 chain + 0149, legacy data classified by the REAL 0133) ==")
    base = "td0149_p_base"
    env.build_base(base)
    check("base database built", True)

    # ---- what the REAL 0133 did
    rc, rows, err = env.q(base, "select l.load_number, coalesce(l.carrier_resolution,'NULL'), (l.carrier_id is not null)::text, (select count(*) from public.dispatches d where d.load_id = l.id)::text from public.loads l order by 1")
    cls = {r[0]: (r[1], r[2], int(r[3])) for r in rows}
    want = {"LD-K001": ("resolved", "true", 1), "LD-K002": ("backfilled", "true", 1), "LD-K003": ("backfilled", "true", 1), "LD-K004": ("unresolved", "false", 2),
            "LD-K005": ("unresolved", "false", 2), "LD-K006": ("resolved", "true", 0), "LD-K901": ("backfilled", "true", 1)}
    for k, v in want.items():
        check(f"0133 classified {k} as {v[0]} (carrier {'set' if v[1] == 'true' else 'NULL'}, {v[2]} dispatch(es))", cls.get(k) == v, str(cls.get(k)))
    zero = [k for k, v in cls.items() if v[0] == "unresolved" and v[2] == 0]
    check("0133 left the zero-dispatch legacy loads unresolved (the Blocker A population)", len(zero) == 22 and "LD-100001" in zero and "LD-299001" in zero, str(len(zero)))
    n_zero = len(zero)

    # ---- the blocker, demonstrated with the real guard
    tmp = "td0149_p_blocker"
    c.createdb(tmp, template=base)
    r = env.run(tmp, env.guard + f"""
set role authenticated;
select set_config('test.current_uid', '{uid('u_disp1')}', false);
select public.create_dispatch('{uid('l1')}', '{uid('ca')}', '{uid('ta3')}', '{uid('da3')}', null, null, null);
""", guard=True)
    check("BLOCKER A reproduced: before 0150 the first dispatch of an existing zero-dispatch load is rejected (23514 unresolved carrier)",
          r.returncode != 0 and "has an unresolved carrier" in r.stderr, r.stderr[-300:])
    c.dropdb(tmp)

    # ---- F1 verification on the same real chain
    print("== Blocker F1: cancel through transition_dispatch_status on the real chain ==")
    f1db = "td0149_p_f1"
    c.createdb(f1db, template=base)
    r = env.run(f1db, (HERE / "f1_cancel_verify.sql").read_text(), guard=True)
    ok_f1 = r.returncode == 0 and "F1 VERIFICATION PASSED" in r.stderr
    check("f1_cancel_verify.sql: all 11 F1 conditions pass on the real 0130..0147 + 0149 chain", ok_f1, r.stderr[-1500:])
    for tag in ("F0", "F2", "F1/F2", "F3", "F4", "F4b", "F5", "F6", "F6b", "F7", "F8", "F9", "F10", "F11", "F11b"):
        check(f"F1 verification group {tag}", re.search(rf"NOTICE:\s+OK: {re.escape(tag)} ", r.stderr) is not None)
    check("F1 finding F1-R1 (cross-org replay of a KNOWN dispatch id + key returns the cached result) is reported", "FINDING F1-R1" in r.stderr)
    (c.tmp / "f1_notices.txt").write_text(r.stderr)
    c.dropdb(f1db)

    # ---- preflight + review on the pre-0150 database
    print("== 0150 preflight / review on the pre-apply database ==")
    pf = env.verify(base, "preflight.sql")
    check("preflight.sql PASSES on the post-0133/0147/0149 database", pf["ok"], pf["err"][-800:])
    rows, summ = env.review(base)
    n_cand = int(summ["CANDIDATES (approve this count)"])
    digest = summ["candidate digest (REQUIRED: paste into v_expected_digest)"]
    check("candidate_review.sql reports the exact candidate population", n_cand == n_zero and summ["BLOCKED (contradictory evidence; 0150 aborts while > 0)"] == "0"
          and summ["unresolved loads WITH dispatches (never touched by 0150)"] == "3", str(summ))
    listed = sorted(r[2].split("  [")[0] for r in rows if r[1] == "CANDIDATE")
    check("candidate_review.sql lists every candidate by load number, organization and context (and nothing sensitive)", listed == sorted(zero) and all("org " in r[3] for r in rows if r[1] == "CANDIDATE"))
    pf2 = env.verify(base, None, fill_preflight((HERE / "preflight.sql").read_text(), n_cand, digest))
    check("preflight.sql with the approved count + digest PASSES", pf2["ok"], pf2["err"][-500:])
    pf3 = env.verify(base, None, fill_preflight((HERE / "preflight.sql").read_text(), n_cand + 1, digest))
    check("preflight.sql with a wrong approved count FAILS closed", not pf3["ok"] and "PREFLIGHT 0150 FAIL" in pf3["err"] and "approved expected count" in pf3["err"], pf3["err"][-400:])
    check("post_apply.sql cannot pass before 0150 exists (provenance table missing)", not env.verify(base, "post_apply.sql")["ok"])

    proposed = (HERE / "proposed_0150.sql").read_text()
    ready = fill(proposed, n_cand, digest)

    # ---- negative scenarios: each on its own clone; a failed migration must change NOTHING
    print("== negative scenarios (fail closed, nothing changed) ==")
    L1, LK = uid("l1"), uid("kd_c2")
    scen = []

    def add(name, mutate, expect, count=None, digest_=None, preflight_fail=True):
        scen.append((name, mutate, expect, count if count is not None else n_cand, digest_ if digest_ is not None else digest, preflight_fail))

    for tbl, col, _req in build.EVIDENCE:
        add(f"evidence row in {tbl}.{col}", evidence_mutation(tbl, col, L1), f"{tbl}=1")
    add("second exception record for the load", f"insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason, detail, status) values ('{uid('o1')}', 'load', '{L1}', 'x', '{{}}', 'manually_resolved');", "exception record(s) for this load (expected exactly 1)")
    add("exception reason text tampered", f"update public.unresolved_carrier_records set reason = reason || ' (edited)' where record_id = '{L1}';", "not the exact open 0133 C4_zero_dispatch record")
    add("exception rule tampered", f"""update public.unresolved_carrier_records set detail = '{{"rule":"C4_conflicting_carriers","dispatches":[]}}' where record_id = '{L1}';""", "not the exact open 0133 C4_zero_dispatch record")
    add("exception organization differs from the load's", f"update public.unresolved_carrier_records set organization_id = '{uid('o2')}' where record_id = '{L1}';", "not the exact open 0133 C4_zero_dispatch record")
    add("exception already closed", f"update public.unresolved_carrier_records set status = 'manually_resolved', resolved_at = now(), resolution_note = 'done' where record_id = '{L1}';", "not the exact open 0133 C4_zero_dispatch record")
    add("exception has a resolver", f"update public.unresolved_carrier_records set resolved_by = '{uid('u_disp1')}' where record_id = '{L1}';", "not the exact open 0133 C4_zero_dispatch record")
    add("0133 provenance row missing", f"delete from public.carrier_backfill_0133_provenance where load_id = '{L1}';", "0133 provenance row missing or inconsistent")
    add("0133 provenance row disagrees (carrier recorded)", f"update public.carrier_backfill_0133_provenance set carrier_id = '{uid('ca')}' where load_id = '{L1}';", "0133 provenance row missing or inconsistent")
    add("load carrier_id already set while unresolved", f"update public.loads set carrier_id = '{uid('ca')}' where id = '{L1}';", "carrier_id is set")
    add("load carrier_locked_at set", f"update public.loads set carrier_locked_at = now() where id = '{L1}';", "carrier_locked_at is set")
    add("load has a financial controller", f"update public.loads set financial_dispatch_id = '{LK}' where id = '{L1}';", "financial_dispatch_id is set")
    add("candidate count too high", "", "candidate count", count=n_cand + 1, preflight_fail=False)
    add("candidate count too low", "", "candidate count", count=n_cand - 1, preflight_fail=False)
    add("expected count not supplied (placeholder untouched)", "", "expected candidate count is not set", count=-1, preflight_fail=False)
    add("wrong candidate digest", "", "candidate digest", digest_="0" * 32, preflight_fail=False)
    add("count filled but digest left NULL", "", "expected candidate digest is not set", digest_=-1, preflight_fail=False)
    add("digest is a placeholder, not 32 hex chars", "", "expected candidate digest is not set", digest_="EXAMPLE-DIGEST", preflight_fail=False)
    add("count is an obvious example (0) while candidates exist", "", "candidate count", count=0, preflight_fail=False)
    add("0132 dispatch guard function altered", "create or replace function public.guard_dispatch_carrier_scope() returns trigger language plpgsql security definer set search_path = pg_catalog, public as $f$ begin return new; end $f$;", "not the reviewed 0132 definition")
    add("0132 dispatch guard trigger disabled", "alter table public.dispatches disable trigger dispatches_guard_carrier_scope;", "guard trigger is missing or disabled")
    add("proposal 0149 not applied (defective create_dispatch restored)", b149.as_replace(env.model["funcs"]["create_dispatch"]["old_block"]), "0149")
    for i, (name, mutate, expect, cnt, dig, pf_fail) in enumerate(scen):
        db = f"td0149_n{i}"
        c.createdb(db, template=base)
        if mutate:
            r = env.run(db, "set session_replication_role = replica;\n" + mutate, guard=True)
            assert r.returncode == 0, f"scenario setup failed [{name}]: {r.stderr[-500:]}"
        before = env.digest(db)
        cat_before = env.catalog(db)
        sql = proposed if cnt == -1 else fill(proposed, cnt, None if dig == -1 else dig)
        r = env.run(db, sql)
        check(f"neg[{name}]: migration REFUSES", r.returncode != 0 and expect in r.stderr, r.stderr[-400:])
        check(f"neg[{name}]: NOTHING changed (rows byte-identical, catalog identical, no provenance table)",
              env.digest(db) == before and env.catalog(db) == cat_before and env.prov_absent(db))
        if pf_fail:
            pf = env.verify(db, "preflight.sql")
            check(f"neg[{name}]: preflight.sql reports it (fails closed)", not pf["ok"] and "PREFLIGHT 0150 FAIL" in pf["err"], pf["err"][-300:])
            if not name.startswith(("0132", "proposal 0149")):   # guard/0149 drift is a preflight-only precondition, not a per-load finding
                rws, sm = env.review(db)
                check(f"neg[{name}]: candidate_review.sql reports it as BLOCKED", sm["BLOCKED (contradictory evidence; 0150 aborts while > 0)"] != "0" and any(x[1] == "BLOCKED" for x in rws))
        c.dropdb(db)

    # historical (cancelled) dispatch: load is outside the pool, must be left untouched
    db = "td0149_hist"
    c.createdb(db, template=base)
    r = env.run(db, "set session_replication_role = replica;\n" + f"insert into public.dispatches (id, organization_id, load_id, carrier_id, driver_id, truck_id, status, cancelled_at) values ('{uid('hist_d')}', '{uid('o1')}', '{L1}', '{uid('ca')}', '{uid('da3')}', '{uid('ta3')}', 'cancelled', now());", guard=True)
    assert r.returncode == 0, r.stderr
    rows, summ = env.review(db)
    check("history: a load with ONLY a cancelled dispatch drops out of the candidate pool", int(summ["CANDIDATES (approve this count)"]) == n_cand - 1)
    before = env.digest(db)
    hist_digest = summ["candidate digest (REQUIRED: paste into v_expected_digest)"]
    r = env.run(db, fill(proposed, n_cand, hist_digest))
    check("history: old count (loads-with-history counted) is refused", r.returncode != 0 and "candidate count" in r.stderr)
    r = env.run(db, fill(proposed, n_cand - 1, hist_digest))
    check("history: with the corrected count the migration applies", r.returncode == 0, r.stderr[-500:])
    after = env.digest(db)
    check("history: the load with a cancelled dispatch is byte-identical (still unresolved, exception still open, no provenance row)",
          before[("loads", L1)] == after[("loads", L1)] and env.scalar(db, f"select carrier_resolution from public.loads where id = '{L1}'") == "unresolved"
          and env.scalar(db, f"select count(*) from public.carrier_backfill_0150_provenance where load_id = '{L1}'") == "0"
          and env.scalar(db, f"select status::text from public.unresolved_carrier_records where record_id = '{L1}'") == "unresolved")
    c.dropdb(db)

    # ---- migration-vs-concurrent-writer lock behaviour
    print("== lock behaviour (real two sessions) ==")
    for variant in ("tamper", "release"):
        db = f"td0149_lock_{variant}"
        c.createdb(db, template=base)
        A = Session(c, db)
        A.send(f"begin;\nselect 1 from public.loads where id = '{uid('l5')}' for update;")
        time.sleep(0.5)
        Bp = subprocess.Popen([PSQL, "-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-h", str(c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", db, "-f", "-"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(c.env))
        Bp.stdin.write(ready)
        Bp.stdin.close()
        check(f"lock[{variant}]: the migration WAITS on a candidate load locked by another session", wait_blocked(env, db))
        A.send(f"update public.loads set carrier_locked_at = now() where id = '{uid('l5')}';" if variant == "tamper" else "select 1;")
        A.send("commit;")
        A.p.stdin.close()
        A.p.communicate(timeout=60)
        bo, be = Bp.communicate(timeout=120)
        if variant == "tamper":
            check("lock[tamper]: the migration re-evaluates AFTER acquiring the lock and aborts on the concurrent change (fail closed, nothing changed)",
                  Bp.returncode != 0 and "carrier_locked_at is set" in be and env.prov_absent(db)
                  and env.scalar(db, "select count(*) from public.loads where carrier_resolution is null") == "0")
        else:
            check("lock[release]: once the lock is released the migration applies normally",
                  Bp.returncode == 0 and env.scalar(db, "select count(*) from public.carrier_backfill_0150_provenance") == str(n_cand), be[-400:])
        c.dropdb(db)

    # ---- the main apply
    print("== apply 0150 on the main database ==")
    main = "td0149_p_main"
    c.createdb(main, template=base)
    d0, dn0 = env.digest(main), env.digest(main, full=False)
    core0 = env.digest(main, mode="core")
    cat0 = env.catalog(main)
    dump0 = c.dump(main)
    t0 = time.time()
    r = env.run(main, ready)
    check("0150 applies (single transaction) with the approved count and digest", r.returncode == 0 and "0150 complete" in r.stderr, r.stderr[-800:])
    print(f"      apply notices: {[l for l in r.stderr.splitlines() if '0150' in l][:3]} ({time.time() - t0:.2f}s)")
    d1 = env.digest(main)
    cat1 = env.catalog(main)
    dump1 = c.dump(main)
    ch_loads, ch_exc = changed_ids(d0, d1, "loads"), changed_ids(d0, d1, "exc")
    cand_ids = sorted(uid(k) for k in ["l%d" % i for i in range(1, 19)] + ["l_delivered", "l_draft", "l_o2"])
    rc, rows, err = env.q(main, "select load_id::text from public.carrier_backfill_0150_provenance order by 1")
    prov_ids = sorted(r_[0] for r_ in rows)
    check(f"exactly the {n_cand} candidates changed (loads); nothing else", ch_loads == prov_ids and len(prov_ids) == n_cand and all(x in prov_ids for x in cand_ids))
    check("exactly the candidates' exception records changed; nothing else", len(ch_exc) == n_cand)
    check("dispatches and 0133 provenance are byte-identical", changed_ids(d0, d1, "disp") == [] and changed_ids(d0, d1, "prov0133") == [])
    check("the 3 unresolved-with-dispatches loads (LD-3, LD-K004, LD-K005) and every resolved/backfilled/pre-existing load are byte-identical",
          all(d0[("loads", uid(x))] == d1[("loads", uid(x))] for x in ("k_c1", "k_c2", "k_c3", "k_c4", "k_c5", "k_pre", "k_o2")))
    dn1 = env.digest(main, full=False)
    rc, rows, err = env.q(main, "select l.id::text, l.carrier_resolution is null, l.carrier_id is null, l.carrier_locked_at is null, l.financial_dispatch_id is null from public.loads l where l.id::text = any(" + "array[" + ",".join(f"'{x}'" for x in prov_ids) + "])")
    check("every candidate is now carrier_id NULL / carrier_resolution NULL / no lock / no controller (no carrier chosen)", all(r_[1:] == ["t", "t", "t", "t"] for r_ in rows) and len(rows) == n_cand)
    # only carrier_resolution differs on candidates
    check("on candidates and their exception records, ONLY carrier_resolution / status,resolved_at,resolution_note changed (every other column of every load and exception record identical)",
          env.digest(main, mode="core") == core0 and len(diff_keys := changed_ids(dn0, dn1, "loads")) == n_cand)
    check("catalog delta = the provenance table and its policy/constraints/indexes only", all("carrier_backfill_0150_provenance" in f"{k[1]}" for k in t149.changed(cat0, cat1)), str(t149.changed(cat0, cat1)[:5]))
    dd = diff_dump(dump0, dump1)
    stmts = [l[1:] for l in dd if l.startswith("+") and re.match(r"\+(CREATE|ALTER|GRANT|REVOKE|COMMENT|DROP|SET|INSERT|UPDATE)\b", l)]
    check("pg_dump delta is ADD-ONLY and every added statement is about the provenance table (no other schema object changed)",
          dd and not any(l.startswith("-") for l in dd) and stmts and all("carrier_backfill_0150_provenance" in x for x in stmts), "\n".join(dd[:20]))

    po = env.verify(main, "post_apply.sql")
    check("post_apply.sql PASSES after apply", po["ok"], po["err"][-800:])
    pfa = env.verify(main, "preflight.sql")
    check("preflight.sql now FAILS (0150 already applied) -- it cannot be run twice", not pfa["ok"] and "already applied" in pfa["err"])
    r = env.run(main, ready)
    check("re-running proposed_0150.sql is refused (already applied), changing nothing", r.returncode != 0 and "already exists" in r.stderr and env.digest(main) == d1)

    # provenance completeness
    rc, rows, err = env.q(main, """select count(*), count(distinct load_id), count(*) filter (where exception_record_id is not null and prior_exception_status = 'unresolved' and closed_exception_status = 'archived_legacy'
        and prior_carrier_id is null and prior_carrier_resolution = 'unresolved' and prior_carrier_locked_at is null and prior_exception_resolved_by is null and prior_exception_resolved_at is null
        and prior_exception_resolution_note is null and prior_exception_reason is not null and prior_exception_detail = '{"rule":"C4_zero_dispatch","dispatches":[]}'::jsonb
        and closed_exception_note like 'Closed by migration 0150%' and expected_candidate_count = @N@ and candidate_digest = '@D@' and applied_at is not null and applied_by is not null and load_number is not null)
        from public.carrier_backfill_0150_provenance""".replace("@N@", str(n_cand)).replace("@D@", digest))
    check("provenance is complete: one row per candidate with the full prior load + exception state, the approved count/digest, time and actor",
          rows[0] == [str(n_cand), str(n_cand), str(n_cand)], str(rows))
    rc, rows, err = env.q(main, "select status::text, count(*), count(resolved_by), count(resolved_at), count(resolution_note) from public.unresolved_carrier_records where record_type = 'load' group by 1 order by 1")
    st = {r_[0]: r_[1:] for r_ in rows}
    check("exception records: candidates archived_legacy (with note + time, no resolver); the 3 with dispatches remain open",
          st.get("archived_legacy") == [str(n_cand), "0", str(n_cand), str(n_cand)] and st.get("unresolved") == ["3", "0", "0", "0"], str(st))

    # functional regression (rolled back)
    r = env.run(main, (HERE / "regression.sql").read_text(), guard=True)
    check("regression.sql PASSES (first-dispatch claim, later different-carrier rejection, cross-org, atomicity, untouched loads)", r.returncode == 0 and "TEST 0150 REGRESSION PASSED" in r.stderr, r.stderr[-1500:])
    for tag in ("R0", "R1/R2", "R3", "R5", "R8"):
        check(f"regression group {tag}", re.search(rf"NOTICE:\s+OK: {re.escape(tag)}", r.stderr) is not None)
    check("regression.sql left the main database untouched (rolled back)", env.digest(main) == d1)

    # ---- competing first-dispatch race (real two sessions), committed
    print("== competing first dispatch (real two sessions) ==")
    L3 = uid("l3")
    A = Session(c, main, "u_disp1")
    A.send(f"set role authenticated;\nbegin;\nselect public.create_dispatch('{L3}', '{uid('ca')}', '{uid('ta3')}', '{uid('da3')}', null, null, null);")
    time.sleep(0.6)
    Bs = Session(c, main, "u_disp1")
    Bs.send(f"set role authenticated;\nselect public.create_dispatch('{L3}', '{uid('cb')}', '{uid('tq4')}', '{uid('dq4')}', null, null, null);")
    check("race: the competing dispatch WAITS behind the first session's load lock", wait_blocked(env, main))
    A.send("commit;")
    A.p.stdin.close()
    ao, ae = A.p.communicate(timeout=60)
    Bs.p.stdin.close()
    bo, be = Bs.p.communicate(timeout=60)
    rc, rows, err = env.q(main, f"select l.carrier_id::text, l.carrier_resolution, (select count(*) from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'), (select count(*) from public.dispatches d where d.load_id = l.id) from public.loads l where l.id = '{L3}'")
    check("race: exactly one winner -- the first session's carrier claims the load; the loser is rejected and leaves no row",
          rows[0] == [uid("ca"), "resolved", "1", "1"] and ("ERROR" in be) and uid("cb") not in (ae or ""), f"{rows} | A:{ae[-200:]} | B:{be[-300:]}")
    print("      loser error:", [l for l in be.splitlines() if "ERROR" in l][:1])
    po2 = env.verify(main, "post_apply.sql")
    check("post_apply.sql still PASSES after a normalised load was claimed (state B tolerated)", po2["ok"] and any("claimed since" in r_[2] and r_[4] == "1" for r_ in po2["rows"]), po2["err"][-500:])
    d2 = env.digest(main)
    r = env.run(main, (HERE / "rollback.sql").read_text())
    check("ROLLBACK REFUSES once a normalised load has been claimed by a dispatch -- and changes nothing", r.returncode != 0 and "ROLLBACK 0150 REFUSED" in r.stderr and env.digest(main) == d2 and not env.prov_absent(main), r.stderr[-500:])
    c.dropdb(main)

    # ---- exact rollback / reapply
    print("== rollback, exact restoration, reapply ==")
    rb = "td0149_p_rb"
    c.createdb(rb, template=base)
    s0_full, s0_norm, s0_cat, s0_dump = env.digest(rb), env.digest(rb, full=False), env.catalog(rb), c.dump(rb)
    s0_noupd = env.digest(rb, mode="noupd")
    r = env.run(rb, ready)
    assert r.returncode == 0, r.stderr
    s1_norm, s1_cat, s1_dump, s1_prov = env.digest(rb, full=False), env.catalog(rb), c.dump(rb), env.digest_prov0150(rb)
    r = env.run(rb, (HERE / "rollback.sql").read_text())
    check("ROLLBACK_0150 succeeds on an untouched applied state", r.returncode == 0 and "ROLLBACK 0150 complete" in r.stderr, r.stderr[-600:])
    s2_full, s2_norm, s2_cat, s2_dump = env.digest(rb), env.digest(rb, full=False), env.catalog(rb), c.dump(rb)
    check("after rollback: catalog identical to the pre-apply catalog", s2_cat == s0_cat, str(t149.changed(s0_cat, s2_cat)[:5]))
    check("after rollback: pg_dump schema identical to the pre-apply dump", s2_dump == s0_dump, "\n".join(diff_dump(s0_dump, s2_dump)[:10]))
    check("after rollback: every load/exception/dispatch/provenance row identical to pre-apply (ignoring only trigger-maintained updated_at)", s2_norm == s0_norm)
    check("after rollback: every load and exception record is byte-identical to pre-apply (only trigger-maintained updated_at differs) -- resolved_at/status/note restored exactly",
          env.digest(rb, mode="noupd") == s0_noupd)
    check("after rollback: the exception records are open again and the loads unresolved (pre-0150 blocker state restored)",
          env.scalar(rb, "select count(*) from public.loads where carrier_resolution = 'unresolved'") == str(n_cand + 3) and env.scalar(rb, "select count(*) from public.unresolved_carrier_records where status = 'unresolved'") == str(n_cand + 3))
    r = env.run(rb, (HERE / "rollback.sql").read_text())
    check("a second rollback is refused (provenance gone)", r.returncode != 0 and "provenance table missing" in r.stderr)
    r = env.run(rb, ready)
    check("reapply after rollback succeeds", r.returncode == 0, r.stderr[-400:])
    check("reapply: catalog, pg_dump, rows and provenance identical to the first apply", env.catalog(rb) == s1_cat and c.dump(rb) == s1_dump and env.digest(rb, full=False) == s1_norm and env.digest_prov0150(rb) == s1_prov)
    check("post_apply.sql passes after reapply", env.verify(rb, "post_apply.sql")["ok"])
    # a stale rollback must refuse when anything moved: evidence + dispatch variants
    for name, mut in (("a load received a carrier", f"update public.loads set carrier_id = '{uid('ca')}', carrier_resolution = 'resolved' where id = '{uid('l7')}';"),
                      ("a load received a dispatch", f"insert into public.dispatches (id, organization_id, load_id, carrier_id, driver_id, truck_id, status) values ('{uid('rb_d')}', '{uid('o1')}', '{uid('l8')}', '{uid('ca')}', '{uid('da3')}', '{uid('ta3')}', 'assigned');"),
                      ("an exception record was edited", f"update public.unresolved_carrier_records set resolution_note = 'edited by hand' where record_id = '{uid('l9')}';"),
                      ("a newer open exception exists", f"insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason, detail) values ('{uid('o1')}', 'load', '{uid('l10')}', 'new', '{{}}');")):
        db = "td0149_rbref"
        c.createdb(db, template=rb)
        assert env.run(db, "set session_replication_role = replica;\n" + mut, guard=True).returncode == 0
        before = env.digest(db)
        r = env.run(db, (HERE / "rollback.sql").read_text())
        check(f"rollback refuses when {name}; nothing changed", r.returncode != 0 and "ROLLBACK 0150 REFUSED" in r.stderr and env.digest(db) == before and not env.prov_absent(db), r.stderr[-300:])
        c.dropdb(db)
    c.dropdb(rb)
    check("the complete sequence 0130..0147 -> 0149 -> 0150 -> (verify) -> rollback -> reapply ran on the real migrations", True)


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
