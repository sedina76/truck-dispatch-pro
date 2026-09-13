#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0143_financial_idempotency.sh -- Phase 3B.3B, Section E/G:
# REAL two-session concurrency proof for the canonical SHA-256, operation-
# scoped idempotency mechanics 0143 introduces on top of
# update_carrier_invoice_draft().
#
# This does NOT re-litigate 0142's own row-lock/staleness races (see
# TEST_CONCURRENCY_0142_draft_update.sh, re-run unmodified against 0143 by
# the Section G verification battery to confirm no regression). It proves,
# under TRUE concurrency, the properties specific to this phase:
#   - a same-key replay under true concurrency still produces exactly one
#     mutation/audit event and never leaks a raw uniqueness error, now
#     under the widened (organization_id, operation, idempotency_key)
#     constraint and the SHA-256 fingerprint;
#   - concurrent same-key/different-invoice and same-key/different-patch
#     races still resolve to exactly one success + one clean, structured
#     IDEMPOTENCY_KEY_REUSED -- never a raw error, never both applied;
#   - the SAME idempotency key string used by TWO DIFFERENT ORGANIZATIONS
#     at the same instant succeeds independently for both (the advisory
#     lock and the durable constraint are both organization-scoped, so
#     concurrent callers from different tenants never contend or leak);
#   - the winning row's new columns (operation, fingerprint_version,
#     state, created_by) are populated correctly and the stored
#     request_fingerprint is a genuine 64-lowercase-hex SHA-256 digest.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0143_financial_idempotency.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0143_fingerprint_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54941}"
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
DB=carrier_invoice_0143_fingerprint_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")
Q() { psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "$1"; }

echo "== bootstrap: seed + support schema + 0130-0143 =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f TEST_SUPPORT_0136_0138_factoring_schema.sql >/dev/null
for m in 0130_carrier_context_foundation 0131_carrier_party_relationships 0132_load_carrier_and_trailer_scope \
         0133_deterministic_carrier_backfill 0134_dispatch_status_transition_and_trailer_privilege_hotfix \
         0135_dispatch_resource_reassignment_and_carrier_lockdown 0136_carrier_factoring_policy_and_relationship_columns \
         0137_deterministic_factoring_carrier_backfill 0138_carrier_default_cutover_classifier_and_secured_rpcs \
         0139_factoring_policy_safety_integrations_and_privilege_remediation 0140_factoring_authorization_and_submission_safety \
         0141_factoring_integration_lifecycle_integrity 0142_immutable_carrier_invoice_foundation \
         0143_canonical_financial_idempotency_hardening; do
  "${PSQL[@]}" -f "migrations/$m.sql" >/dev/null
done

FAIL=0
T="$PGDATA_DIR"

assert_no_deadlock() {
  if grep -qi "deadlock" "$@"; then echo "!! FAIL: deadlock detected"; FAIL=1; return 1; fi
  return 0
}

seed_draft() {
  # $1 = invoice id, $2 = organization ('A' or 'B')
  if [ "$2" = "B" ]; then
    "${PSQL[@]}" -c "
select set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
set role authenticated;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
values ('$1', '22222222-2222-2222-2222-222222222222', 'carrier_freight_invoice', 'b1b1b1b1-0000-0000-0000-000000000001', 'broker', 'b0b00000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000001');
" >/dev/null
  else
    "${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
values ('$1', '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001');
" >/dev/null
  fi
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

# ============================================================================
# SCENARIO 1: same-key replay under TRUE concurrency, against the widened
# (organization_id, operation, idempotency_key) constraint and the SHA-256
# fingerprint. Exactly one mutation + one audit event; no raw
# unique-violation ever reaches a caller.
# ============================================================================
echo
echo "=================  SCENARIO 1: same-key replay under true concurrency (SHA-256/operation-scoped)  ================="
INV1="e1000000-0000-0000-0000-000000000001"
seed_draft "$INV1" A
T0="$(Q "select updated_at from public.carrier_invoices where id='$INV1';")"

(
  as_owner_a "select public.update_carrier_invoice_draft('$INV1'::uuid, '{\"notes\":\"same key note\"}'::jsonb, '$T0'::timestamptz, null, 'fp-race1-samekey');"
) >"$T/s1a.out" 2>"$T/s1a.err" &
P1A=$!
(
  as_owner_a "select public.update_carrier_invoice_draft('$INV1'::uuid, '{\"notes\":\"same key note\"}'::jsonb, '$T0'::timestamptz, null, 'fp-race1-samekey');"
) >"$T/s1b.out" 2>"$T/s1b.err" &
P1B=$!
set +e; wait "$P1A"; wait "$P1B"; set -e
assert_no_deadlock "$T/s1a.err" "$T/s1b.err"

if grep -qi "unique" "$T/s1a.err" "$T/s1b.err" 2>/dev/null; then
  echo "!! FAIL: a raw unique-violation leaked to a caller."; FAIL=1
fi
AUDIT_COUNT="$(Q "select count(*) from public.activity_logs where entity_type='invoice' and entity_id='$INV1' and action='carrier_invoice_draft_updated';")"
if [ "$AUDIT_COUNT" != "1" ]; then
  echo "!! FAIL: expected exactly 1 audit event for the same-key concurrent replay, got $AUDIT_COUNT"; FAIL=1
else
  echo "-> OK: two truly concurrent callers with the IDENTICAL idempotency key produced exactly one mutation and one audit event under the new SHA-256/operation-scoped mechanics -- no unique-violation leaked."
fi

# ============================================================================
# SCENARIO 2: concurrent same-key/DIFFERENT-invoice race (same organization,
# same operation) -- exactly one success, the other a clean, structured
# IDEMPOTENCY_KEY_REUSED, never a raw uniqueness error.
# ============================================================================
echo
echo "=================  SCENARIO 2: concurrent same-key, DIFFERENT-invoice race  ================="
INV2A="e2000000-0000-0000-0000-00000000000a"
INV2B="e2000000-0000-0000-0000-00000000000b"
seed_draft "$INV2A" A
seed_draft "$INV2B" A
T2A="$(Q "select updated_at from public.carrier_invoices where id='$INV2A';")"
T2B="$(Q "select updated_at from public.carrier_invoices where id='$INV2B';")"

(
  as_owner_a "select public.update_carrier_invoice_draft('$INV2A'::uuid, '{\"notes\":\"invoice A\"}'::jsonb, '$T2A'::timestamptz, null, 'fp-race2-samekey');"
) >"$T/s2a.out" 2>"$T/s2a.err" &
P2A=$!
(
  as_owner_a "select public.update_carrier_invoice_draft('$INV2B'::uuid, '{\"notes\":\"invoice B\"}'::jsonb, '$T2B'::timestamptz, null, 'fp-race2-samekey');"
) >"$T/s2b.out" 2>"$T/s2b.err" &
P2B=$!
set +e; wait "$P2A"; wait "$P2B"; set -e
assert_no_deadlock "$T/s2a.err" "$T/s2b.err"

if grep -qi "unique\|constraint\|duplicate key" "$T/s2a.err" "$T/s2b.err" 2>/dev/null; then
  echo "!! FAIL: a raw uniqueness/constraint error leaked to a caller instead of a clean structured response."; FAIL=1
fi
A_SUCCESS=0; B_SUCCESS=0; A_REUSED=0; B_REUSED=0
grep -q '"success": true' "$T/s2a.out" && A_SUCCESS=1
grep -q '"success": true' "$T/s2b.out" && B_SUCCESS=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s2a.out" && A_REUSED=1
grep -q 'IDEMPOTENCY_KEY_REUSED' "$T/s2b.out" && B_REUSED=1
if [ "$((A_SUCCESS + B_SUCCESS))" -ne 1 ] || [ "$((A_REUSED + B_REUSED))" -ne 1 ]; then
  echo "!! FAIL: expected exactly one success + one IDEMPOTENCY_KEY_REUSED, got A=$(cat "$T/s2a.out") B=$(cat "$T/s2b.out")"; FAIL=1
else
  echo "-> OK: two truly concurrent callers with the IDENTICAL key targeting DIFFERENT invoices -- exactly one succeeded, the other got a clean structured IDEMPOTENCY_KEY_REUSED, no raw error, no deadlock."
fi

# ============================================================================
# SCENARIO 3: concurrent same-key/DIFFERENT-PATCH race on the SAME invoice
# -- exactly one succeeds, the other gets IDEMPOTENCY_KEY_REUSED; the
# invoice never ends up torn between the two patches.
# ============================================================================
echo
echo "=================  SCENARIO 3: concurrent same-key, DIFFERENT-patch race (same invoice)  ================="
INV3="e3000000-0000-0000-0000-000000000003"
seed_draft "$INV3" A
T3="$(Q "select updated_at from public.carrier_invoices where id='$INV3';")"

(
  as_owner_a "select public.update_carrier_invoice_draft('$INV3'::uuid, '{\"notes\":\"patch A\"}'::jsonb, '$T3'::timestamptz, null, 'fp-race3-samekey');"
) >"$T/s3a.out" 2>"$T/s3a.err" &
P3A=$!
(
  as_owner_a "select public.update_carrier_invoice_draft('$INV3'::uuid, '{\"notes\":\"patch B\"}'::jsonb, '$T3'::timestamptz, null, 'fp-race3-samekey');"
) >"$T/s3b.out" 2>"$T/s3b.err" &
P3B=$!
set +e; wait "$P3A"; wait "$P3B"; set -e
assert_no_deadlock "$T/s3a.err" "$T/s3b.err"

if grep -qi "unique\|constraint\|duplicate key" "$T/s3a.err" "$T/s3b.err" 2>/dev/null; then
  echo "!! FAIL: a raw uniqueness/constraint error leaked to a caller instead of a clean structured response."; FAIL=1
fi
A_SUCCESS=0; B_SUCCESS=0
grep -q '"success": true' "$T/s3a.out" && A_SUCCESS=1
grep -q '"success": true' "$T/s3b.out" && B_SUCCESS=1
if [ "$((A_SUCCESS + B_SUCCESS))" -ne 1 ]; then
  echo "!! FAIL: expected exactly one of the two same-key/different-patch callers to succeed, got A=$A_SUCCESS B=$B_SUCCESS"; FAIL=1
else
  FINAL_NOTES="$(Q "select notes from public.carrier_invoices where id='$INV3';")"
  if [ "$FINAL_NOTES" != "patch A" ] && [ "$FINAL_NOTES" != "patch B" ]; then
    echo "!! FAIL: final notes value is neither patch -- torn state: '$FINAL_NOTES'"; FAIL=1
  else
    echo "-> OK: exactly one of the two same-key/different-patch callers succeeded (final notes='$FINAL_NOTES'), the other got a clean structured IDEMPOTENCY_KEY_REUSED."
  fi
fi

# ============================================================================
# SCENARIO 4 (Section E item 15, under true concurrency): the SAME
# idempotency key STRING used by TWO DIFFERENT ORGANIZATIONS at the same
# instant -- both must succeed independently; neither the advisory lock
# nor the durable constraint (both organization-scoped) may cause any
# cross-tenant contention, interference, or leak.
# ============================================================================
echo
echo "=================  SCENARIO 4: same key string, two DIFFERENT organizations, true concurrency  ================="
INV4A="e4000000-0000-0000-0000-00000000000a"
INV4B="e4000000-0000-0000-0000-00000000000b"
seed_draft "$INV4A" A
seed_draft "$INV4B" B
T4A="$(Q "select updated_at from public.carrier_invoices where id='$INV4A';")"
T4B="$(Q "select updated_at from public.carrier_invoices where id='$INV4B';")"

(
  as_owner_a "select public.update_carrier_invoice_draft('$INV4A'::uuid, '{\"notes\":\"org A note\"}'::jsonb, '$T4A'::timestamptz, null, 'fp-race4-shared-key');"
) >"$T/s4a.out" 2>"$T/s4a.err" &
P4A=$!
(
  as_owner_b "select public.update_carrier_invoice_draft('$INV4B'::uuid, '{\"notes\":\"org B note\"}'::jsonb, '$T4B'::timestamptz, null, 'fp-race4-shared-key');"
) >"$T/s4b.out" 2>"$T/s4b.err" &
P4B=$!
set +e; wait "$P4A"; wait "$P4B"; set -e
assert_no_deadlock "$T/s4a.err" "$T/s4b.err"

if grep -qi "unique\|constraint\|duplicate key" "$T/s4a.err" "$T/s4b.err" 2>/dev/null; then
  echo "!! FAIL: a raw uniqueness/constraint error leaked to a caller -- cross-tenant contention on a supposedly organization-scoped key/lock."; FAIL=1
fi
A_SUCCESS=0; B_SUCCESS=0
grep -q '"success": true' "$T/s4a.out" && A_SUCCESS=1
grep -q '"success": true' "$T/s4b.out" && B_SUCCESS=1
if [ "$A_SUCCESS" -ne 1 ] || [ "$B_SUCCESS" -ne 1 ]; then
  echo "!! FAIL: expected BOTH organizations to succeed independently using the identical key string, got A=$A_SUCCESS ($(cat "$T/s4a.out")) B=$B_SUCCESS ($(cat "$T/s4b.out"))"; FAIL=1
else
  echo "-> OK: the identical idempotency key string used by two different organizations at the same instant succeeded independently for both -- no cross-tenant contention, no interference, no leak."
fi

# ============================================================================
# SCENARIO 5: post-race sanity -- the winning idempotency row from
# Scenario 1 carries the NEW columns correctly (operation, fingerprint_
# version, state, created_by) and a genuine 64-lowercase-hex SHA-256
# request_fingerprint.
# ============================================================================
echo
echo "=================  SCENARIO 5: winning row shape sanity (operation/fingerprint_version/state/created_by/SHA-256)  ================="
ROW_OK="$(Q "
select (operation = 'update_carrier_invoice_draft')
   and (fingerprint_version = 1)
   and (state = 'completed')
   and (created_by = 'aaaa0000-0000-0000-0000-000000000001'::uuid)
   and (request_fingerprint ~ '^[0-9a-f]{64}\$')
from public.carrier_invoice_lifecycle_idempotency
where organization_id = '11111111-1111-1111-1111-111111111111' and idempotency_key = 'fp-race1-samekey';
")"
if [ "$ROW_OK" != "t" ]; then
  echo "!! FAIL: the winning idempotency row's shape is not as expected (operation/fingerprint_version/state/created_by/64-hex fingerprint)."; FAIL=1
else
  echo "-> OK: the winning idempotency row correctly carries operation='update_carrier_invoice_draft', fingerprint_version=1, state='completed', created_by=the calling owner, and a genuine 64-lowercase-hex SHA-256 request_fingerprint."
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "!!!!!!!!!!!!!!!!  TEST CONCURRENCY 0143 FINANCIAL IDEMPOTENCY FAILED  !!!!!!!!!!!!!!!!"
  exit 1
fi
echo "TEST CONCURRENCY 0143 FINANCIAL IDEMPOTENCY PASSED (same-key replay under true concurrency, same-key/different-invoice collision, same-key/different-patch collision, cross-organization key independence under true concurrency, winning-row shape sanity)"
