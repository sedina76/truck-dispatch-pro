#!/usr/bin/env python3
"""target_preflight.py -- F-30 hosted TARGET PREFLIGHT (read-only, human-run). See HOSTED_PROVISIONING_PLAN.md preconditions 1-2 and
target_preflight_readonly.sql in this directory.

THIS TOOL NEVER CONNECTS TO ANYTHING, NOT EVEN LATENTLY. Unlike its sibling tools (provision_auth_test_identities.py, cleanup_auth_test_identities.py,
mint_identity_jwts.py), there is no real_request()/real_query() function anywhere in this file -- no networking code exists here at all, confined or
otherwise (proven by --self-check: zero network-capable imports ANYWHERE in the file, module scope or nested, not merely "never called"). The only way
data reaches this tool is the OPERATOR pasting the single JSON row that target_preflight_readonly.sql produces, after running that SQL by hand in the SQL
Editor of a project they have independently verified against the Supabase dashboard URL/Settings -- the exact discipline discovery_guard.py and
provision_marker.sql already use elsewhere in this package. SQL run in the Editor cannot know its own project reference, so identity is a human + tool
confirmation gate here too, never a database check.

Two steps, always in this order:
  1. confirm-target --ref <ref> --confirm 'PREFLIGHT F30 TARGET <ref>'
       Prints GO only if <ref> is well-formed, is NOT production / the deleted temporary test project / the local-disposable-harness sentinel, matches the
       required TDP_F30_TEST_PROJECT_REF / TDP_F30_ENVIRONMENT=nonproduction-f30 allowlist, and the typed confirmation phrase matches exactly.
  2. record-evidence --ref <ref> --confirm 'PREFLIGHT F30 TARGET <ref>' --result-file <path to the pasted JSON row> --evidence-dir <dir outside this repo>
       Re-checks the SAME gate as step 1 independently (never bypassable by skipping step 1), evaluates the five conditions below against the pasted
       result, and writes exactly ONE timestamped, redacted evidence JSON file -- on EITHER verdict, GO or STOP, so a stop is recorded, not just printed
       and lost. Refuses to write anything at all -- no evidence file, no partial state -- if the confirmation gate itself fails.

Conditions checked (a mismatch on ANY one -> overall verdict STOP, never GO; ALL must independently pass for GO):
  - postgres_version starts with '17.6' (matches this package's own PostgreSQL-version requirement elsewhere, e.g. role_fixture/probe.py's context_ok()).
  - public_base_table_count == 0 (empty application baseline -- HOSTED_PROVISIONING_PLAN.md precondition 2).
  - f30_marker_schema_exists is False (no pre-existing F-30 marker -- schema f30_test_control, see provision_marker.sql).
  - f30_fixture_schema_exists is False (no pre-existing F-30 fixture -- schema f30_probe, see model.sql/fixture.sql).
  - f30_freeze_schema_exists is False (no pre-existing freeze -- schema ops_freeze_v2, see ../../freeze/02_enable_freeze.sql).
The project reference and environment label are NEVER re-derived from the pasted SQL result (SQL cannot know its own project ref, exactly as
discovery_guard.py's own docstring states) -- they are exactly the human-confirmed --ref and the required TDP_F30_ENVIRONMENT value from the gate above,
carried through unchanged and REDACTED in every printed line and every evidence file (only the first/last 4 characters of the reference are ever written,
matching discovery_guard.py's own confirm_target() convention).

Usage (never executed by anything else in this repository; this tool makes no database write, no Auth-user creation, no probe run, no hosted/production
request of any kind -- it is pure text/JSON evaluation of what a human operator pastes in):
  python3 target_preflight.py --self-check
  python3 target_preflight.py confirm-target --ref <ref> --confirm 'PREFLIGHT F30 TARGET <ref>'
  # ... paste target_preflight_readonly.sql into the SQL Editor of that SAME, dashboard-verified project by hand; save its one output row to a file ...
  python3 target_preflight.py record-evidence --ref <ref> --confirm 'PREFLIGHT F30 TARGET <ref>' \\
      --result-file result.json --evidence-dir ~/tdp-f30-preflight-evidence
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
FORBIDDEN_REFS = {"zteixenjpcygjvznueuo", "fjmrvvyjvqdyopnyetez", "localdisposablef30xx"}
REQUIRED_FIELDS = ("postgres_version", "public_base_table_count", "f30_marker_schema_exists", "f30_fixture_schema_exists", "f30_freeze_schema_exists", "current_database")
CONFIRM_PREFIX = "PREFLIGHT F30 TARGET"


def validate_ref(ref):
    ref = (ref or "").strip().lower()
    if not re.fullmatch(r"[a-z0-9]{20}", ref):
        raise SystemExit(f"REFUSED: '{ref}' is not a well-formed 20-character project reference. STOP.")
    if ref in FORBIDDEN_REFS or ref.startswith("fjmrvvyjvqd"):
        raise SystemExit(f"REFUSED: '{ref}' is a forbidden reference (production, the deleted temporary test project, or the local-disposable-harness sentinel). STOP.")
    return ref


def require_target_confirmed(ref, env, confirm):
    """Same allowlist variables role_fixture/probe.py's own validate_target() and the sibling Auth tools require (TDP_F30_TEST_PROJECT_REF /
    TDP_F30_ENVIRONMENT=nonproduction-f30), PLUS a typed, ref-specific confirmation phrase (mirrors discovery_guard.py's --confirm pattern)."""
    if env.get("TDP_F30_TEST_PROJECT_REF") != ref or env.get("TDP_F30_ENVIRONMENT") != "nonproduction-f30":
        raise SystemExit("REFUSED: TDP_F30_TEST_PROJECT_REF (must equal --ref) and TDP_F30_ENVIRONMENT=nonproduction-f30 are both required. STOP.")
    expected = f"{CONFIRM_PREFIX} {ref}"
    if confirm != expected:
        raise SystemExit(f"REFUSED: --confirm was not given or did not match exactly. Pass exactly:  --confirm '{expected}'  STOP.")


def redact_ref(ref):
    return f"{ref[:4]}...{ref[-4:]}"


def cmd_confirm_target(args):
    ref = validate_ref(args.ref)
    require_target_confirmed(ref, os.environ, args.confirm)
    print(f"GO: target reference {redact_ref(ref)} confirmed for the F-30 preflight. NOW compare it with the Supabase dashboard URL/Settings yourself "
          f"before pasting target_preflight_readonly.sql anywhere. Paste it, save its single output row, then run record-evidence.")


def evaluate(result: dict):
    """Pure function: given the parsed JSON row target_preflight_readonly.sql produces, returns (verdict, mismatches). Touches no file, makes no request --
    every mismatch condition is independent (all five are always checked; this never stops at the first one, since reporting ALL of them at once is more
    useful for a preflight the operator will need to go fix and re-run than an early bail-out would be)."""
    missing = [f for f in REQUIRED_FIELDS if f not in result]
    if missing:
        raise SystemExit(f"REFUSED: --result-file is missing required field(s): {missing}. It must be exactly target_preflight_readonly.sql's own output row -- an edited or partial copy is refused. STOP.")
    mismatches = []
    pg = str(result.get("postgres_version", ""))
    if not re.match(r"^17\.6(?:\s|$)", pg):
        mismatches.append(f"postgres_version is '{pg}', expected to start with '17.6'")
    count = result.get("public_base_table_count")
    if count != 0:
        mismatches.append(f"public_base_table_count is {count!r}, expected 0 (application schema must be empty)")
    if result.get("f30_marker_schema_exists") is not False:
        mismatches.append("f30_marker_schema_exists is not False -- an F-30 marker (f30_test_control) already exists on this target")
    if result.get("f30_fixture_schema_exists") is not False:
        mismatches.append("f30_fixture_schema_exists is not False -- an F-30 fixture (f30_probe) already exists on this target")
    if result.get("f30_freeze_schema_exists") is not False:
        mismatches.append("f30_freeze_schema_exists is not False -- a freeze (ops_freeze_v2) already exists on this target")
    return ("GO" if not mismatches else "STOP", mismatches)


def repo_root(start: Path):
    for parent in (start, *start.parents):
        if (parent / ".git").exists():
            return parent
    return None


def refuse_if_inside_repo(evidence_dir: Path, search_start: Path = HERE):
    root = repo_root(search_start)
    if root is None:
        raise SystemExit("REFUSED: could not locate this repository's root (.git not found upward from this file). Refusing to guess a safe evidence directory. STOP.")
    resolved = evidence_dir.resolve()
    if resolved == root or root in resolved.parents:
        raise SystemExit(f"REFUSED: --evidence-dir '{evidence_dir}' resolves inside this repository ({root}). Evidence must never be committed. STOP.")


def build_record(ref, env, verdict, mismatches, result):
    return {
        "utc": datetime.now(timezone.utc).isoformat(),
        "target_reference": redact_ref(ref),
        "environment": env.get("TDP_F30_ENVIRONMENT"),
        "verdict": verdict,
        "checks": {f: result.get(f) for f in REQUIRED_FIELDS},
        "mismatches": mismatches,
    }


def cmd_record_evidence(args):
    ref = validate_ref(args.ref)
    require_target_confirmed(ref, os.environ, args.confirm)  # fails closed BEFORE any file is touched below
    evidence_dir = Path(args.evidence_dir)
    refuse_if_inside_repo(evidence_dir)
    result = json.loads(Path(args.result_file).read_text())
    verdict, mismatches = evaluate(result)
    record = build_record(ref, os.environ, verdict, mismatches, result)
    evidence_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(evidence_dir, 0o700)
    # Microsecond precision (not just seconds) so two runs in the same wall-clock second -- e.g. a GO run immediately followed by a re-check -- never
    # collide on the same filename and silently overwrite one another's evidence.
    name = evidence_dir / f"f30_target_preflight_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}.json"
    name.write_text(json.dumps(record, indent=2))
    os.chmod(name, 0o600)
    print(json.dumps(record, indent=2))
    if verdict == "GO":
        print(f"\nGO: all F-30 target preflight checks passed for {redact_ref(ref)}. Evidence written to {name}.")
    else:
        print(f"\nSTOP: {len(mismatches)} mismatch(es) for {redact_ref(ref)} -- see 'mismatches' above and in {name}. Do not proceed with F-30 provisioning.")
    sys.exit(0 if verdict == "GO" else 1)


def _raises(exc_type, fn, *fn_args, **fn_kwargs):
    try:
        fn(*fn_args, **fn_kwargs)
        return False
    except exc_type:
        return True


def self_check() -> bool:
    ok = True

    def report(label, passed):
        nonlocal ok
        ok = ok and passed
        print(("ok   " if passed else "FAIL ") + label)

    import ast
    import tempfile

    tree = ast.parse(Path(__file__).read_text())
    forbidden = {"urllib", "http", "socket", "requests", "smtplib", "ftplib", "asyncio", "ssl", "paramiko", "telnetlib"}
    imported = set()
    for node in ast.walk(tree):  # the WHOLE file, not just module scope -- there is no nested real_request()-style exception to carve out here
        if isinstance(node, ast.Import):
            imported.update(n.name.split(".")[0] for n in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    report("NO network-capable module is imported ANYWHERE in this file (module scope or nested) -- this tool cannot connect to anything, not even latently", imported.isdisjoint(forbidden))
    report("only stdlib text/JSON/filesystem modules are imported at all", imported <= {"argparse", "json", "os", "re", "sys", "datetime", "pathlib", "ast", "tempfile"})

    REF = "abcdefghij0123456789"
    ENV = {"TDP_F30_TEST_PROJECT_REF": REF, "TDP_F30_ENVIRONMENT": "nonproduction-f30"}
    report("validate_ref REFUSES a malformed reference", _raises(SystemExit, validate_ref, "too-short"))
    report("validate_ref REFUSES the production reference", _raises(SystemExit, validate_ref, "zteixenjpcygjvznueuo"))
    report("validate_ref REFUSES the deleted temporary test reference (and its prefix)", _raises(SystemExit, validate_ref, "fjmrvvyjvqdyopnyetez") and _raises(SystemExit, validate_ref, "fjmrvvyjvqdxxxxxxxxx"))
    report("validate_ref REFUSES the local-disposable-harness sentinel", _raises(SystemExit, validate_ref, "localdisposablef30xx"))
    report("validate_ref ACCEPTS a well-formed, non-forbidden reference", validate_ref(REF) == REF)

    report("require_target_confirmed REFUSES with no allowlist env vars at all", _raises(SystemExit, require_target_confirmed, REF, {}, None))
    report("require_target_confirmed REFUSES a wrong TDP_F30_ENVIRONMENT value", _raises(SystemExit, require_target_confirmed, REF, {**ENV, "TDP_F30_ENVIRONMENT": "production"}, f"{CONFIRM_PREFIX} {REF}"))
    report("require_target_confirmed REFUSES a --confirm phrase for a DIFFERENT reference", _raises(SystemExit, require_target_confirmed, REF, ENV, f"{CONFIRM_PREFIX} zzzzzzzzzzzzzzzzzzzz"))
    report("require_target_confirmed REFUSES no --confirm at all", _raises(SystemExit, require_target_confirmed, REF, ENV, None))
    report("require_target_confirmed PROCEEDS (no exception) with the exact allowlist and confirmation phrase", require_target_confirmed(REF, ENV, f"{CONFIRM_PREFIX} {REF}") is None)

    report("redact_ref never exposes the full reference", "..." in redact_ref(REF) and REF not in redact_ref(REF))

    full_pass = {"postgres_version": "17.6 (Ubuntu)", "public_base_table_count": 0, "f30_marker_schema_exists": False, "f30_fixture_schema_exists": False, "f30_freeze_schema_exists": False, "current_database": "postgres"}
    verdict, mismatches = evaluate(full_pass)
    report("evaluate() returns GO with zero mismatches when every condition passes", verdict == "GO" and mismatches == [])

    report("evaluate() REFUSES a result missing a required field (never silently treats it as passing)", _raises(SystemExit, evaluate, {k: v for k, v in full_pass.items() if k != "postgres_version"}))

    wrong_pg = {**full_pass, "postgres_version": "16.4 (Ubuntu)"}
    verdict, mismatches = evaluate(wrong_pg)
    report("evaluate() reports STOP with the exact reason for a wrong PostgreSQL version", verdict == "STOP" and any("postgres_version" in m for m in mismatches))

    non_empty = {**full_pass, "public_base_table_count": 7}
    verdict, mismatches = evaluate(non_empty)
    report("evaluate() reports STOP with the exact reason for a non-empty application baseline", verdict == "STOP" and any("public_base_table_count" in m for m in mismatches))

    for field, label in (("f30_marker_schema_exists", "marker"), ("f30_fixture_schema_exists", "fixture"), ("f30_freeze_schema_exists", "freeze")):
        bad = {**full_pass, field: True}
        verdict, mismatches = evaluate(bad)
        report(f"evaluate() reports STOP with the exact reason for a pre-existing {label}", verdict == "STOP" and any(field in m for m in mismatches))

    all_bad = {**full_pass, "postgres_version": "16.0", "public_base_table_count": 3, "f30_marker_schema_exists": True, "f30_fixture_schema_exists": True, "f30_freeze_schema_exists": True}
    verdict, mismatches = evaluate(all_bad)
    report("evaluate() reports ALL five mismatches at once (never stops after the first, unlike this package's write-path tools)", verdict == "STOP" and len(mismatches) == 5)

    report("refuse_if_inside_repo REFUSES this very directory (inside the repo)", _raises(SystemExit, refuse_if_inside_repo, HERE))
    root = repo_root(HERE)
    report("refuse_if_inside_repo REFUSES the repository root itself", root is not None and _raises(SystemExit, refuse_if_inside_repo, root))

    with tempfile.TemporaryDirectory() as td:
        outside = Path(td) / "evidence"
        report("refuse_if_inside_repo ACCEPTS (no exception) a directory outside the repository", refuse_if_inside_repo(outside) is None)

        class Args:
            pass

        result_file = Path(td) / "result.json"
        result_file.write_text(json.dumps(full_pass))
        a = Args()
        a.ref = REF
        a.confirm = f"{CONFIRM_PREFIX} {REF}"
        a.result_file = str(result_file)
        a.evidence_dir = str(outside)
        os.environ.update(ENV)
        try:
            code = _call_and_get_exit_code(cmd_record_evidence, a)
            report("cmd_record_evidence exits 0 (GO) on a full pass", code == 0)
            written = list(outside.iterdir())
            report("cmd_record_evidence wrote exactly one evidence file", len(written) == 1)
            record = json.loads(written[0].read_text())
            report("the evidence file records verdict GO, a UTC timestamp, the REDACTED reference (never the full one), and zero mismatches",
                   record["verdict"] == "GO" and record["utc"] and REF not in json.dumps(record) and record["target_reference"] == redact_ref(REF) and record["mismatches"] == [])
            report("the evidence file is written mode 0600", (written[0].stat().st_mode & 0o777) == 0o600)

            bad_result_file = Path(td) / "bad_result.json"
            bad_result_file.write_text(json.dumps(all_bad))
            a2 = Args()
            a2.ref = REF
            a2.confirm = f"{CONFIRM_PREFIX} {REF}"
            a2.result_file = str(bad_result_file)
            a2.evidence_dir = str(outside)
            code2 = _call_and_get_exit_code(cmd_record_evidence, a2)
            report("cmd_record_evidence exits 1 (STOP) when checks mismatch -- a mismatch is still RECORDED, not silently dropped", code2 == 1)
            written2 = sorted(outside.iterdir())
            report("cmd_record_evidence wrote a SECOND evidence file for the STOP run (the first GO evidence file is never overwritten)", len(written2) == 2)
            stop_record = json.loads(written2[-1].read_text())
            report("the STOP evidence file records verdict STOP and all five mismatches", stop_record["verdict"] == "STOP" and len(stop_record["mismatches"]) == 5)

            before = sorted(p.name for p in outside.iterdir())
            a3 = Args()
            a3.ref = REF
            a3.confirm = "WRONG CONFIRMATION PHRASE"
            a3.result_file = str(result_file)
            a3.evidence_dir = str(outside)
            report("cmd_record_evidence REFUSES outright (no file written) when the confirmation gate itself fails, even with a fully-passing result", _raises(SystemExit, cmd_record_evidence, a3))
            after = sorted(p.name for p in outside.iterdir())
            report("...and wrote NOTHING new -- the gate fails BEFORE any evidence file (or the evidence directory contents) is touched", before == after)
        finally:
            for k in ENV:
                del os.environ[k]

    return ok


def _call_and_get_exit_code(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except SystemExit as e:
        return e.code
    return None


def build_parser():
    """Split out from main() so tests can parse argv lists directly without also invoking sys.argv-dependent execution."""
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--self-check", action="store_true")
    sub = p.add_subparsers(dest="cmd")
    ct = sub.add_parser("confirm-target")
    ct.add_argument("--ref", required=True)
    ct.add_argument("--confirm", default=None)
    rec = sub.add_parser("record-evidence")
    rec.add_argument("--ref", required=True)
    rec.add_argument("--confirm", default=None)
    rec.add_argument("--result-file", required=True, help="path to the single JSON row target_preflight_readonly.sql produced, saved by the operator")
    rec.add_argument("--evidence-dir", required=True, help="directory OUTSIDE this repository to write the timestamped evidence file to")
    return p


def main():
    p = build_parser()
    args = p.parse_args()
    if args.self_check:
        sys.exit(0 if self_check() else 1)
    if args.cmd == "confirm-target":
        cmd_confirm_target(args)
        return
    if args.cmd == "record-evidence":
        cmd_record_evidence(args)
        return
    p.print_help()
    sys.exit(2)


if __name__ == "__main__":
    main()
