#!/usr/bin/env python3
"""Offline tests for the F-30 hosted PROVISIONING PLAN (HOSTED_PROVISIONING_PLAN.md, provision_marker.sql, provision_marker_cleanup.sql, mint_identity_jwts.py).
Makes NO hosted connection and NO database change (no PostgreSQL is started). Pure text/AST inspection plus mint_identity_jwts.py's own offline signing/self-check code."""
import ast
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Whether to actually invoke the `mint` subcommand (still only with throwaway, synthetic, offline data -- never a real secret, never a hosted connection). Left OFF by default
# so a plain run of this file never mints anything, however synthetic; set RUN_MINT_SMOKE=1 explicitly to also exercise that regression coverage.
RUN_MINT_SMOKE = os.environ.get("RUN_MINT_SMOKE") == "1"

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
fails = []


def check(label, condition, detail=""):
    print(("ok   " if condition else "FAIL ") + label + (f"  ({detail})" if detail and not condition else ""))
    if not condition:
        fails.append(label)


def rd(name):
    return (HERE / name).read_text()


PLAN = rd("HOSTED_PROVISIONING_PLAN.md")
MARKER = rd("provision_marker.sql")
MARKER_CLEANUP = rd("provision_marker_cleanup.sql")
MINT_SRC = rd("mint_identity_jwts.py")
CLEAN_SRC = rd("cleanup_auth_test_identities.py")
PREFLIGHT_SRC = rd("target_preflight.py")
PREFLIGHT_SQL = rd("target_preflight_readonly.sql")
README = rd("README.md")
MODEL = rd("model.sql")

print("== plan document ==")
check("states it makes no hosted connection and no database change", "MAKES NO" in PLAN or "make NO hosted connection" in PLAN or "makes NO hosted connection" in PLAN)
check("covers Step A (marker), Step B (identities) and Step C (null-identity)", all(s in PLAN for s in ["## Step A", "## Step B", "## Step C"]))
check("Step B/C are marked BLOCKED for this project's observed key state, not merely gated behind a confirmation", "BLOCKED for this project" in PLAN)
check("Step C names the self-signing block as an independent, secondary reason the null case is also blocked that way (no longer the primary reason, now that Step B does not depend on self-signing)",
      "independent, secondary reason" in PLAN)
check("Step C requires a single isolated read-only preview call before trusting a null token, IF Step B's alternative is ever authorized", "preview" in PLAN and "NOT_PROVEN" in PLAN)
check("Step C states probe.py's requirement now only covers the 14 named identities, and that TDP_F30_NULL_JWT no longer blocks the run when absent",
      "F30_REQUIRED_SYNTHETIC_IDENTITIES_MISSING" in PLAN and "no longer blocks the hosted" in PLAN and 'null_identity_status: "not_proven"' in PLAN)
check("records the OBSERVED key state (current ES256, legacy previously-used) and cites a source for the conclusions drawn from it", "ES256" in PLAN and "previously-used" in PLAN and "## Sources" in PLAN and "supabase.com/docs/guides/auth/signing-keys" in PLAN)
check("Step B is marked BLOCKED for this project with a quoted citation, not a guess", "BLOCKED" in PLAN and "extracting of the private key or shared secret from Supabase is not possible" in PLAN)
check("names the one officially supported alternative exactly (generate + import + ROTATE a new key, then sign locally) and explicitly does NOT authorize it here",
      "gen signing-key" in PLAN and "gen bearer-jwt" in PLAN and "Rotate keys" in PLAN and "does not authorize" in PLAN)
check("states plainly that no key was rotated, no token was minted and no hosted connection was made while producing this revision (case-insensitive: the doc opens the sentence with a capital N)",
      re.search(r"no token was minted", PLAN, re.I) and re.search(r"no hosted connection was made", PLAN, re.I) and re.search(r"no key was rotated", PLAN, re.I))
check("Step C records the 'sub is optional' finding as evidence but marks the CLI-flag-omission detail unconfirmed", "UNCONFIRMED" in PLAN and "an optional UUID" in PLAN)
check("does not itself contain a real-looking secret or JWT", not re.search(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}", PLAN))
check("no longer offers the old --confirm-hs256 escape hatch (superseded by the unconditional, cited block)", "--confirm-hs256" not in PLAN)
check("the documented hosted cleanup command is MANDATORY, not optional, about checking ORPHANS.json/UNRESOLVED.json, and shows both flags in the exact invocation",
      "MANDATORY, not optional" in PLAN and "--orphans-file <provisioning --out-dir>/ORPHANS.json --unresolved-file <provisioning --out-dir>/UNRESOLVED.json" in PLAN)
check("the plan's cleanup command text matches cleanup_auth_test_identities.py's ACTUAL argparse requirement (cross-checked against the source, not just prose)",
      'c.add_argument("--orphans-file", required=True' in CLEAN_SRC and 'c.add_argument("--unresolved-file", required=True' in CLEAN_SRC)

print("== provision_marker.sql ==")
check("marked NOT EXECUTED / NOT APPLIED and states it makes no hosted connection by itself", "NOT EXECUTED" in MARKER and "NOT APPLIED" in MARKER and "MAKES NO HOSTED CONNECTION" in MARKER)
check("refuses on the untouched placeholder", "REPLACE_WITH_VERIFIED_PROJECT_REF" in MARKER and "raise exception" in MARKER)
check("validates the reference shape and rejects the forbidden/production/test references", "'^[a-z0-9]{20}$'" in MARKER and "zteixenjpcygjvznueuo" in MARKER and "fjmrvvyjvqdyopnyetez" in MARKER)
check("also refuses the local-disposable-harness sentinel outright (matches probe.py's FORBIDDEN_REFS)", "localdisposablef30xx" in MARKER)
check("refuses if f30_test_control already exists (never overwrites an existing marker)", "to_regnamespace('f30_test_control') is not null" in MARKER)
check("requires the operator's own session, not SET ROLE (F30_OPERATOR_REQUIRED, matching fixture.sql/reset.sql/cleanup.sql)", "current_user <> session_user" in MARKER and "F30_OPERATOR_REQUIRED" in MARKER)
check("takes the SAME shared advisory lock fixture.sql/reset.sql/cleanup.sql use (303030157), so it cannot race them", "pg_advisory_xact_lock(303030157)" in MARKER)
check("database_name is derived from current_database(), never a second placeholder", "current_database()" in MARKER and len(set(re.findall(r"REPLACE_WITH_\w+", MARKER))) == 1)
check("fixture_id and environment match exactly what model.sql's check_target() requires", "'F30_SYNTHETIC_ROLE_MODEL_V1'" in MARKER and "'nonproduction-f30'" in MARKER and "'F30_SYNTHETIC_ROLE_MODEL_V1'" in MODEL and "'nonproduction-f30'" in MODEL)
check("revokes all privileges from every client role on both the schema and the table", MARKER.count("revoke all") >= 2 and "public, anon, authenticated, service_role" in MARKER)
check("wrapped in exactly one transaction (begin ... commit)", MARKER.count("begin;") == 1 and MARKER.count("commit;") == 1)
_after_commit = MARKER[MARKER.rindex("commit;") + len("commit;"):]
check("ends with a read-only verification SELECT, no further writes after the final commit", "select m.project_ref" in _after_commit and not re.search(r"\b(insert|update|delete|create|drop|alter|grant|revoke|truncate)\b", _after_commit, re.I))
check("contains no live credential-shaped string, no hostname other than the docs' own example pattern, no connection string", not re.search(r"postgres(?:ql)?://|eyJ[A-Za-z0-9_\-]{10,}\.", MARKER))

print("== provision_marker_cleanup.sql ==")
check("marked NOT EXECUTED / NOT APPLIED and states it makes no hosted connection by itself", "NOT EXECUTED" in MARKER_CLEANUP and "NOT APPLIED" in MARKER_CLEANUP and "MAKES NO HOSTED CONNECTION" in MARKER_CLEANUP)
check("refuses while f30_probe still exists (marker removed LAST)", "to_regnamespace('f30_probe') is not null" in MARKER_CLEANUP)
check("refuses if no marker exists, and re-validates fixture/environment/database/reference format+forbidden-set before dropping (matches cleanup.sql's own guard, not a weaker subset)",
      "no marker exists" in MARKER_CLEANUP and "F30_SYNTHETIC_ROLE_MODEL_V1" in MARKER_CLEANUP and "'^[a-z0-9]{20}$'" in MARKER_CLEANUP and "zteixenjpcygjvznueuo" in MARKER_CLEANUP and "localdisposablef30xx" in MARKER_CLEANUP)
check("requires the operator's own session (F30_OPERATOR_REQUIRED)", "current_user <> session_user" in MARKER_CLEANUP and "F30_OPERATOR_REQUIRED" in MARKER_CLEANUP)
check("checks marker ownership/ACL drift before dropping anything (F30_MARKER_OWNERSHIP_OR_ACL_DRIFT, matching fixture.sql/reset.sql/cleanup.sql)", "F30_MARKER_OWNERSHIP_OR_ACL_DRIFT" in MARKER_CLEANUP and "aclexplode" in MARKER_CLEANUP)
check("requires f30.expected_project_ref to match the marker before removing it (F30_EXPLICIT_TARGET_REQUIRED, matching fixture.sql/reset.sql/cleanup.sql)", "f30.expected_project_ref" in MARKER_CLEANUP and "F30_EXPLICIT_TARGET_REQUIRED" in MARKER_CLEANUP)
check("takes the SAME shared advisory lock reset.sql/cleanup.sql use (303030157)", "pg_advisory_xact_lock(303030157)" in MARKER_CLEANUP)
check("drops with RESTRICT, never CASCADE", "drop schema f30_test_control restrict" in MARKER_CLEANUP and "cascade" not in MARKER_CLEANUP.lower())

print("== provision_marker.sql / provision_marker_cleanup.sql guard parity with fixture.sql / reset.sql / cleanup.sql ==")
SIBLINGS = rd("fixture.sql") + rd("reset.sql") + rd("cleanup.sql")
for token in ("current_user<>session_user", "pg_advisory_xact_lock(303030157)"):
    check(f"a real guarded script actually contains '{token}' (sanity: the parity checks above are comparing against something real)", token in SIBLINGS)

print("== mint_identity_jwts.py (static) ==")
tree = ast.parse(MINT_SRC)
imported = {n.name.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.Import) for n in node.names} | \
           {node.module.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.ImportFrom) and node.module}
check("imports the standard library only, no network-capable module", imported.isdisjoint({"urllib", "http", "socket", "requests", "smtplib", "ftplib", "asyncio", "ssl", "paramiko", "telnetlib"}), str(sorted(imported)))
check("the signing secret is read only from an environment variable, never argparse", "TDP_F30_JWT_SIGNING_SECRET" in MINT_SRC and "--secret" not in MINT_SRC and "--jwt-secret" not in MINT_SRC)
check("refuses an --out-dir that resolves inside this git repository", "refuse_if_inside_repo" in MINT_SRC and "REFUSED" in MINT_SRC)
check("FAILS CLOSED (refuses outright) if its own repository root cannot be positively located, instead of silently narrowing the protected boundary", "repo_root(search_start)" in MINT_SRC and "if root is None" in MINT_SRC and "FAIL CLOSED" in MINT_SRC)
check("the null-identity token requires an explicit flag and a distinct output filename", "allow_null_identity_token" in MINT_SRC and "TDP_F30_NULL_JWT_UNVERIFIED" in MINT_SRC)
check("the printed null-token-not-minted message states it blocks the ENTIRE probe run, not just one row", "F30_REQUIRED_SYNTHETIC_IDENTITIES_MISSING" in MINT_SRC and "ENTIRE hosted role-model probe run" in MINT_SRC)
check("signing is refused UNCONDITIONALLY -- no confirm flag overrides it -- unless current-key-algorithm=HS256 AND legacy-secret-status=not-migrated (the only state where the secret is still extractable at all)",
      "require_self_signable_key_state" in MINT_SRC and 'SELF_SIGNABLE_KEY_ALGORITHM = "HS256"' in MINT_SRC and 'SELF_SIGNABLE_LEGACY_STATUS = "not-migrated"' in MINT_SRC and "no override exists" in MINT_SRC)
check("--current-key-algorithm and --legacy-secret-status are both required arguments (read off the dashboard, not assumed)", "--current-key-algorithm" in MINT_SRC and "--legacy-secret-status" in MINT_SRC and 'required=True, choices=["HS256", "ES256", "RS256", "EdDSA"]' in MINT_SRC)
check("cites the exact Supabase FAQ sentence that makes this unconditional (extraction is impossible once migrated, regardless of 'previously used' verification status)",
      "extracting of the private key or shared secret from Supabase is not possible" in MINT_SRC and "previously used" in MINT_SRC.replace("previously-used", "previously used"))
check("the key-state gate is checked before the secret is even read (algorithm gate is primary, not an afterthought)", MINT_SRC.index("require_self_signable_key_state(args.current_key_algorithm") < MINT_SRC.index('os.environ.get("TDP_F30_JWT_SIGNING_SECRET"'))
check("this project's OBSERVED state (ES256 current / HS256 previously-used) is recorded in the module docstring itself, not just the plan", "current-key-algorithm=ES256" in MINT_SRC and "legacy-secret-status=previously-used" in MINT_SRC)
check("names the one supported alternative (gen signing-key / import / Rotate keys / gen bearer-jwt) and marks steps 2-3 as hosted+rotation, out of scope for this tool", "gen signing-key" in MINT_SRC and "gen bearer-jwt" in MINT_SRC and "KEY ROTATION" in MINT_SRC and "out of scope for this tool" in MINT_SRC)
check("the recommended invocation in this file's own docstring uses read -s (not an inline SECRET=... command)", "read -s -p" in MINT_SRC and not re.search(r"TDP_F30_JWT_SIGNING_SECRET=\.\.\. python3", MINT_SRC))
_OLD_BASH_INVOCATION = "read -s -p 'F-30 test-project service-role key: ' TDP_F30_SERVICE_ROLE_KEY"  # the superseded, zsh-incompatible RECOMMENDED command -- distinct
# from merely mentioning "read -s -p" in explanatory prose about why NOT to use it, which both docstrings legitimately do.
check("provision_auth_test_identities.py's own docstring uses the macOS-zsh-correct read -rs \"VAR?prompt\" form for TDP_F30_SERVICE_ROLE_KEY (not an inline KEY=... command, and not bash's read -s -p form as the RECOMMENDED invocation, which fails under zsh)",
      'read -rs "TDP_F30_SERVICE_ROLE_KEY?' in rd("provision_auth_test_identities.py") and "TDP_F30_SERVICE_ROLE_KEY=..." not in rd("provision_auth_test_identities.py") and _OLD_BASH_INVOCATION not in rd("provision_auth_test_identities.py"))
check("cleanup_auth_test_identities.py's own docstring ALSO uses the macOS-zsh-correct read -rs \"VAR?prompt\" form for TDP_F30_SERVICE_ROLE_KEY",
      'read -rs "TDP_F30_SERVICE_ROLE_KEY?' in CLEAN_SRC and "TDP_F30_SERVICE_ROLE_KEY=..." not in CLEAN_SRC and _OLD_BASH_INVOCATION not in CLEAN_SRC)
check("both docstrings explain WHY the zsh form is required (bash's -p means something different under zsh and fails outright)",
      "coprocess" in rd("provision_auth_test_identities.py") and "coprocess" in CLEAN_SRC)
check("provision_auth_test_identities.py's docstring quotes the actual observed zsh failure message (not just a paraphrase)", "no coprocess" in rd("provision_auth_test_identities.py"))
check("no longer offers the superseded --confirm-hs256 flag", "--confirm-hs256" not in MINT_SRC and "require_hs256_confirmed" not in MINT_SRC)
check("token IS written to a file but never interpolated into a print() call (only the string 'token' as English prose is allowed)", "path.write_text(token)" in MINT_SRC and not re.search(r"print\([^)]*[{(,]\s*token\s*[})},]", MINT_SRC) and "{token}" not in MINT_SRC)
check("token files are written with mode 0600 and the directory with 0700", "0o600" in MINT_SRC and "0o700" in MINT_SRC)

print("== mint_identity_jwts.py (executed --self-check; offline, no filesystem writes, no network) ==")
r = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "--self-check"], capture_output=True, text=True, timeout=30)
check("--self-check exits 0", r.returncode == 0, r.stdout[-300:] + r.stderr[-300:])
check("--self-check reports every sub-check as ok (no line starting with the FAIL marker; a label merely containing the word FAIL, e.g. 'FAILS CLOSED', does not count)",
      not any(line.startswith("FAIL ") for line in r.stdout.splitlines()), r.stdout)

print("== mint_identity_jwts.py: REFUSAL paths only (no token is ever produced by any check in this section -- each one exits before mint_token() is reached) ==")
REF = "abcdefghij0123456789"
UNMIGRATED = ["--current-key-algorithm", "HS256", "--legacy-secret-status", "not-migrated"]
CONFIRM = f"LEGACY SECRET RETRIEVED PRE-MIGRATION {REF}"
with tempfile.TemporaryDirectory() as td0:
    env0 = {"TDP_F30_JWT_SIGNING_SECRET": "throwaway-test-secret-never-a-real-project-secret", "PATH": "/usr/bin:/bin"}
    rc = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", REF, "--out-dir", td0, "--current-key-algorithm", "ES256", "--legacy-secret-status", "previously-used"], capture_output=True, text=True, env=env0, timeout=30)
    check("mint REFUSES for THIS project's OBSERVED state (ES256/previously-used), writing nothing -- no --confirm flag can override this branch", rc.returncode != 0 and "no override exists" in (rc.stdout + rc.stderr) and not list(Path(td0).iterdir()), (rc.stdout + rc.stderr)[-250:])
    rc1b = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", REF, "--out-dir", td0, "--current-key-algorithm", "ES256", "--legacy-secret-status", "previously-used", "--confirm-legacy-secret", CONFIRM], capture_output=True, text=True, env=env0, timeout=30)
    check("...even if a --confirm-legacy-secret phrase is supplied anyway (there is no legacy-secret confirmation that fixes an asymmetric current key)", rc1b.returncode != 0 and "no override exists" in (rc1b.stdout + rc1b.stderr) and not list(Path(td0).iterdir()))
    rc = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", REF, "--out-dir", td0, *UNMIGRATED], capture_output=True, text=True, env=env0, timeout=30)
    check("on an (hypothetical) UNMIGRATED project, mint still REFUSES with no --confirm-legacy-secret at all, writing nothing", rc.returncode != 0 and "confirm-legacy-secret" in (rc.stdout + rc.stderr) and not list(Path(td0).iterdir()), (rc.stdout + rc.stderr)[-200:])
    rc2 = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", REF, "--out-dir", td0, *UNMIGRATED, "--confirm-legacy-secret", "LEGACY SECRET RETRIEVED PRE-MIGRATION some-other-ref"], capture_output=True, text=True, env=env0, timeout=30)
    check("...or a --confirm-legacy-secret phrase that doesn't match THIS --project-ref exactly, writing nothing", rc2.returncode != 0 and "confirm-legacy-secret" in (rc2.stdout + rc2.stderr) and not list(Path(td0).iterdir()), (rc2.stdout + rc2.stderr)[-200:])
    r3 = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", REF, "--out-dir", str(HERE), *UNMIGRATED, "--confirm-legacy-secret", CONFIRM], capture_output=True, text=True, env=env0, timeout=30)
    check("mint REFUSES an --out-dir inside this repository (checked before any token would be produced), writing nothing", r3.returncode != 0 and "REFUSED" in (r3.stdout + r3.stderr))
    r4 = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", "PRODUCTIONREF00000000", "--out-dir", td0, *UNMIGRATED], capture_output=True, text=True, env=env0, timeout=30)
    check("mint REFUSES a malformed project reference", r4.returncode != 0)
    r5 = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", "fjmrvvyjvqdyopnyetez", "--out-dir", td0, *UNMIGRATED], capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"}, timeout=30)
    check("mint REFUSES a forbidden reference before even reaching the key-state or secret checks", r5.returncode != 0 and "forbidden reference" in (r5.stdout + r5.stderr))
    check("'localdisposablef30xx' is exactly 20 characters (so only FORBIDDEN_REFS, not the regex, is what refuses it below)", len("localdisposablef30xx") == 20)
    r7 = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", "localdisposablef30xx", "--out-dir", td0, *UNMIGRATED], capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"}, timeout=30)
    check("mint REFUSES the local-disposable-harness sentinel as a --project-ref (matches provision_marker.sql's own new refusal of the same value)", r7.returncode != 0 and "forbidden reference" in (r7.stdout + r7.stderr))
    r6 = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), "mint", "--project-ref", REF, "--out-dir", td0, *UNMIGRATED, "--confirm-legacy-secret", CONFIRM], capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"}, timeout=30)
    check("mint REFUSES with no secret set at all, even on the (hypothetical) unmigrated path with a correct confirmation", r6.returncode != 0 and "TDP_F30_JWT_SIGNING_SECRET" in (r6.stdout + r6.stderr))
    check("none of the above wrote any file anywhere: this section produced zero tokens", not list(Path(td0).iterdir()))

if RUN_MINT_SMOKE:
    print("== mint_identity_jwts.py: SUCCESSFUL mint on a (hypothetical) UNMIGRATED project only -- RUN_MINT_SMOKE=1 was set; still a throwaway offline secret, still no network, still not this project's real state ==")
    topology = json.loads(rd("topology.json"))
    expected_names = sorted(f"TDP_F30_ORG{n}_{role.upper()}_JWT" for n, org in enumerate(topology["organizations"], 1) for role in org["identities"])
    with tempfile.TemporaryDirectory() as td:
        env = {"TDP_F30_JWT_SIGNING_SECRET": "throwaway-test-secret-never-a-real-project-secret", "PATH": "/usr/bin:/bin"}
        base_args = ["mint", "--project-ref", REF, *UNMIGRATED, "--confirm-legacy-secret", CONFIRM]
        r = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), *base_args, "--out-dir", td], capture_output=True, text=True, env=env, timeout=30)
        check("mint (no --allow-null-identity-token) exits 0 and prints no token value", r.returncode == 0 and env["TDP_F30_JWT_SIGNING_SECRET"] not in r.stdout, r.stdout[-300:] + r.stderr[-300:])
        written = sorted(p.name for p in Path(td).iterdir())
        check("writes exactly the 14 expected TDP_F30_ORG{1|2}_{ROLE}_JWT files (matching topology.json / probe.py's own naming), no null token by default", written == expected_names, str(written))
        for name in expected_names:
            p = Path(td) / name
            check(f"{name} is mode 0600", oct(p.stat().st_mode)[-3:] == "600")
            token = p.read_text().strip()
            h, payload_b64, sig = token.split(".")
            payload = json.loads(__import__("base64").urlsafe_b64decode(payload_b64 + "=" * (-len(payload_b64) % 4)))
            n = int(name.split("ORG")[1].split("_")[0])
            role = name.split(f"ORG{n}_")[1].rsplit("_JWT", 1)[0].lower()
            expected_sub = topology["organizations"][n - 1]["identities"][role]
            check(f"{name} claims sub == topology.json's deterministic UUID for that org/role", payload.get("sub") == expected_sub, f"{payload.get('sub')} != {expected_sub}")
            check(f"{name} claims role=authenticated and iss matches the given project ref", payload.get("role") == "authenticated" and payload.get("iss") == f"https://{REF}.supabase.co/auth/v1")
            expected_sig = __import__("base64").urlsafe_b64encode(hmac.new(env["TDP_F30_JWT_SIGNING_SECRET"].encode(), f"{h}.{payload_b64}".encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
            check(f"{name} signature verifies against the given secret", sig == expected_sig)
        r2 = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), *base_args, "--out-dir", td, "--allow-null-identity-token"], capture_output=True, text=True, env=env, timeout=30)
        check("with --allow-null-identity-token, the null token is written under the UNVERIFIED name only", r2.returncode == 0 and (Path(td) / "TDP_F30_NULL_JWT_UNVERIFIED").exists() and not (Path(td) / "TDP_F30_NULL_JWT").exists())
        null_payload = json.loads(__import__("base64").urlsafe_b64decode((Path(td) / "TDP_F30_NULL_JWT_UNVERIFIED").read_text().split(".")[1] + "==="))
        check("the unverified null token's claims omit 'sub' entirely", "sub" not in null_payload and null_payload.get("role") == "authenticated")
        check("a warning is printed for the null token", "UNCONFIRMED" in r2.stdout or "unverified" in r2.stdout.lower())
        r2b = subprocess.run([sys.executable, "-B", str(HERE / "mint_identity_jwts.py"), *base_args, "--out-dir", td], capture_output=True, text=True, env=env, timeout=30)
        check("without --allow-null-identity-token, the printed message says the ENTIRE probe run is blocked (not just one row)", "ENTIRE hosted role-model probe run" in r2b.stdout, r2b.stdout[-300:])
else:
    print("== mint_identity_jwts.py: successful-mint smoke test SKIPPED (RUN_MINT_SMOKE not set) -- no token minted in this run, per this task's instruction ==")

print("== target_preflight_readonly.sql (static) ==")
_stripped = re.sub(r"--[^\n]*", "", PREFLIGHT_SQL)
_statements = [s.strip() for s in _stripped.split(";") if s.strip()]
check("is exactly ONE statement", len(_statements) == 1, str(len(_statements)))
check("that one statement is a plain SELECT (starts with select/with)", bool(re.match(r"(select|with)\b", _statements[0].strip(), re.I)))
FORBIDDEN_SQL_KEYWORDS = re.compile(r"\b(insert|update|delete|truncate|create|alter|drop|grant|revoke|comment|copy|vacuum|analyze|reindex|cluster|refresh|lock|listen|notify|call|do|execute|prepare|set|reset|begin|commit|rollback|savepoint|nextval|setval)\b", re.I)
check("contains no write/DDL/session keyword anywhere", not FORBIDDEN_SQL_KEYWORDS.search(_stripped), str(FORBIDDEN_SQL_KEYWORDS.search(_stripped)))
check("takes no advisory lock (nothing here changes state, so nothing needs to race)", "pg_advisory" not in PREFLIGHT_SQL)
for field in ("postgres_version", "public_base_table_count", "f30_marker_schema_exists", "f30_fixture_schema_exists", "f30_freeze_schema_exists", "current_database"):
    check(f"selects '{field}'", f"'{field}'" in PREFLIGHT_SQL)
check("checks for the marker schema by its real name (f30_test_control, matching provision_marker.sql)", "f30_test_control" in PREFLIGHT_SQL)
check("checks for the fixture schema by its real name (f30_probe, matching model.sql)", "'f30_probe'" in PREFLIGHT_SQL)
check("checks for the freeze schema by its real name (ops_freeze_v2, matching ../../freeze/02_enable_freeze.sql)", "ops_freeze_v2" in PREFLIGHT_SQL)

print("== target_preflight.py (static + executed --self-check; offline, no network) ==")
check("has NO real_request()/real_query() FUNCTION DEFINITION at all -- unlike its siblings, no networking code exists in this file, confined or otherwise (the docstring/self-check TALKING ABOUT their absence is fine; a def is not)",
      "def real_request" not in PREFLIGHT_SRC and "def real_query" not in PREFLIGHT_SRC and "import urllib" not in PREFLIGHT_SRC and "import socket" not in PREFLIGHT_SRC)
check("evaluates all five conditions and never proceeds to GO on any single mismatch",
      "public_base_table_count" in PREFLIGHT_SRC and "f30_marker_schema_exists" in PREFLIGHT_SRC and "f30_fixture_schema_exists" in PREFLIGHT_SRC and "f30_freeze_schema_exists" in PREFLIGHT_SRC and '"GO" if not mismatches else "STOP"' in PREFLIGHT_SRC)
check("record-evidence writes evidence on EITHER verdict (a STOP is recorded, not just printed)", "if verdict == \"GO\":" in PREFLIGHT_SRC and "name.write_text(json.dumps(record" in PREFLIGHT_SRC)
check("the reference is redacted (first/last 4 chars only) everywhere it is written or printed, matching discovery_guard.py's own convention", "def redact_ref" in PREFLIGHT_SRC and "ref[:4]" in PREFLIGHT_SRC)
check("refuses an --evidence-dir inside this repository, same discipline as the Auth-provisioning tool's --out-dir guard", "refuse_if_inside_repo" in PREFLIGHT_SRC)
r_pf = subprocess.run([sys.executable, "-B", str(HERE / "target_preflight.py"), "--self-check"], capture_output=True, text=True, timeout=30)
check("--self-check exits 0", r_pf.returncode == 0, r_pf.stdout[-300:] + r_pf.stderr[-300:])
check("--self-check reports every sub-check as ok (no line starting with the FAIL marker)", not any(line.startswith("FAIL ") for line in r_pf.stdout.splitlines()), r_pf.stdout)

print("== HOSTED_PROVISIONING_PLAN.md documents the target preflight for precondition 2 ==")
check("precondition 2 points at target_preflight.py and target_preflight_readonly.sql, not just a vague reference to 'discovery-guard discipline'",
      "target_preflight.py" in PLAN and "target_preflight_readonly.sql" in PLAN and "confirm-target" in PLAN and "record-evidence" in PLAN)
check("precondition 2 states the tool makes no hosted connection of any kind", "no hosted connection of any kind" in PLAN)

print("== README.md points to the plan ==")
check("README.md references HOSTED_PROVISIONING_PLAN.md", "HOSTED_PROVISIONING_PLAN.md" in README)
check("README.md documents target_preflight.py for precondition 2", "target_preflight.py" in README and "target_preflight_readonly.sql" in README)

print(f"\n{'ALL ' + str(len(fails) == 0 and 'PASSED') if not fails else 'FAILED: ' + str(len(fails))}")
sys.exit(1 if fails else 0)
