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
