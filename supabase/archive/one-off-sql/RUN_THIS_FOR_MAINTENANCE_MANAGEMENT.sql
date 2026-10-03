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
