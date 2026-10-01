# Database freeze v2 (PROPOSAL 0152, Option 4 -- database half) -- NOT APPROVED FOR PRODUCTION, not executed against any production project

**Hosted status (recorded from the operator's report, see `HOSTED_TEST_RESULT_V2.md`):** the v2 trigger freeze PASSED a hosted NON-PRODUCTION test on PostgreSQL 17.6 with pg_cron ABSENT; both pooled and new REST connection paths were proven by the external probe (SQL-only verification is not accepted as proof). The pg_cron path is NOT HOSTED-TESTED. **This does not authorize production execution: production remains blocked pending independent PostgreSQL/Supabase DBA/security review and written Owner approval.**

The v1 role-default design failed the hosted non-production test (a REST insert succeeded during the freeze); see `ROOT_CAUSE_AND_REDESIGN.md`. v1 is preserved in `superseded_v1_role_default/` (DO NOT RUN). v2 = a statement-level write-barrier trigger keyed on `session_user`, plus reviewed cron pauses, plus an external API probe that is the ONLY thing that can call the freeze proven.

| file | what | changes anything? |
|---|---|---|
| `01_discovery_readonly.sql` | identity, roles, memberships, settings, sessions, cron, table/schema/trigger inventory | no (one SELECT) |
| `02_enable_freeze.sql` | fail-closed validation, private `ops_freeze_v2` state, one trigger per scope table, reviewed cron pauses | yes (one transaction) |
| `03_refresh_coverage.sql` | cover tables created since the freeze (run after every table-creating migration) | yes (triggers only) |
| `04_verify_freeze_sql_layer.sql` | installed/complete/functional checks; ends in ROLLBACK; **verdict can never be a freeze proof** | no |
| `05_disable_freeze.sql` | drop the trigger, resume only paused cron jobs | yes |
| `06_verify_disable.sql` | catalog restoration check (one SELECT) | no |
| `07_recycle_api_sessions_optional.sql` | hosted-test helper: end idle `authenticator` sessions so "new connections" can be probed | sessions only |
| `EMERGENCY_UNFREEZE.sql`, `EMERGENCY_RECOVERY.md` | stateless recovery | yes (drops triggers) |
| `hosted_test/` | synthetic fixture (+ diagnostic RPC, baseline fingerprint, cleanup), `api_freeze_probe.py`, the two FILLED scripts for `tdp-freeze-test` | test project only |
| `tests_freeze.py` | local disposable-PostgreSQL + mock-server tests | disposable only |
| `HOSTED_TEST_PLAN.md`, `HOSTED_TEST_RESULT_V2.md`, `ROOT_CAUSE_AND_REDESIGN.md` | the test sequence; the recorded hosted result; analysis and threat model | -- |

Never touched: any role, role setting, privilege, ACL, RLS policy, data, `pgbouncer`/platform role. Order and stop rules for production: `../RUNBOOK_PRODUCTION_0130_0152_DRAFT.md`.
