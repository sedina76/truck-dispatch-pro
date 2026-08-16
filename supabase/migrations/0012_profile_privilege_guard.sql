-- =============================================================================
-- 0012_profile_privilege_guard.sql
-- Closes a privilege-escalation gap in profiles_update_self (0010): that
-- policy only checks `id = auth.uid()`, with no column restriction, so as
-- written it would let any user set their OWN organization_id and role to
-- anything -- e.g. silently promoting themselves to 'owner', or jumping
-- into a different tenant's organization_id. Postgres RLS is row-level
-- only; it cannot express "this column may only change under condition X"
-- on its own. This migration adds that column-level guard via trigger, plus
-- the one sanctioned way to set organization_id/role during onboarding:
-- create_organization_with_owner().
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Guard trigger: organization_id / role may only change if the acting user
-- is already owner/admin of that row's (pre-update) organization, OR the
-- change is happening inside a trusted SECURITY DEFINER function that has
-- explicitly set the app.bypass_profile_guard session flag (see
-- create_organization_with_owner below).
-- ---------------------------------------------------------------------------
create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql
as $$
begin
  if (new.organization_id is distinct from old.organization_id or new.role is distinct from old.role)
     and coalesce(current_setting('app.bypass_profile_guard', true), 'false') <> 'true'
     and not public.has_role(array['owner', 'admin']::public.org_role[])
  then
    raise exception 'insufficient_privilege: only owner/admin may change organization_id or role';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_protect_privileged_columns on public.profiles;
create trigger profiles_protect_privileged_columns
  before update on public.profiles
  for each row execute function public.protect_profile_privileged_columns();

-- ---------------------------------------------------------------------------
-- Onboarding RPC: the only sanctioned path for a brand-new user (who has no
-- organization yet, hence no role to check) to create an organization and
-- become its owner. Runs both writes atomically and flips the session-local
-- bypass flag so the guard trigger above lets the self-assignment through.
-- ---------------------------------------------------------------------------
create or replace function public.create_organization_with_owner(
  p_name text,
  p_slug text
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if exists (select 1 from public.profiles where id = auth.uid() and organization_id is not null) then
    raise exception 'user already belongs to an organization';
  end if;

  insert into public.organizations (name, slug)
  values (p_name, p_slug)
  returning * into v_org;

  perform set_config('app.bypass_profile_guard', 'true', true);

  update public.profiles
  set organization_id = v_org.id,
      role = 'owner'
  where id = auth.uid();

  return v_org;
end;
$$;

grant execute on function public.create_organization_with_owner(text, text) to authenticated;

comment on function public.create_organization_with_owner is
  'Sole onboarding path for a new tenant: creates the organization and promotes the calling (org-less) user to owner. Invite-based joins for additional users are a later migration (see docs/PLAN.md).';
