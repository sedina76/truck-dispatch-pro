-- =============================================================================
-- ROLLBACK_0148_profile_cross_tenant_move_guard.sql
--
-- Restores the 0012 definition of protect_profile_privileged_columns().
-- WARNING: this RE-OPENS the cross-tenant takeover described in 0148.
-- Only use if 0148 demonstrably breaks a legitimate flow, and re-apply a
-- corrected fix promptly.
-- =============================================================================

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
