# Database freeze tooling (PROPOSAL 0152, Option 4 -- database half) -- NOT executed against any real project

Purpose: while `MAINTENANCE_MODE=1` stops every application writer, this stops **everything that reaches the database through the API roles** (stale JWTs, direct PostgREST/RPC calls, the service key, SECURITY DEFINER RPCs) and pauses reviewed cron writers -- without touching the operator/SQL-Editor session, without changing any privilege, and fully reversibly.
Mechanism (validated on PostgreSQL 17.6 and 18.3): `ALTER ROLE <api login role> SET default_transaction_read_only = on` (+ terminating pre-freeze sessions). New sessions of that role cannot write; SELECT keeps working; the operator role is unaffected; `ALTER ROLE ... RESET` restores.

| file | what | changes anything? |
|---|---|---|
| `01_discovery_readonly.sql` | version, identity/privileges, login roles + memberships, prior settings, sessions by role/app/client, every pg_cron job, other scheduled writers, per-role "can I alter / terminate" | **no** (one SELECT) |
| `02_enable_freeze.sql` | validates (fail closed), records prior state in private schema `ops_freeze`, sets the read-only default on the listed API roles, pauses listed cron jobs | yes (single transaction) |
| `03_terminate_api_sessions.sql` | terminates ONLY pre-freeze sessions of the recorded frozen roles | sessions only |
| `04_verify_freeze.sql` | proof battery, one transaction ending in ROLLBACK, zero-row probes, temp objects only | **no** |
| `05_disable_freeze.sql` | restores the exact recorded prior state (roles, only the jobs it paused) | yes |
| `06_recycle_sessions_after_disable.sql` | terminates read-only sessions created during the freeze | sessions only |
| `07_verify_disable.sql` | catalog restoration check | **no** |
| `EMERGENCY_RECOVERY.md`, `HOSTED_TEST_PLAN.md`, `hosted_test/*` | manual recovery; hosted non-production gate + synthetic fixture/cleanup | -- |
| `tests_freeze.py` | local checks on a disposable PostgreSQL with simulated Supabase roles, both with and without a cron schema | disposable only |

## Safeguards (all covered by `tests_freeze.py`)
Empty/mismatching identities abort (operator, expected major version, typed confirmation `FREEZE <db>`, explicit role list). Never freezes: the operator, superusers, Supabase-internal roles, `anon/authenticated/service_role`. Aborts on any unexpected session role, any pre-existing `default_transaction_read_only` (role, database, global, role-in-database), any active cron job not explicitly classified, a listed job that is absent/inactive, or a freeze already active. Prior state is recorded before the first change; disable restores from that record and aborts (atomically) if a paused job was changed or re-activated meanwhile or if the restored setting differs from the record. No `DROP`, no `TRUNCATE`, no `DELETE`, no `GRANT`, and no `REVOKE` on any existing object (the only REVOKEs target the tooling's own new `ops_freeze` schema/tables); the only objects it creates are the private `ops_freeze` schema and temporary objects in the verification transaction.

## Honest limits
* Supabase-managed specifics are **not proven** until `HOSTED_TEST_PLAN.md` passes on a separate hosted project: permission for `postgres` to alter/terminate the `authenticator` role, hosted pooler behaviour, the real role names.
* A role-level setting cannot be observed from another session; the SQL proof plus the REST/RPC probe together prove "new sessions are read-only".
* Supabase Auth-internal and Storage-service writes use other roles and are outside these migrations' tables (disable sign-ups in the dashboard if zero writes are required).
* Order and stop rules: `../RUNBOOK_PRODUCTION_0130_0152_DRAFT.md`.
