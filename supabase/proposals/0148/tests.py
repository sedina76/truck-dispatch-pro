"""Local synthetic remediation tests; NOT APPROVED FOR PRODUCTION."""
import atexit
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import stat
import subprocess
import tempfile
import threading

HERE = Path(__file__).resolve().parent
PORT = "55489"
# Exact SHA-256 allowlist is regenerated only after static review, never at runtime.
REVIEWED = {'aggregate.sql': 'df8ebb9fb5c69514a922e3c6e05669b8862d016a264f096a8914dba09b7a9d56', 'backfill.sql': '7c75acfcb9681eb27622993443e5461792c69c9d8cb919d4b906db6a1ad875f4', 'fixture.sql': 'f968428329c796fd4137b7ddbf048ef587985e1429c08f0b59fcd78ebcfad57f', 'functional.sql': '07fed257c3225af8436b0aebe40ede8365968fa9fd4298b9dc41dd2e1c1f41da', 'harness.sql': '7278a509d8cc3257f994f09e55ecda363c15bbea756f10fe7cf41edc6e46239a', 'post_apply.sql': '1c8949f8c9856fd2c926d38ac4dfb5b1948cc190663159e9f2d9ce5b6d44b70d', 'preflight.sql': 'f0c8e14ce7459c9b17db801c1e2109997518fb5199747ab0b063448c1aec13d2', 'preview.sql': '2b0276cb8ff3d4f26c6040bb7ce279718575543816d81c7dd0f3e0273fa409c7', 'proposed_0148.sql': 'e45b8f48eb28eec6f675d5989ff361b70edd668aa996747203a950f7215526b4', 'reverse_stage.sql': '1c8fd356ec87364ddcc3497ab76cbd4cb916859bb074231082ba90b59e7dd582', 'rollback.sql': '176f3ef93833b9f2aa5208e8a00707574933ab174f12f32b882f9ed235114d11', 'schema_stage.sql': '2a17426bc61464a8e0157f8e44bec95d3b202abb9daff0d54fd6ad6a2682ed0a'}  # REVIEWED_SQL_HASHES


def require(condition, message):
    # Safety checks must also work with python -O.
    if not condition:
        raise RuntimeError(message)


def reviewed_sql():
    """Pinned, inspected SQL only; no includes or external subprocess interpolation."""
    result = {}
    for name, expected in REVIEWED.items():
        path = HERE / name
        require(path.is_file() and not path.is_symlink(), "Unsafe SQL path")
        raw = path.read_bytes()
        require(hashlib.sha256(raw).hexdigest() == expected, "Unreviewed SQL: " + name)
        result[name] = raw.decode("utf-8")
    # These are the only two composition points; psql never reads repository paths.
    result["proposed_0148.sql"] = result["proposed_0148.sql"].replace(
        "-- @SCHEMA_STAGE@", result["schema_stage.sql"])
    result["rollback.sql"] = result["rollback.sql"].replace(
        "-- @REVERSE_STAGE@", result["reverse_stage.sql"])
    return result


def main():
    scripts = reviewed_sql()
    root = Path(tempfile.mkdtemp(prefix="td0148-local-", dir="/private/tmp"))
    original = root.resolve(strict=True)
    identity = (root.stat().st_dev, root.stat().st_ino)

    def validate_root():
        require(not root.is_symlink(), "Root became a symlink")
        require(root.resolve(strict=True) == original and
                original.parent == Path("/private/tmp") and
                original.name.startswith("td0148-local-"), "Invalid generated root")
        info = root.stat()
        require((info.st_dev, info.st_ino) == identity and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o700, "Root identity changed")

    def beneath(name):
        validate_root()
        path = root / name
        require(not path.is_symlink(), "Symlink path rejected")
        resolved = path.resolve(strict=False)
        require(original in resolved.parents, "Path escaped generated root")
        return resolved

    data, socket, log = (beneath(name) for name in ("data", "socket", "server.log"))
    passfile, servicefile = (beneath(name) for name in ("empty.pgpass", "absent.pg_service.conf"))
    socket.mkdir(mode=0o700)
    fd = os.open(passfile, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    require(passfile.stat().st_size == 0 and
            stat.S_IMODE(passfile.stat().st_mode) == 0o600, "Invalid password file")
    require(not servicefile.exists(), "Service file must not exist")
    env = {
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
        "HOME": str(root), "TMPDIR": str(root),
        "PGSERVICEFILE": str(servicefile), "PGPASSFILE": str(passfile),
        "PGHOST": str(socket), "PGPORT": PORT,
        "PGUSER": "postgres", "PGDATABASE": "postgres", "PGCONNECT_TIMEOUT": "5",
    }
    require("PGSERVICE" not in env, "Service selection forbidden")

    def run(program, args, **kwargs):
        validate_root()
        for name in ("data", "socket", "server.log", "empty.pgpass", "absent.pg_service.conf"):
            beneath(name)
        require(program in {"initdb", "pg_ctl", "psql"}, "Unknown executable")
        return subprocess.run(["/opt/homebrew/bin/" + program, *args], env=env,
                              cwd=root, text=True, capture_output=True, timeout=90, **kwargs)

    started = False
    attempted = False
    success = False
    removed = False

    def stop():
        nonlocal started
        if removed or not attempted:
            return
        validate_root()
        beneath("data")
        # Handles launch success followed by timeout/error before started was set.
        status = run("pg_ctl", ["-D", str(data), "status"])
        if status.returncode == 3:
            started = False
            return
        require(status.returncode == 0, "Cannot determine local cluster status")
        stopped = run("pg_ctl", ["-D", str(data), "-m", "fast", "-w", "stop"])
        require(stopped.returncode == 0, "Local shutdown failed: " + stopped.stderr)
        started = False

    def safeguard():
        try:
            stop()
        except Exception as error:
            print(f"Shutdown safeguard failed; artifacts retained at {root}: {error}")

    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Received signal {signum}")

    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    atexit.register(safeguard)
    for sig in previous:
        signal.signal(sig, interrupted)
    try:
        init = run("initdb", ["-D", str(data), "-U", "postgres", "--auth=trust", "--no-locale"])
        require(init.returncode == 0, init.stderr)
        options = shlex.join(["-k", str(socket), "-p", PORT, "-c", "listen_addresses="])
        attempted = True
        start = run("pg_ctl", ["-D", str(data), "-l", str(log), "-o", options, "-w", "start"])
        if start.returncode == 0:
            started = True
        require(started, start.stderr)
        conn = ["-h", str(socket), "-p", PORT, "-U", "postgres", "-d", "postgres"]
        psql = ["-X", "-w", "-v", "ON_ERROR_STOP=1", *conn]
        identity_sql = """SELECT json_build_object(
          'socket_only', inet_server_addr() IS NULL,
          'listen', current_setting('listen_addresses'),
          'database', current_database(), 'user', current_user,
          'socket', current_setting('unix_socket_directories'),
          'port', current_setting('port'), 'data', current_setting('data_directory'));"""
        probe = run("psql", [*psql, "-At", "-c", identity_sql])
        require(probe.returncode == 0, probe.stderr)
        require(json.loads(probe.stdout) == {
            "socket_only": True, "listen": "", "database": "postgres", "user": "postgres",
            "socket": str(socket), "port": PORT, "data": str(data)}, "Wrong server identity")
        checks = []

        def sql(text, database="td0148_model", refused=None):
            require(database in {"postgres", "td0148_reference", "td0148_model"},
                    "Database is not disposable")
            args = ["-X", "-w", "-q", "-At", "-v", "ON_ERROR_STOP=1",
                    "-h", str(socket), "-p", PORT, "-U", "postgres", "-d", database]
            result = run("psql", args, input=text)
            if refused is None:
                require(result.returncode == 0, result.stderr)
            else:
                require(result.returncode != 0 and refused in result.stderr,
                        "Expected refusal missing: " + result.stderr)
            return result.stdout

        def state(database="td0148_model"):
            return json.loads(sql("BEGIN READ ONLY; SELECT json_build_object("
                "'catalog',_td0148.catalog(),'rows',_td0148.rows(true),"
                "'full_rows',_td0148.rows(false)); COMMIT;", database))

        def same(actual, expected, label):
            require(actual == expected, label)
            checks.append(label)

        def evidence(name, value):
            path = beneath(name + ".json")
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(value, stream, sort_keys=True)

        # Cluster-wide roles are created once; two explicit disposable databases.
        sql("CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; "
            "CREATE DATABASE td0148_reference; CREATE DATABASE td0148_model;", "postgres")
        for database in ("td0148_reference", "td0148_model"):
            sql(scripts["fixture.sql"] + scripts["harness.sql"], database)
        before = state("td0148_reference")
        # Separate reference database, using the same reviewed schema fragment.
        # This is a model oracle, NOT evidence of production equivalence.
        sql("BEGIN;\n" + scripts["schema_stage.sql"] + "\nCOMMIT;", "td0148_reference")
        after = state("td0148_reference")
        same(before["rows"], after["rows"], "reference_original_rows_unchanged")
        same(state(), before, "fixture_matches_reference")
        evidence("before", before)
        evidence("after", after)
        for label, value in (("before", before), ("after", after)):
            # All payloads come from local synthetic JSON. SQL literals are escaped.
            literals = [json.dumps(value[k], sort_keys=True).replace("'", "''")
                        for k in ("catalog", "rows", "full_rows")]
            sql("INSERT INTO _td0148.expected VALUES ('" + label + "','" +
                "','".join(literals) + "');")
        sql(scripts["preflight.sql"])
        same(state(), before, "preflight_read_only")

        adversarial = {
            "unexpected_table": "CREATE TABLE public.unexpected(id integer);",
            "policy_expression": "ALTER POLICY factoring_relationships_delete ON public.factoring_relationships USING (true);",
            "policy_role": "ALTER POLICY factoring_companies_delete ON public.factoring_companies TO authenticated;",
            "table_acl": "GRANT SELECT ON public.invoices TO PUBLIC;",
            "column_acl": "GRANT SELECT(id) ON public.invoices TO anon;",
            "default_acl": "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;",
            "column_default": "ALTER TABLE public.invoices ALTER COLUMN amount_paid SET DEFAULT 0;",
            "trigger_state": "ALTER TABLE public.factoring_relationships DISABLE TRIGGER factoring_relationships_guard_org;",
            "enum_label": "ALTER TYPE public.integration_provider ADD VALUE 'unexpected';",
            "financial_drift": "UPDATE public.invoices SET amount_paid=1 WHERE id=md5('invoice1')::uuid;",
            "unexpected_history": "CREATE SCHEMA supabase_migrations; CREATE TABLE supabase_migrations.schema_migrations(version text);",
        }
        # Mutate only inside deliberately aborted transactions; test the same locked gate.
        body = scripts["proposed_0148.sql"].replace("BEGIN;", "", 1)
        for label, change in adversarial.items():
            sql("BEGIN; " + change + "\n" + body, refused="0148_REFUSED_")
            same(state(), before, "refusal_zero_writes_" + label)

        # Inject a failure AFTER actual revocations/DDL but BEFORE commit.
        injected = scripts["proposed_0148.sql"].replace(
            "SELECT _td0148.check_state('after');",
            "DO $$ BEGIN RAISE EXCEPTION '0148_TEST_INJECTED'; END $$;")
        sql(injected, refused="0148_TEST_INJECTED")
        same(state(), before, "transactional_ddl_and_privilege_rollback")
        sql(scripts["proposed_0148.sql"])
        same(state(), after, "exact_post_apply_catalog_and_rows")
        sql(scripts["post_apply.sql"])
        sql(scripts["functional.sql"])
        checks.append("functional_sql_all_checks")
        aggregates = json.loads(sql(scripts["aggregate.sql"]))
        expected_aggregates = {
            "invoices": {"draft": 6, "sent": 21, "viewed": 1, "partially_paid": 2, "paid": 6, "void": 2},
            "payments": {"posted": 15, "voided": 2},
            "factoring": {"pending": 3, "rejected": 1, "partially_settled": 2},
            "invoice_recipient_conflicts": 3, "load_recipient_conflicts": 3,
            "relationship_carrier_nonnull": 0,
        }
        same({k: aggregates[k] for k in expected_aggregates}, expected_aggregates,
             "financial_aggregate_shapes_and_null_ownership")
        evidence("aggregate", aggregates)
        preview = sql(scripts["preview.sql"])
        same(sorted(line for line in preview.splitlines() if line), [
            "multi_carrier_org_provable|1", "single_carrier_org|1",
            "unresolved_multiple|1", "unresolved_no_evidence|1"], "aggregate_backfill_preview")
        same(state(), after, "verifiers_and_preview_read_only")
        # backfill.sql is deliberately NEVER executed during this phase.
        sql(scripts["proposed_0148.sql"], refused="0148_REFUSED_CATALOG_before")
        same(state(), after, "rerun_zero_writes")
        rollback_body = scripts["rollback.sql"].replace("BEGIN;", "", 1)
        sql("BEGIN; UPDATE public.factoring_relationships SET carrier_id=md5('carrier1')::uuid "
            "WHERE id=md5('relationship1')::uuid;\n" + rollback_body,
            refused="0148_REFUSED_")
        same(state(), after, "rollback_refuses_ownership_drift")
        sql(scripts["rollback.sql"])
        same(state(), before, "rollback_exact_normalized_catalog_acl_rows")
        sql(scripts["proposed_0148.sql"])
        same(state(), after, "reapply_after_rollback")
        sql(scripts["rollback.sql"])

        barrier = threading.Barrier(2)
        concurrent_script = scripts["proposed_0148.sql"].replace(
            "SELECT _td0148.lock_model();", "SELECT _td0148.lock_model(); SELECT pg_sleep(0.5);")

        def concurrent_apply(_):
            args = ["-X", "-w", "-q", "-At", "-v", "ON_ERROR_STOP=1",
                    "-h", str(socket), "-p", PORT, "-U", "postgres", "-d", "td0148_model"]
            barrier.wait(timeout=10)
            return run("psql", args, input=concurrent_script)

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(concurrent_apply, range(2)))
        same(sum(o.returncode == 0 for o in outcomes), 1, "concurrency_single_winner")
        loser = next(o for o in outcomes if o.returncode != 0)
        require("0148_REFUSED_BUSY" in loser.stderr or
                "0148_REFUSED_CATALOG_before" in loser.stderr, loser.stderr)
        checks.append("concurrency_loser_refused_without_deadlock")
        same(state(), after, "concurrency_no_partial_application")
        sql(scripts["rollback.sql"])
        same(state(), before, "final_rollback")
        summary = {"scope": "synthetic schema-stage remediation only",
                   "passed_named_checks": len(checks), "checks": checks,
                   "original_rows_sha256": hashlib.sha256(json.dumps(
                       before["rows"], sort_keys=True).encode()).hexdigest(),
                   "before_catalog_sha256": hashlib.sha256(json.dumps(
                       before["catalog"], sort_keys=True).encode()).hexdigest(),
                   "after_catalog_sha256": hashlib.sha256(json.dumps(
                       after["catalog"], sort_keys=True).encode()).hexdigest(),
                   "before_full_rows_sha256": hashlib.sha256(json.dumps(
                       before["full_rows"], sort_keys=True).encode()).hexdigest(),
                   "after_full_rows_sha256": hashlib.sha256(json.dumps(
                       after["full_rows"], sort_keys=True).encode()).hexdigest(),
                   "aggregates": aggregates,
                   "backfill_executed": False, "production_equivalence_proven": False,
                   "final_carrier_cutover_proven": False}
        evidence("results", summary)
        print(json.dumps(summary))
        success = True
    finally:
        # Prevent repeated interrupts during bounded shutdown.
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        try:
            stop()
            if success:
                validate_root()
                for directory, directories, files in os.walk(root, followlinks=False):
                    for name in directories + files:
                        entry = Path(directory) / name
                        require(not entry.is_symlink(), "Cleanup refuses symlink")
                        require(entry.lstat().st_dev == identity[0], "Cleanup refuses mount")
                        require(original in entry.resolve(strict=True).parents,
                                "Cleanup path escaped root")
                validate_root()
                require(shutil.rmtree.avoids_symlink_attacks, "Unsafe rmtree implementation")
                shutil.rmtree(original)
                removed = True
                print("Disposable server stopped; temporary artifacts removed.")
            else:
                print(f"Failure: artifacts retained at {root}")
            atexit.unregister(safeguard)
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)


if __name__ == "__main__":
    main()
