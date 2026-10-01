# Proposal 0150 -- normalise zero-evidence legacy `unresolved` loads (Blocker A)

**NOT APPROVED FOR PRODUCTION. NOT APPLIED. Not in `supabase/migrations/`.** Untracked, prepared for review only.
It also holds the **Blocker F1 verification** (`f1_cancel_verify.sql`); F1 itself needs **no migration** (app change only).

## Numbering
`0130..0147` -> `0149` (enum repair, unchanged) -> **`0150`** (this). The unrelated current proposal `supabase/proposals/0148/`
is untouched and untracked and **must be renumbered to `0152` or higher before promotion** (0149, 0150 and 0151 are ahead of it). Do not renumber it yet.
Proposal `0151` (transition replay authorization) follows this one.

## The problem
0133 marks every legacy load with no dispatch `carrier_resolution='unresolved'` (rule `C4_zero_dispatch`, reason
"No dispatch on this load; a responsible carrier cannot be determined.") and opens an exception record. The 0132 guard then rejects any
new dispatch on an `unresolved` load ("no exceptions"), so those loads can never be dispatched (LD-100035 is expected to be one).

## The fix (and what it deliberately does not do)
For each **candidate** load only: `loads.carrier_resolution 'unresolved' -> NULL` (`carrier_id` stays NULL). That is exactly the state the
*unchanged* 0132 guard already handles: the **first non-cancelled dispatch atomically claims the load for its own carrier**, under the load row
lock, with carrier/org/resource authorization done by `create_dispatch` + the guard. The migration also archives the matching exception
record (`archived_legacy`, factual note, `resolved_by` NULL because no person resolved it) and writes full provenance.
It never chooses a carrier, never touches a load with any dispatch (cancelled included), never modifies any function/trigger (0132 guards
are fingerprint-checked before and after) and never touches a non-candidate row.

## Candidate rules (every one, evaluated under row locks; single source: `build.py`)
1. `carrier_resolution = 'unresolved'`; `carrier_id`, `carrier_locked_at`, `financial_dispatch_id` all NULL.
2. **Zero dispatches of any status.** (A load with a cancelled dispatch is outside the pool and untouched.)
3. **Zero rows in every carrier/financial evidence table** pointing at the load: `invoices`, `dispatch_advances`, `settlement_line_items`,
   `driver_settlement_items`, `expenses`, `compliance_overrides`, `dispatch_resource_reassignments`, and the required 0142/0144/0145 tables
   `carrier_invoice_loads`, `carrier_invoice_line_items.source_load_id`, `carrier_dispatch_service_billing_lines`.
   (A table that was never deployed contributes zero rows; the three required ones must exist.)
4. **Exactly one** exception record for the load, and it is the exact open 0133 record: same organization, `record_type='load'`,
   status `unresolved`, the exact 0133 reason text, `detail = {"rule":"C4_zero_dispatch","dispatches":[]}`, no resolver/time/note.
5. Exactly one matching 0133 provenance row (`carrier_id` NULL, `unresolved`, same organization, pointing at that exception record).
6. The organization exists (and the exception/provenance organization equals the load's).

**Fail closed.** A zero-dispatch `unresolved` load that fails any of 2-6 (contradictory evidence) **aborts the whole migration** -- nothing is skipped
silently. The candidate count **and** digest must equal `v_expected_count` / `v_expected_digest` (both REQUIRED; NULL, a placeholder, or a wrong value -> abort in Phase 1, nothing changed). As shipped the file contains no count and no digest and **fails closed**; it cannot run until the real `candidate_review.sql` result (after 0133) has been reviewed and pasted in. Verified facts:
`unresolved_carrier_records.resolved_by` is nullable (FK, `on delete set null`); status enum = `unresolved | manually_resolved | archived_legacy`.

## Files
| file | purpose |
|---|---|
| `proposed_0150.sql` | the migration (one `begin;..commit;`: preconditions+locks+plan -> mutation -> postconditions) |
| `preflight.sql` | read-only gate (single SELECT): 0133/0147/0149 state, guard fingerprints, pool/candidate/contradiction counts |
| `candidate_review.sql` | read-only owner report: every zero-dispatch unresolved load (number, organization, status, exception id, evidence, CANDIDATE/BLOCKED); prints the count + digest |
| `post_apply.sql` | read-only verifier; valid any time after apply (a load may be pending or already claimed by its first dispatch) |
| `rollback.sql` | emergency exact reversal, refuses if anything moved |
| `build.py` | generates the five SQL files from one shared analysis fragment (`--check` detects staleness) |
| `legacy_seed.sql`, `regression.sql`, `tests.py`, `f1_cancel_verify.sql` | disposable-cluster harness (reuses the reviewed 0149 cluster harness) |

## Owner procedure (production, after 0130..0147 and 0149, inside the maintenance window)
1. `preflight.sql` -> must PASS (if it fails, read the report; do not continue).
2. `candidate_review.sql` -> review every CANDIDATE load (number, organization). BLOCKED must be 0. Note the count and digest.
3. In `proposed_0150.sql` replace the two `null` literals (`v_expected_count` = the approved count; `v_expected_digest` = the printed 32-hex digest; both required) and run it once in the SQL Editor.
4. `post_apply.sql` -> must PASS. Then dispatch LD-100035 as a smoke test (its carrier is claimed by the dispatch).

## Rollback limits (`rollback.sql`)
* Acts only off `carrier_backfill_0150_provenance`; **refuses (changing nothing)** unless every normalised load is still NULL/NULL with no dispatch and its
  exception record is still as 0150 closed it, and no newer open exception exists. **Once any normalised load has been claimed by a dispatch the whole
  rollback refuses** -- a claimed load must never be re-blocked. Use the `DISPATCH_WRITES_DISABLED=1` kill switch instead.
* Restores `carrier_resolution` and the exception status/`resolved_*`/note exactly; `updated_at` is trigger-maintained and not restorable.
* `ROLLBACK_0133` refuses while any 0133 provenance load has changed, so **0150 must be rolled back first** (in reverse order).
* Nothing restores the 0132 dispatch block after a claim; that is intended.

## Sequencing with the F1 app change
F1 (Cancel via `transition_dispatch_status`) is app-only and independent of 0150. Both must be live before dispatchers use the system after 0135:
DB 0130..0147 (one by one, verifier each) -> 0149 -> 0150 (+ post_apply) -> deploy the app (kill switch on during the window) -> smoke tests.

## Test evidence (`python3 supabase/proposals/0150/tests.py`, disposable cluster only)
Real 0130..0147 chain + 0149 on a scratch PostgreSQL; legacy loads classified by the REAL 0133 (C1, C2, C3, C4-conflicting, pre-existing,
other-organization, zero-dispatch). Covers: BLOCKER A reproduced; F1 (11 conditions); preflight/review/post-apply; 31 fail-closed scenarios
(each evidence table, exception tampering, provenance drift, carrier/lock/controller set, wrong/missing/placeholder count and digest, altered guard, disabled trigger,
0149 missing) each proving *nothing changed*; historical-cancelled-dispatch load untouched; real two-session lock behaviour (migration waits and
re-evaluates after the lock); candidate-only mutation (row-level, only `carrier_resolution` changes); catalog + `pg_dump` add-only delta; functional
regression (first-dispatch claim by the selected authorized carrier, later different-carrier rejection, cross-org rejection, wrong-carrier/unresolved
trailer atomic rejection, untouched loads stay blocked); real two-session competing first dispatch; rollback refusal variants; apply -> rollback ->
exact restoration (catalog, dump, rows) -> reapply identical.

## Known limits of the evidence
* Scratch PostgreSQL 18.3 with a faithful *support* schema (not the full production schema); production is PostgreSQL 17.6. The scratch function owner is a
  superuser (production: `postgres`, non-superuser with BYPASSRLS); no touched table uses FORCE RLS (asserted in the F1 script).
* Evidence tables that do not exist in the scratch schema are simulated by stand-in tables; the rule reads them by name/column only.
* Production-only triggers on `loads` (e.g. auto-invoice) are listed by `preflight.sql` (INFO) but not modelled beyond the ones in the support schema.
* Production candidate count/list is unknown until `candidate_review.sql` runs after 0133; the harness population (22) is synthetic.
