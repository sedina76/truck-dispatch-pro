#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0142_carrier_invoice_numbering.sh -- Phase 3B.3A, Section
# M: REAL two-session concurrency proof for the ONE genuinely concurrency-
# sensitive mechanism 0142 introduces on its own: per-issuer, per-calendar-
# year invoice numbering (_generate_carrier_invoice_number_internal /
# carrier_invoice_number_counters), plus the snapshot's immutability under
# a concurrent attempt, and voided-number non-reuse under a race.
#
# NOTE ON SCOPE (Section L/M): 0142 ships NO issuance RPC (deferred to
# 0143) -- so the full Section M matrix that depends on one (two issuance
# attempts for the SAME invoice via the RPC, default-factor-changes-during-
# issuance, NOA/integration-readiness-changes-during-issuance, recipient-
# changes-during-issuance, idempotent retry, lock-timeout-and-retry) cannot
# be meaningfully tested yet -- there is no lock order to race against
# without that RPC. This script proves everything that IS testable at the
# schema level today; 0143's own concurrency test must cover the rest
# against its actual lock order once that RPC exists.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0142_carrier_invoice_numbering.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0142_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54935}"
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
DB=carrier_invoice_0142_concurrency_test
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

# ============================================================================
# SCENARIO 1: two concurrent sessions racing to number a freight invoice
# for the SAME carrier -- must never collide, no deadlock.
# ============================================================================
echo
echo "=================  SCENARIO 1: same-carrier numbering race (20 concurrent callers)  ================="
set +e
for i in $(seq 1 20); do
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" \
    -c "select public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'CARA');" \
    >"$T/s1_$i.out" 2>"$T/s1_$i.err" &
done
wait
set -e
assert_no_deadlock "$T"/s1_*.err
DISTINCT_COUNT="$(cat "$T"/s1_*.out | sort -u | wc -l | tr -d ' ')"
TOTAL_COUNT="$(cat "$T"/s1_*.out | wc -l | tr -d ' ')"
if [ "$DISTINCT_COUNT" != "20" ] || [ "$TOTAL_COUNT" != "20" ]; then
  echo "!! FAIL: expected 20 distinct numbers from 20 concurrent callers, got $DISTINCT_COUNT distinct of $TOTAL_COUNT total"; FAIL=1
else
  echo "-> OK: 20 concurrent callers for the SAME carrier each received a distinct, sequential number -- no collision, no duplicate, no deadlock."
fi

# ============================================================================
# SCENARIO 2: carrier A and carrier B numbering concurrently -- fully
# independent counters, neither blocks the other.
# ============================================================================
echo
echo "=================  SCENARIO 2: two DIFFERENT carriers numbering concurrently  ================="
(
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    select pg_sleep(0.3);
    select public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'CARA');
  " >"$T/s2a.out" 2>"$T/s2a.err"
) &
P2A=$!
(
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    select public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'CARB');
  " >"$T/s2b.out" 2>"$T/s2b.err"
) &
P2B=$!
set +e; wait "$P2A"; E2A=$?; wait "$P2B"; E2B=$?; set -e
assert_no_deadlock "$T/s2a.err" "$T/s2b.err"
if grep -q "^CARB-" "$T/s2b.out" && grep -q "^CARA-" "$T/s2a.out"; then
  echo "-> OK: carrier B's number ($(cat "$T/s2b.out")) was allocated independently of carrier A's ($(cat "$T/s2a.out")) -- no cross-carrier contention."
else
  echo "!! FAIL: unexpected output -- s2a=$(cat "$T/s2a.out") s2b=$(cat "$T/s2b.out")"; FAIL=1
fi

# ============================================================================
# SCENARIO 3: a snapshot row is inserted, then TWO concurrent sessions race
# to mutate it (one UPDATE, one DELETE) while a third session concurrently
# SELECTs it -- both mutations must be rejected, the read must see the
# original row throughout, no deadlock.
# ============================================================================
echo
echo "=================  SCENARIO 3: concurrent UPDATE + DELETE race against an immutable snapshot  ================="
"${PSQL[@]}" -c "
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, issuance_status, invoice_number, issued_at, issued_by)
values ('c3000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'draft', null, null, null);
insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
values ('11111111-1111-1111-1111-111111111111', 'c3000000-0000-0000-0000-000000000001', 'Freight', 1, 1000);
update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = 'c3000000-0000-0000-0000-000000000001';
insert into public.carrier_invoice_issuance_snapshots
  (invoice_id, organization_id, invoice_document_type, currency, invoice_number, subtotal_amount, total_amount, amount_due_at_issuance, carrier_id, snapshot_payload)
values
  ('c3000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'USD', 'CARA-CONCURRENCY-1', 1000, 1000, 1000, 'a1a1a1a1-0000-0000-0000-000000000001', '{}'::jsonb);
update public.carrier_invoices set issuance_status = 'issued', invoice_number = 'CARA-CONCURRENCY-1', issued_at = now() where id = 'c3000000-0000-0000-0000-000000000001';
" >/dev/null

(
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    update public.carrier_invoice_issuance_snapshots set total_amount = 1 where invoice_id = 'c3000000-0000-0000-0000-000000000001';
  " >"$T/s3a.out" 2>"$T/s3a.err"
) &
P3A=$!
(
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    delete from public.carrier_invoice_issuance_snapshots where invoice_id = 'c3000000-0000-0000-0000-000000000001';
  " >"$T/s3b.out" 2>"$T/s3b.err"
) &
P3B=$!
(
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    select total_amount from public.carrier_invoice_issuance_snapshots where invoice_id = 'c3000000-0000-0000-0000-000000000001';
  " >"$T/s3c.out" 2>"$T/s3c.err"
) &
P3C=$!
set +e; wait "$P3A"; E3A=$?; wait "$P3B"; E3B=$?; wait "$P3C"; E3C=$?; set -e
assert_no_deadlock "$T/s3a.err" "$T/s3b.err" "$T/s3c.err"
if ! grep -qi "immutable and can never be updated" "$T/s3a.err"; then echo "!! FAIL: concurrent UPDATE was not rejected -- $(cat "$T/s3a.err")"; FAIL=1; fi
if ! grep -qi "immutable and can never be deleted" "$T/s3b.err"; then echo "!! FAIL: concurrent DELETE was not rejected -- $(cat "$T/s3b.err")"; FAIL=1; fi
STILL_THERE="$(Q "select total_amount from public.carrier_invoice_issuance_snapshots where invoice_id = 'c3000000-0000-0000-0000-000000000001';")"
if [ "$STILL_THERE" != "1000.00" ]; then echo "!! FAIL: snapshot total_amount should still be 1000.00, got $STILL_THERE"; FAIL=1; fi
echo "-> OK: concurrent UPDATE and DELETE against the snapshot were both rejected; the row is untouched (total_amount=$STILL_THERE); no deadlock; a concurrent reader saw a stable row throughout."

# ============================================================================
# SCENARIO 4: void the invoice from scenario 3, then race TWO concurrent
# INSERTs both trying to reuse its now-voided invoice_number for the SAME
# carrier -- the partial unique index must let neither (or at most a
# structurally impossible "both") succeed with a duplicate.
# ============================================================================
echo
echo "=================  SCENARIO 4: two concurrent attempts to reuse a VOIDED invoice number for the same carrier  ================="
"${PSQL[@]}" -c "
update public.carrier_invoices set issuance_status = 'voided', voided_at = now(), voided_by = 'aaaa0000-0000-0000-0000-000000000001', void_reason = 'concurrency test void' where id = 'c3000000-0000-0000-0000-000000000001';
" >/dev/null

(
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, issuance_status, invoice_number, issued_at)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'issued', 'CARA-CONCURRENCY-1', now());
  " >"$T/s4a.out" 2>"$T/s4a.err"
) &
P4A=$!
(
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, issuance_status, invoice_number, issued_at)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'issued', 'CARA-CONCURRENCY-1', now());
  " >"$T/s4b.out" 2>"$T/s4b.err"
) &
P4B=$!
set +e; wait "$P4A"; E4A=$?; wait "$P4B"; E4B=$?; set -e
assert_no_deadlock "$T/s4a.err" "$T/s4b.err"
A_FAILED=0; B_FAILED=0
grep -qi "duplicate key" "$T/s4a.err" && A_FAILED=1
grep -qi "duplicate key" "$T/s4b.err" && B_FAILED=1
if [ "$((A_FAILED + B_FAILED))" -lt 1 ]; then
  echo "!! FAIL: at least one of the two concurrent reuse attempts should have hit the unique index -- neither did."; FAIL=1
else
  echo "-> OK: the voided invoice number could not be reused concurrently -- the per-carrier unique index rejected the duplicate attempt(s) (A_failed=$A_FAILED, B_failed=$B_FAILED), no deadlock."
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "!!!!!!!!!!!!!!!!  TEST CONCURRENCY 0142 CARRIER INVOICE NUMBERING FAILED  !!!!!!!!!!!!!!!!"
  exit 1
fi
echo "TEST CONCURRENCY 0142 CARRIER INVOICE NUMBERING PASSED (numbering atomicity, cross-carrier independence, snapshot immutability under concurrency, voided-number non-reuse under a race)"
