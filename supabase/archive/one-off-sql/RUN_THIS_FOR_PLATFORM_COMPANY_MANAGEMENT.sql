-- =============================================================================
-- 0046_platform_company_management.sql
-- Platform Console company/admin management. Reuses the existing
-- organizations/profiles/auth.users schema entirely -- no new
-- credentials/profile/company tables. Every privileged write goes through
-- either a narrow RLS policy (simple, unguarded fields) or a SECURITY
-- DEFINER RPC that re-checks is_platform_admin() itself (never trusts
-- that the caller already passed the superadmin layout check), following
-- the exact pattern already established by create_organization_with_owner
-- (0012_profile_privilege_guard.sql) and get_org_usage_counts (0016).
--
-- KEY EXISTING MECHANISMS REUSED (confirmed live before writing this):
-- - profiles_protect_privileged_columns trigger (0012) already blocks ANY
--   direct UPDATE of profiles.organization_id/role unless the caller is
--   owner/admin of that row's CURRENT org, or the session-local
--   app.bypass_profile_guard flag is set -- exactly the mechanism a
--   platform admin (who belongs to no tenant org at all) needs to go
--   through deliberately, not around.
-- - organization_subscriptions.status is the REAL access-control gate
--   (src/lib/supabase/middleware.ts: BLOCKED_SUBSCRIPTION_STATUSES
--   includes 'paused') -- Activate/Suspend reuses the existing
--   updateOrgSubscription action and organization_subscriptions_
--   platform_admin_all policy (0016). No new status field invented.
-- - handle_new_user() (0009) already auto-creates a profiles row (org
--   null, role 'dispatcher') the instant an auth.users row is created --
--   including via the Admin API -- so creating a new tenant admin never
--   needs a manual profiles INSERT, only an UPDATE of the auto-created row.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. log_activity() 5-parameter overload (also shipped in
-- 0044_driver_portal_upgrade.sql, which may not be applied on this
-- database yet). Repeated here, identically, because this migration's own
-- audit logging depends on it -- a platform admin's own profile has
-- organization_id = null, so the 4-parameter version's current_org_id()
-- fallback fails exactly like it did for the driver-portal delivery bug.
-- Idempotent (create or replace); harmless if 0044 also defines it.
-- ---------------------------------------------------------------------------
create or replace function public.log_activity(
  p_entity_type public.entity_type,
  p_entity_id uuid,
  p_action text,
  p_changes jsonb default null,
  p_organization_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.activity_logs (organization_id, entity_type, entity_id, action, actor_id, changes)
  values (coalesce(p_organization_id, public.current_org_id()), p_entity_type, p_entity_id, p_action, auth.uid(), p_changes)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.log_activity(public.entity_type, uuid, text, jsonb, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Cross-tenant UPDATE for simple, unguarded fields. organizations had
-- only a SELECT policy (0016); profiles had none at all. Both are
-- additive -- existing tenant-scoped policies are untouched. The
-- privileged columns on profiles (organization_id, role) stay protected
-- regardless of this policy by the existing guard trigger above -- this
-- policy alone is NOT enough to change them, by design.
-- ---------------------------------------------------------------------------
create policy organizations_platform_admin_update on public.organizations
  for update using (public.is_platform_admin())
  with check (public.is_platform_admin());

create policy profiles_platform_admin_update on public.profiles
  for update using (public.is_platform_admin())
  with check (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. platform_create_organization_with_owner: the platform-admin analog of
-- create_organization_with_owner (0012), targeting an arbitrary existing
-- auth user (the new tenant's primary admin, already created via the
-- Admin API in application code) instead of auth.uid(). Same bypass-flag
-- technique, same "must not already belong to an org" safety check.
-- ---------------------------------------------------------------------------
create or replace function public.platform_create_organization_with_owner(
  p_name text,
  p_slug text,
  p_owner_user_id uuid
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if not exists (select 1 from public.profiles where id = p_owner_user_id) then
    raise exception 'owner profile not found';
  end if;

  if exists (select 1 from public.profiles where id = p_owner_user_id and organization_id is not null) then
    raise exception 'that user already belongs to an organization';
  end if;

  insert into public.organizations (name, slug)
  values (p_name, p_slug)
  returning * into v_org;

  perform set_config('app.bypass_profile_guard', 'true', true);

  update public.profiles
  set organization_id = v_org.id,
      role = 'owner'
  where id = p_owner_user_id;

  return v_org;
end;
$$;

grant execute on function public.platform_create_organization_with_owner(text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. platform_assign_user_to_org: for "Add Admin" to an EXISTING company --
-- the target auth user already exists (just created via the Admin API,
-- profile auto-created by handle_new_user with organization_id null) and
-- is being attached to a specific org with a specific role.
-- ---------------------------------------------------------------------------
create or replace function public.platform_assign_user_to_org(
  p_user_id uuid,
  p_org_id uuid,
  p_role public.org_role
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if not exists (select 1 from public.organizations where id = p_org_id) then
    raise exception 'organization not found';
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'user profile not found';
  end if;

  if exists (select 1 from public.profiles where id = p_user_id and organization_id is not null and organization_id <> p_org_id) then
    raise exception 'that user already belongs to a different organization';
  end if;

  perform set_config('app.bypass_profile_guard', 'true', true);

  update public.profiles
  set organization_id = p_org_id,
      role = p_role
  where id = p_user_id;
end;
$$;

grant execute on function public.platform_assign_user_to_org(uuid, uuid, public.org_role) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. platform_is_last_owner: shared last-owner check, used by both the
-- role-change and deactivate flows (spec: "Protect against accidental
-- removal of the company's final owner").
-- ---------------------------------------------------------------------------
create or replace function public.platform_is_last_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    p.role = 'owner'
    and (
      select count(*) from public.profiles p2
      where p2.organization_id = p.organization_id and p2.role = 'owner' and p2.id <> p.id
    ) = 0
  from public.profiles p
  where p.id = p_user_id and p.organization_id is not null;
$$;

grant execute on function public.platform_is_last_owner(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. platform_update_user_role: role changes only (organization_id
-- untouched) -- last-owner-protected.
-- ---------------------------------------------------------------------------
create or replace function public.platform_update_user_role(
  p_user_id uuid,
  p_role public.org_role
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if p_role <> 'owner' and public.platform_is_last_owner(p_user_id) then
    raise exception 'cannot change role: this user is the only owner of their organization';
  end if;

  perform set_config('app.bypass_profile_guard', 'true', true);

  update public.profiles set role = p_role where id = p_user_id;
end;
$$;

grant execute on function public.platform_update_user_role(uuid, public.org_role) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. platform_set_user_active: deactivate/reactivate. is_active is not a
-- guarded column, so this could in principle go through the plain RLS
-- policy above -- it's still a dedicated function so the last-owner check
-- applies consistently to deactivation too, and so it's one auditable
-- entry point rather than a bare table write.
-- ---------------------------------------------------------------------------
create or replace function public.platform_set_user_active(
  p_user_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if not p_is_active and public.platform_is_last_owner(p_user_id) then
    raise exception 'cannot deactivate: this user is the only owner of their organization';
  end if;

  update public.profiles set is_active = p_is_active where id = p_user_id;
end;
$$;

grant execute on function public.platform_set_user_active(uuid, boolean) to authenticated;
