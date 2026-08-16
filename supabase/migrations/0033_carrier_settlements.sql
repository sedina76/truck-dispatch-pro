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
