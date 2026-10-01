#!/usr/bin/env python3
"""EXTERNAL API freeze probe for the hosted NON-PRODUCTION test project (PROPOSAL 0152). Standard library only.

SQL checks can never prove the freeze (the operator is exempt by design); THIS is the proof. It sends real PostgREST requests with the project's own keys and reports only
HTTP status codes and the database's error code/message. Keys are read ONLY from environment variables, are never printed, never written to the evidence file, and are scrubbed
from every printed string. Run it only from the operator's own terminal.

  export TDP_PROJECT_URL='https://<test-ref>.supabase.co'   TDP_ANON_KEY=...  TDP_SERVICE_KEY=...  TDP_USER_JWT=<access token of a synthetic test user, obtained BEFORE the freeze>
  python3 api_freeze_probe.py --phase baseline
  python3 api_freeze_probe.py --phase frozen --label pooled            # immediately after 02 (existing pooled connections are still open)
  python3 api_freeze_probe.py --phase frozen --label new --compare-pids evidence_frozen_pooled_*.json   # after 07_recycle (new connections)
  python3 api_freeze_probe.py --phase restored

Hard guards: refuses any host whose project ref does not start with TDP_EXPECTED_REF_PREFIX (default fjmrvvyjvqd) and ALWAYS refuses the production ref.
FAIL-CLOSED rules for phase frozen: ANY 2xx on a write = FREEZE_BREACH (probe stops at once, evidence saved, exit 3, production approval BLOCKED); an error that does not carry the
freeze marker = INCONCLUSIVE (not proven); a missing key/JWT = INCOMPLETE (not proven). Only "every write blocked with the marker, all roles, all operations" = FREEZE_PROVEN."""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlparse

sys.dont_write_bytecode = True
PRODUCTION_REF = "zteixenjpcygjvznueuo"
MARKER = "TDP_MAINTENANCE_FREEZE"
KEYS = ("TDP_ANON_KEY", "TDP_SERVICE_KEY", "TDP_USER_JWT")
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}(?:\.[A-Za-z0-9_\-]*)?")


def scrub(text):
    text = str(text)
    for k in KEYS:
        v = os.environ.get(k)
        if v:
            text = text.replace(v, "[redacted]")
    return JWT_RE.sub("[redacted-jwt]", text)


def say(msg=""):
    print(scrub(msg))


def guard_target():
    url = os.environ.get("TDP_PROJECT_URL", "").strip().rstrip("/")
    if not url:
        sys.exit("REFUSED: TDP_PROJECT_URL is not set.")
    u = urlparse(url)
    host = (u.hostname or "").lower()
    local = host in ("127.0.0.1", "localhost") and os.environ.get("TDP_ALLOW_LOCAL_MOCK") == "1"
    if not local:
        if u.scheme != "https" or not host.endswith(".supabase.co"):
            sys.exit("REFUSED: the target must be an https://<ref>.supabase.co project URL.")
        ref = host[: -len(".supabase.co")]
        if PRODUCTION_REF in host or ref == PRODUCTION_REF:
            sys.exit("REFUSED: this is the PRODUCTION project. This probe must never be pointed at it.")
        prefix = os.environ.get("TDP_EXPECTED_REF_PREFIX", "fjmrvvyjvqd")
        if not prefix or not ref.startswith(prefix):
            sys.exit(f"REFUSED: project ref '{ref[:6]}...' does not start with the expected test-project prefix '{prefix}'.")
    return url


def request(base, method, path, key, bearer=None, body=None, timeout=20):
    headers = {"apikey": key, "Authorization": "Bearer " + (bearer or key), "Content-Type": "application/json", "Prefer": "return=representation"}
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # network problem: not a valid proof either way
        return 0, f"NETWORK_ERROR {type(e).__name__}"


def err_of(body):
    try:
        j = json.loads(body)
        if isinstance(j, dict):
            return str(j.get("code", "")), str(j.get("message", ""))[:140]
    except Exception:
        pass
    return "", scrub(body)[:100]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", required=True, choices=["baseline", "frozen", "restored", "diag"])
    ap.add_argument("--label", default="run")
    ap.add_argument("--burst", type=int, default=3, help="repeat every write test this many times to touch several pooled connections")
    ap.add_argument("--compare-pids", help="evidence file of an earlier run whose backends must be DISJOINT from this run's (proves new connections)")
    ap.add_argument("--evidence-dir", default=os.path.expanduser("~/tdp-freeze-evidence"), help="keep evidence OUTSIDE the repository")
    a = ap.parse_args()
    base = guard_target()
    anon, svc, jwt = (os.environ.get(k) for k in KEYS)
    say(f"target host ref: {urlparse(base).hostname.split('.')[0][:12]}...   phase={a.phase} label={a.label}")
    roles = [("anon", anon, None), ("service_role", svc, None), ("authenticated", anon, jwt)]
    ev = {"phase": a.phase, "label": a.label, "utc": datetime.now(timezone.utc).isoformat(), "results": [], "backends": [], "production_approval": "PENDING"}
    incomplete = [n for n, k, b in roles if not k or (n == "authenticated" and not b)]
    for n in incomplete:
        say(f"INCOMPLETE: no key/JWT supplied for role '{n}' -- that role cannot be tested")
    backends = set()

    def diag(tag, key, bearer):
        s, b = request(base, "POST", "/rest/v1/rpc/freeze_probe_diag", key, bearer, {})
        try:
            j = json.loads(b)
            j = j[0] if isinstance(j, list) and j else j
            backends.add((j["pid"], j["backend_start"]))
            ev["backends"].append({"role": tag, "pid": j["pid"], "backend_start": j["backend_start"], "session_user": j["session_user"], "current_user": j["current_user"],
                                   "default_transaction_read_only": j["default_transaction_read_only"], "transaction_read_only": j["transaction_read_only"]})
            return j
        except Exception:
            return None

    if a.phase == "diag":
        for n, k, b in roles:
            if not k or (n == "authenticated" and not b):
                continue
            j = diag(n, k, b)
            say(f"{n}: diag={'unavailable (function missing?)' if j is None else {x: j[x] for x in ('session_user', 'current_user', 'default_transaction_read_only', 'transaction_read_only')}}")
        return finish(ev, a, "DIAG_DONE", 0)

    fail = inconclusive = breach = 0
    tests = []
    for n, k, b in roles:
        if not k or (n == "authenticated" and not b):
            continue
        tests += [(n, "GET readable", "GET", "/rest/v1/freeze_probe_items?select=id&limit=1", k, b, None, "read"),
                  (n, "POST insert", "POST", "/rest/v1/freeze_probe_items", k, b, {"note": f"probe-{a.phase}-{n}"}, "write"),
                  (n, "PATCH update", "PATCH", "/rest/v1/freeze_probe_items?id=eq.1", k, b, {"note": "seed"}, "write"),
                  (n, "DELETE delete", "DELETE", "/rest/v1/freeze_probe_items?note=like.probe-*", k, b, None, "write"),
                  (n, "RPC writable SECURITY DEFINER", "POST", "/rest/v1/rpc/freeze_probe_write", k, b, {}, "write")]
    for rep in range(max(1, a.burst)):
        for n, name, method, path, k, b, body, kind in tests:
            if kind == "read" and rep > 0:
                continue
            j = diag(n, k, b) if name == "POST insert" else None   # records which backend served this role (existing vs new connections)
            s, resp = request(base, method, path, k, b, body)
            code, msg = err_of(resp) if s >= 400 or s == 0 else ("", "")
            ok2xx = 200 <= s < 300
            if kind == "read":
                verdict = "PASS" if ok2xx else "FAIL"
            elif a.phase == "frozen":
                if ok2xx:
                    verdict = "BREACH"
                elif code == "25006" and msg.startswith(MARKER):
                    verdict = "BLOCKED"
                else:
                    verdict = "INCONCLUSIVE"
            else:
                verdict = "PASS" if ok2xx else "FAIL"
            ev["results"].append({"rep": rep, "role": n, "test": name, "http": s, "sqlstate": code, "message": msg, "verdict": verdict})
            say(f"  [{rep}] {n:14s} {name:30s} HTTP {s:<3d} {code:6s} {msg[:70]:70s} -> {verdict}")
            if verdict == "BREACH":
                breach += 1
                say("\nFREEZE_BREACH: a write SUCCEEDED while the freeze is enabled. STOPPING THE TEST NOW.")
                say("  1. STOP ALL MIGRATION ACTIVITY. Do not run anything else against this project except restoration.")
                say("  2. Restore: run 05_disable_freeze.sql (or EMERGENCY_UNFREEZE.sql if that cannot run), then 06_verify_disable.sql, then this probe with --phase restored.")
                say("  3. Keep the evidence file written below. Production approval is BLOCKED until a redesigned freeze passes a fresh hosted test.")
                ev["production_approval"] = "BLOCKED"
                return finish(ev, a, "FREEZE_BREACH", 3)
            if verdict in ("FAIL",):
                fail += 1
            if verdict == "INCONCLUSIVE":
                inconclusive += 1
    # backend evidence: which backends served the requests (existing pooled vs new connections)
    say(f"backends observed serving this run: {len(backends)}")
    if a.compare_pids:
        try:
            old = json.load(open(a.compare_pids))
            old_set = {(x["pid"], x["backend_start"]) for x in old["backends"]}
        except Exception as e:
            old_set = None
            say(f"COULD NOT READ --compare-pids file ({type(e).__name__}) -> cannot prove 'new connections'")
        if old_set is not None:
            shared = backends & old_set
            say(f"backends shared with the compared run: {len(shared)} (must be 0 for 'new connections')")
            ev["shared_backends_with_compared_run"] = len(shared)
            if shared or not backends:
                inconclusive += 1
    if a.phase == "frozen":
        if fail or inconclusive or incomplete or not backends:
            final, code = "FREEZE_NOT_PROVEN", 2
            why = []
            if incomplete: why.append("a role could not be tested")
            if inconclusive: why.append(f"{inconclusive} write(s) failed WITHOUT the freeze marker or backends were not distinct")
            if fail: why.append(f"{fail} read(s) failed")
            if not backends: why.append("no backend evidence (is freeze_probe_diag installed?)")
            say("NOT PROVEN: " + "; ".join(why))
        else:
            final, code = "FREEZE_PROVEN", 0
            say(f"FREEZE_PROVEN for label '{a.label}': every write (POST/PATCH/DELETE/RPC) was blocked for anon, service_role and authenticated with {MARKER}; reads still work.")
    else:
        if fail or incomplete:
            final, code = f"{a.phase.upper()}_FAILED", 2
        else:
            final, code = "WRITES_WORK", 0
            say("All tests behaved as expected: writes succeed.")
    return finish(ev, a, final, code)


def finish(ev, a, final, code):
    ev["final"] = final
    if final != "FREEZE_BREACH" and ev.get("production_approval") == "PENDING":
        ev["production_approval"] = "PENDING (this probe alone never grants approval)"
    os.makedirs(a.evidence_dir, exist_ok=True)
    name = os.path.join(a.evidence_dir, f"evidence_{a.phase}_{a.label}_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json")
    with open(name, "w") as f:
        f.write(scrub(json.dumps(ev, indent=2)))
    say(f"\nRESULT: {final}   (evidence file: {os.path.basename(name)} -- statuses and messages only, no keys)")
    sys.exit(code)


if __name__ == "__main__":
    main()
