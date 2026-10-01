-- =============================================================================
-- 0051_fuel_recovery.sql
-- Fuel Logs / Fuel Purchase payment responsibility + carrier/driver
-- settlement recovery. Extends the existing fuel_logs table (0006) --
-- does not create a second fuel system. Reuses expenses (scope='truck',
-- category='fuel', already-existing fuel_log_id UNIQUE column from 0040 --
-- built specifically to prevent a double expense, never populated by any
-- code until now), the existing carrier/driver settlement deduction
-- mechanisms (settlement_line_items.item_type='deduction' /
-- driver_settlement_adjustments.bucket='deduction', already modeled on
-- dispatch_advances' "paid now, recovered later" lifecycle via
-- linked_advance_id, and extended for Maintenance last session via
-- linked_maintenance_id) -- this migration adds the parallel linked_
-- fuel_log_id column rather than inventing a new recovery mechanism.
--
-- RE-RUNNABLE BY DESIGN from the start this time (0050's first attempt
-- was not, and needed a follow-up fix after a live failure) -- every
-- statement is guarded (IF NOT EXISTS / DROP ... IF EXISTS first /
-- existence-checked DO blocks), and the settlement-side cache-sync
-- triggers are split into separate INSERT/UPDATE (NEW-based WHEN) and
-- DELETE (OLD-based WHEN) triggers from the start -- Postgres rejects a
-- WHEN clause referencing NEW on any trigger that also fires on DELETE,
-- learned the hard way on 0050's first attempt.
--
-- GENUINE GAPS being filled (see chat architecture report for why each is
-- actually needed):
--   1. fuel_logs has no payer/recovery/expense-link/carrier columns at all
--      today -- total_amount was a bare number with no accounting path.
--   2. No cross-org guard trigger exists on fuel_logs.
--   3. settlement_line_items / driver_settlement_adjustments have no way
--      to reference a fuel log (only dispatch_advances and, since 0050,
--      maintenance_records).
--   4. 'fuel' is not a valid entity_type value yet (needed so a fuel
--      receipt can be uploaded via the existing polymorphic documents
--      table + a real storage bucket -- fuel_logs.receipt_document_id
--      exists but has never been wired to any upload path).
--   5. No trigger prevents a fuel charge from being recovered twice,
--      recovered beyond its recoverable amount, or recovered through BOTH
--      carrier and driver settlement at once.
--   6. Fuel log deletion is currently fully open (deleteRecord) with no
--      protection once a real expense/recovery is attached to it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Enum extension (additive only). document_type already has
-- 'fuel_receipt' (0040) -- no new document_type value needed, only this
-- one entity_type value so a documents row can legitimately describe
-- "this belongs to a fuel log."
-- ---------------------------------------------------------------------------
alter type public.entity_type add value if not exists 'fuel';

commit; -- new enum value must be committed before use later in this script

-- Postgres has no CREATE TYPE IF NOT EXISTS -- guard each with an
-- existence check, matching the same VALUES as maintenance_paid_by/
-- maintenance_recovery_type/maintenance_recovery_status (0050) but as
-- their own types: a fuel_logs column typed "maintenance_paid_by" would
-- be a confusing schema to read later, and this codebase already keeps
-- parallel-but-distinct enums per table on purpose (settlement_status vs
-- driver_settlement_status).
do $$
begin
  if not exists (select 1 from pg_type where typname = 'fuel_paid_by') then
    create type public.fuel_paid_by as enum ('dispatch_company', 'carrier', 'driver', 'other');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'fuel_recovery_type') then
    create type public.fuel_recovery_type as enum (
      'none', 'carrier_settlement', 'driver_settlement', 'carrier_direct', 'driver_direct'
    );
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'fuel_recovery_status') then
    create type public.fuel_recovery_status as enum (
      'not_applicable', 'pending', 'partially_recovered', 'recovered'
    );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. fuel_logs: payment/recovery/carrier columns. No new "status" column --
-- unlike a repair, a fuel purchase has no open/in-progress operational
-- lifecycle; recovery_status alone captures its financial lifecycle.
-- ---------------------------------------------------------------------------
alter table public.fuel_logs
  add column if not exists carrier_id uuid references public.carriers (id) on delete set null,
  add column if not exists paid_by public.fuel_paid_by not null default 'dispatch_company',
  add column if not exists recovery_type public.fuel_recovery_type not null default 'none',
  add column if not exists recoverable_amount numeric(10, 2) not null default 0,
  add column if not exists responsible_driver_id uuid references public.drivers (id) on delete set null,
  add column if not exists expense_id uuid references public.expenses (id) on delete set null,
  add column if not exists recovery_status public.fuel_recovery_status not null default 'not_applicable',
  add column if not exists recovered_amount numeric(10, 2) not null default 0;

alter table public.fuel_logs drop constraint if exists fuel_logs_recoverable_le_total;
alter table public.fuel_logs add constraint fuel_logs_recoverable_le_total check (recoverable_amount <= total_amount);

alter table public.fuel_logs drop constraint if exists fuel_logs_recoverable_nonneg;
alter table public.fuel_logs add constraint fuel_logs_recoverable_nonneg check (recoverable_amount >= 0);

-- Recovery type dictates exactly one lane -- a responsible_driver_id only
-- makes sense (and is only required) when recovery_type = 'driver_settlement'
-- (spec section 8: staff must explicitly select the responsible driver,
-- never inferred from fuel_logs.driver_id -- "who purchased fuel" and
-- "who owes for it" are deliberately different columns).
alter table public.fuel_logs drop constraint if exists fuel_logs_driver_recovery_shape;
alter table public.fuel_logs add constraint fuel_logs_driver_recovery_shape check (
  (recovery_type = 'driver_settlement' and responsible_driver_id is not null)
  or (recovery_type <> 'driver_settlement')
);

-- recoverable_amount is only meaningful for the two settlement-recovery
-- paths; direct-paid and no-recovery paths recover nothing through this
-- app (spec section 12/13).
alter table public.fuel_logs drop constraint if exists fuel_logs_recoverable_shape;
alter table public.fuel_logs add constraint fuel_logs_recoverable_shape check (
  (recovery_type in ('carrier_settlement', 'driver_settlement') and recoverable_amount >= 0)
  or (recovery_type not in ('carrier_settlement', 'driver_settlement') and recoverable_amount = 0)
);

comment on column public.fuel_logs.recovered_amount is
  'Denormalized cache of the sum of every non-void linked settlement_line_items/driver_settlement_adjustments row for this fuel log -- kept in sync by sync_fuel_recovery_cache() below, whose result (get_fuel_recovery_status()) is the actual source of truth. Never edited directly by application code.';

create index if not exists idx_fuel_logs_carrier on public.fuel_logs (carrier_id) where carrier_id is not null;
create index if not exists idx_fuel_logs_recovery_status on public.fuel_logs (recovery_status);
create index if not exists idx_fuel_logs_expense on public.fuel_logs (expense_id) where expense_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Settlement deduction linkage -- mirrors linked_advance_id / linked_
-- maintenance_id exactly (both tables already have those columns; this is
-- the parallel for fuel, not a new mechanism).
-- ---------------------------------------------------------------------------
alter table public.settlement_line_items
  add column if not exists linked_fuel_log_id uuid references public.fuel_logs (id) on delete set null;
alter table public.driver_settlement_adjustments
  add column if not exists linked_fuel_log_id uuid references public.fuel_logs (id) on delete set null;

create index if not exists idx_settlement_line_items_fuel on public.settlement_line_items (linked_fuel_log_id) where linked_fuel_log_id is not null;
create index if not exists idx_driver_settlement_adjustments_fuel on public.driver_settlement_adjustments (linked_fuel_log_id) where linked_fuel_log_id is not null;

-- A given settlement can only carry ONE deduction line for a given fuel
-- log -- double-click/retry protection (spec section 25/TEST H). Partial
-- recovery across DIFFERENT settlements is still fully supported; this
-- only blocks the SAME settlement from getting the same line twice.
create unique index if not exists uq_settlement_line_items_fuel_per_settlement
  on public.settlement_line_items (settlement_id, linked_fuel_log_id)
  where linked_fuel_log_id is not null and item_type = 'deduction';
create unique index if not exists uq_driver_settlement_adjustments_fuel_per_settlement
  on public.driver_settlement_adjustments (driver_settlement_id, linked_fuel_log_id)
  where linked_fuel_log_id is not null and bucket = 'deduction';

-- ---------------------------------------------------------------------------
-- 3. get_fuel_recovery_status: THE canonical recovered/remaining/status
-- calculation -- sums real linked rows across BOTH settlement tables
-- (excluding void/cancelled settlements), never a duplicated running
-- total maintained by hand (spec section 7: "Prefer deriving
-- recovered_amount from linked settlement rows").
-- ---------------------------------------------------------------------------
create or replace function public.get_fuel_recovery_status(p_fuel_log_id uuid)
returns table (recoverable_amount numeric, recovered_amount numeric, remaining_amount numeric, recovery_status public.fuel_recovery_status)
language sql
stable
as $$
  with f as (
    select fl.recoverable_amount, fl.recovery_type
    from public.fuel_logs fl
    where fl.id = p_fuel_log_id
  ),
  carrier_recovered as (
    select coalesce(sum(sli.amount), 0) as amt
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.linked_fuel_log_id = p_fuel_log_id
      and sli.item_type = 'deduction'
      and s.status <> 'void'
  ),
  driver_recovered as (
    select coalesce(sum(dsa.amount), 0) as amt
    from public.driver_settlement_adjustments dsa
    join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
    where dsa.linked_fuel_log_id = p_fuel_log_id
      and dsa.bucket = 'deduction'
      and ds.status <> 'void'
  )
  select
    f.recoverable_amount,
    (select amt from carrier_recovered) + (select amt from driver_recovered),
    f.recoverable_amount - ((select amt from carrier_recovered) + (select amt from driver_recovered)),
    case
      when f.recovery_type not in ('carrier_settlement', 'driver_settlement') then 'not_applicable'::public.fuel_recovery_status
      when (select amt from carrier_recovered) + (select amt from driver_recovered) <= 0 then 'pending'::public.fuel_recovery_status
      when (select amt from carrier_recovered) + (select amt from driver_recovered) >= f.recoverable_amount then 'recovered'::public.fuel_recovery_status
      else 'partially_recovered'::public.fuel_recovery_status
    end
  from f;
$$;

grant execute on function public.get_fuel_recovery_status(uuid) to authenticated;

create or replace function public.sync_fuel_recovery_cache(p_fuel_log_id uuid)
returns void
language plpgsql
as $$
declare
  v_row record;
begin
  select * into v_row from public.get_fuel_recovery_status(p_fuel_log_id);
  update public.fuel_logs
  set recovered_amount = v_row.recovered_amount,
      recovery_status = v_row.recovery_status
  where id = p_fuel_log_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. guard_fuel_recovery: the DOUBLE-COUNTING / DOUBLE-RECOVERY /
-- OWNER-OPERATOR PROTECTION enforcement point, at the database layer
-- (spec section 9/10). Fires on both settlement_line_items and
-- driver_settlement_adjustments, INSERT/UPDATE only.
-- ---------------------------------------------------------------------------
create or replace function public.guard_fuel_recovery()
returns trigger
language plpgsql
as $$
declare
  v_fuel_log_id uuid;
  v_recovery_type public.fuel_recovery_type;
  v_recoverable numeric;
  v_already_recovered numeric;
  v_org uuid;
begin
  v_fuel_log_id := new.linked_fuel_log_id;
  if v_fuel_log_id is null then
    return new;
  end if;

  select organization_id, recovery_type, recoverable_amount
    into v_org, v_recovery_type, v_recoverable
  from public.fuel_logs where id = v_fuel_log_id;

  if v_org is null then
    raise exception 'Linked fuel log not found.';
  end if;
  if v_org <> new.organization_id then
    raise exception 'Fuel recovery must belong to the same organization.';
  end if;

  -- One recovery lane only, matching fuel_logs.recovery_type -- a
  -- carrier-recovery fuel log can never also pick up a driver-settlement
  -- deduction, and vice versa (spec section 9/10: never both Carrier and
  -- Driver Settlement for the same purchase).
  if tg_table_name = 'settlement_line_items' and v_recovery_type <> 'carrier_settlement' then
    raise exception 'This fuel log is not marked for Carrier Settlement recovery.';
  end if;
  if tg_table_name = 'driver_settlement_adjustments' and v_recovery_type <> 'driver_settlement' then
    raise exception 'This fuel log is not marked for Driver Settlement recovery.';
  end if;

  -- Sum every OTHER already-linked, non-void recovery row across BOTH
  -- tables (excluding this row itself, relevant on update) and confirm
  -- adding/changing this one doesn't exceed the recoverable amount.
  select coalesce(sum(amt), 0) into v_already_recovered from (
    select sli.amount as amt
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.linked_fuel_log_id = v_fuel_log_id
      and sli.item_type = 'deduction'
      and s.status <> 'void'
      and not (tg_table_name = 'settlement_line_items' and sli.id = new.id)
    union all
    select dsa.amount as amt
    from public.driver_settlement_adjustments dsa
    join public.driver_settlements ds on ds.id = dsa.driver_settlement_id
    where dsa.linked_fuel_log_id = v_fuel_log_id
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

drop trigger if exists settlement_line_items_guard_fuel on public.settlement_line_items;
create trigger settlement_line_items_guard_fuel
  before insert or update on public.settlement_line_items
  for each row
  when (new.linked_fuel_log_id is not null)
  execute function public.guard_fuel_recovery();

drop trigger if exists driver_settlement_adjustments_guard_fuel on public.driver_settlement_adjustments;
create trigger driver_settlement_adjustments_guard_fuel
  before insert or update on public.driver_settlement_adjustments
  for each row
  when (new.linked_fuel_log_id is not null)
  execute function public.guard_fuel_recovery();

-- Cache-sync triggers, split into INSERT/UPDATE (NEW-based WHEN) and
-- DELETE (OLD-based WHEN) from the start -- a single combined trigger
-- with a coalesce(new,old) WHEN clause is what broke 0050's first
-- attempt live (Postgres: "DELETE trigger's WHEN condition cannot
-- reference NEW values").
create or replace function public.trg_sync_fuel_recovery_cache()
returns trigger
language plpgsql
as $$
begin
  perform public.sync_fuel_recovery_cache(coalesce(new.linked_fuel_log_id, old.linked_fuel_log_id));
  return coalesce(new, old);
end;
$$;

drop trigger if exists settlement_line_items_sync_fuel_iu on public.settlement_line_items;
drop trigger if exists settlement_line_items_sync_fuel_d on public.settlement_line_items;
create trigger settlement_line_items_sync_fuel_iu
  after insert or update on public.settlement_line_items
  for each row
  when (new.linked_fuel_log_id is not null)
  execute function public.trg_sync_fuel_recovery_cache();
create trigger settlement_line_items_sync_fuel_d
  after delete on public.settlement_line_items
  for each row
  when (old.linked_fuel_log_id is not null)
  execute function public.trg_sync_fuel_recovery_cache();

drop trigger if exists driver_settlement_adjustments_sync_fuel_iu on public.driver_settlement_adjustments;
drop trigger if exists driver_settlement_adjustments_sync_fuel_d on public.driver_settlement_adjustments;
create trigger driver_settlement_adjustments_sync_fuel_iu
  after insert or update on public.driver_settlement_adjustments
  for each row
  when (new.linked_fuel_log_id is not null)
  execute function public.trg_sync_fuel_recovery_cache();
create trigger driver_settlement_adjustments_sync_fuel_d
  after delete on public.driver_settlement_adjustments
  for each row
  when (old.linked_fuel_log_id is not null)
  execute function public.trg_sync_fuel_recovery_cache();

-- ---------------------------------------------------------------------------
-- 5. guard_fuel_log_org: cross-org guard + Truck -> Carrier auto-
-- derivation (spec section 3), same pattern as guard_maintenance_org
-- (0050) minus the truck/trailer-mismatch branch -- fuel_logs has only
-- truck_id, no trailer_id, so there is nothing to reconcile between two
-- pieces of equipment.
-- ---------------------------------------------------------------------------
create or replace function public.guard_fuel_log_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_truck_carrier uuid;
begin
  -- RECOVERY SAFETY (spec section 13): once a real expense and/or
  -- recovery already exists, the truck -- and therefore the carrier
  -- derived from it below -- is frozen. Without this, changing truck_id
  -- after the fact would silently re-derive carrier_id to the NEW
  -- truck's carrier while a real settlement deduction/expense remains
  -- linked back to this same fuel log, corrupting which carrier that
  -- historical recovery actually belongs to. actions.ts already excludes
  -- truck_id from its own update payload once locked -- this is the
  -- defense-in-depth backstop for any write that reaches this table
  -- directly (matching the DB-guard-over-app-only-validation rule used
  -- everywhere else in this schema for financial-integrity-critical
  -- checks).
  if tg_op = 'UPDATE' and (old.expense_id is not null or old.recovered_amount > 0) and new.truck_id is distinct from old.truck_id then
    raise exception 'This fuel log has a linked expense or settlement recovery -- the truck (and its carrier) cannot be changed.';
  end if;

  select organization_id, carrier_id into v_org, v_truck_carrier from public.trucks where id = new.truck_id;
  if v_org is null or v_org <> new.organization_id then
    raise exception 'Fuel log truck must belong to the same organization.';
  end if;
  -- carrier_id is DERIVED from the truck's own canonical relationship,
  -- never independently client-editable (there is no carrier_id form
  -- field at all -- see fuel-form-fields.tsx). A client-supplied
  -- carrier_id is never trusted (spec section 3: "do not trust client
  -- carrier_id").
  new.carrier_id := v_truck_carrier;

  if new.driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Fuel log driver must belong to the same organization.';
    end if;
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

  -- Initialize/recompute recovery_status here (not left at its column
  -- default until the first settlement-side link event syncs it) -- the
  -- exact same fix applied retroactively to guard_maintenance_org last
  -- session after a live test caught the gap; built in from the start
  -- here. Without this, a brand-new carrier_settlement/driver_settlement
  -- fuel log would never appear in either Settlement page's "Pending
  -- Fuel Recoveries" list until it had already been linked once -- an
  -- impossible chicken-and-egg state (spec section 6/TEST B).
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

drop trigger if exists fuel_logs_guard_org on public.fuel_logs;
create trigger fuel_logs_guard_org
  before insert or update on public.fuel_logs
  for each row execute function public.guard_fuel_log_org();

-- ---------------------------------------------------------------------------
-- 6. guard_fuel_log_delete: once a fuel log has a real linked expense or
-- any actual recovered amount, deleting it would silently orphan that
-- accounting trail (the expense/deduction rows themselves are NOT
-- cascade-deleted -- their FK is ON DELETE SET NULL -- so the dollars
-- stay correct, but which purchase they were ever for becomes
-- unrecoverable). Blocked outright rather than allowed to happen
-- silently; the existing edit-lock pattern (actions.ts) is the intended
-- correction path once real money is attached.
-- ---------------------------------------------------------------------------
create or replace function public.guard_fuel_log_delete()
returns trigger
language plpgsql
as $$
begin
  if old.expense_id is not null or old.recovered_amount > 0 then
    raise exception 'This fuel log has a linked expense or settlement recovery and cannot be deleted.';
  end if;
  return old;
end;
$$;

drop trigger if exists fuel_logs_guard_delete on public.fuel_logs;
create trigger fuel_logs_guard_delete
  before delete on public.fuel_logs
  for each row execute function public.guard_fuel_log_delete();

-- ---------------------------------------------------------------------------
-- 7. Private storage bucket for fuel receipts -- reuses the EXISTING
-- expense-documents bucket and its already-live RLS policies verbatim
-- (0040: signed-URL-only, no public access, org-folder-scoped select,
-- owner/admin/accountant/dispatcher insert) rather than creating a third
-- receipts bucket (spec section 19: "Do not build a second receipt
-- table" -- extending to "do not build a second bucket" for the same
-- reason). No new storage policy needed.
-- ---------------------------------------------------------------------------
