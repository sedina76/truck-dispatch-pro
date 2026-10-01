# Proposal 0149 — enum-typed `c_active` repair for `create_dispatch()` / `cancel_dispatch()`

**NOT APPROVED FOR PRODUCTION. NOT APPLIED. Nothing here has been run against Supabase or any real database.**
Lives only under `supabase/proposals/0149/`; nothing was created in `supabase/migrations/`.

> **Numbering note.** This is proposal number **0149**. The separate, unapproved proposal
> `supabase/proposals/0148/` is untouched. **If 0149 is applied before 0148, the 0148 proposal must be
> renumbered above 0149 before promotion.** It has not been renumbered.

## The defect (proven)

Migration `0129_atomic_dispatch_lifecycle.sql` declares, in **both** functions:

```sql
c_active constant text[] := array['assigned', ... 'at_delivery'];   -- create_dispatch: line 397, cancel_dispatch: line 580
... where d.status = any(c_active)                                   -- d.status is public.dispatch_status (enum)
```

`dispatch_status = text` has no operator → `42883: operator does not exist: dispatch_status = text`.
PL/pgSQL type-checks each statement only when it first runs, so `CREATE FUNCTION` in 0129 succeeded.

| Function | Declaration | `d.status = any(c_active)` sites |
|---|---|---|
| `create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)` | 0129:397 | 0129:438, 453, 466, 480 (main path) and 530, 541, 553 (`unique_violation` handler) — 7 |
| `cancel_dispatch(uuid,text)` | 0129:580 | 0129:642 (load-revert `NOT EXISTS`) — 1 |

Blast radius: exactly these 2 functions / 8 sites. `reassign_dispatch_resources()` (0135:182) already uses
`public.dispatch_status[]`; `transition_dispatch_status()` and its helpers (0134) are enum-typed. No other
migration declares `c_active constant text[]` (checked statically by `tests.py`, and live by the verifiers).

**Why it escaped earlier testing:** the shared support schema (`TEST_SUPPORT_0130_0133_schema.sql`) ships a
**stub** `create_dispatch` (`raise exception 'stub'`) and a re-implemented `cancel_dispatch` that uses literal
`status not in (...)` instead of `= any(c_active)`; `TEST_0129_dispatch_lifecycle.sql` is manual-only and the
repo has no CI. `actions.test.mjs` only regex-matches source text. Nothing ran the real 0129 bodies.

## The repair

Only the two declarations change (line layout kept so the diff is 2 lines per function):

```sql
c_active constant public.dispatch_status[] := array[
  'assigned','accepted','en_route_to_pickup','at_pickup','loaded',
  'en_route_to_delivery','at_delivery']::public.dispatch_status[];
```

`dispatches.status` is **not** cast to text. `CREATE OR REPLACE` preserves OIDs, owner, ACL, comment.
Function bodies are **extracted** from 0129 by `build.py`, never retyped.

Signatures replaced (exactly two):
`public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)` returns `uuid`, and
`public.cancel_dispatch(uuid,text)` returns `void` — both plpgsql, SECURITY **INVOKER**, VOLATILE,
PARALLEL UNSAFE, `SET search_path = public`, EXECUTE for `authenticated` only.

## Files

| File | Purpose |
|---|---|
| `proposed_0149.sql` | Forward migration: PHASE 1 fail-closed preconditions → 2× `CREATE OR REPLACE FUNCTION` → PHASE 3 postconditions (incl. owner/ACL/comment/config/args unchanged). One transaction. |
| `preflight.sql` | **Read-only** single SELECT over the system catalogs (29 PASS/FAIL checks + 38 INFO rows): the LIVE functions are exactly the defective 0129 baseline. PASS → full report ending `RESULT \| PASS`; any failure → the statement **raises an error** (`PREFLIGHT FAIL ...`) whose text is the full report. Also re-run after rollback. |
| `post_apply.sql` | **Read-only** single SELECT (30 PASS/FAIL checks): live functions are exactly the repaired definitions, metadata intact; same PASS-report / raise-on-FAIL behavior (`POST_APPLY FAIL ...`). |
| `rollback.sql` | Restores the exact 0129 bodies (**re-introduces the defect** — completeness only). Fails closed unless 0149 is what is live. |
| `build.py` | Generates the four SQL files above from 0129; `--check` fails if any committed file is stale. |
| `tests.py` | Disposable-cluster harness (below). |
| `fixture.sql`, `regression.sql`, `defect_repro.sql` | Test-only SQL; each starts with an identical scratch guard and refuses to run unless the runner's opt-in setting **and** the `/private/tmp/td0149-local-*` cluster identity are present. |

Verifiers compare bodies by an md5 of the comment-stripped, whitespace-free, lowercased text, so harmless
whitespace/comment differences pass while any material drift fails closed (proved on clones, below).

## Application order (when separately approved)

1. `preflight.sql` on the target → no error, last row `RESULT | PREFLIGHT | PASS`.
2. `proposed_0149.sql` (single transaction; aborts and changes nothing on any drift).
3. `post_apply.sql` → no error, last row `RESULT | POST_APPLY | PASS`.
4. Application smoke test: create a dispatch from **New Dispatch**; cancel via the **Dispatch Board** path.
Rollback: `rollback.sql`, then `preflight.sql` (proves the baseline is restored). Rollback brings the defect back.
If 0149 is promoted, generated files must be copied to `supabase/migrations/` under the final number
(the filename is the only thing that changes; the SQL contains no number-dependent text except the `0149` labels).

## Evidence (disposable PG 18.3 cluster; `python3 supabase/proposals/0149/tests.py` → **78 checks, all pass**)

* **Only two declarations changed** — per function the line diff vs 0129 is exactly
  `-  c_active constant text[] := array[` / `+  c_active constant public.dispatch_status[] := array[` and
  `-    'en_route_to_delivery','at_delivery'];` / `+    ...at_delivery']::public.dispatch_status[];`;
  the whitespace/comment-insensitive bodies differ only by that type + cast; `status::text` absent.
* **Before/after catalog** (1082 objects: relations, columns, constraints, indexes, triggers, policies, function
  bodies + metadata/ACL/owner/comment, types): the *only* differences are the two `function_body` entries.
  `pg_dump --schema-only`: exactly 4 removed + 4 added lines (the two declarations × 2 functions).
* **Rollback:** catalog identical to the pre-0149 baseline and `pg_dump` **byte-identical**; `preflight.sql` passes again;
  the 42883 defect is reproducible again. **Reapply:** catalog and dump identical to the first apply.
* **Fail-closed:** second apply (defect gone) and rollback-on-baseline both abort, changing nothing. Seven baseline
  clones: harmless comment/whitespace drift → tolerated and applies; material body drift, ACL drift (`anon` grant), enum
  drift (extra label), an extra `c_active constant text[]` function, `search_path` drift, SECURITY DEFINER drift →
  preflight fails on the specific check and 0149 refuses to run, catalog unchanged.
* **Defect reproduced** on the 0129 baseline (`create_dispatch` and `cancel_dispatch` → `42883 operator does not exist: dispatch_status = text`).

### Requirement → test map (`regression.sql`, 19 assertion groups, run twice; + real 2-session race)

| # | Requirement | Test |
|---|---|---|
| 1,2 | create succeeds; load → `dispatched` | T1 (row, financials fee, notes, carrier claim 0132, financial controller 0125, audit), T1b (default fee 10, blank notes) |
| 3 | cancel succeeds | T2 via `transition_dispatch_status` → `cancel_dispatch` (idempotent, load → `booked`, history kept), T2b (load stays `dispatched` while another active dispatch holds it) |
| 4,5,6 | `TDDRV` / `TDTRK` / `TDTRL` | T3–T6 for **each of the 7 active statuses** (with holder id in DETAIL, `TDDUP` for the load); `delivered/completed/cancelled` never block |
| 7 | carrier mismatch rejected by 0132 guard | T7 (`23514`, no partial writes), T7d unresolved carrier, T7e unresolved trailer |
| 8 | cross-org rejected | T8 (`TDLNF` for another org's load; cross-org carrier/truck rejected by the org guards even after the 0132 claim ran; accountant `TDROL`; unauthenticated `TDAUT`; `TDLND`) |
| 9 | forced downstream failure rolls back everything | T9: injected failure at financials, notes, load update, audit → snapshot identical; T9c: cancel failing at load revert / audit |
| 10 | retry / idempotency | T9 retry creates exactly one dispatch; T10 double-submit → `TDLND` (and `TDDUP` when dispatchable), one set of side effects |
| 11 | signatures/security/search_path/privileges unchanged | `post_apply.sql` + PHASE 3 metadata hash + catalog comparison |
| 12 | no `dispatch_status = text` left | static counts in verifiers (7/1 sites, 0 `text[]`, 0 `status::text`), live blast-radius check, and **every one of the 8 sites executed**: main path (T3–T6, T10), load-revert (T2/T2b), and the 3 `unique_violation` handler sites by a real 2-session race (`race[driver|truck|trailer]` → `TDDRV/TDTRK/TDTRL` naming the committed holder, losing call leaves nothing) |

## Follow-up blockers and findings (NOT changed or proposed here)

* **BLOCKER F1 — dispatch-detail Cancel button (separate follow-up; out of scope for 0149).**
  `cancel_dispatch()` is SECURITY INVOKER. 0135 revoked UPDATE on `public.dispatches` from `authenticated` and re-granted
  only `dispatches.notes`, so `authenticated` may lack the UPDATE privilege the function needs. The app's `cancelDispatch`
  server action (`src/app/(app)/dispatch/actions.ts:566`) calls the RPC directly as `authenticated`. **Confirmed in the
  disposable environment** (real 0135 grants): the direct call is refused with `42501 permission denied for table dispatches`
  before it reaches the repaired statement (pinned by test T2c). **Production behavior is not yet verified.** The Dispatch
  Board path (`transition_dispatch_status`, SECURITY DEFINER → `cancel_dispatch`) works after 0149. **No repair is proposed
  or implemented; 0149 deliberately changes no privileges.**
* **F2 — stale comment.** 0135:97 calls `create_dispatch()` SECURITY DEFINER; it is INVOKER (0129:393). Documentation only.
* **F3 — commit `fbd23e7`** already maps this `42883` to the generic `UNKNOWN` message with no internal detail; no app change needed.

## PostgreSQL version compatibility (disposable tests ran on 18.3 only)

Only PostgreSQL 18.3 exists on the test machine, so the verifiers/migration were **not executed on any older server**.
Inventory of everything they use (extracted from the generated SQL): catalogs `pg_proc`, `pg_language`, `pg_enum`
(`enumsortorder`, 9.1), `pg_attribute`, `pg_indexes`, `pg_trigger` (`tgisinternal`); functions `to_regprocedure/to_regtype/to_regclass`
(9.4), `pg_get_function_arguments`, `pg_get_function_identity_arguments` (8.4), `has_function_privilege(name, oid, text)`,
`obj_description`, `format_type`, `version()`, `current_setting('server_version_num')`, `md5`, `split_part`, `regexp_replace`,
`string_agg`/`array_agg(... order by)` (9.0), `count(*) FILTER` (9.4), `::regrole` (9.5), `LATERAL` (9.3),
`pg_proc.proparallel` (9.6 — the newest feature used), and in the migration only `set_config(..., true)`/`current_setting(..., true)`
and plpgsql `FOR ... IN <WITH query>`. **Nothing depends on PostgreSQL 18 behavior**; the report includes an explicit
`server supports every catalog column this report reads (>= 9.6)` check and prints `server_version`/`version()` first.
Cross-version rendering relied on (`DEFAULT NULL::uuid` in argument lists, `{search_path=public}` in `proconfig`, `=X/owner`
for a PUBLIC ACL entry) is stable across supported releases. Fail-closed is the safe direction: an unexpected rendering
would produce a FAIL, never a false PASS. The migration's function bodies are the 0129 text already accepted by the live server.
Also verified locally: `preflight.sql` succeeds for a role holding **no privilege on any user table**, i.e. it reads catalog
metadata only.

## Fidelity limits / not proven

Harness = pinned support schema + real 0129 bodies + real 0130–0135 + `fixture.sql` (0067 tables/RLS, 0010 RLS loop,
seed). Not modelled: `dispatch_financials_sync` (0068, money math only) and migrations 0136–0147 (none redefines these
functions or adds triggers on `dispatches`/`loads` in the create path — checked statically). PostgreSQL 18.3 locally vs
Supabase's version; live catalog **not** inspected. Production-side proof is `preflight.sql` run by a human first.
Trusted binaries/filesystem assumed; SIGKILL/power loss can bypass cleanup (dirs live under `/private/tmp/td0149-local-*`).

## Re-run

```
python3 supabase/proposals/0149/build.py --check     # generated files current
python3 supabase/proposals/0149/tests.py             # full disposable-cluster verification (well under a minute)
```
