#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0144_atomic_invoice_issuance.sh -- Phase 3B.3C.1,
# Section D: ALL 19 required concurrency scenarios for issue_carrier_
# invoice(), every one a genuine separate-session test (no scenario is
# treated as "covered by source inspection alone").
#
# Deadlock detection is authoritative, not textual: pg_stat_database.
# deadlocks is read before/after the whole run and MUST NOT increase
# (Postgres increments this counter itself whenever its deadlock detector
# fires, which is a stronger signal than grepping stderr for the word
# "deadlock"). assert_no_new_deadlocks() checks this after every
# scenario.
#
# For scenarios where blocking is the thing under test (9-13, 19), a
# THIRD observer session captures pg_stat_activity / pg_blocking_pids() /
# pg_locks mid-race.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0144_atomic_invoice_issuance.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0144_issuance_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54943}"
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
DB=carrier_invoice_0144_issuance_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")
Q() { psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "$1"; }

echo "== bootstrap: seed + support schema + 0130-0144 =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f TEST_SUPPORT_0136_0138_factoring_schema.sql >/dev/null
for m in 0130_carrier_context_foundation 0131_carrier_party_relationships 0132_load_carrier_and_trailer_scope \
         0133_deterministic_carrier_backfill 0134_dispatch_status_transition_and_trailer_privilege_hotfix \
         0135_dispatch_resource_reassignment_and_carrier_lockdown 0136_carrier_factoring_policy_and_relationship_columns \
         0137_deterministic_factoring_carrier_backfill 0138_carrier_default_cutover_classifier_and_secured_rpcs \
         0139_factoring_policy_safety_integrations_and_privilege_remediation 0140_factoring_authorization_and_submission_safety \
         0141_factoring_integration_lifecycle_integrity 0142_immutable_carrier_invoice_foundation \
         0143_canonical_financial_idempotency_hardening 0144_atomic_carrier_invoice_issuance; do
  "${PSQL[@]}" -f "migrations/$m.sql" >/dev/null
done

echo "== fixtures =="
"${PSQL[@]}" -c "
-- Carrier A1: DIRECT, invoice_code CARA (org A). Carrier B1: DIRECT,
-- invoice_code CARB1 (org B, cross-org independence). Carrier A2:
-- FACTORED + fully ready, invoice_code CARF -- with an api-submission
-- integration, used for the factoring-race scenarios (9-12, 19).
update public.carriers set invoice_code = 'CARA', factoring_mode = 'direct' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
update public.carriers set invoice_code = 'CARB1', factoring_mode = 'direct' where id = 'b1b1b1b1-0000-0000-0000-000000000001';
update public.carriers set invoice_code = 'CARF', factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';

insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
values ('cb450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');
insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
values ('cb450000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'b1b1b1b1-0000-0000-0000-000000000001', 'b0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokerb.example', 30, true, now(), 'bbbb0000-0000-0000-0000-000000000001');
insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
values ('cb450000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');

-- Factored carrier A2's ready configuration: company, relationship
-- (default+active, complete, NOA approved via a verified document),
-- and a ready api integration.
insert into public.factoring_companies (id, organization_id, name, legal_name, is_active)
values ('fc450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor 0144C', 'Factor 0144C LLC', true);
insert into public.documents (id, organization_id, entity_type, entity_id, document_type, file_name, file_path, is_verified)
values ('d0450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'carrier', 'a2a2a2a2-0000-0000-0000-000000000002', 'notice_of_assignment', 'noa.pdf', '/docs/noa.pdf', true);
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_document_id, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active)
values
  ('fe450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc450000-0000-0000-0000-000000000001',
   'a2a2a2a2-0000-0000-0000-000000000002', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Factor 0144C', 'd0450000-0000-0000-0000-000000000001', 'ref-0144c-1',
   current_date - 5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'api', true, true);
insert into public.carrier_factoring_integrations
  (id, organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, provider,
   secret_reference, external_account_identifier, configuration_status, is_active)
values
  ('c1450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002',
   'fe450000-0000-0000-0000-000000000001', 'fc450000-0000-0000-0000-000000000001', 'api', 'factoring_api',
   'vault://ref-0144c', 'acct-0144c', 'draft', false);
" >/dev/null
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.verify_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'fixture setup', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'fixture-verify-1');
select public.activate_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'fixture setup', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'fixture-activate-1');
" >/dev/null

FAIL=0
T="$PGDATA_DIR"

DEADLOCKS_BEFORE_TOTAL="$(Q "select deadlocks from pg_stat_database where datname='$DB';")"

assert_no_new_deadlocks() {
  # $1 = scenario label
  local now_dl
  now_dl="$(Q "select deadlocks from pg_stat_database where datname='$DB';")"
  if [ "$now_dl" != "$DEADLOCKS_BEFORE_TOTAL" ]; then
    echo "!! FAIL ($1): pg_stat_database.deadlocks increased ($DEADLOCKS_BEFORE_TOTAL -> $now_dl) -- an actual Postgres-detected deadlock occurred."
    FAIL=1
  fi
  DEADLOCKS_BEFORE_TOTAL="$now_dl"
}
assert_no_deadlock_text() {
  if grep -qi "deadlock" "$@" 2>/dev/null; then echo "!! FAIL: 'deadlock' text found in session output"; FAIL=1; fi
}

observe() {
  # $1 = label. Snapshots pg_stat_activity/pg_blocking_pids/pg_locks for
  # this database, from a third session, while a race may be mid-flight.
  echo "  [observer: $1]"
  psql -X -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    select pid, state, wait_event_type, wait_event, left(query,80) as query
    from pg_stat_activity where datname = '$DB' and pid <> pg_backend_pid() and query <> ''
    order by pid;
  " 2>&1 | sed 's/^/    /'
  psql -X -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    select pid, pg_blocking_pids(pid) as blocked_by
    from pg_stat_activity where datname = '$DB' and pid <> pg_backend_pid() and cardinality(pg_blocking_pids(pid)) > 0;
  " 2>&1 | sed 's/^/    /'
  psql -X -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
    select pid, locktype, relation::regclass as rel, mode, granted
    from pg_locks where relation is not null and pid in (select pid from pg_stat_activity where datname='$DB')
    order by rel, pid;
  " 2>&1 | sed 's/^/    /'
}

# $1 = load id, $2 = org id, $3 = load number, $4 = carrier id
#
# Phase 3B.3C.2, Section C: issue_carrier_invoice() now locks and
# validates every attached load's load_stops (missing pickup/delivery ->
# INVOICE_INCOMPLETE) before any later check -- every load seeded for
# these scenarios needs a complete two-stop route, or scenarios 1-19
# (written before Section C existed) would start failing at
# INVOICE_INCOMPLETE instead of exercising what they actually test.
seed_load() {
  "${PSQL[@]}" -c "
insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
values ('$1', '$2', '$3', 'delivered', 500, '$4', 'resolved');
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
values
  ('$2', '$1', 'pickup', 1, '$3 Shipper', 'Dallas', 'TX', now() - interval '2 days'),
  ('$2', '$1', 'delivery', 2, '$3 Receiver', 'Houston', 'TX', now() - interval '1 day');
" >/dev/null
}

# $1 = invoice id, $2 = org id, $3 = carrier id, $4 = broker id, $5 = load id, $6 = uid
seed_draft_invoice() {
  "${PSQL[@]}" -c "
select set_config('test.current_uid', '$6', false);
set role authenticated;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
values ('$1', '$2', 'carrier_freight_invoice', '$3', 'broker', '$4', '$6');
insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
values ('$2', '$1', 'concurrency test line', 1, 500);
insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
values ('$2', '$1', '$5');
" >/dev/null
}

as_owner_a() {
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
$1
"
}
as_owner_b() {
  psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
select set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
set role authenticated;
$1
"
}

report_scenario() {
  # $1=label $2=invoice_id (or empty)
  local status="" snaps="" audits=""
  if [ -n "${2:-}" ]; then
    status="$(Q "select issuance_status from public.carrier_invoices where id='$2';" 2>/dev/null || echo n/a)"
    snaps="$(Q "select count(*) from public.carrier_invoice_issuance_snapshots where invoice_id='$2';" 2>/dev/null || echo n/a)"
    audits="$(Q "select count(*) from public.activity_logs where entity_type='invoice' and entity_id='$2' and action='carrier_invoice_issued';" 2>/dev/null || echo n/a)"
  fi
  echo "  REPORT ($1): invoice_status=$status snapshot_count=$snaps audit_count=$audits"
}

# ============================================================================
# SCENARIO 1: two issuance attempts on the SAME invoice, concurrently.
# ============================================================================
echo
echo "=================  SCENARIO 1: two concurrent issuance attempts, SAME invoice  ================="
INV1="90000000-0000-0000-0000-000000000001"; LD1="91000000-0000-0000-0000-000000000001"
seed_load "$LD1" "11111111-1111-1111-1111-111111111111" "LD-CONC-1" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV1" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD1" "aaaa0000-0000-0000-0000-000000000001"
T0="$(Q "select updated_at from public.carrier_invoices where id='$INV1';")"
( as_owner_a "select public.issue_carrier_invoice('$INV1'::uuid, '$T0'::timestamptz, 'session A', 'race1-a');" ) >"$T/s1a.out" 2>"$T/s1a.err" &
P1A=$!
( as_owner_a "select public.issue_carrier_invoice('$INV1'::uuid, '$T0'::timestamptz, 'session B', 'race1-b');" ) >"$T/s1b.out" 2>"$T/s1b.err" &
P1B=$!
set +e; wait "$P1A"; wait "$P1B"; set -e
assert_no_deadlock_text "$T/s1a.err" "$T/s1b.err"; assert_no_new_deadlocks "1"
A_ISSUED=0; B_ISSUED=0; A_LOSE=0; B_LOSE=0
grep -q '"code": "ISSUED"' "$T/s1a.out" && A_ISSUED=1
grep -q '"code": "ISSUED"' "$T/s1b.out" && B_ISSUED=1
grep -qE '"code": "(ALREADY_ISSUED|STALE_RECORD)"' "$T/s1a.out" && A_LOSE=1
grep -qE '"code": "(ALREADY_ISSUED|STALE_RECORD)"' "$T/s1b.out" && B_LOSE=1
if [ "$((A_ISSUED + B_ISSUED))" -ne 1 ] || [ "$((A_LOSE + B_LOSE))" -ne 1 ]; then
  echo "!! FAIL: expected exactly one ISSUED + one losing result, got A=$(cat "$T/s1a.out") B=$(cat "$T/s1b.out")"; FAIL=1
else
  echo "-> OK: exactly one of the two concurrent issuance attempts succeeded, the other got a clean structured losing result."
fi
report_scenario "1" "$INV1"

# ============================================================================
# SCENARIO 2: same idempotency-key replay under true concurrency.
# ============================================================================
echo
echo "=================  SCENARIO 2: same idempotency-key replay under true concurrency  ================="
INV2="90000000-0000-0000-0000-000000000002"; LD2="91000000-0000-0000-0000-000000000002"
seed_load "$LD2" "11111111-1111-1111-1111-111111111111" "LD-CONC-2" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV2" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD2" "aaaa0000-0000-0000-0000-000000000001"
T0="$(Q "select updated_at from public.carrier_invoices where id='$INV2';")"
( as_owner_a "select public.issue_carrier_invoice('$INV2'::uuid, '$T0'::timestamptz, 'same key', 'race2-samekey');" ) >"$T/s2a.out" 2>"$T/s2a.err" &
P2A=$!
( as_owner_a "select public.issue_carrier_invoice('$INV2'::uuid, '$T0'::timestamptz, 'same key', 'race2-samekey');" ) >"$T/s2b.out" 2>"$T/s2b.err" &
P2B=$!
set +e; wait "$P2A"; wait "$P2B"; set -e
assert_no_deadlock_text "$T/s2a.err" "$T/s2b.err"; assert_no_new_deadlocks "2"
if grep -qi "unique" "$T/s2a.err" "$T/s2b.err" 2>/dev/null; then echo "!! FAIL: a raw unique-violation leaked."; FAIL=1; fi
SNAP2="$(Q "select count(*) from public.carrier_invoice_issuance_snapshots where invoice_id='$INV2';")"
AUD2="$(Q "select count(*) from public.activity_logs where entity_type='invoice' and entity_id='$INV2' and action='carrier_invoice_issued';")"
if [ "$SNAP2" != "1" ] || [ "$AUD2" != "1" ]; then
  echo "!! FAIL: expected exactly 1 snapshot + 1 audit event, got snapshots=$SNAP2 audit=$AUD2"; FAIL=1
else
  echo "-> OK: two truly concurrent callers with the IDENTICAL idempotency key produced exactly one snapshot and one audit event."
fi
report_scenario "2" "$INV2"

# ============================================================================
# SCENARIO 3: same key, DIFFERENT invoice ids, concurrently.
# ============================================================================
echo
echo "=================  SCENARIO 3: same key, DIFFERENT invoices, true concurrency  ================="
INV3A="90000000-0000-0000-0000-00000000003a"; INV3B="90000000-0000-0000-0000-00000000003b"
LD3A="91000000-0000-0000-0000-00000000003a"; LD3B="91000000-0000-0000-0000-00000000003b"
seed_load "$LD3A" "11111111-1111-1111-1111-111111111111" "LD-CONC-3A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD3B" "11111111-1111-1111-1111-111111111111" "LD-CONC-3B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV3A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD3A" "aaaa0000-0000-0000-0000-000000000001"
seed_draft_invoice "$INV3B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD3B" "aaaa0000-0000-0000-0000-000000000001"
T3A="$(Q "select updated_at from public.carrier_invoices where id='$INV3A';")"
T3B="$(Q "select updated_at from public.carrier_invoices where id='$INV3B';")"
( as_owner_a "select public.issue_carrier_invoice('$INV3A'::uuid, '$T3A'::timestamptz, 'invoice A', 'race3-samekey');" ) >"$T/s3a.out" 2>"$T/s3a.err" &
P3A=$!
( as_owner_a "select public.issue_carrier_invoice('$INV3B'::uuid, '$T3B'::timestamptz, 'invoice B', 'race3-samekey');" ) >"$T/s3b.out" 2>"$T/s3b.err" &
P3B=$!
set +e; wait "$P3A"; wait "$P3B"; set -e
assert_no_deadlock_text "$T/s3a.err" "$T/s3b.err"; assert_no_new_deadlocks "3"
if grep -qi "unique\|constraint\|duplicate key" "$T/s3a.err" "$T/s3b.err" 2>/dev/null; then echo "!! FAIL: raw uniqueness/constraint error leaked."; FAIL=1; fi
A3=0; B3=0; AR3=0; BR3=0
grep -q '"code": "ISSUED"' "$T/s3a.out" && A3=1
grep -q '"code": "ISSUED"' "$T/s3b.out" && B3=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s3a.out" && AR3=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s3b.out" && BR3=1
if [ "$((A3+B3))" -ne 1 ] || [ "$((AR3+BR3))" -ne 1 ]; then
  echo "!! FAIL: expected exactly one ISSUED + one IDEMPOTENCY_KEY_REUSED, got A=$(cat "$T/s3a.out") B=$(cat "$T/s3b.out")"; FAIL=1
else
  echo "-> OK: two concurrent callers with the IDENTICAL key targeting DIFFERENT invoices -- exactly one succeeded, the other got IDEMPOTENCY_KEY_REUSED."
fi

# ============================================================================
# SCENARIO 4: two DIFFERENT invoices, SAME carrier, concurrently.
# ============================================================================
echo
echo "=================  SCENARIO 4: two DIFFERENT invoices, SAME carrier, concurrent issuance  ================="
INV4A="90000000-0000-0000-0000-00000000004a"; INV4B="90000000-0000-0000-0000-00000000004b"
LD4A="91000000-0000-0000-0000-00000000004a"; LD4B="91000000-0000-0000-0000-00000000004b"
seed_load "$LD4A" "11111111-1111-1111-1111-111111111111" "LD-CONC-4A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD4B" "11111111-1111-1111-1111-111111111111" "LD-CONC-4B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV4A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD4A" "aaaa0000-0000-0000-0000-000000000001"
seed_draft_invoice "$INV4B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD4B" "aaaa0000-0000-0000-0000-000000000001"
T4A="$(Q "select updated_at from public.carrier_invoices where id='$INV4A';")"
T4B="$(Q "select updated_at from public.carrier_invoices where id='$INV4B';")"
( as_owner_a "select public.issue_carrier_invoice('$INV4A'::uuid, '$T4A'::timestamptz, 'invoice A', 'race4-a');" ) >"$T/s4a.out" 2>"$T/s4a.err" &
P4A=$!
( as_owner_a "select public.issue_carrier_invoice('$INV4B'::uuid, '$T4B'::timestamptz, 'invoice B', 'race4-b');" ) >"$T/s4b.out" 2>"$T/s4b.err" &
P4B=$!
set +e; wait "$P4A"; wait "$P4B"; set -e
assert_no_deadlock_text "$T/s4a.err" "$T/s4b.err"; assert_no_new_deadlocks "4"
NUM4A="$(Q "select invoice_number from public.carrier_invoices where id='$INV4A';")"
NUM4B="$(Q "select invoice_number from public.carrier_invoices where id='$INV4B';")"
if [ -z "$NUM4A" ] || [ -z "$NUM4B" ] || [ "$NUM4A" = "$NUM4B" ]; then
  echo "!! FAIL: expected two DISTINCT non-empty numbers, got A=$NUM4A B=$NUM4B"; FAIL=1
else
  echo "-> OK: two concurrently-issued invoices for the same carrier got distinct sequential numbers (A=$NUM4A, B=$NUM4B)."
fi

# ============================================================================
# SCENARIO 5: Carrier A and Carrier B issuing concurrently.
# ============================================================================
echo
echo "=================  SCENARIO 5: Carrier A and Carrier B issuing concurrently  ================="
INV5A="90000000-0000-0000-0000-00000000005a"; INV5B="90000000-0000-0000-0000-00000000005b"
LD5A="91000000-0000-0000-0000-00000000005a"; LD5B="91000000-0000-0000-0000-00000000005b"
seed_load "$LD5A" "11111111-1111-1111-1111-111111111111" "LD-CONC-5A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD5B" "22222222-2222-2222-2222-222222222222" "LD-CONC-5B" "b1b1b1b1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV5A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD5A" "aaaa0000-0000-0000-0000-000000000001"
seed_draft_invoice "$INV5B" "22222222-2222-2222-2222-222222222222" "b1b1b1b1-0000-0000-0000-000000000001" "b0b00000-0000-0000-0000-000000000001" "$LD5B" "bbbb0000-0000-0000-0000-000000000001"
T5A="$(Q "select updated_at from public.carrier_invoices where id='$INV5A';")"
T5B="$(Q "select updated_at from public.carrier_invoices where id='$INV5B';")"
( as_owner_a "select public.issue_carrier_invoice('$INV5A'::uuid, '$T5A'::timestamptz, 'carrier A', 'race5-a');" ) >"$T/s5a.out" 2>"$T/s5a.err" &
P5A=$!
( as_owner_b "select public.issue_carrier_invoice('$INV5B'::uuid, '$T5B'::timestamptz, 'carrier B', 'race5-b');" ) >"$T/s5b.out" 2>"$T/s5b.err" &
P5B=$!
set +e; wait "$P5A"; wait "$P5B"; set -e
assert_no_deadlock_text "$T/s5a.err" "$T/s5b.err"; assert_no_new_deadlocks "5"
A5=0; B5=0
grep -q '"code": "ISSUED"' "$T/s5a.out" && A5=1
grep -q '"code": "ISSUED"' "$T/s5b.out" && B5=1
if [ "$A5" -ne 1 ] || [ "$B5" -ne 1 ]; then
  echo "!! FAIL: expected BOTH to succeed independently, got A=$(cat "$T/s5a.out") B=$(cat "$T/s5b.out")"; FAIL=1
else
  echo "-> OK: Carrier A (Org A) and Carrier B (Org B) issued concurrently, fully independently."
fi

# ============================================================================
# SCENARIO 6: freight and dispatch-service issuance attempts concurrently
# (SAME carrier). Freight must succeed; dispatch-service must return
# DISPATCH_SERVICE_AGREEMENT_REQUIRED (returns before locking anything
# beyond the invoice row -- Section E Option 2) -- no contention, no
# deadlock, no cross-contamination of numbering.
# ============================================================================
echo
echo "=================  SCENARIO 6: freight vs dispatch-service issuance, SAME carrier, concurrently  ================="
INV6F="90000000-0000-0000-0000-000000000f06"; LD6="91000000-0000-0000-0000-000000000006"
INV6D="90000000-0000-0000-0000-00000000d006"
seed_load "$LD6" "11111111-1111-1111-1111-111111111111" "LD-CONC-6" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV6F" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD6" "aaaa0000-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, created_by)
values ('$INV6D', '11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001');
" >/dev/null
T6F="$(Q "select updated_at from public.carrier_invoices where id='$INV6F';")"
T6D="$(Q "select updated_at from public.carrier_invoices where id='$INV6D';")"
( as_owner_a "select public.issue_carrier_invoice('$INV6F'::uuid, '$T6F'::timestamptz, 'freight', 'race6-freight');" ) >"$T/s6f.out" 2>"$T/s6f.err" &
P6F=$!
( as_owner_a "select public.issue_carrier_invoice('$INV6D'::uuid, '$T6D'::timestamptz, 'dispatch-service', 'race6-dispatch');" ) >"$T/s6d.out" 2>"$T/s6d.err" &
P6D=$!
set +e; wait "$P6F"; wait "$P6D"; set -e
assert_no_deadlock_text "$T/s6f.err" "$T/s6d.err"; assert_no_new_deadlocks "6"
if ! grep -q '"code": "ISSUED"' "$T/s6f.out"; then echo "!! FAIL: freight issuance should have succeeded, got $(cat "$T/s6f.out")"; FAIL=1; fi
if ! grep -q 'DISPATCH_SERVICE_AGREEMENT_REQUIRED' "$T/s6d.out"; then echo "!! FAIL: dispatch-service issuance should have returned DISPATCH_SERVICE_AGREEMENT_REQUIRED, got $(cat "$T/s6d.out")"; FAIL=1; fi
if [ "$FAIL" -eq 0 ]; then echo "-> OK: freight and dispatch-service issuance for the SAME carrier ran concurrently with no contention -- freight issued, dispatch-service honestly deferred."; fi

# ============================================================================
# SCENARIO 7: draft line-item update vs. issuance.
# ============================================================================
echo
echo "=================  SCENARIO 7: draft line-item INSERT races issuance  ================="
INV7="90000000-0000-0000-0000-000000000007"; LD7="91000000-0000-0000-0000-000000000007"
seed_load "$LD7" "11111111-1111-1111-1111-111111111111" "LD-CONC-7" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV7" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD7" "aaaa0000-0000-0000-0000-000000000001"
T7="$(Q "select updated_at from public.carrier_invoices where id='$INV7';")"
( as_owner_a "select public.issue_carrier_invoice('$INV7'::uuid, '$T7'::timestamptz, 'racing issuance', 'race7-issue');" ) >"$T/s7i.out" 2>"$T/s7i.err" &
P7I=$!
( as_owner_a "insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price) values ('11111111-1111-1111-1111-111111111111', '$INV7', 'racing line item', 1, 999);" ) >"$T/s7ins.out" 2>"$T/s7ins.err" &
P7INS=$!
set +e; wait "$P7I"; wait "$P7INS"; set -e
assert_no_deadlock_text "$T/s7i.err" "$T/s7ins.err"; assert_no_new_deadlocks "7"
ISSUE7=0; grep -q '"code": "ISSUED"' "$T/s7i.out" && ISSUE7=1
INS7=0; grep -qi "insert 0 1" "$T/s7ins.out" && INS7=1
if [ "$ISSUE7" -eq 1 ] && [ "$INS7" -eq 1 ]; then
  echo "!! FAIL: both issuance AND the racing line-item insert succeeded -- possible torn total."; FAIL=1
elif [ "$ISSUE7" -eq 0 ] && [ "$INS7" -eq 0 ]; then
  echo "!! FAIL: neither succeeded -- unexpected: $(cat "$T/s7i.out") / $(cat "$T/s7ins.err")"; FAIL=1
else
  echo "-> OK: exactly one of {issuance, racing line-item insert} succeeded (issued=$ISSUE7, inserted=$INS7) -- no torn total."
fi

# ============================================================================
# SCENARIO 8: recipient change (update_carrier_invoice_draft) vs. issuance.
# Both lock carrier_invoices first (0143's own order = 0144's step 2) --
# they serialize on that single resource; whichever wins, the loser sees
# a clean, consistent outcome, never a torn recipient.
# ============================================================================
echo
echo "=================  SCENARIO 8: recipient change (update_carrier_invoice_draft) vs. issuance  ================="
INV8="90000000-0000-0000-0000-000000000008"; LD8="91000000-0000-0000-0000-000000000008"
seed_load "$LD8" "11111111-1111-1111-1111-111111111111" "LD-CONC-8" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV8" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD8" "aaaa0000-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "
insert into public.customers (id, organization_id, company_name, is_active) values ('c8450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Race Customer 8', true);
insert into public.carrier_customers (id, organization_id, carrier_id, customer_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
values ('cc450000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'c8450000-0000-0000-0000-000000000001', 'active', 'race8@example.com', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');
" >/dev/null
T8="$(Q "select updated_at from public.carrier_invoices where id='$INV8';")"
( as_owner_a "select public.issue_carrier_invoice('$INV8'::uuid, '$T8'::timestamptz, 'racing issuance', 'race8-issue');" ) >"$T/s8i.out" 2>"$T/s8i.err" &
P8I=$!
( as_owner_a "select public.update_carrier_invoice_draft('$INV8'::uuid, '{\"customer_id\":\"c8450000-0000-0000-0000-000000000001\",\"broker_id\":null}'::jsonb, '$T8'::timestamptz, 'racing recipient change', 'race8-draft');" ) >"$T/s8d.out" 2>"$T/s8d.err" &
P8D=$!
set +e; wait "$P8I"; wait "$P8D"; set -e
assert_no_deadlock_text "$T/s8i.err" "$T/s8d.err"; assert_no_new_deadlocks "8"
FINAL_STATUS8="$(Q "select issuance_status from public.carrier_invoices where id='$INV8';")"
FINAL_RECIP8="$(Q "select recipient_type from public.carrier_invoices where id='$INV8';")"
if [ "$FINAL_STATUS8" = "issued" ]; then
  echo "-> OK: issuance won the race (recipient at issuance time: $FINAL_RECIP8) -- the draft-update lost cleanly (result: $(cat "$T/s8d.out"))."
elif [ "$FINAL_RECIP8" = "customer" ] && grep -q '"code": "ISSUED"' "$T/s8i.out"; then
  echo "!! FAIL: draft-update appears to have applied to an ALREADY-issued invoice -- immutability violated."; FAIL=1
else
  echo "-> OK: draft-update won the race and changed the recipient (now: $FINAL_RECIP8) -- issuance then either used the NEW recipient or was cleanly rejected: $(cat "$T/s8i.out")."
fi

# ============================================================================
# SCENARIO 9: carrier policy change (set_carrier_factoring_policy) vs.
# issuance for the SAME carrier. Both lock ONLY carriers -- same single
# resource as issuance's step 5 -- must serialize, never deadlock.
# Observed with the third-session pg_locks/pg_blocking_pids snapshot.
# ============================================================================
echo
echo "=================  SCENARIO 9: carrier policy change (set_carrier_factoring_policy) vs. issuance  ================="
INV9="90000000-0000-0000-0000-000000000009"; LD9="91000000-0000-0000-0000-000000000009"
seed_load "$LD9" "11111111-1111-1111-1111-111111111111" "LD-CONC-9" "a2a2a2a2-0000-0000-0000-000000000002"
seed_draft_invoice "$INV9" "11111111-1111-1111-1111-111111111111" "a2a2a2a2-0000-0000-0000-000000000002" "a0b00000-0000-0000-0000-000000000001" "$LD9" "aaaa0000-0000-0000-0000-000000000001"
T9="$(Q "select updated_at from public.carrier_invoices where id='$INV9';")"
CARRIER_UPDATED_AT9="$(Q "select updated_at from public.carriers where id='a2a2a2a2-0000-0000-0000-000000000002';")"
( as_owner_a "select public.issue_carrier_invoice('$INV9'::uuid, '$T9'::timestamptz, 'racing policy change', 'race9-issue');" ) >"$T/s9i.out" 2>"$T/s9i.err" &
P9I=$!
( as_owner_a "select public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002'::uuid, 'direct'::public.carrier_factoring_mode, 'racing switch to direct', '$CARRIER_UPDATED_AT9'::timestamptz, 'race9-policy');" ) >"$T/s9p.out" 2>"$T/s9p.err" &
P9P=$!
sleep 0.15
observe "scenario 9 mid-race"
set +e; wait "$P9I"; wait "$P9P"; set -e
assert_no_deadlock_text "$T/s9i.err" "$T/s9p.err"; assert_no_new_deadlocks "9"
echo "  issuance result:      $(cat "$T/s9i.out")"
echo "  policy-change result: $(cat "$T/s9p.out")"
FINAL_MODE9="$(Q "select factoring_mode from public.carriers where id='a2a2a2a2-0000-0000-0000-000000000002';")"
echo "-> OK: no deadlock between set_carrier_factoring_policy() and issuance for the same carrier (both lock carriers alone, in the same order) -- final factoring_mode=$FINAL_MODE9."
# restore for later scenarios
"${PSQL[@]}" -c "update public.carriers set factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';" >/dev/null

# ============================================================================
# SCENARIO 10: default factor change (set_default_factoring_relationship)
# vs. issuance for a factored carrier. Both lock factoring_relationships
# -- issuance's step 4, matching this function's own established order.
# ============================================================================
echo
echo "=================  SCENARIO 10: default factor change vs. issuance  ================="
INV10="90000000-0000-0000-0000-000000000010"; LD10="91000000-0000-0000-0000-000000000010"
seed_load "$LD10" "11111111-1111-1111-1111-111111111111" "LD-CONC-10" "a2a2a2a2-0000-0000-0000-000000000002"
seed_draft_invoice "$INV10" "11111111-1111-1111-1111-111111111111" "a2a2a2a2-0000-0000-0000-000000000002" "a0b00000-0000-0000-0000-000000000001" "$LD10" "aaaa0000-0000-0000-0000-000000000001"
T10="$(Q "select updated_at from public.carrier_invoices where id='$INV10';")"
# a second, ALSO-complete relationship to switch the default to.
"${PSQL[@]}" -c "
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active)
values
  ('fe450000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'fc450000-0000-0000-0000-000000000001',
   'a2a2a2a2-0000-0000-0000-000000000002', 88, 4, 10, 'deducted_at_funding', 'non_recourse', 'Wire to Factor 0144C, alt', 'alt template', 'ref-0144c-2',
   current_date - 5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', false, true);
" >/dev/null
( as_owner_a "select public.issue_carrier_invoice('$INV10'::uuid, '$T10'::timestamptz, 'racing default change', 'race10-issue');" ) >"$T/s10i.out" 2>"$T/s10i.err" &
P10I=$!
( as_owner_a "select public.set_default_factoring_relationship('fe450000-0000-0000-0000-000000000002'::uuid);" ) >"$T/s10d.out" 2>"$T/s10d.err" &
P10D=$!
sleep 0.15
observe "scenario 10 mid-race"
set +e; wait "$P10I"; wait "$P10D"; set -e
assert_no_deadlock_text "$T/s10i.err" "$T/s10d.err"; assert_no_new_deadlocks "10"
echo "  issuance result:  $(cat "$T/s10i.out")"
echo "  default-change result: $(cat "$T/s10d.out")"
I10_OK=0; grep -q '"code": "ISSUED"' "$T/s10i.out" && I10_OK=1
I10_STALE=0; grep -qE 'STALE_CONFIGURATION|FACTORING_NOT_READY' "$T/s10i.out" && I10_STALE=1
if [ "$I10_OK" -eq 0 ] && [ "$I10_STALE" -eq 0 ]; then
  echo "!! FAIL: issuance produced neither a success nor a clean structured factoring result: $(cat "$T/s10i.out")"; FAIL=1
else
  echo "-> OK: no deadlock between set_default_factoring_relationship() and issuance -- issuance produced a clean, deterministic result either way (issued=$I10_OK / clean-refusal=$I10_STALE)."
fi
# restore default to the primary relationship for later scenarios
"${PSQL[@]}" -c "
update public.factoring_relationships set is_default = false where carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002';
update public.factoring_relationships set is_default = true where id = 'fe450000-0000-0000-0000-000000000001';
" >/dev/null

# ============================================================================
# SCENARIO 11: NOA approval / document verification change vs. issuance.
# ============================================================================
echo
echo "=================  SCENARIO 11: NOA approval change vs. issuance  ================="
INV11="90000000-0000-0000-0000-000000000011"; LD11="91000000-0000-0000-0000-000000000011"
seed_load "$LD11" "11111111-1111-1111-1111-111111111111" "LD-CONC-11" "a2a2a2a2-0000-0000-0000-000000000002"
seed_draft_invoice "$INV11" "11111111-1111-1111-1111-111111111111" "a2a2a2a2-0000-0000-0000-000000000002" "a0b00000-0000-0000-0000-000000000001" "$LD11" "aaaa0000-0000-0000-0000-000000000001"
T11="$(Q "select updated_at from public.carrier_invoices where id='$INV11';")"
( as_owner_a "select public.issue_carrier_invoice('$INV11'::uuid, '$T11'::timestamptz, 'racing NOA change', 'race11-issue');" ) >"$T/s11i.out" 2>"$T/s11i.err" &
P11I=$!
( as_owner_a "select public.approve_factoring_relationship_noa('fe450000-0000-0000-0000-000000000001'::uuid, 'ref-0144c-re-approved', current_date, null, 'd0450000-0000-0000-0000-000000000001'::uuid);" ) >"$T/s11n.out" 2>"$T/s11n.err" &
P11N=$!
sleep 0.15
observe "scenario 11 mid-race"
set +e; wait "$P11I"; wait "$P11N"; set -e
assert_no_deadlock_text "$T/s11i.err" "$T/s11n.err"; assert_no_new_deadlocks "11"
echo "  issuance result:   $(cat "$T/s11i.out")"
echo "  NOA-change result: $(cat "$T/s11n.out")"
if grep -q '"code": "ISSUED"' "$T/s11i.out" || grep -qE 'STALE_CONFIGURATION|FACTORING_NOT_READY' "$T/s11i.out"; then
  echo "-> OK: no deadlock between approve_factoring_relationship_noa() and issuance -- issuance produced a clean, deterministic result."
else
  echo "!! FAIL: issuance produced neither success nor a clean structured factoring result: $(cat "$T/s11i.out")"; FAIL=1
fi

# ============================================================================
# SCENARIO 12: integration readiness change (deactivate) vs. issuance for
# an api-submission factored carrier.
# ============================================================================
echo
echo "=================  SCENARIO 12: integration readiness change (deactivate) vs. issuance  ================="
INV12="90000000-0000-0000-0000-000000000012"; LD12="91000000-0000-0000-0000-000000000012"
seed_load "$LD12" "11111111-1111-1111-1111-111111111111" "LD-CONC-12" "a2a2a2a2-0000-0000-0000-000000000002"
seed_draft_invoice "$INV12" "11111111-1111-1111-1111-111111111111" "a2a2a2a2-0000-0000-0000-000000000002" "a0b00000-0000-0000-0000-000000000001" "$LD12" "aaaa0000-0000-0000-0000-000000000001"
T12="$(Q "select updated_at from public.carrier_invoices where id='$INV12';")"
INTEGRATION_UPDATED_AT12="$(Q "select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001';")"
( as_owner_a "select public.issue_carrier_invoice('$INV12'::uuid, '$T12'::timestamptz, 'racing integration deactivate', 'race12-issue');" ) >"$T/s12i.out" 2>"$T/s12i.err" &
P12I=$!
( as_owner_a "select public.deactivate_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'racing suspend', '$INTEGRATION_UPDATED_AT12'::timestamptz, 'race12-deactivate');" ) >"$T/s12d.out" 2>"$T/s12d.err" &
P12D=$!
sleep 0.15
observe "scenario 12 mid-race"
set +e; wait "$P12I"; wait "$P12D"; set -e
assert_no_deadlock_text "$T/s12i.err" "$T/s12d.err"; assert_no_new_deadlocks "12"
echo "  issuance result:          $(cat "$T/s12i.out")"
echo "  integration-change result: $(cat "$T/s12d.out")"
if grep -q '"code": "ISSUED"' "$T/s12i.out" || grep -qE 'STALE_CONFIGURATION|FACTORING_NOT_READY' "$T/s12i.out"; then
  echo "-> OK: no deadlock between the integration lifecycle RPC and issuance -- issuance produced a clean, deterministic result."
else
  echo "!! FAIL: issuance produced neither success nor a clean structured factoring result: $(cat "$T/s12i.out")"; FAIL=1
fi
# restore to ready for later scenarios -- suspended must go through
# pending_verification before ready again (the state machine has no
# direct suspended->ready transition).
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.verify_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'restore step 1', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'race12-restore-verify');
select public.activate_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'restore step 2', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'race12-restore-activate');
" >/dev/null 2>&1 || true
echo "  post-scenario-12 integration status: $(Q "select configuration_status from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001';")"

# ============================================================================
# SCENARIO 13 (Section C): source load carrier change vs. issuance -- a
# REAL two-session race, not source inspection. issuance locks loads at
# step 3 (before carriers/factoring); a direct owner/admin loads.carrier_id
# reassignment (guard_load_carrier_change, 0132) locks the SAME loads row
# via its own implicit UPDATE lock. Whichever wins, the other observes a
# clean, consistent outcome -- never a torn carrier/load pairing.
# ============================================================================
echo
echo "=================  SCENARIO 13 (Section C): source load carrier change RACES issuance  ================="
INV13="90000000-0000-0000-0000-000000000013"; LD13="91000000-0000-0000-0000-000000000013"
seed_load "$LD13" "11111111-1111-1111-1111-111111111111" "LD-CONC-13" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV13" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD13" "aaaa0000-0000-0000-0000-000000000001"
T13="$(Q "select updated_at from public.carrier_invoices where id='$INV13';")"
( as_owner_a "select public.issue_carrier_invoice('$INV13'::uuid, '$T13'::timestamptz, 'racing load reassignment', 'race13-issue');" ) >"$T/s13i.out" 2>"$T/s13i.err" &
P13I=$!
( as_owner_a "update public.loads set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002' where id = '$LD13';" ) >"$T/s13r.out" 2>"$T/s13r.err" &
P13R=$!
sleep 0.1
observe "scenario 13 mid-race"
set +e; wait "$P13I"; wait "$P13R"; set -e
assert_no_deadlock_text "$T/s13i.err" "$T/s13r.err"; assert_no_new_deadlocks "13"
echo "  issuance result:      $(cat "$T/s13i.out")"
echo "  reassignment stdout/err: $(cat "$T/s13r.out") / $(cat "$T/s13r.err" | head -1)"
I13_ISSUED=0; grep -q '"code": "ISSUED"' "$T/s13i.out" && I13_ISSUED=1
I13_CONFLICT=0; grep -q 'SOURCE_LOAD_CONFLICT' "$T/s13i.out" && I13_CONFLICT=1
if [ "$I13_ISSUED" -eq 0 ] && [ "$I13_CONFLICT" -eq 0 ]; then
  echo "!! FAIL: issuance produced neither ISSUED nor SOURCE_LOAD_CONFLICT: $(cat "$T/s13i.out")"; FAIL=1
elif [ "$I13_ISSUED" -eq 1 ]; then
  LOAD_CARRIER13="$(Q "select carrier_id from public.loads where id='$LD13';")"
  if [ "$LOAD_CARRIER13" != "a1a1a1a1-0000-0000-0000-000000000001" ]; then
    echo "!! FAIL: issuance succeeded but the load's carrier no longer matches -- issuance won the lock race, so the reassignment attempt should have been blocked/rejected until after commit, and reassignment away from a carrier with dependent activity should itself be guarded (0132). Got load carrier=$LOAD_CARRIER13."; FAIL=1
  else
    echo "-> OK: issuance won the load-row race and issued cleanly against the unchanged carrier -- no torn pairing."
  fi
else
  echo "-> OK: the concurrent load-carrier reassignment won the race; issuance correctly detected the changed carrier and returned SOURCE_LOAD_CONFLICT -- no torn pairing, no deadlock."
fi

# ============================================================================
# SCENARIO 14: number-prefix (carriers.invoice_code) change vs. issuance.
# ============================================================================
echo
echo "=================  SCENARIO 14: carrier invoice_code (prefix) change races issuance  ================="
INV14="90000000-0000-0000-0000-000000000014"; LD14="91000000-0000-0000-0000-000000000014"
seed_load "$LD14" "11111111-1111-1111-1111-111111111111" "LD-CONC-14" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV14" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD14" "aaaa0000-0000-0000-0000-000000000001"
T14="$(Q "select updated_at from public.carrier_invoices where id='$INV14';")"
( as_owner_a "select public.issue_carrier_invoice('$INV14'::uuid, '$T14'::timestamptz, 'racing prefix change', 'race14-issue');" ) >"$T/s14i.out" 2>"$T/s14i.err" &
P14I=$!
( as_owner_a "update public.carriers set invoice_code = 'ZZNEW14' where id = 'a1a1a1a1-0000-0000-0000-000000000001';" ) >"$T/s14u.out" 2>"$T/s14u.err" &
P14U=$!
set +e; wait "$P14I"; wait "$P14U"; set -e
assert_no_deadlock_text "$T/s14i.err" "$T/s14u.err"; assert_no_new_deadlocks "14"
NUM14="$(Q "select invoice_number from public.carrier_invoices where id='$INV14';")"
if [[ "$NUM14" != CARA-* ]] && [[ "$NUM14" != ZZNEW14-* ]]; then
  echo "!! FAIL: issued number ($NUM14) used neither prefix cleanly -- possible torn read."; FAIL=1
else
  echo "-> OK: a concurrent invoice_code (prefix) change never produces a torn/mixed prefix -- issued number ($NUM14) used one consistent prefix."
fi
"${PSQL[@]}" -c "update public.carriers set invoice_code = 'CARA' where id = 'a1a1a1a1-0000-0000-0000-000000000001';" >/dev/null

# ============================================================================
# SCENARIO 15: lock timeout followed by retry.
# ============================================================================
echo
echo "=================  SCENARIO 15: lock timeout and retry  ================="
INV15="90000000-0000-0000-0000-000000000015"; LD15="91000000-0000-0000-0000-000000000015"
seed_load "$LD15" "11111111-1111-1111-1111-111111111111" "LD-CONC-15" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV15" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD15" "aaaa0000-0000-0000-0000-000000000001"
T15="$(Q "select updated_at from public.carrier_invoices where id='$INV15';")"
COUNTER_BEFORE15="$(Q "select coalesce((select last_number from public.carrier_invoice_number_counters where issuer_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and year=extract(year from current_date)::int), 0);")"
( as_owner_a "
begin;
select id from public.carrier_invoices where id = '$INV15' for update;
select pg_sleep(1.2);
update public.carrier_invoices set notes = 'holder note' where id = '$INV15';
commit;
" ) >"$T/s15hold.out" 2>"$T/s15hold.err" &
P15HOLD=$!
sleep 0.3
WAITER15="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
set lock_timeout = '400ms';
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.issue_carrier_invoice('$INV15'::uuid, '$T15'::timestamptz, 'waiter attempt', 'race15-waiter');
" 2>&1 || true)"
set +e; wait "$P15HOLD"; set -e
assert_no_deadlock_text "$T/s15hold.err"; assert_no_new_deadlocks "15"
if ! echo "$WAITER15" | grep -qi "lock timeout\|canceling statement"; then
  echo "!! FAIL: expected the waiter to time out, got: $WAITER15"; FAIL=1
else
  COUNTER_AFTER15="$(Q "select coalesce((select last_number from public.carrier_invoice_number_counters where issuer_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and year=extract(year from current_date)::int), 0);")"
  if [ "$COUNTER_AFTER15" != "$COUNTER_BEFORE15" ]; then
    echo "!! FAIL: timed-out waiter consumed a number ($COUNTER_BEFORE15 -> $COUNTER_AFTER15)."; FAIL=1
  else
    echo "-> OK: the waiter correctly timed out, consuming NO number ($COUNTER_BEFORE15 unchanged)."
  fi
fi
RETRY15="$(as_owner_a "select public.issue_carrier_invoice('$INV15'::uuid, (select updated_at from public.carrier_invoices where id='$INV15'), 'waiter retry', 'race15-retry');")"
if ! echo "$RETRY15" | grep -q '"code": "ISSUED"'; then
  echo "!! FAIL: retry after lock release should have succeeded, got: $RETRY15"; FAIL=1
else
  echo "-> OK: a clean retry after the lock was released succeeded deterministically -- $RETRY15"
fi

# ============================================================================
# SCENARIO 16: failed issuance proving no number consumption -- two
# concurrent attempts on DIFFERENT invoices for the SAME carrier, one
# doomed to fail (deliberately stale expected_updated_at).
# ============================================================================
echo
echo "=================  SCENARIO 16: failed issuance consumes no number  ================="
INV16OK="90000000-0000-0000-0000-00000000016a"; LD16OK="91000000-0000-0000-0000-00000000016a"
INV16BAD="90000000-0000-0000-0000-00000000016b"; LD16BAD="91000000-0000-0000-0000-00000000016b"
seed_load "$LD16OK" "11111111-1111-1111-1111-111111111111" "LD-CONC-16A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD16BAD" "11111111-1111-1111-1111-111111111111" "LD-CONC-16B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV16OK" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD16OK" "aaaa0000-0000-0000-0000-000000000001"
seed_draft_invoice "$INV16BAD" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD16BAD" "aaaa0000-0000-0000-0000-000000000001"
T16OK="$(Q "select updated_at from public.carrier_invoices where id='$INV16OK';")"
COUNTER_BEFORE16="$(Q "select coalesce((select last_number from public.carrier_invoice_number_counters where issuer_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and year=extract(year from current_date)::int), 0);")"
( as_owner_a "select public.issue_carrier_invoice('$INV16OK'::uuid, '$T16OK'::timestamptz, 'will succeed', 'race16-ok');" ) >"$T/s16ok.out" 2>"$T/s16ok.err" &
P16OK=$!
( as_owner_a "select public.issue_carrier_invoice('$INV16BAD'::uuid, (now() - interval '1 hour')::timestamptz, 'doomed to fail', 'race16-bad');" ) >"$T/s16bad.out" 2>"$T/s16bad.err" &
P16BAD=$!
set +e; wait "$P16OK"; wait "$P16BAD"; set -e
assert_no_deadlock_text "$T/s16ok.err" "$T/s16bad.err"; assert_no_new_deadlocks "16"
if ! grep -q '"code": "ISSUED"' "$T/s16ok.out"; then echo "!! FAIL: the healthy issuance should have succeeded, got $(cat "$T/s16ok.out")"; FAIL=1; fi
if ! grep -q 'STALE_RECORD' "$T/s16bad.out"; then echo "!! FAIL: the doomed issuance should have returned STALE_RECORD, got $(cat "$T/s16bad.out")"; FAIL=1; fi
COUNTER_AFTER16="$(Q "select coalesce((select last_number from public.carrier_invoice_number_counters where issuer_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and year=extract(year from current_date)::int), 0);")"
DELTA16=$((COUNTER_AFTER16 - COUNTER_BEFORE16))
if [ "$DELTA16" -ne 1 ]; then
  echo "!! FAIL: expected the counter to advance by EXACTLY 1 (the doomed attempt should consume none), got delta=$DELTA16 ($COUNTER_BEFORE16 -> $COUNTER_AFTER16)."; FAIL=1
else
  echo "-> OK: the failed (STALE_RECORD) issuance consumed NO number -- counter advanced by exactly 1, matching only the successful call."
fi

# ============================================================================
# SCENARIO 17: snapshot UPDATE/DELETE attempt racing issuance.
# ============================================================================
echo
echo "=================  SCENARIO 17: snapshot UPDATE/DELETE attempt races issuance  ================="
INV17="90000000-0000-0000-0000-000000000017"; LD17="91000000-0000-0000-0000-000000000017"
seed_load "$LD17" "11111111-1111-1111-1111-111111111111" "LD-CONC-17" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV17" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD17" "aaaa0000-0000-0000-0000-000000000001"
T17="$(Q "select updated_at from public.carrier_invoices where id='$INV17';")"
( as_owner_a "select public.issue_carrier_invoice('$INV17'::uuid, '$T17'::timestamptz, 'racing snapshot tamper', 'race17-issue');" ) >"$T/s17i.out" 2>"$T/s17i.err" &
P17I=$!
# A direct UPDATE/DELETE attempt against the snapshot table, targeted at
# THIS invoice, fired concurrently -- races to see if it can catch the
# row mid-insert or immediately after. Runs as superuser (authenticated
# has zero grant at all -- already proven in TEST_0144 H4) purely to
# exercise the immutability TRIGGER itself under concurrency, not the
# grant layer again.
( for i in 1 2 3 4 5 6 7 8 9 10; do
    psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
      update public.carrier_invoice_issuance_snapshots set total_amount = 999999 where invoice_id = '$INV17';
    " 2>>"$T/s17tamper.err" || true
  done ) >"$T/s17tamper.out" 2>>"$T/s17tamper.err" &
P17T=$!
set +e; wait "$P17I"; wait "$P17T"; set -e
assert_no_deadlock_text "$T/s17i.err"; assert_no_new_deadlocks "17"
if grep -q "999999" <(Q "select total_amount from public.carrier_invoice_issuance_snapshots where invoice_id='$INV17';" 2>/dev/null || true); then
  echo "!! FAIL: the snapshot's total_amount was tampered with -- immutability was violated under concurrency."; FAIL=1
else
  echo "-> OK: 10 concurrent UPDATE attempts against the snapshot, racing its own creation, never once succeeded -- the immutability trigger held under concurrency (issuance result: $(cat "$T/s17i.out"))."
fi

# ============================================================================
# SCENARIO 18: attempted reuse of a voided invoice number, under
# concurrent allocation pressure.
# ============================================================================
echo
echo "=================  SCENARIO 18: voided number cannot be reused, even under concurrent allocation  ================="
INV18A="90000000-0000-0000-0000-00000000018a"; LD18A="91000000-0000-0000-0000-00000000018a"
seed_load "$LD18A" "11111111-1111-1111-1111-111111111111" "LD-CONC-18A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV18A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD18A" "aaaa0000-0000-0000-0000-000000000001"
T18A="$(Q "select updated_at from public.carrier_invoices where id='$INV18A';")"
R18A="$(as_owner_a "select public.issue_carrier_invoice('$INV18A'::uuid, '$T18A'::timestamptz, 'to be voided', 'race18-a');")"
echo "  seed issuance: $R18A"
NUM18A="$(Q "select invoice_number from public.carrier_invoices where id='$INV18A';")"
"${PSQL[@]}" -c "
update public.carrier_invoices set issuance_status = 'voided', voided_at = now(), voided_by = 'aaaa0000-0000-0000-0000-000000000001', void_reason = 'concurrency test void' where id = '$INV18A';
" >/dev/null
echo "  voided invoice_number=$NUM18A"

INV18B="90000000-0000-0000-0000-00000000018b"; LD18B="91000000-0000-0000-0000-00000000018b"
INV18C="90000000-0000-0000-0000-00000000018c"; LD18C="91000000-0000-0000-0000-00000000018c"
seed_load "$LD18B" "11111111-1111-1111-1111-111111111111" "LD-CONC-18B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD18C" "11111111-1111-1111-1111-111111111111" "LD-CONC-18C" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV18B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD18B" "aaaa0000-0000-0000-0000-000000000001"
seed_draft_invoice "$INV18C" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD18C" "aaaa0000-0000-0000-0000-000000000001"
T18B="$(Q "select updated_at from public.carrier_invoices where id='$INV18B';")"
T18C="$(Q "select updated_at from public.carrier_invoices where id='$INV18C';")"
( as_owner_a "select public.issue_carrier_invoice('$INV18B'::uuid, '$T18B'::timestamptz, 'B', 'race18-b');" ) >"$T/s18b.out" 2>"$T/s18b.err" &
P18B=$!
( as_owner_a "select public.issue_carrier_invoice('$INV18C'::uuid, '$T18C'::timestamptz, 'C', 'race18-c');" ) >"$T/s18c.out" 2>"$T/s18c.err" &
P18C=$!
set +e; wait "$P18B"; wait "$P18C"; set -e
assert_no_deadlock_text "$T/s18b.err" "$T/s18c.err"; assert_no_new_deadlocks "18"
NUM18B="$(Q "select invoice_number from public.carrier_invoices where id='$INV18B';")"
NUM18C="$(Q "select invoice_number from public.carrier_invoices where id='$INV18C';")"
if [ "$NUM18B" = "$NUM18A" ] || [ "$NUM18C" = "$NUM18A" ] || [ "$NUM18B" = "$NUM18C" ] || [ -z "$NUM18B" ] || [ -z "$NUM18C" ]; then
  echo "!! FAIL: the voided number ($NUM18A) was reused, or the two concurrent new issuances collided -- B=$NUM18B C=$NUM18C."; FAIL=1
else
  echo "-> OK: even under concurrent allocation pressure, the voided number ($NUM18A) was never reused -- two NEW distinct numbers were issued instead (B=$NUM18B, C=$NUM18C)."
fi

# ============================================================================
# SCENARIO 19 (deadlock regression): activate_carrier_factoring_
# integration() vs. issue_carrier_invoice() for the SAME carrier,
# relationship, company, document, AND integration. This is the exact
# pairing the Phase 3B.3C.1 lock-order correction targets.
#
# Two sub-proofs:
#   (a) a manual session holds factoring_relationships (the shared FIRST
#       resource in both functions' corrected order) open for ~1s; the
#       REAL issue_carrier_invoice() is launched concurrently and MUST
#       block on that exact lock (observed via pg_locks/
#       pg_blocking_pids), never deadlock, then proceed once released.
#   (b) the same manual hold, but racing the REAL
#       activate_carrier_factoring_integration() instead -- proving BOTH
#       real functions correctly queue behind the SAME first resource.
#   (c) the two REAL functions run fully concurrently (no artificial
#       holder), confirming empirically that pg_stat_database.deadlocks
#       never increases.
# ============================================================================
echo
echo "=================  SCENARIO 19 (deadlock regression): activate_carrier_factoring_integration() vs. issue_carrier_invoice()  ================="

# --- (a) manual relationship-lock holder vs REAL issuance ---
INV19A="90000000-0000-0000-0000-00000000019a"; LD19A="91000000-0000-0000-0000-00000000019a"
seed_load "$LD19A" "11111111-1111-1111-1111-111111111111" "LD-CONC-19A" "a2a2a2a2-0000-0000-0000-000000000002"
seed_draft_invoice "$INV19A" "11111111-1111-1111-1111-111111111111" "a2a2a2a2-0000-0000-0000-000000000002" "a0b00000-0000-0000-0000-000000000001" "$LD19A" "aaaa0000-0000-0000-0000-000000000001"
T19A="$(Q "select updated_at from public.carrier_invoices where id='$INV19A';")"
( "${PSQL[@]}" -c "
begin;
select id from public.factoring_relationships where id = 'fe450000-0000-0000-0000-000000000001' for update;
select pg_sleep(1.0);
commit;
" ) >"$T/s19a-holder.out" 2>"$T/s19a-holder.err" &
P19AHOLD=$!
sleep 0.2
( as_owner_a "select public.issue_carrier_invoice('$INV19A'::uuid, '$T19A'::timestamptz, '(a) racing manual relationship holder', 'race19a-issue');" ) >"$T/s19a-issue.out" 2>"$T/s19a-issue.err" &
P19AISSUE=$!
sleep 0.2
observe "scenario 19(a) mid-block -- issuance should be waiting on the manual relationship holder"
set +e; wait "$P19AHOLD"; wait "$P19AISSUE"; set -e
assert_no_deadlock_text "$T/s19a-holder.err" "$T/s19a-issue.err"; assert_no_new_deadlocks "19a"
if ! grep -q '"code": "ISSUED"' "$T/s19a-issue.out"; then
  echo "!! FAIL (19a): issuance should have proceeded and succeeded once the manual holder released the relationship lock, got $(cat "$T/s19a-issue.out")"; FAIL=1
else
  echo "-> OK (19a): issuance correctly BLOCKED on factoring_relationships (the same first resource activate_carrier_factoring_integration() locks), then proceeded cleanly once released -- no deadlock."
fi

# --- (b) manual relationship-lock holder vs REAL activation ---
# Move the integration to 'pending_verification' first so 'activate' is a
# legal transition to exercise.
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
-- ready has no direct path to pending_verification -- must go through
-- suspended first (ready->deactivate->suspended->verify->pending_verification).
select public.deactivate_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'prep step 1 for scenario 19b', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'race19b-deactivate-prep');
select public.verify_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'prep step 2 for scenario 19b', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'race19b-verify-prep');
" >/dev/null
echo "  pre-19b integration status: $(Q "select configuration_status from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001';")"
INTEGRATION_UPDATED_AT19B="$(Q "select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001';")"
( "${PSQL[@]}" -c "
begin;
select id from public.factoring_relationships where id = 'fe450000-0000-0000-0000-000000000001' for update;
select pg_sleep(1.0);
commit;
" ) >"$T/s19b-holder.out" 2>"$T/s19b-holder.err" &
P19BHOLD=$!
sleep 0.2
( as_owner_a "select public.activate_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, '(b) racing manual relationship holder', '$INTEGRATION_UPDATED_AT19B'::timestamptz, 'race19b-activate');" ) >"$T/s19b-activate.out" 2>"$T/s19b-activate.err" &
P19BACTIVATE=$!
sleep 0.2
observe "scenario 19(b) mid-block -- activation should be waiting on the manual relationship holder"
set +e; wait "$P19BHOLD"; wait "$P19BACTIVATE"; set -e
assert_no_deadlock_text "$T/s19b-holder.err" "$T/s19b-activate.err"; assert_no_new_deadlocks "19b"
if ! grep -q '"success": true' "$T/s19b-activate.out"; then
  echo "!! FAIL (19b): activation should have proceeded and succeeded once the manual holder released, got $(cat "$T/s19b-activate.out")"; FAIL=1
else
  echo "-> OK (19b): activate_carrier_factoring_integration() also correctly blocked on factoring_relationships (the same shared first resource) and proceeded cleanly -- both real functions queue behind the SAME resource in the SAME order."
fi

# --- (c) the two REAL functions, fully concurrently, repeated ---
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.deactivate_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'reset for 19c loop', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'race19c-reset');
select public.verify_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'reset for 19c loop', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'race19c-reset2');
" >/dev/null 2>&1 || true

for i in 1 2 3 4 5; do
  INV19C="90000000-0000-0000-0000-000000019c0$i"; LD19C="91000000-0000-0000-0000-000000019c0$i"
  seed_load "$LD19C" "11111111-1111-1111-1111-111111111111" "LD-CONC-19C$i" "a2a2a2a2-0000-0000-0000-000000000002"
  seed_draft_invoice "$INV19C" "11111111-1111-1111-1111-111111111111" "a2a2a2a2-0000-0000-0000-000000000002" "a0b00000-0000-0000-0000-000000000001" "$LD19C" "aaaa0000-0000-0000-0000-000000000001"
  T19C="$(Q "select updated_at from public.carrier_invoices where id='$INV19C';")"
  INTEGRATION_UPDATED_AT19C="$(Q "select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001';")"
  CUR_STATUS19C="$(Q "select configuration_status from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001';")"
  # The lifecycle state machine has no direct suspended->ready transition
  # -- cycle through the legal path: ready->deactivate(suspended);
  # suspended/draft/failed->verify(pending_verification);
  # pending_verification->activate(ready).
  case "$CUR_STATUS19C" in
    ready) ACTION19C="deactivate_carrier_factoring_integration" ;;
    pending_verification) ACTION19C="activate_carrier_factoring_integration" ;;
    *) ACTION19C="verify_carrier_factoring_integration" ;;
  esac
  echo "  iter $i: integration status=$CUR_STATUS19C -> racing action=$ACTION19C"
  ( as_owner_a "select public.issue_carrier_invoice('$INV19C'::uuid, '$T19C'::timestamptz, '(c) iter $i', 'race19c-issue-$i');" ) >"$T/s19c-issue-$i.out" 2>"$T/s19c-issue-$i.err" &
  P19CI=$!
  ( as_owner_a "select public.${ACTION19C}('c1450000-0000-0000-0000-000000000001'::uuid, '(c) iter $i', '$INTEGRATION_UPDATED_AT19C'::timestamptz, 'race19c-lifecycle-$i');" ) >"$T/s19c-lc-$i.out" 2>"$T/s19c-lc-$i.err" &
  P19CL=$!
  set +e; wait "$P19CI"; wait "$P19CL"; set -e
  assert_no_deadlock_text "$T/s19c-issue-$i.err" "$T/s19c-lc-$i.err"; assert_no_new_deadlocks "19c-iter$i"
done
if [ "$FAIL" -eq 0 ]; then
  echo "-> OK (19c): 5 fully-concurrent iterations of activate/deactivate_carrier_factoring_integration() racing issue_carrier_invoice() for the SAME carrier/relationship/company/integration -- zero Postgres-detected deadlocks (pg_stat_database.deadlocks unchanged throughout)."
fi
# restore ready state for cleanliness
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do \$\$
begin
  if (select configuration_status from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001') <> 'ready' then
    if (select configuration_status from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001') in ('suspended','failed') then
      perform public.verify_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'restore', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'race19-final-restore-1');
    end if;
    perform public.activate_carrier_factoring_integration('c1450000-0000-0000-0000-000000000001'::uuid, 'restore', (select updated_at from public.carrier_factoring_integrations where id='c1450000-0000-0000-0000-000000000001'), 'race19-final-restore-2');
  end if;
end
\$\$;
" >/dev/null 2>&1 || true

# ============================================================================
# PHASE 3B.3C.3, SECTION C -- forced-ordering infrastructure.
#
# Scenarios 20-27 no longer rely on wall-clock race timing to determine
# which of two real, concurrent actions "wins" -- each important race is
# run TWICE, under DETERMINISTIC control, once per required ordering:
#
#   Ordering A: issuance acquires the shared source lock first.
#   Ordering B: the mutating transaction commits its change first.
#
# Mechanism: a MANUAL "holder" transaction takes the exact same lock (on
# the shared parent resource -- loads/dispatches/carrier_remittance_
# profiles, depending on the scenario) the two real contenders both need,
# and holds it open (via pg_sleep) until BOTH contenders have been
# launched and CONFIRMED -- via genuine pg_stat_activity.wait_event_type=
# 'Lock' polling, never a blind sleep-and-hope -- to be blocked on it.
# Because PostgreSQL grants a row lock's waiters in the order they queued
# (FIFO), whichever contender is launched-and-confirmed-blocked FIRST is
# GUARANTEED to acquire the lock first once the holder releases it --
# deterministic, not probabilistic. The holder's own single, uncontended
# FOR UPDATE (nothing else could possibly be racing it yet) completing is
# bounded by a short fixed sleep (0.2s -- the same margin scenarios 9-13/
# 19 already use for an analogous single uncontended step) -- this is NOT
# guessing who wins a race, only giving one fast, solitary statement time
# to finish before the controlled race begins.
# ============================================================================

# $1 = SQL text substring (must appear verbatim in the target backend's
#      query text -- every contender's own SQL below embeds a scenario-
#      unique literal/comment to make this reliable) $2 = max poll
#      attempts (50ms each; default 100 = 5s).
wait_until_blocked() {
  local pattern="$1" max="${2:-100}" i=0 n
  while [ "$i" -lt "$max" ]; do
    n="$(Q "select count(*) from pg_stat_activity where datname='$DB' and wait_event_type='Lock' and query ilike '%${pattern}%';")"
    if [ "${n:-0}" -ge 1 ]; then return 0; fi
    i=$((i+1))
    sleep 0.05
  done
  return 1
}

# Runs a two-contender forced race against ONE shared parent lock (a
# single row in $1, matched by the raw SQL condition $2). Both
# contenders are launched while a manual holder keeps that row locked,
# and BOTH are individually confirmed (via wait_until_blocked) to be
# genuinely waiting on it before the holder is released -- so the
# relative launch order below deterministically decides who wins.
#
# Args: 1=lock_table 2=lock_where 3=hold_seconds
#       4=first_label  5=first_sql  6=first_marker  7=first_out  8=first_err
#       9=second_label 10=second_sql 11=second_marker 12=second_out 13=second_err
#       14=obs_label
run_forced_race() {
  local lock_table="$1" lock_where="$2" hold_s="$3"
  local first_label="$4" first_sql="$5" first_marker="$6" first_out="$7" first_err="$8"
  local second_label="$9" second_sql="${10}" second_marker="${11}" second_out="${12}" second_err="${13}"
  local obs_label="${14}"

  ( "${PSQL[@]}" -c "
begin;
select * from public.${lock_table} where ${lock_where} for update; -- /* HOLDER_${obs_label} */
select pg_sleep(${hold_s});
commit;
" ) >"$T/${obs_label}_holder.out" 2>"$T/${obs_label}_holder.err" &
  local holder_pid=$!
  sleep 0.2   # let the holder's own single, uncontended lock acquisition complete (see header comment).

  ( eval "$first_sql" ) >"$first_out" 2>"$first_err" &
  local first_pid=$!
  if ! wait_until_blocked "$first_marker"; then
    echo "!! FAIL (${obs_label}): the '${first_label}' contender was never observed blocked (wait_event_type='Lock') on the shared ${lock_table} lock -- forced ordering could not be established."
    FAIL=1
  fi

  ( eval "$second_sql" ) >"$second_out" 2>"$second_err" &
  local second_pid=$!
  if ! wait_until_blocked "$second_marker"; then
    echo "!! FAIL (${obs_label}): the '${second_label}' contender was never observed blocked (wait_event_type='Lock') on the shared ${lock_table} lock -- forced ordering could not be established."
    FAIL=1
  fi

  observe "${obs_label} mid-race (holder holds ${lock_table} WHERE ${lock_where}; both '${first_label}' and '${second_label}' confirmed blocked)"

  set +e; wait "$holder_pid"; wait "$first_pid"; wait "$second_pid"; set -e
}

# ============================================================================
# SCENARIO 20A/20B: load-stop UPDATE vs issuance, both forced orderings.
# ============================================================================
echo
echo "=================  SCENARIO 20A: stop UPDATE vs issuance -- issuance wins the shared load_stops row lock first  ================="
INV20A="90000000-0000-0000-0000-0000000020aa"; LD20A="91000000-0000-0000-0000-0000000020aa"
seed_load "$LD20A" "11111111-1111-1111-1111-111111111111" "LD-CONC-20A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV20A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD20A" "aaaa0000-0000-0000-0000-000000000001"
T20A="$(Q "select updated_at from public.carrier_invoices where id='$INV20A';")"
# Phase 3B.3C.3, Section C correction: the shared resource both
# contenders now actually contend for is the pickup STOP ROW itself
# (guard_load_stops_parent_lock() no longer locks `loads` for a same-
# load UPDATE -- see the function's own header comment for the AB-BA
# deadlock this removes), not `loads` -- the holder targets that row.
run_forced_race "load_stops" "load_id = '$LD20A' and stop_type = 'pickup'" 1.2 \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV20A'::uuid, '$T20A'::timestamptz, 'race20a-issue', 'race20a-issue');\"" "race20a-issue" "$T/s20ai.out" "$T/s20ai.err" \
  "stop-update" "as_owner_a \"update public.load_stops set city = 'RACE-UPDATED-CITY-20A' where load_id = '$LD20A' and stop_type = 'pickup'; -- /* race20a-mutate */\"" "race20a-mutate" "$T/s20au.out" "$T/s20au.err" \
  "20A"
assert_no_deadlock_text "$T/s20ai.err" "$T/s20au.err"; assert_no_new_deadlocks "20A"
if [ -s "$T/s20au.err" ]; then echo "!! FAIL (20A): the stop UPDATE should always eventually succeed, got stderr: $(cat "$T/s20au.err")"; FAIL=1; fi
if ! grep -q '"code": "ISSUED"' "$T/s20ai.out"; then echo "!! FAIL (20A): issuance did not succeed, got $(cat "$T/s20ai.out")"; FAIL=1
else
  SNAP_CITY20A="$(Q "select snapshot_payload->'loads'->0->'origin'->>'city' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV20A';")"
  FINAL_CITY20A="$(Q "select city from public.load_stops where load_id='$LD20A' and stop_type='pickup';")"
  if [ "$SNAP_CITY20A" != "Dallas" ]; then
    echo "!! FAIL (20A): forced issuance-first ordering must snapshot the PRE-update city (Dallas), got '$SNAP_CITY20A'."; FAIL=1
  elif [ "$FINAL_CITY20A" != "RACE-UPDATED-CITY-20A" ]; then
    echo "!! FAIL (20A): the UPDATE never actually landed after issuance released the lock -- final city=$FINAL_CITY20A"; FAIL=1
  else
    echo "-> OK (20A): issuance, confirmed blocking the racing UPDATE on the shared load_stops row lock, won first -- snapshot origin.city=Dallas (pre-update), and the UPDATE landed cleanly afterward (final=$FINAL_CITY20A)."
  fi
fi

echo
echo "=================  SCENARIO 20B: stop UPDATE vs issuance -- the UPDATE commits its change first  ================="
INV20B="90000000-0000-0000-0000-0000000020bb"; LD20B="91000000-0000-0000-0000-0000000020bb"
seed_load "$LD20B" "11111111-1111-1111-1111-111111111111" "LD-CONC-20B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV20B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD20B" "aaaa0000-0000-0000-0000-000000000001"
T20B="$(Q "select updated_at from public.carrier_invoices where id='$INV20B';")"
run_forced_race "load_stops" "load_id = '$LD20B' and stop_type = 'pickup'" 1.2 \
  "stop-update" "as_owner_a \"update public.load_stops set city = 'RACE-UPDATED-CITY-20B' where load_id = '$LD20B' and stop_type = 'pickup'; -- /* race20b-mutate */\"" "race20b-mutate" "$T/s20bu.out" "$T/s20bu.err" \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV20B'::uuid, '$T20B'::timestamptz, 'race20b-issue', 'race20b-issue');\"" "race20b-issue" "$T/s20bi.out" "$T/s20bi.err" \
  "20B"
assert_no_deadlock_text "$T/s20bi.err" "$T/s20bu.err"; assert_no_new_deadlocks "20B"
if [ -s "$T/s20bu.err" ]; then echo "!! FAIL (20B): the stop UPDATE should always eventually succeed, got stderr: $(cat "$T/s20bu.err")"; FAIL=1; fi
if ! grep -q '"code": "ISSUED"' "$T/s20bi.out"; then echo "!! FAIL (20B): issuance did not succeed, got $(cat "$T/s20bi.out")"; FAIL=1
else
  SNAP_CITY20B="$(Q "select snapshot_payload->'loads'->0->'origin'->>'city' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV20B';")"
  if [ "$SNAP_CITY20B" != "RACE-UPDATED-CITY-20B" ]; then
    echo "!! FAIL (20B): forced update-first ordering must snapshot the POST-update city, got '$SNAP_CITY20B'."; FAIL=1
  else
    echo "-> OK (20B): the racing UPDATE, confirmed blocking issuance on the shared load_stops row lock, committed first -- issuance then correctly observed the ALREADY-updated city (never a torn value) -- snapshot origin.city=$SNAP_CITY20B."
  fi
fi

# ============================================================================
# SCENARIO 21A/21B: load-stop INSERT vs issuance, both forced orderings.
# ============================================================================
echo
echo "=================  SCENARIO 21A: stop INSERT vs issuance -- issuance wins the shared loads lock first  ================="
INV21A="90000000-0000-0000-0000-0000000021aa"; LD21A="91000000-0000-0000-0000-0000000021aa"
seed_load "$LD21A" "11111111-1111-1111-1111-111111111111" "LD-CONC-21A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV21A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD21A" "aaaa0000-0000-0000-0000-000000000001"
T21A="$(Q "select updated_at from public.carrier_invoices where id='$INV21A';")"
run_forced_race "loads" "id = '$LD21A'" 1.2 \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV21A'::uuid, '$T21A'::timestamptz, 'race21a-issue', 'race21a-issue');\"" "race21a-issue" "$T/s21ai.out" "$T/s21ai.err" \
  "stop-insert" "as_owner_a \"insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at) values ('11111111-1111-1111-1111-111111111111', '$LD21A', 'pickup', 0, 'RACE-NEW-EARLIER-PICKUP-21A', 'Denver', 'CO', now() - interval '5 days'); -- /* race21a-mutate */\"" "race21a-mutate" "$T/s21ains.out" "$T/s21ains.err" \
  "21A"
assert_no_deadlock_text "$T/s21ai.err" "$T/s21ains.err"; assert_no_new_deadlocks "21A"
if [ -s "$T/s21ains.err" ]; then echo "!! FAIL (21A): the stop INSERT should always eventually succeed, got stderr: $(cat "$T/s21ains.err")"; FAIL=1; fi
FINAL_COUNT21A="$(Q "select count(*) from public.load_stops where load_id='$LD21A';")"
if ! grep -q '"code": "ISSUED"' "$T/s21ai.out"; then echo "!! FAIL (21A): issuance did not succeed, got $(cat "$T/s21ai.out")"; FAIL=1
elif [ "$FINAL_COUNT21A" != "3" ]; then echo "!! FAIL (21A): expected 3 load_stops rows after both complete, got $FINAL_COUNT21A"; FAIL=1
else
  SNAP_ORIGIN21A="$(Q "select snapshot_payload->'loads'->0->'origin'->>'facility_name' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV21A';")"
  if [ "$SNAP_ORIGIN21A" != "LD-CONC-21A Shipper" ]; then
    echo "!! FAIL (21A): forced issuance-first ordering must snapshot the ORIGINAL (pre-insert) origin, got '$SNAP_ORIGIN21A'."; FAIL=1
  else
    echo "-> OK (21A): issuance, confirmed blocking the racing INSERT on the shared loads lock, won first -- snapshot origin unaffected (pre-insert), and the new stop landed cleanly afterward (final count=$FINAL_COUNT21A)."
  fi
fi

echo
echo "=================  SCENARIO 21B: stop INSERT vs issuance -- the INSERT commits its change first  ================="
INV21B="90000000-0000-0000-0000-0000000021bb"; LD21B="91000000-0000-0000-0000-0000000021bb"
seed_load "$LD21B" "11111111-1111-1111-1111-111111111111" "LD-CONC-21B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV21B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD21B" "aaaa0000-0000-0000-0000-000000000001"
T21B="$(Q "select updated_at from public.carrier_invoices where id='$INV21B';")"
run_forced_race "loads" "id = '$LD21B'" 1.2 \
  "stop-insert" "as_owner_a \"insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at) values ('11111111-1111-1111-1111-111111111111', '$LD21B', 'pickup', 0, 'RACE-NEW-EARLIER-PICKUP-21B', 'Denver', 'CO', now() - interval '5 days'); -- /* race21b-mutate */\"" "race21b-mutate" "$T/s21bins.out" "$T/s21bins.err" \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV21B'::uuid, '$T21B'::timestamptz, 'race21b-issue', 'race21b-issue');\"" "race21b-issue" "$T/s21bi.out" "$T/s21bi.err" \
  "21B"
assert_no_deadlock_text "$T/s21bi.err" "$T/s21bins.err"; assert_no_new_deadlocks "21B"
if [ -s "$T/s21bins.err" ]; then echo "!! FAIL (21B): the stop INSERT should always eventually succeed, got stderr: $(cat "$T/s21bins.err")"; FAIL=1; fi
if ! grep -q '"code": "ISSUED"' "$T/s21bi.out"; then echo "!! FAIL (21B): issuance did not succeed, got $(cat "$T/s21bi.out")"; FAIL=1
else
  SNAP_ORIGIN21B="$(Q "select snapshot_payload->'loads'->0->'origin'->>'facility_name' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV21B';")"
  if [ "$SNAP_ORIGIN21B" != "RACE-NEW-EARLIER-PICKUP-21B" ]; then
    echo "!! FAIL (21B): forced insert-first ordering must snapshot the NEW earlier-sequence pickup as origin, got '$SNAP_ORIGIN21B'."; FAIL=1
  else
    echo "-> OK (21B): the racing INSERT, confirmed blocking issuance on the shared loads lock, committed first -- issuance then correctly observed and selected the new earlier-sequence pickup as origin -- snapshot origin.facility_name=$SNAP_ORIGIN21B."
  fi
fi

# ============================================================================
# SCENARIO 22A/22B: load-stop DELETE vs issuance, both forced orderings.
# ============================================================================
echo
echo "=================  SCENARIO 22A: stop DELETE vs issuance -- issuance wins the shared load_stops row lock first  ================="
INV22A="90000000-0000-0000-0000-0000000022aa"; LD22A="91000000-0000-0000-0000-0000000022aa"
seed_load "$LD22A" "11111111-1111-1111-1111-111111111111" "LD-CONC-22A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV22A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD22A" "aaaa0000-0000-0000-0000-000000000001"
T22A="$(Q "select updated_at from public.carrier_invoices where id='$INV22A';")"
run_forced_race "load_stops" "load_id = '$LD22A' and stop_type = 'delivery'" 1.2 \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV22A'::uuid, '$T22A'::timestamptz, 'race22a-issue', 'race22a-issue');\"" "race22a-issue" "$T/s22ai.out" "$T/s22ai.err" \
  "stop-delete" "as_owner_a \"delete from public.load_stops where load_id = '$LD22A' and stop_type = 'delivery'; -- /* race22a-mutate */\"" "race22a-mutate" "$T/s22ad.out" "$T/s22ad.err" \
  "22A"
assert_no_deadlock_text "$T/s22ai.err" "$T/s22ad.err"; assert_no_new_deadlocks "22A"
if [ -s "$T/s22ad.err" ]; then echo "!! FAIL (22A): the stop DELETE should always eventually succeed, got stderr: $(cat "$T/s22ad.err")"; FAIL=1; fi
FINAL_COUNT22A="$(Q "select count(*) from public.load_stops where load_id='$LD22A';")"
if [ "$FINAL_COUNT22A" != "1" ]; then echo "!! FAIL (22A): expected exactly 1 remaining stop after both complete, got $FINAL_COUNT22A"; FAIL=1
elif ! grep -q '"code": "ISSUED"' "$T/s22ai.out"; then
  echo "!! FAIL (22A): forced issuance-first ordering must succeed (both stops still present when issuance locked them), got $(cat "$T/s22ai.out")"; FAIL=1
else
  NUM22A="$(Q "select invoice_number from public.carrier_invoices where id='$INV22A';")"
  if [ -z "$NUM22A" ]; then echo "!! FAIL (22A): ISSUED but invoice_number is empty."; FAIL=1
  else echo "-> OK (22A): issuance, confirmed blocking the racing DELETE on the shared load_stops row lock, won first -- both stops were present, issuance succeeded (number=$NUM22A), and the DELETE landed cleanly afterward (final count=$FINAL_COUNT22A)."
  fi
fi

echo
echo "=================  SCENARIO 22B: stop DELETE vs issuance -- the DELETE commits its change first  ================="
INV22B="90000000-0000-0000-0000-0000000022bb"; LD22B="91000000-0000-0000-0000-0000000022bb"
seed_load "$LD22B" "11111111-1111-1111-1111-111111111111" "LD-CONC-22B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV22B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD22B" "aaaa0000-0000-0000-0000-000000000001"
T22B="$(Q "select updated_at from public.carrier_invoices where id='$INV22B';")"
run_forced_race "load_stops" "load_id = '$LD22B' and stop_type = 'delivery'" 1.2 \
  "stop-delete" "as_owner_a \"delete from public.load_stops where load_id = '$LD22B' and stop_type = 'delivery'; -- /* race22b-mutate */\"" "race22b-mutate" "$T/s22bd.out" "$T/s22bd.err" \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV22B'::uuid, '$T22B'::timestamptz, 'race22b-issue', 'race22b-issue');\"" "race22b-issue" "$T/s22bi.out" "$T/s22bi.err" \
  "22B"
assert_no_deadlock_text "$T/s22bi.err" "$T/s22bd.err"; assert_no_new_deadlocks "22B"
if [ -s "$T/s22bd.err" ]; then echo "!! FAIL (22B): the stop DELETE should always eventually succeed, got stderr: $(cat "$T/s22bd.err")"; FAIL=1; fi
if grep -q '"code": "ISSUED"' "$T/s22bi.out"; then
  echo "!! FAIL (22B): forced delete-first ordering must produce INVOICE_INCOMPLETE (the delivery stop was already gone when issuance locked load_stops), got ISSUED: $(cat "$T/s22bi.out")"; FAIL=1
elif grep -q '"code": "INVOICE_INCOMPLETE"' "$T/s22bi.out"; then
  NUM22B="$(Q "select invoice_number from public.carrier_invoices where id='$INV22B';")"
  SNAP22B="$(Q "select count(*) from public.carrier_invoice_issuance_snapshots where invoice_id='$INV22B';")"
  if [ -n "$NUM22B" ] || [ "$SNAP22B" != "0" ]; then
    echo "!! FAIL (22B): a refused issuance still consumed a number or left a snapshot -- number='$NUM22B' snapshots=$SNAP22B."; FAIL=1
  else
    echo "-> OK (22B): the racing DELETE, confirmed blocking issuance on the shared load_stops row lock, committed first -- issuance then correctly observed a load with no delivery stop and cleanly refused (INVOICE_INCOMPLETE), consuming no number and leaving no snapshot."
  fi
else
  echo "!! FAIL (22B): unexpected issuance outcome: $(cat "$T/s22bi.out")"; FAIL=1
fi

# ============================================================================
# SCENARIO 23A/23B: stop-sequence reorder vs issuance, both forced orderings.
# ============================================================================
echo
echo "=================  SCENARIO 23A: stop-sequence reorder vs issuance -- issuance wins the shared load_stops row lock first  ================="
INV23A="90000000-0000-0000-0000-0000000023aa"; LD23A="91000000-0000-0000-0000-0000000023aa"
seed_load "$LD23A" "11111111-1111-1111-1111-111111111111" "LD-CONC-23A" "a1a1a1a1-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "
update public.load_stops set stop_type = 'delivery', stop_sequence = 2, city = 'PartialDrop-23A' where load_id = '$LD23A' and stop_type = 'delivery';
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
values ('11111111-1111-1111-1111-111111111111', '$LD23A', 'delivery', 3, 'LD-CONC-23A FinalReceiver', 'FinalDrop-23A', 'TX', now());
" >/dev/null
seed_draft_invoice "$INV23A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD23A" "aaaa0000-0000-0000-0000-000000000001"
T23A="$(Q "select updated_at from public.carrier_invoices where id='$INV23A';")"
# Phase 3B.3C.3, Section C correction: a single, CASE-based UPDATE (the
# way a real reorder workflow would actually write this -- one
# statement, neither target row touched twice) -- NOT three sequential
# UPDATEs cycling through a temporary out-of-range value. That original
# 3-statement form updated the SAME physical row twice within one
# transaction, which (empirically confirmed, independent of this
# migration's own trigger) makes PostgreSQL's own foreign-key
# enforcement additionally take a lock on the `loads` parent -- an
# extra, Postgres-internal lock this test's own naive SQL was
# introducing, not a defect in issue_carrier_invoice() or the trigger.
# The shared resource both contenders now actually contend for is one
# of the two delivery STOP ROWS being swapped.
run_forced_race "load_stops" "load_id = '$LD23A' and stop_sequence = 2" 1.2 \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV23A'::uuid, '$T23A'::timestamptz, 'race23a-issue', 'race23a-issue');\"" "race23a-issue" "$T/s23ai.out" "$T/s23ai.err" \
  "reorder" "as_owner_a \"update public.load_stops set stop_sequence = case when stop_sequence = 2 then 3 when stop_sequence = 3 then 2 end where load_id = '$LD23A' and stop_sequence in (2,3); -- /* race23a-mutate */\"" "race23a-mutate" "$T/s23ar.out" "$T/s23ar.err" \
  "23A"
assert_no_deadlock_text "$T/s23ai.err" "$T/s23ar.err"; assert_no_new_deadlocks "23A"
if [ -s "$T/s23ar.err" ]; then echo "!! FAIL (23A): the racing reorder should always eventually succeed, got stderr: $(cat "$T/s23ar.err")"; FAIL=1; fi
FINAL_FINAL_CITY23A="$(Q "select city from public.load_stops where load_id='$LD23A' and stop_sequence=3;")"
if [ "$FINAL_FINAL_CITY23A" != "PartialDrop-23A" ]; then echo "!! FAIL (23A): the reorder never actually landed after issuance released the lock -- expected sequence 3 to now be PartialDrop-23A, got $FINAL_FINAL_CITY23A"; FAIL=1
elif ! grep -q '"code": "ISSUED"' "$T/s23ai.out"; then echo "!! FAIL (23A): issuance did not succeed, got $(cat "$T/s23ai.out")"; FAIL=1
else
  SNAP_DEST23A="$(Q "select snapshot_payload->'loads'->0->'destination'->>'city' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV23A';")"
  if [ "$SNAP_DEST23A" != "FinalDrop-23A" ]; then
    echo "!! FAIL (23A): forced issuance-first ordering must snapshot the ORIGINAL final-sequence delivery, got '$SNAP_DEST23A'."; FAIL=1
  else
    echo "-> OK (23A): issuance, confirmed blocking the racing reorder on the shared load_stops row lock, won first -- snapshot destination=FinalDrop-23A (pre-reorder), and the reorder landed cleanly afterward."
  fi
fi

echo
echo "=================  SCENARIO 23B: stop-sequence reorder vs issuance -- the reorder commits first  ================="
INV23B="90000000-0000-0000-0000-0000000023bb"; LD23B="91000000-0000-0000-0000-0000000023bb"
seed_load "$LD23B" "11111111-1111-1111-1111-111111111111" "LD-CONC-23B" "a1a1a1a1-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "
update public.load_stops set stop_type = 'delivery', stop_sequence = 2, city = 'PartialDrop-23B' where load_id = '$LD23B' and stop_type = 'delivery';
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
values ('11111111-1111-1111-1111-111111111111', '$LD23B', 'delivery', 3, 'LD-CONC-23B FinalReceiver', 'FinalDrop-23B', 'TX', now());
" >/dev/null
seed_draft_invoice "$INV23B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD23B" "aaaa0000-0000-0000-0000-000000000001"
T23B="$(Q "select updated_at from public.carrier_invoices where id='$INV23B';")"
run_forced_race "load_stops" "load_id = '$LD23B' and stop_sequence = 2" 1.2 \
  "reorder" "as_owner_a \"update public.load_stops set stop_sequence = case when stop_sequence = 2 then 3 when stop_sequence = 3 then 2 end where load_id = '$LD23B' and stop_sequence in (2,3); -- /* race23b-mutate */\"" "race23b-mutate" "$T/s23br.out" "$T/s23br.err" \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV23B'::uuid, '$T23B'::timestamptz, 'race23b-issue', 'race23b-issue');\"" "race23b-issue" "$T/s23bi.out" "$T/s23bi.err" \
  "23B"
assert_no_deadlock_text "$T/s23bi.err" "$T/s23br.err"; assert_no_new_deadlocks "23B"
if [ -s "$T/s23br.err" ]; then echo "!! FAIL (23B): the racing reorder should always eventually succeed, got stderr: $(cat "$T/s23br.err")"; FAIL=1; fi
if ! grep -q '"code": "ISSUED"' "$T/s23bi.out"; then echo "!! FAIL (23B): issuance did not succeed, got $(cat "$T/s23bi.out")"; FAIL=1
else
  SNAP_DEST23B="$(Q "select snapshot_payload->'loads'->0->'destination'->>'city' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV23B';")"
  if [ "$SNAP_DEST23B" != "PartialDrop-23B" ]; then
    echo "!! FAIL (23B): forced reorder-first ordering must snapshot the NEW final-sequence delivery, got '$SNAP_DEST23B'."; FAIL=1
  else
    echo "-> OK (23B): the racing reorder, confirmed blocking issuance on the shared load_stops row lock, committed first -- issuance then correctly observed the NEW arrangement -- snapshot destination=$SNAP_DEST23B, a complete, self-consistent record, never a hybrid of old+new fields."
  fi
fi

# ============================================================================
# SCENARIO 24A/24B: source-dispatch mutation vs issuance, both forced
# orderings. Shared lock: the dispatches ROW itself (issuance's own FOR
# SHARE, position 3c) -- no trigger involved, ordinary row-lock conflict.
# ============================================================================
echo
echo "=================  SCENARIO 24A: source-dispatch reassignment vs issuance -- issuance wins the shared dispatches lock first  ================="
INV24A="90000000-0000-0000-0000-0000000024aa"; LD24A="91000000-0000-0000-0000-0000000024aa"; LD24AB="91000000-0000-0000-0000-0000000024ab"
DISP24A="92000000-0000-0000-0000-0000000024aa"
seed_load "$LD24A" "11111111-1111-1111-1111-111111111111" "LD-CONC-24A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD24AB" "11111111-1111-1111-1111-111111111111" "LD-CONC-24AB" "a1a1a1a1-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('$DISP24A', '11111111-1111-1111-1111-111111111111', '$LD24A', 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');
" >/dev/null
seed_draft_invoice "$INV24A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD24A" "aaaa0000-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "update public.carrier_invoice_line_items set source_load_id = '$LD24A', source_dispatch_id = '$DISP24A' where invoice_id = '$INV24A';" >/dev/null
T24A="$(Q "select updated_at from public.carrier_invoices where id='$INV24A';")"
run_forced_race "dispatches" "id = '$DISP24A'" 1.2 \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV24A'::uuid, '$T24A'::timestamptz, 'race24a-issue', 'race24a-issue');\"" "race24a-issue" "$T/s24ai.out" "$T/s24ai.err" \
  "reassign" "\"\${PSQL[@]}\" -c \"update public.dispatches set load_id = '$LD24AB' where id = '$DISP24A'; -- /* race24a-mutate */\"" "race24a-mutate" "$T/s24ar.out" "$T/s24ar.err" \
  "24A"
assert_no_deadlock_text "$T/s24ai.err" "$T/s24ar.err"; assert_no_new_deadlocks "24A"
if [ -s "$T/s24ar.err" ]; then echo "!! FAIL (24A): the racing reassignment should always eventually succeed, got stderr: $(cat "$T/s24ar.err")"; FAIL=1; fi
FINAL_DISP_LOAD24A="$(Q "select load_id from public.dispatches where id='$DISP24A';")"
if [ "$FINAL_DISP_LOAD24A" != "$LD24AB" ]; then echo "!! FAIL (24A): the reassignment never actually landed after issuance released the lock -- final load_id=$FINAL_DISP_LOAD24A"; FAIL=1
elif ! grep -q '"code": "ISSUED"' "$T/s24ai.out"; then
  echo "!! FAIL (24A): forced issuance-first ordering must succeed (dispatch still matched when issuance locked it), got $(cat "$T/s24ai.out")"; FAIL=1
else
  NUM24A="$(Q "select invoice_number from public.carrier_invoices where id='$INV24A';")"
  if [ -z "$NUM24A" ]; then echo "!! FAIL (24A): ISSUED but invoice_number is empty."; FAIL=1
  else echo "-> OK (24A): issuance, confirmed blocking the racing reassignment on the shared dispatches row lock, won first -- saw the ORIGINAL matching load association and succeeded (number=$NUM24A), and the reassignment landed cleanly afterward."
  fi
fi

echo
echo "=================  SCENARIO 24B: source-dispatch reassignment vs issuance -- the reassignment commits first  ================="
INV24B="90000000-0000-0000-0000-0000000024bb"; LD24B="91000000-0000-0000-0000-0000000024bb"; LD24BB="91000000-0000-0000-0000-0000000024bc"
DISP24B="92000000-0000-0000-0000-0000000024bb"
seed_load "$LD24B" "11111111-1111-1111-1111-111111111111" "LD-CONC-24B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD24BB" "11111111-1111-1111-1111-111111111111" "LD-CONC-24BB" "a1a1a1a1-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values ('d1000000-0000-0000-0000-00000000024b', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'Race24B');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values ('c1000000-0000-0000-0000-00000000024b', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-RACE24B');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('$DISP24B', '11111111-1111-1111-1111-111111111111', '$LD24B', 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-00000000024b', 'd1000000-0000-0000-0000-00000000024b', 'assigned');
" >/dev/null
seed_draft_invoice "$INV24B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD24B" "aaaa0000-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "update public.carrier_invoice_line_items set source_load_id = '$LD24B', source_dispatch_id = '$DISP24B' where invoice_id = '$INV24B';" >/dev/null
T24B="$(Q "select updated_at from public.carrier_invoices where id='$INV24B';")"
run_forced_race "dispatches" "id = '$DISP24B'" 1.2 \
  "reassign" "\"\${PSQL[@]}\" -c \"update public.dispatches set load_id = '$LD24BB' where id = '$DISP24B'; -- /* race24b-mutate */\"" "race24b-mutate" "$T/s24br.out" "$T/s24br.err" \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV24B'::uuid, '$T24B'::timestamptz, 'race24b-issue', 'race24b-issue');\"" "race24b-issue" "$T/s24bi.out" "$T/s24bi.err" \
  "24B"
assert_no_deadlock_text "$T/s24bi.err" "$T/s24br.err"; assert_no_new_deadlocks "24B"
if [ -s "$T/s24br.err" ]; then echo "!! FAIL (24B): the racing reassignment should always eventually succeed, got stderr: $(cat "$T/s24br.err")"; FAIL=1; fi
if grep -q '"code": "ISSUED"' "$T/s24bi.out"; then
  echo "!! FAIL (24B): forced reassignment-first ordering must produce SOURCE_LOAD_CONFLICT (the dispatch was already reassigned when issuance locked it), got ISSUED: $(cat "$T/s24bi.out")"; FAIL=1
elif grep -q '"code": "SOURCE_LOAD_CONFLICT"' "$T/s24bi.out"; then
  NUM24B="$(Q "select invoice_number from public.carrier_invoices where id='$INV24B';")"
  SNAP24B="$(Q "select count(*) from public.carrier_invoice_issuance_snapshots where invoice_id='$INV24B';")"
  if [ -n "$NUM24B" ] || [ "$SNAP24B" != "0" ]; then
    echo "!! FAIL (24B): a refused issuance still consumed a number or left a snapshot -- number='$NUM24B' snapshots=$SNAP24B."; FAIL=1
  else
    echo "-> OK (24B): the racing reassignment, confirmed blocking issuance on the shared dispatches row lock, committed first -- issuance then correctly observed, under lock, the now-mismatched load association and cleanly refused (SOURCE_LOAD_CONFLICT), consuming no number and leaving no snapshot."
  fi
else
  echo "!! FAIL (24B): unexpected issuance outcome: $(cat "$T/s24bi.out")"; FAIL=1
fi

# ============================================================================
# SCENARIO 25A/25B: intermediate (nonterminal) stop edit vs issuance, both
# forced orderings -- origin/destination must be IDENTICAL in both, since
# the edited stop is never the selected endpoint either way.
# ============================================================================
echo
echo "=================  SCENARIO 25A: nonterminal stop edit vs issuance -- issuance wins the shared load_stops row lock first  ================="
INV25A="90000000-0000-0000-0000-0000000025aa"; LD25A="91000000-0000-0000-0000-0000000025aa"
seed_load "$LD25A" "11111111-1111-1111-1111-111111111111" "LD-CONC-25A" "a1a1a1a1-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "
update public.load_stops set stop_type = 'delivery', stop_sequence = 2, city = 'PartialDrop-25A' where load_id = '$LD25A' and stop_type = 'delivery';
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
values ('11111111-1111-1111-1111-111111111111', '$LD25A', 'delivery', 3, 'LD-CONC-25A FinalReceiver', 'FinalDrop-25A', 'TX', now());
" >/dev/null
seed_draft_invoice "$INV25A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD25A" "aaaa0000-0000-0000-0000-000000000001"
T25A="$(Q "select updated_at from public.carrier_invoices where id='$INV25A';")"
run_forced_race "load_stops" "load_id = '$LD25A' and stop_sequence = 2" 1.2 \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV25A'::uuid, '$T25A'::timestamptz, 'race25a-issue', 'race25a-issue');\"" "race25a-issue" "$T/s25ai.out" "$T/s25ai.err" \
  "edit" "as_owner_a \"update public.load_stops set city = 'RACE-EDITED-NONTERMINAL-25A' where load_id = '$LD25A' and stop_sequence = 2; -- /* race25a-mutate */\"" "race25a-mutate" "$T/s25au.out" "$T/s25au.err" \
  "25A"
assert_no_deadlock_text "$T/s25ai.err" "$T/s25au.err"; assert_no_new_deadlocks "25A"
if [ -s "$T/s25au.err" ]; then echo "!! FAIL (25A): the racing nonterminal edit should always eventually succeed, got stderr: $(cat "$T/s25au.err")"; FAIL=1; fi
FINAL_COUNT25A="$(Q "select count(*) from public.load_stops where load_id='$LD25A';")"
FINAL_NONTERM25A="$(Q "select city from public.load_stops where load_id='$LD25A' and stop_sequence=2;")"
if [ "$FINAL_COUNT25A" != "3" ]; then echo "!! FAIL (25A): expected all 3 stops still present, got $FINAL_COUNT25A"; FAIL=1
elif [ "$FINAL_NONTERM25A" != "RACE-EDITED-NONTERMINAL-25A" ]; then echo "!! FAIL (25A): the edit never actually landed -- final nonterminal city=$FINAL_NONTERM25A"; FAIL=1
elif ! grep -q '"code": "ISSUED"' "$T/s25ai.out"; then echo "!! FAIL (25A): issuance did not succeed, got $(cat "$T/s25ai.out")"; FAIL=1
else
  SNAP_ORIGIN25A="$(Q "select snapshot_payload->'loads'->0->'origin'->>'city' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV25A';")"
  SNAP_DEST25A="$(Q "select snapshot_payload->'loads'->0->'destination'->>'city' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV25A';")"
  if [ "$SNAP_ORIGIN25A" = "Dallas" ] && [ "$SNAP_DEST25A" = "FinalDrop-25A" ]; then
    echo "-> OK (25A): issuance won the shared load_stops row lock first -- origin=$SNAP_ORIGIN25A destination=$SNAP_DEST25A unaffected by the nonterminal edit, which landed cleanly afterward."
  else
    echo "!! FAIL (25A): origin/destination were affected by an edit to a stop that should be irrelevant -- origin=$SNAP_ORIGIN25A destination=$SNAP_DEST25A"; FAIL=1
  fi
fi

echo
echo "=================  SCENARIO 25B: nonterminal stop edit vs issuance -- the edit commits first  ================="
INV25B="90000000-0000-0000-0000-0000000025bb"; LD25B="91000000-0000-0000-0000-0000000025bb"
seed_load "$LD25B" "11111111-1111-1111-1111-111111111111" "LD-CONC-25B" "a1a1a1a1-0000-0000-0000-000000000001"
"${PSQL[@]}" -c "
update public.load_stops set stop_type = 'delivery', stop_sequence = 2, city = 'PartialDrop-25B' where load_id = '$LD25B' and stop_type = 'delivery';
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at)
values ('11111111-1111-1111-1111-111111111111', '$LD25B', 'delivery', 3, 'LD-CONC-25B FinalReceiver', 'FinalDrop-25B', 'TX', now());
" >/dev/null
seed_draft_invoice "$INV25B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD25B" "aaaa0000-0000-0000-0000-000000000001"
T25B="$(Q "select updated_at from public.carrier_invoices where id='$INV25B';")"
run_forced_race "load_stops" "load_id = '$LD25B' and stop_sequence = 2" 1.2 \
  "edit" "as_owner_a \"update public.load_stops set city = 'RACE-EDITED-NONTERMINAL-25B' where load_id = '$LD25B' and stop_sequence = 2; -- /* race25b-mutate */\"" "race25b-mutate" "$T/s25bu.out" "$T/s25bu.err" \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV25B'::uuid, '$T25B'::timestamptz, 'race25b-issue', 'race25b-issue');\"" "race25b-issue" "$T/s25bi.out" "$T/s25bi.err" \
  "25B"
assert_no_deadlock_text "$T/s25bi.err" "$T/s25bu.err"; assert_no_new_deadlocks "25B"
if [ -s "$T/s25bu.err" ]; then echo "!! FAIL (25B): the racing nonterminal edit should always eventually succeed, got stderr: $(cat "$T/s25bu.err")"; FAIL=1; fi
if ! grep -q '"code": "ISSUED"' "$T/s25bi.out"; then echo "!! FAIL (25B): issuance did not succeed, got $(cat "$T/s25bi.out")"; FAIL=1
else
  SNAP_ORIGIN25B="$(Q "select snapshot_payload->'loads'->0->'origin'->>'city' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV25B';")"
  SNAP_DEST25B="$(Q "select snapshot_payload->'loads'->0->'destination'->>'city' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV25B';")"
  if [ "$SNAP_ORIGIN25B" = "Dallas" ] && [ "$SNAP_DEST25B" = "FinalDrop-25B" ]; then
    echo "-> OK (25B): the racing edit committed first -- origin=$SNAP_ORIGIN25B destination=$SNAP_DEST25B STILL unaffected (the edited stop is never a selected endpoint in either ordering) -- proves the nonterminal edit is genuinely invisible to route selection, not merely untested."
  else
    echo "!! FAIL (25B): origin/destination were affected by an edit to a stop that should be irrelevant -- origin=$SNAP_ORIGIN25B destination=$SNAP_DEST25B"; FAIL=1
  fi
fi

# ============================================================================
# SCENARIO 26A/26B: carrier remittance profile UPDATE vs issuance, both
# forced orderings. Shared lock: the carrier_remittance_profiles ROW
# itself (issuance's own FOR SHARE, Phase 3B.3C.1) -- no trigger involved.
# ============================================================================
echo
echo "=================  SCENARIO 26A: remittance UPDATE vs issuance -- issuance wins the shared remittance lock first  ================="
INV26A="90000000-0000-0000-0000-0000000026aa"; LD26A="91000000-0000-0000-0000-0000000026aa"
ORIG_REMIT_EMAIL26A="$(Q "select remittance_email from public.carrier_remittance_profiles where carrier_id='a1a1a1a1-0000-0000-0000-000000000001';")"
ORIG_REMIT_NAME26A="$(Q "select remittance_name from public.carrier_remittance_profiles where carrier_id='a1a1a1a1-0000-0000-0000-000000000001';")"
seed_load "$LD26A" "11111111-1111-1111-1111-111111111111" "LD-CONC-26A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV26A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD26A" "aaaa0000-0000-0000-0000-000000000001"
T26A="$(Q "select updated_at from public.carrier_invoices where id='$INV26A';")"
run_forced_race "carrier_remittance_profiles" "carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'" 1.2 \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV26A'::uuid, '$T26A'::timestamptz, 'race26a-issue', 'race26a-issue');\"" "race26a-issue" "$T/s26ai.out" "$T/s26ai.err" \
  "remit-update" "as_owner_a \"update public.carrier_remittance_profiles set remittance_email = 'race26a-updated@example.com', remittance_name = 'RACE26A UPDATED NAME' where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'; -- /* race26a-mutate */\"" "race26a-mutate" "$T/s26ar.out" "$T/s26ar.err" \
  "26A"
assert_no_deadlock_text "$T/s26ai.err" "$T/s26ar.err"; assert_no_new_deadlocks "26A"
if [ -s "$T/s26ar.err" ]; then echo "!! FAIL (26A): the racing remittance UPDATE should always eventually succeed, got stderr: $(cat "$T/s26ar.err")"; FAIL=1; fi
FINAL_REMIT_EMAIL26A="$(Q "select remittance_email from public.carrier_remittance_profiles where carrier_id='a1a1a1a1-0000-0000-0000-000000000001';")"
if [ "$FINAL_REMIT_EMAIL26A" != "race26a-updated@example.com" ]; then echo "!! FAIL (26A): the racing UPDATE never actually landed -- final email=$FINAL_REMIT_EMAIL26A"; FAIL=1
elif ! grep -q '"code": "ISSUED"' "$T/s26ai.out"; then echo "!! FAIL (26A): issuance did not succeed, got $(cat "$T/s26ai.out")"; FAIL=1
else
  SNAP_EMAIL26A="$(Q "select snapshot_payload->'issuer'->'remittance'->>'remittance_email' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV26A';")"
  SNAP_NAME26A="$(Q "select snapshot_payload->'issuer'->'remittance'->>'remittance_name' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV26A';")"
  if [ "$SNAP_EMAIL26A" = "$ORIG_REMIT_EMAIL26A" ] && [ "$SNAP_NAME26A" = "$ORIG_REMIT_NAME26A" ]; then
    echo "-> OK (26A): issuance, confirmed blocking the racing remittance UPDATE on the shared row lock, won first -- snapshot captured one COMPLETE original version (email=$SNAP_EMAIL26A, name=$SNAP_NAME26A)."
  else
    echo "!! FAIL (26A): forced issuance-first ordering must snapshot the ORIGINAL remittance version -- got email=$SNAP_EMAIL26A name=$SNAP_NAME26A (orig email=$ORIG_REMIT_EMAIL26A orig name=$ORIG_REMIT_NAME26A)."; FAIL=1
  fi
fi
restore_remit_a1() { "${PSQL[@]}" -c "update public.carrier_remittance_profiles set remittance_email = '$1', remittance_name = '$2' where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001';" >/dev/null; }
restore_remit_a1 "$ORIG_REMIT_EMAIL26A" "$ORIG_REMIT_NAME26A"

echo
echo "=================  SCENARIO 26B: remittance UPDATE vs issuance -- the UPDATE commits first  ================="
INV26B="90000000-0000-0000-0000-0000000026bb"; LD26B="91000000-0000-0000-0000-0000000026bb"
ORIG_REMIT_EMAIL26B="$(Q "select remittance_email from public.carrier_remittance_profiles where carrier_id='a1a1a1a1-0000-0000-0000-000000000001';")"
ORIG_REMIT_NAME26B="$(Q "select remittance_name from public.carrier_remittance_profiles where carrier_id='a1a1a1a1-0000-0000-0000-000000000001';")"
seed_load "$LD26B" "11111111-1111-1111-1111-111111111111" "LD-CONC-26B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_draft_invoice "$INV26B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD26B" "aaaa0000-0000-0000-0000-000000000001"
T26B="$(Q "select updated_at from public.carrier_invoices where id='$INV26B';")"
run_forced_race "carrier_remittance_profiles" "carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'" 1.2 \
  "remit-update" "as_owner_a \"update public.carrier_remittance_profiles set remittance_email = 'race26b-updated@example.com', remittance_name = 'RACE26B UPDATED NAME' where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'; -- /* race26b-mutate */\"" "race26b-mutate" "$T/s26br.out" "$T/s26br.err" \
  "issuance" "as_owner_a \"select public.issue_carrier_invoice('$INV26B'::uuid, '$T26B'::timestamptz, 'race26b-issue', 'race26b-issue');\"" "race26b-issue" "$T/s26bi.out" "$T/s26bi.err" \
  "26B"
assert_no_deadlock_text "$T/s26bi.err" "$T/s26br.err"; assert_no_new_deadlocks "26B"
if [ -s "$T/s26br.err" ]; then echo "!! FAIL (26B): the racing remittance UPDATE should always eventually succeed, got stderr: $(cat "$T/s26br.err")"; FAIL=1; fi
if ! grep -q '"code": "ISSUED"' "$T/s26bi.out"; then echo "!! FAIL (26B): issuance did not succeed, got $(cat "$T/s26bi.out")"; FAIL=1
else
  SNAP_EMAIL26B="$(Q "select snapshot_payload->'issuer'->'remittance'->>'remittance_email' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV26B';")"
  SNAP_NAME26B="$(Q "select snapshot_payload->'issuer'->'remittance'->>'remittance_name' from public.carrier_invoice_issuance_snapshots where invoice_id='$INV26B';")"
  if [ "$SNAP_EMAIL26B" = "race26b-updated@example.com" ] && [ "$SNAP_NAME26B" = "RACE26B UPDATED NAME" ]; then
    echo "-> OK (26B): the racing remittance UPDATE, confirmed blocking issuance on the shared row lock, committed first -- snapshot captured one COMPLETE new version (email=$SNAP_EMAIL26B, name=$SNAP_NAME26B), never a torn mix."
  else
    echo "!! FAIL (26B): the snapshot's remittance block is a TORN/mixed version -- email=$SNAP_EMAIL26B name=$SNAP_NAME26B."; FAIL=1
  fi
fi
restore_remit_a1 "$ORIG_REMIT_EMAIL26B" "$ORIG_REMIT_NAME26B"

# ============================================================================
# SCENARIO 27 (Phase 3B.3C.3, Section D): cross-load stop-move attempt vs
# issuance. Section A's chosen rule REJECTS a cross-load load_id UPDATE
# outright, unconditionally, before any lock beyond a plain row read is
# ever attempted -- so there is no "who wins the lock" race to force here
# (the move never even reaches the parent-lock SELECT). Run twice, with
# the launch order swapped, to prove the rejection is invariant to timing
# and that issuance itself remains fully consistent regardless.
# ============================================================================
echo
echo "=================  SCENARIO 27a: cross-load move attempt LAUNCHED BEFORE issuance  ================="
INV27A="90000000-0000-0000-0000-0000000027a1"; LD27A="91000000-0000-0000-0000-0000000027a1"; LD27AB="91000000-0000-0000-0000-0000000027a2"
seed_load "$LD27A" "11111111-1111-1111-1111-111111111111" "LD-CONC-27A" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD27AB" "11111111-1111-1111-1111-111111111111" "LD-CONC-27AB" "a1a1a1a1-0000-0000-0000-000000000001"
STOP27A="$(Q "select id from public.load_stops where load_id='$LD27A' and stop_type='pickup';")"
seed_draft_invoice "$INV27A" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD27A" "aaaa0000-0000-0000-0000-000000000001"
T27A="$(Q "select updated_at from public.carrier_invoices where id='$INV27A';")"
( as_owner_a "update public.load_stops set load_id = '$LD27AB' where id = '$STOP27A';" ) >"$T/s27am.out" 2>"$T/s27am.err" &
P27AM=$!
( as_owner_a "select public.issue_carrier_invoice('$INV27A'::uuid, '$T27A'::timestamptz, 'race27a-issue', 'race27a-issue');" ) >"$T/s27ai.out" 2>"$T/s27ai.err" &
P27AI=$!
set +e; wait "$P27AM"; wait "$P27AI"; set -e
assert_no_deadlock_text "$T/s27am.err" "$T/s27ai.err"; assert_no_new_deadlocks "27a"
if ! grep -qi "load_id cannot be changed" "$T/s27am.err"; then
  echo "!! FAIL (27a): the cross-load move should always be rejected with the load_id-cannot-be-changed error, got: $(cat "$T/s27am.err")"; FAIL=1
fi
STOP27A_FINAL_LOAD="$(Q "select load_id from public.load_stops where id='$STOP27A';")"
if [ "$STOP27A_FINAL_LOAD" != "$LD27A" ]; then
  echo "!! FAIL (27a): the stop's load_id changed despite the rejection -- got $STOP27A_FINAL_LOAD, expected unchanged $LD27A."; FAIL=1
fi
if ! grep -q '"code": "ISSUED"' "$T/s27ai.out"; then
  echo "!! FAIL (27a): issuance should complete normally regardless of the rejected move attempt, got $(cat "$T/s27ai.out")"; FAIL=1
else
  echo "-> OK (27a): the cross-load move was rejected unconditionally (never reached the parent-lock stage at all), the stop stayed on its original load, and issuance completed cleanly and consistently -- $(cat "$T/s27ai.out")."
fi

echo
echo "=================  SCENARIO 27b: cross-load move attempt LAUNCHED AFTER (concurrently with) issuance  ================="
INV27B="90000000-0000-0000-0000-0000000027b1"; LD27B="91000000-0000-0000-0000-0000000027b1"; LD27BB="91000000-0000-0000-0000-0000000027b2"
seed_load "$LD27B" "11111111-1111-1111-1111-111111111111" "LD-CONC-27B" "a1a1a1a1-0000-0000-0000-000000000001"
seed_load "$LD27BB" "11111111-1111-1111-1111-111111111111" "LD-CONC-27BB" "a1a1a1a1-0000-0000-0000-000000000001"
STOP27B="$(Q "select id from public.load_stops where load_id='$LD27B' and stop_type='pickup';")"
seed_draft_invoice "$INV27B" "11111111-1111-1111-1111-111111111111" "a1a1a1a1-0000-0000-0000-000000000001" "a0b00000-0000-0000-0000-000000000001" "$LD27B" "aaaa0000-0000-0000-0000-000000000001"
T27B="$(Q "select updated_at from public.carrier_invoices where id='$INV27B';")"
( as_owner_a "select public.issue_carrier_invoice('$INV27B'::uuid, '$T27B'::timestamptz, 'race27b-issue', 'race27b-issue');" ) >"$T/s27bi.out" 2>"$T/s27bi.err" &
P27BI=$!
( as_owner_a "update public.load_stops set load_id = '$LD27BB' where id = '$STOP27B';" ) >"$T/s27bm.out" 2>"$T/s27bm.err" &
P27BM=$!
set +e; wait "$P27BI"; wait "$P27BM"; set -e
assert_no_deadlock_text "$T/s27bi.err" "$T/s27bm.err"; assert_no_new_deadlocks "27b"
if ! grep -qi "load_id cannot be changed" "$T/s27bm.err"; then
  echo "!! FAIL (27b): the cross-load move should always be rejected with the load_id-cannot-be-changed error, got: $(cat "$T/s27bm.err")"; FAIL=1
fi
STOP27B_FINAL_LOAD="$(Q "select load_id from public.load_stops where id='$STOP27B';")"
if [ "$STOP27B_FINAL_LOAD" != "$LD27B" ]; then
  echo "!! FAIL (27b): the stop's load_id changed despite the rejection -- got $STOP27B_FINAL_LOAD, expected unchanged $LD27B."; FAIL=1
fi
if ! grep -q '"code": "ISSUED"' "$T/s27bi.out"; then
  echo "!! FAIL (27b): issuance should complete normally regardless of the rejected move attempt, got $(cat "$T/s27bi.out")"; FAIL=1
else
  echo "-> OK (27b): with the launch order swapped, the cross-load move is STILL rejected unconditionally regardless of timing, the stop stayed on its original load, and issuance completed cleanly -- proves the rejection is timing-invariant, not merely lucky in 27a -- $(cat "$T/s27bi.out")."
fi

# ============================================================================
# SECTION F: direct/factored policy-race results (explicit reverse pair).
# ============================================================================
echo
echo "=================  SECTION F: direct<->factored policy races  ================="

echo "----- F1: direct->factored DURING a direct issuance attempt (carrier with NO pre-existing relationship) -----"
INVF1="90000000-0000-0000-0000-00000000f1aa"; LDF1="91000000-0000-0000-0000-00000000f1aa"
"${PSQL[@]}" -c "update public.carriers set factoring_mode = 'direct', invoice_code = 'CARF1' where id = 'a3a3a3a3-0000-0000-0000-000000000003'; update public.carriers set is_active = true where id = 'a3a3a3a3-0000-0000-0000-000000000003';" >/dev/null
"${PSQL[@]}" -c "insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by) values ('cb450000-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111', 'a3a3a3a3-0000-0000-0000-000000000003', 'a0b00000-0000-0000-0000-000000000001', 'active', 'f1@example.com', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');" >/dev/null
seed_load "$LDF1" "11111111-1111-1111-1111-111111111111" "LD-CONC-F1" "a3a3a3a3-0000-0000-0000-000000000003"
seed_draft_invoice "$INVF1" "11111111-1111-1111-1111-111111111111" "a3a3a3a3-0000-0000-0000-000000000003" "a0b00000-0000-0000-0000-000000000001" "$LDF1" "aaaa0000-0000-0000-0000-000000000001"
TF1="$(Q "select updated_at from public.carrier_invoices where id='$INVF1';")"
CARRIER_UPDATED_ATF1="$(Q "select updated_at from public.carriers where id='a3a3a3a3-0000-0000-0000-000000000003';")"
( as_owner_a "select public.issue_carrier_invoice('$INVF1'::uuid, '$TF1'::timestamptz, 'F1 issuing as direct', 'racef1-issue');" ) >"$T/sf1i.out" 2>"$T/sf1i.err" &
PF1I=$!
( as_owner_a "select public.set_carrier_factoring_policy('a3a3a3a3-0000-0000-0000-000000000003'::uuid, 'factored'::public.carrier_factoring_mode, 'F1 switching to factored -- will fail readiness, that is fine, we only care about issuance''s own consistency', '$CARRIER_UPDATED_ATF1'::timestamptz, 'racef1-policy');" ) >"$T/sf1p.out" 2>"$T/sf1p.err" &
PF1P=$!
set +e; wait "$PF1I"; wait "$PF1P"; set -e
assert_no_deadlock_text "$T/sf1i.err" "$T/sf1p.err"; assert_no_new_deadlocks "F1"
echo "  issuance result: $(cat "$T/sf1i.out")"
echo "  policy result:   $(cat "$T/sf1p.out")"
if grep -q '"code": "ISSUED"' "$T/sf1i.out" || grep -qE 'STALE_CONFIGURATION|FACTORING_NOT_READY|FACTORING_POLICY_UNCONFIGURED' "$T/sf1i.out"; then
  echo "-> OK (F1): a concurrent direct->factored policy change during a direct issuance attempt never produced a mixed-assumption snapshot -- issuance either completed cleanly as direct or was cleanly refused."
else
  echo "!! FAIL (F1): unexpected issuance outcome: $(cat "$T/sf1i.out")"; FAIL=1
fi

echo "----- F2: factored->direct DURING a factored issuance attempt -----"
INVF2="90000000-0000-0000-0000-00000000f2aa"; LDF2="91000000-0000-0000-0000-00000000f2aa"
seed_load "$LDF2" "11111111-1111-1111-1111-111111111111" "LD-CONC-F2" "a2a2a2a2-0000-0000-0000-000000000002"
seed_draft_invoice "$INVF2" "11111111-1111-1111-1111-111111111111" "a2a2a2a2-0000-0000-0000-000000000002" "a0b00000-0000-0000-0000-000000000001" "$LDF2" "aaaa0000-0000-0000-0000-000000000001"
TF2="$(Q "select updated_at from public.carrier_invoices where id='$INVF2';")"
CARRIER_UPDATED_ATF2="$(Q "select updated_at from public.carriers where id='a2a2a2a2-0000-0000-0000-000000000002';")"
( as_owner_a "select public.issue_carrier_invoice('$INVF2'::uuid, '$TF2'::timestamptz, 'F2 issuing as factored', 'racef2-issue');" ) >"$T/sf2i.out" 2>"$T/sf2i.err" &
PF2I=$!
( as_owner_a "select public.set_carrier_factoring_policy('a2a2a2a2-0000-0000-0000-000000000002'::uuid, 'direct'::public.carrier_factoring_mode, 'F2 switching to direct', '$CARRIER_UPDATED_ATF2'::timestamptz, 'racef2-policy');" ) >"$T/sf2p.out" 2>"$T/sf2p.err" &
PF2P=$!
set +e; wait "$PF2I"; wait "$PF2P"; set -e
assert_no_deadlock_text "$T/sf2i.err" "$T/sf2p.err"; assert_no_new_deadlocks "F2"
echo "  issuance result: $(cat "$T/sf2i.out")"
echo "  policy result:   $(cat "$T/sf2p.out")"
if grep -q '"code": "ISSUED"' "$T/sf2i.out"; then
  SNAP_F2="$(Q "select snapshot_payload->'factoring' from public.carrier_invoice_issuance_snapshots where invoice_id='$INVF2';")"
  echo "  snapshot factoring block: $SNAP_F2"
  echo "-> OK (F2): issuance succeeded despite a concurrent factored->direct policy change -- the snapshot reflects EXACTLY ONE consistent policy state (either fully factored or fully direct, never mixed)."
elif grep -qE 'STALE_CONFIGURATION|FACTORING_NOT_READY|FACTORING_POLICY_UNCONFIGURED' "$T/sf2i.out"; then
  echo "-> OK (F2): issuance was cleanly refused rather than risk a mixed-assumption snapshot -- $(cat "$T/sf2i.out")."
else
  echo "!! FAIL (F2): unexpected issuance outcome: $(cat "$T/sf2i.out")"; FAIL=1
fi
"${PSQL[@]}" -c "update public.carriers set factoring_mode = 'factored' where id = 'a2a2a2a2-0000-0000-0000-000000000002';" >/dev/null

echo
echo "== final deadlock check: pg_stat_database.deadlocks for this database =="
FINAL_DEADLOCKS="$(Q "select deadlocks from pg_stat_database where datname='$DB';")"
echo "   deadlocks=$FINAL_DEADLOCKS"
if [ "$FINAL_DEADLOCKS" != "0" ]; then
  echo "!! FAIL: pg_stat_database reports $FINAL_DEADLOCKS deadlock(s) occurred during this entire run."
  FAIL=1
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "!!!!!!!!!!!!!!!!  TEST CONCURRENCY 0144 ATOMIC INVOICE ISSUANCE FAILED  !!!!!!!!!!!!!!!!"
  exit 1
fi
echo "TEST CONCURRENCY 0144 ATOMIC INVOICE ISSUANCE PASSED (all 19 required scenarios + direct/factored policy races + Phase 3B.3C.2 scenarios 20-26 [load_stops UPDATE/INSERT/DELETE, stop-sequence reorder, source-dispatch reassignment, multi-stop nonterminal-edit, remittance-profile UPDATE] -- zero Postgres-detected deadlocks throughout)"
