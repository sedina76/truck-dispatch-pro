# F-30 hosted provisioning plan -- marker and test identities (NOT EXECUTED)

**This document and its three companion files (`provision_marker.sql`, `provision_marker_cleanup.sql`, `mint_identity_jwts.py`) make NO hosted connection and cause NO database
change by themselves.** Every SQL step here is inert text an authorized human operator must paste into a verified SQL Editor session by hand; the only script is
`mint_identity_jwts.py`, which runs entirely offline (standard library only, no network-capable import -- proven by its own `--self-check`, run and verified locally when this plan
was written) and writes files only to a directory outside this git repository. Nothing in this plan is run by any test, build step or CI in this repository. It exists so the
hosted procedure can be reviewed before an Owner authorizes it, closing the gap identified in the prior review of `role_fixture/README.md`.

## Observed key state for this project, and what it means (revision note)
As of this revision, the target project's own Settings -> API / JWT Signing Keys page shows: **current signing key = ES256 (NIST P-256 curve, asymmetric)**, **legacy JWT
secret = previously used** (not revoked). Read-only research against Supabase's own public documentation (cited throughout Step B and Step C below; no hosted connection was made
to reach these conclusions) establishes that **this state permanently and unconditionally blocks the self-signing approach Step B previously assumed**, regardless of the legacy
key's "previously used" (still-valid-for-verification) status -- extractability of a secret to sign something new, and continued acceptance of signatures the secret already
produced, are two different properties, and Supabase guarantees the first is gone forever once a project has touched the new signing-keys system at all. `mint_identity_jwts.py`
now enforces this unconditionally (`--current-key-algorithm` / `--legacy-secret-status`, no override flag exists for a migrated project) rather than offering a confirmation gate
that could not actually be satisfied. Step B and Step C below are revised accordingly: each case is either given the one supported way found by research, or marked BLOCKED with
the precise, cited reason. No key was rotated, no token was minted, and no hosted connection was made while producing this revision.

## Preconditions (must already be true; none of this plan does them)
1. A separately authorized operator has created a NEW, EMPTY, non-production Supabase project and has personally compared its reference against the Supabase dashboard
   URL/Settings -- never inferred from any SQL result, marker, or script output (SQL cannot know its own project ref).
2. The project runs PostgreSQL 17.6, is confirmed empty of the application schema, and has no pre-existing F-30 marker, fixture, or freeze -- verified with
   `target_preflight.py` (`confirm-target` then, after pasting `target_preflight_readonly.sql` by hand, `record-evidence`) in this directory, which itself makes no
   database write, no Auth-user creation, no probe run, and no hosted connection of any kind (see its own module docstring; proven offline by `--self-check`). It
   produces a timestamped, redacted evidence record with an explicit GO/STOP verdict, and STOPs (never proceeds) on any mismatch -- wrong PostgreSQL version, a
   non-empty `public` schema, or a pre-existing `f30_test_control`/`f30_probe`/`ops_freeze_v2` schema.
3. The operator has SQL Editor (owner) access to that project and, separately, its Project Settings -> API / JWT Keys page (for the JWT signing secret AND the signing-algorithm
   check used in Step B).

## Step A -- provision the marker (`provision_marker.sql`)
1. Open `provision_marker.sql`, replace the single placeholder `v_ref` with the verified 20-character reference from precondition 1, and paste the whole file into the SQL Editor
   of that verified project, as your own operator session (not under `SET ROLE`). It runs in one transaction and refuses (raises, creates nothing) if: the session is running
   under `SET ROLE` (`F30_OPERATOR_REQUIRED`, matching `fixture.sql`/`reset.sql`/`cleanup.sql`); the placeholder was left unedited; the reference is malformed; the reference is
   the production project, the deleted temporary test project, or the local-disposable-harness sentinel `localdisposablef30xx`; or `f30_test_control` already exists. It takes the
   SAME shared advisory lock (`303030157`) `fixture.sql`/`reset.sql`/`cleanup.sql` use, so it can never race one of those.
2. On success it creates schema `f30_test_control` and table `marker` with exactly one row (`project_ref`, `environment='nonproduction-f30'`, `database_name` read safely from
   `current_database()`, `fixture_id='F30_SYNTHETIC_ROLE_MODEL_V1'`), owned by the connecting operator role with no grants to any other role -- exactly what
   `f30_probe.check_target()` (`model.sql`) and every guarded script in this directory (`fixture.sql`, `reset.sql`, `cleanup.sql`) already require and enforce on every use.
3. Run the read-only verification query at the bottom of the same file and check every column by eye. Do not proceed to Step B until `no_grants_to_other_roles` and
   `owned_by_this_session` both read true.
4. Separately, the operator's own SQL Editor session must `set f30.expected_project_ref = '<the same verified reference>';` before running `fixture.sql`, `reset.sql` or
   `cleanup.sql` later (those files already check this setting; provisioning the marker does not set it, since it is a per-session, not a stored, value).
5. **Removal is last, not now.** `provision_marker_cleanup.sql` exists for the end of the whole exercise: it re-runs the SAME full guard `cleanup.sql` itself uses on this marker
   (operator identity, full reference/environment/database/fixture validation, ownership/ACL drift, the explicit `f30.expected_project_ref` match, and the shared advisory lock) --
   refusing if `f30_probe` still exists (the fixture's own `role_fixture/cleanup.sql` must run first) or the marker fails any of those checks -- then drops `f30_test_control
   restrict`. Do not run it until every other F-30 step -- generic probe cleanup included -- is complete and verified, per `README.md`'s own ordering.

## Step B -- the 14 test identities and their JWTs: SUPPORTED via ordinary Supabase Auth users (`provision_auth_test_identities.py`), not self-signed tokens
**Revision note (supersedes the self-signing approach below, which remains documented but is NOT the chosen path):** the deterministic-UUID requirement does not in fact require
producing an arbitrary-`sub` JWT by hand. `auth.admin.createUser`'s own `id` field lets an authorized caller pin a newly created Auth user's UUID at creation time (confirmed
against supabase-js's own types and Supabase's migration guidance), so an ordinary Auth user, created through the ordinary Admin API and signed in through the ordinary password
grant, can be given exactly the UUID `topology.json` already expects for each of the 14 identities -- no self-signed token, no key rotation, no hosted change to the project's
signing configuration at all. `provision_auth_test_identities.py` and `cleanup_auth_test_identities.py` (both in this directory) implement and locally self-test this path in
full:
- **Provisioning** (`provision_auth_test_identities.py provision --project-ref <ref> --confirm '...'`) creates each of the 14 identities with its pinned UUID, signs in as it to
  obtain a real, ordinary JWT, and writes each token to its own `0600` file in `--out-dir` (never to Git, never printed). It refuses to start while a prior run's
  `ORPHANS.json`/`UNRESOLVED.json` still has unresolved entries (see below), and it durably records the outcome of every attempt -- full or partial -- to
  `PROVISIONING_STATUS.json` in `--out-dir`, so a partial failure can never be mistaken for, or silently reported as, a completed run.
- **Accountable orphans:** if a create call succeeds but returns an id other than the one requested, the run stops immediately rather than losing track of the row. If the
  response's own email exactly matches what was requested, the row is provably this fixture's and is recorded to `ORPHANS.json` (cleanable with the companion
  `cleanup-orphans` subcommand, see below); if the email does not match either, ownership cannot be established from the response at all, and the row is instead recorded to a
  separate `UNRESOLVED.json` that no tool in this package ever auto-resolves or auto-deletes from -- clearing it is a deliberate, manual operator action, and the tool exits with
  a distinct code (3) so this case can never be conflated with an ordinary, actionable failure (exit 1).
- **Cleanup** (`cleanup_auth_test_identities.py cleanup ...`) fetches, verifies (exact id AND exact email, never id or email alone, never a fuzzy match), and only then deletes
  each of the 14 -- refusing the entire run at the first identity it cannot positively prove belongs to this fixture. A companion `cleanup-orphans` subcommand applies the same
  fetch-verify-delete discipline to an explicit `ORPHANS.json` list, and rewrites that file to reflect exactly what remains unresolved after every attempt (an empty list on full
  success). `--orphans-file`/`--unresolved-file` arguments on the main `cleanup` subcommand are **MANDATORY, not optional** -- argparse refuses to even parse a `cleanup`
  invocation missing either one, so the check itself can never be silently omitted -- and refuse to run at all while the file they point to still holds unresolved entries, so
  "cleanup complete" can never be declared while an orphan or an unresolved-ownership record from provisioning is still outstanding. The exact hosted command is:
  ```
  python3 cleanup_auth_test_identities.py cleanup --project-ref <ref> --confirm 'CLEANUP F30 AUTH USERS <same ref>' \
      --orphans-file <provisioning --out-dir>/ORPHANS.json --unresolved-file <provisioning --out-dir>/UNRESOLVED.json
  ```
  Neither file needs to already exist (a path with nothing recorded there is treated as resolved) -- but the flags themselves may never be left off.
- **What this path cannot produce, ever:** a `sub`-less ("null-identity") session. No ordinary Supabase Auth flow -- password, magic link, OTP, OAuth, or even anonymous sign-in
  -- issues a JWT with no subject, so this path has no way to prove the null-identity REST case; see Step C.

All of the above is implemented, self-tested offline (`--self-check` on both scripts; zero hosted requests, zero real tokens), and requires NO key rotation and NO change to this
project's signing configuration. **It is the drafted, offline-tested, structurally supported route for the 14 named identities -- it is not itself a hosted action, and running it
against a real project (creating real, persistent Auth users) still requires the same separate Owner authorization as any other hosted write in this plan; nothing here
authorizes that execution.**

**No Supabase Auth user would be created by the self-signing approach below, if it were ever used instead.** The synthetic model (`f30_probe.memberships`) is keyed only on
`auth.uid()`, i.e. the JWT's own `sub` claim, and never joins to `auth.users`; a self-signed token also carries no real Auth account behind it. That part of the original design is
unaffected by the key-state finding below -- what changed is HOW a JWT with an arbitrary `sub` COULD be produced at all, if this project ever needed that instead of the
ordinary-Auth-user path actually chosen above.

**Self-signing itself remains BLOCKED for this project, with a citation, not a guess -- this is why the ordinary-Auth-user path above is the supported route, not merely a
preference, whenever the 14 identities are eventually provisioned.** Supabase's own documentation states plainly: *"You can only extract the legacy JWT secret. Once you've moved to using the JWT signing
keys feature[,] extracting of the private key or shared secret from Supabase is not possible."* (Source 1, FAQ "Why is it not possible to extract the private key or shared
secret from Supabase?"). The observed state for this project -- current key ES256, legacy secret previously-used -- means the project HAS moved to the signing-keys system, so
neither the ES256 private key nor the legacy HS256 secret can be retrieved from the dashboard any more, regardless of the legacy key's signatures still being accepted for
verification (a documented, separate property: *"Both keys in the rotation[:] ... Rotation only changes the key used by Supabase Auth to create new JWTs, but the trust
relationship with both keys remains,"* Source 1, "Rotating and revoking keys"). There is therefore no secret this plan's own operator can obtain to sign a new HS256 token, and no
way to sign a new ES256 token without Supabase's own, never-exposed private key. `mint_identity_jwts.py mint` now refuses this unconditionally (`--current-key-algorithm ES256
--legacy-secret-status previously-used`, or any state other than `HS256`/`not-migrated`) -- there is no confirmation flag that could make this true, so none is offered.

**The one officially supported alternative (named exactly; NOT performed by this plan, requires a hosted connection and a real key rotation)**, per the same source's FAQ "How to
create (mint) JWTs if access to the private key or shared secret is not possible?":
1. `supabase gen signing-key --algorithm ES256` -- generates a brand-new private key **locally, offline**, ready to import.
2. Import that generated key as a new **standby** key on the SAME verified project's JWT Signing Keys dashboard page -- a **hosted write**.
3. Click **Rotate keys** to make it the **current** key -- a real **key rotation** of the project's actual signing configuration (the presently-observed ES256 key would move to
   "previously used"). The docs are explicit that a standby key's signatures are not yet trusted for verification; only after this rotation are they.
4. `supabase gen bearer-jwt --role authenticated --sub <uuid>` -- now signs **locally, offline** against the key from step 1, once step 3 has made it trusted, producing exactly
   the deterministic-`sub` tokens this fixture needs (the CLI's own example is `supabase gen bearer-jwt --role authenticated --sub ef0493c9-3582-425f-a362-aef909588df7`; `sub` is
   documented as an optional UUID, not tied to any real `auth.users` row, which matches this fixture's own no-real-user design).

Steps 2 and 3 are a **hosted connection** and a **key rotation** of this project's real, live signing configuration -- both explicitly out of scope for the read-only-research
task that produced this revision, and materially different in kind from everything else in this fixture (a real, permanent change to the project's actual security
configuration, not an additive synthetic object). **This plan does not authorize steps 2-3.** If an Owner separately decides to authorize them for F-30 purposes specifically, that
decision, its authorization and its evidence belong in a dedicated addendum to this plan, not folded silently into "provisioning as usual" -- record it there, then re-open Step B
with `--current-key-algorithm ES256 --legacy-secret-status previously-used` replaced by the NEW post-rotation state and `mint_identity_jwts.py` extended to support ES256 signing
(it does not today; adding that support was intentionally NOT done in this revision, since it would itself require testing against a real rotated key to trust, which this task's
constraints forbid).

## Step C -- the null-identity case: TDP_F30_NULL_JWT is OPTIONAL; the case itself remains NOT_PROVEN, not blocking
**Revision note:** the 14 named identities no longer depend on Step B's self-signing block at all (see above), so the null-identity case's status is now independent of that
block too, and no longer holds up the other 14. `role_fixture/probe.py`'s `validate_target()` requires only the 14 named tokens; `TDP_F30_NULL_JWT` is checked with the same
rigor ONLY if it is supplied, and its absence is recorded, explicitly, as `null_identity_status: "not_proven"` (with a fixed, quotable reason) in the probe's own result and in
`api_freeze_probe_production.py`'s evidence file -- never a silent omission, and never a reason to skip or weaken the 14 identities' own cases. The parent probe now also prints
and records an explicit top-level summary verdict distinguishing the two possible PASS outcomes: `F30_ROLE_MODEL_FULLY_PROVEN` (14 identities + the null case) versus
`F30_ROLE_MODEL_14_PROVEN_NULL_NOT_PROVEN` (14 identities only) -- see `role_fixture/probe.py`'s `summary_verdict()`.

The reason the null-identity case cannot be proven remains the same as previously documented: no ordinary Supabase Auth flow (password sign-in, magic link, OTP, OAuth, or even
anonymous sign-in) ever issues a session with no `sub` claim, so `provision_auth_test_identities.py`'s ordinary-Auth-user path (Step B) has no supported way to mint one. The
self-signing block below is an independent, secondary reason the same case would ALSO be blocked if self-signing were ever attempted instead -- not the primary one now that
Step B no longer depends on self-signing at all.

Independently of that block, and worth recording for whenever Step B's alternative is eventually authorized: Source 1's own JWT payload documentation lists `sub` as **"an
optional UUID"** among the three custom claims `gen bearer-jwt` needs (`sub`, `role`, `exp`) -- i.e. Supabase's own model already anticipates a `role=authenticated` token that
carries no subject at all, which is useful, positive evidence (not present in the earlier revision of this plan) that the null-identity shape is a legitimate, documented JWT
claim shape in Supabase's own system, not something this fixture invented. What the fetched documentation does **not** show is an actual `gen bearer-jwt` invocation with `--sub`
omitted on the command line -- only that the underlying JSON claim is optional -- so whether the CLI flag itself can simply be left off remains **UNCONFIRMED** until someone
actually tries it (which this revision does not do, and which in any case waits on the same blocked Step B prerequisite).

- **role_fixture/probe.py's own requirement has changed (superseding the previous revision's claim below):** `validate_target()` now requires only `required_token_names()` --
  the 14 named identities -- via `F30_REQUIRED_SYNTHETIC_IDENTITIES_MISSING`; `TDP_F30_NULL_JWT` is checked only if present. Leaving it unset no longer blocks the hosted
  role-model probe run at all -- the 14 identities' cases still run, evaluated with every existing assertion, and the run's result records `null_identity_status: "not_proven"`
  (plus a fixed reason) instead of refusing.
- **If Step B's alternative is ever authorized and executed**, the isolated-first-call procedure from the prior revision still applies before trusting a null-subject token for
  the full matrix: make exactly ONE isolated, read-only `f30_probe_action(..., 'preview', ...)` call with it (never `submit`/`issue`/anything that writes) and observe the raw
  HTTP status manually. A clean `{"code":"FORBIDDEN"}` at HTTP 200 (matching `f30_probe_action`'s own `u is null -> FORBIDDEN` branch) is the only basis for trusting it further;
  an outright gateway rejection (e.g. 401 before the function is reached) means the null-identity REST claim stays **NOT_PROVEN** permanently for this project shape -- never
  substitute a fabricated `sub`, which tests a different (impersonation) case, not this one.
- **The database-level proof needs none of this and is unaffected either way.** `role_fixture/tests.py` already proves the null-identity refusal directly over SQL, bypassing
  PostgREST/GoTrue entirely, on the disposable local cluster, regardless of anything above.

## Database-only hosted freeze probe (nonproduction F-30 only)

The dedicated `tdp-f30-test` database has no verified application deployment with `MAINTENANCE_MODE=1`. Do not use
`--i-confirm-maintenance-mode-is-on` unless that app setting has actually been deployed and verified. A separately
confirmed database/API-only path is available for a frozen F-30 role-model probe. It is valid only with `--role-model`,
`--phase frozen`, matching `TDP_PROD_PROJECT_REF`, `TDP_F30_TEST_PROJECT_REF`,
`TDP_F30_ENVIRONMENT=nonproduction-f30`, all 14 named tokens, and a typed confirmation of exactly
`PROBE F30 DATABASE ONLY <ref>`. Add `--i-confirm-f30-database-only-freeze`; do not combine it with the app-maintenance
confirmation. The guard rejects the known production and forbidden test references before any request.

After the separate baseline and after the SQL-layer freeze has been enabled and verified, an operator can invoke the
existing API probe with `--role-model --phase frozen --label pooled --ref <verified-test-ref>
--confirm 'PROBE F30 DATABASE ONLY <verified-test-ref>' --i-confirm-f30-database-only-freeze` and an evidence
directory outside the repository. For `--label new`, add `--compare-pids <pooled-evidence-file>` as before. Prepare
the generic probe fixture immediately before the test window, have normal and emergency disable procedures ready,
and restore and clean up after both frozen runs. Do not enable the freeze on the basis of this text alone: confirm
current target and credentials, review the filled SQL, and keep the operator available to disable it immediately.

All generic and role-model case assertions remain in force. On frozen PASS the database-only path reports
`F30_DATABASE_FREEZE_PROVEN` and writes `probe_scope: "F30_NONPRODUCTION_DATABASE_ONLY"` and
`app_maintenance_mode: "NOT_TESTED"` in evidence. The role-model summary independently records whether 14 identities
passed with null identity NOT_PROVEN. This result proves only the listed database/API behavior; application maintenance,
the null-identity REST case, and production deployment approval remain unproven. A write breach still stops the run and
requires immediate restoration. The original production frozen path still requires its separate app-maintenance flag.

## What stays manual / explicitly out of scope for this plan
Positive project identification (precondition 1), the PostgreSQL-version/empty-baseline check (precondition 2), the actual hosted dry run and its evidence capture, and final
teardown ordering are all unchanged from `README.md`'s existing "Future order" list. Marker provisioning (Step A) is unaffected by the key-state finding and remains ready as
written. **Step B (the 14 named identities) is SUPPORTED and locally self-tested via `provision_auth_test_identities.py`/`cleanup_auth_test_identities.py` (ordinary Supabase
Auth users with pinned UUIDs) -- no key rotation, no self-signed token, no change to this project's signing configuration.** Step C (the null identity) remains permanently
NOT_PROVEN by any ordinary Auth flow and is recorded as such, explicitly, rather than blocking the other 14; the self-signing alternative (ES256 key generation + a real hosted
key rotation) is documented above as an independent, secondary route to the null case specifically, and remains explicitly NOT authorized by this plan.

## Sources
1. Supabase Docs, "JWT Signing Keys" -- https://supabase.com/docs/guides/auth/signing-keys (key states table, "Rotating and revoking keys", and the FAQ section quoted above).
