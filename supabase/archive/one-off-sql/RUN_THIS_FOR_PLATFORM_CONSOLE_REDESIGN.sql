-- =============================================================================
-- 0045_platform_console_redesign.sql
-- Platform Console (Overview dashboard) redesign. This is a UI/analytics
-- pass over existing data -- almost everything is computed from
-- organizations/organization_subscriptions/subscription_plans/
-- billing_records, all already cross-tenant-readable by platform admins
-- via the 4 policies added in 0016_platform_admin.sql. Only two things
-- were genuinely missing from the existing schema, both added here in the
-- exact same security shape already established in 0016 -- nothing here
-- weakens tenant RLS or grants platform admins broad row-level access to
-- operational data.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. get_platform_operational_snapshot(): the platform-wide analog of the
-- existing get_org_usage_counts(p_org_id) -- same pattern (SECURITY
-- DEFINER, is_platform_admin() gate, counts only, never raw rows),
-- just summed across every tenant instead of one. dispatches/invoices
-- have no platform-admin RLS path today (deliberately, per 0016's own
-- comment) -- this is the narrow, count-only way to power the "Right Now"
-- panel without adding a broad cross-tenant SELECT policy on operational
-- tables.
-- ---------------------------------------------------------------------------
create or replace function public.get_platform_operational_snapshot()
returns table (active_users bigint, live_dispatches bigint, open_invoices bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  return query
    select
      (select count(*) from public.profiles where is_active = true),
      (select count(*) from public.dispatches
         where status in ('assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded', 'en_route_to_delivery', 'at_delivery')),
      (select count(*) from public.invoices where status not in ('paid', 'void'));
end;
$$;

grant execute on function public.get_platform_operational_snapshot() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Cross-tenant read on activity_logs for the Recent Platform Activity
-- feed -- identical shape to organizations_platform_admin_select /
-- profiles_platform_admin_select / billing_records_platform_admin_select
-- (0016). Additive only: the existing tenant-scoped activity_logs_select
-- policy (0010_rls_policies.sql) is untouched, so ordinary tenant users
-- see exactly what they always saw.
-- ---------------------------------------------------------------------------
create policy activity_logs_platform_admin_select on public.activity_logs
  for select using (public.is_platform_admin());
