# Hosted (non-production) Supabase test plan for the database freeze -- NOT executed

**Gate:** the freeze must pass this plan on a SEPARATE hosted Supabase project before it is used on production. No production test substitutes for it.

## 0. What exists today (inspected read-only, no keys shown)
The repository configures exactly ONE Supabase project: `.env.local` -> host `zteixenjpcygjvznueuo.supabase.co`. It cannot be proven to be non-production (it is the project the local app talks to), so **no SQL was run against it**. A temporary project must be created first.

## 1. Create the temporary project (about 3 minutes, free plan is fine)
1. supabase.com -> Dashboard -> **New project**. Name it `tdp-freeze-test`. Any region. Set a database password (save it somewhere private -- do not send it to anyone).
2. Wait until the project is "healthy". Copy the **project reference** (the `xxxx` in `https://xxxx.supabase.co`) -- this is the only identifier I need.
3. Record whether **pg_cron** is installed. If absent, leave it absent for the no-cron path; a separate test with pg_cron installed is needed to prove cron pause and restore.
4. Confirm in Project Settings -> General that its reference is different from `zteixenjpcygjvznueuo` (production must never be used for this test).

## 2. What I need from you (no keys, no passwords)
* The new project reference (host name).
* The output of `01_discovery_readonly.sql` pasted from the test project's SQL Editor (it contains no secrets).
I will then return `02_enable_freeze.sql` filled in for that project. **You** run every SQL file in the test project's SQL Editor and keep the API keys to yourself: the REST probes below are `curl` commands you run locally; paste only the HTTP status codes and error text.

## 3. Test sequence (all on synthetic data)
1. `hosted_test/00_synthetic_fixture.sql`; if pg_cron is installed, schedule the probe cron job (the commented `cron.schedule` line) and note its job id.
2. `01_discovery_readonly.sql` -> save the output (the "before" record). Expected model: operator `postgres`, API login role `authenticator`, memberships to `anon/authenticated/service_role`, no `default_transaction_read_only` anywhere, the probe cron job listed if pg_cron is installed; otherwise no `cron.job` relation.
3. **Baseline writes work (also warms PostgREST's connection pool):** with the anon key: `POST {URL}/rest/v1/freeze_probe_items` body `{"note":"before"}` -> 201; `POST {URL}/rest/v1/rpc/freeze_probe_write` -> 200; count rows.
4. `02_enable_freeze.sql` (filled: operator role, major version, `FREEZE <db>`, roles `['authenticator']`, reviewed-other roles from discovery, cron pause = the probe job id and keep = other ids if installed; otherwise both arrays empty) -> result row `FROZEN`. Then `03_terminate_api_sessions.sql` -> `pre_freeze_sessions_remaining = 0`.
5. `04_verify_freeze.sql` -> `RESULT = PASS`. Its zero-row INSERT/UPDATE/DELETE and SECURITY DEFINER probes target `public.freeze_probe_items`, created by step 1. A missing fixture is a failure.
6. **End-to-end REST/RPC proof (new sessions are read-only; connection recycling worked):** `GET .../freeze_probe_items?select=id&limit=1` -> 200; `POST .../freeze_probe_items` -> **error, code 25006, "cannot execute INSERT in a read-only transaction"**; `PATCH` and `DELETE` -> same; `POST .../rpc/freeze_probe_write` -> same; repeat the insert with the **service_role** key -> same. Auth: sign in a test user from the dashboard's Auth page -> still works (Auth is a separate service).
7. **If pg_cron is installed, test cron pause:** note `select count(*) from public.freeze_probe_items;` -> wait 3 minutes -> unchanged. The job shows `active = false` in `cron.job`.
8. **Operator can migrate:** in the SQL Editor run a harmless write inside a transaction that you roll back (`begin; create table public.fz_op_check (x int); insert into public.fz_op_check values (1); rollback;`) -> succeeds (proves the SQL Editor is unaffected).
9. `05_disable_freeze.sql` -> `RESTORED`; `06_recycle_sessions_after_disable.sql` -> `read_only_sessions_remaining = 0`; `07_verify_disable.sql` -> all PASS. **Write probe:** repeat step 3 -> 201 / 200 (writes work again); if pg_cron is installed, after 2 minutes the count grows (cron resumed: job `active = true`).
10. Re-run `01_discovery_readonly.sql` and compare with step 2: identical settings/cron/membership sections (or the same absent-cron result) (exact restoration).
11. `hosted_test/99_synthetic_cleanup.sql`, then delete the temporary project.

## 4. Pass criteria / stop rules
Any deviation (unexpected role, prior setting, session, cron job, a write that succeeds during the freeze, a restore that differs from the saved discovery) = STOP and report; do not proceed to production. Things this plan specifically checks that the local simulation cannot: whether `postgres` may `ALTER ROLE authenticator SET ...` on hosted Supabase, whether it may terminate `authenticator` backends, and how the hosted pooler/PostgREST reconnect.
