# Backfill report — 0133_deterministic_carrier_backfill

Fill in the blanks below using `VERIFY_0133_PREFLIGHT.sql` (before / plan
preview) and `VERIFY_0133_POST_APPLY.sql` (after). This is the only migration
in Phase 3A that writes `loads.carrier_id`. It never guesses: an ambiguous
load is recorded `unresolved` with an exception row, not assigned a carrier.

**No maintenance window is required before this migration.** If any load
already has a non-NULL `carrier_id` at apply time (assigned by anything
other than 0133 between 0132 and now), 0133 validates it (same-org, agrees
with `financial_dispatch_id`, agrees with every non-cancelled dispatch) and
preserves it byte-for-byte — it is NOT overwritten, and it is deliberately
EXCLUDED from the rollback provenance table, so `ROLLBACK_0133` can never
touch it. `VERIFY_0133_PREFLIGHT.sql` checks 11–12 validate any such
pre-existing assignment before you apply; report the count here:

| Metric | Count |
|---|---|
| Loads with a pre-existing `carrier_id` before this run (preserved, untouched) | ____ |

## MANDATORY GATE: controller-conflict check (VERIFY_0133_PREFLIGHT check 13)

**0133 refuses to apply at all — zero writes anywhere in the database — while
any load's `financial_dispatch_id` is contradicted by a currently
non-cancelled dispatch of a different carrier** (Phase 3A clarification
round, item 2: financial_dispatch_id is never trusted over a live,
disagreeing dispatch — and never silently recorded as `unresolved` while
staying populated, which would leave an internally contradictory row
standing). This is **not** a plan-preview row like the ones below; it is a
hard precondition, checked and reported BEFORE you ever attempt to apply.

1. Run `VERIFY_0133_PREFLIGHT.sql`. If check 13 shows `ok = f`, the query
   immediately below it lists the exact conflicting `load_id`(s), each
   dispatch's carrier, and the contradicting carrier(s).
2. Report the count and load list here:

   | load_id | load_number | financial_dispatch_id | controller carrier | contradicting live carrier(s) |
   |---|---|---|---|---|
   | | | | | |

3. Correct EACH one manually and explicitly (e.g. cancel the dispatch that
   should never have been created, or correct `financial_dispatch_id`) — 0133
   performs NO automatic clearing of `financial_dispatch_id` and NO automatic
   cancellation of any dispatch. Record what was done and by whom:

   | load_id | correction taken | corrected by | date |
   |---|---|---|---|
   | | | | |

4. Rerun `VERIFY_0133_PREFLIGHT.sql`. Only proceed to apply 0133 once check
   13 shows `ok = t` for every load.

- [ ] VERIFY_0133_PREFLIGHT check 13 = `ok = t` (zero controller conflicts) —
      confirmed immediately before apply.

## Plan preview (from VERIFY_0133_PREFLIGHT.sql)

The rows below are what 0133 will actually WRITE — this assumes the gate
above already passed (a non-zero controller-conflict count is never a
"plan," it is a migration that will not run at all).

| Rule | Resolution | Loads |
|---|---|---|
| C1_financial_controller | resolved | ____ |
| C2_sole_noncancelled_carrier | backfilled | ____ |
| C3_sole_cancelled_carrier | backfilled | ____ |
| C4_zero_dispatch | unresolved | ____ |
| C4_conflicting_carriers | unresolved | ____ |
| **Total** | | ____ |

## After apply (from VERIFY_0133_POST_APPLY.sql)

| carrier_resolution | Loads |
|---|---|
| resolved | ____ |
| backfilled | ____ |
| unresolved | ____ |

- [ ] `resolved + backfilled + unresolved` = total load count (every load was
      classified — no NULLs left).
- [ ] `resolved + backfilled` loads all have `carrier_id` pointing at a
      carrier in the same organization (VERIFY check 11).
- [ ] `unresolved` count = number of OPEN `unresolved_carrier_records` rows
      with `record_type = 'load'` (VERIFY checks 8–10).

## Unresolved worklist (from the VERIFY_0133_POST_APPLY.sql tail query)

Every row here is a load with **no proven carrier**. `loads.carrier_id`
stays NULL and all downstream financial automation for it (freight invoice
issuance, factoring, dispatch-service invoicing — added in later slices) is
blocked until it is manually resolved.

| load_id | load_number | org | reason | rule | resolved by | resolution | date |
|---|---|---|---|---|---|---|---|
| | | | | | | (manually_resolved / archived_legacy) | |

Resolving a row means: an authorized user determines the true carrier from
outside evidence (rate confirmation, signed BOL, broker record, etc.), and
either (a) a later slice's controlled assignment path sets
`loads.carrier_id` and the exception `status` becomes `manually_resolved`, or
(b) the load is deliberately parked as `archived_legacy` with a note — never
silently written off. **Do not guess.**

## Sign-off

- Preflight + plan preview reviewed by: __________  Date: __________
- Migration applied by: __________  Date: __________
- Post-apply verified by: __________  Date: __________
- Unresolved-worklist owner assigned: __________  Date: __________
