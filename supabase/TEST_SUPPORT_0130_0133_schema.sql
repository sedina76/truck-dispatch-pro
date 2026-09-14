-- ============================================================================
-- TEST_SUPPORT_0130_0133_schema.sql   --   DISPOSABLE DATABASE ONLY.
--
-- NOT A MIGRATION. Do not apply to any real database. Builds a minimal but
-- FAITHFUL pre-0130 schema (the subset of 0001-0129 that migrations
-- 0130-0133 read or extend) plus a deterministic seed, so the four Phase-3A
-- migrations and their POST_APPLY verifiers can be exercised on a throwaway
-- PostgreSQL instance. See TEST_0130_0133_run.sh.
--
-- Faithfully reproduced: org_role / document_type / load_status /
-- dispatch_status enums; set_updated_at(); organizations / profiles;
-- current_org_id() / current_role() / has_role(); carriers / brokers /
-- customers / drivers / trucks / trailers / loads / load_stops / dispatches
-- (CURRENT column shape, post-0069/0115); platform_settings + proceeds enums
-- + loads.financial_dispatch_id + the five 0125 triggers/functions; the 0055
-- guard_dispatch_org trigger; near-empty invoices / invoice_line_items /
-- payments / settlements / settlement_line_items; stubs for create_dispatch()
-- and auto_generate_invoice_from_delivered_load() + its trigger (landmark
-- checks only). RLS mirrors 0010's blanket grant.
-- ============================================================================

-- --- Supabase-ish auth surface -------------------------------------------
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid
  language sql stable as $$ select nullif(current_setting('test.current_uid', true), '')::uuid $$;

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon')          then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role')  then create role service_role; end if;
end $$;

create extension if not exists pgcrypto;

-- --- enums (0001) -------------------------------------------------------
create type public.org_role as enum ('owner','admin','dispatcher','accountant','driver','viewer');
create type public.load_status as enum (
  'draft','posted','booked','dispatched','in_transit','at_pickup','at_delivery',
  'delivered','pod_received','invoiced','closed','cancelled','problem');
create type public.stop_type as enum ('pickup','delivery');
create type public.dispatch_status as enum (
  'assigned','accepted','en_route_to_pickup','at_pickup','loaded',
  'en_route_to_delivery','at_delivery','delivered','completed','cancelled');
create type public.equipment_status as enum ('active','in_maintenance','out_of_service','inactive');
create type public.entity_type as enum (
  'organization','load','dispatch','carrier','broker','customer',
  'driver','truck','trailer','invoice','settlement','expense');
create type public.driver_status as enum ('active','inactive','on_leave','terminated','applicant');
create type public.document_type as enum (
  'rate_confirmation','bol','pod','cdl','insurance_certificate','w9',
  'motor_carrier_authority','vehicle_registration','ifta_credential','factoring_notice',
  'medical_card','inspection_report','notice_of_assignment','other',
  'expense_receipt','fuel_receipt','toll_receipt','repair_invoice','voided_check',
  'signed_agreement','funding_confirmation','factor_statement','chargeback_notice',
  'lumper_receipt','detention_document','scale_ticket','estimate','before_photo','after_photo');

create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- --- tenancy (0002) ---------------------------------------------------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  -- Phase 3B.4: dba_name/mc_number/dot_number/business_phone/
  -- business_email/address_line1/address_line2/city/state/postal_code
  -- added -- the real 0002_core_saas_tables.sql shape this fixture had
  -- never previously needed (no earlier migration through 0144 reads a
  -- dispatch organization's own legal/contact identity); 0145's
  -- dispatch-service invoice issuer snapshot is the first to need it.
  -- country matches 0002's own NOT NULL DEFAULT 'US'.
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
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table public.profiles (
  id uuid primary key,
  organization_id uuid references public.organizations (id) on delete cascade,
  full_name text not null,
  email text not null,
  role public.org_role not null default 'dispatcher',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create or replace function public.current_org_id() returns uuid
  language sql stable security definer set search_path = public
  as $$ select organization_id from public.profiles where id = auth.uid() $$;
create or replace function public.current_role() returns public.org_role
  language sql stable security definer set search_path = public
  as $$ select role from public.profiles where id = auth.uid() $$;
create or replace function public.has_role(p_roles public.org_role[]) returns boolean
  language sql stable security definer set search_path = public
  as $$ select public.current_role() = any(p_roles) $$;

-- --- fleet & partners (0003, current shape) -------------------------
create table public.carriers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  legal_name text not null,
  dba_name text, mc_number text, dot_number text, ein text,
  contact_name text, phone text, email text,
  address_line1 text, address_line2 text, city text, state text, postal_code text,
  country text not null default 'US',
  notes text,
  is_active boolean not null default true,
  onboarded_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
-- production's 0009 attaches set_updated_at() to EVERY table with an
-- updated_at column, carriers included -- faithfully reproduced here so
-- 0139's set_carrier_factoring_policy() optimistic-concurrency check
-- (Phase 3B.1.1, item 6) is exercised against a value that actually moves
-- on every write, exactly as it does in production (not merely a frozen
-- INSERT-time default).
create trigger set_updated_at before update on public.carriers
  for each row execute function public.set_updated_at();

-- Phase 3B.3C (0144): mc_number/contact_name/phone/email/address_* added
-- so issue_carrier_invoice()'s snapshot-construction code (which reads
-- these real 0003 columns) has something faithful to read in this
-- disposable stub -- every column is nullable, so existing INSERTs
-- (0142/0143's own test fixtures) that never mention them are unaffected.
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
  is_blacklisted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

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
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table public.drivers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  first_name text not null, last_name text not null,
  status public.driver_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table public.trucks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  unit_number text not null,
  status public.equipment_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, unit_number));

create table public.trailers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid references public.carriers (id) on delete set null,
  unit_number text not null,
  vin text,
  trailer_type text,
  length_ft integer,
  license_plate text,
  license_state text,
  ownership_type text,
  status public.equipment_status not null default 'active',
  registration_expiry_date date,
  annual_inspection_expiry_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, unit_number));

-- 0009's real trigger-attachment is a DYNAMIC loop over every table with an
-- updated_at column (discovered at apply time via information_schema), so
-- it genuinely attaches to trailers in production even though grepping 0009
-- for the literal string "trailers" finds nothing (the table name is a
-- bound loop variable, not literal text) -- faithfully reproduced here
-- explicitly, since this minimal schema does not replay that loop.
create trigger set_updated_at before update on public.trailers
  for each row execute function public.set_updated_at();

-- --- operations (0004, current shape post-0069/0115) -------------
create table public.loads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_number text not null,
  broker_id uuid references public.brokers (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  status public.load_status not null default 'draft',
  commodity text, weight_lbs integer,
  -- Phase 3B.4 CORRECTION: this table must NOT carry a live `rate` column
  -- post-0069 -- 0069_financial_column_removal.sql drops loads.rate (and
  -- detention_rate/layover_rate) for real, moving the authoritative value
  -- to load_financials.rate (0067). The Phase 3B.3C (0144) comment this
  -- replaces incorrectly claimed "rate added -- reads the real 0004 rate
  -- column" -- 0004's rate column was real THEN, but was already gone by
  -- 0069, long before 0144 existed; that error made issue_carrier_
  -- invoice() (0144) read a column that does not exist in a real,
  -- fully-migrated database, masked here only because this fixture had
  -- silently grown a `loads.rate` column of its own to match it. `rate`
  -- is kept below ONLY as a test-fixture convenience so every already-
  -- committed 0144 test (which inserts `rate` directly into `loads`)
  -- keeps working unchanged -- mirror_load_financials_test_only() below
  -- copies it into the REAL table (load_financials) every time, so
  -- 0145's corrected issue_carrier_invoice() (which reads load_financials
  -- .rate, matching real production exactly) sees accurate data either
  -- way. No real migration reads loads.rate directly ever again.
  rate numeric(10, 2) not null default 0,
  total_miles numeric(8,2),
  route_miles numeric(8,2), route_miles_calculated_at timestamptz,
  actual_miles numeric(8,2), actual_miles_recorded_at timestamptz,
  rate_confirmation_number text,
  special_instructions text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, load_number));

-- Phase 3B.4: the REAL, authoritative post-0067/0069 table -- see
-- 0067_financial_column_isolation.sql / 0069_financial_column_removal.sql.
-- issue_carrier_invoice() (corrected in 0145) reads THIS table, exactly
-- like create_load_with_stops() (0114) already writes to it directly (no
-- mirror exists in real production -- 0069's cutover removed the need).
create table public.load_financials (
  load_id uuid primary key references public.loads (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  rate numeric(10, 2) not null default 0,
  detention_rate numeric(10, 2),
  layover_rate numeric(10, 2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- TEST-FIXTURE-ONLY compatibility shim (does not exist in real
-- production -- real production has no loads.rate to mirror FROM, since
-- 0069 already dropped it there). Keeps every already-committed 0144
-- test (which sets `rate` directly on `loads`) producing the same
-- load_financials.rate value 0145's corrected function actually reads,
-- without needing to touch any already-committed test file.
create function public.mirror_load_financials_test_only()
returns trigger
language plpgsql
as $$
begin
  insert into public.load_financials (load_id, organization_id, rate)
  values (new.id, new.organization_id, new.rate)
  on conflict (load_id) do update set rate = excluded.rate, updated_at = now();
  return new;
end;
$$;

create trigger a_mirror_load_financials_test_only
  after insert or update of rate on public.loads
  for each row execute function public.mirror_load_financials_test_only();

-- Phase 3B.3C (0144): facility_name/city/state/scheduled_at/arrived_at
-- added -- issue_carrier_invoice()'s snapshot reads the real 0004
-- load_stops columns for each load's origin/destination.
create table public.load_stops (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete cascade,
  stop_type public.stop_type not null,
  stop_sequence integer not null default 1,
  facility_name text,
  city text,
  state text,
  scheduled_at timestamptz,
  arrived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table public.dispatches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  truck_id uuid not null references public.trucks (id) on delete restrict,
  driver_id uuid not null references public.drivers (id) on delete restrict,
  trailer_id uuid references public.trailers (id) on delete set null,
  status public.dispatch_status not null default 'assigned',
  dispatched_by uuid references public.profiles (id) on delete set null,
  dispatched_at timestamptz not null default now(),
  completed_at timestamptz,
  en_route_pickup_at timestamptz, loaded_at timestamptz, in_transit_at timestamptz,
  delivered_at timestamptz, cancelled_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
-- production's 0009 attaches set_updated_at() to EVERY table with an
-- updated_at column, dispatches included -- faithfully reproduced here so
-- 0135's p_expected_updated_at optimistic-concurrency check (Phase 3A.3,
-- item 3) is exercised against a value that actually moves on every write,
-- exactly as it does in production (not merely a frozen INSERT-time default).
create trigger set_updated_at before update on public.dispatches
  for each row execute function public.set_updated_at();

-- --- financial stubs (near-empty; only counts matter to the verifiers) ---
create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_id uuid references public.loads (id) on delete set null,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  broker_id uuid references public.brokers (id) on delete set null,
  customer_id uuid references public.customers (id) on delete set null,
  -- Phase 3B.1.4: submit_invoice_to_factor()'s carrier-resolution gate
  -- (0140) reads status/total_amount/amount_paid/broker_id/customer_id
  -- directly -- added here so TEST_0140 can exercise the real function
  -- against a faithful invoices shape, not a mismatched stub.
  status text not null default 'draft',
  total_amount numeric(10,2) not null default 0,
  amount_paid numeric(10,2) not null default 0,
  invoice_number text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
create table public.invoice_line_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade);
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade);
create table public.settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  status text not null default 'pending');
create table public.settlement_line_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  settlement_id uuid not null references public.settlements (id) on delete cascade,
  load_id uuid references public.loads (id) on delete set null,
  dispatch_id uuid references public.dispatches (id) on delete set null,
  item_type text);

-- --- 0125: proceeds foundation + financial controller --------------
create type public.proceeds_model as enum ('dispatcher_receives_funds','carrier_paid_directly');
create type public.proceeds_payer as enum ('broker','factoring_company','shipper','dispatcher','other');

create table public.platform_settings (
  id boolean primary key default true,
  model_a_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint platform_settings_singleton check (id = true));
insert into public.platform_settings (id) values (true);
create trigger set_updated_at before update on public.platform_settings
  for each row execute function public.set_updated_at();

alter table public.organizations add column load_proceeds_model public.proceeds_model not null default 'dispatcher_receives_funds';
alter table public.carriers add column load_proceeds_model public.proceeds_model;
alter table public.dispatches add column proceeds_model public.proceeds_model;
alter table public.dispatches add column proceeds_payer public.proceeds_payer;
alter table public.dispatches add column proceeds_payer_note text;
alter table public.loads add column financial_dispatch_id uuid references public.dispatches (id) on delete restrict;
create unique index uq_loads_financial_dispatch_one_per_dispatch
  on public.loads (financial_dispatch_id) where financial_dispatch_id is not null;

create or replace function public.resolve_dispatch_proceeds_model(p_dispatch_id uuid)
returns public.proceeds_model language sql stable security definer set search_path = public
as $fn$ select coalesce(d.proceeds_model,'dispatcher_receives_funds'::public.proceeds_model)
        from public.dispatches d where d.id = p_dispatch_id $fn$;

create or replace function public.stamp_dispatch_proceeds_model() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare v_carrier_default public.proceeds_model; v_org_default public.proceeds_model; v_gate boolean;
begin
  if new.proceeds_model is null then
    select load_proceeds_model into v_carrier_default from public.carriers where id = new.carrier_id;
    if v_carrier_default is not null then new.proceeds_model := v_carrier_default;
    else
      select load_proceeds_model into v_org_default from public.organizations where id = new.organization_id;
      new.proceeds_model := coalesce(v_org_default,'dispatcher_receives_funds'::public.proceeds_model);
    end if;
  end if;
  return new;
end $fn$;
create trigger dispatches_stamp_proceeds before insert on public.dispatches
  for each row execute function public.stamp_dispatch_proceeds_model();

create or replace function public.assign_load_financial_dispatch() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare v_load_org uuid;
begin
  select organization_id into v_load_org from public.loads where id = new.load_id for update;
  if v_load_org is null then raise exception 'dispatches AFTER INSERT: load % missing.', new.load_id; end if;
  if v_load_org <> new.organization_id then raise exception 'dispatches AFTER INSERT: org mismatch.'; end if;
  update public.loads set financial_dispatch_id = new.id
    where id = new.load_id and financial_dispatch_id is null;
  return null;
end $fn$;
create trigger dispatches_assign_financial_controller after insert on public.dispatches
  for each row execute function public.assign_load_financial_dispatch();

create or replace function public.guard_load_financial_dispatch_ref() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare v_d_load uuid; v_d_org uuid;
begin
  if new.financial_dispatch_id is null then return new; end if;
  if tg_op='UPDATE' and new.financial_dispatch_id is not distinct from old.financial_dispatch_id then return new; end if;
  select load_id, organization_id into v_d_load, v_d_org from public.dispatches where id = new.financial_dispatch_id;
  if v_d_load is null then raise exception 'loads.financial_dispatch_id % missing dispatch.', new.financial_dispatch_id; end if;
  if v_d_load <> new.id then raise exception 'loads.financial_dispatch_id belongs to another load.'; end if;
  if v_d_org <> new.organization_id then raise exception 'loads.financial_dispatch_id org mismatch.'; end if;
  return new;
end $fn$;
create trigger loads_financial_dispatch_ref_guard before insert or update on public.loads
  for each row execute function public.guard_load_financial_dispatch_ref();

-- --- 0055: guard_dispatch_org --------------------------------------
create or replace function public.guard_dispatch_org() returns trigger language plpgsql as $$
declare v_org uuid; v_carrier_id uuid;
begin
  if new.load_id is not null then
    select organization_id into v_org from public.loads where id = new.load_id;
    if v_org is null or v_org <> new.organization_id then raise exception 'Dispatch load must belong to the same organization.'; end if;
  end if;
  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then raise exception 'Dispatch carrier must belong to the same organization.'; end if;
  end if;
  if new.truck_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.trucks where id = new.truck_id;
    if v_org is null or v_org <> new.organization_id then raise exception 'Dispatch truck must belong to the same organization.'; end if;
    if new.carrier_id is not null and v_carrier_id is distinct from new.carrier_id then raise exception 'The selected truck does not belong to the selected carrier.'; end if;
  end if;
  if new.driver_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then raise exception 'Dispatch driver must belong to the same organization.'; end if;
    if new.carrier_id is not null and v_carrier_id is distinct from new.carrier_id then raise exception 'The selected driver does not belong to the selected carrier.'; end if;
  end if;
  if new.trailer_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.trailers where id = new.trailer_id;
    if v_org is null or v_org <> new.organization_id then raise exception 'Dispatch trailer must belong to the same organization.'; end if;
    if new.carrier_id is not null and v_carrier_id is not null and v_carrier_id is distinct from new.carrier_id then raise exception 'The selected trailer belongs to a different carrier.'; end if;
  end if;
  return new;
end $$;
create trigger dispatches_guard_org before insert or update on public.dispatches
  for each row execute function public.guard_dispatch_org();

-- --- 0054: partial unique indexes -- the race-proof backstop 0135's
-- reassign_dispatch_resources() explicitly relies on (its own unique_
-- violation exception handler names these three index names) -- faithfully
-- reproduced, not merely assumed present.
create unique index if not exists dispatches_active_driver_unique
  on public.dispatches (driver_id)
  where status in ('assigned','accepted','en_route_to_pickup','at_pickup','loaded','en_route_to_delivery','at_delivery');
create unique index if not exists dispatches_active_truck_unique
  on public.dispatches (truck_id)
  where status in ('assigned','accepted','en_route_to_pickup','at_pickup','loaded','en_route_to_delivery','at_delivery');
create unique index if not exists dispatches_active_trailer_unique
  on public.dispatches (trailer_id)
  where trailer_id is not null
    and status in ('assigned','accepted','en_route_to_pickup','at_pickup','loaded','en_route_to_delivery','at_delivery');

-- --- 0007/0046: activity_logs + log_activity() (faithful, needed by 0134's
-- transition_dispatch_status() for its audit-event requirement) ----------
create table public.activity_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  action text not null,
  actor_id uuid references public.profiles (id) on delete set null,
  changes jsonb,
  created_at timestamptz not null default now());

create or replace function public.log_activity(
  p_entity_type public.entity_type, p_entity_id uuid, p_action text,
  p_changes jsonb default null, p_organization_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.activity_logs (organization_id, entity_type, entity_id, action, actor_id, changes)
  values (coalesce(p_organization_id, public.current_org_id()), p_entity_type, p_entity_id, p_action, auth.uid(), p_changes)
  returning id into v_id;
  return v_id;
end;
$$;
grant execute on function public.log_activity(public.entity_type, uuid, text, jsonb, uuid) to authenticated;

-- --- 0068 create_dispatch (STUB -- existence-only check; not needed by
-- any Phase 3A/3A.1 test, which construct dispatches via direct INSERT) --
create or replace function public.create_dispatch(
  p_load_id uuid, p_carrier_id uuid, p_truck_id uuid, p_driver_id uuid,
  p_trailer_id uuid, p_fee_percentage numeric, p_notes text)
returns uuid language plpgsql as $$
begin raise exception 'create_dispatch stub -- disposable test schema only'; end $$;

-- --- 0129 cancel_dispatch (FAITHFUL reproduction -- 0134's transition_
-- dispatch_status() delegates cancellation to this exact function, so its
-- real lock order and business rules must be genuinely exercised, not
-- stubbed). Mirrors migrations/0129_atomic_dispatch_lifecycle.sql lines
-- 570-650 (minus dispatch_financials/dispatch_internal_notes bookkeeping,
-- which this minimal schema does not model and which is irrelevant to the
-- lock-order/status/carrier-history guarantees under test).
create or replace function public.cancel_dispatch(p_dispatch_id uuid, p_reason text default null)
returns void language plpgsql security invoker set search_path = public as $$
declare
  v_load_id uuid; v_status public.dispatch_status; v_notes text; v_org uuid;
  v_cancel_note text; v_reason text := nullif(btrim(coalesce(p_reason,'')), '');
begin
  if auth.uid() is not null and not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'Only an owner, admin, or dispatcher can cancel a dispatch.' using errcode = 'TDROL';
  end if;

  select d.load_id, d.status, d.organization_id into v_load_id, v_status, v_org from public.dispatches d where d.id = p_dispatch_id;
  if not found then raise exception 'That dispatch could not be found.' using errcode = 'TDCNF'; end if;
  if v_status = 'cancelled' then return; end if;

  -- lock LOAD first (matches create_dispatch's order), then the dispatch
  perform 1 from public.loads where id = v_load_id for update;
  select d.status, d.notes into v_status, v_notes from public.dispatches d where d.id = p_dispatch_id for update;
  if v_status = 'cancelled' then return; end if;
  if v_status in ('delivered','completed') then
    raise exception 'A delivered or completed dispatch cannot be cancelled.' using errcode = 'TDTRM', detail = v_status;
  end if;

  v_cancel_note := '[Cancelled' || case when v_reason is not null then ': ' || v_reason else '' end || ']';
  update public.dispatches
     set status = 'cancelled',
         notes = case when v_notes is not null and btrim(v_notes) <> '' then v_notes || E'\n' || v_cancel_note else v_cancel_note end,
         cancelled_at = coalesce(cancelled_at, now())
   where id = p_dispatch_id;

  update public.loads l
     set status = 'booked'
   where l.id = v_load_id
     and l.status not in ('delivered','pod_received','invoiced','closed','cancelled')
     and not exists (
       select 1 from public.dispatches d
       where d.load_id = v_load_id and d.id <> p_dispatch_id
         and d.status not in ('cancelled','delivered','completed'));

  -- 0129 line ~644: cancel_dispatch's OWN audit event. Faithfully
  -- reproduced (a prior round of this test harness omitted this call
  -- entirely, which silently hid the real "transition_dispatch_status()
  -- double-logs a cancellation" bug this correction exists to catch --
  -- TEST_CANCELLATION_AUDIT_DEDUP.sql).
  perform public.log_activity(
    'dispatch'::public.entity_type, p_dispatch_id, 'cancelled',
    case when v_reason is not null then jsonb_build_object('reason', v_reason) end,
    v_org);
end;
$$;
grant execute on function public.cancel_dispatch(uuid, text) to authenticated;

create or replace function public.auto_generate_invoice_from_delivered_load()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- STUB body for the disposable test schema only.
  return new;
end $$;
create trigger auto_generate_invoice_on_delivery after update on public.loads
  for each row execute function public.auto_generate_invoice_from_delivered_load();

-- --- RLS baseline (0010 blanket) ---------------------------------
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;

-- --- 0010: real trailers RLS policies (faithfully reproduced, not just the
-- blanket grant) -- required for a REALISTIC adversarial test of the 0132
-- column-privilege protections (Phase 3A clarification round, item 3):
-- "the adversarial test must operate as a realistic authenticated
-- organization user who can see and normally edit that exact trailer row
-- -- not merely SET ROLE authenticated without JWT/profile context." The
-- production 0010_rls_policies.sql applies this exact policy shape to
-- trailers (and 11 other operational tables) via a single loop; reproduced
-- directly (not via the loop, to keep this file readable) for trailers only
-- -- carriers/brokers/customers/drivers/trucks/loads/dispatches already have
-- their own faithful org-scoping enforced elsewhere in this file (current_org_id()
-- resolution, guard triggers), and this correction's own adversarial test
-- concerns trailers specifically.
alter table public.trailers enable row level security;

create policy trailers_select on public.trailers
  for select using (organization_id = public.current_org_id());

create policy trailers_insert on public.trailers
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
  );

create policy trailers_update on public.trailers
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy trailers_delete on public.trailers
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin']::public.org_role[])
  );

-- ============================================================================
-- SEED  --  deterministic UUIDs so the TEST files can reference rows.
-- ============================================================================
insert into public.organizations (id, name, slug) values
  ('11111111-1111-1111-1111-111111111111', 'Org A', 'org-a'),
  ('22222222-2222-2222-2222-222222222222', 'Org B', 'org-b');

insert into auth.users (id) values
  ('aaaa0000-0000-0000-0000-000000000001'),
  ('bbbb0000-0000-0000-0000-000000000001'),
  ('cccc0000-0000-0000-0000-000000000001'),
  ('dddd0000-0000-0000-0000-000000000001'),
  ('eeee0000-0000-0000-0000-000000000001'),
  ('ffff0000-0000-0000-0000-000000000001');
insert into public.profiles (id, organization_id, full_name, email, role) values
  ('aaaa0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Owner A', 'ownera@example.com', 'owner'),
  ('bbbb0000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Owner B', 'ownerb@example.com', 'owner'),
  ('cccc0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Accountant A', 'accountanta@example.com', 'accountant'),
  ('dddd0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Dispatcher A', 'dispatchera@example.com', 'dispatcher'),
  ('eeee0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Driver A', 'drivera@example.com', 'driver'),
  ('ffff0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Viewer A', 'viewera@example.com', 'viewer');

insert into public.carriers (id, organization_id, legal_name, address_line1, city, state, postal_code, email, is_active) values
  ('a1a1a1a1-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Carrier A1 LLC', '1 A St',  'Dallas',  'TX', '75201', 'a1@example.com', true),
  ('a2a2a2a2-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Carrier A2 LLC', '2 A St',  'Austin',  'TX', '73301', 'a2@example.com', true),
  ('a3a3a3a3-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Carrier A3 (inactive)', '3 A St', 'Waco', 'TX', '76701', 'a3@example.com', false),
  ('b1b1b1b1-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Carrier B1 LLC', '1 B St',  'Reno',    'NV', '89501', 'b1@example.com', true);

insert into public.brokers (id, organization_id, company_name) values
  ('a0b00000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Broker A'),
  ('b0b00000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Broker B');
insert into public.customers (id, organization_id, company_name) values
  ('a0c00000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Customer A');

insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  ('d1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1'),
  ('d2000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'Drv', 'A2'),
  ('d3000000-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'b1b1b1b1-0000-0000-0000-000000000001', 'Drv', 'B1'),
  -- Dedicated equipment for L1's/L2's/L3's OWN seed dispatches (below) --
  -- deliberately NOT d1000000...001/c1000000...001/d2000000...002/
  -- c2000000...002, so those "standard" A1/A2 driver+truck ids stay
  -- COMPLETELY FREE for every other TEST_* file's own ad-hoc fixtures to
  -- use on a different, new active dispatch without tripping the 0054
  -- partial unique indexes (faithfully reproduced below) -- L1/L2/L3 all
  -- need their OWN non-overlapping equipment now that "at most one active
  -- dispatch per driver/truck/trailer" is a real, enforced constraint;
  -- reusing the "standard" ids for ANY seed dispatch would make them
  -- unusable by the many TEST_* files that construct their own fresh
  -- carrier-A1/A2 dispatch fixtures with exactly those ids.
  ('d1000000-0000-0000-0000-000000000091', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-Seed-L1'),
  ('d2000000-0000-0000-0000-000000000092', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'Drv', 'A2-Seed-L2'),
  ('d1000000-0000-0000-0000-000000000093', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-Seed-L3'),
  ('d2000000-0000-0000-0000-000000000094', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'Drv', 'A2-Seed-L3');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  ('c1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1'),
  ('c2000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'TRK-A2'),
  ('c3000000-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'b1b1b1b1-0000-0000-0000-000000000001', 'TRK-B1'),
  ('c1000000-0000-0000-0000-000000000091', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-SEED-L1'),
  ('c2000000-0000-0000-0000-000000000092', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'TRK-A2-SEED-L2'),
  ('c1000000-0000-0000-0000-000000000093', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-SEED-L3'),
  ('c2000000-0000-0000-0000-000000000094', '11111111-1111-1111-1111-111111111111', 'a2a2a2a2-0000-0000-0000-000000000002', 'TRK-A2-SEED-L3');
insert into public.trailers (id, organization_id, carrier_id, unit_number) values
  ('e1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRL-A1'),          -- -> 'carrier'
  ('e9000000-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', null,                                   'TRL-SHARED');       -- -> 'unresolved'

-- Loads (all Org A). L1 keeps its 0125-assigned financial controller; L2..L5
-- have financial_dispatch_id NULLed afterwards to simulate legacy pre-0126 loads.
insert into public.loads (id, organization_id, load_number, broker_id, status) values
  ('10000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'LD-1', 'a0b00000-0000-0000-0000-000000000001', 'dispatched'),
  ('20000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'LD-2', 'a0b00000-0000-0000-0000-000000000001', 'dispatched'),
  ('30000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'LD-3', 'a0b00000-0000-0000-0000-000000000001', 'dispatched'),
  ('40000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'LD-4', 'a0b00000-0000-0000-0000-000000000001', 'booked'),
  ('50000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'LD-5', 'a0b00000-0000-0000-0000-000000000001', 'booked');

-- One Org B load, for cross-org record_id-fabrication tests.
insert into public.loads (id, organization_id, load_number, broker_id, status) values
  ('b0000000-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'LD-B1', 'b0b00000-0000-0000-0000-000000000001', 'booked');

-- Dispatches. The 0125 AFTER INSERT trigger stamps loads.financial_dispatch_id
-- on the first dispatch per load.
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status) values
  ('d1d10000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '10000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000091', 'd1000000-0000-0000-0000-000000000091', 'assigned'),
  ('d2d20000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '20000000-0000-0000-0000-000000000002', 'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000092', 'd2000000-0000-0000-0000-000000000092', 'assigned'),
  ('d3a30000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', '30000000-0000-0000-0000-000000000003', 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000093', 'd1000000-0000-0000-0000-000000000093', 'assigned'),
  ('d3b30000-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111', '30000000-0000-0000-0000-000000000003', 'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000094', 'd2000000-0000-0000-0000-000000000094', 'assigned'),
  ('d5d50000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', '50000000-0000-0000-0000-000000000005', 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'cancelled'),
  -- Org B's load keeps a normal financial controller (like L1) so it never
  -- becomes 'unresolved' and never pollutes any Org-A unresolved-count
  -- assertion in tests that apply 0133 against this whole seed.
  ('dbdb0000-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'b0000000-0000-0000-0000-00000000000b', 'b1b1b1b1-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-00000000000b', 'd3000000-0000-0000-0000-00000000000b', 'assigned');

-- Simulate legacy loads: only L1 keeps a financial controller.
update public.loads set financial_dispatch_id = null
where id in ('20000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000003',
             '50000000-0000-0000-0000-000000000005');

-- Sanity: L1 controller present, L2..L5 NULL, L4 has zero dispatches.
do $s$
begin
  if (select financial_dispatch_id from public.loads where id='10000000-0000-0000-0000-000000000001') is null then
    raise exception 'SEED: L1 should have a financial_dispatch_id.';
  end if;
  if (select count(*) from public.loads where financial_dispatch_id is not null) <> 2 then
    raise exception 'SEED: exactly two loads (L1, Org-B load) should have a financial_dispatch_id.';
  end if;
  if (select count(*) from public.dispatches where load_id='40000000-0000-0000-0000-000000000004') <> 0 then
    raise exception 'SEED: L4 should have zero dispatches.';
  end if;
  raise notice 'SEED OK: 2 orgs, 4 carriers (1 inactive), 6 profiles (owner/owner/accountant/dispatcher/driver/viewer), 5 Org-A loads (L1 controlled / L2 sole / L3 conflicting / L4 zero / L5 cancelled-only) + 1 Org-B load, 2 trailers (1 carrier / 1 shared-null).';
end
$s$;
