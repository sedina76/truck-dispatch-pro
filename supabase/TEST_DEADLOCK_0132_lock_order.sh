#!/usr/bin/env bash
# ============================================================================
# TEST_DEADLOCK_0132_lock_order.sh -- REAL two-session reverse-lock-order
# test (Phase 3A clarification round, item 4: "verify the trigger does not
# create deadlock risk").
#
# LOCK-ORDER AUDIT (read-only inspection of every path that touches both
# loads and dispatches in the same transaction), done before writing this
# test:
--
#   create_dispatch()  (0129, migrations/0129_atomic_dispatch_lifecycle.sql
#                        step 3 / step 7): locks the LOAD (`for update`)
#                        FIRST, then INSERTs the new dispatch row. LOAD then
#                        DISPATCH order.
#   cancel_dispatch()   (0129, same file, explicitly documented "Lock order
#                        is loads THEN dispatches, identical to
#                        create_dispatch, so the two can never deadlock"):
#                        `perform 1 from loads where id=v_load_id for
#                        update;` THEN `select ... from dispatches where
#                        id=p_dispatch_id for update;`. LOAD then DISPATCH.
#   guard_dispatch_carrier_scope() (0132, THIS correction's own new
#                        trigger, BEFORE INSERT OR UPDATE on dispatches):
#                        by the time this trigger's body runs, Postgres has
#                        ALREADY locked the target DISPATCH row as part of
#                        executing the INSERT/UPDATE statement (a BEFORE ROW
#                        trigger cannot run before its own row is locked --
#                        this is a structural Postgres constraint, not a
#                        choice this trigger makes). The trigger THEN
#                        acquires the LOAD lock (`for update`). For a fresh
#                        INSERT this is harmless (no dispatch row existed to
#                        conflict over). For an UPDATE that is carrier-
#                        relevant (carrier_id/load_id change, or
#                        REACTIVATION of a cancelled dispatch), this is
#                        DISPATCH then LOAD order -- the REVERSE of
#                        create_dispatch/cancel_dispatch.
#   guard_load_carrier_change() (0132, BEFORE INSERT OR UPDATE on loads):
#                        only ever does a plain (non-locking) SELECT COUNT(*)
#                        against dispatches -- never acquires a dispatch row
#                        lock. Cannot participate in a lock-order cycle.
#   auto_generate_invoice_from_delivered_load() (existing, AFTER UPDATE on
#                        loads): reads/writes invoices, not dispatches or
#                        loads locks beyond the row already being updated.
#                        Not part of this lock-order class.
#
# REAL, CURRENTLY-REACHABLE TRIGGER FOR THE REVERSE ORDER (verified by
# reading application code, read-only, no files modified): "src/app/(app)/
# dispatch/board-actions.ts" updateDispatchBoardStatus() issues a DIRECT
# `supabase.from("dispatches").update({status: newStatus, ...})` -- NOT
# through cancel_dispatch()/create_dispatch() -- and its VALID_STATUSES set
# includes every status including 'cancelled', with NO check on the
# dispatch's CURRENT status before allowing the move. This makes
# REACTIVATION (status leaving 'cancelled') via a raw UPDATE a real,
# reachable path today, not merely theoretical -- exactly the DISPATCH-then-
# LOAD path above. cancel_dispatch() concurrently cancelling that SAME
# dispatch is LOAD-then-DISPATCH. This script proves that specific pairing
# is a genuine (if narrow) deadlock opportunity, and that Postgres's own
# deadlock detector resolves it safely (one transaction aborts cleanly with
# "deadlock detected"; the other completes; no data corruption; no hang).
#
# Usage:  cd supabase && ./TEST_DEADLOCK_0132_lock_order.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_deadlock.XXXXXX")"
PGPORT="${PGPORT:-54899}"
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
DB=deadlock_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")

echo "== bootstrap: seed + 0130-0132 =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f migrations/0130_carrier_context_foundation.sql >/dev/null
"${PSQL[@]}" -f migrations/0131_carrier_party_relationships.sql >/dev/null
"${PSQL[@]}" -f migrations/0132_load_carrier_and_trailer_scope.sql >/dev/null

echo "== fixture: L_DL with a CANCELLED dispatch D_DL (ready to be 'reactivated' exactly as updateDispatchBoardStatus() would do via a raw UPDATE) =="
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
PIDFILE_A="$PGDATA_TMP/sessionA.pid"
PIDFILE_B="$PGDATA_TMP/sessionB.pid"

# Session A: exactly what updateDispatchBoardStatus() does -- a direct,
# single UPDATE that reactivates the cancelled dispatch. Postgres locks the
# DISPATCH row as part of processing this UPDATE (before any trigger runs);
# guard_dispatch_carrier_scope's BEFORE trigger then requests the LOAD lock
# (v_reactivating = true). DISPATCH-then-LOAD order, exactly as the header
# above describes. Started AFTER B has taken the load lock (via the sleep
# below), so this is where the cycle actually forms.
cat > "$SESSA_SQL" <<'EOF'
\set ON_ERROR_STOP on
select 'A backend pid: ' || pg_backend_pid();
select pg_sleep(1);  -- let B acquire the LOAD lock first (see B's script)
select 'A: reactivating the cancelled dispatch via a raw UPDATE (exactly updateDispatchBoardStatus()) -- locks the DISPATCH row first, then the trigger requests the LOAD lock...' as note;
update public.dispatches set status = 'assigned' where id = 'd2000000-0000-0000-0000-00000000002d';
select 'A: completed (unexpected if a deadlock should have aborted one side -- inspect which side actually won).' as note;
EOF

# Session B: exactly cancel_dispatch()'s own documented lock order (0129:
# "lock LOAD first (matches create_dispatch's order), then the dispatch") --
# LOAD first, held across a deliberate sleep so A has time to grab the
# dispatch row, THEN the dispatch row (where it will collide with A). Two
# explicit statements, matching the real function's own two separate locking
# statements exactly (not wrapped in a helper function, so the timing below
# is fully controlled by this script, not hidden inside a single call).
cat > "$SESSB_SQL" <<'EOF'
\set ON_ERROR_STOP on
select pg_backend_pid() as backend_pid \gset
\o :pidfile
\qecho :backend_pid
\o
select 'B backend pid: ' || :backend_pid;
begin;
select 'B: locking the LOAD first (cancel_dispatch''s own order)...' as note;
select 1 from public.loads where id = 'd1000000-0000-0000-0000-00000000001d' for update;
select pg_sleep(2.5);  -- hold the load lock well past A's dispatch-row acquisition
select 'B: now attempting to lock the DISPATCH row (A should already hold it)...' as note;
select 1 from public.dispatches where id = 'd2000000-0000-0000-0000-00000000002d' for update;
update public.dispatches set status = 'cancelled', cancelled_at = now() where id = 'd2000000-0000-0000-0000-00000000002d';
select 'B: completed (unexpected if a deadlock should have aborted one side -- inspect which side actually won).' as note;
commit;
EOF

echo
echo "=================  DEADLOCK RACE  ================="
echo "-- starting Session B (background: locks LOAD, sleeps, then wants DISPATCH) --"
"${PSQL[@]}" -v pidfile="$PIDFILE_B" -f "$SESSB_SQL" > "$LOGB" 2>&1 &
PID_B_WAIT=$!

echo "-- starting Session A (background: after 1s, reactivates the dispatch -- locks DISPATCH, then wants LOAD) --"
"${PSQL[@]}" -f "$SESSA_SQL" > "$LOGA" 2>&1 &
PID_A_WAIT=$!

set +e
wait "$PID_A_WAIT"; A_EXIT=$?
wait "$PID_B_WAIT"; B_EXIT=$?
set -e

echo "--- Session A log ---"; cat "$LOGA"
echo "--- Session B log ---"; cat "$LOGB"
echo "Session A exit=$A_EXIT   Session B exit=$B_EXIT"

FAIL=0

# Exactly one side must have hit "deadlock detected" and been aborted; the
# OTHER side must have completed normally. If NEITHER did, the cycle never
# actually formed (test is inconclusive -- timing did not overlap as
# intended). If BOTH failed, something worse than a simple deadlock happened.
A_DEADLOCK=0; B_DEADLOCK=0
grep -qi "deadlock detected" "$LOGA" && A_DEADLOCK=1
grep -qi "deadlock detected" "$LOGB" && B_DEADLOCK=1

echo "A_DEADLOCK=$A_DEADLOCK  B_DEADLOCK=$B_DEADLOCK"

if [ "$A_DEADLOCK" -eq 1 ] && [ "$B_DEADLOCK" -eq 0 ] && [ "$B_EXIT" -eq 0 ]; then
  echo "-> OK: genuine deadlock cycle formed and was detected -- Session A (dispatch-then-load, the reactivation path) was the one aborted; Session B (cancel_dispatch's load-then-dispatch order) completed normally."
elif [ "$B_DEADLOCK" -eq 1 ] && [ "$A_DEADLOCK" -eq 0 ] && [ "$A_EXIT" -eq 0 ]; then
  echo "-> OK: genuine deadlock cycle formed and was detected -- Session B was the one aborted; Session A completed normally. (Which specific side Postgres chooses to abort is not guaranteed or important -- what matters is exactly one side loses cleanly.)"
elif [ "$A_DEADLOCK" -eq 0 ] && [ "$B_DEADLOCK" -eq 0 ]; then
  echo "!! INCONCLUSIVE: neither session reported a deadlock -- the two operations did not actually overlap as intended (both completed, meaning they serialized rather than cycled). Re-run, or the timing sleeps need adjusting for this machine."
  FAIL=1
else
  echo "!! UNEXPECTED: deadlock/exit pattern does not match a clean single-side abort. Manual inspection required."
  FAIL=1
fi

echo "-- confirm no corruption regardless of outcome: the dispatch ends in EXACTLY ONE valid, non-torn state --"
FINAL="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select status from public.dispatches where id='d2000000-0000-0000-0000-00000000002d'")"
echo "final dispatch status: $FINAL"
if [ "$FINAL" != "assigned" ] && [ "$FINAL" != "cancelled" ]; then
  echo "!! FAIL: dispatch ended in an invalid/torn status ($FINAL)."
  FAIL=1
else
  echo "-> OK: dispatch ended in a single, valid, well-defined status ($FINAL) -- Postgres's deadlock detector guarantees no torn/partial state, exactly the same guarantee an ordinary lock-wait failure would give. A deadlock is a LIVENESS event (one side must retry), never a CORRECTNESS/integrity event."
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "TEST DEADLOCK 0132 LOCK ORDER PASSED (deadlock reproduced and safely resolved by Postgres, zero corruption)"
else
  echo "TEST DEADLOCK 0132 LOCK ORDER: FAILURES ABOVE"
fi
exit "$FAIL"
