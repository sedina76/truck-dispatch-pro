# Proposal 0152 -- independent review and approval packet

**Status: NOT APPROVED FOR PRODUCTION. NOT APPLIED. Nothing here authorizes production execution.** Production remains BLOCKED pending (1) an independent PostgreSQL/Supabase DBA/security review of this packet and (2) written Owner approval. Prepared for review only; nothing is staged, committed or deployed; `supabase/migrations/` and proposal 0148 are untouched.

> **Funding note:** the independent review recommended here is presently unaffordable. `OWNER_RISK_ACCEPTANCE.md` (unsigned, expired as stored) provides an alternative gate that is **not** independent approval; `ADVERSARIAL_REVIEW.md` is the author's own, non-independent review.

## 1. What is being proposed (one paragraph)
A maintenance window for the carrier-dispatch production database: freeze all writes (application `MAINTENANCE_MODE` + a database write-barrier trigger + reviewed cron pauses), apply `0130..0147` one at a time with verifiers, then `0149` (enum repair), `0150` (legacy unresolved-load normalisation, human stop for count+digest), `0151` (transition replay authorization), `0152` (idempotency/helper hardening), run rolled-back DB smoke tests, deploy final app code, restore the DB freeze exactly, run controlled app smoke tests, lift maintenance. Exact order and stop/rollback rules: `RUNBOOK_PRODUCTION_0130_0152_DRAFT.md` (21 steps).

## 2. Verified state (what has and has not been tested)
| item | state |
|---|---|
| Migrations/proposals 0149-0152 | local disposable PostgreSQL 18.3 and an exact PostgreSQL 17.6 container (earlier round, container since removed): generators, tests, 17.6 compatibility probe, integrity manifest (`integrity.py`, `PROMOTION_MANIFEST.txt`) |
| Application maintenance gate (`src/lib/maintenance/gate.ts`) | unit-tested locally (14 tests, route list derived from the filesystem); **not deployed**, not tested on a real host |
| Database freeze v1 (role default) | **FAILED** the hosted non-production test; superseded (`freeze/ROOT_CAUSE_AND_REDESIGN.md`) |
| Database freeze v2 (trigger) | 191 local checks pass; **hosted non-production test PASSED (PostgreSQL 17.6, pg_cron ABSENT, one table)**: pooled and new REST connections proven blocked by the external probe; restoration proven (`freeze/HOSTED_TEST_RESULT_V2.md`, recorded from the operator's report; raw evidence files are held by the operator, not in the repository) |
| pg_cron pause/resume on hosted Supabase | **NOT HOSTED-TESTED.** If production discovery finds pg_cron installed or any relevant cron job, a separate hosted pg_cron test is required before production |
| Anything on production or staging | **nothing has been run, read or connected** |

Verdict wording (exact): *HOSTED NON-PRODUCTION RESULT -- v2 trigger freeze, PostgreSQL 17.6, pg_cron ABSENT: PASSED. Both the existing-pooled-connection path and the new/recycled-connection path were proven blocked by the EXTERNAL API probe. SQL-only verification is not accepted as freeze proof. The pg_cron path is NOT HOSTED-TESTED. This result does not authorize production execution. Production remains blocked pending independent PostgreSQL/Supabase DBA/security review and written Owner approval.*

## 3. Materials for the reviewer
**Round 4 additions (final D-57 decisions):** proposal `0157` now contains the carrier-invoice issuance / reissue workflow (preview, draft, ready, issue, discard, reissue, dispatch-fee link, billable-record ledger, immutable issuance terms), relationship drift REFUSES submission (`RELATIONSHIP_DRIFT_REISSUE_REQUIRED`), the `rejected` / `funded` states are removed, and `0157/normalize_names.py` normalizes names at promotion; tests: `0157/tests.py`, `src/lib/factoring/carrier-invoice-issuance*.test.mjs`; decisions and limitation: `0157/OWNER_DECISIONS.md`. Please review these together with Round 2 below.

**Round 2 additions:** proposals `0154` (F-05), `0155` (F-01), `0156` (F-08, disabled by default) with their tests (`0154/tests.py`), `0156/OWNER_DECISIONS.md`, and `ADVERSARIAL_REVIEW.md` section 6. Please review these as part of Sections B, D, E and F below, and specifically: (a) the strict evidence hierarchy of 0155 and whether any level is too weak or too strong; (b) whether owner-only exception writing plus fail-closed public function is sufficient for F-05; (c) proposal 0157 (carrier-invoice factoring): the authorization matrix, the server-side relationship selection, the immutable snapshot and hash-chained audit ledger, the operator gate and D-08i enforcement, and the recorded decisions D-57a..h, including owner/admin-only pilot issue/reissue/submission (`0157/OWNER_DECISIONS.md`); proposal 0156 is superseded.

`README.md` (this proposal), `AUDIT.md` (23-function audit), `PG17_COMPATIBILITY.md`, `PROMOTION_PLAN.md`, `PROMOTION_MANIFEST.txt`, `RUNBOOK_PRODUCTION_0130_0152_DRAFT.md`, `MAINTENANCE_FREEZE_DESIGN.md` (v1 section superseded), `freeze/` (`README.md`, `ROOT_CAUSE_AND_REDESIGN.md`, `HOSTED_TEST_RESULT_V2.md`, `HOSTED_TEST_PLAN.md`, `EMERGENCY_RECOVERY.md`, scripts `01..07`, `hosted_test/api_freeze_probe.py`, `tests_freeze.py`), `../../DEPLOYMENT_RUNBOOK_0130_0147.md`, the migrations `0130..0147`, `../../REPAIR_*.sql`/`VERIFY_*` files, and the application changes listed in `git status` (uncommitted).

## 4. Questions the reviewer is asked to answer (each with a finding: OK / CONCERN / BLOCKER)
### A. Trigger-based freeze design and bypass risks
1. Is a statement-level `BEFORE INSERT/UPDATE/DELETE/TRUNCATE` trigger, `ENABLE ALWAYS`, named `0_ops_freeze_block_writes`, an adequate write barrier for PostgREST/Supavisor/Supabase clients on the real production table set (partitions, unlogged tables, views with INSTEAD OF triggers, foreign tables, inheritance, extension-owned tables)?
2. Enumerate every way a non-exempt session could still change data in the scope schemas (e.g. `session_replication_role`, `ALTER TABLE ... DISABLE TRIGGER`, `SET SESSION AUTHORIZATION`, definer functions owned by a role that logs in, `COPY`, logical replication apply, `pg_restore`, triggers ordered before ours, rules, `CREATE TABLE AS`/`SELECT INTO` into new tables) and say which the design already blocks.
3. Is deciding on `session_user` correct and robust on Supabase (PostgREST, pgbouncer/Supavisor, Edge Functions, Studio, Dashboard SQL Editor, `supabase_admin`)? Any path where `session_user` is not the API login role?
4. Lock behaviour: `CREATE TRIGGER` takes SHARE ROW EXCLUSIVE per table inside one transaction with a 5 s `lock_timeout`. Is that acceptable at the production table count and traffic (with maintenance on)? Any deadlock/priority-inversion risk with autovacuum or long transactions?

### B. Exempt operator / superuser model
5. Is exempting the operator (`postgres`) and superusers (`supabase_admin`) acceptable? Could a compromised or mistaken exempt session write business data during the window, and are the runbook's operator rules enough?
6. Is the never-exempt list (`authenticator`, `anon`, `authenticated`, `service_role`, auth/storage/realtime/replication/ETL/read-only/pgbouncer roles) complete for production?

### C. New-table coverage refresh
7. The freeze does not cover tables created while frozen until `03_refresh_coverage.sql` runs (tested; the runbook runs it after every table-creating migration and `04` fails otherwise). Is that residual window acceptable, or should the design add automatic coverage (event trigger, if the platform permits) or run the migrations in a way that avoids it?

### D. Residual risks (each: accept, mitigate, or block)
8. Auth (sign-in, token refresh, `auth.*` writes), Storage (`storage.objects`), Realtime (`realtime.*`) -- platform schemas are out of scope of the trigger.
9. Sequences (`nextval`/`setval` via granted privileges), `NOTIFY`/`pg_notify`, advisory locks, temporary objects, large objects.
10. Outbound side effects of blocked writes (Stripe/Resend webhook retries against the 503 gate) and Supabase Database Webhooks triggered by writes.

### E. Privilege revocations
11. `0152` revokes `service_role` EXECUTE on three internal helper functions; earlier migrations revoke/re-grant other privileges. Confirm the final privilege matrix (before/after snapshot in the runbook, step 14) matches intent, that no needed caller loses access, and that no unintended widening remains. The freeze itself changes no privilege (tested by catalog fingerprints).

### F. Schema-repair strategy
12. Assess the strategy for bringing production from the audited clean `0129` boundary to `0152`: the preflight/verifier discipline per migration, the read-only audits, `0149` enum repair, `0150` normalisation (candidate review + owner-approved count/digest), the manual `REPAIR_*` scripts (never routine), and the "Case 1" assumption that production is exactly at 0129 with no drift. What evidence would change your assessment?

### G. Financial safety of the 0137 backfill
13. `0137` (deterministic factoring backfill: relationship-to-carrier mapping via ordered rules, NOA document states) touches factoring/invoice data. Review the classification rules, the provenance recorded, the unresolved-row handling, the `BACKFILL_REPORT_0137_TEMPLATE.md` sign-off, and `ROLLBACK_0137` refusal conditions. Can any row be mapped to the wrong carrier, or any invoice/financial figure change? Is the fail-safe (unresolved rows stay unresolved) correct?

### H. Ordering of the 0138 and 0140 repairs
14. Confirm the ascending order `0138` (default cutover, classifier, secured RPCs) -> `0139` -> `0140` (factoring authorization/submission safety, exact prior signatures required) is correct: that no window exists where a newer verifier passes while an older, weaker function body is live, that `0140`'s "exact prior signature" preconditions are satisfied by `0138/0139`, and that rollbacks in reverse order remain safe.

### I. Rollback and post-restoration verification controls
15. Are the stop conditions after each of the 21 steps, the rollback order (`ROLLBACK_0152 .. ROLLBACK_0130` with their refusal checks), the PITR/backup gate (step 1) and `EMERGENCY_UNFREEZE.sql` / `EMERGENCY_RECOVERY.md` sufficient? Is the post-restoration verification (`06_verify_disable.sql`, discovery diff, external write probe, controlled app smoke tests, monitoring/re-freeze rule) sufficient, including the case where migrations legitimately change trigger/ACL fingerprints?
16. The external probe for production is NOT written (the hosted probe refuses production by design). Is the proposed approach (a separately reviewed production variant with an explicit ref allow-list and Owner-designated synthetic rows/RPCs) acceptable, or must the proof battery differ?

## 5. Required before any production step (all must be true)
1. **Either** (a) independent PostgreSQL/Supabase DBA/security review completed with no open BLOCKER (Section 4) -- the recommended path -- **or** (b) a signed, unexpired Owner risk acceptance (`OWNER_RISK_ACCEPTANCE.md`), which is NOT independent approval and waives only this item; the blockers in `ADVERSARIAL_REVIEW.md` are never waived.
2. Written Owner approval of this packet and of the exact window plan.
3. Production discovery (`freeze/01_discovery_readonly.sql`) reviewed; if pg_cron is installed or any relevant cron job exists: a separate hosted pg_cron test passed first.
4. A reviewed production API-probe variant exists (item 16).
5. Migrations promoted and byte-verified against `PROMOTION_MANIFEST.txt`; unrelated proposal 0148 renumbered to 0153 or higher; final commit and deployed commit recorded (runbook step 2).
6. Fresh backup/PITR point (runbook step 1).

## 6. Known open items (author's list)
* pg_cron path not hosted-tested; freeze proven on one table only; hosted evidence files are held by the operator and should be inspected by the reviewer.
* Root cause of the v1 hosted failure remains a hypothesis (H1/H2); v2 does not depend on it.
* Freeze local tests ran on PostgreSQL 18.3; hosted proof was on 17.6.
* Production probe variant, the 0150 count/digest and the 0150 candidate list do not exist yet by design.
