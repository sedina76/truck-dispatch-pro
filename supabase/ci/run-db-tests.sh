#!/usr/bin/env bash
# =============================================================================
# supabase/ci/run-db-tests.sh -- runs EVERY database test suite on throwaway
# PostgreSQL clusters. Touches nothing outside temp dirs; never connects to
# Supabase or any real database.
#
#   1. TEST_0130_0133_run.sh             (26 migration/behavior test files)
#   2. TEST_DEADLOCK_*, TEST_ROLLBACK_*, TEST_CONCURRENCY_*  (each its own cluster)
#   3. TEST_0144_LOAD_STOPS_PARENT_LOCK.sql
#   4. TEST_0148 (cross-tenant takeover guard) on a database built from
#      migrations 0001..0119 + platform_stub.sql + 0148 -- the newest point a
#      fresh build can reach (0120+ are pinned to production data). Also
#      proves the guard is genuinely needed: the test must FAIL without 0148.
#
# Requires initdb/pg_ctl/psql/createdb on PATH and a non-root user (initdb
# refuses root). Usage:  bash supabase/ci/run-db-tests.sh
# Exit code is non-zero if anything failed.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # .../supabase
cd "$HERE"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/tdp-db-tests.XXXXXX")"
PORT_BASE="${PORT_BASE:-56100}"
FAILED=()
port=$PORT_BASE

# Runs one suite; retries ONCE only when the throwaway server failed to start
# (an environment hiccup, never a test result).
run_suite() {
  local name="$1"; shift
  local log="$OUT/$name.log"
  for attempt in 1 2; do
    port=$((port + 1))
    PGPORT=$port "$@" >"$log" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then echo "PASS  $name"; return 0; fi
    if [ $attempt -eq 1 ] && grep -q "could not start server" "$log"; then
      echo "retry $name (server failed to start)"; sleep 2; continue
    fi
    echo "FAIL  $name (exit $rc) -- last lines:"; tail -25 "$log" | sed 's/^/      /'
    FAILED+=("$name"); return 1
  done
}

# Builds a throwaway DB from 0001..0119 (+ optional extra files), runs one SQL test.
run_fresh_db_test() {
  local test_sql="$1"; shift
  local extras=("$@")
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/tdp-fresh.XXXXXX")"
  local p=${PGPORT:?}
  initdb -D "$d" -U postgres --auth=trust --no-locale -E UTF8 >/dev/null || return 9
  pg_ctl -D "$d" -l "$d/log" -o "-p $p -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c fsync=off" -w start >/dev/null \
    || { echo "could not start server"; rm -rf "$d"; return 9; }
  local psql=(psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$p" -U postgres -d t)
  local rc=0
  createdb -h 127.0.0.1 -p "$p" -U postgres t \
    && "${psql[@]}" -f ci/platform_stub.sql >/dev/null || rc=8
  if [ $rc -eq 0 ]; then
    for m in migrations/*.sql; do
      local n; n="$(basename "$m" | cut -c1-4)"
      [[ "$n" > "0119" ]] && break
      # pg_cron is not installable on plain PostgreSQL; the stub provides cron.*
      sed -E 's/create extension if not exists pg_cron[^;]*;/select 1;/I' "$m" | "${psql[@]}" >/dev/null || { echo "migration failed: $m"; rc=7; break; }
    done
  fi
  if [ $rc -eq 0 ]; then
    for e in "${extras[@]}"; do "${psql[@]}" -f "$e" >/dev/null || { echo "extra failed: $e"; rc=6; break; }; done
  fi
  [ $rc -eq 0 ] && { psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$p" -U postgres -d t -f "$test_sql" || rc=1; }
  pg_ctl -D "$d" -m immediate stop >/dev/null 2>&1; rm -rf "$d"
  return $rc
}

# Expects the given command to FAIL (proves a test actually detects the bug).
expect_failure() { if "$@"; then echo "UNEXPECTED PASS"; return 1; else return 0; fi; }

echo "== database tests (logs: $OUT) =="
run_suite "TEST_0130_0133_run" bash ./TEST_0130_0133_run.sh
for f in TEST_DEADLOCK_*.sh TEST_ROLLBACK_*.sh TEST_CONCURRENCY_*.sh; do
  run_suite "${f%.sh}" bash "./$f"
done

single_sql_test() {
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/tdp-single.XXXXXX")"
  initdb -D "$d" -U postgres --auth=trust --no-locale -E UTF8 >/dev/null || return 9
  pg_ctl -D "$d" -l "$d/log" -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c fsync=off" -w start >/dev/null \
    || { echo "could not start server"; rm -rf "$d"; return 9; }
  createdb -h 127.0.0.1 -p "$PGPORT" -U postgres t
  psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PGPORT" -U postgres -d t -f "$1"; local rc=$?
  pg_ctl -D "$d" -m immediate stop >/dev/null 2>&1; rm -rf "$d"
  return $rc
}
run_suite "TEST_0144_LOAD_STOPS_PARENT_LOCK" single_sql_test TEST_0144_LOAD_STOPS_PARENT_LOCK.sql

run_suite "TEST_0148_without_fix_must_fail" expect_failure run_fresh_db_test TEST_0148_profile_cross_tenant_move_guard.sql
run_suite "TEST_0148_profile_cross_tenant_move_guard" run_fresh_db_test TEST_0148_profile_cross_tenant_move_guard.sql migrations/0148_profile_cross_tenant_move_guard.sql

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "ALL DATABASE TESTS PASSED"
  exit 0
fi
echo "DATABASE TEST FAILURES: ${FAILED[*]}"
exit 1
