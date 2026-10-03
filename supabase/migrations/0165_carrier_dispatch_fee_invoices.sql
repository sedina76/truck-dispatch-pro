-- ============================================================================
-- 0165_carrier_dispatch_fee_invoices.sql
--
-- Owner decision (2026-10-01): brokers pay the CARRIER; the dispatch company
-- invoices each carrier for what the carrier owes it -- one Dispatch Fee
-- Invoice per carrier per period (e.g. weekly), containing:
--   * the dispatch fee for every load DELIVERED in the period
--     (dispatch_financials.dispatch_fee_amount -- the same fee the dispatch
--     screen shows; delivery date = coalesce(completed_at, delivered_at,
--     dispatched_at), as 0163),
--   * every pending ADVANCE the dispatch company paid for the carrier
--     (fuel, lumper, tolls, ...) dated up to the period end,
--   * FUEL and REPAIRS the dispatch company paid that are marked to be
--     recovered from the carrier (recovery_type 'carrier_settlement' =
--     "recover from carrier"), their still-unrecovered remainder.
--
-- Nothing is ever billed twice:
--   * one live fee line per dispatch, one per advance, (partial unique
--     indexes over non-voided lines);
--   * advances are marked deducted (new deducted_carrier_fee_invoice_id);
--   * fuel/maintenance recovery: invoice lines are a third recovery source
--     next to carrier and driver settlements -- the existing "cannot exceed
--     the recoverable balance" guards and recovery-status caches now count
--     them (functions below are the live 0050/0051 bodies + that source).
--
-- Lifecycle: draft -> sent -> partially_paid -> paid; void (draft/sent
-- without payments) releases every source (fees billable again, advances
-- back to pending, fuel/repair balances restored). Payments from the
-- carrier: carrier_fee_invoice_payments (posted/voided) roll up like
-- customer payments; overpayment refused.
--
-- Writes to invoices/lines only through the SECURITY DEFINER functions
-- below (owner/admin/accountant of the caller's organization). Numbering:
-- DFI-YYYY-NNNNN per organization and year.
-- One transaction; safe to re-run.
-- ============================================================================

begin;

-- ---- tables -------------------------------------------------------------------
create table if not exists public.carrier_fee_invoice_counters (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  year integer not null,
  last_number integer not null default 0,
  primary key (organization_id, year)
);
alter table public.carrier_fee_invoice_counters enable row level security;
revoke all on public.carrier_fee_invoice_counters from anon, authenticated;

create table if not exists public.carrier_fee_invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  invoice_number text not null,
  period_start date not null,
  period_end date not null,
  status text not null default 'draft' check (status in ('draft', 'sent', 'partially_paid', 'paid', 'void')),
  total_amount numeric(12, 2) not null default 0,
  amount_paid numeric(12, 2) not null default 0,
  balance_due numeric(12, 2) generated always as (total_amount - amount_paid) stored,
  terms_days integer not null default 7 check (terms_days between 0 and 120),
  issue_date date,
  due_date date,
  sent_at timestamptz,
  paid_at timestamptz,
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references public.profiles (id) on delete set null,
  void_reason text,
  constraint carrier_fee_invoices_period check (period_end >= period_start),
  constraint carrier_fee_invoices_number_key unique (organization_id, invoice_number),
  constraint carrier_fee_invoices_void_shape check ((status = 'void') = (voided_at is not null))
);
create index if not exists idx_carrier_fee_invoices_org_carrier on public.carrier_fee_invoices (organization_id, carrier_id, period_start desc);

create table if not exists public.carrier_fee_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.carrier_fee_invoices (id) on delete restrict,
  line_type text not null check (line_type in ('dispatch_fee', 'advance', 'fuel', 'maintenance')),
  description text not null,
  amount numeric(12, 2) not null check (amount > 0),
  service_date date,
  load_id uuid references public.loads (id) on delete restrict,
  dispatch_id uuid references public.dispatches (id) on delete restrict,
  load_number text,
  load_rate numeric(12, 2),
  fee_percentage numeric(6, 3),
  dispatch_advance_id uuid references public.dispatch_advances (id) on delete restrict,
  linked_fuel_log_id uuid references public.fuel_logs (id) on delete restrict,
  linked_maintenance_id uuid references public.maintenance_records (id) on delete restrict,
  voided boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint carrier_fee_invoice_lines_source check (
    (line_type = 'dispatch_fee' and dispatch_id is not null and dispatch_advance_id is null and linked_fuel_log_id is null and linked_maintenance_id is null)
    or (line_type = 'advance' and dispatch_advance_id is not null and linked_fuel_log_id is null and linked_maintenance_id is null)
    or (line_type = 'fuel' and linked_fuel_log_id is not null and dispatch_advance_id is null and linked_maintenance_id is null)
    or (line_type = 'maintenance' and linked_maintenance_id is not null and dispatch_advance_id is null and linked_fuel_log_id is null)
  )
);
create index if not exists idx_carrier_fee_invoice_lines_invoice on public.carrier_fee_invoice_lines (invoice_id, sort_order);
-- never billed twice: one live line per source
create unique index if not exists carrier_fee_invoice_lines_one_fee_per_dispatch on public.carrier_fee_invoice_lines (dispatch_id) where line_type = 'dispatch_fee' and not voided;
create unique index if not exists carrier_fee_invoice_lines_one_per_advance on public.carrier_fee_invoice_lines (dispatch_advance_id) where line_type = 'advance' and not voided;

create table if not exists public.carrier_fee_invoice_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.carrier_fee_invoices (id) on delete restrict,
  amount numeric(12, 2) not null check (amount > 0),
  method public.payment_method not null default 'ach',
  paid_date date not null default current_date,
  reference_number text,
  notes text,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  recorded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references public.profiles (id) on delete set null,
  void_reason text
);
create index if not exists idx_carrier_fee_invoice_payments_invoice on public.carrier_fee_invoice_payments (invoice_id);

-- advances can now be deducted into a carrier fee invoice
alter table public.dispatch_advances add column if not exists deducted_carrier_fee_invoice_id uuid references public.carrier_fee_invoices (id) on delete restrict;
alter table public.dispatch_advances drop constraint if exists dispatch_advances_deduction_consistency;
alter table public.dispatch_advances add constraint dispatch_advances_deduction_consistency check (
  (status = 'deducted' and (
     (case when deducted_invoice_id is not null then 1 else 0 end)
   + (case when deducted_settlement_id is not null then 1 else 0 end)
   + (case when deducted_driver_settlement_id is not null then 1 else 0 end)
   + (case when deducted_carrier_fee_invoice_id is not null then 1 else 0 end)) = 1)
  or (status <> 'deducted' and deducted_invoice_id is null and deducted_settlement_id is null
      and deducted_driver_settlement_id is null and deducted_carrier_fee_invoice_id is null)
);
alter table public.dispatch_advances drop constraint if exists dispatch_advances_single_deduction_target;
alter table public.dispatch_advances add constraint dispatch_advances_single_deduction_target check (
  (case when deducted_invoice_id is not null then 1 else 0 end)
  + (case when deducted_settlement_id is not null then 1 else 0 end)
  + (case when deducted_driver_settlement_id is not null then 1 else 0 end)
  + (case when deducted_carrier_fee_invoice_id is not null then 1 else 0 end) <= 1
);

-- ---- RLS: billing roles read; writes only through the functions --------------
alter table public.carrier_fee_invoices enable row level security;
alter table public.carrier_fee_invoice_lines enable row level security;
alter table public.carrier_fee_invoice_payments enable row level security;

drop policy if exists carrier_fee_invoices_select on public.carrier_fee_invoices;
create policy carrier_fee_invoices_select on public.carrier_fee_invoices for select to authenticated
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]));
drop policy if exists carrier_fee_invoice_lines_select on public.carrier_fee_invoice_lines;
create policy carrier_fee_invoice_lines_select on public.carrier_fee_invoice_lines for select to authenticated
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]));
drop policy if exists carrier_fee_invoice_payments_select on public.carrier_fee_invoice_payments;
create policy carrier_fee_invoice_payments_select on public.carrier_fee_invoice_payments for select to authenticated
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]));

revoke all on public.carrier_fee_invoices, public.carrier_fee_invoice_lines, public.carrier_fee_invoice_payments from anon;
revoke insert, update, delete, truncate on public.carrier_fee_invoices, public.carrier_fee_invoice_lines, public.carrier_fee_invoice_payments from authenticated;
grant select on public.carrier_fee_invoices, public.carrier_fee_invoice_lines, public.carrier_fee_invoice_payments to authenticated;

-- ---- totals + immutability ---------------------------------------------------
create or replace function public.carrier_fee_invoice_recalculate()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_id uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.carrier_fee_invoices i
     set total_amount = coalesce((select sum(l.amount) from public.carrier_fee_invoice_lines l where l.invoice_id = v_id and not l.voided), 0),
         updated_at = now()
   where i.id = v_id and i.status <> 'void';
  return null;
end $$;
drop trigger if exists carrier_fee_invoice_lines_recalculate on public.carrier_fee_invoice_lines;
create trigger carrier_fee_invoice_lines_recalculate after insert or update or delete on public.carrier_fee_invoice_lines
  for each row execute function public.carrier_fee_invoice_recalculate();

create or replace function public.guard_carrier_fee_invoice_line()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare v_status text; v_org uuid;
begin
  select status, organization_id into v_status, v_org from public.carrier_fee_invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if tg_op = 'INSERT' and (v_status is distinct from 'draft' or v_org is distinct from new.organization_id) then
    raise exception 'Lines can only be added to a draft invoice of the same organization.';
  end if;
  if tg_op = 'DELETE' and v_status is distinct from 'draft' then
    raise exception 'Lines can only be removed from a draft invoice.';
  end if;
  if tg_op = 'UPDATE' and (new.amount, new.line_type, new.invoice_id, new.dispatch_id, new.dispatch_advance_id, new.linked_fuel_log_id, new.linked_maintenance_id)
       is distinct from (old.amount, old.line_type, old.invoice_id, old.dispatch_id, old.dispatch_advance_id, old.linked_fuel_log_id, old.linked_maintenance_id) then
    raise exception 'Invoice lines cannot be changed; void and re-create the invoice instead.';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists carrier_fee_invoice_lines_guard on public.carrier_fee_invoice_lines;
create trigger carrier_fee_invoice_lines_guard before insert or update or delete on public.carrier_fee_invoice_lines
  for each row execute function public.guard_carrier_fee_invoice_line();

-- ---- fuel / maintenance recovery: invoice lines are a carrier recovery source --
create or replace function public.get_maintenance_recovery_status(p_maintenance_id uuid)
returns table (recoverable_amount numeric, recovered_amount numeric, remaining_amount numeric, recovery_status public.maintenance_recovery_status)
language sql stable as $function$
  with m as (
    select mr.recoverable_amount, mr.recovery_type from public.maintenance_records mr where mr.id = p_maintenance_id
  ),
  rec as (
    select
      (select coalesce(sum(sli.amount), 0) from public.settlement_line_items sli join public.settlements s on s.id = sli.settlement_id
        where sli.linked_maintenance_id = p_maintenance_id and sli.item_type = 'deduction' and s.status <> 'void')
    + (select coalesce(sum(dsa.amount), 0) from public.driver_settlement_adjustments dsa join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
        where dsa.linked_maintenance_id = p_maintenance_id and dsa.bucket = 'deduction' and ds.status <> 'void')
    + (select coalesce(sum(cl.amount), 0) from public.carrier_fee_invoice_lines cl
        where cl.linked_maintenance_id = p_maintenance_id and cl.line_type = 'maintenance' and not cl.voided) as amt
  )
  select m.recoverable_amount, rec.amt, m.recoverable_amount - rec.amt,
    case
      when m.recovery_type not in ('carrier_settlement', 'driver_settlement') then 'not_applicable'::public.maintenance_recovery_status
      when rec.amt <= 0 then 'pending'::public.maintenance_recovery_status
      when rec.amt >= m.recoverable_amount then 'recovered'::public.maintenance_recovery_status
      else 'partially_recovered'::public.maintenance_recovery_status
    end
  from m, rec;
$function$;

create or replace function public.get_fuel_recovery_status(p_fuel_log_id uuid)
returns table (recoverable_amount numeric, recovered_amount numeric, remaining_amount numeric, recovery_status public.fuel_recovery_status)
language sql stable as $function$
  with f as (
    select fl.recoverable_amount, fl.recovery_type from public.fuel_logs fl where fl.id = p_fuel_log_id
  ),
  rec as (
    select
      (select coalesce(sum(sli.amount), 0) from public.settlement_line_items sli join public.settlements s on s.id = sli.settlement_id
        where sli.linked_fuel_log_id = p_fuel_log_id and sli.item_type = 'deduction' and s.status <> 'void')
    + (select coalesce(sum(dsa.amount), 0) from public.driver_settlement_adjustments dsa join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
        where dsa.linked_fuel_log_id = p_fuel_log_id and dsa.bucket = 'deduction' and ds.status <> 'void')
    + (select coalesce(sum(cl.amount), 0) from public.carrier_fee_invoice_lines cl
        where cl.linked_fuel_log_id = p_fuel_log_id and cl.line_type = 'fuel' and not cl.voided) as amt
  )
  select f.recoverable_amount, rec.amt, f.recoverable_amount - rec.amt,
    case
      when f.recovery_type not in ('carrier_settlement', 'driver_settlement') then 'not_applicable'::public.fuel_recovery_status
      when rec.amt <= 0 then 'pending'::public.fuel_recovery_status
      when rec.amt >= f.recoverable_amount then 'recovered'::public.fuel_recovery_status
      else 'partially_recovered'::public.fuel_recovery_status
    end
  from f, rec;
$function$;

-- the over-recovery guards (0050/0051 bodies) now also count invoice lines,
-- and accept the invoice line table as a carrier-recovery lane
create or replace function public.guard_maintenance_recovery()
returns trigger language plpgsql as $function$
declare v_id uuid; v_type public.maintenance_recovery_type; v_recoverable numeric; v_already numeric; v_org uuid; v_new_amt numeric;
begin
  v_id := new.linked_maintenance_id;
  if v_id is null then return new; end if;
  -- (nested: a plpgsql AND does not short-circuit, and only the invoice
  -- line table has a voided column)
  if tg_table_name = 'carrier_fee_invoice_lines' then
    if to_jsonb(new) ->> 'voided' = 'true' then return new; end if;
  end if;
  select organization_id, recovery_type, recoverable_amount into v_org, v_type, v_recoverable from public.maintenance_records where id = v_id;
  if v_org is null then raise exception 'Linked maintenance record not found.'; end if;
  if v_org <> new.organization_id then raise exception 'Maintenance recovery must belong to the same organization.'; end if;
  if tg_table_name in ('settlement_line_items', 'carrier_fee_invoice_lines') and v_type <> 'carrier_settlement' then
    raise exception 'This maintenance record is not marked for recovery from the carrier.';
  end if;
  if tg_table_name = 'driver_settlement_adjustments' and v_type <> 'driver_settlement' then
    raise exception 'This maintenance record is not marked for Driver Settlement recovery.';
  end if;
  select coalesce(sum(amt), 0) into v_already from (
    select sli.amount as amt from public.settlement_line_items sli join public.settlements s on s.id = sli.settlement_id
     where sli.linked_maintenance_id = v_id and sli.item_type = 'deduction' and s.status <> 'void'
       and not (tg_table_name = 'settlement_line_items' and sli.id = new.id)
    union all
    select dsa.amount from public.driver_settlement_adjustments dsa join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
     where dsa.linked_maintenance_id = v_id and dsa.bucket = 'deduction' and ds.status <> 'void'
       and not (tg_table_name = 'driver_settlement_adjustments' and dsa.id = new.id)
    union all
    select cl.amount from public.carrier_fee_invoice_lines cl
     where cl.linked_maintenance_id = v_id and cl.line_type = 'maintenance' and not cl.voided
       and not (tg_table_name = 'carrier_fee_invoice_lines' and cl.id = new.id)
  ) x;
  v_new_amt := new.amount;
  if v_already + v_new_amt > v_recoverable + 0.005 then
    raise exception 'Recovery amount cannot exceed the remaining recoverable balance (remaining: %).', round(v_recoverable - v_already, 2);
  end if;
  return new;
end $function$;

create or replace function public.guard_fuel_recovery()
returns trigger language plpgsql as $function$
declare v_id uuid; v_type public.fuel_recovery_type; v_recoverable numeric; v_already numeric; v_org uuid;
begin
  v_id := new.linked_fuel_log_id;
  if v_id is null then return new; end if;
  -- (nested: a plpgsql AND does not short-circuit, and only the invoice
  -- line table has a voided column)
  if tg_table_name = 'carrier_fee_invoice_lines' then
    if to_jsonb(new) ->> 'voided' = 'true' then return new; end if;
  end if;
  select organization_id, recovery_type, recoverable_amount into v_org, v_type, v_recoverable from public.fuel_logs where id = v_id;
  if v_org is null then raise exception 'Linked fuel log not found.'; end if;
  if v_org <> new.organization_id then raise exception 'Fuel recovery must belong to the same organization.'; end if;
  if tg_table_name in ('settlement_line_items', 'carrier_fee_invoice_lines') and v_type <> 'carrier_settlement' then
    raise exception 'This fuel log is not marked for recovery from the carrier.';
  end if;
  if tg_table_name = 'driver_settlement_adjustments' and v_type <> 'driver_settlement' then
    raise exception 'This fuel log is not marked for Driver Settlement recovery.';
  end if;
  select coalesce(sum(amt), 0) into v_already from (
    select sli.amount as amt from public.settlement_line_items sli join public.settlements s on s.id = sli.settlement_id
     where sli.linked_fuel_log_id = v_id and sli.item_type = 'deduction' and s.status <> 'void'
       and not (tg_table_name = 'settlement_line_items' and sli.id = new.id)
    union all
    select dsa.amount from public.driver_settlement_adjustments dsa join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
     where dsa.linked_fuel_log_id = v_id and dsa.bucket = 'deduction' and ds.status <> 'void'
       and not (tg_table_name = 'driver_settlement_adjustments' and dsa.id = new.id)
    union all
    select cl.amount from public.carrier_fee_invoice_lines cl
     where cl.linked_fuel_log_id = v_id and cl.line_type = 'fuel' and not cl.voided
       and not (tg_table_name = 'carrier_fee_invoice_lines' and cl.id = new.id)
  ) x;
  if v_already + new.amount > v_recoverable + 0.005 then
    raise exception 'Recovery amount cannot exceed the remaining recoverable balance (remaining: %).', round(v_recoverable - v_already, 2);
  end if;
  return new;
end $function$;

drop trigger if exists carrier_fee_invoice_lines_guard_maintenance on public.carrier_fee_invoice_lines;
create trigger carrier_fee_invoice_lines_guard_maintenance before insert or update on public.carrier_fee_invoice_lines
  for each row when (new.linked_maintenance_id is not null) execute function public.guard_maintenance_recovery();
drop trigger if exists carrier_fee_invoice_lines_guard_fuel on public.carrier_fee_invoice_lines;
create trigger carrier_fee_invoice_lines_guard_fuel before insert or update on public.carrier_fee_invoice_lines
  for each row when (new.linked_fuel_log_id is not null) execute function public.guard_fuel_recovery();
-- keep the fuel/maintenance recovery caches (shown on their screens) current
drop trigger if exists carrier_fee_invoice_lines_sync_maintenance_iu on public.carrier_fee_invoice_lines;
create trigger carrier_fee_invoice_lines_sync_maintenance_iu after insert or update on public.carrier_fee_invoice_lines
  for each row when (new.linked_maintenance_id is not null) execute function public.trg_sync_maintenance_recovery_cache();
drop trigger if exists carrier_fee_invoice_lines_sync_maintenance_d on public.carrier_fee_invoice_lines;
create trigger carrier_fee_invoice_lines_sync_maintenance_d after delete on public.carrier_fee_invoice_lines
  for each row when (old.linked_maintenance_id is not null) execute function public.trg_sync_maintenance_recovery_cache();
drop trigger if exists carrier_fee_invoice_lines_sync_fuel_iu on public.carrier_fee_invoice_lines;
create trigger carrier_fee_invoice_lines_sync_fuel_iu after insert or update on public.carrier_fee_invoice_lines
  for each row when (new.linked_fuel_log_id is not null) execute function public.trg_sync_fuel_recovery_cache();
drop trigger if exists carrier_fee_invoice_lines_sync_fuel_d on public.carrier_fee_invoice_lines;
create trigger carrier_fee_invoice_lines_sync_fuel_d after delete on public.carrier_fee_invoice_lines
  for each row when (old.linked_fuel_log_id is not null) execute function public.trg_sync_fuel_recovery_cache();

-- ---- payments roll up ----------------------------------------------------------
create or replace function public.guard_carrier_fee_invoice_payment()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare v record; v_other numeric;
begin
  select * into v from public.carrier_fee_invoices where id = new.invoice_id for update;
  if v.id is null or v.organization_id <> new.organization_id then raise exception 'Invoice not found.'; end if;
  if tg_op = 'UPDATE' then
    if (new.amount, new.invoice_id, new.method, new.paid_date) is distinct from (old.amount, old.invoice_id, old.method, old.paid_date) then
      raise exception 'A recorded payment cannot be changed; void it and record it again.';
    end if;
    if old.status = 'voided' and new.status <> 'voided' then raise exception 'A voided payment cannot be restored.'; end if;
    return new;
  end if;
  if v.status not in ('sent', 'partially_paid') then
    raise exception 'Payments can only be recorded on a sent invoice (this one is %).', v.status;
  end if;
  select coalesce(sum(amount), 0) into v_other from public.carrier_fee_invoice_payments where invoice_id = new.invoice_id and status = 'posted';
  if v_other + new.amount > v.total_amount + 0.005 then
    raise exception 'Payment exceeds the balance due (%).', round(v.total_amount - v_other, 2);
  end if;
  return new;
end $$;
drop trigger if exists carrier_fee_invoice_payments_guard on public.carrier_fee_invoice_payments;
create trigger carrier_fee_invoice_payments_guard before insert or update on public.carrier_fee_invoice_payments
  for each row execute function public.guard_carrier_fee_invoice_payment();

create or replace function public.apply_carrier_fee_invoice_payment()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_paid numeric; v_total numeric; v_status text;
begin
  select coalesce(sum(amount), 0) into v_paid from public.carrier_fee_invoice_payments where invoice_id = new.invoice_id and status = 'posted';
  select total_amount, status into v_total, v_status from public.carrier_fee_invoices where id = new.invoice_id;
  if v_status in ('draft', 'void') then return null; end if;
  update public.carrier_fee_invoices
     set amount_paid = v_paid,
         status = case when v_paid >= v_total - 0.005 then 'paid' when v_paid > 0 then 'partially_paid' else 'sent' end,
         paid_at = case when v_paid >= v_total - 0.005 then coalesce(paid_at, now()) else null end,
         updated_at = now()
   where id = new.invoice_id;
  return null;
end $$;
drop trigger if exists carrier_fee_invoice_payments_apply on public.carrier_fee_invoice_payments;
create trigger carrier_fee_invoice_payments_apply after insert or update on public.carrier_fee_invoice_payments
  for each row execute function public.apply_carrier_fee_invoice_payment();

-- ---- what would be billed (preview and create share it) ------------------------
create or replace function public._carrier_fee_invoice_candidates(p_org uuid, p_carrier_id uuid, p_period_start date, p_period_end date)
returns table (line_type text, description text, amount numeric, service_date date, load_id uuid, dispatch_id uuid, load_number text,
               load_rate numeric, fee_percentage numeric, dispatch_advance_id uuid, linked_fuel_log_id uuid, linked_maintenance_id uuid, sort_key text)
language sql stable security definer set search_path = pg_catalog, public as $$
  -- dispatch fees: loads delivered in the period, not yet billed
  select 'dispatch_fee', 'Dispatch fee -- Load ' || l.load_number || ' (' || trim(to_char(df.dispatch_fee_percentage, 'FM990.###')) || '% of ' || to_char(df.load_rate, 'FM$999,999,990.00') || ')',
         df.dispatch_fee_amount, coalesce(d.completed_at, d.delivered_at, d.dispatched_at)::date, d.load_id, d.id, l.load_number,
         df.load_rate, df.dispatch_fee_percentage, null::uuid, null::uuid, null::uuid,
         '1|' || to_char(coalesce(d.completed_at, d.delivered_at, d.dispatched_at), 'YYYYMMDDHH24MISS') || l.load_number
  from public.dispatches d
  join public.loads l on l.id = d.load_id
  join public.dispatch_financials df on df.dispatch_id = d.id
  where d.organization_id = p_org and d.carrier_id = p_carrier_id
    and d.status in ('delivered', 'completed')
    and coalesce(d.completed_at, d.delivered_at, d.dispatched_at)::date between p_period_start and p_period_end
    and df.dispatch_fee_amount > 0
    and not exists (select 1 from public.carrier_fee_invoice_lines x where x.dispatch_id = d.id and x.line_type = 'dispatch_fee' and not x.voided)
  union all
  -- advances paid for the carrier, still pending, up to the period end
  select 'advance', initcap(replace(a.expense_type::text, '_', ' ')) || ' advance' || coalesce(' -- Load ' || l.load_number, '') || coalesce(': ' || a.description, ''),
         a.amount, a.paid_date, a.load_id, null, l.load_number, null, null, a.id, null, null,
         '2|' || to_char(a.paid_date, 'YYYYMMDD') || a.id::text
  from public.dispatch_advances a
  left join public.loads l on l.id = a.load_id
  where a.organization_id = p_org and a.carrier_id = p_carrier_id and a.status = 'pending' and a.paid_date <= p_period_end
    and not exists (select 1 from public.carrier_fee_invoice_lines x where x.dispatch_advance_id = a.id and x.line_type = 'advance' and not x.voided)
  union all
  -- fuel paid by the dispatch company, to be recovered from the carrier
  select 'fuel', 'Fuel' || coalesce(' -- ' || f.station_name, '') || coalesce(', ' || f.state, '') || ' (' || to_char(f.purchased_at, 'Mon DD') || ')',
         r.remaining_amount, f.purchased_at::date, null, null, null, null, null, null, f.id, null,
         '3|' || to_char(f.purchased_at, 'YYYYMMDDHH24MISS') || f.id::text
  from public.fuel_logs f
  cross join lateral public.get_fuel_recovery_status(f.id) r
  where f.organization_id = p_org and f.carrier_id = p_carrier_id and f.recovery_type = 'carrier_settlement'
    and f.purchased_at::date <= p_period_end and r.remaining_amount > 0.004
  union all
  -- repairs/maintenance paid by the dispatch company, to be recovered from the carrier
  select 'maintenance', coalesce(nullif(m.service_type, ''), 'Repair') || coalesce(' -- ' || m.vendor_name, '') || ' (' || to_char(m.service_date, 'Mon DD') || ')',
         r.remaining_amount, m.service_date, null, null, null, null, null, null, null, m.id,
         '4|' || to_char(m.service_date, 'YYYYMMDD') || m.id::text
  from public.maintenance_records m
  cross join lateral public.get_maintenance_recovery_status(m.id) r
  where m.organization_id = p_org and m.carrier_id = p_carrier_id and m.recovery_type = 'carrier_settlement'
    and m.service_date <= p_period_end and r.remaining_amount > 0.004;
$$;
revoke all on function public._carrier_fee_invoice_candidates(uuid, uuid, date, date) from public, anon, authenticated, service_role;

create or replace function public._carrier_fee_invoice_authorize(p_carrier_id uuid)
returns uuid language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_org uuid := public.current_org_id();
begin
  if auth.uid() is null or v_org is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    raise exception 'Only an owner, admin or accountant can bill carriers.' using errcode = '42501';
  end if;
  if p_carrier_id is not null and not exists (select 1 from public.carriers where id = p_carrier_id and organization_id = v_org) then
    raise exception 'Carrier not found.';
  end if;
  return v_org;
end $$;
revoke all on function public._carrier_fee_invoice_authorize(uuid) from public, anon, authenticated, service_role;

create or replace function public.preview_carrier_fee_invoice(p_carrier_id uuid, p_period_start date, p_period_end date)
returns table (line_type text, description text, amount numeric, service_date date, load_number text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_org uuid := public._carrier_fee_invoice_authorize(p_carrier_id);
begin
  if p_period_end < p_period_start then raise exception 'The period end must be on or after its start.'; end if;
  return query select c.line_type, c.description, c.amount, c.service_date, c.load_number
    from public._carrier_fee_invoice_candidates(v_org, p_carrier_id, p_period_start, p_period_end) c order by c.sort_key;
end $$;

create or replace function public.create_carrier_fee_invoice(p_carrier_id uuid, p_period_start date, p_period_end date, p_notes text default null)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_org uuid := public._carrier_fee_invoice_authorize(p_carrier_id);
  v_year int := extract(year from p_period_end)::int;
  v_n int; v_id uuid; v_terms int; v_lines int;
begin
  if p_period_end < p_period_start then raise exception 'The period end must be on or after its start.'; end if;
  perform 1 from public.carriers where id = p_carrier_id for update;   -- one invoice build per carrier at a time
  if not exists (select 1 from public._carrier_fee_invoice_candidates(v_org, p_carrier_id, p_period_start, p_period_end)) then
    raise exception 'Nothing to bill this carrier for that period (no delivered loads, advances, fuel or repairs left to bill).';
  end if;
  insert into public.carrier_fee_invoice_counters (organization_id, year, last_number) values (v_org, v_year, 1)
    on conflict (organization_id, year) do update set last_number = carrier_fee_invoice_counters.last_number + 1
    returning last_number into v_n;
  select coalesce(dispatch_service_terms_days, 7) into v_terms from public.carriers where id = p_carrier_id;
  insert into public.carrier_fee_invoices (organization_id, carrier_id, invoice_number, period_start, period_end, terms_days, notes, created_by)
  values (v_org, p_carrier_id, 'DFI-' || v_year || '-' || lpad(v_n::text, 5, '0'), p_period_start, p_period_end, least(greatest(v_terms, 0), 120), nullif(btrim(p_notes), ''), auth.uid())
  returning id into v_id;
  insert into public.carrier_fee_invoice_lines (organization_id, invoice_id, line_type, description, amount, service_date, load_id, dispatch_id, load_number,
                                                load_rate, fee_percentage, dispatch_advance_id, linked_fuel_log_id, linked_maintenance_id, sort_order)
  select v_org, v_id, c.line_type, c.description, round(c.amount, 2), c.service_date, c.load_id, c.dispatch_id, c.load_number,
         c.load_rate, c.fee_percentage, c.dispatch_advance_id, c.linked_fuel_log_id, c.linked_maintenance_id, row_number() over (order by c.sort_key)
  from public._carrier_fee_invoice_candidates(v_org, p_carrier_id, p_period_start, p_period_end) c;
  get diagnostics v_lines = row_count;
  update public.dispatch_advances a set status = 'deducted', deducted_carrier_fee_invoice_id = v_id
   where a.id in (select dispatch_advance_id from public.carrier_fee_invoice_lines where invoice_id = v_id and line_type = 'advance');
  perform public.log_activity('carrier'::public.entity_type, p_carrier_id, 'dispatch_fee_invoice_created',
    jsonb_build_object('invoice_id', v_id, 'lines', v_lines, 'period_start', p_period_start, 'period_end', p_period_end), v_org);
  return v_id;
end $$;

create or replace function public.remove_carrier_fee_invoice_line(p_line_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_org uuid := public._carrier_fee_invoice_authorize(null); l record;
begin
  select cl.* into l from public.carrier_fee_invoice_lines cl join public.carrier_fee_invoices i on i.id = cl.invoice_id
   where cl.id = p_line_id and cl.organization_id = v_org and i.status = 'draft' for update of cl;
  if l.id is null then raise exception 'Line not found on a draft invoice.'; end if;
  delete from public.carrier_fee_invoice_lines where id = p_line_id;
  if l.dispatch_advance_id is not null then
    update public.dispatch_advances set status = 'pending', deducted_carrier_fee_invoice_id = null where id = l.dispatch_advance_id and deducted_carrier_fee_invoice_id = l.invoice_id;
  end if;
end $$;

create or replace function public.send_carrier_fee_invoice(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_org uuid := public._carrier_fee_invoice_authorize(null); v record;
begin
  select * into v from public.carrier_fee_invoices where id = p_invoice_id and organization_id = v_org for update;
  if v.id is null then raise exception 'Invoice not found.'; end if;
  if v.status <> 'draft' then raise exception 'Only a draft invoice can be sent (this one is %).', v.status; end if;
  if v.total_amount <= 0 then raise exception 'This invoice has no lines.'; end if;
  update public.carrier_fee_invoices
     set status = 'sent', issue_date = current_date, due_date = current_date + terms_days, sent_at = now(), updated_at = now()
   where id = p_invoice_id;
  perform public.log_activity('carrier'::public.entity_type, v.carrier_id, 'dispatch_fee_invoice_sent', jsonb_build_object('invoice_id', v.id, 'total', v.total_amount), v_org);
end $$;

create or replace function public.void_carrier_fee_invoice(p_invoice_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_org uuid := public._carrier_fee_invoice_authorize(null); v record;
begin
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required to void an invoice.'; end if;
  select * into v from public.carrier_fee_invoices where id = p_invoice_id and organization_id = v_org for update;
  if v.id is null then raise exception 'Invoice not found.'; end if;
  if v.status = 'void' then return; end if;
  if exists (select 1 from public.carrier_fee_invoice_payments where invoice_id = p_invoice_id and status = 'posted') then
    raise exception 'This invoice has payments recorded; void the payments first.';
  end if;
  -- release every source: fees billable again, advances back to pending,
  -- fuel/repair balances restored (recovery caches resync via line triggers)
  -- header first: the voided invoice keeps its total for the record
  update public.carrier_fee_invoices set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason), updated_at = now()
   where id = p_invoice_id;
  update public.carrier_fee_invoice_lines set voided = true where invoice_id = p_invoice_id;
  update public.dispatch_advances set status = 'pending', deducted_carrier_fee_invoice_id = null where deducted_carrier_fee_invoice_id = p_invoice_id;
  perform public.log_activity('carrier'::public.entity_type, v.carrier_id, 'dispatch_fee_invoice_voided', jsonb_build_object('invoice_id', v.id, 'reason', btrim(p_reason)), v_org);
end $$;

create or replace function public.record_carrier_fee_invoice_payment(p_invoice_id uuid, p_amount numeric, p_method public.payment_method, p_paid_date date, p_reference text, p_notes text)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_org uuid := public._carrier_fee_invoice_authorize(null); v_id uuid;
begin
  if not exists (select 1 from public.carrier_fee_invoices where id = p_invoice_id and organization_id = v_org) then raise exception 'Invoice not found.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter a payment amount greater than zero.'; end if;
  insert into public.carrier_fee_invoice_payments (organization_id, invoice_id, amount, method, paid_date, reference_number, notes, recorded_by)
  values (v_org, p_invoice_id, round(p_amount, 2), coalesce(p_method, 'ach'), coalesce(p_paid_date, current_date), nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.void_carrier_fee_invoice_payment(p_payment_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_org uuid := public._carrier_fee_invoice_authorize(null);
begin
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required to void a payment.'; end if;
  update public.carrier_fee_invoice_payments set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = p_payment_id and organization_id = v_org and status = 'posted';
  if not found then raise exception 'Posted payment not found.'; end if;
end $$;

-- client access: only the public RPCs, only signed-in users (role checked inside)
do $acl$
declare f text;
begin
  foreach f in array array[
    'public.preview_carrier_fee_invoice(uuid,date,date)', 'public.create_carrier_fee_invoice(uuid,date,date,text)',
    'public.remove_carrier_fee_invoice_line(uuid)', 'public.send_carrier_fee_invoice(uuid)', 'public.void_carrier_fee_invoice(uuid,text)',
    'public.record_carrier_fee_invoice_payment(uuid,numeric,public.payment_method,date,text,text)', 'public.void_carrier_fee_invoice_payment(uuid,text)'] loop
    execute format('revoke all on function %s from public, anon, service_role', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.carrier_fee_invoice_recalculate()', 'public.apply_carrier_fee_invoice_payment()'] loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f);
  end loop;
end $acl$;

-- postconditions
do $post$
begin
  if to_regclass('public.carrier_fee_invoices') is null or to_regclass('public.carrier_fee_invoice_lines') is null or to_regclass('public.carrier_fee_invoice_payments') is null then
    raise exception '0165 postcondition: tables missing.';
  end if;
  if has_function_privilege('anon', 'public.create_carrier_fee_invoice(uuid,date,date,text)'::regprocedure, 'execute')
     or has_function_privilege('authenticated', 'public._carrier_fee_invoice_candidates(uuid,uuid,date,date)'::regprocedure, 'execute') then
    raise exception '0165 postcondition: function privileges wrong.';
  end if;
  if has_table_privilege('authenticated', 'public.carrier_fee_invoices', 'insert') or has_table_privilege('authenticated', 'public.carrier_fee_invoice_lines', 'delete') then
    raise exception '0165 postcondition: direct writes must go through the functions.';
  end if;
end $post$;

commit;
