-- 0172: Driver Portal "Forgot PIN" + phone numbers matched by digits.
--
-- 1. Phone matching. driver_portal_credentials.phone is stored exactly as
--    office staff typed it, and verify_driver_portal_login (0015) compared
--    it character-for-character -- so a driver typing 5551234567 could not
--    sign in to an account saved as "(555) 123-4567". Login now falls back
--    to comparing digits only (a leading US "1" is ignored), and only when
--    exactly one credential has those digits.
--
-- 2. Forgot PIN. A driver asks for a reset with their phone number; the app
--    emails a 6-digit code to the email on the driver's record (and tells
--    the office). The code is stored only as a bcrypt hash, expires after
--    15 minutes, allows 5 tries, and at most 3 codes can be requested per
--    driver per hour. Using it sets the new PIN, clears any lockout and
--    signs out the driver's other sessions. A deactivated portal login
--    (revoked by the office) can never be reset this way.
--
-- 3. Lockout fix. 0015's login recorded a wrong PIN (failed_attempts + 1,
--    lock after 5) and then RAISED invalid_credentials -- and raising rolls
--    back the whole call, including that update. So failed attempts were
--    never saved and the 5-try lockout never happened. A wrong PIN now
--    saves the attempt and returns no row (the login route already treats
--    "no row" as a failed sign-in). The reset-code check works the same way.
--
-- Every function here is for the server only (service role): not callable
-- by signed-out visitors or signed-in staff through the REST API.
-- Safe to run more than once.

-- ---------------------------------------------------------------------------
-- Phone key: digits only, US country code dropped.
-- ---------------------------------------------------------------------------
create or replace function public.driver_portal_phone_key(p_phone text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if length(d) = 11 and left(d, 1) = '1' then
    d := substr(d, 2);
  end if;
  return d;
end;
$$;

-- Finds the one credential for a typed phone number: exact match first
-- (unchanged behaviour), then a unique digits-only match.
create or replace function public.driver_portal_credential_for_phone(p_phone text)
returns public.driver_portal_credentials
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cred public.driver_portal_credentials;
  v_key text := public.driver_portal_phone_key(p_phone);
  v_count integer;
begin
  select * into v_cred from public.driver_portal_credentials where phone = trim(p_phone);
  if v_cred.driver_id is not null then
    return v_cred;
  end if;
  if length(v_key) < 7 then
    return null;
  end if;
  select count(*) into v_count from public.driver_portal_credentials c where public.driver_portal_phone_key(c.phone) = v_key;
  if v_count <> 1 then
    return null; -- none, or ambiguous: never guess between two drivers
  end if;
  select * into v_cred from public.driver_portal_credentials c where public.driver_portal_phone_key(c.phone) = v_key;
  return v_cred;
end;
$$;

-- ---------------------------------------------------------------------------
-- Login: same as 0015 except for the phone lookup above.
-- ---------------------------------------------------------------------------
create or replace function public.verify_driver_portal_login(p_phone text, p_pin text)
returns table (driver_id uuid, organization_id uuid, first_name text, last_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_cred public.driver_portal_credentials;
begin
  v_cred := public.driver_portal_credential_for_phone(p_phone);

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
    -- Return no row instead of raising: a raise would roll back the
    -- update above, and the attempt would never count toward the lockout.
    return;
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

-- ---------------------------------------------------------------------------
-- Reset codes. No RLS policies: only the SECURITY DEFINER functions below
-- (and the service role) can touch this table.
-- ---------------------------------------------------------------------------
create table if not exists public.driver_portal_pin_resets (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts integer not null default 0,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists driver_portal_pin_resets_driver_idx
  on public.driver_portal_pin_resets (driver_id, created_at desc);

alter table public.driver_portal_pin_resets enable row level security;
revoke all on public.driver_portal_pin_resets from anon, authenticated;

-- Starts a reset. Returns no row when the phone has no active portal login.
-- code is null when the driver already asked 3 times in the last hour.
create or replace function public.driver_portal_begin_pin_reset(p_phone text)
returns table (driver_id uuid, organization_id uuid, first_name text, last_name text, email text, code text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_cred public.driver_portal_credentials;
  v_recent integer;
  v_code text;
begin
  v_cred := public.driver_portal_credential_for_phone(p_phone);
  if v_cred.driver_id is null or not v_cred.is_active then
    return;
  end if;

  select count(*) into v_recent
    from public.driver_portal_pin_resets r
    where r.driver_id = v_cred.driver_id and r.created_at > now() - interval '1 hour';

  if v_recent < 3 then
    -- Uniform 000000-999999 from 4 random bytes (bias < 0.03%, irrelevant at 5 tries).
    v_code := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
    -- Only the newest code works.
    update public.driver_portal_pin_resets r set used_at = now()
      where r.driver_id = v_cred.driver_id and r.used_at is null;
    insert into public.driver_portal_pin_resets (driver_id, organization_id, code_hash, expires_at)
      values (v_cred.driver_id, v_cred.organization_id, crypt(v_code, gen_salt('bf')), now() + interval '15 minutes');
  end if;

  return query
    select d.id, d.organization_id, d.first_name, d.last_name, d.email, v_code
    from public.drivers d
    where d.id = v_cred.driver_id;
end;
$$;

-- Finishes a reset: checks the code, sets the new PIN, clears lockout,
-- signs out every existing session. Returns one row: error is null on
-- success, else invalid_code / code_expired / too_many_attempts /
-- invalid_pin. (Returned, not raised, so a wrong code's attempt is saved.)
drop function if exists public.driver_portal_finish_pin_reset(text, text, text);
create function public.driver_portal_finish_pin_reset(p_phone text, p_code text, p_new_pin text)
returns table (driver_id uuid, organization_id uuid, error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_cred public.driver_portal_credentials;
  v_reset public.driver_portal_pin_resets;
begin
  if p_new_pin is null or p_new_pin !~ '^[0-9]{4,6}$' then
    return query select null::uuid, null::uuid, 'invalid_pin'::text;
    return;
  end if;

  v_cred := public.driver_portal_credential_for_phone(p_phone);
  if v_cred.driver_id is null or not v_cred.is_active then
    return query select null::uuid, null::uuid, 'invalid_code'::text;
    return;
  end if;

  select * into v_reset from public.driver_portal_pin_resets r
    where r.driver_id = v_cred.driver_id and r.used_at is null
    order by r.created_at desc
    limit 1
    for update;

  if v_reset.id is null then
    return query select null::uuid, null::uuid, 'invalid_code'::text;
    return;
  end if;
  if v_reset.expires_at < now() then
    return query select null::uuid, null::uuid, 'code_expired'::text;
    return;
  end if;
  if v_reset.attempts >= 5 then
    return query select null::uuid, null::uuid, 'too_many_attempts'::text;
    return;
  end if;

  if p_code is null or v_reset.code_hash != crypt(trim(p_code), v_reset.code_hash) then
    update public.driver_portal_pin_resets r set attempts = r.attempts + 1 where r.id = v_reset.id;
    return query select null::uuid, null::uuid, 'invalid_code'::text;
    return;
  end if;

  update public.driver_portal_pin_resets r set used_at = now() where r.id = v_reset.id;

  update public.driver_portal_credentials c
    set pin_hash = crypt(p_new_pin, gen_salt('bf')),
        failed_attempts = 0,
        locked_until = null,
        updated_at = now()
    where c.driver_id = v_cred.driver_id;

  delete from public.driver_portal_sessions s where s.driver_id = v_cred.driver_id;

  return query select v_cred.driver_id, v_cred.organization_id, null::text;
end;
$$;

-- Server only.
revoke all on function public.driver_portal_credential_for_phone(text) from public, anon, authenticated;
revoke all on function public.driver_portal_begin_pin_reset(text) from public, anon, authenticated;
revoke all on function public.driver_portal_finish_pin_reset(text, text, text) from public, anon, authenticated;
grant execute on function public.driver_portal_credential_for_phone(text) to service_role;
grant execute on function public.driver_portal_begin_pin_reset(text) to service_role;
grant execute on function public.driver_portal_finish_pin_reset(text, text, text) to service_role;
