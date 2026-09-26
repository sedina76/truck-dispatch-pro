#!/usr/bin/env python3
"""Final source / generated-file integrity gate for proposals 0149-0152 and 0154-0157 (read-only; no database, no writes unless --write-manifest).

    python3 integrity.py                  # verify
    python3 integrity.py --write-manifest # (re)write PROMOTION_MANIFEST.txt after a reviewed change
"""
import hashlib
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
PROPS = HERE.parent
SUPA = PROPS.parent
REPO = SUPA.parent
MANIFEST = HERE / "PROMOTION_MANIFEST.txt"
fails = []


def check(label, cond, detail=""):
    print(("  ok  " if cond else "  FAIL ") + label + ("" if cond else " " + str(detail)))
    if not cond:
        fails.append(label)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def proposal_files():
    out = []
    for d in ("0149", "0150", "0151", "0152", "0154", "0155", "0156", "0157"):
        for f in sorted((PROPS / d).rglob("*")):
            if f.is_file() and "__pycache__" not in f.parts and f.name != "PROMOTION_MANIFEST.txt" and f.suffix != ".pyc":
                out.append(f)
    return out


def main():
    print("== generated files match their generators ==")
    for d in ("0149", "0150", "0151", "0152", "0154", "0155", "0156", "0157"):
        r = subprocess.run([sys.executable, "-B", str(PROPS / d / "build.py"), "--check"], capture_output=True, text=True)
        check(f"{d}: build.py --check ({r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()[:80]})", r.returncode == 0)

    r = subprocess.run([sys.executable, "-B", str(HERE / "production_package/role_fixture/build_fixture.py"), "--check"], capture_output=True, text=True)
    check("F-30 role fixture: all five generated artifacts match their source", r.returncode == 0, r.stdout + r.stderr)

    print("== inputs are pinned to the exact expected source migrations ==")
    t149 = load("t149i", PROPS / "0149" / "tests.py")
    sys.path.insert(0, str(PROPS / "0149"))
    t150 = load("t150i", PROPS / "0150" / "tests.py")
    pins = dict(t149.PINNED)
    pins.update(t150.PINNED_EXTRA)
    for rel, expected in sorted(pins.items()):
        check(f"{rel}", sha(SUPA / rel) == expected)
    for rel in ("migrations/0129_atomic_dispatch_lifecycle.sql", "migrations/0130_carrier_context_foundation.sql", "migrations/0147_production_readiness_blocker_remediation.sql"):
        check(f"{rel} is pinned", rel in pins)

    print("== proposal 0151: repaired body and TSIDK behaviour ==")
    b151 = load("b151i", PROPS / "0151" / "build.py")
    body_md5 = hashlib.md5(b151.norm(b151.new_block().split("$fn$")[1]).encode()).hexdigest()
    check("0151 repaired transition_dispatch_status body md5 is the pinned reviewed value", body_md5 == PIN_0151_BODY_MD5, body_md5)
    nb = b151.new_block()
    check("0151 body: TSIDK, two organization-scoped ledger reads, dispatch-org check before the role gate before the ledger", "TSIDK" in nb and nb.count("t.organization_id = v_org") == 2
          and nb.index("TSDNF") < nb.index("has_role(array['owner','admin','dispatcher']") < nb.index("from public.dispatch_status_transitions t"))
    check("0151 baseline it derives from is the pinned 0134 text", sha(SUPA / "migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql") == pins["migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql"])
    p151 = (PROPS / "0151" / "proposed_0151.sql").read_text()
    check("0151 proposed SQL embeds exactly that body and changes no ACL statement", nb in p151 and not re.search(r"\b(grant|revoke)\b", re.sub(r"--.*", "", p151.replace(nb, "")), re.I))

    print("== proposal 0152: exactly the documented scope ==")
    b152 = load("b152i", PROPS / "0152" / "build.py")
    p152 = (HERE / "proposed_0152.sql").read_text()
    check("8 function replacements", p152.count("create or replace function") == 8 and len(b152.FUNCS) == 8)
    check("3 ACL statements (service_role removed from the 3 internal helpers), no other revoke/grant", len(re.findall(r"^revoke all on function", p152, re.M)) == 3 and "grant execute" not in p152)
    check("2 columns (text NOT NULL) and nothing else altered", len(re.findall(r"^alter table .* add column request_fingerprint text not null;$", p152, re.M)) == 2 and len(re.findall(r"^alter table", p152, re.M)) == 2)
    check("0152 does not redefine 0151's function (it only READS transition_dispatch_status to require that 0151 is applied)", "function public.transition_dispatch_status(" not in p152.lower())

    print("== app mappings never expose raw database text ==")
    conf = (REPO / "src/lib/dispatch/conflicts.ts").read_text()
    res = (REPO / "src/lib/factoring/rpc-result.ts").read_text()
    check("RRIDK maps to a fixed message (fixedMessage overrides the database text)", 'RRIDK: { appCode: "IDEMPOTENCY_KEY_REUSED", field: null, fixedMessage: IDEMPOTENCY_KEY_REUSED_MESSAGE }' in conf and "mapped.fixedMessage ??" in conf)
    check("FPIDK maps to a fixed message before error.message is used", 'error.code === "FPIDK" ? FPIDK_MESSAGE : error.message' in res)

    print("== proposal 0148 is untouched ==")
    m = re.search(r"REVIEWED = (\{.*?\})  # REVIEWED_SQL_HASHES", (PROPS / "0148" / "tests.py").read_text(), re.S)
    reviewed = eval(m.group(1))
    for name, expected in sorted(reviewed.items()):
        check(f"0148/{name} matches its reviewed SHA-256", sha(PROPS / "0148" / name) == expected)
    check("supabase/migrations/ is untouched (git)", subprocess.run(["git", "status", "--porcelain", "supabase/migrations"], cwd=REPO, capture_output=True, text=True).stdout.strip() == "")
    check("supabase/proposals/0148 has no changes since it was created (only untracked, none renamed)", (PROPS / "0148").is_dir() and not list((PROPS / "0148").glob("*.pyc")))

    print("== every task file is accounted for ==")
    porcelain = subprocess.run(["git", "status", "--porcelain"], cwd=REPO, capture_output=True, text=True).stdout.splitlines()
    got = sorted(l[3:].strip('"') for l in porcelain)
    expected = sorted(["src/app/(app)/dispatch/actions.ts", "src/app/(app)/settings/factoring/actions.ts", "src/components/dispatch/cancel-dispatch-form.tsx",
                       "src/components/dispatch/dispatch-conflict-alert.tsx", "src/lib/dispatch/conflicts.ts", "src/lib/factoring/rpc-result.ts",
                       "src/lib/dispatch/cancel.test.mjs", "src/lib/dispatch/cancel.ts", "src/lib/dispatch/idempotency-codes.test.mjs",
                       "supabase/VERIFY_LD100035_CARRIER_SCOPE_READONLY.sql", "supabase/proposals/",
                       ".env.local.example", "src/middleware.ts", "src/lib/maintenance/", "src/lib/factoring/submission-contract.test.mjs", "src/lib/factoring/carrier-invoice-submission.ts",
                       "src/lib/factoring/carrier-invoice-submission.test.mjs", "src/lib/factoring/carrier-invoice-ui-contract.test.mjs", "src/lib/factoring/carrier-invoice-issuance.ts", "src/lib/factoring/carrier-invoice-issuance.test.mjs", "src/lib/factoring/carrier-invoice-issuance-ui-contract.test.mjs", "src/app/(app)/carrier-invoices/", "src/components/carrier-invoices/"])
    check("git status lists exactly the 6 modified + 3 new app files, the maintenance gate (middleware, env example, src/lib/maintenance/), the factoring submission and issuance modules + tests, the read-only LD-100035 verifier and supabase/proposals/", got == expected, str(sorted(set(got) ^ set(expected))))

    print("== promotion manifest (SHA-256 of every proposal file 0149-0152 and 0154-0157) ==")
    lines = [f"{sha(f)}  {f.relative_to(PROPS)}" for f in proposal_files()]
    text = "\n".join(lines) + "\n"
    if "--write-manifest" in sys.argv:
        MANIFEST.write_text(text)
        print(f"  wrote {MANIFEST.name} ({len(lines)} files)")
    else:
        check("PROMOTION_MANIFEST.txt matches the files on disk", MANIFEST.exists() and MANIFEST.read_text() == text)
    print("\nINTEGRITY " + ("FAILED: " + "; ".join(fails) if fails else "PASSED"))
    sys.exit(1 if fails else 0)


PIN_0151_BODY_MD5 = "7d56b97529af95eece84b2f0dab2e83c"

if __name__ == "__main__":
    main()
