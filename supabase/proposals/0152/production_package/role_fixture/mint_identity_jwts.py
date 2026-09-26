#!/usr/bin/env python3
"""mint_identity_jwts.py -- HOSTED PROVISIONING STEP B (test identity JWTs) for the F-30 role/organization fixture. See HOSTED_PROVISIONING_PLAN.md for the full procedure.

MAKES NO NETWORK CONNECTION OF ANY KIND (proven by `--self-check` below: it statically rejects its own file if a network-capable module is ever imported) AND CHANGES NO DATABASE.
It signs JSON Web Tokens ENTIRELY LOCALLY (HMAC-SHA256, standard library only) from the deterministic subjects in topology.json, and writes each token to its own file OUTSIDE this
git repository. It never creates a Supabase Auth user, never calls any API, and never prints a token value to the terminal.

Why no real Auth user is created: the synthetic model (model.sql, f30_probe schema) is keyed entirely on auth.uid() -- the JWT's own 'sub' claim -- and never joins to auth.users. A
real Supabase Auth account would not even let an operator choose its own id to match the deterministic UUIDs in topology.json. The 14 required identities and the null-identity case
are therefore minted directly, against the target project's JWT signing secret, which the operator obtains from Project Settings -> API and supplies ONLY via the
TDP_F30_JWT_SIGNING_SECRET environment variable at the moment this script runs -- never as a command-line argument (shell history), never written to a file, never logged.

SIGNING IS BLOCKED, UNCONDITIONALLY, ONCE A PROJECT HAS MIGRATED TO THE JWT SIGNING KEYS SYSTEM -- NO CONFIRMATION CAN OVERRIDE THIS. Supabase's own docs state plainly: "You can
only extract the legacy JWT secret. Once you've moved to using the JWT signing keys feature[,] extracting of the private key or shared secret from Supabase is not possible."
(https://supabase.com/docs/guides/auth/signing-keys, FAQ "Why is it not possible to extract the private key or shared secret from Supabase?"). This is true even while the legacy
key is merely 'previously used' (not yet revoked) and its SIGNATURES remain accepted for verification -- accepted-for-verification and extractable-to-sign-something-new are
different properties, and only the second one matters for this tool. `mint` therefore takes --current-key-algorithm and --legacy-secret-status (both required, read directly off
that project's own Settings -> API / JWT Signing Keys page) and REFUSES OUTRIGHT, with no override flag of any kind, unless current-key-algorithm=HS256 AND
legacy-secret-status=not-migrated -- i.e. the project has never touched the new signing-keys system at all and the legacy secret is still the one and only key in effect. Any
other combination (an asymmetric current key such as ES256/RS256/EdDSA, or a legacy secret already previously-used/revoked) means the secret this tool would need is gone from
Supabase forever; see the module-level docstring section "OBSERVED KEY STATE" below for the officially supported alternative and why it is out of scope for this tool.

OBSERVED KEY STATE FOR THIS PROJECT (recorded here so this refusal is not mistaken for a bug): current-key-algorithm=ES256 (NIST P-256 curve), legacy-secret-status=previously-used.
Under the rule above this means self-signing is PERMANENTLY BLOCKED for this project via this tool. The only officially documented way to obtain a JWT with a chosen 'sub' now is:
  1. `supabase gen signing-key --algorithm ES256` -- generates a NEW private key locally (offline; the CLI does this without any network call).
  2. Import the generated key as a new STANDBY key on the dashboard's JWT Signing Keys page of the SAME verified project (a HOSTED write).
  3. Click "Rotate keys" to make that key the CURRENT key (a real KEY ROTATION of the project's actual signing configuration -- the observed ES256 key above would move to
     'previously used'). Per the docs, a standby key's signatures are NOT yet accepted for verification; rotation to current is what makes them trusted.
  4. `supabase gen bearer-jwt --role authenticated --sub <uuid>` -- signs locally (offline) against the key from step 1, now that step 3 has made it trusted.
  Steps 2 and 3 are a hosted connection and a key rotation of a real project's real signing configuration -- both explicitly out of scope for this tool and for the task that
  produced this revision. They are recorded here, exactly, so a separately authorized Owner decision can act on them later; this tool will never perform them itself.
  Source: https://supabase.com/docs/guides/auth/signing-keys ("How to create (mint) JWTs if access to the private key or shared secret is not possible?").

NULL-IDENTITY CASE: the SAME signing-key block above applies first -- no token of any kind, named or null, can be minted for this project via this tool. Independently of that,
Supabase's own docs describe 'sub' as "an optional UUID" in the JWT payload passed to `gen bearer-jwt` (same source as above), which is useful, positive evidence that a
subject-less `role=authenticated` token is an anticipated, documented claim shape in Supabase's own model -- not something this fixture invented. What is NOT confirmed by that
text is whether the `gen bearer-jwt` CLI flag `--sub` can actually be omitted on the command line (only the JSON claim's optionality is stated, not a shown omitted-flag
invocation), so this remains UNCONFIRMED until someone actually tries it, which this tool does not do. Separately, role_fixture/probe.py's own validate_target() requires EVERY
name in token_names() -- which unconditionally includes 'TDP_F30_NULL_JWT' -- to be present before it runs ANY case at all (F30_REQUIRED_SYNTHETIC_IDENTITIES_MISSING otherwise),
so once Step B's block is separately lifted, leaving TDP_F30_NULL_JWT unset still blocks the ENTIRE hosted role-model probe run, not just the null-identity row. See
HOSTED_PROVISIONING_PLAN.md Step C for the full, cited discussion and for why the local database-level proof (role_fixture/tests.py) is unaffected by any of this.

Usage (never executed by anything else in this repository):
  python3 mint_identity_jwts.py --self-check
      Offline, no arguments needed. Proves: no forbidden import exists in this file; the sign/verify round trip is internally consistent; the null-identity claims omit 'sub' by
      construction; the repository boundary is FAIL-CLOSED, not silently narrowed, when .git cannot be found; the signing-key-state gate refuses unconditionally for any state
      other than HS256/not-migrated, with NO override. Uses a throwaway in-memory secret and reference; writes nothing; never invokes `mint`.
  For THIS project (ES256 current, HS256 previously-used), `mint` REFUSES UNCONDITIONALLY regardless of any argument -- there is no supported invocation to show here. On an
  UNMIGRATED project only (current-key-algorithm=HS256, legacy-secret-status=not-migrated), the shape would be:
    read -s -p 'JWT signing secret: ' TDP_F30_JWT_SIGNING_SECRET; export TDP_F30_JWT_SIGNING_SECRET; echo
    python3 mint_identity_jwts.py mint --project-ref <ref> --out-dir <dir OUTSIDE this repository> --current-key-algorithm HS256 --legacy-secret-status not-migrated \\
        --confirm-legacy-secret 'LEGACY SECRET RETRIEVED PRE-MIGRATION <same ref>'
    unset TDP_F30_JWT_SIGNING_SECRET
"""
import argparse
import ast
import base64
import hashlib
import hmac
import json
import os
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
FORBIDDEN_REFS = {"zteixenjpcygjvznueuo", "fjmrvvyjvqdyopnyetez", "localdisposablef30xx"}
FORBIDDEN_IMPORTS = {"urllib", "http", "socket", "requests", "smtplib", "ftplib", "asyncio", "ssl", "paramiko", "telnetlib"}


def topology():
    return json.loads((HERE / "topology.json").read_text())


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def build_claims(ref: str, sub: str | None, ttl_seconds: int) -> dict:
    now = int(time.time())
    claims = {"aud": "authenticated", "role": "authenticated", "iss": f"https://{ref}.supabase.co/auth/v1", "iat": now, "exp": now + ttl_seconds}
    if sub is not None:
        claims["sub"] = sub
    return claims


def mint_token(secret: bytes, ref: str, sub: str | None, ttl_seconds: int) -> str:
    header_b64 = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode("ascii"))
    payload_b64 = b64url(json.dumps(build_claims(ref, sub, ttl_seconds), separators=(",", ":")).encode("ascii"))
    signature = hmac.new(secret, f"{header_b64}.{payload_b64}".encode("ascii"), hashlib.sha256).digest()
    return f"{header_b64}.{payload_b64}.{b64url(signature)}"


def repo_root(start: Path) -> Path | None:
    """Returns the repository root (the ancestor holding .git), or None if it cannot be positively located. Never guesses a narrower fallback boundary."""
    for parent in (start, *start.parents):
        if (parent / ".git").exists():
            return parent
    return None


def refuse_if_inside_repo(out_dir: Path, search_start: Path = HERE):
    root = repo_root(search_start)
    if root is None:
        raise SystemExit("REFUSED: this script's own repository root could not be positively located (no .git found in any ancestor). FAIL CLOSED: refusing to write anywhere rather than guessing a narrower boundary. STOP.")
    root = root.resolve()
    resolved = out_dir.resolve()
    if resolved == root or root in resolved.parents:
        raise SystemExit(f"REFUSED: --out-dir ({resolved}) is inside this git repository ({root}). Tokens must never be written into the repository. STOP.")


def validate_ref(ref: str):
    import re

    if not ref or not re.fullmatch(r"[a-z0-9]{20}", ref):
        raise SystemExit(f"REFUSED: '{ref}' is not a well-formed 20-character project reference. STOP.")
    if ref in FORBIDDEN_REFS or ref.startswith("fjmrvvyjvqd"):
        raise SystemExit(f"REFUSED: '{ref}' is a forbidden reference (production or the deleted temporary test project). STOP.")


SELF_SIGNABLE_KEY_ALGORITHM = "HS256"
SELF_SIGNABLE_LEGACY_STATUS = "not-migrated"


def require_self_signable_key_state(current_key_algorithm: str, legacy_secret_status: str, confirm: str | None, ref: str):
    """Refuses unconditionally -- no confirmation phrase can override this branch -- unless the project has NEVER migrated to the JWT Signing Keys system at all
    (current_key_algorithm == 'HS256' and legacy_secret_status == 'not-migrated'), because that is the only state in which the secret this tool needs to sign with is still
    extractable at all. Source: https://supabase.com/docs/guides/auth/signing-keys FAQ "Why is it not possible to extract the private key or shared secret from Supabase?" --
    "You can only extract the legacy JWT secret. Once you've moved to using the JWT signing keys feature[,] extracting ... is not possible." Being merely 'previously used'
    (not yet revoked, signatures still accepted for verification) is NOT the same as still being extractable to sign something new -- this function checks the latter."""
    if current_key_algorithm != SELF_SIGNABLE_KEY_ALGORITHM or legacy_secret_status != SELF_SIGNABLE_LEGACY_STATUS:
        raise SystemExit(
            f"REFUSED (unconditional -- no override exists for this branch): --current-key-algorithm='{current_key_algorithm}' --legacy-secret-status='{legacy_secret_status}'. "
            "Once a project has moved to the JWT Signing Keys system in any way (an asymmetric current key such as ES256/RS256/EdDSA, or a legacy secret already "
            "previously-used/revoked), Supabase makes NEITHER the private key NOR the legacy shared secret extractable ever again -- a documented, permanent platform "
            "guarantee, not a temporary restriction, and true regardless of whether that legacy key's signatures are still accepted for verification. Self-signing here is "
            "therefore categorically impossible, and no --confirm flag exists for this case because none could make it true. See this file's own module docstring "
            "('OBSERVED KEY STATE') for the officially supported alternative (generate + import + ROTATE a new key, then `supabase gen bearer-jwt`) and why it is out of "
            "scope for this tool. STOP."
        )
    expected = f"LEGACY SECRET RETRIEVED PRE-MIGRATION {ref}"
    if confirm != expected:
        raise SystemExit(
            "REFUSED: --confirm-legacy-secret was not given or did not match exactly. Even on this unmigrated project, type it only after actually retrieving the legacy "
            f"JWT secret from Project Settings -> API of the SAME verified project. Pass exactly:  --confirm-legacy-secret '{expected}'  STOP."
        )


def token_names():
    t = topology()
    return [(f"TDP_F30_ORG{n}_{role.upper()}_JWT", org["identities"][role]) for n, org in enumerate(t["organizations"], 1) for role in org["identities"]]


def cmd_mint(args):
    validate_ref(args.project_ref)
    require_self_signable_key_state(args.current_key_algorithm, args.legacy_secret_status, args.confirm_legacy_secret, args.project_ref)
    secret_raw = os.environ.get("TDP_F30_JWT_SIGNING_SECRET", "")
    if not secret_raw:
        raise SystemExit("REFUSED: TDP_F30_JWT_SIGNING_SECRET is not set. This script never accepts the secret as a command-line argument. STOP.")
    out_dir = Path(args.out_dir)
    refuse_if_inside_repo(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(out_dir, 0o700)
    secret = secret_raw.encode("utf-8")
    written = []
    for name, sub in token_names():
        token = mint_token(secret, args.project_ref, sub, args.ttl_seconds)
        path = out_dir / name
        path.write_text(token)
        os.chmod(path, 0o600)
        written.append((name, path, sub))
    if args.allow_null_identity_token:
        token = mint_token(secret, args.project_ref, None, args.ttl_seconds)
        path = out_dir / "TDP_F30_NULL_JWT_UNVERIFIED"
        path.write_text(token)
        os.chmod(path, 0o600)
        written.append(("TDP_F30_NULL_JWT_UNVERIFIED", path, None))
        print("WARNING: a null-subject token was minted at the operator's explicit request. Whether the real gateway accepts a subject-less authenticated request is UNCONFIRMED.")
        print("         Use it ONLY per HOSTED_PROVISIONING_PLAN.md Step C: a single isolated read-only 'preview' call first, observed manually, before it is trusted for anything else.")
        print("         Rename it to TDP_F30_NULL_JWT only after that manual confirmation succeeds.")
    else:
        print("TDP_F30_NULL_JWT was NOT minted (blocked by default). NOTE: probe.py's own validate_target() requires ALL of token_names() present -- including TDP_F30_NULL_JWT --")
        print("before it runs ANY case, so this blocks the ENTIRE hosted role-model probe run, not just the null-identity row. Pass --allow-null-identity-token to mint it under the")
        print("distinct name TDP_F30_NULL_JWT_UNVERIFIED, and follow HOSTED_PROVISIONING_PLAN.md Step C before treating any null-identity REST result as proven.")
    print(f"\nWrote {len(written)} token file(s) to {out_dir.resolve()} (mode 0600). No token value is printed here. Load each with: export NAME=$(cat {out_dir}/NAME)")
    for name, path, sub in written:
        print(f"  {name:<40} sub={sub if sub is not None else '(none)'}")
    print("\nUnset TDP_F30_JWT_SIGNING_SECRET in this shell once you are done minting.")


def self_check() -> bool:
    ok = True

    def report(label, passed):
        nonlocal ok
        ok = ok and passed
        print(("ok   " if passed else "FAIL ") + label)

    tree = ast.parse(Path(__file__).read_text())
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(n.name.split(".")[0] for n in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    report("no network-capable module is imported by this file", imported.isdisjoint(FORBIDDEN_IMPORTS))
    report(f"imports found: {sorted(imported)}", True)

    secret = b"self-check-only-throwaway-secret-not-a-real-key"
    ref = "zzzzzzzzzzzzzzzzzzzz"
    sub = "11111111-1111-1111-1111-111111111111"
    token = mint_token(secret, ref, sub, 60)
    parts = token.split(".")
    report("minted token has exactly 3 dot-separated parts", len(parts) == 3)
    header = json.loads(b64url_decode(parts[0]))
    payload = json.loads(b64url_decode(parts[1]))
    report("header alg/typ correct", header == {"alg": "HS256", "typ": "JWT"})
    report("payload round-trips the exact subject, role, issuer for a NAMED identity", payload.get("sub") == sub and payload.get("role") == "authenticated" and payload.get("iss") == f"https://{ref}.supabase.co/auth/v1")
    expected_sig = b64url(hmac.new(secret, f"{parts[0]}.{parts[1]}".encode("ascii"), hashlib.sha256).digest())
    report("HMAC-SHA256 signature is internally consistent (recomputed signature matches)", parts[2] == expected_sig)
    wrong_secret_sig = b64url(hmac.new(secret + b"x", f"{parts[0]}.{parts[1]}".encode("ascii"), hashlib.sha256).digest())
    report("a different secret produces a different signature (the check is not vacuous)", parts[2] != wrong_secret_sig)

    null_claims = build_claims(ref, None, 60)
    report("null-identity claims OMIT 'sub' entirely by construction", "sub" not in null_claims and null_claims.get("role") == "authenticated")
    named_claims = build_claims(ref, sub, 60)
    report("a named identity's claims DO carry 'sub'", named_claims.get("sub") == sub)

    try:
        refuse_if_inside_repo(HERE)
        report("--out-dir inside the repository is refused", False)
    except SystemExit:
        report("--out-dir inside the repository is refused", True)

    import tempfile

    with tempfile.TemporaryDirectory() as td:
        no_git_dir = Path(td) / "no_git_here"
        no_git_dir.mkdir()
        report("repo_root() returns None (fail closed) when no .git is discoverable, rather than a narrower guessed boundary", repo_root(no_git_dir) is None)
        try:
            refuse_if_inside_repo(Path(td), search_start=no_git_dir)
            report("refuse_if_inside_repo() FAILS CLOSED (refuses) when the repository root cannot be located at all", False)
        except SystemExit:
            report("refuse_if_inside_repo() FAILS CLOSED (refuses) when the repository root cannot be located at all", True)
    report("repo_root() still finds the real repository root from this file's own location", repo_root(HERE) is not None)

    for alg, status, label in (
        ("ES256", "previously-used", "the OBSERVED state for this project (ES256 current / HS256 previously-used)"),
        ("RS256", "not-migrated", "an asymmetric current key even if the legacy secret were somehow still 'not-migrated' (self-contradictory, but must still refuse)"),
        ("HS256", "previously-used", "HS256 current but the legacy secret already migrated away (previously-used, not extractable)"),
        ("HS256", "revoked", "HS256 current but the legacy secret already revoked"),
    ):
        try:
            require_self_signable_key_state(alg, status, f"LEGACY SECRET RETRIEVED PRE-MIGRATION {ref}", ref)
            report(f"signing is refused UNCONDITIONALLY (no confirm phrase can override it) for {label}", False)
        except SystemExit as e:
            report(f"signing is refused UNCONDITIONALLY (no confirm phrase can override it) for {label}", "no override exists" in str(e))
    try:
        require_self_signable_key_state("HS256", "not-migrated", None, ref)
        report("on an UNMIGRATED project, minting still refuses with no --confirm-legacy-secret at all", False)
    except SystemExit:
        report("on an UNMIGRATED project, minting still refuses with no --confirm-legacy-secret at all", True)
    try:
        require_self_signable_key_state("HS256", "not-migrated", "LEGACY SECRET RETRIEVED PRE-MIGRATION some-other-ref", ref)
        report("on an UNMIGRATED project, minting refuses when --confirm-legacy-secret does not match this exact --project-ref", False)
    except SystemExit:
        report("on an UNMIGRATED project, minting refuses when --confirm-legacy-secret does not match this exact --project-ref", True)
    try:
        require_self_signable_key_state("HS256", "not-migrated", f"LEGACY SECRET RETRIEVED PRE-MIGRATION {ref}", ref)
        report("on an UNMIGRATED project, minting proceeds only with the exact, ref-specific confirmation phrase", True)
    except SystemExit:
        report("on an UNMIGRATED project, minting proceeds only with the exact, ref-specific confirmation phrase", False)

    try:
        cmd_mint  # noqa: B018 -- existence check only; not called (would require a secret/out-dir and touch the filesystem)
        report("the mint path is defined but self-check never invokes it (no filesystem write in --self-check)", True)
    except NameError:
        report("cmd_mint must exist", False)

    return ok


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--self-check", action="store_true", help="offline self-verification only; writes nothing, needs no arguments")
    sub = p.add_subparsers(dest="cmd")
    m = sub.add_parser("mint")
    m.add_argument("--project-ref", required=True)
    m.add_argument("--out-dir", required=True)
    m.add_argument("--ttl-seconds", type=int, default=3600)
    m.add_argument("--allow-null-identity-token", action="store_true")
    m.add_argument("--current-key-algorithm", required=True, choices=["HS256", "ES256", "RS256", "EdDSA"], help="read directly off Settings -> API / JWT Signing Keys of the SAME verified project; anything but HS256 refuses unconditionally")
    m.add_argument("--legacy-secret-status", required=True, choices=["not-migrated", "previously-used", "revoked"], help="the Legacy JWT Secret row's own state on that same page; anything but not-migrated refuses unconditionally")
    m.add_argument("--confirm-legacy-secret", default=None, help="must be exactly 'LEGACY SECRET RETRIEVED PRE-MIGRATION <same --project-ref>'; only reachable when current-key-algorithm=HS256 and legacy-secret-status=not-migrated")
    args = p.parse_args()
    if args.self_check:
        sys.exit(0 if self_check() else 1)
    if args.cmd == "mint":
        cmd_mint(args)
        return
    p.print_help()
    sys.exit(2)


if __name__ == "__main__":
    main()
