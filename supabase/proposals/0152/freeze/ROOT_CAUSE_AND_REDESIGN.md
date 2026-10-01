# Root cause of the failed hosted freeze test, and the v2 redesign -- NOT APPROVED FOR PRODUCTION

Status: the v1 design (`ALTER ROLE authenticator SET default_transaction_read_only = on`) FAILED the hosted non-production test and is **superseded** (kept, unchanged and unusable, in `superseded_v1_role_default/`). The v2 design below passed the LOCAL disposable-PostgreSQL tests (`tests_freeze.py`, which does not prove hosted behaviour) AND a hosted NON-PRODUCTION test (PostgreSQL 17.6, pg_cron absent, pooled and new REST connections both proven by the external probe): see `HOSTED_TEST_RESULT_V2.md`. The pg_cron path is NOT HOSTED-TESTED, and this does not authorize production execution: production remains blocked pending independent PostgreSQL/Supabase DBA/security review and written Owner approval. The v1 root-cause hypotheses H1/H2 below remain UNRESOLVED (the hosted diagnostic was taken without the v1 setting present); the v2 design does not depend on them.

## 1. Facts, by evidence class
**A. Confirmed by the hosted test (your observations):** the role setting was present on `authenticator`; SQL probes run in the SQL Editor were blocked (25006); the operator stayed writable; a REST `GET` returned 200; a REST `POST` (publishable key) during the freeze returned **201** and inserted `id=2`; after restoration REST insert 201 and RPC 200.

**B. Confirmed locally on real PostgreSQL (`tests_freeze.py` section 1, PG18.3; these are documented core-PostgreSQL semantics, not hosted facts):**
1. A role-level setting applies to sessions that LOG IN as that role. `SET ROLE`/`SET LOCAL ROLE` does **not** apply the target role's own `ALTER ROLE ... SET` settings (test: `alter role anon set statement_timeout` is not seen after `set local role anon`).
2. `default_transaction_read_only` is only the DEFAULT for new transactions. A transaction that begins with `BEGIN ... READ WRITE` (or `SET TRANSACTION READ WRITE`) writes even when the default is `on`. Test: with `authenticator` at `default_transaction_read_only=on`, a plain transaction is blocked, but `begin isolation level read committed read write; set local role anon; insert ...` **succeeds**, a SECURITY DEFINER RPC in it also writes, and inside it `default_transaction_read_only=on` while `transaction_read_only=off`.
3. Inside such a transaction `session_user` remains the login role (`authenticator`) while `current_user` is the request role (`anon`/`authenticated`/`service_role`) or the definer's owner.
4. The v1 verifier's "simulated frozen session" (`SET LOCAL transaction_read_only = on`) blocks writes for ANY session whether or not any freeze exists (test: operator without any freeze is blocked by it).

**C. Hosted Supabase behaviour that is a HYPOTHESIS (not verified; do not rely on it):**
* **H1 (leading):** PostgREST opens its write transactions with an explicit READ WRITE mode, which overrides the login role's default (consistent with B2 and with the observed 201). Recalled from PostgREST's behaviour, **not verified from source in this environment**.
* H2: the setting never reached the serving backend (pooled/pre-existing backend kept alive, a pooler between PostgREST and Postgres, a session-level reset/override by platform code such as `supautils`, PostgREST configuration). Less likely: `03_terminate` reported zero pre-freeze sessions and the setting is a normal `pg_db_role_setting` row; but not excluded.
* H3: API-key routing (anon vs authenticated vs service_role) changes which login role is used. Believed false (all three arrive through `authenticator` + `SET ROLE`), unverified.
* H4: Supavisor/transaction pooling changes behaviour. Unverified; pool would only matter for connections created before the setting.

**D. Decisive hosted diagnostic (needs another hosted non-production run; read-only, no freeze needed):** `hosted_test/03_diagnostic_function.sql` + `api_freeze_probe.py --phase diag` calls a volatile read-only RPC through the real REST path and records `session_user`, `current_user`, `default_transaction_read_only` and `transaction_read_only`. Interpretation, run with the v1 setting temporarily on (test project only, then reset): `(on, off)` => H1 confirmed (override by READ WRITE); `(off, off)` => H2 (setting never reached the backend). **The v2 design does not depend on which is true:** a trigger fires whatever the transaction mode and whatever the pool did.

## 2. Why the v1 verifier (`04_verify_freeze.sql`) produced a false PASS
It checked (a) that the catalog row `authenticator: default_transaction_read_only=on` existed and (b) that no pre-freeze session was left, then **simulated** a frozen session with `SET LOCAL transaction_read_only = on` and showed that writes fail. (b)+(a) prove only that a setting exists; the simulation fails writes for every session regardless (B4), so it could not distinguish a working freeze from a non-working one. Its own header said the REST probe was mandatory, yet its last row still printed `RESULT = PASS`. It never observed the real API path (SQL Editor is `postgres`, a different login role and transaction mode). 16/16 was therefore a tautology. Fixes: no simulation at all; the verifier's best verdict is `SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED`; only `api_freeze_probe.py` can print `FREEZE_PROVEN`.

## 3. v2 design (layered, fail-closed, reversible)
1. **Application:** `MAINTENANCE_MODE=1` (unchanged; 503 for every request incl. server actions/webhooks).
2. **Database write barrier:** one `BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE` **statement-level** trigger `"0_ops_freeze_block_writes"`, `ENABLE ALWAYS`, on EVERY table of the scope schemas (`public`). The function `ops_freeze_v2.block_writes()` (SECURITY DEFINER, pinned search_path, unreachable by API roles) raises `25006 TDP_MAINTENANCE_FREEZE: ...` unless **`session_user`** is in the recorded exempt list (the operator + superusers). It decides on `session_user` because that is the LOGIN role: `authenticator` for every REST request regardless of `SET ROLE`, and unchanged inside SECURITY DEFINER functions. Statement-level so zero-row `UPDATE/DELETE` and `INSERT ... ON CONFLICT` are blocked and no sequence value is consumed; sorted first (`0_`) so no other trigger runs.
3. **Scheduled writers:** reviewed `pg_cron` jobs paused via `cron.alter_job` (cron runs as the job owner, normally the exempt operator, so the trigger does NOT stop cron: pausing is required) and restored only if unchanged.
4. **Proof:** SQL layer (`04`) + mandatory external API probe (`api_freeze_probe.py`) covering anon/authenticated/service_role x POST/PATCH/DELETE/RPC, existing pooled and new connections; any 2xx write = breach.

### Alternatives considered (rollback / bypass risk)
| mechanism | verdict |
|---|---|
| `ALTER ROLE authenticator SET default_transaction_read_only` (v1) | **Rejected**: only a default; explicit READ WRITE overrides it (B2); failed hosted. |
| same setting on `anon`/`authenticated`/`service_role` | **Rejected**: `SET ROLE` does not apply the target role's settings (B1), so it has no effect on REST; managed roles, and Supabase may rewrite them. |
| `ALTER DATABASE ... SET default_transaction_read_only` | Rejected: same override; would also hit the operator and platform services. |
| `REVOKE INSERT/UPDATE/DELETE` from API roles | Rejected as primary: exact restoration of ACLs (grantors, column privileges, default privileges, Supabase re-grants) is error-prone; breaks reads through some functions; a permanent change if restore fails. |
| RLS "deny writes" restrictive policies | Rejected: `service_role` bypasses RLS; policy DDL on every table is heavier and not exact-restorable. |
| Event trigger to cover new tables automatically | Not relied on: creating event triggers needs superuser (hosted `postgres` is not); instead `03_refresh_coverage.sql` after each migration and `04` fails on any uncovered table. |
| PostgREST/Data-API switch in the Supabase dashboard | Optional extra layer, **hosted-only and unverified**; not part of the required design. |
| **Statement-level trigger on session_user (chosen)** | Immediate for all sessions incl. pooled; independent of transaction mode; catalog-only reversible (drop trigger); bypasses: superuser/table owner (exempt by design), `ALTER TABLE ... DISABLE TRIGGER` by an owner, tables created after the freeze until `03` runs, sequence/large-object/temp/NOTIFY side effects. |

### Threat model and residual risks (all listed in the runbook)
* A table created during the window is writable until `03_refresh_coverage.sql` runs (tested; the runbook runs it after every migration and `04` fails otherwise).
* `service_role`/`anon` can still call `nextval`/`setval`, `pg_advisory_lock`, `NOTIFY`, temp-table and large-object functions if privileges allow; none is business data.
* Writes to platform schemas (`auth`, `storage`, `realtime`, ...) by Supabase's own services are NOT covered (sign-in timestamps, storage objects): disable sign-ups/sign-ins in the Auth dashboard if zero writes are required.
* Owner/superuser sessions are exempt: the operator must not run business writes during the window.
* `CREATE TRIGGER` takes SHARE ROW EXCLUSIVE per table: a writer holding a lock makes enable abort after the 5 s `lock_timeout` (fail closed, nothing changed). In-flight transactions that already passed their statement keep their result.
* PostgreSQL version: local tests ran on 18.3, hosted is 17.6; the constructs used are unchanged across 14-18 but this is not tested on 17.6 here.

## 4. Handling of each writer path
| path | how it is handled |
|---|---|
| anonymous / authenticated / service-role REST POST, PATCH, DELETE | trigger on every scope table (session_user=authenticator is not exempt); proven locally, must be proven by the probe |
| RPC incl. writable SECURITY DEFINER | the underlying table write hits the trigger (session_user unchanged by SECURITY DEFINER) |
| existing pooled sessions / new sessions | statement-level, no session dependence; probe `--label pooled` before recycle, `--label new --compare-pids` after `07_recycle` |
| Server Actions, app API routes, webhooks | `MAINTENANCE_MODE` 503 first; if any slip through, their DB writes are blocked by the trigger |
| pg_cron / scheduled | jobs paused by id (reviewed list); listed, recorded, resumed only if unchanged |
| Supabase Auth / Storage / Realtime | not in scope of the trigger (platform schemas); documented residual; not altered |
| operator / SQL Editor migrations | exempt by `session_user`; `03_refresh_coverage.sql` after table-creating migrations |
| read-only REST | unaffected (probe requires GET 200 for anon and service_role) |
| restoration | `05` drops only the trigger, resumes only paused jobs; `06` + probe; exact catalog fingerprints (ACL, role settings) unchanged because nothing but the trigger and `ops_freeze_v2` is ever created |
