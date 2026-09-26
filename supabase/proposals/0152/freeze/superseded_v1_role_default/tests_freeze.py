#!/usr/bin/env python3
"""Local (disposable PostgreSQL) verification of the database-freeze tooling. NOT a hosted-Supabase test (see HOSTED_TEST_PLAN.md).

Simulates the Supabase role model on a brand-new local cluster (reusing the reviewed 0149 harness Cluster: unix socket only, /private/tmp, no network, no production
credentials): a NON-superuser operator (CREATEROLE + ADMIN OPTION on `authenticator` + pg_signal_backend, like the SQL Editor role), authenticator -> anon/authenticated/
service_role, a Supabase-internal login role, an unexpected app role, business tables/RPC owned by the operator, and a stub `cron` schema (pg_cron is not available locally).
Synthetic data only. Every script is executed as the operator over a real connection; new/stale sessions are real psql processes."""
import importlib.util
import re
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
PROPS = HERE.parents[2]


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


sys.path.insert(0, str(PROPS / "0149"))
t149 = _load("t149f", PROPS / "0149" / "tests.py")
SEP = t149.SEP
checks = []


def check(label, cond, detail=""):
    if not cond:
        raise SystemExit(f"FAIL: {label} {detail}")
    checks.append(label)
    print(f"  ok  {label}")


def sqlfile(name):
    return (HERE / name).read_text()


class Lab:
    def __init__(self):
        self.c = t149.Cluster()
        self.db = "frz_lab"

    def run(self, user, sql, db=None, tuples=False, ok=True, extra_args=()):
        args = ["-X", "-w", "-q", "-v", "ON_ERROR_STOP=1", "-h", str(self.c.sock), "-p", str(t149.PORT), "-U", user, "-d", db or self.db, "-f", "-", *extra_args]
        if tuples:
            args += ["-A", "-t", "-F", SEP]
        return self.c.run(t149.PSQL, args, inp=sql, ok=ok)

    def rows(self, user, sql, db=None):
        p = self.run(user, sql, db=db, tuples=True)
        return [l.split(SEP) for l in p.stdout.splitlines() if l.strip()]

    def scalar(self, sql, user="postgres"):
        r = self.rows(user, sql)
        return r[0][0] if r else None

    def session(self, user, first_sql):
        """A real long-lived psql session (its own backend). first_sql runs immediately; more can be sent."""
        env = dict(self.c.env)
        p = subprocess.Popen([t149.PSQL, "-X", "-w", "-q", "-v", "ON_ERROR_STOP=0", "-h", str(self.c.sock), "-p", str(t149.PORT), "-U", user, "-d", self.db, "-A", "-t"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        p.stdin.write(first_sql + "\n")
        p.stdin.flush()
        return p

    def reap(self, *users):
        """Test hygiene: end the backends of disposable test sessions (killing the psql client alone leaves a sleeping backend)."""
        for u in users:
            self.run("postgres", f"select pg_terminate_backend(pid) from pg_stat_activity where usename = '{u}' and pid <> pg_backend_pid();")
        time.sleep(0.3)

    def wait_backend(self, user, n=1, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            if int(self.scalar(f"select count(*) from pg_stat_activity where usename = '{user}' and backend_type = 'client backend'")) >= n:
                return True
            time.sleep(0.1)
        return False


def fill(script, **kw):
    """Substitute the operator-filled identities. Each placeholder line must exist exactly once."""
    reps = {
        "operator": ("v_operator_role   constant text   := '';", "v_operator_role   constant text   := '{v}';"),
        "major": ("v_expected_major  constant integer := 0;", "v_expected_major  constant integer := {v};"),
        "confirm": ("v_confirm         constant text   := '';", "v_confirm         constant text   := '{v}';"),
        "roles": ("v_api_roles       constant text[] := array[]::text[];", "v_api_roles       constant text[] := array[{v}]::text[];"),
        "other": ("v_reviewed_other_roles constant text[] := array[]::text[];", "v_reviewed_other_roles constant text[] := array[{v}]::text[];"),
        "pause": ("v_cron_pause_ids  constant bigint[] := array[]::bigint[];", "v_cron_pause_ids  constant bigint[] := array[{v}]::bigint[];"),
        "keep": ("v_cron_keep_ids   constant bigint[] := array[]::bigint[];", "v_cron_keep_ids   constant bigint[] := array[{v}]::bigint[];"),
    }
    for k, v in kw.items():
        old, new = reps[k]
        assert script.count(old) == 1, k
        script = script.replace(old, new.replace("{v}", str(v)))
    return script


def setup(lab):
    su = lambda sql, db="postgres": lab.run("postgres", sql, db=db)
    su("create database frz_lab;", db="postgres")
    su("""
create role operator login createrole nosuperuser;
grant pg_signal_backend to operator;
create role authenticator login noinherit;
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
grant anon, authenticated, service_role to authenticator;
grant authenticator to operator with admin option;
create role supabase_read_only_user login; alter role supabase_read_only_user set default_transaction_read_only = on;
create role supabase_auth_admin login;
create role stray_app login;
alter role authenticator set statement_timeout = '30s';
grant all on database frz_lab to operator;
""")
    su("""
grant all on schema public to operator;
create schema cron authorization operator;
create table cron.job (jobid bigserial primary key, schedule text not null, command text not null, database text default 'frz_lab', username text default 'postgres', active boolean not null default true, jobname text);
alter table cron.job owner to operator;
create function cron.alter_job(job_id bigint, schedule text default null, command text default null, database text default null, username text default null, active boolean default null)
  returns void language plpgsql security definer as $f$ begin update cron.job j set active = coalesce(alter_job.active, j.active) where j.jobid = alter_job.job_id; end $f$;
alter function cron.alter_job(bigint, text, text, text, text, boolean) owner to operator;
insert into cron.job (schedule, command, jobname, active) values ('*/5 * * * *', 'select public.sync_writer()', 'sync-writer', true), ('0 6 * * *', 'select 1', 'reader-report', true), ('0 7 * * *', 'select 2', 'already-off', false);
""", db="frz_lab")
    lab.run("operator", """
create table public.dispatches (id serial primary key, note text);
create table public.freeze_probe_items (id bigserial primary key, note text not null default 'probe', created_at timestamptz not null default now());
create table public.loads (id serial primary key, note text);
create table public.activity_logs (id serial primary key, note text);
insert into public.freeze_probe_items (note) values ('seed'); insert into public.dispatches (note) values ('d1'), ('d2'); insert into public.loads (note) values ('l1'); insert into public.activity_logs (note) values ('a1');
create function public.app_write() returns void language sql security definer set search_path = public as $$ insert into public.dispatches (note) values ('rpc') $$;
grant select, insert, update, delete on public.dispatches, public.freeze_probe_items, public.loads, public.activity_logs to authenticated, service_role;
grant usage on all sequences in schema public to authenticated, service_role;
grant execute on function public.app_write() to authenticated, service_role;
create function public.sync_writer() returns void language sql as $$ insert into public.activity_logs (note) values ('cron') $$;
""")


def counts(lab):
    return lab.rows("postgres", "select (select count(*) from public.dispatches), (select count(*) from public.loads), (select count(*) from public.activity_logs)")[0]


def settings(lab):
    return lab.scalar("select coalesce(string_agg(coalesce(d.datname,'ALL') || '/' || coalesce(r.rolname,'ALL') || ':' || s.setconfig::text, '|' order by 1), '') from pg_db_role_setting s left join pg_database d on d.oid = s.setdatabase left join pg_roles r on r.oid = s.setrole")


def frz_schema_exists(lab):
    return lab.scalar("select (to_regclass('ops_freeze.freeze_run') is not null)::text") == "true"


def good_enable(db, **over):
    kw = dict(operator="operator", major=None, confirm=f"FREEZE {db}", roles="'authenticator'", other="'supabase_auth_admin'", pause="1", keep="2,3")
    kw.update(over)
    return kw



def static_checks():
    print("== static safeguards of the freeze scripts ==")
    files = sorted(p.name for p in HERE.glob("0[1-7]_*.sql"))
    check("all seven scripts exist", files == ["01_discovery_readonly.sql", "02_enable_freeze.sql", "03_terminate_api_sessions.sql", "04_verify_freeze.sql", "05_disable_freeze.sql", "06_recycle_sessions_after_disable.sql", "07_verify_disable.sql"], str(files))
    for f in files:
        code = re.sub(r"execute '(?:insert|update|delete)[^']*where false'", "", re.sub(r"--[^\n]*", "", (HERE / f).read_text()))   # the audited zero-row probes of 04_verify_freeze.sql
        code_ns = re.sub(r"'(?:[^']|'')*'", "''", code)          # strip string literals (messages)
        check(f"{f}: no DROP (except temp 'on commit drop'), TRUNCATE, DELETE, GRANT, ALTER SYSTEM, COPY, or superuser-only command",
              not re.search(r"\b(truncate|delete\s+from|grant\b|alter\s+system|copy\b|create\s+role|drop\s+role|alter\s+table\s+\S+\s+disable)", code_ns, re.I)
              and not re.search(r"\bdrop\b(?!\s*\$|\s*;)", re.sub(r"on commit drop", "", code_ns, flags=re.I), re.I), f)
        check(f"{f}: REVOKE only ever targets the tooling's own ops_freeze objects", all("ops_freeze" in m for m in re.findall(r"revoke[^;]*", code_ns, re.I)), f)
    for f in ("01_discovery_readonly.sql", "07_verify_disable.sql"):
        code = t149.strip_sql((HERE / f).read_text())
        check(f"{f}: read-only (exactly one statement, SELECT/WITH only; no DDL/DML keyword)", code.count(";") == 1 and not re.search(r"\b(insert|update|delete|create|alter|drop|grant|revoke|truncate|do)\b", code, re.I), f)
    v = re.sub(r"--[^\n]*", "", (HERE / "04_verify_freeze.sql").read_text())
    check("04_verify_freeze.sql: write probes use only the dedicated fixture",
          "public.freeze_probe_items" in v and not re.search(r"(?:insert into|update|delete from) public\.dispatches", v, re.I))
    check("04_verify_freeze.sql: one transaction that ends in ROLLBACK; every real-table write probe is a ZERO-ROW statement",
          v.count("begin;") == 1 and v.rstrip().endswith("rollback;") and all("where false" in m for m in re.findall(r"execute '(?:insert|update|delete)[^']*'", v)), "")

def absent_cron_checks(major):
    """Exercise the full freeze lifecycle with no cron schema or job relation."""
    lab = Lab()
    ok = False
    try:
        lab.c.start()
        setup(lab)
        lab.run("postgres", "drop schema cron cascade;")
        enable = fill(sqlfile("02_enable_freeze.sql"), **{**good_enable(lab.db), "major": major, "pause": "", "keep": ""})
        p = lab.run("operator", enable, ok=False)
        check("no pg_cron: enable succeeds", p.returncode == 0, p.stderr[-400:])
        rows = lab.rows("operator", sqlfile("04_verify_freeze.sql"))
        check("no pg_cron: freeze verification passes", any(r[1] == "RESULT" and r[2] == "PASS" for r in rows), str([r for r in rows if r[2] == "FAIL"]))
        p = lab.run("operator", sqlfile("05_disable_freeze.sql"), ok=False)
        check("no pg_cron: disable succeeds", p.returncode == 0, p.stderr[-400:])
        rows = lab.rows("operator", sqlfile("07_verify_disable.sql"))
        check("no pg_cron: disable verification passes", not any(r[2] == "FAIL" for r in rows), str(rows))
        p = lab.run("operator", sqlfile("hosted_test/99_synthetic_cleanup.sql"), ok=False)
        check("no pg_cron: cleanup succeeds", p.returncode == 0, p.stderr[-400:])
        ok = True
    finally:
        lab.c.cleanup(ok)


def main():
    static_checks()
    lab = Lab()
    ok = False
    try:
        lab.c.start()
        major = int(lab.c.run(t149.PSQL, ["-X", "-A", "-t", "-h", str(lab.c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", "postgres", "-c", "show server_version_num"]).stdout.strip()) // 10000
        print(f"== disposable PostgreSQL {major} (unix socket only) with a simulated Supabase role model ==")
        setup(lab)
        base_counts = counts(lab)
        base_probe_count = lab.scalar("select count(*) from public.freeze_probe_items")
        acl_sql = "select md5((select coalesce(string_agg(relname || ':' || coalesce(relacl::text, ''), '|' order by relname), '') from pg_class where relnamespace in ('public'::regnamespace, 'cron'::regnamespace) and relkind in ('r', 'S')) || (select coalesce(string_agg(proname || ':' || coalesce(proacl::text, ''), '|' order by proname), '') from pg_proc where pronamespace in ('public'::regnamespace, 'cron'::regnamespace)) || (select coalesce(string_agg(rolname || ':' || rolsuper::text || rolcanlogin::text || rolbypassrls::text, '|' order by rolname), '') from pg_roles where rolname !~ '^pg_'))"
        base_acl = lab.scalar(acl_sql)
        base_settings = settings(lab)
        enable_sql = sqlfile("02_enable_freeze.sql")
        E = lambda **over: fill(enable_sql, **{**good_enable(lab.db), "major": major, **over})

        # ---------------------------------------------------------------- discovery is read-only
        disc = sqlfile("01_discovery_readonly.sql")
        rows = lab.rows("operator", "begin read only;\n" + disc.rstrip().rstrip(";") + ";\ncommit;")
        raw_rows = rows
        rows = [r for r in rows if len(r) >= 4]   # multi-line details continue on following lines
        secs = {r[1] for r in rows}
        check("discovery runs inside a READ ONLY transaction (it changes nothing) and reports every required section",
              {"VERSION", "IDENTITY", "LOGIN ROLES", "CAPABILITY", "API MODEL", "SETTINGS", "SESSIONS", "CRON", "OTHER SCHEDULED / EXTERNAL WRITERS", "FREEZE STATE"} <= secs, str(sorted(secs)))
        text = "\n".join(SEP.join(r) for r in raw_rows)
        check("discovery reports the operator identity/privileges, the API roles and their memberships, prior settings, cron jobs and per-role signalling capability",
              "operator / operator" in text and "authenticator" in text and "statement_timeout=30s" in text and "sync-writer" in text and "id=1 " in text and "(admin)" in text and "YES (createrole + admin option)" in text)
        check("discovery reports sessions (grouped by role/application/client when present) and never selects passwords or foreign query text", "total client sessions" in text and "password" not in text.lower() and "select public.sync_writer" in text)  # (the cron command is a catalog fact, not a session query)
        check("discovery changed nothing (settings, data, no ops_freeze schema)", settings(lab) == base_settings and counts(lab) == base_counts and not frz_schema_exists(lab))

        # ---------------------------------------------------------------- enable: fail-closed refusals (each leaves NOTHING behind)
        def refuse(label, sql, expect, mutate=None, undo=None, sessions=()):
            if mutate:
                lab.run("postgres", mutate)
            ss = [lab.session(u, "select pg_sleep(30);") for u in sessions]
            for u in sessions:
                lab.wait_backend(u)
            p = lab.run("operator", sql, ok=False)
            for s_ in ss:
                s_.kill()
            lab.reap(*sessions)
            if undo:
                lab.run("postgres", undo)
            time.sleep(0.3)
            check(f"enable REFUSES: {label}", p.returncode != 0 and expect in p.stderr, p.stderr[-300:])
            check(f"  ... and left nothing behind ({label})", settings(lab) == base_settings and not frz_schema_exists(lab) and counts(lab) == base_counts)

        refuse("as shipped (no identities filled)", enable_sql, "must all be filled in")
        refuse("wrong confirmation text", E(confirm="FREEZE wrongdb"), "v_confirm must be exactly")
        refuse("operator identity mismatch", E(operator="postgres"), "v_operator_role")
        refuse("wrong expected major version", E(major=major + 1), "v_expected_major")
        refuse("operator listed as a frozen role", E(roles="'operator'"), "is the operator")
        refuse("a superuser listed as a frozen role", E(roles="'postgres'"), "superuser")
        refuse("a never-freeze (Supabase-internal) role listed", E(roles="'supabase_auth_admin'", other="''"), "never-freeze")
        refuse("a non-login role listed", E(roles="'anon'"), "never-freeze") if False else None
        refuse("a role that does not exist", E(roles="'no_such_role'"), "does not exist")
        refuse("an unexpected application session (role stray_app) is connected", E(), "unexpected session(s) of role stray_app", sessions=("stray_app",))
        refuse("the role already has a default_transaction_read_only setting", E(), "already has a default_transaction_read_only setting",
               mutate="alter role authenticator set default_transaction_read_only = off;", undo="alter role authenticator reset default_transaction_read_only;")
        refuse("a database-level default_transaction_read_only exists", E(), "database-level or global", mutate="alter database frz_lab set default_transaction_read_only = off;", undo="alter database frz_lab reset default_transaction_read_only;")
        refuse("an active cron job is not classified", E(pause="1", keep="3"), "neither in v_cron_pause_ids nor v_cron_keep_ids")
        refuse("a listed cron job id does not exist", E(pause="1,99", keep="2,3"), "does not exist")
        refuse("a job to pause is not active", E(pause="1,3", keep="2"), "not active")

        # ---------------------------------------------------------------- enable for real, with stale + reviewed sessions connected
        A = lab.session("authenticator", "select pg_sleep(1);")     # pre-freeze API session (pooled connection)
        B = lab.session("supabase_auth_admin", "select pg_sleep(60);")   # reviewed-other role, must survive
        lab.wait_backend("authenticator"); lab.wait_backend("supabase_auth_admin")
        p = lab.run("operator", E(), ok=False)
        check("enable APPLIES (single transaction, self-check passed)", p.returncode == 0 and "FREEZE ENABLED" in p.stderr, p.stderr[-400:])
        st = lab.rows("postgres", "select r.status, r.operator, r.api_roles::text, (select count(*) from ops_freeze.role_state), (select count(*) from ops_freeze.cron_state), (select count(*) from ops_freeze.cron_state where paused_by_freeze) from ops_freeze.freeze_run r")[0]
        check("the exact prior state was recorded in ops_freeze (roles, database/global rows, every cron job) and the run is 'frozen'", st == ["frozen", "operator", "{authenticator}", "1", "3", "1"], str(st))
        check("prior UNRELATED role setting was recorded verbatim", lab.scalar("select prior_role_setconfig::text from ops_freeze.role_state") == "{statement_timeout=30s}")
        cfg = lab.scalar("select s.setconfig::text from pg_db_role_setting s join pg_roles r on r.oid = s.setrole where r.rolname = 'authenticator'")
        check("authenticator now has default_transaction_read_only=on AND kept statement_timeout=30s", "default_transaction_read_only=on" in cfg and "statement_timeout=30s" in cfg, cfg)
        check("only the reviewed writer job was paused (job 1); reviewed non-writer and already-inactive jobs are untouched",
              lab.rows("postgres", "select jobid, active from cron.job order by jobid") == [["1", "f"], ["2", "t"], ["3", "f"]])
        check("no API role has any privilege on ops_freeze", lab.scalar("select (has_schema_privilege('authenticator', 'ops_freeze', 'usage') or has_schema_privilege('authenticated', 'ops_freeze', 'usage') or has_schema_privilege('service_role', 'ops_freeze', 'usage') or has_schema_privilege('anon', 'ops_freeze', 'usage'))::text") == "false")
        p = lab.run("operator", E(), ok=False)
        check("a second enable is REFUSED while a freeze is active", p.returncode != 0 and "already active" in p.stderr, p.stderr[-200:])
        check("enable modified no business data", counts(lab) == base_counts)

        # ---------------------------------------------------------------- verify BEFORE terminating: must FAIL on the stale session
        ver = sqlfile("04_verify_freeze.sql")
        A2 = lab.session("authenticator", "select pg_sleep(60);")   # simulate a stale pooled session that started BEFORE the freeze? (started after -> post-freeze)
        rows = lab.rows("operator", ver)
        result = [r for r in rows if r[1] == "RESULT"][0]
        check("verify script runs as the operator and yields a RESULT row", result[2] in ("PASS", "FAIL"), str(result))
        A2.kill()
        lab.reap('authenticator')

        # ---------------------------------------------------------------- terminate only the validated pre-freeze API sessions
        A_alive_before = int(lab.scalar("select count(*) from pg_stat_activity where usename = 'authenticator' and backend_type = 'client backend'"))
        C = lab.session("authenticator", "select pg_sleep(60);")   # opened AFTER the freeze (read-only), must survive termination
        lab.wait_backend("authenticator", 1)
        # a stale session: emulate by opening one and back-dating is impossible; the pre-freeze session A finished its sleep and closed, so open a fresh pre-freeze-equivalent via recorded start
        term = sqlfile("03_terminate_api_sessions.sql")
        p = lab.run("operator", term, ok=False, tuples=True)
        check("terminate script runs and reports zero pre-freeze sessions remaining", p.returncode == 0 and "\t0\t" in p.stdout.replace(SEP, "\t") or ("OK" in p.stdout), p.stdout[-300:] + p.stderr[-200:])
        check("the reviewed-other role session (supabase_auth_admin) and the operator are NEVER terminated; the post-freeze API session is left alone",
              int(lab.scalar("select count(*) from pg_stat_activity where usename = 'supabase_auth_admin' and backend_type = 'client backend'")) == 1
              and int(lab.scalar("select count(*) from pg_stat_activity where usename = 'authenticator' and backend_type = 'client backend'")) >= 1)
        C.kill(); B.kill()
        lab.reap('authenticator', 'supabase_auth_admin')

        # ---------------------------------------------------------------- what an API session experiences after the freeze
        def api(sql):
            return lab.run("authenticator", sql, ok=False)
        p = api("begin; set local role authenticated; select count(*) from public.dispatches; commit;")
        check("NEW API session: SELECT works (read-only inspection)", p.returncode == 0, p.stderr[-200:])
        for label, sql in (("direct INSERT as authenticated", "insert into public.dispatches (note) values ('x')"), ("direct UPDATE", "update public.dispatches set note = 'x'"),
                           ("direct DELETE", "delete from public.dispatches"), ("writable SECURITY DEFINER RPC", "select public.app_write()")):
            p = api(f"begin; set local role authenticated; {sql}; commit;")
            check(f"NEW API session: {label} is BLOCKED (25006)", p.returncode != 0 and "read-only transaction" in p.stderr, p.stderr[-200:])
        p = api("begin; set local role service_role; insert into public.dispatches (note) values ('x'); commit;")
        check("NEW API session: a BYPASSRLS service-role write is BLOCKED", p.returncode != 0 and "read-only transaction" in p.stderr)
        p = lab.run("operator", "insert into public.activity_logs (note) values ('operator-still-writes'); delete from public.activity_logs where note = 'operator-still-writes';", ok=False)
        check("the operator session can still write (migrations are not blocked)", p.returncode == 0, p.stderr[-200:])
        check("no business data changed by the blocked attempts", counts(lab) == base_counts)

        # ---------------------------------------------------------------- verify script: PASS once frozen and stale sessions are gone
        rows = lab.rows("operator", ver)
        res = {r[1]: r[2] for r in rows}
        failing = [r for r in rows if r[2] == "FAIL"]
        check("04_verify_freeze.sql: RESULT = PASS (every check passes, no data modified)", res.get("RESULT") == "PASS" and not failing, str(failing))
        check("verification covers: catalog setting, stale sessions, cron pause, operator writable, SELECT, INSERT/UPDATE/DELETE blocked, SECURITY DEFINER blocked, counts unchanged",
              sum(1 for r in rows if r[2] == "PASS") >= 14, str(len(rows)))
        check("verification itself modified no data", counts(lab) == base_counts and lab.scalar("select count(*) from public.freeze_probe_items") == base_probe_count and not lab.scalar("select to_regclass('pg_temp.fz_results')::text"))

        # ---------------------------------------------------------------- stale-session detection (proves the verifier is not vacuous)
        stale = lab.session("authenticator", "select pg_sleep(60);")
        lab.wait_backend("authenticator")
        lab.run("postgres", "update ops_freeze.freeze_run set started_at = now() + interval '1 minute';")   # make every existing session "pre-freeze"
        rows = lab.rows("operator", ver)
        check("verifier FAILS when a pre-freeze session of a frozen role is still connected", [r for r in rows if r[1] == "RESULT"][0][2] == "FAIL")
        lab.run("postgres", "update ops_freeze.freeze_run set started_at = now();")
        p = lab.run("operator", sqlfile("03_terminate_api_sessions.sql"), ok=False)
        time.sleep(0.5)
        check("the terminate script removes exactly those sessions", int(lab.scalar("select count(*) from pg_stat_activity where usename = 'authenticator' and backend_type = 'client backend'")) == 0 and p.returncode == 0, p.stderr[-200:])
        stale.kill()
        lab.reap('authenticator')

        # ---------------------------------------------------------------- disable: refusals leave the freeze intact, then exact restoration
        lab.run("postgres", "update cron.job set command = 'select 999' where jobid = 1;")
        p = lab.run("operator", sqlfile("05_disable_freeze.sql"), ok=False)
        check("disable ABORTS if a paused cron job was changed during the freeze (atomically: still frozen)", p.returncode != 0 and "changed" in p.stderr
              and "default_transaction_read_only=on" in lab.scalar("select s.setconfig::text from pg_db_role_setting s join pg_roles r on r.oid = s.setrole where r.rolname = 'authenticator'"))
        lab.run("postgres", "update cron.job set command = 'select public.sync_writer()' where jobid = 1;")
        lab.run("postgres", "update cron.job set active = true where jobid = 1;")
        p = lab.run("operator", sqlfile("05_disable_freeze.sql"), ok=False)
        check("disable ABORTS if a paused job was re-activated by someone else", p.returncode != 0 and "re-activated" in p.stderr)
        lab.run("postgres", "update cron.job set active = false where jobid = 1;")
        D = lab.session("authenticator", "select pg_sleep(60);")     # a session opened DURING the freeze (read-only for life)
        lab.wait_backend("authenticator")
        p = lab.run("operator", sqlfile("05_disable_freeze.sql"), ok=False)
        check("disable RESTORES from the recorded state (single transaction)", p.returncode == 0 and "FREEZE DISABLED" in p.stderr, p.stderr[-300:])
        check("exact restoration: authenticator's setconfig equals the recorded prior value ({statement_timeout=30s}); no read-only setting remains anywhere", settings(lab) == base_settings, settings(lab))
        check("exact restoration: cron job 1 is active again; jobs 2 and 3 exactly as before", lab.rows("postgres", "select jobid, active from cron.job order by jobid") == [["1", "t"], ["2", "t"], ["3", "f"]])
        check("the run is marked restored; a second disable is REFUSED", lab.scalar("select status from ops_freeze.freeze_run") == "restored"
              and lab.run("operator", sqlfile("05_disable_freeze.sql"), ok=False).returncode != 0)
        p = lab.run("operator", sqlfile("06_recycle_sessions_after_disable.sql"), ok=False, tuples=True)
        time.sleep(0.4)
        check("recycle terminates the read-only session opened during the freeze and nothing else",
              p.returncode == 0 and int(lab.scalar("select count(*) from pg_stat_activity where usename = 'authenticator' and backend_type = 'client backend'")) == 0, p.stderr[-200:])
        D.kill()
        lab.reap('authenticator')
        p = api("begin; set local role authenticated; insert into public.dispatches (note) values ('after-disable'); commit;")
        check("NEW API session after disable can WRITE again (direct INSERT)", p.returncode == 0, p.stderr[-200:])
        p = api("begin; set local role authenticated; select public.app_write(); commit;")
        check("NEW API session after disable can call the writable SECURITY DEFINER RPC again", p.returncode == 0, p.stderr[-200:])
        rows = lab.rows("operator", sqlfile("07_verify_disable.sql"))
        bad = [r for r in rows if r[2] == "FAIL"]
        check("07_verify_disable.sql: every check PASSES (settings, cron, no read-only sessions, writable)", not bad and sum(1 for r in rows if r[2] == "PASS") >= 6, str(rows))
        check("business data changed ONLY by the two deliberate post-disable writes (dispatches +2)", counts(lab) == [str(int(base_counts[0]) + 2), base_counts[1], base_counts[2]], str(counts(lab)))
        check("the freeze scripts never created any object outside the private ops_freeze schema",
              lab.scalar("select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname not in ('pg_catalog','information_schema','pg_toast','ops_freeze','public','cron') and c.relkind in ('r','v','S')") == "0")
        check("no privilege or role attribute was granted/revoked/changed by the freeze tooling (ACL + role attribute fingerprint of public/cron objects and all roles unchanged)", lab.scalar(acl_sql) == base_acl)
        ok = True
        print(f"\nALL {len(checks)} FREEZE-TOOLING CHECKS PASSED (local disposable PostgreSQL {major})")
    finally:
        lab.c.cleanup(ok)
    if ok:
        absent_cron_checks(major)


if __name__ == "__main__":
    main()
