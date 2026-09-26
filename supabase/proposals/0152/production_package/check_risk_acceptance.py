#!/usr/bin/env python3
"""Mechanical validity check of a COMPLETED copy of OWNER_RISK_ACCEPTANCE.md (PROPOSAL 0152). Reads one local file; never connects to anything.
  python3 check_risk_acceptance.py --file /path/to/completed_copy.md [--today YYYY-MM-DD]
Exit 0 only if every required field is filled with a non-placeholder value, the signature date is not in the future, the expiration date is after the signature date and not in the past,
the project reference is 20 characters and is not the deleted test project, the commit sha is 40 hex characters, and both acknowledgements are YES. Anything else exits 1 (EXPIRED/INVALID).
The unmodified repository template is always INVALID. This checks form only: it cannot prove the signature is genuine and it is NOT independent approval."""
import argparse
import re
import sys
from datetime import date, datetime

sys.dont_write_bytecode = True
FIELDS = ["OWNER-SIGNATURE", "OWNER-PRINTED-NAME", "DATE-SIGNED (YYYY-MM-DD)", "EXPIRATION-DATE (YYYY-MM-DD)", "SCOPE-PRODUCTION-PROJECT-REF", "SCOPE-COMMIT-SHA", "SCOPE-MIGRATIONS",
          "SCOPE-FREEZE-DESIGN", "SCOPE-WINDOW-REFERENCE", "ACKNOWLEDGES-NOT-INDEPENDENT-APPROVAL", "ACKNOWLEDGES-BLOCKERS-NOT-WAIVED"]
DELETED_TEST_REF = "fjmrvvyjvqdyopnyetez"


def parse(text):
    m = re.search(r"```\n(OWNER-SIGNATURE:.*?)```", text, re.S)
    if not m:
        return None
    out = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def validate(text, today):
    f = parse(text)
    if f is None:
        return ["signature block not found"]
    errs = []
    for k in FIELDS:
        v = f.get(k, "")
        if not v or (v.startswith("<") and v.endswith(">")):
            errs.append(f"{k}: blank or still a placeholder")
    if errs:
        return errs
    try:
        signed = datetime.strptime(f["DATE-SIGNED (YYYY-MM-DD)"], "%Y-%m-%d").date()
        expires = datetime.strptime(f["EXPIRATION-DATE (YYYY-MM-DD)"], "%Y-%m-%d").date()
    except ValueError:
        return ["dates must be YYYY-MM-DD"]
    if signed > today:
        errs.append("DATE-SIGNED is in the future")
    if expires < today:
        errs.append(f"EXPIRED: expiration date {expires} has passed")
    if expires <= signed:
        errs.append("expiration date must be after the signature date")
    ref = f["SCOPE-PRODUCTION-PROJECT-REF"].lower()
    if not re.fullmatch(r"[a-z0-9]{20}", ref):
        errs.append("SCOPE-PRODUCTION-PROJECT-REF must be a 20-character project reference")
    if ref == DELETED_TEST_REF or ref.startswith("fjmrvvyjvqd"):
        errs.append("SCOPE-PRODUCTION-PROJECT-REF is the deleted temporary test project")
    if not re.fullmatch(r"[0-9a-f]{40}", f["SCOPE-COMMIT-SHA"].lower()):
        errs.append("SCOPE-COMMIT-SHA must be a full 40-hex-character git sha")
    for k in ("ACKNOWLEDGES-NOT-INDEPENDENT-APPROVAL", "ACKNOWLEDGES-BLOCKERS-NOT-WAIVED"):
        if f[k].strip().upper() != "YES":
            errs.append(f"{k} must be YES")
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--today", help="override today's date for testing (YYYY-MM-DD)")
    a = ap.parse_args()
    today = datetime.strptime(a.today, "%Y-%m-%d").date() if a.today else date.today()
    errs = validate(open(a.file).read(), today)
    if errs:
        print("RISK ACCEPTANCE INVALID / EXPIRED -- the independent-review gate is NOT waived:")
        for e in errs:
            print("  - " + e)
        sys.exit(1)
    print("RISK ACCEPTANCE FORM VALID (form only; NOT independent approval; no other gate is waived; blockers still must be closed).")


if __name__ == "__main__":
    main()
