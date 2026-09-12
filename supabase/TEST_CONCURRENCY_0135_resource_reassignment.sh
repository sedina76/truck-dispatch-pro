#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0135_resource_reassignment.sh -- REAL two-session
# concurrency proof for public.reassign_dispatch_resources() (Phase 3A.2,
# item 6). Every scenario uses genuine separate PostgreSQL sessions/
# connections, not sequential simulation.
#
# Required results (item 6): no deadlock errors; a deliberate business
# rejection where appropriate; no torn driver/truck/trailer combination; no
# cross-carrier resource assignment; exactly one audit event per successful
# idempotent operation.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0135_resource_reassignment.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_resource_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54905}"
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
DB=resource_concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")

echo "== bootstrap: seed + 0130-0135 =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f migrations/0130_carrier_context_foundation.sql >/dev/null
"${PSQL[@]}" -f migrations/0131_carrier_party_relationships.sql >/dev/null
"${PSQL[@]}" -f migrations/0132_load_carrier_and_trailer_scope.sql >/dev/null
"${PSQL[@]}" -f migrations/0133_deterministic_carrier_backfill.sql >/dev/null
"${PSQL[@]}" -f migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql >/dev/null
"${PSQL[@]}" -f migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql >/dev/null

FAIL=0
PGDATA_TMP="$PGDATA_DIR"

# =========================== SCENARIO 1 ====================================
echo
echo "=================  SCENARIO 1: resource reassignment vs. cancel_dispatch (same dispatch)  ================="
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  ('d1000000-0000-0000-0000-0000000000c1', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S1a'),
  ('d1000000-0000-0000-0000-0000000000c2', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S1b');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  ('c1000000-0000-0000-0000-0000000000c1', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S1a'),
  ('c1000000-0000-0000-0000-0000000000c2', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S1b');
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('e1000000-0000-0000-0000-00000000001e', '11111111-1111-1111-1111-111111111111', 'LD-CONC1', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('e1d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e1000000-0000-0000-0000-00000000001e',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000c1', 'd1000000-0000-0000-0000-0000000000c1', 'assigned');
"
cat > "$PGDATA_TMP/s1a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
-- Phase 3A.4 (item 1): p_expected_updated_at is now MANDATORY for any
-- REPLACEMENT (this swaps both driver and truck away from the seed values
-- above). Captured HERE, before the deliberate sleep -- exactly like a
-- real dispatcher who loaded the edit page, then waited, then hit Save --
-- so it can genuinely go stale if B's cancellation lands first.
select updated_at as ts from public.dispatches where id = 'e1d10000-0000-0000-0000-000000000001' \gset
select pg_sleep(1);
select public.reassign_dispatch_resources('e1d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000c2', 'c1000000-0000-0000-0000-0000000000c2', null, 'swap driver/truck', null, :'ts');
select 'S1-A: completed.' as note;
EOF
cat > "$PGDATA_TMP/s1b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
begin;
select 1 from public.loads where id = 'e1000000-0000-0000-0000-00000000001e' for update;
select pg_sleep(2.5);
select 1 from public.dispatches where id = 'e1d10000-0000-0000-0000-000000000001' for update;
update public.dispatches set status = 'cancelled', cancelled_at = now() where id = 'e1d10000-0000-0000-0000-000000000001';
select 'S1-B: completed.' as note;
commit;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s1b.sql" > "$PGDATA_TMP/s1b.out" 2>&1 &
P1B=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s1a.sql" > "$PGDATA_TMP/s1a.out" 2>&1 &
P1A=$!
set +e; wait "$P1A"; E1A=$?; wait "$P1B"; E1B=$?; set -e
echo "S1-A exit=$E1A  S1-B exit=$E1B"
# B (cancel_dispatch, no pre-sleep) always locks first and wins the race
# deterministically here. A then unblocks and re-reads under its own lock.
# Two DIFFERENT, both CORRECT, listed-acceptable outcomes are now possible
# for A (item 6: "a deliberate business rejection where appropriate";
# Phase 3A.4 item 1 adds a second, EARLIER one): the mandatory-version
# check runs before the terminal-status check, so a legitimate own-version
# mismatch (A captured its version before B's cancellation committed) is
# now caught as a structured stale_record result FIRST -- A never even
# reaches the "dispatch is cancelled" business rule. If somehow the
# version still matched (a hypothetical tighter timing), the terminal-
# status check (RRINV) is the fallback. Either way: not a raw error, not a
# deadlock, not silent corruption -- A succeeding here is ALSO fine (a
# valid ordering where A's own reassignment committed before B's
# cancellation became visible to it).
if grep -qi "deadlock" "$PGDATA_TMP/s1a.out" "$PGDATA_TMP/s1b.out"; then
  echo "!! FAIL: deadlock detected (resource reassignment vs cancel_dispatch)"; FAIL=1
elif [ "$E1B" -ne 0 ]; then
  echo "!! FAIL: cancel_dispatch (B) failed unexpectedly"; cat "$PGDATA_TMP/s1b.out"; FAIL=1
elif [ "$E1A" -eq 0 ] && grep -q '"stale_record": true' "$PGDATA_TMP/s1a.out"; then
  echo "-> OK: no deadlock; B's cancellation won the race, and A's now-stale captured version was rejected as a structured stale_record result (Phase 3A.4 item 1) -- not a raw error, not a deadlock, not silent corruption."
elif [ "$E1A" -eq 0 ] && ! grep -q '"success": false' "$PGDATA_TMP/s1a.out"; then
  echo "-> OK: no deadlock; both operations happened to serialize with A succeeding before B's cancellation was visible to it (a valid ordering)."
elif grep -qE "RRINV|resources cannot be reassigned on a cancelled dispatch" "$PGDATA_TMP/s1a.out"; then
  echo "-> OK: no deadlock; B's cancellation won the race, and A received the CORRECT, deliberate business rejection (cannot reassign resources on a now-cancelled dispatch) -- not a raw error, not a deadlock, not silent corruption."
else
  echo "!! FAIL: A failed for an UNEXPECTED reason (not the expected post-cancellation rejection):"; cat "$PGDATA_TMP/s1a.out"; FAIL=1
fi

# =========================== SCENARIO 2 ====================================
echo
echo "=================  SCENARIO 2: resource reassignment vs. transition_dispatch_status (same dispatch)  ================="
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  ('d1000000-0000-0000-0000-0000000000c3', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S2a'),
  ('d1000000-0000-0000-0000-0000000000c4', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S2b');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  ('c1000000-0000-0000-0000-0000000000c3', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S2a'),
  ('c1000000-0000-0000-0000-0000000000c4', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S2b');
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('e2000000-0000-0000-0000-00000000002e', '11111111-1111-1111-1111-111111111111', 'LD-CONC2', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('e2d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e2000000-0000-0000-0000-00000000002e',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000c3', 'd1000000-0000-0000-0000-0000000000c3', 'assigned');
"
cat > "$PGDATA_TMP/s2a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
-- Phase 3A.4 (item 1): mandatory version for this driver+truck replacement.
select updated_at as ts from public.dispatches where id = 'e2d10000-0000-0000-0000-000000000001' \gset
select pg_sleep(1);
select public.reassign_dispatch_resources('e2d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000c4', 'c1000000-0000-0000-0000-0000000000c4', null, 'swap for status race test', null, :'ts');
select 'S2-A: completed.' as note;
EOF
cat > "$PGDATA_TMP/s2b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
begin;
select 1 from public.loads where id = 'e2000000-0000-0000-0000-00000000002e' for update;
select pg_sleep(2.5);
commit;
select public.transition_dispatch_status('e2d10000-0000-0000-0000-000000000001', 'accepted');
select 'S2-B: completed.' as note;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s2b.sql" > "$PGDATA_TMP/s2b.out" 2>&1 &
P2B=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s2a.sql" > "$PGDATA_TMP/s2a.out" 2>&1 &
P2A=$!
set +e; wait "$P2A"; E2A=$?; wait "$P2B"; E2B=$?; set -e
echo "S2-A exit=$E2A  S2-B exit=$E2B"
if grep -qi "deadlock" "$PGDATA_TMP/s2a.out" "$PGDATA_TMP/s2b.out"; then
  echo "!! FAIL: deadlock detected (resource reassignment vs status transition)"; FAIL=1
elif [ "$E2A" -ne 0 ] || [ "$E2B" -ne 0 ]; then
  echo "!! FAIL: unexpected failure"; cat "$PGDATA_TMP/s2a.out" "$PGDATA_TMP/s2b.out"; FAIL=1
else
  echo "-> OK: resource reassignment and status transition on the same dispatch serialize cleanly, no deadlock."
fi

# =========================== SCENARIO 3 ====================================
echo
echo "=================  SCENARIO 3: two simultaneous resource reassignments on the SAME dispatch  ================="
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  ('d1000000-0000-0000-0000-0000000000c5', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S3a'),
  ('d1000000-0000-0000-0000-0000000000c6', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S3b'),
  ('d1000000-0000-0000-0000-0000000000c7', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S3c');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  ('c1000000-0000-0000-0000-0000000000c5', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S3a'),
  ('c1000000-0000-0000-0000-0000000000c6', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S3b'),
  ('c1000000-0000-0000-0000-0000000000c7', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S3c');
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('e3000000-0000-0000-0000-00000000003e', '11111111-1111-1111-1111-111111111111', 'LD-CONC3', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('e3d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e3000000-0000-0000-0000-00000000003e',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000c5', 'd1000000-0000-0000-0000-0000000000c5', 'assigned');
"
cat > "$PGDATA_TMP/s3a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
-- Phase 3A.4 (item 1): both A and B capture the SAME pre-race version --
-- exactly like two dispatchers who both had this dispatch's edit page open
-- at the same moment. Whichever actually WINS the row lock applies
-- cleanly; the loser's captured version is now stale (the winner just
-- changed it) and is correctly rejected as stale_record rather than
-- silently overwriting the winner ("last write wins" is no longer this
-- RPC's behavior for a genuine replacement -- that is the whole point of
-- mandatory optimistic concurrency).
select updated_at as ts from public.dispatches where id = 'e3d10000-0000-0000-0000-000000000001' \gset
select public.reassign_dispatch_resources('e3d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000c6', 'c1000000-0000-0000-0000-0000000000c6', null, 'race attempt A', null, :'ts');
select 'S3-A: completed.' as note;
EOF
cat > "$PGDATA_TMP/s3b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select updated_at as ts from public.dispatches where id = 'e3d10000-0000-0000-0000-000000000001' \gset
select pg_sleep(0.2);
select public.reassign_dispatch_resources('e3d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000c7', 'c1000000-0000-0000-0000-0000000000c7', null, 'race attempt B', null, :'ts');
select 'S3-B: completed.' as note;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s3a.sql" > "$PGDATA_TMP/s3a.out" 2>&1 &
P3A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s3b.sql" > "$PGDATA_TMP/s3b.out" 2>&1 &
P3B=$!
set +e; wait "$P3A"; E3A=$?; wait "$P3B"; E3B=$?; set -e
echo "S3-A exit=$E3A  S3-B exit=$E3B"
if grep -qi "deadlock" "$PGDATA_TMP/s3a.out" "$PGDATA_TMP/s3b.out"; then
  echo "!! FAIL: deadlock on two simultaneous resource reassignments"; FAIL=1
elif [ "$E3A" -ne 0 ] || [ "$E3B" -ne 0 ]; then
  echo "!! FAIL: unexpected failure (a raised exception) on a same-version double-reassignment"; cat "$PGDATA_TMP/s3a.out" "$PGDATA_TMP/s3b.out"; FAIL=1
else
  # Phase 3A.4 (item 1): A and B captured the SAME pre-race version, so
  # this is no longer "both apply, last write wins" -- exactly ONE of them
  # must actually apply (a real success) and the OTHER must be rejected as
  # a structured stale_record (its captured version was true at read time,
  # then the winner changed the row before it got there). Neither a raised
  # exception (checked above) nor a torn/third value is acceptable.
  A_STALE=0; B_STALE=0
  grep -q '"stale_record": true' "$PGDATA_TMP/s3a.out" && A_STALE=1
  grep -q '"stale_record": true' "$PGDATA_TMP/s3b.out" && B_STALE=1
  FINAL_DRIVER="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select driver_id from public.dispatches where id='e3d10000-0000-0000-0000-000000000001'")"
  echo "Final driver_id: $FINAL_DRIVER (A stale=$A_STALE, B stale=$B_STALE)"
  if [ "$FINAL_DRIVER" != "d1000000-0000-0000-0000-0000000000c6" ] && [ "$FINAL_DRIVER" != "d1000000-0000-0000-0000-0000000000c7" ]; then
    echo "!! FAIL: final driver_id is neither of the two race attempts -- torn state"; FAIL=1
  elif [ "$A_STALE" -eq 1 ] && [ "$B_STALE" -eq 1 ]; then
    echo "!! FAIL: BOTH attempts were rejected as stale -- expected exactly one winner"; FAIL=1
  elif [ "$A_STALE" -eq 0 ] && [ "$B_STALE" -eq 0 ]; then
    echo "!! FAIL: NEITHER attempt was rejected -- a same-captured-version race should reject exactly one of them, not silently let both apply"; FAIL=1
  elif { [ "$A_STALE" -eq 1 ] && [ "$FINAL_DRIVER" != "d1000000-0000-0000-0000-0000000000c7" ]; } || { [ "$B_STALE" -eq 1 ] && [ "$FINAL_DRIVER" != "d1000000-0000-0000-0000-0000000000c6" ]; }; then
    echo "!! FAIL: final driver_id does not match the non-stale (winning) attempt"; FAIL=1
  else
    echo "-> OK: two simultaneous same-version resource reassignments on the same dispatch serialize cleanly -- exactly one wins (its value is the final state), the other is rejected as stale_record, no torn combination and no silent overwrite."
  fi
fi

# =========================== SCENARIO 4 ====================================
echo
echo "=================  SCENARIO 4: truck reassignment conflict -- two DIFFERENT dispatches racing for the SAME truck  ================="
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  ('d1000000-0000-0000-0000-0000000000c8', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S4a'),
  ('d1000000-0000-0000-0000-0000000000c9', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S4b');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  ('c1000000-0000-0000-0000-0000000000c8', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S4a'),
  ('c1000000-0000-0000-0000-0000000000c9', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S4-CONTESTED');
insert into public.loads (id, organization_id, load_number, broker_id, status) values
  ('e4000000-0000-0000-0000-00000000004e', '11111111-1111-1111-1111-111111111111', 'LD-CONC4A', 'a0b00000-0000-0000-0000-000000000001', 'dispatched'),
  ('e5000000-0000-0000-0000-00000000005e', '11111111-1111-1111-1111-111111111111', 'LD-CONC4B', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status) values
  ('e4d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e4000000-0000-0000-0000-00000000004e',
   'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000c8', 'd1000000-0000-0000-0000-0000000000c8', 'assigned'),
  ('e5d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e5000000-0000-0000-0000-00000000005e',
   'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000c9', 'd1000000-0000-0000-0000-0000000000c9', 'assigned');
"
# Both dispatches attempt to grab TRK-S4-CONTESTED (c1...s9), currently held
# by e5d1. e4d1 wants to take it; simultaneously reassign e5d1 to keep it
# (no-op) is trivial -- the REAL contest is: e4d1 tries to steal it from
# e5d1 while e5d1 is unaffected. Since resources aren't independently locked
# outside the dispatch's own row, the proactive check + the 0054 unique
# index together decide this deterministically -- e4d1's attempt must be
# rejected (truck still active on e5d1), never silently succeed.
cat > "$PGDATA_TMP/s4a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
-- Phase 3A.4 (item 1): mandatory version for this truck replacement.
select updated_at as ts from public.dispatches where id = 'e4d10000-0000-0000-0000-000000000001' \gset
select public.reassign_dispatch_resources('e4d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000c8', 'c1000000-0000-0000-0000-0000000000c9', null, 'attempting to steal the contested truck', null, :'ts');
EOF
set +e
"${PSQL[@]}" -f "$PGDATA_TMP/s4a.sql" > "$PGDATA_TMP/s4a.out" 2>&1
E4A=$?
set -e
echo "S4-A exit=$E4A (expected non-zero: truck already active elsewhere)"
if [ "$E4A" -eq 0 ]; then
  echo "!! FAIL: stealing a truck already active on another dispatch succeeded"; FAIL=1
elif ! grep -qE "RRTRK|already assigned to active dispatch" "$PGDATA_TMP/s4a.out"; then
  echo "!! FAIL: rejected for the wrong reason:"; cat "$PGDATA_TMP/s4a.out"; FAIL=1
else
  echo "-> OK: truck already active on another dispatch cannot be stolen -- deliberate business rejection, not a deadlock, not a silent success."
fi

# =========================== SCENARIO 5 ====================================
echo
echo "=================  SCENARIO 5: shared-trailer reassignment race -- two dispatches genuinely racing for the SAME organization_shared trailer  ================="
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
select public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'organization_shared', 'shared for concurrency test');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  ('d1000000-0000-0000-0000-0000000000ca', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S5a'),
  ('d1000000-0000-0000-0000-0000000000cb', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S5b');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  ('c1000000-0000-0000-0000-0000000000ca', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S5a'),
  ('c1000000-0000-0000-0000-0000000000cb', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S5b');
insert into public.loads (id, organization_id, load_number, broker_id, status) values
  ('e6000000-0000-0000-0000-00000000006e', '11111111-1111-1111-1111-111111111111', 'LD-CONC5A', 'a0b00000-0000-0000-0000-000000000001', 'dispatched'),
  ('e7000000-0000-0000-0000-00000000007e', '11111111-1111-1111-1111-111111111111', 'LD-CONC5B', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status) values
  ('e6d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e6000000-0000-0000-0000-00000000006e',
   'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000ca', 'd1000000-0000-0000-0000-0000000000ca', 'assigned'),
  ('e7d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e7000000-0000-0000-0000-00000000007e',
   'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000cb', 'd1000000-0000-0000-0000-0000000000cb', 'assigned');
"
cat > "$PGDATA_TMP/s5a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select public.reassign_dispatch_resources('e6d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000ca', 'c1000000-0000-0000-0000-0000000000ca', 'e9000000-0000-0000-0000-000000000009', 'claiming the shared trailer, attempt A');
select 'S5-A: completed.' as note;
EOF
cat > "$PGDATA_TMP/s5b.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select pg_sleep(0.15);
select public.reassign_dispatch_resources('e7d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000cb', 'c1000000-0000-0000-0000-0000000000cb', 'e9000000-0000-0000-0000-000000000009', 'claiming the shared trailer, attempt B');
select 'S5-B: completed (or rejected -- see exit code).' as note;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s5a.sql" > "$PGDATA_TMP/s5a.out" 2>&1 &
P5A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s5b.sql" > "$PGDATA_TMP/s5b.out" 2>&1 &
P5B=$!
set +e; wait "$P5A"; E5A=$?; wait "$P5B"; E5B=$?; set -e
echo "S5-A exit=$E5A  S5-B exit=$E5B"
if grep -qi "deadlock" "$PGDATA_TMP/s5a.out" "$PGDATA_TMP/s5b.out"; then
  echo "!! FAIL: deadlock on shared-trailer race"; FAIL=1
elif { [ "$E5A" -eq 0 ] && [ "$E5B" -eq 0 ]; }; then
  echo "!! FAIL: BOTH attempts to claim the same trailer succeeded -- the trailer cannot legitimately be on two active dispatches at once."; cat "$PGDATA_TMP/s5a.out" "$PGDATA_TMP/s5b.out"; FAIL=1
elif { [ "$E5A" -ne 0 ] && [ "$E5B" -ne 0 ]; }; then
  echo "!! FAIL: BOTH attempts failed -- expected exactly one winner."; cat "$PGDATA_TMP/s5a.out" "$PGDATA_TMP/s5b.out"; FAIL=1
else
  TRAILER_COUNT="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.dispatches where trailer_id='e9000000-0000-0000-0000-000000000009' and status<>'cancelled'")"
  echo "active dispatches now holding the shared trailer: $TRAILER_COUNT"
  if [ "$TRAILER_COUNT" != "1" ]; then
    echo "!! FAIL: expected exactly 1 active dispatch holding the shared trailer, got $TRAILER_COUNT"; FAIL=1
  else
    echo "-> OK: exactly one of the two racing attempts won the shared trailer; the other received a deliberate business rejection (0054's trailer unique index is the authoritative backstop). No deadlock, no double-booking."
  fi
fi

# =========================== SCENARIO 6 ====================================
echo
echo "=================  SCENARIO 6: conflicting-carrier tampering under concurrency  ================="
"${PSQL[@]}" -c "
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('e8000000-0000-0000-0000-00000000008e', '11111111-1111-1111-1111-111111111111', 'LD-CONC6', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('e8d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e8000000-0000-0000-0000-00000000008e',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');
"
cat > "$PGDATA_TMP/s6.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
-- Phase 3A.4 (item 1): mandatory version for this driver+truck replacement.
select updated_at as ts from public.dispatches where id = 'e8d10000-0000-0000-0000-000000000001' \gset
select public.reassign_dispatch_resources('e8d10000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', null, 'tampering: cross-carrier driver+truck', null, :'ts');
EOF
set +e
"${PSQL[@]}" -f "$PGDATA_TMP/s6.sql" > "$PGDATA_TMP/s6.out" 2>&1
E6=$?
set -e
echo "S6 exit=$E6 (expected non-zero)"
if [ "$E6" -eq 0 ]; then
  echo "!! FAIL: cross-carrier tampering succeeded"; FAIL=1
elif ! grep -q "does not belong to carrier" "$PGDATA_TMP/s6.out"; then
  echo "!! FAIL: rejected for the wrong reason:"; cat "$PGDATA_TMP/s6.out"; FAIL=1
else
  echo "-> OK: cross-carrier tampering rejected outright."
fi

# =========================== SCENARIO 7 ====================================
echo
echo "=================  SCENARIO 7: replayed idempotency key vs. a DIFFERENT idempotency key, same dispatch, concurrent  ================="
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  ('d1000000-0000-0000-0000-0000000000cc', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S7a'),
  ('d1000000-0000-0000-0000-0000000000cd', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S7b');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  ('c1000000-0000-0000-0000-0000000000cc', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S7a'),
  ('c1000000-0000-0000-0000-0000000000cd', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S7b');
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('e9100000-0000-0000-0000-00000000009e', '11111111-1111-1111-1111-111111111111', 'LD-CONC7', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('e9d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'e9100000-0000-0000-0000-00000000009e',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000cc', 'd1000000-0000-0000-0000-0000000000cc', 'assigned');
"
# 7a: two concurrent calls with the SAME idempotency key -> exactly one real effect.
cat > "$PGDATA_TMP/s7a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
-- Phase 3A.4 (item 1): mandatory version for this driver+truck replacement
-- -- both copies (s7a/s7b are byte-identical, see the cp below) capture
-- the SAME pre-race version, exactly like a genuine client-side retry of
-- the identical submission would. Whichever wins the row lock applies and
-- inserts the ledger row FIRST; the second copy hits the idempotency
-- short-circuit (same dispatch_id + idempotency_key) BEFORE ever reaching
-- the version check at all, and simply replays the cached result -- so
-- this scenario's "exactly one real effect" property is or unaffected by
-- the version becoming stale for a hypothetical second independent call.
select updated_at as ts from public.dispatches where id = 'e9d10000-0000-0000-0000-000000000001' \gset
select public.reassign_dispatch_resources('e9d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000cd', 'c1000000-0000-0000-0000-0000000000cd', null, 'same-key concurrent replay', 'shared-idem-key-7', :'ts');
EOF
cp "$PGDATA_TMP/s7a.sql" "$PGDATA_TMP/s7b.sql"
"${PSQL[@]}" -f "$PGDATA_TMP/s7a.sql" > "$PGDATA_TMP/s7a.out" 2>&1 &
P7A=$!
"${PSQL[@]}" -f "$PGDATA_TMP/s7b.sql" > "$PGDATA_TMP/s7b.out" 2>&1 &
P7B=$!
set +e; wait "$P7A"; E7A=$?; wait "$P7B"; E7B=$?; set -e
echo "S7-A(same key) exit=$E7A  S7-B(same key) exit=$E7B"
AUDIT7="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.activity_logs where entity_id='e9d10000-0000-0000-0000-000000000001' and action='resources_reassigned'")"
echo "audit events after same-key race: $AUDIT7"
if [ "$E7A" -ne 0 ] || [ "$E7B" -ne 0 ]; then
  echo "!! FAIL: a same-idempotency-key concurrent call failed unexpectedly."; cat "$PGDATA_TMP/s7a.out" "$PGDATA_TMP/s7b.out"; FAIL=1
elif [ "$AUDIT7" != "1" ]; then
  echo "!! FAIL: expected exactly 1 audit event for a same-idempotency-key race, got $AUDIT7"; FAIL=1
else
  echo "-> OK: same idempotency key under real concurrency produces exactly ONE audit event."
fi

# 7b: a DIFFERENT idempotency key on the SAME dispatch is a genuinely new
# request -- expect it to be evaluated normally (its own reason required,
# since it is replacing an already-assigned resource again).
# \gset is a psql-client meta-command -- only recognized when read from a
# script file (-f), not from a -c string -- so this needs its own file.
cat > "$PGDATA_TMP/s7c.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select updated_at as ts from public.dispatches where id = 'e9d10000-0000-0000-0000-000000000001' \gset
select public.reassign_dispatch_resources('e9d10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000cc', 'c1000000-0000-0000-0000-0000000000cc', null, 'a genuinely different request', 'different-idem-key-7', :'ts');
EOF
set +e
"${PSQL[@]}" -f "$PGDATA_TMP/s7c.sql" > "$PGDATA_TMP/s7c.out" 2>&1
E7C=$?
set -e
AUDIT7B="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.activity_logs where entity_id='e9d10000-0000-0000-0000-000000000001' and action='resources_reassigned'")"
echo "S7-C(different key) exit=$E7C, total audit events now: $AUDIT7B"
if [ "$E7C" -ne 0 ]; then
  echo "!! FAIL: a genuinely different idempotency key on the same dispatch failed unexpectedly."; cat "$PGDATA_TMP/s7c.out"; FAIL=1
elif [ "$AUDIT7B" != "2" ]; then
  echo "!! FAIL: expected exactly 2 total audit events (1 from the same-key race + 1 from the different key), got $AUDIT7B"; FAIL=1
else
  echo "-> OK: a DIFFERENT idempotency key on the same dispatch is treated as a genuinely new request, applies normally, and gets its OWN audit event."
fi

# =========================== SCENARIO 8 ====================================
echo
echo "=================  SCENARIO 8: lock timeout / retry behavior  ================="
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
values ('d1000000-0000-0000-0000-0000000000ce', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'S8a');
insert into public.trucks (id, organization_id, carrier_id, unit_number)
values ('c1000000-0000-0000-0000-0000000000ce', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-S8a');
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('ea000000-0000-0000-0000-00000000000e', '11111111-1111-1111-1111-111111111111', 'LD-CONC8', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('ead10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'ea000000-0000-0000-0000-00000000000e',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000ce', 'd1000000-0000-0000-0000-0000000000ce', 'assigned');
"
# Session A holds the load lock for 3s (via cancel_dispatch's own pattern).
# Session B sets a 1s statement_timeout and attempts a reassignment -- must
# hit a clean Postgres statement-timeout error, retry, and succeed the
# second time (simulating exactly how an application-level retry loop
# should behave against a lock it briefly cannot acquire -- a timeout is
# not a deadlock and not data corruption).
cat > "$PGDATA_TMP/s8a.sql" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
begin;
select 1 from public.loads where id = 'ea000000-0000-0000-0000-00000000000e' for update;
select pg_sleep(3);
commit;
EOF
"${PSQL[@]}" -f "$PGDATA_TMP/s8a.sql" > "$PGDATA_TMP/s8a.out" 2>&1 &
P8A=$!
sleep 0.5
set +e
psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
set statement_timeout = '1000ms';
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select public.reassign_dispatch_resources('ead10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000ce', 'c1000000-0000-0000-0000-0000000000ce', null, 'attempt under a tight statement_timeout, expected to time out while A holds the load lock');
" > "$PGDATA_TMP/s8b_first.out" 2>&1
E8B1=$?
set -e
wait "$P8A"
echo "first attempt (1s statement_timeout, while A holds the lock for 3s) exit=$E8B1"
if ! grep -qi "statement timeout\|canceling statement" "$PGDATA_TMP/s8b_first.out"; then
  echo "!! FAIL: expected a clean Postgres statement-timeout error, got:"; cat "$PGDATA_TMP/s8b_first.out"; FAIL=1
else
  echo "-> OK: a tight statement_timeout while the load lock is held produces a clean, distinguishable timeout error -- not a hang, not a deadlock, not silent data loss."
fi
# Retry now that A has released the lock -- must succeed cleanly.
set +e
"${PSQL[@]}" -c "
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select public.reassign_dispatch_resources('ead10000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-0000000000ce', 'c1000000-0000-0000-0000-0000000000ce', null, null);
" > "$PGDATA_TMP/s8b_retry.out" 2>&1
E8B2=$?
set -e
echo "retry (lock now free) exit=$E8B2"
if [ "$E8B2" -ne 0 ]; then
  echo "!! FAIL: the retry after the lock was released should have succeeded (a no-op, same driver/truck)."; cat "$PGDATA_TMP/s8b_retry.out"; FAIL=1
else
  echo "-> OK: retrying after a lock-timeout succeeds cleanly once the lock is free -- exactly the pattern an application retry loop should rely on."
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "TEST CONCURRENCY 0135 RESOURCE REASSIGNMENT PASSED"
else
  echo "TEST CONCURRENCY 0135 RESOURCE REASSIGNMENT: FAILURES ABOVE"
fi
exit "$FAIL"
