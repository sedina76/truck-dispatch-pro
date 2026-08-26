-- =============================================================================
-- VERIFY_0106_PREFLIGHT.sql
-- Phase 2P.5A -- read-only preflight for
-- supabase/migrations/0106_operational_exceptions_grouped_security_invoker.sql.
-- Confirms the exact defect mechanism, PostgreSQL compatibility, and
-- records the three real production compliance exceptions' pre-apply
-- state. Every query here is a plain SELECT/introspection -- nothing here
-- mutates anything, and nothing here acknowledges/assigns/resolves any
-- exception row.
-- =============================================================================

-- 1. Live PostgreSQL server version -- security_invoker for views requires
-- PostgreSQL 15+. Do not assume; confirm.
select version();
select current_setting('server_version_num')::int as server_version_num;
-- Expected: server_version_num >= 150000 for ALTER VIEW ... SET
-- (security_invoker = true) to be a valid statement at all.

-- 2. Exact current view definition, owner, and reloptions (this is the
-- authoritative confirmation of the defect -- reloptions will NOT contain
-- "security_invoker=true" today).
select
  c.relname,
  pg_get_userbyid(c.relowner) as owner,
  c.reloptions,
  pg_get_viewdef(c.oid, true) as view_definition
from pg_class c
where c.relname = 'operational_exceptions_grouped' and c.relkind = 'v';
-- Expected: owner is the migration-runner role (typically a superuser or
-- privileged role, NOT a role subject to the org-scoped RLS policy);
-- reloptions is NULL or does not contain security_invoker=true.

-- 3. Current grants on the view.
select grantee, privilege_type from information_schema.role_table_grants
where table_name = 'operational_exceptions_grouped';
-- Expected: authenticated has SELECT (this is what makes the defect
-- reachable -- confirmed already reachable live, not merely theoretical).

-- 4. Base table RLS status and policies (must remain completely unchanged
-- by 0106 -- this migration touches the VIEW only).
select relname, relrowsecurity from pg_class where relname = 'operational_exceptions';
-- Expected: relrowsecurity = true (already confirmed correct behaviorally
-- via direct-table cross-org tests -- this is the authoritative row).

select policyname, cmd, qual from pg_policies where tablename = 'operational_exceptions';
-- Expected: exactly the one existing SELECT policy from 0063
-- ("org staff can view operational exceptions"), scoped to
-- organization_id = current_org_id() and has_role(['owner','admin','dispatcher']).

-- 5. Exhaustive live inventory of EVERY view in the public schema (not
-- just the one already known from migration history) -- confirms there is
-- no other authenticated-selectable view over an RLS-protected table that
-- could share this defect class. A repo-wide grep of every migration file
-- already found exactly one CREATE VIEW statement in this project's
-- entire history (operational_exceptions_grouped, 0063) -- this query is
-- the live-database confirmation of that same fact, in case anything was
-- ever created outside a tracked migration.
select
  v.table_name as view_name,
  pg_get_userbyid(c.relowner) as owner,
  exists (
    select 1 from information_schema.role_table_grants g
    where g.table_name = v.table_name and g.grantee = 'authenticated' and g.privilege_type = 'SELECT'
  ) as authenticated_select_granted,
  c.reloptions
from information_schema.views v
join pg_class c on c.relname = v.table_name and c.relnamespace = 'public'::regnamespace
where v.table_schema = 'public';
-- Expected: exactly one row -- operational_exceptions_grouped -- with
-- authenticated_select_granted = true and reloptions not containing
-- security_invoker=true. Any additional row here is new information this
-- preflight was specifically written to catch -- if one appears, STOP
-- before proceeding, per the task's own instruction to report a newly
-- found vulnerable view separately before widening 0106's scope.

-- 6. The three real production compliance exceptions -- read-only
-- snapshot, recorded (not mutated) immediately before 0106.
select id, organization_id, source_type, status, severity, title, first_detected_at, last_detected_at
from public.operational_exceptions
where source_type = 'compliance_item'
order by first_detected_at;
-- Expected: exactly 3 rows, status = 'open', severity = 'high' -- record
-- these exact ids for post-apply comparison.
