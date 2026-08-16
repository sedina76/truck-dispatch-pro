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
