# Owner risk acceptance -- waiver of the INDEPENDENT DBA/SECURITY REVIEW GATE ONLY (Proposal 0152)

> **STATUS AS STORED IN THE REPOSITORY: UNSIGNED -- EXPIRED -- NOT VALID.** This template is not a signed acceptance. It has no effect until the Owner completes **every** field of Section 8, signs and dates it, and gives it an expiration date that has not yet passed. Any blank field, any unsigned/undated copy, or any date in the past means the waiver has EXPIRED and the independent-review gate is NOT waived. `production_package/check_risk_acceptance.py` checks a completed copy mechanically.

> **THIS IS NOT INDEPENDENT APPROVAL.** It is not an approval, not a certification, and not evidence that production is safe. It does not authorize any production connection, SQL, migration, deployment or freeze. It records only that the Owner knowingly accepts the added risk of proceeding without an independent review.

## 1. What is recorded
1. An independent, paid PostgreSQL/Supabase DBA and security review of Proposals 0149-0152, the 0130-0147 migration chain, the maintenance freeze and the runbook was **recommended** (`INDEPENDENT_REVIEW_PACKET.md`).
2. It has **not been obtained**, because funds for it are presently unavailable.
3. In its place, the same author performed an internal adversarial review (`ADVERSARIAL_REVIEW.md`). **That review is not independent** (same author, same assumptions) and cannot replace one.
4. Independent review remains the recommended path. If it is obtained later with no open blocker, this waiver is unnecessary.

## 2. Risks the Owner understands and accepts by signing
Proceeding without independent review **increases the risk** of, at least:
* **data corruption or loss** (backfills 0133/0137/0150, repairs, rollbacks that refuse or partially cannot restore);
* **incorrect financial relationships** (a factoring relationship, recipient or carrier assigned to the wrong carrier; a payment or invoice attributed wrongly; a misrouted remittance);
* **privilege exposure** (functions or tables executable/writable by roles that should not have access; roles trusted through `auth.uid() IS NULL`);
* **RLS errors** (policies too permissive or too strict; guards bypassed by service-role or trusted contexts);
* **rollback complications** (a rollback that is refused, incomplete, out of order, or that re-introduces known defects);
* defects that a qualified independent reviewer would likely have found and this author did not.
Also understood: after migration 0140 the legacy factoring-submission RPC rejects every invoice (finding F-08); the documented mitigation is re-issue through the new invoice workflow.

## 3. What this waiver REPLACES -- exactly one gate
It replaces **only** the requirement "independent PostgreSQL/Supabase DBA/security review completed with no open blocker" in `RUNBOOK_PRODUCTION_0130_0152_DRAFT.md` (prerequisites) and `PROMOTION_PLAN.md`.

## 4. What this waiver does NOT waive (all remain mandatory)
Every technical gate, test, backup, verification, conflict-resolution and rollback requirement, including: a verified backup/PITR point; the deployed-commit check; byte-verification of every promoted file against `PROMOTION_MANIFEST.txt`; all local suites and `integrity.py`; the production read-only discovery and its review; **every BLOCKER in `ADVERSARIAL_REVIEW.md` (a BLOCKER can never be waived by this document -- it must be closed with evidence)**; explicit human resolution of every legacy conflict in `LEGACY_CONFLICT_WORKSHEET.md`; the 0150 candidate review with the Owner-approved count and digest; a separate hosted pg_cron test if production has pg_cron or any relevant cron job; the production external probe in the maintenance window (fixture, dry run and proof battery); exact restoration verification; immediate abort on any discrepancy; and every stop/rollback condition in the runbook.

## 5. No authorization
Nothing here authorizes production execution, discovery against production, a freeze, a migration, a deployment, or any credential use. Each of those requires its own explicit, separate Owner authorization at the time.

## 6. Expiry and revalidation
* The waiver expires at the end of the **Expiration date** in Section 8 (the Owner should choose the shortest date that covers the planned window; not more than 30 days after signing is recommended).
* It is invalid if the date is blank/past, if any Section 8 field is blank, or if the scope changes (different production project, commit, migration set, or freeze design version).
* It must be re-checked (with `check_risk_acceptance.py`) at runbook step 2 and again immediately before step 6; a failure at either point is a STOP.
* **It expires before production execution unless it is signed and dated: an unsigned copy is expired by definition.**

## 7. Reviewer / author statement
The author states that this document does not represent the proposal as safe, approved or ready, and that the remaining blockers are listed in `ADVERSARIAL_REVIEW.md` and `RUNBOOK_PRODUCTION_0130_0152_DRAFT.md`.

## 8. Signature block (Owner completes; every field required)
```
OWNER-SIGNATURE:            <signature -- type or sign the full legal name here>
OWNER-PRINTED-NAME:         <printed name>
DATE-SIGNED (YYYY-MM-DD):   <date signed>
EXPIRATION-DATE (YYYY-MM-DD): <date the waiver expires>
SCOPE-PRODUCTION-PROJECT-REF: <20-character production project reference the Owner has personally confirmed>
SCOPE-COMMIT-SHA:           <full git commit sha of the release and promoted migrations>
SCOPE-MIGRATIONS:           0130-0147, 0149, 0150, 0151, 0152
SCOPE-FREEZE-DESIGN:        v2 trigger freeze (freeze/ROOT_CAUSE_AND_REDESIGN.md)
SCOPE-WINDOW-REFERENCE:     <maintenance window / change ticket id>
ACKNOWLEDGES-NOT-INDEPENDENT-APPROVAL: <type YES>
ACKNOWLEDGES-BLOCKERS-NOT-WAIVED:      <type YES>
```
