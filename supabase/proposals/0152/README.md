# Proposal 0152 -- replay authorization, request binding and internal-helper privileges

**NOT APPROVED FOR PRODUCTION. NOT APPLIED. Not in `supabase/migrations/`.** Untracked, prepared for review only.

**Status of the maintenance freeze used with this proposal:** the v2 trigger freeze PASSED a hosted NON-PRODUCTION test (PostgreSQL 17.6, pg_cron absent; pooled and new REST connections proven by the external probe -- `freeze/HOSTED_TEST_RESULT_V2.md`); the pg_cron path is NOT HOSTED-TESTED. This does not authorize production execution. Review packet: `INDEPENDENT_REVIEW_PACKET.md`; Owner risk-acceptance alternative (unsigned, NOT independent approval): `OWNER_RISK_ACCEPTANCE.md`; internal adversarial review: `ADVERSARIAL_REVIEW.md`; legacy conflicts: `LEGACY_CONFLICT_WORKSHEET.md`; blocker remediation candidates (F-05/F-01/F-08): `../0154/`, `../0155/`, `../0156/` (superseded) and `../0157/` (carrier-invoice factoring; rounds 2-3 in `ADVERSARIAL_REVIEW.md` sections 6-7); production discovery and probe package (prepared, not run): `production_package/`.

## Numbering
`0130..0147` -> `0149` (enum repair) -> `0150` (zero-evidence unresolved loads; requires the real count + digest) -> `0151` (transition replay authorization) -> **`0152`** (this).
Unrelated proposal `supabase/proposals/0148/` is untouched and must be renumbered to **`0153` or higher** before promotion (not done now).
Migrations 0135-0147 are not modified; 0152 replaces function bodies via `CREATE OR REPLACE` and revokes three privileges.

## Defect class and scope
One defect class: **an idempotency ledger was read (and its cached result returned) before authorization, target-organization ownership or request binding.** See `AUDIT.md` for the full 23-row audit.
Confirmed on the real functions (`python3 tests.py` reproduces them on the baseline): CROSS_ORG_REPLAY (reassign 0135, set policy 0139), SAME_ORG_ROLE_BYPASS (review legacy 0142, update draft 0143),
REQUEST_MISMATCH_REPLAY (reassign, set policy, configure / rotate / lifecycle / deactivate-relationship 0141, review legacy), an existence oracle (reassign, set policy), and
DIRECT_INTERNAL_CALL_EXPOSURE (service_role can execute `_issue_dispatch_service_invoice_internal`, `transition_carrier_factoring_integration_lifecycle`, `_generate_carrier_invoice_payment_number_internal`).
False alarms: issue / payment / void / agreements / draft create+delete (0144-0147) -- authorization and organization scoping already precede the ledger and requests are fingerprint-bound; the helper is NOT reachable by
authenticated / anon / PUBLIC (only service_role, because Supabase default privileges grant it at CREATE and 0145/0146 did not revoke it).

## What 0152 changes
| function | change | mismatch code |
|---|---|---|
| reassign_dispatch_resources | dispatch-org check (same `RRDNF`) before the ledger; ledger lookup organization-scoped and bound to driver/truck/trailer/reason as stored in the ledger row; re-checked under the load+dispatch locks | `RRIDK` (raise) |
| set_carrier_factoring_policy | carrier-org check (same `FPDNF`) before the ledger; org-scoped lookup bound by fingerprint (operation, org, carrier, mode, reason); re-checked under the advisory+row locks | `FPIDK` (raise) |
| configure_ / rotate_carrier_factoring_integration, transition_carrier_factoring_integration_lifecycle (+5 wrappers), deactivate_factoring_relationship | (org, role, target order already correct) replay bound by fingerprint of operation, org, target, every material parameter and reason; ledger read already under the locks | `IDEMPOTENCY_KEY_REUSED` (jsonb) |
| review_legacy_invoice_carrier_migration | role gate before the replay; replay decided after the row lock + org-verified target check; bound to the review row (id, resolution, notes) | `IDEMPOTENCY_KEY_REUSED` (jsonb) |
| update_carrier_invoice_draft | role + per-role field gate re-applied AT REPLAY (first-call error precedence untouched) | (existing `IDEMPOTENCY_KEY_REUSED`) |
| 3 helpers | `REVOKE ... FROM service_role` too (plus public/anon/authenticated) | -- |

Design decisions: **actor is not bound** (a different currently authorized owner/admin/dispatcher may replay an organization-owned operation); **`expected_updated_at` is not part of the fingerprint** for 0139/0141 because 0139
deliberately replays across a stale token (`TEST_0139` P6, re-run green); the reason text IS bound for the fingerprinted families and for reassign (stored in its ledger row); NULL fingerprints never replay; normal first-call behaviour is unchanged
(matrix steps s0/s12/s13/s14 identical to the baseline for all eight RPCs, and every repository suite passes).

## Schema changes (necessary, minimal)
Two **`request_fingerprint text NOT NULL`** columns (no default) on `factoring_policy_idempotency` (0139) and `factoring_integration_lifecycle_idempotency` (0141): neither ledger stores the request, so request binding is impossible
otherwise. **Zero-row invariant:** both ledgers are introduced by 0139/0141 in the same maintenance window and must be EMPTY when 0152 runs; `preflight.sql` FAILS if either holds a row, and `proposed_0152.sql` independently takes `ACCESS EXCLUSIVE` locks on both, re-counts under the locks and ABORTS WITHOUT CHANGES if either is non-empty (no fingerprint is fabricated or backfilled). The DB-enforced NOT NULL means no row can ever exist without a fingerprint, and the repaired functions additionally fail closed (`IS DISTINCT FROM`) if an unexpected NULL is ever met. The rollback drops the columns (exact prior schema). Every other ledger already stores what is needed (0135: driver/truck/trailer/reason; 0142: review row; 0143+: fingerprints). No index, constraint,
policy, trigger or grant change; ledgers are not written by the migration.

## Files
`proposed_0152.sql` (exact-baseline-fingerprint preconditions incl. 0151 applied -> 2 columns -> 8 function replacements -> 3 revokes -> postconditions: exactly the 8 bodies changed, every property/ACL identical except the 3 helpers, ledgers untouched) -
`preflight.sql` - `post_apply.sql` - `rollback.sql` (exact baseline bodies, drops the columns, re-grants service_role on the helpers; refuses on drift; **re-introduces the defects**) - `diffs/*.patch` (per-function semantic diff) -
`AUDIT.md` - `build.py` (derives every function from its authoritative migration text with anchored, asserted edits; `--check`) - `fixture_0152.sql`, `matrix.sql` (generated authorization/replay matrix), `tests.py`.

## Tests (`python3 supabase/proposals/0152/tests.py`, disposable cluster only, Supabase-style default privileges)
Baseline defect reproduction; **runtime probes (16-17 expectations each, run on the baseline AND after 0152) for every externally executable SAFE RPC of 0144-0147** (`probe_safe_0144_0147.sql`, appended to a copy of TEST_0147) plus the structural proof; zero-row gate scenarios (per ledger, atomic, plus a two-session lock race); NOT NULL enforcement; fail-closed NULL replay; non-NULL fingerprint written by every fingerprinting RPC; apply; catalog / privilege / `pg_dump` comparison (8 bodies + 3 helper ACLs + 2 columns, nothing else); matrix of 16 steps x 8 RPCs (136 expectations);
concurrent duplicates (real two sessions, all 8 RPCs); 0151 and F1 suites on the final chain; the repository's own suites (0134, cancellation dedup, backward matrix, 0135, 0139, 0141, 0143-0147) re-run with 0151/0152
injected; rollback -> exact restoration -> reapply.

## Not changed (decision: separate future hardening task)
A wider `anon` / `service_role` privilege cleanup (e.g. `anon` EXECUTE on `transition_dispatch_status`, `reassign_dispatch_resources`, `set_carrier_factoring_policy`, `service_role` on pure predicates) is **not** part of 0152; all other ACLs are preserved exactly
(verified by a complete before/after ACL comparison over every public function). It needs a complete caller inventory first. Only the three confirmed internal helpers lose `service_role`.

## App mappings (added with this revision)
`RRIDK` -> `rpcDispatchConflict` (`src/lib/dispatch/conflicts.ts`) with the FIXED message; `FPIDK` -> `resolveStructuredRpcResult` (`src/lib/factoring/rpc-result.ts`), the single shared place where the factoring actions turn a raised RPC error into user text. See `PG17_COMPATIBILITY.md` for the PostgreSQL 17.6 review.

## PostgreSQL 17.6 gate -- PASSED
Executed on an exact PostgreSQL 17.6 (official container image `postgres:17.6`, aarch64, `server_version_num 170006`) through OrbStack: 0149 / 0150 / 0151 / 0152 suites and `pg17_probe.py` pass; see `PG17_COMPATIBILITY.md` (findings and 17-vs-18 differences) and `pg17_probe.py`. Test reports were preserved outside the repository.

## Known limits
Scratch PostgreSQL (18.3 on the host, 17.6 in a container) with a support schema. The repository suites for 0135/0139/0141 stop before 0143, so they run with a test-only fingerprint shim and the partial 0152 statements that exist at their
migration state; the full `proposed_0152.sql` runs in the 0147 suite and in the dedicated chain.
