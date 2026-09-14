# LOCK_ORDER_0146_CARRIER_INVOICE_PAYMENTS.md

## Deployment sequence

Production rollout must use this order:

1. Put the carrier-invoice feature in maintenance, fail-closed mode.
2. Run `VERIFY_0146_PREFLIGHT.sql` and stop if any check fails or any issuance snapshot exists.
3. Apply migrations in numeric order through 0146.
4. Run `VERIFY_0146_POST_APPLY.sql` and stop if any check fails.
5. Deploy application code compatible with snapshot schema version 2 only after the database verification passes.
6. Keep 0144/0145-era issuance disabled from the start of preflight until 0146 application and verification finish.

This sequence is documentation only. No production or Supabase action is part of the migration or its test procedure.

Phase 3B.5 — lock order for `record_carrier_invoice_payment()` and
`void_carrier_invoice_payment()`, proved against 0144's freight-issuance
order, 0145's dispatch-service-issuance and agreement-lifecycle order
(`LOCK_ORDER_0144_INVOICE_ISSUANCE.md`, `LOCK_ORDER_0145_DISPATCH_
SERVICE_BILLING.md`), and against each other.

## Required primary order (Section K)

1. **Advisory lock** — `pg_advisory_xact_lock(hash(organization_id,
   operation, idempotency_key))`.
2. **`carrier_invoices`** — the target invoice row, `FOR UPDATE`.
3. **`carrier_invoice_payments`** — the payment row(s) involved, `FOR
   UPDATE`.
4. **Rollup/update** — the `carrier_invoices.amount_paid`/`payment_status`
   `UPDATE`.
5. **Audit/idempotency completion** — `log_activity()` + `carrier_
   invoice_lifecycle_idempotency` `INSERT`, both inside the savepoint-
   scoped APPLY block.

Both RPCs follow this exact order; neither ever locks a payment row
before its own invoice row.

## `record_carrier_invoice_payment()` — full order

1. Advisory lock (per-operation key).
2. **`carrier_invoices`** — `FOR UPDATE`, by `p_invoice_id` directly (no
   provisional lookup needed — the invoice id is the RPC's own first
   parameter).
3. **`carrier_invoice_issuance_snapshots`** — `FOR SHARE`, only for
   `carrier_freight_invoice` (to read the immutable `factoring` block) —
   matches 0145's own "lock even an already-immutable row before reading
   it into a new decision" convention.
4. **`carrier_invoice_payments`** — every EXISTING `posted` row for this
   invoice, locked one at a time in **ascending `id` order**, `FOR
   UPDATE` — belt-and-suspenders on top of the invoice row lock (which
   alone already fully serializes concurrent calls against the SAME
   invoice, matching 0144's own STEP 16 line-item-locking precedent:
   "explicit locking on top of a parent lock that already serializes
   it").
5. **`carrier_invoice_payments`** (`INSERT`) — the new payment row.
6. **`carrier_invoices`** (`UPDATE`) — the rollup.
7. **`carrier_invoice_lifecycle_idempotency`** (`INSERT`).

## `void_carrier_invoice_payment()` — full order

1. Advisory lock (per-operation key).
2. A **provisional (unlocked) read** of `carrier_invoice_payments.
   carrier_invoice_id` for `p_payment_id` — needed to know which invoice
   to lock first, since the RPC's own parameter is a payment id, not an
   invoice id. `carrier_invoice_id` is immutable on this table (PHASE 5's
   own guard trigger rejects any change to it), so this provisional read
   is stable and safe to use for lock-ordering purposes, exactly matching
   0145's own provisional-`carrier_id` pattern (Phase 3B.4.1, Section A).
3. **`carrier_invoices`** — `FOR UPDATE`, by the provisionally-read
   `carrier_invoice_id` — **locked BEFORE the payment row**, satisfying
   the required primary order.
4. **`carrier_invoice_payments`** — the TARGET payment row, `FOR UPDATE`,
   by `p_payment_id` (re-validating `organization_id` under lock).
5. **`carrier_invoice_payments`** — every OTHER `posted` row for the same
   invoice, ascending `id`, `FOR UPDATE` (for the rollup recompute) —
   same belt-and-suspenders reasoning as `record_carrier_invoice_
   payment()`'s own step 4.
6. **`carrier_invoice_payments`** (`UPDATE`) — the target row's own
   status/void fields.
7. **`carrier_invoices`** (`UPDATE`) — the rollup.
8. **`carrier_invoice_lifecycle_idempotency`** (`INSERT`).

**Why the provisional-read approach cannot reverse the order.** The
provisional read (step 2) takes no lock at all — it is a plain `SELECT`
with no `FOR UPDATE`/`FOR SHARE`. The first REAL lock either function
acquires (after the advisory lock) is always `carrier_invoices`, never
`carrier_invoice_payments`. No path in this migration, or in 0144/0145,
ever acquires these two tables' locks in the reverse order.

## Proof: no path locks a payment row before its invoice row

Both RPCs above are the ONLY functions in this schema that ever lock
`carrier_invoice_payments` at all (it is a brand-new table, 0146). By
direct construction, both acquire `carrier_invoices` strictly first.
There is therefore no possible AB-BA cycle between these two resources
— the only way two calls could ever contend is on the identical
`carrier_invoices` row (ordinary single-resource contention, resolved
by whichever call's `FOR UPDATE` is granted first) or the identical
`carrier_invoice_payments` row (same reasoning, one level deeper).

## Interaction with freight/dispatch-service issuance (0144/0145)

`issue_carrier_invoice()` (both the freight path and the dispatch-
service-internal path) locks `carrier_invoices` at its own STEP 5/
position 1, then never touches `carrier_invoice_payments` at all (it
did not exist before this migration, and issuance never references it).
`record_/void_carrier_invoice_payment()` likewise never lock anything
issuance locks EXCEPT `carrier_invoices` itself (the identical row,
identical resource) and, for `record_carrier_invoice_payment()` only,
`carrier_invoice_issuance_snapshots` `FOR SHARE` — the SAME resource,
SAME lock mode, issuance itself uses when reading a *different*
invoice's snapshot (0145's own freight-invoice-lookup, position 8) or
never locks at all for its own freight path (0144 never re-reads its
own just-created snapshot). No reversal is possible: the only shared
resource between "issuance in flight" and "payment in flight" is the
`carrier_invoices` row itself, and whichever call locks it first fully
completes (commit or rollback) before the other proceeds — ordinary,
cycle-free single-resource serialization. `TEST_CONCURRENCY_0146`
Scenario 11 proves this live (payment vs. issuance, both orderings).

## Interaction with 0145's agreement-lifecycle carrier-scoped advisory lock

`record_/void_carrier_invoice_payment()` never acquire the Phase 3B.4.1
carrier-scoped effective-dates advisory lock (`_carrier_dispatch_
service_agreement_effective_dates_lock_key`) at all — payments have no
relationship to agreement effective-date ranges. No shared advisory-lock
keyspace exists between this migration and 0145's own, so no
interaction, no cycle, nothing to prove here beyond "these two advisory
keyspaces are structurally disjoint by construction" (different hash
input strings: `'...|carrier_dispatch_service_agreement_effective_
dates'` for 0145 vs. `'|record_carrier_invoice_payment|...'`/`'|void_
carrier_invoice_payment|...'` operation strings for 0146 — collision is
astronomically unlikely and is this codebase's own already-accepted
property of the shared `hashtextextended` advisory-lock keyspace, not a
new risk).

## Legacy payment paths (0006/0009/0026/0027)

`apply_payment_to_invoice()` (0009, hardened 0026) is a trigger on
`public.payments`, firing `AFTER INSERT OR UPDATE OR DELETE`, locking
only its own row (the trigger's own `NEW`/`OLD`) plus `public.invoices`
via `guard_payment_amount()`'s own `SELECT ... FOR UPDATE`. Neither
`public.payments` nor `public.invoices` is ever locked by this
migration's own two RPCs (Section A/B: deliberately isolated, different
tables entirely) — zero shared resources, zero possible interaction.

## Residual assumptions (documented, not eliminated)

- **`carrier_invoice_issuance_snapshots` is locked `FOR SHARE` by
  `record_carrier_invoice_payment()`, never `FOR UPDATE`.** Nothing in
  this migration ever writes to it — Section G/H's "the issuance
  snapshot is never changed by payment activity" requirement is enforced
  structurally (no `UPDATE`/`INSERT`/`DELETE` statement targets it at
  all in either RPC), not merely by omission of a stronger lock mode.
- **`void_carrier_invoice_payment()`'s provisional read is the only
  place in this migration where a lock-ordering decision depends on an
  unlocked value.** `carrier_invoice_id` is immutable (guard-trigger-
  enforced) the instant a payment row exists, so this is safe by the
  same reasoning 0145's own Phase 3B.4.1 revision already established
  and proved live for its own provisional `carrier_id` reads.
- **Two concurrent payments against the SAME invoice can never both pass
  the overpayment check**, because both must acquire the identical
  `carrier_invoices` `FOR UPDATE` lock first — whichever wins computes
  the TRUE remaining balance from the just-locked, freshly-summed
  `carrier_invoice_payments` set (never trusting `carrier_invoices.
  amount_paid` alone, self-healing by construction) before the other can
  even begin its own check. `TEST_CONCURRENCY_0146` Scenarios 1/2/7
  prove this live.

## Phase 3B.5.2 addendum — canonical version-2 issuance introduces zero new locks

`issue_carrier_invoice()`/`_issue_dispatch_service_invoice_internal()`
are replaced IN PLACE by this migration (Section C) to emit
`schema_version=2` — but every lock acquisition, and its ORDER, is
byte-for-byte unchanged from the installed 0145 bodies (verified by the
direct function-source diff performed during this phase's own
verification: the only textual difference between the 0145-original and
0146-replaced bodies is the snapshot-construction block itself, never a
`SELECT ... FOR UPDATE`/`FOR SHARE`/`pg_advisory_xact_lock` call). The
canonical-shape correction is a pure output-format change applied AFTER
every lock in both functions' own lock order has already been acquired
and every guarded check has already passed — it cannot introduce a new
deadlock class, and `TEST_CONCURRENCY_0144`/`TEST_CONCURRENCY_0145`
(re-run in full against the replaced functions) confirm zero regression
(zero deadlocks, identical scenario outcomes to the pre-3B.5.2 baseline).
