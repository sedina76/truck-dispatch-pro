-- ---------------------------------------------------------------------------
-- Driver Portal: phone + PIN login for drivers (separate from Supabase Auth,
-- which is reserved for organization staff), plus live GPS location pings
-- reported from the driver's own phone browser while the portal is open.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- driver_portal_credentials: one row per driver who has been granted portal
-- access. phone is globally unique so login can look a driver up before any
-- org context is known. pin_hash is bcrypt (pgcrypto crypt/gen_salt('bf'))
-- and is never selectable by ordinary roles -- only the SECURITY DEFINER
-- functions below (which run as the table owner) can read it.
-- ---------------------------------------------------------------------------
create table public.driver_portal_credentials (
  driver_id uuid primary key references public.drivers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  phone text not null unique,
  pin_hash text not null,
  is_active boolean not null default true,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.driver_portal_credentials
  for each row execute function public.set_updated_at();

alter table public.driver_portal_credentials enable row level security;

create policy "org staff can view portal credential status"
  on public.driver_portal_credentials for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No insert/update/delete policy for any client role: writes only happen
-- through set_driver_portal_pin / revoke_driver_portal_access below.

-- A bare column-level REVOKE is a no-op here: Supabase grants blanket
-- table-level SELECT to authenticated/anon on every new table by default,
-- and that table-level grant subsumes any column, regardless of column-level
-- revokes. To actually hide pin_hash, revoke the table-level grant first,
-- then re-grant SELECT on only the non-sensitive columns.
revoke select on public.driver_portal_credentials from authenticated, anon;
grant select (driver_id, organization_id, phone, is_active, failed_attempts, locked_until, last_login_at, created_at, updated_at)
  on public.driver_portal_credentials to authenticated;

-- ---------------------------------------------------------------------------
-- driver_portal_sessions: server-issued session tokens. Only the hash of the
-- token is stored (sha256, computed in the app); the raw token lives only in
-- the driver's browser cookie. No RLS policies at all -- accessed exclusively
-- via the service_role key from trusted server-side route handlers, mirroring
-- app_encryption_keys elsewhere in this schema.
-- ---------------------------------------------------------------------------
create table public.driver_portal_sessions (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  token_hash text not null unique,
  user_agent text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index driver_portal_sessions_driver_id_idx on public.driver_portal_sessions (driver_id);

alter table public.driver_portal_sessions enable row level security;

-- ---------------------------------------------------------------------------
-- driver_locations: real GPS pings sent from the driver's phone browser
-- (Geolocation API) while the portal is open. One row per ping -- never
-- overwritten -- so dispatch can see a breadcrumb trail, not just a dot.
-- ---------------------------------------------------------------------------
create table public.driver_locations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  driver_id uuid not null references public.drivers (id) on delete cascade,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_meters numeric(8, 2),
  heading numeric(6, 2),
  speed_kph numeric(6, 2),
  recorded_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index driver_locations_org_driver_recorded_idx
  on public.driver_locations (organization_id, driver_id, recorded_at desc);

alter table public.driver_locations enable row level security;

-- Required for the dispatcher-side live map: Supabase only pushes
-- postgres_changes realtime events for tables explicitly added to this
-- publication.
alter publication supabase_realtime add table public.driver_locations;

create policy "org staff can view driver locations"
  on public.driver_locations for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No insert policy for client roles: pings are written by the report-location
-- route handler using the service_role key, after it has independently
-- verified the driver's portal session cookie server-side.

-- ---------------------------------------------------------------------------
-- set_driver_portal_pin: called by org staff (owner/admin/dispatcher) from
-- the driver detail page to grant or reset a driver's portal login.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- revoke_driver_portal_access: disables login and kills any live sessions.
-- ---------------------------------------------------------------------------
create or replace function public.revoke_driver_portal_access(p_driver_id uuid)
returns void
language plpgsql
security definer
set search_path = public
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

  update public.driver_portal_credentials set is_active = false, updated_at = now() where driver_id = p_driver_id;
  delete from public.driver_portal_sessions where driver_id = p_driver_id;
end;
$$;

grant execute on function public.revoke_driver_portal_access(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- verify_driver_portal_login: called by the /api/driver-portal/login route
-- handler (service_role key) after the caller submits a phone + pin. Not
-- dependent on auth.uid() -- the driver has no Supabase Auth session at all --
-- so this is callable by anon too, but the app only ever calls it server-side.
-- Locks the credential for 15 minutes after 5 consecutive failed attempts.
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
