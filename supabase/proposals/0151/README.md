# Proposal 0151 -- authorize BEFORE any idempotency replay in `transition_dispatch_status()` (F1-R1)

**NOT APPROVED FOR PRODUCTION. NOT APPLIED. Not in `supabase/migrations/`.** Untracked, prepared for review only.

## Numbering
`0130..0147` -> `0149` (enum repair, unchanged) -> `0150` (zero-evidence unresolved loads; requires the real count + digest) -> **`0151`** (this).
The unrelated current proposal `supabase/proposals/0148/` is untouched and must be renumbered to **`0152` or higher** before promotion (not done now).
0134 is **not** modified; 0151 replaces only the function body via `CREATE OR REPLACE`.

## Root cause (confirmed on the real 0134 function, see `defect_repro.sql`)
`supabase/migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql`, `transition_dispatch_status`:
* line 317: `auth.uid() IS NULL -> TSAUT`; line 321: `current_org_id() IS NULL -> TSAUT` (authentication + "has an organization" only);
* lines **329-335**: the ledger is read **here**: `select result ... from public.dispatch_status_transitions where dispatch_id = p_dispatch_id and idempotency_key = p_idempotency_key` -> `return v_cached || {idempotent_replay:true}`;
* only afterwards (lines 338-346) is the dispatch's organization compared to the caller's (TSDNF), and only later still (STEP 3, after the locks) is the role checked.

Ledger `public.dispatch_status_transitions`: `id, dispatch_id (FK cascade), idempotency_key, organization_id (FK), old_status, new_status, result jsonb, created_by (FK set null), created_at`; **`UNIQUE (dispatch_id, idempotency_key)`**; RLS select by organization; no client writes.
Replay scope in 0134: **dispatch + key only** -- NOT organization, NOT user, NOT operation (requested status), NOT current role.
Cached JSON returned: `success, dispatch_id, old_status, new_status, no_op, reactivated` (+ `idempotent_replay`).
Consequences reproduced on 0134: a dispatcher **of another organization**, an owner of another organization, a same-org **accountant/viewer**, and a **role-downgraded** ex-dispatcher, each holding a known dispatch UUID + key, all received the cached result; a real key vs a wrong key gave *success* vs *TSDNF* (an existence oracle for foreign dispatches and keys); the same key with a **different requested status** silently returned the stale result. **Not** defects: unauthenticated callers and users removed from the organization are already refused before the ledger (uid / organization are checked first). The same key cannot collide across dispatches (the key is per dispatch) but the ledger primary uniqueness is not organization-scoped.

## The fix (function body only)
Order in 0151: authenticated (unchanged) -> caller has an organization (unchanged) -> **target dispatch belongs to the caller's organization, else the identical `TSDNF`** ->
**caller CURRENTLY holds owner/admin/dispatcher (else `TSROL`)** -> **only then** the ledger lookup, filtered by `organization_id = caller's org` + dispatch + key, **bound to the original requested status** (`new_status` mismatch -> new `TSIDK`), and a replay of a reactivation or backward correction additionally requires CURRENT owner/admin (a replay never grants more than performing it) -> everything else as 0134 -> after the load+dispatch locks the ledger is checked **again** so a concurrent duplicate replays the winner's result instead of returning a `no_op`.

Ledger binding decision (no schema change; existing columns suffice): **organization** bound; **dispatch** bound (already); **operation/request** bound via the stored `new_status` (== requested status by construction); **actor NOT bound** -- policy: another CURRENT owner/admin/dispatcher of the same organization may replay a cached result (it is organization data they can already read; binding the actor would only add retry failures); **no request fingerprint** (reason text is deliberately not part of the key: the original reason stands).
Preserved: signature `(uuid, dispatch_status, text, text) returns jsonb`, `SECURITY DEFINER`, `set search_path = pg_catalog, public`, owner, ACL, comment, ledger contents, transition / cancellation / audit / rollback semantics (differential matrix: 47 calls identical).
Intended behaviour changes (all tightening): foreign-org / unauthorized-role / downgraded replay refused; role gate also covers the idempotent no-op path (0134 let an accountant hit a no-op); same key + different status -> `TSIDK`; concurrent duplicate returns the replay.
App impact: `TSIDK` is unreachable from the Cancel form (one key per form instance, always `cancelled`); `cancel.ts` already maps unknown codes to the generic message, so **no F1 app change is needed**.

## Privileges (unchanged by 0151)
0151 changes NO ACL. Supabase's default privileges leave `anon` and `service_role` with EXECUTE on `transition_dispatch_status` (0134 revoked only PUBLIC); that pre-existing ACL is preserved exactly. The migration's Phase 3 compares the COMPLETE `proacl` of every public function before/after (not selected roles), plus the four role privileges of this function; `rollback.sql` re-compares `proacl`; the verifiers report the raw ACL text as INFO and require only `authenticated` EXECUTE and no PUBLIC EXECUTE. A wider `anon`/`service_role` cleanup is a separate future task.

## Files
`proposed_0151.sql` (preconditions incl. exact 0134 fingerprint -> one `CREATE OR REPLACE FUNCTION` -> postconditions: exactly one function body changed, all properties/ACL/comment identical, ledger unchanged) - `preflight.sql` - `post_apply.sql` - `rollback.sql` (restores the exact 0134 text; refuses on drift; **re-introduces the defect**) - `function_diff.patch` (semantic diff 0134 -> 0151) - `build.py` (derives everything from the 0134 source; `--check`) - `fixture_0151.sql`, `defect_repro.sql`, `regression.sql`, `matrix.sql`, `tests.py` (harness).

## Deployment
DB 0130..0147 (one by one, verifier each) -> 0149 -> 0150 (after the real `candidate_review.sql`) -> **0151** (`preflight.sql` -> apply -> `post_apply.sql`) -> app deploy -> smoke tests. 0151 is independent of the app; it can be applied any time after 0134.

## Test evidence (`python3 supabase/proposals/0151/tests.py`, disposable cluster only)
Real 0130..0147 -> 0149 -> 0150 -> 0151. Defect reproduction on 0134; the regression suite FAILS on 0134 and PASSES on 0151: original + cached cancellation, same-user and different-authorized-user retries (no duplicate audit/ledger rows), unauthenticated / no-organization, cross-org replay (dispatcher and owner, real key) indistinguishable from wrong key / missing dispatch, removed / moved / downgraded, same key on another dispatch and in another organization, key bound to requested status, reactivation/backward replay needs owner/admin, no-op role gate, failed transaction then retry, no duplicates anywhere; differential matrix (47 normal calls identical); real two-session concurrent duplicates; F1 cancellation verification (11 conditions) on the final chain; catalog + property + `pg_dump` comparison (only the function body changes); apply -> rollback (exact 0134 restoration) -> reapply identical.

## Known limits
Scratch PostgreSQL 18.3 with a support schema (production 17.6, `postgres` non-superuser); other idempotent RPCs are audited (report) but **not** changed here.
