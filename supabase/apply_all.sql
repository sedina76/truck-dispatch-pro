-- ============= 0001_extensions_enums_helpers.sql =============
-- =============================================================================
-- 0001_extensions_enums_helpers.sql
-- Extensions, enumerated types, and reusable helper functions.
-- Everything downstream (tables, RLS, triggers) depends on this file.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists pg_cron;    -- scheduled jobs (compliance status refresh, etc.)

-- ---------------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------------

-- Tenancy / identity
create type public.org_role as enum (
  'owner', 'admin', 'dispatcher', 'accountant', 'driver', 'viewer'
);

-- Billing / subscriptions (platform-level SaaS billing, not freight billing)
create type public.subscription_tier as enum ('starter', 'professional', 'enterprise');
create type public.subscription_status as enum (
  'trialing', 'active', 'past_due', 'canceled', 'incomplete', 'paused'
);

-- Generic polymorphic entity reference (used by documents, compliance_items,
-- notes, tasks, activity_logs, notifications)
create type public.entity_type as enum (
  'organization', 'load', 'dispatch', 'carrier', 'broker', 'customer',
  'driver', 'truck', 'trailer', 'invoice', 'settlement', 'expense'
);

-- Fleet / partners
create type public.equipment_status as enum ('active', 'in_maintenance', 'out_of_service', 'inactive');
create type public.driver_status as enum ('active', 'inactive', 'on_leave', 'terminated', 'applicant');

-- Operations
create type public.load_status as enum (
  'draft', 'posted', 'booked', 'dispatched', 'in_transit', 'at_pickup',
  'at_delivery', 'delivered', 'pod_received', 'invoiced', 'closed',
  'cancelled', 'problem'
);
create type public.stop_type as enum ('pickup', 'delivery');
create type public.dispatch_status as enum (
  'assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded',
  'en_route_to_delivery', 'at_delivery', 'delivered', 'completed', 'cancelled'
);

-- Documents / compliance
create type public.document_type as enum (
  'rate_confirmation', 'bol', 'pod', 'cdl', 'insurance_certificate', 'w9',
  'motor_carrier_authority', 'vehicle_registration', 'ifta_credential',
  'factoring_notice', 'medical_card', 'inspection_report',
  'notice_of_assignment', 'other'
);
create type public.compliance_item_type as enum (
  'cdl_expiry', 'medical_card_expiry', 'insurance_expiry',
  'registration_expiry', 'authority_expiry', 'annual_inspection',
  'drug_test', 'ifta_renewal', 'other'
);
create type public.compliance_status as enum ('valid', 'expiring_soon', 'expired', 'missing', 'waived');

-- Financial
create type public.invoice_status as enum (
  'draft', 'sent', 'viewed', 'partially_paid', 'paid', 'overdue', 'void', 'disputed'
);
create type public.payment_method as enum ('ach', 'wire', 'check', 'credit_card', 'cash', 'factoring', 'other');
create type public.settlement_status as enum ('pending', 'approved', 'paid', 'on_hold', 'disputed', 'cancelled');
create type public.expense_category as enum (
  'fuel', 'maintenance', 'tolls', 'permits_and_licenses', 'insurance',
  'payroll', 'office', 'lease_or_loan', 'other'
);

-- Productivity
create type public.task_status as enum ('open', 'in_progress', 'completed', 'cancelled');
create type public.task_priority as enum ('low', 'medium', 'high', 'urgent');
create type public.notification_type as enum (
  'load_status_change', 'dispatch_assigned', 'document_expiring', 'document_expired',
  'invoice_overdue', 'payment_received', 'settlement_ready', 'task_due', 'system', 'mention'
);

-- Integrations
create type public.integration_provider as enum (
  'dat', 'truckstop', 'loadboard_123', 'quickbooks', 'stripe', 'twilio',
  'sendgrid', 'motive', 'samsara', 'rmis', 'highway', 'carrier411'
);

-- ---------------------------------------------------------------------------
-- Helper functions (used pervasively by RLS policies and triggers)
--
-- NOTE: public.current_org_id() / current_role() / has_role() are NOT
-- defined here even though they conceptually belong with these helpers --
-- they read from public.profiles, which does not exist until
-- 0002_core_saas_tables.sql. LANGUAGE SQL functions are parse-analyzed
-- against real catalog objects at CREATE FUNCTION time, so defining them
-- before their target table exists fails migration application. They are
-- defined at the bottom of 0002, immediately after `profiles` is created.
-- ---------------------------------------------------------------------------

-- Generic updated_at maintenance trigger, attached to every table that has
-- an `updated_at` column (wired up automatically in 0009_functions_triggers.sql).
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============= 0002_core_saas_tables.sql =============
-- =============================================================================
-- 0002_core_saas_tables.sql
-- Tenancy root (organizations), identity (profiles), and platform-level
-- SaaS subscription/billing tables (Starter / Professional / Enterprise).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- organizations: the tenant root. Every business table hangs off this via
-- organization_id, either directly or transitively.
-- ---------------------------------------------------------------------------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  dba_name text,
  mc_number text,
  dot_number text,
  business_phone text,
  business_email text,
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  postal_code text,
  country text not null default 'US',
  timezone text not null default 'America/Chicago',
  logo_url text,
  is_active boolean not null default true,
  trial_ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.organizations is 'Tenant root. One row per dispatch company.';

-- ---------------------------------------------------------------------------
-- profiles: application-level user record, 1:1 with auth.users. Created
-- automatically by the handle_new_user() trigger (see 0009).
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  organization_id uuid references public.organizations (id) on delete cascade,
  full_name text not null,
  email text not null,
  phone text,
  avatar_url text,
  role public.org_role not null default 'dispatcher',
  is_active boolean not null default true,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'App-level user profile + org membership + role. organization_id is null until onboarding assigns/creates an org.';
comment on column public.profiles.role is 'Coarse-grained RBAC. See docs/PLAN.md for the full permission matrix per role.';

-- ---------------------------------------------------------------------------
-- Tenant-scoping helper functions. Defined here (rather than in 0001 with
-- the other helpers) because they read from `profiles`, which must exist
-- first -- LANGUAGE SQL functions are parse-analyzed against real catalog
-- objects at CREATE FUNCTION time. All RLS policies (0010) build on these.
-- SECURITY DEFINER + fixed search_path: lets them read `profiles` even when
-- the calling role's own RLS would otherwise block that read, and prevents
-- search_path hijacking.
-- ---------------------------------------------------------------------------

-- Returns the organization_id of the currently authenticated user.
create or replace function public.current_org_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select organization_id from public.profiles where id = auth.uid();
$$;

-- Returns the org_role of the currently authenticated user.
create or replace function public.current_role()
returns public.org_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- True if the current user's role is one of the given roles. Used as the
-- standard building block for RLS write policies, e.g.:
--   public.has_role(array['owner','admin']::public.org_role[])
create or replace function public.has_role(p_roles public.org_role[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_role() = any(p_roles);
$$;

grant execute on function public.current_org_id() to authenticated;
grant execute on function public.current_role() to authenticated;
grant execute on function public.has_role(public.org_role[]) to authenticated;

-- ---------------------------------------------------------------------------
-- subscription_plans: global catalog (NOT tenant-scoped). Seeded with
-- Starter / Professional / Enterprise; managed by the platform operator.
-- ---------------------------------------------------------------------------
create table public.subscription_plans (
  id uuid primary key default gen_random_uuid(),
  tier public.subscription_tier not null unique,
  name text not null,
  description text,
  monthly_price_cents integer not null,
  annual_price_cents integer,
  max_users integer,
  max_trucks integer,
  max_active_loads integer,
  features jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.subscription_plans is 'Global plan catalog. Not org-scoped; writable only by service_role.';

-- ---------------------------------------------------------------------------
-- organization_subscriptions: which plan a tenant is on, mirrored from Stripe.
-- ---------------------------------------------------------------------------
create table public.organization_subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  plan_id uuid not null references public.subscription_plans (id),
  status public.subscription_status not null default 'trialing',
  billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly', 'annual')),
  stripe_customer_id text,
  stripe_subscription_id text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  canceled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.organization_subscriptions is 'Tenant subscription state, kept in sync with Stripe via webhooks (service_role writes only).';

-- ---------------------------------------------------------------------------
-- billing_records: platform invoices issued to a tenant for their SaaS
-- subscription (distinct from freight `invoices`, which bill brokers/customers).
-- ---------------------------------------------------------------------------
create table public.billing_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  organization_subscription_id uuid references public.organization_subscriptions (id) on delete set null,
  stripe_invoice_id text,
  amount_cents integer not null,
  currency text not null default 'usd',
  status text not null default 'open' check (status in ('open', 'paid', 'void', 'uncollectible')),
  invoice_pdf_url text,
  period_start timestamptz,
  period_end timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.billing_records is 'Platform SaaS billing history (Stripe invoices for the tenant''s own subscription).';

-- ============= 0003_fleet_and_partners.sql =============
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

-- ============= 0004_operations.sql =============
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

-- ============= 0005_documents_compliance.sql =============
-- =============================================================================
-- 0005_documents_compliance.sql
-- Polymorphic document storage (rate cons, BOL, POD, CDL, insurance, W9,
-- authority, registration, IFTA, factoring letters, etc.) and the compliance
-- tracker for expiring credentials.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- documents: polymorphic file attachment. entity_type + entity_id point at
-- the owning row (load, dispatch, carrier, driver, truck, trailer, ...).
-- file_path is a Supabase Storage object path, not the raw file.
-- ---------------------------------------------------------------------------
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  document_type public.document_type not null,
  file_name text not null,
  file_path text not null,
  file_size_bytes bigint,
  mime_type text,
  issued_date date,
  expiry_date date,
  is_verified boolean not null default false,
  verified_by uuid references public.profiles (id) on delete set null,
  verified_at timestamptz,
  uploaded_by uuid references public.profiles (id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.documents is 'Polymorphic file registry. file_path references an object in the "documents" Supabase Storage bucket, namespaced by organization_id.';

-- ---------------------------------------------------------------------------
-- compliance_items: tracks credentials/requirements that expire (CDL,
-- insurance, medical card, registration, authority, inspection, IFTA,
-- drug tests). Optionally linked to the document that proves compliance.
-- status is kept current by the refresh_compliance_statuses() scheduled job.
-- ---------------------------------------------------------------------------
create table public.compliance_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  item_type public.compliance_item_type not null,
  document_id uuid references public.documents (id) on delete set null,
  expiry_date date,
  status public.compliance_status not null default 'valid',
  reminder_sent_at timestamptz,
  resolved_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.compliance_items is 'Expiring-credential tracker driving the Compliance dashboard and expiry notifications.';

-- ============= 0006_financials.sql =============
-- =============================================================================
-- 0006_financials.sql
-- Invoicing (billing brokers/customers), payments, carrier/driver
-- settlements, expenses, fuel, and maintenance.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- invoices: bill a broker or customer for a completed dispatch/load.
-- subtotal/total are recalculated from line items by
-- recalculate_invoice_totals(); amount_paid is recalculated from payments by
-- apply_payment_to_invoice(). balance_due is a generated column.
-- ---------------------------------------------------------------------------
create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_number text not null,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  load_id uuid references public.loads (id) on delete set null,
  broker_id uuid references public.brokers (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  status public.invoice_status not null default 'draft',
  bill_to_name text not null,
  bill_to_email text,
  bill_to_address text,
  subtotal_amount numeric(10, 2) not null default 0,
  discount_amount numeric(10, 2) not null default 0,
  tax_amount numeric(10, 2) not null default 0,
  total_amount numeric(10, 2) not null default 0,
  amount_paid numeric(10, 2) not null default 0,
  balance_due numeric(10, 2) generated always as (total_amount - amount_paid) stored,
  issue_date date not null default current_date,
  due_date date,
  sent_at timestamptz,
  paid_at timestamptz,
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, invoice_number)
);

create table public.invoice_line_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  description text not null,
  quantity numeric(10, 2) not null default 1,
  unit_price numeric(10, 2) not null default 0,
  line_total numeric(10, 2) generated always as (quantity * unit_price) stored,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- payments: money received against an invoice. Multiple partial payments
-- are supported; apply_payment_to_invoice() rolls them up.
-- ---------------------------------------------------------------------------
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  amount numeric(10, 2) not null,
  method public.payment_method not null default 'ach',
  reference_number text,
  received_at timestamptz not null default now(),
  recorded_by uuid references public.profiles (id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- settlements: payout owed to a carrier (and/or driver) for one or more
-- dispatches, net of deductions (fuel advances, escrow, repairs, etc.).
-- ---------------------------------------------------------------------------
create table public.settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  settlement_number text not null,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  driver_id uuid references public.drivers (id) on delete set null,
  status public.settlement_status not null default 'pending',
  gross_amount numeric(10, 2) not null default 0,
  deductions_amount numeric(10, 2) not null default 0,
  net_amount numeric(10, 2) generated always as (gross_amount - deductions_amount) stored,
  period_start date,
  period_end date,
  payment_method public.payment_method,
  paid_at timestamptz,
  approved_by uuid references public.profiles (id) on delete set null,
  approved_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, settlement_number)
);

create table public.settlement_line_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  settlement_id uuid not null references public.settlements (id) on delete cascade,
  description text not null,
  item_type text not null check (item_type in ('earning', 'deduction')),
  amount numeric(10, 2) not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- expenses: general operating costs, optionally tied to a carrier/truck/driver.
-- ---------------------------------------------------------------------------
create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid references public.carriers (id) on delete set null,
  truck_id uuid references public.trucks (id) on delete set null,
  driver_id uuid references public.drivers (id) on delete set null,
  category public.expense_category not null,
  amount numeric(10, 2) not null,
  expense_date date not null default current_date,
  vendor_name text,
  description text,
  receipt_document_id uuid references public.documents (id) on delete set null,
  recorded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- fuel_logs: per-fill-up fuel purchases, tied to a truck.
-- ---------------------------------------------------------------------------
create table public.fuel_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  truck_id uuid not null references public.trucks (id) on delete cascade,
  driver_id uuid references public.drivers (id) on delete set null,
  gallons numeric(8, 2) not null,
  price_per_gallon numeric(6, 3),
  total_amount numeric(10, 2) not null,
  odometer_reading integer,
  state text,
  station_name text,
  purchased_at timestamptz not null default now(),
  receipt_document_id uuid references public.documents (id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- maintenance_records: service history for a truck or trailer.
-- ---------------------------------------------------------------------------
create table public.maintenance_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  truck_id uuid references public.trucks (id) on delete cascade,
  trailer_id uuid references public.trailers (id) on delete cascade,
  service_type text not null,
  description text,
  cost numeric(10, 2) not null default 0,
  odometer_reading integer,
  vendor_name text,
  service_date date not null default current_date,
  next_service_due_date date,
  next_service_due_odometer integer,
  receipt_document_id uuid references public.documents (id) on delete set null,
  recorded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint maintenance_records_truck_or_trailer check (truck_id is not null or trailer_id is not null)
);

-- ============= 0007_productivity.sql =============
-- =============================================================================
-- 0007_productivity.sql
-- Cross-cutting productivity tables: tasks/follow-ups, notes, an immutable
-- activity/audit log, and in-app notifications.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- tasks: follow-ups, optionally attached to any entity (a load, a carrier,
-- an expiring document, etc.) via the polymorphic entity_type/entity_id pair.
-- ---------------------------------------------------------------------------
create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type,
  entity_id uuid,
  title text not null,
  description text,
  status public.task_status not null default 'open',
  priority public.task_priority not null default 'medium',
  due_at timestamptz,
  assigned_to uuid references public.profiles (id) on delete set null,
  created_by uuid references public.profiles (id) on delete set null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- notes: free-text notes attached to any entity.
-- ---------------------------------------------------------------------------
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  body text not null,
  is_pinned boolean not null default false,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- activity_logs: append-only audit trail. Rows are written exclusively via
-- the log_activity() SECURITY DEFINER function (see 0009) -- there is no
-- direct insert/update/delete policy for authenticated users, so the trail
-- cannot be edited or backdated from the client.
-- ---------------------------------------------------------------------------
create table public.activity_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  action text not null,
  actor_id uuid references public.profiles (id) on delete set null,
  changes jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- notifications: in-app notifications for a single recipient profile.
-- ---------------------------------------------------------------------------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  type public.notification_type not null,
  title text not null,
  body text,
  entity_type public.entity_type,
  entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

-- ============= 0008_integrations.sql =============
-- =============================================================================
-- 0008_integrations.sql
-- Per-tenant integration configuration for third-party services: load
-- boards (DAT, Truckstop, 123Loadboard), accounting (QuickBooks), billing
-- (Stripe), comms (Twilio, SendGrid), telematics (Motive, Samsara), and
-- compliance/monitoring (RMIS, Highway, Carrier411).
-- =============================================================================

create table public.integration_settings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  provider public.integration_provider not null,
  is_enabled boolean not null default false,
  -- NOTE: for production, do not store raw secrets in this jsonb column.
  -- Use Supabase Vault (or an equivalent KMS-backed secret store) and keep
  -- only opaque references (e.g. a vault secret id) here.
  credentials jsonb not null default '{}'::jsonb,
  config jsonb not null default '{}'::jsonb,
  last_synced_at timestamptz,
  last_sync_status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, provider)
);

comment on table public.integration_settings is 'Per-org third-party integration config/credentials. Restricted to owner/admin via RLS (see 0010).';

-- ============= 0009_functions_triggers.sql =============
-- =============================================================================
-- 0009_functions_triggers.sql
-- Business-logic functions and the triggers that wire them up:
--   - updated_at maintenance, auto-attached to every table with that column
--   - dispatch fee calculation from load rate x fee %
--   - invoice totals rollup from line items, and amount_paid rollup from payments
--   - settlement gross/deductions rollup from settlement line items
--   - new-user -> profile provisioning
--   - compliance status refresh (scheduled) + expiring-items lookup
--   - invoice numbering helper
--   - append-only activity logging helper
-- =============================================================================

-- ---------------------------------------------------------------------------
-- updated_at: attach public.set_updated_at() (defined in 0001) to every
-- table in the public schema that has an updated_at column. Re-running this
-- migration is idempotent and will also pick up any future table.
-- ---------------------------------------------------------------------------
do $$
declare
  t record;
begin
  for t in
    select c.table_name
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.column_name = 'updated_at'
  loop
    execute format(
      'drop trigger if exists set_updated_at on public.%I;
       create trigger set_updated_at before update on public.%I
       for each row execute function public.set_updated_at();',
      t.table_name, t.table_name
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Dispatch financials: dispatch_fee_amount / carrier_net_amount are derived,
-- never entered by hand. load_rate is snapshotted from loads.rate the first
-- time it is unset, then locked in for historical accuracy.
-- ---------------------------------------------------------------------------
create or replace function public.sync_dispatch_financials()
returns trigger
language plpgsql
as $$
declare
  v_load_rate numeric(10, 2);
begin
  if new.load_rate is null or new.load_rate = 0 then
    select rate into v_load_rate from public.loads where id = new.load_id;
    new.load_rate := coalesce(v_load_rate, 0);
  end if;

  new.dispatch_fee_amount := round(new.load_rate * (new.dispatch_fee_percentage / 100.0), 2);
  new.carrier_net_amount := new.load_rate - new.dispatch_fee_amount;

  return new;
end;
$$;

drop trigger if exists dispatches_sync_financials on public.dispatches;
create trigger dispatches_sync_financials
  before insert or update of load_rate, dispatch_fee_percentage, load_id
  on public.dispatches
  for each row execute function public.sync_dispatch_financials();

-- ---------------------------------------------------------------------------
-- Invoice totals: recompute subtotal/total whenever line items change.
-- ---------------------------------------------------------------------------
create or replace function public.recalculate_invoice_totals()
returns trigger
language plpgsql
as $$
declare
  v_invoice_id uuid;
  v_subtotal numeric(10, 2);
begin
  v_invoice_id := coalesce(new.invoice_id, old.invoice_id);

  select coalesce(sum(line_total), 0) into v_subtotal
  from public.invoice_line_items
  where invoice_id = v_invoice_id;

  update public.invoices
  set subtotal_amount = v_subtotal,
      total_amount = v_subtotal - discount_amount + tax_amount
  where id = v_invoice_id;

  return null;
end;
$$;

drop trigger if exists invoice_line_items_recalculate on public.invoice_line_items;
create trigger invoice_line_items_recalculate
  after insert or update or delete on public.invoice_line_items
  for each row execute function public.recalculate_invoice_totals();

-- ---------------------------------------------------------------------------
-- Invoice payment rollup: keep amount_paid and status in sync with payments.
-- ---------------------------------------------------------------------------
create or replace function public.apply_payment_to_invoice()
returns trigger
language plpgsql
as $$
declare
  v_invoice_id uuid;
  v_total_paid numeric(10, 2);
  v_invoice_total numeric(10, 2);
begin
  v_invoice_id := coalesce(new.invoice_id, old.invoice_id);

  select coalesce(sum(amount), 0) into v_total_paid
  from public.payments
  where invoice_id = v_invoice_id;

  select total_amount into v_invoice_total
  from public.invoices where id = v_invoice_id;

  update public.invoices
  set amount_paid = v_total_paid,
      status = case
        when v_total_paid <= 0 then status
        when v_total_paid >= v_invoice_total then 'paid'
        else 'partially_paid'
      end,
      paid_at = case when v_total_paid >= v_invoice_total then now() else paid_at end
  where id = v_invoice_id;

  return null;
end;
$$;

drop trigger if exists payments_apply_to_invoice on public.payments;
create trigger payments_apply_to_invoice
  after insert or update or delete on public.payments
  for each row execute function public.apply_payment_to_invoice();

-- ---------------------------------------------------------------------------
-- Settlement totals: recompute gross/deductions from settlement_line_items.
-- ---------------------------------------------------------------------------
create or replace function public.recalculate_settlement_totals()
returns trigger
language plpgsql
as $$
declare
  v_settlement_id uuid;
  v_gross numeric(10, 2);
  v_deductions numeric(10, 2);
begin
  v_settlement_id := coalesce(new.settlement_id, old.settlement_id);

  select coalesce(sum(amount) filter (where item_type = 'earning'), 0),
         coalesce(sum(amount) filter (where item_type = 'deduction'), 0)
  into v_gross, v_deductions
  from public.settlement_line_items
  where settlement_id = v_settlement_id;

  update public.settlements
  set gross_amount = v_gross,
      deductions_amount = v_deductions
  where id = v_settlement_id;

  return null;
end;
$$;

drop trigger if exists settlement_line_items_recalculate on public.settlement_line_items;
create trigger settlement_line_items_recalculate
  after insert or update or delete on public.settlement_line_items
  for each row execute function public.recalculate_settlement_totals();

-- ---------------------------------------------------------------------------
-- New-user provisioning: auto-create a profile row when a Supabase Auth
-- user is created. organization_id starts null; the app's onboarding flow
-- either creates a new organization (making this user 'owner') or accepts
-- an invite (assigning an existing organization_id + role).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    new.email,
    'dispatcher'
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Compliance status refresh: intended to run daily via pg_cron, e.g.
--   select cron.schedule('refresh-compliance-statuses', '0 6 * * *',
--     $$select public.refresh_compliance_statuses();$$);
-- ---------------------------------------------------------------------------
create or replace function public.refresh_compliance_statuses()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.compliance_items
  set status = case
    when expiry_date is null then status
    when expiry_date < current_date then 'expired'
    when expiry_date <= current_date + interval '30 days' then 'expiring_soon'
    else 'valid'
  end
  where expiry_date is not null
    and status not in ('waived');
end;
$$;

-- Convenience read helper for the current org's Compliance dashboard.
create or replace function public.get_expiring_compliance_items(p_days_ahead integer default 30)
returns setof public.compliance_items
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.compliance_items
  where organization_id = public.current_org_id()
    and expiry_date is not null
    and expiry_date <= current_date + (p_days_ahead || ' days')::interval
    and status <> 'waived'
  order by expiry_date asc;
$$;

grant execute on function public.get_expiring_compliance_items(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Invoice numbering helper: simple per-org sequential number (INV-000123).
-- Not concurrency-safe under heavy simultaneous inserts for the same org;
-- upgrade to a per-org sequence/counter table if that becomes a problem.
-- ---------------------------------------------------------------------------
create or replace function public.generate_invoice_number(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  select count(*) + 1 into v_count
  from public.invoices
  where organization_id = p_organization_id;

  return 'INV-' || lpad(v_count::text, 6, '0');
end;
$$;

grant execute on function public.generate_invoice_number(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Activity logging helper: the only sanctioned way to write to
-- activity_logs from client code (SECURITY DEFINER; table has no direct
-- insert policy for authenticated users -- see 0010).
-- ---------------------------------------------------------------------------
create or replace function public.log_activity(
  p_entity_type public.entity_type,
  p_entity_id uuid,
  p_action text,
  p_changes jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.activity_logs (organization_id, entity_type, entity_id, action, actor_id, changes)
  values (public.current_org_id(), p_entity_type, p_entity_id, p_action, auth.uid(), p_changes)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.log_activity(public.entity_type, uuid, text, jsonb) to authenticated;

-- ============= 0010_rls_policies.sql =============
-- =============================================================================
-- 0010_rls_policies.sql
-- Row Level Security for every tenant table. Baseline rule: a row is only
-- visible/writable if its organization_id matches public.current_org_id()
-- (see 0001). Sensitive tables (billing, integrations, audit log) add
-- role-based restrictions on top via public.has_role().
--
-- Role tiers used below:
--   operational_write := owner, admin, dispatcher      (day-to-day fleet/load ops)
--   financial_write   := owner, admin, accountant       (money-adjacent records)
--   admin_only        := owner, admin                   (destructive/sensitive)
--   owner_only        := owner                           (org-level settings)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Base table grants. RLS policies only ever narrow what a row-owning grant
-- already permits -- without this, `authenticated` has zero access and
-- every policy below is moot. (On Supabase's hosted platform this is
-- pre-configured for you via default privileges; it is included here
-- explicitly so this schema is portable to any plain Postgres instance.)
-- No grants to `anon`: this product has no unauthenticated read surface.
-- ---------------------------------------------------------------------------
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;

-- ---------------------------------------------------------------------------
-- organizations
-- ---------------------------------------------------------------------------
alter table public.organizations enable row level security;

create policy organizations_select on public.organizations
  for select using (id = public.current_org_id());

-- Any authenticated user may create a brand-new organization during
-- onboarding; the app must immediately assign the creator as 'owner' via a
-- follow-up profile update (a SECURITY DEFINER RPC is recommended so the
-- two steps happen atomically).
create policy organizations_insert on public.organizations
  for insert with check (auth.uid() is not null);

create policy organizations_update on public.organizations
  for update using (id = public.current_org_id() and public.has_role(array['owner']::public.org_role[]))
  with check (id = public.current_org_id());

create policy organizations_delete on public.organizations
  for delete using (id = public.current_org_id() and public.has_role(array['owner']::public.org_role[]));

-- ---------------------------------------------------------------------------
-- profiles
-- No insert policy: rows are created exclusively by the handle_new_user()
-- trigger, which is SECURITY DEFINER and bypasses RLS.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;

create policy profiles_select on public.profiles
  for select using (organization_id = public.current_org_id() or id = auth.uid());

create policy profiles_update_self on public.profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());

create policy profiles_update_admin on public.profiles
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin']::public.org_role[]))
  with check (organization_id = public.current_org_id());

create policy profiles_delete on public.profiles
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
    and id <> auth.uid()
  );

-- ---------------------------------------------------------------------------
-- subscription_plans: global read-only catalog. No write policy for
-- authenticated users -- only service_role (which bypasses RLS) manages it.
-- ---------------------------------------------------------------------------
alter table public.subscription_plans enable row level security;

create policy subscription_plans_select on public.subscription_plans
  for select using (true);

-- ---------------------------------------------------------------------------
-- organization_subscriptions / billing_records: owner/admin read-only.
-- Writes happen exclusively via service_role from Stripe webhook handlers.
-- ---------------------------------------------------------------------------
alter table public.organization_subscriptions enable row level security;

create policy organization_subscriptions_select on public.organization_subscriptions
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

alter table public.billing_records enable row level security;

create policy billing_records_select on public.billing_records
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- Fleet & partners: standard operational CRUD.
-- select: any org member. write: owner/admin/dispatcher. delete: owner/admin.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  standard_tables text[] := array[
    'carriers', 'brokers', 'customers', 'drivers', 'trucks', 'trailers',
    'loads', 'load_stops', 'dispatches', 'load_tracking_events',
    'documents', 'compliance_items'
  ];
begin
  foreach t in array standard_tables loop
    execute format('alter table public.%I enable row level security;', t);

    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_delete on public.%1$I
        for delete using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin']::public.org_role[])
        );
    $p$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- truck_driver_assignments: same operational tier as fleet tables above.
-- ---------------------------------------------------------------------------
alter table public.truck_driver_assignments enable row level security;

create policy truck_driver_assignments_select on public.truck_driver_assignments
  for select using (organization_id = public.current_org_id());

create policy truck_driver_assignments_insert on public.truck_driver_assignments
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

create policy truck_driver_assignments_update on public.truck_driver_assignments
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy truck_driver_assignments_delete on public.truck_driver_assignments
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- Financial: invoices, payments, settlements, expenses, fuel, maintenance.
-- select: any org member. write: owner/admin/accountant (+ dispatcher for
-- the operational cost tables: expenses/fuel_logs/maintenance_records).
-- delete: owner/admin/accountant.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  financial_tables text[] := array['invoices', 'settlements'];
  ops_cost_tables text[] := array['expenses', 'fuel_logs', 'maintenance_records'];
  child_tables text[] := array['invoice_line_items', 'payments', 'settlement_line_items'];
begin
  foreach t in array financial_tables || ops_cost_tables loop
    execute format('alter table public.%I enable row level security;', t);

    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_delete on public.%1$I
        for delete using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        );
    $p$, t);
  end loop;

  -- invoices / settlements: owner/admin/accountant only
  foreach t in array financial_tables loop
    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);
  end loop;

  -- expenses / fuel_logs / maintenance_records: dispatchers can log these too
  foreach t in array ops_cost_tables loop
    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant','dispatcher']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant','dispatcher']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);
  end loop;

  -- child line-item tables inherit the parent's write tier
  foreach t in array child_tables loop
    execute format('alter table public.%I enable row level security;', t);

    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_delete on public.%1$I
        for delete using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        );
    $p$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- tasks / notes: any org member (except viewer) can create; owner/admin or
-- the original author can delete.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  collab_tables text[] := array['tasks', 'notes'];
begin
  foreach t in array collab_tables loop
    execute format('alter table public.%I enable row level security;', t);

    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (organization_id = public.current_org_id())
        with check (organization_id = public.current_org_id());
    $p$, t);
  end loop;
end $$;

create policy tasks_delete on public.tasks
  for delete using (
    organization_id = public.current_org_id()
    and (public.has_role(array['owner', 'admin']::public.org_role[]) or created_by = auth.uid())
  );

create policy notes_delete on public.notes
  for delete using (
    organization_id = public.current_org_id()
    and (public.has_role(array['owner', 'admin']::public.org_role[]) or created_by = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- activity_logs: immutable audit trail. Readable by org members; writable
-- only through the log_activity() SECURITY DEFINER function (0009) -- no
-- insert/update/delete policy is granted to authenticated users.
-- ---------------------------------------------------------------------------
alter table public.activity_logs enable row level security;

create policy activity_logs_select on public.activity_logs
  for select using (organization_id = public.current_org_id());

-- ---------------------------------------------------------------------------
-- notifications: strictly per-recipient. Delivery (insert) happens via
-- backend/service_role or SECURITY DEFINER RPCs, not direct client insert.
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;

create policy notifications_select on public.notifications
  for select using (profile_id = auth.uid());

create policy notifications_update on public.notifications
  for update using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

create policy notifications_delete on public.notifications
  for delete using (profile_id = auth.uid());

-- ---------------------------------------------------------------------------
-- integration_settings: owner/admin only, in every direction (holds
-- third-party credentials).
-- ---------------------------------------------------------------------------
alter table public.integration_settings enable row level security;

create policy integration_settings_select on public.integration_settings
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy integration_settings_insert on public.integration_settings
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy integration_settings_update on public.integration_settings
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy integration_settings_delete on public.integration_settings
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ============= 0011_indexes.sql =============
-- =============================================================================
-- 0011_indexes.sql
-- Performance indexes. Every organization_id column gets a btree index
-- automatically (critical: it's the column every RLS policy filters on).
-- Beyond that, add targeted indexes for the query patterns the app actually
-- runs (status filters, dashboard widgets, FK lookups).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- organization_id on every tenant table (auto-discovered; idempotent).
-- ---------------------------------------------------------------------------
do $$
declare
  t record;
begin
  for t in
    select table_name from information_schema.columns
    where table_schema = 'public' and column_name = 'organization_id'
  loop
    execute format(
      'create index if not exists idx_%s_organization_id on public.%I (organization_id);',
      t.table_name, t.table_name
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Loads / dispatches / tracking
-- ---------------------------------------------------------------------------
create index if not exists idx_loads_status on public.loads (organization_id, status);
create index if not exists idx_loads_broker on public.loads (broker_id);
create index if not exists idx_loads_customer on public.loads (customer_id);

create index if not exists idx_load_stops_load on public.load_stops (load_id, stop_sequence);

create index if not exists idx_dispatches_load on public.dispatches (load_id);
create index if not exists idx_dispatches_status on public.dispatches (organization_id, status);
create index if not exists idx_dispatches_carrier on public.dispatches (carrier_id);
create index if not exists idx_dispatches_truck on public.dispatches (truck_id);
create index if not exists idx_dispatches_driver on public.dispatches (driver_id);

create index if not exists idx_load_tracking_load on public.load_tracking_events (load_id, occurred_at desc);

-- ---------------------------------------------------------------------------
-- Fleet & partners
-- ---------------------------------------------------------------------------
create index if not exists idx_drivers_carrier on public.drivers (carrier_id);
create index if not exists idx_trucks_carrier on public.trucks (carrier_id);
create index if not exists idx_trailers_carrier on public.trailers (carrier_id);
create index if not exists idx_truck_driver_assignments_driver on public.truck_driver_assignments (driver_id);

-- ---------------------------------------------------------------------------
-- Documents & compliance -- expiry lookups drive the Compliance dashboard.
-- ---------------------------------------------------------------------------
create index if not exists idx_documents_entity on public.documents (entity_type, entity_id);
create index if not exists idx_documents_expiry on public.documents (expiry_date) where expiry_date is not null;

create index if not exists idx_compliance_entity on public.compliance_items (entity_type, entity_id);
create index if not exists idx_compliance_expiry on public.compliance_items (expiry_date) where status <> 'waived';
create index if not exists idx_compliance_status on public.compliance_items (organization_id, status);

-- ---------------------------------------------------------------------------
-- Financial
-- ---------------------------------------------------------------------------
create index if not exists idx_invoices_status on public.invoices (organization_id, status);
create index if not exists idx_invoices_dispatch on public.invoices (dispatch_id);
create index if not exists idx_invoice_line_items_invoice on public.invoice_line_items (invoice_id);
create index if not exists idx_payments_invoice on public.payments (invoice_id);

create index if not exists idx_settlements_carrier on public.settlements (carrier_id);
create index if not exists idx_settlements_status on public.settlements (organization_id, status);
create index if not exists idx_settlement_line_items_settlement on public.settlement_line_items (settlement_id);

create index if not exists idx_expenses_date on public.expenses (organization_id, expense_date desc);
create index if not exists idx_fuel_logs_truck on public.fuel_logs (truck_id, purchased_at desc);
create index if not exists idx_maintenance_truck on public.maintenance_records (truck_id, service_date desc);
create index if not exists idx_maintenance_trailer on public.maintenance_records (trailer_id, service_date desc);

-- ---------------------------------------------------------------------------
-- Productivity
-- ---------------------------------------------------------------------------
create index if not exists idx_tasks_assigned_open on public.tasks (assigned_to) where status not in ('completed', 'cancelled');
create index if not exists idx_notes_entity on public.notes (entity_type, entity_id);
create index if not exists idx_activity_logs_entity on public.activity_logs (entity_type, entity_id, created_at desc);
create index if not exists idx_notifications_unread on public.notifications (profile_id) where read_at is null;

-- ============= 0012_profile_privilege_guard.sql =============
-- =============================================================================
-- 0012_profile_privilege_guard.sql
-- Closes a privilege-escalation gap in profiles_update_self (0010): that
-- policy only checks `id = auth.uid()`, with no column restriction, so as
-- written it would let any user set their OWN organization_id and role to
-- anything -- e.g. silently promoting themselves to 'owner', or jumping
-- into a different tenant's organization_id. Postgres RLS is row-level
-- only; it cannot express "this column may only change under condition X"
-- on its own. This migration adds that column-level guard via trigger, plus
-- the one sanctioned way to set organization_id/role during onboarding:
-- create_organization_with_owner().
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Guard trigger: organization_id / role may only change if the acting user
-- is already owner/admin of that row's (pre-update) organization, OR the
-- change is happening inside a trusted SECURITY DEFINER function that has
-- explicitly set the app.bypass_profile_guard session flag (see
-- create_organization_with_owner below).
-- ---------------------------------------------------------------------------
create or replace function public.protect_profile_privileged_columns()
returns trigger
language plpgsql
as $$
begin
  if (new.organization_id is distinct from old.organization_id or new.role is distinct from old.role)
     and coalesce(current_setting('app.bypass_profile_guard', true), 'false') <> 'true'
     and not public.has_role(array['owner', 'admin']::public.org_role[])
  then
    raise exception 'insufficient_privilege: only owner/admin may change organization_id or role';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_protect_privileged_columns on public.profiles;
create trigger profiles_protect_privileged_columns
  before update on public.profiles
  for each row execute function public.protect_profile_privileged_columns();

-- ---------------------------------------------------------------------------
-- Onboarding RPC: the only sanctioned path for a brand-new user (who has no
-- organization yet, hence no role to check) to create an organization and
-- become its owner. Runs both writes atomically and flips the session-local
-- bypass flag so the guard trigger above lets the self-assignment through.
-- ---------------------------------------------------------------------------
create or replace function public.create_organization_with_owner(
  p_name text,
  p_slug text
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if exists (select 1 from public.profiles where id = auth.uid() and organization_id is not null) then
    raise exception 'user already belongs to an organization';
  end if;

  insert into public.organizations (name, slug)
  values (p_name, p_slug)
  returning * into v_org;

  perform set_config('app.bypass_profile_guard', 'true', true);

  update public.profiles
  set organization_id = v_org.id,
      role = 'owner'
  where id = auth.uid();

  return v_org;
end;
$$;

grant execute on function public.create_organization_with_owner(text, text) to authenticated;

comment on function public.create_organization_with_owner is
  'Sole onboarding path for a new tenant: creates the organization and promotes the calling (org-less) user to owner. Invite-based joins for additional users are a later migration (see docs/PLAN.md).';

-- ============= 0013_dispatch_advances.sql =============
-- =============================================================================
-- 0013_dispatch_advances.sql
-- Dispatcher advances / reimbursable expenses: money the dispatch company
-- pays upfront on a carrier's behalf (fuel, lumper, tolls, driver advances,
-- ...), tracked until it is recouped -- normally by deducting it from that
-- carrier's settlement payout, occasionally against an invoice for edge
-- cases where the carrier is billed directly.
-- =============================================================================

create type public.advance_expense_type as enum (
  'fuel', 'lumper', 'toll', 'parking', 'scale', 'repair', 'driver_advance', 'hotel', 'other'
);

create type public.advance_status as enum ('pending', 'deducted', 'reimbursed', 'waived');

create table public.dispatch_advances (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  driver_id uuid references public.drivers (id) on delete set null,
  truck_id uuid references public.trucks (id) on delete set null,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  load_id uuid references public.loads (id) on delete set null,
  expense_type public.advance_expense_type not null,
  description text,
  amount numeric(10, 2) not null check (amount > 0),
  paid_by uuid references public.profiles (id) on delete set null,
  paid_date date not null default current_date,
  payment_method public.payment_method,
  receipt_url text,
  status public.advance_status not null default 'pending',
  deducted_invoice_id uuid references public.invoices (id) on delete set null,
  deducted_settlement_id uuid references public.settlements (id) on delete set null,
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Prevents double deduction at the data layer, not just in application
  -- code: an advance can only be linked to a deduction target once it has
  -- actually been deducted, and only to one target at a time. Reimbursed
  -- (carrier paid the dispatch company back directly) and waived advances
  -- never carry a deduction link -- they were settled outside that mechanism.
  constraint dispatch_advances_deduction_consistency check (
    (status = 'deducted' and (deducted_invoice_id is not null) <> (deducted_settlement_id is not null))
    or (status <> 'deducted' and deducted_invoice_id is null and deducted_settlement_id is null)
  )
);

comment on table public.dispatch_advances is
  'Reimbursable expenses (fuel, lumper, tolls, ...) the dispatch company pays upfront for a carrier, recouped via settlement/invoice deduction, direct reimbursement, or waived.';
comment on column public.dispatch_advances.deducted_invoice_id is
  'Set only if this advance was recouped by deducting it from a broker/customer invoice -- an edge case; the normal path is deducted_settlement_id.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
create index idx_dispatch_advances_organization_id on public.dispatch_advances (organization_id);
create index idx_dispatch_advances_carrier on public.dispatch_advances (carrier_id);
create index idx_dispatch_advances_status on public.dispatch_advances (organization_id, status);
create index idx_dispatch_advances_dispatch on public.dispatch_advances (dispatch_id);
create index idx_dispatch_advances_load on public.dispatch_advances (load_id);

-- ---------------------------------------------------------------------------
-- updated_at trigger (same convention as every other table; the generic
-- auto-wiring DO block in 0009 already ran, so this table needs its own).
-- ---------------------------------------------------------------------------
create trigger set_updated_at
  before update on public.dispatch_advances
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: same tier as expenses/fuel_logs/maintenance_records -- operational
-- costs that owner/admin/accountant/dispatcher can all log, but only
-- owner/admin/accountant can delete.
-- ---------------------------------------------------------------------------
alter table public.dispatch_advances enable row level security;

create policy dispatch_advances_select on public.dispatch_advances
  for select using (organization_id = public.current_org_id());

create policy dispatch_advances_insert on public.dispatch_advances
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

create policy dispatch_advances_update on public.dispatch_advances
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy dispatch_advances_delete on public.dispatch_advances
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- Deduction functions. Both are SECURITY DEFINER so they can write to
-- settlement_line_items / invoice_line_items and update dispatch_advances
-- atomically, but they still resolve organization_id from the target row
-- itself (never from a caller-supplied argument) so a caller can only ever
-- affect data already inside their own org's settlement/invoice.
-- ---------------------------------------------------------------------------

-- Deducts every pending advance for a carrier into a settlement. This is
-- the primary path: the dispatch fee (kept by the dispatch company) and any
-- advances (fuel, lumper, ...) both reduce what's ultimately paid to the
-- carrier, and settlements already compute net_amount = gross - deductions.
create or replace function public.deduct_pending_advances_into_settlement(p_settlement_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_carrier_id uuid;
  v_count integer := 0;
  v_advance record;
  v_next_sort integer;
begin
  select organization_id, carrier_id into v_org_id, v_carrier_id
  from public.settlements where id = p_settlement_id;

  if v_org_id is null then
    raise exception 'Settlement % not found', p_settlement_id;
  end if;

  select coalesce(max(sort_order), 0) + 1 into v_next_sort
  from public.settlement_line_items where settlement_id = p_settlement_id;

  for v_advance in
    select * from public.dispatch_advances
    where carrier_id = v_carrier_id
      and organization_id = v_org_id
      and status = 'pending'
    order by paid_date
  loop
    insert into public.settlement_line_items (organization_id, settlement_id, description, item_type, amount, sort_order)
    values (
      v_org_id,
      p_settlement_id,
      'Advance -- ' || replace(v_advance.expense_type::text, '_', ' ') ||
        case when v_advance.description is not null then ': ' || v_advance.description else '' end,
      'deduction',
      v_advance.amount,
      v_next_sort
    );

    update public.dispatch_advances
    set status = 'deducted', deducted_settlement_id = p_settlement_id
    where id = v_advance.id;

    v_count := v_count + 1;
    v_next_sort := v_next_sort + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.deduct_pending_advances_into_settlement is
  'Sweeps every pending dispatch_advances row for a settlement''s carrier into that settlement as deduction line items, then marks each advance deducted. Idempotent in practice: already-deducted advances have status <> pending, so re-running only picks up newly-recorded ones.';

-- Deducts pending advances into a broker/customer invoice instead -- only
-- meaningful when the invoice is tied to a dispatch (and therefore a
-- carrier); an invoice with no dispatch_id has no carrier to attribute
-- advances to, and this is a no-op in that case.
create or replace function public.deduct_pending_advances_into_invoice(p_invoice_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_carrier_id uuid;
  v_count integer := 0;
  v_advance record;
  v_next_sort integer;
begin
  select i.organization_id, d.carrier_id into v_org_id, v_carrier_id
  from public.invoices i
  left join public.dispatches d on d.id = i.dispatch_id
  where i.id = p_invoice_id;

  if v_org_id is null then
    raise exception 'Invoice % not found', p_invoice_id;
  end if;

  if v_carrier_id is null then
    return 0;
  end if;

  select coalesce(max(sort_order), 0) + 1 into v_next_sort
  from public.invoice_line_items where invoice_id = p_invoice_id;

  for v_advance in
    select * from public.dispatch_advances
    where carrier_id = v_carrier_id
      and organization_id = v_org_id
      and status = 'pending'
    order by paid_date
  loop
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (
      v_org_id,
      p_invoice_id,
      'Advance deduction -- ' || replace(v_advance.expense_type::text, '_', ' ') ||
        case when v_advance.description is not null then ': ' || v_advance.description else '' end,
      1,
      -v_advance.amount,
      v_next_sort
    );

    update public.dispatch_advances
    set status = 'deducted', deducted_invoice_id = p_invoice_id
    where id = v_advance.id;

    v_count := v_count + 1;
    v_next_sort := v_next_sort + 1;
  end loop;

  return v_count;
end;
$$;

comment on function public.deduct_pending_advances_into_invoice is
  'Edge-case counterpart to deduct_pending_advances_into_settlement, for dispatch companies that occasionally bill a carrier directly rather than recouping via settlement. No-op if the invoice has no linked dispatch (and therefore no carrier).';

grant execute on function public.deduct_pending_advances_into_settlement(uuid) to authenticated;
grant execute on function public.deduct_pending_advances_into_invoice(uuid) to authenticated;

-- ============= 0014_company_driver_compliance_expansion.sql =============
-- =============================================================================
-- 0014_company_driver_compliance_expansion.sql
-- Three things:
--   1. Company module: authority/registration fields, mailing address,
--      invoice defaults, and a bank_accounts table.
--   2. Driver module expansion: full personnel profile, encrypted SSN and
--      direct-deposit account fields with an admin-only reveal path and a
--      permanent access log.
--   3. Compliance taxonomy expansion + a structured insurance_policies
--      table (GL / Cargo / Physical Damage / Workers Comp), replacing the
--      "everything is a generic compliance_item" approach for insurance.
-- =============================================================================

-- =============================================================================
-- PART 1: Company module
-- =============================================================================

create type public.authority_status as enum ('active', 'pending', 'inactive', 'revoked');

alter table public.organizations
  add column fax text,
  add column website text,
  add column ein text,
  add column usdot_authority_status public.authority_status,
  add column broker_authority_status public.authority_status,
  add column dispatch_authority_status public.authority_status,
  add column safety_rating text,
  add column safety_rating_date date,
  add column mailing_address_line1 text,
  add column mailing_address_line2 text,
  add column mailing_city text,
  add column mailing_state text,
  add column mailing_postal_code text,
  add column invoice_footer text,
  add column default_payment_terms_days integer not null default 30,
  add column default_invoice_notes text;

create table public.organization_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  bank_name text not null,
  account_nickname text,
  account_type text not null default 'checking' check (account_type in ('checking', 'savings')),
  routing_number_last4 text,
  account_number_last4 text,
  routing_number_encrypted bytea,
  account_number_encrypted bytea,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.organization_bank_accounts is
  'Company payment instructions for receiving factoring/broker payments. Routing/account numbers are encrypted the same way as driver SSNs -- see PART 2 for the shared key-handling pattern.';

create trigger set_updated_at
  before update on public.organization_bank_accounts
  for each row execute function public.set_updated_at();

alter table public.organization_bank_accounts enable row level security;

create policy organization_bank_accounts_select on public.organization_bank_accounts
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy organization_bank_accounts_insert on public.organization_bank_accounts
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy organization_bank_accounts_update on public.organization_bank_accounts
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy organization_bank_accounts_delete on public.organization_bank_accounts
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- Column-level lockdown: RLS governs *rows*, not columns, so a row-level
-- policy alone would still let any owner/admin SELECT the raw ciphertext
-- bytea through the normal REST API. Only the reveal function below (which
-- runs as the table owner via SECURITY DEFINER, bypassing column grants
-- entirely) may ever read the encrypted columns.
revoke select on public.organization_bank_accounts from authenticated;
grant select (
  id, organization_id, bank_name, account_nickname, account_type,
  routing_number_last4, account_number_last4, is_primary, created_at, updated_at
) on public.organization_bank_accounts to authenticated;
revoke insert, update on public.organization_bank_accounts from authenticated;
grant insert (organization_id, bank_name, account_nickname, account_type, is_primary)
  on public.organization_bank_accounts to authenticated;
grant update (bank_name, account_nickname, account_type, is_primary)
  on public.organization_bank_accounts to authenticated;

-- =============================================================================
-- PART 2: Encrypted PII infrastructure (shared by drivers' SSN and
-- direct-deposit numbers, and the company bank accounts above)
-- =============================================================================

-- Holds the symmetric key(s) used for pgp_sym_encrypt/decrypt. RLS is
-- enabled with *zero* policies defined -- that's deliberate, not an
-- oversight: it means there is no role, including authenticated or
-- service_role-via-PostgREST, that can read a row here through the normal
-- API. The only way in is a SECURITY DEFINER function owned by the table
-- owner, which bypasses RLS (and column grants) entirely by Postgres
-- design. This is the standard pre-Vault pattern for app-level secrets;
-- if this project later enables Supabase Vault, this table can be
-- retired in favor of it without changing the functions' external API.
create table public.app_encryption_keys (
  id uuid primary key default gen_random_uuid(),
  key_name text not null unique,
  key_value text not null,
  created_at timestamptz not null default now()
);

alter table public.app_encryption_keys enable row level security;

comment on table public.app_encryption_keys is
  'Symmetric keys for pgp_sym_encrypt/decrypt of driver SSNs and bank account numbers. No RLS policies exist on purpose -- unreachable via the API; only SECURITY DEFINER functions can read it.';

insert into public.app_encryption_keys (key_name, key_value)
values ('driver_pii_key', encode(gen_random_bytes(32), 'hex'))
on conflict (key_name) do nothing;

-- Not granted to authenticated. Callers reach this only by being another
-- SECURITY DEFINER function, which executes with the definer's privileges
-- (the table owner) for its whole body, including nested calls -- so the
-- lack of a grant here never blocks the legitimate call paths below.
create or replace function public.get_app_encryption_key(p_key_name text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select key_value from public.app_encryption_keys where key_name = p_key_name;
$$;

-- Permanent audit trail: every single decryption of a driver's SSN or
-- direct-deposit numbers is recorded here and can never be deleted through
-- the normal API (no delete policy is defined).
create table public.driver_pii_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  driver_id uuid not null references public.drivers (id) on delete cascade,
  field_name text not null check (field_name in ('ssn', 'direct_deposit_account', 'direct_deposit_routing')),
  accessed_by uuid references public.profiles (id) on delete set null,
  reason text,
  accessed_at timestamptz not null default now()
);

comment on table public.driver_pii_access_log is
  'Immutable audit trail of every SSN / bank account reveal. Written exclusively by reveal_driver_pii(); no update/delete policy exists.';

alter table public.driver_pii_access_log enable row level security;

create index idx_driver_pii_access_log_driver on public.driver_pii_access_log (driver_id, accessed_at desc);

create policy driver_pii_access_log_select on public.driver_pii_access_log
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- Same audit-log pattern as driver_pii_access_log, scoped to the company's
-- own bank accounts instead of a driver.
create table public.bank_account_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  bank_account_id uuid not null references public.organization_bank_accounts (id) on delete cascade,
  field_name text not null check (field_name in ('account_number', 'routing_number')),
  accessed_by uuid references public.profiles (id) on delete set null,
  reason text,
  accessed_at timestamptz not null default now()
);

alter table public.bank_account_access_log enable row level security;

create policy bank_account_access_log_select on public.bank_account_access_log
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- Write/reveal pair for organization_bank_accounts, mirroring
-- set_driver_pii/reveal_driver_pii below but scoped to owner-only (a
-- company's own receiving-payment details are more sensitive than a
-- single driver's, since every invoice/factoring payment depends on them).
create or replace function public.set_bank_account_pii(
  p_bank_account_id uuid,
  p_field text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_key text;
  v_digits text;
begin
  if p_field not in ('account_number', 'routing_number') then
    raise exception 'Unsupported field: %', p_field;
  end if;

  select organization_id into v_org_id from public.organization_bank_accounts where id = p_bank_account_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Bank account not found in your organization';
  end if;
  if not public.has_role(array['owner']::public.org_role[]) then
    raise exception 'Only the owner may set bank account numbers';
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');
  v_digits := right(regexp_replace(p_value, '[^0-9]', '', 'g'), 4);

  if p_field = 'account_number' then
    update public.organization_bank_accounts
    set account_number_encrypted = pgp_sym_encrypt(p_value, v_key), account_number_last4 = v_digits
    where id = p_bank_account_id;
  else
    update public.organization_bank_accounts
    set routing_number_encrypted = pgp_sym_encrypt(p_value, v_key), routing_number_last4 = v_digits
    where id = p_bank_account_id;
  end if;
end;
$$;

grant execute on function public.set_bank_account_pii(uuid, text, text) to authenticated;

create or replace function public.reveal_bank_account_pii(
  p_bank_account_id uuid,
  p_field text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_key text;
  v_encrypted bytea;
begin
  if p_field not in ('account_number', 'routing_number') then
    raise exception 'Unsupported field: %', p_field;
  end if;

  select organization_id into v_org_id from public.organization_bank_accounts where id = p_bank_account_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Bank account not found in your organization';
  end if;
  if not public.has_role(array['owner']::public.org_role[]) then
    raise exception 'Only the owner may reveal bank account numbers';
  end if;

  if p_field = 'account_number' then
    select account_number_encrypted into v_encrypted from public.organization_bank_accounts where id = p_bank_account_id;
  else
    select routing_number_encrypted into v_encrypted from public.organization_bank_accounts where id = p_bank_account_id;
  end if;

  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');

  insert into public.bank_account_access_log (organization_id, bank_account_id, field_name, accessed_by, reason)
  values (v_org_id, p_bank_account_id, p_field, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;

grant execute on function public.reveal_bank_account_pii(uuid, text, text) to authenticated;

-- =============================================================================
-- PART 3: Driver module expansion
-- =============================================================================

alter table public.drivers
  add column employee_number text,
  add column photo_url text,
  add column gender text,
  add column address_line1 text,
  add column city text,
  add column state text,
  add column postal_code text,
  add column emergency_contact_name text,
  add column emergency_contact_phone text,
  add column department text,
  add column cdl_class text check (cdl_class in ('A', 'B', 'C')),
  add column cdl_restrictions text,
  add column cdl_endorsements text,
  add column medical_card_number text,
  add column drug_test_date date,
  add column drug_test_expiry_date date,
  add column background_check_date date,
  add column background_check_status text check (background_check_status in ('pending', 'passed', 'failed')),
  add column mvr_date date,
  add column mvr_status text check (mvr_status in ('pending', 'passed', 'failed')),
  add column twic_expiry_date date,
  add column hazmat_endorsement_expiry_date date,
  add column passport_number text,
  add column passport_expiry_date date,
  add column work_authorization_status text check (work_authorization_status in ('citizen', 'permanent_resident', 'visa', 'ead', 'other')),
  add column work_authorization_expiry_date date,
  add column direct_deposit_bank_name text,
  add column direct_deposit_account_last4 text,
  add column direct_deposit_account_encrypted bytea,
  add column direct_deposit_routing_encrypted bytea,
  add column ssn_last4 text,
  add column ssn_encrypted bytea;

comment on column public.drivers.ssn_encrypted is
  'PGP-symmetric-encrypted (pgcrypto). Never selectable by authenticated directly -- see the column-level REVOKE below. Set via set_driver_pii(), read via reveal_driver_pii(), both owner/admin-only and the latter is logged.';
comment on column public.drivers.ssn_last4 is
  'Plaintext last 4 digits only, for the default masked ***-**-1234 display. Not sensitive enough on its own to warrant encryption or access logging.';

-- ---------------------------------------------------------------------------
-- PII write/reveal functions. Both are owner/admin-only regardless of the
-- caller's general driver-edit permissions (dispatchers can edit most
-- driver fields per the RLS policy below, but never these).
-- ---------------------------------------------------------------------------
create or replace function public.set_driver_pii(
  p_driver_id uuid,
  p_field text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_key text;
  v_digits text;
begin
  if p_field not in ('ssn', 'direct_deposit_account', 'direct_deposit_routing') then
    raise exception 'Unsupported PII field: %', p_field;
  end if;

  select organization_id into v_org_id from public.drivers where id = p_driver_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Driver not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may set this field';
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');
  v_digits := right(regexp_replace(p_value, '[^0-9]', '', 'g'), 4);

  if p_field = 'ssn' then
    update public.drivers set ssn_encrypted = pgp_sym_encrypt(p_value, v_key), ssn_last4 = v_digits
    where id = p_driver_id;
  elsif p_field = 'direct_deposit_account' then
    update public.drivers set direct_deposit_account_encrypted = pgp_sym_encrypt(p_value, v_key), direct_deposit_account_last4 = v_digits
    where id = p_driver_id;
  else
    update public.drivers set direct_deposit_routing_encrypted = pgp_sym_encrypt(p_value, v_key)
    where id = p_driver_id;
  end if;
end;
$$;

grant execute on function public.set_driver_pii(uuid, text, text) to authenticated;

create or replace function public.reveal_driver_pii(
  p_driver_id uuid,
  p_field text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_key text;
  v_encrypted bytea;
begin
  if p_field not in ('ssn', 'direct_deposit_account', 'direct_deposit_routing') then
    raise exception 'Unsupported PII field: %', p_field;
  end if;

  select organization_id into v_org_id from public.drivers where id = p_driver_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Driver not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may reveal this field';
  end if;

  if p_field = 'ssn' then
    select ssn_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  elsif p_field = 'direct_deposit_account' then
    select direct_deposit_account_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  else
    select direct_deposit_routing_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  end if;

  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');

  insert into public.driver_pii_access_log (organization_id, driver_id, field_name, accessed_by, reason)
  values (v_org_id, p_driver_id, p_field, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;

grant execute on function public.reveal_driver_pii(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Column-level lockdown on drivers, same rationale as organization_bank_accounts
-- above: RLS already scopes rows to the caller's org (drivers_select /
-- drivers_update policies from 0010), but that alone does not stop a
-- logged-in dispatcher or viewer from selecting the raw encrypted bytea
-- columns through the normal REST API. Every column except the three
-- encrypted ones is re-granted explicitly.
-- ---------------------------------------------------------------------------
revoke select on public.drivers from authenticated;
grant select (
  id, organization_id, carrier_id, first_name, last_name, phone, email,
  cdl_number, cdl_state, cdl_expiry_date, medical_card_expiry_date, hire_date,
  date_of_birth, status, home_terminal_city, home_terminal_state, pay_type,
  pay_rate, notes, created_at, updated_at,
  employee_number, photo_url, gender, address_line1, city, state, postal_code,
  emergency_contact_name, emergency_contact_phone, department, cdl_class,
  cdl_restrictions, cdl_endorsements, medical_card_number, drug_test_date,
  drug_test_expiry_date, background_check_date, background_check_status,
  mvr_date, mvr_status, twic_expiry_date, hazmat_endorsement_expiry_date,
  passport_number, passport_expiry_date, work_authorization_status,
  work_authorization_expiry_date, direct_deposit_bank_name,
  direct_deposit_account_last4, ssn_last4
) on public.drivers to authenticated;

revoke insert, update on public.drivers from authenticated;
grant insert (
  organization_id, carrier_id, first_name, last_name, phone, email,
  cdl_number, cdl_state, cdl_expiry_date, medical_card_expiry_date, hire_date,
  date_of_birth, status, home_terminal_city, home_terminal_state, pay_type,
  pay_rate, notes, employee_number, photo_url, gender, address_line1, city,
  state, postal_code, emergency_contact_name, emergency_contact_phone,
  department, cdl_class, cdl_restrictions, cdl_endorsements,
  medical_card_number, drug_test_date, drug_test_expiry_date,
  background_check_date, background_check_status, mvr_date, mvr_status,
  twic_expiry_date, hazmat_endorsement_expiry_date, passport_number,
  passport_expiry_date, work_authorization_status, work_authorization_expiry_date,
  direct_deposit_bank_name, direct_deposit_account_last4
) on public.drivers to authenticated;
grant update (
  carrier_id, first_name, last_name, phone, email, cdl_number, cdl_state,
  cdl_expiry_date, medical_card_expiry_date, hire_date, date_of_birth, status,
  home_terminal_city, home_terminal_state, pay_type, pay_rate, notes,
  employee_number, photo_url, gender, address_line1, city, state, postal_code,
  emergency_contact_name, emergency_contact_phone, department, cdl_class,
  cdl_restrictions, cdl_endorsements, medical_card_number, drug_test_date,
  drug_test_expiry_date, background_check_date, background_check_status,
  mvr_date, mvr_status, twic_expiry_date, hazmat_endorsement_expiry_date,
  passport_number, passport_expiry_date, work_authorization_status,
  work_authorization_expiry_date, direct_deposit_bank_name, direct_deposit_account_last4
) on public.drivers to authenticated;

-- =============================================================================
-- PART 4: Compliance taxonomy expansion + structured insurance policies
-- =============================================================================

alter type public.compliance_item_type add value if not exists 'dot_inspection';
alter type public.compliance_item_type add value if not exists 'twic_expiry';
alter type public.compliance_item_type add value if not exists 'hazmat_expiry';
alter type public.compliance_item_type add value if not exists 'passport_expiry';
alter type public.compliance_item_type add value if not exists 'work_authorization_expiry';
alter type public.compliance_item_type add value if not exists 'background_check';

create type public.insurance_policy_type as enum (
  'general_liability', 'cargo', 'physical_damage', 'workers_compensation'
);

create table public.insurance_policies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid references public.carriers (id) on delete cascade,
  policy_type public.insurance_policy_type not null,
  insurer_name text not null,
  policy_number text,
  coverage_amount numeric(12, 2),
  premium_amount numeric(10, 2),
  effective_date date,
  expiry_date date,
  document_id uuid references public.documents (id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.insurance_policies is
  'Structured insurance tracking (GL, Cargo, Physical Damage, Workers Comp). carrier_id null = the dispatch company''s own policy; set = a carrier''s policy on file.';

create index idx_insurance_policies_organization_id on public.insurance_policies (organization_id);
create index idx_insurance_policies_carrier on public.insurance_policies (carrier_id);
create index idx_insurance_policies_expiry on public.insurance_policies (expiry_date);

create trigger set_updated_at
  before update on public.insurance_policies
  for each row execute function public.set_updated_at();

alter table public.insurance_policies enable row level security;

create policy insurance_policies_select on public.insurance_policies
  for select using (organization_id = public.current_org_id());

create policy insurance_policies_insert on public.insurance_policies
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy insurance_policies_update on public.insurance_policies
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy insurance_policies_delete on public.insurance_policies
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- =============================================================================
-- PART 5: DOT violations (safety history; starts empty, populated manually
-- or from a future FMCSA/SAFER integration)
-- =============================================================================

create table public.dot_violations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid references public.carriers (id) on delete cascade,
  driver_id uuid references public.drivers (id) on delete set null,
  violation_date date not null default current_date,
  violation_type text not null,
  description text,
  severity text check (severity in ('low', 'medium', 'high', 'critical')) default 'medium',
  is_resolved boolean not null default false,
  resolved_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_dot_violations_organization_id on public.dot_violations (organization_id);
create index idx_dot_violations_carrier on public.dot_violations (carrier_id);

create trigger set_updated_at
  before update on public.dot_violations
  for each row execute function public.set_updated_at();

alter table public.dot_violations enable row level security;

create policy dot_violations_select on public.dot_violations
  for select using (organization_id = public.current_org_id());

create policy dot_violations_insert on public.dot_violations
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

create policy dot_violations_update on public.dot_violations
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy dot_violations_delete on public.dot_violations
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
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
-- ---------------------------------------------------------------------------
-- Platform Admin: a user who operates the SaaS itself, sitting above every
-- tenant -- distinct from org_role, which is always scoped to one
-- organization (even 'owner' only owns their own org). Adds a cross-tenant
-- console: list every company, inspect/change their subscription plan and
-- status, and see basic usage counts, without opening operational tables
-- (loads, trucks, carriers, ...) to cross-tenant reads.
-- ---------------------------------------------------------------------------

-- platform_admins: membership table. No RLS policies at all -- checked
-- exclusively via is_platform_admin() below, mirroring the zero-policy
-- app_encryption_keys pattern used elsewhere in this schema.
create table public.platform_admins (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  created_at timestamptz not null default now()
);

alter table public.platform_admins enable row level security;

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.platform_admins where id = auth.uid());
$$;

grant execute on function public.is_platform_admin() to authenticated;

-- Admins can see who else is an admin (needed for the "Platform Admins" management
-- page) -- safe since only rows that already pass is_platform_admin() can read it.
create policy platform_admins_self_select on public.platform_admins
  for select using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Cross-tenant read access for the platform console.
-- ---------------------------------------------------------------------------
create policy organizations_platform_admin_select on public.organizations
  for select using (public.is_platform_admin());

create policy profiles_platform_admin_select on public.profiles
  for select using (public.is_platform_admin());

create policy organization_subscriptions_platform_admin_all on public.organization_subscriptions
  for all using (public.is_platform_admin()) with check (public.is_platform_admin());

create policy billing_records_platform_admin_select on public.billing_records
  for select using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- get_org_usage_counts: usage snapshot for the companies list/detail, without
-- granting platform admins broad cross-tenant SELECT on operational tables.
-- Defense in depth: checks is_platform_admin() itself rather than trusting
-- the caller to have already checked, since it's granted to `authenticated`.
-- ---------------------------------------------------------------------------
create or replace function public.get_org_usage_counts(p_org_id uuid)
returns table (user_count bigint, truck_count bigint, active_load_count bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  return query
    select
      (select count(*) from public.profiles where organization_id = p_org_id),
      (select count(*) from public.trucks where organization_id = p_org_id),
      (select count(*) from public.loads where organization_id = p_org_id
         and status in ('booked', 'dispatched', 'in_transit', 'at_pickup', 'at_delivery'));
end;
$$;

grant execute on function public.get_org_usage_counts(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- add_platform_admin / remove_platform_admin: manage the admin roster from
-- inside the console itself. Promoting requires the target to already have a
-- Supabase Auth account (an existing tenant user, or one created ahead of
-- time). The very first admin can't be added this way -- see the bootstrap
-- note in RUN_THIS_FOR_PLATFORM_ADMIN.sql / the accompanying chat message.
-- ---------------------------------------------------------------------------
create or replace function public.add_platform_admin(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  select id into v_user_id from auth.users where email = p_email;
  if v_user_id is null then
    raise exception 'no account found with that email';
  end if;

  insert into public.platform_admins (id, full_name)
  values (v_user_id, coalesce((select full_name from public.profiles where id = v_user_id), p_email))
  on conflict (id) do nothing;
end;
$$;

grant execute on function public.add_platform_admin(text) to authenticated;

create or replace function public.remove_platform_admin(p_admin_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if (select count(*) from public.platform_admins) <= 1 then
    raise exception 'cannot remove the last platform admin';
  end if;

  delete from public.platform_admins where id = p_admin_id;
end;
$$;

grant execute on function public.remove_platform_admin(uuid) to authenticated;
-- ---------------------------------------------------------------------------
-- Adds middle_name to the Personal Information section of the driver
-- record. Not sensitive enough to need the encrypted-PII treatment SSN and
-- direct deposit numbers get (see 0014 PART 2/3) -- just a plain column,
-- same tier as first_name/last_name.
-- ---------------------------------------------------------------------------
alter table public.drivers add column middle_name text;

-- The column-level grants from 0014 are an explicit allow-list (not a
-- deny-list), so a brand new column is invisible to the API until it's
-- added to all three grants below, same as every other non-sensitive field.
grant select (middle_name) on public.drivers to authenticated;
grant insert (middle_name) on public.drivers to authenticated;
grant update (middle_name) on public.drivers to authenticated;
-- ---------------------------------------------------------------------------
-- Driver Applications: public, no-login employment intake form at
-- /driver-application. Distinct from public.drivers (the internal record a
-- dispatcher manages) -- an application is reviewed by staff and, if
-- approved, converted into a real driver record. Kept as its own table
-- rather than early rows in `drivers` so an applicant never has any of the
-- access, visibility, or lifecycle a real driver record implies.
--
-- SSN gets the exact same treatment as public.drivers.ssn_encrypted (0014
-- PART 2/3): pgp_sym_encrypt with the same driver_pii_key, last-4-only
-- plaintext for masked display, owner/admin-only reveal, and every reveal
-- logged. Submission itself is anonymous (the applicant has no Supabase Auth
-- session), so the insert path is a SECURITY DEFINER function grantable to
-- `anon` -- there is no INSERT policy or grant for anon on the table itself.
-- ---------------------------------------------------------------------------

create type public.driver_application_status as enum (
  'submitted', 'under_review', 'interview', 'approved', 'rejected', 'converted'
);

create table public.driver_applications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  status public.driver_application_status not null default 'submitted',

  -- Position & availability
  position_applied_for text,
  availability text check (availability in ('full_time', 'part_time', 'otr', 'regional', 'local', 'flexible')),

  -- Personal information
  first_name text not null,
  middle_name text,
  last_name text not null,
  date_of_birth date,
  ssn_encrypted bytea,
  ssn_last4 text,
  phone text,
  email text,
  address_line1 text,
  city text,
  state text,
  postal_code text,

  -- CDL information
  cdl_number text,
  cdl_state text,
  cdl_class text check (cdl_class in ('A', 'B', 'C')),
  cdl_endorsements text,
  cdl_expiry_date date,

  -- Driving experience
  years_of_experience numeric(4, 1),
  equipment_experience text,

  -- Employment history -- an array of {employer, position, start_date,
  -- end_date, reason_for_leaving}, collected by a repeatable client-side
  -- section. jsonb rather than a child table: it's write-once-then-reviewed
  -- content, never queried/filtered on individually.
  employment_history jsonb not null default '[]'::jsonb,

  -- Driving record (self-disclosed; this app has no MVR/background-check
  -- integration, so it never claims to be a verified/pulled record)
  has_been_convicted_of_dui boolean,
  has_had_license_suspended boolean,
  has_had_preventable_accident boolean,
  driving_record_explanation text,

  -- Medical card
  has_valid_medical_card boolean,
  medical_card_expiry_date date,

  -- Uploaded documents -- array of {label, storage_path, file_name,
  -- uploaded_at}. Bucket is private; staff view via short-lived signed URLs
  -- generated server-side (see get_driver_application_document_url below).
  uploaded_documents jsonb not null default '[]'::jsonb,

  -- Emergency contact
  emergency_contact_name text,
  emergency_contact_phone text,

  -- Electronic signature: typed full legal name + explicit certification
  -- checkbox, not a drawn signature pad. Timestamp + submitting IP are
  -- captured as the rest of the "signing" evidence.
  signature_name text not null,
  signature_agreed_at timestamptz not null default now(),
  submitted_from_ip text,

  -- Review workflow
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  review_notes text,
  converted_driver_id uuid references public.drivers (id) on delete set null,

  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.driver_applications
  for each row execute function public.set_updated_at();

create index idx_driver_applications_organization_id on public.driver_applications (organization_id);
create index idx_driver_applications_status on public.driver_applications (status);

comment on column public.driver_applications.ssn_encrypted is
  'PGP-symmetric-encrypted with the same driver_pii_key as public.drivers.ssn_encrypted. Never selectable by authenticated directly -- see the column-level revoke below.';
comment on column public.driver_applications.uploaded_documents is
  'Array of {label, storage_path, file_name, uploaded_at}. storage_path points into the private driver-application-documents bucket; only readable via a signed URL generated by get_driver_application_document_url().';

alter table public.driver_applications enable row level security;

create policy driver_applications_select on public.driver_applications
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- Staff can update status/review fields, never the PII or the applicant's
-- own submitted answers -- see the column-level grant below, which is the
-- real enforcement (RLS alone doesn't stop selecting/writing a column).
create policy driver_applications_update on public.driver_applications
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- No insert policy at all: rows are created exclusively by
-- submit_driver_application() below, which runs as SECURITY DEFINER and so
-- bypasses RLS regardless of whether the caller is anon or authenticated.

revoke select on public.driver_applications from authenticated, anon;
grant select (
  id, organization_id, status, position_applied_for, availability,
  first_name, middle_name, last_name, date_of_birth, ssn_last4, phone, email,
  address_line1, city, state, postal_code,
  cdl_number, cdl_state, cdl_class, cdl_endorsements, cdl_expiry_date,
  years_of_experience, equipment_experience, employment_history,
  has_been_convicted_of_dui, has_had_license_suspended, has_had_preventable_accident,
  driving_record_explanation, has_valid_medical_card, medical_card_expiry_date,
  uploaded_documents, emergency_contact_name, emergency_contact_phone,
  signature_name, signature_agreed_at, submitted_from_ip,
  reviewed_by, reviewed_at, review_notes, converted_driver_id,
  submitted_at, updated_at
) on public.driver_applications to authenticated;

revoke update on public.driver_applications from authenticated, anon;
grant update (status, reviewed_by, reviewed_at, review_notes) on public.driver_applications to authenticated;

-- ---------------------------------------------------------------------------
-- driver_application_pii_access_log: mirrors driver_pii_access_log (0014) --
-- kept as its own table rather than widening that one, since it references
-- driver_applications, not drivers, and the two shouldn't be joined loosely.
-- ---------------------------------------------------------------------------
create table public.driver_application_pii_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  application_id uuid not null references public.driver_applications (id) on delete cascade,
  accessed_by uuid not null references public.profiles (id) on delete set null,
  reason text,
  accessed_at timestamptz not null default now()
);

alter table public.driver_application_pii_access_log enable row level security;

create policy driver_application_pii_access_log_select on public.driver_application_pii_access_log
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

comment on table public.driver_application_pii_access_log is
  'Immutable audit trail of every applicant SSN reveal. Written exclusively by reveal_driver_application_pii(); no update/delete policy exists.';

-- ---------------------------------------------------------------------------
-- Private storage bucket for uploaded application documents (CDL copy,
-- medical card, resume, ...). No storage.objects policies are added for
-- anon or authenticated -- every read and write goes through a route
-- handler / server action using the service_role key, which bypasses
-- storage RLS entirely after independently verifying who's asking.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'driver-application-documents',
  'driver-application-documents',
  false,
  10485760, -- 10 MB
  array['application/pdf', 'image/jpeg', 'image/png', 'image/heic']
)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- submit_driver_application: the one and only way a row can be created.
-- Grantable to anon since the applicant has no Supabase Auth session at all.
-- p_id lets the caller (the /api/driver-application/submit route handler)
-- pre-generate the application id client-side-adjacent so document uploads
-- (which happen as the applicant attaches files, before final submit) can
-- be written to storage under that id ahead of this call.
-- ---------------------------------------------------------------------------
create or replace function public.submit_driver_application(
  p_id uuid,
  p_organization_id uuid,
  p_position_applied_for text,
  p_availability text,
  p_first_name text,
  p_middle_name text,
  p_last_name text,
  p_date_of_birth date,
  p_ssn text,
  p_phone text,
  p_email text,
  p_address_line1 text,
  p_city text,
  p_state text,
  p_postal_code text,
  p_cdl_number text,
  p_cdl_state text,
  p_cdl_class text,
  p_cdl_endorsements text,
  p_cdl_expiry_date date,
  p_years_of_experience numeric,
  p_equipment_experience text,
  p_employment_history jsonb,
  p_has_been_convicted_of_dui boolean,
  p_has_had_license_suspended boolean,
  p_has_had_preventable_accident boolean,
  p_driving_record_explanation text,
  p_has_valid_medical_card boolean,
  p_medical_card_expiry_date date,
  p_uploaded_documents jsonb,
  p_emergency_contact_name text,
  p_emergency_contact_phone text,
  p_signature_name text,
  p_submitted_from_ip text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_key text;
  v_ssn_encrypted bytea;
  v_ssn_last4 text;
begin
  if p_first_name is null or trim(p_first_name) = '' or p_last_name is null or trim(p_last_name) = '' then
    raise exception 'First and last name are required';
  end if;
  if p_signature_name is null or trim(p_signature_name) = '' then
    raise exception 'Electronic signature (typed full legal name) is required';
  end if;
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    raise exception 'Unknown organization';
  end if;

  if p_ssn is not null and trim(p_ssn) <> '' then
    if p_ssn !~ '^\d{3}-\d{2}-\d{4}$' then
      raise exception 'SSN must be in the format XXX-XX-XXXX';
    end if;
    v_key := public.get_app_encryption_key('driver_pii_key');
    v_ssn_encrypted := pgp_sym_encrypt(p_ssn, v_key);
    v_ssn_last4 := right(p_ssn, 4);
  end if;

  insert into public.driver_applications (
    id, organization_id, position_applied_for, availability,
    first_name, middle_name, last_name, date_of_birth, ssn_encrypted, ssn_last4,
    phone, email, address_line1, city, state, postal_code,
    cdl_number, cdl_state, cdl_class, cdl_endorsements, cdl_expiry_date,
    years_of_experience, equipment_experience, employment_history,
    has_been_convicted_of_dui, has_had_license_suspended, has_had_preventable_accident,
    driving_record_explanation, has_valid_medical_card, medical_card_expiry_date,
    uploaded_documents, emergency_contact_name, emergency_contact_phone,
    signature_name, submitted_from_ip
  ) values (
    p_id, p_organization_id, p_position_applied_for, p_availability,
    p_first_name, p_middle_name, p_last_name, p_date_of_birth, v_ssn_encrypted, v_ssn_last4,
    p_phone, p_email, p_address_line1, p_city, p_state, p_postal_code,
    p_cdl_number, p_cdl_state, p_cdl_class, p_cdl_endorsements, p_cdl_expiry_date,
    p_years_of_experience, p_equipment_experience, coalesce(p_employment_history, '[]'::jsonb),
    p_has_been_convicted_of_dui, p_has_had_license_suspended, p_has_had_preventable_accident,
    p_driving_record_explanation, p_has_valid_medical_card, p_medical_card_expiry_date,
    coalesce(p_uploaded_documents, '[]'::jsonb), p_emergency_contact_name, p_emergency_contact_phone,
    p_signature_name, p_submitted_from_ip
  );

  return p_id;
end;
$$;

grant execute on function public.submit_driver_application(
  uuid, uuid, text, text, text, text, text, date, text, text, text, text, text, text, text,
  text, text, text, text, date, numeric, text, jsonb, boolean, boolean, boolean, text,
  boolean, date, jsonb, text, text, text, text
) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- reveal_driver_application_pii: owner/admin-only, logged every time.
-- ---------------------------------------------------------------------------
create or replace function public.reveal_driver_application_pii(p_application_id uuid, p_reason text default null)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_encrypted bytea;
begin
  select organization_id, ssn_encrypted into v_org_id, v_encrypted
  from public.driver_applications where id = p_application_id;

  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Application not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may reveal this field';
  end if;
  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');

  insert into public.driver_application_pii_access_log (organization_id, application_id, accessed_by, reason)
  values (v_org_id, p_application_id, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;

grant execute on function public.reveal_driver_application_pii(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- convert_driver_application_to_driver: creates a real drivers row from an
-- approved application. The encrypted SSN ciphertext is copied byte-for-byte
-- from the application to the new driver row -- it is never decrypted in
-- this function, so the plaintext SSN does not exist anywhere in memory
-- during conversion, only at the two points it always has: the applicant's
-- original submission, and a logged owner/admin reveal.
-- ---------------------------------------------------------------------------
create or replace function public.convert_driver_application_to_driver(p_application_id uuid, p_carrier_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app public.driver_applications;
  v_driver_id uuid;
begin
  select * into v_app from public.driver_applications where id = p_application_id;
  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may convert an application';
  end if;
  if v_app.status = 'converted' then
    raise exception 'This application has already been converted';
  end if;
  if not exists (select 1 from public.carriers where id = p_carrier_id and organization_id = v_app.organization_id) then
    raise exception 'Carrier not found in your organization';
  end if;

  insert into public.drivers (
    organization_id, carrier_id, first_name, middle_name, last_name, phone, email,
    date_of_birth, address_line1, city, state, postal_code,
    emergency_contact_name, emergency_contact_phone,
    cdl_number, cdl_state, cdl_class, cdl_endorsements, cdl_expiry_date,
    medical_card_expiry_date, status, ssn_encrypted, ssn_last4
  ) values (
    v_app.organization_id, p_carrier_id, v_app.first_name, v_app.middle_name, v_app.last_name,
    v_app.phone, v_app.email, v_app.date_of_birth, v_app.address_line1, v_app.city, v_app.state, v_app.postal_code,
    v_app.emergency_contact_name, v_app.emergency_contact_phone,
    v_app.cdl_number, v_app.cdl_state, v_app.cdl_class, v_app.cdl_endorsements, v_app.cdl_expiry_date,
    v_app.medical_card_expiry_date, 'applicant', v_app.ssn_encrypted, v_app.ssn_last4
  )
  returning id into v_driver_id;

  update public.driver_applications
    set status = 'converted', converted_driver_id = v_driver_id, updated_at = now()
    where id = p_application_id;

  return v_driver_id;
end;
$$;

grant execute on function public.convert_driver_application_to_driver(uuid, uuid) to authenticated;
-- ---------------------------------------------------------------------------
-- Fixes a latent bug in 0014: set_bank_account_pii, reveal_bank_account_pii,
-- set_driver_pii, and reveal_driver_pii all call pgp_sym_encrypt/
-- pgp_sym_decrypt (pgcrypto) but only had `set search_path = public`.
-- Discovered earlier this session with the *same* class of function
-- (gen_salt/crypt in the driver-portal PIN functions) -- pgcrypto lives in
-- the `extensions` schema on Supabase, not `public`, so any unqualified
-- call fails at runtime with "function pgp_sym_encrypt(...) does not exist"
-- even though the function itself was created successfully. Because 0014's
-- live status was never confirmed, this was caught by inspection while
-- building the driver-application feature (which calls the same encryption
-- path) rather than by a failed call in production. CREATE OR REPLACE is
-- safe to run whether or not 0014 has been applied yet.
-- ---------------------------------------------------------------------------

create or replace function public.set_bank_account_pii(
  p_bank_account_id uuid,
  p_field text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_digits text;
begin
  if p_field not in ('account_number', 'routing_number') then
    raise exception 'Unsupported field: %', p_field;
  end if;

  select organization_id into v_org_id from public.organization_bank_accounts where id = p_bank_account_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Bank account not found in your organization';
  end if;
  if not public.has_role(array['owner']::public.org_role[]) then
    raise exception 'Only the owner may set bank account numbers';
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');
  v_digits := right(regexp_replace(p_value, '[^0-9]', '', 'g'), 4);

  if p_field = 'account_number' then
    update public.organization_bank_accounts
    set account_number_encrypted = pgp_sym_encrypt(p_value, v_key), account_number_last4 = v_digits
    where id = p_bank_account_id;
  else
    update public.organization_bank_accounts
    set routing_number_encrypted = pgp_sym_encrypt(p_value, v_key), routing_number_last4 = v_digits
    where id = p_bank_account_id;
  end if;
end;
$$;

create or replace function public.reveal_bank_account_pii(
  p_bank_account_id uuid,
  p_field text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_encrypted bytea;
begin
  if p_field not in ('account_number', 'routing_number') then
    raise exception 'Unsupported field: %', p_field;
  end if;

  select organization_id into v_org_id from public.organization_bank_accounts where id = p_bank_account_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Bank account not found in your organization';
  end if;
  if not public.has_role(array['owner']::public.org_role[]) then
    raise exception 'Only the owner may reveal bank account numbers';
  end if;

  if p_field = 'account_number' then
    select account_number_encrypted into v_encrypted from public.organization_bank_accounts where id = p_bank_account_id;
  else
    select routing_number_encrypted into v_encrypted from public.organization_bank_accounts where id = p_bank_account_id;
  end if;

  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');

  insert into public.bank_account_access_log (organization_id, bank_account_id, field_name, accessed_by, reason)
  values (v_org_id, p_bank_account_id, p_field, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;

create or replace function public.set_driver_pii(
  p_driver_id uuid,
  p_field text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_digits text;
begin
  if p_field not in ('ssn', 'direct_deposit_account', 'direct_deposit_routing') then
    raise exception 'Unsupported PII field: %', p_field;
  end if;

  select organization_id into v_org_id from public.drivers where id = p_driver_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Driver not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may set this field';
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');
  v_digits := right(regexp_replace(p_value, '[^0-9]', '', 'g'), 4);

  if p_field = 'ssn' then
    update public.drivers set ssn_encrypted = pgp_sym_encrypt(p_value, v_key), ssn_last4 = v_digits
    where id = p_driver_id;
  elsif p_field = 'direct_deposit_account' then
    update public.drivers set direct_deposit_account_encrypted = pgp_sym_encrypt(p_value, v_key), direct_deposit_account_last4 = v_digits
    where id = p_driver_id;
  else
    update public.drivers set direct_deposit_routing_encrypted = pgp_sym_encrypt(p_value, v_key)
    where id = p_driver_id;
  end if;
end;
$$;

create or replace function public.reveal_driver_pii(
  p_driver_id uuid,
  p_field text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_encrypted bytea;
begin
  if p_field not in ('ssn', 'direct_deposit_account', 'direct_deposit_routing') then
    raise exception 'Unsupported PII field: %', p_field;
  end if;

  select organization_id into v_org_id from public.drivers where id = p_driver_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Driver not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may reveal this field';
  end if;

  if p_field = 'ssn' then
    select ssn_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  elsif p_field = 'direct_deposit_account' then
    select direct_deposit_account_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  else
    select direct_deposit_routing_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  end if;

  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');

  insert into public.driver_pii_access_log (organization_id, driver_id, field_name, accessed_by, reason)
  values (v_org_id, p_driver_id, p_field, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;
-- ---------------------------------------------------------------------------
-- Fixes a gap from 0017: the middle_name column on public.drivers exists
-- (confirmed live -- a driver was already successfully created with a
-- middle_name via convert_driver_application_to_driver, which runs as
-- SECURITY DEFINER and so bypasses column grants entirely), but the
-- column-level SELECT/INSERT/UPDATE grants for it were never actually
-- applied to the `authenticated` role. Postgres denies an entire query when
-- it references any column the caller lacks a grant on -- not just that
-- column -- so every plain page load of a driver (View/Edit, same page)
-- was failing outright and rendering blank. GRANT is idempotent -- safe to
-- run even if some of these already succeeded.
-- ---------------------------------------------------------------------------

grant select (middle_name) on public.drivers to authenticated;
grant insert (middle_name) on public.drivers to authenticated;
grant update (middle_name) on public.drivers to authenticated;
-- ---------------------------------------------------------------------------
-- get_load_summary: replaces loads/page.tsx's in-memory sum of an
-- unpaginated select("rate") result (correct today at a handful of rows,
-- but silently wrong past PostgREST's default row cap once the table
-- grows) with a real SUM(rate) computed in Postgres.
--
-- Deliberately NOT security definer: it runs with the caller's own
-- privileges, so the existing RLS policy on public.loads
-- (organization_id = current_org_id()) applies exactly as it would to any
-- other query against the table -- this function does not, and cannot,
-- see another organization's loads. No new privilege is being granted here,
-- just a server-side aggregate over rows the caller could already read.
-- ---------------------------------------------------------------------------
create or replace function public.get_load_summary(p_search text default null)
returns table (total_loads bigint, total_rate_value numeric)
language sql
stable
as $$
  select
    count(*)::bigint,
    coalesce(sum(rate), 0)::numeric
  from public.loads
  where p_search is null or load_number ilike '%' || p_search || '%';
$$;

grant execute on function public.get_load_summary(text) to authenticated;
-- ---------------------------------------------------------------------------
-- Automatic invoice generation on delivery.
--
-- Implemented as a database trigger on public.loads, not application code,
-- so it fires no matter which code path flips a load to 'delivered' --
-- the load edit form, the dispatch board's drag-and-drop status update, a
-- future API integration, or a direct REST call all go through the same
-- table write and therefore the same trigger. "Do not simply add a
-- frontend button" is the whole reason for this approach.
--
-- Uses the single literal 'delivered' status, matching the trigger
-- condition described in the request and the COMPLETED_LOAD_STATUSES
-- primary value in src/lib/loads/status.ts -- no separate/independent
-- status classification is introduced here.
-- ---------------------------------------------------------------------------

-- Duplicate protection, database-level: partial unique index means even two
-- concurrent transactions racing to insert an invoice for the same load
-- cannot both succeed, regardless of application-level checks.
create unique index invoices_load_id_unique_idx on public.invoices (load_id) where load_id is not null;

create or replace function public.auto_generate_invoice_from_delivered_load()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_to_name text;
  v_bill_to_email text;
  v_bill_to_address text;
  v_payment_terms integer;
  v_invoice_number text;
  v_dispatch_id uuid;
  v_invoice_id uuid;
begin
  -- Only a genuine transition INTO 'delivered' fires this -- not every
  -- update to an already-delivered load (editing notes, re-saving, etc.).
  if NEW.status is distinct from 'delivered' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and OLD.status is not distinct from 'delivered' then
    return NEW;
  end if;

  -- Belt-and-suspenders idempotency check before even attempting the
  -- insert (the unique index above is the real guarantee under a race).
  if exists (select 1 from public.invoices where load_id = NEW.id) then
    return NEW;
  end if;

  -- Bill-to party: broker first (brokered freight), else the direct
  -- customer. Never the driver/carrier -- they're paid via settlements,
  -- a completely separate flow from customer/broker invoicing.
  if NEW.broker_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', address_line1, city, state, postal_code)), ''),
           payment_terms_days
      into v_bill_to_name, v_bill_to_email, v_bill_to_address, v_payment_terms
    from public.brokers where id = NEW.broker_id;
  elsif NEW.customer_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', billing_address_line1, city, state, postal_code)), ''),
           payment_terms_days
      into v_bill_to_name, v_bill_to_email, v_bill_to_address, v_payment_terms
    from public.customers where id = NEW.customer_id;
  else
    -- No broker or customer on file to bill -- leave the load delivered
    -- without fabricating a bill-to party. A dispatcher can still create
    -- the invoice manually once the load is linked to one.
    return NEW;
  end if;

  select id into v_dispatch_id from public.dispatches where load_id = NEW.id limit 1;
  v_invoice_number := public.generate_invoice_number(NEW.organization_id);

  insert into public.invoices (
    organization_id, invoice_number, load_id, dispatch_id, broker_id, customer_id,
    status, bill_to_name, bill_to_email, bill_to_address,
    subtotal_amount, total_amount, issue_date, due_date, notes
  ) values (
    NEW.organization_id, v_invoice_number, NEW.id, v_dispatch_id, NEW.broker_id, NEW.customer_id,
    'draft', v_bill_to_name, v_bill_to_email, v_bill_to_address,
    NEW.rate, NEW.rate, current_date, current_date + coalesce(v_payment_terms, 30),
    'Auto-generated on delivery for load ' || NEW.load_number
  )
  on conflict (load_id) where load_id is not null do nothing
  returning id into v_invoice_id;

  -- v_invoice_id is null if the on-conflict branch fired (a concurrent
  -- request won the race) -- skip the line item entirely in that case.
  if v_invoice_id is not null then
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (NEW.organization_id, v_invoice_id, 'Freight charges -- Load ' || NEW.load_number, 1, NEW.rate, 0);

    perform public.log_activity('invoice', v_invoice_id, 'created');
  end if;

  return NEW;
end;
$$;

create trigger auto_generate_invoice_on_delivery
  after update on public.loads
  for each row execute function public.auto_generate_invoice_from_delivered_load();
-- ---------------------------------------------------------------------------
-- Proof of Delivery (POD) workflow. Reuses the existing public.documents
-- table (entity_type = 'load', document_type = 'pod') rather than creating
-- a competing table -- both already exist. Only the rejection state is new.
-- ---------------------------------------------------------------------------

alter table public.documents
  add column rejected_at timestamptz,
  add column rejected_by uuid references public.profiles (id) on delete set null,
  add column rejection_reason text;

comment on column public.documents.rejected_at is
  'Set together with rejected_by/rejection_reason when a POD (or any document) is rejected. A row with rejected_at set and is_verified false is in the Rejected state; replacing it means uploading a new document row, not editing this one, so rejection history is never overwritten.';

-- Status for a given load's POD is a derived 4-state value computed from
-- documents rows, never stored redundantly:
--   no row                                -> Missing
--   row, rejected_at is null, not verified -> Uploaded
--   row, is_verified = true               -> Verified
--   row, rejected_at is not null          -> Rejected

-- ---------------------------------------------------------------------------
-- Private storage bucket for load documents (POD, and future load-linked
-- documents). No public access; every read goes through a signed URL with
-- an expiration, every write is checked by the policies below.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('load-documents', 'load-documents', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

-- Staff uploads/reads go through the authenticated Supabase client directly
-- (not a service-role route handler), so real Storage RLS policies are
-- needed here -- unlike the driver-application-documents bucket, where the
-- uploader has no Supabase Auth session at all and everything is mediated
-- by a trusted server-side route handler instead.
--
-- Objects are stored at {organization_id}/{load_id}/{filename}; policies
-- check the first path segment against the caller's own org.
create policy load_documents_select on storage.objects
  for select using (
    bucket_id = 'load-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

create policy load_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'load-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy: a rejected or superseded POD is never edited or
-- removed in place (see the comment on documents.rejected_at) -- a
-- replacement is a new upload, new document row, new object path.

-- ---------------------------------------------------------------------------
-- Invoice send gate: a load's invoice cannot move from draft to sent
-- without a verified POD on file. Enforced here (not just in the UI) so it
-- holds regardless of which code path attempts the status change.
-- ---------------------------------------------------------------------------
create or replace function public.check_invoice_ready_to_send()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_verified_pod boolean;
begin
  if NEW.status is distinct from 'sent' or OLD.status = 'sent' then
    return NEW;
  end if;
  if NEW.load_id is null then
    -- Not tied to a load (a manually created invoice with no POD concept)
    -- -- nothing to gate.
    return NEW;
  end if;

  select exists (
    select 1 from public.documents
    where entity_type = 'load'
      and entity_id = NEW.load_id
      and document_type = 'pod'
      and is_verified = true
  ) into v_has_verified_pod;

  if not v_has_verified_pod then
    raise exception 'Cannot send invoice: Proof of Delivery is required and must be verified first.'
      using errcode = 'P0001';
  end if;

  return NEW;
end;
$$;

create trigger invoice_requires_verified_pod_to_send
  before update on public.invoices
  for each row execute function public.check_invoice_ready_to_send();
-- ---------------------------------------------------------------------------
-- Billing Packet workflow. Reuses public.documents for every supporting
-- document (POD, rate confirmation, BOL, accessorials) -- no competing
-- document table. Only the packet itself (a generated, merged PDF) needs
-- new metadata storage, since it isn't a document someone uploaded.
-- ---------------------------------------------------------------------------

alter type public.document_type add value if not exists 'lumper_receipt';
alter type public.document_type add value if not exists 'detention_document';
alter type public.document_type add value if not exists 'scale_ticket';

create type public.billing_packet_status as enum ('generated', 'outdated', 'sent');

-- ---------------------------------------------------------------------------
-- billing_packets: metadata for each generated packet PDF. A new row per
-- generation (version + 1), never edited in place -- same "append, don't
-- overwrite" pattern as documents.rejected_at/POD replacement, so packet
-- history is never lost. document_snapshot freezes exactly which document
-- rows (id + created_at) were included, which is what regeneration compares
-- against to decide whether a packet is stale -- never filenames alone.
-- ---------------------------------------------------------------------------
create table public.billing_packets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  version integer not null,
  status public.billing_packet_status not null default 'generated',
  storage_path text not null,
  document_snapshot jsonb not null default '[]'::jsonb,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.profiles (id) on delete set null,
  sent_at timestamptz,
  sent_by uuid references public.profiles (id) on delete set null,
  recipient_email text,
  created_at timestamptz not null default now(),
  unique (invoice_id, version)
);

comment on table public.billing_packets is
  'One row per generated packet PDF (a version), not one row per invoice -- regenerating never overwrites history. document_snapshot is an array of {document_id, document_type, created_at} for every source document included, used to detect staleness when a POD/rate-con/BOL is later replaced.';

create index idx_billing_packets_invoice_id on public.billing_packets (invoice_id, version desc);

alter table public.billing_packets enable row level security;

-- Same access tier as invoices themselves (0010_rls_policies.sql):
-- select any org member, write owner/admin/accountant.
create policy billing_packets_select on public.billing_packets
  for select using (organization_id = public.current_org_id());

create policy billing_packets_insert on public.billing_packets
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy billing_packets_update on public.billing_packets
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- ---------------------------------------------------------------------------
-- Private storage bucket for generated packet PDFs.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('billing-packets', 'billing-packets', false, 26214400, array['application/pdf'])
on conflict (id) do nothing;

create policy billing_packets_storage_select on storage.objects
  for select using (
    bucket_id = 'billing-packets'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

create policy billing_packets_storage_insert on storage.objects
  for insert with check (
    bucket_id = 'billing-packets'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- Billing Packet generation hardening: adds the DELETE policies needed to
-- support the app-level cleanup path when a packet reservation succeeds
-- but the subsequent PDF upload fails (see generatePacket() in
-- src/app/(app)/invoices/billing-packet-actions.ts). No schema/version
-- semantics change -- version uniqueness (invoice_id, version) is unchanged,
-- and no existing row/object is ever touched by this.
--
-- These policies are scoped identically to the existing insert/update
-- policies from 0024 (same org, same role tier) -- they do not expand who
-- can write billing packets, only what a request that already has write
-- access can undo for ITS OWN failed, not-yet-successful attempt. App code
-- only ever calls delete from that one failure-recovery branch; a
-- successfully generated packet is never targeted for deletion by any
-- code path.
-- ---------------------------------------------------------------------------

create policy billing_packets_delete on public.billing_packets
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy billing_packets_storage_delete on storage.objects
  for delete using (
    bucket_id = 'billing-packets'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- =============================================================================
-- 0026_accounts_receivable.sql
-- Accounts Receivable & Payment Tracking. Builds entirely on the existing
-- invoices/invoice_line_items/payments schema from 0006_financials.sql and
-- the existing apply_payment_to_invoice()/recalculate_invoice_totals()
-- triggers from 0009_functions_triggers.sql -- no competing tables, no new
-- invoice_status values, no change to POD/billing-packet behavior.
--
-- balance_due stays the single source of truth exactly as it already was
-- (generated column: total_amount - amount_paid, 0006) -- nothing here
-- introduces a second, driftable balance field.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- payments: add what's needed for numbering, void/reversal, and the extra
-- reference fields the Record Payment form asks for. Nothing here touches
-- amount/method/invoice_id -- those already exist from 0006.
-- ---------------------------------------------------------------------------
create type public.payment_status as enum ('posted', 'voided');

-- Concurrency-safe numbering: nextval() on a sequence is atomic under
-- concurrent inserts by construction (unlike generate_invoice_number()'s
-- count(*)+1, which 0009 already documents as not concurrency-safe). Wrapped
-- in a SECURITY DEFINER function, matching generate_invoice_number()'s own
-- shape, so the function owner's implicit sequence privileges are used
-- instead of granting USAGE on the sequence directly to authenticated.
create sequence public.payment_number_seq;

create or replace function public.generate_payment_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  return 'PAY-' || lpad(nextval('public.payment_number_seq')::text, 6, '0');
end;
$$;

grant execute on function public.generate_payment_number() to authenticated;

alter table public.payments
  add column payment_number text not null default public.generate_payment_number(),
  add column status public.payment_status not null default 'posted',
  add column check_number text,
  add column bank_reference text,
  add column voided_by uuid references public.profiles (id) on delete set null,
  add column voided_at timestamptz,
  add column void_reason text,
  add column updated_at timestamptz not null default now(),
  add constraint payments_payment_number_key unique (payment_number),
  add constraint payments_void_requires_reason check (status <> 'voided' or void_reason is not null);

comment on column public.payments.status is
  'posted = counts toward amount_paid/balance_due via apply_payment_to_invoice(). voided = an auditable reversal/correction, excluded from that rollup but never deleted -- see voided_by/voided_at/void_reason.';

-- payments already has organization_id NOT NULL (0006) and RLS from 0010's
-- child_tables loop (select: any org member; insert/update/delete:
-- owner/admin/accountant) -- unchanged by this migration. The blanket
-- `grant select, insert, update, delete on all tables ... to authenticated`
-- from 0010 already covers these new columns; no column-level grants
-- needed (payments/invoices were never part of the driver-PII
-- column-restriction pattern).

drop trigger if exists set_updated_at on public.payments;
create trigger set_updated_at before update on public.payments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Overpayment guard (defense-in-depth, not just the app form): rejects a
-- posted payment whose amount exceeds the invoice's CURRENT balance_due.
-- No credits/unapplied-cash table exists anywhere in this schema, so per
-- spec this blocks rather than inventing one.
--
-- `select ... for update` locks the invoice row for the rest of this
-- transaction, so two concurrent payment inserts against the same invoice
-- can never both read the same pre-payment balance and both pass -- the
-- second waits for the first's transaction (and the AFTER INSERT
-- apply_payment_to_invoice() rollup it fires) to commit before evaluating
-- its own check. This is what makes the overpayment guard concurrency-safe,
-- not just correct for a single request.
-- ---------------------------------------------------------------------------
create or replace function public.guard_payment_amount()
returns trigger
language plpgsql
as $$
declare
  v_balance numeric(10, 2);
  v_invoice_status public.invoice_status;
begin
  -- old.status is distinct from new.status covers BOTH the normal INSERT
  -- case (OLD is NULL for an INSERT-triggered call, so OLD.status IS
  -- DISTINCT FROM anything) and the one UPDATE case that actually needs
  -- re-validating: a payment transitioning back to 'posted' from 'voided'
  -- (there is no un-void path in the app today, but the DB should not
  -- silently trust it if one is ever added or called directly). Excluding
  -- updates where status stays 'posted' unchanged is what keeps this from
  -- re-rejecting a harmless notes-only edit on an already-posted payment --
  -- new.amount always exceeds "the balance due after this same payment is
  -- already applied" for any real payment, so re-checking on every update
  -- would be a false positive, not a real one.
  if new.status = 'posted' and old.status is distinct from new.status then
    if new.amount is null or new.amount <= 0 then
      raise exception 'Payment amount must be greater than zero.';
    end if;

    select balance_due, status into v_balance, v_invoice_status
    from public.invoices
    where id = new.invoice_id
    for update;

    if v_invoice_status is null then
      raise exception 'Invoice not found.';
    end if;

    if v_invoice_status = 'void' then
      raise exception 'Cannot record a payment against a void invoice.';
    end if;

    if new.amount > v_balance then
      raise exception 'Payment amount ($%) exceeds the invoice balance due ($%). Overpayment is not supported -- record a partial payment for the remaining balance instead.', new.amount, v_balance;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists payments_guard_amount on public.payments;
create trigger payments_guard_amount
  before insert or update on public.payments
  for each row execute function public.guard_payment_amount();

-- ---------------------------------------------------------------------------
-- apply_payment_to_invoice(): replaces the 0009 version to (a) only count
-- status = 'posted' payments -- a voided payment must stop counting toward
-- amount_paid the moment it's voided, since this trigger also fires on
-- UPDATE -- and (b) correctly revert status back to 'sent' when total_paid
-- drops back to 0 (e.g. the only payment on an invoice gets voided), which
-- the original version left stuck at whatever it was. Never auto-transitions
-- draft/void/disputed -- those are workflow states this rollup has no
-- business overriding.
-- ---------------------------------------------------------------------------
create or replace function public.apply_payment_to_invoice()
returns trigger
language plpgsql
as $$
declare
  v_invoice_id uuid;
  v_total_paid numeric(10, 2);
  v_invoice_total numeric(10, 2);
  v_current_status public.invoice_status;
begin
  v_invoice_id := coalesce(new.invoice_id, old.invoice_id);

  select coalesce(sum(amount) filter (where status = 'posted'), 0) into v_total_paid
  from public.payments
  where invoice_id = v_invoice_id;

  select total_amount, status into v_invoice_total, v_current_status
  from public.invoices where id = v_invoice_id;

  if v_current_status is null then
    return null; -- invoice row itself is gone (cascade delete); nothing to update
  end if;

  update public.invoices
  set amount_paid = v_total_paid,
      status = case
        when v_current_status in ('draft', 'void', 'disputed') then v_current_status
        when v_total_paid <= 0 then 'sent'
        when v_invoice_total > 0 and v_total_paid >= v_invoice_total then 'paid'
        else 'partially_paid'
      end,
      paid_at = case when v_invoice_total > 0 and v_total_paid >= v_invoice_total then now() else null end
  where id = v_invoice_id;

  return null;
end;
$$;

-- Trigger definition itself (name/table/timing/columns) is unchanged from
-- 0009 -- only the function body above changed, via create or replace.
drop trigger if exists payments_apply_to_invoice on public.payments;
create trigger payments_apply_to_invoice
  after insert or update or delete on public.payments
  for each row execute function public.apply_payment_to_invoice();

-- ---------------------------------------------------------------------------
-- Guard against contradictory manually-set invoice statuses (e.g. staff
-- picking "Paid" from the status dropdown on an invoice with a positive
-- balance). Only re-validates when status is actually CHANGING to a
-- payment-derived value -- never fires for recalculate_invoice_totals()'s
-- own updates (which never touch status) or any other unrelated edit, so
-- existing line-item editing keeps working exactly as before.
-- ---------------------------------------------------------------------------
create or replace function public.guard_invoice_status()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'paid' and new.amount_paid < new.total_amount then
      raise exception 'Cannot set invoice status to Paid: amount paid ($%) is less than the invoice total ($%). Record a payment for the remaining balance instead of setting this manually.', new.amount_paid, new.total_amount;
    end if;
    if new.status = 'partially_paid' and (new.amount_paid <= 0 or new.amount_paid >= new.total_amount) then
      raise exception 'Cannot set invoice status to Partially Paid manually -- this status is set automatically when a payment is recorded.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists invoices_guard_status on public.invoices;
create trigger invoices_guard_status
  before update on public.invoices
  for each row execute function public.guard_invoice_status();

-- ---------------------------------------------------------------------------
-- Overdue: derived, never stored. due_date < as-of AND balance_due > 0,
-- for any invoice not already paid/void/disputed/draft. Nothing mutates
-- invoices.status to 'overdue' on a schedule -- that would depend on a
-- cron job actually running and can go stale; deriving it on every read
-- instead means it's always correct the instant due_date passes, with zero
-- dependency on anyone opening the invoice page or a cron firing.
-- ---------------------------------------------------------------------------
create or replace function public.invoice_effective_status(
  p_status public.invoice_status,
  p_due_date date,
  p_balance_due numeric,
  p_as_of date default current_date
) returns public.invoice_status
language sql
stable
as $$
  select case
    when p_status in ('paid', 'void', 'disputed', 'draft') then p_status
    when p_due_date is not null and p_due_date < p_as_of and p_balance_due > 0 then 'overdue'::public.invoice_status
    else p_status
  end;
$$;

grant execute on function public.invoice_effective_status(public.invoice_status, date, numeric, date) to authenticated;

-- Aging bucket by due_date, relative to an as-of date (defaults to today).
-- Unpaid/no due date and not yet due both land in 'current'.
create or replace function public.ar_aging_bucket(p_due_date date, p_as_of date default current_date)
returns text
language sql
stable
as $$
  select case
    when p_due_date is null or p_due_date >= p_as_of then 'current'
    when p_as_of - p_due_date <= 30 then '1_30'
    when p_as_of - p_due_date <= 60 then '31_60'
    when p_as_of - p_due_date <= 90 then '61_90'
    else '90_plus'
  end;
$$;

grant execute on function public.ar_aging_bucket(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_ar_summary: the ONE canonical A/R aggregate -- Finance dashboard,
-- main Dashboard KPIs, and the Reports aging page all call this same
-- function so the same metric can never disagree across pages. Deliberately
-- NOT security definer (same reasoning as get_load_summary, 0021): it runs
-- with the caller's own privileges, so the existing RLS policy on
-- public.invoices/public.payments (organization_id = current_org_id())
-- applies exactly as it would to any other query -- this cannot see another
-- organization's receivables. p_broker_id/p_customer_id optionally scope it
-- to one party (used by Broker/Customer A/R sections); both null means the
-- whole org. p_as_of_date lets Reports ask "as of" a past date; defaults to
-- today for the live dashboard.
-- ---------------------------------------------------------------------------
create or replace function public.get_ar_summary(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_as_of_date date default current_date
)
returns table (
  total_receivables numeric,
  current_amount numeric,
  bucket_1_30 numeric,
  bucket_31_60 numeric,
  bucket_61_90 numeric,
  bucket_90_plus numeric,
  overdue_invoice_count bigint,
  overdue_amount numeric,
  collected_this_month numeric
)
language sql
stable
as $$
  with outstanding as (
    select i.balance_due, i.due_date
    from public.invoices i
    where i.status not in ('paid', 'void')
      and i.balance_due > 0
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  collected as (
    select coalesce(sum(p.amount), 0) as amt
    from public.payments p
    join public.invoices i on i.id = p.invoice_id
    where p.status = 'posted'
      and p.received_at >= date_trunc('month', p_as_of_date)
      and p.received_at < date_trunc('month', p_as_of_date) + interval '1 month'
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  )
  select
    coalesce(sum(o.balance_due), 0) as total_receivables,
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = 'current'), 0),
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = '1_30'), 0),
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = '31_60'), 0),
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = '61_90'), 0),
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) = '90_plus'), 0),
    count(*) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) <> 'current')::bigint,
    coalesce(sum(o.balance_due) filter (where public.ar_aging_bucket(o.due_date, p_as_of_date) <> 'current'), 0),
    (select amt from collected)
  from outstanding o;
$$;

grant execute on function public.get_ar_summary(uuid, uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_ar_invoices: the row source behind the Accounts Receivable table,
-- Reports drill-down, and Broker/Customer "Open Invoices" lists -- one
-- shared query so effective_status/aging_bucket/days_past_due can never be
-- computed differently on different pages. Excludes void invoices always;
-- p_status filters by the *effective* status (e.g. 'overdue'), not the
-- raw stored one, so filtering by "Overdue" actually matches what the
-- badge shows. Sorted oldest-due-first with a balance, matching the "most
-- overdue / oldest collectible invoices first" default the spec asks for.
-- ---------------------------------------------------------------------------
create or replace function public.get_ar_invoices(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_status text default null,
  p_as_of_date date default current_date
)
returns table (
  id uuid,
  invoice_number text,
  load_id uuid,
  load_number text,
  broker_id uuid,
  broker_name text,
  customer_id uuid,
  customer_name text,
  bill_to_name text,
  issue_date date,
  due_date date,
  total_amount numeric,
  amount_paid numeric,
  balance_due numeric,
  status public.invoice_status,
  effective_status public.invoice_status,
  aging_bucket text,
  days_past_due integer
)
language sql
stable
as $$
  select
    i.id, i.invoice_number, i.load_id, l.load_number,
    i.broker_id, b.company_name, i.customer_id, c.company_name,
    i.bill_to_name, i.issue_date, i.due_date,
    i.total_amount, i.amount_paid, i.balance_due,
    i.status,
    public.invoice_effective_status(i.status, i.due_date, i.balance_due, p_as_of_date),
    public.ar_aging_bucket(i.due_date, p_as_of_date),
    case when i.due_date is not null and i.due_date < p_as_of_date then (p_as_of_date - i.due_date) else 0 end
  from public.invoices i
  left join public.loads l on l.id = i.load_id
  left join public.brokers b on b.id = i.broker_id
  left join public.customers c on c.id = i.customer_id
  where i.status <> 'void'
    and (p_broker_id is null or i.broker_id = p_broker_id)
    and (p_customer_id is null or i.customer_id = p_customer_id)
    and (
      p_status is null
      or public.invoice_effective_status(i.status, i.due_date, i.balance_due, p_as_of_date)::text = p_status
    )
  order by
    case when i.balance_due > 0 then 0 else 1 end,
    i.due_date asc nulls last,
    i.issue_date asc;
$$;

grant execute on function public.get_ar_invoices(uuid, uuid, text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_party_ar_summary: Broker/Customer A/R + payment-behavior metrics.
-- avg_days_to_pay is computed ONLY from invoices that actually reached
-- 'paid', using that invoice's own latest posted payment date -- i.e. only
-- from data that actually exists, never estimated/fabricated. Returns null
-- (not 0) when there's no paid history yet; render that as "Not enough
-- data" rather than a fake 0-day average.
-- ---------------------------------------------------------------------------
create or replace function public.get_party_ar_summary(p_broker_id uuid default null, p_customer_id uuid default null)
returns table (
  total_billed numeric,
  total_paid numeric,
  outstanding numeric,
  past_due numeric,
  open_invoices bigint,
  paid_invoices bigint,
  oldest_unpaid_due_date date,
  avg_days_to_pay numeric
)
language sql
stable
as $$
  with scoped as (
    select i.*
    from public.invoices i
    where i.status <> 'void'
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  paid_durations as (
    select s.id, s.issue_date, max(p.received_at)::date as paid_date
    from scoped s
    join public.payments p on p.invoice_id = s.id and p.status = 'posted'
    where s.status = 'paid'
    group by s.id, s.issue_date
  )
  select
    coalesce((select sum(total_amount) from scoped), 0),
    coalesce((select sum(amount_paid) from scoped), 0),
    coalesce((select sum(balance_due) from scoped where balance_due > 0), 0),
    coalesce((select sum(balance_due) from scoped where balance_due > 0 and due_date is not null and due_date < current_date), 0),
    (select count(*) from scoped where balance_due > 0)::bigint,
    (select count(*) from scoped where status = 'paid')::bigint,
    (select min(due_date) from scoped where balance_due > 0),
    (select round(avg(paid_date - issue_date), 1) from paid_durations);
$$;

grant execute on function public.get_party_ar_summary(uuid, uuid) to authenticated;

-- =============================================================================
-- 0027_collections.sql
-- Collections & Overdue Management. Builds entirely on the A/R architecture
-- from 0026_accounts_receivable.sql -- invoice_effective_status(),
-- ar_aging_bucket(), get_ar_summary(), get_ar_invoices(),
-- get_party_ar_summary() are all reused, not reimplemented. No second A/R
-- calculation system, no change to the working payment/invoice/POD/
-- billing-packet workflow (the one extension to apply_payment_to_invoice()
-- below is strictly additive -- see that section).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Collections status: a separate concept from invoices.status (financial
-- state). Lives directly on invoices as a mutable "current state" column,
-- the same way invoices.status/amount_paid/paid_at already do -- consistent
-- with this schema's existing convention rather than a new 1:1 side table.
-- Staff-driven (advanced by collections actions, not derived), except the
-- 'resolved' transition on full payment (see apply_payment_to_invoice below).
-- ---------------------------------------------------------------------------
create type public.collection_status as enum (
  'not_started', 'contacted', 'follow_up', 'promise_to_pay', 'disputed', 'escalated', 'resolved'
);

alter table public.invoices
  add column collection_status public.collection_status not null default 'not_started',
  add column assigned_collector_id uuid references public.profiles (id) on delete set null;

create index idx_invoices_collection_status on public.invoices (collection_status) where status not in ('paid', 'void');
create index idx_invoices_assigned_collector on public.invoices (assigned_collector_id) where assigned_collector_id is not null;

-- A collector must belong to the SAME organization as the invoice -- a
-- cross-org profile id must never be assignable, checked at the DB level
-- (not just by only offering same-org options in the UI dropdown).
create or replace function public.guard_invoice_collector_assignment()
returns trigger
language plpgsql
as $$
declare
  v_collector_org uuid;
begin
  if new.assigned_collector_id is not null and old.assigned_collector_id is distinct from new.assigned_collector_id then
    select organization_id into v_collector_org from public.profiles where id = new.assigned_collector_id;
    if v_collector_org is null or v_collector_org <> new.organization_id then
      raise exception 'Assigned collector must belong to the same organization as the invoice.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists invoices_guard_collector_assignment on public.invoices;
create trigger invoices_guard_collector_assignment
  before insert or update on public.invoices
  for each row execute function public.guard_invoice_collector_assignment();

-- ---------------------------------------------------------------------------
-- apply_payment_to_invoice(): ADDITIVE extension only -- every existing
-- line (amount_paid rollup, status transitions draft/void/disputed-safe,
-- sent/partially_paid/paid, paid_at) is byte-for-byte unchanged from
-- 0026_accounts_receivable.sql. The only new line sets collection_status
-- to 'resolved' once an invoice becomes fully paid, satisfying "a paid
-- invoice leaves the active collection queue" (the queue itself already
-- excludes paid/void invoices via get_ar_invoices()'s own filter, this
-- just keeps the visible collection_status label in sync too). Never
-- touches collection_status in any other case -- an escalated/disputed
-- invoice that receives a partial payment keeps its collection_status
-- exactly as collectors left it.
-- ---------------------------------------------------------------------------
create or replace function public.apply_payment_to_invoice()
returns trigger
language plpgsql
as $$
declare
  v_invoice_id uuid;
  v_total_paid numeric(10, 2);
  v_invoice_total numeric(10, 2);
  v_current_status public.invoice_status;
begin
  v_invoice_id := coalesce(new.invoice_id, old.invoice_id);

  select coalesce(sum(amount) filter (where status = 'posted'), 0) into v_total_paid
  from public.payments
  where invoice_id = v_invoice_id;

  select total_amount, status into v_invoice_total, v_current_status
  from public.invoices where id = v_invoice_id;

  if v_current_status is null then
    return null;
  end if;

  update public.invoices
  set amount_paid = v_total_paid,
      status = case
        when v_current_status in ('draft', 'void', 'disputed') then v_current_status
        when v_total_paid <= 0 then 'sent'
        when v_invoice_total > 0 and v_total_paid >= v_invoice_total then 'paid'
        else 'partially_paid'
      end,
      paid_at = case when v_invoice_total > 0 and v_total_paid >= v_invoice_total then now() else null end,
      collection_status = case
        when v_invoice_total > 0 and v_total_paid >= v_invoice_total then 'resolved'::public.collection_status
        else collection_status
      end
  where id = v_invoice_id;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- invoice_collection_activity: the contact log / collection notes (spec
-- sections 4 and 5 are the same data from two angles -- one table serves
-- both). Append-only: no update/delete RLS policy is granted at all, the
-- same pattern activity_logs already uses (0007/0010) for an audit trail
-- that must never be edited from the client, not just "append-only by UI
-- convention".
-- ---------------------------------------------------------------------------
create type public.collection_contact_method as enum ('phone', 'email', 'sms', 'portal', 'other');

create table public.invoice_collection_activity (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  contact_method public.collection_contact_method not null default 'other',
  contact_name text,
  note text not null,
  next_follow_up_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create index idx_collection_activity_invoice on public.invoice_collection_activity (invoice_id, created_at desc);
create index idx_collection_activity_org on public.invoice_collection_activity (organization_id);
create index idx_collection_activity_followup on public.invoice_collection_activity (next_follow_up_at) where next_follow_up_at is not null;

alter table public.invoice_collection_activity enable row level security;

create policy invoice_collection_activity_select on public.invoice_collection_activity
  for select using (organization_id = public.current_org_id());

create policy invoice_collection_activity_insert on public.invoice_collection_activity
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- payment_promises: status column stores ONLY the two states a human
-- actually decides ('open' at creation, 'cancelled' if a collector calls
-- it off) -- kept/partially_kept/broken are derived on every read by
-- promise_effective_status(), never stored, so they can never go stale.
-- Documented rule (mirrors the exact worked examples in the spec):
--   1. status = 'cancelled'                          -> cancelled
--   2. applied_amount >= promised_amount              -> kept
--   3. expected_payment_date < as_of                  -> broken
--      (covers both zero AND partial payment once the expected date has
--      passed -- a partial payment does not protect a promise past its date)
--   4. applied_amount > 0 (and not yet past due)       -> partially_kept
--   5. otherwise                                       -> open
-- applied_amount = payment_promise_applied_amount() below: posted payments
-- on the invoice received ON OR AFTER promise_date, capped at
-- promised_amount -- payments that predate the promise never count toward
-- it (a promise can't be "kept" by money that arrived before it existed),
-- and a promise can never show more applied than it asked for.
-- ---------------------------------------------------------------------------
create type public.payment_promise_status as enum ('open', 'kept', 'partially_kept', 'broken', 'cancelled');

create table public.payment_promises (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  promised_amount numeric(10, 2) not null check (promised_amount > 0),
  promise_date date not null default current_date,
  expected_payment_date date not null,
  contact_person text,
  notes text,
  status public.payment_promise_status not null default 'open' check (status in ('open', 'cancelled')),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  cancelled_by uuid references public.profiles (id) on delete set null,
  cancelled_at timestamptz,
  cancelled_reason text
);

create index idx_payment_promises_invoice on public.payment_promises (invoice_id, created_at desc);
create index idx_payment_promises_org on public.payment_promises (organization_id);
create index idx_payment_promises_expected_date on public.payment_promises (expected_payment_date);

alter table public.payment_promises enable row level security;

create policy payment_promises_select on public.payment_promises
  for select using (organization_id = public.current_org_id());

create policy payment_promises_insert on public.payment_promises
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- update: the only mutation ever performed is cancellation (status ->
-- 'cancelled' + cancelled_by/at/reason) -- promised_amount/expected date/
-- promise_date are never edited in place, matching "avoid hard-delete /
-- avoid silently overwriting collection history". No delete policy.
create policy payment_promises_update on public.payment_promises
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

drop trigger if exists set_updated_at on public.payment_promises;
create trigger set_updated_at before update on public.payment_promises
  for each row execute function public.set_updated_at();

create or replace function public.payment_promise_applied_amount(
  p_invoice_id uuid,
  p_promise_date date,
  p_promised_amount numeric
) returns numeric
language sql
stable
as $$
  select least(
    coalesce(
      (select sum(amount) from public.payments
       where invoice_id = p_invoice_id
         and status = 'posted'
         and received_at >= p_promise_date::timestamptz),
      0
    ),
    p_promised_amount
  );
$$;

grant execute on function public.payment_promise_applied_amount(uuid, date, numeric) to authenticated;

create or replace function public.promise_effective_status(
  p_status public.payment_promise_status,
  p_applied_amount numeric,
  p_promised_amount numeric,
  p_expected_payment_date date,
  p_as_of date default current_date
) returns public.payment_promise_status
language sql
stable
as $$
  select case
    when p_status = 'cancelled' then 'cancelled'::public.payment_promise_status
    when p_applied_amount >= p_promised_amount then 'kept'::public.payment_promise_status
    when p_expected_payment_date < p_as_of then 'broken'::public.payment_promise_status
    when p_applied_amount > 0 then 'partially_kept'::public.payment_promise_status
    else 'open'::public.payment_promise_status
  end;
$$;

grant execute on function public.promise_effective_status(public.payment_promise_status, numeric, numeric, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- invoice_disputes: multiple rows per invoice are allowed over time (a
-- dispute can be reopened) -- "current" disputed amount is the sum of
-- still-open ones (status in open/under_review), computed inline wherever
-- needed, never a separately-maintained running total that could drift.
-- Resolution is an UPDATE to the SAME row (status/resolved_at/resolved_by/
-- resolution), not a delete -- the full history of what was disputed, why,
-- and how it was resolved stays on that one row permanently.
-- ---------------------------------------------------------------------------
create type public.invoice_dispute_status as enum ('open', 'under_review', 'resolved', 'rejected');
create type public.invoice_dispute_reason as enum (
  'rate_discrepancy', 'missing_pod', 'missing_rate_confirmation', 'lumper', 'detention',
  'shortage', 'damage', 'late_delivery', 'duplicate_invoice', 'billing_error', 'other'
);

create table public.invoice_disputes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  status public.invoice_dispute_status not null default 'open',
  reason public.invoice_dispute_reason not null default 'other',
  disputed_amount numeric(10, 2) not null check (disputed_amount > 0),
  broker_contact text,
  notes text,
  opened_by uuid references public.profiles (id) on delete set null,
  opened_at timestamptz not null default now(),
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  resolution text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_invoice_disputes_invoice on public.invoice_disputes (invoice_id, created_at desc);
create index idx_invoice_disputes_org on public.invoice_disputes (organization_id);
create index idx_invoice_disputes_status on public.invoice_disputes (status);

alter table public.invoice_disputes enable row level security;

create policy invoice_disputes_select on public.invoice_disputes
  for select using (organization_id = public.current_org_id());

create policy invoice_disputes_insert on public.invoice_disputes
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy invoice_disputes_update on public.invoice_disputes
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

drop trigger if exists set_updated_at on public.invoice_disputes;
create trigger set_updated_at before update on public.invoice_disputes
  for each row execute function public.set_updated_at();

-- Per-invoice dispute totals, reused by get_collections_queue() and the
-- Invoice Detail Collections section so "Total Balance / Disputed /
-- Undisputed" is computed identically everywhere.
create or replace function public.invoice_dispute_summary(p_invoice_id uuid)
returns table (disputed_amount numeric, dispute_status public.invoice_dispute_status)
language sql
stable
as $$
  select
    coalesce((select sum(disputed_amount) from public.invoice_disputes
              where invoice_id = p_invoice_id and status in ('open', 'under_review')), 0),
    (select status from public.invoice_disputes
     where invoice_id = p_invoice_id order by created_at desc limit 1);
$$;

grant execute on function public.invoice_dispute_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- invoice_reminders: state/history for reminder stages. No email provider
-- exists in this project (confirmed in 0024/billing-packet-actions.ts) --
-- rows are created in 'pending' and the send action attempts + records the
-- real outcome, exactly like sendBillingPacket()'s honest-failure pattern.
-- Nothing here ever marks a reminder 'sent' without an actual provider
-- succeeding. No unique constraint on (invoice_id, stage) -- that would
-- make an intentional, staff-requested resend impossible; the app layer
-- checks for an existing non-failed row first and requires an explicit
-- resend confirmation instead (see queueReminder in collections/actions.ts).
-- ---------------------------------------------------------------------------
create type public.invoice_reminder_stage as enum (
  'before_due', 'due_today', 'overdue_7', 'overdue_15', 'overdue_30', 'overdue_60', 'overdue_90_plus'
);
create type public.invoice_reminder_status as enum ('pending', 'sent', 'failed');

create table public.invoice_reminders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  stage public.invoice_reminder_stage not null,
  recipient_email text,
  status public.invoice_reminder_status not null default 'pending',
  error_message text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create index idx_invoice_reminders_invoice on public.invoice_reminders (invoice_id, created_at desc);
create index idx_invoice_reminders_org on public.invoice_reminders (organization_id);

alter table public.invoice_reminders enable row level security;

create policy invoice_reminders_select on public.invoice_reminders
  for select using (organization_id = public.current_org_id());

create policy invoice_reminders_insert on public.invoice_reminders
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy invoice_reminders_update on public.invoice_reminders
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- Which stage an invoice is currently at, purely for display/reminder-
-- eligibility purposes -- independent of whether any reminder has actually
-- been sent for it. "Highest milestone reached" (descending threshold
-- checks), the same style ar_aging_bucket()/invoice_collection_priority()
-- already use -- not equal-width ranges. Days 1-6 overdue haven't reached
-- any named milestone yet (the stages are exactly before_due/due_today/7/
-- 15/30/60/90+, nothing named for 1-6) so they stay at 'due_today', the
-- last milestone actually reached, rather than being awkwardly folded into
-- the 7-day stage before day 7 has actually arrived.
create or replace function public.invoice_reminder_stage_for(p_due_date date, p_as_of date default current_date)
returns public.invoice_reminder_stage
language sql
stable
as $$
  select case
    when p_due_date is null or p_due_date > p_as_of then 'before_due'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 90 then 'overdue_90_plus'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 60 then 'overdue_60'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 30 then 'overdue_30'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 15 then 'overdue_15'::public.invoice_reminder_stage
    when p_as_of - p_due_date >= 7 then 'overdue_7'::public.invoice_reminder_stage
    else 'due_today'::public.invoice_reminder_stage
  end;
$$;

grant execute on function public.invoice_reminder_stage_for(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- invoice_collection_priority: ONE deterministic function, used by
-- get_collections_queue() below and nowhere else recomputes it -- so the
-- Collections queue and any future consumer (e.g. the Dashboard alert)
-- can never disagree. IMMUTABLE: a pure function of its two inputs, no
-- current_date/table access inside it.
--
-- Formula (documented, not tunable from the UI):
--   URGENT : an active promise is BROKEN, OR 90+ days past due
--   HIGH   : 61-89 days past due
--   NORMAL : 1-60 days past due
--   LOW    : not yet due (current)
-- This intentionally mirrors the exact priority-group ordering the spec
-- asks the queue to sort by. Balance size and invoice age are NOT folded
-- into the tier itself -- they're the documented tie-breaker used only to
-- order rows *within* a tier (largest balance / oldest first), matching
-- "within a priority group, prefer larger balances/older invoices" instead
-- of secretly bumping a tier for a big balance. Disputes and contact
-- recency are deliberately NOT folded into the tier either: a disputed
-- invoice isn't necessarily "more urgent to collect" (it may need to PAUSE
-- pressure, not increase it) -- dispute_status and last_contact_at are
-- surfaced as their own queue columns/filters instead of being silently
-- baked into this score.
-- ---------------------------------------------------------------------------
create or replace function public.invoice_collection_priority(
  p_promise_effective_status public.payment_promise_status,
  p_days_past_due integer
) returns text
language sql
immutable
as $$
  select case
    when p_promise_effective_status = 'broken' then 'urgent'
    when p_days_past_due >= 90 then 'urgent'
    when p_days_past_due >= 61 then 'high'
    when p_days_past_due >= 1 then 'normal'
    else 'low'
  end;
$$;

grant execute on function public.invoice_collection_priority(public.payment_promise_status, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- broker_payment_risk: an explicitly INTERNAL, operational signal computed
-- only from this org's own payment history -- never call this a credit
-- score/rating anywhere in the UI (no external credit bureau is involved).
-- Documented formula (score 0-8, thresholds below):
--   +2 avg days to pay > 45          | +1 avg days to pay > 30
--   +1 has any past-due balance
--   +2 has any 90+ day balance
--   +2 has any BROKEN promise (ever, via promise_effective_status())
--   +1 has any OPEN/UNDER_REVIEW dispute
--   score >= 4 -> HIGH, score >= 2 -> MEDIUM, else LOW
-- Reuses get_party_ar_summary() for avg_days_to_pay/past_due rather than
-- recomputing them -- same single A/R source as everywhere else.
-- ---------------------------------------------------------------------------
create or replace function public.broker_payment_risk(p_broker_id uuid)
returns text
language sql
stable
as $$
  with party as (
    select * from public.get_party_ar_summary(p_broker_id, null)
  ),
  bal_90 as (
    select coalesce(sum(i.balance_due), 0) as amt
    from public.invoices i
    where i.broker_id = p_broker_id
      and i.status not in ('paid', 'void')
      and i.balance_due > 0
      and public.ar_aging_bucket(i.due_date) = '90_plus'
  ),
  broken as (
    select count(*) as cnt
    from public.payment_promises pp
    join public.invoices i on i.id = pp.invoice_id
    where i.broker_id = p_broker_id
      and public.promise_effective_status(
            pp.status,
            public.payment_promise_applied_amount(pp.invoice_id, pp.promise_date, pp.promised_amount),
            pp.promised_amount, pp.expected_payment_date
          ) = 'broken'
  ),
  disputes as (
    select count(*) as cnt
    from public.invoice_disputes d
    join public.invoices i on i.id = d.invoice_id
    where i.broker_id = p_broker_id and d.status in ('open', 'under_review')
  )
  select case
    when score >= 4 then 'high'
    when score >= 2 then 'medium'
    else 'low'
  end
  from (
    select
      (case when party.avg_days_to_pay > 45 then 2 when party.avg_days_to_pay > 30 then 1 else 0 end)
      + (case when party.past_due > 0 then 1 else 0 end)
      + (case when bal_90.amt > 0 then 2 else 0 end)
      + (case when broken.cnt > 0 then 2 else 0 end)
      + (case when disputes.cnt > 0 then 1 else 0 end)
      as score
    from party, bal_90, broken, disputes
  ) scored;
$$;

grant execute on function public.broker_payment_risk(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_collections_queue: THE canonical query for both the Collections
-- queue table and the Invoice Detail Collections section (pass p_invoice_id
-- to get exactly one row, status included, for a paid/void invoice too --
-- the queue-mode paid/void exclusion only applies when p_invoice_id is
-- null). Deliberately NOT security definer, same reasoning as
-- get_ar_invoices() -- runs with the caller's own RLS, so this can never
-- see another organization's collections data. Reuses
-- invoice_effective_status()/ar_aging_bucket() from 0026 rather than
-- recomputing balance/aging logic.
-- ---------------------------------------------------------------------------
create or replace function public.get_collections_queue(
  p_invoice_id uuid default null,
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_collector_id uuid default null,
  p_as_of_date date default current_date
)
returns table (
  id uuid,
  invoice_number text,
  load_id uuid,
  load_number text,
  broker_id uuid,
  broker_name text,
  customer_id uuid,
  customer_name text,
  bill_to_name text,
  issue_date date,
  due_date date,
  total_amount numeric,
  amount_paid numeric,
  balance_due numeric,
  status public.invoice_status,
  effective_status public.invoice_status,
  aging_bucket text,
  days_past_due integer,
  collection_status public.collection_status,
  assigned_collector_id uuid,
  assigned_collector_name text,
  last_contact_at timestamptz,
  last_contact_method public.collection_contact_method,
  next_follow_up_at timestamptz,
  promise_id uuid,
  promise_amount numeric,
  promise_expected_date date,
  promise_effective_status public.payment_promise_status,
  dispute_status public.invoice_dispute_status,
  disputed_amount numeric,
  undisputed_amount numeric,
  priority text
)
language sql
stable
as $$
  with base as (
    select i.*, l.load_number, b.company_name as broker_name, c.company_name as customer_name
    from public.invoices i
    left join public.loads l on l.id = i.load_id
    left join public.brokers b on b.id = i.broker_id
    left join public.customers c on c.id = i.customer_id
    where (p_invoice_id is null or i.id = p_invoice_id)
      and (p_invoice_id is not null or i.status not in ('paid', 'void'))
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
      and (p_collector_id is null or i.assigned_collector_id = p_collector_id)
  ),
  latest_activity as (
    select distinct on (invoice_id) invoice_id, contact_method, created_at, next_follow_up_at
    from public.invoice_collection_activity
    order by invoice_id, created_at desc
  ),
  latest_promise as (
    select distinct on (invoice_id) *
    from public.payment_promises
    order by invoice_id, created_at desc
  ),
  latest_dispute as (
    select distinct on (invoice_id) invoice_id, status
    from public.invoice_disputes
    order by invoice_id, created_at desc
  ),
  dispute_totals as (
    select invoice_id, sum(disputed_amount) as disputed_amount
    from public.invoice_disputes
    where status in ('open', 'under_review')
    group by invoice_id
  ),
  rows as (
    select
      base.id, base.invoice_number, base.load_id, base.load_number,
      base.broker_id, base.broker_name, base.customer_id, base.customer_name,
      base.bill_to_name, base.issue_date, base.due_date,
      base.total_amount, base.amount_paid, base.balance_due,
      base.status,
      public.invoice_effective_status(base.status, base.due_date, base.balance_due, p_as_of_date) as effective_status,
      public.ar_aging_bucket(base.due_date, p_as_of_date) as aging_bucket,
      (case when base.due_date is not null and base.due_date < p_as_of_date then (p_as_of_date - base.due_date) else 0 end) as days_past_due,
      base.collection_status,
      base.assigned_collector_id,
      prof.full_name as assigned_collector_name,
      la.created_at as last_contact_at,
      la.contact_method as last_contact_method,
      la.next_follow_up_at,
      lp.id as promise_id,
      lp.promised_amount as promise_amount,
      lp.expected_payment_date as promise_expected_date,
      (case when lp.id is null then null else
        public.promise_effective_status(
          lp.status,
          public.payment_promise_applied_amount(lp.invoice_id, lp.promise_date, lp.promised_amount),
          lp.promised_amount, lp.expected_payment_date, p_as_of_date
        )
      end) as promise_effective_status,
      ld.status as dispute_status,
      coalesce(dt.disputed_amount, 0) as disputed_amount,
      base.balance_due - coalesce(dt.disputed_amount, 0) as undisputed_amount
    from base
    left join public.profiles prof on prof.id = base.assigned_collector_id
    left join latest_activity la on la.invoice_id = base.id
    left join latest_promise lp on lp.invoice_id = base.id
    left join latest_dispute ld on ld.invoice_id = base.id
    left join dispute_totals dt on dt.invoice_id = base.id
  )
  select rows.*, public.invoice_collection_priority(rows.promise_effective_status, rows.days_past_due) as priority
  from rows
  -- Six-way sort group, finer-grained than the 4-tier priority column
  -- above (broken promises are pulled out ahead of plain 90+ overdue, and
  -- current-tier is additionally split into 1-30/due-soon) -- matching
  -- the exact ordering the spec lists for the queue's default sort.
  order by
    case
      when rows.promise_effective_status = 'broken' then 0
      when rows.aging_bucket = '90_plus' then 1
      when rows.aging_bucket = '61_90' then 2
      when rows.aging_bucket = '31_60' then 3
      when rows.aging_bucket = '1_30' then 4
      else 5
    end,
    rows.balance_due desc,
    rows.days_past_due desc;
$$;

grant execute on function public.get_collections_queue(uuid, uuid, uuid, uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_collections_summary: Collections dashboard KPIs. Reuses
-- get_ar_summary() (overdue amount/count, collected this month) and
-- get_party_ar_summary() (org-wide avg days to pay, via null/null) rather
-- than recomputing either -- only due_this_week/promises_due/
-- disputed_amount are genuinely new aggregates.
-- ---------------------------------------------------------------------------
create or replace function public.get_collections_summary(p_as_of_date date default current_date)
returns table (
  total_overdue numeric,
  overdue_invoices bigint,
  due_this_week numeric,
  promises_due bigint,
  disputed_amount numeric,
  collected_this_month numeric,
  avg_days_to_pay numeric
)
language sql
stable
as $$
  with ar as (
    select * from public.get_ar_summary(null, null, p_as_of_date)
  ),
  party as (
    select * from public.get_party_ar_summary(null, null)
  ),
  due_week as (
    select coalesce(sum(i.balance_due), 0) as amt
    from public.invoices i
    where i.status not in ('paid', 'void')
      and i.balance_due > 0
      and i.due_date is not null
      and i.due_date >= p_as_of_date
      and i.due_date <= p_as_of_date + 7
  ),
  promises_due as (
    select count(*) as cnt
    from public.payment_promises pp
    where pp.expected_payment_date <= p_as_of_date + 7
      and public.promise_effective_status(
            pp.status,
            public.payment_promise_applied_amount(pp.invoice_id, pp.promise_date, pp.promised_amount),
            pp.promised_amount, pp.expected_payment_date, p_as_of_date
          ) = 'open'
  ),
  disputes as (
    select coalesce(sum(disputed_amount), 0) as amt
    from public.invoice_disputes
    where status in ('open', 'under_review')
  )
  select ar.overdue_amount, ar.overdue_invoice_count, due_week.amt, promises_due.cnt, disputes.amt, ar.collected_this_month, party.avg_days_to_pay
  from ar, party, due_week, promises_due, disputes;
$$;

grant execute on function public.get_collections_summary(date) to authenticated;

-- =============================================================================
-- 0028_auto_invoice_dispatch_sync_fix.sql
-- Fixes the root cause of a real delivered load (LD-100014) never getting
-- its auto-generated draft invoice. The existing trigger from
-- 0022_auto_invoice_on_delivery.sql -- auto_generate_invoice_from_delivered_load(),
-- firing AFTER UPDATE on public.loads when status transitions into
-- 'delivered' -- is untouched and remains the single canonical automation.
-- Nothing here duplicates it, replaces it, or moves it into application code.
--
-- Two real, narrowly-scoped fixes:
--   1. ROOT CAUSE: dispatches.status and loads.status are two separate
--      columns on two separate tables. The Dispatch Board's drag-and-drop
--      (updateDispatchStatus) and the Dispatch Detail page's status field
--      (updateDispatch) both write ONLY dispatches.status -- neither ever
--      touches loads.status. So a dispatcher marking a dispatch
--      "Completed"/"Delivered" (a real, everyday action) never flips the
--      load itself to 'delivered', and the existing invoice trigger --
--      which only ever watches loads.status -- correctly never fires,
--      because that transition genuinely never happens on the loads table.
--      This is exactly what happened to LD-100014: its dispatch reached
--      status = 'completed' while the load itself stayed at 'dispatched'.
--      Fix: a new trigger on dispatches that, only when a dispatch
--      transitions into a delivered-equivalent status, updates the linked
--      load to 'delivered' (and only if the load hasn't already moved
--      past that point) -- which then fires the EXISTING loads trigger
--      exactly as if a dispatcher had set it by hand. Not security
--      definer: the loads/dispatches RLS update policies already grant
--      the identical role tier (owner/admin/dispatcher) on both tables
--      (0010_rls_policies.sql), so there is nothing to bypass.
--   2. Payment-terms fallback gap: the existing trigger fell back straight
--      to a hard-coded 30 when a broker/customer had no payment_terms_days
--      on file, silently skipping the organization's own
--      default_payment_terms_days column (added in 0014, already exists
--      for exactly this purpose). Fixed to consult it as the middle tier:
--      broker/customer terms -> organization default -> 30 as a final,
--      practically-unreachable safety net (organizations.default_payment_terms_days
--      is itself NOT NULL DEFAULT 30, so the bare literal only matters if
--      that column were ever nulled out directly).
-- =============================================================================

create or replace function public.auto_generate_invoice_from_delivered_load()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_to_name text;
  v_bill_to_email text;
  v_bill_to_address text;
  v_payment_terms integer;
  v_org_default_terms integer;
  v_invoice_number text;
  v_dispatch_id uuid;
  v_invoice_id uuid;
begin
  if NEW.status is distinct from 'delivered' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and OLD.status is not distinct from 'delivered' then
    return NEW;
  end if;

  if exists (select 1 from public.invoices where load_id = NEW.id) then
    return NEW;
  end if;

  if NEW.broker_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', address_line1, city, state, postal_code)), ''),
           payment_terms_days
      into v_bill_to_name, v_bill_to_email, v_bill_to_address, v_payment_terms
    from public.brokers where id = NEW.broker_id;
  elsif NEW.customer_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', billing_address_line1, city, state, postal_code)), ''),
           payment_terms_days
      into v_bill_to_name, v_bill_to_email, v_bill_to_address, v_payment_terms
    from public.customers where id = NEW.customer_id;
  else
    return NEW;
  end if;

  -- Organization default terms, used only when the broker/customer has no
  -- explicit payment_terms_days of their own -- see header comment.
  select default_payment_terms_days into v_org_default_terms
  from public.organizations where id = NEW.organization_id;

  select id into v_dispatch_id from public.dispatches where load_id = NEW.id limit 1;
  v_invoice_number := public.generate_invoice_number(NEW.organization_id);

  insert into public.invoices (
    organization_id, invoice_number, load_id, dispatch_id, broker_id, customer_id,
    status, bill_to_name, bill_to_email, bill_to_address,
    subtotal_amount, total_amount, issue_date, due_date, notes
  ) values (
    NEW.organization_id, v_invoice_number, NEW.id, v_dispatch_id, NEW.broker_id, NEW.customer_id,
    'draft', v_bill_to_name, v_bill_to_email, v_bill_to_address,
    NEW.rate, NEW.rate, current_date,
    current_date + coalesce(v_payment_terms, v_org_default_terms, 30),
    'Auto-generated on delivery for load ' || NEW.load_number
  )
  on conflict (load_id) where load_id is not null do nothing
  returning id into v_invoice_id;

  if v_invoice_id is not null then
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (NEW.organization_id, v_invoice_id, 'Freight charges -- Load ' || NEW.load_number, 1, NEW.rate, 0);

    perform public.log_activity('invoice', v_invoice_id, 'created');
  end if;

  return NEW;
end;
$$;

-- Trigger definition itself (name/table/timing/columns) is unchanged from
-- 0022 -- only the function body above changed, via create or replace.
drop trigger if exists auto_generate_invoice_on_delivery on public.loads;
create trigger auto_generate_invoice_on_delivery
  after update on public.loads
  for each row execute function public.auto_generate_invoice_from_delivered_load();

-- ---------------------------------------------------------------------------
-- The actual root-cause fix: propagate a dispatch reaching a
-- delivered-equivalent status onto its load, so the existing loads trigger
-- above has a real transition to fire on. Deliberately narrow: only fires
-- on a genuine transition INTO ('delivered', 'completed'), and only
-- touches the load if it hasn't already moved past 'delivered' on its own
-- (pod_received/invoiced/closed) or been cancelled -- never regresses a
-- load backwards, never overrides a status a dispatcher/accountant set
-- more specifically by hand afterward.
-- ---------------------------------------------------------------------------
create or replace function public.sync_load_status_from_dispatch()
returns trigger
language plpgsql
as $$
begin
  if NEW.status in ('delivered', 'completed') and OLD.status is distinct from NEW.status then
    update public.loads
    set status = 'delivered'
    where id = NEW.load_id
      and status not in ('delivered', 'pod_received', 'invoiced', 'closed', 'cancelled');
  end if;
  return NEW;
end;
$$;

drop trigger if exists dispatches_sync_load_status on public.dispatches;
create trigger dispatches_sync_load_status
  after update on public.dispatches
  for each row execute function public.sync_load_status_from_dispatch();


-- =============================================================================
-- 0029_statements.sql
-- Broker/Customer Statements. Reuses the existing invoice/payment schema
-- and the canonical A/R functions from 0026_accounts_receivable.sql
-- (invoice_effective_status, ar_aging_bucket, get_ar_summary,
-- get_ar_invoices, get_party_ar_summary) -- no second financial system, no
-- duplicate balance/aging calculation. Only two genuinely new aggregates
-- are added (opening balance reconstruction + the period ledger), since
-- nothing existing can answer "what did this party owe as of a past date".
-- =============================================================================

create type public.statement_party_type as enum ('broker', 'customer');
create type public.statement_type as enum ('open_balance', 'period', 'aging');
create type public.statement_status as enum ('draft', 'generated', 'sent');

-- Concurrency-safe numbering, identical pattern to generate_payment_number()
-- (0026_accounts_receivable.sql) -- nextval() on a sequence is atomic under
-- concurrent inserts by construction.
create sequence public.statement_number_seq;

create or replace function public.generate_statement_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  return 'STM-' || lpad(nextval('public.statement_number_seq')::text, 6, '0');
end;
$$;

grant execute on function public.generate_statement_number() to authenticated;

-- ---------------------------------------------------------------------------
-- statements: one row per generated statement (a version/snapshot), never
-- edited in place -- same "append, don't overwrite history" pattern as
-- billing_packets (0024_billing_packets.sql). snapshot freezes exactly
-- which invoice/payment IDs were included and the computed totals, so a
-- previously-sent statement can never silently change if invoices/payments
-- are edited afterward.
-- ---------------------------------------------------------------------------
create table public.statements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  statement_number text not null default public.generate_statement_number(),
  party_type public.statement_party_type not null,
  broker_id uuid references public.brokers (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  statement_type public.statement_type not null,
  period_start date,
  period_end date,
  as_of_date date not null default current_date,
  opening_balance numeric(12, 2) not null default 0,
  closing_balance numeric(12, 2) not null default 0,
  status public.statement_status not null default 'generated',
  storage_path text,
  snapshot jsonb not null default '{}'::jsonb,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.profiles (id) on delete set null,
  sent_at timestamptz,
  sent_by uuid references public.profiles (id) on delete set null,
  recipient_email text,
  created_at timestamptz not null default now(),
  unique (statement_number),
  constraint statements_exactly_one_party check (
    (party_type = 'broker' and broker_id is not null and customer_id is null)
    or (party_type = 'customer' and customer_id is not null and broker_id is null)
  ),
  constraint statements_period_bounds check (
    statement_type <> 'period' or (period_start is not null and period_end is not null and period_start <= period_end)
  )
);

comment on table public.statements is
  'One row per generated statement (a snapshot), never overwritten -- regenerating creates a new row. snapshot freezes the exact invoice/payment IDs and totals a party saw at generation time.';

create index idx_statements_org on public.statements (organization_id, generated_at desc);
create index idx_statements_broker on public.statements (broker_id, generated_at desc) where broker_id is not null;
create index idx_statements_customer on public.statements (customer_id, generated_at desc) where customer_id is not null;

alter table public.statements enable row level security;

-- Same access tier as invoices/billing_packets: select any org member,
-- write owner/admin/accountant. Delete is granted only for the same
-- reason billing_packets_delete exists (0025_billing_packet_race_hardening.sql)
-- -- app-level rollback of a reservation whose PDF upload failed, never
-- used to remove a successfully generated statement.
create policy statements_select on public.statements
  for select using (organization_id = public.current_org_id());

create policy statements_insert on public.statements
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy statements_update on public.statements
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy statements_delete on public.statements
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- Private storage bucket for generated statement PDFs. Same shape as
-- billing-packets (0024/0025): org-folder-prefix RLS, signed URLs only,
-- delete policy included from the start (learned from having to add it
-- retroactively for billing_packets) so the reserve-then-upload-then-
-- rollback-on-failure pattern works immediately.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('statements', 'statements', false, 26214400, array['application/pdf'])
on conflict (id) do nothing;

create policy statements_storage_select on storage.objects
  for select using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

create policy statements_storage_insert on storage.objects
  for insert with check (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy statements_storage_delete on storage.objects
  for delete using (
    bucket_id = 'statements'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- get_statement_opening_balance: what a party owed at the END of the day
-- BEFORE a given date -- i.e. the balance carried into a period statement
-- starting on that date. Reconstructed from history (every non-void
-- invoice issued on/before the cutoff, minus every posted payment received
-- on/before the cutoff), NOT read from invoices.balance_due (which is only
-- ever the CURRENT live balance, not a point-in-time figure). Deliberately
-- NOT security definer -- runs with the caller's own RLS, identical
-- reasoning to get_ar_summary()/get_ar_invoices() (0026): this cannot see
-- another organization's invoices/payments, because the underlying SELECTs
-- are subject to the exact same RLS policies any other query would be.
-- ---------------------------------------------------------------------------
create or replace function public.get_statement_opening_balance(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_cutoff_date date default current_date - 1
)
returns numeric
language sql
stable
as $$
  with scoped_invoices as (
    select i.id, i.total_amount
    from public.invoices i
    where i.status <> 'void'
      and i.issue_date <= p_cutoff_date
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  charges as (
    select coalesce(sum(total_amount), 0) as amt from scoped_invoices
  ),
  posted_payments as (
    select coalesce(sum(p.amount), 0) as amt
    from public.payments p
    join scoped_invoices si on si.id = p.invoice_id
    where p.status = 'posted'
      and p.received_at::date <= p_cutoff_date
  )
  select (select amt from charges) - (select amt from posted_payments);
$$;

grant execute on function public.get_statement_opening_balance(uuid, uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_statement_period_summary: Opening Balance + Period Charges - Period
-- Payments = Closing Balance, exactly the formula in the spec. Period
-- Charges = non-void invoices ISSUED within [start, end]; Period Payments
-- = POSTED payments RECEIVED within [start, end] (voided payments never
-- reduce the balance, matching apply_payment_to_invoice()'s own posted-only
-- rollup). Closing balance necessarily reconciles to the live A/R balance
-- for that party as of period_end, because both are built from the same
-- underlying invoices/payments rows filtered the same way.
-- ---------------------------------------------------------------------------
create or replace function public.get_statement_period_summary(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_period_start date default date_trunc('month', current_date)::date,
  p_period_end date default current_date
)
returns table (opening_balance numeric, period_charges numeric, period_payments numeric, closing_balance numeric)
language sql
stable
as $$
  with charges as (
    select coalesce(sum(i.total_amount), 0) as amt
    from public.invoices i
    where i.status <> 'void'
      and i.issue_date >= p_period_start
      and i.issue_date <= p_period_end
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  pmts as (
    select coalesce(sum(p.amount), 0) as amt
    from public.payments p
    join public.invoices i on i.id = p.invoice_id
    where p.status = 'posted'
      and p.received_at::date >= p_period_start
      and p.received_at::date <= p_period_end
      and i.status <> 'void'
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  ),
  opening as (
    select public.get_statement_opening_balance(p_broker_id, p_customer_id, p_period_start - 1) as amt
  )
  select
    opening.amt,
    charges.amt,
    pmts.amt,
    opening.amt + charges.amt - pmts.amt
  from opening, charges, pmts;
$$;

grant execute on function public.get_statement_period_summary(uuid, uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- get_statement_transactions: the chronological ledger for a Period
-- Statement -- one row per invoice issued and per payment (posted or
-- voided) received within the window, running_balance computed as
-- opening_balance + a cumulative window sum. Voided payments are included
-- for visibility (spec section 13, "reversals must remain visible") but
-- contribute 0 to both payment_amount and the running balance -- shown
-- with is_voided=true so the UI can render "VOIDED" without them ever
-- affecting the math. Sort order is chronological with invoices before
-- same-day payments (a same-day invoice+payment reads naturally as
-- charge-then-payment), a stable secondary key on id.
-- ---------------------------------------------------------------------------
create or replace function public.get_statement_transactions(
  p_broker_id uuid default null,
  p_customer_id uuid default null,
  p_period_start date default date_trunc('month', current_date)::date,
  p_period_end date default current_date
)
returns table (
  txn_date date,
  txn_type text,
  reference text,
  load_id uuid,
  load_number text,
  description text,
  charge_amount numeric,
  payment_amount numeric,
  is_voided boolean,
  running_balance numeric
)
language sql
stable
as $$
  with opening as (
    select public.get_statement_opening_balance(p_broker_id, p_customer_id, p_period_start - 1) as amt
  ),
  rows as (
    select
      i.issue_date as txn_date,
      'invoice'::text as txn_type,
      i.invoice_number as reference,
      i.load_id,
      l.load_number,
      'Freight Charges'::text as description,
      i.total_amount as charge_amount,
      0::numeric as payment_amount,
      false as is_voided,
      0 as sort_order,
      i.id as tie_break
    from public.invoices i
    left join public.loads l on l.id = i.load_id
    where i.status <> 'void'
      and i.issue_date >= p_period_start
      and i.issue_date <= p_period_end
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)

    union all

    select
      p.received_at::date as txn_date,
      case when p.status = 'voided' then 'payment_void' else 'payment' end as txn_type,
      p.payment_number as reference,
      i.load_id,
      l.load_number,
      initcap(replace(p.method::text, '_', ' ')) || ' Payment' || (case when p.status = 'voided' then ' (Voided)' else '' end) as description,
      0::numeric as charge_amount,
      case when p.status = 'posted' then p.amount else 0 end as payment_amount,
      (p.status = 'voided') as is_voided,
      1 as sort_order,
      p.id as tie_break
    from public.payments p
    join public.invoices i on i.id = p.invoice_id
    left join public.loads l on l.id = i.load_id
    where i.status <> 'void'
      and p.received_at::date >= p_period_start
      and p.received_at::date <= p_period_end
      and (p_broker_id is null or i.broker_id = p_broker_id)
      and (p_customer_id is null or i.customer_id = p_customer_id)
  )
  select
    rows.txn_date, rows.txn_type, rows.reference, rows.load_id, rows.load_number, rows.description,
    rows.charge_amount, rows.payment_amount, rows.is_voided,
    (select amt from opening) + sum(rows.charge_amount - rows.payment_amount)
      over (order by rows.txn_date, rows.sort_order, rows.tie_break rows between unbounded preceding and current row)
      as running_balance
  from rows
  order by rows.txn_date, rows.sort_order, rows.tie_break;
$$;

grant execute on function public.get_statement_transactions(uuid, uuid, date, date) to authenticated;


-- =============================================================================
-- 0030_statement_party_org_guard.sql
-- Fixes a real bug found during live cross-org security testing of
-- 0029_statements.sql: statements_insert's RLS check only validates
-- organization_id = current_org_id() -- it never confirmed that broker_id/
-- customer_id (a foreign key into another org-scoped table) actually
-- belongs to THAT SAME organization. A user could insert a statement row
-- in their own org that references another organization's real broker_id,
-- exactly the way guard_invoice_collector_assignment() (0027_collections.sql)
-- already prevents for invoices.assigned_collector_id.
--
-- Impact was contained (no financial figures actually leaked -- every real
-- read path, get_ar_invoices()/get_statement_period_summary()/etc.,
-- re-derives its own numbers from RLS-scoped invoices/payments and would
-- have returned zero/empty for a cross-org id regardless), but the row
-- itself should never have been insertable at all.
-- =============================================================================

create or replace function public.guard_statement_party_org()
returns trigger
language plpgsql
as $$
declare
  v_party_org uuid;
begin
  if new.broker_id is not null then
    select organization_id into v_party_org from public.brokers where id = new.broker_id;
    if v_party_org is null or v_party_org <> new.organization_id then
      raise exception 'Statement broker must belong to the same organization as the statement.';
    end if;
  end if;

  if new.customer_id is not null then
    select organization_id into v_party_org from public.customers where id = new.customer_id;
    if v_party_org is null or v_party_org <> new.organization_id then
      raise exception 'Statement customer must belong to the same organization as the statement.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists statements_guard_party_org on public.statements;
create trigger statements_guard_party_org
  before insert or update on public.statements
  for each row execute function public.guard_statement_party_org();




-- =============================================================================
-- 0031_driver_settlements.sql
-- Driver Settlement / Driver Pay. A deliberately SEPARATE system from the
-- existing carrier public.settlements/settlement_line_items (0006_financials.sql):
-- that table is carrier-centric (carrier_id not null, driver_id optional) --
-- money the dispatch company pays a CARRIER, who may then pay their own
-- driver outside this app. This migration adds direct DRIVER pay: a
-- driver-specific pay rate (percentage/per-mile/flat), calculated per
-- completed load, settled and paid directly to the driver. Reuses
-- drivers/loads/dispatches for the assignment relationship (no second
-- "driver trip" table), reuses public.payment_method for settlement
-- payment methods, and reuses public.dispatch_advances for driver
-- cash/fuel advances (extended with one nullable FK) rather than
-- duplicating advance-tracking. Never touches invoices/payments
-- (customer revenue) or the existing carrier settlements table.
-- =============================================================================

create type public.driver_pay_method as enum ('percentage', 'per_mile', 'flat_rate');
create type public.driver_settlement_status as enum ('draft', 'approved', 'partially_paid', 'paid', 'void');
create type public.driver_settlement_payment_status as enum ('posted', 'voided');
create type public.driver_settlement_adjustment_bucket as enum ('adjustment', 'deduction', 'advance');

-- ---------------------------------------------------------------------------
-- driver_pay_rates: effective-dated pay rules per driver. Exactly one
-- non-null rate column matching pay_method (percentage_rate / rate_per_mile
-- / flat_rate) -- "hourly" is deliberately NOT offered as a pay method:
-- no table anywhere in this schema (loads, dispatches) tracks hours worked,
-- so there is nothing to calculate hourly pay from (spec section 1: "Hourly
-- only if the existing schema already supports hours" -- it doesn't).
--
-- effective_to is managed automatically, not by the caller: inserting a
-- new rate for a driver closes out that driver's currently-open row
-- (effective_to is null) to the day before the new row's effective_from,
-- via guard_driver_pay_rate_effective_dates() below -- so there is always
-- at most one open-ended "current" rate per driver, and old rows are never
-- edited or deleted, only closed. This is what makes a later rate change
-- provably unable to alter an already-settled load's snapshot: settlement
-- items store their own frozen pay_rate (0031's driver_settlement_items),
-- never a live join back to this table.
-- ---------------------------------------------------------------------------
create table public.driver_pay_rates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  driver_id uuid not null references public.drivers (id) on delete cascade,
  pay_method public.driver_pay_method not null,
  percentage_rate numeric(5, 2),
  rate_per_mile numeric(6, 3),
  flat_rate numeric(10, 2),
  effective_from date not null default current_date,
  effective_to date,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  constraint driver_pay_rates_one_rate_matches_method check (
    (pay_method = 'percentage' and percentage_rate is not null and rate_per_mile is null and flat_rate is null)
    or (pay_method = 'per_mile' and rate_per_mile is not null and percentage_rate is null and flat_rate is null)
    or (pay_method = 'flat_rate' and flat_rate is not null and percentage_rate is null and rate_per_mile is null)
  ),
  constraint driver_pay_rates_valid_range check (effective_to is null or effective_to >= effective_from)
);

comment on table public.driver_pay_rates is
  'Effective-dated driver pay rules. Never edited/deleted in place -- a rate change closes the previous open row and inserts a new one. Settlement line items snapshot the rate actually used, so this table changing never retroactively changes a past settlement.';

create index idx_driver_pay_rates_driver on public.driver_pay_rates (driver_id, effective_from desc);

alter table public.driver_pay_rates enable row level security;

create policy driver_pay_rates_select on public.driver_pay_rates
  for select using (organization_id = public.current_org_id());

create policy driver_pay_rates_insert on public.driver_pay_rates
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- Same-organization guard for the driver_id FK, matching
-- guard_invoice_collector_assignment() (0027)/guard_statement_party_org()
-- (0030) -- a cross-org driver_id must never be insertable even though
-- the RLS check above only validates organization_id on the rate row
-- itself.
create or replace function public.guard_driver_pay_rate_driver_org()
returns trigger
language plpgsql
as $$
declare
  v_driver_org uuid;
begin
  select organization_id into v_driver_org from public.drivers where id = new.driver_id;
  if v_driver_org is null or v_driver_org <> new.organization_id then
    raise exception 'Driver pay rate must belong to the same organization as the driver.';
  end if;
  return new;
end;
$$;

drop trigger if exists driver_pay_rates_guard_driver_org on public.driver_pay_rates;
create trigger driver_pay_rates_guard_driver_org
  before insert on public.driver_pay_rates
  for each row execute function public.guard_driver_pay_rate_driver_org();

-- Auto-close the previously-open rate row for this driver so ranges never
-- overlap, then let the new row insert as the new open-ended current rate.
create or replace function public.guard_driver_pay_rate_effective_dates()
returns trigger
language plpgsql
as $$
declare
  v_open_id uuid;
  v_open_from date;
begin
  select id, effective_from into v_open_id, v_open_from
  from public.driver_pay_rates
  where driver_id = new.driver_id and effective_to is null
  for update;

  if v_open_id is not null then
    if new.effective_from <= v_open_from then
      raise exception 'New pay rate effective date (%) must be after the currently active rate''s effective date (%).', new.effective_from, v_open_from;
    end if;
    update public.driver_pay_rates set effective_to = new.effective_from - 1 where id = v_open_id;
  end if;

  -- Safety net against any other overlap (e.g. a backdated historical
  -- correction insert) beyond the simple "close the open row" case above.
  if exists (
    select 1 from public.driver_pay_rates
    where driver_id = new.driver_id
      and id is distinct from new.id
      and daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]') && daterange(new.effective_from, coalesce(new.effective_to, 'infinity'::date), '[]')
  ) then
    raise exception 'This pay rate''s effective date range overlaps an existing rate for this driver.';
  end if;

  return new;
end;
$$;

drop trigger if exists driver_pay_rates_guard_dates on public.driver_pay_rates;
create trigger driver_pay_rates_guard_dates
  before insert on public.driver_pay_rates
  for each row execute function public.guard_driver_pay_rate_effective_dates();

-- ---------------------------------------------------------------------------
-- calculate_driver_load_pay: THE canonical pay calculation -- selects the
-- driver_pay_rates row effective as of p_as_of_date (defaulting to the
-- dispatch's own completed_at/dispatched_at, i.e. when the load actually
-- moved), then computes gross pay from dispatches.load_rate (the
-- snapshot taken at dispatch time, 0004_operations.sql -- not a live
-- loads.rate re-read) and loads.total_miles. Deliberately NOT security
-- definer -- runs with the caller's own RLS on dispatches/loads/
-- driver_pay_rates, same reasoning as get_ar_invoices()/get_statement_*().
-- This is the ONLY place percentage/per-mile/flat math is computed;
-- driver_settlement_items snapshots its result, nothing recomputes it
-- independently anywhere else.
-- ---------------------------------------------------------------------------
create or replace function public.calculate_driver_load_pay(
  p_driver_id uuid,
  p_load_id uuid,
  p_as_of_date date default null
)
returns table (
  dispatch_id uuid,
  load_number text,
  delivery_date date,
  miles numeric,
  load_rate numeric,
  pay_method public.driver_pay_method,
  pay_rate numeric,
  gross_pay numeric
)
language sql
stable
as $$
  with d as (
    select disp.id as dispatch_id, l.load_number, l.total_miles,
           disp.load_rate,
           coalesce(disp.completed_at, disp.dispatched_at)::date as delivery_date
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    where disp.driver_id = p_driver_id and disp.load_id = p_load_id
    order by disp.dispatched_at desc
    limit 1
  ),
  rate as (
    select dpr.pay_method, dpr.percentage_rate, dpr.rate_per_mile, dpr.flat_rate
    from public.driver_pay_rates dpr, d
    where dpr.driver_id = p_driver_id
      and dpr.effective_from <= coalesce(p_as_of_date, d.delivery_date)
      and (dpr.effective_to is null or dpr.effective_to >= coalesce(p_as_of_date, d.delivery_date))
    order by dpr.effective_from desc
    limit 1
  )
  select
    d.dispatch_id, d.load_number, d.delivery_date, d.total_miles, d.load_rate,
    rate.pay_method,
    case rate.pay_method
      when 'percentage' then rate.percentage_rate
      when 'per_mile' then rate.rate_per_mile
      when 'flat_rate' then rate.flat_rate
    end as pay_rate,
    case rate.pay_method
      when 'percentage' then round(d.load_rate * (rate.percentage_rate / 100.0), 2)
      when 'per_mile' then round(coalesce(d.total_miles, 0) * rate.rate_per_mile, 2)
      when 'flat_rate' then rate.flat_rate
      else null
    end as gross_pay
  from d left join rate on true;
$$;

grant execute on function public.calculate_driver_load_pay(uuid, uuid, date) to authenticated;

-- get_payable_loads() is defined further below, immediately after
-- driver_settlement_items is created -- its body references that table
-- (to exclude already-settled loads), and unlike PL/pgSQL, a LANGUAGE SQL
-- function's body is parsed against the catalog at CREATE time, so it
-- must physically follow every table/function it references in this file.

-- ---------------------------------------------------------------------------
-- Numbering: same concurrency-safe sequence-default pattern as
-- generate_payment_number()/generate_statement_number() (0026/0029).
-- ---------------------------------------------------------------------------
create sequence public.driver_settlement_number_seq;
create or replace function public.generate_driver_settlement_number()
returns text language plpgsql security definer set search_path = public as $$
begin
  return 'SET-' || lpad(nextval('public.driver_settlement_number_seq')::text, 6, '0');
end;
$$;
grant execute on function public.generate_driver_settlement_number() to authenticated;

create sequence public.driver_settlement_payment_number_seq;
create or replace function public.generate_driver_settlement_payment_number()
returns text language plpgsql security definer set search_path = public as $$
begin
  -- Deliberately DSPAY- (not PAY-, which invoice payments already use --
  -- spec section 22: "Do not reuse invoice payment numbers if that causes
  -- ambiguity").
  return 'DSPAY-' || lpad(nextval('public.driver_settlement_payment_number_seq')::text, 6, '0');
end;
$$;
grant execute on function public.generate_driver_settlement_payment_number() to authenticated;

-- ---------------------------------------------------------------------------
-- driver_settlements: one row per settlement (a period for one driver).
-- carrier_id is snapshotted from drivers.carrier_id at creation time (every
-- driver belongs to exactly one carrier, 0003_fleet_and_partners.sql) --
-- purely informational display ("Carrier/Company" header field), never a
-- second carrier-settlement relationship. gross_pay/adjustments_amount/
-- deductions_amount/advances_amount/amount_paid are maintained by triggers
-- below (recalculate_driver_settlement_totals/apply_driver_settlement_payment),
-- exactly mirroring how invoices.subtotal_amount/amount_paid work
-- (0006/0009/0026) -- net_pay and balance_due are generated columns, the
-- single source of truth, never independently recomputed elsewhere.
-- ---------------------------------------------------------------------------
create table public.driver_settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  settlement_number text not null default public.generate_driver_settlement_number(),
  driver_id uuid not null references public.drivers (id) on delete restrict,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  period_start date not null,
  period_end date not null,
  status public.driver_settlement_status not null default 'draft',
  gross_pay numeric(12, 2) not null default 0,
  adjustments_amount numeric(12, 2) not null default 0,
  deductions_amount numeric(12, 2) not null default 0,
  advances_amount numeric(12, 2) not null default 0,
  net_pay numeric(12, 2) generated always as (gross_pay + adjustments_amount - deductions_amount - advances_amount) stored,
  amount_paid numeric(12, 2) not null default 0,
  balance_due numeric(12, 2) generated always as (gross_pay + adjustments_amount - deductions_amount - advances_amount - amount_paid) stored,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  approved_at timestamptz,
  approved_by uuid references public.profiles (id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references public.profiles (id) on delete set null,
  void_reason text,
  unique (organization_id, settlement_number),
  constraint driver_settlements_valid_period check (period_end >= period_start),
  constraint driver_settlements_void_requires_reason check (status <> 'void' or void_reason is not null)
);

comment on table public.driver_settlements is
  'One driver, one period, per row. Never deleted -- void + reissue is the only correction path. gross_pay/adjustments/deductions/advances are maintained by triggers from driver_settlement_items/driver_settlement_adjustments; amount_paid from driver_settlement_payments.';

create index idx_driver_settlements_driver on public.driver_settlements (driver_id, period_start desc);
create index idx_driver_settlements_org on public.driver_settlements (organization_id, created_at desc);

alter table public.driver_settlements enable row level security;

create policy driver_settlements_select on public.driver_settlements
  for select using (organization_id = public.current_org_id());

create policy driver_settlements_insert on public.driver_settlements
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy driver_settlements_update on public.driver_settlements
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

drop trigger if exists set_updated_at on public.driver_settlements;
-- (no updated_at column by design -- every mutation is either a
-- trigger-maintained rollup or an explicit approved_at/voided_at field)

-- Same-org guard for driver_id/carrier_id, matching the pattern used
-- throughout this session for every cross-table FK on a tenant row.
create or replace function public.guard_driver_settlement_org()
returns trigger
language plpgsql
as $$
declare
  v_driver_org uuid;
  v_driver_carrier uuid;
begin
  select organization_id, carrier_id into v_driver_org, v_driver_carrier from public.drivers where id = new.driver_id;
  if v_driver_org is null or v_driver_org <> new.organization_id then
    raise exception 'Settlement driver must belong to the same organization.';
  end if;
  -- carrier_id is a snapshot of the driver's own carrier -- never
  -- independently chosen, so this also guarantees it can't drift from
  -- the driver's real carrier.
  if new.carrier_id is distinct from v_driver_carrier then
    raise exception 'Settlement carrier must match the driver''s own carrier.';
  end if;
  return new;
end;
$$;

drop trigger if exists driver_settlements_guard_org on public.driver_settlements;
create trigger driver_settlements_guard_org
  before insert on public.driver_settlements
  for each row execute function public.guard_driver_settlement_org();

-- ---------------------------------------------------------------------------
-- driver_settlement_items: the load-pay snapshot (spec section 9). Every
-- numeric column is frozen at insert time from calculate_driver_load_pay()
-- -- a later driver_pay_rates change, or even a later loads/dispatches
-- edit, can never silently alter an already-added item.
-- ---------------------------------------------------------------------------
create table public.driver_settlement_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  driver_settlement_id uuid not null references public.driver_settlements (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete restrict,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  load_number text not null,
  delivery_date date,
  miles numeric(8, 2),
  load_rate numeric(10, 2) not null,
  pay_method public.driver_pay_method not null,
  pay_rate numeric(10, 4) not null,
  gross_pay numeric(10, 2) not null,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null
);

comment on table public.driver_settlement_items is
  'Frozen load-pay snapshot: load_rate/pay_method/pay_rate/gross_pay are copied from calculate_driver_load_pay() at the moment the load is added, never a live recalculation.';

create index idx_driver_settlement_items_settlement on public.driver_settlement_items (driver_settlement_id);
create index idx_driver_settlement_items_load on public.driver_settlement_items (load_id);

alter table public.driver_settlement_items enable row level security;

create policy driver_settlement_items_select on public.driver_settlement_items
  for select using (organization_id = public.current_org_id());

create policy driver_settlement_items_insert on public.driver_settlement_items
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy driver_settlement_items_delete on public.driver_settlement_items
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- Duplicate protection (spec section 16): a load already in an active
-- (non-void) settlement can never be added to another one. Locks the
-- candidate load's dispatch row for the rest of this transaction so two
-- concurrent "add this load" attempts can't both pass the check before
-- either commits -- same technique as guard_payment_amount()'s
-- `for update` (0026).
create or replace function public.guard_driver_settlement_item_duplicate()
returns trigger
language plpgsql
as $$
declare
  v_settlement_status public.driver_settlement_status;
begin
  select status into v_settlement_status from public.driver_settlements where id = new.driver_settlement_id;
  if v_settlement_status is null then
    raise exception 'Settlement not found.';
  end if;
  if v_settlement_status <> 'draft' then
    raise exception 'Cannot add loads to a settlement that is not in draft status.';
  end if;

  perform 1 from public.loads where id = new.load_id for update;

  if exists (
    select 1 from public.driver_settlement_items dsi
    join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
    where dsi.load_id = new.load_id and ds.status <> 'void'
  ) then
    raise exception 'This load is already included in an active driver settlement.';
  end if;

  return new;
end;
$$;

drop trigger if exists driver_settlement_items_guard_duplicate on public.driver_settlement_items;
create trigger driver_settlement_items_guard_duplicate
  before insert on public.driver_settlement_items
  for each row execute function public.guard_driver_settlement_item_duplicate();

-- Deletion (removing an eligible load before approval, spec section 17)
-- only allowed while the parent settlement is still draft.
create or replace function public.guard_driver_settlement_item_delete()
returns trigger
language plpgsql
as $$
declare
  v_status public.driver_settlement_status;
begin
  select status into v_status from public.driver_settlements where id = old.driver_settlement_id;
  if v_status is distinct from 'draft' then
    raise exception 'Cannot remove a load from a settlement that is not in draft status.';
  end if;
  return old;
end;
$$;

drop trigger if exists driver_settlement_items_guard_delete on public.driver_settlement_items;
create trigger driver_settlement_items_guard_delete
  before delete on public.driver_settlement_items
  for each row execute function public.guard_driver_settlement_item_delete();

-- ---------------------------------------------------------------------------
-- get_payable_loads: eligible-for-settlement loads for a driver/period --
-- delivered/completed (COMPLETED_LOAD_STATUSES, src/lib/loads/status.ts:
-- 'delivered'/'pod_received'), assigned to this driver via dispatches
-- (the canonical assignment relationship, spec section 4), within the
-- period by delivery date, and NOT already included in any non-void
-- settlement (not exists, mirroring get_ar_invoices()'s own exclusion
-- style). Never returns pending/assigned/in-transit/cancelled loads --
-- those statuses never appear in COMPLETED_LOAD_STATUSES. Defined here,
-- after driver_settlement_items/driver_settlements exist, since its body
-- references both.
-- ---------------------------------------------------------------------------
create or replace function public.get_payable_loads(
  p_driver_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  load_id uuid,
  dispatch_id uuid,
  load_number text,
  pickup_city text,
  pickup_state text,
  delivery_city text,
  delivery_state text,
  delivery_date date,
  miles numeric,
  load_rate numeric,
  pay_method public.driver_pay_method,
  pay_rate numeric,
  gross_pay numeric
)
language sql
stable
as $$
  with candidates as (
    select disp.id as dispatch_id, l.id as load_id
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    where disp.driver_id = p_driver_id
      and l.status in ('delivered', 'pod_received')
      and coalesce(disp.completed_at, disp.dispatched_at)::date between p_period_start and p_period_end
      and not exists (
        select 1 from public.driver_settlement_items dsi
        join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
        where dsi.load_id = l.id and ds.status <> 'void'
      )
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as pickup_city,
           max(state) filter (where stop_type = 'pickup') as pickup_state,
           max(city) filter (where stop_type = 'delivery') as delivery_city,
           max(state) filter (where stop_type = 'delivery') as delivery_state
    from public.load_stops
    where load_id in (select load_id from candidates)
    group by load_id
  )
  select
    c.load_id, c.dispatch_id, p.load_number, s.pickup_city, s.pickup_state, s.delivery_city, s.delivery_state,
    p.delivery_date, p.miles, p.load_rate, p.pay_method, p.pay_rate, p.gross_pay
  from candidates c
  left join stops s on s.load_id = c.load_id
  cross join lateral public.calculate_driver_load_pay(p_driver_id, c.load_id) p
  order by p.delivery_date asc nulls last;
$$;

grant execute on function public.get_payable_loads(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- driver_settlement_adjustments: adjustments / deductions / advances
-- (spec sections 10-13). bucket classifies which of the three settlement
-- totals this row rolls into; amount is signed for bucket='adjustment'
-- (a positive adjustment is a bonus/credit, a negative one reduces pay)
-- but must be a positive magnitude for 'deduction'/'advance' (always
-- subtracted -- the settlement formula in 0031 already subtracts them).
-- linked_advance_id optionally connects an existing public.dispatch_advances
-- row (spec section 12: "connect it... do not create duplicate advance
-- records") rather than re-entering the same advance manually.
-- ---------------------------------------------------------------------------
create table public.driver_settlement_adjustments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  driver_settlement_id uuid not null references public.driver_settlements (id) on delete cascade,
  bucket public.driver_settlement_adjustment_bucket not null,
  category text not null,
  amount numeric(10, 2) not null,
  description text,
  source_reference text,
  linked_advance_id uuid references public.dispatch_advances (id) on delete set null,
  effective_date date not null default current_date,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  constraint driver_settlement_adjustments_magnitude check (bucket = 'adjustment' or amount > 0)
);

comment on table public.driver_settlement_adjustments is
  'Manual adjustments/deductions/advances against a settlement. category is free text (spec: "do not invent deductions automatically" -- staff type whatever applies, e.g. Fuel Advance/Tolls/Lumper/Damage/Equipment/Insurance/Other) rather than a rigid enum of every possible deduction type.';

create index idx_driver_settlement_adjustments_settlement on public.driver_settlement_adjustments (driver_settlement_id);

alter table public.driver_settlement_adjustments enable row level security;

create policy driver_settlement_adjustments_select on public.driver_settlement_adjustments
  for select using (organization_id = public.current_org_id());

create policy driver_settlement_adjustments_insert on public.driver_settlement_adjustments
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy driver_settlement_adjustments_delete on public.driver_settlement_adjustments
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create or replace function public.guard_driver_settlement_adjustment_draft()
returns trigger
language plpgsql
as $$
declare
  v_status public.driver_settlement_status;
  v_id uuid;
begin
  v_id := coalesce(new.driver_settlement_id, old.driver_settlement_id);
  select status into v_status from public.driver_settlements where id = v_id;
  if v_status is distinct from 'draft' then
    raise exception 'Adjustments can only be added or removed while the settlement is in draft status.';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists driver_settlement_adjustments_guard_draft on public.driver_settlement_adjustments;
create trigger driver_settlement_adjustments_guard_draft
  before insert or delete on public.driver_settlement_adjustments
  for each row execute function public.guard_driver_settlement_adjustment_draft();

-- ---------------------------------------------------------------------------
-- recalculate_driver_settlement_totals: keeps driver_settlements.gross_pay/
-- adjustments_amount/deductions_amount/advances_amount in sync with its
-- items/adjustments, exactly mirroring recalculate_invoice_totals()
-- (0009_functions_triggers.sql). net_pay/balance_due are generated columns
-- computed FROM these, never set directly.
-- ---------------------------------------------------------------------------
create or replace function public.recalculate_driver_settlement_totals()
returns trigger
language plpgsql
as $$
declare
  v_settlement_id uuid;
  v_gross numeric(12, 2);
  v_adjustments numeric(12, 2);
  v_deductions numeric(12, 2);
  v_advances numeric(12, 2);
begin
  v_settlement_id := coalesce(new.driver_settlement_id, old.driver_settlement_id);

  select coalesce(sum(gross_pay), 0) into v_gross
  from public.driver_settlement_items where driver_settlement_id = v_settlement_id;

  select
    coalesce(sum(amount) filter (where bucket = 'adjustment'), 0),
    coalesce(sum(amount) filter (where bucket = 'deduction'), 0),
    coalesce(sum(amount) filter (where bucket = 'advance'), 0)
  into v_adjustments, v_deductions, v_advances
  from public.driver_settlement_adjustments where driver_settlement_id = v_settlement_id;

  update public.driver_settlements
  set gross_pay = v_gross, adjustments_amount = v_adjustments, deductions_amount = v_deductions, advances_amount = v_advances
  where id = v_settlement_id;

  return null;
end;
$$;

drop trigger if exists driver_settlement_items_recalculate on public.driver_settlement_items;
create trigger driver_settlement_items_recalculate
  after insert or update or delete on public.driver_settlement_items
  for each row execute function public.recalculate_driver_settlement_totals();

drop trigger if exists driver_settlement_adjustments_recalculate on public.driver_settlement_adjustments;
create trigger driver_settlement_adjustments_recalculate
  after insert or update or delete on public.driver_settlement_adjustments
  for each row execute function public.recalculate_driver_settlement_totals();

-- ---------------------------------------------------------------------------
-- Approval (spec section 18): freezes the settlement by moving it out of
-- 'draft' -- every item/adjustment guard above already blocks edits once
-- status <> 'draft', so approval alone is what makes the snapshot
-- immutable. Records approved_at/approved_by. Requires at least one item
-- or adjustment (an empty settlement has nothing to approve).
-- ---------------------------------------------------------------------------
create or replace function public.approve_driver_settlement(p_settlement_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_status public.driver_settlement_status;
  v_item_count integer;
begin
  select status into v_status from public.driver_settlements where id = p_settlement_id for update;
  if v_status is null then
    raise exception 'Settlement not found.';
  end if;
  if v_status <> 'draft' then
    raise exception 'Only a draft settlement can be approved.';
  end if;

  select count(*) into v_item_count from public.driver_settlement_items where driver_settlement_id = p_settlement_id;
  if v_item_count = 0 then
    raise exception 'Cannot approve a settlement with no loads.';
  end if;

  update public.driver_settlements
  set status = 'approved', approved_at = now(), approved_by = auth.uid()
  where id = p_settlement_id;
end;
$$;

grant execute on function public.approve_driver_settlement(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Void (spec section 28): the only correction path for an approved/paid
-- settlement. Never deletes -- items/adjustments/payments all remain on
-- the row for audit history. Once voided, get_payable_loads() naturally
-- makes its loads eligible again (its exclusion check is `ds.status <>
-- 'void'`), which is the documented replacement rule: void, then create a
-- new settlement that will pick the same loads back up.
-- ---------------------------------------------------------------------------
create or replace function public.void_driver_settlement(p_settlement_id uuid, p_reason text)
returns void
language plpgsql
security invoker
as $$
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to void a settlement.';
  end if;

  update public.driver_settlements
  set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
  where id = p_settlement_id and status <> 'void';

  if not found then
    raise exception 'Settlement not found or already voided.';
  end if;
end;
$$;

grant execute on function public.void_driver_settlement(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- driver_settlement_payments: a DEDICATED table, not the customer-invoice
-- public.payments table -- inspected first (spec section 19): payments
-- has invoice_id NOT NULL and is joined everywhere (A/R, Collections,
-- Statements) as customer-invoice revenue. Forcing driver payouts through
-- it would either require making invoice_id nullable (breaking every one
-- of those joins' assumptions) or fabricating a fake invoice per driver
-- payment (actively wrong -- "do not mix customer invoice revenue with
-- driver pay"). A separate table with its own DSPAY- numbering is the
-- correct, unambiguous design.
-- ---------------------------------------------------------------------------
create table public.driver_settlement_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  driver_settlement_id uuid not null references public.driver_settlements (id) on delete cascade,
  payment_number text not null default public.generate_driver_settlement_payment_number(),
  amount numeric(10, 2) not null,
  method public.payment_method not null default 'ach',
  reference_number text,
  check_number text,
  bank_reference text,
  status public.driver_settlement_payment_status not null default 'posted',
  paid_date date not null default current_date,
  notes text,
  recorded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  voided_by uuid references public.profiles (id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  unique (payment_number),
  constraint driver_settlement_payments_void_requires_reason check (status <> 'voided' or void_reason is not null)
);

create index idx_driver_settlement_payments_settlement on public.driver_settlement_payments (driver_settlement_id, created_at desc);

alter table public.driver_settlement_payments enable row level security;

create policy driver_settlement_payments_select on public.driver_settlement_payments
  for select using (organization_id = public.current_org_id());

create policy driver_settlement_payments_insert on public.driver_settlement_payments
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy driver_settlement_payments_update on public.driver_settlement_payments
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- Overpayment guard + draft/void protection, mirroring guard_payment_amount()
-- (0026) exactly, including the `for update` row lock that makes it
-- concurrency-safe under two simultaneous payment inserts.
create or replace function public.guard_driver_settlement_payment_amount()
returns trigger
language plpgsql
as $$
declare
  v_balance numeric(12, 2);
  v_status public.driver_settlement_status;
begin
  if new.status = 'posted' and old.status is distinct from new.status then
    if new.amount is null or new.amount <= 0 then
      raise exception 'Payment amount must be greater than zero.';
    end if;

    select balance_due, status into v_balance, v_status
    from public.driver_settlements where id = new.driver_settlement_id for update;

    if v_status is null then
      raise exception 'Settlement not found.';
    end if;
    if v_status in ('draft', 'void') then
      raise exception 'Cannot record a payment against a % settlement -- approve it first.', v_status;
    end if;
    if new.amount > v_balance then
      raise exception 'Payment amount ($%) exceeds the settlement balance due ($%). Record a partial payment for the remaining balance instead.', new.amount, v_balance;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists driver_settlement_payments_guard_amount on public.driver_settlement_payments;
create trigger driver_settlement_payments_guard_amount
  before insert or update on public.driver_settlement_payments
  for each row execute function public.guard_driver_settlement_payment_amount();

-- Rollup: amount_paid + status transition, mirroring apply_payment_to_invoice()
-- (0026) -- posted-only sum, reverts to 'approved' if a payment is voided
-- back down to 0, never touches draft/void.
create or replace function public.apply_driver_settlement_payment()
returns trigger
language plpgsql
as $$
declare
  v_settlement_id uuid;
  v_total_paid numeric(12, 2);
  v_net_pay numeric(12, 2);
  v_current_status public.driver_settlement_status;
begin
  v_settlement_id := coalesce(new.driver_settlement_id, old.driver_settlement_id);

  select coalesce(sum(amount) filter (where status = 'posted'), 0) into v_total_paid
  from public.driver_settlement_payments where driver_settlement_id = v_settlement_id;

  select net_pay, status into v_net_pay, v_current_status
  from public.driver_settlements where id = v_settlement_id;

  if v_current_status is null then
    return null;
  end if;

  update public.driver_settlements
  set amount_paid = v_total_paid,
      status = case
        when v_current_status in ('draft', 'void') then v_current_status
        when v_total_paid <= 0 then 'approved'
        when v_net_pay > 0 and v_total_paid >= v_net_pay then 'paid'
        else 'partially_paid'
      end
  where id = v_settlement_id;

  return null;
end;
$$;

drop trigger if exists driver_settlement_payments_apply on public.driver_settlement_payments;
create trigger driver_settlement_payments_apply
  after insert or update or delete on public.driver_settlement_payments
  for each row execute function public.apply_driver_settlement_payment();

-- ---------------------------------------------------------------------------
-- Connect existing driver advances (spec section 12) rather than
-- duplicating: one nullable column linking a dispatch_advances row to the
-- driver settlement it was deducted against, mutually exclusive with the
-- existing carrier-settlement deduction target. Existing
-- deducted_settlement_id/deducted_invoice_id exclusivity check (0013)
-- already covers "only one target at a time" for those two; extended here
-- to include the new third target.
-- ---------------------------------------------------------------------------
alter table public.dispatch_advances
  add column deducted_driver_settlement_id uuid references public.driver_settlements (id) on delete set null;

alter table public.dispatch_advances drop constraint if exists dispatch_advances_single_deduction_target;
alter table public.dispatch_advances add constraint dispatch_advances_single_deduction_target check (
  (case when deducted_invoice_id is not null then 1 else 0 end)
  + (case when deducted_settlement_id is not null then 1 else 0 end)
  + (case when deducted_driver_settlement_id is not null then 1 else 0 end)
  <= 1
);

-- ---------------------------------------------------------------------------
-- get_driver_settlement_summary: YTD figures for the Driver Profile
-- "Settlement Summary" section (spec section 25) and the driver-performance
-- report (section 30). Deliberately not security definer -- runs under
-- the caller's RLS on driver_settlements.
-- ---------------------------------------------------------------------------
create or replace function public.get_driver_settlement_summary(p_driver_id uuid, p_year integer default extract(year from current_date)::integer)
returns table (
  ytd_gross_pay numeric,
  ytd_deductions numeric,
  ytd_advances numeric,
  ytd_net_paid numeric,
  unpaid_approved_count bigint,
  unpaid_approved_balance numeric,
  last_settlement_date date,
  completed_trips bigint,
  total_miles numeric,
  total_load_revenue numeric
)
language sql
stable
as $$
  with settled as (
    select * from public.driver_settlements
    where driver_id = p_driver_id
      and status <> 'void'
      and extract(year from period_end) = p_year
  ),
  items as (
    select dsi.* from public.driver_settlement_items dsi
    join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
    where ds.driver_id = p_driver_id and ds.status <> 'void'
  )
  select
    coalesce((select sum(gross_pay) from settled), 0),
    coalesce((select sum(deductions_amount) from settled), 0),
    coalesce((select sum(advances_amount) from settled), 0),
    coalesce((select sum(amount_paid) from settled), 0),
    (select count(*) from public.driver_settlements where driver_id = p_driver_id and status in ('approved', 'partially_paid'))::bigint,
    coalesce((select sum(balance_due) from public.driver_settlements where driver_id = p_driver_id and status in ('approved', 'partially_paid')), 0),
    (select max(period_end) from public.driver_settlements where driver_id = p_driver_id and status <> 'void'),
    (select count(*) from items)::bigint,
    coalesce((select sum(miles) from items), 0),
    coalesce((select sum(load_rate) from items), 0);
$$;

grant execute on function public.get_driver_settlement_summary(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Driver Portal read access: a driver may view ONLY their own settlements
-- (spec section 24). Reuses the existing driver-portal RLS pattern (see
-- 0015_driver_portal.sql's "org staff can view..." policies for the
-- shape) -- the driver portal has no Supabase Auth session of its own
-- (phone+PIN, service-role client per src/lib/driver-portal/session.ts),
-- so this policy exists for completeness/future direct-auth use but the
-- actual portal page enforces the same scoping at the query level via the
-- service-role client + an explicit .eq('driver_id', identity.driverId)
-- filter, exactly like every other driver-portal page in this app.
-- ---------------------------------------------------------------------------





-- =============================================================================
-- 0032_driver_settlements_bugfixes.sql
-- Two real bugs found during live testing of 0031_driver_settlements.sql.
-- Fixes a real bug found during live testing of 0031_driver_settlements.sql:
-- the pre-existing dispatch_advances_deduction_consistency check constraint
-- (0013_dispatch_advances.sql) only knows about deducted_invoice_id/
-- deducted_settlement_id -- it was never updated when 0031 added
-- deducted_driver_settlement_id. Requiring status='deducted' to also have
-- exactly one of ONLY the first two columns set meant marking an advance
-- deducted via a driver settlement (the new, third target) always violated
-- this constraint, even though 0031's own dispatch_advances_single_deduction_target
-- check (an "at most one of three" rule) was satisfied. Replaces it with
-- the three-target-aware equivalent: status='deducted' requires exactly one
-- of the three target columns set; any other status requires all three null.
-- =============================================================================

alter table public.dispatch_advances drop constraint if exists dispatch_advances_deduction_consistency;

alter table public.dispatch_advances add constraint dispatch_advances_deduction_consistency check (
  (
    status = 'deducted'
    and (
      (case when deducted_invoice_id is not null then 1 else 0 end)
      + (case when deducted_settlement_id is not null then 1 else 0 end)
      + (case when deducted_driver_settlement_id is not null then 1 else 0 end)
    ) = 1
  )
  or (
    status <> 'deducted'
    and deducted_invoice_id is null
    and deducted_settlement_id is null
    and deducted_driver_settlement_id is null
  )
);

-- ---------------------------------------------------------------------------
-- Second real bug found in the same live test session: driver_pay_rates
-- (0031) has a SELECT and an INSERT policy but NO UPDATE policy. RLS with
-- no matching policy for a command doesn't error -- it silently matches
-- zero rows. guard_driver_pay_rate_effective_dates() is NOT security
-- definer, so its internal `update ... set effective_to = ...` (closing
-- the previously-open rate row) ran with the CALLING user's own RLS and
-- silently updated 0 rows for any real authenticated user -- the old row
-- was never actually closed, so the immediately-following overlap
-- safety-check correctly (if confusingly) rejected the insert, because
-- from RLS's point of view the two rows genuinely still overlapped. Only
-- service_role (which bypasses RLS) ever exercised the intended path.
-- Adding the missing policy, same tier as insert, fixes the real update.
-- ---------------------------------------------------------------------------
create policy driver_pay_rates_update on public.driver_pay_rates
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- =============================================================================
-- 0033_carrier_settlements.sql
-- Carrier Settlement / Owner-Operator Pay. EXTENDS the existing carrier-
-- centric public.settlements/settlement_line_items (0006_financials.sql) --
-- inspected first (see chat report): that schema is genuinely carrier-
-- centric and structurally the right home for this, it was just never
-- completed (single-dispatch, single lump payment_method/paid_at scalar,
-- no per-load snapshot, no partial-payment history, no duplicate
-- protection, no Quick Pay). No competing carrier_settlements/
-- carrier_settlement_items table is created. Table was empty (0 rows) at
-- migration time, confirmed live, so every change below is safe -- no
-- historical data reshaped or lost.
--
-- Canonical carrier-pay source: dispatches.carrier_net_amount, ALREADY a
-- historical snapshot (load_rate - dispatch_fee_amount, computed once at
-- dispatch time by sync_dispatch_financials(), 0009_functions_triggers.sql)
-- -- exactly "the actual carrier/dispatch rate already stored with the
-- load/dispatch" the spec asks to prefer. No new carrier-rate-history table
-- is created; dispatches.dispatch_fee_amount/dispatch_fee_percentage
-- already ARE "Company Gross Margin"/"Margin %" under existing names, so
-- margin reporting reuses them rather than reintroducing the concept.
-- =============================================================================

-- New statuses, additive to the existing enum (0001) -- 'pending'/
-- 'on_hold'/'disputed'/'cancelled' are untouched for any pre-existing
-- code path; new carrier settlements use 'draft' in place of 'pending'
-- and 'void' in place of 'cancelled' going forward, matching the spec's
-- exact vocabulary and driver_settlement_status's shape.
alter type public.settlement_status add value if not exists 'draft';
alter type public.settlement_status add value if not exists 'partially_paid';
alter type public.settlement_status add value if not exists 'void';

-- Postgres requires a new enum value to be committed before it can be used
-- in a CHECK constraint, DEFAULT, or comparison later in the SAME script --
-- this migration's own settlements_void_requires_reason constraint and
-- every function below that compares status to 'draft'/'partially_paid'/
-- 'void' would otherwise fail with "unsafe use of new value" even though
-- the whole thing is logically one migration. Committing here closes that
-- transaction boundary; everything after this point runs in a new one.
commit;

create type public.carrier_settlement_payment_status as enum ('posted', 'voided');
create type public.settlement_payee_type as enum ('carrier', 'factor');

-- ---------------------------------------------------------------------------
-- settlements: extended with the additional financial buckets the spec's
-- math requires (gross/adjustments/deductions/advances/quick_pay_fee),
-- amount_paid + balance_due (rollup from the new payments table below),
-- Quick Pay snapshot fields, payee snapshot fields (spec section 41), and
-- void audit fields. net_amount is dropped and re-added with the fuller
-- formula -- safe on an empty table, and for any future real row it
-- recomputes identically to the old formula when advances/adjustments/
-- quick_pay_fee are 0, so no behavior change for anything already using
-- the old two-bucket net_amount = gross - deductions shape.
-- ---------------------------------------------------------------------------
alter table public.settlements
  add column adjustments_amount numeric(10, 2) not null default 0,
  add column advances_amount numeric(10, 2) not null default 0,
  add column quick_pay_enabled boolean not null default false,
  add column quick_pay_rate_percent numeric(5, 2),
  add column quick_pay_fee_amount numeric(10, 2) not null default 0,
  add column amount_paid numeric(10, 2) not null default 0,
  add column payee_type public.settlement_payee_type not null default 'carrier',
  add column payee_name text,
  add column voided_at timestamptz,
  add column voided_by uuid references public.profiles (id) on delete set null,
  add column void_reason text;

alter table public.settlements drop column net_amount;
alter table public.settlements add column net_amount numeric(10, 2)
  generated always as (gross_amount + adjustments_amount - deductions_amount - advances_amount - quick_pay_fee_amount) stored;
alter table public.settlements add column balance_due numeric(10, 2)
  generated always as (gross_amount + adjustments_amount - deductions_amount - advances_amount - quick_pay_fee_amount - amount_paid) stored;

alter table public.settlements
  add constraint settlements_void_requires_reason check (status <> 'void' or void_reason is not null);

comment on column public.settlements.payee_name is
  'Snapshotted at approval time from carriers.legal_name (payee_type=carrier) or carriers.factoring_company_name (payee_type=factor) -- if the carrier''s factoring assignment later changes, an already-approved settlement keeps showing who was actually paid, not the current value (spec section 41).';

-- ---------------------------------------------------------------------------
-- settlement_line_items: extended with per-load snapshot columns and a
-- richer item_type vocabulary. The table had zero rows, so the check
-- constraint is replaced outright rather than widened awkwardly.
-- load_pay rows carry the snapshot (spec section 11); adjustment/
-- deduction/advance/quick_pay_fee rows are manual/system entries, same
-- shape as driver_settlement_adjustments (0031) for consistency.
-- ---------------------------------------------------------------------------
alter table public.settlement_line_items drop constraint if exists settlement_line_items_item_type_check;
alter table public.settlement_line_items add constraint settlement_line_items_item_type_check
  check (item_type in ('load_pay', 'adjustment', 'deduction', 'advance', 'quick_pay_fee'));

alter table public.settlement_line_items
  add column load_id uuid references public.loads (id) on delete restrict,
  add column dispatch_id uuid references public.dispatches (id) on delete set null,
  add column load_number text,
  add column delivery_date date,
  add column miles numeric(8, 2),
  add column customer_revenue numeric(10, 2),
  add column carrier_rate numeric(10, 2),
  add column pay_basis text,
  add column linked_advance_id uuid references public.dispatch_advances (id) on delete set null,
  add column created_by uuid references public.profiles (id) on delete set null,
  add constraint settlement_line_items_load_pay_shape check (
    (item_type = 'load_pay' and load_id is not null and carrier_rate is not null)
    or (item_type <> 'load_pay')
  ),
  add constraint settlement_line_items_amount_magnitude check (item_type in ('load_pay', 'adjustment') or amount > 0);

comment on column public.settlement_line_items.carrier_rate is
  'Frozen snapshot from dispatches.carrier_net_amount at the moment this load was added -- never a live re-read of the carrier''s current default rate (spec section 5/39).';

create index idx_settlement_line_items_load on public.settlement_line_items (load_id) where load_id is not null;

-- ---------------------------------------------------------------------------
-- calculate_carrier_load_settlement: THE canonical carrier-pay AND margin
-- source. Reads the existing, already-snapshotted dispatch financials --
-- never recomputes a percentage/rate independently, never re-reads the
-- carrier's current default dispatch_fee_percentage for an old load.
-- Deliberately NOT security definer -- runs under the caller's own RLS on
-- dispatches/loads, same reasoning as calculate_driver_load_pay() (0031).
-- ---------------------------------------------------------------------------
create or replace function public.calculate_carrier_load_settlement(
  p_carrier_id uuid,
  p_load_id uuid
)
returns table (
  dispatch_id uuid,
  load_number text,
  delivery_date date,
  miles numeric,
  customer_revenue numeric,
  carrier_rate numeric,
  gross_margin numeric,
  margin_percent numeric,
  driver_name text,
  truck_unit text
)
language sql
stable
as $$
  select
    disp.id, l.load_number,
    coalesce(disp.completed_at, disp.dispatched_at)::date,
    l.total_miles,
    disp.load_rate,
    disp.carrier_net_amount,
    disp.dispatch_fee_amount,
    disp.dispatch_fee_percentage,
    trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')),
    t.unit_number
  from public.dispatches disp
  join public.loads l on l.id = disp.load_id
  left join public.drivers d on d.id = disp.driver_id
  left join public.trucks t on t.id = disp.truck_id
  where disp.carrier_id = p_carrier_id and disp.load_id = p_load_id
  order by disp.dispatched_at desc
  limit 1;
$$;

grant execute on function public.calculate_carrier_load_settlement(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_payable_carrier_loads: eligible-for-settlement loads for a carrier/
-- period. Same shape/exclusion style as get_payable_loads() (0031):
-- delivered/completed only, this carrier's own dispatches, within the
-- period by delivery date, not already in a non-void carrier settlement.
-- ---------------------------------------------------------------------------
create or replace function public.get_payable_carrier_loads(
  p_carrier_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  load_id uuid,
  dispatch_id uuid,
  load_number text,
  pickup_city text,
  pickup_state text,
  delivery_city text,
  delivery_state text,
  delivery_date date,
  miles numeric,
  customer_revenue numeric,
  carrier_rate numeric,
  gross_margin numeric,
  margin_percent numeric,
  driver_name text,
  truck_unit text
)
language sql
stable
as $$
  with candidates as (
    select disp.id as dispatch_id, l.id as load_id
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    where disp.carrier_id = p_carrier_id
      and l.status in ('delivered', 'pod_received')
      and coalesce(disp.completed_at, disp.dispatched_at)::date between p_period_start and p_period_end
      and not exists (
        select 1 from public.settlement_line_items sli
        join public.settlements s on s.id = sli.settlement_id
        where sli.item_type = 'load_pay' and sli.load_id = l.id and s.status <> 'void'
      )
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as pickup_city,
           max(state) filter (where stop_type = 'pickup') as pickup_state,
           max(city) filter (where stop_type = 'delivery') as delivery_city,
           max(state) filter (where stop_type = 'delivery') as delivery_state
    from public.load_stops
    where load_id in (select load_id from candidates)
    group by load_id
  )
  select
    c.load_id, c.dispatch_id, p.load_number, s.pickup_city, s.pickup_state, s.delivery_city, s.delivery_state,
    p.delivery_date, p.miles, p.customer_revenue, p.carrier_rate, p.gross_margin, p.margin_percent, p.driver_name, p.truck_unit
  from candidates c
  left join stops s on s.load_id = c.load_id
  cross join lateral public.calculate_carrier_load_settlement(p_carrier_id, c.load_id) p
  order by p.delivery_date asc nulls last;
$$;

grant execute on function public.get_payable_carrier_loads(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Same-org guard for settlements.carrier_id -- matching the pattern used
-- for every cross-table FK on a tenant row this session.
-- ---------------------------------------------------------------------------
create or replace function public.guard_carrier_settlement_org()
returns trigger
language plpgsql
as $$
declare
  v_carrier_org uuid;
begin
  select organization_id into v_carrier_org from public.carriers where id = new.carrier_id;
  if v_carrier_org is null or v_carrier_org <> new.organization_id then
    raise exception 'Settlement carrier must belong to the same organization.';
  end if;
  return new;
end;
$$;

drop trigger if exists settlements_guard_carrier_org on public.settlements;
create trigger settlements_guard_carrier_org
  before insert on public.settlements
  for each row execute function public.guard_carrier_settlement_org();

-- ---------------------------------------------------------------------------
-- Duplicate protection (spec section 37): a load already in an active
-- (non-void) carrier settlement cannot be added to another. `for update`
-- row lock on the load makes concurrent attempts safe (spec section 38).
-- ---------------------------------------------------------------------------
create or replace function public.guard_settlement_line_item_duplicate()
returns trigger
language plpgsql
as $$
declare
  v_status public.settlement_status;
begin
  if new.item_type <> 'load_pay' then
    return new;
  end if;

  select status into v_status from public.settlements where id = new.settlement_id;
  if v_status is null then
    raise exception 'Settlement not found.';
  end if;
  if v_status not in ('draft', 'pending') then
    raise exception 'Cannot add loads to a settlement that is not in draft status.';
  end if;

  perform 1 from public.loads where id = new.load_id for update;

  if exists (
    select 1 from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.item_type = 'load_pay' and sli.load_id = new.load_id and s.status <> 'void'
  ) then
    raise exception 'This load is already included in an active carrier settlement.';
  end if;

  return new;
end;
$$;

drop trigger if exists settlement_line_items_guard_duplicate on public.settlement_line_items;
create trigger settlement_line_items_guard_duplicate
  before insert on public.settlement_line_items
  for each row execute function public.guard_settlement_line_item_duplicate();

-- Edits/removals only while draft (spec section 18/19) -- 'pending' is
-- treated as equivalent to draft throughout these guards so the
-- pre-existing status value keeps working if anything still uses it.
create or replace function public.guard_settlement_line_item_draft()
returns trigger
language plpgsql
as $$
declare
  v_status public.settlement_status;
  v_id uuid;
begin
  v_id := coalesce(new.settlement_id, old.settlement_id);
  select status into v_status from public.settlements where id = v_id;
  if v_status not in ('draft', 'pending') then
    raise exception 'Line items can only be added or removed while the settlement is in draft status.';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists settlement_line_items_guard_draft_delete on public.settlement_line_items;
create trigger settlement_line_items_guard_draft_delete
  before delete on public.settlement_line_items
  for each row execute function public.guard_settlement_line_item_draft();

-- (insert-time draft check already covered by guard_settlement_line_item_duplicate
-- for load_pay rows; non-load_pay rows need the same check, added here)
create or replace function public.guard_settlement_adjustment_draft_insert()
returns trigger
language plpgsql
as $$
declare
  v_status public.settlement_status;
begin
  if new.item_type = 'load_pay' then
    return new; -- already covered by the duplicate guard above
  end if;
  select status into v_status from public.settlements where id = new.settlement_id;
  if v_status is null then
    raise exception 'Settlement not found.';
  end if;
  if v_status not in ('draft', 'pending') then
    raise exception 'Line items can only be added while the settlement is in draft status.';
  end if;
  return new;
end;
$$;

drop trigger if exists settlement_line_items_guard_draft_insert on public.settlement_line_items;
create trigger settlement_line_items_guard_draft_insert
  before insert on public.settlement_line_items
  for each row execute function public.guard_settlement_adjustment_draft_insert();

-- ---------------------------------------------------------------------------
-- recalculate_settlement_totals(): REPLACES the existing 0009 version
-- (earning/deduction only) with the 5-bucket-aware equivalent. Trigger
-- definition itself is unchanged -- only the function body, via create or
-- replace -- so this is additive, not a competing trigger.
-- ---------------------------------------------------------------------------
create or replace function public.recalculate_settlement_totals()
returns trigger
language plpgsql
as $$
declare
  v_settlement_id uuid;
  v_gross numeric(10, 2);
  v_adjustments numeric(10, 2);
  v_deductions numeric(10, 2);
  v_advances numeric(10, 2);
  v_quick_pay numeric(10, 2);
begin
  v_settlement_id := coalesce(new.settlement_id, old.settlement_id);

  select
    coalesce(sum(amount) filter (where item_type = 'load_pay'), 0),
    coalesce(sum(amount) filter (where item_type = 'adjustment'), 0),
    coalesce(sum(amount) filter (where item_type = 'deduction'), 0),
    coalesce(sum(amount) filter (where item_type = 'advance'), 0),
    coalesce(sum(amount) filter (where item_type = 'quick_pay_fee'), 0)
  into v_gross, v_adjustments, v_deductions, v_advances, v_quick_pay
  from public.settlement_line_items
  where settlement_id = v_settlement_id;

  update public.settlements
  set gross_amount = v_gross, adjustments_amount = v_adjustments, deductions_amount = v_deductions,
      advances_amount = v_advances, quick_pay_fee_amount = v_quick_pay
  where id = v_settlement_id;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- apply_quick_pay: computes and (re)writes the single quick_pay_fee line
-- item for a draft settlement from its own gross_amount at call time --
-- called explicitly by app code when Quick Pay is toggled on/off or the
-- rate changes, never automatically (spec section 14: "Do not
-- automatically apply Quick Pay"). Snapshots quick_pay_rate_percent on the
-- settlement itself so a later change to anything never alters this
-- settlement's already-computed fee once it leaves draft (guarded by the
-- draft-only line-item triggers above).
-- ---------------------------------------------------------------------------
create or replace function public.apply_quick_pay(p_settlement_id uuid, p_enabled boolean, p_rate_percent numeric)
returns void
language plpgsql
security invoker
as $$
declare
  v_status public.settlement_status;
  v_gross numeric(10, 2);
  v_org uuid;
  v_fee numeric(10, 2);
begin
  select status, gross_amount, organization_id into v_status, v_gross, v_org
  from public.settlements where id = p_settlement_id;
  if v_status is null then
    raise exception 'Settlement not found.';
  end if;
  if v_status not in ('draft', 'pending') then
    raise exception 'Quick Pay can only be changed while the settlement is in draft status.';
  end if;

  delete from public.settlement_line_items where settlement_id = p_settlement_id and item_type = 'quick_pay_fee';

  if p_enabled then
    if p_rate_percent is null or p_rate_percent <= 0 then
      raise exception 'A positive Quick Pay rate is required.';
    end if;
    v_fee := round(v_gross * (p_rate_percent / 100.0), 2);
    insert into public.settlement_line_items (organization_id, settlement_id, description, item_type, amount, pay_basis)
    values (v_org, p_settlement_id, 'Quick Pay Fee (' || p_rate_percent || '%)', 'quick_pay_fee', v_fee, 'quick_pay');
  end if;

  update public.settlements
  set quick_pay_enabled = p_enabled, quick_pay_rate_percent = case when p_enabled then p_rate_percent else null end
  where id = p_settlement_id;
end;
$$;

grant execute on function public.apply_quick_pay(uuid, boolean, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Approval / Void (mirrors approve_driver_settlement/void_driver_settlement,
-- 0031, exactly). 'pending' is accepted as a synonym for 'draft' so the
-- pre-existing default status still approves cleanly.
-- ---------------------------------------------------------------------------
create or replace function public.approve_carrier_settlement(p_settlement_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_status public.settlement_status;
  v_carrier_id uuid;
  v_item_count integer;
  v_payee_type public.settlement_payee_type;
  v_carrier_name text;
  v_factor_name text;
begin
  select status, carrier_id, payee_type into v_status, v_carrier_id, v_payee_type
  from public.settlements where id = p_settlement_id for update;
  if v_status is null then
    raise exception 'Settlement not found.';
  end if;
  if v_status not in ('draft', 'pending') then
    raise exception 'Only a draft settlement can be approved.';
  end if;

  select count(*) into v_item_count from public.settlement_line_items where settlement_id = p_settlement_id and item_type = 'load_pay';
  if v_item_count = 0 then
    raise exception 'Cannot approve a settlement with no loads.';
  end if;

  select legal_name, factoring_company_name into v_carrier_name, v_factor_name from public.carriers where id = v_carrier_id;

  update public.settlements
  set status = 'approved', approved_at = now(), approved_by = auth.uid(),
      payee_name = case when v_payee_type = 'factor' then coalesce(v_factor_name, v_carrier_name) else v_carrier_name end
  where id = p_settlement_id;
end;
$$;

grant execute on function public.approve_carrier_settlement(uuid) to authenticated;

create or replace function public.void_carrier_settlement(p_settlement_id uuid, p_reason text)
returns void
language plpgsql
security invoker
as $$
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to void a settlement.';
  end if;

  update public.settlements
  set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
  where id = p_settlement_id and status <> 'void';

  if not found then
    raise exception 'Settlement not found or already voided.';
  end if;
end;
$$;

grant execute on function public.void_carrier_settlement(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Numbering: CPAY-###### for carrier settlement payments, never reusing
-- PAY- (invoice payments) or DSPAY- (driver settlement payments) --
-- spec section 23.
-- ---------------------------------------------------------------------------
create sequence public.carrier_settlement_payment_number_seq;
create or replace function public.generate_carrier_settlement_payment_number()
returns text language plpgsql security definer set search_path = public as $$
begin
  return 'CPAY-' || lpad(nextval('public.carrier_settlement_payment_number_seq')::text, 6, '0');
end;
$$;
grant execute on function public.generate_carrier_settlement_payment_number() to authenticated;

-- ---------------------------------------------------------------------------
-- carrier_settlement_payments: a DEDICATED table, not customer-invoice
-- public.payments (invoice_id NOT NULL there, semantic confusion -- spec
-- section 20) and not public.driver_settlement_payments (a different
-- economic obligation -- spec section 6/9's explicit distinction).
-- ---------------------------------------------------------------------------
create table public.carrier_settlement_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  settlement_id uuid not null references public.settlements (id) on delete cascade,
  payment_number text not null default public.generate_carrier_settlement_payment_number(),
  amount numeric(10, 2) not null,
  method public.payment_method not null default 'ach',
  reference_number text,
  check_number text,
  bank_reference text,
  status public.carrier_settlement_payment_status not null default 'posted',
  paid_date date not null default current_date,
  notes text,
  recorded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  voided_by uuid references public.profiles (id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  unique (payment_number),
  constraint carrier_settlement_payments_void_requires_reason check (status <> 'voided' or void_reason is not null)
);

create index idx_carrier_settlement_payments_settlement on public.carrier_settlement_payments (settlement_id, created_at desc);

alter table public.carrier_settlement_payments enable row level security;

create policy carrier_settlement_payments_select on public.carrier_settlement_payments
  for select using (organization_id = public.current_org_id());

create policy carrier_settlement_payments_insert on public.carrier_settlement_payments
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy carrier_settlement_payments_update on public.carrier_settlement_payments
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- Overpayment guard + draft/void protection (spec section 22/38), mirrors
-- guard_driver_settlement_payment_amount() exactly, including the `for
-- update` lock that makes it concurrency-safe.
create or replace function public.guard_carrier_settlement_payment_amount()
returns trigger
language plpgsql
as $$
declare
  v_balance numeric(10, 2);
  v_status public.settlement_status;
begin
  if new.status = 'posted' and old.status is distinct from new.status then
    if new.amount is null or new.amount <= 0 then
      raise exception 'Payment amount must be greater than zero.';
    end if;

    select balance_due, status into v_balance, v_status
    from public.settlements where id = new.settlement_id for update;

    if v_status is null then
      raise exception 'Settlement not found.';
    end if;
    if v_status in ('draft', 'pending', 'void') then
      raise exception 'Cannot record a payment against a % settlement -- approve it first.', v_status;
    end if;
    if new.amount > v_balance then
      raise exception 'Payment amount ($%) exceeds the settlement balance due ($%). Record a partial payment for the remaining balance instead.', new.amount, v_balance;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists carrier_settlement_payments_guard_amount on public.carrier_settlement_payments;
create trigger carrier_settlement_payments_guard_amount
  before insert or update on public.carrier_settlement_payments
  for each row execute function public.guard_carrier_settlement_payment_amount();

-- Rollup: amount_paid + status transition, mirrors apply_driver_settlement_payment().
create or replace function public.apply_carrier_settlement_payment()
returns trigger
language plpgsql
as $$
declare
  v_settlement_id uuid;
  v_total_paid numeric(10, 2);
  v_net_amount numeric(10, 2);
  v_current_status public.settlement_status;
begin
  v_settlement_id := coalesce(new.settlement_id, old.settlement_id);

  select coalesce(sum(amount) filter (where status = 'posted'), 0) into v_total_paid
  from public.carrier_settlement_payments where settlement_id = v_settlement_id;

  select net_amount, status into v_net_amount, v_current_status
  from public.settlements where id = v_settlement_id;

  if v_current_status is null then
    return null;
  end if;

  update public.settlements
  set amount_paid = v_total_paid,
      status = case
        when v_current_status in ('draft', 'pending', 'void') then v_current_status
        when v_total_paid <= 0 then 'approved'
        when v_net_amount > 0 and v_total_paid >= v_net_amount then 'paid'
        else 'partially_paid'
      end,
      paid_at = case when v_net_amount > 0 and v_total_paid >= v_net_amount then now() else null end
  where id = v_settlement_id;

  return null;
end;
$$;

drop trigger if exists carrier_settlement_payments_apply on public.carrier_settlement_payments;
create trigger carrier_settlement_payments_apply
  after insert or update or delete on public.carrier_settlement_payments
  for each row execute function public.apply_carrier_settlement_payment();

-- ---------------------------------------------------------------------------
-- get_carrier_settlement_summary: YTD figures for Carrier Profile (spec
-- section 28) and margin reporting (section 33/34) -- the ONE shared
-- source, so no page independently recomputes margin.
-- ---------------------------------------------------------------------------
create or replace function public.get_carrier_settlement_summary(p_carrier_id uuid, p_year integer default extract(year from current_date)::integer)
returns table (
  ytd_gross_pay numeric,
  ytd_deductions numeric,
  ytd_advances numeric,
  ytd_quick_pay_fees numeric,
  ytd_net_paid numeric,
  unpaid_approved_count bigint,
  unpaid_approved_balance numeric,
  last_settlement_date date,
  completed_loads bigint,
  total_customer_revenue numeric,
  total_carrier_pay numeric,
  total_gross_margin numeric
)
language sql
stable
as $$
  with settled as (
    select * from public.settlements
    where carrier_id = p_carrier_id
      and status <> 'void'
      and extract(year from coalesce(period_end, created_at::date)) = p_year
  ),
  items as (
    select sli.* from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where s.carrier_id = p_carrier_id and s.status <> 'void' and sli.item_type = 'load_pay'
  )
  select
    coalesce((select sum(gross_amount) from settled), 0),
    coalesce((select sum(deductions_amount) from settled), 0),
    coalesce((select sum(advances_amount) from settled), 0),
    coalesce((select sum(quick_pay_fee_amount) from settled), 0),
    coalesce((select sum(amount_paid) from settled), 0),
    (select count(*) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid'))::bigint,
    coalesce((select sum(balance_due) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid')), 0),
    (select max(period_end) from public.settlements where carrier_id = p_carrier_id and status <> 'void'),
    (select count(*) from items)::bigint,
    coalesce((select sum(customer_revenue) from items), 0),
    coalesce((select sum(carrier_rate) from items), 0),
    coalesce((select sum(customer_revenue) - sum(carrier_rate) from items), 0);
$$;

grant execute on function public.get_carrier_settlement_summary(uuid, integer) to authenticated;


-- =============================================================================
-- 0034_carrier_settlements_bugfixes.sql
-- Two real bugs found during the live Carrier Settlement test.
--
-- BUG 1 -- margin_percent imprecise (Test A: $7,000 revenue / $5,400
-- carrier pay / $1,600 margin / 22.857142...% margin):
-- calculate_carrier_load_settlement() (0033) returned margin_percent as
-- disp.dispatch_fee_percentage -- the STORED, independently-editable
-- numeric(5,2) rate field on the dispatch row, not a derived ratio of the
-- actual gross_margin/customer_revenue amounts. Live result was 22.86
-- (the stored rate, rounded to 2dp at entry time) instead of the true
-- 22.857142857142857...% the actual dollar amounts imply. The two agree
-- only when dispatch_fee_amount was itself computed fresh from that exact
-- percentage and never independently adjusted afterward (e.g. a manual
-- override, a negotiated flat accessorial, or -- as in this test itself --
-- any value that doesn't reduce to a clean 2-decimal percentage of the
-- load rate); real settlements can and do drift from that. gross_margin
-- (disp.dispatch_fee_amount, NUMERIC(10,2)) was already exact and is
-- unchanged; only margin_percent is corrected, to the authoritative ratio
-- actually implied by the exact dollar figures: round(dispatch_fee_amount
-- / load_rate * 100, 10).
--
-- BUG 2 -- settlement creation completely broken (found immediately in
-- Test D): public.settlements.settlement_number (0006_financials.sql) is
-- `text not null` with NO default and no generator function was ever
-- added for it -- unlike invoices/statements/driver_settlements, which
-- all get theirs from a dedicated generate_*_number() sequence default.
-- createCarrierSettlement() (settlements/actions.ts) never supplies
-- settlement_number either, so every real "New Carrier Settlement"
-- submission in the live app fails outright with `null value in column
-- "settlement_number" violates not-null constraint` -- confirmed live.
-- Fixed the same way as every other numbered document this session:
-- CS-###### sequence + generate_carrier_settlement_number(), set as the
-- column default so the existing insert (which never mentions the column)
-- starts working with no app code change. "CS-" (not driver settlements'
-- existing "SET-") to keep the two settlement types visually distinct.
-- =============================================================================

create or replace function public.calculate_carrier_load_settlement(
  p_carrier_id uuid,
  p_load_id uuid
)
returns table (
  dispatch_id uuid,
  load_number text,
  delivery_date date,
  miles numeric,
  customer_revenue numeric,
  carrier_rate numeric,
  gross_margin numeric,
  margin_percent numeric,
  driver_name text,
  truck_unit text
)
language sql
stable
as $$
  select
    disp.id, l.load_number,
    coalesce(disp.completed_at, disp.dispatched_at)::date,
    l.total_miles,
    disp.load_rate,
    disp.carrier_net_amount,
    disp.dispatch_fee_amount,
    case when disp.load_rate <> 0 then round(disp.dispatch_fee_amount / disp.load_rate * 100, 10) else null end,
    trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')),
    t.unit_number
  from public.dispatches disp
  join public.loads l on l.id = disp.load_id
  left join public.drivers d on d.id = disp.driver_id
  left join public.trucks t on t.id = disp.truck_id
  where disp.carrier_id = p_carrier_id and disp.load_id = p_load_id
  order by disp.dispatched_at desc
  limit 1;
$$;

grant execute on function public.calculate_carrier_load_settlement(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- BUG 2 fix: settlement_number default, matching generate_statement_number()
-- (0029) / generate_driver_settlement_number() (0031) exactly.
-- ---------------------------------------------------------------------------
create sequence if not exists public.carrier_settlement_number_seq;
create or replace function public.generate_carrier_settlement_number()
returns text language plpgsql security definer set search_path = public as $$
begin
  return 'CS-' || lpad(nextval('public.carrier_settlement_number_seq')::text, 6, '0');
end;
$$;
grant execute on function public.generate_carrier_settlement_number() to authenticated;

alter table public.settlements
  alter column settlement_number set default public.generate_carrier_settlement_number();


-- =============================================================================
-- 0035_carrier_settlements_bugfixes_2.sql
-- Two more real bugs found continuing the live Carrier Settlement test.
--
-- BUG 3 (Test H, approval/freeze): settlement_line_items had draft-only
-- guards on INSERT (guard_settlement_line_item_duplicate /
-- guard_settlement_adjustment_draft_insert) and DELETE
-- (settlement_line_items_guard_draft_delete), but no trigger at all on
-- UPDATE. Confirmed live: after approving a settlement, a direct UPDATE
-- of a load_pay line's amount/carrier_rate/customer_revenue succeeded --
-- silently breaking the frozen-snapshot guarantee (spec section 39: "carrier
-- rate changes must not retroactively alter settlement snapshots") for the
-- one path (UPDATE) the existing guards didn't cover, even though no
-- current app action performs such an update itself. Fix: bind the
-- EXISTING guard_settlement_line_item_draft() function (already correct --
-- it already resolves coalesce(new.settlement_id, old.settlement_id) and
-- blocks when status not in ('draft','pending')) to BEFORE UPDATE too.
-- No new function, no schema change.
--
-- BUG 4 (Test O/N, Carrier Profile YTD summary): get_carrier_settlement_summary()
-- (0033) filtered its `settled`/`items` CTEs with only `status <> 'void'`,
-- so DRAFT settlements -- still being edited, not yet approved, could still
-- be deleted entirely -- were counted into "YTD Gross Carrier Pay", YTD
-- deductions/advances/Quick-Pay-fees, completed-load count, total customer
-- revenue, total carrier pay, and total gross margin. Confirmed live: with
-- 3 finalized settlements (approved/partially_paid, true YTD gross pay
-- $20,400, 3 loads, revenue $25,000, carrier pay $20,400, margin $4,600)
-- plus 4 unrelated leftover drafts sitting in the test carrier's queue
-- ($1,500 + $0 + $2,200/$250 advance + $1,900), the function returned
-- ytd_gross_pay $26,000 and completed_loads 6 -- silently inflated by
-- settlements that were never actually finalized. The same `status <>
-- 'void'` pattern already exists in get_driver_settlement_summary() (0031)
-- -- out of scope for this carrier-settlement test round, flagged
-- separately, not changed here.
--
-- Fix: restrict `settled`/`items` (and last_settlement_date) to actually
-- finalized statuses -- approved/partially_paid/paid -- matching the
-- unpaid_approved_count/unpaid_approved_balance columns in the same
-- function, which already used exactly that filter.
--
-- BUG 5 (Test Q, settlement PDF/detail): spec requires the settlement PDF
-- to show Pickup/Delivery per load. get_payable_carrier_loads() (0033)
-- already joins load_stops and returns pickup_city/pickup_state/
-- delivery_city/delivery_state, but that data was discarded the moment a
-- load became a settlement_line_items row -- neither
-- calculate_carrier_load_settlement() (the single-load add path) nor the
-- settlement_line_items table itself carried it, so it could never be
-- shown later on the settlement detail page or PDF regardless of load
-- data. Fixed by snapshotting it into settlement_line_items, same as
-- every other load-level field (spec section 39: frozen at add-time).
-- =============================================================================

alter table public.settlement_line_items
  add column pickup_city text,
  add column pickup_state text,
  add column delivery_city text,
  add column delivery_state text;

drop function if exists public.calculate_carrier_load_settlement(uuid, uuid);
create function public.calculate_carrier_load_settlement(
  p_carrier_id uuid,
  p_load_id uuid
)
returns table (
  dispatch_id uuid,
  load_number text,
  delivery_date date,
  miles numeric,
  customer_revenue numeric,
  carrier_rate numeric,
  gross_margin numeric,
  margin_percent numeric,
  driver_name text,
  truck_unit text,
  pickup_city text,
  pickup_state text,
  delivery_city text,
  delivery_state text
)
language sql
stable
as $$
  select
    disp.id, l.load_number,
    coalesce(disp.completed_at, disp.dispatched_at)::date,
    l.total_miles,
    disp.load_rate,
    disp.carrier_net_amount,
    disp.dispatch_fee_amount,
    case when disp.load_rate <> 0 then round(disp.dispatch_fee_amount / disp.load_rate * 100, 10) else null end,
    trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')),
    t.unit_number,
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1)
  from public.dispatches disp
  join public.loads l on l.id = disp.load_id
  left join public.drivers d on d.id = disp.driver_id
  left join public.trucks t on t.id = disp.truck_id
  where disp.carrier_id = p_carrier_id and disp.load_id = p_load_id
  order by disp.dispatched_at desc
  limit 1;
$$;

grant execute on function public.calculate_carrier_load_settlement(uuid, uuid) to authenticated;

drop trigger if exists settlement_line_items_guard_draft_update on public.settlement_line_items;
create trigger settlement_line_items_guard_draft_update
  before update on public.settlement_line_items
  for each row execute function public.guard_settlement_line_item_draft();

create or replace function public.get_carrier_settlement_summary(p_carrier_id uuid, p_year integer default extract(year from current_date)::integer)
returns table (
  ytd_gross_pay numeric,
  ytd_deductions numeric,
  ytd_advances numeric,
  ytd_quick_pay_fees numeric,
  ytd_net_paid numeric,
  unpaid_approved_count bigint,
  unpaid_approved_balance numeric,
  last_settlement_date date,
  completed_loads bigint,
  total_customer_revenue numeric,
  total_carrier_pay numeric,
  total_gross_margin numeric
)
language sql
stable
as $$
  with settled as (
    select * from public.settlements
    where carrier_id = p_carrier_id
      and status in ('approved', 'partially_paid', 'paid')
      and extract(year from coalesce(period_end, created_at::date)) = p_year
  ),
  items as (
    select sli.* from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where s.carrier_id = p_carrier_id and s.status in ('approved', 'partially_paid', 'paid') and sli.item_type = 'load_pay'
  )
  select
    coalesce((select sum(gross_amount) from settled), 0),
    coalesce((select sum(deductions_amount) from settled), 0),
    coalesce((select sum(advances_amount) from settled), 0),
    coalesce((select sum(quick_pay_fee_amount) from settled), 0),
    coalesce((select sum(amount_paid) from settled), 0),
    (select count(*) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid'))::bigint,
    coalesce((select sum(balance_due) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid')), 0),
    (select max(period_end) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid', 'paid')),
    (select count(*) from items)::bigint,
    coalesce((select sum(customer_revenue) from items), 0),
    coalesce((select sum(carrier_rate) from items), 0),
    coalesce((select sum(customer_revenue) - sum(carrier_rate) from items), 0);
$$;

grant execute on function public.get_carrier_settlement_summary(uuid, integer) to authenticated;

-- =============================================================================
-- 0036_carrier_settlements_dependency_fix.sql
-- 0035_carrier_settlements_bugfixes_2.sql silently failed to apply as a
-- whole (confirmed live: settlement_line_items.pickup_city didn't exist,
-- calculate_carrier_load_settlement still returned the old 10-column
-- shape, and a direct UPDATE of an approved settlement_line_items row
-- still succeeded -- BUG 3's trigger never got created either).
--
-- First attempt at this file (this same migration number) assumed the
-- cause was a pg_depend edge from get_payable_carrier_loads() (0033) --
-- which calls calculate_carrier_load_settlement() via `cross join
-- lateral` -- blocking the plain DROP FUNCTION and added `cascade` plus
-- an unconditional `create function` for get_payable_carrier_loads to
-- recreate it after the cascade. That assumption was wrong: confirmed
-- live just now that a plain function call inside another LANGUAGE SQL
-- function's body does NOT register as a hard catalog dependency in this
-- Postgres version -- the cascade had nothing to cascade to, so
-- get_payable_carrier_loads was never dropped, and the unconditional
-- `create function public.get_payable_carrier_loads(...)` collided with
-- the still-existing original: `42723: function "get_payable_carrier_loads"
-- already exists with same argument types`. That is what actually rolled
-- the whole script back the second time; it also explains why the
-- original 0035 (no cascade, no get_payable_carrier_loads statement at
-- all) never had a chance to reach this specific failure -- its own root
-- cause remains unconfirmed, but every statement in this file is now
-- idempotent regardless, so it applies cleanly however the DB got here.
--
-- Fix: `create or replace function get_payable_carrier_loads` instead of
-- a plain `create function`, so this succeeds whether or not the cascade
-- actually dropped it. `cascade` is left on the calculate_carrier_load_
-- settlement drop as a harmless no-op safety net. Every other statement
-- here was already idempotent (`if not exists` / `create or replace` /
-- `drop trigger if exists`).
-- =============================================================================

alter table public.settlement_line_items
  add column if not exists pickup_city text,
  add column if not exists pickup_state text,
  add column if not exists delivery_city text,
  add column if not exists delivery_state text;

drop function if exists public.calculate_carrier_load_settlement(uuid, uuid) cascade;

create function public.calculate_carrier_load_settlement(
  p_carrier_id uuid,
  p_load_id uuid
)
returns table (
  dispatch_id uuid,
  load_number text,
  delivery_date date,
  miles numeric,
  customer_revenue numeric,
  carrier_rate numeric,
  gross_margin numeric,
  margin_percent numeric,
  driver_name text,
  truck_unit text,
  pickup_city text,
  pickup_state text,
  delivery_city text,
  delivery_state text
)
language sql
stable
as $$
  select
    disp.id, l.load_number,
    coalesce(disp.completed_at, disp.dispatched_at)::date,
    l.total_miles,
    disp.load_rate,
    disp.carrier_net_amount,
    disp.dispatch_fee_amount,
    case when disp.load_rate <> 0 then round(disp.dispatch_fee_amount / disp.load_rate * 100, 10) else null end,
    trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')),
    t.unit_number,
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1)
  from public.dispatches disp
  join public.loads l on l.id = disp.load_id
  left join public.drivers d on d.id = disp.driver_id
  left join public.trucks t on t.id = disp.truck_id
  where disp.carrier_id = p_carrier_id and disp.load_id = p_load_id
  order by disp.dispatched_at desc
  limit 1;
$$;

grant execute on function public.calculate_carrier_load_settlement(uuid, uuid) to authenticated;

-- Recreated verbatim from 0033 -- not itself buggy, it just needs to
-- exist again in case the cascade above dropped it. create or replace
-- (not plain create) since, in practice, it usually won't have been.
create or replace function public.get_payable_carrier_loads(
  p_carrier_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  load_id uuid,
  dispatch_id uuid,
  load_number text,
  pickup_city text,
  pickup_state text,
  delivery_city text,
  delivery_state text,
  delivery_date date,
  miles numeric,
  customer_revenue numeric,
  carrier_rate numeric,
  gross_margin numeric,
  margin_percent numeric,
  driver_name text,
  truck_unit text
)
language sql
stable
as $$
  with candidates as (
    select disp.id as dispatch_id, l.id as load_id
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    where disp.carrier_id = p_carrier_id
      and l.status in ('delivered', 'pod_received')
      and coalesce(disp.completed_at, disp.dispatched_at)::date between p_period_start and p_period_end
      and not exists (
        select 1 from public.settlement_line_items sli
        join public.settlements s on s.id = sli.settlement_id
        where sli.item_type = 'load_pay' and sli.load_id = l.id and s.status <> 'void'
      )
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as pickup_city,
           max(state) filter (where stop_type = 'pickup') as pickup_state,
           max(city) filter (where stop_type = 'delivery') as delivery_city,
           max(state) filter (where stop_type = 'delivery') as delivery_state
    from public.load_stops
    where load_id in (select load_id from candidates)
    group by load_id
  )
  select
    c.load_id, c.dispatch_id, p.load_number, s.pickup_city, s.pickup_state, s.delivery_city, s.delivery_state,
    p.delivery_date, p.miles, p.customer_revenue, p.carrier_rate, p.gross_margin, p.margin_percent, p.driver_name, p.truck_unit
  from candidates c
  left join stops s on s.load_id = c.load_id
  cross join lateral public.calculate_carrier_load_settlement(p_carrier_id, c.load_id) p
  order by p.delivery_date asc nulls last;
$$;

grant execute on function public.get_payable_carrier_loads(uuid, date, date) to authenticated;

-- BUG 3 fix, re-applied.
drop trigger if exists settlement_line_items_guard_draft_update on public.settlement_line_items;
create trigger settlement_line_items_guard_draft_update
  before update on public.settlement_line_items
  for each row execute function public.guard_settlement_line_item_draft();

-- BUG 4 fix, re-applied.
create or replace function public.get_carrier_settlement_summary(p_carrier_id uuid, p_year integer default extract(year from current_date)::integer)
returns table (
  ytd_gross_pay numeric,
  ytd_deductions numeric,
  ytd_advances numeric,
  ytd_quick_pay_fees numeric,
  ytd_net_paid numeric,
  unpaid_approved_count bigint,
  unpaid_approved_balance numeric,
  last_settlement_date date,
  completed_loads bigint,
  total_customer_revenue numeric,
  total_carrier_pay numeric,
  total_gross_margin numeric
)
language sql
stable
as $$
  with settled as (
    select * from public.settlements
    where carrier_id = p_carrier_id
      and status in ('approved', 'partially_paid', 'paid')
      and extract(year from coalesce(period_end, created_at::date)) = p_year
  ),
  items as (
    select sli.* from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where s.carrier_id = p_carrier_id and s.status in ('approved', 'partially_paid', 'paid') and sli.item_type = 'load_pay'
  )
  select
    coalesce((select sum(gross_amount) from settled), 0),
    coalesce((select sum(deductions_amount) from settled), 0),
    coalesce((select sum(advances_amount) from settled), 0),
    coalesce((select sum(quick_pay_fee_amount) from settled), 0),
    coalesce((select sum(amount_paid) from settled), 0),
    (select count(*) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid'))::bigint,
    coalesce((select sum(balance_due) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid')), 0),
    (select max(period_end) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid', 'paid')),
    (select count(*) from items)::bigint,
    coalesce((select sum(customer_revenue) from items), 0),
    coalesce((select sum(carrier_rate) from items), 0),
    coalesce((select sum(customer_revenue) - sum(carrier_rate) from items), 0);
$$;

grant execute on function public.get_carrier_settlement_summary(uuid, integer) to authenticated;


-- =============================================================================
-- 0037_profitability.sql
-- Profitability & Load Margin module. Inspected first (per instructions):
-- loads, dispatches, invoices, invoice_line_items, expenses, fuel_logs,
-- carriers, drivers, settlements, settlement_line_items, driver_settlements,
-- driver_settlement_items, driver_pay_rates, load_stops, brokers, customers.
--
-- KEY SCHEMA FINDINGS THAT SHAPE THIS DESIGN:
--
-- 1. expenses/fuel_logs have NO load_id or dispatch_id column -- only
--    carrier_id/truck_id/driver_id. There is no reliable way to attribute
--    an expense row to one specific load with the current schema. Per
--    instructions ("report that limitation rather than inventing
--    attribution"), other_direct_cost is returned as NULL (not 0) on every
--    row -- never guessed via truck/date-range heuristics, never silently
--    zeroed. total_direct_cost uses coalesce(other_direct_cost, 0) only
--    for the arithmetic, so a real transportation cost isn't nulled out by
--    an always-missing category, but other_direct_cost itself stays
--    honestly NULL. This limitation is also called out in the chat report.
--
-- 2. dispatches always carries both carrier_id and driver_id (both NOT
--    NULL) -- the schema does not structurally distinguish "outsourced to
--    a carrier" from "run by a company driver" at the dispatch level.
--    driver_pay_rates (0031) is the deliberate opt-in signal: staff only
--    create a pay-rate row for a driver they intend to pay via Driver
--    Settlement. Absent that row, a dispatch defaults to the carrier path
--    (dispatches.carrier_net_amount is always populated once a dispatch
--    exists -- computed by the pre-existing sync_dispatch_financials()
--    trigger, 0009). This mirrors exactly how the Carrier/Driver Settlement
--    modules already coexist: both are opt-in, and "never both" is a
--    business-process expectation, not a DB constraint, on either side.
--
-- 3. Canonical revenue: invoices.subtotal_amount - discount_amount for the
--    most recent non-void invoice on the load, when one exists (tax is
--    excluded -- it isn't company revenue). This is the actual billed
--    amount, independent of any later edit to loads.rate (invoice line
--    items are stored values, never a live re-read of the load). Before an
--    invoice exists, loads.rate is used as an explicit ESTIMATE only.
--
-- 4. Canonical transportation cost, in priority order (never both carrier
--    and driver cost for the same load -- see finding #2):
--      a. Non-void, finalized (approved/partially_paid/paid) Carrier
--         Settlement load_pay line -- sli.carrier_rate. COMPLETE.
--      b. Non-void, finalized Driver Settlement item -- dsi.gross_pay.
--         COMPLETE.
--      c. driver_pay_rates exists for this driver as of the delivery date
--         -- calculate_driver_load_pay() (0031, reused verbatim, not
--         reimplemented). ESTIMATED.
--      d. dispatches.carrier_net_amount, if a dispatch exists. ESTIMATED.
--      e. Otherwise NULL -- MISSING_COST. Never coerced to $0.
--    Advances are never added: carrier_rate/gross_pay are the settlement's
--    own gross load-pay snapshot columns, already exclusive of the
--    advances/deductions/quick-pay buckets tracked separately on
--    settlements/driver_settlements (0031/0033) -- summing them in here
--    would double count exactly what those buckets already represent.
--
-- 5. Historical stability: every COMPLETE-status figure is read from an
--    already-frozen settlement snapshot column (sli.carrier_rate /
--    dsi.gross_pay -- both documented as frozen-at-add-time in their own
--    migrations). Nothing here re-reads a carrier's current rate, a
--    driver's current pay rate, or live load_stops for a load whose cost
--    is already finalized. ESTIMATED rows are explicitly, visibly
--    estimates (profitability_status says so) precisely because they DO
--    still move if the source data changes before a settlement exists.
--
-- 6. Void handling: every settlement/driver_settlement join filters
--    status in ('approved','partially_paid','paid') -- void and draft
--    rows are excluded, matching the same finalized-status convention
--    fixed into get_carrier_settlement_summary in 0035/0036. `distinct on`
--    picks the single most recent matching line per load, so a voided-
--    and-replaced settlement's old row can never be counted alongside its
--    replacement.
--
-- ONE canonical function, get_load_profitability(), is the sole source of
-- per-load truth. Every aggregation function below (by broker/customer/
-- carrier/driver/lane/period) selects FROM it and only adds a GROUP BY --
-- none of them reimplement the revenue/cost/margin formulas. All are
-- LANGUAGE SQL, none SECURITY DEFINER -- run under the caller's own RLS on
-- loads/dispatches/invoices/settlements/etc, so cross-org data is
-- impossible to leak, matching every canonical RPC already in this
-- codebase (get_ar_invoices, get_payable_carrier_loads, etc).
-- =============================================================================

create type public.profitability_status as enum (
  'COMPLETE', 'ESTIMATED', 'MISSING_COST', 'MISSING_REVENUE', 'NOT_DELIVERED'
);

-- ---------------------------------------------------------------------------
-- get_load_profitability: THE canonical per-load profitability source.
-- p_load_id null returns every load in the caller's org (RLS-scoped); a
-- specific id returns just that one row -- same function serves Load
-- Detail (one row) and Reports/Dashboard (full set), so there is never a
-- second, competing calculation and never an N+1 per-load RPC loop.
-- ---------------------------------------------------------------------------
create or replace function public.get_load_profitability(p_load_id uuid default null)
returns table (
  load_id uuid,
  load_number text,
  organization_id uuid,
  delivery_date date,
  load_status public.load_status,
  broker_id uuid,
  customer_id uuid,
  carrier_id uuid,
  driver_id uuid,
  origin_city text,
  origin_state text,
  destination_city text,
  destination_state text,
  miles numeric,
  revenue numeric,
  revenue_source text,
  carrier_cost numeric,
  driver_cost numeric,
  transportation_cost numeric,
  transportation_cost_source text,
  other_direct_cost numeric,
  total_direct_cost numeric,
  gross_profit numeric,
  margin_percent numeric,
  revenue_per_mile numeric,
  cost_per_mile numeric,
  profit_per_mile numeric,
  profitability_status public.profitability_status
)
language sql
stable
as $$
  with base as (
    select l.id as load_id, l.load_number, l.organization_id, l.status as load_status,
           l.broker_id, l.customer_id, l.total_miles as miles, l.rate as booked_rate
    from public.loads l
    where p_load_id is null or l.id = p_load_id
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as origin_city,
           max(state) filter (where stop_type = 'pickup') as origin_state,
           max(city) filter (where stop_type = 'delivery') as destination_city,
           max(state) filter (where stop_type = 'delivery') as destination_state
    from public.load_stops
    where load_id in (select load_id from base)
    group by load_id
  ),
  -- canonical assignment for a load: most recent dispatch (mirrors
  -- calculate_carrier_load_settlement's own `order by dispatched_at desc
  -- limit 1` convention, 0033).
  disp as (
    select distinct on (load_id)
      load_id, id as dispatch_id, carrier_id, driver_id, carrier_net_amount,
      coalesce(completed_at, dispatched_at)::date as delivery_date
    from public.dispatches
    where load_id in (select load_id from base)
    order by load_id, dispatched_at desc
  ),
  inv as (
    select distinct on (load_id)
      load_id, (subtotal_amount - discount_amount) as invoice_revenue
    from public.invoices
    where load_id in (select load_id from base) and status <> 'void'
    order by load_id, issue_date desc, created_at desc
  ),
  carrier_finalized as (
    select distinct on (sli.load_id)
      sli.load_id, sli.carrier_rate as cost
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.item_type = 'load_pay'
      and sli.load_id in (select load_id from base)
      and s.status in ('approved', 'partially_paid', 'paid')
    order by sli.load_id, sli.created_at desc
  ),
  driver_finalized as (
    select distinct on (dsi.load_id)
      dsi.load_id, dsi.gross_pay as cost
    from public.driver_settlement_items dsi
    join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
    where dsi.load_id in (select load_id from base)
      and ds.status in ('approved', 'partially_paid', 'paid')
    order by dsi.load_id, dsi.created_at desc
  ),
  -- opt-in signal: a driver only has a driver_pay_rates row if staff mean
  -- to pay them via Driver Settlement (finding #2 above).
  rated_drivers as (
    select distinct driver_id from public.driver_pay_rates
  ),
  driver_estimate as (
    select b.load_id, calc.gross_pay as cost
    from base b
    join disp d on d.load_id = b.load_id
    join rated_drivers rd on rd.driver_id = d.driver_id
    cross join lateral public.calculate_driver_load_pay(d.driver_id, b.load_id) calc
  ),
  resolved as (
    select
      b.load_id,
      d.delivery_date,
      d.carrier_id,
      d.driver_id,
      coalesce(inv.invoice_revenue, b.booked_rate) as revenue,
      case when inv.invoice_revenue is not null then 'invoice'
           when b.booked_rate is not null and b.booked_rate <> 0 then 'load_rate_estimated'
           else null end as revenue_source,
      cf.cost as carrier_finalized_cost,
      df.cost as driver_finalized_cost,
      de.cost as driver_estimate_cost,
      d.carrier_net_amount as carrier_estimate_cost
    from base b
    left join disp d on d.load_id = b.load_id
    left join inv on inv.load_id = b.load_id
    left join carrier_finalized cf on cf.load_id = b.load_id
    left join driver_finalized df on df.load_id = b.load_id
    left join driver_estimate de on de.load_id = b.load_id
  )
  select
    b.load_id, b.load_number, b.organization_id,
    r.delivery_date, b.load_status, b.broker_id, b.customer_id,
    r.carrier_id, r.driver_id,
    st.origin_city, st.origin_state, st.destination_city, st.destination_state,
    b.miles,
    r.revenue, r.revenue_source,
    case when r.carrier_finalized_cost is not null then r.carrier_finalized_cost
         when r.driver_finalized_cost is null and r.driver_estimate_cost is null and r.carrier_estimate_cost is not null then r.carrier_estimate_cost
         else 0 end as carrier_cost,
    case when r.driver_finalized_cost is not null then r.driver_finalized_cost
         when r.carrier_finalized_cost is null and r.driver_estimate_cost is not null then r.driver_estimate_cost
         else 0 end as driver_cost,
    coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) as transportation_cost,
    case when r.carrier_finalized_cost is not null then 'carrier_settlement_finalized'
         when r.driver_finalized_cost is not null then 'driver_settlement_finalized'
         when r.driver_estimate_cost is not null then 'driver_pay_estimated'
         when r.carrier_estimate_cost is not null then 'carrier_dispatch_estimated'
         else null end as transportation_cost_source,
    null::numeric as other_direct_cost,
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + 0 end as total_direct_cost,
    case when r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) end as gross_profit,
    case when r.revenue is null or r.revenue = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost)) / r.revenue * 100, 6) end as margin_percent,
    case when b.miles is null or b.miles = 0 or r.revenue is null then null else round(r.revenue / b.miles, 4) end as revenue_per_mile,
    case when b.miles is null or b.miles = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round(coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) / b.miles, 4) end as cost_per_mile,
    case when b.miles is null or b.miles = 0 or r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost)) / b.miles, 4) end as profit_per_mile,
    case
      when b.load_status not in ('delivered', 'pod_received', 'invoiced', 'closed') then 'NOT_DELIVERED'
      when r.revenue is null then 'MISSING_REVENUE'
      when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then 'MISSING_COST'
      when r.revenue_source = 'invoice' and (r.carrier_finalized_cost is not null or r.driver_finalized_cost is not null) then 'COMPLETE'
      else 'ESTIMATED'
    end::public.profitability_status as profitability_status
  from base b
  left join stops st on st.load_id = b.load_id
  left join resolved r on r.load_id = b.load_id;
$$;

grant execute on function public.get_load_profitability(uuid) to authenticated;

comment on function public.get_load_profitability(uuid) is
  'Canonical, sole source of load-level profitability. Every page (Load Detail, Broker/Customer/Carrier/Driver profiles, Reports, Dashboard) reads from this function or from one of the get_profitability_by_*() aggregations below -- never a second, independently-written revenue/cost/margin calculation.';

-- ---------------------------------------------------------------------------
-- Aggregations. Every one of these selects FROM get_load_profitability(null)
-- and only adds a GROUP BY / filter -- none recomputes revenue, cost, or
-- margin. NOT_DELIVERED rows are excluded from every aggregation (nothing
-- to aggregate yet); everything else (COMPLETE/ESTIMATED/MISSING_*) is
-- included so a MISSING_COST load still counts toward load/revenue totals
-- without silently contributing a wrong-but-plausible cost number.
-- ---------------------------------------------------------------------------
create or replace function public.get_profitability_summary(p_period_start date default null, p_period_end date default null)
returns table (
  load_count bigint,
  complete_count bigint,
  estimated_count bigint,
  missing_cost_count bigint,
  missing_revenue_count bigint,
  total_revenue numeric,
  total_transportation_cost numeric,
  total_gross_profit numeric,
  avg_margin_percent numeric,
  total_miles numeric,
  avg_revenue_per_mile numeric,
  avg_profit_per_mile numeric
)
language sql
stable
as $$
  select
    count(*)::bigint,
    count(*) filter (where profitability_status = 'COMPLETE')::bigint,
    count(*) filter (where profitability_status = 'ESTIMATED')::bigint,
    count(*) filter (where profitability_status = 'MISSING_COST')::bigint,
    count(*) filter (where profitability_status = 'MISSING_REVENUE')::bigint,
    coalesce(sum(revenue), 0),
    coalesce(sum(transportation_cost), 0),
    coalesce(sum(gross_profit), 0),
    case when sum(revenue) is not null and sum(revenue) <> 0
      then round(sum(gross_profit) / sum(revenue) * 100, 6) else null end,
    coalesce(sum(miles), 0),
    case when sum(miles) > 0 then round(sum(revenue) / sum(miles), 4) else null end,
    case when sum(miles) > 0 and sum(gross_profit) is not null then round(sum(gross_profit) / sum(miles), 4) else null end
  from public.get_load_profitability(null)
  where profitability_status <> 'NOT_DELIVERED'
    and (p_period_start is null or delivery_date >= p_period_start)
    and (p_period_end is null or delivery_date <= p_period_end);
$$;

grant execute on function public.get_profitability_summary(date, date) to authenticated;

create or replace function public.get_profitability_by_broker(p_period_start date default null, p_period_end date default null)
returns table (
  broker_id uuid, broker_name text, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select lp.broker_id, b.company_name, count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  left join public.brokers b on b.id = lp.broker_id
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.broker_id is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.broker_id, b.company_name
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_broker(date, date) to authenticated;

create or replace function public.get_profitability_by_customer(p_period_start date default null, p_period_end date default null)
returns table (
  customer_id uuid, customer_name text, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select lp.customer_id, c.company_name, count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  left join public.customers c on c.id = lp.customer_id
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.customer_id is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.customer_id, c.company_name
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_customer(date, date) to authenticated;

create or replace function public.get_profitability_by_carrier(p_period_start date default null, p_period_end date default null)
returns table (
  carrier_id uuid, carrier_name text, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select lp.carrier_id, c.legal_name, count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  left join public.carriers c on c.id = lp.carrier_id
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.carrier_id is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.carrier_id, c.legal_name
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_carrier(date, date) to authenticated;

-- Staff-only (internal reporting/report pages under (app), never the
-- Driver Portal) -- commercial margin data must not reach drivers.
create or replace function public.get_profitability_by_driver(p_period_start date default null, p_period_end date default null)
returns table (
  driver_id uuid, driver_name text, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select lp.driver_id, trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')), count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  left join public.drivers d on d.id = lp.driver_id
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.driver_id is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.driver_id, d.first_name, d.last_name
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_driver(date, date) to authenticated;

create or replace function public.get_profitability_by_lane(p_period_start date default null, p_period_end date default null)
returns table (
  origin_city text, origin_state text, destination_city text, destination_state text,
  load_count bigint, total_revenue numeric, total_transportation_cost numeric,
  total_gross_profit numeric, avg_margin_percent numeric, avg_revenue_per_mile numeric
)
language sql
stable
as $$
  select lp.origin_city, lp.origin_state, lp.destination_city, lp.destination_state, count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end,
    case when sum(lp.miles) > 0 then round(sum(lp.revenue) / sum(lp.miles), 4) else null end
  from public.get_load_profitability(null) lp
  where lp.profitability_status <> 'NOT_DELIVERED'
    and lp.origin_city is not null and lp.destination_city is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.origin_city, lp.origin_state, lp.destination_city, lp.destination_state
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_lane(date, date) to authenticated;

-- p_granularity: 'day' | 'week' | 'month' (validated -- anything else
-- falls back to 'month' rather than raising, since this only ever feeds a
-- date_trunc call).
create or replace function public.get_profitability_by_period(p_granularity text default 'month', p_period_start date default null, p_period_end date default null)
returns table (
  period_start date, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select date_trunc(case when p_granularity in ('day', 'week', 'month') then p_granularity else 'month' end, lp.delivery_date)::date,
    count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.delivery_date is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by 1
  order by 1 desc;
$$;

grant execute on function public.get_profitability_by_period(text, date, date) to authenticated;


-- =============================================================================
-- 0038_profitability_zero_rate_fix.sql
-- Bug found in the live Profitability test: a load with no invoice and
-- loads.rate = 0 (the column's own not-null default -- meaning "never
-- priced", not "genuinely free freight") resolved revenue to 0.00 instead
-- of NULL, via `coalesce(inv.invoice_revenue, b.booked_rate)`. A committed
-- $0.00 revenue is not null, so the profitability_status CASE's `when
-- r.revenue is null then 'MISSING_REVENUE'` branch never fired -- the row
-- fell through to ESTIMATED with $0.00 revenue displayed, misrepresenting
-- an unpriced load as a real, calculated (if small) profit/loss figure.
-- Confirmed live: TEST-PROF-MISSREV (rate 0, no invoice) returned
-- revenue=0.00, revenue_source=null, status=ESTIMATED instead of the
-- intended MISSING_REVENUE.
--
-- Fix: nullif(b.booked_rate, 0) before the coalesce, so a genuinely-unset
-- (0) load rate is treated the same as no rate at all -- consistent with
-- the same "never convert missing to $0" principle already applied to
-- transportation cost. A load actually priced at a nonzero rate is
-- unaffected; only the true edge case (rate never entered) changes.
-- create or replace of the existing 0037 function only -- same signature,
-- no schema change.
-- =============================================================================

create or replace function public.get_load_profitability(p_load_id uuid default null)
returns table (
  load_id uuid,
  load_number text,
  organization_id uuid,
  delivery_date date,
  load_status public.load_status,
  broker_id uuid,
  customer_id uuid,
  carrier_id uuid,
  driver_id uuid,
  origin_city text,
  origin_state text,
  destination_city text,
  destination_state text,
  miles numeric,
  revenue numeric,
  revenue_source text,
  carrier_cost numeric,
  driver_cost numeric,
  transportation_cost numeric,
  transportation_cost_source text,
  other_direct_cost numeric,
  total_direct_cost numeric,
  gross_profit numeric,
  margin_percent numeric,
  revenue_per_mile numeric,
  cost_per_mile numeric,
  profit_per_mile numeric,
  profitability_status public.profitability_status
)
language sql
stable
as $$
  with base as (
    select l.id as load_id, l.load_number, l.organization_id, l.status as load_status,
           l.broker_id, l.customer_id, l.total_miles as miles, l.rate as booked_rate
    from public.loads l
    where p_load_id is null or l.id = p_load_id
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as origin_city,
           max(state) filter (where stop_type = 'pickup') as origin_state,
           max(city) filter (where stop_type = 'delivery') as destination_city,
           max(state) filter (where stop_type = 'delivery') as destination_state
    from public.load_stops
    where load_id in (select load_id from base)
    group by load_id
  ),
  disp as (
    select distinct on (load_id)
      load_id, id as dispatch_id, carrier_id, driver_id, carrier_net_amount,
      coalesce(completed_at, dispatched_at)::date as delivery_date
    from public.dispatches
    where load_id in (select load_id from base)
    order by load_id, dispatched_at desc
  ),
  inv as (
    select distinct on (load_id)
      load_id, (subtotal_amount - discount_amount) as invoice_revenue
    from public.invoices
    where load_id in (select load_id from base) and status <> 'void'
    order by load_id, issue_date desc, created_at desc
  ),
  carrier_finalized as (
    select distinct on (sli.load_id)
      sli.load_id, sli.carrier_rate as cost
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.item_type = 'load_pay'
      and sli.load_id in (select load_id from base)
      and s.status in ('approved', 'partially_paid', 'paid')
    order by sli.load_id, sli.created_at desc
  ),
  driver_finalized as (
    select distinct on (dsi.load_id)
      dsi.load_id, dsi.gross_pay as cost
    from public.driver_settlement_items dsi
    join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
    where dsi.load_id in (select load_id from base)
      and ds.status in ('approved', 'partially_paid', 'paid')
    order by dsi.load_id, dsi.created_at desc
  ),
  rated_drivers as (
    select distinct driver_id from public.driver_pay_rates
  ),
  driver_estimate as (
    select b.load_id, calc.gross_pay as cost
    from base b
    join disp d on d.load_id = b.load_id
    join rated_drivers rd on rd.driver_id = d.driver_id
    cross join lateral public.calculate_driver_load_pay(d.driver_id, b.load_id) calc
  ),
  resolved as (
    select
      b.load_id,
      d.delivery_date,
      d.carrier_id,
      d.driver_id,
      coalesce(inv.invoice_revenue, nullif(b.booked_rate, 0)) as revenue,
      case when inv.invoice_revenue is not null then 'invoice'
           when b.booked_rate is not null and b.booked_rate <> 0 then 'load_rate_estimated'
           else null end as revenue_source,
      cf.cost as carrier_finalized_cost,
      df.cost as driver_finalized_cost,
      de.cost as driver_estimate_cost,
      d.carrier_net_amount as carrier_estimate_cost
    from base b
    left join disp d on d.load_id = b.load_id
    left join inv on inv.load_id = b.load_id
    left join carrier_finalized cf on cf.load_id = b.load_id
    left join driver_finalized df on df.load_id = b.load_id
    left join driver_estimate de on de.load_id = b.load_id
  )
  select
    b.load_id, b.load_number, b.organization_id,
    r.delivery_date, b.load_status, b.broker_id, b.customer_id,
    r.carrier_id, r.driver_id,
    st.origin_city, st.origin_state, st.destination_city, st.destination_state,
    b.miles,
    r.revenue, r.revenue_source,
    case when r.carrier_finalized_cost is not null then r.carrier_finalized_cost
         when r.driver_finalized_cost is null and r.driver_estimate_cost is null and r.carrier_estimate_cost is not null then r.carrier_estimate_cost
         else 0 end as carrier_cost,
    case when r.driver_finalized_cost is not null then r.driver_finalized_cost
         when r.carrier_finalized_cost is null and r.driver_estimate_cost is not null then r.driver_estimate_cost
         else 0 end as driver_cost,
    coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) as transportation_cost,
    case when r.carrier_finalized_cost is not null then 'carrier_settlement_finalized'
         when r.driver_finalized_cost is not null then 'driver_settlement_finalized'
         when r.driver_estimate_cost is not null then 'driver_pay_estimated'
         when r.carrier_estimate_cost is not null then 'carrier_dispatch_estimated'
         else null end as transportation_cost_source,
    null::numeric as other_direct_cost,
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + 0 end as total_direct_cost,
    case when r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) end as gross_profit,
    case when r.revenue is null or r.revenue = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost)) / r.revenue * 100, 6) end as margin_percent,
    case when b.miles is null or b.miles = 0 or r.revenue is null then null else round(r.revenue / b.miles, 4) end as revenue_per_mile,
    case when b.miles is null or b.miles = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round(coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) / b.miles, 4) end as cost_per_mile,
    case when b.miles is null or b.miles = 0 or r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost)) / b.miles, 4) end as profit_per_mile,
    case
      when b.load_status not in ('delivered', 'pod_received', 'invoiced', 'closed') then 'NOT_DELIVERED'
      when r.revenue is null then 'MISSING_REVENUE'
      when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then 'MISSING_COST'
      when r.revenue_source = 'invoice' and (r.carrier_finalized_cost is not null or r.driver_finalized_cost is not null) then 'COMPLETE'
      else 'ESTIMATED'
    end::public.profitability_status as profitability_status
  from base b
  left join stops st on st.load_id = b.load_id
  left join resolved r on r.load_id = b.load_id;
$$;

grant execute on function public.get_load_profitability(uuid) to authenticated;


-- =============================================================================
-- 0039_print_export_email.sql
-- Toolbar Print/Export/Email module. Print (window.print()/existing PDF
-- routes) and Export (CSV, server-side RLS-scoped queries) need no schema
-- changes at all. Email needs exactly one thing: a place to honestly
-- record send attempts (including BLOCKED ones -- no provider is
-- configured anywhere in this project, confirmed by inspecting package.json
-- and every .env* file: no Resend/SendGrid/Postmark/SES/SMTP/nodemailer
-- dependency or credential exists). No equivalent audit table existed
-- (checked: no reminder_log/email_log/collection_reminders table anywhere
-- in prior migrations) so a minimal one is added here, matching the exact
-- field list from the chat spec.
--
-- Never SECURITY DEFINER -- selects/inserts run under the caller's own
-- RLS, same canonical pattern as every other table this session.
-- =============================================================================

create type public.email_send_status as enum ('sent', 'blocked', 'failed');

create table public.email_send_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  recipient text not null,
  cc text,
  subject text not null,
  attachment_type text,
  status public.email_send_status not null,
  error text,
  sent_by uuid references public.profiles (id) on delete set null,
  sent_at timestamptz not null default now(),
  constraint email_send_log_failure_requires_error check (status = 'sent' or error is not null)
);

comment on table public.email_send_log is
  'Every Print/Export/Email toolbar send attempt, including blocked ones (no email provider configured -- status stays blocked/failed, never sent, until a real provider exists). Never written to on a merely-opened compose dialog, only on an actual Send click.';

create index idx_email_send_log_entity on public.email_send_log (organization_id, entity_type, entity_id, sent_at desc);

alter table public.email_send_log enable row level security;

create policy email_send_log_select on public.email_send_log
  for select using (organization_id = public.current_org_id());

create policy email_send_log_insert on public.email_send_log
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy -- append-only audit trail, matching every other
-- audit-style table in this codebase (driver_pii_access_log, etc).
-- =============================================================================
-- 0040_expense_cost_management.sql
-- Expense & Cost Management. Inspected first (per instructions): expenses,
-- fuel_logs, dispatch_advances, loads, dispatches, trucks, trailers,
-- drivers, carriers, documents, settlements/settlement_line_items,
-- driver_settlements/driver_settlement_adjustments.
--
-- KEY FINDINGS:
-- 1. public.expenses (0006_financials.sql) already exists but is bare:
--    carrier_id/truck_id/driver_id/category/amount/date/vendor/description/
--    receipt_document_id only -- no load_id/dispatch_id, no scope, no
--    status/approval/void lifecycle, no expense_number. EXTENDED here, not
--    replaced -- no load_expenses/truck_expenses competing table created.
-- 2. public.fuel_logs is truck-scoped operational fuel detail with its own
--    total_amount and receipt_document_id -- kept as-is (per instructions,
--    "fuel_logs remains operational fuel detail"). expenses gets an
--    optional fuel_log_id with a partial unique index so the SAME fuel
--    purchase can never be double-counted as both a fuel_logs row and a
--    separate expenses row.
-- 3. public.documents is already polymorphic (entity_type enum already
--    includes 'expense', from 0001) -- no new document infrastructure
--    needed, only new document_type values for receipt categorization.
-- 4. public.driver_settlement_adjustments (0031) is a DIFFERENT financial
--    concept (payroll deductions against a driver's own settlement) --
--    deliberately not touched or conflated with this module.
-- 5. RLS on expenses already exists (0010_rls_policies.sql, the
--    ops_cost_tables loop: select = any org member, insert/update =
--    owner/admin/accountant/dispatcher, delete = owner/admin/accountant).
--    Kept as the base row-visibility policy; a NEW trigger below adds
--    finer-grained gating specifically on the approve/pay/void
--    transitions (dispatcher can create/edit a draft, but not approve/pay/
--    void -- "do not let a dispatcher casually approve").
-- =============================================================================

-- ---------------------------------------------------------------------------
-- New enums.
-- ---------------------------------------------------------------------------
create type public.expense_scope as enum ('load', 'truck', 'driver', 'carrier', 'general');
create type public.expense_status as enum ('draft', 'submitted', 'approved', 'paid', 'void');

-- New categories, additive to the existing enum (0001) -- 'fuel',
-- 'maintenance', 'tolls', 'permits_and_licenses', 'insurance', 'payroll',
-- 'office', 'lease_or_loan', 'other' are untouched. Direct-load categories
-- and more specific overhead categories added per the spec's exact lists.
alter type public.expense_category add value if not exists 'lumper';
alter type public.expense_category add value if not exists 'detention_cost';
alter type public.expense_category add value if not exists 'scale_ticket';
alter type public.expense_category add value if not exists 'parking';
alter type public.expense_category add value if not exists 'permit';
alter type public.expense_category add value if not exists 'escort';
alter type public.expense_category add value if not exists 'washout';
alter type public.expense_category add value if not exists 'repair';
alter type public.expense_category add value if not exists 'trailer_expense';
alter type public.expense_category add value if not exists 'hotel_layover';
alter type public.expense_category add value if not exists 'cargo_claim';
alter type public.expense_category add value if not exists 'rent';
alter type public.expense_category add value if not exists 'utilities';
alter type public.expense_category add value if not exists 'software';
alter type public.expense_category add value if not exists 'accounting';
alter type public.expense_category add value if not exists 'legal';
alter type public.expense_category add value if not exists 'phone_internet';
alter type public.expense_category add value if not exists 'office_supplies';
alter type public.expense_category add value if not exists 'bank_fees';

-- New receipt document types, additive to the existing enum (0001, extended
-- by 0024). lumper_receipt/detention_document/scale_ticket already exist.
alter type public.document_type add value if not exists 'expense_receipt';
alter type public.document_type add value if not exists 'fuel_receipt';
alter type public.document_type add value if not exists 'toll_receipt';
alter type public.document_type add value if not exists 'repair_invoice';

-- Postgres requires a new enum value to be committed before it can be used
-- in a comparison/CHECK/default later in the SAME script (confirmed the
-- hard way earlier this session, 0033/0038) -- every value added above is
-- only ever compared against starting below, so one commit here covers
-- all of them.
commit;

-- ---------------------------------------------------------------------------
-- Extend public.expenses: scope, load/dispatch/trailer linkage, money
-- fields, numbering, lifecycle, audit trail. All additive/nullable or
-- defaulted -- the table already had rows in some installs (truck/carrier/
-- general costs logged before this migration), so nothing here can break
-- an existing row; every new NOT NULL column ships with a default that
-- reproduces "this is an untouched legacy row" (scope='general',
-- status='approved' -- see backfill note below).
-- ---------------------------------------------------------------------------
create sequence public.expense_number_seq;
create or replace function public.generate_expense_number()
returns text language plpgsql security definer set search_path = public as $$
begin
  return 'EXP-' || lpad(nextval('public.expense_number_seq')::text, 6, '0');
end;
$$;
grant execute on function public.generate_expense_number() to authenticated;

alter table public.expenses
  add column expense_number text not null default public.generate_expense_number(),
  add column scope public.expense_scope not null default 'general',
  add column load_id uuid references public.loads (id) on delete restrict,
  add column dispatch_id uuid references public.dispatches (id) on delete set null,
  add column trailer_id uuid references public.trailers (id) on delete set null,
  add column fuel_log_id uuid references public.fuel_logs (id) on delete set null,
  add column tax_amount numeric(10, 2) not null default 0,
  add column payment_method public.payment_method,
  add column reference_number text,
  add column billable_to_customer boolean not null default false,
  add column notes text,
  add column status public.expense_status not null default 'approved',
  add column approved_at timestamptz,
  add column approved_by uuid references public.profiles (id) on delete set null,
  add column paid_at timestamptz,
  add column paid_by uuid references public.profiles (id) on delete set null,
  add column voided_at timestamptz,
  add column voided_by uuid references public.profiles (id) on delete set null,
  add column void_reason text;

-- Existing rows (created before this migration, if any) are legacy
-- truck/carrier/general costs entered with no lifecycle at all -- treating
-- them as already-'approved' (not 'draft') is what keeps them counting in
-- truck/carrier/general totals exactly as they did before this migration,
-- with no behavior change for pre-existing data. New rows going forward
-- default to 'draft' (set explicitly by the app on insert, see actions.ts)
-- -- this column default only exists to make the backfill safe.
alter table public.expenses alter column status set default 'draft';

alter table public.expenses add column total_amount numeric(10, 2)
  generated always as (amount + tax_amount) stored;

alter table public.expenses
  add constraint expenses_void_requires_reason check (status <> 'void' or void_reason is not null),
  add constraint expenses_fuel_log_unique unique (fuel_log_id);

comment on column public.expenses.fuel_log_id is
  'Optional link to the fuel_logs row this expense represents, if any. UNIQUE -- a given fuel purchase can be linked from at most one expense row, so the same purchase can never be double-counted as both a fuel_logs total and a separate expense (spec section 15/53).';

create index idx_expenses_load on public.expenses (load_id) where load_id is not null;
create index idx_expenses_truck on public.expenses (truck_id) where truck_id is not null;
create index idx_expenses_scope_status on public.expenses (organization_id, scope, status);

-- ---------------------------------------------------------------------------
-- guard_expense_scope: ONE canonical scope per expense (spec section 3).
-- LOAD requires load_id; TRUCK requires truck_id and forbids load_id (a
-- truck-only cost is never simultaneously a load cost); DRIVER/CARRIER
-- require their own id and forbid load_id; GENERAL forbids every entity
-- link. truck_id/driver_id/carrier_id/trailer_id/dispatch_id may still be
-- present on a LOAD-scoped row as pure traceability context (spec section
-- 9: "these are context fields, not separate accounting scopes").
-- ---------------------------------------------------------------------------
create or replace function public.guard_expense_scope()
returns trigger
language plpgsql
as $$
begin
  case new.scope
    when 'load' then
      if new.load_id is null then
        raise exception 'A load-scoped expense requires a load.';
      end if;
    when 'truck' then
      if new.truck_id is null then
        raise exception 'A truck-scoped expense requires a truck.';
      end if;
      if new.load_id is not null then
        raise exception 'A truck-scoped expense cannot also be linked to a load -- use scope = load instead.';
      end if;
    when 'driver' then
      if new.driver_id is null then
        raise exception 'A driver-scoped expense requires a driver.';
      end if;
      if new.load_id is not null then
        raise exception 'A driver-scoped expense cannot also be linked to a load -- use scope = load instead.';
      end if;
    when 'carrier' then
      if new.carrier_id is null then
        raise exception 'A carrier-scoped expense requires a carrier.';
      end if;
      if new.load_id is not null then
        raise exception 'A carrier-scoped expense cannot also be linked to a load -- use scope = load instead.';
      end if;
    when 'general' then
      if new.load_id is not null or new.truck_id is not null or new.driver_id is not null or new.carrier_id is not null then
        raise exception 'A general/overhead expense cannot be linked to a load, truck, driver, or carrier.';
      end if;
  end case;
  return new;
end;
$$;

drop trigger if exists expenses_guard_scope on public.expenses;
create trigger expenses_guard_scope
  before insert or update on public.expenses
  for each row execute function public.guard_expense_scope();

-- ---------------------------------------------------------------------------
-- guard_expense_org: every referenced load/dispatch/truck/trailer/driver/
-- carrier must belong to the SAME organization as the expense -- a DB-level
-- guard, not just UI filtering (spec section 46), matching the identical
-- pattern used for every cross-table FK this session (guard_carrier_
-- settlement_org, guard_driver_pay_rate_driver_org, etc).
-- ---------------------------------------------------------------------------
create or replace function public.guard_expense_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
begin
  if new.load_id is not null then
    select organization_id into v_org from public.loads where id = new.load_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Expense load must belong to the same organization.';
    end if;
  end if;
  if new.dispatch_id is not null then
    select organization_id into v_org from public.dispatches where id = new.dispatch_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Expense dispatch must belong to the same organization.';
    end if;
  end if;
  if new.truck_id is not null then
    select organization_id into v_org from public.trucks where id = new.truck_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Expense truck must belong to the same organization.';
    end if;
  end if;
  if new.trailer_id is not null then
    select organization_id into v_org from public.trailers where id = new.trailer_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Expense trailer must belong to the same organization.';
    end if;
  end if;
  if new.driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Expense driver must belong to the same organization.';
    end if;
  end if;
  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Expense carrier must belong to the same organization.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists expenses_guard_org on public.expenses;
create trigger expenses_guard_org
  before insert or update on public.expenses
  for each row execute function public.guard_expense_org();

-- ---------------------------------------------------------------------------
-- Auto-resolve dispatch -> load, and validate a chosen dispatch actually
-- belongs to the chosen load, when both are present (spec section 8).
-- ---------------------------------------------------------------------------
create or replace function public.guard_expense_dispatch_load()
returns trigger
language plpgsql
as $$
declare
  v_dispatch_load_id uuid;
begin
  if new.dispatch_id is null then
    return new;
  end if;
  select load_id into v_dispatch_load_id from public.dispatches where id = new.dispatch_id;
  if new.load_id is null then
    new.load_id := v_dispatch_load_id;
  elsif v_dispatch_load_id is distinct from new.load_id then
    raise exception 'The selected dispatch does not belong to the selected load.';
  end if;
  return new;
end;
$$;

drop trigger if exists expenses_guard_dispatch_load on public.expenses;
create trigger expenses_guard_dispatch_load
  before insert or update on public.expenses
  for each row execute function public.guard_expense_dispatch_load();

-- ---------------------------------------------------------------------------
-- guard_expense_lifecycle: draft-only editing of core accounting fields
-- (spec section 23), role-gated approve/pay/void transitions (spec section
-- 24/26/42: dispatchers can create/edit a draft expense but not approve/
-- pay/void it), and a same-row `for update` lock during any status change
-- so approve/void/paid can never race into a contradictory final state
-- (spec section 47 -- mirrors guard_carrier_settlement_payment_amount's
-- concurrency pattern).
-- ---------------------------------------------------------------------------
create or replace function public.guard_expense_lifecycle()
returns trigger
language plpgsql
as $$
begin
  -- Lock this row for the duration of the transaction so two concurrent
  -- approve/void/paid attempts serialize instead of racing.
  perform 1 from public.expenses where id = old.id for update;

  if new.status is distinct from old.status then
    if old.status = 'void' then
      raise exception 'A voided expense cannot change status.';
    end if;
    if old.status = 'paid' and new.status <> 'void' then
      raise exception 'A paid expense can only be voided, not reverted.';
    end if;
    if new.status in ('approved', 'paid') and old.status not in ('draft', 'submitted', 'approved') then
      raise exception 'Invalid status transition.';
    end if;

    if new.status = 'approved' and old.status <> 'approved' then
      if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
        raise exception 'Only owners, admins, and accountants may approve expenses.';
      end if;
      new.approved_at := now();
      new.approved_by := auth.uid();
    end if;

    if new.status = 'paid' then
      if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
        raise exception 'Only owners, admins, and accountants may mark expenses paid.';
      end if;
      new.paid_at := now();
      new.paid_by := auth.uid();
    end if;

    if new.status = 'void' then
      if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
        raise exception 'Only owners, admins, and accountants may void expenses.';
      end if;
      if new.void_reason is null or btrim(new.void_reason) = '' then
        raise exception 'A reason is required to void an expense.';
      end if;
      new.voided_at := now();
      new.voided_by := auth.uid();
    end if;
  else
    -- No status change: once out of draft/submitted, freeze the core
    -- accounting fields (spec section 23). Everything not listed here
    -- (vendor, description, notes, reference_number, receipt) stays
    -- editable at any stage.
    if old.status not in ('draft', 'submitted') then
      if new.amount is distinct from old.amount
        or new.tax_amount is distinct from old.tax_amount
        or new.category is distinct from old.category
        or new.scope is distinct from old.scope
        or new.load_id is distinct from old.load_id
        or new.truck_id is distinct from old.truck_id
        or new.driver_id is distinct from old.driver_id
        or new.carrier_id is distinct from old.carrier_id
      then
        raise exception 'Amount, category, scope, and entity links are frozen once an expense leaves draft/submitted. Void and re-enter to correct.';
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists expenses_guard_lifecycle on public.expenses;
create trigger expenses_guard_lifecycle
  before update on public.expenses
  for each row execute function public.guard_expense_lifecycle();

-- ---------------------------------------------------------------------------
-- get_load_direct_expenses: THE canonical direct-load-cost source (spec
-- section 28). p_load_id null returns every load in the caller's org
-- (RLS-scoped, same convention as get_load_profitability, 0037) --
-- callable as a set (for the profitability join below) or for one load
-- (Load Detail's expense breakdown panel). Only scope = 'load', non-void,
-- correct organization (via ordinary RLS -- not security definer).
-- Draft/submitted are surfaced separately as "pending" -- never folded
-- into the approved total (spec section 7/30).
-- ---------------------------------------------------------------------------
create or replace function public.get_load_direct_expenses(p_load_id uuid default null)
returns table (
  load_id uuid,
  expense_count bigint,
  approved_direct_expense_total numeric,
  pending_direct_expense_total numeric,
  pending_expense_count bigint,
  categories jsonb
)
language sql
stable
as $$
  with relevant as (
    select e.*
    from public.expenses e
    where e.scope = 'load'
      and e.status <> 'void'
      and (p_load_id is null or e.load_id = p_load_id)
  ),
  loads_in_scope as (
    select distinct load_id from relevant
  ),
  cat_breakdown as (
    select load_id, jsonb_object_agg(category, cat_total) as categories
    from (
      select load_id, category::text as category, sum(total_amount) as cat_total
      from relevant
      where status in ('approved', 'paid')
      group by load_id, category
    ) c
    group by load_id
  )
  select
    l.load_id,
    count(*) filter (where r.id is not null)::bigint,
    coalesce(sum(r.total_amount) filter (where r.status in ('approved', 'paid')), 0),
    coalesce(sum(r.total_amount) filter (where r.status in ('draft', 'submitted')), 0),
    count(*) filter (where r.status in ('draft', 'submitted'))::bigint,
    coalesce(cb.categories, '{}'::jsonb)
  from loads_in_scope l
  left join relevant r on r.load_id = l.load_id
  left join cat_breakdown cb on cb.load_id = l.load_id
  group by l.load_id, cb.categories;
$$;

grant execute on function public.get_load_direct_expenses(uuid) to authenticated;

comment on function public.get_load_direct_expenses(uuid) is
  'Canonical direct-load-cost source. Only scope=load, non-void, approved/paid expenses count toward approved_direct_expense_total; draft/submitted are surfaced separately as pending_direct_expense_total and never silently included as final cost. get_load_profitability() (0037/0038, updated below) is the only other function that reads this.';

-- ---------------------------------------------------------------------------
-- Truck/driver/carrier cost views -- same shape of query as
-- get_load_direct_expenses but grouped by the other three scopes, for the
-- Truck/Driver/Carrier profile cost panels and Reports -> Expenses (spec
-- sections 33/34/37).
-- ---------------------------------------------------------------------------
create or replace function public.get_truck_expense_summary(p_truck_id uuid default null, p_period_start date default null, p_period_end date default null)
returns table (
  truck_id uuid,
  expense_count bigint,
  total_amount numeric,
  categories jsonb
)
language sql
stable
as $$
  with relevant as (
    select e.* from public.expenses e
    where e.scope = 'truck'
      and e.status in ('approved', 'paid')
      and (p_truck_id is null or e.truck_id = p_truck_id)
      and (p_period_start is null or e.expense_date >= p_period_start)
      and (p_period_end is null or e.expense_date <= p_period_end)
  ),
  cat as (
    select truck_id, jsonb_object_agg(category, cat_total) as categories
    from (select truck_id, category::text as category, sum(total_amount) as cat_total from relevant group by truck_id, category) c
    group by truck_id
  )
  select r.truck_id, count(*)::bigint, sum(r.total_amount), coalesce(cat.categories, '{}'::jsonb)
  from relevant r
  left join cat on cat.truck_id = r.truck_id
  group by r.truck_id, cat.categories;
$$;

grant execute on function public.get_truck_expense_summary(uuid, date, date) to authenticated;

create or replace function public.get_driver_expense_summary(p_driver_id uuid default null, p_period_start date default null, p_period_end date default null)
returns table (driver_id uuid, expense_count bigint, total_amount numeric)
language sql
stable
as $$
  select e.driver_id, count(*)::bigint, sum(e.total_amount)
  from public.expenses e
  where e.scope = 'driver'
    and e.status in ('approved', 'paid')
    and (p_driver_id is null or e.driver_id = p_driver_id)
    and (p_period_start is null or e.expense_date >= p_period_start)
    and (p_period_end is null or e.expense_date <= p_period_end)
  group by e.driver_id;
$$;

grant execute on function public.get_driver_expense_summary(uuid, date, date) to authenticated;

create or replace function public.get_carrier_expense_summary(p_carrier_id uuid default null, p_period_start date default null, p_period_end date default null)
returns table (carrier_id uuid, expense_count bigint, total_amount numeric)
language sql
stable
as $$
  select e.carrier_id, count(*)::bigint, sum(e.total_amount)
  from public.expenses e
  where e.scope = 'carrier'
    and e.status in ('approved', 'paid')
    and (p_carrier_id is null or e.carrier_id = p_carrier_id)
    and (p_period_start is null or e.expense_date >= p_period_start)
    and (p_period_end is null or e.expense_date <= p_period_end)
  group by e.carrier_id;
$$;

grant execute on function public.get_carrier_expense_summary(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Expense reporting aggregates (spec sections 35/36/39) -- all thin
-- GROUP BYs over public.expenses directly (not over get_load_direct_
-- expenses, since these report across every scope, not just load), same
-- DRY principle as the profitability aggregation functions (0037): one
-- canonical read, several grouped views over it.
-- ---------------------------------------------------------------------------
create or replace function public.get_expense_summary(p_period_start date default null, p_period_end date default null)
returns table (
  total_count bigint,
  total_amount numeric,
  direct_load_total numeric,
  truck_fleet_total numeric,
  general_overhead_total numeric,
  driver_carrier_total numeric,
  pending_count bigint,
  pending_amount numeric
)
language sql
stable
as $$
  select
    count(*) filter (where status in ('approved', 'paid'))::bigint,
    coalesce(sum(total_amount) filter (where status in ('approved', 'paid')), 0),
    coalesce(sum(total_amount) filter (where status in ('approved', 'paid') and scope = 'load'), 0),
    coalesce(sum(total_amount) filter (where status in ('approved', 'paid') and scope = 'truck'), 0),
    coalesce(sum(total_amount) filter (where status in ('approved', 'paid') and scope = 'general'), 0),
    coalesce(sum(total_amount) filter (where status in ('approved', 'paid') and scope in ('driver', 'carrier')), 0),
    count(*) filter (where status in ('draft', 'submitted'))::bigint,
    coalesce(sum(total_amount) filter (where status in ('draft', 'submitted')), 0)
  from public.expenses
  where status <> 'void'
    and (p_period_start is null or expense_date >= p_period_start)
    and (p_period_end is null or expense_date <= p_period_end);
$$;

grant execute on function public.get_expense_summary(date, date) to authenticated;

create or replace function public.get_expense_by_category(p_period_start date default null, p_period_end date default null)
returns table (category public.expense_category, expense_count bigint, total_amount numeric, percent_of_total numeric)
language sql
stable
as $$
  with rows as (
    select category, total_amount from public.expenses
    where status in ('approved', 'paid')
      and (p_period_start is null or expense_date >= p_period_start)
      and (p_period_end is null or expense_date <= p_period_end)
  ),
  grand_total as (select coalesce(sum(total_amount), 0) as t from rows)
  select r.category, count(*)::bigint, sum(r.total_amount),
    case when (select t from grand_total) <> 0 then round(sum(r.total_amount) / (select t from grand_total) * 100, 4) else null end
  from rows r
  group by r.category
  order by sum(r.total_amount) desc;
$$;

grant execute on function public.get_expense_by_category(date, date) to authenticated;

create or replace function public.get_expense_monthly_trend(p_period_start date default null, p_period_end date default null)
returns table (
  month date,
  direct_load_total numeric,
  truck_fleet_total numeric,
  general_overhead_total numeric,
  total_amount numeric
)
language sql
stable
as $$
  select
    date_trunc('month', expense_date)::date,
    coalesce(sum(total_amount) filter (where scope = 'load'), 0),
    coalesce(sum(total_amount) filter (where scope = 'truck'), 0),
    coalesce(sum(total_amount) filter (where scope = 'general'), 0),
    sum(total_amount)
  from public.expenses
  where status in ('approved', 'paid')
    and (p_period_start is null or expense_date >= p_period_start)
    and (p_period_end is null or expense_date <= p_period_end)
  group by 1
  order by 1 desc;
$$;

grant execute on function public.get_expense_monthly_trend(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Profitability integration (spec section 29/30). Re-creates
-- get_load_profitability() (0037, fixed in 0038) with the SAME signature --
-- other_direct_cost now comes from get_load_direct_expenses() instead of
-- being unconditionally null, and a new PENDING_EXPENSES status is added
-- so a load with real transportation cost but still-draft expenses is
-- never silently reported COMPLETE (spec: "Do not silently mark final
-- profit COMPLETE if known draft expenses are waiting for approval").
-- other_direct_cost is always a real, evaluated number now (coalesced to
-- 0 when there are truly zero load-scoped expenses) -- never an unresolved
-- unknown, since get_load_direct_expenses always runs a real query.
-- ---------------------------------------------------------------------------
alter type public.profitability_status add value if not exists 'PENDING_EXPENSES';
commit;

-- CREATE OR REPLACE FUNCTION cannot change a set-returning function's
-- output column list -- 0038's version has other_direct_cost immediately
-- followed by total_direct_cost; this version inserts a new
-- pending_direct_cost column between them, which Postgres rejects as an
-- incompatible return-type change ("cannot change return type of existing
-- function"). Learned the hard way earlier this session (0036) and
-- required again here -- drop first, then create.
drop function if exists public.get_load_profitability(uuid);

create function public.get_load_profitability(p_load_id uuid default null)
returns table (
  load_id uuid,
  load_number text,
  organization_id uuid,
  delivery_date date,
  load_status public.load_status,
  broker_id uuid,
  customer_id uuid,
  carrier_id uuid,
  driver_id uuid,
  origin_city text,
  origin_state text,
  destination_city text,
  destination_state text,
  miles numeric,
  revenue numeric,
  revenue_source text,
  carrier_cost numeric,
  driver_cost numeric,
  transportation_cost numeric,
  transportation_cost_source text,
  other_direct_cost numeric,
  pending_direct_cost numeric,
  total_direct_cost numeric,
  gross_profit numeric,
  margin_percent numeric,
  revenue_per_mile numeric,
  cost_per_mile numeric,
  profit_per_mile numeric,
  profitability_status public.profitability_status
)
language sql
stable
as $$
  with base as (
    select l.id as load_id, l.load_number, l.organization_id, l.status as load_status,
           l.broker_id, l.customer_id, l.total_miles as miles, l.rate as booked_rate
    from public.loads l
    where p_load_id is null or l.id = p_load_id
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as origin_city,
           max(state) filter (where stop_type = 'pickup') as origin_state,
           max(city) filter (where stop_type = 'delivery') as destination_city,
           max(state) filter (where stop_type = 'delivery') as destination_state
    from public.load_stops
    where load_id in (select load_id from base)
    group by load_id
  ),
  disp as (
    select distinct on (load_id)
      load_id, id as dispatch_id, carrier_id, driver_id, carrier_net_amount,
      coalesce(completed_at, dispatched_at)::date as delivery_date
    from public.dispatches
    where load_id in (select load_id from base)
    order by load_id, dispatched_at desc
  ),
  inv as (
    select distinct on (load_id)
      load_id, (subtotal_amount - discount_amount) as invoice_revenue
    from public.invoices
    where load_id in (select load_id from base) and status <> 'void'
    order by load_id, issue_date desc, created_at desc
  ),
  carrier_finalized as (
    select distinct on (sli.load_id)
      sli.load_id, sli.carrier_rate as cost
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.item_type = 'load_pay'
      and sli.load_id in (select load_id from base)
      and s.status in ('approved', 'partially_paid', 'paid')
    order by sli.load_id, sli.created_at desc
  ),
  driver_finalized as (
    select distinct on (dsi.load_id)
      dsi.load_id, dsi.gross_pay as cost
    from public.driver_settlement_items dsi
    join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
    where dsi.load_id in (select load_id from base)
      and ds.status in ('approved', 'partially_paid', 'paid')
    order by dsi.load_id, dsi.created_at desc
  ),
  rated_drivers as (
    select distinct driver_id from public.driver_pay_rates
  ),
  driver_estimate as (
    select b.load_id, calc.gross_pay as cost
    from base b
    join disp d on d.load_id = b.load_id
    join rated_drivers rd on rd.driver_id = d.driver_id
    cross join lateral public.calculate_driver_load_pay(d.driver_id, b.load_id) calc
  ),
  direct_exp as (
    select * from public.get_load_direct_expenses(p_load_id)
  ),
  resolved as (
    select
      b.load_id,
      d.delivery_date,
      d.carrier_id,
      d.driver_id,
      coalesce(inv.invoice_revenue, nullif(b.booked_rate, 0)) as revenue,
      case when inv.invoice_revenue is not null then 'invoice'
           when b.booked_rate is not null and b.booked_rate <> 0 then 'load_rate_estimated'
           else null end as revenue_source,
      cf.cost as carrier_finalized_cost,
      df.cost as driver_finalized_cost,
      de.cost as driver_estimate_cost,
      d.carrier_net_amount as carrier_estimate_cost,
      coalesce(dx.approved_direct_expense_total, 0) as other_direct_cost,
      coalesce(dx.pending_direct_expense_total, 0) as pending_direct_cost,
      coalesce(dx.pending_expense_count, 0) as pending_expense_count
    from base b
    left join disp d on d.load_id = b.load_id
    left join inv on inv.load_id = b.load_id
    left join carrier_finalized cf on cf.load_id = b.load_id
    left join driver_finalized df on df.load_id = b.load_id
    left join driver_estimate de on de.load_id = b.load_id
    left join direct_exp dx on dx.load_id = b.load_id
  )
  select
    b.load_id, b.load_number, b.organization_id,
    r.delivery_date, b.load_status, b.broker_id, b.customer_id,
    r.carrier_id, r.driver_id,
    st.origin_city, st.origin_state, st.destination_city, st.destination_state,
    b.miles,
    r.revenue, r.revenue_source,
    case when r.carrier_finalized_cost is not null then r.carrier_finalized_cost
         when r.driver_finalized_cost is null and r.driver_estimate_cost is null and r.carrier_estimate_cost is not null then r.carrier_estimate_cost
         else 0 end as carrier_cost,
    case when r.driver_finalized_cost is not null then r.driver_finalized_cost
         when r.carrier_finalized_cost is null and r.driver_estimate_cost is not null then r.driver_estimate_cost
         else 0 end as driver_cost,
    coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) as transportation_cost,
    case when r.carrier_finalized_cost is not null then 'carrier_settlement_finalized'
         when r.driver_finalized_cost is not null then 'driver_settlement_finalized'
         when r.driver_estimate_cost is not null then 'driver_pay_estimated'
         when r.carrier_estimate_cost is not null then 'carrier_dispatch_estimated'
         else null end as transportation_cost_source,
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.other_direct_cost end as other_direct_cost,
    r.pending_direct_cost,
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost end as total_direct_cost,
    case when r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost) end as gross_profit,
    case when r.revenue is null or r.revenue = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost)) / r.revenue * 100, 6) end as margin_percent,
    case when b.miles is null or b.miles = 0 or r.revenue is null then null else round(r.revenue / b.miles, 4) end as revenue_per_mile,
    case when b.miles is null or b.miles = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost) / b.miles, 4) end as cost_per_mile,
    case when b.miles is null or b.miles = 0 or r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost)) / b.miles, 4) end as profit_per_mile,
    case
      when b.load_status not in ('delivered', 'pod_received', 'invoiced', 'closed') then 'NOT_DELIVERED'
      when r.revenue is null then 'MISSING_REVENUE'
      when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then 'MISSING_COST'
      when r.pending_expense_count > 0 then 'PENDING_EXPENSES'
      when r.revenue_source = 'invoice' and (r.carrier_finalized_cost is not null or r.driver_finalized_cost is not null) then 'COMPLETE'
      else 'ESTIMATED'
    end::public.profitability_status as profitability_status
  from base b
  left join stops st on st.load_id = b.load_id
  left join resolved r on r.load_id = b.load_id;
$$;

grant execute on function public.get_load_profitability(uuid) to authenticated;

comment on function public.get_load_profitability(uuid) is
  'Canonical load profitability, now integrated with the Expense & Cost Management module (0040): other_direct_cost is the real, always-evaluated sum of approved/paid scope=load expenses (0 when there genuinely are none, never an unresolved unknown), pending_direct_cost surfaces not-yet-approved load expenses separately, and PENDING_EXPENSES is reported instead of COMPLETE whenever draft/submitted load expenses exist so a final margin is never shown while cost is still coming in.';

-- ---------------------------------------------------------------------------
-- Private storage bucket for expense receipts (spec section 19) -- same
-- exact pattern as load-documents (0023_pod_workflow.sql): no public
-- access, every read via a signed URL, objects at
-- {organization_id}/{expense_id}/{filename}, policies check the first path
-- segment against the caller's own org. A dedicated bucket rather than
-- reusing load-documents since receipts attach to expenses (which may not
-- even be load-scoped) via the polymorphic documents table
-- (entity_type='expense', already a valid value since 0001), not to loads.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-documents', 'expense-documents', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

create policy expense_documents_select on storage.objects
  for select using (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

create policy expense_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy -- a receipt is never edited in place; a
-- correction is a new upload attached to the (still-draft) expense, or a
-- void-and-re-enter once approved, matching every other document type.

-- =============================================================================
-- 0041_expense_cost_management_fix.sql
-- Resume/fix for 0040_expense_cost_management.sql after a live migration
-- attempt failed partway through.
--
-- ROOT CAUSE: 0040's `create or replace function public.get_load_profitability`
-- inserted a new `pending_direct_cost` column into the MIDDLE of the
-- function's existing RETURNS TABLE column list (between other_direct_cost
-- and total_direct_cost, which were adjacent in 0038). Postgres rejects
-- that as an incompatible return-type change ("cannot change return type
-- of existing function") -- CREATE OR REPLACE FUNCTION can only be used
-- when the output column list is unchanged; a DROP FUNCTION is required
-- first. This exact rule was already learned earlier this session (0036,
-- the carrier-settlements CASCADE fix) but was not re-applied when this
-- specific function was rewritten -- confirmed live: the enums, expenses
-- table columns, triggers, and the expense summary/direct-cost RPC
-- functions from 0040 all committed successfully (the SQL editor runs each
-- statement up to an explicit `commit;` as a real checkpoint), but
-- execution stopped at the failing CREATE OR REPLACE, so
-- get_load_profitability was left on its old (0038) shape and the
-- expense-documents storage bucket/policies after it never ran either.
--
-- 0040 itself has been corrected in place (drop function added before the
-- recreate) so a FRESH database applying 0001-0040 in order won't hit
-- this. This file exists to bring an ALREADY-PARTIALLY-MIGRATED database
-- (yours) the rest of the way, without re-running anything that already
-- succeeded and would now fail with "already exists" (as you saw when
-- retrying the whole 0040 script from the top). Do NOT re-run
-- RUN_THIS_FOR_EXPENSE_COST_MANAGEMENT.sql on this database -- run ONLY
-- this file.
-- =============================================================================

-- Same rule as above, applied correctly this time.
drop function if exists public.get_load_profitability(uuid);

create function public.get_load_profitability(p_load_id uuid default null)
returns table (
  load_id uuid,
  load_number text,
  organization_id uuid,
  delivery_date date,
  load_status public.load_status,
  broker_id uuid,
  customer_id uuid,
  carrier_id uuid,
  driver_id uuid,
  origin_city text,
  origin_state text,
  destination_city text,
  destination_state text,
  miles numeric,
  revenue numeric,
  revenue_source text,
  carrier_cost numeric,
  driver_cost numeric,
  transportation_cost numeric,
  transportation_cost_source text,
  other_direct_cost numeric,
  pending_direct_cost numeric,
  total_direct_cost numeric,
  gross_profit numeric,
  margin_percent numeric,
  revenue_per_mile numeric,
  cost_per_mile numeric,
  profit_per_mile numeric,
  profitability_status public.profitability_status
)
language sql
stable
as $$
  with base as (
    select l.id as load_id, l.load_number, l.organization_id, l.status as load_status,
           l.broker_id, l.customer_id, l.total_miles as miles, l.rate as booked_rate
    from public.loads l
    where p_load_id is null or l.id = p_load_id
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as origin_city,
           max(state) filter (where stop_type = 'pickup') as origin_state,
           max(city) filter (where stop_type = 'delivery') as destination_city,
           max(state) filter (where stop_type = 'delivery') as destination_state
    from public.load_stops
    where load_id in (select load_id from base)
    group by load_id
  ),
  disp as (
    select distinct on (load_id)
      load_id, id as dispatch_id, carrier_id, driver_id, carrier_net_amount,
      coalesce(completed_at, dispatched_at)::date as delivery_date
    from public.dispatches
    where load_id in (select load_id from base)
    order by load_id, dispatched_at desc
  ),
  inv as (
    select distinct on (load_id)
      load_id, (subtotal_amount - discount_amount) as invoice_revenue
    from public.invoices
    where load_id in (select load_id from base) and status <> 'void'
    order by load_id, issue_date desc, created_at desc
  ),
  carrier_finalized as (
    select distinct on (sli.load_id)
      sli.load_id, sli.carrier_rate as cost
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.item_type = 'load_pay'
      and sli.load_id in (select load_id from base)
      and s.status in ('approved', 'partially_paid', 'paid')
    order by sli.load_id, sli.created_at desc
  ),
  driver_finalized as (
    select distinct on (dsi.load_id)
      dsi.load_id, dsi.gross_pay as cost
    from public.driver_settlement_items dsi
    join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
    where dsi.load_id in (select load_id from base)
      and ds.status in ('approved', 'partially_paid', 'paid')
    order by dsi.load_id, dsi.created_at desc
  ),
  rated_drivers as (
    select distinct driver_id from public.driver_pay_rates
  ),
  driver_estimate as (
    select b.load_id, calc.gross_pay as cost
    from base b
    join disp d on d.load_id = b.load_id
    join rated_drivers rd on rd.driver_id = d.driver_id
    cross join lateral public.calculate_driver_load_pay(d.driver_id, b.load_id) calc
  ),
  direct_exp as (
    select * from public.get_load_direct_expenses(p_load_id)
  ),
  resolved as (
    select
      b.load_id,
      d.delivery_date,
      d.carrier_id,
      d.driver_id,
      coalesce(inv.invoice_revenue, nullif(b.booked_rate, 0)) as revenue,
      case when inv.invoice_revenue is not null then 'invoice'
           when b.booked_rate is not null and b.booked_rate <> 0 then 'load_rate_estimated'
           else null end as revenue_source,
      cf.cost as carrier_finalized_cost,
      df.cost as driver_finalized_cost,
      de.cost as driver_estimate_cost,
      d.carrier_net_amount as carrier_estimate_cost,
      coalesce(dx.approved_direct_expense_total, 0) as other_direct_cost,
      coalesce(dx.pending_direct_expense_total, 0) as pending_direct_cost,
      coalesce(dx.pending_expense_count, 0) as pending_expense_count
    from base b
    left join disp d on d.load_id = b.load_id
    left join inv on inv.load_id = b.load_id
    left join carrier_finalized cf on cf.load_id = b.load_id
    left join driver_finalized df on df.load_id = b.load_id
    left join driver_estimate de on de.load_id = b.load_id
    left join direct_exp dx on dx.load_id = b.load_id
  )
  select
    b.load_id, b.load_number, b.organization_id,
    r.delivery_date, b.load_status, b.broker_id, b.customer_id,
    r.carrier_id, r.driver_id,
    st.origin_city, st.origin_state, st.destination_city, st.destination_state,
    b.miles,
    r.revenue, r.revenue_source,
    case when r.carrier_finalized_cost is not null then r.carrier_finalized_cost
         when r.driver_finalized_cost is null and r.driver_estimate_cost is null and r.carrier_estimate_cost is not null then r.carrier_estimate_cost
         else 0 end as carrier_cost,
    case when r.driver_finalized_cost is not null then r.driver_finalized_cost
         when r.carrier_finalized_cost is null and r.driver_estimate_cost is not null then r.driver_estimate_cost
         else 0 end as driver_cost,
    coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) as transportation_cost,
    case when r.carrier_finalized_cost is not null then 'carrier_settlement_finalized'
         when r.driver_finalized_cost is not null then 'driver_settlement_finalized'
         when r.driver_estimate_cost is not null then 'driver_pay_estimated'
         when r.carrier_estimate_cost is not null then 'carrier_dispatch_estimated'
         else null end as transportation_cost_source,
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.other_direct_cost end as other_direct_cost,
    r.pending_direct_cost,
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost end as total_direct_cost,
    case when r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost) end as gross_profit,
    case when r.revenue is null or r.revenue = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost)) / r.revenue * 100, 6) end as margin_percent,
    case when b.miles is null or b.miles = 0 or r.revenue is null then null else round(r.revenue / b.miles, 4) end as revenue_per_mile,
    case when b.miles is null or b.miles = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost) / b.miles, 4) end as cost_per_mile,
    case when b.miles is null or b.miles = 0 or r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost)) / b.miles, 4) end as profit_per_mile,
    case
      when b.load_status not in ('delivered', 'pod_received', 'invoiced', 'closed') then 'NOT_DELIVERED'
      when r.revenue is null then 'MISSING_REVENUE'
      when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then 'MISSING_COST'
      when r.pending_expense_count > 0 then 'PENDING_EXPENSES'
      when r.revenue_source = 'invoice' and (r.carrier_finalized_cost is not null or r.driver_finalized_cost is not null) then 'COMPLETE'
      else 'ESTIMATED'
    end::public.profitability_status as profitability_status
  from base b
  left join stops st on st.load_id = b.load_id
  left join resolved r on r.load_id = b.load_id;
$$;

grant execute on function public.get_load_profitability(uuid) to authenticated;

comment on function public.get_load_profitability(uuid) is
  'Canonical load profitability, now integrated with the Expense & Cost Management module (0040): other_direct_cost is the real, always-evaluated sum of approved/paid scope=load expenses (0 when there genuinely are none, never an unresolved unknown), pending_direct_cost surfaces not-yet-approved load expenses separately, and PENDING_EXPENSES is reported instead of COMPLETE whenever draft/submitted load expenses exist so a final margin is never shown while cost is still coming in.';

-- ---------------------------------------------------------------------------
-- Private storage bucket for expense receipts -- 0040's copy of this
-- section never ran (execution stopped at the function above), confirmed
-- live: the expense-documents bucket does not exist yet. Same exact
-- pattern as load-documents. Bucket insert is already idempotent (on
-- conflict do nothing); policies are guarded with drop-if-exists so this
-- whole file is safe to re-run.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-documents', 'expense-documents', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

drop policy if exists expense_documents_select on storage.objects;
create policy expense_documents_select on storage.objects
  for select using (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

drop policy if exists expense_documents_insert on storage.objects;
create policy expense_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy -- a receipt is never edited in place; a
-- correction is a new upload attached to the (still-draft) expense, or a
-- void-and-re-enter once approved, matching every other document type.

-- =============================================================================
-- 0042_profile_sharing.sql
-- Shareable Driver / Carrier Profile workflow. Inspected first: drivers
-- (0003, expanded 0014), carriers (0003), insurance_policies (0014),
-- documents (0005, polymorphic entity_type already includes 'driver'/
-- 'carrier'/'load'), loads/load_stops/dispatches (0004), email_send_log
-- (0039, the pattern this mirrors for honest-blocked send logging),
-- statements' private-bucket + signed-URL pattern (0029, the pattern this
-- mirrors for PDF storage).
--
-- KEY DECISIONS:
-- 1. NOT a generic "take the full driver/carrier row and hide some fields"
--    view. Two new SQL functions, get_external_driver_profile() and
--    get_external_carrier_profile(), each with an explicit column list in
--    their SELECT -- the allowlist lives at the query level, so a future
--    sensitive column added to drivers/carriers can never silently leak
--    into an external PDF just by existing (spec section 21).
-- 2. drivers.photo_shareable (new, default false): the spec calls for the
--    driver photo to appear "if approved for sharing" -- no such consent
--    concept existed anywhere in the schema, so rather than silently
--    treating "a photo_url is set" as implicit approval, this is an
--    explicit, safe-by-default opt-in column staff must turn on per driver.
-- 3. profile_share_log is the single audit trail for every generate/
--    download/email attempt (spec section 12), with a frozen JSONB
--    snapshot of exactly what was shared (spec section 13) so later
--    changes to the live driver/carrier/load never rewrite history.
--    Never SECURITY DEFINER -- runs under the caller's own RLS.
-- 4. guard_profile_share_org: same-org guard on load_id/driver_id/
--    carrier_id (this session's standard cross-table-FK pattern) PLUS a
--    document-safety guard -- every id in document_ids_included must
--    already belong to the same org and to the driver/carrier on this
--    share, and if its document_type is in the sensitive list (cdl,
--    medical_card), the caller must be owner/admin. This is enforced at
--    the database level, not only in the UI, so a crafted API call can't
--    bypass it (spec section 23).
-- 5. Private 'shared-profiles' storage bucket, path
--    {organization_id}/{load_id}/{profile_share_id}/profile.pdf, signed
--    URLs only, no public bucket -- identical pattern to 'statements'
--    (0029) and 'expense-documents' (0040).
-- =============================================================================

create type public.profile_share_type as enum ('driver', 'carrier', 'combined');
create type public.profile_share_status as enum ('GENERATED', 'SENT', 'BLOCKED', 'FAILED');

-- ---------------------------------------------------------------------------
-- Explicit consent flag for including a driver's photo in an EXTERNAL
-- (broker/customer-facing) profile. Default false -- a photo_url being set
-- is not by itself "approved for sharing".
-- ---------------------------------------------------------------------------
alter table public.drivers add column photo_shareable boolean not null default false;

comment on column public.drivers.photo_shareable is
  'Explicit staff opt-in for including this driver''s photo in an external (broker/customer-facing) shared profile. Default false -- a photo_url existing is not itself consent to share it externally.';

-- photo_shareable needs to be selectable/settable like any ordinary driver
-- field -- drivers already has column-level grants locked down (0014) to
-- exclude only the three encrypted PII columns, so it's added to both.
grant select (photo_shareable) on public.drivers to authenticated;
grant update (photo_shareable) on public.drivers to authenticated;

-- ---------------------------------------------------------------------------
-- profile_share_log: audit trail + immutable snapshot for every generated
-- external profile (spec sections 12/13/19).
-- ---------------------------------------------------------------------------
create table public.profile_share_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete restrict,
  driver_id uuid references public.drivers (id) on delete set null,
  carrier_id uuid references public.carriers (id) on delete set null,
  profile_type public.profile_share_type not null,
  recipient_email text not null,
  recipient_party_type text check (recipient_party_type in ('broker', 'customer')),
  document_ids_included uuid[] not null default '{}'::uuid[],
  snapshot jsonb not null,
  storage_path text,
  status public.profile_share_status not null default 'GENERATED',
  error text,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.profiles (id) on delete set null,
  sent_at timestamptz,
  sent_by uuid references public.profiles (id) on delete set null,
  constraint profile_share_log_requires_subject check (driver_id is not null or carrier_id is not null),
  constraint profile_share_log_failure_requires_error check (status not in ('BLOCKED', 'FAILED') or error is not null)
);

comment on table public.profile_share_log is
  'Every Share Profile generate/download/email attempt for a load''s assigned driver/carrier. snapshot is a frozen JSONB copy of exactly what was shared (spec section 13) -- later edits to the live driver/carrier/load never change a historical row. document_ids_included stores document IDs only, never document contents (spec section 12).';

create index idx_profile_share_log_load on public.profile_share_log (load_id, generated_at desc);
create index idx_profile_share_log_org on public.profile_share_log (organization_id, generated_at desc);

alter table public.profile_share_log enable row level security;

create policy profile_share_log_select on public.profile_share_log
  for select using (organization_id = public.current_org_id());

create policy profile_share_log_insert on public.profile_share_log
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- Sending is the only post-insert mutation ever allowed (GENERATED -> SENT/
-- BLOCKED/FAILED, plus sent_at/sent_by/error) -- see guard_profile_share_
-- immutable below for what's actually enforced. Same role list as insert:
-- whoever could generate a share can also attempt to send it.
create policy profile_share_log_update on public.profile_share_log
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- No delete policy -- append-only audit trail, matching email_send_log
-- (0039) and driver_pii_access_log (0014).

-- ---------------------------------------------------------------------------
-- guard_profile_share_org: same-org guard on every FK, plus document
-- safety (spec sections 20/23).
-- ---------------------------------------------------------------------------
create or replace function public.guard_profile_share_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_doc record;
  v_matched integer := 0;
begin
  select organization_id into v_org from public.loads where id = new.load_id;
  if v_org is null or v_org <> new.organization_id then
    raise exception 'Load must belong to the same organization.';
  end if;

  if new.driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Driver must belong to the same organization.';
    end if;
  end if;

  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Carrier must belong to the same organization.';
    end if;
  end if;

  if new.document_ids_included is not null and array_length(new.document_ids_included, 1) > 0 then
    for v_doc in
      select id, organization_id, entity_type, entity_id, document_type
      from public.documents
      where id = any(new.document_ids_included)
    loop
      v_matched := v_matched + 1;
      if v_doc.organization_id <> new.organization_id then
        raise exception 'Attached document does not belong to your organization.';
      end if;
      if not (
        (v_doc.entity_type = 'driver' and v_doc.entity_id = new.driver_id)
        or (v_doc.entity_type = 'carrier' and v_doc.entity_id = new.carrier_id)
      ) then
        raise exception 'Attached document does not belong to the driver/carrier on this share.';
      end if;
      if v_doc.document_type::text in ('cdl', 'medical_card') and not public.has_role(array['owner', 'admin']::public.org_role[]) then
        raise exception 'Only owners and admins may include sensitive identity/compliance documents.';
      end if;
    end loop;
    if v_matched <> array_length(new.document_ids_included, 1) then
      raise exception 'One or more attached document ids are invalid.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists profile_share_log_guard_org on public.profile_share_log;
create trigger profile_share_log_guard_org
  before insert on public.profile_share_log
  for each row execute function public.guard_profile_share_org();

-- ---------------------------------------------------------------------------
-- guard_profile_share_immutable: once written, a share record is a
-- historical fact. The only legal updates are the send outcome (status/
-- error/sent_at/sent_by) -- everything else (snapshot, recipient,
-- document list, which driver/carrier/load) is frozen, matching "no
-- overwrite" (spec section 33) and "do not rely only on CSS hiding /
-- silently regenerate historical profiles" (spec section 19/22).
-- ---------------------------------------------------------------------------
create or replace function public.guard_profile_share_immutable()
returns trigger
language plpgsql
as $$
begin
  -- storage_path is reserve-row-then-upload-then-fill (same pattern as
  -- statements/actions.ts::generateStatement): the row is inserted first
  -- so the PDF's storage path can be keyed on a real id, then filled in by
  -- a follow-up UPDATE once the upload succeeds. That ONE null-to-value
  -- transition is allowed; any change after it's already set is not (no
  -- swapping the file a share record points to after the fact).
  if new.storage_path is distinct from old.storage_path and old.storage_path is not null then
    raise exception 'A generated profile''s storage path cannot be changed once set.';
  end if;
  if new.snapshot is distinct from old.snapshot
    or new.recipient_email is distinct from old.recipient_email
    or new.profile_type is distinct from old.profile_type
    or new.document_ids_included is distinct from old.document_ids_included
    or new.load_id is distinct from old.load_id
    or new.driver_id is distinct from old.driver_id
    or new.carrier_id is distinct from old.carrier_id
  then
    raise exception 'A generated profile share is a historical record and cannot be modified -- only its storage path (once, on first upload) and send outcome (status/error/sent_at/sent_by) may change.';
  end if;
  if old.status <> 'GENERATED' and new.status is distinct from old.status then
    raise exception 'A share''s send outcome can only be recorded once.';
  end if;
  return new;
end;
$$;

drop trigger if exists profile_share_log_guard_immutable on public.profile_share_log;
create trigger profile_share_log_guard_immutable
  before update on public.profile_share_log
  for each row execute function public.guard_profile_share_immutable();

-- ---------------------------------------------------------------------------
-- get_external_driver_profile: THE allowlist for driver data on an
-- external profile. Explicit column list -- no select(*), so a future
-- sensitive column added to drivers cannot silently appear here (spec
-- section 21). Never returns SSN, DOB, address, emergency contact,
-- employment application, bank info, pay rate, or any HR/background/drug
-- test detail -- this function has no SELECT path to any of them at all.
-- ---------------------------------------------------------------------------
create or replace function public.get_external_driver_profile(p_driver_id uuid)
returns table (
  driver_id uuid,
  full_name text,
  phone text,
  photo_url text,
  status public.driver_status,
  cdl_class text,
  cdl_state text,
  cdl_expiry_date date,
  cdl_endorsements text,
  medical_card_expiry_date date,
  years_experience numeric,
  completed_trips bigint
)
language sql
stable
as $$
  select
    d.id,
    trim(d.first_name || ' ' || d.last_name),
    d.phone,
    case when d.photo_shareable then d.photo_url else null end,
    d.status,
    d.cdl_class,
    d.cdl_state,
    d.cdl_expiry_date,
    d.cdl_endorsements,
    d.medical_card_expiry_date,
    case when d.hire_date is not null then round((current_date - d.hire_date) / 365.25, 1) else null end,
    (select count(*) from public.dispatches disp where disp.driver_id = d.id and disp.status = 'completed')
  from public.drivers d
  where d.id = p_driver_id;
$$;

grant execute on function public.get_external_driver_profile(uuid) to authenticated;

comment on function public.get_external_driver_profile(uuid) is
  'Broker/customer-safe driver allowlist. Deliberately excludes: SSN, DOB, home address, emergency contact, employment application fields, bank/direct-deposit info, pay rate/type, background check/drug test/MVR details, internal notes -- none of those columns are referenced in this function''s body at all.';

-- ---------------------------------------------------------------------------
-- get_external_carrier_profile: same allowlist principle for carriers.
-- Never returns settlement amounts, pay rate, Quick Pay fee, advances,
-- deductions, margin, banking, internal notes, or EIN -- no SELECT path to
-- settlements/settlement_line_items/dispatch_advances/carriers.ein exists
-- in this function.
--
-- "Auto Liability" (spec wording) is mapped to insurance_policies'
-- 'general_liability' policy_type -- the closest and only carrier-level
-- liability coverage this schema tracks (0014_company_driver_compliance_
-- expansion.sql defines general_liability/cargo/physical_damage/
-- workers_compensation; there is no separate "auto_liability" type).
-- ---------------------------------------------------------------------------
create or replace function public.get_external_carrier_profile(p_carrier_id uuid)
returns table (
  carrier_id uuid,
  legal_name text,
  dba_name text,
  mc_number text,
  dot_number text,
  phone text,
  email text,
  address text,
  is_active boolean,
  auto_liability_status text,
  auto_liability_expiry date,
  cargo_insurance_status text,
  cargo_insurance_expiry date,
  completed_loads bigint
)
language sql
stable
as $$
  with gl as (
    select expiry_date from public.insurance_policies
    where carrier_id = p_carrier_id and policy_type = 'general_liability'
    order by expiry_date desc nulls last
    limit 1
  ),
  cargo as (
    select expiry_date from public.insurance_policies
    where carrier_id = p_carrier_id and policy_type = 'cargo'
    order by expiry_date desc nulls last
    limit 1
  )
  select
    c.id, c.legal_name, c.dba_name, c.mc_number, c.dot_number, c.phone, c.email,
    nullif(concat_ws(', ', c.address_line1, c.city, c.state, c.postal_code), ''),
    c.is_active,
    -- Lowercase 'active'/'expired'/'missing' -- matches the same status
    -- vocabulary StatusBadge (src/components/ui/status-badge.tsx) already
    -- maps to success/danger/neutral tones everywhere else in this app,
    -- so the profile UI needs no special-casing to color these correctly.
    case when gl.expiry_date is null then 'missing' when gl.expiry_date >= current_date then 'active' else 'expired' end,
    gl.expiry_date,
    case when cargo.expiry_date is null then 'missing' when cargo.expiry_date >= current_date then 'active' else 'expired' end,
    cargo.expiry_date,
    (select count(*) from public.dispatches disp where disp.carrier_id = c.id and disp.status = 'completed')
  from public.carriers c
  left join gl on true
  left join cargo on true
  where c.id = p_carrier_id;
$$;

grant execute on function public.get_external_carrier_profile(uuid) to authenticated;

comment on function public.get_external_carrier_profile(uuid) is
  'Broker/customer-safe carrier allowlist. Deliberately excludes: settlement amounts, carrier pay rate, Quick Pay fee, advances, deductions, company margin, banking info, internal notes, EIN -- none of those columns/tables are referenced in this function''s body at all.';

-- ---------------------------------------------------------------------------
-- Private storage bucket for generated profile-share PDFs (spec section
-- 14). No public URL ever; every read is a fresh short-lived signed URL,
-- identical convention to 'statements' (0029) and 'expense-documents'
-- (0040/0041).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shared-profiles', 'shared-profiles', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

drop policy if exists shared_profiles_select on storage.objects;
create policy shared_profiles_select on storage.objects
  for select using (
    bucket_id = 'shared-profiles'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

drop policy if exists shared_profiles_insert on storage.objects;
create policy shared_profiles_insert on storage.objects
  for insert with check (
    bucket_id = 'shared-profiles'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy -- a generated profile PDF is never edited or
-- replaced in place; a new share is a new object at a new profile_share_id
-- path, matching every other document/receipt bucket in this codebase.

-- =============================================================================
-- 0043_profile_sharing_fix.sql
-- Live-test bugfix for 0042_profile_sharing.sql (Test H5).
--
-- BUG: guard_profile_share_org() only gated SENSITIVE document types
-- (cdl, medical_card) behind an owner/admin role check. It never checked
-- whether a document's type was on any allowlist at all -- a document of
-- an unsupported/arbitrary type (e.g. 'other', which the Share dialog
-- never offers as a candidate in the first place) that genuinely belonged
-- to the correct driver/carrier and organization was silently accepted
-- as if it were "safe", because the function only distinguished
-- safe-vs-sensitive for the ROLE check, not membership in either
-- allowlist to begin with. Confirmed live: a document_type='other' row
-- belonging to the correct driver was successfully attached by an Owner.
--
-- FIX: explicit allowlist of every document_type this feature is willing
-- to attach at all (the exact same 4 values SAFE_DOCUMENT_TYPES +
-- SENSITIVE_DOCUMENT_TYPES enumerate in src/lib/profile-share/generate.ts)
-- -- anything else is rejected outright, regardless of ownership or role.
-- =============================================================================

create or replace function public.guard_profile_share_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_doc record;
  v_matched integer := 0;
begin
  select organization_id into v_org from public.loads where id = new.load_id;
  if v_org is null or v_org <> new.organization_id then
    raise exception 'Load must belong to the same organization.';
  end if;

  if new.driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Driver must belong to the same organization.';
    end if;
  end if;

  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Carrier must belong to the same organization.';
    end if;
  end if;

  if new.document_ids_included is not null and array_length(new.document_ids_included, 1) > 0 then
    for v_doc in
      select id, organization_id, entity_type, entity_id, document_type
      from public.documents
      where id = any(new.document_ids_included)
    loop
      v_matched := v_matched + 1;
      if v_doc.organization_id <> new.organization_id then
        raise exception 'Attached document does not belong to your organization.';
      end if;
      if not (
        (v_doc.entity_type = 'driver' and v_doc.entity_id = new.driver_id)
        or (v_doc.entity_type = 'carrier' and v_doc.entity_id = new.carrier_id)
      ) then
        raise exception 'Attached document does not belong to the driver/carrier on this share.';
      end if;
      -- Explicit allowlist -- fixes the gap found live in Test H5.
      -- Matches SAFE_DOCUMENT_TYPES + SENSITIVE_DOCUMENT_TYPES exactly
      -- (src/lib/profile-share/generate.ts). Anything else (w9, other,
      -- bol, rate_confirmation, etc.) is never attachable to an external
      -- profile share, regardless of ownership or role.
      if v_doc.document_type::text not in ('insurance_certificate', 'motor_carrier_authority', 'cdl', 'medical_card') then
        raise exception 'This document type is not eligible for external profile sharing.';
      end if;
      if v_doc.document_type::text in ('cdl', 'medical_card') and not public.has_role(array['owner', 'admin']::public.org_role[]) then
        raise exception 'Only owners and admins may include sensitive identity/compliance documents.';
      end if;
    end loop;
    if v_matched <> array_length(new.document_ids_included, 1) then
      raise exception 'One or more attached document ids are invalid.';
    end if;
  end if;

  return new;
end;
$$;

-- =============================================================================
-- 0044_driver_portal_upgrade.sql
-- Driver Portal upgrade. Almost everything in this pass is pure
-- application code reusing existing tables/enums/triggers/RLS/storage
-- exactly as instructed -- no new dispatch/document/expense/settlement
-- structures. Exactly ONE real database fix was required, found live
-- (Test: "Dispatch -> Load -> Invoice Regression").
--
-- BUG: marking a dispatch "Delivered" from the Driver Portal uses the
-- service-role client (drivers have no Supabase Auth session/auth.uid()
-- at all -- see src/lib/driver-portal/session.ts, unchanged this pass).
-- That UPDATE correctly cascades through the EXISTING, untouched trigger
-- chain: dispatches_sync_load_status -> loads.status = 'delivered' ->
-- auto_generate_invoice_on_delivery -> auto_generate_invoice_from_
-- delivered_load() (0028_auto_invoice_dispatch_sync_fix.sql), which calls
-- public.log_activity('invoice', v_invoice_id, 'created'). log_activity()
-- (0009_functions_triggers.sql) inserts into activity_logs using
-- public.current_org_id(), which reads `select organization_id from
-- profiles where id = auth.uid()`. Under the driver portal's service-role
-- client there is no auth.uid() at all, so current_org_id() returns NULL,
-- and the insert into activity_logs (organization_id not null) throws --
-- which aborts the ENTIRE triggering UPDATE, including the dispatches.status
-- write itself. Confirmed live: before this fix, a driver marking a trip
-- Delivered failed outright with "null value in column organization_id of
-- relation activity_logs violates not-null constraint" -- the dispatch
-- never actually reached 'delivered', the load never synced, and no
-- invoice was created.
--
-- FIX: log_activity() gets one new, backward-compatible optional
-- parameter, p_organization_id default null. Every EXISTING call site
-- (staff-side, always under a real Supabase Auth session) is untouched
-- and keeps resolving it from current_org_id() exactly as before.
-- auto_generate_invoice_from_delivered_load() is the only call site
-- updated to pass NEW.organization_id explicitly, so it no longer depends
-- on a session that may not exist -- this makes the trigger itself
-- correct for ANY caller (service-role driver portal, staff RLS session,
-- or a future integration), not just a driver-portal-specific carve-out.
-- =============================================================================

create or replace function public.log_activity(
  p_entity_type public.entity_type,
  p_entity_id uuid,
  p_action text,
  p_changes jsonb default null,
  p_organization_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.activity_logs (organization_id, entity_type, entity_id, action, actor_id, changes)
  values (coalesce(p_organization_id, public.current_org_id()), p_entity_type, p_entity_id, p_action, auth.uid(), p_changes)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.log_activity(public.entity_type, uuid, text, jsonb, uuid) to authenticated;

-- Same body as 0028, only the log_activity() call now passes NEW.organization_id.
create or replace function public.auto_generate_invoice_from_delivered_load()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_to_name text;
  v_bill_to_email text;
  v_bill_to_address text;
  v_payment_terms integer;
  v_org_default_terms integer;
  v_invoice_number text;
  v_dispatch_id uuid;
  v_invoice_id uuid;
begin
  if NEW.status is distinct from 'delivered' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and OLD.status is not distinct from 'delivered' then
    return NEW;
  end if;

  if exists (select 1 from public.invoices where load_id = NEW.id) then
    return NEW;
  end if;

  if NEW.broker_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', address_line1, city, state, postal_code)), ''),
           payment_terms_days
      into v_bill_to_name, v_bill_to_email, v_bill_to_address, v_payment_terms
    from public.brokers where id = NEW.broker_id;
  elsif NEW.customer_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', billing_address_line1, city, state, postal_code)), ''),
           payment_terms_days
      into v_bill_to_name, v_bill_to_email, v_bill_to_address, v_payment_terms
    from public.customers where id = NEW.customer_id;
  else
    return NEW;
  end if;

  select default_payment_terms_days into v_org_default_terms
  from public.organizations where id = NEW.organization_id;

  select id into v_dispatch_id from public.dispatches where load_id = NEW.id limit 1;
  v_invoice_number := public.generate_invoice_number(NEW.organization_id);

  insert into public.invoices (
    organization_id, invoice_number, load_id, dispatch_id, broker_id, customer_id,
    status, bill_to_name, bill_to_email, bill_to_address,
    subtotal_amount, total_amount, issue_date, due_date, notes
  ) values (
    NEW.organization_id, v_invoice_number, NEW.id, v_dispatch_id, NEW.broker_id, NEW.customer_id,
    'draft', v_bill_to_name, v_bill_to_email, v_bill_to_address,
    NEW.rate, NEW.rate, current_date,
    current_date + coalesce(v_payment_terms, v_org_default_terms, 30),
    'Auto-generated on delivery for load ' || NEW.load_number
  )
  on conflict (load_id) where load_id is not null do nothing
  returning id into v_invoice_id;

  if v_invoice_id is not null then
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (NEW.organization_id, v_invoice_id, 'Freight charges -- Load ' || NEW.load_number, 1, NEW.rate, 0);

    -- p_organization_id explicit -- see header comment. This is the one
    -- real functional fix in this migration.
    perform public.log_activity('invoice', v_invoice_id, 'created', null, NEW.organization_id);
  end if;

  return NEW;
end;
$$;

-- Trigger definition itself (name/table/timing/columns) is unchanged --
-- only the function body above changed, via create or replace.
drop trigger if exists auto_generate_invoice_on_delivery on public.loads;
create trigger auto_generate_invoice_on_delivery
  after update on public.loads
  for each row execute function public.auto_generate_invoice_from_delivered_load();

-- ---------------------------------------------------------------------------
-- Defensive re-run: found live while testing driver-portal expense receipt
-- upload (which reuses this exact bucket, spec section 14) that the
-- expense-documents bucket does not exist on this database, even though
-- 0041_expense_cost_management_fix.sql already contains this identical
-- block. Unrelated to anything in this pass -- re-included here, fully
-- idempotent (on conflict do nothing / drop policy if exists), so this
-- migration guarantees the bucket exists regardless of what happened with
-- 0041 on this specific database.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-documents', 'expense-documents', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

drop policy if exists expense_documents_select on storage.objects;
create policy expense_documents_select on storage.objects
  for select using (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

drop policy if exists expense_documents_insert on storage.objects;
create policy expense_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- =============================================================================
-- 0045_platform_console_redesign.sql
-- Platform Console (Overview dashboard) redesign. This is a UI/analytics
-- pass over existing data -- almost everything is computed from
-- organizations/organization_subscriptions/subscription_plans/
-- billing_records, all already cross-tenant-readable by platform admins
-- via the 4 policies added in 0016_platform_admin.sql. Only two things
-- were genuinely missing from the existing schema, both added here in the
-- exact same security shape already established in 0016 -- nothing here
-- weakens tenant RLS or grants platform admins broad row-level access to
-- operational data.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. get_platform_operational_snapshot(): the platform-wide analog of the
-- existing get_org_usage_counts(p_org_id) -- same pattern (SECURITY
-- DEFINER, is_platform_admin() gate, counts only, never raw rows),
-- just summed across every tenant instead of one. dispatches/invoices
-- have no platform-admin RLS path today (deliberately, per 0016's own
-- comment) -- this is the narrow, count-only way to power the "Right Now"
-- panel without adding a broad cross-tenant SELECT policy on operational
-- tables.
-- ---------------------------------------------------------------------------
create or replace function public.get_platform_operational_snapshot()
returns table (active_users bigint, live_dispatches bigint, open_invoices bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  return query
    select
      (select count(*) from public.profiles where is_active = true),
      (select count(*) from public.dispatches
         where status in ('assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded', 'en_route_to_delivery', 'at_delivery')),
      (select count(*) from public.invoices where status not in ('paid', 'void'));
end;
$$;

grant execute on function public.get_platform_operational_snapshot() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Cross-tenant read on activity_logs for the Recent Platform Activity
-- feed -- identical shape to organizations_platform_admin_select /
-- profiles_platform_admin_select / billing_records_platform_admin_select
-- (0016). Additive only: the existing tenant-scoped activity_logs_select
-- policy (0010_rls_policies.sql) is untouched, so ordinary tenant users
-- see exactly what they always saw.
-- ---------------------------------------------------------------------------
create policy activity_logs_platform_admin_select on public.activity_logs
  for select using (public.is_platform_admin());

-- =============================================================================
-- 0046_platform_company_management.sql
-- Platform Console company/admin management. Reuses the existing
-- organizations/profiles/auth.users schema entirely -- no new
-- credentials/profile/company tables. Every privileged write goes through
-- either a narrow RLS policy (simple, unguarded fields) or a SECURITY
-- DEFINER RPC that re-checks is_platform_admin() itself (never trusts
-- that the caller already passed the superadmin layout check), following
-- the exact pattern already established by create_organization_with_owner
-- (0012_profile_privilege_guard.sql) and get_org_usage_counts (0016).
--
-- KEY EXISTING MECHANISMS REUSED (confirmed live before writing this):
-- - profiles_protect_privileged_columns trigger (0012) already blocks ANY
--   direct UPDATE of profiles.organization_id/role unless the caller is
--   owner/admin of that row's CURRENT org, or the session-local
--   app.bypass_profile_guard flag is set -- exactly the mechanism a
--   platform admin (who belongs to no tenant org at all) needs to go
--   through deliberately, not around.
-- - organization_subscriptions.status is the REAL access-control gate
--   (src/lib/supabase/middleware.ts: BLOCKED_SUBSCRIPTION_STATUSES
--   includes 'paused') -- Activate/Suspend reuses the existing
--   updateOrgSubscription action and organization_subscriptions_
--   platform_admin_all policy (0016). No new status field invented.
-- - handle_new_user() (0009) already auto-creates a profiles row (org
--   null, role 'dispatcher') the instant an auth.users row is created --
--   including via the Admin API -- so creating a new tenant admin never
--   needs a manual profiles INSERT, only an UPDATE of the auto-created row.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. log_activity() 5-parameter overload (also shipped in
-- 0044_driver_portal_upgrade.sql, which may not be applied on this
-- database yet). Repeated here, identically, because this migration's own
-- audit logging depends on it -- a platform admin's own profile has
-- organization_id = null, so the 4-parameter version's current_org_id()
-- fallback fails exactly like it did for the driver-portal delivery bug.
-- Idempotent (create or replace); harmless if 0044 also defines it.
-- ---------------------------------------------------------------------------
create or replace function public.log_activity(
  p_entity_type public.entity_type,
  p_entity_id uuid,
  p_action text,
  p_changes jsonb default null,
  p_organization_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.activity_logs (organization_id, entity_type, entity_id, action, actor_id, changes)
  values (coalesce(p_organization_id, public.current_org_id()), p_entity_type, p_entity_id, p_action, auth.uid(), p_changes)
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.log_activity(public.entity_type, uuid, text, jsonb, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Cross-tenant UPDATE for simple, unguarded fields. organizations had
-- only a SELECT policy (0016); profiles had none at all. Both are
-- additive -- existing tenant-scoped policies are untouched. The
-- privileged columns on profiles (organization_id, role) stay protected
-- regardless of this policy by the existing guard trigger above -- this
-- policy alone is NOT enough to change them, by design.
-- ---------------------------------------------------------------------------
create policy organizations_platform_admin_update on public.organizations
  for update using (public.is_platform_admin())
  with check (public.is_platform_admin());

create policy profiles_platform_admin_update on public.profiles
  for update using (public.is_platform_admin())
  with check (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. platform_create_organization_with_owner: the platform-admin analog of
-- create_organization_with_owner (0012), targeting an arbitrary existing
-- auth user (the new tenant's primary admin, already created via the
-- Admin API in application code) instead of auth.uid(). Same bypass-flag
-- technique, same "must not already belong to an org" safety check.
-- ---------------------------------------------------------------------------
create or replace function public.platform_create_organization_with_owner(
  p_name text,
  p_slug text,
  p_owner_user_id uuid
)
returns public.organizations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org public.organizations;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if not exists (select 1 from public.profiles where id = p_owner_user_id) then
    raise exception 'owner profile not found';
  end if;

  if exists (select 1 from public.profiles where id = p_owner_user_id and organization_id is not null) then
    raise exception 'that user already belongs to an organization';
  end if;

  insert into public.organizations (name, slug)
  values (p_name, p_slug)
  returning * into v_org;

  perform set_config('app.bypass_profile_guard', 'true', true);

  update public.profiles
  set organization_id = v_org.id,
      role = 'owner'
  where id = p_owner_user_id;

  return v_org;
end;
$$;

grant execute on function public.platform_create_organization_with_owner(text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. platform_assign_user_to_org: for "Add Admin" to an EXISTING company --
-- the target auth user already exists (just created via the Admin API,
-- profile auto-created by handle_new_user with organization_id null) and
-- is being attached to a specific org with a specific role.
-- ---------------------------------------------------------------------------
create or replace function public.platform_assign_user_to_org(
  p_user_id uuid,
  p_org_id uuid,
  p_role public.org_role
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if not exists (select 1 from public.organizations where id = p_org_id) then
    raise exception 'organization not found';
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'user profile not found';
  end if;

  if exists (select 1 from public.profiles where id = p_user_id and organization_id is not null and organization_id <> p_org_id) then
    raise exception 'that user already belongs to a different organization';
  end if;

  perform set_config('app.bypass_profile_guard', 'true', true);

  update public.profiles
  set organization_id = p_org_id,
      role = p_role
  where id = p_user_id;
end;
$$;

grant execute on function public.platform_assign_user_to_org(uuid, uuid, public.org_role) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. platform_is_last_owner: shared last-owner check, used by both the
-- role-change and deactivate flows (spec: "Protect against accidental
-- removal of the company's final owner").
-- ---------------------------------------------------------------------------
create or replace function public.platform_is_last_owner(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    p.role = 'owner'
    and (
      select count(*) from public.profiles p2
      where p2.organization_id = p.organization_id and p2.role = 'owner' and p2.id <> p.id
    ) = 0
  from public.profiles p
  where p.id = p_user_id and p.organization_id is not null;
$$;

grant execute on function public.platform_is_last_owner(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. platform_update_user_role: role changes only (organization_id
-- untouched) -- last-owner-protected.
-- ---------------------------------------------------------------------------
create or replace function public.platform_update_user_role(
  p_user_id uuid,
  p_role public.org_role
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if p_role <> 'owner' and public.platform_is_last_owner(p_user_id) then
    raise exception 'cannot change role: this user is the only owner of their organization';
  end if;

  perform set_config('app.bypass_profile_guard', 'true', true);

  update public.profiles set role = p_role where id = p_user_id;
end;
$$;

grant execute on function public.platform_update_user_role(uuid, public.org_role) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. platform_set_user_active: deactivate/reactivate. is_active is not a
-- guarded column, so this could in principle go through the plain RLS
-- policy above -- it's still a dedicated function so the last-owner check
-- applies consistently to deactivation too, and so it's one auditable
-- entry point rather than a bare table write.
-- ---------------------------------------------------------------------------
create or replace function public.platform_set_user_active(
  p_user_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if not p_is_active and public.platform_is_last_owner(p_user_id) then
    raise exception 'cannot deactivate: this user is the only owner of their organization';
  end if;

  update public.profiles set is_active = p_is_active where id = p_user_id;
end;
$$;

grant execute on function public.platform_set_user_active(uuid, boolean) to authenticated;


-- =============================================================================
-- 0047_new_load_workflow.sql
-- Atomic Load + Stops creation for the upgraded New Load screen. Reuses the
-- existing loads/load_stops tables verbatim (no new columns -- load_type,
-- PO#, pieces/pallets, temperature, hazmat all have no existing column and
-- no other part of the app reads them, so none are added here). document_type
-- already contains 'rate_confirmation' (0001) -- no enum change needed.
--
-- create_load_with_stops() is intentionally NOT security definer: it runs
-- as the calling authenticated user, so the exact same RLS policies that
-- already govern `loads`/`load_stops` (0010_rls_policies.sql: org-scoped,
-- owner/admin/dispatcher write) apply to both inserts inside it, unchanged.
-- Atomicity comes from this being a single function invocation -- Postgres
-- rolls back everything the function did if any statement inside it raises,
-- so a load can never be left behind with a partially-failed stop list (or
-- vice versa) without any manual compensating-delete logic.
-- =============================================================================

create or replace function public.create_load_with_stops(
  p_load jsonb,
  p_stops jsonb
)
returns uuid
language plpgsql
as $$
declare
  v_org_id uuid;
  v_load_id uuid;
  v_stop jsonb;
  v_stop_count integer;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'Could not determine the current organization for this user.';
  end if;

  v_stop_count := coalesce(jsonb_array_length(p_stops), 0);
  if v_stop_count = 0 then
    raise exception 'At least a pickup and a delivery stop are required.';
  end if;

  insert into public.loads (
    organization_id, load_number, broker_id, customer_id, status, commodity,
    weight_lbs, equipment_type, total_miles, rate, rate_confirmation_number,
    special_instructions, booked_by
  )
  values (
    v_org_id,
    p_load ->> 'load_number',
    nullif(p_load ->> 'broker_id', '')::uuid,
    nullif(p_load ->> 'customer_id', '')::uuid,
    coalesce(nullif(p_load ->> 'status', ''), 'draft')::public.load_status,
    nullif(p_load ->> 'commodity', ''),
    nullif(p_load ->> 'weight_lbs', '')::integer,
    nullif(p_load ->> 'equipment_type', ''),
    nullif(p_load ->> 'total_miles', '')::numeric,
    coalesce(nullif(p_load ->> 'rate', '')::numeric, 0),
    nullif(p_load ->> 'rate_confirmation_number', ''),
    nullif(p_load ->> 'special_instructions', ''),
    -- Dispatcher/booked-by is always the real calling user, never a
    -- client-supplied id -- prevents one dispatcher from attributing a
    -- booking to someone else.
    auth.uid()
  )
  returning id into v_load_id;

  for v_stop in select * from jsonb_array_elements(p_stops)
  loop
    insert into public.load_stops (
      organization_id, load_id, stop_type, stop_sequence, facility_name,
      address_line1, address_line2, city, state, postal_code, country,
      contact_name, contact_phone, scheduled_at, scheduled_window_end,
      reference_number, notes
    )
    values (
      v_org_id,
      v_load_id,
      (v_stop ->> 'stop_type')::public.stop_type,
      (v_stop ->> 'stop_sequence')::integer,
      nullif(v_stop ->> 'facility_name', ''),
      nullif(v_stop ->> 'address_line1', ''),
      nullif(v_stop ->> 'address_line2', ''),
      v_stop ->> 'city',
      v_stop ->> 'state',
      nullif(v_stop ->> 'postal_code', ''),
      coalesce(nullif(v_stop ->> 'country', ''), 'US'),
      nullif(v_stop ->> 'contact_name', ''),
      nullif(v_stop ->> 'contact_phone', ''),
      nullif(v_stop ->> 'scheduled_at', '')::timestamptz,
      nullif(v_stop ->> 'scheduled_window_end', '')::timestamptz,
      nullif(v_stop ->> 'reference_number', ''),
      nullif(v_stop ->> 'notes', '')
    );
  end loop;

  perform public.log_activity('load'::public.entity_type, v_load_id, 'created', p_load, v_org_id);

  return v_load_id;
end;
$$;

grant execute on function public.create_load_with_stops(jsonb, jsonb) to authenticated;


-- =============================================================================
-- 0048_dispatch_workflow_upgrade.sql
-- Dispatch page upgrade. Reuses the existing dispatches/loads/load_stops/
-- carriers/drivers/trucks/trailers schema verbatim -- no new tables, no new
-- enum values (dispatch_status already has 'cancelled'; trucks/trailers
-- already have ownership_type 'owner_operator' for Assignment Type).
--
-- ONE genuine gap found and fixed here: every other multi-FK table in this
-- schema (expenses, driver_pay_rates, profile_share_log, ...) has a
-- guard_*_org() trigger validating that its foreign keys belong to the
-- same organization as the row itself -- dispatches never got one. RLS on
-- `dispatches` only checks the dispatch row's own organization_id; it does
-- NOT verify that a submitted carrier_id/truck_id/driver_id/trailer_id
-- actually belongs to that org. Without this trigger, a crafted request
-- could assign another organization's carrier/driver/truck/trailer to a
-- dispatch. Also validates relationship consistency (the assigned
-- driver/truck actually belongs to the assigned carrier; a trailer, if
-- set, either belongs to that carrier or is unassigned/shared).
-- =============================================================================

create or replace function public.guard_dispatch_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_carrier_id uuid;
begin
  if new.load_id is not null then
    select organization_id into v_org from public.loads where id = new.load_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch load must belong to the same organization.';
    end if;
  end if;

  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch carrier must belong to the same organization.';
    end if;
  end if;

  if new.truck_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.trucks where id = new.truck_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch truck must belong to the same organization.';
    end if;
    if new.carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected truck does not belong to the selected carrier.';
    end if;
  end if;

  if new.driver_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch driver must belong to the same organization.';
    end if;
    if new.carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected driver does not belong to the selected carrier.';
    end if;
  end if;

  if new.trailer_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.trailers where id = new.trailer_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch trailer must belong to the same organization.';
    end if;
    -- Trailers may be a shared/unassigned pool (carrier_id nullable, 0003) --
    -- only reject a trailer that belongs to a DIFFERENT carrier, not one
    -- with no carrier at all.
    if new.carrier_id is not null and v_carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected trailer belongs to a different carrier.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists dispatches_guard_org on public.dispatches;
create trigger dispatches_guard_org
  before insert or update on public.dispatches
  for each row execute function public.guard_dispatch_org();


-- =============================================================================
-- 0049_log_activity_overload_fix.sql
--
-- REAL, LIVE BUG FOUND while testing the dispatch workflow upgrade (0048):
-- 0044/0046 added a 5-parameter log_activity() overload (p_changes,
-- p_organization_id both defaulted) via `create or replace function`. Since
-- the parameter LIST differs from the original 4-parameter version (0009),
-- Postgres treats this as a NEW, separate overload rather than a
-- replacement -- both the 4-param and 5-param versions have coexisted ever
-- since. Any caller supplying 3 or 4 arguments (matching both overloads'
-- required parameters, via the newer one's defaults) now gets:
--   "Could not choose the best candidate function... function
--    public.log_activity(...) is not unique"
--
-- This is not cosmetic: `auto_generate_invoice_from_delivered_load()`
-- (0022/0028)'s own internal call -- `perform public.log_activity('invoice',
-- v_invoice_id, 'created')`, 3 positional args -- hits this ambiguity too,
-- meaning the delivered-load -> auto-invoice trigger itself has been
-- silently broken since 0046 was applied. Confirmed live: marking a
-- dispatch delivered on a disposable test load failed with exactly this
-- error. src/lib/actions/records.ts's generic logActivity() helper (used
-- by every insertRecord/updateRecord/updateRecordInPlace/deleteRecord call
-- across the whole app -- carriers, brokers, customers, drivers, trucks,
-- trailers, loads, invoices, payments, settlements) calls with exactly 3
-- named args and is equally affected.
--
-- Fix: drop the now-redundant 4-parameter overload. The 5-parameter
-- version's behavior for 3/4-arg callers is identical (p_changes/
-- p_organization_id already default to null / current_org_id()) -- this
-- removes the ambiguity without changing behavior for any caller that
-- already specifies 5 arguments.
-- =============================================================================

drop function if exists public.log_activity(public.entity_type, uuid, text, jsonb);


-- =============================================================================
-- 0050_maintenance_management.sql
-- Maintenance & Preventive Maintenance Management. Extends the existing
-- maintenance_records table (0006) -- does not create a second maintenance
-- system. Reuses expenses (scope='truck'/'general', category='maintenance',
-- already-existing columns), the existing carrier/driver settlement
-- deduction mechanisms (settlement_line_items.item_type='deduction' /
-- driver_settlement_adjustments.bucket='deduction', both already modeled
-- on dispatch_advances' "paid now, recovered later" lifecycle via
-- linked_advance_id -- this migration adds the parallel linked_
-- maintenance_id column rather than inventing a new recovery mechanism),
-- the existing polymorphic documents table, and the existing
-- equipment_status enum (already has 'in_maintenance'/'out_of_service' --
-- no new availability flag).
--
-- GENUINE GAPS being filled (see chat architecture audit for why each is
-- actually needed, not just convenient):
--   1. maintenance_records has no payer/recovery/expense-link/status
--      columns at all today -- cost was a bare number.
--   2. No cross-org guard trigger exists on maintenance_records (same gap
--      class already found and fixed on dispatches in the prior session).
--   3. settlement_line_items / driver_settlement_adjustments have no way
--      to reference a maintenance record (only dispatch_advances, via
--      linked_advance_id).
--   4. 'maintenance' is not a valid entity_type value yet (needed for the
--      documents table + log_activity()).
--   5. 3 of the 6 requested document categories don't exist yet
--      (repair_invoice/inspection_report/expense_receipt/other already do).
--   6. No trigger prevents a maintenance charge from being recovered twice,
--      recovered beyond its recoverable amount, or recovered through BOTH
--      carrier and driver settlement at once.
--
-- RE-RUNNABLE BY DESIGN: every statement below is guarded (IF NOT EXISTS /
-- DROP ... IF EXISTS first / existence-checked DO blocks) so this file can
-- be safely re-executed after a partial failure without hand-editing it --
-- a first attempt at this migration hit a genuine bug (a DELETE trigger's
-- WHEN clause referencing NEW, which Postgres rejects) that rolled back
-- everything after the enum-value commit below; re-running the ORIGINAL
-- unguarded script a second time would then have failed immediately on
-- "type already exists" for nothing. Confirmed live before writing this
-- version: entity_type already has 'maintenance' (survived, committed
-- before the failure point); maintenance_records.status, linked_
-- maintenance_id, and every new function below do NOT exist yet (rolled
-- back) -- so this corrected version has real, needed work to do.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Enum extensions (additive only -- every existing value/usage untouched).
-- Already idempotent (IF NOT EXISTS) and already confirmed applied.
-- ---------------------------------------------------------------------------
alter type public.entity_type add value if not exists 'maintenance';
alter type public.document_type add value if not exists 'estimate';
alter type public.document_type add value if not exists 'before_photo';
alter type public.document_type add value if not exists 'after_photo';

commit; -- new enum values must be committed before use later in this script

-- Postgres has no CREATE TYPE IF NOT EXISTS -- guard each with an
-- existence check instead, so re-running this file is always safe.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'maintenance_status') then
    create type public.maintenance_status as enum ('open', 'completed', 'cancelled');
  end if;
end $$;

-- Mirrors the RECOVERY dropdown exactly (spec "PAYMENT & RESPONSIBILITY").
do $$
begin
  if not exists (select 1 from pg_type where typname = 'maintenance_paid_by') then
    create type public.maintenance_paid_by as enum ('dispatch_company', 'carrier', 'driver', 'other');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'maintenance_recovery_type') then
    create type public.maintenance_recovery_type as enum (
      'none', 'carrier_settlement', 'driver_settlement', 'carrier_direct', 'driver_direct'
    );
  end if;
end $$;

-- Derived at read time (get_maintenance_recovery_status() below), never
-- stored as the source of truth -- this column is a denormalized cache
-- refreshed by the same function/trigger, kept only so it can be filtered/
-- sorted in list views without a correlated subquery per row.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'maintenance_recovery_status') then
    create type public.maintenance_recovery_status as enum (
      'not_applicable', 'pending', 'partially_recovered', 'recovered'
    );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. maintenance_records: payment/recovery/status columns.
-- ---------------------------------------------------------------------------
alter table public.maintenance_records
  add column if not exists carrier_id uuid references public.carriers (id) on delete set null,
  add column if not exists status public.maintenance_status not null default 'open',
  add column if not exists paid_by public.maintenance_paid_by not null default 'dispatch_company',
  add column if not exists recovery_type public.maintenance_recovery_type not null default 'none',
  add column if not exists recoverable_amount numeric(10, 2) not null default 0,
  add column if not exists responsible_driver_id uuid references public.drivers (id) on delete set null,
  add column if not exists expense_id uuid references public.expenses (id) on delete set null,
  add column if not exists recovery_status public.maintenance_recovery_status not null default 'not_applicable',
  add column if not exists recovered_amount numeric(10, 2) not null default 0;

alter table public.maintenance_records drop constraint if exists maintenance_records_recoverable_le_cost;
alter table public.maintenance_records add constraint maintenance_records_recoverable_le_cost check (recoverable_amount <= cost);

alter table public.maintenance_records drop constraint if exists maintenance_records_recoverable_nonneg;
alter table public.maintenance_records add constraint maintenance_records_recoverable_nonneg check (recoverable_amount >= 0);

-- Recovery type dictates exactly one lane -- a responsible_driver_id only
-- makes sense (and is only required) when recovery_type = 'driver_settlement'.
alter table public.maintenance_records drop constraint if exists maintenance_records_driver_recovery_shape;
alter table public.maintenance_records add constraint maintenance_records_driver_recovery_shape check (
  (recovery_type = 'driver_settlement' and responsible_driver_id is not null)
  or (recovery_type <> 'driver_settlement')
);

-- recoverable_amount is only meaningful for the two settlement-recovery
-- paths; direct-paid and no-recovery paths recover nothing through this
-- app (spec Case 1 / Case 3).
alter table public.maintenance_records drop constraint if exists maintenance_records_recoverable_shape;
alter table public.maintenance_records add constraint maintenance_records_recoverable_shape check (
  (recovery_type in ('carrier_settlement', 'driver_settlement') and recoverable_amount >= 0)
  or (recovery_type not in ('carrier_settlement', 'driver_settlement') and recoverable_amount = 0)
);

comment on column public.maintenance_records.recovered_amount is
  'Denormalized cache of the sum of every non-void linked settlement_line_items/driver_settlement_adjustments row for this record -- kept in sync by sync_maintenance_recovery_status() below, whose result is the actual source of truth (get_maintenance_recovery_status()). Never edited directly by application code.';

create index if not exists idx_maintenance_records_carrier on public.maintenance_records (carrier_id) where carrier_id is not null;
create index if not exists idx_maintenance_records_status on public.maintenance_records (status);
create index if not exists idx_maintenance_records_recovery_status on public.maintenance_records (recovery_status);

-- ---------------------------------------------------------------------------
-- 2. Settlement deduction linkage -- mirrors linked_advance_id exactly
-- (both tables already have that column; this is the parallel for
-- maintenance, not a new mechanism).
-- ---------------------------------------------------------------------------
alter table public.settlement_line_items
  add column if not exists linked_maintenance_id uuid references public.maintenance_records (id) on delete set null;
alter table public.driver_settlement_adjustments
  add column if not exists linked_maintenance_id uuid references public.maintenance_records (id) on delete set null;

create index if not exists idx_settlement_line_items_maintenance on public.settlement_line_items (linked_maintenance_id) where linked_maintenance_id is not null;
create index if not exists idx_driver_settlement_adjustments_maintenance on public.driver_settlement_adjustments (linked_maintenance_id) where linked_maintenance_id is not null;

-- A given settlement can only carry ONE deduction line for a given
-- maintenance record -- double-click/retry protection (spec IDEMPOTENCY).
-- Partial recovery across DIFFERENT settlements is still fully supported;
-- this only blocks the SAME settlement from getting the same line twice.
create unique index if not exists uq_settlement_line_items_maintenance_per_settlement
  on public.settlement_line_items (settlement_id, linked_maintenance_id)
  where linked_maintenance_id is not null and item_type = 'deduction';
create unique index if not exists uq_driver_settlement_adjustments_maintenance_per_settlement
  on public.driver_settlement_adjustments (driver_settlement_id, linked_maintenance_id)
  where linked_maintenance_id is not null and bucket = 'deduction';

-- ---------------------------------------------------------------------------
-- 3. get_maintenance_recovery_status: THE canonical recovered/remaining/
-- status calculation -- sums real linked rows across BOTH settlement
-- tables (excluding void/cancelled settlements), never a duplicated
-- running total maintained by hand. This is what the recovered_amount/
-- recovery_status cache columns above are kept in sync with.
-- ---------------------------------------------------------------------------
create or replace function public.get_maintenance_recovery_status(p_maintenance_id uuid)
returns table (recoverable_amount numeric, recovered_amount numeric, remaining_amount numeric, recovery_status public.maintenance_recovery_status)
language sql
stable
as $$
  with m as (
    select mr.recoverable_amount, mr.recovery_type
    from public.maintenance_records mr
    where mr.id = p_maintenance_id
  ),
  carrier_recovered as (
    select coalesce(sum(sli.amount), 0) as amt
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.linked_maintenance_id = p_maintenance_id
      and sli.item_type = 'deduction'
      and s.status <> 'void'
  ),
  driver_recovered as (
    select coalesce(sum(dsa.amount), 0) as amt
    from public.driver_settlement_adjustments dsa
    join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
    where dsa.linked_maintenance_id = p_maintenance_id
      and dsa.bucket = 'deduction'
      and ds.status <> 'void'
  )
  select
    m.recoverable_amount,
    (select amt from carrier_recovered) + (select amt from driver_recovered),
    m.recoverable_amount - ((select amt from carrier_recovered) + (select amt from driver_recovered)),
    case
      when m.recovery_type not in ('carrier_settlement', 'driver_settlement') then 'not_applicable'::public.maintenance_recovery_status
      when (select amt from carrier_recovered) + (select amt from driver_recovered) <= 0 then 'pending'::public.maintenance_recovery_status
      when (select amt from carrier_recovered) + (select amt from driver_recovered) >= m.recoverable_amount then 'recovered'::public.maintenance_recovery_status
      else 'partially_recovered'::public.maintenance_recovery_status
    end
  from m;
$$;

grant execute on function public.get_maintenance_recovery_status(uuid) to authenticated;

-- Refreshes the two cache columns on maintenance_records from the
-- canonical function above -- called by the guard trigger below after
-- every insert/update/delete on either deduction table, so list views
-- never need a per-row correlated subquery.
create or replace function public.sync_maintenance_recovery_cache(p_maintenance_id uuid)
returns void
language plpgsql
as $$
declare
  v_row record;
begin
  select * into v_row from public.get_maintenance_recovery_status(p_maintenance_id);
  update public.maintenance_records
  set recovered_amount = v_row.recovered_amount,
      recovery_status = v_row.recovery_status
  where id = p_maintenance_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. guard_maintenance_recovery: the DOUBLE-COUNTING / DOUBLE-RECOVERY /
-- OWNER-OPERATOR PROTECTION enforcement point, at the database layer, not
-- just in application code (spec: "Reject contradictory dual recovery
-- server-side/database-side"). Fires on both settlement_line_items and
-- driver_settlement_adjustments, INSERT/UPDATE only (a DELETE has no NEW
-- row to validate -- cache resync for deletes is handled by the separate
-- AFTER trigger further down).
-- ---------------------------------------------------------------------------
create or replace function public.guard_maintenance_recovery()
returns trigger
language plpgsql
as $$
declare
  v_maintenance_id uuid;
  v_recovery_type public.maintenance_recovery_type;
  v_recoverable numeric;
  v_already_recovered numeric;
  v_org uuid;
begin
  v_maintenance_id := new.linked_maintenance_id;
  if v_maintenance_id is null then
    return new;
  end if;

  select organization_id, recovery_type, recoverable_amount
    into v_org, v_recovery_type, v_recoverable
  from public.maintenance_records where id = v_maintenance_id;

  if v_org is null then
    raise exception 'Linked maintenance record not found.';
  end if;
  if v_org <> new.organization_id then
    raise exception 'Maintenance recovery must belong to the same organization.';
  end if;

  -- One recovery lane only, matching maintenance_records.recovery_type --
  -- a carrier-recovery record can never also pick up a driver-settlement
  -- deduction, and vice versa (spec: "one financial responsibility path
  -- only unless an explicitly supported split is configured" -- no split
  -- mechanism exists, so this is a hard block).
  if tg_table_name = 'settlement_line_items' and v_recovery_type <> 'carrier_settlement' then
    raise exception 'This maintenance record is not marked for Carrier Settlement recovery.';
  end if;
  if tg_table_name = 'driver_settlement_adjustments' and v_recovery_type <> 'driver_settlement' then
    raise exception 'This maintenance record is not marked for Driver Settlement recovery.';
  end if;

  -- Sum every OTHER already-linked, non-void recovery row across BOTH
  -- tables (excluding this row itself, relevant on update) and confirm
  -- adding/changing this one doesn't exceed the recoverable amount --
  -- covers both "retry created a duplicate" and "two team-driver
  -- allocations together exceed the total" in one check.
  select coalesce(sum(amt), 0) into v_already_recovered from (
    select sli.amount as amt
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.linked_maintenance_id = v_maintenance_id
      and sli.item_type = 'deduction'
      and s.status <> 'void'
      and not (tg_table_name = 'settlement_line_items' and sli.id = new.id)
    union all
    select dsa.amount as amt
    from public.driver_settlement_adjustments dsa
    join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
    where dsa.linked_maintenance_id = v_maintenance_id
      and dsa.bucket = 'deduction'
      and ds.status <> 'void'
      and not (tg_table_name = 'driver_settlement_adjustments' and dsa.id = new.id)
  ) x;

  if v_already_recovered + new.amount > v_recoverable + 0.005 then
    raise exception 'Recovery amount cannot exceed the remaining recoverable balance (remaining: %).', round(v_recoverable - v_already_recovered, 2);
  end if;

  return new;
end;
$$;

drop trigger if exists settlement_line_items_guard_maintenance on public.settlement_line_items;
create trigger settlement_line_items_guard_maintenance
  before insert or update on public.settlement_line_items
  for each row
  when (new.linked_maintenance_id is not null)
  execute function public.guard_maintenance_recovery();

drop trigger if exists driver_settlement_adjustments_guard_maintenance on public.driver_settlement_adjustments;
create trigger driver_settlement_adjustments_guard_maintenance
  before insert or update on public.driver_settlement_adjustments
  for each row
  when (new.linked_maintenance_id is not null)
  execute function public.guard_maintenance_recovery();

-- Keep the cache in sync after every successful insert/update/delete
-- (AFTER, so it runs only once the guard above has already allowed it).
-- Two SEPARATE triggers per table (not one INSERT-OR-UPDATE-OR-DELETE
-- trigger with a combined WHEN clause): Postgres rejects a WHEN condition
-- that references NEW on a trigger that also fires on DELETE (NEW doesn't
-- exist for a deleted row) -- this is the exact bug the first version of
-- this migration hit live. INSERT/UPDATE share a NEW-based WHEN clause;
-- DELETE gets its own OLD-based one.
create or replace function public.trg_sync_maintenance_recovery_cache()
returns trigger
language plpgsql
as $$
begin
  perform public.sync_maintenance_recovery_cache(coalesce(new.linked_maintenance_id, old.linked_maintenance_id));
  return coalesce(new, old);
end;
$$;

drop trigger if exists settlement_line_items_sync_maintenance on public.settlement_line_items;
drop trigger if exists settlement_line_items_sync_maintenance_iu on public.settlement_line_items;
drop trigger if exists settlement_line_items_sync_maintenance_d on public.settlement_line_items;
create trigger settlement_line_items_sync_maintenance_iu
  after insert or update on public.settlement_line_items
  for each row
  when (new.linked_maintenance_id is not null)
  execute function public.trg_sync_maintenance_recovery_cache();
create trigger settlement_line_items_sync_maintenance_d
  after delete on public.settlement_line_items
  for each row
  when (old.linked_maintenance_id is not null)
  execute function public.trg_sync_maintenance_recovery_cache();

drop trigger if exists driver_settlement_adjustments_sync_maintenance on public.driver_settlement_adjustments;
drop trigger if exists driver_settlement_adjustments_sync_maintenance_iu on public.driver_settlement_adjustments;
drop trigger if exists driver_settlement_adjustments_sync_maintenance_d on public.driver_settlement_adjustments;
create trigger driver_settlement_adjustments_sync_maintenance_iu
  after insert or update on public.driver_settlement_adjustments
  for each row
  when (new.linked_maintenance_id is not null)
  execute function public.trg_sync_maintenance_recovery_cache();
create trigger driver_settlement_adjustments_sync_maintenance_d
  after delete on public.driver_settlement_adjustments
  for each row
  when (old.linked_maintenance_id is not null)
  execute function public.trg_sync_maintenance_recovery_cache();

-- ---------------------------------------------------------------------------
-- 5. guard_maintenance_org: cross-org + relationship-consistency guard,
-- same pattern as guard_dispatch_org()/guard_expense_org() (prior
-- sessions). Also the CONTRADICTORY-RELATIONSHIP guard (spec PHASE 3:
-- "Do not allow contradictory equipment/carrier relationships").
-- ---------------------------------------------------------------------------
create or replace function public.guard_maintenance_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_truck_carrier uuid;
  v_trailer_carrier uuid;
begin
  if new.truck_id is not null then
    select organization_id, carrier_id into v_org, v_truck_carrier from public.trucks where id = new.truck_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Maintenance truck must belong to the same organization.';
    end if;
  end if;

  if new.trailer_id is not null then
    select organization_id, carrier_id into v_org, v_trailer_carrier from public.trailers where id = new.trailer_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Maintenance trailer must belong to the same organization.';
    end if;
  end if;

  -- carrier_id is DERIVED from the truck/trailer's own canonical
  -- relationship, never independently client-editable (there is no
  -- carrier_id form field at all -- see maintenance-form-fields.tsx). If
  -- BOTH a truck and a trailer are selected and they belong to two
  -- DIFFERENT real carriers, that is a contradictory combination -- reject
  -- it rather than silently preferring one (spec EQUIPMENT -> CARRIER
  -- AUTO-SELECTION: "do NOT silently choose one -- reject the combination
  -- or show a clear mismatch warning"). Either one alone, or both
  -- agreeing, resolves normally.
  if v_truck_carrier is not null and v_trailer_carrier is not null and v_truck_carrier <> v_trailer_carrier then
    raise exception 'The selected truck and trailer belong to different carriers -- select equipment from a single carrier, or log two separate maintenance records.';
  end if;

  if new.truck_id is not null and v_truck_carrier is not null then
    new.carrier_id := v_truck_carrier;
  elsif new.trailer_id is not null and v_trailer_carrier is not null then
    new.carrier_id := v_trailer_carrier;
  else
    new.carrier_id := null;
  end if;

  if new.expense_id is not null then
    select organization_id into v_org from public.expenses where id = new.expense_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Linked expense must belong to the same organization.';
    end if;
  end if;

  if new.responsible_driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.responsible_driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Responsible driver must belong to the same organization.';
    end if;
  end if;

  -- Initialize/recompute recovery_status here rather than leaving it at its
  -- column default ('not_applicable') until the first settlement-side
  -- link event syncs it (sync_maintenance_recovery_cache is only invoked
  -- BY triggers on settlement_line_items/driver_settlement_adjustments --
  -- nothing ever calls it at maintenance_records insert time otherwise).
  -- Without this, a brand-new carrier_settlement/driver_settlement record
  -- would never appear in either Settlement page's "Pending Maintenance
  -- Recoveries" list (both filter on recovery_status IN ('pending',
  -- 'partially_recovered')) until it had already been linked once --
  -- an impossible chicken-and-egg state that would hide every new
  -- recovery from the staff who need to link it (spec RECOVERY /
  -- TEST F). Safe to recompute unconditionally on every insert/update:
  -- new.recovered_amount always reflects the current real cache (0 for a
  -- fresh insert; the trigger-maintained real total on any update, since
  -- nothing here overwrites it), so this can never invent progress that
  -- didn't come from an actual linked settlement row.
  if new.recovery_type not in ('carrier_settlement', 'driver_settlement') then
    new.recovery_status := 'not_applicable';
  elsif coalesce(new.recovered_amount, 0) <= 0 then
    new.recovery_status := 'pending';
  elsif new.recovered_amount >= new.recoverable_amount then
    new.recovery_status := 'recovered';
  else
    new.recovery_status := 'partially_recovered';
  end if;

  return new;
end;
$$;

drop trigger if exists maintenance_records_guard_org on public.maintenance_records;
create trigger maintenance_records_guard_org
  before insert or update on public.maintenance_records
  for each row execute function public.guard_maintenance_org();

-- ---------------------------------------------------------------------------
-- 6. Preventive maintenance status: OK / DUE SOON / DUE / OVERDUE, computed
-- live from real equipment data (next_service_due_date/_odometer vs. today
-- /current_odometer) -- never a fabricated/cached mileage.
--   OVERDUE:  the due date has already passed, or the odometer has already
--             gone past the due mileage.
--   DUE:      due today, or the odometer has reached (but not yet passed)
--             the due mileage -- "needs service now."
--   DUE SOON: within the next 14 days, or within the next 1,000 miles, but
--             not yet reached.
--   OK:       comfortably before either threshold.
-- Whichever of date/odometer is more urgent wins (e.g. overdue by date
-- but not yet by mileage still reports overdue).
-- ---------------------------------------------------------------------------
create or replace function public.get_preventive_maintenance_status(
  p_next_due_date date,
  p_next_due_odometer integer,
  p_current_odometer integer
)
returns text
language sql
immutable
as $$
  select case
    when p_next_due_date is null and p_next_due_odometer is null then 'not_scheduled'
    when (p_next_due_date is not null and p_next_due_date < current_date)
      or (p_next_due_odometer is not null and p_current_odometer is not null and p_current_odometer > p_next_due_odometer)
      then 'overdue'
    when (p_next_due_date is not null and p_next_due_date = current_date)
      or (p_next_due_odometer is not null and p_current_odometer is not null and p_current_odometer = p_next_due_odometer)
      then 'due'
    when (p_next_due_date is not null and p_next_due_date <= current_date + 14)
      or (p_next_due_odometer is not null and p_current_odometer is not null and p_current_odometer >= p_next_due_odometer - 1000)
      then 'due_soon'
    else 'ok'
  end;
$$;

grant execute on function public.get_preventive_maintenance_status(date, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Reactivation guard: a truck/trailer cannot be set back to 'active' by
-- the maintenance-aware reactivate action while another OPEN maintenance
-- record still references it (spec: "Do not reactivate equipment
-- incorrectly if another open blocking maintenance record still exists").
-- Reuses the existing equipment_status enum -- no second availability flag.
-- ---------------------------------------------------------------------------
create or replace function public.can_reactivate_equipment(p_truck_id uuid, p_trailer_id uuid)
returns boolean
language sql
stable
as $$
  select not exists (
    select 1 from public.maintenance_records mr
    where mr.status = 'open'
      and ((p_truck_id is not null and mr.truck_id = p_truck_id) or (p_trailer_id is not null and mr.trailer_id = p_trailer_id))
  );
$$;

grant execute on function public.can_reactivate_equipment(uuid, uuid) to authenticated;

-- =============================================================================
-- 0051_fuel_recovery.sql
-- Fuel Logs / Fuel Purchase payment responsibility + carrier/driver
-- settlement recovery. Extends the existing fuel_logs table (0006) --
-- does not create a second fuel system. Reuses expenses (scope='truck',
-- category='fuel', already-existing fuel_log_id UNIQUE column from 0040 --
-- built specifically to prevent a double expense, never populated by any
-- code until now), the existing carrier/driver settlement deduction
-- mechanisms (settlement_line_items.item_type='deduction' /
-- driver_settlement_adjustments.bucket='deduction', already modeled on
-- dispatch_advances' "paid now, recovered later" lifecycle via
-- linked_advance_id, and extended for Maintenance last session via
-- linked_maintenance_id) -- this migration adds the parallel linked_
-- fuel_log_id column rather than inventing a new recovery mechanism.
--
-- RE-RUNNABLE BY DESIGN from the start this time (0050's first attempt
-- was not, and needed a follow-up fix after a live failure) -- every
-- statement is guarded (IF NOT EXISTS / DROP ... IF EXISTS first /
-- existence-checked DO blocks), and the settlement-side cache-sync
-- triggers are split into separate INSERT/UPDATE (NEW-based WHEN) and
-- DELETE (OLD-based WHEN) triggers from the start -- Postgres rejects a
-- WHEN clause referencing NEW on any trigger that also fires on DELETE,
-- learned the hard way on 0050's first attempt.
--
-- GENUINE GAPS being filled (see chat architecture report for why each is
-- actually needed):
--   1. fuel_logs has no payer/recovery/expense-link/carrier columns at all
--      today -- total_amount was a bare number with no accounting path.
--   2. No cross-org guard trigger exists on fuel_logs.
--   3. settlement_line_items / driver_settlement_adjustments have no way
--      to reference a fuel log (only dispatch_advances and, since 0050,
--      maintenance_records).
--   4. 'fuel' is not a valid entity_type value yet (needed so a fuel
--      receipt can be uploaded via the existing polymorphic documents
--      table + a real storage bucket -- fuel_logs.receipt_document_id
--      exists but has never been wired to any upload path).
--   5. No trigger prevents a fuel charge from being recovered twice,
--      recovered beyond its recoverable amount, or recovered through BOTH
--      carrier and driver settlement at once.
--   6. Fuel log deletion is currently fully open (deleteRecord) with no
--      protection once a real expense/recovery is attached to it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Enum extension (additive only). document_type already has
-- 'fuel_receipt' (0040) -- no new document_type value needed, only this
-- one entity_type value so a documents row can legitimately describe
-- "this belongs to a fuel log."
-- ---------------------------------------------------------------------------
alter type public.entity_type add value if not exists 'fuel';

commit; -- new enum value must be committed before use later in this script

-- Postgres has no CREATE TYPE IF NOT EXISTS -- guard each with an
-- existence check, matching the same VALUES as maintenance_paid_by/
-- maintenance_recovery_type/maintenance_recovery_status (0050) but as
-- their own types: a fuel_logs column typed "maintenance_paid_by" would
-- be a confusing schema to read later, and this codebase already keeps
-- parallel-but-distinct enums per table on purpose (settlement_status vs
-- driver_settlement_status).
do $$
begin
  if not exists (select 1 from pg_type where typname = 'fuel_paid_by') then
    create type public.fuel_paid_by as enum ('dispatch_company', 'carrier', 'driver', 'other');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'fuel_recovery_type') then
    create type public.fuel_recovery_type as enum (
      'none', 'carrier_settlement', 'driver_settlement', 'carrier_direct', 'driver_direct'
    );
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'fuel_recovery_status') then
    create type public.fuel_recovery_status as enum (
      'not_applicable', 'pending', 'partially_recovered', 'recovered'
    );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. fuel_logs: payment/recovery/carrier columns. No new "status" column --
-- unlike a repair, a fuel purchase has no open/in-progress operational
-- lifecycle; recovery_status alone captures its financial lifecycle.
-- ---------------------------------------------------------------------------
alter table public.fuel_logs
  add column if not exists carrier_id uuid references public.carriers (id) on delete set null,
  add column if not exists paid_by public.fuel_paid_by not null default 'dispatch_company',
  add column if not exists recovery_type public.fuel_recovery_type not null default 'none',
  add column if not exists recoverable_amount numeric(10, 2) not null default 0,
  add column if not exists responsible_driver_id uuid references public.drivers (id) on delete set null,
  add column if not exists expense_id uuid references public.expenses (id) on delete set null,
  add column if not exists recovery_status public.fuel_recovery_status not null default 'not_applicable',
  add column if not exists recovered_amount numeric(10, 2) not null default 0;

alter table public.fuel_logs drop constraint if exists fuel_logs_recoverable_le_total;
alter table public.fuel_logs add constraint fuel_logs_recoverable_le_total check (recoverable_amount <= total_amount);

alter table public.fuel_logs drop constraint if exists fuel_logs_recoverable_nonneg;
alter table public.fuel_logs add constraint fuel_logs_recoverable_nonneg check (recoverable_amount >= 0);

-- Recovery type dictates exactly one lane -- a responsible_driver_id only
-- makes sense (and is only required) when recovery_type = 'driver_settlement'
-- (spec section 8: staff must explicitly select the responsible driver,
-- never inferred from fuel_logs.driver_id -- "who purchased fuel" and
-- "who owes for it" are deliberately different columns).
alter table public.fuel_logs drop constraint if exists fuel_logs_driver_recovery_shape;
alter table public.fuel_logs add constraint fuel_logs_driver_recovery_shape check (
  (recovery_type = 'driver_settlement' and responsible_driver_id is not null)
  or (recovery_type <> 'driver_settlement')
);

-- recoverable_amount is only meaningful for the two settlement-recovery
-- paths; direct-paid and no-recovery paths recover nothing through this
-- app (spec section 12/13).
alter table public.fuel_logs drop constraint if exists fuel_logs_recoverable_shape;
alter table public.fuel_logs add constraint fuel_logs_recoverable_shape check (
  (recovery_type in ('carrier_settlement', 'driver_settlement') and recoverable_amount >= 0)
  or (recovery_type not in ('carrier_settlement', 'driver_settlement') and recoverable_amount = 0)
);

comment on column public.fuel_logs.recovered_amount is
  'Denormalized cache of the sum of every non-void linked settlement_line_items/driver_settlement_adjustments row for this fuel log -- kept in sync by sync_fuel_recovery_cache() below, whose result (get_fuel_recovery_status()) is the actual source of truth. Never edited directly by application code.';

create index if not exists idx_fuel_logs_carrier on public.fuel_logs (carrier_id) where carrier_id is not null;
create index if not exists idx_fuel_logs_recovery_status on public.fuel_logs (recovery_status);
create index if not exists idx_fuel_logs_expense on public.fuel_logs (expense_id) where expense_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Settlement deduction linkage -- mirrors linked_advance_id / linked_
-- maintenance_id exactly (both tables already have those columns; this is
-- the parallel for fuel, not a new mechanism).
-- ---------------------------------------------------------------------------
alter table public.settlement_line_items
  add column if not exists linked_fuel_log_id uuid references public.fuel_logs (id) on delete set null;
alter table public.driver_settlement_adjustments
  add column if not exists linked_fuel_log_id uuid references public.fuel_logs (id) on delete set null;

create index if not exists idx_settlement_line_items_fuel on public.settlement_line_items (linked_fuel_log_id) where linked_fuel_log_id is not null;
create index if not exists idx_driver_settlement_adjustments_fuel on public.driver_settlement_adjustments (linked_fuel_log_id) where linked_fuel_log_id is not null;

-- A given settlement can only carry ONE deduction line for a given fuel
-- log -- double-click/retry protection (spec section 25/TEST H). Partial
-- recovery across DIFFERENT settlements is still fully supported; this
-- only blocks the SAME settlement from getting the same line twice.
create unique index if not exists uq_settlement_line_items_fuel_per_settlement
  on public.settlement_line_items (settlement_id, linked_fuel_log_id)
  where linked_fuel_log_id is not null and item_type = 'deduction';
create unique index if not exists uq_driver_settlement_adjustments_fuel_per_settlement
  on public.driver_settlement_adjustments (driver_settlement_id, linked_fuel_log_id)
  where linked_fuel_log_id is not null and bucket = 'deduction';

-- ---------------------------------------------------------------------------
-- 3. get_fuel_recovery_status: THE canonical recovered/remaining/status
-- calculation -- sums real linked rows across BOTH settlement tables
-- (excluding void/cancelled settlements), never a duplicated running
-- total maintained by hand (spec section 7: "Prefer deriving
-- recovered_amount from linked settlement rows").
-- ---------------------------------------------------------------------------
create or replace function public.get_fuel_recovery_status(p_fuel_log_id uuid)
returns table (recoverable_amount numeric, recovered_amount numeric, remaining_amount numeric, recovery_status public.fuel_recovery_status)
language sql
stable
as $$
  with f as (
    select fl.recoverable_amount, fl.recovery_type
    from public.fuel_logs fl
    where fl.id = p_fuel_log_id
  ),
  carrier_recovered as (
    select coalesce(sum(sli.amount), 0) as amt
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.linked_fuel_log_id = p_fuel_log_id
      and sli.item_type = 'deduction'
      and s.status <> 'void'
  ),
  driver_recovered as (
    select coalesce(sum(dsa.amount), 0) as amt
    from public.driver_settlement_adjustments dsa
    join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
    where dsa.linked_fuel_log_id = p_fuel_log_id
      and dsa.bucket = 'deduction'
      and ds.status <> 'void'
  )
  select
    f.recoverable_amount,
    (select amt from carrier_recovered) + (select amt from driver_recovered),
    f.recoverable_amount - ((select amt from carrier_recovered) + (select amt from driver_recovered)),
    case
      when f.recovery_type not in ('carrier_settlement', 'driver_settlement') then 'not_applicable'::public.fuel_recovery_status
      when (select amt from carrier_recovered) + (select amt from driver_recovered) <= 0 then 'pending'::public.fuel_recovery_status
      when (select amt from carrier_recovered) + (select amt from driver_recovered) >= f.recoverable_amount then 'recovered'::public.fuel_recovery_status
      else 'partially_recovered'::public.fuel_recovery_status
    end
  from f;
$$;

grant execute on function public.get_fuel_recovery_status(uuid) to authenticated;

create or replace function public.sync_fuel_recovery_cache(p_fuel_log_id uuid)
returns void
language plpgsql
as $$
declare
  v_row record;
begin
  select * into v_row from public.get_fuel_recovery_status(p_fuel_log_id);
  update public.fuel_logs
  set recovered_amount = v_row.recovered_amount,
      recovery_status = v_row.recovery_status
  where id = p_fuel_log_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. guard_fuel_recovery: the DOUBLE-COUNTING / DOUBLE-RECOVERY /
-- OWNER-OPERATOR PROTECTION enforcement point, at the database layer
-- (spec section 9/10). Fires on both settlement_line_items and
-- driver_settlement_adjustments, INSERT/UPDATE only.
-- ---------------------------------------------------------------------------
create or replace function public.guard_fuel_recovery()
returns trigger
language plpgsql
as $$
declare
  v_fuel_log_id uuid;
  v_recovery_type public.fuel_recovery_type;
  v_recoverable numeric;
  v_already_recovered numeric;
  v_org uuid;
begin
  v_fuel_log_id := new.linked_fuel_log_id;
  if v_fuel_log_id is null then
    return new;
  end if;

  select organization_id, recovery_type, recoverable_amount
    into v_org, v_recovery_type, v_recoverable
  from public.fuel_logs where id = v_fuel_log_id;

  if v_org is null then
    raise exception 'Linked fuel log not found.';
  end if;
  if v_org <> new.organization_id then
    raise exception 'Fuel recovery must belong to the same organization.';
  end if;

  -- One recovery lane only, matching fuel_logs.recovery_type -- a
  -- carrier-recovery fuel log can never also pick up a driver-settlement
  -- deduction, and vice versa (spec section 9/10: never both Carrier and
  -- Driver Settlement for the same purchase).
  if tg_table_name = 'settlement_line_items' and v_recovery_type <> 'carrier_settlement' then
    raise exception 'This fuel log is not marked for Carrier Settlement recovery.';
  end if;
  if tg_table_name = 'driver_settlement_adjustments' and v_recovery_type <> 'driver_settlement' then
    raise exception 'This fuel log is not marked for Driver Settlement recovery.';
  end if;

  -- Sum every OTHER already-linked, non-void recovery row across BOTH
  -- tables (excluding this row itself, relevant on update) and confirm
  -- adding/changing this one doesn't exceed the recoverable amount.
  select coalesce(sum(amt), 0) into v_already_recovered from (
    select sli.amount as amt
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.linked_fuel_log_id = v_fuel_log_id
      and sli.item_type = 'deduction'
      and s.status <> 'void'
      and not (tg_table_name = 'settlement_line_items' and sli.id = new.id)
    union all
    select dsa.amount as amt
    from public.driver_settlement_adjustments dsa
    join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
    where dsa.linked_fuel_log_id = v_fuel_log_id
      and dsa.bucket = 'deduction'
      and ds.status <> 'void'
      and not (tg_table_name = 'driver_settlement_adjustments' and dsa.id = new.id)
  ) x;

  if v_already_recovered + new.amount > v_recoverable + 0.005 then
    raise exception 'Recovery amount cannot exceed the remaining recoverable balance (remaining: %).', round(v_recoverable - v_already_recovered, 2);
  end if;

  return new;
end;
$$;

drop trigger if exists settlement_line_items_guard_fuel on public.settlement_line_items;
create trigger settlement_line_items_guard_fuel
  before insert or update on public.settlement_line_items
  for each row
  when (new.linked_fuel_log_id is not null)
  execute function public.guard_fuel_recovery();

drop trigger if exists driver_settlement_adjustments_guard_fuel on public.driver_settlement_adjustments;
create trigger driver_settlement_adjustments_guard_fuel
  before insert or update on public.driver_settlement_adjustments
  for each row
  when (new.linked_fuel_log_id is not null)
  execute function public.guard_fuel_recovery();

-- Cache-sync triggers, split into INSERT/UPDATE (NEW-based WHEN) and
-- DELETE (OLD-based WHEN) from the start -- a single combined trigger
-- with a coalesce(new,old) WHEN clause is what broke 0050's first
-- attempt live (Postgres: "DELETE trigger's WHEN condition cannot
-- reference NEW values").
create or replace function public.trg_sync_fuel_recovery_cache()
returns trigger
language plpgsql
as $$
begin
  perform public.sync_fuel_recovery_cache(coalesce(new.linked_fuel_log_id, old.linked_fuel_log_id));
  return coalesce(new, old);
end;
$$;

drop trigger if exists settlement_line_items_sync_fuel_iu on public.settlement_line_items;
drop trigger if exists settlement_line_items_sync_fuel_d on public.settlement_line_items;
create trigger settlement_line_items_sync_fuel_iu
  after insert or update on public.settlement_line_items
  for each row
  when (new.linked_fuel_log_id is not null)
  execute function public.trg_sync_fuel_recovery_cache();
create trigger settlement_line_items_sync_fuel_d
  after delete on public.settlement_line_items
  for each row
  when (old.linked_fuel_log_id is not null)
  execute function public.trg_sync_fuel_recovery_cache();

drop trigger if exists driver_settlement_adjustments_sync_fuel_iu on public.driver_settlement_adjustments;
drop trigger if exists driver_settlement_adjustments_sync_fuel_d on public.driver_settlement_adjustments;
create trigger driver_settlement_adjustments_sync_fuel_iu
  after insert or update on public.driver_settlement_adjustments
  for each row
  when (new.linked_fuel_log_id is not null)
  execute function public.trg_sync_fuel_recovery_cache();
create trigger driver_settlement_adjustments_sync_fuel_d
  after delete on public.driver_settlement_adjustments
  for each row
  when (old.linked_fuel_log_id is not null)
  execute function public.trg_sync_fuel_recovery_cache();

-- ---------------------------------------------------------------------------
-- 5. guard_fuel_log_org: cross-org guard + Truck -> Carrier auto-
-- derivation (spec section 3), same pattern as guard_maintenance_org
-- (0050) minus the truck/trailer-mismatch branch -- fuel_logs has only
-- truck_id, no trailer_id, so there is nothing to reconcile between two
-- pieces of equipment.
-- ---------------------------------------------------------------------------
create or replace function public.guard_fuel_log_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_truck_carrier uuid;
begin
  -- RECOVERY SAFETY (spec section 13): once a real expense and/or
  -- recovery already exists, the truck -- and therefore the carrier
  -- derived from it below -- is frozen. Without this, changing truck_id
  -- after the fact would silently re-derive carrier_id to the NEW
  -- truck's carrier while a real settlement deduction/expense remains
  -- linked back to this same fuel log, corrupting which carrier that
  -- historical recovery actually belongs to. actions.ts already excludes
  -- truck_id from its own update payload once locked -- this is the
  -- defense-in-depth backstop for any write that reaches this table
  -- directly (matching the DB-guard-over-app-only-validation rule used
  -- everywhere else in this schema for financial-integrity-critical
  -- checks).
  if tg_op = 'UPDATE' and (old.expense_id is not null or old.recovered_amount > 0) and new.truck_id is distinct from old.truck_id then
    raise exception 'This fuel log has a linked expense or settlement recovery -- the truck (and its carrier) cannot be changed.';
  end if;

  select organization_id, carrier_id into v_org, v_truck_carrier from public.trucks where id = new.truck_id;
  if v_org is null or v_org <> new.organization_id then
    raise exception 'Fuel log truck must belong to the same organization.';
  end if;
  -- carrier_id is DERIVED from the truck's own canonical relationship,
  -- never independently client-editable (there is no carrier_id form
  -- field at all -- see fuel-form-fields.tsx). A client-supplied
  -- carrier_id is never trusted (spec section 3: "do not trust client
  -- carrier_id").
  new.carrier_id := v_truck_carrier;

  if new.driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Fuel log driver must belong to the same organization.';
    end if;
  end if;

  if new.expense_id is not null then
    select organization_id into v_org from public.expenses where id = new.expense_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Linked expense must belong to the same organization.';
    end if;
  end if;

  if new.responsible_driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.responsible_driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Responsible driver must belong to the same organization.';
    end if;
  end if;

  -- Initialize/recompute recovery_status here (not left at its column
  -- default until the first settlement-side link event syncs it) -- the
  -- exact same fix applied retroactively to guard_maintenance_org last
  -- session after a live test caught the gap; built in from the start
  -- here. Without this, a brand-new carrier_settlement/driver_settlement
  -- fuel log would never appear in either Settlement page's "Pending
  -- Fuel Recoveries" list until it had already been linked once -- an
  -- impossible chicken-and-egg state (spec section 6/TEST B).
  if new.recovery_type not in ('carrier_settlement', 'driver_settlement') then
    new.recovery_status := 'not_applicable';
  elsif coalesce(new.recovered_amount, 0) <= 0 then
    new.recovery_status := 'pending';
  elsif new.recovered_amount >= new.recoverable_amount then
    new.recovery_status := 'recovered';
  else
    new.recovery_status := 'partially_recovered';
  end if;

  return new;
end;
$$;

drop trigger if exists fuel_logs_guard_org on public.fuel_logs;
create trigger fuel_logs_guard_org
  before insert or update on public.fuel_logs
  for each row execute function public.guard_fuel_log_org();

-- ---------------------------------------------------------------------------
-- 6. guard_fuel_log_delete: once a fuel log has a real linked expense or
-- any actual recovered amount, deleting it would silently orphan that
-- accounting trail (the expense/deduction rows themselves are NOT
-- cascade-deleted -- their FK is ON DELETE SET NULL -- so the dollars
-- stay correct, but which purchase they were ever for becomes
-- unrecoverable). Blocked outright rather than allowed to happen
-- silently; the existing edit-lock pattern (actions.ts) is the intended
-- correction path once real money is attached.
-- ---------------------------------------------------------------------------
create or replace function public.guard_fuel_log_delete()
returns trigger
language plpgsql
as $$
begin
  if old.expense_id is not null or old.recovered_amount > 0 then
    raise exception 'This fuel log has a linked expense or settlement recovery and cannot be deleted.';
  end if;
  return old;
end;
$$;

drop trigger if exists fuel_logs_guard_delete on public.fuel_logs;
create trigger fuel_logs_guard_delete
  before delete on public.fuel_logs
  for each row execute function public.guard_fuel_log_delete();

-- ---------------------------------------------------------------------------
-- 7. Private storage bucket for fuel receipts -- reuses the EXISTING
-- expense-documents bucket and its already-live RLS policies verbatim
-- (0040: signed-URL-only, no public access, org-folder-scoped select,
-- owner/admin/accountant/dispatcher insert) rather than creating a third
-- receipts bucket (spec section 19: "Do not build a second receipt
-- table" -- extending to "do not build a second bucket" for the same
-- reason). No new storage policy needed.
-- ---------------------------------------------------------------------------

-- =============================================================================
-- 0052_expense_documents_bucket_policies.sql
--
-- BUG FOUND (live, during Fuel Recovery Test P -- receipt security):
-- migration 0040_expense_cost_management.sql already contains the
-- `expense-documents` storage bucket + its two RLS policies
-- (expense_documents_select / expense_documents_insert), and this
-- migration's own header/comments describe them as already live. They
-- were NOT: a live probe (storage.listBuckets()) confirmed the bucket
-- itself did not exist at all, and after creating it via the Storage API
-- (a data-plane operation, not DDL -- the only part of this gap fixable
-- without a migration), a real upload attempt still failed with
-- "new row violates row-level security policy," confirming the two RLS
-- policies from 0040 were never applied either. This is a PRE-EXISTING
-- gap that predates this session's Fuel work -- it silently also broke
-- the already-shipped Expense receipt upload feature
-- (uploadExpenseReceipt, src/app/(app)/expenses/actions.ts), which uses
-- the exact same bucket. Not caused by, and not specific to, Fuel Logs.
--
-- This migration only re-asserts the bucket + policies from 0040, fully
-- idempotently (safe to run even where 0040's storage section DID
-- apply correctly) -- no other schema, table, or trigger changes.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-documents', 'expense-documents', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

drop policy if exists expense_documents_select on storage.objects;
create policy expense_documents_select on storage.objects
  for select using (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

drop policy if exists expense_documents_insert on storage.objects;
create policy expense_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy -- a receipt is never edited in place; a
-- correction is a new upload (fuel_logs) or void-and-re-enter (expenses),
-- matching every other document type in this schema (unchanged from 0040).

-- ============= 0053_email_send_log_resend.sql =============
-- Wiring a real email provider (Resend) means email_send_log rows now need
-- to distinguish "we attempted this and it's still pending/failed" from
-- "Resend actually accepted it" -- sent_at was previously `not null default
-- now()`, so every row (including 'blocked'/'failed' ones) got a timestamp
-- at insert time regardless of outcome. That contradicts the audit contract
-- ("never write sent_at on failure"), so it's now nullable with no default;
-- the application sets it explicitly, only on a real 'sent' result.
-- Existing rows are untouched -- this only loosens the constraint, it never
-- rewrites data.
alter table public.email_send_log alter column sent_at drop not null;
alter table public.email_send_log alter column sent_at drop default;

-- Resend's message id, for support/debugging ("did this actually go out,
-- and which provider-side message is it"). Additive, nullable -- never
-- populated for blocked/failed attempts.
alter table public.email_send_log add column provider_message_id text;

comment on table public.email_send_log is
  'Every Print/Export/Email toolbar send attempt, including blocked ones (no email provider configured) and failed ones (provider rejected the send) -- status stays blocked/failed and sent_at stays null unless Resend actually accepted the send.';

comment on column public.email_send_log.sent_at is
  'Set only when status = sent (the real moment Resend accepted the send). Null for blocked/failed attempts.';

comment on column public.email_send_log.provider_message_id is
  'Resend message id from a successful send, for support/debugging. Null for blocked/failed attempts.';

-- ============= 0054_dispatch_conflict_guards.sql =============
-- Concurrency backstop for dispatch assignment conflicts. checkAssignment
-- Conflicts() (src/app/(app)/dispatch/actions.ts) is a SELECT-then-INSERT
-- check -- correct for the common case, but not atomic: two dispatchers
-- submitting for the same driver/truck/trailer at nearly the same moment
-- can both pass that SELECT before either INSERT lands. These partial
-- unique indexes make "at most one active dispatch per driver/truck/
-- trailer" a real, race-proof database guarantee, so exactly one of the
-- two concurrent inserts/updates can ever succeed. The status list must
-- stay in sync with ACTIVE_DISPATCH_STATUSES in actions.ts.
--
-- The application never relies on the raw unique_violation this produces
-- for its user-facing message -- src/lib/dispatch/errors.ts recognizes
-- these specific index names and re-derives the same friendly "already on
-- an active dispatch" message checkAssignmentConflicts() would have given,
-- by looking up the row that won the race.
create unique index if not exists dispatches_active_driver_unique
  on public.dispatches (driver_id)
  where status in ('assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded', 'en_route_to_delivery', 'at_delivery');

create unique index if not exists dispatches_active_truck_unique
  on public.dispatches (truck_id)
  where status in ('assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded', 'en_route_to_delivery', 'at_delivery');

create unique index if not exists dispatches_active_trailer_unique
  on public.dispatches (trailer_id)
  where trailer_id is not null
    and status in ('assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded', 'en_route_to_delivery', 'at_delivery');

-- ============= 0055_reattach_guard_dispatch_org.sql =============
-- CRITICAL, pre-existing, unrelated-to-this-pass finding (discovered via
-- the dispatch-conflict-UX cross-org live test): guard_dispatch_org()
-- (0048_dispatch_workflow_upgrade.sql) is NOT currently attached to
-- public.dispatches in this database. Verified directly: a plain INSERT
-- under a real authenticated session, with organization_id set to the
-- caller's own org but load_id/carrier_id/truck_id/driver_id pointing at a
-- DIFFERENT real organization's rows, succeeds with zero error -- for
-- every one of load_id, carrier_id, truck_id, and driver_id independently.
-- Whether the 0048 trigger was simply never applied to this database or
-- was later dropped some other way, the effect is the same: there is
-- currently no DB-level protection against a cross-org dispatch
-- assignment at all.
--
-- This migration only re-applies the EXACT function/trigger 0048 already
-- defined -- byte-for-byte the same logic, nothing changed, nothing
-- weakened. `create or replace function` + `drop trigger if exists` +
-- `create trigger` is idempotent and safe to run whether the original
-- never took effect or is simply missing now.
create or replace function public.guard_dispatch_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_carrier_id uuid;
begin
  if new.load_id is not null then
    select organization_id into v_org from public.loads where id = new.load_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch load must belong to the same organization.';
    end if;
  end if;

  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch carrier must belong to the same organization.';
    end if;
  end if;

  if new.truck_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.trucks where id = new.truck_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch truck must belong to the same organization.';
    end if;
    if new.carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected truck does not belong to the selected carrier.';
    end if;
  end if;

  if new.driver_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch driver must belong to the same organization.';
    end if;
    if new.carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected driver does not belong to the selected carrier.';
    end if;
  end if;

  if new.trailer_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.trailers where id = new.trailer_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch trailer must belong to the same organization.';
    end if;
    -- Trailers may be a shared/unassigned pool (carrier_id nullable, 0003) --
    -- only reject a trailer that belongs to a DIFFERENT carrier, not one
    -- with no carrier at all.
    if new.carrier_id is not null and v_carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected trailer belongs to a different carrier.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists dispatches_guard_org on public.dispatches;
create trigger dispatches_guard_org
  before insert or update on public.dispatches
  for each row execute function public.guard_dispatch_org();

-- ============= 0056_integrations_center.sql =============
-- =============================================================================
-- 0056_integrations_center.sql
-- Upgrades integration_settings (0008) from a bare is_enabled boolean into
-- real per-org connection state, backing a real Integrations Center
-- (src/lib/integrations/registry.ts + status.ts). Provider-level STATIC
-- metadata (name, category, connection type, capabilities, requirements,
-- whether a real connector exists) intentionally stays in the TypeScript
-- registry, not duplicated into columns here -- this table only ever holds
-- per-org DYNAMIC state (is it enabled, has it been tested, when, with what
-- result). "Connected" is deliberately never a stored column: it's always
-- derived (registry.implemented && configured && last_test_status =
-- 'success' [&& not stale]), computed in src/lib/integrations/status.ts, so
-- there is no boolean anywhere that can lie about being "Active".
-- =============================================================================

-- log_activity() takes a closed entity_type enum; Integration
-- configure/test/enable/disable/disconnect events need their own value.
-- Additive only -- every existing value and every existing row is untouched.
alter type public.entity_type add value if not exists 'integration';

alter table public.integration_settings
  -- Human-meaningful label for whichever account got connected -- "ABC
  -- Logistics" for a QuickBooks company, the verified sender address for
  -- Resend, etc. Never a secret.
  add column if not exists account_label text,
  -- The provider's own identifier for the connected account/company/tenant
  -- (QuickBooks realm ID, etc.) -- an opaque reference, not a credential.
  add column if not exists external_account_id text,
  add column if not exists last_connected_at timestamptz,
  add column if not exists last_tested_at timestamptz,
  add column if not exists last_test_status text,
  add column if not exists last_test_message text,
  add column if not exists last_error_code text,
  add column if not exists last_error_message text,
  -- Distinct from is_enabled=false (Disable, spec section 34): set only by
  -- an explicit Disconnect, which also clears account_label/
  -- external_account_id below -- disabling never touches this.
  add column if not exists disconnected_at timestamptz,
  add column if not exists created_by uuid references public.profiles (id) on delete set null,
  add column if not exists updated_by uuid references public.profiles (id) on delete set null;

alter table public.integration_settings
  add constraint integration_settings_last_test_status_check
    check (last_test_status is null or last_test_status in ('success', 'failure'));

comment on table public.integration_settings is
  'Per-org third-party integration STATE (not metadata -- see src/lib/integrations/registry.ts for provider name/category/connection-type/capabilities). is_enabled alone never implies "connected"; see src/lib/integrations/status.ts for the real derivation. credentials jsonb is unused in production: no currently-implemented provider stores a per-org secret here (Resend''s credential is a platform-wide server env var). If a future provider needs one, use Supabase Vault or equivalent -- do not start writing raw secrets into this column.';

comment on column public.integration_settings.credentials is
  'Unused placeholder for a future per-org secret reference (a Vault secret id, never a raw value). No current code path writes to this column.';


-- ============= 0057_dispatch_board_upgrade.sql =============
-- =============================================================================
-- 0057_dispatch_board_upgrade.sql
-- Dispatch Board Phase 1: operational per-status timestamps, detention
-- free-time settings, and document visibility. Purely additive -- no
-- column dropped/renamed, no enum value added/removed/reused for a
-- different meaning, no existing data touched. dispatch_status itself is
-- NOT modified: every value this feature needs already exists on it
-- (assigned, accepted, en_route_to_pickup, at_pickup, loaded,
-- en_route_to_delivery, at_delivery, delivered, completed, cancelled).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Per-status operational timestamps on dispatches.
--
-- Deliberately NOT added: an "assigned_at" column. dispatched_at
-- (0004_operations.sql, `not null default now()`) is already set at the
-- exact moment a dispatch is created, and every dispatch is always created
-- with status='assigned' (see createDispatch() in dispatch/actions.ts) --
-- it already IS the assigned timestamp. Adding a second column for the
-- same fact would be exactly the "duplicating meaning unnecessarily" this
-- migration is told to avoid.
--
-- Deliberately NOT reused: completed_at. It looks like an obvious fit for
-- "delivered_at", but it is a load-bearing field for real accounting
-- logic today: get_carrier_settlement_line_items(), get_driver_settlement
-- _items(), and the profitability functions (0031/0033/0034/0035/0036/
-- 0037/0038/0040) all key their settlement/profitability period off
-- `coalesce(completed_at, dispatched_at)::date`. No application code
-- currently writes to completed_at (confirmed by inspection), so today
-- that coalesce always falls back to dispatched_at. Starting to populate
-- it here would silently change which settlement/profitability period
-- every future delivered dispatch lands in -- a real accounting behavior
-- change nobody asked for in this pass. delivered_at below is therefore a
-- distinct, new, purely-operational column; completed_at is left exactly
-- as-is.
--
-- Also deliberately NOT added: arrived_pickup_at/departed_pickup_at/
-- arrived_delivery_at/departed_delivery_at on dispatches. Their exact
-- equivalents already exist on load_stops (arrived_at, departed_at --
-- 0003_load_management.sql), already read by Driver Profile's trip
-- history (src/components/drivers/trip-history-section.tsx) but never
-- written by any code path today. Detention/arrival tracking for this
-- feature writes to those existing per-stop columns instead of creating a
-- second, competing set of timestamps on dispatches.
alter table public.dispatches
  add column if not exists en_route_pickup_at timestamptz,
  add column if not exists loaded_at timestamptz,
  add column if not exists in_transit_at timestamptz,
  add column if not exists delivered_at timestamptz,
  add column if not exists cancelled_at timestamptz;

comment on column public.dispatches.en_route_pickup_at is 'Set once, first time status becomes en_route_to_pickup. Never overwritten by a later transition.';
comment on column public.dispatches.loaded_at is 'Set once, first time status becomes loaded. Also the moment load_stops.departed_at is set for the pickup stop (truck leaving with freight).';
comment on column public.dispatches.in_transit_at is 'Set once, first time status becomes en_route_to_delivery ("In Transit" in the UI).';
comment on column public.dispatches.delivered_at is 'Set once, first time status becomes delivered. Operational only -- NOT the field settlement/profitability math reads (that remains completed_at, see the note above); intentionally kept separate. Also the moment load_stops.departed_at is set for the delivery stop.';
comment on column public.dispatches.cancelled_at is 'Set once, first time status becomes cancelled.';

-- ---------------------------------------------------------------------------
-- Detention free-time settings, per organization (configurable, spec
-- section 13). Defaults match the spec's own example (120/120) and apply
-- to every existing organization automatically via the column default.
-- ---------------------------------------------------------------------------
alter table public.organizations
  add column if not exists pickup_detention_free_minutes integer not null default 120,
  add column if not exists delivery_detention_free_minutes integer not null default 120;

alter table public.organizations
  add constraint organizations_detention_minutes_check
    check (pickup_detention_free_minutes >= 0 and delivery_detention_free_minutes >= 0);

comment on column public.organizations.pickup_detention_free_minutes is 'Minutes of free time at pickup before detention accrues. Display/calculation only -- no automatic billing yet.';
comment on column public.organizations.delivery_detention_free_minutes is 'Minutes of free time at delivery before detention accrues. Display/calculation only -- no automatic billing yet.';

-- ---------------------------------------------------------------------------
-- Document visibility. Every document defaults to internal_only, including
-- every existing row (the column default applies retroactively) -- nothing
-- that was previously reachable only by staff becomes newly exposed by
-- this migration. Enforcement of this happens in the query layer
-- (src/lib/documents/*) -- this column is the source of truth those
-- queries filter on, not a UI-only label.
-- ---------------------------------------------------------------------------
create type public.document_visibility as enum (
  'internal_only', 'driver_visible', 'customer_visible', 'carrier_visible', 'shared'
);

alter table public.documents
  add column if not exists visibility public.document_visibility not null default 'internal_only';

comment on column public.documents.visibility is 'Who this document may be shown to beyond staff. Defaults to internal_only for every row, including pre-existing ones -- rate confirmations must never be set to anything else by application code.';

-- ============= 0058_driver_phone_gps.sql =============
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


-- =============================================================================
-- (appended) 0059_gps_geofence_detention.sql -- was missing from this file
-- =============================================================================

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


-- =============================================================================
-- 0060_route_intelligence.sql
-- =============================================================================

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
