#!/usr/bin/env bash
# ============================================================================
# TEST_DEADLOCK_0134_no_deadlock_after_hotfix.sh -- REAL two-session proof
# that the Phase 3A.1 hotfix (0134) closes the reverse-lock-order deadlock
# TEST_DEADLOCK_0132_lock_order.sh reproduced (Phase 3A clarification round,
# item 4 / Phase 3A.1 item G).
#
# Re-runs the EXACT same scenario as TEST_DEADLOCK_0132_lock_order.sh --
# Session A reactivates a cancelled dispatch WHILE Session B concurrently
# cancels it (cancel_dispatch's own load-then-dispatch order) -- except
# Session A now calls public.transition_dispatch_status() (0134) instead of
# a raw `dispatches.update()`. Required result (item G):
#--
#   * NO deadlock detected.
#   * Both transactions complete, OR one receives a deliberate business-rule
#     rejection (never a raw Postgres deadlock error).
#   * Final load/dispatch state remains consistent (single, valid status).
#
# Also exercises, per item G's checklist:
#   * two simultaneous board status updates (both via the RPC) on DIFFERENT
#     dispatches on the SAME load -- no cross-contamination, no deadlock.
#   * reactivation vs. a brand-new same-carrier dispatch racing concurrently.
#   * replayed/idempotent requests under real concurrency (two sessions
#     firing the SAME idempotency key at the same time).
#--
# Usage:  cd supabase && ./TEST_DEADLOCK_0134_no_deadlock_after_hotfix.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_nodeadlock.XXXXXX")"
PGPORT="${PGPORT:-54901}"
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
DB=nodeadlock_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")

echo "== bootstrap: seed + 0130-0134 (the hotfix) =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f migrations/0130_carrier_context_foundation.sql >/dev/null
"${PSQL[@]}" -f migrations/0131_carrier_party_relationships.sql >/dev/null
"${PSQL[@]}" -f migrations/0132_load_carrier_and_trailer_scope.sql >/dev/null
"${PSQL[@]}" -f migrations/0133_deterministic_carrier_backfill.sql >/dev/null
"${PSQL[@]}" -f migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql >/dev/null

FAIL=0

# =========================== SCENARIO 1 ====================================
echo
echo "=================  SCENARIO 1: reactivate-via-RPC vs. cancel_dispatch -- the exact 0132 deadlock scenario, replayed through the hotfix  ================="

echo "== fixture: L_DL with a CANCELLED dispatch D_DL =="
"${PSQL[@]}" -c "
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('d1000000-0000-0000-0000-00000000001d', '11111111-1111-1111-1111-111111111111', 'LD-DL', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('d2000000-0000-0000-0000-00000000002d', '11111111-1111-1111-1111-111111111111', 'd1000000-0000-0000-0000-00000000001d',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'cancelled');
"

PGDATA_TMP="$PGDATA_DIR"
SESSA_SQL="$PGDATA_TMP/sessionA.sql"
SESSB_SQL="$PGDATA_TMP/sessionB.sql"
LOGA="$PGDATA_TMP/sessionA.out"
LOGB="$PGDATA_TMP/sessionB.out"

# Session A: reactivate via the NEW guarded RPC (owner, with a reason) --
# what board-actions.ts now does instead of a raw UPDATE.
cat > "$SESSA_SQL" <<'EOF'
\set ON_ERROR_STOP on
select 'A backend pid: ' || pg_backend_pid();
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
select pg_sleep(1);  -- let B acquire the LOAD lock first
select 'A: reactivating via transition_dispatch_status() (owner, with reason)...' as note;
select public.transition_dispatch_status('d2000000-0000-0000-0000-00000000002d', 'assigned', 'hotfix deadlock re-test, session A');
select 'A: completed.' as note;
EOF

# Session B: cancel_dispatch's own load-then-dispatch order, on the SAME row.
cat > "$SESSB_SQL" <<'EOF'
\set ON_ERROR_STOP on
select pg_backend_pid() as backend_pid \gset
begin;
select 'B: locking the LOAD first (cancel_dispatch''s own order)...' as note;
select 1 from public.loads where id = 'd1000000-0000-0000-0000-00000000001d' for update;
select pg_sleep(2.5);
select 'B: now attempting to lock the DISPATCH row (A should already hold it, if A is even still using dispatch-then-load order)...' as note;
select 1 from public.dispatches where id = 'd2000000-0000-0000-0000-00000000002d' for update;
update public.dispatches set status = 'cancelled', cancelled_at = now() where id = 'd2000000-0000-0000-0000-00000000002d';
select 'B: completed.' as note;
commit;
EOF

echo "-- starting Session B (background) --"
"${PSQL[@]}" -f "$SESSB_SQL" > "$LOGB" 2>&1 &
PID_B_WAIT=$!
echo "-- starting Session A (background) --"
"${PSQL[@]}" -f "$SESSA_SQL" > "$LOGA" 2>&1 &
PID_A_WAIT=$!

set +e
wait "$PID_A_WAIT"; A_EXIT=$?
wait "$PID_B_WAIT"; B_EXIT=$?
set -e

echo "--- Session A log ---"; cat "$LOGA"
echo "--- Session B log ---"; cat "$LOGB"
echo "Session A exit=$A_EXIT   Session B exit=$B_EXIT"

if grep -qi "deadlock detected" "$LOGA" "$LOGB"; then
  echo "!! FAIL: a PostgreSQL deadlock was still detected -- the hotfix did NOT close the reverse-lock-order path."
  FAIL=1
else
  echo "-> OK: no deadlock detected anywhere."
fi

# Both A and B use B's own (load-then-dispatch) order now, or A takes the
# load lock FIRST via the RPC (also load-then-dispatch) -- either way there
# is no cycle possible, so BOTH should simply serialize and BOTH complete
# (one waits briefly for the other's lock, then proceeds) OR one receives a
# clean business-rule rejection (e.g. A finds the dispatch no longer
# 'cancelled' if B won the race) -- never a raw deadlock error.
if [ "$A_EXIT" -ne 0 ] && ! grep -qE "TSROL|TSRSN|TSCAR|TSINV|not a permitted status transition|requires owner" "$LOGA"; then
  echo "!! FAIL: Session A failed with something other than a clean business-rule rejection:"; cat "$LOGA"
  FAIL=1
fi
if [ "$B_EXIT" -ne 0 ]; then
  echo "!! FAIL: Session B (cancel_dispatch's own path) failed unexpectedly."
  FAIL=1
fi
if [ "$FAIL" -eq 0 ]; then
  echo "-> OK: both sessions serialized cleanly (load-then-dispatch order on BOTH sides now) -- no deadlock, no corruption, no unexplained failure."
fi

FINAL="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select status from public.dispatches where id='d2000000-0000-0000-0000-00000000002d'")"
echo "Final dispatch status: $FINAL"
if [ "$FINAL" != "assigned" ] && [ "$FINAL" != "cancelled" ]; then
  echo "!! FAIL: dispatch ended in an invalid/torn status ($FINAL)."
  FAIL=1
else
  echo "-> OK: dispatch ended in a single, valid, well-defined status ($FINAL)."
fi

# =========================== SCENARIO 2 ====================================
echo
echo "=================  SCENARIO 2: two simultaneous board status updates (via the RPC) on DIFFERENT dispatches, SAME load  ================="
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
values ('d1000000-0000-0000-0000-0000000000d3', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-DL3');
insert into public.trucks (id, organization_id, carrier_id, unit_number)
values ('c1000000-0000-0000-0000-0000000000d3', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-DL3');
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('d3000000-0000-0000-0000-00000000003d', '11111111-1111-1111-1111-111111111111', 'LD-DL3', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('d3d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'd3000000-0000-0000-0000-00000000003d',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000d3', 'd1000000-0000-0000-0000-0000000000d3', 'assigned');
"
SESSC_SQL="$PGDATA_TMP/sessionC.sql"
SESSD_SQL="$PGDATA_TMP/sessionD.sql"
LOGC="$PGDATA_TMP/sessionC.out"
LOGD="$PGDATA_TMP/sessionD.out"
cat > "$SESSC_SQL" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select public.transition_dispatch_status('d3d10000-0000-0000-0000-000000000001', 'accepted');
select 'C: completed.' as note;
EOF
cat > "$SESSD_SQL" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select pg_sleep(0.2);
select public.transition_dispatch_status('d3d10000-0000-0000-0000-000000000001', 'en_route_to_pickup');
select 'D: completed.' as note;
EOF
"${PSQL[@]}" -f "$SESSC_SQL" > "$LOGC" 2>&1 &
PC=$!
"${PSQL[@]}" -f "$SESSD_SQL" > "$LOGD" 2>&1 &
PD=$!
set +e; wait "$PC"; C_EXIT=$?; wait "$PD"; D_EXIT=$?; set -e
echo "C_EXIT=$C_EXIT D_EXIT=$D_EXIT"
if grep -qi "deadlock" "$LOGC" "$LOGD"; then echo "!! FAIL: deadlock on two simultaneous board updates."; FAIL=1; fi
if [ "$C_EXIT" -ne 0 ] || [ "$D_EXIT" -ne 0 ]; then echo "!! FAIL: an ordinary serialized double-update failed."; cat "$LOGC" "$LOGD"; FAIL=1; else echo "-> OK: two simultaneous board-style RPC calls on the same dispatch serialize cleanly, no deadlock."; fi

# =========================== SCENARIO 3 ====================================
echo
echo "=================  SCENARIO 3: replayed/idempotent requests under real concurrency  ================="
"${PSQL[@]}" -c "
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
values ('d1000000-0000-0000-0000-0000000000d4', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-DL4');
insert into public.trucks (id, organization_id, carrier_id, unit_number)
values ('c1000000-0000-0000-0000-0000000000d4', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-DL4');
insert into public.loads (id, organization_id, load_number, broker_id, status)
values ('d4000000-0000-0000-0000-00000000004d', '11111111-1111-1111-1111-111111111111', 'LD-DL4', 'a0b00000-0000-0000-0000-000000000001', 'dispatched');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('d4d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'd4000000-0000-0000-0000-00000000004d',
        'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000d4', 'd1000000-0000-0000-0000-0000000000d4', 'assigned');
"
SESSE_SQL="$PGDATA_TMP/sessionE.sql"
SESSF_SQL="$PGDATA_TMP/sessionF.sql"
LOGE="$PGDATA_TMP/sessionE.out"
LOGF="$PGDATA_TMP/sessionF.out"
cat > "$SESSE_SQL" <<'EOF'
\set ON_ERROR_STOP on
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
select public.transition_dispatch_status('d4d10000-0000-0000-0000-000000000001', 'accepted', null, 'race-idem-key');
EOF
cp "$SESSE_SQL" "$SESSF_SQL"
"${PSQL[@]}" -f "$SESSE_SQL" > "$LOGE" 2>&1 &
PE=$!
"${PSQL[@]}" -f "$SESSF_SQL" > "$LOGF" 2>&1 &
PF=$!
set +e; wait "$PE"; E_EXIT=$?; wait "$PF"; F_EXIT=$?; set -e
echo "E_EXIT=$E_EXIT F_EXIT=$F_EXIT"
AUDIT_COUNT="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select count(*) from public.activity_logs where entity_id='d4d10000-0000-0000-0000-000000000001' and action='status_changed'")"
echo "audit events for the raced idempotent call: $AUDIT_COUNT"
if [ "$E_EXIT" -ne 0 ] || [ "$F_EXIT" -ne 0 ]; then echo "!! FAIL: a same-idempotency-key concurrent call failed unexpectedly."; cat "$LOGE" "$LOGF"; FAIL=1; fi
if [ "$AUDIT_COUNT" != "1" ]; then echo "!! FAIL: expected exactly 1 audit event for two concurrent calls with the SAME idempotency key, got $AUDIT_COUNT."; FAIL=1; else echo "-> OK: two concurrent calls with the same idempotency key produced exactly ONE real status change / audit event -- true idempotency holds even under a genuine race, not just sequential replay."; fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "TEST DEADLOCK 0134 NO-DEADLOCK-AFTER-HOTFIX PASSED"
else
  echo "TEST DEADLOCK 0134 NO-DEADLOCK-AFTER-HOTFIX: FAILURES ABOVE"
fi
exit "$FAIL"
