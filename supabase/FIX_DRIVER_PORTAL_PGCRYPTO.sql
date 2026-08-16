-- Fix: pgcrypto's crypt()/gen_salt() live in the "extensions" schema on
-- Supabase, not "public". The two functions below need that schema on their
-- search_path to find them. Safe to run again even after the original
-- RUN_THIS_FOR_DRIVER_PORTAL.sql -- CREATE OR REPLACE FUNCTION does not
-- error if the function already exists, unlike CREATE TABLE.

create or replace function public.set_driver_portal_pin(p_driver_id uuid, p_phone text, p_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
begin
  if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
    raise exception 'not authorized';
  end if;

  select organization_id into v_org_id from public.drivers where id = p_driver_id;
  if v_org_id is null or v_org_id != public.current_org_id() then
    raise exception 'driver not found';
  end if;

  if p_phone is null or length(trim(p_phone)) < 7 then
    raise exception 'a valid phone number is required';
  end if;

  if p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'pin must be 4 to 6 digits';
  end if;

  insert into public.driver_portal_credentials (driver_id, organization_id, phone, pin_hash, is_active, failed_attempts, locked_until)
  values (p_driver_id, v_org_id, trim(p_phone), crypt(p_pin, gen_salt('bf')), true, 0, null)
  on conflict (driver_id) do update
    set phone = excluded.phone,
        pin_hash = excluded.pin_hash,
        is_active = true,
        failed_attempts = 0,
        locked_until = null,
        updated_at = now();
end;
$$;

grant execute on function public.set_driver_portal_pin(uuid, text, text) to authenticated;

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
      set failed_attempts = failed_attempts + 1,
          locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else locked_until end,
          updated_at = now()
      where driver_id = v_cred.driver_id;
    raise exception 'invalid_credentials';
  end if;

  update public.driver_portal_credentials
    set failed_attempts = 0, locked_until = null, last_login_at = now(), updated_at = now()
    where driver_id = v_cred.driver_id;

  return query
    select d.id, d.organization_id, d.first_name, d.last_name
    from public.drivers d
    where d.id = v_cred.driver_id;
end;
$$;

grant execute on function public.verify_driver_portal_login(text, text) to anon, authenticated;
