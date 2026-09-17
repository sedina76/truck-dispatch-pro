#!/usr/bin/env bash
# ============================================================================
# TEST_0130_0133_run.sh -- disposable-PostgreSQL test runner for Phase 3A.
#
# Spins up a throwaway PostgreSQL 18 cluster, creates one database per TEST
# file, and runs TEST_0130..TEST_0133 (each bootstraps a faithful pre-0130
# schema, applies its migration chain, prints the POST_APPLY matrix, and runs
# behavior assertions). Fails (exit non-zero) if any TEST script errors OR if
# any POST_APPLY matrix row shows ok = f.
#
# Touches NOTHING outside a temp dir. Does not connect to Supabase / any real
# database. Requires: initdb, pg_ctl, psql, createdb on PATH (Homebrew
# postgresql@18 provides them).
#
# NOT included here (run separately -- each manages its own throwaway
# cluster with real wall-clock timing, unsuited to this script's single
# shared cluster): TEST_CONCURRENCY_0132_carrier_guard.sh (real two-session
# concurrency proof, correction #3).
#
# Usage:  cd "supabase" && ./TEST_0130_0133_run.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA="$(mktemp -d "${TMPDIR:-/tmp}/pg_phase3a.XXXXXX")"
PGPORT="${PGPORT:-54893}"
PGHOST=127.0.0.1
export PGHOST PGPORT
LOG="$PGDATA/server.log"

cleanup() {
  pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$PGDATA"
}
trap cleanup EXIT

echo "== initdb ($PGDATA) =="
LC_ALL=C LANG=C initdb -D "$PGDATA" -U postgres --auth=trust --no-locale --encoding=UTF8 >/dev/null

echo "== start server (port $PGPORT) =="
LC_ALL=C LANG=C pg_ctl -D "$PGDATA" -l "$LOG" \
  -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off" \
  -w start >/dev/null

export PGUSER=postgres
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -P pager=off -h "$PGHOST" -p "$PGPORT" -U postgres)

FAIL=0
n=0
# id | filename | db name | exact "PASSED" banner text the file echoes on success
tests=(
  "0130|TEST_0130_carrier_context_foundation.sql|t_0130|TEST 0130 PASSED"
  "0130rud|TEST_0130_RECORD_UNRESOLVED_DIRECT.sql|t_0130rud|TEST 0130 RECORD_UNRESOLVED DIRECT PASSED"
  "0131|TEST_0131_carrier_party_relationships.sql|t_0131|TEST 0131 PASSED"
  "0132|TEST_0132_load_carrier_and_trailer_scope.sql|t_0132|TEST 0132 PASSED"
  "0133|TEST_0133_deterministic_carrier_backfill.sql|t_0133|TEST 0133 PASSED"
  "0133rbtrig|TEST_0133_ROLLBACK_TRIGGER_SAFETY.sql|t_0133rbtrig|TEST 0133 ROLLBACK TRIGGER SAFETY PASSED"
  "0133race|TEST_0133_PREEXISTING_CARRIER_RACE.sql|t_0133race|TEST 0133 PREEXISTING CARRIER RACE PASSED"
  "0133hist|TEST_0133_HISTORICAL_CONFLICTS.sql|t_0133hist|TEST 0133 HISTORICAL CONFLICTS PASSED"
  "0133abort|TEST_0133_STRUCTURAL_ABORT_PREEXISTING_CONFLICT.sql|t_0133abort|TEST 0133 STRUCTURAL ABORT (PRE-EXISTING CONFLICT) PASSED"
  "adversarial|TEST_ADVERSARIAL_TRAILER_AND_DISPATCH.sql|t_adversarial|TEST ADVERSARIAL TRAILER AND DISPATCH PASSED"
  "0134|TEST_0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql|t_0134|TEST 0134 PASSED"
  "canceldedup|TEST_CANCELLATION_AUDIT_DEDUP.sql|t_canceldedup|TEST CANCELLATION AUDIT DEDUP PASSED"
  "0135|TEST_0135_dispatch_resource_reassignment_and_carrier_lockdown.sql|t_0135|TEST 0135 PASSED"
  "0136|TEST_0136_carrier_factoring_policy_and_relationship_columns.sql|t_0136|TEST 0136 PASSED"
  "0137|TEST_0137_deterministic_factoring_carrier_backfill.sql|t_0137|TEST 0137 PASSED"
  "0138|TEST_0138_carrier_default_cutover_classifier_and_secured_rpcs.sql|t_0138|TEST 0138 PASSED"
  "0139|TEST_0139_factoring_policy_safety_integrations_and_privilege_remediation.sql|t_0139|TEST 0139 PASSED"
  "0140|TEST_0140_factoring_authorization_and_submission_safety.sql|t_0140|TEST 0140 PASSED"
  "0141|TEST_0141_factoring_integration_lifecycle_integrity.sql|t_0141|TEST 0141 PASSED"
  "0142|TEST_0142_immutable_carrier_invoice_foundation.sql|t_0142|TEST 0142 PASSED"
  "0143|TEST_0143_canonical_financial_idempotency_hardening.sql|t_0143|TEST 0143 PASSED"
  "0144|TEST_0144_atomic_carrier_invoice_issuance.sql|t_0144|TEST 0144 PASSED"
  "backward|TEST_STATUS_MATRIX_BACKWARD_CORRECTIONS.sql|t_backward|TEST STATUS MATRIX BACKWARD CORRECTIONS PASSED"
  "0145|TEST_0145_carrier_dispatch_service_agreements_and_issuance.sql|t_0145|TEST 0145 PASSED"
  "0146|TEST_0146_carrier_invoice_payments_and_balance_rollups.sql|t_0146|TEST 0146 PASSED"
  "0147|TEST_0147_production_readiness_blocker_remediation.sql|t_0147|TEST 0147 PASSED"
)
for row in "${tests[@]}"; do
  IFS='|' read -r id f db banner <<<"$row"
  n=$((n+1))
  echo
  echo "=================  $f  ================="
  createdb -h "$PGHOST" -p "$PGPORT" -U postgres "$db"
  out="$PGDATA/$id.out"
  if "${PSQL[@]}" -d "$db" -f "$f" >"$out" 2>&1; then
    :
  else
    echo "  !! psql exited non-zero for $f"
    FAIL=1
  fi
  # gate: any POST_APPLY matrix row with ok = f  -> failure
  if grep -Eq '\|[[:space:]]*f[[:space:]]*$' "$out"; then
    echo "  !! a POST_APPLY matrix row shows ok = f in $f"
    grep -nE '\|[[:space:]]*f[[:space:]]*$' "$out" | sed 's/^/     /'
    FAIL=1
  fi
  # surface the notices / pass lines
  grep -E 'PASSED|OK: |SEED OK|NOTICE:.*(complete|PHASE|classification|ABORTED)' "$out" | sed 's/^/  /' || true
  if grep -qF "$banner" "$out"; then echo "  -> $f OK"; else echo "  !! $f did not reach '$banner'"; FAIL=1; fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ALL PHASE 3A DISPOSABLE-DB TESTS PASSED"
else
  echo "PHASE 3A DISPOSABLE-DB TESTS: FAILURES ABOVE"
fi
exit "$FAIL"
