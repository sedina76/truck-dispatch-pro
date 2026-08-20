-- =============================================================================
-- 0067_financial_column_isolation.sql
-- Phase 2G.8: Financial Data Isolation -- extension tables, backfill, RLS,
-- and MIRROR TRIGGERS so the new tables stay live/authoritative from the
-- moment this applies (revised from the Phase 2G.7 draft, which was
-- backfill-only with no ongoing sync). PROPOSED ONLY -- NOT APPLIED.
--
-- PROBLEM (confirmed live, Phase 2G.7): loads.rate/detention_rate/
-- layover_rate/rate_confirmation_number and dispatches.dispatch_fee_percentage/
-- load_rate/dispatch_fee_amount/carrier_net_amount are real, stored columns
-- on tables whose SELECT RLS is "any org member" -- driver/viewer sessions
-- retrieved every one of them, with real values, via a direct client query.
-- Phase 2G.8 additionally audited carriers/customers/brokers/drivers and
-- found the same class of problem: dispatch_fee_percentage/
-- factoring_company_name (carriers), credit_rating/average_days_to_pay
-- (customers, brokers), pay_type/pay_rate (drivers) -- all readable by any
-- org member today.
--
-- WHY NOT JUST TIGHTEN THE BASE TABLES' SELECT RLS: loads/dispatches/
-- carriers/customers/brokers/drivers are all OPERATIONAL tables driver/
-- viewer genuinely need ROW access to (load status, dispatch assignment,
-- carrier/customer/broker contact info, driver CDL/contact info). A
-- blanket FINANCIAL_ROLES-only SELECT policy on any of these whole tables
-- would break Operations for those roles. PostgreSQL RLS filters rows, not
-- columns -- the only structurally sound fix that preserves row access
-- while making specific columns genuinely unreachable via any query path
-- is to move them to their own tables with their own RLS.
--
-- REJECTED ALTERNATIVES: safe operational VIEWS (Postgres view-security
-- semantics -- owner vs. invoker privileges -- are a well-known real-world
-- RLS footgun); SECURITY DEFINER safe-projection RPCs only, no schema
-- change (requires every current and future caller to remember to use the
-- RPC instead of the table -- one missed spot reopens the hole); native
-- column-level GRANT/REVOKE (doesn't work -- Postgres column privileges
-- are conditioned on the literal DB role, never on profiles.role, which
-- only has meaning inside RLS predicates/functions).
--
-- ROLE TIER CORRECTION (Phase 2G.9 item 1): the insert/update policies on
-- all six tables below now read owner/admin/dispatcher/ACCOUNTANT (they
-- previously omitted accountant, an unintentional gap against the final
-- FINANCIAL_ROLES definition -- accountant is a first-class financial
-- role and must have at least the same read/write access the existing
-- billing/accounting workflow already grants it elsewhere, e.g. invoices/
-- payments). Delete policies now read owner/admin/ACCOUNTANT (previously
-- owner/admin only), matching the existing 0010_rls_policies.sql
-- precedent for financial_tables/ops_cost_tables delete exactly --
-- dispatcher is deliberately excluded from delete there too, consistent
-- with how it's excluded from deleting invoices/settlements/expenses
-- today.
--
-- MIRROR TRIGGERS (new in this revision): AFTER INSERT OR UPDATE triggers
-- on each base table upsert the current row's sensitive columns into the
-- matching extension table. This means every EXISTING writer (app-code
-- Server Actions, the auto-invoice trigger, sync_dispatch_financials)
-- keeps writing the OLD columns exactly as today -- no writer needs to be
-- individually repointed for the extension tables to stay correct -- while
-- every NEW reader (0068's redefined reporting RPCs) reads the extension
-- tables and gets live, current data. This is the transition-safe design
-- the Phase 2G.8 spec asked for: divergence is impossible because the
-- mirror is driven by a trigger on the same row-write transaction, not by
-- independently-computed application code; it ends at the (not yet
-- written) 0069 cutover, when the old columns are dropped and these
-- mirrors are removed because there is nothing left to mirror FROM.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- load_financials
-- ---------------------------------------------------------------------------
create table if not exists public.load_financials (
  load_id uuid primary key references public.loads (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  rate numeric(10, 2) not null default 0,
  detention_rate numeric(10, 2),
  layover_rate numeric(10, 2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.load_financials is
  'Financial-column isolation (0067) -- kept live by mirror_load_financials() below, not a one-time snapshot. loads itself keeps rate/detention_rate/layover_rate until the 0069 cutover drops them. rate_confirmation_number stays on loads permanently (Phase 2G.9 reclassification: a plain text reference key, not a dollar figure -- see loads/[id]/page.tsx''s LOAD_SAFE_COLUMNS comment) -- it never belonged in this table and was removed from it here rather than carried forward as a second, unnecessary copy.';

insert into public.load_financials (load_id, organization_id, rate, detention_rate, layover_rate, created_at, updated_at)
select id, organization_id, rate, detention_rate, layover_rate, created_at, updated_at
from public.loads
on conflict (load_id) do nothing;

alter table public.load_financials enable row level security;

create policy load_financials_select on public.load_financials
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  );

create policy load_financials_insert on public.load_financials
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  );

create policy load_financials_update on public.load_financials
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy load_financials_delete on public.load_financials
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

-- SECURITY DEFINER: must write regardless of the CALLING user's own RLS
-- (e.g. a dispatcher inserting a load has insert rights on `loads` but the
-- mirror write here targets a table whose insert policy is intentionally
-- narrower is not the concern -- the concern is this must always succeed
-- when the base table write succeeds, independent of caller role, since
-- it is bookkeeping, not a user-initiated financial change).
create or replace function public.mirror_load_financials()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.load_financials (load_id, organization_id, rate, detention_rate, layover_rate, updated_at)
  values (new.id, new.organization_id, new.rate, new.detention_rate, new.layover_rate, now())
  on conflict (load_id) do update set
    rate = excluded.rate,
    detention_rate = excluded.detention_rate,
    layover_rate = excluded.layover_rate,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists loads_mirror_financials on public.loads;
create trigger loads_mirror_financials
  after insert or update on public.loads
  for each row execute function public.mirror_load_financials();

-- ---------------------------------------------------------------------------
-- dispatch_financials
-- ---------------------------------------------------------------------------
create table if not exists public.dispatch_financials (
  dispatch_id uuid primary key references public.dispatches (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  dispatch_fee_percentage numeric(5, 2) not null default 10.00,
  load_rate numeric(10, 2) not null default 0,
  dispatch_fee_amount numeric(10, 2) not null default 0,
  carrier_net_amount numeric(10, 2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.dispatch_financials is
  'Financial-column isolation (0067) -- kept live by mirror_dispatch_financials() below. dispatches.notes is deliberately NOT included here: it is sensitive-internal, not financial, and is out of scope for this architecture (see the Phase 2G.8 report).';

insert into public.dispatch_financials (dispatch_id, organization_id, dispatch_fee_percentage, load_rate, dispatch_fee_amount, carrier_net_amount, created_at, updated_at)
select id, organization_id, dispatch_fee_percentage, load_rate, dispatch_fee_amount, carrier_net_amount, created_at, updated_at
from public.dispatches
on conflict (dispatch_id) do nothing;

alter table public.dispatch_financials enable row level security;

create policy dispatch_financials_select on public.dispatch_financials
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  );

create policy dispatch_financials_insert on public.dispatch_financials
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  );

create policy dispatch_financials_update on public.dispatch_financials
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy dispatch_financials_delete on public.dispatch_financials
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create or replace function public.mirror_dispatch_financials()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Fires AFTER sync_dispatch_financials() (0009) has already computed
  -- dispatch_fee_amount/carrier_net_amount onto NEW during the BEFORE
  -- phase of the same statement, so NEW here already holds the final,
  -- correct computed values -- this mirrors them, it does not recompute
  -- them a second time (a second computation is exactly the "two
  -- competing sources of truth" the spec warns against).
  insert into public.dispatch_financials (dispatch_id, organization_id, dispatch_fee_percentage, load_rate, dispatch_fee_amount, carrier_net_amount, updated_at)
  values (new.id, new.organization_id, new.dispatch_fee_percentage, new.load_rate, new.dispatch_fee_amount, new.carrier_net_amount, now())
  on conflict (dispatch_id) do update set
    dispatch_fee_percentage = excluded.dispatch_fee_percentage,
    load_rate = excluded.load_rate,
    dispatch_fee_amount = excluded.dispatch_fee_amount,
    carrier_net_amount = excluded.carrier_net_amount,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists dispatches_mirror_financials on public.dispatches;
create trigger dispatches_mirror_financials
  after insert or update on public.dispatches
  for each row execute function public.mirror_dispatch_financials();

-- =============================================================================
-- Other mixed tables audited this phase (Phase 2G.8 item 4). Field-by-field
-- decisions (full reasoning in the report):
--   carriers.dispatch_fee_percentage -> FINANCIAL, moved.
--   carriers.factoring_company_name -> SENSITIVE-INTERNAL business
--     relationship, moved alongside it rather than a separate table --
--     both describe "how this carrier is paid," not two different concerns.
--   carriers.payment_terms_days / customers.payment_terms_days /
--     brokers.payment_terms_days -> AMBIGUOUS, decided FINANCIAL: used only
--     to compute due dates (suggestedDueDate()) and displayed as a plain
--     "Net 30"-style term -- lower severity than a dollar rate, but still a
--     negotiated commercial term a driver/viewer has no operational reason
--     to see. Moved for consistency with the other three fields on each of
--     these tables, not merely for symmetry with loads/dispatches.
--   customers.credit_rating / brokers.credit_rating -> internal risk
--     assessment, moved.
--   brokers.average_days_to_pay -> derived payment-history metric, moved.
--   drivers.pay_type / drivers.pay_rate -> compensation, moved to
--     driver_compensation (name chosen to match the spec's own suggestion
--     and to read clearly next to driver_settlements/driver_pay_rates,
--     which this is NOT the same as -- driver_pay_rates (0031) is a
--     separate, already-existing rate-card table for settlement
--     calculations; drivers.pay_type/pay_rate is the driver record's own
--     default, kept as its own row here rather than merged into that
--     unrelated table).
-- Not moved: everything else on these four tables (legal_name, mc_number,
-- dot_number, contact info, addresses, CDL/medical-card dates, status) --
-- genuinely operational, needed by driver/viewer today (e.g. a driver
-- portal check-in flow or a dispatcher confirming a carrier's DOT number).
-- =============================================================================

create table if not exists public.carrier_financials (
  carrier_id uuid primary key references public.carriers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  dispatch_fee_percentage numeric(5, 2) not null default 10.00,
  payment_terms_days integer not null default 7,
  factoring_company_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.carrier_financials (carrier_id, organization_id, dispatch_fee_percentage, payment_terms_days, factoring_company_name, created_at, updated_at)
select id, organization_id, dispatch_fee_percentage, payment_terms_days, factoring_company_name, created_at, updated_at
from public.carriers
on conflict (carrier_id) do nothing;

alter table public.carrier_financials enable row level security;

create policy carrier_financials_select on public.carrier_financials
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy carrier_financials_insert on public.carrier_financials
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy carrier_financials_update on public.carrier_financials
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy carrier_financials_delete on public.carrier_financials
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]));

create or replace function public.mirror_carrier_financials()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.carrier_financials (carrier_id, organization_id, dispatch_fee_percentage, payment_terms_days, factoring_company_name, updated_at)
  values (new.id, new.organization_id, new.dispatch_fee_percentage, new.payment_terms_days, new.factoring_company_name, now())
  on conflict (carrier_id) do update set
    dispatch_fee_percentage = excluded.dispatch_fee_percentage,
    payment_terms_days = excluded.payment_terms_days,
    factoring_company_name = excluded.factoring_company_name,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists carriers_mirror_financials on public.carriers;
create trigger carriers_mirror_financials
  after insert or update on public.carriers
  for each row execute function public.mirror_carrier_financials();

-- ---------------------------------------------------------------------------

create table if not exists public.customer_financials (
  customer_id uuid primary key references public.customers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  payment_terms_days integer default 30,
  credit_rating text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.customer_financials (customer_id, organization_id, payment_terms_days, credit_rating, created_at, updated_at)
select id, organization_id, payment_terms_days, null, created_at, updated_at
from public.customers
on conflict (customer_id) do nothing;

alter table public.customer_financials enable row level security;

create policy customer_financials_select on public.customer_financials
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy customer_financials_insert on public.customer_financials
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy customer_financials_update on public.customer_financials
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy customer_financials_delete on public.customer_financials
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]));

create or replace function public.mirror_customer_financials()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.customer_financials (customer_id, organization_id, payment_terms_days, updated_at)
  values (new.id, new.organization_id, new.payment_terms_days, now())
  on conflict (customer_id) do update set
    payment_terms_days = excluded.payment_terms_days,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists customers_mirror_financials on public.customers;
create trigger customers_mirror_financials
  after insert or update on public.customers
  for each row execute function public.mirror_customer_financials();

-- ---------------------------------------------------------------------------
-- Note: customers has no credit_rating column today (only brokers does --
-- confirmed by inspection of 0004_operations.sql) -- customer_financials
-- still carries the column for schema symmetry with broker_financials
-- since a future credit_rating on customers is plausible, but it is always
-- null via the trigger above until such a column exists to mirror from.

create table if not exists public.broker_financials (
  broker_id uuid primary key references public.brokers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  payment_terms_days integer default 30,
  credit_rating text,
  average_days_to_pay numeric(5, 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.broker_financials (broker_id, organization_id, payment_terms_days, credit_rating, average_days_to_pay, created_at, updated_at)
select id, organization_id, payment_terms_days, credit_rating, average_days_to_pay, created_at, updated_at
from public.brokers
on conflict (broker_id) do nothing;

alter table public.broker_financials enable row level security;

create policy broker_financials_select on public.broker_financials
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy broker_financials_insert on public.broker_financials
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy broker_financials_update on public.broker_financials
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy broker_financials_delete on public.broker_financials
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]));

create or replace function public.mirror_broker_financials()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.broker_financials (broker_id, organization_id, payment_terms_days, credit_rating, average_days_to_pay, updated_at)
  values (new.id, new.organization_id, new.payment_terms_days, new.credit_rating, new.average_days_to_pay, now())
  on conflict (broker_id) do update set
    payment_terms_days = excluded.payment_terms_days,
    credit_rating = excluded.credit_rating,
    average_days_to_pay = excluded.average_days_to_pay,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists brokers_mirror_financials on public.brokers;
create trigger brokers_mirror_financials
  after insert or update on public.brokers
  for each row execute function public.mirror_broker_financials();

-- ---------------------------------------------------------------------------

create table if not exists public.driver_compensation (
  driver_id uuid primary key references public.drivers (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  pay_type text check (pay_type in ('per_mile', 'percentage', 'hourly', 'salary')),
  pay_rate numeric(10, 2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.driver_compensation is
  'Isolates drivers.pay_type/pay_rate (the driver record''s own default rate). Distinct from the pre-existing driver_pay_rates table (0031_driver_settlements.sql), which is a separate rate-card input to settlement calculations -- not touched here.';

insert into public.driver_compensation (driver_id, organization_id, pay_type, pay_rate, created_at, updated_at)
select id, organization_id, pay_type, pay_rate, created_at, updated_at
from public.drivers
on conflict (driver_id) do nothing;

alter table public.driver_compensation enable row level security;

create policy driver_compensation_select on public.driver_compensation
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy driver_compensation_insert on public.driver_compensation
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy driver_compensation_update on public.driver_compensation
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy driver_compensation_delete on public.driver_compensation
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]));

create or replace function public.mirror_driver_compensation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.driver_compensation (driver_id, organization_id, pay_type, pay_rate, updated_at)
  values (new.id, new.organization_id, new.pay_type, new.pay_rate, now())
  on conflict (driver_id) do update set
    pay_type = excluded.pay_type,
    pay_rate = excluded.pay_rate,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists drivers_mirror_compensation on public.drivers;
create trigger drivers_mirror_compensation
  after insert or update on public.drivers
  for each row execute function public.mirror_driver_compensation();

-- =============================================================================
-- dispatch_internal_notes (Phase 2G.10 item 4)
--
-- dispatches.notes is SENSITIVE-INTERNAL, not financial -- deliberately
-- NOT added to dispatch_financials above, per explicit instruction. It
-- gets its own tiny parallel table instead: same structural problem
-- (dispatches' SELECT RLS is "any org member", confirmed live -- driver/
-- viewer can read notes via direct query today, and the existing "STAFF
-- ONLY" label on it was never actually enforced at the data layer), same
-- structural fix, but tracked as its own concern so this migration's
-- stated purpose (financial isolation) and this table's purpose
-- (internal-communication isolation) never get confused with each other
-- -- e.g. a future change to who can see financials must never
-- accidentally also change who can see dispatch notes, or vice versa.
--
-- Role tier: FINANCIAL_ROLES (owner/admin/dispatcher/accountant) is used
-- here too, but for a different reason than on the financial tables --
-- this is simply the existing "internal staff" tier already used
-- everywhere else in this app (Reports, Email History, Billing), not a
-- claim that dispatch notes are financial data.
-- =============================================================================

create table if not exists public.dispatch_internal_notes (
  dispatch_id uuid primary key references public.dispatches (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.dispatch_internal_notes is
  'Isolates dispatches.notes (internal staff notes -- never shown to drivers/carriers, "STAFF ONLY" labeled in the UI since Phase 2E but never actually RLS-enforced until this table). Kept live by mirror_dispatch_internal_notes(). dispatches.notes stays in place until the 0069 cutover.';

insert into public.dispatch_internal_notes (dispatch_id, organization_id, notes, created_at, updated_at)
select id, organization_id, notes, created_at, updated_at
from public.dispatches
on conflict (dispatch_id) do nothing;

alter table public.dispatch_internal_notes enable row level security;

create policy dispatch_internal_notes_select on public.dispatch_internal_notes
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  );

create policy dispatch_internal_notes_insert on public.dispatch_internal_notes
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  );

create policy dispatch_internal_notes_update on public.dispatch_internal_notes
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy dispatch_internal_notes_delete on public.dispatch_internal_notes
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create or replace function public.mirror_dispatch_internal_notes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.dispatch_internal_notes (dispatch_id, organization_id, notes, updated_at)
  values (new.id, new.organization_id, new.notes, now())
  on conflict (dispatch_id) do update set
    notes = excluded.notes,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists dispatches_mirror_internal_notes on public.dispatches;
create trigger dispatches_mirror_internal_notes
  after insert or update on public.dispatches
  for each row execute function public.mirror_dispatch_internal_notes();

-- =============================================================================
-- The OLD columns on loads/dispatches/carriers/customers/brokers/drivers
-- are UNCHANGED and UNRESTRICTED by this migration -- applying 0067 alone
-- does not yet close the vulnerability, it only stands up the live,
-- correctly-RLS'd parallel copy every safe reader will be repointed to.
-- See 0068 (RPC/function repointing) and the deferred 0069 (old-column
-- drop, not written -- see the Phase 2G.8 report for why) for the rest of
-- the plan.
-- =============================================================================
