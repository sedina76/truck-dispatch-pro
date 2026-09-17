# Lock order — migration 0147 mutation RPCs

This documents the full, trigger-inclusive lock order for every new or
touched mutation path in migration 0147, so a future migration extending
this schema can avoid introducing a lock-order inversion (the classic
deadlock precondition: two transactions that acquire the same two locks
in opposite order).

## `create_carrier_invoice_draft(...)`

1. `pg_advisory_xact_lock(hashtextextended(org || '|create_carrier_invoice_draft|' || idempotency_key, 0))`
   — acquired first, before any row is touched. Serializes concurrent
   calls sharing the same `(organization_id, idempotency_key)` pair.
2. `select ... from carrier_invoice_draft_create_idempotency where
   organization_id = ... and idempotency_key = ...` — plain read, no lock
   beyond the implicit share lock of a normal `SELECT` (no `FOR UPDATE`;
   the advisory lock above already serializes writers to this key).
3. `select ... from carrier_ids_selectable_for_new_records()` — read-only,
   no lock.
4. `select ... from brokers/customers where id = ... and organization_id =
   ...` — read-only, no lock.
5. `insert into carrier_invoices (...)` — acquires a new row (no
   contention possible; the row does not exist yet). Fires
   `a0142_guard_org_consistency` (`BEFORE INSERT`), which itself only
   performs read-only `SELECT`s against `carriers`/`brokers`/`customers`
   (no additional row locks).
6. `insert into activity_logs` (via `log_activity()`) — new row, no
   contention.
7. `insert into carrier_invoice_draft_create_idempotency` — new row, no
   contention (the advisory lock from step 1 already prevents a
   concurrent second insert for the same key).

No `FOR UPDATE` row lock is ever taken by this RPC — it only ever inserts
new rows, so there is nothing to lock against a concurrent creator except
the advisory lock (step 1), which is acquired first and released only at
transaction end (`pg_advisory_xact_lock`, not `pg_advisory_lock`).

## `delete_carrier_invoice_draft(...)`

1. `pg_advisory_xact_lock(hashtextextended(org || '|delete_carrier_invoice_draft|' || idempotency_key, 0))`
   — acquired first, exactly the same pattern as create.
2. `select ... from carrier_invoice_draft_delete_idempotency where
   organization_id = ... and idempotency_key = ...` — read-only.
3. `select ... from carrier_invoices where id = ... for update` — row lock
   on the target invoice, acquired **after** the advisory lock and
   **before** any other table's row lock. This is the same "advisory lock
   before row lock" ordering `update_carrier_invoice_draft` (0143) and
   `review_legacy_invoice_carrier_migration` (0142) already established.
4. `delete from carrier_invoices where id = ...` — fires
   `a0142_guard_delete` (`BEFORE DELETE`, read-only check against `OLD`,
   no additional lock) and cascades (`ON DELETE CASCADE`) to
   `carrier_invoice_line_items` and `carrier_invoice_loads` for that
   `invoice_id`, each row-locked and removed by Postgres's own FK
   machinery in the same statement, before this statement returns.
5. `insert into activity_logs` — new row.
6. `insert into carrier_invoice_draft_delete_idempotency` — new row.

**Lock order relative to `update_carrier_invoice_draft` / `issue_carrier_invoice`**:
all three acquire the operation-scoped advisory lock first, then the
target invoice row (`FOR UPDATE`), in that same order — no inversion is
possible between any pair of these RPCs. A `delete_carrier_invoice_draft`
call and an `update_carrier_invoice_draft`/`issue_carrier_invoice` call
racing on the *same* invoice serialize on the row lock in step 3/its
equivalent; whichever acquires it first proceeds, the other observes a
stale `updated_at` (or, for delete, `NOT_FOUND` if the row is already
gone) once it acquires the lock second. This is exactly what
`TEST_CONCURRENCY_0147_production_readiness.sh` scenarios 4 and 6 prove
directly.

**Lock order relative to line-item mutation**: a client inserting a line
item does **not** lock the parent `carrier_invoices` row at all (only
`a0142_guard_line_item_mutability`, `BEFORE INSERT`, reads the parent
row's `issuance_status` via a plain `SELECT`, no lock). `delete_carrier_
invoice_draft`'s `FOR UPDATE` on the parent does not conflict with that
read. The only interaction is the `ON DELETE CASCADE` FK: if the delete
commits first, a line-item insert racing it either completes before the
cascade (and is then removed by it) or fails outright once the parent row
is gone (foreign key violation) — never a torn or orphaned line item
either way (`TEST_CONCURRENCY_0147_production_readiness.sh` scenario 5).

## `scan_legacy_invoices_for_carrier_migration()`

No advisory lock (this RPC has no idempotency key — it is intentionally
re-runnable, each call fully re-deriving every classification). No
explicit row lock either: each iteration's `INSERT ... ON CONFLICT
(legacy_invoice_id) DO UPDATE` on `legacy_invoice_carrier_migration_review`
takes Postgres's own implicit per-row lock for the duration of that one
statement, released immediately after. Two concurrent scans over the same
organization interleave freely; `ON CONFLICT DO UPDATE` guarantees the
last writer's classification wins with no error and no duplicate row (the
table's own `legacy_invoice_id` unique constraint, from 0142, is the
serialization point — not an application-level lock).

## `review_legacy_invoice_carrier_migration(...)`

Unchanged by 0147 (only its EXECUTE grant was touched). For completeness:
`select ... from legacy_invoice_carrier_migration_review where id = ...
for update` (row lock, taken *before* the organization/staleness checks,
0142's own established ordering) — no advisory lock (idempotency is
scoped by `(organization_id, idempotency_key)` on a UNIQUE index alone,
sufficient here because there is no separate "does the target exist yet"
race the way `create_carrier_invoice_draft` has).

**Lock order relative to `scan_legacy_invoices_for_carrier_migration`**: a
scan's `INSERT ... ON CONFLICT DO UPDATE` and a review's `SELECT ... FOR
UPDATE` on the *same* review row can race; Postgres serializes them at the
row level automatically (whichever statement arrives second at the lock
manager simply waits, then proceeds against the post-first-writer state).
No advisory lock is needed or used here, and no lock-order inversion is
possible since neither path takes more than one row lock at a time
(`TEST_CONCURRENCY_0147_production_readiness.sh` scenario 11).

## Summary table

| RPC | Advisory lock key | Row lock(s), in order |
|---|---|---|
| `create_carrier_invoice_draft` | `org\|create_carrier_invoice_draft\|key` | none (INSERT-only) |
| `delete_carrier_invoice_draft` | `org\|delete_carrier_invoice_draft\|key` | `carrier_invoices` (`FOR UPDATE`) |
| `update_carrier_invoice_draft` (0143, unchanged) | `org\|update_carrier_invoice_draft\|key` | `carrier_invoices` (`FOR UPDATE`) |
| `issue_carrier_invoice` (0144/0145, unchanged) | `org\|issue_carrier_invoice\|key` | `carrier_invoices` (`FOR UPDATE`), then load/dispatch rows in a fixed, pre-existing order (see 0144's own header) |
| `review_legacy_invoice_carrier_migration` (0142, unchanged) | none | `legacy_invoice_carrier_migration_review` (`FOR UPDATE`) |
| `scan_legacy_invoices_for_carrier_migration` (0147-corrected body, same lock shape) | none | per-row, implicit, one at a time (`ON CONFLICT DO UPDATE`) |

Every RPC that takes an advisory lock takes **at most one** row lock
afterward, and always the same table (`carrier_invoices`) in the same
role (target of the operation). No RPC in this set ever acquires two
different tables' row locks in an order that could invert against another
RPC in this set — this is why `TEST_CONCURRENCY_0147_production_readiness.sh`
records zero Postgres-detected deadlocks across all twelve scenarios.
