#!/usr/bin/env python3
"""Guard for the PRODUCTION read-only discovery package (PROPOSAL 0152). Standard library only. It never connects to anything and never reads credentials.

  python3 discovery_guard.py check-files                      # statically prove every discovery/conflict SQL is read-only (no network, no env)
  python3 discovery_guard.py confirm-target --ref <ref> --confirm 'DISCOVER PRODUCTION <ref>'
        # prints a 'GO' line only if <ref> is the explicitly configured production ref (env TDP_PROD_PROJECT_REF), is NOT the deleted test project, and the typed
        # confirmation matches exactly. The operator must ALSO compare <ref> with the Supabase dashboard URL/Settings before pasting any SQL.
Refusals exit non-zero. SQL run in the Supabase SQL Editor cannot know its own project ref, so the ref check is a human + tool gate, not a database gate."""
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
FREEZE = HERE.parent / "freeze"
DELETED_TEST_REF = "fjmrvvyjvqdyopnyetez"
TEST_PREFIX = "fjmrvvyjvqd"
DISCOVERY_FILES = [FREEZE / "01_discovery_readonly.sql", HERE / "P02_schema_objects_readonly.sql", HERE / "P03_privileges_readonly.sql"]
FORBIDDEN = re.compile(r"\b(insert|update|delete|truncate|create|alter|drop|grant|revoke|comment|copy|vacuum|analyze|reindex|cluster|refresh|lock|listen|notify|call|do|execute|prepare|set|reset|begin|commit|rollback|savepoint|"
                       r"nextval|setval|pg_terminate_backend|pg_cancel_backend|pg_advisory_lock|pg_advisory_xact_lock|pg_reload_conf|pg_sleep|set_config|dblink|lo_import|lo_export|pg_read_file|"
                       r"cron\.schedule|cron\.alter_job|cron\.unschedule|pg_notify|txid_current)\b", re.I)


def strip_sql(text):
    """Remove comments and single-quoted string literals in ONE left-to-right pass (so `--` inside a string or an apostrophe inside a comment cannot confuse it)."""
    return re.sub(r"--[^\n]*|/\*.*?\*/|'(?:[^']|'')*'", lambda m: "''" if m.group(0).startswith("'") else " ", text, flags=re.S)


def statements(text):
    return [s.strip() for s in strip_sql(text).split(";") if s.strip()]


def split_queries(text):
    parts = re.split(r"^-- ==== (Q\d+)[^\n]*\n", text, flags=re.M)
    return {parts[i]: parts[i + 1] for i in range(1, len(parts), 2)}


def check_sql_readonly(name, text, expect_single=True):
    st = statements(text)
    problems = []
    if expect_single and len(st) != 1:
        problems.append(f"{len(st)} statements (expected exactly 1)")
    for s in st:
        if not re.match(r"(select|with)\b", s, re.I):
            problems.append("statement does not start with SELECT/WITH: " + s[:40])
        m = FORBIDDEN.search(re.sub(r"\bexecute\b(?=\s+'?\s*ops)", "", s))
        if m:
            problems.append("forbidden keyword/function: " + m.group(0))
    return problems


def check_files():
    bad = 0
    for f in DISCOVERY_FILES:
        pr = check_sql_readonly(f.name, f.read_text())
        # 01_discovery uses query_to_xml over catalog SELECT strings; strings are stripped, and those strings are SELECTs by construction (checked below)
        print(("FAIL " if pr else "ok   ") + f.name + ("  " + "; ".join(pr) if pr else ""))
        bad += bool(pr)
        for lit in re.findall(r"query_to_xml\(\s*'((?:[^']|'')*)'", f.read_text(), re.S):
            if not re.match(r"\s*select\b", lit, re.I) or FORBIDDEN.search(strip_sql(lit)):
                print("FAIL " + f.name + "  query_to_xml string is not a plain SELECT: " + lit[:60]); bad += 1
    qs = split_queries((HERE / "legacy_conflict_queries.sql").read_text())
    for name, q in qs.items():
        pr = check_sql_readonly(name, q)
        print(("FAIL " if pr else "ok   ") + f"legacy_conflict_queries.sql {name}" + ("  " + "; ".join(pr) if pr else ""))
        bad += bool(pr)
    if not qs:
        print("FAIL no queries found"); bad += 1
    return bad


def confirm_target(ref, confirm):
    prod = os.environ.get("TDP_PROD_PROJECT_REF", "").strip().lower()
    ref = (ref or "").strip().lower()
    if not prod:
        sys.exit("REFUSED: TDP_PROD_PROJECT_REF is not set. The production project reference must be configured explicitly (never guessed).")
    if not re.fullmatch(r"[a-z0-9]{20}", prod):
        sys.exit("REFUSED: TDP_PROD_PROJECT_REF is not a 20-character project reference.")
    if prod == DELETED_TEST_REF or prod.startswith(TEST_PREFIX) or ref == DELETED_TEST_REF or ref.startswith(TEST_PREFIX):
        sys.exit("REFUSED: that is the deleted temporary TEST project reference (or shares its prefix). It is never a production target.")
    if ref != prod:
        sys.exit("REFUSED: --ref does not equal the configured production reference.")
    if confirm != f"DISCOVER PRODUCTION {prod}":
        sys.exit(f"REFUSED: the typed confirmation must be exactly 'DISCOVER PRODUCTION {prod}'.")
    print(f"GO: target reference {prod[:4]}...{prod[-4:]} confirmed. NOW compare it with the Supabase dashboard URL/Settings yourself before pasting any SQL. Results MUST be reviewed before any freeze or migration.")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("check-files", "confirm-target"):
        sys.exit("REFUSED: no action given. Use 'check-files' or 'confirm-target'. (This tool never connects to anything.)")
    if argv[1] == "check-files":
        sys.exit(1 if check_files() else 0)
    a = dict(zip(argv[2::2], argv[3::2]))
    confirm_target(a.get("--ref"), a.get("--confirm"))


if __name__ == "__main__":
    main(sys.argv)
