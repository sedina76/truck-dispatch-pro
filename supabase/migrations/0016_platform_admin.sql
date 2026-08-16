-- ---------------------------------------------------------------------------
-- Platform Admin: a user who operates the SaaS itself, sitting above every
-- tenant -- distinct from org_role, which is always scoped to one
-- organization (even 'owner' only owns their own org). Adds a cross-tenant
-- console: list every company, inspect/change their subscription plan and
-- status, and see basic usage counts, without opening operational tables
-- (loads, trucks, carriers, ...) to cross-tenant reads.
-- ---------------------------------------------------------------------------

-- platform_admins: membership table. No RLS policies at all -- checked
-- exclusively via is_platform_admin() below, mirroring the zero-policy
-- app_encryption_keys pattern used elsewhere in this schema.
create table public.platform_admins (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  created_at timestamptz not null default now()
);

alter table public.platform_admins enable row level security;

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.platform_admins where id = auth.uid());
$$;

grant execute on function public.is_platform_admin() to authenticated;

-- Admins can see who else is an admin (needed for the "Platform Admins" management
-- page) -- safe since only rows that already pass is_platform_admin() can read it.
create policy platform_admins_self_select on public.platform_admins
  for select using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Cross-tenant read access for the platform console.
-- ---------------------------------------------------------------------------
create policy organizations_platform_admin_select on public.organizations
  for select using (public.is_platform_admin());

create policy profiles_platform_admin_select on public.profiles
  for select using (public.is_platform_admin());

create policy organization_subscriptions_platform_admin_all on public.organization_subscriptions
  for all using (public.is_platform_admin()) with check (public.is_platform_admin());

create policy billing_records_platform_admin_select on public.billing_records
  for select using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- get_org_usage_counts: usage snapshot for the companies list/detail, without
-- granting platform admins broad cross-tenant SELECT on operational tables.
-- Defense in depth: checks is_platform_admin() itself rather than trusting
-- the caller to have already checked, since it's granted to `authenticated`.
-- ---------------------------------------------------------------------------
create or replace function public.get_org_usage_counts(p_org_id uuid)
returns table (user_count bigint, truck_count bigint, active_load_count bigint)
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
      (select count(*) from public.profiles where organization_id = p_org_id),
      (select count(*) from public.trucks where organization_id = p_org_id),
      (select count(*) from public.loads where organization_id = p_org_id
         and status in ('booked', 'dispatched', 'in_transit', 'at_pickup', 'at_delivery'));
end;
$$;

grant execute on function public.get_org_usage_counts(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- add_platform_admin / remove_platform_admin: manage the admin roster from
-- inside the console itself. Promoting requires the target to already have a
-- Supabase Auth account (an existing tenant user, or one created ahead of
-- time). The very first admin can't be added this way -- see the bootstrap
-- note in RUN_THIS_FOR_PLATFORM_ADMIN.sql / the accompanying chat message.
-- ---------------------------------------------------------------------------
create or replace function public.add_platform_admin(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  select id into v_user_id from auth.users where email = p_email;
  if v_user_id is null then
    raise exception 'no account found with that email';
  end if;

  insert into public.platform_admins (id, full_name)
  values (v_user_id, coalesce((select full_name from public.profiles where id = v_user_id), p_email))
  on conflict (id) do nothing;
end;
$$;

grant execute on function public.add_platform_admin(text) to authenticated;

create or replace function public.remove_platform_admin(p_admin_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if (select count(*) from public.platform_admins) <= 1 then
    raise exception 'cannot remove the last platform admin';
  end if;

  delete from public.platform_admins where id = p_admin_id;
end;
$$;

grant execute on function public.remove_platform_admin(uuid) to authenticated;
