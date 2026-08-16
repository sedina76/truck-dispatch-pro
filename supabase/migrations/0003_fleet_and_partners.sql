-- =============================================================================
-- 0003_fleet_and_partners.sql
-- Carriers (the trucking companies this dispatch org manages), brokers,
-- customers, drivers, trucks, trailers, and the truck<->driver assignment
-- history table.
--
-- Business rule: a truck must NOT permanently own a driver_id column,
-- because drivers move between trucks. `truck_driver_assignments` tracks
-- that relationship over time; `dispatches` captures the per-load pairing.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- carriers: the fleet-owning companies this dispatch org provides dispatch
-- services for. A carrier has many drivers, trucks, and trailers.
-- ---------------------------------------------------------------------------
create table public.carriers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  legal_name text not null,
  dba_name text,
  mc_number text,
  dot_number text,
  ein text,
  contact_name text,
  phone text,
  email text,
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  postal_code text,
  country text not null default 'US',
  dispatch_fee_percentage numeric(5, 2) not null default 10.00,
  payment_terms_days integer not null default 7,
  factoring_company_name text,
  notes text,
  is_active boolean not null default true,
  onboarded_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.carriers.dispatch_fee_percentage is 'Default % used to seed dispatches.dispatch_fee_percentage for this carrier''s loads.';

-- ---------------------------------------------------------------------------
-- brokers: freight brokers that loads are sourced from. Every load belongs
-- to a broker.
-- ---------------------------------------------------------------------------
create table public.brokers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  company_name text not null,
  mc_number text,
  contact_name text,
  phone text,
  email text,
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  postal_code text,
  country text not null default 'US',
  credit_rating text,
  payment_terms_days integer default 30,
  average_days_to_pay numeric(5, 1),
  is_blacklisted boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- customers: direct shipper relationships (distinct from brokered loads).
-- ---------------------------------------------------------------------------
create table public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  company_name text not null,
  contact_name text,
  phone text,
  email text,
  billing_address_line1 text,
  billing_address_line2 text,
  city text,
  state text,
  postal_code text,
  country text not null default 'US',
  payment_terms_days integer default 30,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- drivers: belong to a carrier. Never tied 1:1 to a truck permanently.
-- ---------------------------------------------------------------------------
create table public.drivers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  first_name text not null,
  last_name text not null,
  phone text,
  email text,
  cdl_number text,
  cdl_state text,
  cdl_expiry_date date,
  medical_card_expiry_date date,
  hire_date date,
  date_of_birth date,
  status public.driver_status not null default 'active',
  home_terminal_city text,
  home_terminal_state text,
  pay_type text check (pay_type in ('per_mile', 'percentage', 'hourly', 'salary')),
  pay_rate numeric(10, 2),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- trucks: belong to a carrier. No driver_id column by design (see header).
-- ---------------------------------------------------------------------------
create table public.trucks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  unit_number text not null,
  vin text,
  make text,
  model text,
  year integer,
  license_plate text,
  license_state text,
  ownership_type text check (ownership_type in ('owned', 'leased', 'owner_operator')),
  status public.equipment_status not null default 'active',
  current_odometer integer,
  registration_expiry_date date,
  annual_inspection_expiry_date date,
  ifta_sticker_expiry_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, unit_number)
);

-- ---------------------------------------------------------------------------
-- trailers: optionally tied to a carrier (some trailer pools are shared).
-- ---------------------------------------------------------------------------
create table public.trailers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid references public.carriers (id) on delete set null,
  unit_number text not null,
  vin text,
  trailer_type text check (trailer_type in ('dry_van', 'reefer', 'flatbed', 'step_deck', 'lowboy', 'tanker', 'other')),
  length_ft integer,
  license_plate text,
  license_state text,
  ownership_type text check (ownership_type in ('owned', 'leased', 'owner_operator')),
  status public.equipment_status not null default 'active',
  registration_expiry_date date,
  annual_inspection_expiry_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, unit_number)
);

-- ---------------------------------------------------------------------------
-- truck_driver_assignments: history of which driver is currently (or was
-- previously) running which truck. The partial unique index guarantees at
-- most one "current" driver per truck at any time, without ever forcing a
-- permanent FK between the two tables.
-- ---------------------------------------------------------------------------
create table public.truck_driver_assignments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  truck_id uuid not null references public.trucks (id) on delete cascade,
  driver_id uuid not null references public.drivers (id) on delete cascade,
  assigned_at timestamptz not null default now(),
  unassigned_at timestamptz,
  is_current boolean not null default true,
  created_at timestamptz not null default now()
);

create unique index truck_driver_assignments_one_current_per_truck
  on public.truck_driver_assignments (truck_id)
  where (is_current);

comment on table public.truck_driver_assignments is 'Time-boxed truck<->driver pairing history. At most one is_current row per truck.';
