-- =============================================================================
-- 0059_gps_geofence_detention.sql
-- Phase 2B: GPS Geofencing + Automatic Arrival + Detention Automation.
-- Purely additive on top of 0057 (dispatch operational timestamps + org
-- detention free-time settings) and 0058 (driver phone GPS). Does not
-- modify, drop, or rename anything from either migration. dispatch_status
-- is NOT modified: every transition this feature makes uses a value that
-- already exists on it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Stop coordinates. A geofence needs latitude/longitude; not every load_stop
-- has them today (most were entered as city/state text only). Automatic
-- geofence logic simply stays disabled for a stop until coordinates exist --
-- see resolveStopCoordinates() in the app layer. geocode_source records how
-- the coordinates got there ('manual' for now; the app layer's
-- resolveStopCoordinates() boundary is where a real geocoding provider would
-- plug in later without a second migration).
-- ---------------------------------------------------------------------------
alter table public.load_stops
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists geocoded_at timestamptz,
  add column if not exists geocode_source text;

alter table public.load_stops
  add constraint load_stops_latitude_check check (latitude is null or latitude between -90 and 90),
  add constraint load_stops_longitude_check check (longitude is null or longitude between -180 and 180);

comment on column public.load_stops.latitude is 'Optional. Geofence automation for this stop stays disabled while null -- never fabricated from city/state alone.';
comment on column public.load_stops.geocode_source is 'How latitude/longitude got here, e.g. ''manual''. No geocoding provider is called automatically by this migration or the app code it ships with.';

-- ---------------------------------------------------------------------------
-- Org-level geofence radius + automation mode. Centralized settings, not
-- hard-coded per file -- src/lib/tracking/geofence.ts reads these instead of
-- carrying its own copy of the numbers.
-- ---------------------------------------------------------------------------
create type public.gps_automation_mode as enum ('off', 'suggest', 'automatic');

alter table public.organizations
  add column if not exists pickup_geofence_radius_m integer not null default 300,
  add column if not exists delivery_geofence_radius_m integer not null default 300,
  add column if not exists gps_automation_mode public.gps_automation_mode not null default 'suggest';

alter table public.organizations
  add constraint organizations_geofence_radius_check
    check (pickup_geofence_radius_m > 0 and delivery_geofence_radius_m > 0);

comment on column public.organizations.gps_automation_mode is 'off = no GPS status automation at all. suggest (default for every org, including pre-existing ones) = geofence confirmations are logged and offered to the driver to confirm, never silently applied. automatic = eligible geofence transitions apply immediately. No existing organization is defaulted to automatic.';

-- ---------------------------------------------------------------------------
-- dispatch_geofence_state: one row per (dispatch, stop). Confirmed state is
-- derived from multiple qualifying pings, never a single one (spec section
-- 7) -- confirmed_inside_at/confirmed_outside_at only ever get set once each
-- per row and are the edge-trigger the app layer uses to fire arrival/
-- departure automation exactly once, not on every subsequent ping inside
-- the same geofence.
-- ---------------------------------------------------------------------------
create type public.geofence_state as enum ('outside', 'candidate_inside', 'inside', 'candidate_outside', 'exited');

create table public.dispatch_geofence_state (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  dispatch_id uuid not null references public.dispatches (id) on delete cascade,
  load_stop_id uuid not null references public.load_stops (id) on delete cascade,
  stop_type public.stop_type not null,
  state public.geofence_state not null default 'outside',
  inside_confirmations integer not null default 0,
  outside_confirmations integer not null default 0,
  first_inside_at timestamptz,
  confirmed_inside_at timestamptz,
  confirmed_outside_at timestamptz,
  -- Set once a confirmed arrival's status transition has actually been
  -- applied (by automatic mode, or by the driver tapping Confirm Arrival) --
  -- distinct from confirmed_inside_at itself so a 'suggest'-mode org can
  -- show "awaiting driver confirmation" (confirmed_inside_at set,
  -- status_applied_at still null) to office staff.
  status_applied_at timestamptz,
  driver_confirmed_at timestamptz,
  last_distance_m numeric(10, 2),
  last_accuracy_m numeric(8, 2),
  last_location_at timestamptz,
  -- Detention-notification dedupe -- each fires at most once per stop, not
  -- once per ping while a truck sits in detention.
  detention_warning_notified_at timestamptz,
  detention_started_notified_at timestamptz,
  detention_60min_notified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (dispatch_id, load_stop_id)
);

create index dispatch_geofence_state_org_idx on public.dispatch_geofence_state (organization_id);
create index dispatch_geofence_state_dispatch_idx on public.dispatch_geofence_state (dispatch_id);

alter table public.dispatch_geofence_state enable row level security;

alter publication supabase_realtime add table public.dispatch_geofence_state;

create policy "org staff can view geofence state"
  on public.dispatch_geofence_state for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No client write policy -- written only by the location-ping route and the
-- driver-portal confirm action, both service-role, both after independently
-- verifying the driver's own session and dispatch ownership server-side.
-- Same trust model as driver_locations / driver_tracking_sessions (0058).

comment on table public.dispatch_geofence_state is
  'One row per (dispatch, stop). GPS geofence entry/exit is only ever confirmed after multiple qualifying pings (see evaluateGeofencesForDispatch() in src/lib/tracking/geofence.ts) -- never from a single ping. confirmed_inside_at/confirmed_outside_at are edge-triggers: each is set at most once per row.';

create trigger dispatch_geofence_state_set_updated_at
  before update on public.dispatch_geofence_state
  for each row execute function public.set_updated_at();
