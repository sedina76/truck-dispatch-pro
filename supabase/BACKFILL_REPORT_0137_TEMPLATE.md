# Backfill report — 0137_deterministic_factoring_carrier_backfill

Fill in the blanks below using `VERIFY_0137_PREFLIGHT.sql` (before / plan
preview) and `VERIFY_0137_POST_APPLY.sql` (after). This is the only data
migration in Phase 3B.1 — it writes `factoring_relationships.carrier_id`
(brand new, added NULL for every row by 0136) and never guesses: an
ambiguous relationship is recorded `unresolved` with an exception row, not
assigned a carrier.

## MANDATORY GATE: structural-conflict check (VERIFY_0137_PREFLIGHT check 6)

**0137 refuses to apply at all — zero writes anywhere in the database —
while any single `factored_invoices` row's own invoice resolves to
DIFFERENT carriers via its dispatch vs. its load** (should be structurally
impossible given `guard_dispatch_carrier_scope`, 0132 — reported and
aborted, never guessed past).

1. Run `VERIFY_0137_PREFLIGHT.sql`. If check 6 shows `ok = f`, list the
   exact conflicting rows here:

   | factored_invoice_id | invoice_id | dispatch carrier | load carrier |
   |---|---|---|---|
   | | | | |

2. Correct each one manually and explicitly. 0137 performs no automatic
   correction.
3. Rerun `VERIFY_0137_PREFLIGHT.sql`. Only proceed once check 6 = `ok = t`.

- [ ] VERIFY_0137_PREFLIGHT check 6 = `ok = t` (zero structural conflicts) —
      confirmed immediately before apply.
- [ ] VERIFY_0137_PREFLIGHT check 7 = `ok = t` (zero orgs with more than one
      active+default relationship — 0071's own invariant, defensively
      re-checked) — confirmed immediately before apply.

## Plan preview (from VERIFY_0137_PREFLIGHT.sql's bottom query)

| Predicted resolution | Relationships |
|---|---|
| single_carrier_org | ____ |
| multi_carrier_org_provable | ____ |
| unresolved_no_evidence | ____ |
| unresolved_multiple | ____ |
| **Total** | ____ |

## After apply (from VERIFY_0137_POST_APPLY.sql)

| resolution | Relationships |
|---|---|
| single_carrier_org | ____ |
| multi_carrier_org_provable | ____ |
| unresolved_no_evidence | ____ |
| unresolved_multiple | ____ |

- [ ] Sum of all four = total `factoring_relationships` row count (every
      row was classified — VERIFY check 2).
- [ ] Every resolved row's carrier belongs to the same organization (VERIFY
      check 4).
- [ ] Every unresolved row has a matching OPEN `unresolved_carrier_records`
      row (VERIFY check 5).

## Informational context (never blocks backfill — from VERIFY_0137_PREFLIGHT's PHASE 0 notice)

| Metric | Count |
|---|---|
| Expired relationships (`effective_to < today`) at apply time | ____ |
| Relationships under an inactive factoring company at apply time | ____ |

These are **not** backfill blockers — they inform what 0138's classifier
(`classify_carrier_factoring_readiness()`) will report once carrier_id is
populated (`default_expired`, `factoring_company_inactive`).

## Unresolved worklist (from the unresolved_carrier_records rows this run created)

Every row here is a factoring relationship with **no proven carrier**.
`carrier_id` stays NULL and it can never become a carrier's default (0138's
carrier-scoped unique index requires `carrier_id is not null`).

| relationship_id | organization | org_carrier_count | evidence_carrier_ids | reason | resolved by | resolution | date |
|---|---|---|---|---|---|---|---|
| | | | | | | (manually_resolved / archived_legacy) | |

Resolving a row means: an authorized user determines the true carrier from
outside evidence (which carrier's loads this factor was actually used for),
and either (a) a future controlled assignment path sets `carrier_id`
directly (owner/admin only, subject to the same org/company consistency
guard), or (b) the relationship is deliberately parked as `archived_legacy`
with a note. **Do not guess.**

## Sign-off

- Preflight + plan preview reviewed by: __________  Date: __________
- Migration applied by: __________  Date: __________
- Post-apply verified by: __________  Date: __________
- Unresolved-worklist owner assigned: __________  Date: __________
