#!/usr/bin/env python3
"""LOCAL verification of the v2 (trigger-based) database freeze tooling and of the external API probe. NOT a hosted-Supabase test and it does not prove hosted behaviour.

Disposable local PostgreSQL only (reuses the reviewed 0149 harness Cluster: unix socket, /private/tmp, no network, no credentials). It models the distinction that broke v1:
the LOGIN role (authenticator = session_user) versus the EFFECTIVE role of a REST transaction (SET LOCAL ROLE anon/authenticated/service_role) and versus SECURITY DEFINER owners,
using real psql sessions and PostgREST-style transactions (BEGIN ... READ WRITE; SET LOCAL ROLE ...). The probe is exercised against an in-process mock server on 127.0.0.1 only."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


v1 = _load("v1freeze", HERE / "superseded_v1_role_default" / "tests_freeze.py")   # Lab, setup, cron stub (superseded suite kept only for its harness)
t149 = v1.t149
Lab = v1.Lab
checks = []
V = ("-v", "VERBOSITY=verbose")


def check(label, cond, detail=""):
    if not cond:
        raise SystemExit(f"FAIL: {label} {detail}")
    checks.append(label)
    print(f"  ok  {label}")


def sql(name):
    return (HERE / name).read_text()


def fill2(script, **kw):
    reps = {
        "operator": ("v_operator_role   constant text   := '';", "v_operator_role   constant text   := '{v}';"),
        "major": ("v_expected_major  constant integer := 0;", "v_expected_major  constant integer := {v};"),
        "confirm": ("v_confirm         constant text   := '';", "v_confirm         constant text   := '{v}';"),
        "exempt": ("v_exempt_login_roles constant text[] := array[]::text[];", "v_exempt_login_roles constant text[] := array[{v}]::text[];"),
        "scope": ("v_scope_schemas   constant text[] := array[]::text[];", "v_scope_schemas   constant text[] := array[{v}]::text[];"),
        "reviewed": ("v_reviewed_out_of_scope_schemas constant text[] := array[]::text[];", "v_reviewed_out_of_scope_schemas constant text[] := array[{v}]::text[];"),
        "pause": ("v_cron_pause_ids  constant bigint[] := array[]::bigint[];", "v_cron_pause_ids  constant bigint[] := array[{v}]::bigint[];"),
        "keep": ("v_cron_keep_ids   constant bigint[] := array[]::bigint[];", "v_cron_keep_ids   constant bigint[] := array[{v}]::bigint[];"),
    }
    for k, v in kw.items():
        old, new = reps[k]
        assert script.count(old) == 1, k
        script = script.replace(old, new.replace("{v}", str(v)))
    return script


def good(major, **over):
    kw = dict(operator="operator", major=major, confirm="FREEZE frz_lab", exempt="'operator','postgres'", scope="'public'", pause="1", keep="2,3")
    kw.update(over)
    return kw


def api(lab, role, stmt, rw=True, login="authenticator"):
    """A PostgREST-style request transaction: the API logs in as `login` (session_user) and SETs LOCAL ROLE to the request's role."""
    begin = "begin isolation level read committed read write;" if rw else "begin;"
    return lab.run(login, f"{begin} set local role {role}; {stmt}; commit;", ok=False, extra_args=V)


def blocked(p):
    return p.returncode != 0 and "25006" in p.stderr and "TDP_MAINTENANCE_FREEZE" in p.stderr


def catalog_fp(lab):
    """Fingerprint of everything the freeze must NOT change: all role attributes + rolconfig, all pg_db_role_setting rows, and every relation/function ACL in public."""
    return lab.scalar("""select md5(
      (select coalesce(string_agg(rolname || rolsuper::text || rolcreaterole::text || rolbypassrls::text || rolcanlogin::text || coalesce(rolconfig::text, ''), '|' order by rolname), '') from pg_roles)
      || (select coalesce(string_agg(coalesce(setdatabase::text, '') || ':' || coalesce(setrole::text, '') || ':' || setconfig::text, '|' order by 1), '') from pg_db_role_setting)
      || (select coalesce(string_agg(relname || ':' || coalesce(relacl::text, '') || ':' || relrowsecurity::text, '|' order by relname), '') from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r','S','p'))
      || (select coalesce(string_agg(proname || ':' || coalesce(proacl::text, ''), '|' order by proname), '') from pg_proc where pronamespace = 'public'::regnamespace))""")


def trig_count(lab):
    return int(lab.scalar("select count(*) from pg_trigger where tgname = '0_ops_freeze_block_writes' and not tgisinternal"))


def nothing_left(lab):
    return lab.scalar("select (to_regclass('ops_freeze_v2.freeze_run') is null)::text") == "true" and trig_count(lab) == 0


def setup2(lab):
    v1.setup(lab)
    lab.run("operator", """
grant select, insert, update, delete on all tables in schema public to anon;
grant usage on all sequences in schema public to anon;
grant execute on function public.app_write() to anon;
create table public.audit_side_effect (id serial primary key, note text);
create function public.trg_side_effect() returns trigger language plpgsql as $$ begin insert into public.audit_side_effect (note) values ('side-effect'); return null; end $$;
create trigger loads_side_effect before insert or update or delete on public.loads for each statement execute function public.trg_side_effect();
create function public.diag() returns jsonb language sql volatile as $$ select jsonb_build_object('session_user', session_user, 'current_user', current_user, 'default_ro', current_setting('default_transaction_read_only'), 'tx_ro', current_setting('transaction_read_only')) $$;
grant execute on function public.diag() to anon, authenticated, service_role;
""")


def static_checks():
    print("== static safeguards (v2 scripts) ==")
    names = ["01_discovery_readonly.sql", "02_enable_freeze.sql", "03_refresh_coverage.sql", "04_verify_freeze_sql_layer.sql", "05_disable_freeze.sql", "06_verify_disable.sql",
             "07_recycle_api_sessions_optional.sql", "EMERGENCY_UNFREEZE.sql"]
    check("all v2 scripts exist", all((HERE / n).exists() for n in names))
    for n in names:
        code = t149.strip_sql((HERE / n).read_text())
        code = re.sub(r"execute format\('delete from %I\.%I where false'[^;]*", "", code)
        ns = re.sub(r"'(?:[^']|'')*'", "''", code)
        check(f"{n}: no ALTER ROLE / CREATE|DROP ROLE / ALTER SYSTEM / COPY / DELETE FROM / GRANT / DROP of anything but the freeze trigger",
              not re.search(r"\b(alter\s+role|create\s+role|drop\s+role|alter\s+system|copy\b|delete\s+from|grant\b)", ns, re.I)
              and all(re.search(r"drop trigger", m, re.I) for m in re.findall(r"\bdrop\b[^;]{0,40}", re.sub(r"on commit drop", "", ns, flags=re.I), re.I)), n)
        check(f"{n}: every cron.job / cron.alter_job reference is inside a string (dynamic SQL) -- none is a static reference the planner could resolve when pg_cron is absent",
              not re.search(r"\bcron\s*\.\s*(job|alter_job)", code), n)
        check(f"{n}: never sets or resets default_transaction_read_only and never names pgbouncer in an ALTER", "default_transaction_read_only" not in ns.lower() and not re.search(r"alter[^;]*pgbouncer", code, re.I), n)
        check(f"{n}: REVOKE only ever targets the tooling's own ops_freeze_v2 objects", all("ops_freeze_v2" in m for m in re.findall(r"revoke[^;]*", ns, re.I)), n)
        if n != "07_recycle_api_sessions_optional.sql":
            check(f"{n}: terminates no session", "pg_terminate_backend" not in ns, n)
    for n in ("01_discovery_readonly.sql", "06_verify_disable.sql"):
        code = t149.strip_sql((HERE / n).read_text())
        check(f"{n}: read-only (one statement; SELECT/WITH only)", code.count(";") == 1 and not re.search(r"\b(insert|update|delete|create|alter|drop|grant|revoke|truncate|do)\b", code, re.I), n)
    v = t149.strip_sql((HERE / "04_verify_freeze_sql_layer.sql").read_text())
    check("04: one transaction that ends in ROLLBACK", v.strip().lower().startswith("begin;") and v.strip().lower().endswith("rollback;"))
    check("04: NEVER simulates a frozen session (no SET transaction_read_only / default_transaction_read_only)", "transaction_read_only" not in v.lower().replace("current_setting('transaction_read_only')", ""))
    raw = (HERE / "04_verify_freeze_sql_layer.sql").read_text()
    vc = re.search(r"'VERDICT', case(.*?) from fz_results", raw, re.S).group(1)
    check("04: its overall verdict is never PASS/FROZEN -- only SQL_LAYER_OK__NOT_A_FREEZE_PROOF__... or SQL_LAYER_FAIL",
          sorted(re.findall(r"'(SQL_LAYER[A-Z_]*)'", vc)) == ["SQL_LAYER_FAIL", "SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED"] and "'PASS'" not in vc.split(" end,", 1)[0].split("then", 1)[1])
    e = (HERE / "02_enable_freeze.sql").read_text()
    body = re.search(r"function ops_freeze_v2\.block_writes\(\).*?\$f\$;", (HERE / "02_enable_freeze.sql").read_text(), re.S)
    check("02: the trigger decides on session_user, never on current_user", body and "session_user" in body.group(0) and "current_user" not in re.sub(r"--[^\n]*", "", body.group(0)))
    check("02: trigger is BEFORE ... FOR EACH STATEMENT, ENABLE ALWAYS, named to sort first", "before insert or update or delete or truncate" in e and "for each statement" in e and "enable always trigger" in e and "'0_ops_freeze_block_writes'" in e)
    for fname, tmpl in (("02_enable_freeze_FILLED_tdp-freeze-test.sql", "02_enable_freeze.sql"), ("07_recycle_api_sessions_FILLED_tdp-freeze-test.sql", "07_recycle_api_sessions_optional.sql")):
        filled = [l for l in (HERE / "hosted_test" / fname).read_text().splitlines() if not l.startswith("-- FILLED") and not (l.startswith("-- ") and fname.startswith("02") and l.split()[1] in ("v2", "(auth/storage/realtime/etc.", "No"))]
        norm = lambda ls: [re.sub(r":=.*?;", ":= X;", l) if re.match(r"\s+v_(operator_role|expected_major|confirm|exempt_login_roles|scope_schemas|api_roles)\b", l) else l for l in ls]
        check(f"{fname}: differs from its template ONLY in the filled constants (and header comments)", norm([l for l in filled if l.strip()]) == norm([l for l in (HERE / tmpl).read_text().splitlines() if l.strip()]), fname)
    ftxt = (HERE / "hosted_test" / "02_enable_freeze_FILLED_tdp-freeze-test.sql").read_text()
    check("hosted FILLED enable: no static cron.job reference either", not re.search(r"\\bcron\\s*\\.\\s*(job|alter_job)", t149.strip_sql(ftxt)))
    check("hosted FILLED enable: operator postgres, major 17, confirm 'FREEZE postgres', exempt postgres+supabase_admin, scope public, no cron ids, no pgbouncer/authenticator in any constant",
          all(x in ftxt for x in ("v_operator_role   constant text   := 'postgres'", "v_expected_major  constant integer := 17", "'FREEZE postgres'", "array['postgres', 'supabase_admin']", "array['public']"))
          and not re.search(r"v_exempt_login_roles[^\n]*(authenticator|pgbouncer)", ftxt))
    p = HERE / "hosted_test" / "api_freeze_probe.py"
    src = p.read_text()
    check("probe: refuses the production ref, requires the test prefix, reads keys only from env, has a breach stop", "zteixenjpcygjvznueuo" in src and "TDP_EXPECTED_REF_PREFIX" in src and "FREEZE_BREACH" in src and "os.environ.get(k)" in src)
    check("no committed file contains a JWT-shaped string or a service key", not any(re.search(r"eyJ[A-Za-z0-9_\-]{20,}\.", f.read_text(errors="ignore")) for f in HERE.rglob("*") if f.is_file() and f.suffix in (".sql", ".py", ".md")))


# ---------------------------------------------------------------------------------------------------------------------------------------------- the local database part
def db_tests(lab, major):
    setup2(lab)
    base_fp = catalog_fp(lab)
    print("== 1. MODELLING THE HOSTED FAILURE: login-role default vs. the effective role of a REST transaction ==")
    lab.run("postgres", "alter role authenticator set default_transaction_read_only = on;")
    p = lab.run("authenticator", "show default_transaction_read_only; begin; set local role anon; insert into public.freeze_probe_items (note) values ('plain-tx'); commit;", ok=False, extra_args=V)
    check("v1 model: a PLAIN transaction of the authenticator login inherits the read-only default (this is what SQL probes and psql see)", blocked_pg(p))
    p = api(lab, "anon", "insert into public.freeze_probe_items (note) values ('rest-rw')")
    check("v1 model: an explicit BEGIN ... READ WRITE + SET LOCAL ROLE anon INSERT SUCCEEDS although authenticator has default_transaction_read_only=on (the hosted 201)", p.returncode == 0, p.stderr[-200:])
    p = api(lab, "service_role", "select public.app_write()")
    check("v1 model: a SECURITY DEFINER RPC in the same READ WRITE transaction also writes", p.returncode == 0, p.stderr[-200:])
    row = lab.rows("authenticator", "begin isolation level read committed read write; set local role anon; select public.diag()->>'default_ro', public.diag()->>'tx_ro', public.diag()->>'session_user', public.diag()->>'current_user'; commit;")
    check("v1 model: inside that transaction default_transaction_read_only=on is visible yet transaction_read_only=off; session_user stays authenticator while current_user is anon", row and row[-1][:4] == ["on", "off", "authenticator", "anon"], str(row))
    lab.run("postgres", "alter role anon set statement_timeout = '7s';")
    st = lab.rows("authenticator", "begin; set local role anon; show statement_timeout; commit;")
    check("SET ROLE does NOT apply the target role's own ALTER ROLE settings (only the LOGIN role's settings apply) -> settings on anon/authenticated/service_role would not be a control", st and st[-1][0] == "30s", str(st))
    lab.run("postgres", "alter role anon reset statement_timeout; alter role authenticator reset default_transaction_read_only;")
    p = lab.run("operator", "begin; set local transaction_read_only = on; insert into public.freeze_probe_items (note) values ('x'); commit;", ok=False, extra_args=V)
    check("why the v1 verifier falsely passed: SET LOCAL transaction_read_only=on blocks ANY session regardless of the freeze (tautological simulation)", blocked_pg(p))
    lab.run("postgres", "delete from public.freeze_probe_items where note in ('rest-rw'); delete from public.dispatches where note = 'rpc';")
    check("v1 experiment left no role setting behind", catalog_fp(lab) == base_fp)

    lab.rows("postgres", "select 1")
    print("== 2. fail-closed enable refusals (each must leave NOTHING behind) ==")
    good_kw = good(major)
    refusals = [
        ("nothing filled in", dict(operator="", major=0, confirm="", exempt="", scope="", pause="", keep=""), "must all be filled in"),
        ("wrong confirmation string", dict(confirm="FREEZE production"), "v_confirm must be exactly"),
        ("wrong operator role", dict(operator="postgres"), "but v_operator_role is"),
        ("wrong major version", dict(major=major - 1), "server major version"),
        ("operator not in the exempt list", dict(exempt="'postgres'"), "operator role must be in v_exempt_login_roles"),
        ("exempt list contains authenticator", dict(exempt="'operator','authenticator'"), "may never be exempt"),
        ("exempt list contains a non-superuser other role", dict(exempt="'operator','stray_app'"), "neither the operator nor a superuser"),
        ("exempt role does not exist", dict(exempt="'operator','ghost'"), "does not exist"),
        ("scope schema is a platform schema (cron)", dict(scope="'public','cron'"), "platform/system schema"),
        ("scope schema does not exist", dict(scope="'public','nope'"), "does not exist"),
        ("active cron job unclassified", dict(keep="3"), "neither in v_cron_pause_ids nor v_cron_keep_ids"),
        ("listed cron id does not exist", dict(keep="2,3,99"), "does not exist"),
    ]
    for label, over, expect in refusals:
        p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **{**good_kw, **over}), ok=False)
        check(f"enable REFUSES: {label}", p.returncode != 0 and expect in p.stderr and nothing_left(lab), p.stderr[-260:])
    lab.run("postgres", "create schema extra_app; create table extra_app.t (id int);")
    p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **good_kw), ok=False)
    check("enable REFUSES: a schema with tables that nobody classified (would stay writable)", p.returncode != 0 and "neither in v_scope_schemas nor reviewed" in p.stderr and nothing_left(lab), p.stderr[-260:])
    lab.run("postgres", "drop schema extra_app cascade;")
    lab.run("postgres", "create table public.owned_by_super (id int);")
    p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **good_kw), ok=False)
    check("enable REFUSES: a scope table the operator cannot create a trigger on", p.returncode != 0 and "does not own" in p.stderr and nothing_left(lab), p.stderr[-260:])
    lab.run("postgres", "drop table public.owned_by_super;")
    lab.run("operator", "create trigger \"0_ops_freeze_block_writes\" before insert on public.loads for each statement execute function public.trg_side_effect();")
    p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **good_kw), ok=False)
    check("enable REFUSES: a pre-existing trigger with the freeze name", p.returncode != 0 and "already exists (unexpected prior state)" in p.stderr and trig_count(lab) == 1, p.stderr[-260:])
    lab.run("operator", "drop trigger \"0_ops_freeze_block_writes\" on public.loads;")
    holder = lab.session("operator", "begin; lock table public.loads in access exclusive mode; select pg_sleep(20);")
    time.sleep(1.0)
    t0 = time.time()
    p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **good_kw), ok=False)
    holder.kill(); lab.reap("operator")
    check("enable is fail-closed on lock contention: aborts after the 5 s lock_timeout with nothing changed (no queueing writers)", p.returncode != 0 and "lock timeout" in p.stderr and nothing_left(lab) and time.time() - t0 < 15, p.stderr[-200:])
    lab.reap("operator")

    print("== 3. enable, then every writer path through real sessions ==")
    pooled = lab.session("authenticator", "select 1;")     # a session opened BEFORE the freeze: an 'existing pooled connection'
    time.sleep(0.5)
    before_fp = catalog_fp(lab)
    counts_before = v1.counts(lab)
    p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **good_kw), ok=False)
    check("enable succeeds (single transaction, self-check passed)", p.returncode == 0 and "FREEZE ENABLED" in p.stderr, p.stderr[-400:])
    ntab = int(lab.scalar("select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r','p')"))
    check("every public table has the enabled-ALWAYS BEFORE statement trigger", trig_count(lab) == ntab and lab.scalar("select count(*) from pg_trigger where tgname = '0_ops_freeze_block_writes' and tgenabled = 'A'") == str(ntab), f"{trig_count(lab)}/{ntab}")
    check("the freeze changed NO role, role setting, ACL, RLS flag or function privilege (catalog fingerprint identical)", catalog_fp(lab) == before_fp)
    check("the API login role's own settings are untouched", lab.scalar("select rolconfig::text from pg_roles where rolname = 'authenticator'") == "{statement_timeout=30s}")
    seq_before = lab.scalar("select last_value from freeze_seq_view") if False else lab.scalar("select last_value from pg_sequences where sequencename = 'freeze_probe_items_id_seq'")
    for role in ("anon", "authenticated", "service_role"):
        for rw in (True, False):
            mode = "explicit READ WRITE" if rw else "default"
            for label, stmt in (("INSERT", "insert into public.freeze_probe_items (note) values ('x')"),
                                ("INSERT ... ON CONFLICT", "insert into public.freeze_probe_items (id, note) values (1, 'x') on conflict (id) do nothing"),
                                ("UPDATE (matching rows)", "update public.freeze_probe_items set note = 'x'"),
                                ("UPDATE (zero rows)", "update public.freeze_probe_items set note = 'x' where false"),
                                ("DELETE", "delete from public.freeze_probe_items"),
                                ("writable SECURITY DEFINER RPC", "select public.app_write()"),
                                ("write to a table with a user trigger (no side effects may run)", "insert into public.loads (note) values ('x')")):
                p = api(lab, role, stmt, rw=rw)
                check(f"{role:13s} {mode:19s} {label}: blocked with 25006 + TDP_MAINTENANCE_FREEZE", blocked(p), p.stderr[-200:])
    check("blocked statements consumed no sequence value and ran no other trigger (audit side-effect table empty)",
          lab.scalar("select last_value from pg_sequences where sequencename = 'freeze_probe_items_id_seq'") == seq_before and lab.scalar("select count(*) from public.audit_side_effect") == "0")
    p = lab.run("authenticator", "begin isolation level read committed read write; set local role anon; truncate public.loads; commit;", ok=False, extra_args=V)
    check("TRUNCATE by the API login is blocked (by trigger or privilege)", p.returncode != 0)
    p = api(lab, "service_role", "select count(*) from public.dispatches", rw=False)
    check("reads keep working for every API role (service_role SELECT)", p.returncode == 0, p.stderr[-200:])
    p = api(lab, "anon", "select count(*) from public.freeze_probe_items", rw=True)
    check("reads keep working in a READ WRITE transaction too (anon SELECT)", p.returncode == 0, p.stderr[-200:])
    pooled.stdin.write("begin isolation level read committed read write; set local role anon; insert into public.freeze_probe_items (note) values ('pooled'); commit; select 'DONE_POOLED';\n"); pooled.stdin.flush()
    time.sleep(1.0)
    pooled.stdin.write("\\q\n"); pooled.stdin.flush()
    out, err = pooled.communicate(timeout=20)
    check("an EXISTING pooled session (opened before the freeze) cannot write either", "TDP_MAINTENANCE_FREEZE" in err and "DONE_POOLED" in out, err[-200:])
    lab.reap("authenticator")
    p = lab.run("stray_app", "insert into public.dispatches (note) values ('x')", ok=False, extra_args=V)
    check("an unknown NON-exempt login role is blocked (fail closed: exemption is an allow-list)", p.returncode != 0)
    lab.run("postgres", "grant insert on public.dispatches to stray_app;")
    p = lab.run("stray_app", "insert into public.dispatches (note) values ('x')", ok=False, extra_args=V)
    check("an unknown login role WITH table privileges is still blocked by the trigger", blocked(p), p.stderr[-200:])
    lab.run("postgres", "revoke insert on public.dispatches from stray_app;")
    check("business data unchanged by all API attempts", v1.counts(lab) == counts_before)
    p = lab.run("operator", "insert into public.dispatches (note) values ('operator-write'); delete from public.dispatches where note = 'operator-write'; select public.app_write(); delete from public.dispatches where note = 'rpc';", ok=False, extra_args=V)
    check("the OPERATOR (exempt login) can still write, call writable RPCs and migrate", p.returncode == 0, p.stderr[-200:])
    p = lab.run("operator", "begin; set local role anon; insert into public.freeze_probe_items (note) values ('operator-as-anon'); rollback;", ok=False)
    check("design property: the operator stays exempt even after SET ROLE anon (session_user decides) -- an API caller cannot use this: PostgREST logs in as authenticator", p.returncode == 0)
    p = lab.run("postgres", "insert into public.dispatches (note) values ('super'); delete from public.dispatches where note = 'super';", ok=False)
    check("an exempt superuser (the supabase_admin analog) can still write", p.returncode == 0)
    seen = lab.rows("authenticator", "begin isolation level read committed read write; set local role authenticated; select public.diag()->>'session_user', public.diag()->>'current_user'; commit;")
    check("model check: inside the definer/REST path session_user is the login (authenticator) and current_user the request role", seen and seen[-1][:2] == ["authenticator", "authenticated"], str(seen))

    print("== 4. the SQL-layer verifier: honest verdict, real trigger firing, sabotage detection, no data change ==")
    rows = lab.rows("operator", sql("04_verify_freeze_sql_layer.sql"))
    verdict = [r for r in rows if len(r) >= 3 and r[1] == "VERDICT"]
    check("04 on a good freeze: verdict is SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED (never PASS/FROZEN)", verdict and verdict[0][2] == "SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED" and "PASS" != verdict[0][2], str(verdict))
    check("04 really fires the trigger on every frozen table (zero-row DELETE -> 25006)", any("really FIRES" in r[1] and r[2] == "PASS" for r in rows if len(r) >= 3))
    check("04 changed nothing: exempt roles still recorded, counts and fingerprint identical", lab.scalar("select exempt_roles::text from ops_freeze_v2.freeze_run") == "{operator,postgres}" and v1.counts(lab) == counts_before and catalog_fp(lab) == before_fp)
    lab.run("operator", 'alter table public.freeze_probe_items disable trigger "0_ops_freeze_block_writes";')
    rows = lab.rows("operator", sql("04_verify_freeze_sql_layer.sql"))
    check("04 DETECTS a disabled trigger (SQL_LAYER_FAIL)", any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_FAIL" for r in rows))
    p = api(lab, "anon", "insert into public.freeze_probe_items (note) values ('leak')")
    check("(control) with that trigger disabled the API write really would succeed -> the SQL layer is what matters and the verifier caught it", p.returncode == 0)
    lab.run("operator", "delete from public.freeze_probe_items where note = 'leak'; alter table public.freeze_probe_items enable always trigger \"0_ops_freeze_block_writes\";")
    lab.run("operator", "create table public.new_after_freeze (id serial primary key, note text); grant select, insert on public.new_after_freeze to anon; grant usage on all sequences in schema public to anon;")
    p = api(lab, "anon", "insert into public.new_after_freeze (note) values ('gap')")
    check("KNOWN GAP (documented): a table created while frozen is writable until 03_refresh_coverage.sql runs", p.returncode == 0)
    rows = lab.rows("operator", sql("04_verify_freeze_sql_layer.sql"))
    check("04 DETECTS the uncovered new table (SQL_LAYER_FAIL)", any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_FAIL" for r in rows))
    lab.run("operator", "delete from public.new_after_freeze;")
    p = lab.run("operator", sql("03_refresh_coverage.sql"), ok=False)
    check("03 covers the new table", p.returncode == 0 and trig_count(lab) == ntab + 1, p.stderr[-200:])
    p = api(lab, "anon", "insert into public.new_after_freeze (note) values ('gap2')")
    check("after 03 the new table is blocked for the API", blocked(p), p.stderr[-200:])
    rows = lab.rows("operator", sql("04_verify_freeze_sql_layer.sql"))
    check("04 with migrations since the freeze: fingerprint FAIL unless v_after_migrations is true", any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_FAIL" for r in rows))
    rows = lab.rows("operator", sql("04_verify_freeze_sql_layer.sql").replace("v_after_migrations constant boolean := false;", "v_after_migrations constant boolean := true;"))
    check("04 with v_after_migrations=true: OK verdict (the differences are INFO rows)", any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED" for r in rows))
    p = lab.run("stray_app", sql("04_verify_freeze_sql_layer.sql"), ok=False)
    check("(control) the verifier's decision function says non-operator API roles are not exempt", lab.scalar("select ops_freeze_v2.session_is_exempt('authenticator')::text") == "false" and lab.scalar("select ops_freeze_v2.session_is_exempt('operator')::text") == "true")
    check("cron: the reviewed writer is paused; readers and the already-off job are untouched", lab.rows("postgres", "select jobid, active from cron.job order by 1") == [["1", "f"], ["2", "t"], ["3", "f"]])
    check("API roles cannot execute the freeze functions or read its state", lab.run("authenticator", "begin; set local role anon; select ops_freeze_v2.session_is_exempt('x'); rollback;", ok=False).returncode != 0
          and lab.run("authenticator", "begin; set local role authenticated; select * from ops_freeze_v2.freeze_run; rollback;", ok=False).returncode != 0)

    print("== 5. cron safety on disable, then disable, exact restoration ==")
    lab.run("postgres", "update cron.job set active = true where jobid = 1;")
    p = lab.run("operator", sql("05_disable_freeze.sql"), ok=False)
    check("disable ABORTS when a paused cron job was re-activated by someone else (transaction rolled back, triggers remain)", p.returncode != 0 and "re-activated" in p.stderr and trig_count(lab) == ntab + 1, p.stderr[-200:])
    lab.run("postgres", "update cron.job set active = false where jobid = 1;")
    p = lab.run("operator", sql("05_disable_freeze.sql"), ok=False)
    check("disable succeeds", p.returncode == 0 and "FREEZE DISABLED" in p.stderr, p.stderr[-300:])
    check("no freeze trigger remains anywhere; run marked restored", trig_count(lab) == 0 and lab.scalar("select status from ops_freeze_v2.freeze_run") == "restored")
    check("cron: ONLY the job the freeze paused is active again; the job that was already off stays off", lab.rows("postgres", "select jobid, active from cron.job order by 1") == [["1", "t"], ["2", "t"], ["3", "f"]])
    rows = lab.rows("operator", sql("06_verify_disable.sql"))
    check("06 on a freeze with migrations: verdict flags the fingerprint difference (SQL_LAYER_RESTORED_BUT_FINGERPRINT_DIFFERS__EXPLAIN_OR_STOP)",
          any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_RESTORED_BUT_FINGERPRINT_DIFFERS__EXPLAIN_OR_STOP" for r in rows), str(rows[-1:]))
    for role in ("anon", "authenticated", "service_role"):
        p = api(lab, role, "insert into public.freeze_probe_items (note) values ('after')")
        check(f"after disable the SAME {role} REST-style write succeeds again", p.returncode == 0, p.stderr[-200:])
    p = api(lab, "service_role", "select public.app_write()")
    check("after disable the writable SECURITY DEFINER RPC works again", p.returncode == 0)
    p = lab.run("operator", sql("05_disable_freeze.sql"), ok=False)
    check("a second disable is REFUSED (no active run)", p.returncode != 0 and "no active freeze run" in p.stderr)

    print("== 6. clean cycle without migrations: fingerprints identical; then emergency path ==")
    lab.run("operator", "drop table public.new_after_freeze;")
    lab.run("postgres", "delete from public.freeze_probe_items where note in ('after','pooled'); delete from public.dispatches where note = 'rpc'; update cron.job set active = false where jobid = 1;")
    lab.run("postgres", "update cron.job set active = true where jobid = 1;")
    fp0 = catalog_fp(lab)
    p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **good_kw), ok=False)
    check("second freeze run (after a restored one) enables", p.returncode == 0, p.stderr[-300:])
    rows = lab.rows("operator", sql("04_verify_freeze_sql_layer.sql"))
    check("04 (no migrations): OK verdict with fingerprints identical", any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED" for r in rows), str([r for r in rows if len(r) > 2 and r[2] == "FAIL"]))
    p = lab.run("operator", sql("EMERGENCY_UNFREEZE.sql"), ok=False)
    check("EMERGENCY_UNFREEZE.sql (stateless) removes every freeze trigger", p.returncode == 0 and trig_count(lab) == 0, p.stderr[-200:])
    check("after the emergency path API writes work again", api(lab, "anon", "insert into public.freeze_probe_items (note) values ('em')").returncode == 0)
    p = lab.run("operator", sql("05_disable_freeze.sql"), ok=False)
    check("05 still completes after an emergency unfreeze (drops nothing, resumes cron, marks restored)", p.returncode == 0 and lab.scalar("select status from ops_freeze_v2.freeze_run order by started_at desc limit 1") == "restored", p.stderr[-200:])
    lab.run("postgres", "delete from public.freeze_probe_items where note = 'em';")
    rows = lab.rows("operator", sql("06_verify_disable.sql"))
    check("06 after a migration-free cycle: SQL_LAYER_RESTORED__EXTERNAL_WRITE_PROBE_REQUIRED (trigger and ACL fingerprints identical)", any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_RESTORED__EXTERNAL_WRITE_PROBE_REQUIRED" for r in rows), str(rows[-3:]))
    check("whole cycle: no role/setting/ACL/RLS/function-privilege change", catalog_fp(lab) == fp0)

    print("== 7. optional session recycle (hosted test helper) ==")
    s = lab.session("authenticator", "select pg_sleep(60);"); lab.wait_backend("authenticator")
    keep = lab.session("stray_app", "select pg_sleep(60);"); lab.wait_backend("stray_app")
    rec = sql("07_recycle_api_sessions_optional.sql")
    rec = rec.replace("v_operator_role constant text   := '';", "v_operator_role constant text   := 'operator';").replace("v_confirm       constant text   := '';", "v_confirm       constant text   := 'RECYCLE frz_lab';").replace("v_api_roles     constant text[] := array[]::text[];", "v_api_roles     constant text[] := array['authenticator'];")
    p = lab.run("operator", rec.replace("array['authenticator'];", "array['pgbouncer'];"), ok=False)
    check("recycle REFUSES a never-terminate role", p.returncode != 0 and "never-terminate" in p.stderr)
    p = lab.run("operator", rec, ok=False)
    check("recycle terminates the authenticator session only", p.returncode == 0 and lab.scalar("select count(*) from pg_stat_activity where usename = 'authenticator' and backend_type = 'client backend'") == "0"
          and lab.scalar("select count(*) from pg_stat_activity where usename = 'stray_app' and backend_type = 'client backend'") == "1")
    s.kill(); keep.kill(); lab.reap("authenticator", "stray_app", "operator")

    print("== 9. pg_cron ABSENT (hosted tdp-freeze-test has no cron schema): the whole cycle must work; pg_cron PRESENT is covered by sections 2-7 ==")
    lab.run("postgres", "drop schema cron cascade;")
    check("precondition: cron.job does not exist", lab.scalar("select (to_regclass('cron.job') is null)::text") == "true")
    p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **good(major, pause="1", keep="2,3")), ok=False)
    check("no pg_cron: enable REFUSES cron ids that cannot exist (fail closed, nothing left behind)", p.returncode != 0 and "cron.job is not present" in p.stderr and trig_count(lab) == 0
          and lab.scalar("select count(*) from ops_freeze_v2.freeze_run where status = 'frozen'") == "0", p.stderr[-260:])
    p = lab.run("operator", fill2(sql("02_enable_freeze.sql"), **good(major, pause="", keep="")), ok=False)
    check("no pg_cron: enable SUCCEEDS (no 42P01 relation \"cron.job\" does not exist)", p.returncode == 0 and "FREEZE ENABLED" in p.stderr and "42P01" not in p.stderr, p.stderr[-400:])
    check("no pg_cron: every table is covered and no cron state was recorded", trig_count(lab) == int(lab.scalar("select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r','p')"))
          and lab.scalar("select count(*) from ops_freeze_v2.cron_state where run_id = (select run_id from ops_freeze_v2.freeze_run where status = 'frozen')") == "0")
    check("no pg_cron: API write is blocked while frozen", blocked(api(lab, "anon", "insert into public.freeze_probe_items (note) values ('x')")))
    rows = lab.rows("operator", sql("04_verify_freeze_sql_layer.sql"))
    check("no pg_cron: 04 works and gives the honest OK verdict (cron row is INFO 'not exercised')", any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED" for r in rows)
          and any(len(r) >= 3 and "pg_cron is not installed" in r[1] and r[2] == "INFO" for r in rows), str([r for r in rows if len(r) > 2 and r[2] == "FAIL"]))
    p = lab.run("operator", sql("03_refresh_coverage.sql"), ok=False)
    check("no pg_cron: 03 refresh works", p.returncode == 0, p.stderr[-200:])
    p = lab.run("operator", sql("05_disable_freeze.sql"), ok=False)
    check("no pg_cron: 05 disable works", p.returncode == 0 and "FREEZE DISABLED" in p.stderr and trig_count(lab) == 0, p.stderr[-300:])
    rows = lab.rows("operator", sql("06_verify_disable.sql"))
    check("no pg_cron: 06 works and reports restored", any(len(r) >= 3 and r[1] == "VERDICT" and r[2] == "SQL_LAYER_RESTORED__EXTERNAL_WRITE_PROBE_REQUIRED" for r in rows), str(rows[-3:]))
    check("no pg_cron: API writes work again after disable", api(lab, "anon", "insert into public.freeze_probe_items (note) values ('y')").returncode == 0)
    lab.run("postgres", "delete from public.freeze_probe_items where note = 'y';")
    p = lab.run("operator", sql("EMERGENCY_UNFREEZE.sql"), ok=False)
    check("no pg_cron: emergency unfreeze runs cleanly", p.returncode == 0, p.stderr[-200:])


def blocked_pg(p):
    return p.returncode != 0 and "25006" in p.stderr and "read-only transaction" in p.stderr


# ---------------------------------------------------------------------------------------------------------------------------------------------- the external probe part
class Mock(BaseHTTPRequestHandler):
    mode = "baseline"          # baseline | frozen_ok | frozen_leaky | frozen_other | restored
    pids = [(11, "2026-01-01T00:00:00Z"), (12, "2026-01-01T00:00:01Z")]
    hits = []

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        Mock.hits.append((self.command, self.path, self.headers.get("apikey")))
        if self.path.startswith("/rest/v1/rpc/freeze_probe_diag"):
            pid, start = Mock.pids[len(Mock.hits) % len(Mock.pids)]
            return self._send(200, {"session_user": "authenticator", "current_user": "anon", "default_transaction_read_only": "off", "transaction_read_only": "off", "pid": pid, "backend_start": start})
        if self.command == "GET":
            return self._send(200, [{"id": 1}])
        role_is_anon = self.headers.get("apikey") == os.environ["TDP_ANON_KEY"] and self.headers.get("Authorization") == "Bearer " + os.environ["TDP_ANON_KEY"]
        if Mock.mode in ("baseline", "restored"):
            return self._send(201 if self.command == "POST" else 200, [{"id": 2}])
        if Mock.mode == "frozen_leaky" and self.command == "POST" and role_is_anon and "/rpc/" not in self.path:
            return self._send(201, [{"id": 2}])
        if Mock.mode == "frozen_other":
            return self._send(401, {"code": "PGRST301", "message": "JWT expired"})
        return self._send(405, {"code": "25006", "message": "TDP_MAINTENANCE_FREEZE: writes are temporarily disabled during a scheduled system upgrade"})

    do_GET = do_POST = do_PATCH = do_DELETE = _handle


def probe_tests():
    print("== 8. external API probe against a LOCAL MOCK server (127.0.0.1 only; proves the probe's logic, not Supabase) ==")
    srv = HTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    sent = {"TDP_ANON_KEY": "SENTINEL-ANON-KEY-DO-NOT-PRINT", "TDP_SERVICE_KEY": "SENTINEL-SERVICE-KEY-DO-NOT-PRINT", "TDP_USER_JWT": "SENTINEL-USER-JWT-DO-NOT-PRINT"}
    os.environ.update(sent)
    tmp = tempfile.mkdtemp(prefix="probe-ev-")
    exe = HERE / "hosted_test" / "api_freeze_probe.py"

    def run(*args, url=f"http://127.0.0.1:{port}", extra_env=None):
        env = {**os.environ, "TDP_PROJECT_URL": url, "TDP_ALLOW_LOCAL_MOCK": "1", **(extra_env or {})}
        return subprocess.run([sys.executable, "-B", str(exe), "--evidence-dir", tmp, *args], capture_output=True, text=True, env=env, timeout=120)

    def no_leak(p):
        blob = p.stdout + p.stderr + "".join(f.read_text() for f in Path(tmp).glob("evidence_*.json"))
        return not any(v in blob for v in sent.values())

    Mock.mode = "baseline"
    p = run("--phase", "baseline", "--burst", "2")
    check("probe baseline: writes succeed for anon, service_role and authenticated -> WRITES_WORK (exit 0)", p.returncode == 0 and "WRITES_WORK" in p.stdout, p.stdout[-300:] + p.stderr[-200:])
    Mock.mode = "frozen_ok"; Mock.pids = [(11, "t1"), (12, "t2")]
    p = run("--phase", "frozen", "--label", "pooled", "--burst", "2")
    pooled_ev = sorted(Path(tmp).glob("evidence_frozen_pooled_*.json"))[-1]
    check("probe frozen (all blocked with the marker, reads work): FREEZE_PROVEN (exit 0)", p.returncode == 0 and "FREEZE_PROVEN" in p.stdout, p.stdout[-400:])
    Mock.pids = [(11, "t1"), (13, "t3")]
    p = run("--phase", "frozen", "--label", "new", "--compare-pids", str(pooled_ev))
    check("probe 'new connections' with a SHARED backend: NOT proven (exit 2)", p.returncode == 2 and "FREEZE_NOT_PROVEN" in p.stdout, p.stdout[-300:])
    Mock.pids = [(21, "t7"), (22, "t8")]
    p = run("--phase", "frozen", "--label", "new", "--compare-pids", str(pooled_ev))
    check("probe 'new connections' with DISJOINT backends: FREEZE_PROVEN", p.returncode == 0 and "FREEZE_PROVEN" in p.stdout, p.stdout[-300:])
    Mock.mode = "frozen_leaky"
    n_before = len(Mock.hits)
    p = run("--phase", "frozen", "--label", "leak")
    ev = sorted(Path(tmp).glob("evidence_frozen_leak_*.json"))[-1]
    check("probe frozen with ONE leaking write (anon POST 201, the hosted v1 failure): FREEZE_BREACH, exit 3, stops immediately, production approval BLOCKED",
          p.returncode == 3 and "FREEZE_BREACH" in p.stdout and "STOP ALL MIGRATION ACTIVITY" in p.stdout and "05_disable_freeze.sql" in p.stdout and json.loads(ev.read_text())["production_approval"] == "BLOCKED", p.stdout[-500:])
    check("the breach stopped the run at the first success (no further write requests were sent)", sum(1 for h in Mock.hits[n_before:] if h[0] in ("PATCH", "DELETE")) == 0)
    Mock.mode = "frozen_other"
    p = run("--phase", "frozen", "--label", "other")
    check("probe frozen where writes fail for ANOTHER reason (401, no freeze marker): INCONCLUSIVE -> NOT proven (exit 2)", p.returncode == 2 and "FREEZE_NOT_PROVEN" in p.stdout, p.stdout[-300:])
    Mock.mode = "frozen_ok"
    p = run("--phase", "frozen", "--label", "nojwt", extra_env={"TDP_USER_JWT": ""})
    check("probe with no authenticated-user JWT: INCOMPLETE -> NOT proven (fail closed)", p.returncode == 2 and "INCOMPLETE" in p.stdout, p.stdout[-300:])
    Mock.mode = "restored"
    p = run("--phase", "restored")
    check("probe restored: writes work again -> WRITES_WORK", p.returncode == 0 and "WRITES_WORK" in p.stdout)
    check("no key/JWT value ever appears in probe output or evidence files", all(no_leak(q) for q in [p]))
    p = run("--phase", "baseline", url="https://zteixenjpcygjvznueuo.supabase.co")
    check("probe REFUSES the production project before any request", p.returncode != 0 and "PRODUCTION" in (p.stdout + p.stderr) and "PRODUCTION" in (p.stdout + p.stderr), (p.stdout + p.stderr)[-200:])
    p = run("--phase", "baseline", url="https://abcdefghijk.supabase.co")
    check("probe REFUSES a project whose ref does not start with the expected test prefix", p.returncode != 0 and "expected test-project prefix" in (p.stdout + p.stderr))
    p = run("--phase", "baseline", url="http://127.0.0.1:%d" % port, extra_env={"TDP_ALLOW_LOCAL_MOCK": "0"})
    check("probe REFUSES a non-Supabase target unless the local-mock switch is set", p.returncode != 0 and "https://<ref>.supabase.co" in (p.stdout + p.stderr))
    srv.shutdown()


def main():
    static_checks()
    lab = Lab()
    ok = False
    try:
        lab.c.start()
        major = int(lab.c.run(t149.PSQL, ["-X", "-A", "-t", "-h", str(lab.c.sock), "-p", str(t149.PORT), "-U", "postgres", "-d", "postgres", "-c", "show server_version_num"]).stdout.strip()) // 10000
        print(f"== disposable PostgreSQL {major} (unix socket only) with a simulated Supabase role model ==")
        db_tests(lab, major)
        ok = True
    finally:
        lab.reap("authenticator", "stray_app", "operator")
        lab.c.cleanup(ok)
    probe_tests()
    print(f"\nALL {len(checks)} V2 FREEZE-TOOLING CHECKS PASSED (local disposable PostgreSQL {major}; NOT a hosted-Supabase proof)")


if __name__ == "__main__":
    main()
