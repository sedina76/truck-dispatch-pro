-- =============================================================================
-- 0106_operational_exceptions_grouped_security_invoker.sql
-- Phase 2P.5A -- SECURITY REPAIR. Restores the querying user's own RLS/
-- privilege evaluation on public.operational_exceptions_grouped (0063).
--
-- DEFECT (confirmed live via 2P.5 acceptance testing, root-caused, not
-- assumed): the view was created in 0063 as a plain `create view ... as
-- ...`, and 0063's own comment claimed "Postgres evaluates RLS on the
-- underlying operational_exceptions table using the QUERYING role's own
-- permissions when a view is selected through PostgREST" -- this was
-- incorrect. Before PostgreSQL 15's security_invoker view option, a
-- view's underlying-table permission and row-level-security checks run
-- as the VIEW OWNER (the migration-runner role), not as the end user
-- issuing the query through PostgREST. Combined with the view's own
-- `grant select ... to authenticated` (also in 0063), this made every row
-- of operational_exceptions readable through this view by every
-- authenticated user of every organization and every role, completely
-- bypassing both the org-scoping and the owner/admin/dispatcher-only
-- policy the base table's RLS is supposed to enforce. Confirmed live:
--   - an unrelated organization's owner could read another organization's
--     exception rows (including the 3 real production compliance
--     exceptions) through this view.
--   - a same-org Viewer (a role the base table's policy explicitly
--     excludes) could read the org's exception rows through this view.
-- The RAW operational_exceptions table's own RLS was and remains correct
-- and unaffected -- confirmed via direct cross-org/cross-role tests
-- against it, both before and after this repair. Only the view was wrong.
--
-- FIX: PostgreSQL 15+'s security_invoker view option makes the view
-- evaluate permissions and RLS policies as the CALLING role, exactly what
-- 0063's own (incorrect) comment already assumed was happening. This is
-- the single correct, minimal fix -- no column, grouping logic, grant
-- (beyond what already existed), or base-table change is needed or made.
-- A live repo-wide audit (2P.5A) found this is the ONLY view that has
-- ever existed in this project's migration history -- there is no other
-- view to carry the same defect class.
-- =============================================================================

alter view public.operational_exceptions_grouped set (security_invoker = true);

comment on view public.operational_exceptions_grouped is
  'Phase 2E, security-invoker-repaired Phase 2P.5A. One row per operational INCIDENT (a dispatch''s compound OFF ROUTE + LATE collapses to one row here, led by the higher-severity exception), not one row per exception episode. exception_types carries every active type in the group, so filtering/labeling never depends on which one happens to be primary. security_invoker=true (0106) makes this view evaluate the underlying operational_exceptions table''s RLS policy (organization_id = current_org_id() and owner/admin/dispatcher role) as the QUERYING user, not the view owner -- 0063''s original comment claimed this was already the behavior; it was not, until this migration. group_key is dispatch_id for dispatch/load-scoped types, else a synthetic per-row key for source types that never compound (detention, compliance).';
