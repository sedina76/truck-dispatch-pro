#!/usr/bin/env python3
"""Proposal 0149 -- disposable-PostgreSQL verification harness.

NOT APPROVED FOR PRODUCTION. Creates a brand-new local cluster under
/private/tmp/td0149-local-*, unix-socket only (listen_addresses=''), port 55491,
with an explicit minimal environment (no PGSERVICE / inherited PG* variables) and
absolute binary paths. It never connects to Supabase or any real database and
never writes inside the repository.

What it proves (all against the REAL 0129 function bodies, the REAL 0130-0135
migrations and a faithful support schema; see README.md):
  static  generated SQL is current; 0129/0130-0135/support-schema sources are
          SHA-256 pinned; the 0149 function bodies differ from 0129 by exactly the
          two c_active declarations; verifiers contain no write statements
  live    baseline defect reproduced (42883) -> preflight ok -> clone drift
          scenarios fail closed -> apply -> post_apply ok -> before/after catalog
          + pg_dump comparison (only the two function bodies changed) ->
          functional regression suite -> fail-closed re-apply -> rollback ->
          exact restoration (catalog + dump identical) -> reapply -> identical
          to the first apply -> regression suite again
"""
import atexit
import difflib
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build  # noqa: E402

SUPA = HERE.parents[1]
BIN = "/opt/homebrew/bin"
INITDB, PG_CTL, PSQL, PG_DUMP = (f"{BIN}/{n}" for n in ("initdb", "pg_ctl", "psql", "pg_dump"))
ALLOWED = {INITDB, PG_CTL, PSQL, PG_DUMP}
PORT = 55491
SEP = "\x1f"

PINNED = {
    "migrations/0129_atomic_dispatch_lifecycle.sql": "cd8515d202f146fb6395fd11ab8feef7a4c99de0a3ef47c959c988d6c270f945",
    "migrations/0130_carrier_context_foundation.sql": "a3ac49661079edf1cca13a5ae8b7958c714c1cfeb8df15eeb2df59c48d76e155",
    "migrations/0131_carrier_party_relationships.sql": "6bced38e25aed452c507eca0df69d5312fa2e04ba1186e64a80eade753673e79",
    "migrations/0132_load_carrier_and_trailer_scope.sql": "bcc4242424ccd42b6868350086ca2655453cb464facd02ce5718added54c5a7e",
    "migrations/0133_deterministic_carrier_backfill.sql": "110f6165ad5e04ffdf2c41e2fa1619727f3f33cc98b24191f31092f991ccca27",
    "migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql": "b71bb6eb07a76902fc24f196d11c88afdc49d2f7913c0d9613c85a9c4d305ed9",
    "migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql": "43b7ae277ebf3e1ed9f2d2b09616a196a6d072cd04bd820ffbbe21dd7e9c4e2f",
    "TEST_SUPPORT_0130_0133_schema.sql": "edb1180128d7f1f856adc103f1fe47e075fe095a2e72b0e4807537486cf121fb",
}
CHAIN = [k for k in PINNED if k.startswith("migrations/013")]
EXPECTED_OK_NOTICES = 19  # regression.sql "OK:" lines (T0,T1,T1b,T2,T2c,T2b x2,T3-6,T3 terminal,T7,T7d/e,T8,T9 x4,T9c x2,T10)

results = {"checks": [], "steps": {}}


def check(label, cond, detail=""):
    if not cond:
        raise SystemExit(f"FAIL: {label} {detail}")
    results["checks"].append(label)
    print(f"  ok  {label}")


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def pinned(rel: str) -> str:
    raw = (SUPA / rel).read_bytes()
    if sha256(raw) != PINNED[rel]:
        raise SystemExit(f"Unreviewed source (SHA-256 mismatch): {rel}")
    return raw.decode("utf-8")


def strip_sql(text: str) -> str:
    """Remove single-quoted strings and -- comments (string-aware), for keyword scans."""
    out, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            i += 1
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            out.append("''")
        elif text.startswith("--", i):
            while i < n and text[i] != "\n":
                i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def guard_of(text: str) -> str:
    return text[text.index("-- BEGIN_GUARD"):text.index("-- END_GUARD") + len("-- END_GUARD")]


def manifest(path: Path) -> dict:
    return {str(p.relative_to(path)): sha256(p.read_bytes()) for p in sorted(path.rglob("*")) if p.is_file()}


# ------------------------------------------------------------------- static
def static_checks():
    print("== static checks ==")
    files = build.build_all()
    for name, text in files.items():
        check(f"generated {name} is current", (HERE / name).read_text() == text)
    for rel in PINNED:
        pinned(rel)
    check("0129 + 0130-0135 + support schema match their SHA-256 pins", True)
    m = build.model()
    for name, f in m["funcs"].items():
        check(f"{name}: 0149 block == 0129 block with ONLY the c_active declaration replaced",
              f["new_block"] == f["old_block"].replace(build.OLD_DECL, build.NEW_DECL) and f["old_block"].count(build.OLD_DECL) == 1)
        diff = [l for l in difflib.unified_diff(f["old_block"].splitlines(), f["new_block"].splitlines(), lineterm="", n=0)
                if l[:1] in "+-" and not l.startswith(("---", "+++"))]
        want = ["-  c_active constant text[] := array[", "-    'en_route_to_delivery','at_delivery'];",
                "+  c_active constant public.dispatch_status[] := array[", "+    'en_route_to_delivery','at_delivery']::public.dispatch_status[];"]
        check(f"{name}: line diff vs 0129 is exactly the two declaration lines", sorted(diff) == sorted(want), str(diff))
        check(f"{name}: comment/whitespace-insensitive body differs ONLY by type + cast",
              build.norm(f["new_body"]).replace("public.dispatch_status[]:=array", "text[]:=array")
              .replace("]::public.dispatch_status[];", "];", 1) == build.norm(f["old_body"]))
        check(f"{name}: dispatches.status is never cast to text in the repaired body", "status::text" not in build.norm(f["new_body"]))
    prop = (HERE / "proposed_0149.sql").read_text()
    roll = (HERE / "rollback.sql").read_text()
    for name, f in m["funcs"].items():
        check(f"proposed_0149.sql embeds the repaired {name} block verbatim", build.as_replace(f["new_block"]) in prop)
        check(f"rollback.sql embeds the exact 0129 {name} block verbatim", build.as_replace(f["old_block"]) in roll)
    check("proposed_0149.sql has exactly two CREATE OR REPLACE FUNCTION statements", len(re.findall(r"create or replace function", prop)) == 2)
    check("rollback.sql has exactly two CREATE OR REPLACE FUNCTION statements", len(re.findall(r"create or replace function", roll)) == 2)
    forbidden = re.compile(r"\b(create|alter|drop|grant|revoke|insert|update|delete|truncate|copy|comment|reindex|vacuum)\b", re.I)
    for name in ("proposed_0149.sql", "rollback.sql"):
        text = (HERE / name).read_text()
        for f in m["funcs"].values():
            text = text.replace(build.as_replace(f["new_block"]), "").replace(build.as_replace(f["old_block"]), "")
        check(f"{name}: outside the two function blocks only begin/commit/DO(select-only checks)", not forbidden.search(strip_sql(text)), forbidden.findall(strip_sql(text)).__str__())
    strict = re.compile(r"\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|comment|copy|call|do|begin|commit|rollback|savepoint|"
                        r"set|reset|lock|listen|notify|vacuum|reindex|analyze|execute|prepare|declare|fetch|refresh|cluster|import|security)\b", re.I)
    for name in ("preflight.sql", "post_apply.sql"):
        raw = (HERE / name).read_text()
        s = strip_sql(raw)
        hits = [w for w in strict.findall(s)]
        check(f"{name}: exactly ONE select statement; no data-/schema-changing keyword, transaction control, set_config or routine call in code",
              s.count(";") == 1 and s.lstrip().lower().startswith("with expect") and not hits and "set_config" not in s, str(hits))
        raw_hits = re.findall(r"(?i)\b(insert|update|delete|merge|truncate|create|alter|drop|grant|revoke|comment|copy|call)\b", raw)
        check(f"{name}: forbidden words appear nowhere in the file text (code, strings or comments)", not raw_hits, str(raw_hits))
    later = [p.name for p in sorted((SUPA / "migrations").glob("*.sql")) if int(p.name[:4]) > 129
             and re.search(r"create (or replace )?function public\.(create|cancel)_dispatch\(", p.read_text())]
    check("no migration after 0129 redefines create_dispatch/cancel_dispatch", not later, str(later))
    bad = [p.name for p in sorted((SUPA / "migrations").glob("*.sql")) if p.name != "0129_atomic_dispatch_lifecycle.sql"
           and re.search(r"c_active\s+constant\s+text\[\]", p.read_text())]
    check("no other migration declares c_active constant text[] (blast radius = 0129 only)", not bad, str(bad))
    g = guard_of((HERE / "fixture.sql").read_text())
    check("scratch guard is identical in fixture.sql, regression.sql and defect_repro.sql",
          all(guard_of((HERE / n).read_text()) == g for n in ("regression.sql", "defect_repro.sql")))
    return g


# ------------------------------------------------------------------ cluster
class Cluster:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="td0149-local-", dir="/private/tmp")).resolve()
        os.chmod(self.root, 0o700)
        if not re.fullmatch(r"/private/tmp/td0149-local-[A-Za-z0-9_]+", str(self.root)):
            raise SystemExit(f"unsafe root {self.root}")
        self.data, self.sock, self.tmp = self.root / "data", self.root / "socket", self.root / "tmp"
        self.sock.mkdir(mode=0o700)
        self.tmp.mkdir(mode=0o700)
        pgpass = self.root / "pgpass"
        pgpass.write_text("")
        os.chmod(pgpass, 0o600)
        self.env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C", "HOME": str(self.root), "TMPDIR": str(self.tmp),
                    "PGSERVICEFILE": str(self.root / "no_service.conf"), "PGPASSFILE": str(pgpass)}
        self.started = False

    def run(self, prog, args, inp=None, extra=None, ok=True):
        if prog not in ALLOWED:
            raise SystemExit(f"executable not allowed: {prog}")
        env = dict(self.env)
        env.update(extra or {})
        p = subprocess.run([prog, *args], input=inp, capture_output=True, text=True, env=env, timeout=600)
        if ok and p.returncode != 0:
            raise SystemExit(f"{prog} failed rc={p.returncode}\n{p.stderr[-3000:]}\n{p.stdout[-1500:]}")
        return p

    def start(self):
        self.run(INITDB, ["-D", str(self.data), "-U", "postgres", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        opts = shlex.join(["-p", str(PORT), "-c", "listen_addresses=", "-c", f"unix_socket_directories={self.sock}", "-c", "fsync=off"])
        self.run(PG_CTL, ["-D", str(self.data), "-l", str(self.root / "server.log"), "-o", opts, "-w", "start"])
        self.started = True

    def stop(self):
        if self.started:
            self.run(PG_CTL, ["-D", str(self.data), "-m", "immediate", "-w", "stop"], ok=False)
            self.started = False

    def psql(self, db, sql, guard=False, tuples=False, ro=False, ok=True):
        args = ["-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-h", str(self.sock), "-p", str(PORT), "-U", "postgres", "-d", db, "-f", "-"]
        if tuples:
            args += ["-A", "-t", "-F", SEP]
        if ro:
            sql = "begin read only;\n" + sql + "\ncommit;\n"
        extra = {"PGOPTIONS": "-c app.zzz_0149_test=scratch-ok"} if guard else {}
        return self.run(PSQL, args, inp=sql, extra=extra, ok=ok)

    def dump(self, db):
        out = self.run(PG_DUMP, ["-h", str(self.sock), "-p", str(PORT), "-U", "postgres", "-d", db, "--schema-only"]).stdout
        return [l for l in out.splitlines() if not l.startswith(("\\restrict", "\\unrestrict"))]

    def createdb(self, name, template=None):
        self.psql("postgres", f'create database {name}' + (f" template {template}" if template else "") + ";")

    def dropdb(self, name):
        self.psql("postgres", f"drop database if exists {name} with (force);")   # FORCE (PG13+): a client-killed backend (pg_sleep holder) must not block cleanup

    def cleanup(self, success):
        self.stop()
        if success and self.root.exists() and re.fullmatch(r"/private/tmp/td0149-local-[A-Za-z0-9_]+", str(self.root)) \
                and not self.root.is_symlink() and shutil.rmtree.avoids_symlink_attacks:
            shutil.rmtree(self.root)
            print(f"cleaned {self.root}")
        else:
            print(f"RETAINED for inspection: {self.root}")


CATALOG_SQL = r"""
select cat || chr(31) || obj || chr(31) || md5(def) from (
  select 'relation' as cat, n.nspname::text || '.' || c.relname::text as obj,
         concat_ws('|', c.relkind::text, pg_get_userbyid(c.relowner)::text, coalesce(c.relacl::text, ''), c.relrowsecurity::text,
                   c.relforcerowsecurity::text, coalesce(c.reloptions::text, ''), coalesce(obj_description(c.oid, 'pg_class'), '')) as def
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname in ('public', 'auth', 'td0149_t') and c.relkind in ('r','p','v','m','S','i')
  union all
  select 'column', n.nspname::text || '.' || c.relname::text || '.' || a.attname::text,
         concat_ws('|', format_type(a.atttypid, a.atttypmod), a.attnotnull::text, coalesce(pg_get_expr(d.adbin, d.adrelid), ''),
                   a.attgenerated::text, a.attidentity::text, coalesce(a.attacl::text, ''))
    from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where n.nspname in ('public', 'auth', 'td0149_t') and a.attnum > 0 and not a.attisdropped and c.relkind in ('r','p','v','m')
  union all
  select 'constraint', n.nspname::text || '.' || c.relname::text || '.' || k.conname::text, pg_get_constraintdef(k.oid) || '|' || k.convalidated::text
    from pg_constraint k join pg_class c on c.oid = k.conrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname in ('public', 'auth', 'td0149_t')
  union all
  select 'index', schemaname::text || '.' || indexname::text, indexdef from pg_indexes where schemaname in ('public', 'auth', 'td0149_t')
  union all
  select 'trigger', n.nspname::text || '.' || c.relname::text || '.' || t.tgname::text, pg_get_triggerdef(t.oid) || '|' || t.tgenabled::text
    from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where not t.tgisinternal and n.nspname in ('public', 'auth', 'td0149_t')
  union all
  select 'policy', schemaname::text || '.' || tablename::text || '.' || policyname::text, to_jsonb(p)::text from pg_policies p where schemaname in ('public', 'auth', 'td0149_t')
  union all
  select 'function_body', n.nspname::text || '.' || p.proname::text || '(' || pg_get_function_identity_arguments(p.oid) || ')', md5(p.prosrc) || '|' || l.lanname::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang where n.nspname in ('public', 'auth', 'td0149_t')
  union all
  select 'function_meta', n.nspname::text || '.' || p.proname::text || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         concat_ws('|', pg_get_userbyid(p.proowner)::text, coalesce(p.proacl::text, ''), coalesce(p.proconfig::text, ''), pg_get_function_arguments(p.oid),
                   p.prorettype::regtype::text, p.prokind::text, p.provolatile::text, p.prosecdef::text, p.proisstrict::text, p.proleakproof::text,
                   p.proparallel::text, coalesce(obj_description(p.oid, 'pg_proc'), ''))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'auth', 'td0149_t')
  union all
  select 'type', n.nspname::text || '.' || t.typname::text,
         t.typtype::text || '|' || coalesce((select string_agg(e.enumlabel::text, ',' order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid), '')
    from pg_type t join pg_namespace n on n.oid = t.typnamespace where n.nspname in ('public', 'auth', 'td0149_t') and t.typtype in ('e', 'd', 'c')
) x order by 1;
"""


def catalog(c, db):
    out = c.psql(db, CATALOG_SQL, tuples=True, ro=True).stdout
    d = {}
    for line in out.splitlines():
        if line.strip():
            cat, obj, h = line.split(SEP)
            d[(cat, obj)] = h
    return d


def changed(a, b):
    return sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))


def verify(c, db, sqlfile, role=None):
    """Run a production verifier inside a READ ONLY transaction (optionally as a role). Returns {ok, rows, err}.
    PASS -> rc 0 and a final RESULT|PASS row; FAIL -> the statement raises (rc != 0) and err carries the report."""
    text = (HERE / sqlfile).read_text()
    if role:
        text = f"set local role {role};\n" + text
    p = c.psql(db, text, tuples=True, ro=True, ok=False)
    rows = [l.split(SEP) for l in p.stdout.splitlines() if l.count(SEP) == 4]
    ok = p.returncode == 0 and bool(rows) and rows[-1][1] == "RESULT" and rows[-1][3] == "PASS" \
        and all(r[3] in ("INFO", "PASS") for r in rows)
    return {"ok": ok, "rows": rows, "err": p.stderr}


def failed_items(v):
    """Failing check titles from the error report (lines 'CHECK | <item> | FAIL | <detail>')."""
    return [l.split(" | ")[1] for l in v["err"].splitlines() if " | FAIL | " in l]


REQUIRED_REPORT_ITEMS = ["server_version", "server_version_num", "version()", "dispatches.status column type",
                         "dispatch_status enum values (in sort order)", "public functions declaring c_active constant text[]"]
REQUIRED_PER_FUNCTION = ["identity", "identity arguments", "arguments with defaults", "returns", "language", "volatility", "parallel safety",
                         "security mode", "configuration (search_path)", "owner", "raw ACL", "EXECUTE privilege", "declared c_active type", "live body md5 (normalised)"]


def race_test(c, template_db, guard):
    """Two REAL concurrent sessions exercising create_dispatch's `exception when unique_violation` handler
    (its three `d.status = any(c_active)` sites). Session A is paused inside its own INSERT (advisory-lock
    hook trigger), session B commits a competing ACTIVE dispatch, then A resumes, trips the 0054 partial
    unique index and must re-derive the holder (TDDRV/TDTRK/TDTRL with the holder's dispatch id)."""
    import time
    db = "td0149_race"
    c.createdb(db, template=template_db)
    try:
        c.psql(db, guard + """
\\set ON_ERROR_STOP on
create function td0149_t.pause_hook() returns trigger language plpgsql as $$
begin
  if new.load_id = td0149_t.id('l14') then
    perform pg_advisory_lock(149149);
    perform pg_advisory_unlock(149149);
  end if;
  return new;
end $$;
create trigger zz_pause before insert on public.dispatches for each row execute function td0149_t.pause_hook();
""", guard=True)
        rounds = [
            ("driver", "TDDRV", "(l16, ca, ta2, da3, null)", "insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status) values (td0149_t.id('race_b'), td0149_t.id('o1'), td0149_t.id('l16'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da3'), 'assigned');", "LD-100016"),
            ("truck", "TDTRK", "(l17, ca, ta3, da2, null)", "insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status) values (td0149_t.id('race_b'), td0149_t.id('o1'), td0149_t.id('l17'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da2'), 'assigned');", "LD-100017"),
            ("trailer", "TDTRL", "(l18, ca, ta2, da2, ra2)", "insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, trailer_id, status) values (td0149_t.id('race_b'), td0149_t.id('o1'), td0149_t.id('l18'), td0149_t.id('ca'), td0149_t.id('ta2'), td0149_t.id('da2'), td0149_t.id('ra2'), 'assigned');", "LD-100018"),
        ]
        out = []
        base_args = ["-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-h", str(c.sock), "-p", str(PORT), "-U", "postgres", "-d", db, "-f", "-"]
        for mode, want, _, competing, ld in rounds:
            env = dict(c.env)
            holder = subprocess.Popen([PSQL, *base_args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            holder.stdin.write("select pg_advisory_lock(149149); select pg_sleep(60);\n")
            holder.stdin.close()
            for _ in range(100):
                if c.psql(db, "select count(*) from pg_locks where locktype = 'advisory' and objid = 149149 and granted;", tuples=True).stdout.strip() == "1":
                    break
                time.sleep(0.1)
            else:
                holder.kill()
                raise SystemExit("race: lock holder never acquired the advisory lock")
            a_sql = ("select set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);\n"
                     "select r.state, r.msg, r.detail, r.new_id from td0149_t.try_create(td0149_t.id('l14'), td0149_t.id('ca'), td0149_t.id('ta3'), td0149_t.id('da3'), td0149_t.id('ra2')) r;\n")
            a = subprocess.Popen([PSQL, *base_args, "-A", "-t", "-F", SEP], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            a.stdin.write(a_sql)
            a.stdin.close()
            for _ in range(100):
                if c.psql(db, "select count(*) from pg_locks where locktype = 'advisory' and objid = 149149 and not granted;", tuples=True).stdout.strip() == "1":
                    break
                time.sleep(0.1)
            else:
                a.kill(); holder.kill()
                raise SystemExit("race: session A never blocked inside its INSERT")
            c.psql(db, "select set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);\n" + competing)  # session B: committed competing active dispatch
            holder.terminate()   # releases the advisory lock -> A resumes and trips the 0054 index
            holder.communicate(timeout=30)
            so, se = a.communicate(timeout=60)
            if a.returncode != 0:
                raise SystemExit(f"race session A failed: {se}")
            fields = [l for l in so.splitlines() if SEP in l][-1].split(SEP)
            holder_id = c.psql(db, "select td0149_t.id('race_b')::text;", tuples=True).stdout.strip()
            check(f"race[{mode}]: unique_violation handler re-derives {want} naming the committed holder (detail = holder dispatch id, message names {ld})",
                  fields[0] == want and fields[2] == holder_id and ld in fields[1] and fields[3] == "", str(fields))
            state = c.psql(db, "select (select count(*) from public.dispatches where load_id = td0149_t.id('l14')) || '|' || (select status::text from public.loads where id = td0149_t.id('l14')) || '|' || coalesce((select carrier_id::text from public.loads where id = td0149_t.id('l14')), '-');", tuples=True).stdout.strip()
            check(f"race[{mode}]: the losing create left no dispatch, no load status change and no carrier claim", state == "0|booked|-", state)
            out.append(f"{mode}:{fields[0]}")
            c.psql(db, "select set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);\nselect public.cancel_dispatch(td0149_t.id('race_b'), 'race cleanup');\n"
                       "delete from public.dispatch_financials where dispatch_id = td0149_t.id('race_b');\n"
                       "update public.loads set financial_dispatch_id = null where financial_dispatch_id = td0149_t.id('race_b');\n"
                       "delete from public.dispatches where id = td0149_t.id('race_b');\n")
        return out
    finally:
        c.dropdb(db)

# -------------------------------------------------------------------- flow
def main():
    guard = static_checks()
    manifest_0148_before = manifest(SUPA / "proposals" / "0148")
    files = {n: (HERE / n).read_text() for n in ("proposed_0149.sql", "rollback.sql", "preflight.sql", "post_apply.sql")}
    m = build.model()
    text_0129 = build.source()

    c = Cluster()
    success = False

    def bail(*_):
        c.cleanup(False)
        sys.exit(130)

    signal.signal(signal.SIGINT, bail)
    signal.signal(signal.SIGTERM, bail)
    atexit.register(lambda: c.started and c.stop())
    try:
        print(f"== cluster {c.root} (port {PORT}, unix socket only) ==")
        c.start()
        c.createdb("td0149_main")
        DB = "td0149_main"

        # ---- setup: support schema + 0129 BASELINE + 0130..0135 + fixture -------------------
        base = "".join(m["funcs"][n]["old_block"] + "\n\n" for n in ("create_dispatch", "cancel_dispatch")) + build.baseline_privileges_sql(text_0129)
        setup = (guard + "\n\\set ON_ERROR_STOP on\n" + pinned("TEST_SUPPORT_0130_0133_schema.sql")
                 + "\ndrop function public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text);\n"
                 + "drop function public.cancel_dispatch(uuid,text);\n" + base
                 + "".join("\n" + pinned(rel) for rel in CHAIN) + "\n" + (HERE / "fixture.sql").read_text())
        c.psql(DB, setup, guard=True)
        print("== baseline installed (0129 functions + real 0130-0135 + fixture) ==")

        # a scratch-guard refusal proof: fixture guard must refuse without the opt-in
        refuse = c.psql(DB, guard + "\nselect 1;", guard=False, ok=False)
        check("scratch guard refuses to run without the explicit opt-in setting", refuse.returncode != 0 and "TEST_0149 refused" in refuse.stderr)

        # ---- preflight on the baseline ---------------------------------------------------------
        pre = verify(c, DB, "preflight.sql")
        n_pass = sum(r[3] == "PASS" for r in pre["rows"] if r[1] != "RESULT")
        n_info = sum(r[3] == "INFO" for r in pre["rows"])
        check(f"preflight.sql: baseline recognised ({n_pass} PASS checks, {n_info} INFO rows, RESULT=PASS, read-only txn)", pre["ok"], pre["err"][-800:])
        items = {r[2] for r in pre["rows"]}
        need = REQUIRED_REPORT_ITEMS + [f"{fn}: {i}" for fn in ("create_dispatch", "cancel_dispatch") for i in REQUIRED_PER_FUNCTION]
        check("preflight report exposes server version, both function identities/signatures, language, volatility, security mode, search_path, owner, ACL/EXECUTE, status type, enum values, c_active declaration, live body fingerprint",
              all(i in items for i in need), str([i for i in need if i not in items]))
        check("preflight report shows the defective text[] declaration in the LIVE bodies",
              all(r[4] == "text[]" for r in pre["rows"] if r[2].endswith(": declared c_active type")))
        check("preflight report contains no connection strings, keys or passwords",
              not re.search(r"(?i)password|secret|api[_ ]?key|jwt|postgres(ql)?://", "\n".join(SEP.join(r) for r in pre["rows"])))
        c.psql("postgres", "create role td0149_reader nologin;")
        lp = c.psql(DB, "select has_table_privilege('td0149_reader', 'public.dispatches', 'SELECT') or has_table_privilege('td0149_reader', 'public.loads', 'SELECT') "
                        "or has_schema_privilege('td0149_reader', 'td0149_t', 'USAGE');", tuples=True).stdout.strip()
        check("test role td0149_reader holds no privilege on any user table", lp == "f", lp)
        lo = verify(c, DB, "preflight.sql", role="td0149_reader")
        check("preflight.sql passes for a role with NO table privileges (it reads catalog metadata only, never user data)", lo["ok"] and lo["rows"] == pre["rows"], lo["err"][-500:])
        if "--show-preflight" in sys.argv:
            print("\n".join(" | ".join(r) for r in pre["rows"]))
        post_on_base = verify(c, DB, "post_apply.sql")
        check("post_apply.sql correctly RAISES on the un-repaired baseline", not post_on_base["ok"] and "POST_APPLY FAIL" in post_on_base["err"])
        results["steps"]["preflight_pass_checks"] = n_pass
        results["steps"]["preflight_info_rows"] = n_info

        # ---- defect reproduction ----------------------------------------------------------------
        rep = c.psql(DB, (HERE / "defect_repro.sql").read_text(), guard=True)
        check("defect reproduced on baseline: create_dispatch AND cancel_dispatch raise 42883 dispatch_status = text",
              "DEFECT REPRODUCED ON BASELINE" in rep.stderr)
        repro_lines = [l.split("NOTICE:")[-1].strip() for l in rep.stderr.splitlines() if "REPRO " in l]

        # ---- baseline snapshots -------------------------------------------------------------------
        cat0, dump0 = catalog(c, DB), c.dump(DB)
        print(f"== baseline snapshot: {len(cat0)} catalog objects, {len(dump0)} dump lines ==")

        # ---- drift scenarios on clones of the baseline -------------------------------------------
        print("== fail-closed drift scenarios (each on a clone of the baseline) ==")
        cb = m["funcs"]["create_dispatch"]["old_block"]
        harmless = cb.replace("begin\n  -- 1. authenticated", "begin\n\n\n  -- harmless comment added by an operator\n  -- 1. authenticated")
        assert harmless != cb
        material = cb.replace("You must be signed in to create a dispatch.", "You must be signed in to create a dispatch!")
        assert material != cb
        scenarios = [
            ("d1_harmless_whitespace_comments", build.as_replace(harmless) + "\n", True, None),
            ("d2_material_body_drift", build.as_replace(material) + "\n", False, "body fingerprint matches 0129 baseline"),
            ("d3_acl_drift", "grant execute on function public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text) to anon;", False, "EXECUTE granted to authenticated only"),
            ("d4_enum_drift", "alter type public.dispatch_status add value 'zz_drift';", False, "exactly the expected 10 labels"),
            ("d5_extra_defective_function", "create function public.td0149_extra() returns int language plpgsql as $$ declare c_active constant text[] := array['x']; begin return 1; end $$;", False, "blast radius"),
            ("d6_search_path_drift", "alter function public.cancel_dispatch(uuid,text) set search_path = public, pg_temp;", False, "search_path is exactly public"),
            ("d7_security_definer_drift", "alter function public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text) security definer;", False, "SECURITY INVOKER"),
        ]
        for name, sql, harmless_ok, must_fail in scenarios:
            db = "td0149_" + name[:2]
            c.createdb(db, template=DB)
            c.psql(db, sql)
            pre_state = catalog(c, db)
            rows = verify(c, db, "preflight.sql")
            r = c.psql(db, files["proposed_0149.sql"], ok=False)
            post_state = catalog(c, db)
            if harmless_ok:
                check(f"{name}: harmless comment/whitespace drift is tolerated (preflight passes, 0149 applies)", rows["ok"] and r.returncode == 0)
                check(f"{name}: after apply the repaired definition is exactly recognised", verify(c, db, "post_apply.sql")["ok"])
            else:
                bad = failed_items(rows)
                if "--show-preflight" in sys.argv and name.startswith("d2"):
                    print("---- sample FAIL output (" + name + ") ----\n" + "\n".join(rows["err"].splitlines()[:14]) + "\n----")
                check(f"{name}: preflight RAISES (PREFLIGHT FAIL) naming '{must_fail}'", (not rows["ok"]) and "PREFLIGHT FAIL" in rows["err"] and any(must_fail in b for b in bad), str(bad))
                check(f"{name}: proposed_0149.sql fails closed and changes nothing",
                      r.returncode != 0 and "0149 precondition failed" in r.stderr and pre_state == post_state)
            c.dropdb(db)

        # ---- apply -------------------------------------------------------------------------------------
        a1 = c.psql(DB, files["proposed_0149.sql"])
        check("proposed_0149.sql applies (phase 1 preconditions + phase 3 postconditions pass)",
              "PHASE 1 preconditions passed" in a1.stderr and "PHASE 3 postconditions passed" in a1.stderr)
        post = verify(c, DB, "post_apply.sql")
        n_post = sum(r[3] == "PASS" for r in post["rows"] if r[1] != "RESULT")
        check(f"post_apply.sql: RESULT=PASS ({n_post} PASS checks, read-only txn)", post["ok"], post["err"][-800:])
        results["steps"]["post_apply_pass_checks"] = n_post
        pf = verify(c, DB, "preflight.sql")
        check("preflight.sql correctly RAISES after apply (defect signature gone)", not pf["ok"] and "PREFLIGHT FAIL" in pf["err"])

        cat1, dump1 = catalog(c, DB), c.dump(DB)
        diff_cat = changed(cat0, cat1)
        expect = sorted([("function_body", "public.create_dispatch(p_load_id uuid, p_carrier_id uuid, p_truck_id uuid, p_driver_id uuid, p_trailer_id uuid, p_dispatch_fee_percentage numeric, p_notes text)"),
                         ("function_body", "public.cancel_dispatch(p_dispatch_id uuid, p_reason text)")])
        check("catalog before/after: ONLY the two function bodies changed (relations/columns/constraints/indexes/triggers/policies/types/function metadata/ACLs/comments all identical)",
              diff_cat == expect, str(diff_cat))
        check("catalog before/after: object counts identical", len(cat0) == len(cat1))
        dl = [l for l in difflib.unified_diff(dump0, dump1, lineterm="", n=0) if l[:1] in "+-" and not l.startswith(("---", "+++"))]
        old_l = [l.rstrip("\n") for l in build.OLD_DECL.splitlines() if "'assigned'" not in l]
        new_l = [l.rstrip("\n") for l in build.NEW_DECL.splitlines() if "'assigned'" not in l]
        want = sorted(["-" + x for x in old_l] * 2 + ["+" + x for x in new_l] * 2)
        check("pg_dump --schema-only before/after: exactly 4 removed + 4 added lines (the two c_active declarations x 2 functions)",
              sorted(dl) == want, "\n".join(dl[:20]))
        results["steps"]["dump_diff_lines"] = dl

        # ---- functional regression --------------------------------------------------------------------
        r1 = c.psql(DB, (HERE / "regression.sql").read_text(), guard=True)
        oks = re.findall(r"NOTICE:\s+OK: (T[^\n]*)", r1.stderr)
        check(f"regression.sql passes ({len(oks)} OK assertions groups)", "TEST 0149 REGRESSION PASSED" in r1.stderr and len(oks) == EXPECTED_OK_NOTICES, f"{len(oks)}")
        results["steps"]["regression_ok_groups"] = len(oks)
        check("regression run left the catalog unchanged (ends in ROLLBACK)", catalog(c, DB) == cat1)
        results["steps"]["race_rounds"] = race_test(c, DB, guard)

        # ---- second apply must fail closed --------------------------------------------------------------
        a2 = c.psql(DB, files["proposed_0149.sql"], ok=False)
        check("re-applying 0149 on the repaired database fails closed and changes nothing",
              a2.returncode != 0 and "0149 precondition failed" in a2.stderr and catalog(c, DB) == cat1)

        # ---- rollback -----------------------------------------------------------------------------------
        rb = c.psql(DB, files["rollback.sql"])
        check("rollback.sql applies (pre/post conditions pass)", "PHASE 1 preconditions passed" in rb.stderr and "PHASE 3 postconditions passed" in rb.stderr)
        pre_rb = verify(c, DB, "preflight.sql")
        check("after rollback preflight.sql passes again (exact 0129 baseline restored)", pre_rb["ok"], pre_rb["err"][-800:])
        cat_rb, dump_rb = catalog(c, DB), c.dump(DB)
        check("after rollback: catalog identical to the pre-0149 baseline (every object, ACL, comment, body)", cat_rb == cat0, str(changed(cat0, cat_rb)))
        check("after rollback: pg_dump --schema-only byte-identical to the baseline dump", dump_rb == dump0)
        rep2 = c.psql(DB, (HERE / "defect_repro.sql").read_text(), guard=True)
        check("after rollback the original defect is present again (as expected)", "DEFECT REPRODUCED ON BASELINE" in rep2.stderr)
        rb2 = c.psql(DB, files["rollback.sql"], ok=False)
        check("rollback.sql on the un-repaired baseline fails closed and changes nothing",
              rb2.returncode != 0 and "0149 precondition failed" in rb2.stderr and catalog(c, DB) == cat0)

        # ---- reapply -------------------------------------------------------------------------------------
        a3 = c.psql(DB, files["proposed_0149.sql"])
        check("reapply after rollback succeeds", "PHASE 3 postconditions passed" in a3.stderr)
        post3 = verify(c, DB, "post_apply.sql")
        check("post_apply.sql passes after reapply", post3["ok"], post3["err"][-800:])
        cat3, dump3 = catalog(c, DB), c.dump(DB)
        check("after reapply: catalog identical to the first apply", cat3 == cat1)
        check("after reapply: pg_dump byte-identical to the first apply", dump3 == dump1)
        r2 = c.psql(DB, (HERE / "regression.sql").read_text(), guard=True)
        oks2 = re.findall(r"NOTICE:\s+OK: (T[^\n]*)", r2.stderr)
        check("regression.sql passes again after apply -> rollback -> reapply", "TEST 0149 REGRESSION PASSED" in r2.stderr and len(oks2) == EXPECTED_OK_NOTICES)

        # ---- 0148 untouched ---------------------------------------------------------------------------------
        check("supabase/proposals/0148 is byte-for-byte unchanged by this run", manifest(SUPA / "proposals" / "0148") == manifest_0148_before)
        results["steps"]["repro"] = repro_lines
        results["steps"]["regression_ok_lines"] = oks
        success = True
    finally:
        c.cleanup(success)
    print("\nALL 0149 CHECKS PASSED:", len(results["checks"]), "checks")
    print(json.dumps({"checks": len(results["checks"]), **{k: v for k, v in results["steps"].items() if k != "regression_ok_lines"}}, indent=2))


if __name__ == "__main__":
    main()
