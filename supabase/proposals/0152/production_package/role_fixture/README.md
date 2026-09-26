# F-30 role and organization fixture — synthetic, non-production only

This is an additive companion to `../PROD_PROBE_FIXTURE_PROPOSAL.sql`. The generic fixture still tests writes by anon/authenticated/service_role. This private fixture independently tests pilot authorization, carrier grants, tenant isolation and the freeze using **synthetic action receipts**. It never installs application migrations, creates actual financial documents, invokes the 0144/0157 RPCs, or enables factoring. Its role decisions track D-57h; tests also pin the real 0157 role gates. This proves the fixture's model and freeze behavior, not a substitute implementation or hosted proof of the application.

The generic fixture intentionally refuses an existing installation; that assertion is unchanged. The new role fixture installs idempotently only when its seed data, source, ownership, schema, functions and privileges match exactly and no receipts remain. Dirty or foreign objects cause refusal, never overwrite. `reset.sql` restores only synthetic receipts to zero after verified unfreeze. Cleanup uses explicit RESTRICT drops and refuses drift, outstanding receipts, active freeze, orphan freeze triggers and external dependencies. It does not remove trusted target markers or freeze audit history; the operator removes the marker after all fixture work is complete. Disposable local tests remove the marker and destroy their entire cluster.

## Files and local commands

- `model.sql`: hand-maintained private model and two public RPCs.
- `build_fixture.py`: offline generator for `fixture.sql`, `reset.sql`, `cleanup.sql`, `verify.sql` and `topology.json`. `--check` refuses stale generated files; it is also invoked by 0152 integrity.py.
- `probe.py`: request matrix, target/identity guard and strict result evaluator; contains no network client.
- `tests.py`: disposable local PostgreSQL; accepts **no connection/target arguments**. Uses the unchanged v2 freeze scripts on actual SQL sessions, including a persistent backend before activation and a distinct new backend afterward.
- `tests_probe.py`: offline transport contracts and negative cases, including breach stop, marker/version/hash mismatch, forbidden extra fields and sanitized evidence.

```text
python3 -B supabase/proposals/0152/production_package/role_fixture/build_fixture.py
python3 -B supabase/proposals/0152/production_package/role_fixture/build_fixture.py --check
python3 -B supabase/proposals/0152/production_package/role_fixture/tests.py
python3 -B supabase/proposals/0152/production_package/role_fixture/tests_probe.py
```

No commands above connect to a hosted database. PostgreSQL tests use the existing isolated local harness (Unix socket under /private/tmp, empty credential environment, listen_addresses empty). Its local major version is recorded separately from the required hosted PostgreSQL 17.6. A persistent SQL backend models transaction-pool reuse; it is not a real Supavisor connection.

## Deterministic topology

Canonical UUIDs and source hash are in generated `topology.json`. UUID prefix: `f3000000-0000-0000-0000-`; twelve-digit suffix is the number below. Organization A has base 1000; B has base 2000. Every foreign key containing tenant-owned data includes organization scope.

| Object | Suffix offset from base | Per organization |
|---|---:|---:|
| Organization | 0 | 1 |
| Owner / admin | 1 / 2 | 1 each |
| Granted / ungranted dispatcher | 3 / 4 | 1 each |
| Accountant / driver / viewer | 5 / 6 / 7 | 1 each |
| Carrier | 10 | 1 |
| Broker / customer | 11 / 12 | 1 each |
| Factoring relationship / factor | 13 / 14 | 1 each |
| Loads | 20–22 | 3 |
| Dispatches | 30–32 | 3 |
| Carrier invoices (draft, ready, issued) | 40–42 | 3 |
| Carrier grant | carrier + granted dispatcher | 1 |

Null identity is an authenticated database role with no subject, not a fake profile. anon and service_role are database roles with no memberships. Each organization has its own server-resolved recipient, routing, terms and freight amounts. No dispatch fee is folded into those amounts. The model represents authorization intent rather than invoice state transitions.

Initial counts: organizations 2; memberships 14; carriers 2; parties 4; factors 2; relationships 2; loads 6; dispatches 6; invoices 6; carrier_grants 2; receipts 0; manifest 1. `verify.sql` exposes counts, seed/catalog hashes and comparisons. There are no wall-clock, random or sequence-dependent seed values. Receipts have no timestamps and keys are deterministic per phase/identity/action. Hashes cover seeds and catalog definitions, owner, column/table/function ACLs and policies. Only the known v2 freeze trigger is excluded from the catalog hash while active; its presence/absence is independently verified by the freeze suite and maintenance guards. The baseline hash is required again before cleanup.

## Authorization matrix

| Caller | Preview | Prepare / ready / discard | Issue / reissue / submit / submission replay |
|---|---|---|---|
| Same-organization owner/admin | OK | OK | OK (synthetic receipts only) |
| Dispatcher with carrier grant | OK | OK for granted carrier | FORBIDDEN, including an owner's existing key |
| Ungranted dispatcher | FORBIDDEN | FORBIDDEN | FORBIDDEN |
| Accountant / driver / viewer / null identity | FORBIDDEN | FORBIDDEN | FORBIDDEN |
| anon / service_role | permission denied, SQLSTATE 42501 | same | same |
| Non-null member requesting foreign/unknown invoice | NOT_FOUND, identical response containing only the code | same | same |

`f30_probe_action(p_invoice_id uuid, p_action text, p_request_key text)` has no organization, relationship, factor, routing, recipient, terms or amount input. All are resolved from private rows and composite foreign keys; extra named arguments fail signature resolution. Authorization and tenant lookup precede idempotency. Within the synthetic model forbidden preparation uses FORBIDDEN; actual 0157's ungranted preparation code remains NOT_AUTHORIZED_FOR_CARRIER. Raw table access is denied to all API roles, including service_role despite BYPASSRLS.

Before/after freeze, authorized receipt writes succeed; during freeze, fresh writes fail with SQLSTATE `25006` and marker `TDP_MAINTENANCE_FREEZE`. The hosted probe expects HTTP 405 for that contract. Preview remains readable. Unauthorized calls remain denied rather than being mistaken for freeze proof. Seed/catalog drift blocks reruns and cleanup. The unchanged v2 freeze does not modify ACLs; tests compare exact pre/post privileges and prove a separately injected grant is detected as drift, then revoke only that known synthetic change. Failure-path tests unfreeze using the real restoration script and verify the prior fingerprints.

## Guard and future hosted configuration — not executed

The exact, reviewable procedure for both steps below (marker + test identities), including how the null-identity case is handled or explicitly blocked, is `HOSTED_PROVISIONING_PLAN.md` plus `provision_marker.sql`, `provision_marker_cleanup.sql` and `mint_identity_jwts.py` in this directory. None of the four makes a hosted connection or a database change by itself; each is inert until an authorized operator runs it by hand (see the plan for exactly which parts are SQL pasted into a verified project and which part is an offline script). `tests_provisioning_plan.py` proves this offline.

**Before any of that (precondition 2): `target_preflight.py` + `target_preflight_readonly.sql`** verify the target project's exact reference (human + tool confirmation gate only, matching discovery_guard.py's own convention -- SQL cannot know its own project ref), PostgreSQL version, empty application baseline, and the absence of any pre-existing F-30 marker/fixture/freeze. `target_preflight.py` has NO real_request()/real_query() function at all -- no networking code exists in the file, not even confined to an uncalled function -- so the only way it ever sees hosted state is a human pasting the single read-only SQL row it asks for; it writes a timestamped, redacted GO/STOP evidence file and stops (never proceeds) on any mismatch. Proven entirely offline by its own `--self-check`.

**Supported path for the 14 named identities (drafted and offline-tested only; NOT run against any hosted project; hosted execution NOT authorized by this README):** `provision_auth_test_identities.py` and `cleanup_auth_test_identities.py` create/remove ORDINARY Supabase Auth test users instead of self-signed JWTs, using the Admin API's documented `id` override to keep exactly `topology.json`'s deterministic UUIDs -- avoiding the ES256/previously-used signing-key block entirely, at the cost of a hosted call on every dry run and a new, highly sensitive secret (`TDP_F30_SERVICE_ROLE_KEY`). Both take an injected transport and have zero network import at module scope; `tests_auth_provisioning.py` exercises the full provision-then-cleanup lifecycle, every ownership refusal, and secret scrubbing against a fake in-memory Auth backend (verified with `socket.socket` monkeypatched to raise, confirming zero network activity).

Provisioning durably records its own outcome to `PROVISIONING_STATUS.json` in `--out-dir` on every exit, success or failure, so a partial failure can never be reported (or mistaken, by counting files) as a completed run. If a create call ever returns an unexpected id, the row is never silently lost: if the response's own email exactly matches what was requested, it is recorded to `ORPHANS.json` (cleanable with `cleanup_auth_test_identities.py cleanup-orphans`, which rewrites that file to the true remaining state after every attempt); if the email does not match either, ownership cannot be established at all, and the row is recorded instead to a separate `UNRESOLVED.json` that no tool ever auto-resolves -- clearing it is a deliberate, manual operator action, and provisioning exits 3 (not the ordinary failure code 1) in that case. `cleanup`'s `--orphans-file`/`--unresolved-file` flags are **MANDATORY, not optional**: argparse itself refuses to start the `cleanup` subcommand at all if either is omitted, so the pre-flight check against the corresponding provisioning run's records can never be silently skipped by simply not passing the flag. A new provisioning run, and a declaration that cleanup is complete, both refuse to proceed while either file still holds unresolved entries -- the exact invocation is:
```
python3 cleanup_auth_test_identities.py cleanup --project-ref <ref> --confirm 'CLEANUP F30 AUTH USERS <same ref>' \
    --orphans-file <provisioning --out-dir>/ORPHANS.json --unresolved-file <provisioning --out-dir>/UNRESOLVED.json
```

**The null-identity REST case remains permanently unproven by this path** -- no ordinary Auth flow ever issues a subject-less session; see their module docstrings. This is a standing limitation, not a bug to fix: `role_fixture/probe.py` treats `TDP_F30_NULL_JWT` as OPTIONAL (see below) precisely so this one, permanently-unprovable case never blocks the 14 that can be proven.

There is no automatic target discovery and no marker creator for hosted environments. The local harness alone creates its marker. Before a future hosted run, a separately authorized operator must positively identify the new empty non-production project and then provision the owner-only `f30_test_control.marker` table with exactly one row and these text fields:

- `project_ref`: the verified replacement 20-character reference (not production, the deleted test ref/prefix or the local sentinel).
- `environment`: exactly `nonproduction-f30`.
- `database_name`: the verified current database name.
- `fixture_id`: exactly `F30_SYNTHETIC_ROLE_MODEL_V1`.

The marker table must be owned by the same operator that installs the fixture and must have no grants to other roles; its schema must be private. Do not infer non-production status from a SQL marker alone: an operator could label any database. Hostname/reference identification must occur independently **before connecting**. The SQL guard fails on missing, empty, duplicate, null, mismatched or untrusted markers and denied references. Install/reset/cleanup additionally require the operator's session to set `f30.expected_project_ref` to the already verified marker reference. No API caller supplies this setting or chooses financial context. The local sentinel is accepted only on a Unix-socket `frz_lab` database; the REST role probe refuses it entirely.

The parent production-probe command retains its original confirmation guards and adds `--role-model`. For this dry run only, its `TDP_PROD_PROJECT_REF`/URL/key variables refer to the verified **test** project. Additional allowlist variables are `TDP_F30_TEST_PROJECT_REF` (must match) and `TDP_F30_ENVIRONMENT=nonproduction-f30`. Before any request the companion requires all 14 `TDP_F30_ORG{1|2}_{ROLE}_JWT` variables (roles match uppercase topology identity names). **`TDP_F30_NULL_JWT` is OPTIONAL**, not required: if supplied it is validated with the exact same rigor as every other identity and its case runs normally; if absent, the 14 named identities still run (no assertion relaxed) and the result instead records `null_identity_status: "not_proven"` (with a fixed, quotable reason) rather than refusing the whole run. Claims must carry the exact deterministic subject (or no subject for null, when supplied), authenticated role and issuer matching the test reference. Payload decoding checks consistency only; the API verifies signatures. Tokens must be provisioned through the authorized test environment and kept only in the operator environment, never in repository files or evidence. The fixture itself creates no Auth users and no signing keys by default; `provision_auth_test_identities.py` is a drafted, offline-tested, NOT-yet-authorized-for-hosted-execution path that WOULD create real (persistent, so separately requiring `cleanup_auth_test_identities.py`) Auth users if ever run. A successful dry run's evidence carries an explicit top-level `role_model_summary` distinguishing `F30_ROLE_MODEL_FULLY_PROVEN` (14 identities + null case) from `F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN` (14 identities only) -- never a bare, ambiguous "PASS". Whether the replacement gateway permits the null-subject test JWT must be confirmed; direct SQL proves the database null-identity path locally, but a gateway rejection is not silently counted as a database pass.

The first REST request is read-only `f30_probe_context()` as owner. It must attest the exact fixture source and current seed/catalog hashes, matching non-production marker, and PostgreSQL 17.6 before any generic or role-model write. The companion runs 170 checks per phase. It stops on the first mismatch or breach, writes only enumerated codes/statuses to evidence, and instructs restoration. The operator/orchestrator remains responsible for immediate unfreeze, verification and cleanup; the REST probe never holds an operator credential.

Future order: positively identify target and empty-project baseline; provision trusted marker and synthetic Auth identities; install generic and role fixtures; capture counts/fingerprints and privileges; baseline; enable freeze including BOTH `public` and `f30_probe` in scope (review the owner-only control schema); pooled probe; recycle/new probe with disjoint backend identities; direct/pooler SQL probes where supported; verified disable; restored probe; compare privileges; guarded receipt reset; verify exact baseline; role cleanup; generic cleanup; confirm no orphan object, active run or temporary privilege; remove test marker/identities. Freeze metadata is restored audit history, not an active/abandoned run; retain or remove only under its separately reviewed cleanup procedure.

**Local fixture preparation can be READY; the hosted F-30 verdict remains BLOCKED** until a replacement target is created and identified, PostgreSQL 17.6/empty baseline verified, secure direct/pooler and REST credentials available, synthetic tokens provisioned, and a hosted restoration operator is present. No hosted or production connection is made by this preparation work. F-05, F-31 and conditional F-32 are unchanged; pg_cron absence alone is not an F-30 failure.
