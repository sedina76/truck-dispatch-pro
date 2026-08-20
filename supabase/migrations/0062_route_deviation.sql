-- =============================================================================
-- 0062_route_deviation.sql
-- Phase 2D: Route Deviation Detection, Dispatcher Exception Automation &
-- Recovery. Purely additive on top of 0057-0061. Does not modify, drop, or
-- rename anything from those migrations. dispatch_status is NOT modified.
-- No historical GPS or route-intelligence records are rewritten.
--
-- Reuses, rather than duplicates:
--   - notifications / activity_logs (0007_productivity.sql) for alerts and
--     history -- no new exception/incident table architecture is created.
--   - dispatch_route_intelligence (0060) as the route geometry source; this
--     migration never stores its own copy of route geometry.
--   - current_org_id() / has_role() (0002) for RLS, identical to every
--     other Phase 2A-2C.1 table's policy shape.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Org-level feature toggle + thresholds. Conservative default (spec section
-- 39): route_deviation_enabled defaults to FALSE for every organization,
-- existing and new alike -- this is a new automated alerting system that
-- can imply something operationally/reputationally sensitive ("this driver
-- went off route"), so it stays opt-in rather than silently active the
-- moment this migration lands. Stored in meters (spec section 40); the
-- settings UI converts to/from miles for display/entry.
-- ---------------------------------------------------------------------------
alter table public.organizations
  add column if not exists route_deviation_enabled boolean not null default false,
  add column if not exists route_deviation_warning_m integer not null default 805,    -- ~0.5 mi
  add column if not exists route_deviation_confirmed_m integer not null default 1609, -- ~1.0 mi
  add column if not exists route_deviation_recovery_m integer not null default 402;   -- ~0.25 mi

alter table public.organizations
  add constraint organizations_route_deviation_threshold_check
    check (
      route_deviation_recovery_m > 0
      and route_deviation_recovery_m < route_deviation_warning_m
      and route_deviation_warning_m <= route_deviation_confirmed_m
    );

comment on column public.organizations.route_deviation_enabled is 'Phase 2D. Default false for every organization, including pre-existing ones -- a new automated exception/alert system is opt-in, never silently activated by this migration (spec section 39).';
comment on column public.organizations.route_deviation_warning_m is 'Distance (meters) beyond which a ping enters informational "candidate" territory. Never alerts by itself -- see route_deviation_confirmed_m.';
comment on column public.organizations.route_deviation_confirmed_m is 'Distance (meters) beyond which sustained pings (see src/lib/tracking/route-deviation.ts) confirm OFF ROUTE and trigger a dispatcher alert.';
comment on column public.organizations.route_deviation_recovery_m is 'Distance (meters) a confirmed-off-route truck must sustain to be marked RECOVERED. Deliberately smaller than the warning distance (hysteresis, spec section 11) so a truck near a boundary does not flap between states.';

-- ---------------------------------------------------------------------------
-- dispatch_route_deviation_state: one CURRENT row per (dispatch, target
-- stop) -- exact same "advance to a new row on target-stop change" shape as
-- dispatch_route_intelligence (0060), which is what naturally prevents a
-- prior stop's deviation evidence from ever contaminating the next stop's
-- evaluation (spec section 14/54): a new target stop has no existing row,
-- so it always starts at the 'on_route' default.
--
-- This table intentionally holds only the CURRENT/latest episode's state,
-- not a full event history -- activity_logs (written by the orchestrator,
-- src/lib/tracking/evaluate-route-deviation.ts) is the historical record
-- (spec section 22), matching how detention/geofence events already work.
-- ---------------------------------------------------------------------------
create type public.route_deviation_state as enum ('on_route', 'candidate', 'off_route', 'recovering', 'recovered');
create type public.route_deviation_calc_status as enum ('ok', 'no_geometry', 'low_accuracy', 'stale_gps', 'arrived');

create table public.dispatch_route_deviation_state (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  dispatch_id uuid not null references public.dispatches (id) on delete cascade,
  target_stop_id uuid not null references public.load_stops (id) on delete cascade,

  state public.route_deviation_state not null default 'on_route',
  -- Records WHY the state machine did/didn't run on the most recent ping
  -- (spec section 6: "store/record why evaluation was skipped"). When not
  -- 'ok', `state` above is left untouched -- it keeps showing the last
  -- known state (with calculation_status telling the UI that's stale/not
  -- currently evaluated), never silently reset to a false "on_route".
  calculation_status public.route_deviation_calc_status not null default 'ok',
  distance_from_route_m numeric(10, 2),

  candidate_started_at timestamptz,
  candidate_ping_count integer not null default 0,
  confirmed_at timestamptz,

  recovery_started_at timestamptz,
  recovery_ping_count integer not null default 0,
  recovered_at timestamptz,

  -- Route-version awareness (spec section 15, called out as critical): which
  -- dispatch_route_intelligence row this state was last evaluated against.
  -- The orchestrator resets in-progress (not yet confirmed) candidate
  -- evidence when this changes, so a route recalculation can never let
  -- old-route evidence silently confirm a deviation against new geometry
  -- (spec section 55). A CONFIRMED off_route episode is left alone on a
  -- route-version change -- recalculating the route around a truck that has
  -- already deviated does not un-happen that fact (spec section 16); the
  -- normal recovery hysteresis is what clears it, never an instant reset.
  route_intelligence_id uuid references public.dispatch_route_intelligence (id) on delete set null,
  route_calculated_at timestamptz,

  last_evaluated_at timestamptz,
  last_location_at timestamptz,
  last_accuracy_m numeric(8, 2),

  -- Manual office-only "false positive" dismissal (spec section 37).
  -- Deliberately does NOT touch `state`/confirmed_at/recovery fields --
  -- dismissal is acknowledgement, not a claim about GPS reality (spec
  -- section 36: acknowledging must never mark a truck back on route).
  dismissed_at timestamptz,
  dismissed_by uuid references public.profiles (id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (dispatch_id, target_stop_id)
);

create index dispatch_route_deviation_state_org_idx on public.dispatch_route_deviation_state (organization_id);
create index dispatch_route_deviation_state_dispatch_idx on public.dispatch_route_deviation_state (dispatch_id);

alter table public.dispatch_route_deviation_state enable row level security;

alter publication supabase_realtime add table public.dispatch_route_deviation_state;

create policy "org staff can view route deviation state"
  on public.dispatch_route_deviation_state for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No client write policy -- written only by the location-ping route
-- (service-role, after a trusted GPS ping) and the dispatcher-facing
-- dismiss action, both after independently verifying ownership/context
-- server-side. Same trust model as dispatch_geofence_state (0059) and
-- dispatch_route_intelligence (0060).

comment on table public.dispatch_route_deviation_state is
  'One current row per (dispatch, target stop): how far the truck''s trustworthy GPS is from the CALCULATED route geometry to its current target stop, and the sustained-confirmation/recovery state machine over that distance. See src/lib/tracking/route-deviation.ts for the state machine and src/lib/tracking/evaluate-route-deviation.ts for the orchestration (gating, notifications, forced ETA recalculation, activity log).';

create trigger dispatch_route_deviation_state_set_updated_at
  before update on public.dispatch_route_deviation_state
  for each row execute function public.set_updated_at();
