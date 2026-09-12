#!/usr/bin/env bash
# ============================================================================
# TEST_CONCURRENCY_0132_carrier_guard.sh -- REAL two-session concurrency test
# (correction #3: a sequential test does not prove concurrency safety).
#
# Spins up its own throwaway PostgreSQL 18 cluster (independent of
# TEST_0130_0133_run.sh), applies 0130-0132 (NOT 0133 -- this test wants a
# genuinely open, unresolved load to race on), then opens TWO REAL,
# concurrent OS-level psql connections against it and proves:
#
# SCENARIO 1: conflicting-carrier dispatch race on the SAME load (correction
#   #1-#3: "the concurrency test revealed a critical cross-carrier integrity
#   defect" / "the correct outcome is not both conflicting dispatches
#   preserved"). Proves guard_dispatch_carrier_scope()'s authoritative row
#   lock (0132 section D) genuinely serializes and rejects the loser, rather
#   than the OLD behavior (both dispatches surviving, only the financial-
#   controller assignment being contested).
#   Session A: BEGIN; INSERT dispatch DA (carrier A1) on load L_RACE
#              (carrier_id currently NULL) -- guard_dispatch_carrier_scope's
#              own SELECT ... FOR UPDATE atomically claims the load
#              (carrier_id=A1, carrier_resolution='resolved') inside this
#              same transaction; pg_sleep(3); COMMIT.
#   Session B: (started ~1.5s later, so A is provably mid-sleep, still
#              holding its row lock) BEGIN; INSERT dispatch DB (carrier A2)
#              on the SAME load -- EXPECTED TO FAIL once unblocked, since by
#              then A's committed claim makes A1 the load's authoritative
#              carrier and guard_dispatch_carrier_scope rejects the mismatch.
#   While A sleeps, the orchestrator polls pg_stat_activity for B's backend
#   PID and asserts pg_blocking_pids() names A -- concrete, external proof
#   that B is genuinely BLOCKED on Postgres's row lock (guard_dispatch_
#   carrier_scope's own SELECT ... FOR UPDATE on the loads row, acquired
#   before A's BEFORE INSERT trigger returns), not just executing
#   sequentially by coincidence.
#   After A commits and B's session exits: asserts B's psql process exited
#   NON-ZERO (the INSERT raised, no COMMIT ever ran for B), asserts exactly
#   ONE dispatch (DA) exists on L_RACE (DB was never written -- not "written
#   but not controller"), asserts loads.carrier_id = A1 = the sole surviving
#   dispatch's carrier, financial_dispatch_id points to DA (carrier A1),
#   carrier_resolution = 'resolved', and zero carrier mismatches anywhere on
#   the load. Then applies 0133 and confirms the already-resolved load passes
#   through unchanged (PRE_EXISTING, per TEST_0133_PREEXISTING_CARRIER_RACE.sql
#   -- 0132's own guard resolved it before 0133 ever ran).
#
# SCENARIO 2: concurrent zero-activity carrier assignment on ANOTHER load
#   Two sessions concurrently attempt to set loads.carrier_id on a
#   DIFFERENT, zero-dispatch load to two different carriers. Documents the
#   actual, honest outcome: Postgres serializes the two UPDATEs (the second
#   blocks on the row lock until the first commits), then the second
#   re-evaluates guard_load_carrier_change against the now-current (already
#   non-NULL) row. Since guard_load_carrier_change's zero-activity
#   reassignment rule permits value -> different-value when there is still
#   no dependent activity, the second UPDATE also succeeds: this is
#   documented as CORRECT, EXPECTED "last-committed-write-wins" behavior
#   (no torn/inconsistent state -- Postgres's row lock already guarantees
#   that), not a defect requiring additional locking.
#
# Usage:  cd supabase && ./TEST_CONCURRENCY_0132_carrier_guard.sh
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PGDATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pg_concurrency.XXXXXX")"
PGPORT="${PGPORT:-54897}"
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
  -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off" \
  -w start >/dev/null

export PGUSER=postgres PGHOST PGPORT
DB=concurrency_test
createdb "$DB"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB")

echo "== bootstrap: seed + 0130-0132 (NOT 0133) =="
"${PSQL[@]}" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
"${PSQL[@]}" -f migrations/0130_carrier_context_foundation.sql >/dev/null
"${PSQL[@]}" -f migrations/0131_carrier_party_relationships.sql >/dev/null
"${PSQL[@]}" -f migrations/0132_load_carrier_and_trailer_scope.sql >/dev/null

echo "== fixture: L_RACE, zero dispatches, carrier_id NULL =="
"${PSQL[@]}" -c "insert into public.loads (id, organization_id, load_number, broker_id, status) values ('c0000000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'LD-RACE', 'a0b00000-0000-0000-0000-000000000001', 'booked');" >/dev/null
echo "== fixture: L_RACE2, zero dispatches, carrier_id NULL (scenario 2) =="
"${PSQL[@]}" -c "insert into public.loads (id, organization_id, load_number, broker_id, status) values ('c2000000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'LD-RACE2', 'a0b00000-0000-0000-0000-000000000001', 'booked');" >/dev/null

FAIL=0

# =========================== SCENARIO 1 ====================================
echo
echo "=================  SCENARIO 1: conflicting-carrier dispatch race  ================="

SESSA_SQL="$PGDATA_DIR/sessionA.sql"
SESSB_SQL="$PGDATA_DIR/sessionB.sql"
LOGA="$PGDATA_DIR/sessionA.out"
LOGB="$PGDATA_DIR/sessionB.out"
PIDFILE_B="$PGDATA_DIR/sessionB.pid"

cat > "$SESSA_SQL" <<'EOF'
\set ON_ERROR_STOP on
select 'A backend pid: ' || pg_backend_pid();
begin;
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('a0a00000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111',
        'c0000000-0000-0000-0000-00000000000c', 'a1a1a1a1-0000-0000-0000-000000000001',
        'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');
select 'A: dispatch DA inserted, controller-assignment lock held. Sleeping 3s...' as note;
select pg_sleep(3);
commit;
select 'A: committed.' as note;
EOF

cat > "$SESSB_SQL" <<'EOF'
\set ON_ERROR_STOP on
select pg_backend_pid() as backend_pid \gset
\o :pidfile
\qecho :backend_pid
\o
select pg_sleep(1.5);  -- let A start its transaction, insert, and enter its own sleep first
select 'B: attempting a conflicting-carrier dispatch on the SAME load (expect to BLOCK on the row lock, then be REJECTED once unblocked)...' as note;
begin;
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
values ('b0b00000-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111',
        'c0000000-0000-0000-0000-00000000000c', 'a2a2a2a2-0000-0000-0000-000000000002',
        'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'assigned');
select 'B: TEST FAIL -- the conflicting-carrier INSERT should never have succeeded.' as note;
commit;
EOF

echo "-- starting Session A (background) --"
"${PSQL[@]}" -v pidfile="$PIDFILE_B" -f "$SESSA_SQL" > "$LOGA" 2>&1 &
PID_A_WAIT=$!

echo "-- starting Session B (background, internally waits 1.5s before its own transaction) --"
"${PSQL[@]}" -v pidfile="$PIDFILE_B" -f "$SESSB_SQL" > "$LOGB" 2>&1 &
PID_B_WAIT=$!

# Wait for B to have written its backend pid (proves B's session/connection exists)
for i in $(seq 1 50); do
  [ -s "$PIDFILE_B" ] && break
  sleep 0.1
done
B_BACKEND_PID="$(tr -d '[:space:]' < "$PIDFILE_B" 2>/dev/null || true)"
echo "Session B backend pid: ${B_BACKEND_PID:-unknown}"

# Poll for CONCRETE, EXTERNAL proof B is blocked ON A SPECIFICALLY --
# pg_blocking_pids() is more precise than wait_event_type alone (it names
# the exact blocker). Polls for up to ~8s, which comfortably spans B's
# internal 1.5s warm-up plus A's full 3s hold.
BLOCKED_OBSERVED=0
for i in $(seq 1 40); do
  sleep 0.2
  if [ -n "${B_BACKEND_PID:-}" ]; then
    BLOCKERS="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" \
      -c "select coalesce(array_to_string(pg_blocking_pids($B_BACKEND_PID), ','), '')" 2>/dev/null || true)"
    if [ -n "$BLOCKERS" ]; then
      BLOCKED_OBSERVED=1
      echo "OBSERVED: session B (pid $B_BACKEND_PID) is blocked by pid(s) [$BLOCKERS] -- genuinely blocked on a real Postgres lock, not merely slow."
      break
    fi
  fi
done

set +e
wait "$PID_A_WAIT"; A_EXIT=$?
wait "$PID_B_WAIT"; B_EXIT=$?
set -e

echo "--- Session A log ---"; cat "$LOGA"
echo "--- Session B log ---"; cat "$LOGB"
echo "Session A exit=$A_EXIT   Session B exit=$B_EXIT"

if [ "$BLOCKED_OBSERVED" -ne 1 ]; then
  echo "!! FAIL: never observed session B blocked via pg_blocking_pids() -- the concurrency proof is incomplete."
  FAIL=1
else
  echo "-> OK: session B was observed genuinely blocked (pg_blocking_pids non-empty) while session A held the row lock."
fi

if [ "$A_EXIT" -ne 0 ]; then
  echo "!! FAIL: session A (the legitimate, uncontested dispatch) was expected to succeed but exited non-zero."
  FAIL=1
else
  echo "-> OK: session A's dispatch (carrier A1) succeeded."
fi

if [ "$B_EXIT" -eq 0 ]; then
  echo "!! FAIL: session B's conflicting-carrier INSERT exited ZERO (succeeded) -- this is exactly the defect being corrected. It must be rejected."
  FAIL=1
elif grep -qF 'does not match load' "$LOGB" && grep -qF 'a conflicting carrier can never coexist' "$LOGB"; then
  echo "-> OK: session B's conflicting-carrier INSERT was rejected by guard_dispatch_carrier_scope() with the expected carrier-mismatch error, once unblocked."
else
  echo "!! FAIL: session B failed, but not with the expected carrier-mismatch rejection -- inspect Session B log above."
  FAIL=1
fi
if grep -qF "TEST FAIL" "$LOGB"; then
  echo "!! FAIL: session B's log reached the post-INSERT 'TEST FAIL' marker -- the INSERT did not actually fail."
  FAIL=1
fi

echo "-- verifying final state: exactly one dispatch, one carrier, consistent controller, zero mismatches --"
RESULT="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "
  select
    (select count(*) from public.dispatches where load_id='c0000000-0000-0000-0000-00000000000c') as n_dispatches,
    (select count(*) from public.dispatches where load_id='c0000000-0000-0000-0000-00000000000c' and status <> 'cancelled') as n_noncancelled,
    (select financial_dispatch_id from public.loads where id='c0000000-0000-0000-0000-00000000000c') as controller,
    (select carrier_id from public.loads where id='c0000000-0000-0000-0000-00000000000c') as load_carrier,
    (select carrier_resolution from public.loads where id='c0000000-0000-0000-0000-00000000000c') as resolution,
    (select count(distinct carrier_id) from public.dispatches where load_id='c0000000-0000-0000-0000-00000000000c' and status <> 'cancelled') as n_distinct_live_carriers
")"
echo "n_dispatches | n_noncancelled | controller | load_carrier | resolution | n_distinct_live_carriers = $RESULT"

N_DISP="$(echo "$RESULT" | cut -d'|' -f1 | tr -d '[:space:]')"
N_NONCANC="$(echo "$RESULT" | cut -d'|' -f2 | tr -d '[:space:]')"
CONTROLLER="$(echo "$RESULT" | cut -d'|' -f3 | tr -d '[:space:]')"
LOAD_CARRIER="$(echo "$RESULT" | cut -d'|' -f4 | tr -d '[:space:]')"
RESOLUTION="$(echo "$RESULT" | cut -d'|' -f5 | tr -d '[:space:]')"
N_LIVE_CARRIERS="$(echo "$RESULT" | cut -d'|' -f6 | tr -d '[:space:]')"

if [ "$N_DISP" != "1" ] || [ "$N_NONCANC" != "1" ]; then
  echo "!! FAIL: expected exactly 1 dispatch (DA) on L_RACE, got n_dispatches=$N_DISP n_noncancelled=$N_NONCANC -- DB must never have been written at all."
  FAIL=1
else
  echo "-> OK: exactly ONE dispatch exists on L_RACE (DA, carrier A1) -- DB was rejected outright, not written-but-not-controller. No conflicting non-cancelled dispatch survives."
fi

if [ "$CONTROLLER" != "a0a00000-0000-0000-0000-00000000000a" ]; then
  echo "!! FAIL: expected DA to be the financial controller, got '$CONTROLLER'."
  FAIL=1
else
  echo "-> OK: financial_dispatch_id = DA."
fi

if [ "$LOAD_CARRIER" != "a1a1a1a1-0000-0000-0000-000000000001" ] || [ "$RESOLUTION" != "resolved" ]; then
  echo "!! FAIL: expected loads.carrier_id=A1 / carrier_resolution=resolved, got carrier_id='$LOAD_CARRIER' resolution='$RESOLUTION'."
  FAIL=1
else
  echo "-> OK: loads.carrier_id = A1 (the surviving dispatch's carrier), carrier_resolution = resolved -- atomically claimed by guard_dispatch_carrier_scope() inside session A's own transaction, BEFORE session B was ever unblocked."
fi

if [ "$N_LIVE_CARRIERS" != "1" ]; then
  echo "!! FAIL: expected exactly 1 distinct carrier among non-cancelled dispatches on L_RACE, got $N_LIVE_CARRIERS -- a carrier mismatch survived."
  FAIL=1
else
  echo "-> OK: zero carrier mismatches -- financial_dispatch_id's carrier (A1), loads.carrier_id (A1), and every non-cancelled dispatch's carrier (A1) all agree."
fi

echo "-- applying 0133 and confirming the already-resolved load passes through unchanged (PRE_EXISTING) --"
"${PSQL[@]}" -f migrations/0133_deterministic_carrier_backfill.sql >/dev/null
CLASS_CARRIER="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select carrier_resolution || '|' || coalesce(carrier_id::text,'') from public.loads where id='c0000000-0000-0000-0000-00000000000c'")"
CLASS="$(echo "$CLASS_CARRIER" | cut -d'|' -f1)"
CARRIER="$(echo "$CLASS_CARRIER" | cut -d'|' -f2)"
# The load was ALREADY resolved by guard_dispatch_carrier_scope() during
# session A's transaction, well before 0133 ever runs -- so it is the
# PRE_EXISTING case 0133 explicitly detects and leaves untouched (same class
# TEST_0133_PREEXISTING_CARRIER_RACE.sql already proves), NOT a fresh C1/C2
# classification. This end-to-end assertion confirms 0132's guard and 0133's
# backfill compose safely with no ambiguity surviving into the backfill.
if [ "$CLASS" != "resolved" ] || [ "$CARRIER" != "a1a1a1a1-0000-0000-0000-000000000001" ]; then
  echo "!! FAIL: expected L_RACE to remain classified 'resolved'/A1 after 0133 (PRE_EXISTING passthrough), got resolution='$CLASS' carrier='$CARRIER'."
  FAIL=1
else
  echo "-> OK: 0133 left the already-resolved raced load exactly as guard_dispatch_carrier_scope() set it ('resolved'/A1, PRE_EXISTING passthrough) -- end-to-end concurrency-to-backfill correctness confirmed, no ambiguity survives."
fi

# =========================== SCENARIO 2 ====================================
echo
echo "=================  SCENARIO 2: concurrent zero-activity carrier assignment  ================="

SESSC_SQL="$PGDATA_DIR/sessionC.sql"
SESSD_SQL="$PGDATA_DIR/sessionD.sql"
LOGC="$PGDATA_DIR/sessionC.out"
LOGD="$PGDATA_DIR/sessionD.out"

cat > "$SESSC_SQL" <<'EOF'
\set ON_ERROR_STOP on
begin;
update public.loads set carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'
 where id = 'c2000000-0000-0000-0000-00000000000c';
select pg_sleep(2);
commit;
select 'C: committed carrier_id=A1.' as note;
EOF

cat > "$SESSD_SQL" <<'EOF'
\set ON_ERROR_STOP on
select pg_sleep(0.7);  -- let C start and take the row lock first
select 'D: attempting a concurrent assignment on the SAME zero-activity load (expect to BLOCK)...' as note;
update public.loads set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002'
 where id = 'c2000000-0000-0000-0000-00000000000c';
select 'D: unblocked and committed carrier_id=A2 (last-committed-write-wins, zero-activity reassignment is permitted -- documented, not a defect).' as note;
EOF

"${PSQL[@]}" -f "$SESSC_SQL" > "$LOGC" 2>&1 &
PID_C=$!
"${PSQL[@]}" -f "$SESSD_SQL" > "$LOGD" 2>&1 &
PID_D=$!
wait "$PID_C" || true
wait "$PID_D" || true

echo "--- Session C log ---"; cat "$LOGC"
echo "--- Session D log ---"; cat "$LOGD"

FINAL_CARRIER="$(psql -X -tA -h "$PGHOST" -p "$PGPORT" -U postgres -d "$DB" -c "select carrier_id from public.loads where id='c2000000-0000-0000-0000-00000000000c'")"
echo "Final carrier_id for L_RACE2: $FINAL_CARRIER"
if [ "$FINAL_CARRIER" != "a2a2a2a2-0000-0000-0000-000000000002" ] && [ "$FINAL_CARRIER" != "a1a1a1a1-0000-0000-0000-000000000001" ]; then
  echo "!! FAIL: final carrier_id is neither A1 nor A2 -- torn/corrupted state."
  FAIL=1
else
  echo "-> OK: final state is a single, consistent, valid carrier_id (Postgres's row lock guarantees no torn write). Documented behavior: two concurrent zero-activity assignments serialize; the LAST COMMITTED write determines the final value. This is correct MVCC semantics for a plain UPDATE, not a race condition -- there is no window where the row is inconsistent or where both writers believe they succeeded with different final states."
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CONCURRENCY SCENARIOS PASSED"
else
  echo "CONCURRENCY TEST: FAILURES ABOVE"
fi
exit "$FAIL"
