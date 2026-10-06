-- 0171: only the platform may change a company's billing access or suspension.
--
-- organizations_update (0010) lets a company's OWNER update their own
-- organizations row -- every column, including:
--   billing_required  false = free access, no subscription needed (0121)
--   is_active         false = suspended from the Platform Console
-- So an owner could call the REST API with their own login and give their
-- company free access, or undo a suspension. This trigger refuses any
-- change to those two columns unless the caller is a platform admin.
--
-- Not affected:
--   * Platform admins (Platform Console, organizations_platform_admin_update).
--   * Server code using the service role key, and the Supabase SQL editor:
--     neither carries a signed-in user (auth.uid() is null).
--   * Normal company-settings saves: they don't change these columns, and
--     an unchanged value is not a change.
--
-- Safe to run more than once.

create or replace function public.guard_platform_controlled_org_flags()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.billing_required is distinct from old.billing_required
      or new.is_active is distinct from old.is_active)
     and auth.uid() is not null
     and not public.is_platform_admin() then
    raise exception 'Only the platform can change billing access or suspension for a company.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.guard_platform_controlled_org_flags() is
  'Blocks non-platform-admin users from changing organizations.billing_required / is_active (0171).';

drop trigger if exists organizations_guard_platform_controlled_flags on public.organizations;
create trigger organizations_guard_platform_controlled_flags
  before update on public.organizations
  for each row
  execute function public.guard_platform_controlled_org_flags();
