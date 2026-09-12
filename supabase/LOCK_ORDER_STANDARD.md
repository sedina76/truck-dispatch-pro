# Lock-order standard for `loads` / `dispatches` (and related resources)

Phase 3A.2, item 5. **The one required order for every code path that
touches both `loads` and `dispatches` in the same transaction:**

1. **Load** (`select ... from loads where id = ... for update`)
2. **Dispatch** (`select ... from dispatches where id = ... for update`, or
   the implicit row lock from an `UPDATE`/`INSERT` on it)
3. **Related resource rows, in a consistent order** — driver, then truck,
   then trailer (matches the column order already used throughout
   `guard_dispatch_org`, `create_dispatch`, and `reassign_dispatch_resources`)
4. Validation
5. Mutation
6. Audit

No path in this codebase acquires resource-row locks explicitly (driver/
truck/trailer conflicts are read via plain `SELECT`, backed by the 0054
partial unique indexes as the race-proof authority — see below), so step 3
is a reading/ordering convention for future code, not a currently-taken
explicit lock.

## Audit of every path touching both tables (or their financial-controller
relationship)

| Path | File | Order used | Conforms? |
|---|---|---|---|
| `create_dispatch()` | `migrations/0129_atomic_dispatch_lifecycle.sql` (~L417-424, step 3) | Load **first** (`for update`), then INSERTs the dispatch (which locks it implicitly), then driver/truck/trailer conflict `SELECT`s (unlocked, backed by 0054) | ✅ |
| `cancel_dispatch()` | same file (~L611-614), explicitly documented "so the two can never deadlock" | Load **first** (`for update`), then the specific dispatch row (`for update`) | ✅ |
| `transition_dispatch_status()` | `migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql` (STEP 1/STEP 2) | Load **first**, unconditionally, for every call regardless of whether this specific transition needs it — then the dispatch row | ✅ (this unconditional load-lock is the whole point of the Phase 3A.1 hotfix) |
| `reassign_dispatch_resources()` | `migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql` (STEP 1/STEP 2) | Load **first**, unconditionally, then the dispatch row; driver/truck/trailer are read (not locked) afterward, in that order, then written in the same order in the final `UPDATE`'s column list | ✅ |
| `guard_dispatch_carrier_scope()` (0132) | `migrations/0132_load_carrier_and_trailer_scope.sql` | BEFORE trigger on `dispatches` — by the time it runs, Postgres has **already locked the dispatch row** (a structural constraint of the trigger mechanism, not this trigger's choice); it then locks the load. For a **direct client UPDATE bypassing every RPC above**, this is dispatch-then-load — the reverse order. | ⚠️ **Only reachable via a raw client UPDATE, which no longer exists for board-actions.ts, driver-portal, or the edit form (all now route through the RPCs above, which lock load-first BEFORE ever touching the dispatch row, making this trigger's own internal lock a same-transaction no-op re-lock).** See "Residual risk" below. |
| `guard_dispatch_org()` (0055) | `migrations/0055_reattach_guard_dispatch_org.sql` | BEFORE trigger on `dispatches` — reads (does not lock) `loads`/`carriers`/`trucks`/`drivers`/`trailers` for org/carrier consistency. No lock acquired on `loads`. | ✅ (nothing to conflict with — a plain `SELECT`, not `FOR UPDATE`) |
| `assign_load_financial_dispatch()` (0125, financial-controller assignment) | production 0125 migration | AFTER INSERT trigger on `dispatches` — locks the **load** `FOR UPDATE`, sets `financial_dispatch_id` if still NULL. Fires only after the row is already fully inserted (and, since 0132, after `guard_dispatch_carrier_scope`'s own load lock already ran in the SAME transaction) | ✅ (re-acquiring a lock the same transaction already holds is instant, not a wait) |
| Delivery completion (`updateDispatchBoardStatus` → `delivered`, and the full edit form) | `src/app/(app)/dispatch/board-actions.ts`, `src/app/(app)/dispatch/actions.ts` | Now routes the status write through `transition_dispatch_status()` (load-first) exactly like every other board/edit-form status change; the secondary writes it makes afterward (`driver_tracking_sessions`, exception sync) touch neither `loads` nor `dispatches` | ✅ |
| Driver-portal transitions | `src/app/driver-portal/actions.ts` | Direct `dispatches.update({status, ...})` via the **service-role client** — never calls `transition_dispatch_status()`. Confirmed forward-only (`DISPATCH_STATUS_ORDER`, `targetIdx <= currentIdx` throws) and never touches `carrier_id`/`load_id`/`driver_id`/`truck_id`/`trailer_id` (grep-confirmed). Forward-only status changes are NOT carrier-relevant, so `guard_dispatch_carrier_scope`'s `v_carrier_relevant` is `false` and **no load lock is acquired at all** by this path — nothing to order against. | ✅ (out of scope for the lock-order question entirely — it never takes the load lock) |
| Geofence automation | `src/lib/tracking/evaluate-geofences.ts` | Same as driver-portal: service-role client, status-only writes (`at_pickup`, `en_route_to_delivery`, `at_delivery`), never reactivates, never touches resource columns. Same conclusion. | ✅ |
| Future `reassign_load_carrier()` (Phase 3B, not built) | — | **Must** follow this same standard when it is built: lock the load first, then re-validate every non-cancelled dispatch on it (already-established pattern from `guard_dispatch_carrier_scope`), then mutate, then audit. Documented here so the standard is established *before* that RPC exists, not retrofitted after. | 📋 requirement for Phase 3B |

## Residual risk, disclosed precisely

`guard_dispatch_carrier_scope()`'s own internal lock acquisition happens
**after** Postgres has already locked the row targeted by whatever
INSERT/UPDATE fired it — this is a structural property of BEFORE triggers,
not something the trigger body can reorder. This is *only* a reverse-order
risk when something writes to `dispatches` (in a way that trips
`v_carrier_relevant`: an INSERT, a `carrier_id`/`load_id` change, or
reactivation) **without** having already locked the load first in the same
transaction.

As of this round, every reachable application path that can trip
`v_carrier_relevant` goes through one of the four load-first RPCs above
(`create_dispatch`, `cancel_dispatch`, `transition_dispatch_status`,
`reassign_dispatch_resources`) — confirmed by the repository-wide search in
the Phase 3A.2 report (item 3). The trigger's own internal lock is
therefore, in every currently-reachable case, a no-op re-lock of a row the
same transaction already holds.

**What would reopen this risk**: any FUTURE code that performs a direct
`supabase.from("dispatches").insert(...)` or
`.update({ carrier_id / load_id / status })` outside these four RPCs. There
is no database-level way to force every possible future client call through
an RPC (the column-level REVOKE in 0135 prevents *ordinary authenticated
writes*, but a `service_role` client, or a new RPC written without this
document in hand, could still reintroduce it). This document, plus the
`TEST_DEADLOCK_*` scripts, are the standing guard against that — any new
write path to `dispatches` should be checked against this table before it
ships, and (if it can be carrier-relevant) should lock the load first.

## Verification

- `TEST_DEADLOCK_0132_lock_order.sh` — reproduces the reverse-order deadlock
  when a raw UPDATE reactivates a dispatch (the exact bug this whole
  correction chain closes).
- `TEST_DEADLOCK_0134_no_deadlock_after_hotfix.sh` — proves the identical
  scenario, routed through `transition_dispatch_status()`, no longer
  deadlocks.
- `TEST_CONCURRENCY_0135_resource_reassignment.sh` — proves
  `reassign_dispatch_resources()` vs. `cancel_dispatch()` /
  `transition_dispatch_status()` / itself, under real two-session
  concurrency, never deadlocks.
