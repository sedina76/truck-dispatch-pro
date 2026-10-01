-- =============================================================================
-- VERIFY_0148_POST_APPLY.sql   -- READ-ONLY. Safe to run in production.
-- Every row must show ok = t.
-- =============================================================================
select check_name, ok from (
  select 'guard function blocks direct organization_id changes' as check_name,
         position('organization_id cannot be changed directly' in pg_get_functiondef('public.protect_profile_privileged_columns()'::regprocedure)) > 0 as ok
  union all
  select 'guard function scopes role changes to own organization',
         position('old.organization_id is distinct from public.current_org_id()' in pg_get_functiondef('public.protect_profile_privileged_columns()'::regprocedure)) > 0
  union all
  select 'trigger profiles_protect_privileged_columns is installed and enabled',
         exists (select 1 from pg_trigger t
                 where t.tgrelid = 'public.profiles'::regclass
                   and t.tgname = 'profiles_protect_privileged_columns'
                   and t.tgenabled = 'O'
                   and t.tgfoid = 'public.protect_profile_privileged_columns()'::regprocedure)
  union all
  select 'signup RPC still uses the bypass flag',
         position('app.bypass_profile_guard' in pg_get_functiondef('public.create_organization_with_owner(text,text)'::regprocedure)) > 0
) checks;
