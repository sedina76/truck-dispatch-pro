#!/usr/bin/env python3
"""cleanup_auth_test_identities.py -- removes the 14 F-30 Auth test users created by provision_auth_test_identities.py. See HOSTED_PROVISIONING_PLAN.md.

NOT EXECUTED BY ANYTHING IN THIS REPOSITORY. MAKES NO HOSTED REQUEST BY ITSELF: `run()` takes an injected `request` callable, identical in shape to
provision_auth_test_identities.py's own; this module has ZERO network-capable imports at module scope (proven by --self-check). The only network-capable import
(`real_request()`) is defined but never called by --self-check or by tests_auth_provisioning.py.

REFUSES TO DELETE ANY USER IT CANNOT PROVE BELONGS TO THIS F-30 RUN. For each of the 14 known (uuid, expected-email) pairs from topology.json, this tool:
  1. FETCHES the user by id first (GET) -- it never deletes blind, by id alone, and never deletes based on a locally-assumed record.
  2. If not found: treated as an already-clean no-op, not an error, not a deletion.
  3. If found: the RETURNED record's own 'id' AND 'email' must BOTH equal EXACTLY the one pairing topology.json declares for that identity, AND the email must match
     the strict f30-org{N}-{role}@example-test.invalid pattern this fixture always uses. A match on id alone, or email alone, or a similarly-shaped but wrong email,
     is a REFUSAL, not a deletion -- and refusal is a reported FAILURE requiring operator attention, not a silent skip, since it usually means something unexpected
     is using one of this fixture's reserved ids.
  4. Only after ALL of the above passes does it call DELETE, and it verifies the response before counting the identity as removed.
Aborts the ENTIRE run at the first ownership-check failure (matching this package's "stop on first mismatch" convention) -- it never proceeds past a user it could not
positively identify as its own, even to clean up the other 13.

Secrets: TDP_F30_SERVICE_ROLE_KEY (env var ONLY, same discipline as the provisioning tool) is the sole secret. Every printed line is scrubbed the same way.

Usage (never executed by anything else in this repository):
  python3 cleanup_auth_test_identities.py --self-check
  read -rs "TDP_F30_SERVICE_ROLE_KEY?F-30 test-project service-role key: "; export TDP_F30_SERVICE_ROLE_KEY; echo
  TDP_F30_TEST_PROJECT_REF=<ref> TDP_F30_ENVIRONMENT=nonproduction-f30 \\
  python3 cleanup_auth_test_identities.py cleanup --project-ref <ref> --confirm 'CLEANUP F30 AUTH USERS <same ref>' \\
      --orphans-file <the provisioning run's --out-dir>/ORPHANS.json --unresolved-file <same --out-dir>/UNRESOLVED.json
      NOT RUN BY THIS REVISION. Would call the real Supabase Auth Admin API (a hosted write) to fetch-then-delete each of the 14 identities.
      The `read -rs "VAR?prompt"` form above is macOS zsh syntax, same reason as provision_auth_test_identities.py's own docstring (zsh's `-p` means "read
      from a coprocess", not "show this prompt"; bash's `read -s -p 'prompt' VAR` form fails under zsh).
      --orphans-file and --unresolved-file are MANDATORY (argparse itself refuses to start without both): hosted cleanup must always be pointed at the
      corresponding provisioning run's records, so it can refuse to run at all while either still holds an unresolved entry. Neither file needs to already
      exist -- a path with nothing recorded at it is treated as resolved -- but the flag itself may never be omitted.
"""
import argparse
import ast
import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
FORBIDDEN_REFS = {"zteixenjpcygjvznueuo", "fjmrvvyjvqdyopnyetez", "localdisposablef30xx"}
FORBIDDEN_IMPORTS = {"urllib", "http", "socket", "requests", "smtplib", "ftplib", "asyncio", "ssl", "paramiko", "telnetlib"}
EMAIL_DOMAIN = "example-test.invalid"
EMAIL_RE = re.compile(r"^f30-org([12])-([a-z-]+)@" + re.escape(EMAIL_DOMAIN) + r"$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def topology():
    return json.loads((HERE / "topology.json").read_text())


def identities():
    t = topology()
    out = []
    for n, org in enumerate(t["organizations"], 1):
        for role, uid in org["identities"].items():
            if role.lower() in ("null", "none", "anonymous") or not uid or not UUID_RE.match(uid):
                raise SystemExit(f"REFUSED: topology.json org {n} role '{role}' is not a valid identity (uuid={uid!r}). STOP.")
            email = f"f30-org{n}-{role.replace('_', '-')}@{EMAIL_DOMAIN}"
            out.append({"env_name": f"TDP_F30_ORG{n}_{role.upper()}_JWT", "org": n, "role": role, "uuid": uid, "email": email})
    return out


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
        raise SystemExit(f"REFUSED: '{ref}' is a forbidden reference. STOP.")


def require_target_confirmed(ref: str, env: dict, confirm: str | None, expected_prefix: str = "CLEANUP F30 AUTH USERS"):
    if env.get("TDP_F30_TEST_PROJECT_REF") != ref or env.get("TDP_F30_ENVIRONMENT") != "nonproduction-f30":
        raise SystemExit("REFUSED: TDP_F30_TEST_PROJECT_REF (must equal --project-ref) and TDP_F30_ENVIRONMENT=nonproduction-f30 are both required. STOP.")
    expected = f"{expected_prefix} {ref}"
    if confirm != expected:
        raise SystemExit(f"REFUSED: --confirm was not given or did not match exactly. Pass exactly:  --confirm '{expected}'  STOP.")


class OwnershipError(Exception):
    """Raised when a fetched user cannot be positively proven to belong to this F-30 run. Never followed by a delete call."""


class CleanupError(Exception):
    """Raised on any other unexpected response (fetch failure other than 404, or a delete that does not succeed)."""


def refuse_if_unresolved(path, label):
    """Refuses (raises, does nothing else) if `path` is given and exists and contains one or more entries -- the same enforced-stop predicate
    provision_auth_test_identities.py uses before a new provisioning run, reused here so 'cleanup complete' means the same thing in both tools. A missing path
    argument, a missing file, or an empty list ([]) are all treated as resolved."""
    if path is None:
        return
    path = Path(path)
    if not path.exists():
        return
    try:
        entries = json.loads(path.read_text())
    except (ValueError, TypeError):
        entries = None
    if entries:
        raise SystemExit(f"REFUSED: {len(entries)} unresolved {label} record(s) in {path}. Cleanup cannot be declared complete until they are resolved. STOP.")


def verify_ownership(identity: dict, record: dict):
    """The single ownership predicate: id AND email must BOTH equal exactly what topology.json declares, AND the email must match the strict, generated pattern.
    Any one of these failing is a refusal, regardless of what the other two say."""
    m = EMAIL_RE.match(record.get("email", "") or "")
    if record.get("id") != identity["uuid"]:
        raise OwnershipError(f"{identity['env_name']}: fetched record's id ({record.get('id')}) does not match topology.json's ({identity['uuid']}). REFUSING to delete.")
    if record.get("email") != identity["email"]:
        raise OwnershipError(f"{identity['env_name']}: fetched record's email ({record.get('email')!r}) does not match the expected {identity['email']!r}. REFUSING to delete -- id alone is never sufficient proof.")
    if not m or int(m.group(1)) != identity["org"] or m.group(2) != identity["role"].replace("_", "-"):
        raise OwnershipError(f"{identity['env_name']}: email does not match the strict f30-org{{N}}-{{role}} reserved pattern. REFUSING to delete.")


def run(request, service_role_key: str):
    """Fetch-then-verify-then-delete, in identities()'s fixed order. Stops at the first OwnershipError or CleanupError -- an identity it cannot positively prove is
    its own is left untouched, and no identity AFTER it in the order is even attempted."""
    headers = {"apikey": service_role_key, "Authorization": f"Bearer {service_role_key}"}
    deleted, already_absent = [], []
    for identity in identities():
        status, body = request("GET", f"/auth/v1/admin/users/{identity['uuid']}", headers, None)
        if status == 404:
            already_absent.append(identity["env_name"])
            continue
        if status != 200:
            raise CleanupError(f"{identity['env_name']}: fetch failed (HTTP {status}). Aborting; nothing further deleted.")
        try:
            record = json.loads(body)
        except (ValueError, TypeError):
            record = {}
        verify_ownership(identity, record)  # raises OwnershipError, uncaught -- aborts the whole run
        status, _ = request("DELETE", f"/auth/v1/admin/users/{identity['uuid']}", headers, None)
        if status not in (200, 204):
            raise CleanupError(f"{identity['env_name']}: delete did not succeed (HTTP {status}). Aborting; nothing further deleted.")
        deleted.append(identity["env_name"])
    return deleted, already_absent


def verify_orphan_ownership(orphan: dict, record: dict):
    """The same rigor as verify_ownership, but keyed on the orphan RECORD's own captured facts (its actual_id and the email provisioning independently confirmed
    at creation time) instead of topology.json -- this is what makes it safe to delete a row whose id was never in topology.json at all. The orphan file is a
    LEAD, never trusted alone: every field is re-checked against what the server ACTUALLY returns for that id, right now, before any delete."""
    if record.get("id") != orphan["actual_id"]:
        raise OwnershipError(f"orphan {orphan['env_name']}: fetched record's id ({record.get('id')}) does not match the recorded actual_id ({orphan['actual_id']}). REFUSING to delete.")
    if record.get("email") != orphan["email"]:
        raise OwnershipError(f"orphan {orphan['env_name']}: fetched record's email ({record.get('email')!r}) does not match the recorded {orphan['email']!r}. REFUSING to delete.")
    if not EMAIL_RE.match(orphan.get("email", "") or ""):
        raise OwnershipError(f"orphan {orphan['env_name']}: the recorded email does not match the strict f30-org{{N}}-{{role}} reserved pattern. REFUSING to delete.")


def run_orphans(request, service_role_key: str, orphans: list):
    """Same fetch-then-verify-then-delete shape and same stop-at-first-failure discipline as run(), but over an explicit, pre-recorded orphan list (from
    provision_auth_test_identities.py's ORPHANS.json) instead of topology.json's 14 -- it never scans or guesses; it only ever considers ids it was explicitly told
    about, each independently re-verified against the live server before any delete.

    On ANY failure the raised exception carries `.resolved_env_names` -- exactly the orphans that WERE deleted or confirmed already-absent before the failure --
    so the caller (cmd_cleanup_orphans) can persist the TRUE remaining set back to the orphans file, never losing partial progress and never re-declaring an
    already-resolved entry as still outstanding."""
    headers = {"apikey": service_role_key, "Authorization": f"Bearer {service_role_key}"}
    deleted, already_absent = [], []
    for orphan in orphans:
        try:
            status, body = request("GET", f"/auth/v1/admin/users/{orphan['actual_id']}", headers, None)
            if status == 404:
                already_absent.append(orphan["env_name"])
                continue
            if status != 200:
                raise CleanupError(f"orphan {orphan['env_name']}: fetch failed (HTTP {status}). Aborting; nothing further deleted.")
            try:
                record = json.loads(body)
            except (ValueError, TypeError):
                record = {}
            verify_orphan_ownership(orphan, record)
            status, _ = request("DELETE", f"/auth/v1/admin/users/{orphan['actual_id']}", headers, None)
            if status not in (200, 204):
                raise CleanupError(f"orphan {orphan['env_name']}: delete did not succeed (HTTP {status}). Aborting; nothing further deleted.")
            deleted.append(orphan["env_name"])
        except (OwnershipError, CleanupError) as e:
            e.resolved_env_names = list(deleted) + list(already_absent)
            raise
    return deleted, already_absent


def write_remaining_orphans(orphans_file: Path, orphans: list, resolved_env_names):
    """Rewrites orphans_file to contain ONLY the entries NOT in resolved_env_names -- called after every cleanup-orphans attempt, success or failure, so the
    file always reflects the TRUE outstanding set. A fully successful run therefore leaves it as an empty list ([]), which refuse_if_unresolved() treats as
    resolved; a partial failure keeps exactly the unresolved remainder (the one that failed, plus anything after it that was never attempted)."""
    resolved = set(resolved_env_names)
    remaining = [o for o in orphans if o["env_name"] not in resolved]
    orphans_file.write_text(json.dumps(remaining, indent=2))
    os.chmod(orphans_file, 0o600)


def cmd_cleanup(args):
    """`--orphans-file`/`--unresolved-file` are MANDATORY, not optional: hosted cleanup of the 14 named identities never reads or writes either file itself (it
    has nothing to do with orphans), but the operator must always point it at the corresponding provisioning run's `ORPHANS.json`/`UNRESOLVED.json` (from that
    run's `--out-dir`) so this pre-flight check can run. Omitting either flag entirely is refused by argparse itself (`required=True` on both, see main()) before
    this function is ever reached -- a missing check is not an option, only a file that happens not to exist yet is (refuse_if_unresolved treats a nonexistent
    path as resolved, since no provisioning run has left anything outstanding at it). If either file DOES hold unresolved entries, this refuses to even start,
    so 'cleanup complete' can never be declared -- for the 14, or for the run as a whole -- while an orphan/unresolved-ownership record from provisioning is
    still outstanding."""
    validate_ref(args.project_ref)
    refuse_if_unresolved(args.orphans_file, "orphan")
    refuse_if_unresolved(args.unresolved_file, "unresolved-ownership")
    require_target_confirmed(args.project_ref, os.environ, args.confirm)
    service_role_key = os.environ.get("TDP_F30_SERVICE_ROLE_KEY", "")
    if not service_role_key:
        raise SystemExit("REFUSED: TDP_F30_SERVICE_ROLE_KEY is not set. STOP.")
    try:
        deleted, already_absent = run(real_request(args.project_ref), service_role_key)
    except (OwnershipError, CleanupError) as e:
        print(scrub(f"ABORTED: {e}"))
        sys.exit(1)
    print(scrub(f"Deleted {len(deleted)}; already absent (no-op) {len(already_absent)}."))


def cmd_cleanup_orphans(args):
    """Persists the TRUE remaining state back to --orphans-file on EVERY outcome, success or failure (write_remaining_orphans), so the file itself is always
    the live source of truth for refuse_if_unresolved() -- a full success leaves it '[]' (resolved), a partial failure leaves exactly the still-outstanding
    entries, and nothing here ever silently leaves a stale, already-resolved entry sitting in the file to block a later run forever."""
    validate_ref(args.project_ref)
    require_target_confirmed(args.project_ref, os.environ, args.confirm, expected_prefix="CLEANUP F30 ORPHANS")
    service_role_key = os.environ.get("TDP_F30_SERVICE_ROLE_KEY", "")
    if not service_role_key:
        raise SystemExit("REFUSED: TDP_F30_SERVICE_ROLE_KEY is not set. STOP.")
    orphans_file = Path(args.orphans_file)
    orphans = json.loads(orphans_file.read_text())
    try:
        deleted, already_absent = run_orphans(real_request(args.project_ref), service_role_key, orphans)
    except (OwnershipError, CleanupError) as e:
        resolved = getattr(e, "resolved_env_names", [])
        write_remaining_orphans(orphans_file, orphans, resolved)
        print(scrub(f"ABORTED: {e}"))
        sys.exit(1)
    write_remaining_orphans(orphans_file, orphans, deleted + already_absent)
    print(scrub(f"Deleted {len(deleted)} orphan(s); already absent (no-op) {len(already_absent)}. {args.orphans_file} updated to reflect the remaining (now empty) set."))


def real_request(project_ref: str):
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
    imported = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            imported.update(n.name.split(".")[0] for n in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    report("no network-capable module is imported at MODULE SCOPE by this file", imported.isdisjoint(FORBIDDEN_IMPORTS))
    nested = {n.name.split(".")[0] for fn in ast.walk(tree) if isinstance(fn, ast.FunctionDef) and fn.name == "real_request" for node in ast.walk(fn) if isinstance(node, ast.Import) for n in node.names}
    report("the network import that DOES exist is confined inside real_request() (never called by --self-check or the tests)", nested == {"urllib"})

    ids = identities()
    report("identities() yields exactly 14 entries, matching provision_auth_test_identities.py's own", len(ids) == 14)

    def fake_all_present_and_owned(method, path, headers, body):
        uid = path.rsplit("/", 1)[1]
        ident = next(i for i in ids if i["uuid"] == uid)
        if method == "GET":
            return 200, json.dumps({"id": uid, "email": ident["email"]})
        if method == "DELETE":
            return 204, ""
        return 404, "{}"

    deleted, absent = run(fake_all_present_and_owned, "fake-key")
    report("a clean run with every user present and correctly owned deletes all 14 and reports none absent", sorted(deleted) == sorted(i["env_name"] for i in ids) and absent == [])

    def fake_all_absent(method, path, headers, body):
        return 404, "{}"

    deleted, absent = run(fake_all_absent, "fake-key")
    report("if none of the 14 exist, cleanup is a clean no-op (0 deleted, 14 already-absent) -- not an error", deleted == [] and len(absent) == 14)

    def fake_wrong_email(method, path, headers, body):
        uid = path.rsplit("/", 1)[1]
        if method == "GET":
            return 200, json.dumps({"id": uid, "email": "someone-real@example.com"})
        return 500, "{}"  # DELETE must never even be attempted

    try:
        run(fake_wrong_email, "fake-key")
        report("a user whose id matches but whose email does NOT match the expected pattern is REFUSED, never deleted", False)
    except OwnershipError:
        report("a user whose id matches but whose email does NOT match the expected pattern is REFUSED, never deleted", True)

    def fake_wrong_id_in_body(method, path, headers, body):
        uid = path.rsplit("/", 1)[1]
        ident = next(i for i in ids if i["uuid"] == uid)
        if method == "GET":
            return 200, json.dumps({"id": "22222222-2222-2222-2222-222222222222", "email": ident["email"]})
        return 500, "{}"

    try:
        run(fake_wrong_id_in_body, "fake-key")
        report("a fetched record whose id does not match (even with the right email) is REFUSED, never deleted", False)
    except OwnershipError:
        report("a fetched record whose id does not match (even with the right email) is REFUSED, never deleted", True)

    def fake_lookalike_email(method, path, headers, body):
        uid = path.rsplit("/", 1)[1]
        if method == "GET":
            return 200, json.dumps({"id": uid, "email": "f30-org1-owner.evil@example-test.invalid"})
        return 500, "{}"

    try:
        run(fake_lookalike_email, "fake-key")
        report("a similarly-shaped but not-exactly-matching email is REFUSED, never deleted (no fuzzy/substring matching)", False)
    except OwnershipError:
        report("a similarly-shaped but not-exactly-matching email is REFUSED, never deleted (no fuzzy/substring matching)", True)

    calls_after_failure = []

    def fake_stops_at_first_failure(method, path, headers, body):
        calls_after_failure.append((method, path))
        uid = path.rsplit("/", 1)[1]
        ident = next(i for i in ids if i["uuid"] == uid)
        if ident["env_name"] == ids[0]["env_name"]:
            if method == "GET":
                return 200, json.dumps({"id": uid, "email": "wrong@example-test.invalid"})
        return 404, "{}"

    try:
        run(fake_stops_at_first_failure, "fake-key")
    except OwnershipError:
        pass
    report("the run ABORTS at the first ownership failure -- it never even attempts to look up the remaining identities", calls_after_failure == [("GET", f"/auth/v1/admin/users/{ids[0]['uuid']}")])

    REF = "abcdefghij0123456789"
    try:
        require_target_confirmed(REF, {}, None)
        report("cleanup is refused with no TDP_F30_TEST_PROJECT_REF/TDP_F30_ENVIRONMENT/--confirm at all", False)
    except SystemExit:
        report("cleanup is refused with no TDP_F30_TEST_PROJECT_REF/TDP_F30_ENVIRONMENT/--confirm at all", True)
    require_target_confirmed(REF, {"TDP_F30_TEST_PROJECT_REF": REF, "TDP_F30_ENVIRONMENT": "nonproduction-f30"}, f"CLEANUP F30 AUTH USERS {REF}")
    report("cleanup proceeds only with the exact, ref-specific confirmation phrase and the matching allowlist env vars", True)
    require_target_confirmed(REF, {"TDP_F30_TEST_PROJECT_REF": REF, "TDP_F30_ENVIRONMENT": "nonproduction-f30"}, f"CLEANUP F30 ORPHANS {REF}", expected_prefix="CLEANUP F30 ORPHANS")
    report("cleanup-orphans uses its OWN distinct confirmation phrase (never accepted for the main 'cleanup' path or vice versa)",
           _raises(SystemExit, require_target_confirmed, REF, {"TDP_F30_TEST_PROJECT_REF": REF, "TDP_F30_ENVIRONMENT": "nonproduction-f30"}, f"CLEANUP F30 AUTH USERS {REF}", expected_prefix="CLEANUP F30 ORPHANS"))

    orphan = {"env_name": "TDP_F30_ORG1_OWNER_JWT", "expected_uuid": ids[0]["uuid"], "actual_id": "00000000-0000-0000-0000-000000000000", "email": ids[0]["email"]}

    def fake_orphan_present_and_owned(method, path, headers, body):
        if method == "GET":
            return 200, json.dumps({"id": orphan["actual_id"], "email": orphan["email"]})
        if method == "DELETE":
            return 204, ""
        return 404, "{}"

    deleted, absent = run_orphans(fake_orphan_present_and_owned, "fake-key", [orphan])
    report("run_orphans deletes a correctly-owned orphan by its ACTUAL id (never the topology-expected uuid, which the server never had)", deleted == [orphan["env_name"]] and absent == [])

    def fake_orphan_absent(method, path, headers, body):
        return 404, "{}"

    deleted, absent = run_orphans(fake_orphan_absent, "fake-key", [orphan])
    report("run_orphans treats an already-absent orphan as a clean no-op", deleted == [] and absent == [orphan["env_name"]])

    def fake_orphan_wrong_email(method, path, headers, body):
        if method == "GET":
            return 200, json.dumps({"id": orphan["actual_id"], "email": "someone-else@example.com"})
        return 500, "{}"

    try:
        run_orphans(fake_orphan_wrong_email, "fake-key", [orphan])
        report("run_orphans REFUSES to delete if the live record's email does not match the recorded orphan's email", False)
    except OwnershipError:
        report("run_orphans REFUSES to delete if the live record's email does not match the recorded orphan's email", True)

    def fake_orphan_wrong_id(method, path, headers, body):
        if method == "GET":
            return 200, json.dumps({"id": "99999999-9999-9999-9999-999999999999", "email": orphan["email"]})
        return 500, "{}"

    try:
        run_orphans(fake_orphan_wrong_id, "fake-key", [orphan])
        report("run_orphans REFUSES to delete if the live record's id does not match the recorded orphan's actual_id (defensive; GET already targets that id)", False)
    except OwnershipError:
        report("run_orphans REFUSES to delete if the live record's id does not match the recorded orphan's actual_id (defensive; GET already targets that id)", True)

    os.environ["TDP_F30_SERVICE_ROLE_KEY"] = "self-check-throwaway-service-role-key"
    scrubbed = scrub(f"leaked: {os.environ['TDP_F30_SERVICE_ROLE_KEY']}")
    report("scrub() redacts the service-role key from any printed output", "self-check-throwaway-service-role-key" not in scrubbed)
    del os.environ["TDP_F30_SERVICE_ROLE_KEY"]

    report("refuse_if_unresolved does nothing when path is None", refuse_if_unresolved(None, "orphan") is None)
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        missing = Path(td) / "ORPHANS.json"
        report("refuse_if_unresolved does nothing when the file does not exist at all", refuse_if_unresolved(missing, "orphan") is None)
        missing.write_text("[]")
        report("refuse_if_unresolved does nothing when the file holds an empty list", refuse_if_unresolved(missing, "orphan") is None)
        missing.write_text(json.dumps([orphan]))
        report("refuse_if_unresolved REFUSES when the file holds one or more entries", _raises(SystemExit, refuse_if_unresolved, missing, "orphan"))

        # write_remaining_orphans: full success clears the file to [].
        of = Path(td) / "ORPHANS_full.json"
        of.write_text(json.dumps([orphan]))
        write_remaining_orphans(of, [orphan], [orphan["env_name"]])
        report("write_remaining_orphans clears the file to [] once every orphan is resolved", json.loads(of.read_text()) == [])
        report("write_remaining_orphans leaves a fully-cleared file unable to block a rerun (refuse_if_unresolved passes)", refuse_if_unresolved(of, "orphan") is None)

        # write_remaining_orphans: partial failure keeps only the unresolved remainder.
        orphan2 = {**orphan, "env_name": "TDP_F30_ORG1_ADMIN_JWT", "actual_id": "11111111-1111-1111-1111-111111111111"}
        op = Path(td) / "ORPHANS_partial.json"
        op.write_text(json.dumps([orphan, orphan2]))
        write_remaining_orphans(op, [orphan, orphan2], [orphan["env_name"]])
        remaining = json.loads(op.read_text())
        report("write_remaining_orphans keeps exactly the unresolved remainder after a partial failure", [r["env_name"] for r in remaining] == [orphan2["env_name"]])
        report("that remainder still blocks a rerun via refuse_if_unresolved", _raises(SystemExit, refuse_if_unresolved, op, "orphan"))

        # run_orphans attaches .resolved_env_names to the raised exception on partial failure, in original order.
        def fake_second_orphan_wrong_email(method, path, headers, body):
            if path.rsplit("/", 1)[1] == orphan["actual_id"]:
                if method == "GET":
                    return 200, json.dumps({"id": orphan["actual_id"], "email": orphan["email"]})
                return 204, ""
            if method == "GET":
                return 200, json.dumps({"id": orphan2["actual_id"], "email": "someone-else@example.com"})
            return 500, "{}"

        try:
            run_orphans(fake_second_orphan_wrong_email, "fake-key", [orphan, orphan2])
            report("run_orphans attaches .resolved_env_names (the ones resolved BEFORE the failure) to the raised exception", False)
        except OwnershipError as e:
            report("run_orphans attaches .resolved_env_names (the ones resolved BEFORE the failure) to the raised exception", getattr(e, "resolved_env_names", None) == [orphan["env_name"]])

        # cmd_cleanup's pre-flight orphans/unresolved gates.
        class _Args:
            pass

        blocked_file = Path(td) / "ORPHANS_gate.json"
        blocked_file.write_text(json.dumps([orphan]))
        gate_args = _Args()
        gate_args.project_ref = "abcdefghij0123456789"
        gate_args.orphans_file = str(blocked_file)
        gate_args.unresolved_file = None
        gate_args.confirm = None
        report("cmd_cleanup refuses to even start (before touching TDP_F30_SERVICE_ROLE_KEY or confirm) while --orphans-file has unresolved entries",
               _raises(SystemExit, cmd_cleanup, gate_args))

        blocked_unresolved = Path(td) / "UNRESOLVED_gate.json"
        blocked_unresolved.write_text(json.dumps([{"env_name": "x"}]))
        gate_args2 = _Args()
        gate_args2.project_ref = "abcdefghij0123456789"
        gate_args2.orphans_file = str(Path(td) / "ORPHANS_missing.json")  # does not exist -- resolved, must not itself block
        gate_args2.unresolved_file = str(blocked_unresolved)
        gate_args2.confirm = None
        report("cmd_cleanup ALSO refuses to even start while --unresolved-file has unresolved entries, independent of --orphans-file's own state",
               _raises(SystemExit, cmd_cleanup, gate_args2))

        # argparse itself (build_parser()) fails closed if either mandatory flag is omitted entirely -- the check can never be silently skipped by
        # simply not passing the flag on the command line.
        base_argv = ["cleanup", "--project-ref", "abcdefghij0123456789", "--confirm", "x"]
        report("argparse REFUSES 'cleanup' with --unresolved-file omitted (only --orphans-file given)",
               _raises(SystemExit, build_parser().parse_args, base_argv + ["--orphans-file", str(blocked_file)]))
        report("argparse REFUSES 'cleanup' with --orphans-file omitted (only --unresolved-file given)",
               _raises(SystemExit, build_parser().parse_args, base_argv + ["--unresolved-file", str(blocked_unresolved)]))
        report("argparse REFUSES 'cleanup' with BOTH mandatory file flags omitted", _raises(SystemExit, build_parser().parse_args, base_argv))
        report("argparse ACCEPTS 'cleanup' once both mandatory file flags are given",
               not _raises(SystemExit, build_parser().parse_args, base_argv + ["--orphans-file", str(blocked_file), "--unresolved-file", str(blocked_unresolved)]))

    return ok


def build_parser():
    """Split out from main() so tests can parse argv lists directly (and confirm argparse itself fails closed on missing required flags) without also invoking
    sys.argv-dependent execution."""
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--self-check", action="store_true")
    sub = p.add_subparsers(dest="cmd")
    c = sub.add_parser("cleanup")
    c.add_argument("--project-ref", required=True)
    c.add_argument("--confirm", default=None)
    c.add_argument("--orphans-file", required=True, help="MANDATORY pre-flight gate: the ORPHANS.json from the corresponding provisioning run's --out-dir (need not exist yet); refuses to start if it still has unresolved entries")
    c.add_argument("--unresolved-file", required=True, help="MANDATORY pre-flight gate: the UNRESOLVED.json from the corresponding provisioning run's --out-dir (need not exist yet); refuses to start if it still has unresolved entries")
    o = sub.add_parser("cleanup-orphans")
    o.add_argument("--project-ref", required=True)
    o.add_argument("--confirm", default=None)
    o.add_argument("--orphans-file", required=True, help="the ORPHANS.json a prior provision_auth_test_identities.py run wrote to its --out-dir")
    return p


def main():
    p = build_parser()
    args = p.parse_args()
    if args.self_check:
        sys.exit(0 if self_check() else 1)
    if args.cmd == "cleanup":
        cmd_cleanup(args)
        return
    if args.cmd == "cleanup-orphans":
        cmd_cleanup_orphans(args)
        return
    p.print_help()
    sys.exit(2)


if __name__ == "__main__":
    main()
