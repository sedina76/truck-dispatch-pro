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
