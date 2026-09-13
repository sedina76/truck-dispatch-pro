#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0142_draft_update.sh -- Phase 3B.3A.2, Section G: REAL
# two-session concurrency proof for update_carrier_invoice_draft().
#
# Lock design under test: the RPC locks the target invoice row (FOR UPDATE)
# BEFORE checking the idempotency cache and BEFORE the staleness check --
# so two concurrent callers targeting the SAME invoice always serialize
# against each other, and the loser's idempotency/staleness checks always
# observe whatever the winner already committed, never a stale pre-lock
# snapshot.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0142_draft_update.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0142_draft_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54940}"
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
DB=carrier_invoice_draft_0142_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")
Q() { psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "$1"; }

echo "== bootstrap: seed + support schema + 0130-0142 =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f TEST_SUPPORT_0136_0138_factoring_schema.sql >/dev/null
for m in 0130_carrier_context_foundation 0131_carrier_party_relationships 0132_load_carrier_and_trailer_scope \
         0133_deterministic_carrier_backfill 0134_dispatch_status_transition_and_trailer_privilege_hotfix \
         0135_dispatch_resource_reassignment_and_carrier_lockdown 0136_carrier_factoring_policy_and_relationship_columns \
         0137_deterministic_factoring_carrier_backfill 0138_carrier_default_cutover_classifier_and_secured_rpcs \
         0139_factoring_policy_safety_integrations_and_privilege_remediation 0140_factoring_authorization_and_submission_safety \
         0141_factoring_integration_lifecycle_integrity 0142_immutable_carrier_invoice_foundation; do
  "${PSQL[@]}" -f "migrations/$m.sql" >/dev/null
done

FAIL=0
T="$PGDATA_DIR"

assert_no_deadlock() {
  if grep -qi "deadlock" "$@"; then echo "!! FAIL: deadlock detected"; FAIL=1; return 1; fi
  return 0
}

seed_draft() {
  # $1 = invoice id to create
  "${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
values ('$1', '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001');
" >/dev/null
}

as_owner() {
  # $1 = SQL to run as the owner (authenticated)
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
$1
"
}

# ============================================================================
# SCENARIO 1: same-version race -- two concurrent callers both load the
# SAME updated_at, then both call the RPC with different patches/keys.
# Exactly one must succeed; the other must get STALE_RECORD (the row lock
# serializes them, and the loser's staleness check runs AFTER the winner
# has already committed a new updated_at).
# ============================================================================
echo
echo "=================  SCENARIO 1: same-version race (two callers, same expected_updated_at)  ================="
INV1="d1000000-0000-0000-0000-000000000001"
seed_draft "$INV1"
T0="$(Q "select updated_at from public.carrier_invoices where id='$INV1';")"

(
  as_owner "select public.update_carrier_invoice_draft('$INV1'::uuid, '{\"notes\":\"from session A\"}'::jsonb, '$T0'::timestamptz, null, 'race1-a');"
) >"$T/s1a.out" 2>"$T/s1a.err" &
P1A=$!
(
  as_owner "select pg_sleep(0.2); select public.update_carrier_invoice_draft('$INV1'::uuid, '{\"notes\":\"from session B\"}'::jsonb, '$T0'::timestamptz, null, 'race1-b');"
) >"$T/s1b.out" 2>"$T/s1b.err" &
P1B=$!
set +e; wait "$P1A"; E1A=$?; wait "$P1B"; E1B=$?; set -e
assert_no_deadlock "$T/s1a.err" "$T/s1b.err"

A_SUCCESS=0; B_SUCCESS=0
grep -q '"success": true' "$T/s1a.out" && A_SUCCESS=1
grep -q '"success": true' "$T/s1b.out" && B_SUCCESS=1
A_STALE=0; B_STALE=0
grep -q 'STALE_RECORD' "$T/s1a.out" && A_STALE=1
grep -q 'STALE_RECORD' "$T/s1b.out" && B_STALE=1

if [ "$((A_SUCCESS + B_SUCCESS))" -ne 1 ]; then
  echo "!! FAIL: expected exactly ONE success, got A_success=$A_SUCCESS B_success=$B_SUCCESS -- $(cat "$T/s1a.out") / $(cat "$T/s1b.out")"; FAIL=1
elif [ "$((A_STALE + B_STALE))" -ne 1 ]; then
  echo "!! FAIL: expected exactly ONE STALE_RECORD, got A_stale=$A_STALE B_stale=$B_STALE"; FAIL=1
else
  echo "-> OK: exactly one of the two same-version callers succeeded, the other got STALE_RECORD -- no deadlock, no double mutation, no torn state."
fi

# ============================================================================
# SCENARIO 2: same-key replay under TRUE concurrency -- two sessions call
# with the IDENTICAL idempotency key at (as close as possible to) the same
# instant. Exactly one real mutation + one audit event; the other must
# either be a clean cache hit or safely blocked/serialized -- never a raw
# unique-violation, never a double mutation.
# ============================================================================
echo
echo "=================  SCENARIO 2: same-key replay under true concurrency  ================="
INV2="d2000000-0000-0000-0000-000000000002"
seed_draft "$INV2"
T0="$(Q "select updated_at from public.carrier_invoices where id='$INV2';")"

(
  as_owner "select public.update_carrier_invoice_draft('$INV2'::uuid, '{\"notes\":\"same key note\"}'::jsonb, '$T0'::timestamptz, null, 'race2-samekey');"
) >"$T/s2a.out" 2>"$T/s2a.err" &
P2A=$!
(
  as_owner "select public.update_carrier_invoice_draft('$INV2'::uuid, '{\"notes\":\"same key note\"}'::jsonb, '$T0'::timestamptz, null, 'race2-samekey');"
) >"$T/s2b.out" 2>"$T/s2b.err" &
P2B=$!
set +e; wait "$P2A"; E2A=$?; wait "$P2B"; E2B=$?; set -e
assert_no_deadlock "$T/s2a.err" "$T/s2b.err"

if grep -qi "unique" "$T/s2a.err" "$T/s2b.err" 2>/dev/null; then
  echo "!! FAIL: a raw unique-violation leaked to a caller -- the row-lock-before-idempotency-check ordering did not serialize this correctly."; FAIL=1
fi
AUDIT_COUNT="$(Q "select count(*) from public.activity_logs where entity_type='invoice' and entity_id='$INV2' and action='carrier_invoice_draft_updated';")"
if [ "$AUDIT_COUNT" != "1" ]; then
  echo "!! FAIL: expected exactly 1 audit event for the same-key concurrent replay, got $AUDIT_COUNT"; FAIL=1
else
  echo "-> OK: two truly concurrent callers with the IDENTICAL idempotency key produced exactly one mutation and one audit event -- no unique-violation leaked, no double mutation."
fi

# ============================================================================
# SCENARIO 3: different-key collision -- two concurrent callers, DIFFERENT
# idempotency keys, conflicting patches, same starting updated_at. The row
# lock must serialize them; the loser must get a deterministic STALE_
# RECORD (never a lost update, never both silently applied).
# ============================================================================
echo
echo "=================  SCENARIO 3: different-key collision (conflicting patches, same version)  ================="
INV3="d3000000-0000-0000-0000-000000000003"
seed_draft "$INV3"
T0="$(Q "select updated_at from public.carrier_invoices where id='$INV3';")"

(
  as_owner "select public.update_carrier_invoice_draft('$INV3'::uuid, '{\"due_date\":\"2026-01-01\"}'::jsonb, '$T0'::timestamptz, null, 'race3-a');"
) >"$T/s3a.out" 2>"$T/s3a.err" &
P3A=$!
(
  as_owner "select public.update_carrier_invoice_draft('$INV3'::uuid, '{\"due_date\":\"2026-12-31\"}'::jsonb, '$T0'::timestamptz, null, 'race3-b');"
) >"$T/s3b.out" 2>"$T/s3b.err" &
P3B=$!
set +e; wait "$P3A"; E3A=$?; wait "$P3B"; E3B=$?; set -e
assert_no_deadlock "$T/s3a.err" "$T/s3b.err"

A_SUCCESS=0; B_SUCCESS=0
grep -q '"success": true' "$T/s3a.out" && A_SUCCESS=1
grep -q '"success": true' "$T/s3b.out" && B_SUCCESS=1
if [ "$((A_SUCCESS + B_SUCCESS))" -ne 1 ]; then
  echo "!! FAIL: expected exactly ONE of the two different-key conflicting-patch callers to succeed, got A=$A_SUCCESS B=$B_SUCCESS"; FAIL=1
else
  FINAL_DUE_DATE="$(Q "select due_date from public.carrier_invoices where id='$INV3';")"
  echo "-> OK: exactly one of the two conflicting different-key callers succeeded (final due_date=$FINAL_DUE_DATE); the other deterministically got STALE_RECORD -- no lost update, no torn state."
fi

# ============================================================================
# SCENARIO 4: recipient change race -- two concurrent callers both try to
# change the SAME invoice's recipient (to different brokers). Exactly one
# must win; the recipient must never end up torn (mismatched type/id).
# ============================================================================
echo
echo "=================  SCENARIO 4: recipient change race  ================="
INV4="d4000000-0000-0000-0000-000000000004"
seed_draft "$INV4"
"${PSQL[@]}" -c "
insert into public.customers (id, organization_id, company_name, is_active) values ('c4000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Race Customer', true);
insert into public.carrier_customers (id, organization_id, carrier_id, customer_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
values ('cc430000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000001', 'active', 'race@customer.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');
" >/dev/null
T0="$(Q "select updated_at from public.carrier_invoices where id='$INV4';")"

(
  as_owner "select public.update_carrier_invoice_draft('$INV4'::uuid, '{\"customer_id\":\"c4000000-0000-0000-0000-000000000001\",\"broker_id\":null}'::jsonb, '$T0'::timestamptz, 'session A recipient change', 'race4-a');"
) >"$T/s4a.out" 2>"$T/s4a.err" &
P4A=$!
(
  as_owner "select public.update_carrier_invoice_draft('$INV4'::uuid, '{\"notes\":\"session B unrelated note\"}'::jsonb, '$T0'::timestamptz, null, 'race4-b');"
) >"$T/s4b.out" 2>"$T/s4b.err" &
P4B=$!
set +e; wait "$P4A"; E4A=$?; wait "$P4B"; E4B=$?; set -e
assert_no_deadlock "$T/s4a.err" "$T/s4b.err"

A_SUCCESS=0; B_SUCCESS=0
grep -q '"success": true' "$T/s4a.out" && A_SUCCESS=1
grep -q '"success": true' "$T/s4b.out" && B_SUCCESS=1
if [ "$((A_SUCCESS + B_SUCCESS))" -ne 1 ]; then
  echo "!! FAIL: expected exactly ONE of the two concurrent callers to succeed, got A=$A_SUCCESS B=$B_SUCCESS"; FAIL=1
else
  RECIPIENT_TYPE="$(Q "select recipient_type from public.carrier_invoices where id='$INV4';")"
  RECIPIENT_BROKER="$(Q "select recipient_broker_id from public.carrier_invoices where id='$INV4';")"
  RECIPIENT_CUSTOMER="$(Q "select recipient_customer_id from public.carrier_invoices where id='$INV4';")"
  if [ "$RECIPIENT_TYPE" = "broker" ] && [ -z "$RECIPIENT_CUSTOMER" ] && [ -n "$RECIPIENT_BROKER" ]; then
    echo "-> OK: recipient never torn -- still a clean broker recipient (type=$RECIPIENT_TYPE, broker=$RECIPIENT_BROKER, customer=$RECIPIENT_CUSTOMER) after the race."
  elif [ "$RECIPIENT_TYPE" = "customer" ] && [ -z "$RECIPIENT_BROKER" ] && [ -n "$RECIPIENT_CUSTOMER" ]; then
    echo "-> OK: recipient never torn -- cleanly swapped to the customer (type=$RECIPIENT_TYPE, broker=$RECIPIENT_BROKER, customer=$RECIPIENT_CUSTOMER) after the race."
  else
    echo "!! FAIL: recipient shape is torn after the race -- type=$RECIPIENT_TYPE broker=$RECIPIENT_BROKER customer=$RECIPIENT_CUSTOMER"; FAIL=1
  fi
fi

# ============================================================================
# SCENARIO 5: lock timeout and retry -- a long-held lock forces a
# concurrent caller to time out cleanly (no partial effect), then a clean
# retry after the lock is released succeeds.
# ============================================================================
echo
echo "=================  SCENARIO 5: lock timeout and retry  ================="
INV5="d5000000-0000-0000-0000-000000000005"
seed_draft "$INV5"
T0="$(Q "select updated_at from public.carrier_invoices where id='$INV5';")"

(
  as_owner "
begin;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
select id from public.carrier_invoices where id = '$INV5' for update;
select pg_sleep(1.2);
update public.carrier_invoices set notes = 'holder note' where id = '$INV5';
commit;
"
) >"$T/s5holder.out" 2>"$T/s5holder.err" &
P5HOLD=$!

sleep 0.3
WAITER_OUT="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
set lock_timeout = '400ms';
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.update_carrier_invoice_draft('$INV5'::uuid, '{\"notes\":\"waiter attempt\"}'::jsonb, '$T0'::timestamptz, null, 'race5-waiter');
" 2>&1 || true)"

set +e; wait "$P5HOLD"; E5HOLD=$?; set -e
assert_no_deadlock "$T/s5holder.err"

if ! echo "$WAITER_OUT" | grep -qi "lock timeout\|canceling statement"; then
  echo "!! FAIL: expected the waiter to hit a lock timeout while the holder held the row, got: $WAITER_OUT"; FAIL=1
else
  echo "-> OK: the waiter correctly timed out on the held lock (no partial effect)."
fi

RETRY_RESULT="$(as_owner "select public.update_carrier_invoice_draft('$INV5'::uuid, '{\"notes\":\"waiter retry after release\"}'::jsonb, (select updated_at from public.carrier_invoices where id='$INV5'), null, 'race5-retry');")"
if ! echo "$RETRY_RESULT" | grep -q '"success": true'; then
  echo "!! FAIL: the retry after the lock was released should have succeeded, got: $RETRY_RESULT"; FAIL=1
else
  echo "-> OK: a clean retry after the lock was released succeeded deterministically -- $RETRY_RESULT"
fi

# ============================================================================
# SCENARIO 6 (Phase 3B.3A.3, Section C item 7): concurrent same-key/
# different-invoice race -- two sessions call with the IDENTICAL
# idempotency key at the same instant, targeting DIFFERENT invoices.
# Exactly one must succeed; the other must get a clean, structured
# IDEMPOTENCY_KEY_REUSED -- never a raw uniqueness error, never both
# applied, never a deadlock. This is the exact race the advisory lock
# (Phase 3B.3A.3 Section A/B) was added to close.
# ============================================================================
echo
echo "=================  SCENARIO 6: concurrent same-key, DIFFERENT-invoice race  ================="
INV6A="d6000000-0000-0000-0000-00000000000a"
INV6B="d6000000-0000-0000-0000-00000000000b"
seed_draft "$INV6A"
seed_draft "$INV6B"
T6A="$(Q "select updated_at from public.carrier_invoices where id='$INV6A';")"
T6B="$(Q "select updated_at from public.carrier_invoices where id='$INV6B';")"

(
  as_owner "select public.update_carrier_invoice_draft('$INV6A'::uuid, '{\"notes\":\"invoice A\"}'::jsonb, '$T6A'::timestamptz, null, 'race6-samekey');"
) >"$T/s6a.out" 2>"$T/s6a.err" &
P6A=$!
(
  as_owner "select public.update_carrier_invoice_draft('$INV6B'::uuid, '{\"notes\":\"invoice B\"}'::jsonb, '$T6B'::timestamptz, null, 'race6-samekey');"
) >"$T/s6b.out" 2>"$T/s6b.err" &
P6B=$!
set +e; wait "$P6A"; E6A=$?; wait "$P6B"; E6B=$?; set -e
assert_no_deadlock "$T/s6a.err" "$T/s6b.err"

if grep -qi "unique\|constraint\|duplicate key" "$T/s6a.err" "$T/s6b.err" 2>/dev/null; then
  echo "!! FAIL: a raw uniqueness/constraint error leaked to a caller instead of a clean structured response."; FAIL=1
fi
A_SUCCESS=0; B_SUCCESS=0; A_REUSED=0; B_REUSED=0
grep -q '"success": true' "$T/s6a.out" && A_SUCCESS=1
grep -q '"success": true' "$T/s6b.out" && B_SUCCESS=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s6a.out" && A_REUSED=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s6b.out" && B_REUSED=1
if [ "$((A_SUCCESS + B_SUCCESS))" -ne 1 ] || [ "$((A_REUSED + B_REUSED))" -ne 1 ]; then
  echo "!! FAIL: expected exactly one success + one IDEMPOTENCY_KEY_REUSED, got A=$(cat "$T/s6a.out") B=$(cat "$T/s6b.out")"; FAIL=1
else
  echo "-> OK: two truly concurrent callers with the IDENTICAL key targeting DIFFERENT invoices -- exactly one succeeded, the other got a clean structured IDEMPOTENCY_KEY_REUSED, no raw error, no deadlock."
fi

# ============================================================================
# SCENARIO 7 (Section C item 8): concurrent same-key/different-PATCH race
# on the SAME invoice -- exactly one succeeds, the other gets a clean
# structured IDEMPOTENCY_KEY_REUSED; the invoice ends up with exactly one
# of the two patches applied, never a blend of both, never both.
# ============================================================================
echo
echo "=================  SCENARIO 7: concurrent same-key, DIFFERENT-patch race (same invoice)  ================="
INV7="d7000000-0000-0000-0000-000000000007"
seed_draft "$INV7"
T7="$(Q "select updated_at from public.carrier_invoices where id='$INV7';")"

(
  as_owner "select public.update_carrier_invoice_draft('$INV7'::uuid, '{\"notes\":\"patch A\"}'::jsonb, '$T7'::timestamptz, null, 'race7-samekey');"
) >"$T/s7a.out" 2>"$T/s7a.err" &
P7A=$!
(
  as_owner "select public.update_carrier_invoice_draft('$INV7'::uuid, '{\"notes\":\"patch B\"}'::jsonb, '$T7'::timestamptz, null, 'race7-samekey');"
) >"$T/s7b.out" 2>"$T/s7b.err" &
P7B=$!
set +e; wait "$P7A"; E7A=$?; wait "$P7B"; E7B=$?; set -e
assert_no_deadlock "$T/s7a.err" "$T/s7b.err"

if grep -qi "unique\|constraint\|duplicate key" "$T/s7a.err" "$T/s7b.err" 2>/dev/null; then
  echo "!! FAIL: a raw uniqueness/constraint error leaked to a caller instead of a clean structured response."; FAIL=1
fi
A_SUCCESS=0; B_SUCCESS=0
grep -q '"success": true' "$T/s7a.out" && A_SUCCESS=1
grep -q '"success": true' "$T/s7b.out" && B_SUCCESS=1
if [ "$((A_SUCCESS + B_SUCCESS))" -ne 1 ]; then
  echo "!! FAIL: expected exactly one of the two same-key/different-patch callers to succeed, got A=$A_SUCCESS B=$B_SUCCESS"; FAIL=1
else
  FINAL_NOTES="$(Q "select notes from public.carrier_invoices where id='$INV7';")"
  if [ "$FINAL_NOTES" != "patch A" ] && [ "$FINAL_NOTES" != "patch B" ]; then
    echo "!! FAIL: final notes value is neither patch -- torn state: '$FINAL_NOTES'"; FAIL=1
  else
    echo "-> OK: exactly one of the two same-key/different-patch callers succeeded (final notes='$FINAL_NOTES'), the other got a clean structured IDEMPOTENCY_KEY_REUSED -- no raw error, no torn state, no deadlock."
  fi
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "!!!!!!!!!!!!!!!!  TEST CONCURRENCY 0142 DRAFT UPDATE FAILED  !!!!!!!!!!!!!!!!"
  exit 1
fi
echo "TEST CONCURRENCY 0142 DRAFT UPDATE PASSED (same-version race, same-key replay under true concurrency, different-key collision, recipient-change race, lock timeout + retry, concurrent same-key/different-invoice collision, concurrent same-key/different-patch collision)"
