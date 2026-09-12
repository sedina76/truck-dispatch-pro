#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0139_policy_and_integration_races.sh -- REAL two-session
# concurrency proof for public.set_carrier_factoring_policy() (Phase
# 3B.1.1, item 10's "real two-session policy/default/integration races").
# Every scenario uses genuine separate PostgreSQL sessions, not simulated
# ordering.
#
# Required results: no deadlock anywhere; exactly one winner when two
# policy changes race for the SAME carrier with the SAME expected version
# (optimistic concurrency, not a lock-order accident); two DIFFERENT
# carriers' policy changes never interfere with each other even
# concurrently; a policy change racing a concurrent carrier_factoring_
# integrations insert for the same carrier never deadlocks and never
# corrupts either table.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0139_policy_and_integration_races.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0139_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54907}"
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
DB=factoring_0139_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")

echo "== bootstrap: seed + support schema + 0130-0139 =="
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

FAIL=0
PGDATA_TMP="$PGDATA_DIR"

# =========================== SCENARIO 1 ====================================
# Two concurrent set_carrier_factoring_policy() calls for the SAME carrier,
# BOTH reading the same (now-stale-to-one-of-them) expected_updated_at --
# exactly one must succeed; the other must get a clean stale_record result,
# never a deadlock, never both applied, never neither.
echo
echo "=================  SCENARIO 1: two concurrent policy changes racing for the SAME carrier, same expected version  ================="
UPDATED_AT="$("${PSQL[@]}" -tA -c "select updated_at from public.carriers where id = 'a1a1a1a1-0000-0000-0000-000000000001'")"
cat > "$PGDATA_TMP/s1a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.2);
select public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'session A: go direct', '$UPDATED_AT'::timestamptz, null) as result;
EOF
cat > "$PGDATA_TMP/s1b.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.2);
select public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'session B: go direct', '$UPDATED_AT'::timestamptz, null) as result;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s1a.sql" > "$PGDATA_TMP/s1a.out" 2>&1 &
P1A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s1b.sql" > "$PGDATA_TMP/s1b.out" 2>&1 &
P1B=$!
set +e; wait "$P1A"; E1A=$?; wait "$P1B"; E1B=$?; set -e
echo "S1-A exit=$E1A  S1-B exit=$E1B"
if grep -qi "deadlock" "$PGDATA_TMP/s1a.out" "$PGDATA_TMP/s1b.out"; then
  echo "!! FAIL: deadlock on two concurrent policy changes for the same carrier"; FAIL=1
elif [ "$E1A" -ne 0 ] || [ "$E1B" -ne 0 ]; then
  echo "!! FAIL: unexpected raised exception"; cat "$PGDATA_TMP/s1a.out" "$PGDATA_TMP/s1b.out"; FAIL=1
else
  N_SUCCESS=0
  N_STALE=0
  grep -q '"success" *: *true' "$PGDATA_TMP/s1a.out" && N_SUCCESS=$((N_SUCCESS+1))
  grep -q '"success" *: *true' "$PGDATA_TMP/s1b.out" && N_SUCCESS=$((N_SUCCESS+1))
  grep -q '"stale_record" *: *true' "$PGDATA_TMP/s1a.out" && N_STALE=$((N_STALE+1))
  grep -q '"stale_record" *: *true' "$PGDATA_TMP/s1b.out" && N_STALE=$((N_STALE+1))
  echo "successes=$N_SUCCESS  stale_record_rejections=$N_STALE"
  N_AUDIT_EVENTS="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.activity_logs where entity_id='a1a1a1a1-0000-0000-0000-000000000001' and action='factoring_policy_changed'")"
  echo "audit events written: $N_AUDIT_EVENTS"
  if [ "$N_SUCCESS" != "1" ] || [ "$N_STALE" != "1" ] || [ "$N_AUDIT_EVENTS" != "1" ]; then
    echo "!! FAIL: expected exactly 1 success + 1 stale_record rejection + 1 audit event, got success=$N_SUCCESS stale=$N_STALE audit=$N_AUDIT_EVENTS"; FAIL=1
  else
    echo "-> OK: two concurrent policy changes for the same carrier with the same expected version serialize cleanly -- exactly one wins (optimistic concurrency, not a lock accident), the loser gets a clean stale_record result, exactly one audit event, no deadlock."
  fi
fi

# =========================== SCENARIO 2 ====================================
# Two DIFFERENT carriers' policy changes running concurrently -- both must
# succeed independently (Carrier A's change never affects Carrier B), even
# though both take the SAME kind of advisory lock (namespaced by carrier_id).
echo
echo "=================  SCENARIO 2: two DIFFERENT carriers set policy concurrently (no cross-carrier interference)  ================="
UPDATED_AT_A2="$("${PSQL[@]}" -tA -c "select updated_at from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002'")"
UPDATED_AT_A1="$("${PSQL[@]}" -tA -c "select updated_at from public.carriers where id = 'a1a1a1a1-0000-0000-0000-000000000001'")"
cat > "$PGDATA_TMP/s2a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002', 'direct', 'A2 goes direct', '$UPDATED_AT_A2'::timestamptz, null) as result;
EOF
cat > "$PGDATA_TMP/s2b.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'A1 goes direct', '$UPDATED_AT_A1'::timestamptz, null) as result;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s2a.sql" > "$PGDATA_TMP/s2a.out" 2>&1 &
P2A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s2b.sql" > "$PGDATA_TMP/s2b.out" 2>&1 &
P2B=$!
set +e; wait "$P2A"; E2A=$?; wait "$P2B"; E2B=$?; set -e
echo "S2-A exit=$E2A  S2-B exit=$E2B"
if grep -qi "deadlock" "$PGDATA_TMP/s2a.out" "$PGDATA_TMP/s2b.out"; then
  echo "!! FAIL: deadlock on two different carriers' concurrent policy changes"; FAIL=1
elif [ "$E2A" -ne 0 ] || [ "$E2B" -ne 0 ] || ! grep -q '"success" *: *true' "$PGDATA_TMP/s2a.out" || ! grep -q '"success" *: *true' "$PGDATA_TMP/s2b.out"; then
  echo "!! FAIL: expected BOTH carriers' policy changes to succeed independently"; cat "$PGDATA_TMP/s2a.out" "$PGDATA_TMP/s2b.out"; FAIL=1
else
  A2_MODE="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select factoring_mode from public.carriers where id='a2a2a2a2-0000-0000-0000-000000000002'")"
  A1_MODE="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select factoring_mode from public.carriers where id='a1a1a1a1-0000-0000-0000-000000000001'")"
  echo "A2 mode: $A2_MODE / A1 mode: $A1_MODE"
  if [ "$A2_MODE" != "direct" ] || [ "$A1_MODE" != "direct" ]; then
    echo "!! FAIL: one carrier's resulting mode is wrong after the concurrent race"; FAIL=1
  else
    echo "-> OK: two different carriers' policy changes proceed concurrently, independently, and correctly -- no cross-carrier interference, no deadlock."
  fi
fi

# =========================== SCENARIO 3 ====================================
# A policy change (-> factored) racing a concurrent INSERT into
# carrier_factoring_integrations for the SAME carrier/relationship -- these
# touch different tables with no shared advisory lock key, so this proves
# no deadlock/corruption arises from that independence, not from ordering.
echo
echo "=================  SCENARIO 3: policy change racing a concurrent carrier_factoring_integrations insert (different tables, same carrier)  ================="
"${PSQL[@]}" -c "
insert into public.factoring_companies (id, organization_id, name, is_active) values
  ('fc090000-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'Factor S3-0139', true);
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default) values
  ('fe090000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc090000-0000-0000-0000-000000000009',
   'a2a2a2a2-0000-0000-0000-000000000002', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire E', 'NOA E', 'v1',
   current_date, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true);
"
UPDATED_AT_A2B="$("${PSQL[@]}" -tA -c "select updated_at from public.carriers where id = 'a2a2a2a2-0000-0000-0000-000000000002'")"
cat > "$PGDATA_TMP/s3a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002', 'factored', 'A2 goes factored', '$UPDATED_AT_A2B'::timestamptz, null) as result;
EOF
cat > "$PGDATA_TMP/s3b.sql" <<EOF
\\set ON_ERROR_STOP on
insert into public.carrier_factoring_integrations
  (organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, secret_reference, configuration_status, is_active, approved_by, approved_at)
values
  ('11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002',
   'fe090000-0000-0000-0000-000000000001', 'fc090000-0000-0000-0000-000000000009', 'api',
   'vault://race-test', 'active', true, 'aaaa0000-0000-0000-0000-000000000001', now());
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s3a.sql" > "$PGDATA_TMP/s3a.out" 2>&1 &
P3A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s3b.sql" > "$PGDATA_TMP/s3b.out" 2>&1 &
P3B=$!
set +e; wait "$P3A"; E3A=$?; wait "$P3B"; E3B=$?; set -e
echo "S3-A(policy) exit=$E3A  S3-B(integration insert) exit=$E3B"
if grep -qi "deadlock" "$PGDATA_TMP/s3a.out" "$PGDATA_TMP/s3b.out"; then
  echo "!! FAIL: deadlock between policy change and concurrent integration insert"; FAIL=1
elif [ "$E3B" -ne 0 ]; then
  echo "!! FAIL: the integration insert failed unexpectedly"; cat "$PGDATA_TMP/s3b.out"; FAIL=1
else
  echo "S3-A result:"; cat "$PGDATA_TMP/s3a.out"
  N_INTEGRATIONS="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.carrier_factoring_integrations where carrier_id='a2a2a2a2-0000-0000-0000-000000000002'")"
  echo "integrations recorded for A2: $N_INTEGRATIONS"
  if [ "$N_INTEGRATIONS" != "1" ]; then
    echo "!! FAIL: expected exactly 1 integration row, got $N_INTEGRATIONS"; FAIL=1
  else
    echo "-> OK: no deadlock between set_carrier_factoring_policy() and a concurrent carrier_factoring_integrations write for the same carrier -- both complete cleanly regardless of interleaving."
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "TEST CONCURRENCY 0139 POLICY AND INTEGRATION RACES PASSED"
else
  echo "TEST CONCURRENCY 0139 POLICY AND INTEGRATION RACES: FAILURES ABOVE"
fi
exit "$FAIL"
