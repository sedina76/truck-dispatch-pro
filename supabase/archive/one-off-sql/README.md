# Archived one-off SQL (moved here 2026-10-01)

Historical scripts that were pasted into the Supabase SQL Editor by hand.
**Nothing here needs to be run again.** Kept for history only.

| Kind | What it was |
|---|---|
| `RUN_THIS_FOR_*.sql` (44) | Copy-paste versions of migrations. 43 are byte-for-byte identical to a file in `supabase/migrations/`; the migration is the source of truth. |
| `RUN_THIS_ONE_FOR_LOGIN.sql`, `apply_all.sql` | Early "apply everything" bundles from before migrations were applied one by one. |
| `FIX_*`, `REPAIR_*` | One-time data repairs for specific records (already applied). |
| `CLEANUP_*` | One-time test-data cleanups (already applied; see each file's header). |
| `VERIFY_<NAME>.sql` (no migration number) | One-time read-only audits for specific incidents. |

Do not run any of these against production without reading the file and
confirming it still matches the current schema.
