-- =============================================================================
-- 0071_factoring_schema.sql
-- Phase 2H.2: core factoring schema -- tables, enum, RLS, and integrity
-- constraints only. No workflow functions (submit/approve/fund/release
-- reserve/etc.) -- those are Phase 2H.4/2H.5's "authoritative service
-- layer," scoped separately per the phase checkpoints. PROPOSED ONLY --
-- NOT APPLIED.
--
-- This is AR-side (customer/broker invoice) factoring: the org sells its
-- own receivables to a factoring company. Deliberately distinct from the
-- existing AP-side "carrier-payee factoring" (settlement_payee_type enum,
-- carrier_financials.factoring_company_name, 0033/0070) -- that feature
-- routes a payment the ORG MAKES TO A CARRIER to that carrier's own
-- factor; this feature is the org's OWN invoices being sold. Neither
-- table nor column is shared or reused between the two.
--
-- Money model: factored_invoices snapshots every dollar figure (face
-- value, advance/fee/reserve percentages AND amounts) at submission time.
-- Nothing here re-derives a historical transaction's numbers from the
-- (possibly later-changed) factoring_relationships defaults -- exactly
-- the same snapshot principle settlements.payee_name already established
-- for the AP-side feature (0033).
--
-- AR integrity: nothing here writes to invoices/payments. A factor's
-- advance, fee, and reserve release are a different economic relationship
-- (org <-> factor) from the customer/broker actually paying (org <->
-- customer, the existing payments/apply_payment_to_invoice() path,
-- reusing payment_method = 'factoring', already defined in 0001). This
-- migration adds no application logic that decides when to write a
-- payments row -- that's Phase 2H.5.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Status enum -- matches this project's established convention for
-- top-level entity status (invoice_status, settlement_status, load_status,
-- dispatch_status are all enums, not text+check; settlement_status itself
-- grew via ALTER TYPE ADD VALUE IF NOT EXISTS in 0033, e.g. the historical
-- precedent this follows exactly).
-- ---------------------------------------------------------------------------
create type public.factored_invoice_status as enum (
  'draft', 'submitted', 'pending', 'approved', 'rejected', 'cancelled',
  'funded', 'partially_settled', 'disputed', 'recourse', 'chargeback', 'closed'
);

-- Three genuinely new document types for factoring-specific paperwork.
-- 'factoring_notice' and 'notice_of_assignment' already exist (0001) and
-- cover the submission-notice case -- not duplicated here.
alter type public.document_type add value if not exists 'funding_confirmation';
alter type public.document_type add value if not exists 'factor_statement';
alter type public.document_type add value if not exists 'chargeback_notice';

-- ---------------------------------------------------------------------------
-- factoring_companies: the factor itself. Org-scoped (a factor known to
-- one org is a separate row from the "same" factor known to another --
-- no cross-org sharing, matching every other partner table in this app:
-- carriers/brokers/customers are all org-scoped the same way).
-- ---------------------------------------------------------------------------
create table public.factoring_companies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  legal_name text,
  contact_name text,
  email text,
  phone text,
  website text,
  address_line1 text,
  city text,
  state text,
  postal_code text,
  account_number text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists set_updated_at on public.factoring_companies;
create trigger set_updated_at before update on public.factoring_companies
  for each row execute function public.set_updated_at();

alter table public.factoring_companies enable row level security;

create policy factoring_companies_select on public.factoring_companies
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_companies_insert on public.factoring_companies
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_companies_update on public.factoring_companies
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy factoring_companies_delete on public.factoring_companies
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
-- Delete IS permitted at the RLS layer (matches the existing carriers/
-- brokers/customers precedent -- this app allows hard-deleting partner
-- records generally, not just soft-delete). The actual "never delete
-- historical factoring-company information required by existing
-- transactions" guarantee (Part 11) is enforced structurally below: every
-- FK from factored_invoices/factoring_relationships to this table is
-- ON DELETE RESTRICT, not CASCADE -- a factor with any factoring history
-- cannot be deleted at the database level regardless of role, only
-- deactivated (is_active = false).

-- ---------------------------------------------------------------------------
-- factoring_relationships: the org's commercial terms with a factor.
-- Historical rows are kept (effective_from/effective_to) so a rate change
-- is a NEW row, never an edit to the old one -- factored_invoices
-- references the specific relationship row in effect at submission time.
-- ---------------------------------------------------------------------------
create table public.factoring_relationships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  factoring_company_id uuid not null references public.factoring_companies (id) on delete restrict,
  relationship_name text,
  default_advance_percentage numeric(5, 2) not null check (default_advance_percentage >= 0 and default_advance_percentage <= 100),
  default_factoring_fee_percentage numeric(5, 2) not null check (default_factoring_fee_percentage >= 0 and default_factoring_fee_percentage <= 100),
  default_reserve_percentage numeric(5, 2) not null check (default_reserve_percentage >= 0 and default_reserve_percentage <= 100),
  fee_timing text not null check (fee_timing in ('deducted_at_funding', 'deducted_from_reserve')),
  recourse_type text not null check (recourse_type in ('recourse', 'non_recourse')),
  payment_terms_days integer,
  minimum_fee numeric(10, 2) check (minimum_fee is null or minimum_fee >= 0),
  wire_fee numeric(10, 2) check (wire_fee is null or wire_fee >= 0),
  ach_fee numeric(10, 2) check (ach_fee is null or ach_fee >= 0),
  other_fee_default numeric(10, 2) check (other_fee_default is null or other_fee_default >= 0),
  is_default boolean not null default false,
  is_active boolean not null default true,
  effective_from date not null default current_date,
  effective_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- effective_from is NOT NULL above (default current_date), so the
  -- "effective_from is null" branch is currently unreachable -- included
  -- anyway, defensively, so this constraint stays correct on its own
  -- even if that NOT NULL were ever relaxed later; it costs nothing today.
  constraint factoring_relationships_valid_effective_range check (
    effective_to is null or effective_from is null or effective_to >= effective_from
  ),
  -- A relationship cannot be both the org's default AND inactive --
  -- prevents a deactivated relationship from silently remaining "the"
  -- default (see the partial unique index below, which also guards this
  -- independently in case this CHECK is ever relaxed).
  constraint factoring_relationships_default_must_be_active check (not is_default or is_active)
);

-- At most one default relationship per organization, at any given time --
-- AND that default must be active. Requiring is_active here too (not
-- just relying on the CHECK constraint above) means a historical
-- relationship that somehow ended up inactive-while-still-flagged-default
-- (e.g. data predating the CHECK constraint) can never block a fresh
-- relationship from being set as the new default -- the stale row simply
-- falls outside this partial index's predicate.
create unique index factoring_relationships_one_default_per_org
  on public.factoring_relationships (organization_id)
  where is_default and is_active;

drop trigger if exists set_updated_at on public.factoring_relationships;
create trigger set_updated_at before update on public.factoring_relationships
  for each row execute function public.set_updated_at();

-- Org-consistency guard: the referenced factoring_company must belong to
-- the same organization as this relationship row. Same shape as
-- guard_carrier_settlement_org() (0033) -- CHECK constraints can't do
-- cross-table lookups, so this is a BEFORE INSERT trigger.
create or replace function public.guard_factoring_relationship_org()
returns trigger
language plpgsql
as $$
declare
  v_company_org uuid;
begin
  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'Factoring relationship must reference a factoring company in the same organization.';
  end if;
  return new;
end;
$$;

drop trigger if exists factoring_relationships_guard_org on public.factoring_relationships;
create trigger factoring_relationships_guard_org
  before insert on public.factoring_relationships
  for each row execute function public.guard_factoring_relationship_org();

alter table public.factoring_relationships enable row level security;

create policy factoring_relationships_select on public.factoring_relationships
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_relationships_insert on public.factoring_relationships
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_relationships_update on public.factoring_relationships
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy factoring_relationships_delete on public.factoring_relationships
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
-- Same "delete allowed at RLS, blocked structurally if referenced"
-- pattern as factoring_companies -- factored_invoices' FK to this table
-- is also ON DELETE RESTRICT below.

-- ---------------------------------------------------------------------------
-- factored_invoices: one row per factoring lifecycle attempt for an
-- existing invoice. Multiple rows CAN exist for the same invoice_id over
-- time (e.g. rejected, then resubmitted) -- what's actually constrained
-- is "at most one non-terminal attempt in flight at once" (the partial
-- unique index below), not a strict one-to-one with invoices.
-- ---------------------------------------------------------------------------
create table public.factored_invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  factoring_company_id uuid not null references public.factoring_companies (id) on delete restrict,
  factoring_relationship_id uuid not null references public.factoring_relationships (id) on delete restrict,

  status public.factored_invoice_status not null default 'draft',

  submitted_at timestamptz,
  submitted_by uuid references public.profiles (id) on delete set null,
  approved_at timestamptz,
  approved_by uuid references public.profiles (id) on delete set null,
  rejected_at timestamptz,
  rejected_by uuid references public.profiles (id) on delete set null,
  rejection_reason text,

  invoice_face_value numeric(10, 2) not null check (invoice_face_value >= 0),

  advance_percentage numeric(5, 2) not null check (advance_percentage >= 0 and advance_percentage <= 100),
  expected_advance_amount numeric(10, 2) not null check (expected_advance_amount >= 0),

  factoring_fee_percentage numeric(5, 2) not null check (factoring_fee_percentage >= 0 and factoring_fee_percentage <= 100),
  factoring_fee_amount numeric(10, 2) not null check (factoring_fee_amount >= 0),

  reserve_percentage numeric(5, 2) not null check (reserve_percentage >= 0 and reserve_percentage <= 100),
  reserve_amount numeric(10, 2) not null check (reserve_amount >= 0),

  other_fees numeric(10, 2) not null default 0 check (other_fees >= 0),
  fee_timing text not null check (fee_timing in ('deducted_at_funding', 'deducted_from_reserve')),

  expected_funding_amount numeric(10, 2) not null check (expected_funding_amount >= 0),
  actual_funded_amount numeric(10, 2) check (actual_funded_amount is null or actual_funded_amount >= 0),
  funded_at timestamptz,

  customer_paid_factor_at timestamptz,
  customer_paid_factor_amount numeric(10, 2) check (customer_paid_factor_amount is null or customer_paid_factor_amount >= 0),

  reserve_released_amount numeric(10, 2) not null default 0 check (reserve_released_amount >= 0),
  reserve_released_at timestamptz,
  outstanding_reserve numeric(10, 2) generated always as (reserve_amount - reserve_released_amount) stored,

  recourse_amount numeric(10, 2) not null default 0 check (recourse_amount >= 0),
  chargeback_amount numeric(10, 2) not null default 0 check (chargeback_amount >= 0),

  reconciliation_status text not null default 'unreconciled' check (reconciliation_status in ('unreconciled', 'partially_reconciled', 'reconciled')),

  closed_at timestamptz,
  closed_by uuid references public.profiles (id) on delete set null,

  external_reference text,
  notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint factored_invoices_reserve_not_over_released check (reserve_released_amount <= reserve_amount)
);

-- At most one "open" factoring attempt per invoice at a time.
-- rejected/cancelled are FAILED/ABANDONED attempts and free the invoice
-- up for a fresh submission (e.g. resubmit to a different factor after
-- rejection). closed is a SUCCEEDED, fully-settled attempt and does
-- NOT free the slot -- the same invoice must never be silently
-- resubmitted just because its prior factoring transaction finished
-- successfully; a genuinely new receivable needs a genuinely new
-- invoice. draft/submitted/pending/approved/funded/partially_settled/
-- disputed/recourse/chargeback are all still-open (in-flight or
-- unresolved) and correctly stay excluded from the "free" set by not
-- being listed here.
create unique index factored_invoices_one_active_per_invoice
  on public.factored_invoices (invoice_id)
  where status not in ('rejected', 'cancelled');

-- External reference uniqueness scoped to (org, factor), not global --
-- two different orgs' factors, or the same org's two different factors,
-- could plausibly reuse the same reference format without colliding.
create unique index factored_invoices_external_reference_unique
  on public.factored_invoices (organization_id, factoring_company_id, external_reference)
  where external_reference is not null;

create index idx_factored_invoices_invoice_id on public.factored_invoices (invoice_id);
create index idx_factored_invoices_org_status on public.factored_invoices (organization_id, status);

drop trigger if exists set_updated_at on public.factored_invoices;
create trigger set_updated_at before update on public.factored_invoices
  for each row execute function public.set_updated_at();

-- Org-consistency guard: invoice_id, factoring_company_id, and
-- factoring_relationship_id must all belong to the same organization as
-- this factored_invoices row -- AND factoring_relationship_id must
-- actually belong to factoring_company_id specifically, not merely to
-- some OTHER relationship/company pair that both happen to be in the
-- same org. Without this last check, an org with multiple factors and
-- multiple relationships could construct a factored_invoices row citing
-- Company A's id alongside a relationship that was actually negotiated
-- with Company B -- each individual org check would pass while the
-- relationship-to-company linkage itself was wrong. Same shape as
-- guard_carrier_settlement_org() otherwise.
create or replace function public.guard_factored_invoice_org()
returns trigger
language plpgsql
as $$
declare
  v_invoice_org uuid;
  v_company_org uuid;
  v_relationship_org uuid;
  v_relationship_company_id uuid;
begin
  select organization_id into v_invoice_org from public.invoices where id = new.invoice_id;
  if v_invoice_org is null or v_invoice_org <> new.organization_id then
    raise exception 'Factored invoice must reference an invoice in the same organization.';
  end if;

  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'Factored invoice must reference a factoring company in the same organization.';
  end if;

  select organization_id, factoring_company_id into v_relationship_org, v_relationship_company_id
  from public.factoring_relationships where id = new.factoring_relationship_id;
  if v_relationship_org is null or v_relationship_org <> new.organization_id then
    raise exception 'Factored invoice must reference a factoring relationship in the same organization.';
  end if;
  if v_relationship_company_id <> new.factoring_company_id then
    raise exception 'Factored invoice''s factoring relationship must belong to the same factoring company as factoring_company_id.';
  end if;

  return new;
end;
$$;

drop trigger if exists factored_invoices_guard_org on public.factored_invoices;
create trigger factored_invoices_guard_org
  before insert on public.factored_invoices
  for each row execute function public.guard_factored_invoice_org();

-- Status-transition guard: prevents impossible transitions at the DB
-- layer, not just the (not-yet-written, Phase 2H.4/2H.5) service
-- functions -- per Part 15/16's explicit "do not use application
-- validation as the only protection." Only fires when status actually
-- changes; repeated writes at the same status (e.g. accumulating a
-- second partial reserve release while staying 'partially_settled') are
-- untouched by this guard.
create or replace function public.guard_factored_invoice_status_transition()
returns trigger
language plpgsql
as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if (old.status, new.status) not in (
    ('draft', 'submitted'),
    ('submitted', 'pending'), ('submitted', 'cancelled'),
    ('pending', 'approved'), ('pending', 'rejected'), ('pending', 'cancelled'),
    ('approved', 'funded'), ('approved', 'cancelled'),
    ('funded', 'partially_settled'), ('funded', 'disputed'), ('funded', 'closed'),
    ('partially_settled', 'disputed'), ('partially_settled', 'closed'),
    ('disputed', 'recourse'), ('disputed', 'closed'), ('disputed', 'partially_settled'),
    ('recourse', 'chargeback'), ('recourse', 'closed')
  ) then
    raise exception 'Invalid factored invoice status transition: % -> %.', old.status, new.status;
  end if;

  return new;
end;
$$;

drop trigger if exists factored_invoices_guard_status_transition on public.factored_invoices;
create trigger factored_invoices_guard_status_transition
  before update of status on public.factored_invoices
  for each row execute function public.guard_factored_invoice_status_transition();

alter table public.factored_invoices enable row level security;

create policy factored_invoices_select on public.factored_invoices
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factored_invoices_insert on public.factored_invoices
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factored_invoices_update on public.factored_invoices
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
-- No delete policy at all -- a factored invoice is financial transaction
-- history, not a partner-directory entry; it must be closed/cancelled
-- through its status, never removed. Matches factoring_events' own
-- append-only treatment below, one level up the lifecycle.

-- ---------------------------------------------------------------------------
-- factoring_events: append-only audit trail. No update/delete policy at
-- all (matches activity_logs' own treatment) -- once written, a lifecycle
-- event is permanent history.
-- ---------------------------------------------------------------------------
create table public.factoring_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  factored_invoice_id uuid not null references public.factored_invoices (id) on delete cascade,
  event_type text not null check (event_type in (
    'submitted', 'approved', 'rejected', 'funded', 'customer_payment_reported',
    'reserve_released', 'disputed', 'recourse_started', 'chargeback', 'buyback',
    'closed', 'cancelled'
  )),
  from_status text,
  to_status text,
  amount numeric(10, 2) check (amount is null or amount >= 0),
  reference text,
  notes text,
  performed_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create index idx_factoring_events_factored_invoice_id on public.factoring_events (factored_invoice_id, created_at desc);

create or replace function public.guard_factoring_event_org()
returns trigger
language plpgsql
as $$
declare
  v_invoice_org uuid;
begin
  select organization_id into v_invoice_org from public.factored_invoices where id = new.factored_invoice_id;
  if v_invoice_org is null or v_invoice_org <> new.organization_id then
    raise exception 'Factoring event must reference a factored invoice in the same organization.';
  end if;
  return new;
end;
$$;

drop trigger if exists factoring_events_guard_org on public.factoring_events;
create trigger factoring_events_guard_org
  before insert on public.factoring_events
  for each row execute function public.guard_factoring_event_org();

alter table public.factoring_events enable row level security;

create policy factoring_events_select on public.factoring_events
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_events_insert on public.factoring_events
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
-- No update, no delete policy -- append-only.
