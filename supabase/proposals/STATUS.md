# Proposal status (production project zteixenjpcygjvznueuo)

Verified against production on 2026-10-01 (function fingerprints plus each proposal's `post_apply.sql`).

| Proposal | Production | Migration file |
|---|---|---|
| 0149 | applied | `migrations/0149_dispatch_lifecycle_enum_array_repair.sql` |
| 0150 | applied (approved count/digest typed into the SQL Editor copy only) | `migrations/0150_normalize_zero_evidence_unresolved_loads.sql` |
| 0151 | applied | `migrations/0151_transition_replay_authorization.sql` |
| 0152 | applied; post_apply 22/22 PASS | `migrations/0152_idempotency_replay_hardening.sql` |
| 0154 | applied | `migrations/0154_unresolved_carrier_record_exposure_fix.sql` |
| 0155 | applied | `migrations/0155_strict_carrier_inference_review.sql` |
| 0156 | **NOT applied; superseded; never apply** | none |
| 0157 | applied; post_apply 104/104 PASS; factoring gate DISABLED | `migrations/0157_carrier_invoice_issuance_and_factoring.sql` |
| 0148 (proposal) | not applied; unrelated to `migrations/0148_profile_cross_tenant_move_guard.sql` | must be renumbered to 0153 or 0161+ before use |

Notes:
- The migration files are **byte-identical** copies of `proposed_*.sql`. Their "NOT APPROVED / NOT APPLIED" headers are historical; this table is the current status.
- 0150 stays fail-closed in the repository: `v_expected_count` / `v_expected_digest` are `null`, so running the file unedited aborts and changes nothing. Never commit a filled copy.
- 0157 was applied **without** `normalize_names.py`: production objects keep their `_0157` suffix, and the application code uses those names. Do not normalize the repository copy unless a later migration renames the live objects.
- The proposal folders stay in place: their `preflight.sql` / `post_apply.sql` / `rollback.sql` are the verifiers, and app tests read `proposals/0157/proposed_0157.sql`.
- `migrations/0160_*` was applied before 0149..0157 were copied here; it is independent of them (it only touches the legacy `factored_invoices` reconciliation).
