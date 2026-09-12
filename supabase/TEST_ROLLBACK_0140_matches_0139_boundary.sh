#!/usr/bin/env bash
# ============================================================================
# TEST_ROLLBACK_0140_matches_0139_boundary.sh -- Phase 3B.1.6, Section E.
#
#   1. Apply through 0139.
#   2. Capture function definitions, signatures, grants, policies, comments
#      -- the "0139 boundary".
#   3. Apply 0140.
#   4. Run VERIFY_0140_POST_APPLY.
#   5. Run ROLLBACK_0140.
#   6. Compare the resulting catalog/function definitions to the captured
#      0139 boundary -- must match EXACTLY for everything 0140 touches,
#      EXCEPT approve_factoring_relationship_noa() (Section D's own,
#      explicit, verified exception -- asserted separately below).
#   7. Reapply 0140.
#   8. Run VERIFY_0140_POST_APPLY again.
#   9. Run the full TEST_0130_0133_run.sh suite.
#
# Usage: cd supabase && ./TEST_ROLLBACK_0140_matches_0139_boundary.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0140_rollback_boundary.XXXXXX")"
PGPORT="${PGPORT:-54910}"
PGHOST=127.0.0.1
LOG="$PGDATA_DIR/server.log"

cleanup() {
  pg_ctl -D "$PGDATA_DIR" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$PGDATA_DIR"
}
trap cleanup EXIT

echo "== initdb ($PGDATA_DIR) =="
LC_ALL=C LANG=C initdb -D "$PGDATA_DIR" -U postgres --auth=trust --no-locale --encoding=UTF8 >/dev/null

echo "== start server (port $PGPORT) =="
LC_ALL=C LANG=C pg_ctl -D "$PGDATA_DIR" -l "$LOG" \
  -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off" \
  -w start >/dev/null

export PGUSER=postgres PGHOST PGPORT
DB=factoring_0140_rollback_boundary_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")

capture_boundary() {
  local out="$1"
  "${PSQL[@]}" -tA -F'|' -c "
    select 'policy:factoring_companies:' || policyname || ':qual', qual from pg_policies where schemaname='public' and tablename='factoring_companies'
    union all
    select 'policy:factoring_companies:' || policyname || ':check', with_check from pg_policies where schemaname='public' and tablename='factoring_companies'
    union all
    select 'policy:factoring_relationships:' || policyname || ':qual', qual from pg_policies where schemaname='public' and tablename='factoring_relationships'
    union all
    select 'policy:factoring_relationships:' || policyname || ':check', with_check from pg_policies where schemaname='public' and tablename='factoring_relationships'
    order by 1;
  " > "$out.policies"
  "${PSQL[@]}" -tA -c "select pg_get_functiondef('public.submit_invoice_to_factor(uuid,uuid)'::regprocedure);" > "$out.submit_def" 2>/dev/null || echo "MISSING" > "$out.submit_def"
  "${PSQL[@]}" -tA -c "select coalesce(obj_description('public.submit_invoice_to_factor(uuid,uuid)'::regprocedure,'pg_proc'),'');" > "$out.submit_comment"
  "${PSQL[@]}" -tA -c "select has_function_privilege('authenticated','public.submit_invoice_to_factor(uuid,uuid)','EXECUTE');" > "$out.submit_grant"
  "${PSQL[@]}" -tA -c "select coalesce(obj_description('public.factoring_companies'::regclass,'pg_class'),'');" > "$out.companies_comment"
  "${PSQL[@]}" -tA -c "select coalesce(obj_description('public.factoring_relationships'::regclass,'pg_class'),'');" > "$out.relationships_comment"
}

echo "== 1/2. bootstrap through 0139, capture the 0139 boundary =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f TEST_SUPPORT_0136_0138_factoring_schema.sql >/dev/null
for m in 0130_carrier_context_foundation 0131_carrier_party_relationships 0132_load_carrier_and_trailer_scope \
         0133_deterministic_carrier_backfill 0134_dispatch_status_transition_and_trailer_privilege_hotfix \
         0135_dispatch_resource_reassignment_and_carrier_lockdown 0136_carrier_factoring_policy_and_relationship_columns \
         0137_deterministic_factoring_carrier_backfill 0138_carrier_default_cutover_classifier_and_secured_rpcs \
         0139_factoring_policy_safety_integrations_and_privilege_remediation; do
  "${PSQL[@]}" -f "migrations/$m.sql" >/dev/null
done
capture_boundary "$PGDATA_DIR/boundary_0139"
"${PSQL[@]}" -tA -c "select pg_get_functiondef('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)'::regprocedure);" > "$PGDATA_DIR/noa_0139_def" 2>/dev/null || echo "MISSING" > "$PGDATA_DIR/noa_0139_def"
echo "-- 0139 NOA def contains the KNOWN BUG shape (v_doc.file_name referenced unconditionally): --"
grep -c "v_doc.file_name" "$PGDATA_DIR/noa_0139_def" || true

echo "== 3. apply 0140 =="
"${PSQL[@]}" -f migrations/0140_factoring_authorization_and_submission_safety.sql >/dev/null

echo "== 4. VERIFY_0140_POST_APPLY =="
POST_APPLY_1="$("${PSQL[@]}" -f VERIFY_0140_POST_APPLY.sql)"
echo "$POST_APPLY_1"
if echo "$POST_APPLY_1" | grep -qi "| f$\| f *$"; then
  echo "!! FAIL: a VERIFY_0140_POST_APPLY row reported ok=f after applying 0140"; exit 1
fi

echo "== 5. ROLLBACK_0140 =="
"${PSQL[@]}" -f ROLLBACK_0140_factoring_authorization_and_submission_safety.sql

echo "== 6. compare post-rollback catalog to the captured 0139 boundary =="
capture_boundary "$PGDATA_DIR/after_rollback"
FAIL=0
for f in policies submit_def submit_comment submit_grant companies_comment relationships_comment; do
  if ! diff -q "$PGDATA_DIR/boundary_0139.$f" "$PGDATA_DIR/after_rollback.$f" >/dev/null; then
    echo "!! FAIL: $f differs from the 0139 boundary after rollback"
    diff "$PGDATA_DIR/boundary_0139.$f" "$PGDATA_DIR/after_rollback.$f" || true
    FAIL=1
  else
    echo "-> OK: $f matches the 0139 boundary exactly."
  fi
done

# approve_factoring_relationship_noa is the ONE explicit, documented
# exception (Section D) -- it must NOT match 0139's def (that would mean
# the bug fix was reverted), and it must still contain the fix.
"${PSQL[@]}" -tA -c "select pg_get_functiondef('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)'::regprocedure);" > "$PGDATA_DIR/noa_after_rollback_def"
if diff -q "$PGDATA_DIR/noa_0139_def" "$PGDATA_DIR/noa_after_rollback_def" >/dev/null; then
  echo "!! FAIL: approve_factoring_relationship_noa was reverted to 0139's exact (buggy) definition -- Section D requires the fix to survive this rollback."
  FAIL=1
elif ! grep -q "v_doc_snapshot_file_name" "$PGDATA_DIR/noa_after_rollback_def"; then
  echo "!! FAIL: approve_factoring_relationship_noa no longer contains the 0140 bug fix after rollback."
  FAIL=1
else
  echo "-> OK: approve_factoring_relationship_noa differs from 0139's definition (as required -- the fix is NOT reverted) and still contains the fix, exactly as Section D documents."
fi

if [ "$FAIL" -ne 0 ]; then
  echo "TEST ROLLBACK 0140 MATCHES 0139 BOUNDARY: FAILURES ABOVE"
  exit 1
fi

echo "== 7. reapply 0140 =="
"${PSQL[@]}" -f migrations/0140_factoring_authorization_and_submission_safety.sql >/dev/null

echo "== 8. VERIFY_0140_POST_APPLY (again, after reapply) =="
POST_APPLY_2="$("${PSQL[@]}" -f VERIFY_0140_POST_APPLY.sql)"
echo "$POST_APPLY_2"
if echo "$POST_APPLY_2" | grep -qi "| f$\| f *$"; then
  echo "!! FAIL: a VERIFY_0140_POST_APPLY row reported ok=f after reapplying 0140"; exit 1
fi

echo "== 9. full disposable-DB suite (fresh cluster, via TEST_0130_0133_run.sh) =="
pg_ctl -D "$PGDATA_DIR" -m immediate stop >/dev/null 2>&1 || true
./TEST_0130_0133_run.sh

echo
echo "TEST ROLLBACK 0140 MATCHES 0139 BOUNDARY: PASSED"
