# PostgreSQL 17.6 compatibility review -- proposals 0149, 0150, 0151, 0152

**Status: EXECUTED on PostgreSQL 17.6** (official `postgres:17.6` container, Debian 17.6-2.pgdg13+1, aarch64-unknown-linux-gnu, `server_version_num = 170006`) in addition to 18.3. Results: 0149 78 ok / 0150 219 / 0151 78 / 0152 316 checks all pass, plus `pg17_probe.py` (explicit behaviour probe; 17.6 vs 18.3 diff below). The static table remains as the feature inventory.

## Features used by the production-facing SQL (proposed_*, preflight, post_apply, candidate_review, rollback)
| Feature (where) | Introduced | 17.6 | Note |
|---|---|---|---|
| `CREATE OR REPLACE FUNCTION` with `SECURITY DEFINER`, `SET search_path`, `plpgsql`, `constant` variables, `RAISE ... USING ERRCODE` (all) | <= 9.x | supported | |
| `to_regclass`, `to_regprocedure`, `to_regtype` (all) | 9.4 / 9.5 | supported | |
| `pg_get_function_arguments`, `pg_get_function_identity_arguments`, `pg_get_constraintdef`, `pg_get_triggerdef`, `obj_description` (0149-0152 verifiers) | <= 9.x | supported | `pg_get_constraintdef` text for CHECK/UNIQUE is compared in 0150/0151 preflights; the deparse format of `CHECK (... IS NULL OR ...)` and `UNIQUE (a, b)` is unchanged 17 -> 18 |
| `has_function_privilege(role_name, oid, 'execute')` with real role names (`authenticated`, `anon`, `service_role`) | 8.x | supported | **The `'public'` pseudo-role form was REMOVED from 0151/0152** (its support in `has_*_privilege` is not confirmed for 17); PUBLIC is now tested with `proacl IS NULL OR EXISTS (unnest(proacl) LIKE '=%')`, which is version independent |
| `unnest`, `string_agg(... ORDER BY)`, `count(*) FILTER (WHERE ...)`, `FULL JOIN ... USING`, `concat_ws`, `regexp_replace(..., 'g')`, `md5`, `format('%I %L')` | <= 9.4 | supported | |
| `row(...) IS DISTINCT FROM row(...)` (0150-0152) | 8.x | supported | |
| `jsonb_build_object`, `jsonb - text[]`, `jsonb ->>`, `to_jsonb(record)` | 9.5 / 10 | supported | |
| `query_to_xml(...)` + `xpath(...)` for per-table evidence counts (0150 verifiers/migration) | 8.3 | supported | read-only `SELECT count(*)` built with `format('%s ... %I ... %L')` from catalog-validated identifiers |
| `CREATE TEMP TABLE ... ON COMMIT DROP AS WITH ...` inside `DO` (0150-0152) | 8.x | supported | |
| `PERFORM ... ORDER BY ... FOR UPDATE`, `LOCK TABLE ... IN ACCESS EXCLUSIVE MODE` (0150, 0152) | 8.x | supported | requires table ownership -- the migration role owns these tables |
| `GET DIAGNOSTICS x = ROW_COUNT`, `pg_advisory_xact_lock`, `hashtextextended` (0152 bodies inherited from 0141-0146) | 9.x / 11 | supported | |
| `ALTER TABLE ... ADD COLUMN ... text NOT NULL` on an EMPTY table (0152) | 8.x | supported | succeeds without a default only while the table has zero rows -- exactly the invariant 0152 asserts under lock |
| `ALTER TABLE ... DROP COLUMN` (0152 rollback), `COMMENT ON COLUMN`, `REVOKE ... FROM service_role` | 8.x | supported | |
| `CREATE POLICY`, `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`, `GRANT SELECT` (0150 provenance table) | 9.5 | supported | |
| enum label `'archived_legacy'` on an existing enum (0150 uses, never adds it) | -- | supported | no `ALTER TYPE ... ADD VALUE` anywhere |

## Behavioural differences between 18.3 (tests) and 17.6 (production) that matter here
1. **NOT NULL constraints in the catalog.** PostgreSQL 18 records each NOT NULL as a `pg_constraint` row (`..._request_fingerprint_not_null`); 17 records it only in `pg_attribute.attnotnull`. The 0152 test
   tolerates 0 or 2 such constraint rows. Effects on 17: none for behaviour; the rollback still restores the exact prior schema (`DROP COLUMN`).
2. **Error text for a NOT NULL violation** is `null value in column "request_fingerprint" of relation "..." violates not-null constraint` in both versions (SQLSTATE 23502); the 0152 test matches the column name only.
3. **`pg_dump` output** differs by version (e.g. named NOT NULL lines in 18); dump comparisons in the harness are same-version only and are not a production check.
4. `psql` 18 client features are used only by the harness.

## Not used anywhere in the proposals (PG18-only features)
`uuidv7()`, virtual generated columns, `RETURNING OLD/NEW`, `NOT NULL ... NOT VALID`, temporal constraints, `MERGE ... RETURNING`, `regexp_instr` (harness only, PG 15+).

## Supabase-specific assumptions (independent of the server version)
* Function owner is `postgres` (non-superuser, BYPASSRLS): `CREATE OR REPLACE`, `REVOKE`, `LOCK TABLE`, `ALTER TABLE` all require ownership, which the SQL Editor role has for objects created by the migrations.
* Supabase's default privileges give `anon`, `authenticated`, `service_role` EXECUTE on new functions (0127). The scratch cluster now emulates this; 0151/0152 compare complete ACLs (`proacl`) before/after and never assume a role lacks EXECUTE.
* The SQL Editor runs each statement/batch under its own transaction handling: run every migration file as ONE batch (each file is a single `begin; ... commit;`).

## Executed findings (PostgreSQL 17.6 vs 18.3, `pg17_probe.py`)
Identical on both (23 probed facts): adding `text NOT NULL` without default succeeds on an empty table and fails on a non-empty one (`column ... contains null values`, 23502); inserting NULL raises 23502; `attnotnull = t` for both fingerprint columns; owner `postgres`, SECURITY DEFINER, `search_path = pg_catalog, public`, plpgsql for all 8 repaired functions; `CREATE OR REPLACE` keeps ACL/owner/comment; typed enum-array `= any(...)` works and `enum = text` fails with `operator does not exist: dispatch_status = text` (the 0149 defect signature); custom SQLSTATEs (`RRIDK`, `TSIDK`) raise and are caught; `lock_timeout` -> `55P03`; a second session's `pg_try_advisory_xact_lock` on a held key is false; a two-session advisory deadlock -> `40P01`; `pg_get_functiondef` header identical.
Differences: (1) **17 has no NOT NULL rows in `pg_constraint`** (18 records 2 for the new columns, `contype = 'n'`); the 0152 catalog comparison accepts 0 or 2 such rows. (2) **`pg_dump` 17 prints `request_fingerprint text NOT NULL`; 18 prints `... CONSTRAINT <name>_not_null NOT NULL`.** (3) 316 public functions on 17 vs 341 on 18 (extension functions from the platform's `pgcrypto` build; not from these proposals). (4) platform string only.
Harness differences found and fixed while running on 17.6 (no assertion weakened): `DROP DATABASE ... WITH (FORCE)` for disposable-database cleanup; the migration file is passed to psql as a FILE in the lock/race tests (a 90 KB pipe stalls when psql blocks inside the migration's lock wait; Linux pipes hold 64 KB); a Python 3.13 `Popen.communicate()` behaviour difference was shimmed inside the container only (`sitecustomize`, not in the repository).
