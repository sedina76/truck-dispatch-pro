-- =============================================================================
-- VERIFY_0148_PREFLIGHT.sql   -- READ-ONLY. Safe to run in production.
--
-- Run BEFORE applying 0148. Looks for the fingerprints the cross-tenant
-- takeover would leave behind if anyone has already used it:
--   1. organizations with ZERO member profiles (an attacker's original,
--      now-abandoned signup org)
--   2. organizations with MORE THAN ONE owner (the attacker added as an
--      extra owner of the victim org), each owner listed for manual review
--   3. whether the 0148 fix is installed yet
-- None of these is proof by itself (a company may legitimately have two
-- owners, or an abandoned test org). Review each row by hand.
-- =============================================================================

-- 1. Organizations nobody belongs to
select 'EMPTY_ORG' as finding, o.id as organization_id, o.name, o.slug, o.created_at
from public.organizations o
where not exists (select 1 from public.profiles p where p.organization_id = o.id)
order by o.created_at desc;

-- 2. Organizations with more than one owner, with each owner listed
select 'MULTI_OWNER_ORG' as finding, o.id as organization_id, o.name,
       p.id as profile_id, p.email, p.full_name, p.created_at as profile_created_at,
       p.updated_at as profile_updated_at
from public.organizations o
join public.profiles p on p.organization_id = o.id and p.role = 'owner'
where (select count(*) from public.profiles q where q.organization_id = o.id and q.role = 'owner') > 1
order by o.name, p.created_at;

-- 3. Is the fix installed yet? (expect false before 0148, true after)
select 'FIX_0148_INSTALLED' as finding,
       position('organization_id cannot be changed directly' in pg_get_functiondef('public.protect_profile_privileged_columns()'::regprocedure)) > 0 as installed;
