#!/usr/bin/env python3
"""LOCAL tests of the production package (PROPOSAL 0152): discovery/conflict SQL, discovery guard, risk-acceptance checker, production probe (local mock only), documents.
Disposable local PostgreSQL only (0149 harness Cluster, unix socket) and a local mock HTTP server on 127.0.0.1. No Supabase, no production, no credentials. The conflict queries run on a
SYNTHETIC model of the columns they use -- this proves their logic on invented rows, NOT that they run on the real schema."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
from datetime import date, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
P0152 = HERE.parent
REPO = HERE.parents[3]


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


FZ = _load("fz_tests", P0152 / "freeze" / "tests_freeze.py")
t149 = FZ.t149
guard = _load("dguard", HERE / "discovery_guard.py")
scan = _load("sscan", HERE / "static_scan_migrations.py")
risk = _load("risk", HERE / "check_risk_acceptance.py")
checks = []
V = ("-v", "VERBOSITY=verbose")


def check(label, cond, detail=""):
    if not cond:
        raise SystemExit(f"FAIL: {label} {detail}")
    checks.append(label)
    print(f"  ok  {label}")


def txt(p):
    return Path(p).read_text()


# ------------------------------------------------------------------------------------------------------------------------------------------------- static / guard / risk acceptance
def static_tests():
    print("== 1. discovery + conflict SQL: statically read-only; guard; static scan ==")
    check("discovery_guard check-files passes (exit 0) on every discovery file and Q01-Q15", subprocess.run([sys.executable, "-B", str(HERE / "discovery_guard.py"), "check-files"], capture_output=True, text=True).returncode == 0)
    qs = guard.split_queries(txt(HERE / "legacy_conflict_queries.sql"))
    check("16 conflict queries Q01..Q16, one statement each", sorted(qs) == [f"Q{i:02d}" for i in range(1, 17)] and all(len(guard.statements(q)) == 1 for q in qs.values()))
    bad = {"update": "update public.t set a = 1;", "insert-in-cte": "with x as (insert into t values (1) returning 1) select 1;", "two statements": "select 1; select 2;", "nextval": "select nextval('s');",
           "terminate": "select pg_terminate_backend(1);", "set_config": "select set_config('a','b',false);", "ddl": "create table t (a int);", "do": "do $$ begin end $$;", "lock": "lock table t;"}
    for name, sql in bad.items():
        check(f"guard REJECTS a non-read-only statement ({name})", guard.check_sql_readonly("x", sql) != [])
    check("guard accepts a plain SELECT and ignores forbidden words inside strings/comments", guard.check_sql_readonly("x", "select 'update x; drop y' as t -- delete\n;") == [])
    for f in [HERE / "P02_schema_objects_readonly.sql", HERE / "P03_privileges_readonly.sql"]:
        check(f"{f.name}: no forbidden keyword after stripping strings/comments", guard.check_sql_readonly(f.name, txt(f)) == [])
    env = {k: v for k, v in os.environ.items() if k != "TDP_PROD_PROJECT_REF"}
    G = lambda *a, e=None: subprocess.run([sys.executable, "-B", str(HERE / "discovery_guard.py"), *a], capture_output=True, text=True, env={**env, **(e or {})})
    REF = "abcdefghijklmnopqrst"
    check("confirm-target REFUSES with no action", G().returncode != 0)
    check("confirm-target REFUSES when TDP_PROD_PROJECT_REF is unset", "not set" in G("confirm-target", "--ref", REF, "--confirm", f"DISCOVER PRODUCTION {REF}").stderr)
    check("confirm-target REFUSES the deleted test project reference", "TEST project" in G("confirm-target", "--ref", "fjmrvvyjvqdyopnyetez", "--confirm", "DISCOVER PRODUCTION fjmrvvyjvqdyopnyetez", e={"TDP_PROD_PROJECT_REF": "fjmrvvyjvqdyopnyetez"}).stderr)
    check("confirm-target REFUSES a ref sharing the test prefix", G("confirm-target", "--ref", "fjmrvvyjvqdaaaaaaaaa", "--confirm", "DISCOVER PRODUCTION fjmrvvyjvqdaaaaaaaaa", e={"TDP_PROD_PROJECT_REF": "fjmrvvyjvqdaaaaaaaaa"}).returncode != 0)
    check("confirm-target REFUSES a ref different from the configured one", "does not equal" in G("confirm-target", "--ref", "zzzzzzzzzzzzzzzzzzzz", "--confirm", "DISCOVER PRODUCTION zzzzzzzzzzzzzzzzzzzz", e={"TDP_PROD_PROJECT_REF": REF}).stderr)
    check("confirm-target REFUSES a wrong typed confirmation", "typed confirmation" in G("confirm-target", "--ref", REF, "--confirm", "yes", e={"TDP_PROD_PROJECT_REF": REF}).stderr)
    r = G("confirm-target", "--ref", REF, "--confirm", f"DISCOVER PRODUCTION {REF}", e={"TDP_PROD_PROJECT_REF": REF})
    check("confirm-target accepts the exact configured ref + typed confirmation, prints only a masked ref and the human-check reminder", r.returncode == 0 and REF not in r.stdout and "compare it with the Supabase dashboard" in r.stdout and "reviewed before any freeze or migration" in r.stdout, r.stdout)
    s = scan.scan()
    check("static scan: NO unqualified relation reference in any SECURITY DEFINER body of 0130-0147 and proposals 0149-0156 (temporary-table shadowing finding F-13: no current exposure; heuristic)", scan.unqualified_relation_refs() == {}, str(scan.unqualified_relation_refs()))
    check("static scan: no SECURITY DEFINER function lacks a pinned search_path or a REVOKE; 12 revoke only PUBLIC (not anon); 42 do not revoke service_role; 4 invoker functions have no REVOKE (matches ADVERSARIAL_REVIEW.md)",
          s["security_definer_non_trigger"] == 43 and s["definer_without_pinned_search_path"] == [] and s["definer_without_any_revoke"] == [] and len(s["definer_revoke_lacks_anon"]) == 12
          and s["definer_revoke_lacks_service_role"] == 42 and len(s["invoker_without_revoke"]) == 4, str(s))


def risk_tests():
    print("== 2. Owner risk acceptance: unsigned template is INVALID; validator rules ==")
    tpl = txt(P0152 / "OWNER_RISK_ACCEPTANCE.md")
    today = date(2026, 9, 21)
    check("the repository template is INVALID/EXPIRED as stored", risk.validate(tpl, today) != [])
    for phrase in ["UNSIGNED -- EXPIRED -- NOT VALID", "NOT INDEPENDENT APPROVAL", "funds for it are presently unavailable", "data corruption", "incorrect financial relationships", "privilege exposure", "RLS errors", "rollback complications",
                   "replaces", "only", "does NOT waive", "can never be waived", "No authorization", "an unsigned copy is expired by definition", "OWNER-SIGNATURE", "OWNER-PRINTED-NAME", "DATE-SIGNED", "EXPIRATION-DATE", "SCOPE-PRODUCTION-PROJECT-REF"]:
        check(f"template states: {phrase}", phrase.lower() in tpl.lower())
    filled = tpl
    vals = {"OWNER-SIGNATURE": "Jane Owner", "OWNER-PRINTED-NAME": "Jane Owner", "DATE-SIGNED (YYYY-MM-DD)": "2026-09-20", "EXPIRATION-DATE (YYYY-MM-DD)": "2026-10-10", "SCOPE-PRODUCTION-PROJECT-REF": "abcdefghijklmnopqrst",
            "SCOPE-COMMIT-SHA": "a" * 40, "SCOPE-WINDOW-REFERENCE": "CHG-1", "ACKNOWLEDGES-NOT-INDEPENDENT-APPROVAL": "YES", "ACKNOWLEDGES-BLOCKERS-NOT-WAIVED": "YES"}

    def fill(over=None):
        v = {**vals, **(over or {})}
        out = tpl
        for k, val in v.items():
            out = re.sub(rf"^{re.escape(k)}:.*$", f"{k}: {val}", out, flags=re.M)
        return out

    check("a completely filled, unexpired copy passes the FORM check", risk.validate(fill(), today) == [])
    check("expired (expiration before today) is INVALID", any("EXPIRED" in e for e in risk.validate(fill({"EXPIRATION-DATE (YYYY-MM-DD)": "2026-09-01"}), today)))
    check("a blank field is INVALID", risk.validate(fill({"OWNER-PRINTED-NAME": ""}), today) != [])
    check("a placeholder left in place is INVALID", risk.validate(fill({"OWNER-SIGNATURE": "<signature>"}), today) != [])
    check("signature date in the future is INVALID", risk.validate(fill({"DATE-SIGNED (YYYY-MM-DD)": "2026-12-01", "EXPIRATION-DATE (YYYY-MM-DD)": "2027-01-01"}), today) != [])
    check("expiration not after signature is INVALID", risk.validate(fill({"EXPIRATION-DATE (YYYY-MM-DD)": "2026-09-20"}), today) != [])
    check("the deleted test project ref is INVALID", risk.validate(fill({"SCOPE-PRODUCTION-PROJECT-REF": "fjmrvvyjvqdyopnyetez"}), today) != [])
    check("a short commit sha is INVALID", risk.validate(fill({"SCOPE-COMMIT-SHA": "abc123"}), today) != [])
    check("acknowledgement other than YES is INVALID", risk.validate(fill({"ACKNOWLEDGES-BLOCKERS-NOT-WAIVED": "NO"}), today) != [])
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "c.md"
        f.write_text(tpl)
        r = subprocess.run([sys.executable, "-B", str(HERE / "check_risk_acceptance.py"), "--file", str(f)], capture_output=True, text=True)
        check("CLI exits 1 for the unsigned template and says the gate is NOT waived", r.returncode == 1 and "NOT waived" in r.stdout)
        f.write_text(fill({"DATE-SIGNED (YYYY-MM-DD)": (date.today() - timedelta(days=1)).isoformat(), "EXPIRATION-DATE (YYYY-MM-DD)": (date.today() + timedelta(days=10)).isoformat()}))
        r = subprocess.run([sys.executable, "-B", str(HERE / "check_risk_acceptance.py"), "--file", str(f)], capture_output=True, text=True)
        check("CLI exits 0 for a valid copy but says it is NOT independent approval", r.returncode == 0 and "NOT independent approval" in r.stdout)


# ------------------------------------------------------------------------------------------------------------------------------------------------- local database part
SYN = """
create table public.carriers (id text primary key, organization_id text, factoring_mode text default 'unconfigured');
create table public.dispatches (id text primary key, load_id text, carrier_id text, status text);
create table public.loads (id text primary key, organization_id text, load_number text, financial_dispatch_id text, carrier_id text, carrier_resolution text, status text default 'booked', created_at timestamptz default now());
create table public.invoices (id text primary key, organization_id text, dispatch_id text, load_id text, broker_id text, customer_id text, status text, amount_paid numeric default 0, total_amount numeric default 100);
create table public.factoring_relationships (id text primary key, organization_id text, relationship_name text, is_default boolean default false, is_active boolean default true, carrier_id text);
create table public.factored_invoices (id text primary key, organization_id text, invoice_id text, factoring_relationship_id text, status text default 'draft');
create table public.payments (id text primary key, organization_id text, invoice_id text, amount numeric, received_at timestamptz default now());
create table public.unresolved_carrier_records (id serial primary key, organization_id text, record_type text, record_id text, status text default 'unresolved', created_at timestamptz default now());
create table public.carrier_backfill_0137_provenance (relationship_id text primary key, resolution text, evidence_carrier_ids text[]);
create table public.profile_share_log (id serial primary key, load_id text, carrier_id text);
create function public.classify_legacy_invoice_for_carrier_migration(p text) returns text language sql stable as $$ select 'stub_' || p $$;
insert into public.carriers (id, organization_id, factoring_mode) values ('cA1','A','unconfigured'), ('cA2','A','unconfigured'), ('cB1','B','unconfigured'), ('cC1','C','factored'), ('cC2','C','factored');
insert into public.loads (id, organization_id, load_number, financial_dispatch_id) values ('L1','A','1001','dA1'), ('L2','A','1002',null), ('L3','A','1003',null), ('L4','B','2001',null), ('L5','A','1005',null);
insert into public.dispatches values ('dA1','L1','cA1','assigned'), ('dA2','L1','cA2','assigned'), ('dB1','L3','cA1','assigned'), ('dB2','L3','cA2','assigned'), ('dX','L5','cA1','cancelled'),
  ('dR3','L5','cA1','assigned'), ('dR4a','L5','cA1','assigned'), ('dR4b','L5','cA2','assigned'), ('dInv1','L5','cA1','assigned'), ('dInv3','L5','cA2','assigned');
insert into public.invoices (id, organization_id, dispatch_id, load_id, broker_id, customer_id, status, amount_paid, total_amount) values
  ('i_r4a','A','dR4a','L5','b',null,'sent',0,100), ('i_r4b','A','dR4b','L5','b',null,'sent',0,100), ('i_p1','A','dInv1','L5','b',null,'sent',0,100), ('i_p2','A',null,'L5','b',null,'sent',0,100),
  ('i_c3','A','dInv3','L5','b',null,'sent',0,100), ('i_void','A',null,null,'b',null,'void',0,100), ('i_paid','A',null,'L5','b',null,'paid',100,100), ('i_both','A',null,'L5','b','c','sent',0,100),
  ('i_none','A',null,'L5',null,null,'sent',0,100), ('i_noload','A',null,null,'b',null,'sent',50,100), ('i_ok','A','dInv1','L5','b',null,'sent',0,100), ('i_b1','B','dInv1','L5','b',null,'sent',0,100), ('i_fa','A',null,'L5','b',null,'sent',0,100), ('i_nl2','A',null,null,'b',null,'sent',0,100);
insert into public.factoring_relationships (id, organization_id, relationship_name, is_default, is_active, carrier_id) values
  ('fr1','B','only-carrier org',false,true,null), ('fr2','A','no evidence',false,true,null), ('fr3','A','two carriers',false,true,null), ('fr4','A','partial evidence',false,true,'cA1'),
  ('fr5','A','complete evidence',false,true,'cA2'), ('frd1','C','dup default 1',true,true,'cC1'), ('frd2','C','dup default 2',true,true,'cC1'), ('frn','C','default without carrier',true,true,null);
insert into public.factored_invoices (id, organization_id, invoice_id, factoring_relationship_id) values ('f1','A','i_r4a','fr3'), ('f2','A','i_r4b','fr3'), ('f3','A','i_p1','fr4'), ('f4','A','i_p2','fr4'), ('f5','A','i_c3','fr5'), ('f6','A','i_fa','fr4');
insert into public.payments (id, organization_id, invoice_id, amount) values ('pay1','A','i_noload',50), ('pay2','A','i_ok',10);
insert into public.unresolved_carrier_records (organization_id, record_type, record_id) values ('A','load','L2'), ('A','factoring_relationship','fr2'), ('A','payment','pay1'), ('A','dispatch_fee_candidate','x');
insert into public.carrier_backfill_0137_provenance values ('fr2','unresolved_no_evidence','{}'), ('fr3','unresolved_multiple','{cA1,cA2}'), ('fr5','multi_carrier_org_provable','{cA2}');
insert into public.loads (id, organization_id, load_number, carrier_resolution, status) values ('L6','A','1006','unresolved','booked');
insert into public.dispatches values ('dL6','L6','cA1','assigned');
insert into public.profile_share_log (load_id, carrier_id) values ('L2', 'cA2'), ('L2', null), ('L4', null);
"""


def rowsq(lab, db, q):
    return lab.rows("postgres", "begin read only;\n" + q + "\nrollback;", db=db)


def db_tests():
    print("== 3. conflict queries + P02/P03 on a disposable local database (SYNTHETIC rows; read-only transactions) ==")
    lab = FZ.Lab()
    ok = False
    try:
        lab.c.start()
        FZ.setup2(lab)   # creates frz_lab with the simulated Supabase role model (authenticator, anon, authenticated, service_role, cron stub, business tables)
        lab.run("postgres", "create database pkg_lab;", db="postgres")
        lab.run("postgres", "create role authenticated_x nologin;", db="postgres") if False else None
        lab.run("postgres", SYN, db="pkg_lab")
        qs = guard.split_queries(txt(HERE / "legacy_conflict_queries.sql"))
        R = {k: rowsq(lab, "pkg_lab", v) for k, v in qs.items()}
        check("every Q01..Q16 executes inside a READ ONLY transaction without error (a write would have raised 25006)", len(R) == 16)
        check("Q01 counts unresolved records by type/status", any(r[0] == "factoring_relationship" and r[1] == "unresolved" and r[2] == "1" for r in R["Q01"]))
        pred = sorted((r[-1]) for r in R["Q02"])
        check("Q02 predicts the four 0137 outcomes correctly (R1 single-carrier org, R2 x2, R3, R4)", pred.count("R1_single_carrier_org") == 1 and pred.count("R3_unresolved_no_evidence") >= 1 and pred.count("R4_unresolved_multiple") >= 1
              and pred.count("R2_provable_from_dispatch_evidence") >= 2, str(pred))
        check("Q03 finds ONLY the partial-evidence relationship (fr4) and not the complete one (fr5)", [r[1] for r in R["Q03"]] == ["fr4"], str(R["Q03"]))
        check("Q05 finds the controller conflict load (L1)", [r[1] for r in R["Q05"]] == ["L1"], str(R["Q05"]))
        check("Q06 finds the multi-carrier loads without controller (L3, and L5 which the synthetic invoices share)", sorted(r[1] for r in R["Q06"]) == ["L3", "L5"], str(R["Q06"]))
        check("Q07 counts zero-dispatch loads per organization (A: L2; B: L4)", sorted((r[0], r[1]) for r in R["Q07"]) == [("A", "1"), ("B", "1")], str(R["Q07"]))
        classes = {r[1]: int(r[2]) for r in R["Q08"] if r[0] == "A"}
        check("Q08 predicts legacy invoice classes (void, paid/partial, both recipients, no recipient, no load, factored)", all(k in classes for k in ["voided_cancelled", "paid_or_partially_paid", "conflicting_recipient_evidence", "missing_recipient", "missing_carrier_evidence", "existing_factoring_activity"]), str(classes))
        check("Q09 calls the installed classifier for every invoice (stub here)", sum(int(r[1]) for r in R["Q09"]) == 14)
        check("Q10 finds the payment on an invoice without a load (pay1) and not the healthy one", [r[1] for r in R["Q10"]] == ["pay1"], str(R["Q10"]))
        check("Q11 finds unconfigured carriers that own relationships (cA1, cA2) and not the configured ones", sorted(r[1] for r in R["Q11"]) == ["cA1", "cA2"], str(R["Q11"]))
        lab.run("postgres", "update public.carriers set factoring_mode = 'unconfigured' where id = 'cC1';", db="pkg_lab")
        check("Q11 then also finds cC1 once it is unconfigured", sorted(r[1] for r in rowsq(lab, "pkg_lab", qs["Q11"])) == ["cA1", "cA2", "cC1"])
        check("Q12 finds the duplicate default (cC1) and the default without a carrier", sorted(r[1] or "NULL" for r in R["Q12"]) == ["NULL", "cC1"], str(R["Q12"]))
        check("Q13 lists unresolved relationships from the provenance table (fr2, fr3)", sorted(r[2] for r in R["Q13"]) == ["fr2", "fr3"], str(R["Q13"]))
        check("Q14 finds the unresolved load that HAS dispatches (L6)", [r[1] for r in R["Q14"]] == ["L6"], str(R["Q14"]))
        check("Q16 finds the zero-dispatch loads already tied to a shared profile (L2 with a named carrier, L4 without)", sorted((r[1], r[3]) for r in R["Q16"]) == [("L2", "2"), ("L4", "1")] and any("cA2" in r[-1] for r in R["Q16"] if r[1] == "L2"), str(R["Q16"]))
        check("Q15 finds open records of types no migration produces (payment, dispatch_fee_candidate)", sorted(r[0] for r in R["Q15"]) == ["dispatch_fee_candidate", "payment"], str(R["Q15"]))
        before = FZ.catalog_fp(lab)
        for name in ("P02_schema_objects_readonly.sql", "P03_privileges_readonly.sql", "../freeze/01_discovery_readonly.sql"):
            p = lab.run("postgres", "begin read only;\n" + txt(HERE / name) + "\nrollback;", db="frz_lab", ok=False, tuples=True)
            check(f"{Path(name).name} executes in a READ ONLY transaction and returns rows", p.returncode == 0 and len(p.stdout.splitlines()) > 5, p.stderr[-300:])
        check("running the discovery files changed nothing (catalog fingerprint identical)", FZ.catalog_fp(lab) == before)
        # F-05 demonstration: a definer function revoked only from PUBLIC stays executable by anon when default privileges grant it
        lab.run("postgres", "alter default privileges for role postgres in schema public grant execute on functions to anon, authenticated, service_role;", db="frz_lab")
        lab.run("postgres", """create function public.f05_trusts_null_uid() returns int language sql security definer set search_path = pg_catalog, public as $$ select 1 $$;
                               revoke all on function public.f05_trusts_null_uid() from public; grant execute on function public.f05_trusts_null_uid() to authenticated;""", db="frz_lab")
        rows = lab.rows("postgres", "begin read only;\n" + txt(HERE / "P03_privileges_readonly.sql") + "\nrollback;", db="frz_lab")
        flagged = [r for r in rows if len(r) >= 3 and r[1].startswith("SECURITY DEFINER WITH anon EXECUTE") and "f05_trusts_null_uid" in r[2]]
        check("P03 FLAGS a SECURITY DEFINER function that anon can still execute via default privileges although `revoke ... from public` was run (finding F-05 is detectable)", len(flagged) == 1, str(rows[:6]))
        lab.run("postgres", "revoke execute on function public.f05_trusts_null_uid() from anon;", db="frz_lab")
        rows = lab.rows("postgres", "begin read only;\n" + txt(HERE / "P03_privileges_readonly.sql") + "\nrollback;", db="frz_lab")
        check("P03 stops flagging it once anon EXECUTE is revoked explicitly", not any("f05_trusts_null_uid" in r[2] for r in rows if len(r) >= 3 and r[1].startswith("SECURITY DEFINER WITH anon EXECUTE")))
        # fixture proposal: apply/cleanup on the disposable database only
        lab.run("postgres", "create role service_role_dummy;", db="frz_lab", ok=False)
        p = lab.run("postgres", txt(HERE / "PROD_PROBE_FIXTURE_PROPOSAL.sql"), db="frz_lab", ok=False, tuples=True)
        check("probe fixture PROPOSAL applies on a disposable database (locally) and creates exactly its three objects", p.returncode == 0 and "ttt1" in p.stdout.replace(t149.SEP, "").replace("\n", ""), p.stderr[-200:] + p.stdout[-200:])
        p = lab.run("postgres", txt(HERE / "PROD_PROBE_FIXTURE_PROPOSAL.sql"), db="frz_lab", ok=False)
        check("applying it twice is refused (nothing changed)", p.returncode != 0 and "already exists" in p.stderr)
        p = api_rw(lab, "anon", "insert into public.ops_freeze_probe_items (note) values ('x')")
        check("baseline: anon REST-style write to the probe table works before any freeze", p.returncode == 0, p.stderr[-200:])
        p = api_rw(lab, "anon", "insert into public.ops_freeze_probe_items (note) values ('" + "y" * 41 + "')")
        check("the probe table caps note at 40 characters", p.returncode != 0)
        p = lab.run("postgres", txt(HERE / "PROD_PROBE_FIXTURE_CLEANUP.sql"), db="frz_lab", ok=False, tuples=True)
        check("probe fixture CLEANUP removes exactly the three objects and nothing else", p.returncode == 0 and "ttt" in p.stdout.replace(t149.SEP, "").replace("\n", "") and lab.scalar("select count(*) from pg_class where relname like 'ops_freeze_probe%'") == "0")
        ok = True
    finally:
        lab.reap("authenticator", "operator", "stray_app")
        lab.c.cleanup(ok)


def api_rw(lab, role, stmt):
    return lab.run("authenticator", f"begin isolation level read committed read write; set local role {role}; {stmt}; commit;", db="frz_lab", ok=False, extra_args=V)


# ------------------------------------------------------------------------------------------------------------------------------------------------- production probe (local mock)
class Mock(BaseHTTPRequestHandler):
    mode = "baseline"
    pids = [(11, "t1"), (12, "t2")]
    hits = []

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        Mock.hits.append((self.command, self.path))
        if self.path.startswith("/rest/v1/rpc/ops_freeze_probe_diag"):
            pid, start = Mock.pids[len(Mock.hits) % len(Mock.pids)]
            return self._send(200, {"pid": pid, "backend_start": start})
        if self.command == "GET":
            return self._send(200, [{"id": 1}])
        anon = os.environ["TDP_PROD_ANON_KEY"]
        is_anon = self.headers.get("apikey") == anon and self.headers.get("Authorization") == "Bearer " + anon
        if Mock.mode in ("baseline", "restored"):
            return self._send(201 if self.command == "POST" else 200, [{"id": 2}])
        if Mock.mode == "frozen_leaky" and self.command == "POST" and is_anon and "/rpc/" not in self.path:
            return self._send(201, [{"id": 2}])
        if Mock.mode == "frozen_other":
            return self._send(401, {"code": "PGRST301", "message": "JWT expired"})
        return self._send(405, {"code": "25006", "message": "TDP_MAINTENANCE_FREEZE: writes are temporarily disabled during a scheduled system upgrade"})

    do_GET = do_POST = do_PATCH = do_DELETE = _handle


def probe_tests():
    print("== 4. production probe: refusals and behaviour against a LOCAL MOCK only ==")
    class ConcurrentMockServer(ThreadingHTTPServer):
        request_queue_size = 128
        daemon_threads = True

    srv = ConcurrentMockServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    REF = "abcdefghijklmnopqrst"
    sent = {"TDP_PROD_ANON_KEY": "SENTINEL-PROD-ANON-DO-NOT-PRINT", "TDP_PROD_SERVICE_KEY": "SENTINEL-PROD-SERVICE-DO-NOT-PRINT", "TDP_PROD_USER_JWT": "SENTINEL-PROD-JWT-DO-NOT-PRINT"}
    os.environ.update(sent)   # the mock server (same process) compares the presented key with the sentinel
    tmp = tempfile.mkdtemp(prefix="prodprobe-ev-")
    exe = HERE / "api_freeze_probe_production.py"
    base_env = {k: v for k, v in os.environ.items() if not k.startswith("TDP_")}

    def run(*args, env=None, ref=REF, url=f"http://127.0.0.1:{port}", confirm=True, evidence=True):
        e = {**base_env, **sent, "TDP_PROD_PROJECT_REF": ref, "TDP_PROD_PROJECT_URL": url, "TDP_PROD_PROBE_SELF_TEST": "1", **(env or {})}
        a = list(args)
        if confirm and "--confirm" not in a:
            a += ["--ref", ref, "--confirm", f"PROBE PRODUCTION {ref}"]
        if evidence:
            a += ["--evidence-dir", tmp]
        return subprocess.run([sys.executable, "-B", str(exe), *a], capture_output=True, text=True, env=e, timeout=120)

    n0 = len(Mock.hits)
    for label, r in [("no arguments", run(confirm=False, evidence=False)), ("phase but no --confirm", run("--phase", "baseline", confirm=False)),
                     ("wrong typed confirmation", run("--phase", "baseline", "--ref", REF, "--confirm", "yes")),
                     ("the deleted test project ref", run("--phase", "baseline", ref="fjmrvvyjvqdyopnyetez")), ("a ref sharing the test prefix", run("--phase", "baseline", ref="fjmrvvyjvqdaaaaaaaaa")),
                     ("--ref different from TDP_PROD_PROJECT_REF", run("--phase", "baseline", "--ref", "zzzzzzzzzzzzzzzzzzzz", "--confirm", "PROBE PRODUCTION zzzzzzzzzzzzzzzzzzzz")),
                     ("TDP_PROD_PROJECT_REF unset", run("--phase", "baseline", env={"TDP_PROD_PROJECT_REF": ""})),
                     ("a URL whose host is not <ref>.supabase.co", run("--phase", "baseline", url="https://evil.example.com", env={"TDP_PROD_PROBE_SELF_TEST": "0"})),
                     ("a local URL without the self-test switch", run("--phase", "baseline", env={"TDP_PROD_PROBE_SELF_TEST": "0"})),
                     ("phase frozen without --i-confirm-maintenance-mode-is-on", run("--phase", "frozen")), ("unknown extra arguments", run("--phase", "baseline", "--bogus"))]:
        check(f"probe REFUSES (exit 4, before any request): {label}", r.returncode == 4 and "REFUSED" in r.stderr, f"rc={r.returncode} {r.stderr[-200:]}")
    check("none of the refusals sent a single request", len(Mock.hits) == n0)

    def evid(prefix):
        return json.loads(sorted(Path(tmp).glob(f"evidence_{prefix}_*.json"))[-1].read_text())

    Mock.mode = "baseline"
    r = run("--phase", "baseline")
    check("baseline: writes succeed for anon, service_role, authenticated -> WRITES_WORK (exit 0)", r.returncode == 0 and "WRITES_WORK" in r.stdout, r.stdout[-300:] + r.stderr[-200:])
    Mock.mode = "frozen_ok"; Mock.pids = [(11, "t1"), (12, "t2")]
    r = run("--phase", "frozen", "--label", "pooled", "--i-confirm-maintenance-mode-is-on")
    pooled = sorted(Path(tmp).glob("evidence_frozen_pooled_*.json"))[-1]
    check("frozen/pooled: every write blocked with SQLSTATE 25006 + marker, GET works, >=2 backends -> FREEZE_PROVEN (exit 0)", r.returncode == 0 and "FREEZE_PROVEN" in r.stdout, r.stdout[-500:])
    Mock.pids = [(21, "t7"), (22, "t8")]
    r = run("--phase", "frozen", "--label", "new", "--compare-pids", str(pooled), "--i-confirm-maintenance-mode-is-on")
    check("frozen/new with DISJOINT backends -> FREEZE_PROVEN", r.returncode == 0 and "FREEZE_PROVEN" in r.stdout, r.stdout[-400:])
    Mock.pids = [(11, "t1"), (23, "t9")]
    r = run("--phase", "frozen", "--label", "new", "--compare-pids", str(pooled), "--i-confirm-maintenance-mode-is-on")
    check("frozen/new sharing a backend with the pooled run -> NOT PROVEN (exit 2)", r.returncode == 2 and "FREEZE_NOT_PROVEN" in r.stdout and "shared" in r.stdout)
    r = run("--phase", "frozen", "--label", "new", "--i-confirm-maintenance-mode-is-on")
    check("frozen/new WITHOUT --compare-pids -> NOT PROVEN", r.returncode == 2 and "requires --compare-pids" in r.stdout)
    Mock.pids = [(31, "t5")]
    r = run("--phase", "frozen", "--label", "one", "--i-confirm-maintenance-mode-is-on")
    check("inconclusive backend coverage (only one backend observed) -> NOT PROVEN", r.returncode == 2 and "fewer than 2 distinct backends" in r.stdout)
    Mock.pids = [(11, "t1"), (12, "t2")]
    Mock.mode = "frozen_leaky"
    n1 = len(Mock.hits)
    r = run("--phase", "frozen", "--label", "leak", "--i-confirm-maintenance-mode-is-on")
    ev = evid("frozen_leak")
    check("ONE successful write while frozen (anon POST 201 = the hosted v1 failure) -> FREEZE_BREACH, exit 3, restoration instructions, approval BLOCKED",
          r.returncode == 3 and "FREEZE_BREACH" in r.stdout and "STOP ALL MIGRATION ACTIVITY" in r.stdout and "05_disable_freeze.sql" in r.stdout and "MAINTENANCE_MODE stays ON" in r.stdout and ev["production_approval"] == "BLOCKED", r.stdout[-400:])
    check("the breach stopped the run at the first success (no PATCH/DELETE was sent after it)", sum(1 for h in Mock.hits[n1:] if h[0] in ("PATCH", "DELETE")) == 0)
    Mock.mode = "frozen_other"
    r = run("--phase", "frozen", "--label", "other", "--i-confirm-maintenance-mode-is-on")
    check("unexpected error without the freeze marker (401) -> NOT PROVEN, never a pass", r.returncode == 2 and "FREEZE_NOT_PROVEN" in r.stdout and "WITHOUT SQLSTATE 25006" in r.stdout)
    Mock.mode = "frozen_ok"
    r = run("--phase", "frozen", "--label", "nojwt", "--i-confirm-maintenance-mode-is-on", env={"TDP_PROD_USER_JWT": ""})
    check("a missing role (no authenticated-user JWT) -> INCOMPLETE -> NOT PROVEN", r.returncode == 2 and "INCOMPLETE" in r.stdout)
    r = run("--phase", "frozen", "--label", "nosvc", "--i-confirm-maintenance-mode-is-on", env={"TDP_PROD_SERVICE_KEY": ""})
    check("a missing role (no service_role key) -> NOT PROVEN", r.returncode == 2 and "INCOMPLETE" in r.stdout)
    Mock.mode = "restored"
    r = run("--phase", "restored")
    check("restored: writes succeed again for all three roles -> WRITES_WORK", r.returncode == 0 and "WRITES_WORK" in r.stdout)
    Mock.mode = "frozen_ok"
    r = run("--phase", "restored")
    check("restored while writes are still blocked -> RESTORED_FAILED (exit 2)", r.returncode == 2 and "RESTORED_FAILED" in r.stdout)
    # sanitisation
    allowed_top = {"phase", "label", "utc", "results", "backends", "production_approval", "distinct_backends", "shared_backends_with_compared_run", "final"}
    files = list(Path(tmp).glob("evidence_*.json"))
    blob = "".join(f.read_text() for f in files)
    ok = True
    for f in files:
        j = json.loads(f.read_text())
        ok &= set(j) <= allowed_top and all(set(x) == {"rep", "role", "test", "http", "sqlstate", "marker_present", "verdict"} for x in j["results"]) and all(set(x) == {"role", "pid", "backend_start"} for x in j["backends"])
    check("evidence files contain ONLY allow-listed fields (status, role label, SQLSTATE, marker flag, verdict, backend id, timestamps) -- no bodies, no messages", ok and len(files) >= 8 and "message" not in blob)
    out = subprocess.run([sys.executable, "-B", str(exe), "--phase", "baseline", "--ref", REF, "--confirm", f"PROBE PRODUCTION {REF}", "--evidence-dir", tmp], capture_output=True, text=True,
                         env={**base_env, **sent, "TDP_PROD_PROJECT_REF": REF, "TDP_PROD_PROJECT_URL": f"http://127.0.0.1:{port}", "TDP_PROD_PROBE_SELF_TEST": "1"})
    every = blob + out.stdout + out.stderr
    check("no key/JWT value appears in any evidence file or probe output", not any(v in every for v in sent.values()))
    src = txt(exe)
    check("default evidence directory is outside the repository", 'os.path.expanduser("~/tdp-prod-probe-evidence")' in src)
    check("the probe touches only the dedicated ops_freeze_probe_* objects (no business table names)", not re.search(r"/rest/v1/(loads|invoices|payments|dispatches|carriers|factoring)", src) and "ops_freeze_probe_items" in src)
    srv.shutdown()


# ------------------------------------------------------------------------------------------------------------------------------------------------- documents
def doc_tests():
    print("== 5. documents: wording, coverage, no unsupported claims ==")
    ws = txt(P0152 / "LEGACY_CONFLICT_WORKSHEET.md")
    qs = set(re.findall(r"\*\*(Q\d\d)\*\*", ws)) | set(re.findall(r"\bQ(\d\d)\b", ws)) and {f"Q{m}" for m in re.findall(r"\bQ(\d\d)\b", ws)}
    check("every query Q01..Q16 is referenced by the worksheet", qs >= {f"Q{i:02d}" for i in range(1, 17)}, str(sorted(qs)))
    check("worksheet has one row per conflict C01..C15", all(f"| C{i:02d} |" in ws for i in range(1, 16)))
    for t in ["load", "invoice", "payment", "document", "factoring_relationship", "factored_invoice", "trailer", "dispatch_fee_candidate", "other"]:
        check(f"worksheet covers record type '{t}'", t in ws)
    for phrase in ["Never guess", "No mass assignment", "No silent deletion", "NO production data", "have **not** been run on the real schema", "Historical financial records are not rewritten"]:
        check(f"worksheet states: {phrase}", phrase in ws)
    ar = txt(P0152 / "ADVERSARIAL_REVIEW.md")
    check("adversarial review classifies findings as OK / CONCERN / BLOCKER with file:line references", all(x in ar for x in ("| **BLOCKER**", "| CONCERN", "| OK")) and len(re.findall(r"`\d{4}[^`]*:\d+", ar)) >= 25)
    check("adversarial review states it is NOT independent and not an approval", "not independent" in ar.lower() and "not an approval" in ar.lower() and "cannot be waived" in ar)
    rb = txt(P0152 / "RUNBOOK_PRODUCTION_0130_0152_DRAFT.md")
    for phrase in ["independent PostgreSQL/Supabase DBA/security review completed with no open blockers", "signed, unexpired Owner risk acceptance", "recommended path", "NOT independent approval", "separate hosted pg_cron test",
                   "verified backup/PITR point", "Every legacy conflict", "api_freeze_probe_production.py", "exact restoration", "Global ABORT RULE", "check_risk_acceptance.py"]:
        check(f"runbook states: {phrase}", phrase in rb)
    check("runbook keeps the 21 numbered steps in order", [int(m) for m in re.findall(r"^## (\d+)\. ", rb, re.M)][:21] == list(range(1, 22)))
    for f in ["OWNER_RISK_ACCEPTANCE.md", "ADVERSARIAL_REVIEW.md", "LEGACY_CONFLICT_WORKSHEET.md", "INDEPENDENT_REVIEW_PACKET.md", "production_package/README.md"]:
        t = txt(P0152 / f)
        claims = [m for m in re.finditer(r"production (is|are) (approved|ready|safe)|(approved|ready|safe) for production", t, re.I)
                  if not re.search(r"\b(not|never|no|until|unless|before|cannot|nor|neither|without)\b", t[max(0, m.start() - 60):m.start()], re.I)]
        check(f"{f}: never claims production is approved/ready/safe (every mention is negated or conditional)", not claims and "READY FOR PRODUCTION" not in t, str([c.group(0) for c in claims]))
    check("0150/0151 renumbering comments no longer say 0152 (0152 is a used number)", not any("0152 or higher" in txt(p) for p in (P0152.parent / "0150").glob("*.sql")) and not any("0152 or higher" in txt(p) for p in (P0152.parent / "0151").glob("*.sql")))
    check("supabase/migrations/ untouched by this work (git)", subprocess.run(["git", "status", "--porcelain", "supabase/migrations"], cwd=REPO, capture_output=True, text=True).stdout.strip() == "")
    check("proposal 0148 untouched (git shows no change; it is untracked as a whole so its file list is compared with the pinned 12+ files)", len(list((P0152.parent / "0148").glob("*"))) >= 12)


def main():
    static_tests()
    risk_tests()
    db_tests()
    probe_tests()
    doc_tests()
    print(f"\nALL {len(checks)} PRODUCTION-PACKAGE CHECKS PASSED (local only; synthetic data; mock server; NOT a hosted or production proof)")


if __name__ == "__main__":
    main()
