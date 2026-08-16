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
