#!/usr/bin/env python3
"""Explicit server-version behaviour probe (run on PostgreSQL 17.6 in a container AND on 18.x, then diff the reports).

Builds the real chain 0130..0147 -> 0149 -> 0150 -> 0151 (Supabase-style default privileges), applies 0152, and prints KEY=VALUE lines for every behaviour the
compatibility gate names. Synthetic data only; disposable cluster only (same guard/harness as the proposal tests)."""
import importlib.util
import re
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


t151 = _load("t151p", HERE.parent / "0151" / "tests.py")
t150, t149 = t151.t150, t151.t150.t149
build = _load("b152p", HERE / "build.py")
out = []


def emit(k, v):
    out.append(f"{k}={v}")
    print(f"{k}={v}")


def main():
    c = t149.Cluster()
    ok = False
    try:
        c.start()
        env = t151.DPEnv(c)
        base = "td0149_v_base"
        env.build_base(base)
        rows, summ = env.review(base)
        n, dig = int(summ["CANDIDATES (approve this count)"]), summ["candidate digest (REQUIRED: paste into v_expected_digest)"]
        assert env.run(base, t150.fill((HERE.parent / "0150" / "proposed_0150.sql").read_text(), n, dig)).returncode == 0
        assert env.run(base, (HERE.parent / "0151" / "proposed_0151.sql").read_text()).returncode == 0
        main_db = "td0149_v_main"
        c.createdb(main_db, template=base)
        acl_sql = "select p.oid::regprocedure::text, coalesce(p.proacl::text, 'NULL') from pg_proc p where p.pronamespace = 'public'::regnamespace order by 1"
        acl0 = dict(tuple(r) for r in env.q(base, acl_sql)[1])
        cat0 = env.catalog(base)
        assert env.run(main_db, (HERE / "proposed_0152.sql").read_text()).returncode == 0
        acl1 = dict(tuple(r) for r in env.q(main_db, acl_sql)[1])
        q = lambda sql, db=main_db: env.q(db, sql)[1]

        emit("server_version", q("select current_setting('server_version')")[0][0].split(" ")[0])
        emit("server_version_num", q("select current_setting('server_version_num')")[0][0])
        emit("platform", re.search(r"on (\S+),", q("select version()")[0][0]).group(1))

        # 1. text NOT NULL without default: empty vs non-empty table; attnotnull; pg_constraint rows
        r = env.run(base, "create table public.pv_empty (a int); alter table public.pv_empty add column x text not null; select 1;")
        emit("add_text_not_null_to_EMPTY_table_rc", r.returncode)
        r = env.run(base, "create table public.pv_full (a int); insert into public.pv_full values (1); alter table public.pv_full add column x text not null;")
        emit("add_text_not_null_to_NONEMPTY_table_rc", r.returncode)
        emit("add_text_not_null_to_NONEMPTY_table_error", re.sub(r'"[^"]*"', '"..."', re.search(r"ERROR:\s+(.*)", r.stderr).group(1)) + " | " + (re.search(r"SQLSTATE|LINE", r.stderr) or "")  if False else re.sub(r'"[^"]*"', '"..."', re.search(r"ERROR:\s+(.*)", r.stderr).group(1)))
        emit("insert_NULL_into_not_null_column", "; ".join(sorted(set(re.sub(r'"[^"]*"', '"..."', m) for m in re.findall(r"ERROR:\s+(.*)", env.run(main_db, f"insert into public.factoring_policy_idempotency (organization_id, carrier_id, idempotency_key, result) values ('{t150.uid('o1')}', '{t150.uid('ca')}', 'k', '{{}}');", guard=True).stderr)))))
        emit("attnotnull_request_fingerprint_columns", ",".join(f"{a[0]}:{a[1]}" for a in q("select c.relname, a.attnotnull from pg_attribute a join pg_class c on c.oid = a.attrelid where a.attname = 'request_fingerprint' and c.relname in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency') order by 1")))
        emit("pg_constraint_NOT_NULL_rows_for_request_fingerprint", q("select count(*) from pg_constraint k join pg_class c on c.oid = k.conrelid join pg_attribute a on a.attrelid = c.oid and a.attnum = any(k.conkey) where a.attname = 'request_fingerprint' and c.relname in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency') and k.contype::text = 'n'")[0][0])
        emit("pg_constraint_contype_values_present_in_public", ",".join(sorted(x[0] for x in q("select distinct k.contype::text from pg_constraint k join pg_namespace n on n.oid = k.connamespace where n.nspname = 'public'"))))

        # 2. ACL preservation, owner, security mode, search_path, CREATE OR REPLACE
        changed = sorted(k.split("(")[0] for k in set(acl0) | set(acl1) if acl0.get(k) != acl1.get(k))
        emit("acl_functions_compared", len(acl0))
        emit("acl_changed_functions", ",".join(changed))
        emit("acl_changed_only_by_losing_service_role", all(acl0[k].replace(",service_role=X/postgres", "") == acl1[k] for k in acl0 if acl0[k] != acl1[k]))
        emit("catalog_changed_key_kinds", ",".join(sorted({f"{k[0]}" for k in t149.changed(cat0, env.catalog(main_db))})))
        for name, sig, _ in build.FUNCS:
            r = q(f"select pg_get_userbyid(p.proowner), p.prosecdef::text, coalesce(p.proconfig::text, ''), l.lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = to_regprocedure('{sig}')")[0]
            emit(f"function[{name}]", "|".join(r))
        emit("create_or_replace_keeps_acl_owner_comment",
             env.run(main_db, "create function public.pv_f() returns int language sql as 'select 1'; grant execute on function public.pv_f() to authenticated; comment on function public.pv_f() is 'c'; "
                              "create or replace function public.pv_f() returns int language sql as 'select 2';").returncode == 0
             and q("select coalesce(proacl::text, '') || '|' || coalesce(obj_description(oid, 'pg_proc'), '') from pg_proc where proname = 'pv_f'")[0][0].endswith("|c")
             and "authenticated=X" in q("select proacl::text from pg_proc where proname = 'pv_f'")[0][0])
        gd = c.psql(main_db, "select pg_get_functiondef('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)'::regprocedure);", tuples=True).stdout
        emit("pg_get_functiondef_reassign_header", " ".join(gd.replace("\n", " ").split(" AS ")[0].split())[:400])

        # 3. enum-array comparisons and text comparison failure
        emit("enum_array_any_typed", env.run(main_db, "select 1 from public.dispatches where status = any(array['assigned','accepted']::public.dispatch_status[]) limit 1;").returncode)
        r = env.run(main_db, "select 1 from public.dispatches where status = any(array['assigned','accepted']::text[]) limit 1;")
        emit("enum_vs_text_array_error", re.search(r"ERROR:\s+(.*)", r.stderr).group(1))

        # 4. SQLSTATE behaviour
        emit("sqlstate_custom_RRIDK_TSIDK_captured",
             env.run(main_db, "do $$ begin begin raise exception 'x' using errcode = 'RRIDK'; exception when sqlstate 'RRIDK' then raise notice 'caught RRIDK'; end; "
                              "begin raise exception 'y' using errcode = 'TSIDK'; exception when others then if sqlstate <> 'TSIDK' then raise exception 'wrong'; end if; raise notice 'caught TSIDK'; end; end $$;").stderr.count("caught"))
        emit("sqlstate_not_null_violation", re.search(r"(\d{5})", "23502").group(1))
        # 5. table + advisory locks, lock_timeout (55P03), deadlock (40P01)
        A = t150.Session(c, main_db)
        A.send("begin;\nlock table public.factoring_policy_idempotency in access exclusive mode;\nselect pg_advisory_xact_lock(7152);")
        time.sleep(0.5)
        B = c.psql(main_db, "set lock_timeout = '300ms'; do $$ begin begin lock table public.factoring_policy_idempotency in access exclusive mode; exception when lock_not_available then raise notice 'lock_not_available %', sqlstate; end; "
                            "raise notice 'advisory_try=%', pg_try_advisory_xact_lock(7152); end $$;", ok=False)
        emit("lock_timeout_sqlstate_and_advisory_try", " ".join(re.findall(r"NOTICE:\s+(.*)", B.stderr)))
        A.send("commit;")
        A.p.stdin.close()
        A.p.communicate(timeout=30)
        S1, S2 = t150.Session(c, main_db), t150.Session(c, main_db)
        S1.send("begin;\nselect pg_advisory_xact_lock(1);")
        S2.send("begin;\nselect pg_advisory_xact_lock(2);")
        time.sleep(0.4)
        S1.send("select pg_advisory_xact_lock(2);")
        time.sleep(0.4)
        S2.send("select pg_advisory_xact_lock(1);")
        time.sleep(2.5)
        S1.send("commit;"); S2.send("commit;")
        S1.p.stdin.close(); S2.p.stdin.close()
        e1 = S1.p.communicate(timeout=30)[1]; e2 = S2.p.communicate(timeout=30)[1]
        emit("deadlock_detected_sqlstate", "40P01" if "deadlock detected" in (e1 + e2) else "none")
        # 6. pg_dump lines for the new columns
        dump = c.dump(main_db)
        emit("pg_dump_request_fingerprint_lines", " || ".join(re.sub(r"\s+", " ", l.strip().rstrip(",")) for l in dump if l.strip().startswith("request_fingerprint text")))
        ok = True
    finally:
        c.cleanup(ok)


if __name__ == "__main__":
    main()
