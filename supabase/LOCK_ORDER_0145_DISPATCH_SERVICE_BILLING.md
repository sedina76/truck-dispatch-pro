# LOCK_ORDER_0145_DISPATCH_SERVICE_BILLING.md

Phase 3B.4 — lock order for the five agreement-lifecycle RPCs
(`create_carrier_dispatch_service_agreement`,
`create_carrier_dispatch_service_agreement_version`,
`approve_carrier_dispatch_service_agreement_version`,
`deactivate_carrier_dispatch_service_agreement_version`,
`deactivate_carrier_dispatch_service_agreement`) and for
`_issue_dispatch_service_invoice_internal()` (the STEP 10 branch
`issue_carrier_invoice()` now calls for `invoice_document_type =
'dispatch_service_invoice'`), proved against 0144's already-corrected
order (`LOCK_ORDER_0144_INVOICE_ISSUANCE.md`) and against each other.

**Phase 3B.4.1 revision.** Adds the carrier-scoped effective-dates
advisory lock (`_carrier_dispatch_service_agreement_effective_dates_
lock_key(organization_id, carrier_id)`) to all six functions above, plus
the `CARRIER_INACTIVE` and `DISPATCH_REMITTANCE_REQUIRED` checks in
`_issue_dispatch_service_invoice_internal()`. This revision **replaces**
the previous version's "one expected 40P01 deadlock in Scenario 1"
section below with the actual fix: that deadlock is now structurally
eliminated, not merely documented as acceptable. See "The Phase 3B.4.1
deadlock fix" below for the full derivation.

## The carrier-scoped effective-dates advisory lock (Phase 3B.4.1)

`_carrier_dispatch_service_agreement_effective_dates_lock_key(p_org,
p_carrier_id)` returns `hashtextextended(p_org::text || '|' ||
p_carrier_id::text || '|carrier_dispatch_service_agreement_effective_
dates', 0)` — a single, canonical key scoped to **(organization_id,
carrier_id)**, deliberately **not** `agreement_id` (Section A: nothing
prevents an organization from creating more than one agreement
container for the same carrier, and the exclusion constraint itself is
scoped to `carrier_id` alone).

Every one of the following acquires this **identical** key via
`pg_advisory_xact_lock(...)`, in the **identical relative position** —
immediately after the pre-existing per-operation
`(organization_id, operation, idempotency_key)` advisory lock, and
**before** any `carrier_dispatch_service_agreement_versions` row
lock/insert/update:

| Caller | How `carrier_id` is obtained for the key |
|---|---|
| `create_carrier_dispatch_service_agreement` | direct parameter (`p_carrier_id`) |
| `create_carrier_dispatch_service_agreement_version` | provisional (unlocked) read of `carrier_dispatch_service_agreements.carrier_id` for `p_agreement_id` |
| `approve_carrier_dispatch_service_agreement_version` | provisional (unlocked) read of `carrier_dispatch_service_agreement_versions.carrier_id` for `p_version_id` |
| `deactivate_carrier_dispatch_service_agreement_version` | provisional (unlocked) read of `carrier_dispatch_service_agreement_versions.carrier_id` for `p_version_id` |
| `deactivate_carrier_dispatch_service_agreement` | provisional (unlocked) read of `carrier_dispatch_service_agreements.carrier_id` for `p_agreement_id` |
| `_issue_dispatch_service_invoice_internal` | direct field (`p_row.carrier_id`) |

The provisional reads are safe because `carrier_id` is immutable on
`carrier_dispatch_service_agreement_versions` once a row exists (no RPC
or guard trigger ever changes it — `guard_carrier_dispatch_service_
agreement_version_lifecycle()` explicitly rejects any attempted change)
and `carrier_dispatch_service_agreements.carrier_id` is likewise never
written by any RPC after `INSERT`.

**This advisory lock is transaction-scoped (`pg_advisory_xact_lock`,
held until COMMIT or ROLLBACK)**, which is the load-bearing property:
at most **one** transaction is ever "inside" the overlap-sensitive
section for a given carrier at a time. A second transaction contending
for the same `(org, carrier)` key blocks on the **advisory lock**
itself — a lightweight, dedicated PostgreSQL wait mechanism entirely
separate from the GiST index's own two-phase exclusion-constraint check
— not on the exclusion constraint. By the time it proceeds, the first
transaction has already fully committed or rolled back, so any
exclusion-constraint check the second transaction eventually performs
only ever needs to compare against **already-committed** rows, which
cannot deadlock (there is no in-flight transaction left to wait on).

## The Phase 3B.4.1 deadlock fix — root cause and exact mechanism

**Root cause (pre-3B.4.1).** Two concurrent transactions each approving
a *different*, mutually-overlapping `carrier_dispatch_service_agreement_
versions` row for the *same* carrier would both reach their own
`UPDATE ... SET status = 'approved'` statement without any prior
serialization. PostgreSQL's GiST exclusion-constraint check, run as
part of each `UPDATE`, must determine whether the row it is
inserting/updating conflicts with any other row currently in the index
— including a row from a **different, concurrently in-flight**
transaction that has not committed yet. To make that determination
safely, the checking transaction must wait for the other's outcome
(commit or abort) before it can decide. If transaction A is checking
against B's uncommitted row while B is simultaneously checking against
A's, that is a genuine AB-BA cycle, and PostgreSQL's own deadlock
detector (correctly) aborts one side with `SQLSTATE 40P01`.

**The fix.** Interpose the carrier-scoped advisory lock, acquired by
*every* writer of this overlap-sensitive state, strictly before either
transaction reaches its own exclusion-constrained `UPDATE`/`INSERT`.
Since the lock is mutually exclusive and held for the whole transaction:

1. Transaction A acquires the lock first (or B does — symmetric).
2. Transaction B, wanting the same `(org, carrier)` key, blocks on the
   *advisory* lock — never reaching its own version-row lock, its own
   application-level overlap re-query, or its own `UPDATE`.
3. A performs its **application-level** overlap re-query (see below),
   then its `UPDATE`s, then commits (releasing the advisory lock) or
   rolls back.
4. Only now does B's advisory-lock wait resolve. B re-queries the
   overlap set **fresh** (A's change, if any, is now fully committed
   and visible) and either proceeds cleanly or gets a clean, structured
   `AGREEMENT_OVERLAP` from the app-level check — never from a deadlock,
   because by the time B's own `UPDATE` runs, there is no concurrently
   in-flight competing transaction left for the exclusion constraint to
   need to wait on.

**Belt-and-suspenders app-level check.** `approve_carrier_dispatch_
service_agreement_version()` additionally performs an explicit
`daterange(...) && daterange(...)` overlap query against every other
currently-`approved` version for the same `carrier_id` (excluding the
version being approved and, if given, the one being superseded)
**while holding the advisory lock**, and returns a clean, structured
`AGREEMENT_OVERLAP` result *before* ever attempting the `UPDATE` — this
means the GiST exclusion constraint (`cdsav_no_overlap_when_approved`)
now functions as a **pure backstop** and should never actually fire
in normal operation; its `exclusion_violation` exception handler is
kept only for defense-in-depth (e.g. a future direct/service-role write
that bypasses this RPC entirely).

**Required result, verified live** (`TEST_CONCURRENCY_0145_dispatch_
service_billing.sh`, Sections A/D/F below): zero deadlocks; exactly one
approval succeeds; the loser returns structured `AGREEMENT_OVERLAP`; no
partial approval; no duplicate audit event; no successful idempotency
record for the loser.

## `CARRIER_INACTIVE` and `DISPATCH_REMITTANCE_REQUIRED` (Phase 3B.4.1, Sections C/G)

Both checks are performed **after locking their respective row**
(`carriers` `FOR UPDATE` at position 5 below; `organizations` `FOR
SHARE` at position 7 below) and **again, defensively, immediately
before snapshot construction** (re-reading the already-locked `carriers`
row — not a new lock, not a new resource; nothing could have changed it
since the FOR UPDATE lock was acquired, given the effective-dates
advisory lock closes the only path that a concurrent carrier mutation
could otherwise race through this same transaction window). Neither
check introduces a new lockable resource — both ride the existing
`carriers`/`organizations` locks already in the order below.

## The dispatch-service issuance order (Phase 3B.4.1: updated)

`issue_carrier_invoice()`'s STEPS 1-9 (advisory lock, `carrier_invoices`
row, idempotency, draft/payment-state checks) are fully shared with the
freight path and unchanged — see `LOCK_ORDER_0144_INVOICE_ISSUANCE.md`
positions 1-2. STEP 10 dispatches to
`_issue_dispatch_service_invoice_internal()`, which then acquires, in
order:

1. **`carrier_invoices`** (already locked at STEP 5, `FOR UPDATE`) — the
   target dispatch-service invoice. Not re-acquired; inherited from the
   caller's own transaction.
2. **`loads`** — every covered load attached via `carrier_invoice_loads`,
   locked one at a time in **ascending `id` order**, `FOR UPDATE` — the
   *identical* resource, at the *identical* relative position (3), that
   0144's freight path already locks. No `load_stops` lock is taken here
   (Section J's snapshot never includes a route) — `guard_load_stops_
   parent_lock()` (0144) never comes into play for this path.
3. **Advisory lock** — `_carrier_dispatch_service_agreement_effective_
   dates_lock_key(p_org, p_row.carrier_id)` (Phase 3B.4.1, new) —
   acquired immediately before the applicable-version lookup, so that
   lookup can never race a concurrent approve/supersede/deactivate for
   the same carrier.
4. **`carrier_dispatch_service_agreement_versions`** — the single
   applicable approved version for `(carrier_id, current_date)`,
   `FOR UPDATE` — a brand-new resource, not locked by any 0130-0144 path.
5. **`carriers`** — the invoice's own carrier, `FOR UPDATE` — the
   *identical* resource, at the *identical* relative position (5), that
   0144's freight path already locks (both paths lock `loads` before
   `carriers`). `CARRIER_MISMATCH` (not found/wrong org) and
   `CARRIER_INACTIVE` (Phase 3B.4.1, new — a distinct code from
   0144's own overloaded `CARRIER_MISMATCH`, for accurate UI behavior)
   are both checked here, under lock.
6. **`carrier_remittance_profiles`** — `FOR SHARE`, immediately after
   `carriers`, matching 0144's own position (9) relative order.
7. **`organizations`** — the dispatch organization's own row (`p_org`),
   `FOR SHARE` — a brand-new resource; read-only identity/remittance
   capture only. `DISPATCH_REMITTANCE_REQUIRED` (Phase 3B.4.1, new) is
   checked here, under lock, before any per-load work or number
   allocation.
8. **Per covered load, ascending `id`** (`percentage_of_freight` only):
   the related, already-issued `carrier_invoices` row (a **different**
   row than the one locked at position 1 — the freight invoice, not the
   dispatch-service invoice being issued), `FOR SHARE`, then its
   `carrier_invoice_issuance_snapshots` row, `FOR SHARE`.
9. **`carrier_dispatch_service_billing_lines`** — one `INSERT` per
   covered load (the `unique(load_id)` constraint is the anti-double-
   billing backstop; a `unique_violation` here returns `LOAD_ALREADY_
   BILLED`, never a raw error).
10. **`carrier_invoice_line_items`** — one `INSERT` per covered load (a
    brand-new row each time — no pre-existing row to lock).
11. A defensive, lock-free **re-read** of `carriers.is_active` (Phase
    3B.4.1, Section C: "revalidate immediately before snapshot
    construction") — not a new lock; the row has been held `FOR UPDATE`
    since position 5.
12. **`carrier_invoice_number_counters`** — via `_generate_carrier_
    invoice_number_internal()`'s own atomic `INSERT ... ON CONFLICT ...
    RETURNING` (unchanged mechanism, same function 0144 already uses for
    freight numbers).
13. **`carrier_invoice_issuance_snapshots`** (`INSERT`) + the
    `carrier_invoices` status/totals transition + `carrier_invoice_
    lifecycle_idempotency` (`INSERT`) — all inside the savepoint-scoped
    APPLY block, mirroring 0144's own established pattern exactly.

Positions 2 and 5 are the *same table, same relative order* as 0144's
freight path (`loads` before `carriers`) — this is deliberate: it means
a freight issuance call and a dispatch-service issuance call for the
*same carrier* can never reverse against each other on these two shared
resources, because both always acquire `loads` then `carriers`, never
the other order. Position 8 locks a *second*, distinct `carrier_
invoices` row (the freight invoice) — never the same row already locked
at position 1 — so this is not a self-conflict, and no other path ever
locks two `carrier_invoices` rows together except this one and (for a
different pair) nothing in 0001-0144. The new advisory lock (position 3)
introduces no *row*-lock reversal risk against anything, by construction
— advisory locks occupy an entirely separate lock space from row/table
locks and are never taken on a table/row this function also locks.

## The five agreement-lifecycle RPCs (Phase 3B.4.1: updated)

Each acquires (a) its own per-operation advisory lock, (b) the new
carrier-scoped effective-dates advisory lock, then (c) its own row
lock(s) — never `loads`, `carrier_invoices`, or any factoring table:

| RPC | Advisory locks (in order) | Row locks (`FOR UPDATE`) |
|---|---|---|
| `create_carrier_dispatch_service_agreement` | per-operation key, then `(org, p_carrier_id)` | `carriers` |
| `create_carrier_dispatch_service_agreement_version` | per-operation key, then `(org, agreement's carrier_id)` | `carrier_dispatch_service_agreements` (serializes `version_number` allocation) |
| `approve_carrier_dispatch_service_agreement_version` | per-operation key, then `(org, version's carrier_id)` | `carrier_dispatch_service_agreement_versions` — the target version, and (only if `p_supersede_version_id` is given) the version being superseded, **in ascending `id` order** regardless of which parameter is which |
| `deactivate_carrier_dispatch_service_agreement_version` | per-operation key, then `(org, version's carrier_id)` | `carrier_dispatch_service_agreement_versions` — the target version only |
| `deactivate_carrier_dispatch_service_agreement` | per-operation key, then `(org, agreement's carrier_id)` | `carrier_dispatch_service_agreements` — the target agreement only |

**Why none of these five can deadlock against anything else, and why
the new advisory lock cannot introduce a reversal.** Two entirely
separate lock spaces are in play, and neither RPC ever acquires them in
different relative orders: every RPC always takes its per-operation
advisory lock **before** the carrier-scoped advisory lock (both are
advisory locks, never contended against each other except by identical
keys, which never collide across different `(org, operation, key)`
tuples in practice), and always takes the carrier-scoped advisory lock
**before** any row lock. A transaction that locks only one *row*
resource (or, for `approve_..._version`, two rows of the *same* table
in a fixed, deterministic order) can never be the "held X, waiting on
Y" side of an AB-BA cycle on the *row*-lock graph — there is no X for it
to hold while waiting on something else. The advisory-lock graph is
equally cycle-free: every caller acquires (per-operation key) then
(carrier-scoped key), in that fixed order, never the reverse, so two
advisory locks can never form a cycle either. The only way any of these
five could still contend is against another call to the *same* function
(or against `_issue_dispatch_service_invoice_internal`, or against
`approve_..._version` itself) for the *same* carrier — ordinary,
single-key advisory-lock contention (whoever locks first proceeds; the
other blocks, then either proceeds or gets a structured rejection such
as `STALE_RECORD`/`AGREEMENT_OVERLAP`/`STALE_AGREEMENT`), never a cycle.

**`create_carrier_dispatch_service_agreement` vs. the issuance paths
(both freight and dispatch-service):** the freight path never acquires
the carrier-scoped advisory lock at all (it has no reason to — it never
touches agreement/version state), so it can only ever contend with
`create_carrier_dispatch_service_agreement` on the `carriers` row lock
itself, ordinary single-resource contention. The dispatch-service path
*does* acquire the carrier-scoped advisory lock (position 3 above) and,
separately, the `carriers` row lock (position 5) — but always in that
same relative order (advisory-then-row), matching every lifecycle RPC's
own order, so no reversal is possible.

**`approve_/deactivate_..._version` vs. dispatch-service issuance
(Phase 3B.4.1 revision):** both now acquire the *identical*
carrier-scoped advisory lock before touching any version row — so the
window in which issuance could observe a version change *between* its
own provisional lookup and its own row lock (the pre-3B.4.1
`STALE_AGREEMENT` race) is now closed: whichever side acquires the
advisory lock first fully completes (commit or rollback) before the
other's provisional lookup even runs. `STALE_AGREEMENT`'s own
revalidation code is kept as defense-in-depth (documented, not
eliminated, below) but this specific race can no longer produce it in
practice — the only two live outcomes are `ISSUED` (issuance's lock
acquired first) or `AGREEMENT_NOT_APPROVED`/`AGREEMENT_NOT_EFFECTIVE`
(the lifecycle operation's lock acquired first, fully committed, and
issuance's own subsequent lookup correctly reflects the new state).

**`deactivate_carrier_dispatch_service_agreement` vs. any version-level
RPC or issuance:** locks only the parent `carrier_dispatch_service_
agreements` row (plus the same carrier-scoped advisory lock, for
consistency) — never a version row directly. No cycle possible for the
same reasoning above. (Deactivating the *agreement* does not, and per
Section E must not, retroactively invalidate an already-issued invoice
— it only prevents *future* issuance from finding an applicable version,
since the lookup in `_issue_dispatch_service_invoice_internal()` joins
through `a.status = 'active'`.)

## Full proof table — every 0130-0144 lock-taking path, re-checked against 0145/3B.4.1's new resources

| Function | Tables/locks taken | Conflicts with the current order? |
|---|---|---|
| `issue_carrier_invoice()` freight path (0144) | `carrier_invoices` → `loads` → `load_stops` → `dispatches` → `factoring_relationships` → `carriers` → `factoring_companies`/NOA doc/integration → `carrier_remittance_profiles` → recipient → line items → number counter → snapshot | No — `loads`→`carriers` relative order matches the dispatch-service path exactly; never acquires the new carrier-scoped advisory lock at all (no reason to), so it can only ever contend with the five lifecycle RPCs on the plain `carriers` row lock, ordinary single-resource contention. |
| `transition_carrier_factoring_integration_lifecycle()` (0141) | `factoring_relationships` → `carriers` → `factoring_companies` → NOA doc → integration | No — never touches any 0145 table/advisory key. |
| `set_carrier_factoring_policy()` (0139) | `carriers` only | No — single resource; also never acquires the carrier-scoped advisory lock. |
| `guard_dispatch_carrier_scope()` / `guard_load_carrier_change()` / `reassign_dispatch_resources()` / `transition_dispatch_status()` (0132/0134/0135) | `loads` → `dispatches` | No — never locks `carrier_dispatch_service_agreement_versions`/`carriers`+`loads` together in reversed order, and never touches the new advisory-lock keyspace. |
| `guard_load_stops_parent_lock()` (0144) | `loads` (the stop's parent row) | No — dispatch-service issuance never locks `load_stops` at all. |
| `guard_carrier_dispatch_service_agreement_version_lifecycle()` (0145) | Fires `BEFORE UPDATE OR DELETE` on `carrier_dispatch_service_agreement_versions` itself — no *additional* lock; the row is already locked by whichever statement fired the trigger, which (for every authenticated path) is always one of the five lifecycle RPCs, all of which already hold the carrier-scoped advisory lock by the time any such `UPDATE`/`DELETE` runs. | No — a pure business-rule guard, introduces no new resource. |
| Every other 0130-0144 RPC (`activate_carrier_party`, `set_default_factoring_relationship`, `approve_factoring_relationship_noa`, `submit_invoice_to_factor`, etc.) | Various, none touching `carrier_dispatch_service_*` or `organizations` | No — re-confirmed by direct source re-read; none acquires any lock (row or advisory) that 0145/3B.4.1 introduces. |

**Conclusion.** Phase 3B.4.1 introduces exactly one genuinely new
lock-space (the carrier-scoped advisory-lock keyspace), acquired by
exactly six functions (the five lifecycle RPCs plus dispatch-service
issuance), always in the same fixed relative position (after the
per-operation advisory lock, before any version-row lock), and never
combined with any row lock in a way that could reverse against another
path's own order. No 0001-0144 path, and no other 0145 path, ever
touches this advisory-lock keyspace at all — so it cannot introduce a
cross-cutting deadlock with anything outside the six functions listed
above, and within those six, the fixed relative order (per-operation →
carrier-scoped → row locks) is itself cycle-free by construction. Every
genuinely concurrent pair is proved live in `TEST_CONCURRENCY_0145_
dispatch_service_billing.sh`, including the Section F stress runs (20
two-session + 10 three-session overlapping-approval races, non-
overlapping/different-carrier/different-organization control cases,
and approval-vs-supersession/deactivation/issuance pairings) — all
verified to produce **zero** Postgres-detected deadlocks.

## Residual assumptions (documented, not eliminated)

- **The five agreement-lifecycle RPCs never lock `loads`, `carrier_
  invoices`, or any factoring table.** True as of 0145/3B.4.1,
  re-verified by direct source re-read of all five function bodies. If
  a future migration ever makes one of them also lock one of those
  tables, this proof must be redone.
- **`_issue_dispatch_service_invoice_internal()`'s agreement-version
  lookup is per-invoice, not per-load.** A single applicable version is
  resolved once per issuance call and applied uniformly to every
  covered load in that invoice (Section F's documented simplification) —
  this means the version lock (position 4) and the carrier-scoped
  advisory lock (position 3) are each acquired exactly once per call,
  never once per load, and are not candidates for a self-deadlock across
  the loop.
- **`organizations` is now locked `FOR SHARE` for the first time in this
  schema's history.** No 0001-0144 path ever locks it at all. Two
  concurrent dispatch-service issuance calls for *different* carriers
  under the *same* organization both take this same `FOR SHARE` lock —
  compatible with each other (shared locks never conflict with other
  shared locks), so this introduces no contention against a concurrent
  `DISPATCH_REMITTANCE_REQUIRED`-relevant `UPDATE` of `organizations.
  remittance_instructions` beyond ordinary shared/exclusive lock
  semantics (Scenario 12's own concurrency proof covers this directly).
- **The freight invoice locked at position 8 is read-only (`FOR
  SHARE`).** Nothing in the dispatch-service path ever escalates this to
  `FOR UPDATE` or writes to it — Section A/I's legal-separation
  requirement (a dispatch-service invoice must never alter a carrier
  freight invoice) is enforced not just by omission of any `UPDATE`
  statement targeting it, but structurally: the freight invoice's own
  `carrier_invoices` row and its snapshot are only ever `SELECT`ed here.
- **`STALE_AGREEMENT`'s revalidation code path is kept, though the
  specific race that used to reach it (deactivate-vs-issuance,
  Scenario 3) is now closed by the carrier-scoped advisory lock** (see
  above). It remains reachable in principle only by a hypothetical
  future path that mutates a version row *without* acquiring the
  carrier-scoped advisory lock first — none exists today. Kept as
  defense-in-depth, not dead code removed, consistent with this
  codebase's own established convention for structurally-hard-to-reach
  branches (e.g. 0144's `source_dispatch_id` re-validation).
- **`FREIGHT_INVOICE_CARRIER_MISMATCH`** remains structurally
  unreachable given 0142's own immutability guarantee (an issued
  freight invoice's `carrier_id` can never change, by any role) —
  unaffected by this revision, documented previously and unchanged.
