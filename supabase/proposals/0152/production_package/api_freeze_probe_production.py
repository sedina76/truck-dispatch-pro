#!/usr/bin/env python3
"""PRODUCTION external API freeze probe (PROPOSAL 0152). NOT RUN. Standard library only. DEFAULT = REFUSE.

It runs ONLY against the dedicated probe objects (public.ops_freeze_probe_items, public.ops_freeze_probe_write(), public.ops_freeze_probe_diag()) that must first be created by an
Owner-approved, separately reviewed change (PROD_PROBE_FIXTURE_PROPOSAL.sql, NOT applied). It never touches a business table.

Refusals (exit 4, before any network request): no arguments; no --confirm; a confirmation that is not exactly 'PROBE PRODUCTION <ref>'; TDP_PROD_PROJECT_REF unset or not a 20-character ref;
the deleted temporary TEST project ref or anything starting with its prefix; --ref different from the configured ref; TDP_PROD_PROJECT_URL whose host is not exactly <ref>.supabase.co;
phase 'frozen' without --i-confirm-maintenance-mode-is-on, except the separately confirmed, non-production F-30 database-only path.
Secrets: keys/JWTs come ONLY from TDP_PROD_ANON_KEY / TDP_PROD_SERVICE_KEY / TDP_PROD_USER_JWT, are never printed, never stored, and every printed/stored string is scrubbed.
Evidence (written OUTSIDE the repository, default ~/tdp-prod-probe-evidence): allow-listed fields only -- phase, label, UTC time, role label, test name, HTTP status, SQLSTATE, marker_present
(boolean), verdict, backend pid + backend_start (needed to prove pooled-vs-new), final result. No response bodies, no messages, no keys, no tokens.
Frozen success requires: GET 200 for every role; POST/PATCH/DELETE/writable RPC blocked (SQLSTATE 25006 + exact marker TDP_MAINTENANCE_FREEZE) for anon, authenticated AND service_role;
>= 2 distinct backends observed; for label 'new': --compare-pids given and ZERO shared backends. ANY 2xx write while frozen = FREEZE_BREACH: stop at once, exit 3, print restoration steps.
Missing role/key/JWT, an error without the marker, network failure or inconclusive backend coverage = NOT PROVEN (exit 2). Restored/baseline: every write must succeed.
Optional --role-model is NON-PRODUCTION ONLY and additionally requires the pinned synthetic fixture, its marker, and the 14 named synthetic identities; see role_fixture/README.md.
TDP_F30_NULL_JWT is OPTIONAL: no ordinary Supabase Auth flow can issue a subject-less session, so its absence no longer blocks the 14 named identities (which still run and are
evaluated with every existing assertion, unrelaxed) -- it is instead recorded, explicitly, as a top-level "null_identity_status":"not_proven" field in the evidence file, plus a
printed F30_NULL_IDENTITY_NOT_PROVEN line, rather than refusing the whole run or omitting the gap from the record. On a PASS, the evidence file's top-level
"role_model_summary" field (and a matching printed line) distinguishes F30_ROLE_MODEL_FULLY_PROVEN (14 identities + null case) from
F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN (14 identities only) -- see role_fixture/probe.py's summary_verdict().
For a dedicated nonproduction F-30 database with no verified app deployment, the separately confirmed
--i-confirm-f30-database-only-freeze path requires --role-model --phase frozen and typed
'PROBE F30 DATABASE ONLY <ref>'. It records app_maintenance_mode=NOT_TESTED and returns
F30_DATABASE_FREEZE_PROVEN on success. It never replaces the production maintenance confirmation."""
import argparse
import importlib.util
from pathlib import Path
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlparse

sys.dont_write_bytecode = True
DELETED_TEST_REF = "fjmrvvyjvqdyopnyetez"
TEST_PREFIX = "fjmrvvyjvqd"
MARKER = "TDP_MAINTENANCE_FREEZE"
KEYS = ("TDP_PROD_ANON_KEY", "TDP_PROD_SERVICE_KEY", "TDP_PROD_USER_JWT")
PRODUCTION_REF = "zteixenjpcygjvznueuo"
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}(?:\.[A-Za-z0-9_\-]*)?")
TABLE, RPC_WRITE, RPC_DIAG = "ops_freeze_probe_items", "ops_freeze_probe_write", "ops_freeze_probe_diag"
EVIDENCE_KEYS = {"rep", "role", "test", "http", "sqlstate", "marker_present", "verdict"}


def scrub(text):
    text = str(text)
    for k in (*KEYS, *(n for n in os.environ if n.startswith("TDP_F30_") and n.endswith("_JWT"))):
        v = os.environ.get(k)
        if v:
            text = text.replace(v, "[redacted]")
    return JWT_RE.sub("[redacted-jwt]", text)


def say(msg=""):
    print(scrub(msg))


def refuse(msg):
    print("REFUSED: " + scrub(msg), file=sys.stderr)
    sys.exit(4)


def guard(a):
    ref = os.environ.get("TDP_PROD_PROJECT_REF", "").strip().lower()
    db_only = getattr(a, "i_confirm_f30_database_only_freeze", False)
    if not a.confirm:
        refuse("--confirm is required (exactly 'PROBE PRODUCTION <ref>'). Nothing was sent.")
    if not re.fullmatch(r"[a-z0-9]{20}", ref):
        refuse("TDP_PROD_PROJECT_REF must be set to the explicit 20-character production project reference. Nothing was sent.")
    if ref == DELETED_TEST_REF or ref.startswith(TEST_PREFIX):
        refuse("that reference is the deleted temporary TEST project (or shares its prefix). Nothing was sent.")
    if (a.ref or "").strip().lower() != ref:
        refuse("--ref must equal TDP_PROD_PROJECT_REF. Nothing was sent.")
    if db_only:
        if a.phase != "frozen" or not getattr(a, "role_model", False):
            refuse("database-only confirmation requires --role-model --phase frozen. Nothing was sent.")
        if getattr(a, "i_confirm_maintenance_mode_is_on", False):
            refuse("database-only and app-maintenance confirmations cannot be combined. Nothing was sent.")
        if ref == PRODUCTION_REF:
            refuse("the database-only path refuses the production project. Nothing was sent.")
        if a.confirm != f"PROBE F30 DATABASE ONLY {ref}":
            refuse(f"the typed confirmation must be exactly 'PROBE F30 DATABASE ONLY {ref}'. Nothing was sent.")
    elif a.confirm != f"PROBE PRODUCTION {ref}":
        refuse(f"the typed confirmation must be exactly 'PROBE PRODUCTION {ref}'. Nothing was sent.")
    url = os.environ.get("TDP_PROD_PROJECT_URL", "").strip().rstrip("/")
    u = urlparse(url)
    host = (u.hostname or "").lower()
    if not (host in ("127.0.0.1", "localhost") and os.environ.get("TDP_PROD_PROBE_SELF_TEST") == "1"):
        if u.scheme != "https" or host != f"{ref}.supabase.co":
            refuse("TDP_PROD_PROJECT_URL must be exactly https://<ref>.supabase.co for the configured reference. Nothing was sent.")
    if a.phase == "frozen" and not (getattr(a, "i_confirm_maintenance_mode_is_on", False) or db_only):
        refuse("phase 'frozen' requires --i-confirm-maintenance-mode-is-on (MAINTENANCE_MODE=1 is deployed and the DB freeze is enabled). Nothing was sent.")
    if getattr(a, "role_model", False):
        try:
            role_model().validate_target(ref, os.environ)
        except ValueError as exc:
            refuse(str(exc) + ". Nothing was sent.")
    return url


def role_model():
    spec = importlib.util.spec_from_file_location("f30_role_probe", Path(__file__).parent / "role_fixture" / "probe.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def request(base, method, path, key, bearer=None, body=None, timeout=20):
    headers = {"apikey": key, "Authorization": "Bearer " + (bearer or key), "Content-Type": "application/json", "Prefer": "return=minimal" if method != "GET" and "rpc" not in path else "return=representation"}
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, f"NETWORK_ERROR {type(e).__name__}"


def code_and_marker(body):
    try:
        j = json.loads(body)
        if isinstance(j, dict):
            return str(j.get("code", ""))[:8], str(j.get("message", "")).startswith(MARKER)
    except Exception:
        pass
    return "", False


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--role-model", action="store_true", help="Require the guarded non-production synthetic role fixture in addition to the generic probe")
    ap.add_argument("--phase", choices=["baseline", "frozen", "restored"])
    ap.add_argument("--label", default="run")
    ap.add_argument("--burst", type=int, default=5)
    ap.add_argument("--compare-pids")
    ap.add_argument("--ref")
    ap.add_argument("--confirm")
    ap.add_argument("--i-confirm-maintenance-mode-is-on", action="store_true", dest="i_confirm_maintenance_mode_is_on")
    ap.add_argument("--i-confirm-f30-database-only-freeze", action="store_true", dest="i_confirm_f30_database_only_freeze")
    ap.add_argument("--evidence-dir", default=os.path.expanduser("~/tdp-prod-probe-evidence"))
    a, extra = ap.parse_known_args()
    if extra or not a.phase:
        refuse("no/unknown arguments. This tool refuses by default; see the module docstring. Nothing was sent.")
    base = guard(a)
    anon, svc, jwt = (os.environ.get(k) for k in KEYS)
    say(f"target reference {os.environ['TDP_PROD_PROJECT_REF'][:4]}...{os.environ['TDP_PROD_PROJECT_REF'][-4:]}  phase={a.phase} label={a.label}")
    roles = [("anon", anon, None), ("service_role", svc, None), ("authenticated", anon, jwt)]
    db_only = a.i_confirm_f30_database_only_freeze
    ev = {"phase": a.phase, "label": a.label, "utc": datetime.now(timezone.utc).isoformat(), "results": [], "backends": [], "production_approval": "PENDING (this probe alone never grants approval)"}
    if db_only:
        ev["probe_scope"] = "F30_NONPRODUCTION_DATABASE_ONLY"
        ev["app_maintenance_mode"] = "NOT_TESTED"
        say("F30_DATABASE_ONLY: app MAINTENANCE_MODE was NOT TESTED; this run cannot establish production readiness.")
    incomplete = [n for n, k, b in roles if not k or (n == "authenticated" and not b)]
    for n in incomplete:
        say(f"INCOMPLETE: no key/JWT supplied for role '{n}' -- that role cannot be tested")
    if a.role_model:
        if incomplete:
            return finish(ev, a, "F30_IDENTITIES_INCOMPLETE", 2)
        role_module = role_model()
        result = role_module.run(request, base, a.phase, os.environ, os.environ["TDP_PROD_PROJECT_REF"])
        ev["role_model"] = result
        ev["null_identity_status"] = result.get("null_identity_status", "not_attempted")  # top-level, explicit, easy to grep in the evidence file -- not just nested
        if ev["null_identity_status"] == "not_proven":
            say("F30_NULL_IDENTITY_NOT_PROVEN: TDP_F30_NULL_JWT was not supplied. The null-identity REST case was NOT attempted this run (recorded as NOT_PROVEN "
                "in the evidence file, not silently omitted). The 14 named identities ran and were evaluated normally, with no assertion relaxed.")
        if result["verdict"] != "PASS":
            final = "FREEZE_BREACH" if result["verdict"] == "BREACH" else "F30_ROLE_MODEL_NOT_PROVEN"
            say(final + ": STOP. Restore with 05_disable_freeze.sql and verify with 06_verify_disable.sql before cleanup.")
            return finish(ev, a, final, 3 if result["verdict"] == "BREACH" else 2)
        # PASS: still one of two distinct outcomes -- give it an explicit, unmistakable summary line and evidence field rather than saying nothing
        # (existing 'verdict'/'null_identity_status' fields and every assertion on them are unchanged; this only ADDS a label on top of them).
        ev["role_model_summary"] = role_module.summary_verdict(result)
        if ev["role_model_summary"] == "F30_ROLE_MODEL_FULLY_PROVEN":
            say("F30_ROLE_MODEL_FULLY_PROVEN: all 14 named identities AND the null-identity REST case passed every assertion.")
        else:
            say(f"{ev['role_model_summary']}: all 14 named identities passed every assertion; the null-identity REST case was NOT_PROVEN this run "
                "(see F30_NULL_IDENTITY_NOT_PROVEN above). This is NOT full proof of the role model.")
    backends = set()

    def diag(tag, key, bearer):
        s, b = request(base, "POST", f"/rest/v1/rpc/{RPC_DIAG}", key, bearer, {})
        try:
            j = json.loads(b)
            j = j[0] if isinstance(j, list) and j else j
            backends.add((int(j["pid"]), str(j["backend_start"])))
            ev["backends"].append({"role": tag, "pid": int(j["pid"]), "backend_start": str(j["backend_start"])})
        except Exception:
            pass

    tests = []
    for n, k, b in roles:
        if not k or (n == "authenticated" and not b):
            continue
        tests += [(n, "GET readable", "GET", f"/rest/v1/{TABLE}?select=id&limit=1", k, b, None, "read"),
                  (n, "POST insert", "POST", f"/rest/v1/{TABLE}", k, b, {"note": f"probe-{a.phase}-{n}"}, "write"),
                  (n, "PATCH update", "PATCH", f"/rest/v1/{TABLE}?note=eq.seed", k, b, {"note": "seed"}, "write"),
                  (n, "DELETE delete", "DELETE", f"/rest/v1/{TABLE}?note=like.probe-*", k, b, None, "write"),
                  (n, "RPC writable SECURITY DEFINER", "POST", f"/rest/v1/rpc/{RPC_WRITE}", k, b, {}, "write")]
    fail = inconclusive = 0
    for rep in range(max(1, a.burst)):
        for n, name, method, path, k, b, body, kind in tests:
            if kind == "read" and rep > 0:
                continue
            if name == "POST insert":
                diag(n, k, b)
            s, resp = request(base, method, path, k, b, body)
            code, marker = code_and_marker(resp) if (s >= 400 or s == 0) else ("", False)
            ok2xx = 200 <= s < 300
            if kind == "read":
                verdict = "PASS" if ok2xx else "FAIL"
            elif a.phase == "frozen":
                verdict = "BREACH" if ok2xx else ("BLOCKED" if code == "25006" and marker else "INCONCLUSIVE")
            else:
                verdict = "PASS" if ok2xx else "FAIL"
            row = {"rep": rep, "role": n, "test": name, "http": s, "sqlstate": code, "marker_present": marker, "verdict": verdict}
            assert set(row) == EVIDENCE_KEYS
            ev["results"].append(row)
            say(f"  [{rep}] {n:14s} {name:30s} HTTP {s:<3d} {code:6s} marker={str(marker):5s} -> {verdict}")
            if verdict == "BREACH":
                say("\nFREEZE_BREACH: a write SUCCEEDED while the freeze is enabled. STOPPING NOW.")
                say("  1. STOP ALL MIGRATION ACTIVITY.  2. Restore: 05_disable_freeze.sql (or EMERGENCY_UNFREEZE.sql), 06_verify_disable.sql, then --phase restored.")
                say("  3. Keep the evidence file; production approval is BLOCKED; " +
                    ("app MAINTENANCE_MODE was NOT TESTED." if db_only else "MAINTENANCE_MODE stays ON."))
                ev["production_approval"] = "BLOCKED"
                return finish(ev, a, "FREEZE_BREACH", 3)
            fail += verdict == "FAIL"
            inconclusive += verdict == "INCONCLUSIVE"
    say(f"distinct backends observed: {len(backends)}")
    ev["distinct_backends"] = len(backends)
    reasons = []
    if a.phase == "frozen":
        if a.label == "new" and not a.compare_pids:
            reasons.append("label 'new' requires --compare-pids (the pooled evidence file)")
        if a.compare_pids:
            try:
                old = json.load(open(a.compare_pids))
                old_set = {(int(x["pid"]), str(x["backend_start"])) for x in old["backends"]}
                shared = backends & old_set
                ev["shared_backends_with_compared_run"] = len(shared)
                if shared or not old_set:
                    reasons.append(f"{len(shared)} backend(s) shared with the compared run (or it had none)")
            except Exception:
                reasons.append("could not read --compare-pids file")
        if len(backends) < 2:
            reasons.append("fewer than 2 distinct backends observed (inconclusive coverage; raise --burst or install the diag function)")
        if incomplete:
            reasons.append("a role could not be tested")
        if inconclusive:
            reasons.append(f"{inconclusive} write(s) failed WITHOUT SQLSTATE 25006 + freeze marker")
        if fail:
            reasons.append(f"{fail} read(s) failed")
        if reasons:
            say("NOT PROVEN: " + "; ".join(reasons))
            return finish(ev, a, "FREEZE_NOT_PROVEN", 2)
        if db_only:
            say(f"F30_DATABASE_FREEZE_PROVEN for label '{a.label}' (database/API only; app MAINTENANCE_MODE NOT TESTED).")
            return finish(ev, a, "F30_DATABASE_FREEZE_PROVEN", 0)
        say(f"FREEZE_PROVEN for label '{a.label}' (anon, service_role, authenticated: every write blocked with the marker; reads work).")
        return finish(ev, a, "FREEZE_PROVEN", 0)
    if fail or incomplete:
        say("NOT OK: " + ("a role could not be tested; " if incomplete else "") + f"{fail} expectation(s) failed")
        return finish(ev, a, f"{a.phase.upper()}_FAILED", 2)
    say("All tests behaved as expected: writes succeed.")
    return finish(ev, a, "WRITES_WORK", 0)


def finish(ev, a, final, code):
    ev["final"] = final
    os.makedirs(a.evidence_dir, exist_ok=True)
    name = os.path.join(a.evidence_dir, f"evidence_{a.phase}_{re.sub('[^A-Za-z0-9_-]', '', a.label)}_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json")
    with open(name, "w") as f:
        f.write(scrub(json.dumps(ev, indent=2)))
    say(f"\nRESULT: {final}   (evidence file: {os.path.basename(name)} -- sanitized: no keys, no bodies)")
    sys.exit(code)


if __name__ == "__main__":
    main()
