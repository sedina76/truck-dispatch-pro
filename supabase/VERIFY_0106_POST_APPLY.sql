-- =============================================================================
-- VERIFY_0106_POST_APPLY.sql
-- Phase 2P.5A -- read-only post-apply verification for 0106. Every query
-- here is a plain SELECT -- nothing here mutates, acknowledges, assigns,
-- or resolves any exception row. Full role/cross-org behavioral proof is
-- covered separately by a live TEST-2P5A-* acceptance script (session
-- clients per role), not by this file -- this file confirms the DDL
-- itself took effect and that nothing else moved.
-- =============================================================================

-- 1. security_invoker is now set.
select c.relname, c.reloptions
from pg_class c
where c.relname = 'operational_exceptions_grouped' and c.relkind = 'v';
-- Expected: reloptions contains "security_invoker=true".

-- 2. View definition/grouping/column logic is otherwise byte-identical to
-- before 0106 -- ALTER VIEW ... SET (security_invoker) changes only the
-- reloption, never the query itself, but confirm rather than assume.
select pg_get_viewdef('public.operational_exceptions_grouped'::regclass, true) as view_definition;
-- Expected: identical to the preflight's own query-2 result.

-- 3. Grants unchanged.
select grantee, privilege_type from information_schema.role_table_grants
where table_name = 'operational_exceptions_grouped';
-- Expected: identical to the preflight's own query-3 result (authenticated
-- SELECT still present -- 0106 does not revoke it, since legitimate
-- owner/admin/dispatcher access through the view is still required; RLS
-- now correctly filters it per-user instead of the grant alone gating it).

-- 4. Base table completely untouched.
select relname, relrowsecurity from pg_class where relname = 'operational_exceptions';
select policyname, cmd, qual from pg_policies where tablename = 'operational_exceptions';
-- Expected: both identical to the preflight's own query-4 results.

-- 5. The three real production compliance exceptions -- confirm identical
-- ids/organization/status/severity to the preflight snapshot (last_detected_at
-- may legitimately have advanced via the normal 5-minute cron tick -- that
-- is expected reconciliation behavior, not a mutation of substance).
select id, organization_id, source_type, status, severity, title
from public.operational_exceptions
where source_type = 'compliance_item'
order by first_detected_at;
-- Expected: same 3 ids/org/status/severity as the preflight's query 6.

-- 6. Confirm no other view was affected/created (0106 must touch exactly
-- one object).
select
  v.table_name as view_name,
  c.reloptions
from information_schema.views v
join pg_class c on c.relname = v.table_name and c.relnamespace = 'public'::regnamespace
where v.table_schema = 'public';
-- Expected: still exactly one row -- operational_exceptions_grouped, now
-- with security_invoker=true in reloptions.
