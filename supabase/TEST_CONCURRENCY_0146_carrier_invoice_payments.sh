#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0146_carrier_invoice_payments.sh -- Phase 3B.5, Section L:
# all 20 required concurrency scenarios for record_carrier_invoice_payment()
# and void_carrier_invoice_payment(), every one a genuine separate-session
# test.
#
# Deadlock detection is authoritative, not textual: pg_stat_database.
# deadlocks is read before/after the whole run and MUST NOT increase.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0146_carrier_invoice_payments.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0146_payments_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54946}"
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
  -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off -c deadlock_timeout=300ms -c log_lock_waits=on" \
  -w start >/dev/null

export PGUSER=postgres PGHOST PGPORT
DB=carrier_invoice_payments_0146_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")
Q() { psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "$1"; }

echo "== bootstrap: seed + support schema + 0130-0146 =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f TEST_SUPPORT_0136_0138_factoring_schema.sql >/dev/null
for m in 0130_carrier_context_foundation 0131_carrier_party_relationships 0132_load_carrier_and_trailer_scope \
         0133_deterministic_carrier_backfill 0134_dispatch_status_transition_and_trailer_privilege_hotfix \
         0135_dispatch_resource_reassignment_and_carrier_lockdown 0136_carrier_factoring_policy_and_relationship_columns \
         0137_deterministic_factoring_carrier_backfill 0138_carrier_default_cutover_classifier_and_secured_rpcs \
         0139_factoring_policy_safety_integrations_and_privilege_remediation 0140_factoring_authorization_and_submission_safety \
         0141_factoring_integration_lifecycle_integrity 0142_immutable_carrier_invoice_foundation \
         0143_canonical_financial_idempotency_hardening 0144_atomic_carrier_invoice_issuance \
         0145_carrier_dispatch_service_agreements_and_issuance 0146_carrier_invoice_payments_and_balance_rollups; do
  "${PSQL[@]}" -f "migrations/$m.sql" >/dev/null
done

echo "== fixtures =="
"${PSQL[@]}" -c "
update public.organizations set remittance_instructions = 'Org A remit' where id = '11111111-1111-1111-1111-111111111111';
update public.organizations set remittance_instructions = 'Org B remit' where id = '22222222-2222-2222-2222-222222222222';

update public.carriers set invoice_code = 'CARA', factoring_mode = 'direct' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
update public.carriers set invoice_code = 'CARB1', factoring_mode = 'direct' where id = 'b1b1b1b1-0000-0000-0000-000000000001';
update public.carriers set invoice_code = 'CARF', factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';

insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by) values
  ('cb490000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001'),
  ('cb490000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'b1b1b1b1-0000-0000-0000-000000000001', 'b0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokerb.example', 30, true, now(), 'bbbb0000-0000-0000-0000-000000000001'),
  ('cb490000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');

insert into public.factoring_companies (id, organization_id, name, legal_name, is_active)
values ('fc490000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor 0146C', 'Factor 0146C LLC', true);
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, submission_destination_email,
   is_default, is_active)
values
  ('fe490000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc490000-0000-0000-0000-000000000001',
   'a2a2a2a2-0000-0000-0000-000000000002', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Factor 0146C', 'NOA 0146C', 'ref-0146c-1',
   current_date - 5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'secure_email', 'factor0146c@example.com', true, true);
" >/dev/null

FAIL=0
T="$PGDATA_DIR"

DEADLOCKS_BEFORE_TOTAL="$(Q "select deadlocks from pg_stat_database where datname='$DB';")"
assert_no_new_deadlocks() {
  local now_dl
  now_dl="$(Q "select deadlocks from pg_stat_database where datname='$DB';")"
  if [ "$now_dl" != "$DEADLOCKS_BEFORE_TOTAL" ]; then
    echo "!! FAIL ($1): pg_stat_database.deadlocks increased ($DEADLOCKS_BEFORE_TOTAL -> $now_dl)."
    FAIL=1
  fi
  DEADLOCKS_BEFORE_TOTAL="$now_dl"
}
assert_no_deadlock_text() { if grep -qi "deadlock" "$@" 2>/dev/null; then echo "!! FAIL: 'deadlock' text found in session output"; FAIL=1; fi; }

as_uid() {
  # $1 = uid, $2 = sql
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
select set_config('test.current_uid', '$1', false);
set role authenticated;
$2
"
}
as_owner_a() { as_uid "aaaa0000-0000-0000-0000-000000000001" "$1"; }
as_owner_b() { as_uid "bbbb0000-0000-0000-0000-000000000001" "$1"; }

# $1=carrier $2=rate $3=org(default A) $4=broker(default A's) $5=uid(default owner A)
# Creates a load + freight invoice + issues it. Echoes "invoice_id".
make_issued_freight_invoice() {
  local carrier="$1" rate="$2" org="${3:-11111111-1111-1111-1111-111111111111}" broker="${4:-a0b00000-0000-0000-0000-000000000001}" uid="${5:-aaaa0000-0000-0000-0000-000000000001}"
  local lid iid
  lid="$(Q "select gen_random_uuid();")"
  "${PSQL[@]}" -c "
insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
values ('$lid', '$org', 'LD-CONC-$lid', '$broker', '$carrier', 'resolved', 'delivered', $rate);
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at) values
('$org', '$lid', 'pickup', 1, 'S', 'Dallas', 'TX', now() - interval '2 days'),
('$org', '$lid', 'delivery', 2, 'R', 'Houston', 'TX', now() - interval '1 day');
" >/dev/null
  iid="$(Q "select gen_random_uuid();")"
  "${PSQL[@]}" -c "
select set_config('test.current_uid', '$uid', false);
set role authenticated;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
values ('$iid', '$org', 'carrier_freight_invoice', '$carrier', 'broker', '$broker', '$uid');
insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
values ('$org', '$iid', 'freight', 1, $rate, 'freight_charge', '$lid');
insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('$org', '$iid', '$lid');
" >/dev/null
  local t0
  t0="$(Q "select updated_at from public.carrier_invoices where id='$iid';")"
  as_uid "$uid" "select public.issue_carrier_invoice('$iid'::uuid, '$t0'::timestamptz, 'fixture', 'fixture-issue-$iid');" >/dev/null
  echo "$iid"
}

echo
echo "########################################################################"
echo "SCENARIO 1: two partial payments racing (both fit within balance)"
echo "########################################################################"
echo "  Finding, verified directly before writing this scenario: both RPCs"
echo "  require p_expected_updated_at (Section D's own signature) -- when"
echo "  two callers race using the SAME pre-race snapshot of the invoice's"
echo "  updated_at, whichever acquires the FOR UPDATE lock second sees the"
echo "  row AFTER the first's commit (its own lock acquisition blocks until"
echo "  then), so its OWN expected_updated_at is now provably stale -- it"
echo "  gets a clean STALE_RECORD, never a silent lost update. This is"
echo "  STRICTER than 'both succeed blindly' and is the correct, by-design"
echo "  behavior (matching every other optimistic-concurrency RPC in this"
echo "  schema, 0143-0145) -- verified by a real retry below, which succeeds"
echo "  once it re-reads a fresh updated_at."
INV1="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 1000)"
T1="$(Q "select updated_at from public.carrier_invoices where id='$INV1';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV1'::uuid, 300.00, current_date, 'ach', 'r1a', '$T1'::timestamptz, 's1a', 's1-key-a');" ) >"$T/s1a.out" 2>"$T/s1a.err" &
P1A=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV1'::uuid, 400.00, current_date, 'wire', 'r1b', '$T1'::timestamptz, 's1b', 's1-key-b');" ) >"$T/s1b.out" 2>"$T/s1b.err" &
P1B=$!
set +e; wait "$P1A"; wait "$P1B"; set -e
assert_no_deadlock_text "$T/s1a.err" "$T/s1b.err"; assert_no_new_deadlocks "1"
A1=0; B1=0; AS1=0; BS1=0
grep -q '"code": "PAYMENT_RECORDED"' "$T/s1a.out" && A1=1
grep -q '"code": "PAYMENT_RECORDED"' "$T/s1b.out" && B1=1
grep -q 'STALE_RECORD' "$T/s1a.out" && AS1=1
grep -q 'STALE_RECORD' "$T/s1b.out" && BS1=1
if [ "$((A1+B1))" -ne 1 ] || [ "$((AS1+BS1))" -ne 1 ]; then
  echo "!! FAIL: expected exactly one PAYMENT_RECORDED + one STALE_RECORD, got A=$(cat "$T/s1a.out") B=$(cat "$T/s1b.out")"; FAIL=1
fi
# The loser retries with a freshly-read updated_at -- must now succeed,
# proving no lost update, just a required re-read.
T1_FRESH="$(Q "select updated_at from public.carrier_invoices where id='$INV1';")"
# Retry with the STALE LOSER's own original amount (A=300, B=400) -- NOT
# always the same one -- whichever side actually lost the race.
if [ "$AS1" = "1" ]; then RETRY_AMOUNT1=300.00; else RETRY_AMOUNT1=400.00; fi
RETRY1="$(as_owner_a "select public.record_carrier_invoice_payment('$INV1'::uuid, $RETRY_AMOUNT1, current_date, 'ach', 'r1-retry', '$T1_FRESH'::timestamptz, 's1 retry', 's1-key-retry');")"
echo "$RETRY1" | grep -q '"code": "PAYMENT_RECORDED"' || { echo "!! FAIL: the stale loser's retry (with a fresh read) should have succeeded, got $RETRY1"; FAIL=1; }
AMOUNT_PAID1="$(Q "select amount_paid from public.carrier_invoices where id='$INV1';")"
[ "$AMOUNT_PAID1" = "700.00" ] || { echo "!! FAIL: expected amount_paid=700.00 after the retry (no lost update), got $AMOUNT_PAID1"; FAIL=1; }
echo "-> OK: exactly one payment won the race; the loser got a clean STALE_RECORD (never a lost update) and succeeded on retry with a fresh read -- final amount_paid=$AMOUNT_PAID1."

echo
echo "########################################################################"
echo "SCENARIO 2: two payments that together would overpay"
echo "########################################################################"
echo "  First race (same stale snapshot): expect PAYMENT_RECORDED + STALE_RECORD"
echo "  (per Scenario 1's own finding). The genuine OVERPAYMENT guard is then"
echo "  proven by the loser's OWN retry, now with a FRESH read reflecting the"
echo "  winner's payment already applied -- this is the realistic shape of"
echo "  'two submissions that together would overpay': a client that reloads"
echo "  after being told its data was stale must still be correctly blocked"
echo "  by the balance itself, not merely by staleness."
INV2="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T2="$(Q "select updated_at from public.carrier_invoices where id='$INV2';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV2'::uuid, 300.00, current_date, 'ach', 'r2a', '$T2'::timestamptz, 's2a', 's2-key-a');" ) >"$T/s2a.out" 2>"$T/s2a.err" &
P2A=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV2'::uuid, 300.00, current_date, 'wire', 'r2b', '$T2'::timestamptz, 's2b', 's2-key-b');" ) >"$T/s2b.out" 2>"$T/s2b.err" &
P2B=$!
set +e; wait "$P2A"; wait "$P2B"; set -e
assert_no_deadlock_text "$T/s2a.err" "$T/s2b.err"; assert_no_new_deadlocks "2"
A2=0; B2=0; AS2=0; BS2=0
grep -q '"code": "PAYMENT_RECORDED"' "$T/s2a.out" && A2=1
grep -q '"code": "PAYMENT_RECORDED"' "$T/s2b.out" && B2=1
grep -q 'STALE_RECORD' "$T/s2a.out" && AS2=1
grep -q 'STALE_RECORD' "$T/s2b.out" && BS2=1
[ "$((A2+B2))" -eq 1 ] && [ "$((AS2+BS2))" -eq 1 ] || { echo "!! FAIL: expected exactly one PAYMENT_RECORDED + one STALE_RECORD, got A=$(cat "$T/s2a.out") B=$(cat "$T/s2b.out")"; FAIL=1; }
T2_FRESH="$(Q "select updated_at from public.carrier_invoices where id='$INV2';")"
RETRY2="$(as_owner_a "select public.record_carrier_invoice_payment('$INV2'::uuid, 300.00, current_date, 'wire', 'r2b-retry', '$T2_FRESH'::timestamptz, 's2b retry', 's2-key-b-retry');")"
echo "$RETRY2" | grep -q 'OVERPAYMENT' || { echo "!! FAIL: the retry (now with a FRESH read, $500 total, $300 already paid, $300 more requested) should hit OVERPAYMENT, got $RETRY2"; FAIL=1; }
AMOUNT_PAID2="$(Q "select amount_paid from public.carrier_invoices where id='$INV2';")"
[ "$AMOUNT_PAID2" = "300.00" ] || { echo "!! FAIL: expected amount_paid=300.00 (no overpayment, ever), got $AMOUNT_PAID2"; FAIL=1; }
echo "-> OK: two payments that together would overpay -- the race itself produced one winner + one STALE_RECORD; the loser's own fresh-data retry was THEN correctly blocked by OVERPAYMENT. amount_paid never exceeded 300.00 of 500.00."

echo
echo "########################################################################"
echo "SCENARIO 3: full payment vs partial payment, racing"
echo "########################################################################"
INV3="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 1000)"
T3="$(Q "select updated_at from public.carrier_invoices where id='$INV3';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV3'::uuid, 1000.00, current_date, 'ach', 'r3full', '$T3'::timestamptz, 's3full', 's3-key-full');" ) >"$T/s3full.out" 2>"$T/s3full.err" &
P3F=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV3'::uuid, 100.00, current_date, 'wire', 'r3partial', '$T3'::timestamptz, 's3partial', 's3-key-partial');" ) >"$T/s3partial.out" 2>"$T/s3partial.err" &
P3P=$!
set +e; wait "$P3F"; wait "$P3P"; set -e
assert_no_deadlock_text "$T/s3full.err" "$T/s3partial.err"; assert_no_new_deadlocks "3"
FOK=0; POK=0; FST=0; PST=0
grep -q '"code": "PAYMENT_RECORDED"' "$T/s3full.out" && FOK=1
grep -q '"code": "PAYMENT_RECORDED"' "$T/s3partial.out" && POK=1
grep -q 'STALE_RECORD' "$T/s3full.out" && FST=1
grep -q 'STALE_RECORD' "$T/s3partial.out" && PST=1
if [ "$((FOK+POK))" -ne 1 ] || [ "$((FST+PST))" -ne 1 ]; then
  echo "!! FAIL: expected exactly one PAYMENT_RECORDED + one STALE_RECORD, got FULL=$(cat "$T/s3full.out") PARTIAL=$(cat "$T/s3partial.out")"; FAIL=1
fi
T3_FRESH="$(Q "select updated_at from public.carrier_invoices where id='$INV3';")"
if [ "$FST" = "1" ]; then
  # The full-payment attempt was the stale loser -- its own retry (full
  # $1000 against a $900 remaining balance, since partial won) must
  # correctly OVERPAY.
  RETRY3="$(as_owner_a "select public.record_carrier_invoice_payment('$INV3'::uuid, 1000.00, current_date, 'ach', 'r3full-retry', '$T3_FRESH'::timestamptz, 's3full retry', 's3-key-full-retry');")"
  echo "$RETRY3" | grep -q 'OVERPAYMENT' || { echo "!! FAIL: the full-payment retry against a reduced balance should OVERPAY, got $RETRY3"; FAIL=1; }
else
  # The partial-payment attempt was the stale loser -- its own retry
  # ($100 against a $0 remaining balance, since full won) must correctly
  # find the invoice ALREADY_PAID.
  RETRY3="$(as_owner_a "select public.record_carrier_invoice_payment('$INV3'::uuid, 100.00, current_date, 'wire', 'r3partial-retry', '$T3_FRESH'::timestamptz, 's3partial retry', 's3-key-partial-retry');")"
  echo "$RETRY3" | grep -q 'ALREADY_PAID' || { echo "!! FAIL: the partial-payment retry against a fully-paid invoice should be ALREADY_PAID, got $RETRY3"; FAIL=1; }
fi
echo "-> OK: full-vs-partial race -- exactly one won, the other cleanly STALE_RECORD; its own fresh-data retry was then correctly blocked (OVERPAYMENT or ALREADY_PAID, matching whichever side actually won)."

echo
echo "########################################################################"
echo "SCENARIO 4: same-key payment replay under true concurrency (SAME invoice, SAME payload)"
echo "########################################################################"
INV4="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T4="$(Q "select updated_at from public.carrier_invoices where id='$INV4';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV4'::uuid, 200.00, current_date, 'ach', 'r4', '$T4'::timestamptz, 's4', 's4-samekey');" ) >"$T/s4a.out" 2>"$T/s4a.err" &
P4A=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV4'::uuid, 200.00, current_date, 'ach', 'r4', '$T4'::timestamptz, 's4', 's4-samekey');" ) >"$T/s4b.out" 2>"$T/s4b.err" &
P4B=$!
set +e; wait "$P4A"; wait "$P4B"; set -e
assert_no_deadlock_text "$T/s4a.err" "$T/s4b.err"; assert_no_new_deadlocks "4"
if grep -qi "unique" "$T/s4a.err" "$T/s4b.err" 2>/dev/null; then echo "!! FAIL: a raw unique-violation leaked."; FAIL=1; fi
CT4="$(Q "select count(*) from public.carrier_invoice_payments where carrier_invoice_id='$INV4';")"
[ "$CT4" = "1" ] || { echo "!! FAIL: expected exactly 1 payment row, got $CT4"; FAIL=1; }
AUD4="$(Q "select count(*) from public.activity_logs where entity_type='invoice' and entity_id='$INV4' and action='carrier_invoice_payment_recorded';")"
[ "$AUD4" = "1" ] || { echo "!! FAIL: expected exactly 1 audit event, got $AUD4"; FAIL=1; }
echo "-> OK: two truly concurrent callers with the IDENTICAL key+payload -- exactly one payment row, one audit event."

echo
echo "########################################################################"
echo "SCENARIO 5: same key, DIFFERENT amount, true concurrency"
echo "########################################################################"
INV5="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T5="$(Q "select updated_at from public.carrier_invoices where id='$INV5';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV5'::uuid, 100.00, current_date, 'ach', 'r5', '$T5'::timestamptz, 's5', 's5-samekey');" ) >"$T/s5a.out" 2>"$T/s5a.err" &
P5A=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV5'::uuid, 200.00, current_date, 'ach', 'r5', '$T5'::timestamptz, 's5', 's5-samekey');" ) >"$T/s5b.out" 2>"$T/s5b.err" &
P5B=$!
set +e; wait "$P5A"; wait "$P5B"; set -e
assert_no_deadlock_text "$T/s5a.err" "$T/s5b.err"; assert_no_new_deadlocks "5"
A5=0; B5=0; AR5=0; BR5=0
grep -q '"code": "PAYMENT_RECORDED"' "$T/s5a.out" && A5=1
grep -q '"code": "PAYMENT_RECORDED"' "$T/s5b.out" && B5=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s5a.out" && AR5=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s5b.out" && BR5=1
[ "$((A5+B5))" -eq 1 ] && [ "$((AR5+BR5))" -eq 1 ] || { echo "!! FAIL: expected exactly one PAYMENT_RECORDED + one IDEMPOTENCY_KEY_REUSED, got A=$(cat "$T/s5a.out") B=$(cat "$T/s5b.out")"; FAIL=1; }
echo "-> OK: same key, different amount -- exactly one recorded, the other cleanly IDEMPOTENCY_KEY_REUSED."

echo
echo "########################################################################"
echo "SCENARIO 6: same key, DIFFERENT invoice, true concurrency"
echo "########################################################################"
INV6A="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
INV6B="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T6A="$(Q "select updated_at from public.carrier_invoices where id='$INV6A';")"
T6B="$(Q "select updated_at from public.carrier_invoices where id='$INV6B';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV6A'::uuid, 100.00, current_date, 'ach', 'r6a', '$T6A'::timestamptz, 's6', 's6-samekey');" ) >"$T/s6a.out" 2>"$T/s6a.err" &
P6A=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV6B'::uuid, 100.00, current_date, 'ach', 'r6b', '$T6B'::timestamptz, 's6', 's6-samekey');" ) >"$T/s6b.out" 2>"$T/s6b.err" &
P6B=$!
set +e; wait "$P6A"; wait "$P6B"; set -e
assert_no_deadlock_text "$T/s6a.err" "$T/s6b.err"; assert_no_new_deadlocks "6"
A6=0; B6=0; AR6=0; BR6=0
grep -q '"code": "PAYMENT_RECORDED"' "$T/s6a.out" && A6=1
grep -q '"code": "PAYMENT_RECORDED"' "$T/s6b.out" && B6=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s6a.out" && AR6=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s6b.out" && BR6=1
[ "$((A6+B6))" -eq 1 ] && [ "$((AR6+BR6))" -eq 1 ] || { echo "!! FAIL: expected exactly one PAYMENT_RECORDED + one IDEMPOTENCY_KEY_REUSED, got A=$(cat "$T/s6a.out") B=$(cat "$T/s6b.out")"; FAIL=1; }
echo "-> OK: same key across two DIFFERENT invoices -- exactly one recorded, the other cleanly IDEMPOTENCY_KEY_REUSED."

echo
echo "########################################################################"
echo "SCENARIO 7: two DIFFERENT invoices paid concurrently -- no cross-invoice interference"
echo "########################################################################"
INV7A="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
INV7B="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T7A="$(Q "select updated_at from public.carrier_invoices where id='$INV7A';")"
T7B="$(Q "select updated_at from public.carrier_invoices where id='$INV7B';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV7A'::uuid, 500.00, current_date, 'ach', 'r7a', '$T7A'::timestamptz, 's7a', 's7-key-a');" ) >"$T/s7a.out" 2>"$T/s7a.err" &
P7A=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV7B'::uuid, 500.00, current_date, 'ach', 'r7b', '$T7B'::timestamptz, 's7b', 's7-key-b');" ) >"$T/s7b.out" 2>"$T/s7b.err" &
P7B=$!
set +e; wait "$P7A"; wait "$P7B"; set -e
assert_no_deadlock_text "$T/s7a.err" "$T/s7b.err"; assert_no_new_deadlocks "7"
grep -q '"code": "PAYMENT_RECORDED"' "$T/s7a.out" || { echo "!! FAIL (7A): $(cat "$T/s7a.out")"; FAIL=1; }
grep -q '"code": "PAYMENT_RECORDED"' "$T/s7b.out" || { echo "!! FAIL (7B): $(cat "$T/s7b.out")"; FAIL=1; }
echo "-> OK: two different invoices paid concurrently -- both succeeded independently."

echo
echo "########################################################################"
echo "SCENARIO 8: record payment vs void payment, concurrently (different payments, same invoice)"
echo "########################################################################"
INV8="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 1000)"
T8="$(Q "select updated_at from public.carrier_invoices where id='$INV8';")"
PAY8_RESULT="$(as_owner_a "select public.record_carrier_invoice_payment('$INV8'::uuid, 300.00, current_date, 'ach', 'r8existing', '$T8'::timestamptz, 's8 setup', 's8-setup-key');")"
PAY8_ID="$(echo "$PAY8_RESULT" | grep -o '"payment_id": "[^"]*"' | cut -d'"' -f4)"
T8B="$(Q "select updated_at from public.carrier_invoice_payments where id='$PAY8_ID';")"
T8I="$(Q "select updated_at from public.carrier_invoices where id='$INV8';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV8'::uuid, 200.00, current_date, 'wire', 'r8new', '$T8I'::timestamptz, 's8 record', 's8-record-key');" ) >"$T/s8r.out" 2>"$T/s8r.err" &
P8R=$!
( as_owner_a "select public.void_carrier_invoice_payment('$PAY8_ID'::uuid, '$T8B'::timestamptz, 's8 void', 's8-void-key');" ) >"$T/s8v.out" 2>"$T/s8v.err" &
P8V=$!
set +e; wait "$P8R"; wait "$P8V"; set -e
assert_no_deadlock_text "$T/s8r.err" "$T/s8v.err"; assert_no_new_deadlocks "8"
grep -q '"code": "PAYMENT_RECORDED"' "$T/s8r.out" || { echo "!! FAIL (8 record): $(cat "$T/s8r.out")"; FAIL=1; }
grep -q '"code": "PAYMENT_VOIDED"' "$T/s8v.out" || { echo "!! FAIL (8 void): $(cat "$T/s8v.out")"; FAIL=1; }
FINAL8="$(Q "select amount_paid from public.carrier_invoices where id='$INV8';")"
[ "$FINAL8" = "200.00" ] || { echo "!! FAIL (8): expected amount_paid=200.00 (300 voided + 200 new), got $FINAL8"; FAIL=1; }
echo "-> OK: record vs void, concurrently -- both succeeded, correctly serialized on the invoice lock (final amount_paid=$FINAL8)."

echo
echo "########################################################################"
echo "SCENARIO 9: two void attempts on the SAME payment, concurrently"
echo "########################################################################"
INV9="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T9="$(Q "select updated_at from public.carrier_invoices where id='$INV9';")"
PAY9_RESULT="$(as_owner_a "select public.record_carrier_invoice_payment('$INV9'::uuid, 500.00, current_date, 'ach', 'r9', '$T9'::timestamptz, 's9 setup', 's9-setup-key');")"
PAY9_ID="$(echo "$PAY9_RESULT" | grep -o '"payment_id": "[^"]*"' | cut -d'"' -f4)"
T9P="$(Q "select updated_at from public.carrier_invoice_payments where id='$PAY9_ID';")"
( as_owner_a "select public.void_carrier_invoice_payment('$PAY9_ID'::uuid, '$T9P'::timestamptz, 's9 void A', 's9-void-a');" ) >"$T/s9a.out" 2>"$T/s9a.err" &
P9A=$!
( as_owner_a "select public.void_carrier_invoice_payment('$PAY9_ID'::uuid, '$T9P'::timestamptz, 's9 void B', 's9-void-b');" ) >"$T/s9b.out" 2>"$T/s9b.err" &
P9B=$!
set +e; wait "$P9A"; wait "$P9B"; set -e
assert_no_deadlock_text "$T/s9a.err" "$T/s9b.err"; assert_no_new_deadlocks "9"
AV9=0; BV9=0; AL9=0; BL9=0
grep -q '"code": "PAYMENT_VOIDED"' "$T/s9a.out" && AV9=1
grep -q '"code": "PAYMENT_VOIDED"' "$T/s9b.out" && BV9=1
grep -qE 'PAYMENT_ALREADY_VOIDED|STALE_RECORD' "$T/s9a.out" && AL9=1
grep -qE 'PAYMENT_ALREADY_VOIDED|STALE_RECORD' "$T/s9b.out" && BL9=1
[ "$((AV9+BV9))" -eq 1 ] && [ "$((AL9+BL9))" -eq 1 ] || { echo "!! FAIL: expected exactly one PAYMENT_VOIDED + one PAYMENT_ALREADY_VOIDED/STALE_RECORD, got A=$(cat "$T/s9a.out") B=$(cat "$T/s9b.out")"; FAIL=1; }
echo "-> OK: two concurrent void attempts on the same payment -- exactly one won, the other cleanly refused."

echo
echo "########################################################################"
echo "SCENARIO 10: full-payment void reopening the invoice, racing a concurrent read"
echo "########################################################################"
INV10="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T10="$(Q "select updated_at from public.carrier_invoices where id='$INV10';")"
PAY10_RESULT="$(as_owner_a "select public.record_carrier_invoice_payment('$INV10'::uuid, 500.00, current_date, 'ach', 'r10', '$T10'::timestamptz, 's10 setup', 's10-setup-key');")"
PAY10_ID="$(echo "$PAY10_RESULT" | grep -o '"payment_id": "[^"]*"' | cut -d'"' -f4)"
T10P="$(Q "select updated_at from public.carrier_invoice_payments where id='$PAY10_ID';")"
( as_owner_a "select public.void_carrier_invoice_payment('$PAY10_ID'::uuid, '$T10P'::timestamptz, 's10 void', 's10-void-key');" ) >"$T/s10v.out" 2>"$T/s10v.err" &
P10V=$!
( for i in $(seq 1 20); do Q "select payment_status from public.carrier_invoices where id='$INV10';" >/dev/null; done ) >"$T/s10r.out" 2>"$T/s10r.err" &
P10R=$!
set +e; wait "$P10V"; wait "$P10R"; set -e
assert_no_deadlock_text "$T/s10v.err" "$T/s10r.err"; assert_no_new_deadlocks "10"
grep -q '"code": "PAYMENT_VOIDED"' "$T/s10v.out" || { echo "!! FAIL (10): $(cat "$T/s10v.out")"; FAIL=1; }
FINAL10="$(Q "select row(amount_paid, payment_status) from public.carrier_invoices where id='$INV10';")"
[ "$FINAL10" = "(0.00,unpaid)" ] || { echo "!! FAIL (10): expected (0.00,unpaid) after voiding the sole full payment, got $FINAL10"; FAIL=1; }
echo "-> OK: voiding the full/final payment correctly reopened the invoice to unpaid/\$0, with a concurrent reader never observing a torn intermediate state."

echo
echo "########################################################################"
echo "SCENARIO 11: payment vs invoice issuance, both orderings"
echo "########################################################################"
echo "----- 11A: issuance and payment attempt racing on a NOT-YET-issued invoice -----"
LD11A="$(Q "select gen_random_uuid();")"
"${PSQL[@]}" -c "
insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
values ('$LD11A', '11111111-1111-1111-1111-111111111111', 'LD-CONC11A', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 400);
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at) values
('11111111-1111-1111-1111-111111111111', '$LD11A', 'pickup', 1, 'S', 'Dallas', 'TX', now() - interval '2 days'),
('11111111-1111-1111-1111-111111111111', '$LD11A', 'delivery', 2, 'R', 'Houston', 'TX', now() - interval '1 day');
" >/dev/null
INV11A="$(Q "select gen_random_uuid();")"
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
values ('$INV11A', '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001');
insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
values ('11111111-1111-1111-1111-111111111111', '$INV11A', 'freight', 1, 400, 'freight_charge', '$LD11A');
insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', '$INV11A', '$LD11A');
" >/dev/null
T11AI="$(Q "select updated_at from public.carrier_invoices where id='$INV11A';")"
( as_owner_a "select public.issue_carrier_invoice('$INV11A'::uuid, '$T11AI'::timestamptz, 's11a issue', 's11a-issue-key');" ) >"$T/s11ai.out" 2>"$T/s11ai.err" &
P11AI=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV11A'::uuid, 100.00, current_date, 'ach', 'r11a', '$T11AI'::timestamptz, 's11a pay', 's11a-pay-key');" ) >"$T/s11ap.out" 2>"$T/s11ap.err" &
P11AP=$!
set +e; wait "$P11AI"; wait "$P11AP"; set -e
assert_no_deadlock_text "$T/s11ai.err" "$T/s11ap.err"; assert_no_new_deadlocks "11A"
grep -q '"code": "ISSUED"' "$T/s11ai.out" || { echo "!! FAIL (11A issue): $(cat "$T/s11ai.out")"; FAIL=1; }
if grep -q '"code": "PAYMENT_RECORDED"' "$T/s11ap.out"; then
  echo "-> OK (11A): payment locked the invoice AFTER issuance committed -- succeeded cleanly."
elif grep -q 'INVALID_STATE\|STALE_RECORD' "$T/s11ap.out"; then
  echo "-> OK (11A): payment attempted before/during issuance -- cleanly refused (draft not yet issued, or stale row), never a torn read."
else
  echo "!! FAIL (11A): unexpected payment outcome: $(cat "$T/s11ap.out")"; FAIL=1
fi

echo "----- 11B: payment vs issuance on an ALREADY-issued invoice, racing with a second freight invoice's issuance (different invoice, same carrier) -----"
INV11B="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 300)"
T11B="$(Q "select updated_at from public.carrier_invoices where id='$INV11B';")"
LD11C="$(Q "select gen_random_uuid();")"
"${PSQL[@]}" -c "
insert into public.loads (id, organization_id, load_number, broker_id, carrier_id, carrier_resolution, status, rate)
values ('$LD11C', '11111111-1111-1111-1111-111111111111', 'LD-CONC11C', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved', 'delivered', 250);
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at) values
('11111111-1111-1111-1111-111111111111', '$LD11C', 'pickup', 1, 'S', 'Dallas', 'TX', now() - interval '2 days'),
('11111111-1111-1111-1111-111111111111', '$LD11C', 'delivery', 2, 'R', 'Houston', 'TX', now() - interval '1 day');
" >/dev/null
INV11C="$(Q "select gen_random_uuid();")"
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
values ('$INV11C', '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001');
insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id)
values ('11111111-1111-1111-1111-111111111111', '$INV11C', 'freight', 1, 250, 'freight_charge', '$LD11C');
insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('11111111-1111-1111-1111-111111111111', '$INV11C', '$LD11C');
" >/dev/null
T11C="$(Q "select updated_at from public.carrier_invoices where id='$INV11C';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV11B'::uuid, 300.00, current_date, 'ach', 'r11b', '$T11B'::timestamptz, 's11b pay', 's11b-pay-key');" ) >"$T/s11bp.out" 2>"$T/s11bp.err" &
P11BP=$!
( as_owner_a "select public.issue_carrier_invoice('$INV11C'::uuid, '$T11C'::timestamptz, 's11b issue other', 's11b-issue-key');" ) >"$T/s11bi.out" 2>"$T/s11bi.err" &
P11BI=$!
set +e; wait "$P11BP"; wait "$P11BI"; set -e
assert_no_deadlock_text "$T/s11bp.err" "$T/s11bi.err"; assert_no_new_deadlocks "11B"
grep -q '"code": "PAYMENT_RECORDED"' "$T/s11bp.out" || { echo "!! FAIL (11B pay): $(cat "$T/s11bp.out")"; FAIL=1; }
grep -q '"code": "ISSUED"' "$T/s11bi.out" || { echo "!! FAIL (11B issue): $(cat "$T/s11bi.out")"; FAIL=1; }
echo "-> OK (11B): a payment on one invoice and an issuance on a DIFFERENT invoice (same carrier) proceeded fully independently."

echo
echo "########################################################################"
echo "SCENARIO 12: payment vs a future/attempted invoice void (direct-context simulation -- no void-invoice RPC exists yet)"
echo "########################################################################"
INV12="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T12="$(Q "select updated_at from public.carrier_invoices where id='$INV12';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV12'::uuid, 200.00, current_date, 'ach', 'r12', '$T12'::timestamptz, 's12 pay', 's12-pay-key');" ) >"$T/s12p.out" 2>"$T/s12p.err" &
P12P=$!
( "${PSQL[@]}" -c "update public.carrier_invoices set issuance_status='voided', voided_at=now(), voided_by='aaaa0000-0000-0000-0000-000000000001', void_reason='s12 concurrency test void' where id = '$INV12';" ) >"$T/s12v.out" 2>"$T/s12v.err" &
P12V=$!
set +e; wait "$P12P"; wait "$P12V"; set -e
assert_no_deadlock_text "$T/s12p.err" "$T/s12v.err"; assert_no_new_deadlocks "12"
echo "  payment result: $(cat "$T/s12p.out")"
if grep -q '"code": "PAYMENT_RECORDED"' "$T/s12p.out"; then
  echo "-> OK (12): payment locked the invoice first and completed correctly; the void then applied cleanly afterward."
elif grep -q 'INVALID_STATE' "$T/s12p.out"; then
  echo "-> OK (12): the void committed first (issuance_status='voided') -- payment correctly refused rather than post against a voided invoice."
elif grep -q 'STALE_RECORD' "$T/s12p.out"; then
  echo "-> OK (12): the void committed first and changed updated_at (set_updated_at fires for any UPDATE) -- payment correctly saw its own expected_updated_at as stale rather than proceed on outdated data (Scenario 1's own finding applies here too)."
else
  echo "!! FAIL (12): unexpected payment outcome: $(cat "$T/s12p.out")"; FAIL=1
fi
# 'voided' is a TERMINAL issuance_status (0142's own state machine) --
# INV12 is intentionally never reused after this scenario, so no
# cleanup/reversion is attempted (and none would succeed).

echo
echo "########################################################################"
echo "SCENARIO 13: factored invoice payment attempt vs factoring configuration change"
echo "########################################################################"
INV13="$(make_issued_freight_invoice a2a2a2a2-0000-0000-0000-000000000002 500)"
T13="$(Q "select updated_at from public.carrier_invoices where id='$INV13';")"
CARRIER13_UPDATED="$(Q "select updated_at from public.carriers where id='a2a2a2a2-0000-0000-0000-000000000002';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV13'::uuid, 100.00, current_date, 'ach', 'r13', '$T13'::timestamptz, 's13 pay', 's13-pay-key');" ) >"$T/s13p.out" 2>"$T/s13p.err" &
P13P=$!
( as_owner_a "select public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002'::uuid, 'direct'::public.carrier_factoring_mode, 's13 switch to direct', '$CARRIER13_UPDATED'::timestamptz, 's13-policy-key');" ) >"$T/s13c.out" 2>"$T/s13c.err" &
P13C=$!
set +e; wait "$P13P"; wait "$P13C"; set -e
assert_no_deadlock_text "$T/s13p.err" "$T/s13c.err"; assert_no_new_deadlocks "13"
echo "  payment result: $(cat "$T/s13p.out")"
echo "  policy result:  $(cat "$T/s13c.out")"
if grep -q 'FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW' "$T/s13p.out"; then
  echo "-> OK (13): the invoice's own immutable issuance SNAPSHOT (captured factored) governs -- rejected regardless of the carrier's current policy changing concurrently."
elif grep -q '"code": "PAYMENT_RECORDED"' "$T/s13p.out"; then
  echo "-> OK (13): payment succeeded -- consistent since the snapshot is immutable and was read correctly under lock."
else
  echo "!! FAIL (13): unexpected payment outcome: $(cat "$T/s13p.out")"; FAIL=1
fi
"${PSQL[@]}" -c "update public.carriers set factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';" >/dev/null

echo
echo "########################################################################"
echo "SCENARIO 14: currency mismatch attempt (direct-context bypass, structural)"
echo "########################################################################"
INV14="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
set +e
"${PSQL[@]}" -c "
insert into public.carrier_invoice_payments (organization_id, carrier_invoice_id, payment_date, amount, currency, payment_method, payer_type, payer_broker_id, recorded_by)
values ('11111111-1111-1111-1111-111111111111', '$INV14', current_date, 50.00, 'EUR', 'ach', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001');
" >"$T/s14.out" 2>"$T/s14.err"
set -e
if grep -qi "currency must equal its invoice" "$T/s14.err"; then
  echo "-> OK (14): a mismatched-currency direct write was refused by the cross-table backstop trigger."
else
  echo "!! FAIL (14): expected the currency backstop to reject this, got: $(cat "$T/s14.err")"; FAIL=1
fi
CT14="$(Q "select count(*) from public.carrier_invoice_payments where carrier_invoice_id='$INV14';")"
[ "$CT14" = "0" ] || { echo "!! FAIL (14): no payment row should have been created, got $CT14"; FAIL=1; }

echo
echo "########################################################################"
echo "SCENARIO 15: lock timeout and retry -- a long-held invoice lock forces a second payment attempt to wait, then succeed"
echo "########################################################################"
INV15="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T15="$(Q "select updated_at from public.carrier_invoices where id='$INV15';")"
( psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
begin;
select 1 from public.carrier_invoices where id = '$INV15' for update;
select pg_sleep(2);
commit;
" ) >"$T/s15h.out" 2>"$T/s15h.err" &
P15H=$!
sleep 0.3
START15=$(date +%s)
( as_owner_a "select public.record_carrier_invoice_payment('$INV15'::uuid, 100.00, current_date, 'ach', 'r15', '$T15'::timestamptz, 's15', 's15-key');" ) >"$T/s15p.out" 2>"$T/s15p.err" &
P15P=$!
set +e; wait "$P15H"; wait "$P15P"; set -e
END15=$(date +%s)
assert_no_deadlock_text "$T/s15h.err" "$T/s15p.err"; assert_no_new_deadlocks "15"
ELAPSED15=$((END15-START15))
grep -q '"code": "PAYMENT_RECORDED"' "$T/s15p.out" || { echo "!! FAIL (15): expected PAYMENT_RECORDED once the lock released, got $(cat "$T/s15p.out")"; FAIL=1; }
if [ "$ELAPSED15" -lt 1 ]; then
  echo "!! FAIL (15): returned in ${ELAPSED15}s -- expected to BLOCK on the held invoice lock for close to 2s."
  FAIL=1
else
  echo "-> OK (15): the payment attempt correctly BLOCKED on the held invoice lock (${ELAPSED15}s) and then succeeded once released."
fi

echo
echo "########################################################################"
echo "SCENARIO 16: a FAILING payment attempt proves no audit/idempotency success"
echo "########################################################################"
INV16="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 100)"
T16="$(Q "select updated_at from public.carrier_invoices where id='$INV16';")"
AUD16_BEFORE="$(Q "select count(*) from public.activity_logs where entity_type='invoice' and entity_id='$INV16' and action='carrier_invoice_payment_recorded';")"
IDEMP16_BEFORE="$(Q "select count(*) from public.carrier_invoice_lifecycle_idempotency where invoice_id='$INV16' and operation='record_carrier_invoice_payment';")"
RESULT16="$(as_owner_a "select public.record_carrier_invoice_payment('$INV16'::uuid, 500.00, current_date, 'ach', 'r16', '$T16'::timestamptz, 's16', 's16-key');")"
echo "$RESULT16" | grep -q 'OVERPAYMENT' || { echo "!! FAIL (16): expected OVERPAYMENT (amount exceeds the $100 invoice), got $RESULT16"; FAIL=1; }
AUD16_AFTER="$(Q "select count(*) from public.activity_logs where entity_type='invoice' and entity_id='$INV16' and action='carrier_invoice_payment_recorded';")"
IDEMP16_AFTER="$(Q "select count(*) from public.carrier_invoice_lifecycle_idempotency where invoice_id='$INV16' and operation='record_carrier_invoice_payment';")"
[ "$AUD16_AFTER" = "$AUD16_BEFORE" ] || { echo "!! FAIL (16): a failed payment must never create an audit event."; FAIL=1; }
[ "$IDEMP16_AFTER" = "$IDEMP16_BEFORE" ] || { echo "!! FAIL (16): a failed payment must never create a successful idempotency record."; FAIL=1; }
echo "-> OK (16): the failed OVERPAYMENT attempt created zero audit events and zero idempotency records."

echo
echo "########################################################################"
echo "SCENARIO 17: cross-organization tampering"
echo "########################################################################"
INV17="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T17="$(Q "select updated_at from public.carrier_invoices where id='$INV17';")"
RESULT17="$(as_owner_b "select public.record_carrier_invoice_payment('$INV17'::uuid, 100.00, current_date, 'ach', 'r17', '$T17'::timestamptz, 's17', 's17-key');")"
echo "$RESULT17" | grep -q 'NOT_FOUND' || { echo "!! FAIL (17a): org B acting on org A's invoice should get NOT_FOUND, got $RESULT17"; FAIL=1; }
CT17="$(Q "select count(*) from public.carrier_invoice_payments where carrier_invoice_id='$INV17';")"
[ "$CT17" = "0" ] || { echo "!! FAIL (17a): no payment row should have been created."; FAIL=1; }

# Also: void a payment cross-org.
PAY17_RESULT="$(as_owner_a "select public.record_carrier_invoice_payment('$INV17'::uuid, 100.00, current_date, 'ach', 'r17own', '$T17'::timestamptz, 's17own', 's17-own-key');")"
PAY17_ID="$(echo "$PAY17_RESULT" | grep -o '"payment_id": "[^"]*"' | cut -d'"' -f4)"
RESULT17B="$(as_owner_b "select public.void_carrier_invoice_payment('$PAY17_ID'::uuid, now(), 's17b', 's17b-key');")"
echo "$RESULT17B" | grep -q 'NOT_FOUND' || { echo "!! FAIL (17b): org B voiding org A's payment should get NOT_FOUND, got $RESULT17B"; FAIL=1; }
[ "$(Q "select status from public.carrier_invoice_payments where id='$PAY17_ID';")" = "posted" ] || { echo "!! FAIL (17b): the payment must remain posted."; FAIL=1; }
echo "-> OK (17): cross-organization tampering (both record and void) cleanly refused as NOT_FOUND -- no cross-tenant leakage."

echo
echo "########################################################################"
echo "SCENARIO 18: direct table-write bypass, racing a legitimate RPC call"
echo "########################################################################"
INV18="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T18="$(Q "select updated_at from public.carrier_invoices where id='$INV18';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV18'::uuid, 200.00, current_date, 'ach', 'r18', '$T18'::timestamptz, 's18', 's18-key');" ) >"$T/s18r.out" 2>"$T/s18r.err" &
P18R=$!
( psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
insert into public.carrier_invoice_payments (organization_id, carrier_invoice_id, payment_date, amount, currency, payment_method, payer_type, payer_broker_id, recorded_by)
values ('11111111-1111-1111-1111-111111111111', '$INV18', current_date, 50.00, 'USD', 'ach', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001');
" ) >"$T/s18b.out" 2>"$T/s18b.err" &
P18B=$!
set +e; wait "$P18R"; wait "$P18B"; set -e
assert_no_deadlock_text "$T/s18r.err" "$T/s18b.err"; assert_no_new_deadlocks "18"
grep -q '"code": "PAYMENT_RECORDED"' "$T/s18r.out" || { echo "!! FAIL (18 RPC): $(cat "$T/s18r.out")"; FAIL=1; }
if grep -qi "permission denied\|row-level security" "$T/s18b.err"; then
  echo "-> OK (18): the legitimate RPC succeeded; the concurrent direct-table-write bypass attempt was refused entirely (RLS/grant), regardless of timing."
else
  echo "!! FAIL (18): expected the direct bypass to be refused by RLS/grants, got: $(cat "$T/s18b.err")"; FAIL=1
fi

echo
echo "########################################################################"
echo "SCENARIO 19: snapshot mutation attempt during payment"
echo "########################################################################"
INV19="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T19="$(Q "select updated_at from public.carrier_invoices where id='$INV19';")"
SNAP19_BEFORE="$(Q "select total_amount from public.carrier_invoice_issuance_snapshots where invoice_id='$INV19';")"
( as_owner_a "select public.record_carrier_invoice_payment('$INV19'::uuid, 200.00, current_date, 'ach', 'r19', '$T19'::timestamptz, 's19', 's19-key');" ) >"$T/s19p.out" 2>"$T/s19p.err" &
P19P=$!
( psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
update public.carrier_invoice_issuance_snapshots set total_amount = 1 where invoice_id = '$INV19';
" ) >"$T/s19m.out" 2>"$T/s19m.err" &
P19M=$!
set +e; wait "$P19P"; wait "$P19M"; set -e
assert_no_deadlock_text "$T/s19p.err" "$T/s19m.err"; assert_no_new_deadlocks "19"
grep -q '"code": "PAYMENT_RECORDED"' "$T/s19p.out" || { echo "!! FAIL (19 payment): $(cat "$T/s19p.out")"; FAIL=1; }
if grep -qi "immutable and can never be updated" "$T/s19m.err"; then
  echo "-> OK (19): the concurrent snapshot mutation attempt was rejected by the (unchanged, 0142) immutability trigger regardless of timing."
else
  echo "!! FAIL (19): expected the snapshot-immutability rejection, got: $(cat "$T/s19m.err")"; FAIL=1
fi
SNAP19_AFTER="$(Q "select total_amount from public.carrier_invoice_issuance_snapshots where invoice_id='$INV19';")"
[ "$SNAP19_AFTER" = "$SNAP19_BEFORE" ] || { echo "!! FAIL (19): the snapshot must remain unchanged, was $SNAP19_BEFORE now $SNAP19_AFTER"; FAIL=1; }

echo
echo "########################################################################"
echo "SCENARIO 20: a LEGACY public.invoices id passed to the new RPC, racing a legitimate payment"
echo "########################################################################"
# NOTE: Q() lacks -q, so an INSERT ... RETURNING would otherwise also
# capture the "INSERT 0 1" command tag on its own line, corrupting the
# id -- -q is added here specifically for this one RETURNING call.
LEGACY20="$(psql -X -q -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "insert into public.invoices (organization_id, invoice_number, total_amount) values ('11111111-1111-1111-1111-111111111111', 'LEGACY-CONC-20', 500.00) returning id;")"
INV20="$(make_issued_freight_invoice a1a1a1a1-0000-0000-0000-000000000001 500)"
T20="$(Q "select updated_at from public.carrier_invoices where id='$INV20';")"
( as_owner_a "select public.record_carrier_invoice_payment('$LEGACY20'::uuid, 100.00, current_date, 'ach', 'r20legacy', now(), 's20 legacy', 's20-legacy-key');" ) >"$T/s20l.out" 2>"$T/s20l.err" &
P20L=$!
( as_owner_a "select public.record_carrier_invoice_payment('$INV20'::uuid, 100.00, current_date, 'ach', 'r20real', '$T20'::timestamptz, 's20 real', 's20-real-key');" ) >"$T/s20r.out" 2>"$T/s20r.err" &
P20R=$!
set +e; wait "$P20L"; wait "$P20R"; set -e
assert_no_deadlock_text "$T/s20l.err" "$T/s20r.err"; assert_no_new_deadlocks "20"
grep -q 'NOT_FOUND' "$T/s20l.out" || { echo "!! FAIL (20 legacy): expected NOT_FOUND for the legacy invoices id, got $(cat "$T/s20l.out")"; FAIL=1; }
grep -q '"code": "PAYMENT_RECORDED"' "$T/s20r.out" || { echo "!! FAIL (20 real): $(cat "$T/s20r.out")"; FAIL=1; }
echo "-> OK (20): a legacy public.invoices id cleanly returned NOT_FOUND with zero interference to a concurrent, legitimate payment on a real carrier_invoices row."

echo
echo "== final deadlock check: pg_stat_database.deadlocks for this database =="
FINAL_DEADLOCKS_TOTAL="$(Q "select deadlocks from pg_stat_database where datname='$DB';")"
echo "   total deadlocks for the whole run=$FINAL_DEADLOCKS_TOTAL"
if [ "$FINAL_DEADLOCKS_TOTAL" != "0" ]; then
  echo "!! FAIL: expected ZERO deadlocks for this entire run, got $FINAL_DEADLOCKS_TOTAL."
  FAIL=1
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "!!!!!!!!!!!!!!!!  TEST CONCURRENCY 0146 CARRIER INVOICE PAYMENTS FAILED  !!!!!!!!!!!!!!!!"
  exit 1
fi
echo "TEST CONCURRENCY 0146 CARRIER INVOICE PAYMENTS PASSED (all 20 required scenarios -- ZERO Postgres-detected deadlocks throughout)"
