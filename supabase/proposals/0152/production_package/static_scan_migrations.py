#!/usr/bin/env python3
"""Reproducible STATIC scan used by ADVERSARIAL_REVIEW.md (finding F-05/F-09/F-16). Reads the repository files only; never connects to anything.
It counts, over migrations 0130..0147, the SECURITY DEFINER (non-trigger) functions and which roles their REVOKE statements name, plus SECURITY DEFINER functions without a pinned search_path.
A REVOKE that names only PUBLIC does not remove EXECUTE that Supabase's default privileges grant explicitly to anon/authenticated/service_role: production ACLs must be read (P03)."""
import glob
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
MIG = Path(__file__).resolve().parents[3] / "migrations"


def scan():
    files = sorted(glob.glob(str(MIG / "013[0-9]*.sql")) + glob.glob(str(MIG / "014[0-7]*.sql")))
    sec, invoker, rev, nopath = {}, {}, {}, []
    for f in files:
        s = Path(f).read_text()
        num = Path(f).name[:4]
        for m in re.finditer(r"create\s+(?:or\s+replace\s+)?function\s+(public\.\w+)\s*\(([^)]*)\)(.*?)\bas\s+\$", s, re.I | re.S):
            head = m.group(3).lower()
            if "returns trigger" in head:
                continue
            if "security definer" in head:
                sec[m.group(1)] = num
                if "search_path" not in head:
                    nopath.append(m.group(1))
            else:
                invoker[m.group(1)] = num
        for m in re.finditer(r"revoke\s+(?:all|execute)\s+on\s+function\s+(public\.\w+)\s*\([^)]*\)\s+from\s+([^;]+);", s, re.I):
            rev.setdefault(m.group(1), set()).update(x.strip().lower() for x in m.group(2).split(","))
    return {
        "files": len(files),
        "security_definer_non_trigger": len(sec),
        "definer_without_pinned_search_path": sorted(nopath),
        "definer_without_any_revoke": sorted(n for n in sec if n not in rev),
        "definer_revoke_lacks_anon": sorted(n for n in sec if "anon" not in rev.get(n, set())),
        "definer_revoke_lacks_service_role": len([n for n in sec if "service_role" not in rev.get(n, set())]),
        "invoker_without_revoke": sorted(n for n in invoker if n not in rev),
    }


KW = {"select", "only", "lateral", "values", "the", "a", "an", "each", "new", "old", "this", "that", "it", "any", "all", "other", "one", "same", "which", "row", "rows", "table", "them", "each", "both", "here", "there", "now", "then", "of", "current_date", "current_timestamp"}


def strip_lit(t):
    return re.sub(r"--[^\n]*|/\*.*?\*/|'(?:[^']|'')*'", " ", t, flags=re.S)


def unqualified_relation_refs():
    """Heuristic (comments and string literals removed): in SECURITY DEFINER function bodies of 0130..0147 and proposals 0149..0156, an identifier right after FROM / JOIN / UPDATE / DELETE FROM /
    INSERT INTO that has no schema prefix and is not a CTE name, a plpgsql variable (v_*, p_*), a function call or a keyword. A hit means a caller's temporary table could shadow it (finding F-13)."""
    files = sorted(glob.glob(str(MIG / "013[0-9]*.sql")) + glob.glob(str(MIG / "014[0-7]*.sql")) + glob.glob(str(MIG.parent / "proposals" / "01[45][0-9]" / "proposed_*.sql")))
    hits = {}
    for f in files:
        s = Path(f).read_text()
        for m in re.finditer(r"create\s+(?:or\s+replace\s+)?function\s+(public\.\w+)\s*\(([^)]*)\)(.*?)\bas\s+(\$\w*\$)(.*?)\4", s, re.I | re.S):
            head, body = m.group(3).lower(), strip_lit(m.group(5))
            if "security definer" not in head or "returns trigger" in head:
                continue
            ctes = set(re.findall(r"\b(\w+)\s+as\s*(?:not\s+materialized\s*)?\(", body, re.I)) | set(re.findall(r"\bwith\s+(\w+)\s+as\b", body, re.I))
            for mm in re.finditer(r"\b(from|join|update|delete\s+from|insert\s+into)\s+([a-z_][a-z0-9_]*)\b(?!\s*[.(])", body, re.I):
                name = mm.group(2).lower()
                if name in KW or name in ctes or name.startswith(("v_", "p_", "c_")) or name in ("into", "set", "public", "pg_catalog", "auth", "lateral", "only"):
                    continue
                hits.setdefault(f"{Path(f).name}:{m.group(1)}", set()).add(name)
    return hits


if __name__ == "__main__":
    r = scan()
    for k, v in r.items():
        print(f"{k}: {v}")
    h = unqualified_relation_refs()
    print(f"unqualified_relation_ref_candidates: {sum(len(v) for v in h.values())} in {len(h)} function(s)")
    for k, v in sorted(h.items()):
        print("   ", k, sorted(v))
