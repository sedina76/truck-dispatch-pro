-- =============================================================================
-- 0148_profile_cross_tenant_move_guard.sql
--
-- SECURITY FIX -- cross-tenant takeover via profiles_update_self.
--
-- The problem (proven on a disposable database built from 0001..0119):
--   0012's protect_profile_privileged_columns() lets organization_id / role
--   change whenever the acting user has_role(owner/admin) -- in THEIR OWN
--   current organization -- without checking WHERE the row is moving to.
--   Every self-service signup becomes 'owner' of the org it just created via
--   create_organization_with_owner(). So any brand-new signup could run
--     update profiles set organization_id = '<victim org uuid>', role = 'owner'
--      where id = auth.uid();
--   (allowed by profiles_update_self: USING/CHECK id = auth.uid()) and
--   instantly become owner of the victim organization, with full RLS access
--   to its loads, carriers, invoices, documents, etc. Organization ids are
--   not secret: every stored document path starts with the org id, so they
--   appear in document links shared with brokers, carriers and drivers.
--
-- The fix (same function name/signature, CREATE OR REPLACE, trigger unchanged):
--   * organization_id may NEVER change through a direct UPDATE. The only
--     sanctioned paths -- create_organization_with_owner (0012) and the
--     platform_* SECURITY DEFINER functions (0046) -- already set
--     app.bypass_profile_guard and keep working unchanged.
--   * role may change only when the acting user is owner/admin AND the
--     target row belongs to the acting user's own current organization.
--     This preserves Settings -> Users role changes (updateUserRole) exactly.
--   * The bypass flag must be exactly 'true' (unchanged semantics).
--
-- Audited application code (src/): no code path changes
-- profiles.organization_id with a direct UPDATE; the only direct privileged
-- column write is updateUserRole() (role, same org) -- still allowed.
--
-- Not changed here (product decision, flagged separately): an admin may
-- still set any role, including 'owner', inside their own organization.
--
-- Migrations 0001-0147 untouched. No data changes. Idempotent.
-- Rollback: supabase/ROLLBACK_0148_profile_cross_tenant_move_guard.sql
-- Test:     supabase/TEST_0148_profile_cross_tenant_move_guard.sql
-- =============================================================================

do $$
begin
  if to_regprocedure('public.protect_profile_privileged_columns()') is null then
    raise exception '0148 precondition failed: public.protect_profile_privileged_columns() does not exist (0012 not applied?)';
  end if;
  if not exists (
    select 1 from pg_trigger t
    where t.tgrelid = 'public.profiles'::regclass
      and t.tgname = 'profiles_protect_privileged_columns'
      and not t.tgisinternal
  ) then
    raise exception '0148 precondition failed: trigger profiles_protect_privileged_columns is missing on public.profiles';
  end if;
  if to_regprocedure('public.current_org_id()') is null
     or to_regprocedure('public.has_role(public.org_role[])') is null then
    raise exception '0148 precondition failed: current_org_id() / has_role(org_role[]) missing';
  end if;
  raise notice '0148 PHASE 1 preconditions passed.';
end $$;

create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql
as $$
begin
  -- Trusted SECURITY DEFINER paths (signup, platform admin) opt in explicitly.
  if coalesce(current_setting('app.bypass_profile_guard', true), 'false') = 'true' then
    return new;
  end if;

  -- Moving a profile between organizations is never allowed by direct UPDATE,
  -- for anyone, regardless of role. (Closes the cross-tenant takeover.)
  if new.organization_id is distinct from old.organization_id then
    raise exception 'insufficient_privilege: organization_id cannot be changed directly'
      using errcode = '42501';
  end if;

  -- Role changes: owner/admin only, and only for a row in the acting user's
  -- own current organization.
  if new.role is distinct from old.role then
    if not public.has_role(array['owner', 'admin']::public.org_role[])
       or old.organization_id is null
       or old.organization_id is distinct from public.current_org_id()
    then
      raise exception 'insufficient_privilege: only owner/admin may change role, and only within their own organization'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- Trigger already points at this function (0012); re-assert it idempotently.
drop trigger if exists profiles_protect_privileged_columns on public.profiles;
create trigger profiles_protect_privileged_columns
  before update on public.profiles
  for each row execute function public.protect_profile_privileged_columns();

do $$ begin
  raise notice '0148 complete: profiles.organization_id can no longer be changed by direct UPDATE (bypass-flagged SECURITY DEFINER paths unchanged); role changes require owner/admin of the row''s own organization. Migrations 0001-0147 untouched.';
end $$;
