# supabase/

| Path | Purpose |
|---|---|
| `migrations/` | **Source of truth** for the database schema, applied in order. |
| `TEST_*.sql`, `TEST_*.sh`, `TEST_SUPPORT_*` | Database tests. Run them all with `bash supabase/ci/run-db-tests.sh` (CI runs this on every push). Never point them at a real database. |
| `VERIFY_<NNNN>_PREFLIGHT.sql` / `_POST_APPLY.sql` | Read-only checks to run in production before / after applying migration NNNN. |
| `ROLLBACK_<NNNN>_*.sql` | How to undo migration NNNN. |
| `PRODUCTION_PREFLIGHT_*`, `LOCK_ORDER_*.md`, `DEPLOYMENT_RUNBOOK_*.md`, `BACKFILL_REPORT_*` | Deployment notes and checklists for specific migration batches. |
| `ci/` | Throwaway-database tooling used by the test runner. |
| `seed/` | Local development seed data. |
| `archive/` | Historical one-off scripts. Nothing there needs to be run again. |

Note: migrations 0120+ check for live production data, so a brand-new empty
database can only be built from migrations up to 0119 (see `ci/`).
