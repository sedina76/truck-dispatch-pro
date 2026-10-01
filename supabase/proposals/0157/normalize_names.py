#!/usr/bin/env python3
"""Proposal 0157 -- D-57f: normalize the `_0157` proposal object names at PROMOTION, with collision and drift refusal checks. Repository-only; reads files, writes nothing unless --write DIR.

The proposal keeps a `_0157` suffix on its tables, indexes, constraints, triggers and functions so it can never collide with (or be mistaken for) an existing object while it is only a proposal. When the Owner
promotes it, the suffix is removed MECHANICALLY (this script) from the four reviewed files (proposed, preflight, post_apply, rollback) -- never by hand.

  python3 normalize_names.py --check          refuses (exit 1) on: a name collapse (two names normalizing to one), a normalized name that already exists in supabase/migrations or in any OTHER proposal, a leftover `_0157` identifier
  python3 normalize_names.py --write DIR      writes the four normalized files into DIR (outside the repository migrations folder is the Owner's choice; this script never writes under supabase/migrations)
  python3 normalize_names.py --verify FILE NAME   DRIFT REFUSAL: exits 1 unless FILE is byte-identical to the normalized NAME (proposed_0157.sql | preflight.sql | post_apply.sql | rollback.sql)
"""
import hashlib
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
FILES = ("proposed_0157.sql", "preflight.sql", "post_apply.sql", "rollback.sql")
IDENT = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*_0157(?=[_\W]|$)(?!\.sql)[A-Za-z0-9_]*")
SUFFIX = re.compile(r"_0157(?=[_\W]|$)(?!\.sql)")


def source_texts():
    return {f: (HERE / f).read_text() for f in FILES}


def names(text):
    return sorted(set(IDENT.findall(text)))


def normalize_text(text):
    return SUFFIX.sub("", text)


def normalized_files():
    return {f: normalize_text(t) for f, t in source_texts().items()}


def mapping():
    allnames = sorted({n for t in source_texts().values() for n in names(t)})
    return {n: SUFFIX.sub("", n) for n in allnames}


def other_sql_text():
    out = []
    for p in list((SUPA / "migrations").glob("*.sql")) + [q for q in (SUPA / "proposals").rglob("*.sql") if HERE not in q.parents]:
        out.append((str(p.relative_to(SUPA)), p.read_text(errors="replace")))
    return out


def problems():
    bad = []
    m = mapping()
    if not m:
        bad.append("no _0157 names found (nothing to normalize?)")
    inv = {}
    for old, new in m.items():
        inv.setdefault(new, []).append(old)
    for new, olds in inv.items():
        if len(olds) > 1:
            bad.append(f"NAME COLLAPSE: {olds} would all become '{new}'")
    others = other_sql_text()
    for old, new in m.items():
        pat = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(new) + r"(?![A-Za-z0-9_])")
        for rel, txt in others:
            code = re.sub(r"--.*", "", txt)
            if pat.search(code):
                bad.append(f"COLLISION: normalized name '{new}' (from '{old}') already appears in {rel}")
                break
    for f, t in normalized_files().items():
        left = IDENT.findall(t)
        if left:
            bad.append(f"LEFTOVER: {f} still contains {sorted(set(left))[:3]}")
    return bad


def digest():
    h = hashlib.sha256()
    for f, t in sorted(normalized_files().items()):
        h.update(f.encode() + b"\0" + t.encode() + b"\0")
    return h.hexdigest()


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--check"]:
        bad = problems()
        print("\n".join(bad) if bad else f"name normalization is safe: {len(mapping())} names, no collapse, no collision, none left; normalized-set sha256 {digest()}")
        sys.exit(1 if bad else 0)
    if a[:1] == ["--write"] and len(a) == 2:
        bad = problems()
        if bad:
            print("REFUSED:\n" + "\n".join(bad))
            sys.exit(1)
        out = Path(a[1])
        if (SUPA / "migrations").resolve() in out.resolve().parents or out.resolve() == (SUPA / "migrations").resolve():
            print("REFUSED: this script never writes under supabase/migrations")
            sys.exit(1)
        out.mkdir(parents=True, exist_ok=True)
        for f, t in normalized_files().items():
            (out / f.replace("_0157", "")).write_text(t)
            print(f"wrote {out / f.replace('_0157', '')}")
        sys.exit(0)
    if a[:1] == ["--verify"] and len(a) == 3:
        want = normalized_files().get(a[2])
        if want is None:
            print(f"unknown file name {a[2]}")
            sys.exit(2)
        got = Path(a[1]).read_text()
        print("candidate is byte-identical to the normalized reviewed file" if got == want else "DRIFT REFUSED: the candidate differs from the normalized reviewed file")
        sys.exit(0 if got == want else 1)
    print(__doc__)
    sys.exit(2)
