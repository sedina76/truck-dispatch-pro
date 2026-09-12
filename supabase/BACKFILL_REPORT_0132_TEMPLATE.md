# Backfill report — 0132_load_carrier_and_trailer_scope

Fill in the blanks below using `VERIFY_0132_PREFLIGHT.sql` (before) and
`VERIFY_0132_POST_APPLY.sql` (after). This migration backfills exactly one
column: `trailers.ownership_scope`. It does **not** touch `loads`.

## Before apply (from VERIFY_0132_PREFLIGHT.sql context queries)

| Metric | Count |
|---|---|
| Trailers with a carrier (`carrier_id IS NOT NULL`) — will become `carrier` | ____ |
| Trailers with no carrier (`carrier_id IS NULL`) — will become `unresolved` | ____ |
| Total trailers | ____ |
| Dispatches referencing a soon-to-be-`unresolved` trailer | ____ |
| **ACTIVE** dispatches referencing a soon-to-be-`unresolved` trailer | ____ |

## Blast radius acknowledged

- [ ] The ACTIVE-dispatch count above was reviewed. If non-zero, those
      dispatches keep operating normally (the guard does not fire on
      unrelated UPDATEs), but that trailer **cannot be re-assigned** — to this
      dispatch or any other — until an owner/admin classifies it.
- [ ] No trailer with `carrier_id IS NULL` is silently being treated as an
      intentionally shared asset. `organization_shared` is **never** assigned
      by this migration (correction 10) — it is a deliberate zero count.

## After apply (from VERIFY_0132_POST_APPLY.sql)

| ownership_scope | Count |
|---|---|
| carrier | ____ |
| organization_shared | 0 (must always be 0 immediately after this migration) |
| unresolved | ____ |

## Follow-up required (separate, later action — not part of Phase 3A)

List every `unresolved` trailer an owner/admin should review and, where
appropriate, explicitly promote to `organization_shared`:

| trailer_id | unit_number | organization | reviewed by | decision | date |
|---|---|---|---|---|---|
| | | | | | |

Until reviewed, these trailers cannot be assigned to any dispatch
(`guard_dispatch_carrier_scope`, migration 0132).

## Sign-off

- Preflight run by: __________  Date: __________
- Migration applied by: __________  Date: __________
- Post-apply verified by: __________  Date: __________
