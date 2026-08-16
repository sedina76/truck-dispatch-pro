-- =============================================================================
-- 0004_operations.sql
-- The operational core: loads (with multi-stop support), dispatches
-- (load -> carrier/truck/driver/trailer assignment), and load tracking events.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- loads: a unit of freight sourced from a broker (or booked directly with a
-- customer). Rate lives here; dispatches snapshot it at assignment time.
-- ---------------------------------------------------------------------------
create table public.loads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_number text not null,
  broker_id uuid references public.brokers (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  status public.load_status not null default 'draft',
  commodity text,
  weight_lbs integer,
  equipment_type text check (equipment_type in ('dry_van', 'reefer', 'flatbed', 'step_deck', 'lowboy', 'tanker', 'other')),
  total_miles numeric(8, 2),
  rate numeric(10, 2) not null default 0,
  detention_rate numeric(10, 2),
  layover_rate numeric(10, 2),
  rate_confirmation_number text,
  booked_by uuid references public.profiles (id) on delete set null,
  special_instructions text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, load_number)
);

comment on table public.loads is 'A shipment sourced from a broker or booked directly with a customer.';

-- ---------------------------------------------------------------------------
-- load_stops: ordered pickup/delivery stops for a load (supports multi-stop
-- routes, not just a single origin/destination pair).
-- ---------------------------------------------------------------------------
create table public.load_stops (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete cascade,
  stop_type public.stop_type not null,
  stop_sequence integer not null default 1,
  facility_name text,
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  postal_code text,
  country text not null default 'US',
  contact_name text,
  contact_phone text,
  scheduled_at timestamptz,
  scheduled_window_end timestamptz,
  arrived_at timestamptz,
  departed_at timestamptz,
  reference_number text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- dispatches: assigns a load to a carrier, truck, driver, and optionally a
-- trailer. dispatch_fee_amount / carrier_net_amount are computed by the
-- sync_dispatch_financials() trigger (see 0009) from load_rate x fee %.
-- ---------------------------------------------------------------------------
create table public.dispatches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  truck_id uuid not null references public.trucks (id) on delete restrict,
  driver_id uuid not null references public.drivers (id) on delete restrict,
  trailer_id uuid references public.trailers (id) on delete set null,
  status public.dispatch_status not null default 'assigned',
  dispatch_fee_percentage numeric(5, 2) not null default 10.00,
  load_rate numeric(10, 2) not null default 0,
  dispatch_fee_amount numeric(10, 2) not null default 0,
  carrier_net_amount numeric(10, 2) not null default 0,
  dispatched_by uuid references public.profiles (id) on delete set null,
  dispatched_at timestamptz not null default now(),
  completed_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.dispatches.load_rate is 'Snapshot of loads.rate at dispatch time, so later edits to the load do not silently change historical settlements.';
comment on column public.dispatches.dispatch_fee_amount is 'Computed: load_rate * dispatch_fee_percentage / 100. See sync_dispatch_financials().';
comment on column public.dispatches.carrier_net_amount is 'Computed: load_rate - dispatch_fee_amount.';

-- ---------------------------------------------------------------------------
-- load_tracking_events: check calls / status changes / GPS breadcrumbs.
-- ---------------------------------------------------------------------------
create table public.load_tracking_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete cascade,
  dispatch_id uuid references public.dispatches (id) on delete cascade,
  status public.load_status,
  latitude numeric(9, 6),
  longitude numeric(9, 6),
  location_description text,
  source text check (source in ('manual', 'driver_app', 'elog', 'carrier_api', 'dispatcher')) default 'manual',
  reported_by uuid references public.profiles (id) on delete set null,
  occurred_at timestamptz not null default now(),
  notes text,
  created_at timestamptz not null default now()
);

comment on table public.load_tracking_events is 'Append-only timeline of load status/location updates (check calls, ELD pings, manual notes).';
