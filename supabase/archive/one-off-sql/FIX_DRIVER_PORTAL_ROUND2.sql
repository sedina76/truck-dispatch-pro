-- Round 2 fix, found via live testing:
--
-- 1) The column-level "revoke select (pin_hash) ... from authenticated"
--    from the original script was a no-op: Supabase grants blanket
--    table-level SELECT to authenticated/anon on every new table, and that
--    subsumes any column regardless of column-level revokes. To actually
--    hide pin_hash you must revoke the table-level grant, then re-grant
--    SELECT on only the safe columns.
--
-- 2) verify_driver_portal_login's RETURNS TABLE(driver_id uuid, ...) implicitly
--    declares "driver_id" as a PL/pgSQL variable, which collided with the bare
--    "driver_id" column reference in two UPDATE ... WHERE clauses, causing
--    "column reference driver_id is ambiguous" on every login attempt.
--
-- Both are safe to run again.

revoke select on public.driver_portal_credentials from authenticated, anon;
grant select (driver_id, organization_id, phone, is_active, failed_attempts, locked_until, last_login_at, created_at, updated_at)
  on public.driver_portal_credentials to authenticated;

create or replace function public.verify_driver_portal_login(p_phone text, p_pin text)
returns table (driver_id uuid, organization_id uuid, first_name text, last_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_cred public.driver_portal_credentials;
begin
  select * into v_cred from public.driver_portal_credentials where phone = trim(p_phone);

  if v_cred.driver_id is null or not v_cred.is_active then
    raise exception 'invalid_credentials';
  end if;

  if v_cred.locked_until is not null and v_cred.locked_until > now() then
    raise exception 'account_locked';
  end if;

  if v_cred.pin_hash != crypt(p_pin, v_cred.pin_hash) then
    update public.driver_portal_credentials
      set failed_attempts = driver_portal_credentials.failed_attempts + 1,
          locked_until = case when driver_portal_credentials.failed_attempts + 1 >= 5 then now() + interval '15 minutes' else driver_portal_credentials.locked_until end,
          updated_at = now()
      where driver_portal_credentials.driver_id = v_cred.driver_id;
    raise exception 'invalid_credentials';
  end if;

  update public.driver_portal_credentials
    set failed_attempts = 0, locked_until = null, last_login_at = now(), updated_at = now()
    where driver_portal_credentials.driver_id = v_cred.driver_id;

  return query
    select d.id, d.organization_id, d.first_name, d.last_name
    from public.drivers d
    where d.id = v_cred.driver_id;
end;
$$;

grant execute on function public.verify_driver_portal_login(text, text) to anon, authenticated;
