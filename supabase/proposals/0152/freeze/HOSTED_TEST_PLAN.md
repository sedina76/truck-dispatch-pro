# Hosted NON-PRODUCTION test plan for the v2 freeze -- EXECUTED once on the temporary project `tdp-freeze-test` (since deleted): PASSED for the pg_cron-ABSENT path; NOT APPROVED FOR PRODUCTION

**Hosted status (recorded from the operator's report, see `HOSTED_TEST_RESULT_V2.md`):** the v2 trigger freeze PASSED a hosted NON-PRODUCTION test on PostgreSQL 17.6 with pg_cron ABSENT; both pooled and new REST connection paths were proven by the external probe (SQL-only verification is not accepted as proof). The pg_cron path is NOT HOSTED-TESTED. **This does not authorize production execution: production remains blocked pending independent PostgreSQL/Supabase DBA/security review and written Owner approval.**

**Re-use:** this plan is the template for any further hosted test, in particular the REQUIRED separate **pg_cron** test if production discovery finds pg_cron installed or relevant cron jobs (create a NEW temporary project, enable pg_cron there, add a writing cron job, list its job id in `v_cron_pause_ids`, and add checks that the job is paused during the freeze (row count of its target unchanged over >= 3 minutes) and resumed only if unchanged after `05`).

**Gate:** v2 must pass this plan on the separate project before production is even considered. Never run anything here against `zteixenjpcygjvznueuo` (the probe refuses it). SQL results alone can never pass this plan: the external probe is the proof.
**Secrets:** keys live only in environment variables of your own terminal (use `read -s`), are never pasted into chat, never written to files. The probe prints only HTTP status codes and error text and scrubs any key-looking value.

## A. Preparation (one-time, non-mutating except where stated)
1. `hosted_test/00_synthetic_fixture.sql` (already applied earlier; re-run is idempotent), then `hosted_test/03_diagnostic_function.sql` (adds the read-only diagnostic RPC).
2. Create a synthetic test user in the test project (Dashboard -> Authentication -> Users -> Add user, e.g. `freeze-test@example.invalid`, any password kept private). No production user.
3. In a terminal (values never echoed):
   ```
   export TDP_PROJECT_URL='https://<test-ref>.supabase.co'      # ref must start with fjmrvvyjvqd
   read -s TDP_ANON_KEY; export TDP_ANON_KEY                     # publishable/anon key of the TEST project
   read -s TDP_SERVICE_KEY; export TDP_SERVICE_KEY               # secret/service_role key of the TEST project
   export TDP_USER_EMAIL='freeze-test@example.invalid'; read -s TDP_USER_PASSWORD
   export TDP_USER_JWT=$(curl -s -X POST "$TDP_PROJECT_URL/auth/v1/token?grant_type=password" -H "apikey: $TDP_ANON_KEY" -H 'Content-Type: application/json' -d "$(python3 -c 'import json,os;print(json.dumps({"email":os.environ["TDP_USER_EMAIL"],"password":os.environ["TDP_USER_PASSWORD"]}))')" | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'); unset TDP_USER_PASSWORD
   ```
   (Obtain the JWT BEFORE the freeze: signing in writes to Auth tables.)

## B. Diagnostic of the v1 failure (optional but recommended; read-only)
4. `python3 hosted_test/api_freeze_probe.py --phase diag` -> prints `session_user`, `current_user`, `default_transaction_read_only`, `transaction_read_only` seen by real REST requests (expect `authenticator`/request role, `off`/`off` with no setting present). To classify H1/H2 of `ROOT_CAUSE_AND_REDESIGN.md` you may, TEST PROJECT ONLY, run `alter role authenticator set default_transaction_read_only = on;`, restart nothing, run the diag again, then `alter role authenticator reset default_transaction_read_only;` and confirm with the discovery script. Skip this if you prefer; v2 does not depend on it.

## C. Baseline
5. `01_discovery_readonly.sql` (save the whole grid = "before"); `hosted_test/02_fixture_baseline_readonly.sql` (save row).
6. `python3 hosted_test/api_freeze_probe.py --phase baseline` -> `WRITES_WORK`, exit 0 (every write for anon/service_role/authenticated succeeds; it leaves only `probe-*` rows, removed by the DELETE test).
7. Re-run `02_fixture_baseline_readonly.sql` and note the new counts.

## D. Freeze and proof (STOP on the first failure)
8. `hosted_test/02_enable_freeze_FILLED_tdp-freeze-test.sql` -> `SQL_LAYER_ENABLED` (a `FREEZE REFUSED` means nothing changed: paste it back).
9. `04_verify_freeze_sql_layer.sql` -> verdict `SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED` (anything else: STOP).
10. **Existing pooled connections:** immediately `python3 hosted_test/api_freeze_probe.py --phase frozen --label pooled` -> must end `FREEZE_PROVEN`.
11. `hosted_test/07_recycle_api_sessions_FILLED_tdp-freeze-test.sql` (ends idle `authenticator` sessions only), then **new connections:** `python3 hosted_test/api_freeze_probe.py --phase frozen --label new --compare-pids ~/tdp-freeze-evidence/evidence_frozen_pooled_<time>.json` -> must end `FREEZE_PROVEN` (backends disjoint from step 10).
12. GET still reads (part of the probe). Operator writable: in the SQL Editor `begin; create table public.fz_op_check (x int); insert into public.fz_op_check values (1); rollback;` -> succeeds.
13. Coverage after a "migration": `begin;` is NOT used; instead run `create table public.fz_new_table (id int);` then `03_refresh_coverage.sql` then `04` (OK) and finally `drop table public.fz_new_table;`.
14. Observe >= 5 minutes: `02_fixture_baseline_readonly.sql` before and after must be identical (rows_md5, sequence_last_value).
**Breach rule:** if the probe prints `FREEZE_BREACH` (any 2xx write while frozen) or exits 3: the test FAILS; stop ALL migration activity; run `05_disable_freeze.sql` (or `EMERGENCY_UNFREEZE.sql`), `06_verify_disable.sql`, probe `--phase restored`; keep `~/tdp-freeze-evidence/*`; production approval is BLOCKED.
**Inconclusive rule:** `FREEZE_NOT_PROVEN` (exit 2: a write failed without the freeze marker, a role could not be tested, backends not disjoint) is NOT a pass: fix the cause and repeat from step 8.

## E. Restoration
15. `05_disable_freeze.sql` -> `SQL_LAYER_DISABLED` (`freeze_triggers_remaining = 0`); `06_verify_disable.sql` -> `SQL_LAYER_RESTORED__EXTERNAL_WRITE_PROBE_REQUIRED` (no migrations ran, so trigger/ACL fingerprints must be identical: `SQL_LAYER_RESTORED_BUT_FINGERPRINT_DIFFERS...` here means STOP).
16. `python3 hosted_test/api_freeze_probe.py --phase restored` -> `WRITES_WORK`.
17. Re-run `01_discovery_readonly.sql` and diff against step 5 (settings, memberships, sessions roles: identical apart from timestamps/pids); `02_fixture_baseline_readonly.sql` (ACL/owner/RLS hashes identical; counts changed only by probe writes).
18. `hosted_test/99_synthetic_cleanup.sql`; `unset TDP_ANON_KEY TDP_SERVICE_KEY TDP_USER_JWT`; delete the test user; delete the temporary project when finished.

## Pass criteria (all required)
Baseline writes work; frozen: `FREEZE_PROVEN` for `pooled` and for `new`; operator writable; GET readable; five-minute observation unchanged; disable verified; restored writes work; discovery before/after equal. Only then may the Owner consider (separately, in writing) a production plan. Items that remain hosted-only: everything in D and E steps that touch the real API, PostgREST's transaction mode (H1/H2), pooler behaviour, pg_cron pause (pg_cron is not installed on the test project; enable it in a further test if the cron path must be proven hosted).
