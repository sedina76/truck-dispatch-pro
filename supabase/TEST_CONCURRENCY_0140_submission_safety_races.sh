#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0140_submission_safety_races.sh -- Phase 3B.1.5, Section
# D: REAL two-session concurrency proof for ALL EIGHT required scenarios.
# Every scenario below uses genuine separate PostgreSQL sessions (background
# psql processes), never a sequential simulation.
#
# Phase 3B.1.5 changed submit_invoice_to_factor() to an UNCONDITIONAL
# structured rejection ({success:false, code:'CARRIER_INVOICE_SNAPSHOT_
# REQUIRED'}) for every legacy invoice -- it no longer reads carriers,
# factoring_relationships (beyond none), or carrier_factoring_integrations
# at all. Scenarios 3-6 below (default/policy/NOA/integration changes
# "racing" a submission) are therefore proven UNREACHABLE AS RACES: this
# script demonstrates that explicitly, with two real sessions each time,
# rather than simply omitting them -- showing the configuration mutation
# completes independently and the submission's rejection is identical and
# timing-independent, because the submission function no longer takes any
# lock or touches any row those mutations could ever contend with.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0140_submission_safety_races.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0140_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54908}"
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
  -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off -c deadlock_timeout=500ms" \
  -w start >/dev/null

export PGUSER=postgres PGHOST PGPORT
DB=factoring_0140_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")

echo "== bootstrap: seed + support schema + 0130-0140 =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f TEST_SUPPORT_0136_0138_factoring_schema.sql >/dev/null
"${PSQL[@]}" -f migrations/0130_carrier_context_foundation.sql >/dev/null
"${PSQL[@]}" -f migrations/0131_carrier_party_relationships.sql >/dev/null
"${PSQL[@]}" -f migrations/0132_load_carrier_and_trailer_scope.sql >/dev/null
"${PSQL[@]}" -f migrations/0133_deterministic_carrier_backfill.sql >/dev/null
"${PSQL[@]}" -f migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql >/dev/null
"${PSQL[@]}" -f migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql >/dev/null
"${PSQL[@]}" -f migrations/0136_carrier_factoring_policy_and_relationship_columns.sql >/dev/null
"${PSQL[@]}" -f migrations/0137_deterministic_factoring_carrier_backfill.sql >/dev/null
"${PSQL[@]}" -f migrations/0138_carrier_default_cutover_classifier_and_secured_rpcs.sql >/dev/null
"${PSQL[@]}" -f migrations/0139_factoring_policy_safety_integrations_and_privilege_remediation.sql >/dev/null
"${PSQL[@]}" -f migrations/0140_factoring_authorization_and_submission_safety.sql >/dev/null

"${PSQL[@]}" -c "
insert into public.factoring_companies (id, organization_id, name, is_active) values
  ('fc0c0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor S1', true);
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active) values
  ('fe0c0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc0c0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire A', 'NOA A', 'v1',
   current_date, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true, true),
  ('fe0c0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'fc0c0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 85, 4, 12, 'deducted_at_funding', 'non_recourse', 'Wire A2', 'NOA A2', 'v1',
   current_date, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', false, true);
update public.carriers set factoring_mode = 'factored' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
insert into public.invoices (id, organization_id, dispatch_id, invoice_number, status, total_amount, amount_paid) values
  ('9c0c0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'd1d10000-0000-0000-0000-000000000001', 'INV-S1', 'sent', 1000, 0);
"

FAIL=0
PGDATA_TMP="$PGDATA_DIR"
REJECTED_JSON='"success": false'

assert_rejected() {
  local file="$1"
  grep -q "$REJECTED_JSON" "$file" && grep -q "CARRIER_INVOICE_SNAPSHOT_REQUIRED" "$file"
}

# =========================== SCENARIO 1 ====================================
# Same invoice, same relationship id ("same idempotency key" -- this
# function has no separate idempotency-key parameter; the invoice id itself
# is the natural dedup key, serialized by its own advisory lock).
echo
echo "=================  SCENARIO 1: same invoice, same relationship id, two concurrent sessions  ================="
cat > "$PGDATA_TMP/s1a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.2);
select public.submit_invoice_to_factor('9c0c0000-0000-0000-0000-000000000001', 'fe0c0000-0000-0000-0000-000000000001') as result;
EOF
cp "$PGDATA_TMP/s1a.sql" "$PGDATA_TMP/s1b.sql"
"${PSQL[@]}" -f "$PGDATA_TMP/s1a.sql" > "$PGDATA_TMP/s1a.out" 2>&1 &
P1A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s1b.sql" > "$PGDATA_TMP/s1b.out" 2>&1 &
P1B=$!
set +e; wait "$P1A"; E1A=$?; wait "$P1B"; E1B=$?; set -e
echo "S1-A exit=$E1A  S1-B exit=$E1B"
if grep -qi "deadlock" "$PGDATA_TMP/s1a.out" "$PGDATA_TMP/s1b.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif [ "$E1A" -ne 0 ] || [ "$E1B" -ne 0 ]; then
  echo "!! FAIL: unexpected error"; cat "$PGDATA_TMP/s1a.out" "$PGDATA_TMP/s1b.out"; FAIL=1
elif ! assert_rejected "$PGDATA_TMP/s1a.out" || ! assert_rejected "$PGDATA_TMP/s1b.out"; then
  echo "!! FAIL: both sessions must get the structured rejection"; cat "$PGDATA_TMP/s1a.out" "$PGDATA_TMP/s1b.out"; FAIL=1
else
  N_ROWS="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.factored_invoices where invoice_id='9c0c0000-0000-0000-0000-000000000001'")"
  if [ "$N_ROWS" != "0" ]; then echo "!! FAIL: expected 0 rows, got $N_ROWS"; FAIL=1
  else echo "-> OK: both concurrent attempts on the same invoice serialize on the invoice advisory lock and both get the identical deterministic structured rejection; zero rows created, no deadlock."
  fi
fi

# =========================== SCENARIO 2 ====================================
# Same invoice, DIFFERENT relationship ids -- proves the outcome is
# identical regardless, since p_relationship_id is never consulted.
echo
echo "=================  SCENARIO 2: same invoice, DIFFERENT relationship ids, two concurrent sessions  ================="
cat > "$PGDATA_TMP/s2a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.15);
select public.submit_invoice_to_factor('9c0c0000-0000-0000-0000-000000000001', 'fe0c0000-0000-0000-0000-000000000001') as result;
EOF
cat > "$PGDATA_TMP/s2b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.15);
select public.submit_invoice_to_factor('9c0c0000-0000-0000-0000-000000000001', 'fe0c0000-0000-0000-0000-000000000002') as result;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s2a.sql" > "$PGDATA_TMP/s2a.out" 2>&1 &
P2A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s2b.sql" > "$PGDATA_TMP/s2b.out" 2>&1 &
P2B=$!
set +e; wait "$P2A"; E2A=$?; wait "$P2B"; E2B=$?; set -e
if grep -qi "deadlock" "$PGDATA_TMP/s2a.out" "$PGDATA_TMP/s2b.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif ! assert_rejected "$PGDATA_TMP/s2a.out" || ! assert_rejected "$PGDATA_TMP/s2b.out"; then
  echo "!! FAIL: both must be rejected regardless of relationship id"; FAIL=1
else
  echo "-> OK: two concurrent attempts with DIFFERENT relationship ids both get the identical rejection -- the relationship id is never reached/consulted, no deadlock."
fi

# =========================== SCENARIOS 3-6 ====================================
# Configuration-mutation "races" -- proven UNREACHABLE AS RACES with real
# two-session pairs: submit_invoice_to_factor() no longer takes any lock or
# reads any row these mutations touch, so each pair runs concurrently with
# ZERO interaction -- no blocking, no deadlock, both sides succeed/reject
# exactly as they would in isolation, independent of timing.
run_unreachable_pair() {
  local label="$1" config_sql="$2" expect_success_key="$3"
  echo
  echo "=================  $label  ================="
  cat > "$PGDATA_TMP/subm.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.15);
select public.submit_invoice_to_factor('9c0c0000-0000-0000-0000-000000000001', 'fe0c0000-0000-0000-0000-000000000001') as result;
EOF
  printf '%s\n' "$config_sql" > "$PGDATA_TMP/cfg.sql"
  "${PSQL[@]}" -f "$PGDATA_TMP/subm.sql" > "$PGDATA_TMP/subm.out" 2>&1 &
  PA=$!
  "${PSQL[@]}" -f "$PGDATA_TMP/cfg.sql" > "$PGDATA_TMP/cfg.out" 2>&1 &
  PB=$!
  set +e; wait "$PA"; EA=$?; wait "$PB"; EB=$?; set -e
  echo "submission exit=$EA  config-mutation exit=$EB"
  if grep -qi "deadlock" "$PGDATA_TMP/subm.out" "$PGDATA_TMP/cfg.out"; then
    echo "!! FAIL: deadlock -- submission must never contend with configuration mutations any more"; FAIL=1
  elif ! assert_rejected "$PGDATA_TMP/subm.out"; then
    echo "!! FAIL: submission did not get the structured rejection"; cat "$PGDATA_TMP/subm.out"; FAIL=1
  elif [ "$EB" -ne 0 ] || ! grep -q "$expect_success_key" "$PGDATA_TMP/cfg.out"; then
    echo "!! FAIL: the concurrent configuration mutation did not complete normally"; cat "$PGDATA_TMP/cfg.out"; FAIL=1
  else
    echo "-> OK: proven unreachable as a race -- the configuration mutation completed independently and successfully; the submission's rejection was identical and timing-independent; no lock contention, no deadlock."
  fi
}

# 3: default factor change for the SAME carrier the submission's (rejected,
# unused) relationship belongs to.
run_unreachable_pair "SCENARIO 3: default-relationship change racing a (structurally-blocked) submission" \
'\set ON_ERROR_STOP on
select set_config('"'"'test.current_uid'"'"', '"'"'aaaa0000-0000-0000-0000-000000000001'"'"', false);
set role authenticated;
select public.set_default_factoring_relationship('"'"'fe0c0000-0000-0000-0000-000000000002'"'"') as result;' \
'"success": true'

# reset default back for the next scenarios
"${PSQL[@]}" -c "
update public.factoring_relationships set is_default=false where id='fe0c0000-0000-0000-0000-000000000002';
update public.factoring_relationships set is_default=true where id='fe0c0000-0000-0000-0000-000000000001';
"

# 4: carrier policy change (factored -> direct) for the same carrier.
UPDATED_AT="$("${PSQL[@]}" -tA -c "select updated_at from public.carriers where id='a1a1a1a1-0000-0000-0000-000000000001'")"
run_unreachable_pair "SCENARIO 4: carrier policy change (factored -> direct) racing a (structurally-blocked) submission" \
"\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'race test', '$UPDATED_AT'::timestamptz, null) as result;" \
'"success": true'

# restore factored for the next scenarios
"${PSQL[@]}" -c "update public.carriers set factoring_mode='factored' where id='a1a1a1a1-0000-0000-0000-000000000001';"

# 5: NOA approval change for the relationship.
run_unreachable_pair "SCENARIO 5: NOA approval change racing a (structurally-blocked) submission" \
'\set ON_ERROR_STOP on
select set_config('"'"'test.current_uid'"'"', '"'"'aaaa0000-0000-0000-0000-000000000001'"'"', false);
set role authenticated;
select public.approve_factoring_relationship_noa('"'"'fe0c0000-0000-0000-0000-000000000001'"'"', '"'"'v2'"'"', current_date, '"'"'updated NOA text'"'"') as result;' \
'"success": true'

# 6: API integration configuration change (insert a new carrier_factoring_integrations row).
run_unreachable_pair "SCENARIO 6: API integration configuration change racing a (structurally-blocked) submission" \
"\\set ON_ERROR_STOP on
insert into public.carrier_factoring_integrations
  (organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, secret_reference, configuration_status, is_active, approved_by, approved_at)
values
  ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'fe0c0000-0000-0000-0000-000000000001',
   'fc0c0000-0000-0000-0000-000000000001', 'api', 'vault://race-test-0140', 'active', true, 'aaaa0000-0000-0000-0000-000000000001', now())
returning jsonb_build_object('success', true) as result;" \
'"success": true'

# =========================== SCENARIO 7 ====================================
# Cross-carrier relationship tampering: two concurrent sessions each try to
# submit the SAME org-A invoice using a relationship id that does NOT
# belong to its carrier (one uses org-B's own relationship id shape, one
# uses a syntactically valid but nonexistent id) -- neither must ever
# reveal anything about the other carrier's data; both get the identical,
# uninformative structured rejection.
echo
echo "=================  SCENARIO 7: concurrent cross-carrier relationship-id tampering attempts  ================="
"${PSQL[@]}" -c "
insert into public.factoring_companies (id, organization_id, name, is_active) values
  ('fc0c0000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Factor Org B', true);
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, is_default, is_active) values
  ('fe0c0000-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'fc0c0000-0000-0000-0000-000000000002',
   'b1b1b1b1-0000-0000-0000-000000000001', 90, 3, 10, 'deducted_at_funding', 'non_recourse', true, true);
"
cat > "$PGDATA_TMP/s7a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.submit_invoice_to_factor('9c0c0000-0000-0000-0000-000000000001', 'fe0c0000-0000-0000-0000-00000000000b') as result;
EOF
cat > "$PGDATA_TMP/s7b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.submit_invoice_to_factor('9c0c0000-0000-0000-0000-000000000001', 'ffffffff-ffff-ffff-ffff-ffffffffffff') as result;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s7a.sql" > "$PGDATA_TMP/s7a.out" 2>&1 &
P7A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s7b.sql" > "$PGDATA_TMP/s7b.out" 2>&1 &
P7B=$!
set +e; wait "$P7A"; E7A=$?; wait "$P7B"; E7B=$?; set -e
if grep -qi "deadlock" "$PGDATA_TMP/s7a.out" "$PGDATA_TMP/s7b.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif ! assert_rejected "$PGDATA_TMP/s7a.out" || ! assert_rejected "$PGDATA_TMP/s7b.out"; then
  echo "!! FAIL: both tampering attempts must get the same generic rejection"; cat "$PGDATA_TMP/s7a.out" "$PGDATA_TMP/s7b.out"; FAIL=1
elif grep -qi "Wire\|NOA\|Org B\|Factor Org B" "$PGDATA_TMP/s7a.out" "$PGDATA_TMP/s7b.out"; then
  echo "!! FAIL: a cross-carrier tampering attempt leaked protected data about another carrier/org"; FAIL=1
else
  echo "-> OK: both cross-carrier tampering attempts (org B's own relationship id, and a nonexistent id) get the identical generic structured rejection, with no protected data from another carrier/organization ever revealed -- no deadlock."
fi

# =========================== SCENARIO 8 ====================================
# Lock timeout followed by retry: session A holds the invoice's advisory
# lock open (inside an explicit transaction) while session B attempts a
# submission for the SAME invoice with a short statement_timeout -- B must
# time out waiting on the lock (not deadlock, not silently proceed), and a
# RETRY after A releases the lock must return the same deterministic
# structured rejection.
echo
echo "=================  SCENARIO 8: lock held open, concurrent attempt times out, then a clean retry  ================="
cat > "$PGDATA_TMP/s8a.sql" <<'EOF'
\set ON_ERROR_STOP on
begin;
select pg_advisory_xact_lock(hashtext('factoring_submission:9c0c0000-0000-0000-0000-000000000001'));
select pg_sleep(1.2);
commit;
EOF
cat > "$PGDATA_TMP/s8b.sql" <<'EOF'
\set ON_ERROR_STOP on
set statement_timeout = '400ms';
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.submit_invoice_to_factor('9c0c0000-0000-0000-0000-000000000001', 'fe0c0000-0000-0000-0000-000000000001') as result;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s8a.sql" > "$PGDATA_TMP/s8a.out" 2>&1 &
P8A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s8b.sql" > "$PGDATA_TMP/s8b.out" 2>&1 &
P8B=$!
set +e; wait "$P8A"; E8A=$?; wait "$P8B"; E8B=$?; set -e
echo "S8-A(holder) exit=$E8A  S8-B(waiter, 400ms timeout) exit=$E8B"
if [ "$E8B" -eq 0 ]; then
  echo "!! FAIL: the waiting session should have timed out (statement_timeout), not completed"; cat "$PGDATA_TMP/s8b.out"; FAIL=1
elif ! grep -qi "statement timeout" "$PGDATA_TMP/s8b.out"; then
  echo "!! FAIL: expected a statement_timeout error while waiting on the held lock"; cat "$PGDATA_TMP/s8b.out"; FAIL=1
else
  echo "S8-B correctly timed out waiting on the lock held by S8-A. Retrying now that S8-A has released it..."
  cat > "$PGDATA_TMP/s8retry.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.submit_invoice_to_factor('9c0c0000-0000-0000-0000-000000000001', 'fe0c0000-0000-0000-0000-000000000001') as result;
EOF
  "${PSQL[@]}" -f "$PGDATA_TMP/s8retry.sql" > "$PGDATA_TMP/s8retry.out" 2>&1
  if ! assert_rejected "$PGDATA_TMP/s8retry.out"; then
    echo "!! FAIL: the retry after the lock was released did not return the deterministic structured rejection"; cat "$PGDATA_TMP/s8retry.out"; FAIL=1
  else
    N_ROWS="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.factored_invoices where invoice_id='9c0c0000-0000-0000-0000-000000000001'")"
    if [ "$N_ROWS" != "0" ]; then echo "!! FAIL: expected 0 rows after the whole timeout/retry sequence, got $N_ROWS"; FAIL=1
    else echo "-> OK: the timed-out attempt produced no partial effect, and the retry -- once the lock was free -- returned the same deterministic structured rejection. No double effect, no corruption."
    fi
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "TEST CONCURRENCY 0140 SUBMISSION SAFETY RACES PASSED (all 8 scenarios)"
else
  echo "TEST CONCURRENCY 0140 SUBMISSION SAFETY RACES: FAILURES ABOVE"
fi
exit "$FAIL"
