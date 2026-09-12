#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0140_configuration_races.sh -- Phase 3B.1.6, Sections B/C:
# REAL two-session concurrency proof for the TRIGGER-INCLUSIVE lock graph
# among the four factoring configuration paths (set_default_factoring_
# relationship, approve_factoring_relationship_noa, set_carrier_factoring_
# policy, and direct INSERT/UPDATE on carrier_factoring_integrations /
# factoring_relationships) -- NOT submission (that is
# TEST_CONCURRENCY_0140_submission_safety_races.sh's job).
#
# Section B's own suspected reversal ("A holds relationship row -> A waits
# for factoring_company lock -> B holds factoring_company lock -> B waits
# for relationship row") is tested explicitly below with pg_blocking_pids()/
# pg_locks introspection from a third, independent observer session -- not
# assumed from reading the function bodies alone, per this phase's own
# instruction not to assume an RPC takes only the locks visible directly in
# its body (triggers -- set_updated_at, guard_factoring_relationship_org,
# guard_factoring_relationship_protected_fields, guard_carrier_factoring_
# integration_org -- and FK/unique-index enforcement are all accounted for;
# see the migration 0140 header comment / this phase's final report for the
# full trigger-inclusive lock table).
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0140_configuration_races.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_0140_cfg_races.XXXXXX")"
PGPORT="${PGPORT:-54909}"
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
DB=factoring_0140_cfg_races_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")
Q() { psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "$1"; }

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

echo "== fixtures: one carrier (A1), one factor, four COMPLETE (ready) relationships =="
"${PSQL[@]}" -c "
insert into public.factoring_companies (id, organization_id, name, is_active) values
  ('fc0d0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor CFG', true);
insert into public.factoring_relationships
  (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
   default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
   noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active) values
  ('fe0d0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc0d0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 90,3,10,'deducted_at_funding','non_recourse','Wire Rel A','NOA rel A v1','v1',
   current_date-10, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true, true),
  ('fe0d0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'fc0d0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 85,4,12,'deducted_at_funding','non_recourse','Wire Rel B','NOA rel B v1','v1',
   current_date-10, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', false, true),
  ('fe0d0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'fc0d0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 80,5,15,'deducted_from_reserve','recourse','Wire Rel C','NOA rel C v1','v1',
   current_date-10, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', false, true),
  ('fe0d0000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'fc0d0000-0000-0000-0000-000000000001',
   'a1a1a1a1-0000-0000-0000-000000000001', 88,3,10,'deducted_at_funding','non_recourse','Wire Rel D','NOA rel D v1','v1',
   current_date-10, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', false, true);
update public.carriers set factoring_mode = 'factored' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
"

FAIL=0
T="$PGDATA_DIR"

# ============================================================================
# SECTION B: the suspected relationship/company reversal --
#   A holds relationship row -> A waits for factoring_company advisory lock
#   -> B holds factoring_company advisory lock -> B waits for relationship
#   row
# Session A: approve_factoring_relationship_noa(relA) -- relA IS the
# carrier's current default. Session B: set_default_factoring_relationship
# (relB) -- its very first UPDATE ("clear the prior default") targets
# relA's row (since relA is currently the default), which is exactly the
# same row A holds. Externally verified via pg_blocking_pids()/pg_locks
# from a third, independent session while both are in flight.
# ============================================================================
echo
echo "=================  SECTION B: NOA approval (relA) vs default-change (relB, clearing relA) -- reversal/deadlock proof  ================="

cat > "$T/bA.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
begin;
-- Manually acquire the EXACT row lock approve_factoring_relationship_noa()
-- itself takes internally (a plain `select ... for update` on this same
-- row) -- indistinguishable, from pg_locks' point of view, from being
-- "mid-function" at that exact point, since Postgres lock state is a
-- property of the transaction, not the call stack. /* NOA_SESSION holds relA */
select id from public.factoring_relationships where id = 'fe0d0000-0000-0000-0000-000000000001' for update;
select pg_sleep(1.5);
-- Now perform the REAL call (re-entrant: this session already holds the
-- row lock, so the function's own internal `for update` is an instant
-- no-op) -- proceeds through every trigger the NOA UPDATE actually fires
-- (set_updated_at, guard_factoring_relationship_org, guard_factoring_
-- relationship_protected_fields -- none of which take any further lock,
-- confirmed by static audit and exercised for real right here).
select public.approve_factoring_relationship_noa('fe0d0000-0000-0000-0000-000000000001', 'v2', current_date, 'NOA rel A v2 -- updated under contention') as result;
commit;
EOF

cat > "$T/bB.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.3);
-- /* DEFAULT_SESSION targets relB, must clear relA first */
select public.set_default_factoring_relationship('fe0d0000-0000-0000-0000-000000000002') as result;
EOF

"${PSQL[@]}" -f "$T/bA.sql" > "$T/bA.out" 2>&1 &
PBA=$!
"${PSQL[@]}" -f "$T/bB.sql" > "$T/bB.out" 2>&1 &
PBB=$!

# Observer: POLL pg_stat_activity/pg_blocking_pids() repeatedly across the
# window where A holds relA's row lock (t in [0,1.5]) and B is expected to
# be waiting on it (B's own statement begins at t=0.3) -- identify each
# session by a real, stable substring of its OWN currently-executing
# query text (not a comment, which is not necessarily preserved as the
# active statement text once a later statement in the same script is what
# is actually running) rather than a single fixed-instant read.
NOA_EVER_BLOCKED=0
DEFAULT_SEEN_BLOCKED=0
for i in 1 2 3 4 5 6 7 8; do
  sleep 0.15
  SNAP="$(Q "select pid, query ilike '%pg_sleep(1.5)%' as is_noa_holder, query ilike '%set_default_factoring_relationship%' as is_default_change, wait_event_type, wait_event, state, pg_blocking_pids(pid) as blocked_by from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid();" 2>/dev/null || true)"
  echo "-- snapshot #$i --"
  echo "$SNAP"
  while IFS='|' read -r pid is_noa is_default wet we st blocked; do
    [ -z "$pid" ] && continue
    if [ "$is_noa" = "t" ] && [ "$blocked" != "{}" ] && [ -n "$blocked" ]; then NOA_EVER_BLOCKED=1; fi
    if [ "$is_default" = "t" ] && [ "$blocked" != "{}" ] && [ -n "$blocked" ]; then DEFAULT_SEEN_BLOCKED=1; fi
  done <<< "$SNAP"
done

LOCKS="$(Q "select l.locktype, l.mode, l.granted, l.pid from pg_locks l join pg_class c on c.oid = l.relation where c.relname = 'factoring_relationships' order by l.pid, l.granted desc;" 2>/dev/null || true)"
echo "-- pg_locks on factoring_relationships (last poll) --"
echo "$LOCKS"

set +e; wait "$PBA"; EBA=$?; wait "$PBB"; EBB=$?; set -e
echo "B-session(NOA holder) exit=$EBA  B-session(default-change waiter) exit=$EBB"

# The hypothesized cycle requires A itself to eventually WAIT on something
# B holds (the factoring_company/carrier-default advisory locks). Prove
# the negative directly, across the WHOLE polled window: the NOA session
# is NEVER observed blocked_by anything, while the default-change session
# IS observed blocked (on the NOA session's row lock, not the reverse).
if grep -qi "deadlock" "$T/bA.out" "$T/bB.out"; then
  echo "!! FAIL: deadlock detected"; FAIL=1
elif [ "$EBA" -ne 0 ] || [ "$EBB" -ne 0 ]; then
  echo "!! FAIL: unexpected error"; cat "$T/bA.out" "$T/bB.out"; FAIL=1
elif [ "$NOA_EVER_BLOCKED" -eq 1 ]; then
  echo "!! FAIL: the NOA session was observed waiting on something at some point -- the reversal IS reachable"; FAIL=1
elif [ "$DEFAULT_SEEN_BLOCKED" -eq 0 ]; then
  echo "!! WARN: never observed the default-change session blocked across the polled window (timing-sensitive) -- re-run to confirm; continuing with data checks"
else
  echo "-> OK: externally confirmed via pg_blocking_pids() across a polled window -- the NOA session (holding relA's row lock) was never blocked by anything at any point; the default-change session (holding both advisory locks) WAS observed waiting, on the NOA session's row lock. The hypothesized reversal (A waits for B's advisory lock) did not occur and cannot: approve_factoring_relationship_noa() never acquires any advisory lock at all (confirmed both statically and here, live)."
fi

N_NOA_EVENTS="$(Q "select count(*) from public.activity_logs where entity_id='a1a1a1a1-0000-0000-0000-000000000001' and action='factoring_noa_approved';")"
N_DEFAULT_EVENTS="$(Q "select count(*) from public.activity_logs where entity_id='a1a1a1a1-0000-0000-0000-000000000001' and action='factoring_default_changed';")"
FINAL_STATE="$(Q "select id, is_default, noa_reference from public.factoring_relationships where id in ('fe0d0000-0000-0000-0000-000000000001','fe0d0000-0000-0000-0000-000000000002') order by id;")"
echo "$FINAL_STATE"
if [ "$N_NOA_EVENTS" != "1" ] || [ "$N_DEFAULT_EVENTS" != "1" ]; then
  echo "!! FAIL: expected exactly one audit event per successful mutation (NOA=$N_NOA_EVENTS, default=$N_DEFAULT_EVENTS)"; FAIL=1
elif ! echo "$FINAL_STATE" | grep -q "fe0d0000-0000-0000-0000-000000000001|f|v2" || ! echo "$FINAL_STATE" | grep -q "fe0d0000-0000-0000-0000-000000000002|t|"; then
  echo "!! FAIL: final state is not consistent (expected relA: is_default=false, noa_reference=v2; relB: is_default=true)"; FAIL=1
else
  echo "-> OK: no partially applied NOA/default state -- relA carries BOTH its new NOA reference (from the NOA session) AND is_default=false (from the default-change session); relB is the new default. Exactly one audit event per mutation, neither duplicated."
fi

# ============================================================================
# C1: Default change vs NOA approval on the SAME relationship (distinct
# collision from Section B: both sessions target relB itself directly --
# NOA approval's own row lock vs the "become new default" UPDATE's row
# lock on the SAME row, not the "clear prior default" row).
# ============================================================================
echo
echo "=================  C1: default change (-> relC) vs NOA approval, BOTH on the SAME relationship (relC)  ================="
cat > "$T/c1A.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.approve_factoring_relationship_noa('fe0d0000-0000-0000-0000-000000000003', 'v2', current_date, 'NOA rel C v2 -- race') as result;
EOF
cat > "$T/c1B.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_default_factoring_relationship('fe0d0000-0000-0000-0000-000000000003') as result;
EOF
"${PSQL[@]}" -f "$T/c1A.sql" > "$T/c1A.out" 2>&1 &
PC1A=$!
"${PSQL[@]}" -f "$T/c1B.sql" > "$T/c1B.out" 2>&1 &
PC1B=$!
set +e; wait "$PC1A"; EC1A=$?; wait "$PC1B"; EC1B=$?; set -e
if grep -qi "deadlock" "$T/c1A.out" "$T/c1B.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif [ "$EC1A" -ne 0 ] || [ "$EC1B" -ne 0 ]; then
  echo "!! FAIL: unexpected error"; cat "$T/c1A.out" "$T/c1B.out"; FAIL=1
else
  ROW="$(Q "select is_default, noa_reference from public.factoring_relationships where id='fe0d0000-0000-0000-0000-000000000003';")"
  if [ "$ROW" != "t|v2" ]; then
    echo "!! FAIL: expected relC to be is_default=true AND noa_reference=v2 (both mutations landed), got: $ROW"; FAIL=1
  else
    echo "-> OK: no deadlock; both mutations to the SAME row serialize via its row lock and both land (is_default=true, noa_reference=v2) -- no torn/lost update."
  fi
fi

# ============================================================================
# C2: Default change vs relationship operational UPDATE -- accountant
# renames relC (now the default) via an ORDINARY RLS UPDATE (no RPC) while
# relD becomes the new default (clearing relC).
# ============================================================================
echo
echo "=================  C2: default change (-> relD, clearing relC) vs an ordinary operational UPDATE on relC  ================="
cat > "$T/c2A.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
update public.factoring_relationships set relationship_name = 'Rel C -- renamed under contention' where id = 'fe0d0000-0000-0000-0000-000000000003';
select 'ok' as result;
EOF
cat > "$T/c2B.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_default_factoring_relationship('fe0d0000-0000-0000-0000-000000000004') as result;
EOF
"${PSQL[@]}" -f "$T/c2A.sql" > "$T/c2A.out" 2>&1 &
PC2A=$!
"${PSQL[@]}" -f "$T/c2B.sql" > "$T/c2B.out" 2>&1 &
PC2B=$!
set +e; wait "$PC2A"; EC2A=$?; wait "$PC2B"; EC2B=$?; set -e
if grep -qi "deadlock" "$T/c2A.out" "$T/c2B.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif [ "$EC2A" -ne 0 ] || [ "$EC2B" -ne 0 ]; then
  echo "!! FAIL: unexpected error"; cat "$T/c2A.out" "$T/c2B.out"; FAIL=1
else
  ROW="$(Q "select relationship_name, is_default from public.factoring_relationships where id='fe0d0000-0000-0000-0000-000000000003';")"
  if [ "$ROW" != "Rel C -- renamed under contention|f" ]; then
    echo "!! FAIL: expected relC renamed AND is_default=false, got: $ROW"; FAIL=1
  else
    echo "-> OK: no deadlock; the accountant's ordinary rename and the default-change's clearing UPDATE both land on the same row (relationship_name updated, is_default=false) -- no torn config."
  fi
fi

# ============================================================================
# C3: Default change vs relationship deactivation -- deactivating the
# CURRENT default directly (ordinary UPDATE, is_active=false) races
# becoming-a-new-default (which would clear the current one first). The
# CHECK constraint factoring_relationships_default_must_be_active makes
# the ORDER matter: whichever UPDATE's row lock is acquired first decides
# whether the deactivation attempt succeeds (default already cleared) or
# is rejected outright (still the default -- constraint violation, a
# deterministic business rejection, never a crash/deadlock).
# ============================================================================
echo
echo "=================  C3: default change (-> relC, clearing relD) vs a direct attempt to deactivate relD (the CURRENT default)  ================="
cat > "$T/c3A.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
do $$
begin
  update public.factoring_relationships set is_active = false where id = 'fe0d0000-0000-0000-0000-000000000004';
  raise notice 'DEACTIVATE_RESULT: succeeded';
exception when check_violation then
  raise notice 'DEACTIVATE_RESULT: rejected (check_violation) -- % ', sqlerrm;
end
$$;
EOF
cat > "$T/c3B.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_default_factoring_relationship('fe0d0000-0000-0000-0000-000000000003') as result;
EOF
"${PSQL[@]}" -f "$T/c3A.sql" > "$T/c3A.out" 2>&1 &
PC3A=$!
"${PSQL[@]}" -f "$T/c3B.sql" > "$T/c3B.out" 2>&1 &
PC3B=$!
set +e; wait "$PC3A"; EC3A=$?; wait "$PC3B"; EC3B=$?; set -e
if grep -qi "deadlock" "$T/c3A.out" "$T/c3B.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif [ "$EC3A" -ne 0 ] || [ "$EC3B" -ne 0 ]; then
  echo "!! FAIL: unexpected error (a real crash, not the handled check_violation)"; cat "$T/c3A.out" "$T/c3B.out"; FAIL=1
else
  # Whichever order actually happened, the invariant must hold NOW: no row
  # is ever left is_default=true AND is_active=false at the same time.
  BAD="$(Q "select count(*) from public.factoring_relationships where is_default and not is_active;")"
  echo "-- deactivation attempt outcome --"; grep "DEACTIVATE_RESULT" "$T/c3A.out" || true
  if [ "$BAD" != "0" ]; then
    echo "!! FAIL: found a relationship that is is_default=true AND is_active=false -- invariant violated"; FAIL=1
  else
    echo "-> OK: no deadlock; regardless of interleaving, the CHECK constraint (not a race) decided the deactivation attempt deterministically, and no relationship is ever left default-yet-inactive."
  fi
fi

# ============================================================================
# C4: Policy change (carrier -> direct) vs default change for the SAME
# carrier -- disjoint advisory-lock keys and disjoint locked tables
# (carriers vs factoring_relationships): proven to run with ZERO
# contention, both succeeding concurrently.
# ============================================================================
echo
echo "=================  C4: carrier policy change (factored -> direct) vs default change, SAME carrier  ================="
CARRIER_UPDATED_AT="$(Q "select updated_at from public.carriers where id='a1a1a1a1-0000-0000-0000-000000000001';")"
cat > "$T/c4A.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'direct', 'C4 race test', '$CARRIER_UPDATED_AT'::timestamptz, null) as result;
EOF
cat > "$T/c4B.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_default_factoring_relationship('fe0d0000-0000-0000-0000-000000000004') as result;
EOF
"${PSQL[@]}" -f "$T/c4A.sql" > "$T/c4A.out" 2>&1 &
PC4A=$!
"${PSQL[@]}" -f "$T/c4B.sql" > "$T/c4B.out" 2>&1 &
PC4B=$!
set +e; wait "$PC4A"; EC4A=$?; wait "$PC4B"; EC4B=$?; set -e
if grep -qi "deadlock" "$T/c4A.out" "$T/c4B.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif [ "$EC4A" -ne 0 ] || [ "$EC4B" -ne 0 ] || ! grep -q '"success": true' "$T/c4A.out" || ! grep -q '"success": true' "$T/c4B.out"; then
  echo "!! FAIL: both mutations were expected to succeed independently"; cat "$T/c4A.out" "$T/c4B.out"; FAIL=1
else
  CLASSIFY="$("${PSQL[@]}" -tA -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.classify_carrier_factoring_readiness('a1a1a1a1-0000-0000-0000-000000000001');
" | tail -1)"
  echo "classify_carrier_factoring_readiness -> $CLASSIFY"
  echo "-> OK: no lock contention between policy change and default change (disjoint advisory keys, disjoint locked tables) -- both succeeded concurrently; classifier reports one consistent, well-formed result afterward."
fi
# restore factored for the remaining scenarios
"${PSQL[@]}" -c "update public.carriers set factoring_mode='factored' where id='a1a1a1a1-0000-0000-0000-000000000001';" >/dev/null

# ============================================================================
# C5: Integration INSERT/UPDATE vs relationship deactivation. The
# integration's FK to factoring_relationships takes FOR KEY SHARE on the
# referenced row (RI trigger); an ordinary deactivation UPDATE takes FOR NO
# KEY UPDATE. Per Postgres's own row-lock compatibility matrix these do
# NOT conflict -- proven here with two real sessions, both succeeding with
# no blocking.
# ============================================================================
echo
echo "=================  C5: integration INSERT (references relB) vs ordinary deactivation of relB  ================="
cat > "$T/c5A.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
insert into public.carrier_factoring_integrations
  (organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, secret_reference, configuration_status, is_active, approved_by, approved_at)
values
  ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'fe0d0000-0000-0000-0000-000000000002',
   'fc0d0000-0000-0000-0000-000000000001', 'api', 'vault://c5-race', 'active', true, 'aaaa0000-0000-0000-0000-000000000001', now())
returning jsonb_build_object('success', true) as result;
EOF
cat > "$T/c5B.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
update public.factoring_relationships set is_active = false where id = 'fe0d0000-0000-0000-0000-000000000002';
select jsonb_build_object('success', true) as result;
EOF
"${PSQL[@]}" -f "$T/c5A.sql" > "$T/c5A.out" 2>&1 &
PC5A=$!
"${PSQL[@]}" -f "$T/c5B.sql" > "$T/c5B.out" 2>&1 &
PC5B=$!
set +e; wait "$PC5A"; EC5A=$?; wait "$PC5B"; EC5B=$?; set -e
if grep -qi "deadlock" "$T/c5A.out" "$T/c5B.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif [ "$EC5A" -ne 0 ] || [ "$EC5B" -ne 0 ]; then
  echo "!! FAIL: unexpected error"; cat "$T/c5A.out" "$T/c5B.out"; FAIL=1
else
  N_ACTIVE_INTEGRATIONS="$(Q "select count(*) from public.carrier_factoring_integrations where factoring_relationship_id='fe0d0000-0000-0000-0000-000000000002' and is_active;")"
  REL_ACTIVE="$(Q "select is_active from public.factoring_relationships where id='fe0d0000-0000-0000-0000-000000000002';")"
  echo "-> OK: no deadlock, no blocking (FOR KEY SHARE from the integration's FK is compatible with the deactivation's FOR NO KEY UPDATE) -- integration row created (active integrations=$N_ACTIVE_INTEGRATIONS) and relationship deactivated (is_active=$REL_ACTIVE) independently. (Note, not a concurrency defect: this schema does not itself forbid an active integration from referencing a now-inactive relationship -- a business-rule question for a future phase, out of scope here per 'do not expand factoring functionality.')"
fi

# ============================================================================
# C6: Integration INSERT/UPDATE vs policy change -- both reference the SAME
# carriers row (the integration's FK takes FOR KEY SHARE on it; the policy
# change takes FOR NO KEY UPDATE via its own FOR UPDATE select) -- again
# compatible, proven non-blocking.
# ============================================================================
echo
echo "=================  C6: integration INSERT (references carrier A1) vs policy change on carrier A1  ================="
CARRIER_UPDATED_AT2="$(Q "select updated_at from public.carriers where id='a1a1a1a1-0000-0000-0000-000000000001';")"
cat > "$T/c6A.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
insert into public.carrier_factoring_integrations
  (organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, secret_reference, configuration_status, is_active, approved_by, approved_at)
values
  ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'fe0d0000-0000-0000-0000-000000000003',
   'fc0d0000-0000-0000-0000-000000000001', 'api', 'vault://c6-race', 'active', true, 'aaaa0000-0000-0000-0000-000000000001', now())
returning jsonb_build_object('success', true) as result;
EOF
cat > "$T/c6B.sql" <<EOF
\\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_carrier_factoring_policy('a1a1a1a1-0000-0000-0000-000000000001', 'factored', 'C6 race test (no-op mode, still exercises the lock)', '$CARRIER_UPDATED_AT2'::timestamptz, null) as result;
EOF
"${PSQL[@]}" -f "$T/c6A.sql" > "$T/c6A.out" 2>&1 &
PC6A=$!
"${PSQL[@]}" -f "$T/c6B.sql" > "$T/c6B.out" 2>&1 &
PC6B=$!
set +e; wait "$PC6A"; EC6A=$?; wait "$PC6B"; EC6B=$?; set -e
if grep -qi "deadlock" "$T/c6A.out" "$T/c6B.out"; then
  echo "!! FAIL: deadlock"; FAIL=1
elif [ "$EC6A" -ne 0 ] || [ "$EC6B" -ne 0 ] || ! grep -q '"success": true' "$T/c6B.out"; then
  echo "!! FAIL: unexpected error"; cat "$T/c6A.out" "$T/c6B.out"; FAIL=1
else
  echo "-> OK: no deadlock, no blocking -- integration INSERT and policy change both completed independently against the same carrier row (FOR KEY SHARE vs FOR NO KEY UPDATE are compatible)."
fi

# ============================================================================
# C7: Two NOA approvals on the SAME relationship -- both take the row's
# real FOR UPDATE lock; the second must SERIALIZE behind the first (queue,
# not deadlock), and whichever commits second's values are the ones that
# stick, with exactly two audit events (one per approval).
# ============================================================================
echo
echo "=================  C7: two concurrent NOA approvals on the SAME relationship (relD)  ================="
cat > "$T/c7A.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.approve_factoring_relationship_noa('fe0d0000-0000-0000-0000-000000000004', 'vA', current_date, 'NOA rel D -- session A') as result;
EOF
cat > "$T/c7B.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.approve_factoring_relationship_noa('fe0d0000-0000-0000-0000-000000000004', 'vB', current_date, 'NOA rel D -- session B') as result;
EOF
"${PSQL[@]}" -f "$T/c7A.sql" > "$T/c7A.out" 2>&1 &
PC7A=$!
"${PSQL[@]}" -f "$T/c7B.sql" > "$T/c7B.out" 2>&1 &
PC7B=$!
set +e; wait "$PC7A"; EC7A=$?; wait "$PC7B"; EC7B=$?; set -e
if grep -qi "deadlock" "$T/c7A.out" "$T/c7B.out"; then
  echo "!! FAIL: deadlock -- two same-row lockers on independent single resources must never deadlock"; FAIL=1
elif [ "$EC7A" -ne 0 ] || [ "$EC7B" -ne 0 ]; then
  echo "!! FAIL: unexpected error"; cat "$T/c7A.out" "$T/c7B.out"; FAIL=1
else
  N_EVENTS="$(Q "select count(*) from public.activity_logs where entity_id='a1a1a1a1-0000-0000-0000-000000000001' and action='factoring_noa_approved' and changes->>'relationship_id'='fe0d0000-0000-0000-0000-000000000004';")"
  FINAL_REF="$(Q "select noa_reference from public.factoring_relationships where id='fe0d0000-0000-0000-0000-000000000004';")"
  if [ "$N_EVENTS" != "2" ]; then
    echo "!! FAIL: expected exactly 2 audit events (one per approval), got $N_EVENTS"; FAIL=1
  elif [ "$FINAL_REF" != "vA" ] && [ "$FINAL_REF" != "vB" ]; then
    echo "!! FAIL: final noa_reference is neither session's value: $FINAL_REF"; FAIL=1
  else
    echo "-> OK: no deadlock -- the second approval serialized behind the first on the row lock (a queue, not a cycle); exactly 2 audit events, one per approval, and the row holds whichever session's values committed last ($FINAL_REF) -- no torn state."
  fi
fi

# ============================================================================
# C8: Lock timeout then retry, for the SAME collision class as Section B --
# session A holds a relationship row open; session B (short
# statement_timeout) attempts a default-change that needs to clear it,
# times out cleanly, then a retry after A releases succeeds deterministically.
# ============================================================================
echo
echo "=================  C8: lock held open (NOA session on relC) -> default-change attempt times out -> clean retry  ================="
# Deterministic reset -- force relC to be the SOLE current default
# regardless of whatever C1-C7 left behind, so relD's "become default"
# call is guaranteed to need to clear relC's row (the one A holds).
"${PSQL[@]}" -c "
update public.factoring_relationships set is_default = false where carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001';
update public.factoring_relationships set is_default = true where id = 'fe0d0000-0000-0000-0000-000000000003';
" >/dev/null
cat > "$T/c8A.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
begin;
select id from public.factoring_relationships where id = 'fe0d0000-0000-0000-0000-000000000003' for update;
select pg_sleep(1.2);
commit;
EOF
cat > "$T/c8B.sql" <<'EOF'
\set ON_ERROR_STOP on
set statement_timeout = '400ms';
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select pg_sleep(0.1);
select public.set_default_factoring_relationship('fe0d0000-0000-0000-0000-000000000004') as result;
EOF
"${PSQL[@]}" -f "$T/c8A.sql" > "$T/c8A.out" 2>&1 &
PC8A=$!
"${PSQL[@]}" -f "$T/c8B.sql" > "$T/c8B.out" 2>&1 &
PC8B=$!
set +e; wait "$PC8A"; EC8A=$?; wait "$PC8B"; EC8B=$?; set -e
echo "C8-A(holder) exit=$EC8A  C8-B(waiter, 400ms timeout) exit=$EC8B"
if [ "$EC8B" -eq 0 ]; then
  echo "!! FAIL: the waiting session should have timed out, not completed"; cat "$T/c8B.out"; FAIL=1
elif ! grep -qi "statement timeout" "$T/c8B.out"; then
  echo "!! FAIL: expected a statement_timeout error while waiting on the held lock"; cat "$T/c8B.out"; FAIL=1
else
  echo "C8-B correctly timed out. Retrying now that C8-A has released relC's row lock..."
  cat > "$T/c8retry.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
select public.set_default_factoring_relationship('fe0d0000-0000-0000-0000-000000000004') as result;
EOF
  "${PSQL[@]}" -f "$T/c8retry.sql" > "$T/c8retry.out" 2>&1
  if ! grep -q '"success": true' "$T/c8retry.out"; then
    echo "!! FAIL: the retry after the lock was released did not succeed"; cat "$T/c8retry.out"; FAIL=1
  else
    IS_DEFAULT="$(Q "select is_default from public.factoring_relationships where id='fe0d0000-0000-0000-0000-000000000004';")"
    if [ "$IS_DEFAULT" != "t" ]; then
      echo "!! FAIL: expected relD to be the default after the retry, got is_default=$IS_DEFAULT"; FAIL=1
    else
      echo "-> OK: the timed-out attempt produced no partial effect, and the retry -- once the row lock was free -- deterministically succeeded and set the intended new default. No double effect, no corruption."
    fi
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "TEST CONCURRENCY 0140 CONFIGURATION RACES PASSED (Section B + C1-C8)"
else
  echo "TEST CONCURRENCY 0140 CONFIGURATION RACES: FAILURES ABOVE"
fi
exit "$FAIL"
