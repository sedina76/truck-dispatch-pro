-- =============================================================================
-- 0058_driver_phone_gps.sql
-- Phase 2A: Driver Phone GPS Tracking. Purely additive on top of the
-- already-existing driver_locations table/RLS/realtime publication
-- (0015_driver_portal.sql) and the already-existing /live-tracking page --
-- this does not rebuild or duplicate that, it fills the specific gaps:
-- a fast latest-location lookup, formal trip tracking sessions, and two
-- columns driver_locations didn't have yet.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- driver_locations: add truck_id (the dispatch's truck at ping time -- the
-- API route already resolves the active dispatch server-side, this just
-- keeps its truck alongside each ping without a join back through
-- dispatches every time) and altitude (browser-provided, optional, never
-- fabricated when the device doesn't report it).
-- ---------------------------------------------------------------------------
alter table public.driver_locations
  add column if not exists truck_id uuid references public.trucks (id) on delete set null,
  add column if not exists altitude numeric(8, 2);

create index if not exists driver_locations_dispatch_idx
  on public.driver_locations (dispatch_id);

-- ---------------------------------------------------------------------------
-- driver_latest_locations: one row per driver, upserted on every ping
-- (trigger below) so the Live Tracking page and Dispatch Drawer can read a
-- single indexed row instead of scanning/deduping driver_locations history.
-- Same RLS shape as driver_locations: org staff can SELECT, no client
-- write policy -- only ever written by the trigger (SECURITY DEFINER,
-- runs as the table owner) off a driver_locations insert that itself only
-- ever happens through the service-role API route.
-- ---------------------------------------------------------------------------
create table public.driver_latest_locations (
  driver_id uuid primary key references public.drivers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  truck_id uuid references public.trucks (id) on delete set null,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_meters numeric(8, 2),
  heading numeric(6, 2),
  speed_kph numeric(6, 2),
  altitude numeric(8, 2),
  recorded_at timestamptz not null,
  updated_at timestamptz not null default now()
);

create index driver_latest_locations_org_idx on public.driver_latest_locations (organization_id);
create index driver_latest_locations_dispatch_idx on public.driver_latest_locations (dispatch_id);

alter table public.driver_latest_locations enable row level security;

alter publication supabase_realtime add table public.driver_latest_locations;

create policy "org staff can view latest driver locations"
  on public.driver_latest_locations for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No insert/update/delete policy for client roles -- written only by the
-- trigger function below.

create or replace function public.sync_driver_latest_location()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.driver_latest_locations (
    driver_id, organization_id, truck_id, dispatch_id,
    latitude, longitude, accuracy_meters, heading, speed_kph, altitude, recorded_at, updated_at
  )
  values (
    new.driver_id, new.organization_id, new.truck_id, new.dispatch_id,
    new.latitude, new.longitude, new.accuracy_meters, new.heading, new.speed_kph, new.altitude, new.recorded_at, now()
  )
  on conflict (driver_id) do update set
    organization_id = excluded.organization_id,
    truck_id = excluded.truck_id,
    dispatch_id = excluded.dispatch_id,
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    accuracy_meters = excluded.accuracy_meters,
    heading = excluded.heading,
    speed_kph = excluded.speed_kph,
    altitude = excluded.altitude,
    recorded_at = excluded.recorded_at,
    updated_at = now()
  -- A ping that arrives out of order (rare, but possible with retried
  -- requests on a flaky mobile connection) must never regress the latest
  -- row backwards in time.
  where excluded.recorded_at >= driver_latest_locations.recorded_at;

  return new;
end;
$$;

create trigger driver_locations_sync_latest
  after insert on public.driver_locations
  for each row execute function public.sync_driver_latest_location();

-- ---------------------------------------------------------------------------
-- driver_tracking_sessions: the formal Start Trip / Stop Trip session,
-- distinct from a raw ping. A driver may have at most one 'active' session
-- at a time (partial unique index below) -- Start Trip creates/resumes it,
-- Stop Trip (or an automatic stop on Delivered) ends it. History is kept
-- (status moves to 'stopped'/'completed', never deleted) for the
-- trip-based, non-indefinite tracking model (spec section 15).
-- ---------------------------------------------------------------------------
create type public.driver_tracking_session_status as enum ('active', 'stopped', 'completed');

create table public.driver_tracking_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  driver_id uuid not null references public.drivers (id) on delete cascade,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  truck_id uuid references public.trucks (id) on delete set null,
  started_at timestamptz not null default now(),
  stopped_at timestamptz,
  status public.driver_tracking_session_status not null default 'active',
  last_location_at timestamptz,
  created_at timestamptz not null default now()
);

create index driver_tracking_sessions_org_idx on public.driver_tracking_sessions (organization_id);
create index driver_tracking_sessions_driver_idx on public.driver_tracking_sessions (driver_id);
create index driver_tracking_sessions_dispatch_idx on public.driver_tracking_sessions (dispatch_id);

-- Only one active session per driver, enforced at the database level (not
-- just in application code) -- a second concurrent "Start Trip" (e.g. two
-- open tabs) resumes the existing row rather than ever creating a second
-- active one.
create unique index driver_tracking_sessions_one_active_per_driver
  on public.driver_tracking_sessions (driver_id)
  where status = 'active';

alter table public.driver_tracking_sessions enable row level security;

create policy "org staff can view tracking sessions"
  on public.driver_tracking_sessions for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No client write policy -- created/updated only via driver-portal server
-- actions using the service-role key, after independently verifying the
-- driver's portal session server-side (same pattern as driver_locations).

comment on table public.driver_tracking_sessions is
  'Formal Start Trip / Stop Trip sessions. Trip-based, not indefinite: a driver is only tracked while an active dispatch exists AND they have explicitly started sharing (spec section 15) -- this table is what "started sharing" actually means, distinct from any single GPS ping.';
