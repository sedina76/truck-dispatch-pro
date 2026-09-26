#!/usr/bin/env python3
"""provision_auth_test_identities.py -- creates the 14 F-30 test identities as ORDINARY Supabase Auth users (real, GoTrue-issued sessions) instead of self-signed JWTs,
preserving topology.json's deterministic UUIDs via the Admin API's documented `id` override. See HOSTED_PROVISIONING_PLAN.md for the key-state finding that motivates this
alternative and its trade-offs against key rotation.

NOT EXECUTED BY ANYTHING IN THIS REPOSITORY. MAKES NO HOSTED REQUEST BY ITSELF: `run()` takes an injected `request` callable (the exact same shape role_fixture/probe.py already
uses: `request(method, path, headers, body) -> (status, body_text)`); this module has ZERO network-capable imports of its own (proven by --self-check, same static AST scan as
mint_identity_jwts.py/probe.py). The only code that can actually reach the network is `real_request()` below, which is fully defined but is NEVER called by --self-check or by
tests_auth_provisioning.py -- both inject a fake, in-memory `request` and assert on the calls it recorded.

Why real Auth users still preserve the deterministic design: `auth.admin.createUser`'s `AdminUserAttributes` accepts an optional `id` field that overrides the normally-random
id (confirmed against the actual supabase-js type definitions and corroborated by community migration guides that use it specifically to preserve foreign keys). Each of the 14
identities is therefore created with EXACTLY the uuid already declared in topology.json -- topology.json, model.sql, fixture.sql, build_fixture.py and probe.py need NO change.

THE NULL-IDENTITY REST CASE REMAINS UNPROVEN, PERMANENTLY, VIA THIS TOOL. No ordinary Supabase Auth flow -- password sign-in, magic link, OTP, OAuth, or even anonymous sign-in --
ever issues a session with no `sub` claim; every one of them creates or references a real auth.users row with a real id. This tool has NO code path that could create a 'null'
identity, and `identities()` below never yields one; asking for one is refused outright (see main()). The only standing evidence for the null-identity refusal remains
role_fixture/tests.py's direct-SQL proof on the disposable local cluster; this tool does not change or substitute for that.

Exact UUID verification (required, not optional): after every create AND every sign-in, the id the server actually returns / the session token's own 'sub' claim is compared
BYTE-FOR-BYTE against the uuid this run expects for that identity. Any mismatch aborts the ENTIRE run immediately -- no identity already produced is trusted, no token already
written is left in place unflagged, and no further identity is attempted -- matching this package's "stop on first mismatch, never relax an assertion" convention throughout.

Accountable orphans (a real row WAS created, just not under the id we asked for): if the create call succeeds (200/201) with an unexpected id, that response ALSO tells us
whether the email came back exactly as we sent it -- the one fact we control independently of the server's choice of id. When that email IS confirmed the row is recorded
(env_name, expected_uuid, actual_id, email) to out_dir/ORPHANS.json for cleanup_auth_test_identities.py's 'cleanup-orphans' to remove, AFTER its own independent
re-verification against the live server -- this file never deletes anything itself. When the email is NOT confirmed either, ownership cannot be proven at all: the row is
instead recorded to the SEPARATE out_dir/UNRESOLVED.json (never read by cleanup-orphans, never auto-actionable by anything) and the run exits with the distinct code 3 (not
the ordinary failure code 1) -- unmistakable, and this package will never delete a user whose ownership was never proven.

ENFORCED STOP: run() refuses outright -- before attempting a single identity -- if out_dir already holds an unresolved ORPHANS.json or UNRESOLVED.json from a prior run. A
new provisioning run never starts on top of an unresolved one; resolve the prior run's orphans (cleanup-orphans) or unresolved record (manual investigation) first.

DURABLE, UNMISTAKABLE STATUS: out_dir/PROVISIONING_STATUS.json is (re)written on every exit from run() -- 'complete' (all 14) or 'failed' (naming exactly which identity
stopped it, why, and which ones DID succeed first). Nobody has to infer a partial run from counting token files.

The "already exists" outcome (an idempotent re-run) is detected by an EXACT condition only: HTTP 422 with the response's own error_code field equal to "email_exists" -- never
a substring search over the response body, which could misclassify an unrelated failure that happens to contain the word "already".

Secrets: TDP_F30_SERVICE_ROLE_KEY (env var ONLY, never a CLI argument, never written to a file, never printed) is the sole secret this tool touches. Per-identity passwords are
generated locally with secrets.token_urlsafe, used only in-memory for the immediate sign-in call, and are never written, printed or logged. Every printed line is passed through
scrub() first, which redacts the service-role key, every generated password, and any JWT-shaped string -- the same discipline api_freeze_probe_production.py's own scrub() uses.

Usage (never executed by anything else in this repository):
  python3 provision_auth_test_identities.py --self-check
      Offline, no arguments, no real request ever attempted. Proves: no network-capable import; the target/confirm/env-var guards refuse correctly; exact-UUID verification
      catches a mismatched create response AND a mismatched sign-in token; the out-dir boundary is fail-closed; secrets are scrubbed from all output; a request for a
      null identity is refused outright.
  read -rs "TDP_F30_SERVICE_ROLE_KEY?F-30 test-project service-role key: "; export TDP_F30_SERVICE_ROLE_KEY; echo
  TDP_F30_TEST_PROJECT_REF=<ref> TDP_F30_ENVIRONMENT=nonproduction-f30 \\
  python3 provision_auth_test_identities.py provision --project-ref <ref> --out-dir <dir OUTSIDE this repository> --confirm 'PROVISION F30 AUTH USERS <same ref>'
      NOT RUN BY THIS REVISION. Would call the real Supabase Auth Admin API (a hosted write) for each of the 14 identities.
      The `read -rs "VAR?prompt"` form above is macOS zsh syntax (zsh is macOS's default shell since Catalina): zsh's `read -p` means "read from a coprocess",
      NOT "show this prompt" -- bash's `read -s -p 'prompt' VAR` form FAILS under zsh with 'read:2: -p: no coprocess' and leaves the variable unset. `-r`
      disables backslash interpretation in the typed value. Either way, the key never appears as a literal in the command line, so it is absent from shell
      history and `ps`; `scrub()` also redacts it from every line this tool itself prints.
"""
import argparse
import ast
import base64
import json
import os
import re
import secrets
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
FORBIDDEN_REFS = {"zteixenjpcygjvznueuo", "fjmrvvyjvqdyopnyetez", "localdisposablef30xx"}
FORBIDDEN_IMPORTS = {"urllib", "http", "socket", "requests", "smtplib", "ftplib", "asyncio", "ssl", "paramiko", "telnetlib"}
EMAIL_DOMAIN = "example-test.invalid"  # RFC 2606 reserved, deliberately undeliverable -- never a real mailbox


def topology():
    return json.loads((HERE / "topology.json").read_text())


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def identities():
    """The 14 required identities, in a fixed order. ACTIVELY REFUSES (raises, produces nothing) a role named 'null'/'none' or a missing/malformed uuid -- there is no such
    thing as a null Auth user, so this is a hard invariant, not just an absence of a code path; see the module docstring's NULL-IDENTITY paragraph."""
    t = topology()
    out = []
    for n, org in enumerate(t["organizations"], 1):
        for role, uid in org["identities"].items():
            if role.lower() in ("null", "none", "anonymous") or not uid or not UUID_RE.match(uid):
                raise SystemExit(f"REFUSED: topology.json org {n} role '{role}' is not a valid, real identity (uuid={uid!r}). There is no null/anonymous Auth-user identity this tool will ever provision. STOP.")
            email = f"f30-org{n}-{role.replace('_', '-')}@{EMAIL_DOMAIN}"
            out.append({"env_name": f"TDP_F30_ORG{n}_{role.upper()}_JWT", "org": n, "role": role, "uuid": uid, "email": email})
    return out


def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def decode_claims(jwt: str) -> dict:
    try:
        return json.loads(b64url_decode(jwt.split(".")[1]))
    except (IndexError, ValueError, TypeError):
        return {}


SECRET_ENV_NAMES = ("TDP_F30_SERVICE_ROLE_KEY",)


def scrub(text, extra_secrets=()):
    text = str(text)
    for name in SECRET_ENV_NAMES:
        v = os.environ.get(name)
        if v:
            text = text.replace(v, "[redacted]")
    for s in extra_secrets:
        if s:
            text = text.replace(s, "[redacted]")
    return re.sub(r"eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}(?:\.[A-Za-z0-9_\-]*)?", "[redacted-jwt]", text)


def validate_ref(ref: str):
    if not ref or not re.fullmatch(r"[a-z0-9]{20}", ref or ""):
        raise SystemExit(f"REFUSED: '{ref}' is not a well-formed 20-character project reference. STOP.")
    if ref in FORBIDDEN_REFS or ref.startswith("fjmrvvyjvqd"):
        raise SystemExit(f"REFUSED: '{ref}' is a forbidden reference (production, the deleted temporary test project, or the local-disposable-harness sentinel). STOP.")


def require_target_confirmed(ref: str, env: dict, confirm: str | None, expected_prefix: str):
    """Same allowlist variables role_fixture/probe.py's own validate_target() requires (TDP_F30_TEST_PROJECT_REF / TDP_F30_ENVIRONMENT=nonproduction-f30), PLUS a typed,
    ref-specific confirmation phrase (mirrors discovery_guard.py's --confirm pattern), checked independently of any Auth-user identity -- this tool runs BEFORE any F-30
    identity exists, so it cannot use f30_probe_context() (which itself requires an authenticated owner/admin) the way probe.py's own run() does."""
    if env.get("TDP_F30_TEST_PROJECT_REF") != ref or env.get("TDP_F30_ENVIRONMENT") != "nonproduction-f30":
        raise SystemExit("REFUSED: TDP_F30_TEST_PROJECT_REF (must equal --project-ref) and TDP_F30_ENVIRONMENT=nonproduction-f30 are both required. STOP.")
    expected = f"{expected_prefix} {ref}"
    if confirm != expected:
        raise SystemExit(f"REFUSED: --confirm was not given or did not match exactly. Pass exactly:  --confirm '{expected}'  STOP.")


def repo_root(start: Path) -> Path | None:
    for parent in (start, *start.parents):
        if (parent / ".git").exists():
            return parent
    return None


def refuse_if_inside_repo(out_dir: Path, search_start: Path = HERE):
    root = repo_root(search_start)
    if root is None:
        raise SystemExit("REFUSED: this script's own repository root could not be positively located (no .git found in any ancestor). FAIL CLOSED. STOP.")
    root = root.resolve()
    resolved = out_dir.resolve()
    if resolved == root or root in resolved.parents:
        raise SystemExit(f"REFUSED: --out-dir ({resolved}) is inside this git repository ({root}). Tokens must never be written into the repository. STOP.")


class ProvisioningError(Exception):
    """Raised on any exact-UUID mismatch or unexpected API response; aborts the whole run without writing the mismatched identity's token."""


class OrphanCreatedError(ProvisioningError):
    """Raised specifically when the create call returned 200/201 -- a row WAS created on the server -- but with an id that does not match what was requested.
    Ownership of that specific row is provable ONLY if the response also echoes back the exact email we requested (the one fact we control and can check without
    trusting the server's choice of id); `email_confirmed` records whether that held. run() uses this to write an accountable, cleanable orphan record -- it never
    deletes anything itself (see cleanup_auth_test_identities.py's own, independent ownership re-verification: this file's record is a lead, not a delete order).
    When NOT confirmed, run() instead writes a durable UNRESOLVED.json record (see record_unresolved) -- ownership stays unproven forever unless a human resolves
    it directly against the Auth Admin API; no tool in this package will ever delete based on it."""

    def __init__(self, identity: dict, actual_id, returned_email, email_confirmed: bool):
        self.identity = identity
        self.actual_id = actual_id
        self.returned_email = returned_email
        self.email_confirmed = email_confirmed
        if email_confirmed:
            msg = (f"{identity['env_name']}: create returned id {actual_id!r} but expected {identity['uuid']!r} -- EXACT UUID VERIFICATION FAILED. A row WAS "
                   f"created (its email matches exactly what we requested, so ownership is provable); recorded as an orphan in ORPHANS.json for "
                   f"cleanup_auth_test_identities.py's 'cleanup-orphans' to remove after its own independent re-verification. No token written.")
        else:
            msg = (f"{identity['env_name']}: create returned id {actual_id!r} (expected {identity['uuid']!r}) AND email {returned_email!r} (expected "
                   f"{identity['email']!r}) -- ownership cannot be proven from this response alone. Recorded to UNRESOLVED.json (NOT ORPHANS.json -- no "
                   f"automated tool will ever act on it); this needs manual operator investigation directly against the Auth Admin API before any further "
                   f"provisioning or cleanup can proceed. No token written, no user deleted.")
        super().__init__(msg)


def record_orphan(out_dir: Path, identity: dict, actual_id, email: str):
    """Appends one accountable orphan record to out_dir/ORPHANS.json (created if absent). Never overwrites a prior run's entries. Contains no secret -- ids and
    a synthetic .invalid email are not credentials -- so, unlike the token files, this one file is safe to read back and print for operator review."""
    path = out_dir / "ORPHANS.json"
    existing = json.loads(path.read_text()) if path.exists() else []
    existing.append({"env_name": identity["env_name"], "expected_uuid": identity["uuid"], "actual_id": actual_id, "email": email})
    path.write_text(json.dumps(existing, indent=2))
    os.chmod(path, 0o600)


def record_unresolved(out_dir: Path, identity: dict, actual_id, returned_email):
    """Appends one UNRESOLVED record to out_dir/UNRESOLVED.json (created if absent) -- the durable counterpart to ORPHANS.json for the case ownership could NOT
    be proven at all. Deliberately a SEPARATE file: cleanup_auth_test_identities.py's 'cleanup-orphans' only ever reads ORPHANS.json, so an unresolved record can
    never be picked up and acted on automatically. There is no automated resolver for this file -- clearing an entry is a deliberate, manual operator action
    taken only after investigating directly against the Auth Admin API; see refuse_if_unresolved()."""
    path = out_dir / "UNRESOLVED.json"
    existing = json.loads(path.read_text()) if path.exists() else []
    existing.append({"env_name": identity["env_name"], "expected_uuid": identity["uuid"], "actual_id": actual_id, "expected_email": identity["email"], "returned_email": returned_email})
    path.write_text(json.dumps(existing, indent=2))
    os.chmod(path, 0o600)


def write_status(out_dir: Path, status: str, succeeded: list, failed_identity=None, reason=None):
    """A durable, unmistakable record of the MOST RECENT run() invocation's outcome -- out_dir/PROVISIONING_STATUS.json. 'complete' is written ONLY once every
    one of the 14 identities has been written; 'failed' is written on ANY abort, naming exactly which identity stopped the run and why, and listing every
    identity that DID succeed before it (their token files are legitimate and unaffected -- this file exists so nobody has to infer that from file counting).
    Overwritten (not appended) each run -- it describes the LATEST attempt, not history; ORPHANS.json/UNRESOLVED.json are the durable, cumulative records."""
    path = out_dir / "PROVISIONING_STATUS.json"
    path.write_text(json.dumps({"status": status, "succeeded": succeeded, "failed_identity": failed_identity, "reason": reason}, indent=2))
    os.chmod(path, 0o600)


def refuse_if_unresolved(path: Path, label: str):
    """Refuses (raises, does nothing else) if `path` exists and contains one or more entries -- the enforced stop before a NEW provisioning run, or before
    declaring cleanup complete, per ORPHANS.json / UNRESOLVED.json. A missing file or an empty list ([]) is treated as resolved."""
    if not path.exists():
        return
    try:
        entries = json.loads(path.read_text())
    except (ValueError, TypeError):
        entries = None
    if entries:
        raise SystemExit(f"REFUSED: {len(entries)} unresolved {label} record(s) in {path}. Resolve them first -- see the module docstring. STOP.")


def create_and_sign_in(request, identity: dict, service_role_key: str) -> str:
    """One identity: create (id-pinned) then sign in. Returns the verified access_token. Raises ProvisioningError (or its OrphanCreatedError subclass) on ANY
    mismatch -- never returns a token for an identity whose id was not proven to match, whether from the create response or from the session token's own 'sub'
    claim."""
    password = secrets.token_urlsafe(32)
    headers = {"apikey": service_role_key, "Authorization": f"Bearer {service_role_key}", "Content-Type": "application/json"}
    status, body = request("POST", "/auth/v1/admin/users", headers, {"id": identity["uuid"], "email": identity["email"], "password": password, "email_confirm": True})
    try:
        data = json.loads(body)
    except (ValueError, TypeError):
        data = {}
    # EXACT condition only -- GoTrue's documented signal for this specific case is the structured error_code field, never a substring match over the whole body
    # (a substring match on "already" could misclassify an unrelated failure that happens to contain that word, masking the real cause).
    already_exists = status == 422 and isinstance(data, dict) and data.get("error_code") == "email_exists"
    if status in (200, 201):
        returned_id = data.get("id") if isinstance(data, dict) else None
        if returned_id != identity["uuid"]:
            returned_email = data.get("email") if isinstance(data, dict) else None
            raise OrphanCreatedError(identity, returned_id, returned_email, email_confirmed=returned_email == identity["email"])
    elif not already_exists:
        raise ProvisioningError(f"{identity['env_name']}: create failed (HTTP {status}). Aborting; no token written.")
    # Idempotent re-run: if the identity already exists (from a prior run), we cannot reuse the just-generated password -- this run cannot sign in for it.
    # This is a KNOWN LIMITATION of password-based re-provisioning, not silently worked around: report it as a distinct, named outcome.
    if already_exists:
        raise ProvisioningError(f"{identity['env_name']}: already exists from a prior run; this tool does not know its password and will not guess or reset it. Run cleanup first, or sign in through a separate, explicit re-auth step.")
    status, body = request("POST", "/auth/v1/token?grant_type=password", {**headers, "apikey": service_role_key}, {"email": identity["email"], "password": password})
    try:
        data = json.loads(body)
    except (ValueError, TypeError):
        data = {}
    if status != 200 or not isinstance(data, dict) or "access_token" not in data:
        raise ProvisioningError(f"{identity['env_name']}: sign-in failed (HTTP {status}). Aborting; no token written.")
    token = data["access_token"]
    claims = decode_claims(token)
    if claims.get("sub") != identity["uuid"]:
        raise ProvisioningError(f"{identity['env_name']}: session token's own 'sub' claim ({claims.get('sub')}) does not match the expected {identity['uuid']} -- EXACT UUID VERIFICATION FAILED. Aborting; no token written.")
    if claims.get("role") != "authenticated":
        raise ProvisioningError(f"{identity['env_name']}: session token's role claim is {claims.get('role')!r}, not 'authenticated'. Aborting; no token written.")
    return token


def run(request, service_role_key: str, out_dir: Path):
    """Provisions all 14 identities in the FIXED order identities() returns. Stops at the first ProvisioningError -- never writes a token for an unverified identity,
    never continues past one, and never leaves a partially-written, unverified file behind (each file is written only after full verification of that one identity).

    ENFORCED STOP: refuses outright, before attempting anything, if out_dir already holds an unresolved ORPHANS.json or UNRESOLVED.json from a prior run -- a new
    run never starts on top of an unresolved one.

    DURABLE, UNMISTAKABLE OUTCOME: out_dir/PROVISIONING_STATUS.json is written on every exit from this function -- 'complete' with all 14 names on full success,
    or 'failed' naming exactly which identity stopped the run, why, and which ones DID succeed before it. An OrphanCreatedError with a confirmed email is ALSO
    recorded to out_dir/ORPHANS.json (actionable by cleanup-orphans); one with an UNCONFIRMED email is instead recorded to out_dir/UNRESOLVED.json (never
    auto-actionable -- ownership was never proven, so nothing here or in cleanup_auth_test_identities.py will ever delete it)."""
    refuse_if_unresolved(out_dir / "ORPHANS.json", "orphan")
    refuse_if_unresolved(out_dir / "UNRESOLVED.json", "unresolved-ownership")
    written = []
    for identity in identities():
        try:
            token = create_and_sign_in(request, identity, service_role_key)
        except OrphanCreatedError as e:
            if e.email_confirmed:
                record_orphan(out_dir, identity, e.actual_id, identity["email"])
            else:
                record_unresolved(out_dir, identity, e.actual_id, e.returned_email)
            write_status(out_dir, "failed", written, failed_identity=identity["env_name"], reason=str(e))
            raise
        except ProvisioningError as e:
            write_status(out_dir, "failed", written, failed_identity=identity["env_name"], reason=str(e))
            raise
        path = out_dir / identity["env_name"]
        path.write_text(token)
        os.chmod(path, 0o600)
        written.append(identity["env_name"])
    write_status(out_dir, "complete", written)
    return written


def cmd_provision(args):
    validate_ref(args.project_ref)
    require_target_confirmed(args.project_ref, os.environ, args.confirm, "PROVISION F30 AUTH USERS")
    service_role_key = os.environ.get("TDP_F30_SERVICE_ROLE_KEY", "")
    if not service_role_key:
        raise SystemExit("REFUSED: TDP_F30_SERVICE_ROLE_KEY is not set. This script never accepts it as a command-line argument. STOP.")
    out_dir = Path(args.out_dir)
    refuse_if_inside_repo(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(out_dir, 0o700)
    try:
        written = run(real_request(args.project_ref), service_role_key, out_dir)
    except OrphanCreatedError as e:
        if e.email_confirmed:
            print(scrub(f"ABORTED: {e}"))
            sys.exit(1)
        # Unmistakable and distinct from an ordinary failure: exit code 3, matching this package's own convention for a severe, must-not-auto-resolve condition
        # (compare FREEZE_BREACH's use of exit 3 in api_freeze_probe_production.py) -- automation must never treat this the same as a routine retry-able error.
        print(scrub(f"UNRESOLVED: {e}"))
        sys.exit(3)
    except ProvisioningError as e:
        print(scrub(f"ABORTED: {e}"))
        sys.exit(1)
    print(scrub(f"Wrote {len(written)} token file(s) to {out_dir.resolve()} (mode 0600). No token value or password is printed here."))


def real_request(project_ref: str):
    """Builds the REAL transport. Imports urllib ONLY here (never at module load, never reached by --self-check or the tests) -- defined but NOT called by this revision."""
    import urllib.error
    import urllib.request

    base = f"https://{project_ref}.supabase.co"

    def _request(method, path, headers, body):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    return _request


def _raises(exc_type, fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
        return False
    except exc_type:
        return True


def self_check() -> bool:
    ok = True

    def report(label, passed):
        nonlocal ok
        ok = ok and passed
        print(("ok   " if passed else "FAIL ") + label)

    tree = ast.parse(Path(__file__).read_text())
    imported = set()  # MODULE-SCOPE only (tree.body), so a network import deliberately nested inside real_request() -- never reached by --self-check -- does not trip this
    for node in tree.body:
        if isinstance(node, ast.Import):
            imported.update(n.name.split(".")[0] for n in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    report("no network-capable module is imported at MODULE SCOPE by this file", imported.isdisjoint(FORBIDDEN_IMPORTS))
    report(f"module-scope imports found: {sorted(imported)}", True)
    nested_in_real_request = {n.name.split(".")[0] for fn in ast.walk(tree) if isinstance(fn, ast.FunctionDef) and fn.name == "real_request" for node in ast.walk(fn) if isinstance(node, ast.Import) for n in node.names}
    report("the network import that DOES exist is confined inside real_request() (never called by --self-check or the tests)", nested_in_real_request == {"urllib"})

    ids = identities()
    report("identities() yields exactly 14 entries (2 orgs x 7 roles), never a null/15th entry", len(ids) == 14)
    fake_topology_with_null = {"organizations": [{"identities": {"owner": "11111111-1111-1111-1111-111111111111", "null": None}}]}
    _real_topology = globals()["topology"]
    globals()["topology"] = lambda: fake_topology_with_null
    try:
        identities()
        report("a role literally named 'null' (or a missing uuid) in topology.json is ACTIVELY REFUSED, not silently skipped", False)
    except SystemExit:
        report("a role literally named 'null' (or a missing uuid) in topology.json is ACTIVELY REFUSED, not silently skipped", True)
    finally:
        globals()["topology"] = _real_topology
    report("every email is under the reserved .invalid test domain and encodes org+role uniquely", len({i["email"] for i in ids}) == 14 and all(i["email"].endswith("@" + EMAIL_DOMAIN) for i in ids))

    REF = "abcdefghij0123456789"
    calls = []

    def fake_ok(method, path, headers, body):
        calls.append((method, path, body))
        if path == "/auth/v1/admin/users":
            return 201, json.dumps({"id": body["id"], "email": body["email"]})
        if path.startswith("/auth/v1/token"):
            claims = {"sub": body["_expect_sub"], "role": "authenticated"} if "_expect_sub" in body else {"sub": [i for i in ids if i["email"] == body["email"]][0]["uuid"], "role": "authenticated"}
            enc = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
            return 200, json.dumps({"access_token": f"header.{enc}.sig"})
        return 404, "{}"

    import tempfile

    with tempfile.TemporaryDirectory() as td:
        written = run(fake_ok, "fake-service-role-key-not-real", Path(td))
        report("a full, verified provisioning run writes all 14 expected files with a fake transport (no real request made)", sorted(written) == sorted(i["env_name"] for i in ids))
        report("every written token's sub matches the expected uuid for its file name", all(decode_claims(Path(td, i["env_name"]).read_text()).get("sub") == i["uuid"] for i in ids))
        report("every written file is mode 0600", all(oct(Path(td, i["env_name"]).stat().st_mode)[-3:] == "600" for i in ids))
        status = json.loads((Path(td) / "PROVISIONING_STATUS.json").read_text())
        report("a full success writes PROVISIONING_STATUS.json with status=complete and all 14 names -- durable, not just inferred from file counting",
               status["status"] == "complete" and sorted(status["succeeded"]) == sorted(i["env_name"] for i in ids) and status["failed_identity"] is None and status["reason"] is None)
        rerun_written = run(fake_ok, "fake-service-role-key-not-real", Path(td))  # a clean, already-complete out_dir never blocks a fresh call (no leftover ORPHANS/UNRESOLVED)
        report("a subsequent run against a CLEAN out_dir (no unresolved records left behind) is never blocked by refuse_if_unresolved", sorted(rerun_written) == sorted(i["env_name"] for i in ids))
    report("exactly 56 requests were made across the two full runs above (28 each), never a stray call", len(calls) == 56)

    def fake_wrong_create_id_confirmed_email(method, path, headers, body):
        if path == "/auth/v1/admin/users":
            return 201, json.dumps({"id": "00000000-0000-0000-0000-000000000000", "email": body["email"]})
        return 404, "{}"

    with tempfile.TemporaryDirectory() as td:
        try:
            run(fake_wrong_create_id_confirmed_email, "x", Path(td))
            report("a create response with the WRONG id but a CONFIRMED email raises OrphanCreatedError and writes NO token file", False)
        except OrphanCreatedError:
            report("a create response with the WRONG id but a CONFIRMED email raises OrphanCreatedError and writes NO token file",
                   sorted(p.name for p in Path(td).iterdir()) == ["ORPHANS.json", "PROVISIONING_STATUS.json"])
        orphans = json.loads((Path(td) / "ORPHANS.json").read_text())
        report("the orphan is recorded with the actual (unexpected) id, the expected uuid, and the confirmed email -- exactly one entry", orphans == [{"env_name": ids[0]["env_name"], "expected_uuid": ids[0]["uuid"], "actual_id": "00000000-0000-0000-0000-000000000000", "email": ids[0]["email"]}])
        report("ORPHANS.json is written mode 0600, same as a token file", oct((Path(td) / "ORPHANS.json").stat().st_mode)[-3:] == "600")
        status = json.loads((Path(td) / "PROVISIONING_STATUS.json").read_text())
        report("PROVISIONING_STATUS.json durably records status=failed, WHICH identity failed and why, and that nothing succeeded before it",
               status["status"] == "failed" and status["failed_identity"] == ids[0]["env_name"] and status["succeeded"] == [] and "EXACT UUID VERIFICATION FAILED" in status["reason"])
        report("ENFORCED STOP: a subsequent run() REFUSES outright while ORPHANS.json is unresolved -- no identity is even attempted", _raises(SystemExit, run, fake_ok, "x", Path(td)) and len(calls) == 56)
        (Path(td) / "ORPHANS.json").write_text("[]")  # simulate a completed cleanup-orphans
        run(fake_ok, "x", Path(td))  # must NOT raise now that the orphan record is resolved (emptied)
        report("once ORPHANS.json is emptied (resolved), a subsequent run() is no longer blocked", True)

    def fake_wrong_create_id_and_email(method, path, headers, body):
        if path == "/auth/v1/admin/users":
            return 201, json.dumps({"id": "00000000-0000-0000-0000-000000000000", "email": "not-what-we-asked-for@example.com"})
        return 404, "{}"

    with tempfile.TemporaryDirectory() as td:
        try:
            run(fake_wrong_create_id_and_email, "x", Path(td))
            report("a create response with the WRONG id AND an unrecognized email raises but does NOT record an (unverifiable) ORPHAN", False)
        except OrphanCreatedError as e:
            report("a create response with the WRONG id AND an unrecognized email raises but does NOT record an (unverifiable) ORPHAN",
                   not e.email_confirmed and not (Path(td) / "ORPHANS.json").exists())
        report("...instead it is recorded, durably, to the SEPARATE UNRESOLVED.json", (Path(td) / "UNRESOLVED.json").exists())
        unresolved = json.loads((Path(td) / "UNRESOLVED.json").read_text())
        report("the unresolved record carries BOTH the wrong actual id AND the wrong returned email, plus what was expected -- exactly one entry",
               unresolved == [{"env_name": ids[0]["env_name"], "expected_uuid": ids[0]["uuid"], "actual_id": "00000000-0000-0000-0000-000000000000", "expected_email": ids[0]["email"], "returned_email": "not-what-we-asked-for@example.com"}])
        report("UNRESOLVED.json is written mode 0600", oct((Path(td) / "UNRESOLVED.json").stat().st_mode)[-3:] == "600")
        status = json.loads((Path(td) / "PROVISIONING_STATUS.json").read_text())
        report("PROVISIONING_STATUS.json ALSO records this as failed (the unresolved case is never mistaken for a completed run)", status["status"] == "failed" and status["failed_identity"] == ids[0]["env_name"])
        report("ENFORCED STOP: a subsequent run() REFUSES outright while UNRESOLVED.json has entries -- there is no automated way to clear it (by design)", _raises(SystemExit, run, fake_ok, "x", Path(td)))

    def fake_plain_failure(method, path, headers, body):
        if path == "/auth/v1/admin/users":
            return 500, "{}"
        return 404, "{}"

    with tempfile.TemporaryDirectory() as td:
        try:
            run(fake_plain_failure, "x", Path(td))
            report("an ordinary (non-orphan) ProvisioningError ALSO writes a durable failed PROVISIONING_STATUS.json", False)
        except ProvisioningError:
            status = json.loads((Path(td) / "PROVISIONING_STATUS.json").read_text())
            report("an ordinary (non-orphan) ProvisioningError ALSO writes a durable failed PROVISIONING_STATUS.json", status["status"] == "failed" and status["failed_identity"] == ids[0]["env_name"] and not (Path(td) / "ORPHANS.json").exists() and not (Path(td) / "UNRESOLVED.json").exists())

    def fake_unrelated_error_mentioning_the_word_already(method, path, headers, body):
        if path == "/auth/v1/admin/users":
            return 500, json.dumps({"error_code": "unexpected_failure", "msg": "the database connection pool has already been exhausted"})
        return 404, "{}"

    with tempfile.TemporaryDirectory() as td:
        try:
            run(fake_unrelated_error_mentioning_the_word_already, "x", Path(td))
            report("an UNRELATED failure whose message happens to contain the word 'already' is NOT misclassified as already-exists (exact error_code/status match only)", False)
        except ProvisioningError as e:
            report("an UNRELATED failure whose message happens to contain the word 'already' is NOT misclassified as already-exists (exact error_code/status match only)",
                   "create failed (HTTP 500)" in str(e) and "already exists" not in str(e) and [p.name for p in Path(td).iterdir()] == ["PROVISIONING_STATUS.json"])

    def fake_wrong_signin_sub(method, path, headers, body):
        if path == "/auth/v1/admin/users":
            return 201, json.dumps({"id": body["id"], "email": body["email"]})
        if path.startswith("/auth/v1/token"):
            enc = base64.urlsafe_b64encode(json.dumps({"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}).encode()).decode().rstrip("=")
            return 200, json.dumps({"access_token": f"h.{enc}.s"})
        return 404, "{}"

    with tempfile.TemporaryDirectory() as td:
        try:
            run(fake_wrong_signin_sub, "x", Path(td))
            report("a sign-in token whose 'sub' does not match the expected uuid raises ProvisioningError and writes nothing", False)
        except ProvisioningError:
            report("a sign-in token whose 'sub' does not match the expected uuid raises ProvisioningError and writes no TOKEN file (only the durable status record)",
                   [p.name for p in Path(td).iterdir()] == ["PROVISIONING_STATUS.json"])

    def fake_already_exists(method, path, headers, body):
        if path == "/auth/v1/admin/users":
            return 422, json.dumps({"error_code": "email_exists", "msg": "User already registered"})
        return 404, "{}"

    with tempfile.TemporaryDirectory() as td:
        try:
            run(fake_already_exists, "x", Path(td))
            report("an already-exists response is reported as a distinct, named outcome (not silently treated as success)", False)
        except ProvisioningError as e:
            report("an already-exists response is reported as a distinct, named outcome (not silently treated as success)", "already exists" in str(e))

    try:
        require_target_confirmed(REF, {}, None, "PROVISION F30 AUTH USERS")
        report("provisioning is refused with no TDP_F30_TEST_PROJECT_REF/TDP_F30_ENVIRONMENT/--confirm at all", False)
    except SystemExit:
        report("provisioning is refused with no TDP_F30_TEST_PROJECT_REF/TDP_F30_ENVIRONMENT/--confirm at all", True)
    try:
        require_target_confirmed(REF, {"TDP_F30_TEST_PROJECT_REF": REF, "TDP_F30_ENVIRONMENT": "nonproduction-f30"}, "PROVISION F30 AUTH USERS some-other-ref", "PROVISION F30 AUTH USERS")
        report("provisioning is refused when --confirm does not match this exact --project-ref", False)
    except SystemExit:
        report("provisioning is refused when --confirm does not match this exact --project-ref", True)
    require_target_confirmed(REF, {"TDP_F30_TEST_PROJECT_REF": REF, "TDP_F30_ENVIRONMENT": "nonproduction-f30"}, f"PROVISION F30 AUTH USERS {REF}", "PROVISION F30 AUTH USERS")
    report("provisioning proceeds only with the exact, ref-specific confirmation phrase and the matching allowlist env vars", True)

    try:
        refuse_if_inside_repo(HERE)
        report("--out-dir inside the repository is refused", False)
    except SystemExit:
        report("--out-dir inside the repository is refused", True)
    with tempfile.TemporaryDirectory() as td:
        no_git_dir = Path(td) / "no_git_here"
        no_git_dir.mkdir()
        try:
            refuse_if_inside_repo(Path(td), search_start=no_git_dir)
            report("FAILS CLOSED when the repository root cannot be located at all", False)
        except SystemExit:
            report("FAILS CLOSED when the repository root cannot be located at all", True)

    os.environ["TDP_F30_SERVICE_ROLE_KEY"] = "self-check-throwaway-service-role-key"
    scrubbed = scrub(f"leaked value: {os.environ['TDP_F30_SERVICE_ROLE_KEY']} and a jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig", extra_secrets=("a-generated-password-1234",))
    report("scrub() redacts the service-role key and JWT-shaped strings from any printed output", "self-check-throwaway-service-role-key" not in scrubbed and "eyJ" not in scrubbed.replace("[redacted-jwt]", ""))
    report("scrub() also redacts an explicitly-passed extra secret (e.g. a generated password)", "a-generated-password-1234" not in scrub("password was a-generated-password-1234", extra_secrets=("a-generated-password-1234",)))
    del os.environ["TDP_F30_SERVICE_ROLE_KEY"]

    # A deterministic call-count check (never a global sys.modules probe, which is process-wide and can be spuriously tripped by something ELSE in the same
    # process importing urllib for an unrelated reason -- the AST check above already proves the import is confined to real_request()'s body; this proves
    # self_check() itself never CALLS it).
    _orig_real_request = globals()["real_request"]
    _calls = []
    globals()["real_request"] = lambda ref: _calls.append(ref) or _orig_real_request(ref)
    try:
        report("real_request is defined (for later, authorized use) but --self-check never calls it", "real_request" in globals() and _calls == [])
    finally:
        globals()["real_request"] = _orig_real_request

    return ok


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--self-check", action="store_true")
    sub = p.add_subparsers(dest="cmd")
    prov = sub.add_parser("provision")
    prov.add_argument("--project-ref", required=True)
    prov.add_argument("--out-dir", required=True)
    prov.add_argument("--confirm", default=None)
    args = p.parse_args()
    if args.self_check:
        sys.exit(0 if self_check() else 1)
    if args.cmd == "provision":
        cmd_provision(args)
        return
    p.print_help()
    sys.exit(2)


if __name__ == "__main__":
    main()
