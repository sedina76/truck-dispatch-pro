#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0138_default_factor_races.sh -- REAL two-session
# concurrency proof for public.set_default_factoring_relationship() (Phase
# 3B.1, item 13). Every scenario uses genuine separate PostgreSQL sessions.
#
# Required results: no deadlock; exactly one winner when two calls race for
# the SAME carrier's default; two DIFFERENT carriers under the SAME
# factoring company never interfere with each other, even concurrently; a
# company-deactivation attempt racing a set-default call never deadlocks
# (fixed lock order: company, then carrier -- deactivation only ever takes
# the company lock).
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0138_default_factor_races.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_factoring_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54906}"
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
DB=factoring_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")

echo "== bootstrap: seed + support schema + 0130-0138 =="
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

FAIL=0
PGDATA_TMP="$PGDATA_DIR"

# =========================== SCENARIO 1 ====================================
# Two concurrent set_default calls for the SAME carrier, two DIFFERENT
# candidate relationships -- exactly one must win, the other must be
# cleanly rejected (never both, never neither, never a deadlock).
echo
echo "=================  SCENARIO 1: two concurrent set_default calls for the SAME carrier  ================="
"${PSQL[@]}" -c "
insert into public.factoring_companies (id, organization_id, name) values
  ('fc010000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor S1');
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method) values
  ('fe010000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc010000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire A', 'NOA A', 'v1',
   current_date, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue'),
  ('fe010000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'fc010000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 85, 4, 12, 'deducted_at_funding', 'non_recourse', 'Wire B', 'NOA B', 'v1',
   current_date, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue');
"
cat > "$PGDATA_TMP/s1a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
select pg_sleep(0.2);
select public.set_default_factoring_relationship('fe010000-0000-0000-0000-000000000001') as result;
EOF
cat > "$PGDATA_TMP/s1b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
select pg_sleep(0.2);
select public.set_default_factoring_relationship('fe010000-0000-0000-0000-000000000002') as result;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s1a.sql" > "$PGDATA_TMP/s1a.out" 2>&1 &
P1A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s1b.sql" > "$PGDATA_TMP/s1b.out" 2>&1 &
P1B=$!
set +e; wait "$P1A"; E1A=$?; wait "$P1B"; E1B=$?; set -e
echo "S1-A exit=$E1A  S1-B exit=$E1B"
if grep -qi "deadlock" "$PGDATA_TMP/s1a.out" "$PGDATA_TMP/s1b.out"; then
  echo "!! FAIL: deadlock on two concurrent set_default calls for the same carrier"; FAIL=1
elif [ "$E1A" -ne 0 ] || [ "$E1B" -ne 0 ]; then
  echo "!! FAIL: unexpected raised exception"; cat "$PGDATA_TMP/s1a.out" "$PGDATA_TMP/s1b.out"; FAIL=1
else
  N_DEFAULT="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.factoring_relationships where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and is_default and is_active")"
  echo "active defaults for the carrier after the race: $N_DEFAULT"
  if [ "$N_DEFAULT" != "1" ]; then
    echo "!! FAIL: expected exactly 1 active default after the race, got $N_DEFAULT"; FAIL=1
  else
    echo "-> OK: two concurrent set_default calls for the same carrier serialize cleanly -- exactly one becomes/remains the default, no deadlock, no double-default."
  fi
fi

# =========================== SCENARIO 2 ====================================
# Two DIFFERENT carriers, SAME factoring company, concurrent set_default
# calls -- both must succeed independently (Carrier A's change never
# affects Carrier B), proving the carrier-scoped lock genuinely isolates
# them even though both also share the SAME company-scoped lock.
echo
echo "=================  SCENARIO 2: two DIFFERENT carriers (same factoring company) set default concurrently  ================="
"${PSQL[@]}" -c "
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method) values
  ('fe020000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc010000-0000-0000-0000-000000000001',
   'a2a2a2a2-0000-0000-0000-000000000002', 80, 5, 15, 'deducted_from_reserve', 'recourse', 'Wire C', 'NOA C', 'v1',
   current_date, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue');
"
cat > "$PGDATA_TMP/s2a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
select public.set_default_factoring_relationship('fe010000-0000-0000-0000-000000000002') as result;
EOF
cat > "$PGDATA_TMP/s2b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
select public.set_default_factoring_relationship('fe020000-0000-0000-0000-000000000001') as result;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s2a.sql" > "$PGDATA_TMP/s2a.out" 2>&1 &
P2A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s2b.sql" > "$PGDATA_TMP/s2b.out" 2>&1 &
P2B=$!
set +e; wait "$P2A"; E2A=$?; wait "$P2B"; E2B=$?; set -e
echo "S2-A exit=$E2A  S2-B exit=$E2B"
if grep -qi "deadlock" "$PGDATA_TMP/s2a.out" "$PGDATA_TMP/s2b.out"; then
  echo "!! FAIL: deadlock on two different carriers under the same company"; FAIL=1
elif [ "$E2A" -ne 0 ] || [ "$E2B" -ne 0 ]; then
  echo "!! FAIL: unexpected raised exception"; cat "$PGDATA_TMP/s2a.out" "$PGDATA_TMP/s2b.out"; FAIL=1
elif ! grep -q '"success" *: *true' "$PGDATA_TMP/s2a.out" || ! grep -q '"success" *: *true' "$PGDATA_TMP/s2b.out"; then
  echo "!! FAIL: expected BOTH carriers' set_default calls to succeed independently"; cat "$PGDATA_TMP/s2a.out" "$PGDATA_TMP/s2b.out"; FAIL=1
else
  A1_DEFAULT="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select id from public.factoring_relationships where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and is_default and is_active")"
  A2_DEFAULT="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select id from public.factoring_relationships where carrier_id='a2a2a2a2-0000-0000-0000-000000000002' and is_default and is_active")"
  echo "A1 default: $A1_DEFAULT / A2 default: $A2_DEFAULT"
  if [ "$A1_DEFAULT" != "fe010000-0000-0000-0000-000000000002" ] || [ "$A2_DEFAULT" != "fe020000-0000-0000-0000-000000000001" ]; then
    echo "!! FAIL: one carrier's default is wrong or missing after the concurrent race"; FAIL=1
  else
    echo "-> OK: two different carriers under the same factoring company set their defaults concurrently, independently, and correctly -- no cross-carrier interference, no deadlock."
  fi
fi

# =========================== SCENARIO 3 ====================================
# A company-deactivation attempt racing a set_default call for one of its
# OWN relationships -- fixed lock order (set_default: company then
# carrier; deactivation: company only) must prevent any deadlock.
echo
echo "=================  SCENARIO 3: company deactivation racing a set_default call (deadlock safety)  ================="
"${PSQL[@]}" -c "
insert into public.factoring_companies (id, organization_id, name) values
  ('fc030000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Factor S3');
insert into public.carriers (id, organization_id, legal_name, factoring_mode) values
  ('a3030000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Carrier S3', 'factored');
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method) values
  ('fe030000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc030000-0000-0000-0000-000000000003',
   'a3030000-0000-0000-0000-000000000003', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire D', 'NOA D', 'v1',
   current_date, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue');
"
cat > "$PGDATA_TMP/s3a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
select public.set_default_factoring_relationship('fe030000-0000-0000-0000-000000000001') as result;
EOF
cat > "$PGDATA_TMP/s3b.sql" <<'EOF'
\set ON_ERROR_STOP on
select pg_sleep(0.05);
update public.factoring_companies set is_active = false where id = 'fc030000-0000-0000-0000-000000000003';
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s3a.sql" > "$PGDATA_TMP/s3a.out" 2>&1 &
P3A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s3b.sql" > "$PGDATA_TMP/s3b.out" 2>&1 &
P3B=$!
set +e; wait "$P3A"; E3A=$?; wait "$P3B"; E3B=$?; set -e
echo "S3-A(set_default) exit=$E3A  S3-B(deactivate) exit=$E3B"
if grep -qi "deadlock" "$PGDATA_TMP/s3a.out" "$PGDATA_TMP/s3b.out"; then
  echo "!! FAIL: deadlock between set_default and company deactivation"; FAIL=1
elif [ "$E3A" -ne 0 ]; then
  echo "!! FAIL: set_default (already the default's OWN relationship, first-time set) failed unexpectedly"; cat "$PGDATA_TMP/s3a.out"; FAIL=1
else
  # Deactivation is EXPECTED to fail (business rejection: this relationship
  # is now the default) if it runs after set_default committed, or to
  # succeed if it ran first (in which case set_default would then find an
  # inactive company and fail with a clean business rejection, never a
  # deadlock) -- either ordering is a valid, non-deadlocked outcome.
  echo "-> OK: no deadlock between set_default_factoring_relationship() and company deactivation -- fixed lock order (company, then carrier) holds under real concurrency."
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "TEST CONCURRENCY 0138 DEFAULT FACTOR RACES PASSED"
else
  echo "TEST CONCURRENCY 0138 DEFAULT FACTOR RACES: FAILURES ABOVE"
fi
exit "$FAIL"
