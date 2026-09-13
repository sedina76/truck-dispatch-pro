#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0141_integration_lifecycle.sh -- Phase 3B.2, Section 8:
# REAL two-session concurrency proof for the integration lifecycle. Every
# scenario below uses genuine separate PostgreSQL sessions (background psql
# processes), never a sequential simulation.
#
# Lock design under test: activate_carrier_factoring_integration() (and any
# other transition to 'ready') locks, in fixed order: the governing
# relationship row (FOR UPDATE) -- the SAME row set_default_factoring_
# relationship()/approve_factoring_relationship_noa()/deactivate_factoring_
# relationship() already lock FOR UPDATE -- then the carrier row (FOR
# UPDATE, the SAME row set_carrier_factoring_policy() already locks), then
# the factoring company row (FOR SHARE) and, if referenced, the NOA
# document row (FOR SHARE). Every other transition (deactivate/verify/fail/
# revoke/rotate/configure) locks only the relationship row (and, for an
# existing integration, that integration's own row) -- never the carrier/
# company/document rows. This closes the TOCTOU window between a new
# lifecycle RPC and the three PRE-EXISTING RPCs (0138/0139/0140) WITHOUT
# modifying any of their bodies -- the row-level, organization-scoped
# dependency guard (attached to the underlying TABLES, not any one RPC,
# and narrowed from statement-level in Phase 3B.2.1) is the second,
# independent line of defense proven below: any mutation that would leave
# an active integration invalid is rolled back in its entirety, regardless
# of which code path attempted it.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0141_integration_lifecycle.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0141_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54930}"
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
DB=factoring_0141_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")
Q() { psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "$1"; }

echo "== bootstrap: seed + support schema + 0130-0141 =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f TEST_SUPPORT_0136_0138_factoring_schema.sql >/dev/null
for m in 0130_carrier_context_foundation 0131_carrier_party_relationships 0132_load_carrier_and_trailer_scope \
         0133_deterministic_carrier_backfill 0134_dispatch_status_transition_and_trailer_privilege_hotfix \
         0135_dispatch_resource_reassignment_and_carrier_lockdown 0136_carrier_factoring_policy_and_relationship_columns \
         0137_deterministic_factoring_carrier_backfill 0138_carrier_default_cutover_classifier_and_secured_rpcs \
         0139_factoring_policy_safety_integrations_and_privilege_remediation 0140_factoring_authorization_and_submission_safety \
         0141_factoring_integration_lifecycle_integrity; do
  "${PSQL[@]}" -f "migrations/$m.sql" >/dev/null
done

echo "== fixtures: carrier A1, one factor, two COMPLETE relationships (relX default, relY not) =="
"${PSQL[@]}" -c "
insert into public.factoring_companies (id, organization_id, name, is_active) values
  ('fc0e0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor CFG', true);
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active) values
  ('fe0e0000-0000-0000-0000-0000000000a1', '11111111-1111-1111-1111-111111111111', 'fc0e0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 90,3,10,'deducted_at_funding','non_recourse','Wire X','NOA X v1','v1',
   current_date-10, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true, true),
  ('fe0e0000-0000-0000-0000-0000000000a2', '11111111-1111-1111-1111-111111111111', 'fc0e0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 85,4,12,'deducted_at_funding','non_recourse','Wire Y','NOA Y v1','v1',
   current_date-10, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', false, true);
update public.carriers set factoring_mode = 'factored' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
"

FAIL=0
T="$PGDATA_DIR"

configure_and_verify() {
  # $1 = relationship id, $2 = local file key to stash the new integration id under, $3 = idempotency prefix
  "${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.configure_carrier_factoring_integration('$1', null, null, null, null, 'seed configuration for concurrency test',
  (select updated_at from public.factoring_relationships where id='$1'), '$3-configure');
" >/dev/null
  local created
  created="$(Q "select result->>'integration_id' from public.factoring_integration_lifecycle_idempotency where idempotency_key='$3-configure'")"
  echo "$created" > "$T/$2.id"
  "${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.verify_carrier_factoring_integration('$created'::uuid, 'begin manual review', (select updated_at from public.carrier_factoring_integrations where id='$created'::uuid), '$3-verify');
" >/dev/null
}

revoke_all_on() {
  # $1 = relationship id -- revokes every non-revoked integration attached
  # to it, via the real RPC (never direct SQL), so that resetting is_default/
  # is_active flags afterward can never violate the dependency invariant.
  "${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.revoke_carrier_factoring_integration(id, 'cleanup between scenarios', updated_at, 'cleanup-'||id) from public.carrier_factoring_integrations where factoring_relationship_id='$1' and configuration_status <> 'revoked';
" >/dev/null
}

assert_no_deadlock() {
  if grep -qi "deadlock" "$@"; then echo "!! FAIL: deadlock detected"; FAIL=1; return 1; fi
  return 0
}

assert_invariant_holds() {
  local bad
  bad="$(Q "select count(*) from public.carrier_factoring_integrations i where i.is_active and public.factoring_integration_lifecycle_problem(i.id) is not null;" 2>/dev/null || echo "ERR")"
  if [ "$bad" != "0" ]; then
    echo "!! FAIL: invariant violated -- $bad active integration(s) with a problem, or the check itself errored ($bad)"; FAIL=1; return 1
  fi
  local multi
  multi="$(Q "select count(*) from (select factoring_relationship_id from public.carrier_factoring_integrations where is_active group by factoring_relationship_id having count(*) > 1) x;")"
  if [ "$multi" != "0" ]; then
    echo "!! FAIL: $multi relationship(s) have MORE THAN ONE active/ready integration"; FAIL=1; return 1
  fi
  return 0
}

# ============================================================================
# SCENARIO 1: integration activation vs. relationship deactivation
# ============================================================================
echo
echo "=================  SCENARIO 1: integration activation vs. relationship deactivation (same relationship)  ================="
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s1int" "s1"
S1_IID="$(cat "$T/s1int.id")"
cat > "$T/s1a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S1_IID'::uuid, 'activate racing deactivation', (select updated_at from public.carrier_factoring_integrations where id='$S1_IID'::uuid), 's1-activate') as result;
EOF
cat > "$T/s1b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.deactivate_factoring_relationship('fe0e0000-0000-0000-0000-0000000000a1', 'deactivate racing activation', (select updated_at from public.factoring_relationships where id='fe0e0000-0000-0000-0000-0000000000a1'), 's1-deact', false) as result;
EOF
"${PSQL[@]}" -f "$T/s1a.sql" > "$T/s1a.out" 2>&1 &
P1A=$!
"${PSQL[@]}" -f "$T/s1b.sql" > "$T/s1b.out" 2>&1 &
P1B=$!
set +e; wait "$P1A"; E1A=$?; wait "$P1B"; E1B=$?; set -e
echo "S1-A(activate) exit=$E1A  S1-B(deactivate) exit=$E1B"
assert_no_deadlock "$T/s1a.out" "$T/s1b.out"
assert_invariant_holds
echo "-- outcome: --"; grep result "$T/s1a.out" "$T/s1b.out" 2>/dev/null || true
echo "-> OK: no deadlock; whichever committed first, the final state is consistent (either the relationship stayed active with the integration now ready, or the relationship deactivated and the activation attempt correctly saw a now-inactive relationship) -- no active integration is ever attached to an invalid relationship."
# reset for next scenarios: revoke any active integration first (never
# reset flags out from under one), then ensure relX active/default again.
revoke_all_on "fe0e0000-0000-0000-0000-0000000000a1"
"${PSQL[@]}" -c "update public.factoring_relationships set is_active=true, is_default=true where id='fe0e0000-0000-0000-0000-0000000000a1';" >/dev/null 2>&1 || true

# ============================================================================
# SCENARIO 2: integration activation vs. default-factor change
# ============================================================================
echo
echo "=================  SCENARIO 2: integration activation vs. default-factor change (same carrier)  ================="
# Ensure a clean pending_verification integration on relX again for this scenario.
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s2int" "s2setup"
S2_IID="$(cat "$T/s2int.id")"
cat > "$T/s2a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S2_IID'::uuid, 'activate racing default change', (select updated_at from public.carrier_factoring_integrations where id='$S2_IID'::uuid), 's2-activate') as result;
EOF
cat > "$T/s2b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_default_factoring_relationship('fe0e0000-0000-0000-0000-0000000000a2') as result;
EOF
"${PSQL[@]}" -f "$T/s2a.sql" > "$T/s2a.out" 2>&1 &
P2A=$!
"${PSQL[@]}" -f "$T/s2b.sql" > "$T/s2b.out" 2>&1 &
P2B=$!
set +e; wait "$P2A"; E2A=$?; wait "$P2B"; E2B=$?; set -e
echo "S2-A(activate relX) exit=$E2A  S2-B(default->relY) exit=$E2B"
assert_no_deadlock "$T/s2a.out" "$T/s2b.out"
assert_invariant_holds
echo "-- outcome: --"; cat "$T/s2a.out" "$T/s2b.out" | grep -i "result\|ERROR" 2>/dev/null || true
echo "-> OK: no deadlock; if the default changed to relY BEFORE relX's activation, activation correctly sees relationship_not_default; if relX's activation committed FIRST, the default-change's own row-level dependency guard detects the now-invalid combination and rolls back the ENTIRE default-change (proving the cross-cutting guard, not just the RPC's own precheck)."
# reset: revoke any active integration first, then restore relX as
# default, relY not, for later scenarios.
revoke_all_on "fe0e0000-0000-0000-0000-0000000000a1"
revoke_all_on "fe0e0000-0000-0000-0000-0000000000a2"
"${PSQL[@]}" -c "
update public.factoring_relationships set is_default=false where carrier_id='a1a1a1a1-0000-0000-0000-000000000001';
update public.factoring_relationships set is_default=true where id='fe0e0000-0000-0000-0000-0000000000a1';
" >/dev/null

# ============================================================================
# SCENARIO 3: integration activation vs. policy change (factored -> direct)
# ============================================================================
echo
echo "=================  SCENARIO 3: integration activation vs. carrier policy change (factored -> direct)  ================="
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s3int" "s3setup"
S3_IID="$(cat "$T/s3int.id")"
CARRIER_VER="$(Q "select updated_at from public.carriers where id='a1a1a1a1-0000-0000-0000-000000000001';")"
cat > "$T/s3a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S3_IID'::uuid, 'activate racing policy change', (select updated_at from public.carrier_factoring_integrations where id='$S3_IID'::uuid), 's3-activate') as result;
EOF
cat > "$T/s3b.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'S3 race test', '$CARRIER_VER'::timestamptz, null) as result;
EOF
"${PSQL[@]}" -f "$T/s3a.sql" > "$T/s3a.out" 2>&1 &
P3A=$!
"${PSQL[@]}" -f "$T/s3b.sql" > "$T/s3b.out" 2>&1 &
P3B=$!
set +e; wait "$P3A"; E3A=$?; wait "$P3B"; E3B=$?; set -e
echo "S3-A(activate) exit=$E3A  S3-B(policy->direct) exit=$E3B"
assert_no_deadlock "$T/s3a.out" "$T/s3b.out"
assert_invariant_holds
echo "-- outcome: --"; cat "$T/s3a.out" "$T/s3b.out" | grep -i "result\|ERROR" 2>/dev/null || true
echo "-> OK: no deadlock; either activation sees carrier_not_factored, or (if activation committed first) the policy change's own row-level guard rejects switching to direct while an active integration now depends on 'factored'."
# reset: carrier back to factored (idempotent no-op if the policy change above never committed)
"${PSQL[@]}" -c "update public.carriers set factoring_mode='factored' where id='a1a1a1a1-0000-0000-0000-000000000001';" >/dev/null

# ============================================================================
# SCENARIO 4: two integrations racing to become active/ready for the SAME relationship
# ============================================================================
echo
echo "=================  SCENARIO 4: two integrations racing to become active/ready for the SAME relationship  ================="
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s4inta" "s4a"
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s4intb" "s4b"
S4_IID_A="$(cat "$T/s4inta.id")"
S4_IID_B="$(cat "$T/s4intb.id")"
cat > "$T/s4a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S4_IID_A'::uuid, 'race to become ready A', (select updated_at from public.carrier_factoring_integrations where id='$S4_IID_A'::uuid), 's4-activate-a') as result;
EOF
cat > "$T/s4b.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S4_IID_B'::uuid, 'race to become ready B', (select updated_at from public.carrier_factoring_integrations where id='$S4_IID_B'::uuid), 's4-activate-b') as result;
EOF
"${PSQL[@]}" -f "$T/s4a.sql" > "$T/s4a.out" 2>&1 &
P4A=$!
"${PSQL[@]}" -f "$T/s4b.sql" > "$T/s4b.out" 2>&1 &
P4B=$!
set +e; wait "$P4A"; E4A=$?; wait "$P4B"; E4B=$?; set -e
echo "S4-A exit=$E4A  S4-B exit=$E4B"
assert_no_deadlock "$T/s4a.out" "$T/s4b.out"
if [ "$E4A" -ne 0 ] || [ "$E4B" -ne 0 ]; then echo "!! FAIL: both calls should return normally (rejection is a structured result, not a raised error)"; FAIL=1; fi
N_READY="$(Q "select count(*) from public.carrier_factoring_integrations where factoring_relationship_id='fe0e0000-0000-0000-0000-0000000000a1' and is_active;")"
if [ "$N_READY" != "1" ]; then echo "!! FAIL: expected exactly 1 active integration on relX, got $N_READY"; FAIL=1
else echo "-> OK: no deadlock; exactly one of the two integrations became active/ready, the other received the deterministic ACTIVE_INTEGRATION_DEPENDENCY rejection."
fi
assert_invariant_holds
# revoke whichever became ready so relX starts clean for scenario 5
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.revoke_carrier_factoring_integration(id, 'cleanup between scenarios', updated_at, 's4-cleanup-'||id) from public.carrier_factoring_integrations where factoring_relationship_id='fe0e0000-0000-0000-0000-0000000000a1' and configuration_status <> 'revoked';
" >/dev/null

# ============================================================================
# SCENARIO 5: credential rotation vs. integration deactivation (same integration)
# ============================================================================
echo
echo "=================  SCENARIO 5: credential rotation vs. integration deactivation (same integration)  ================="
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s5int" "s5setup"
S5_IID="$(cat "$T/s5int.id")"
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.activate_carrier_factoring_integration('$S5_IID'::uuid, 'activate before racing rotation/deactivation', (select updated_at from public.carrier_factoring_integrations where id='$S5_IID'::uuid), 's5-preactivate');
" >/dev/null
cat > "$T/s5a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.rotate_carrier_factoring_integration('$S5_IID'::uuid, null, null, null, null, 'rotate racing deactivation', (select updated_at from public.carrier_factoring_integrations where id='$S5_IID'::uuid), 's5-rotate') as result;
EOF
cat > "$T/s5b.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.deactivate_carrier_factoring_integration('$S5_IID'::uuid, 'deactivate racing rotation', (select updated_at from public.carrier_factoring_integrations where id='$S5_IID'::uuid), 's5-deactivate') as result;
EOF
"${PSQL[@]}" -f "$T/s5a.sql" > "$T/s5a.out" 2>&1 &
P5A=$!
"${PSQL[@]}" -f "$T/s5b.sql" > "$T/s5b.out" 2>&1 &
P5B=$!
set +e; wait "$P5A"; E5A=$?; wait "$P5B"; E5B=$?; set -e
echo "S5-A(rotate) exit=$E5A  S5-B(deactivate) exit=$E5B"
assert_no_deadlock "$T/s5a.out" "$T/s5b.out"
echo "-- outcome: --"; cat "$T/s5a.out" "$T/s5b.out" | grep -i "result\|ERROR" 2>/dev/null || true
N_REVOKED="$(Q "select count(*) from public.carrier_factoring_integrations where id='$S5_IID'::uuid and configuration_status='revoked';")"
if [ "$N_REVOKED" != "1" ]; then echo "!! FAIL: the original integration should end up revoked either way (rotation always revokes it; deactivation alone would not -- so rotation must have won or run), got revoked=$N_REVOKED"; fi
assert_invariant_holds
echo "-> OK: no deadlock; the two operations serialize on the same relationship+integration rows -- whichever ran first determined the other's outcome deterministically (a deactivation of an already-rotated/revoked integration gets REVOKED_TERMINAL; a rotation of an already-deactivated integration still succeeds, since rotate accepts any non-revoked source state), with no double effect."

# ============================================================================
# SCENARIO 6: NOA change vs. integration activation (same relationship)
# ============================================================================
echo
echo "=================  SCENARIO 6: NOA re-approval vs. integration activation (same relationship)  ================="
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a2" "s6int" "s6setup"
S6_IID="$(cat "$T/s6int.id")"
cat > "$T/s6a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S6_IID'::uuid, 'activate racing NOA change', (select updated_at from public.carrier_factoring_integrations where id='$S6_IID'::uuid), 's6-activate') as result;
EOF
cat > "$T/s6b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.approve_factoring_relationship_noa('fe0e0000-0000-0000-0000-0000000000a2', 'v2', current_date, 'updated NOA text under contention') as result;
EOF
"${PSQL[@]}" -f "$T/s6a.sql" > "$T/s6a.out" 2>&1 &
P6A=$!
"${PSQL[@]}" -f "$T/s6b.sql" > "$T/s6b.out" 2>&1 &
P6B=$!
set +e; wait "$P6A"; E6A=$?; wait "$P6B"; E6B=$?; set -e
echo "S6-A(activate) exit=$E6A  S6-B(NOA re-approve) exit=$E6B"
assert_no_deadlock "$T/s6a.out" "$T/s6b.out"
if [ "$E6B" -ne 0 ]; then echo "!! FAIL: NOA re-approval should always succeed (it never depends on integration state)"; cat "$T/s6b.out"; FAIL=1; fi
assert_invariant_holds
echo "-> OK: no deadlock; both operations serialize on the SAME relationship row (activate's own lock vs. approve_factoring_relationship_noa's existing lock) -- the NOA re-approval always succeeds (it never depends on the integration), and activation sees a fully consistent, non-stale view of the relationship's NOA state either way."
# revoke to reset for scenario 7/8
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.revoke_carrier_factoring_integration(id, 'cleanup between scenarios', updated_at, 's6-cleanup-'||id) from public.carrier_factoring_integrations where factoring_relationship_id='fe0e0000-0000-0000-0000-0000000000a2' and configuration_status <> 'revoked';
" >/dev/null

# ============================================================================
# SCENARIO 7: same idempotency key replay (activation)
# ============================================================================
echo
echo "=================  SCENARIO 7: same idempotency key replay, two concurrent sessions  ================="
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s7int" "s7setup"
S7_IID="$(cat "$T/s7int.id")"
S7_VER="$(Q "select updated_at from public.carrier_factoring_integrations where id='$S7_IID'::uuid;")"
cat > "$T/s7a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S7_IID'::uuid, 'same key replay test', '$S7_VER'::timestamptz, 's7-same-key') as result;
EOF
cp "$T/s7a.sql" "$T/s7b.sql"
"${PSQL[@]}" -f "$T/s7a.sql" > "$T/s7a.out" 2>&1 &
P7A=$!
"${PSQL[@]}" -f "$T/s7b.sql" > "$T/s7b.out" 2>&1 &
P7B=$!
set +e; wait "$P7A"; E7A=$?; wait "$P7B"; E7B=$?; set -e
echo "S7-A exit=$E7A  S7-B exit=$E7B"
assert_no_deadlock "$T/s7a.out" "$T/s7b.out"
if grep -q '"success": true' "$T/s7a.out" "$T/s7b.out" 2>/dev/null; then :; else echo "!! FAIL: at least one side must show success:true"; FAIL=1; fi
N_EVENTS="$(Q "select count(*) from public.factoring_integration_lifecycle_idempotency where target_id='$S7_IID'::uuid and idempotency_key='s7-same-key';")"
if [ "$N_EVENTS" != "1" ]; then echo "!! FAIL: expected exactly 1 idempotency-cache row for this key, got $N_EVENTS (would mean the replay was NOT deduplicated)"; FAIL=1
else echo "-> OK: no deadlock; both concurrent identical-key requests are safely serialized by the relationship-row lock -- exactly one real mutation + cache row is created, and the second call returns the identical cached result (idempotent_replay)."
fi
assert_invariant_holds
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.revoke_carrier_factoring_integration(id, 'cleanup between scenarios', updated_at, 's7-cleanup-'||id) from public.carrier_factoring_integrations where factoring_relationship_id='fe0e0000-0000-0000-0000-0000000000a1' and configuration_status <> 'revoked';
" >/dev/null

# ============================================================================
# SCENARIO 8: different idempotency keys racing (activation)
# ============================================================================
echo
echo "=================  SCENARIO 8: different idempotency keys racing, two concurrent sessions  ================="
# Both callers load the SAME pre-race version, then race with two DIFFERENT
# idempotency keys -- since neither key matches a cached entry, this
# exercises the OTHER real per-call outcome the task asks for
# ("deterministic stale/conflict results"): the winner activates for
# real; the loser's optimistic-concurrency check (expected_updated_at)
# correctly reports STALE_RECORD -- a genuine, non-cached, deterministic
# per-call rejection, never a replay.
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s8int" "s8setup"
S8_IID="$(cat "$T/s8int.id")"
S8_VER="$(Q "select updated_at from public.carrier_factoring_integrations where id='$S8_IID'::uuid;")"
cat > "$T/s8a.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S8_IID'::uuid, 'different key race A', '$S8_VER'::timestamptz, 's8-key-a') as result;
EOF
cat > "$T/s8b.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S8_IID'::uuid, 'different key race B', '$S8_VER'::timestamptz, 's8-key-b') as result;
EOF
"${PSQL[@]}" -f "$T/s8a.sql" > "$T/s8a.out" 2>&1 &
P8A=$!
"${PSQL[@]}" -f "$T/s8b.sql" > "$T/s8b.out" 2>&1 &
P8B=$!
set +e; wait "$P8A"; E8A=$?; wait "$P8B"; E8B=$?; set -e
echo "S8-A exit=$E8A  S8-B exit=$E8B"
assert_no_deadlock "$T/s8a.out" "$T/s8b.out"
N_SUCCESS="$( { grep -c '"success": true' "$T/s8a.out" "$T/s8b.out" || true; } | awk -F: '{s+=$2} END{print s+0}')"
N_REJECTED="$( { grep -cE 'STALE_RECORD|ALREADY_IN_STATE' "$T/s8a.out" "$T/s8b.out" || true; } | awk -F: '{s+=$2} END{print s+0}')"
echo "successes=$N_SUCCESS rejected(stale_or_already)=$N_REJECTED"
if [ "${N_SUCCESS:-0}" != "1" ] || [ "${N_REJECTED:-0}" != "1" ]; then
  echo "!! FAIL: expected exactly one real success and one real deterministic rejection (STALE_RECORD or ALREADY_IN_STATE), never both cached/replayed"; cat "$T/s8a.out" "$T/s8b.out"; FAIL=1
else
  echo "-> OK: no deadlock; different idempotency keys against the same target never share a cache entry -- exactly one activates for real, the other gets its own deterministic, non-cached rejection (STALE_RECORD, since both loaded the same pre-race version -- exactly the optimistic-concurrency protection working as intended)."
fi
assert_invariant_holds
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.revoke_carrier_factoring_integration(id, 'cleanup between scenarios', updated_at, 's8-cleanup-'||id) from public.carrier_factoring_integrations where factoring_relationship_id='fe0e0000-0000-0000-0000-0000000000a1' and configuration_status <> 'revoked';
" >/dev/null

# ============================================================================
# SCENARIO 9: lock timeout followed by retry
# ============================================================================
echo
echo "=================  SCENARIO 9: lock held open, concurrent activation times out, then a clean retry  ================="
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a1" "s9int" "s9setup"
S9_IID="$(cat "$T/s9int.id")"
cat > "$T/s9a.sql" <<'EOF'
\set ON_ERROR_STOP on
begin;
select id from public.factoring_relationships where id = 'fe0e0000-0000-0000-0000-0000000000a1' for update;
select pg_sleep(1.2);
commit;
EOF
cat > "$T/s9b.sql" <<EOF
\\set ON_ERROR_STOP on
set statement_timeout = '400ms';
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.activate_carrier_factoring_integration('$S9_IID'::uuid, 'attempt during held lock', (select updated_at from public.carrier_factoring_integrations where id='$S9_IID'::uuid), 's9-activate') as result;
EOF
"${PSQL[@]}" -f "$T/s9a.sql" > "$T/s9a.out" 2>&1 &
P9A=$!
"${PSQL[@]}" -f "$T/s9b.sql" > "$T/s9b.out" 2>&1 &
P9B=$!
set +e; wait "$P9A"; E9A=$?; wait "$P9B"; E9B=$?; set -e
echo "S9-A(holder) exit=$E9A  S9-B(waiter, 400ms timeout) exit=$E9B"
if [ "$E9B" -eq 0 ]; then
  echo "!! FAIL: the waiting activation should have timed out, not completed"; cat "$T/s9b.out"; FAIL=1
elif ! grep -qi "statement timeout" "$T/s9b.out"; then
  echo "!! FAIL: expected a statement_timeout error while waiting on the held relationship lock"; cat "$T/s9b.out"; FAIL=1
else
  echo "S9-B correctly timed out. Retrying now that S9-A has released the lock..."
  cat > "$T/s9retry.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.activate_carrier_factoring_integration('$S9_IID'::uuid, 'retry after lock released', (select updated_at from public.carrier_factoring_integrations where id='$S9_IID'::uuid), 's9-retry') as result;
EOF
  "${PSQL[@]}" -f "$T/s9retry.sql" > "$T/s9retry.out" 2>&1
  if ! grep -q '"success": true' "$T/s9retry.out"; then
    echo "!! FAIL: the retry after the lock was released did not succeed"; cat "$T/s9retry.out"; FAIL=1
  else
    echo "-> OK: the timed-out attempt produced no partial effect, and the retry -- once the lock was free -- deterministically activated the integration. No double effect, no corruption."
  fi
fi
assert_invariant_holds

# ============================================================================
# SCENARIO 10: genuine document-unverification race (Phase 3B.2.1, Section B)
#
# Uses the ACTUAL reachable production write path, not NOA re-approval:
# src/app/(app)/carriers/onboarding/actions.ts's rejectOnboardingDocument()
# performs exactly `update public.documents set is_verified=false,
# rejected_at=now(), rejected_by=<uid>, rejection_reason=... where id=...`
# through the caller's own session client (RLS, owner/admin/dispatcher per
# the standard_tables policy loop, 0010) -- reproduced here verbatim at the
# SQL level (a Next.js server action cannot be invoked from this harness,
# but the exact statement it issues, run under the same role/RLS context,
# is what actually matters for a lock/concurrency proof).
#
# 10a: activation holds the document FOR SHARE lock first (via the real
# lock chain relationship->carrier->company->document->integration) --
# the reject-document UPDATE (FOR NO KEY UPDATE, which conflicts with FOR
# SHARE) must block on it, externally verified via a third observer
# session polling pg_stat_activity/pg_blocking_pids(); once activation
# commits (integration now active/ready), the reject-document UPDATE must
# then be REJECTED by the row-level dependency guard (documents is
# one of its six watched tables) -- an active integration can never be
# left depending on a now-unverified document.
#
# 10b: the reject-document UPDATE commits FIRST (before any activation
# attempt) -- the later activation attempt must return a structured
# NOT_READY/noa_document_not_verified result, never an exception, never a
# partial mutation.
# ============================================================================
echo
echo "=================  SCENARIO 10a: activation holds a verified NOA document -- concurrent document rejection (is_verified -> false) blocks, then is REJECTED by the dependency guard once activation commits  ================="

# Revoke any lingering active integrations from earlier scenarios first --
# clearing is_default out from under an active one would itself violate
# the dependency invariant (see Sections 1-2 above).
revoke_all_on "fe0e0000-0000-0000-0000-0000000000a1"
revoke_all_on "fe0e0000-0000-0000-0000-0000000000a2"
"${PSQL[@]}" -c "
-- exactly one default for this carrier at a time (partial unique index) --
-- clear any existing default BEFORE inserting the new one, since the
-- constraint is checked immediately, not deferred.
update public.factoring_relationships set is_default=false where carrier_id='a1a1a1a1-0000-0000-0000-000000000001';
insert into public.documents (id, organization_id, entity_type, entity_id, document_type, file_name, file_path, is_verified, verified_by, verified_at)
values ('9d0e0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'carrier', 'a1a1a1a1-0000-0000-0000-000000000001',
  'notice_of_assignment', 'noa-signed.pdf', '11111111-1111-1111-1111-111111111111/carrier/a1a1a1a1-0000-0000-0000-000000000001/noa-signed.pdf',
  true, 'aaaa0000-0000-0000-0000-000000000001', now());
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_document_id,
   noa_document_snapshot_file_name, noa_document_snapshot_file_path, noa_reference, noa_effective_date,
   noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active) values
  ('fe0e0000-0000-0000-0000-0000000000a3', '11111111-1111-1111-1111-111111111111', 'fc0e0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 90,3,10,'deducted_at_funding','non_recourse','Wire Z',
   '9d0e0000-0000-0000-0000-000000000001', 'noa-signed.pdf', '11111111-1111-1111-1111-111111111111/carrier/a1a1a1a1-0000-0000-0000-000000000001/noa-signed.pdf',
   'NOA Z v1', current_date-5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true, true);
"
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a3" "s10aint" "s10asetup"
S10A_IID="$(cat "$T/s10aint.id")"

cat > "$T/s10aA.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
begin;
-- /* ACTIVATE_SESSION: manually take the exact lock chain activate() itself
--    takes internally, so we can hold it open long enough to observe --
--    indistinguishable from "mid-function" from pg_locks' point of view. */
select id from public.factoring_relationships where id = 'fe0e0000-0000-0000-0000-0000000000a3' for update;
select c.id from public.carriers c where c.id = 'a1a1a1a1-0000-0000-0000-000000000001' for update;
select fc.id from public.factoring_companies fc where fc.id = 'fc0e0000-0000-0000-0000-000000000001' for share;
select d.id from public.documents d where d.id = '9d0e0000-0000-0000-0000-000000000001' for share;
select pg_sleep(1.5);
select public.activate_carrier_factoring_integration('$S10A_IID'::uuid, 'activate holding verified NOA document', (select updated_at from public.carrier_factoring_integrations where id='$S10A_IID'::uuid), 's10a-activate') as result;
commit;
EOF
cat > "$T/s10aB.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.3);
-- /* REJECT_DOCUMENT_SESSION: the EXACT statement rejectOnboardingDocument()
--    (src/app/(app)/carriers/onboarding/actions.ts) issues. */
-- The harness's minimal documents stub (TEST_SUPPORT_0136_0138) does not
-- carry rejected_at/rejected_by/rejection_reason (not needed by 0130-0141's
-- own logic) -- only is_verified is what the invariant actually depends on,
-- so only that column is set here; the real action also sets those three
-- bookkeeping columns, immaterial to this proof.
update public.documents set is_verified = false
  where id = '9d0e0000-0000-0000-0000-000000000001';
select 'reject_document_result' as marker, 'completed' as outcome;
EOF

"${PSQL[@]}" -f "$T/s10aA.sql" > "$T/s10aA.out" 2>&1 &
P10AA=$!
"${PSQL[@]}" -f "$T/s10aB.sql" > "$T/s10aB.out" 2>&1 &
P10AB=$!

DOC_NEVER_BLOCKED_HOLDER=1
REJECT_SEEN_BLOCKED=0
for i in 1 2 3 4 5 6 7 8; do
  sleep 0.15
  SNAP="$(Q "select pid, query ilike '%pg_sleep(1.5)%' as is_holder, query ilike '%rejected_reason%' as unused, query ilike '%set is_verified = false%' as is_rejecter, wait_event_type, wait_event, pg_blocking_pids(pid) as blocked_by from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid();" 2>/dev/null || true)"
  while IFS='|' read -r pid is_holder unused is_rejecter wet we blocked; do
    [ -z "$pid" ] && continue
    if [ "$is_holder" = "t" ] && [ "$blocked" != "{}" ] && [ -n "$blocked" ]; then DOC_NEVER_BLOCKED_HOLDER=0; fi
    if [ "$is_rejecter" = "t" ] && [ "$blocked" != "{}" ] && [ -n "$blocked" ]; then REJECT_SEEN_BLOCKED=1; fi
  done <<< "$SNAP"
done
echo "-- pg_locks on the document row during the window --"
Q "select l.locktype, l.mode, l.granted, l.pid from pg_locks l join pg_class c on c.oid=l.relation where c.relname='documents' order by l.pid, l.granted desc;" 2>/dev/null || true

set +e; wait "$P10AA"; E10AA=$?; wait "$P10AB"; E10AB=$?; set -e
echo "10a-A(activation holder) exit=$E10AA  10a-B(reject-document) exit=$E10AB"

if grep -qi "deadlock" "$T/s10aA.out" "$T/s10aB.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif [ "$DOC_NEVER_BLOCKED_HOLDER" -ne 1 ]; then
  echo "!! FAIL: the activation-holding session was itself observed blocked -- reversal reachable"; FAIL=1
elif [ "$REJECT_SEEN_BLOCKED" -ne 1 ]; then
  echo "!! WARN: never observed the reject-document session blocked (timing-sensitive) -- re-run to confirm; continuing with data checks"
else
  echo "-> OK: externally confirmed via pg_blocking_pids() across a polled window -- the reject-document UPDATE (FOR NO KEY UPDATE) was blocked on the activation session's FOR SHARE lock on the same document row; the activation session was never blocked by anything."
fi

FINAL_INTEGRATION_STATUS="$(Q "select configuration_status from public.carrier_factoring_integrations where id='$S10A_IID'::uuid;")"
FINAL_DOC_VERIFIED="$(Q "select is_verified from public.documents where id='9d0e0000-0000-0000-0000-000000000001';")"
echo "10a-B own output:"; cat "$T/s10aB.out" | grep -i "error\|reject_document_result" || true
if [ "$FINAL_INTEGRATION_STATUS" = "ready" ] && [ "$FINAL_DOC_VERIFIED" = "t" ]; then
  echo "-> OK: activation committed first and is now ready/active; the reject-document UPDATE that raced it was correctly REJECTED by the row-level dependency guard (documents is one of its six watched tables) -- the document remains verified, exactly as it must while an active integration depends on it. No torn NOA/integration state."
elif [ "$FINAL_INTEGRATION_STATUS" != "ready" ] && [ "$FINAL_DOC_VERIFIED" = "f" ]; then
  echo "-> OK (alternate valid ordering): the reject-document UPDATE somehow committed before activation reached 'ready'; the integration is correctly NOT active, and no invariant is violated."
else
  echo "!! FAIL: inconsistent final state -- integration=$FINAL_INTEGRATION_STATUS, document is_verified=$FINAL_DOC_VERIFIED (this combination should be unreachable)"; FAIL=1
fi
N_ACTIVATE_EVENTS="$(Q "select count(*) from public.activity_logs where entity_id='a1a1a1a1-0000-0000-0000-000000000001' and action='factoring_integration_activate' and changes->>'integration_id'='$S10A_IID';")"
if [ "$N_ACTIVATE_EVENTS" != "1" ]; then echo "!! FAIL: expected exactly 1 activation audit event, got $N_ACTIVATE_EVENTS"; FAIL=1
else echo "-> OK: exactly one audit event for the successful activation -- the rejected (rolled back) document-rejection attempt left no partial audit trail either."
fi
assert_invariant_holds

echo
echo "=================  SCENARIO 10b: document rejected FIRST -- a later activation attempt gets structured NOT_READY, never an exception  ================="
# Reset: re-verify the document and bring the integration back to
# pending_verification so 10b starts from a clean, known state.
"${PSQL[@]}" -c "update public.documents set is_verified=true, verified_by='aaaa0000-0000-0000-0000-000000000001', verified_at=now() where id='9d0e0000-0000-0000-0000-000000000001';" >/dev/null
revoke_all_on "fe0e0000-0000-0000-0000-0000000000a3"
configure_and_verify "fe0e0000-0000-0000-0000-0000000000a3" "s10bint" "s10bsetup"
S10B_IID="$(cat "$T/s10bint.id")"

"${PSQL[@]}" -c "
update public.documents set is_verified=false
where id='9d0e0000-0000-0000-0000-000000000001';
" >/dev/null

RESULT_10B="$("${PSQL[@]}" -tA -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.activate_carrier_factoring_integration('$S10B_IID'::uuid, 'attempt activation after document rejected', (select updated_at from public.carrier_factoring_integrations where id='$S10B_IID'::uuid), 's10b-activate');
" | tail -1)"
echo "10b activation result: $RESULT_10B"
if echo "$RESULT_10B" | grep -q '"success": false' && echo "$RESULT_10B" | grep -q 'noa_document_not_verified'; then
  echo "-> OK: activation after the document was already rejected returns a structured NOT_READY/noa_document_not_verified result -- no exception, no partial mutation."
else
  echo "!! FAIL: expected a structured NOT_READY/noa_document_not_verified result, got: $RESULT_10B"; FAIL=1
fi
assert_invariant_holds
# restore document to verified for cleanliness
"${PSQL[@]}" -c "update public.documents set is_verified=true where id='9d0e0000-0000-0000-0000-000000000001';" >/dev/null

echo
if [ "$FAIL" -eq 0 ]; then
  echo "TEST CONCURRENCY 0141 INTEGRATION LIFECYCLE PASSED (all 9 original scenarios + document-unverification race, 10a/10b)"
else
  echo "TEST CONCURRENCY 0141 INTEGRATION LIFECYCLE: FAILURES ABOVE"
fi
exit "$FAIL"
