# Proposed 0148 local schema-stage model — NOT APPROVED FOR PRODUCTION

Implementation is ready for static review only. Expanded tests have NOT run.
Nothing here is a discovered production migration or a deployment command.

## Scope and evidence boundary

This model reproduces the reported missing carrier column, missing 0137 provenance,
missing classifier and carrier index, retained org index, 23 seven-privilege anon
grants, and two policies using the exact owner/admin expressions from 0140.
Financial shapes: 38 invoices (6 draft, 21 sent, 1 viewed, 2 partially_paid, 6 paid,
2 void); 17 payments (15 posted, 2 voided); 6 factoring records (3 pending,
1 rejected, 2 partially_settled); 3 invoice and 3 load recipient conflicts.
All identifiers and rows are generated synthetic data.

**It is not an exact production clone.** The audit did not capture full live
policy definitions, columns, ACLs, triggers, functions, types or dependencies.
0071 already defines both delete-policy names, so names alone do not establish
out-of-order 0140 execution. The owner/admin policy bodies are a modeled assumption.
The org-scoped default RPC comes from 0072, not evidence of partial 0138.

Non-factoring tables and auth helpers are intentionally simplified. Carrier-party
and unresolved-record tables are dependency scaffolding, not full 0130–0135
reconstruction. The integration-provider enum is a two-label synthetic model.
Additional sequence/generated-column/ACL witnesses test catalog comparison;
they are not claimed production objects. Migration history is modeled absent.
A sanitized, independently approved live manifest remains mandatory before any
production design can be finalized. No production collection is authorized here.

## Files and stages

- `fixture.sql`: deterministic pre-state, repository-derived 0071 factoring tables,
  guards and 0072 functions; modeled 0140 delete policies; synthetic financial rows.
- `harness.sql`: private test instrumentation, catalog/row capture, exact gates,
  local-identity checks and deterministic table locks.
- `preflight.sql`: read-only comparison against the reference pre-state.
- `proposed_0148.sql` + `schema_stage.sql`: one atomic, locked schema transaction.
  The runner substitutes one fixed marker using SHA-256-pinned text, not psql includes.
- `post_apply.sql`, `functional.sql`, `aggregate.sql`, `preview.sql`: read-only
  target, privilege, classifier, invariant, aggregate and ownership-preview checks.
- `rollback.sql` + `reverse_stage.sql`: gated model-only reversal in one transaction.
- `backfill.sql` and `backfill-approval.json`: deliberately disabled future stage.
- `tests.py`: hardened disposable cluster runner, reference/model databases,
  named checks, SHA-256 source pins and private evidence artifacts.
- `REVIEW.md`: operation inventory, isolation, destructive targets and review limits.

The schema stage revokes seven anon privileges on precisely the 23 tables, restores
0136 columns/types/constraints/guards, and installs the 0138 classifier and partial
carrier index. No existing column values are updated. No carrier backfill runs.
Full policy tuples must already match the reference: reconciliation is a verified
no-op. Unknown/legacy/different policies refuse; there is no name-only replacement.

**The org index is retained.** NULL active defaults are not covered by the carrier
index. Removing the org index now would weaken the invariant. This package does
not replace the legacy default-setting RPC, claim full 0138 completion, or implement
0139–0147. Final cutover must follow approved actual ownership backfill and verified
coverage, with separate RPC/privilege changes reviewed together.

## Verification design (not executed)

The runner creates `td0148_reference` and `td0148_model` in one new local cluster.
Reference target DDL uses the same reviewed schema fragment as the candidate;
comparison tests transaction/gate/rollback correctness, not an independent proof
that the target specification itself is correct. Functional assertions add semantic
checks for 161 anon privileges, classifier permissions/result, NULL ownership,
carrier-mode defaults and both valid unique indexes.

Normalized catalog capture covers schemas/owners/ACLs; relations/RLS flags;
columns/types/defaults/generated expressions/column ACLs; constraint definitions
and validation; indexes/predicates/validity; function definitions/owners/ACLs,
volatility/security/search_path; triggers; complete policies; sequence metadata;
default ACLs; roles/memberships; extension and event-trigger inventory.
Original-column and full-row SHA-256 hashes cover every modeled table, including
financial rows, recipients, carrier values and any unexpected history tables.
Absent migration history is part of the expected schema boundary.

ACL ordering, object OIDs, physical storage, dropped-column slots and MVCC metadata
are normalized away. Hashes prove logical row-value equality only, not physical
heap bytes. Harness schema is excluded and is trusted instrumentation. This is not
a universal PostgreSQL catalog serializer or a production authorization boundary.

Planned checks: exact preflight; 11 adversarial shape/data refusals; injected
post-DDL/revoke failure; successful apply; exact target and preserved originals;
read-only functional/aggregate/preview checks; unsafe rerun; rollback refusal after
ownership drift; exact normalized rollback; reapply; simultaneous apply attempts
with one winner, bounded locks and no deadlock; final rollback.
Backfill is never executed, even to test its refusal.

## Backfill gate and manual financial review

The preview classifies one relationship in each deterministic/unresolved category.
It emits counts only and writes no provenance. Ambiguous/no-evidence relationships
remain NULL. `backfill.sql` always raises: editing the JSON cannot enable it.
A future executable component needs signature verification and a locked evidence
plan bound to catalog, data and script hashes, expiry and DBA/Finance/Factoring/
Security approvals. This phase does not implement or test that component.
Never invent ownership, auto-convert invoices, clean up financial rows, or edit
migration-history rows. Preserve all payment/factoring history and resolve legacy
financial discrepancies only through separately approved manual review.

## Production runbook — review gates only, no commands

1. Keep production BLOCKED; obtain the missing manifest under separate authority.
2. DBA/security compare actual policy/function/ACL/dependency definitions with sources.
3. Resolve the inaccurate name-only migration-landmark diagnostics.
4. Review the actual target and rollback dependency graph; complete this local rehearsal.
5. Finance/AR and factoring owners sign off aggregate financial/recipient states,
   deterministic ownership evidence and unresolved relationships before any backfill.
6. Security and application-security approve table revocations and approved RPC access.
7. Lead DBA approves stage ordering, invariant coverage, reference definitions,
   concurrency controls, tested recovery and post-stage verifiers.
8. Release/change manager approves maintenance window and traffic freeze/fail-closed mode.
9. Require all approvals, separately authorized execution, and a complete final audit
   with zero failing blockers before deployment authorization.

No production remediation may begin until all required approvals are recorded.
All approvals remain missing. Local design permission is not production approval.
