-- =============================================================================
-- 0060_route_intelligence.sql
-- Phase 2C: Route Intelligence, ETA, Miles Remaining & Late-Risk Monitoring.
-- Purely additive on top of 0057-0059. Does not modify, drop, or rename
-- anything from those migrations. dispatch_status is NOT modified.
--
-- Booked miles (loads.total_miles, 0004_operations.sql) are NEVER written
-- by anything in this migration or the app code it ships with -- that
-- column keeps meaning exactly what it always has: the mileage entered
-- when the load was booked. Route Miles (calculated road-route distance)
-- and Miles Remaining (calculated road-route distance from the truck's
-- current position) are new, separate concepts stored only here.
-- =============================================================================

create type public.route_risk_status as enum ('unknown', 'on_time', 'at_risk', 'late', 'arrived');
create type public.route_confidence as enum ('high', 'medium', 'low');
create type public.route_calculation_status as enum ('ok', 'provider_unavailable', 'no_coordinates', 'no_target_stop');

-- ---------------------------------------------------------------------------
-- dispatch_route_intelligence: one current row per (dispatch, target stop).
-- A new row is created (via upsert on the unique constraint below) each
-- time the operational target stop advances -- so a dispatch's route
-- history across multiple stops is naturally preserved, never overwriting
-- a prior stop's final numbers.
-- ---------------------------------------------------------------------------
create table public.dispatch_route_intelligence (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  dispatch_id uuid not null references public.dispatches (id) on delete cascade,
  driver_id uuid references public.drivers (id) on delete set null,
  truck_id uuid references public.trucks (id) on delete set null,
  target_stop_id uuid not null references public.load_stops (id) on delete cascade,

  origin_latitude double precision,
  origin_longitude double precision,
  destination_latitude double precision,
  destination_longitude double precision,

  -- Route Miles / duration for the CURRENT leg (truck's position at
  -- calculated_at -> target stop). Meters/seconds are the provider's
  -- native units; the app layer converts for display (spec section 17:
  -- never show false precision like "128.38291 mi").
  route_distance_meters numeric(10, 2),
  route_duration_seconds integer,
  -- Array of [lon, lat] pairs (GeoJSON coordinate order), decimated to a
  -- reasonable point count before storage -- this is the CALCULATED route
  -- line for the map, never raw historical GPS breadcrumbs (spec section 20).
  route_geometry jsonb,
  -- Set once, the first time a route is successfully calculated for this
  -- (dispatch, target stop) pair -- the stable denominator route progress
  -- (spec section 18) divides against. Never overwritten by a later,
  -- smaller-remaining-distance recalculation, so progress can only move
  -- forward for a given target stop.
  initial_distance_meters numeric(10, 2),

  estimated_arrival_at timestamptz,
  appointment_at timestamptz,
  appointment_window_end timestamptz,

  -- Positive = early (minutes of margin before the effective deadline),
  -- negative = late. Effective deadline is appointment_window_end when
  -- set, else appointment_at (spec section 11).
  schedule_variance_minutes integer,
  risk_status public.route_risk_status not null default 'unknown',
  confidence public.route_confidence not null default 'low',

  provider text,
  calculation_status public.route_calculation_status not null default 'ok',
  -- Only advances on a SUCCESSFUL calculation -- a provider failure leaves
  -- this (and the route numbers above) at their last-known-good value
  -- rather than clearing them, so the UI can keep showing a clearly-marked
  -- stale ETA instead of nothing (spec section 27).
  calculated_at timestamptz,
  -- The driver_locations.recorded_at of the GPS ping this calculation (or
  -- calculation attempt) was based on -- lets the UI distinguish "GPS is
  -- fresh but route calc failed" from "GPS itself is stale".
  source_location_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (dispatch_id, target_stop_id)
);

create index dispatch_route_intelligence_org_idx on public.dispatch_route_intelligence (organization_id);
create index dispatch_route_intelligence_dispatch_idx on public.dispatch_route_intelligence (dispatch_id);

alter table public.dispatch_route_intelligence enable row level security;

alter publication supabase_realtime add table public.dispatch_route_intelligence;

create policy "org staff can view route intelligence"
  on public.dispatch_route_intelligence for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No client write policy -- written only by the location-ping route
-- (server-side, after a trusted GPS ping) and the dispatcher-facing
-- "Refresh ETA" server action, both via the service-role client after
-- independently verifying ownership/context server-side. Same trust model
-- as dispatch_geofence_state (0059).

comment on table public.dispatch_route_intelligence is
  'Road-route ETA/risk for a dispatch''s current operational target stop. Distinct from loads.total_miles (booked miles, entered at booking time, never overwritten here) and from straight-line Haversine distance (used only for geofencing/sanity checks, never as a driving-miles or ETA source -- see src/lib/routing/).';

create trigger dispatch_route_intelligence_set_updated_at
  before update on public.dispatch_route_intelligence
  for each row execute function public.set_updated_at();
