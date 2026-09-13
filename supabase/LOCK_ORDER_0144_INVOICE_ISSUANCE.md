# LOCK_ORDER_0144_INVOICE_ISSUANCE.md

Phase 3B.3C.1 — corrected, trigger-inclusive lock order for
`issue_carrier_invoice()`, proved against every other lock-taking code
path this schema has as of migration 0144. Revision history: the first
draft of 0144 locked `carriers` **before** `factoring_relationships` —
the exact reverse of `activate_carrier_factoring_integration()` (0141).
This revision corrects that reversal and re-derives the full order from
scratch, including two-session proof for every scenario in Section D of
the corresponding task.

**Phase 3B.3C.2 revision**: inserts two new positions, 3b (`load_stops`)
and 3c (`dispatches`), between `loads` (position 3) and
`factoring_relationships` (position 4) — see "The `load_stops` and
`dispatches` sub-orders (Phase 3B.3C.2, Sections C/D)" below for the full
derivation and proof this introduces no new deadlock cycle. No other
position changed.

## The corrected global order `issue_carrier_invoice()` follows

1. **Advisory lock**: `pg_advisory_xact_lock(hash(organization_id, 'issue_carrier_invoice', idempotency_key))`.
2. **`carrier_invoices`** — the target invoice row, `FOR UPDATE`.
3. **`loads`** — every source load attached via `carrier_invoice_loads`, locked one at a time in **ascending `id` order**, `FOR UPDATE`.
3b. **`load_stops`** — every stop row of every attached load, locked one at a time in **ascending `(load_id, stop_sequence, id)` order**, `FOR UPDATE`. A `BEFORE INSERT OR UPDATE OR DELETE` trigger on `load_stops` itself, `guard_load_stops_parent_lock()`, forces every stop-mutation path (including a brand-new `INSERT`) to first lock that stop's own parent `loads` row — the same lock this RPC already holds from position 3 — before proceeding, so a concurrent stop write can never interleave with this position; it either fully precedes or fully follows this transaction. Only after every stop is locked does `issue_carrier_invoice()` reject a missing pickup/delivery, a duplicate `stop_sequence`, or an inverted route (Phase 3B.3C.2, Section C).
3c. **`dispatches`** — every DISTINCT non-null `source_dispatch_id` referenced by the invoice's own (not-yet-locked) line items, locked one at a time in **ascending `id` order**, `FOR SHARE`. Re-validated under lock: `load_id = ANY(` the locked loads `)` and `carrier_id =` the invoice's own carrier (Phase 3B.3C.2, Section D).
4. **`factoring_relationships`** — the carrier's current default+active relationship, if one exists. **Provisionally discovered** via an unlocked read *before* this lock (see "Provisional discovery" below), then locked `FOR UPDATE`.
5. **`carriers`** — the invoice's own carrier, `FOR UPDATE`.
6. **`factoring_companies`** — `FOR SHARE` (read-only for this RPC).
7. **`documents`** (the NOA document, if `noa_document_id` is set) — `FOR SHARE`.
8. **`carrier_factoring_integrations`** (only if `submission_method='api'`) — `FOR SHARE`.
9. **`carrier_remittance_profiles`** — `FOR SHARE`.
10. **Recipient** — `brokers` OR `customers`, then `carrier_brokers` OR `carrier_customers` (matching), both `FOR UPDATE`.
11. **`carrier_invoice_line_items`** — every line item of the matching `line_type`, locked one at a time in **ascending `id` order**, `FOR UPDATE`.
12. **`carrier_invoice_number_counters`** — touched only via `_generate_carrier_invoice_number_internal()`'s own single `INSERT ... ON CONFLICT ... RETURNING` (atomic by construction, no separate lock needed).
13. **`carrier_invoice_issuance_snapshots`** (`INSERT`) + the `carrier_invoices` status transition(s) — both inside the savepoint-scoped APPLY block.

Steps 4/6/7/8 are skipped entirely for a `direct` or `unconfigured`
carrier (nothing to lock); step 6/7/8 only fire once the carrier is
confirmed `factored` under lock at step 5. Step 3c is a structural no-op
against every current fixture (no existing INSERT path populates
`source_dispatch_id` yet — see Section D below) but is always executed
so the association is provably protected once a future migration starts
populating it.

## Why positions 4–5 changed, and why the new order is correct

`transition_carrier_factoring_integration_lifecycle()` (0141 — the
function behind `activate_/deactivate_/verify_/fail_/revoke_/
rotate_carrier_factoring_integration`), for its `'ready'` (activation)
transition, locks in this exact sequence (migration 0141, lines
628–660):

```
perform 1 from public.factoring_relationships where id = v_relationship_id for update;
...
select c.* into v_carrier from public.carriers c
  join public.factoring_relationships r on r.carrier_id = c.id
  where r.id = v_relationship_id
  for update of c;
select fc.is_active into v_company_active from public.factoring_companies fc ...  for share of fc;
select d.* into v_doc from public.documents d ...  for share of d;
...
select * into v_integration from public.carrier_factoring_integrations where id = p_integration_id ... for update;
```

i.e. **factoring_relationships → carriers → factoring_companies (share)
→ NOA document (share) → the integration row**. The first draft of 0144
locked `carriers` at what is now position 5, but *before* any
`factoring_relationships` lock — the reverse pairing. Two transactions
acquiring `{carriers, factoring_relationships}` in opposite order for the
same carrier/relationship is a textbook AB-BA deadlock: issuance holding
`carriers` and waiting on the relationship, while an activation call
holds the relationship and waits on `carriers`.

**Correction**: 0144 now locks `factoring_relationships` before
`carriers`, exactly matching 0141's order (positions 4–8 above map onto
0141's sequence one-for-one). See Scenario 19 in
`TEST_CONCURRENCY_0144_atomic_invoice_issuance.sh` for the genuine
two-session, `pg_locks`-observed proof this no longer deadlocks.

### Provisional discovery (positions 3→4)

The invoice row alone does not reveal which relationship to lock until
the carrier's policy is known — and locking `carriers` first to find out
would reproduce the exact reversal being fixed. `issue_carrier_invoice()`
therefore:

1. Reads (unlocked) the carrier's current default+active relationship,
   if any — **regardless of the carrier's current `factoring_mode`**
   (`set_carrier_factoring_policy()` never clears `is_default`/
   `is_active` on a relationship when a carrier reverts to `direct`, so a
   stale-but-still-flagged relationship can exist even for a currently-
   `direct` carrier — checking unconditionally is what lets a concurrent
   `direct→factored` transition still be locked in the correct order in
   the common case, with no refuse-and-retry round trip).
2. Locks that relationship (if found) `FOR UPDATE` — *before* locking
   `carriers`.
3. Locks `carriers` `FOR UPDATE`.
4. Re-validates the locked carrier's `factoring_mode` against what was
   provisionally assumed:
   - `direct`/`unconfigured` under lock: any provisionally-locked
     relationship is simply unused — no data from it is ever read into
     the snapshot. Safe by construction, no refusal needed (Section F:
     a concurrent `factored→direct` transition during a factored
     issuance attempt always resolves cleanly as a direct-billing
     issuance).
   - `factored` under lock, but nothing was provisionally locked: a
     second (unlocked) existence check distinguishes "never configured"
     (→ `FACTORING_NOT_READY`, permanent, retrying will not help) from "a
     relationship was created/defaulted after the provisional read" (→
     `STALE_CONFIGURATION`, transient, a retry will now discover and
     lock the correct row).
   - `factored` under lock, and something was provisionally locked, but
     it is no longer the carrier's current default+active relationship:
     `STALE_CONFIGURATION` — a genuine identity change, always a race,
     never a permanent gap.

This is the general pattern for "an early read is needed to discover a
later lock key": treat it as provisional, acquire locks in the global
order, re-read and revalidate every value under lock, and return a
structured stale/not-ready result on any mismatch — never a wrong-order
lock, never stale data in the snapshot.

## Full proof table — every other lock-taking function's own footprint

| Function | Tables locked (`FOR UPDATE`/`FOR SHARE` or equivalent) | Relative order | Conflicts with 0144's corrected order? |
|---|---|---|---|
| `update_carrier_invoice_draft()` (0143) | `carrier_invoices` only | n/a (single table) | No — same single resource as step 2. |
| `guard_carrier_invoice_line_item_mutability()` (0144-hardened) | `carrier_invoices` only (its own internal lock, fired by a direct write to `carrier_invoice_line_items`) | n/a (single table) | No — same resource as step 2. |
| `guard_carrier_invoice_load_mutability()` (0144-hardened) | `carrier_invoices` only | n/a (single table) | No — same reasoning. |
| `set_carrier_factoring_policy()` (0139) | `carriers` only | n/a (single table) | No — never combined with `factoring_relationships`/`carrier_factoring_integrations`/`loads` in the same transaction, so it can never be the "other side" of a 4-vs-5 cycle. |
| `set_default_factoring_relationship()` (0138) | `factoring_relationships` only (row-locked; plus two ADVISORY locks — `factoring_company:{id}` then `factoring_default_relationship:carrier:{id}` — a disjoint keyspace from step 1's `hashtextextended`-derived key) | n/a (one row-locked table) | No — never combined with `carriers`/`carrier_factoring_integrations`/`loads` in the same transaction. |
| `approve_factoring_relationship_noa()` (0140) | `factoring_relationships` only | n/a (single table) | No — same reasoning. |
| **`transition_carrier_factoring_integration_lifecycle()`** (0141: `activate_/deactivate_/verify_/fail_/revoke_/rotate_carrier_factoring_integration`) | `factoring_relationships` → `carriers` (share... `for update of c`) → `factoring_companies` (share) → NOA document (share) → `carrier_factoring_integrations` | `factoring_relationships` → `carriers` → `factoring_companies` → NOA doc → integration | **This is the pairing that was reversed — now fixed.** 0144's corrected steps 4→5→6→7→8 match this exactly. |
| `guard_dispatch_carrier_scope()` (0132) | `loads` only (`FOR UPDATE`, single row), plus an unlocked read of `trailers` | n/a | No — never locks `carriers`/`factoring_*` in the same transaction (verified by direct re-read of the 0132 source, Phase 3B.3C.1). |
| `guard_load_carrier_change()` (0132) | `loads` (implicit, via the `UPDATE`/`INSERT` statement itself); unlocked reads of `carriers`/`dispatches` | n/a | No — no explicit `FOR UPDATE` on `carriers` at all. |
| `reassign_dispatch_resources()` (0135) | `loads` → `dispatches`, both `FOR UPDATE` | `loads` → `dispatches` | No — never touches `carriers`/`factoring_*`. |
| `transition_dispatch_status()` (0134) | `loads` → `dispatches`, both `FOR UPDATE` | `loads` → `dispatches` | No — same reasoning. |
| `activate_carrier_party()` (0131) | No explicit row lock at all (plain `SELECT`s + an upsert into `carrier_brokers`/`carrier_customers`, whose own target row is implicitly locked by the `INSERT ... ON CONFLICT`) | n/a | No — never locks `carriers`/`factoring_*`/`loads` together with anything else. |
| `submit_invoice_to_factor()` (0140) | none (unconditionally fail-closed, reads only) | n/a | No — takes no lock at all. |
| **`guard_load_stops_parent_lock()`** (Phase 3B.3C.2, new) | `loads` only (the stop's own parent row, `FOR UPDATE`) — fires on every `load_stops` `INSERT`/`UPDATE`/`DELETE`, from any caller | n/a (single table) | No — never combined with `carriers`/`factoring_*` in the same transaction; its only lock (`loads`) is the exact same resource, at the exact same relative position, `issue_carrier_invoice()` already locks at position 3. |

**Conclusion**: `issue_carrier_invoice()` is the only transaction that
ever holds locks on `factoring_relationships` AND `carriers` AND
`factoring_companies`/NOA-document/`carrier_factoring_integrations`
together — and it now acquires them in **exactly** the order 0141's own
activation path already established. Two concurrent issuance calls for
the same carrier also serialize without deadlock, since both acquire the
same fixed sequence.

### The `loads` and line-item sub-orders (steps 3 and 11)

`issue_carrier_invoice()` is the only place in this schema that ever
locks more than one `loads` row, or more than one
`carrier_invoice_line_items` row, inside a single transaction. Both are
locked in **ascending `id` order** — a loop of single-row `FOR UPDATE`
selects, never a bulk `... ORDER BY ... FOR UPDATE` (which does not
guarantee lock-acquisition order). This is the schema's own established
convention for any FUTURE code path that ever needs to lock more than one
row of either table together.

### Source-load lock compatibility (Section C)

Every path capable of changing `loads.carrier_id`, dispatch carrier/
controller identity, load stops, rate, load number, or pickup/delivery
dates was re-inspected directly (not merely grepped) for Phase 3B.3C.1:
`guard_dispatch_carrier_scope()`, `guard_load_carrier_change()`,
`reassign_dispatch_resources()`, `transition_dispatch_status()`. None of
them ever locks `carriers`/`factoring_relationships`/
`factoring_companies`/`carrier_factoring_integrations` in the same
transaction as a `loads`/`dispatches` lock. This means: (a) locking
`loads` at position 3 — before the carrier/factoring block — introduces
no new deadlock cycle against any of these; and (b) the reverse ordering
concern the task raises ("issuance must not take carrier/factoring locks
and then wait for a load row if another operation can hold the load row
and then wait for carrier or factoring state") does not apply today,
because no such "another operation" exists. `TEST_CONCURRENCY_0144`
Scenario 13 / Section-C race still proves this live, with a genuine
two-session `loads.carrier_id` reassignment racing issuance, rather than
resting on source inspection alone.

### The `load_stops` and `dispatches` sub-orders (Phase 3B.3C.2, Sections C/D)

**The gap.** The immutable snapshot's origin/destination/pickup-date/
delivery-date fields are derived from `load_stops`, but the pre-3B.3C.2
version of `issue_carrier_invoice()` never locked `load_stops` at all —
a concurrent stop edit, reorder, insert, or delete could race the
snapshot build unobserved. Locking the *existing* stop rows alone is
insufficient for one specific failure mode: a row lock cannot lock the
**absence** of a row, so nothing would stop a brand-new stop `INSERT`
from landing on a locked load's stop set mid-issuance and going
completely unnoticed by a lock taken only on the rows that existed at
the time the lock was acquired.

**The fix — a lock-ordering trigger, not a business rule.**
`guard_load_stops_parent_lock()` is a `BEFORE INSERT OR UPDATE OR DELETE`
trigger installed directly on `load_stops` (previously it had **no**
guard trigger at all anywhere in 0001–0144 — only generic RLS-based
owner/admin/dispatcher CRUD via the `standard_tables` policy-generation
loop in `0010_rls_policies.sql`).

**Phase 3B.3C.3 revision (Sections A and C).** The original version
locked `coalesce(new.load_id, old.load_id)` for *every* operation:

```sql
perform 1 from public.loads where id = coalesce(new.load_id, old.load_id) for update;
```

Two real defects were found and fixed against this single line:

- **Section A**: for an UPDATE that changes `load_id` (a cross-load stop
  move), `coalesce` resolves to `NEW.load_id` only — `OLD.load_id`'s own
  parent is never locked at all, leaving the *source* load's stop set
  unprotected. Fixed by rejecting a cross-load `load_id` UPDATE outright
  (`55000`) — no application code, RPC, or test in this codebase ever
  performs one (move a stop between loads via delete+insert instead).
- **Section C**: for UPDATE (same `load_id`) and DELETE on an *existing*
  row, PostgreSQL always locks that row's own tuple (implicitly, as part
  of the statement's own row-fetch) **before** any `BEFORE ROW` trigger
  runs — a trigger cannot see or reorder this. So this trigger's own
  additional `loads` lock, taken *after* that implicit row lock, made the
  session's acquisition order `load_stops-row → loads-row` — the *exact
  reverse* of `issue_carrier_invoice()`'s own `loads → load_stops` order
  (STEP 11 → STEP 11a). Two sessions acquiring the same two resources in
  opposite order is a textbook AB-BA deadlock, and it is genuinely
  reachable (not hypothetical) — confirmed live and reproducibly once the
  race was deterministically forced (see Section C below); ordinary
  wall-clock racing in Phase 3B.3C.2 never happened to trigger it, which
  is exactly why forcing both orderings matters.

**The corrected rule:**

```sql
if tg_op = 'INSERT' then
  perform 1 from public.loads where id = new.load_id for update;
  return new;
elsif tg_op = 'DELETE' then
  return old;                          -- no additional lock (see below)
else -- UPDATE
  if new.load_id is distinct from old.load_id then
    raise exception '...' using errcode = '55000';
  end if;
  return new;                          -- no additional lock (see below)
end if;
```

Only **INSERT** still explicitly locks `loads` — the sole case where
doing so is both *necessary* (closing the "a row lock can't lock a row's
absence" gap for a brand-new stop — nothing else exists yet for anything
to implicitly lock) and *safe* (no pre-existing tuple lock for it to
reverse against — a new row's INSERT and the trigger's `loads` lock are
the *only* two things happening, in the *same* relative order
`issue_carrier_invoice()` uses). For **DELETE** and **same-`load_id`
UPDATE**, the row's own already-held implicit lock is, by itself, fully
sufficient serialization against `issue_carrier_invoice()`'s own STEP
11a explicit `FOR UPDATE` on that identical row — a single shared
resource, one acquisition order, no cycle possible, deadlock-free by
construction. Adding a *second*, different-resource lock (`loads`) for
these two operations bought no additional safety and was the entire
source of the AB-BA cycle.

This is the *same* lock, at the *same* relative position in the global
order (position 3, immediately before 3b), that `issue_carrier_invoice()`
already takes on that row for INSERT's case. The trigger has **zero
knowledge of invoices, issuance, or any business rule** — it is a pure
serialization device. Because both the RPC and every stop-INSERT path
now compete for the identical lock resource before doing anything else,
and both the RPC and every stop-UPDATE(same-load)/DELETE path now
compete for the identical *row* lock, one of exactly two interleavings
is possible for any concurrent stop write against a load an issuance
call is targeting:

- the stop mutation's lock (parent, for INSERT; the row itself, for
  UPDATE/DELETE) is granted first → it commits (or rolls back) in full
  *before* issuance's own corresponding lock is granted, so issuance's
  later read deterministically sees the fully-committed post-change
  state; or
- issuance's lock is granted first → the stop mutation blocks until
  issuance's transaction ends, so issuance's read deterministically sees
  the complete pre-change state, and the stop mutation lands cleanly
  only afterward.

No third interleaving exists — a torn/partial read of `load_stops` (part
old, part new) is structurally impossible, because both sides serialize
on one lock before either can observe or change any row. This is proved
live, not just by source inspection, by `TEST_CONCURRENCY_0144`
Scenarios 20A/20B (UPDATE), 21A/21B (INSERT), 22A/22B (DELETE), 23A/23B
(sequence reorder), and 25A/25B (multi-stop shipment vs. a nonterminal-
stop edit) — each run under **both** deterministically forced orderings
(Phase 3B.3C.3, Section C: a manual lock holder plus genuine
`pg_stat_activity.wait_event_type='Lock'` polling, never wall-clock
guessing), with a third-party `pg_locks`/`pg_blocking_pids()` observer,
verifying both legitimate outcomes above, zero deadlocks in either
ordering, and that the snapshot's origin/destination is always one
complete version, never a hybrid. (20A/22A/23A are precisely the forced
interleaving that reproduced the AB-BA deadlock before this correction.)

**A related, independent PostgreSQL behavior worth documenting**: a
multi-statement transaction that updates the *same* `load_stops` row
more than once (e.g. a naive 3-step sequence swap cycling through a
temporary out-of-range value) can cause PostgreSQL's own foreign-key
enforcement (`load_stops_load_id_fkey`) to *additionally* take a
`FOR KEY SHARE` lock on the referenced `loads` row — independent of, and
not controllable by, this migration's own trigger. This is not a defect
in `issue_carrier_invoice()` or in `guard_load_stops_parent_lock()`; it
is inherent PostgreSQL FK-constraint-trigger behavior, empirically
confirmed not to fire for a single-statement update (including one that
touches multiple rows via a single `CASE`-based `UPDATE`, which is also
the natural way any real reorder workflow would be written) or for an
update that touches a given row only once per transaction. No
application code path in this codebase ever updates the same
`load_stops` row twice within one transaction (see
`LOAD_STOPS_MUTATION_AUDIT_0144.md`), so this is a documented edge case,
not a live risk — `TEST_CONCURRENCY_0144`'s own scenario 23 was
corrected to use the single-statement `CASE` form specifically to avoid
exercising this Postgres-internal behavior in a test whose intent is to
prove `issue_carrier_invoice()`'s own locking, not PostgreSQL's FK
subsystem.

**Why position 3b (right after `loads`, before `factoring_relationships`)
and not later.** `guard_load_stops_parent_lock()`'s own lock (on
`loads`) is already fully subsumed by whatever `loads` locks
`issue_carrier_invoice()` is holding by position 3 — it introduces no
NEW table into the global order, only a new set of `load_stops` row
locks that no other existing code path ever takes together with
`carriers`/`factoring_relationships`/`factoring_companies`/
`carrier_factoring_integrations` (there being no other RPC or trigger
that locks `load_stops` and any of those tables in the same
transaction as of 0001–0144). Placing it immediately after `loads`
mirrors the existing precedent of locking every attached load's own
sub-resources (line items, at position 11) in one contiguous block
relative to their parent, and keeps the "reject before any factoring
work is done" ordering Section C requires (a load with a malformed
route is rejected via `INVOICE_INCOMPLETE`/`SOURCE_LOAD_CONFLICT` before
any factoring/remittance/recipient lock is ever taken).

**Section D — `dispatches`.** Unlike `load_stops`, no new trigger is
needed for `dispatches`: `source_dispatch_id` only needs its *existing*
row re-validated (never an absent row protected), so an ordinary
`FOR SHARE` row lock at position 3c is sufficient — a concurrent
`UPDATE` to that same dispatch row requires an exclusive row lock, which
directly conflicts with issuance's `FOR SHARE` lock, so the two
genuinely serialize without any trigger at all. `TEST_CONCURRENCY_0144`
Scenario 24 proves this live: reassigning a dispatch's `load_id` away
from the invoice's attached loads either blocks until issuance completes
(dispatch is `ISSUED` against the original, still-matching association)
or lands first and is then correctly caught as `SOURCE_LOAD_CONFLICT`
under lock — never a torn read of the dispatch's own load/carrier
identity. `source_dispatch_id` is, as of 0001–0144, always `NULL` in
practice (added as a forward-looking nullable column in Phase 3B.3C;
no existing `INSERT` path populates it) — no *mutable* dispatch field
(`status`/`driver_id`/`truck_id`/`trailer_id`/financials) is ever read
into the snapshot, so there is no mutable dispatch DATA that can go
stale. What position 3c protects is narrower: that the association
itself (which load/carrier a referenced dispatch belongs to) cannot
silently change, unnoticed, between line-item creation and issuance.

**Deadlock-cycle check for 3b/3c.** Since 3b/3c introduce no table this
RPC did not already reach (via `loads`) or that no other code path locks
together with `carriers`/`factoring_*` (via `dispatches`, re-confirmed:
`guard_dispatch_carrier_scope()`/`reassign_dispatch_resources()`/
`transition_dispatch_status()` lock only `loads`→`dispatches`, never
`carriers`/`factoring_*` in the same transaction — see the proof table
below, unchanged from Phase 3B.3C.1), no new 2-resource or N-resource
cycle is possible. The only new resource genuinely introduced is
`load_stops` itself, and `guard_load_stops_parent_lock()` guarantees
every path that ever touches it also locks `loads` FIRST, in the same
relative position this RPC already uses — so two transactions can only
ever contend on `load_stops` after both have already agreed on `loads`
ordering, which this schema already serializes safely (ascending `id`,
single-row locks, position 3).

## Residual assumptions (documented, not eliminated)

- **Dispatch/load RPCs never combine with carrier/factoring locks.** True
  as of 0141–0144, re-verified directly for this revision. If a future
  migration ever makes a load/dispatch mutation also lock `carriers` or a
  factoring table, this proof must be redone.
- **Advisory-lock keyspace sharing.** `hashtextextended(...)` (0142/0143/
  0144's own convention) and `hashtext(...)` (0138/0139/0140's
  convention) both ultimately call the single-`bigint` form of
  `pg_advisory_xact_lock`, sharing one global keyspace. A collision
  between an unrelated `hashtext(...)` value and this RPC's own
  `hashtextextended(...)` value is astronomically unlikely and is an
  already-accepted property of this codebase, not a new risk 0144
  introduces.
- **`carrier_remittance_profiles`** now genuinely locked (`FOR SHARE`) —
  the residual gap noted in the pre-correction version of this document
  is closed. `TEST_CONCURRENCY_0144` Scenario 26 is the live two-session
  proof of this existing lock (Phase 3B.3C.2, Section F) — no code
  change, an empirical confirmation.
- **`load_stops` has exactly one guard trigger (`guard_load_stops_parent_
  lock()`), and it is a pure lock-ordering device.** If a future
  migration ever adds a SECOND trigger on `load_stops` (a real business
  rule, not just lock-ordering), that trigger must be checked against
  this same proof — it inherits the position-3b lock ordering for free
  (the parent-lock trigger fires first, `BEFORE` triggers run in
  alphabetical-by-name order and `a0144_...` sorts before anything
  starting later in the alphabet) but must not itself acquire any lock
  outside the established order.
- **`dispatches`' `source_dispatch_id` protection is currently a
  structural no-op in production.** No existing `carrier_invoice_line_
  items` `INSERT` path (this RPC does not create line items; they are
  created via direct RLS grant, per 0142) ever populates
  `source_dispatch_id`. Position 3c's lock/re-validate loop is dead code
  against every current fixture and is exercised in tests only via a
  direct, trusted-context `UPDATE` (matching this suite's own established
  fixture technique, e.g. `TEST_0144`'s E8 test) — it becomes load-
  bearing the moment a future migration starts populating this column
  from a real application path, and this document's proof already covers
  that future state.
