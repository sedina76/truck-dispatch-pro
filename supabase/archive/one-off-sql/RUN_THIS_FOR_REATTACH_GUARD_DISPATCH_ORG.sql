-- CRITICAL, pre-existing, unrelated-to-this-pass finding (discovered via
-- the dispatch-conflict-UX cross-org live test): guard_dispatch_org()
-- (0048_dispatch_workflow_upgrade.sql) is NOT currently attached to
-- public.dispatches in this database. Verified directly: a plain INSERT
-- under a real authenticated session, with organization_id set to the
-- caller's own org but load_id/carrier_id/truck_id/driver_id pointing at a
-- DIFFERENT real organization's rows, succeeds with zero error -- for
-- every one of load_id, carrier_id, truck_id, and driver_id independently.
-- Whether the 0048 trigger was simply never applied to this database or
-- was later dropped some other way, the effect is the same: there is
-- currently no DB-level protection against a cross-org dispatch
-- assignment at all.
--
-- This migration only re-applies the EXACT function/trigger 0048 already
-- defined -- byte-for-byte the same logic, nothing changed, nothing
-- weakened. `create or replace function` + `drop trigger if exists` +
-- `create trigger` is idempotent and safe to run whether the original
-- never took effect or is simply missing now.
create or replace function public.guard_dispatch_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_carrier_id uuid;
begin
  if new.load_id is not null then
    select organization_id into v_org from public.loads where id = new.load_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch load must belong to the same organization.';
    end if;
  end if;

  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch carrier must belong to the same organization.';
    end if;
  end if;

  if new.truck_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.trucks where id = new.truck_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch truck must belong to the same organization.';
    end if;
    if new.carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected truck does not belong to the selected carrier.';
    end if;
  end if;

  if new.driver_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch driver must belong to the same organization.';
    end if;
    if new.carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected driver does not belong to the selected carrier.';
    end if;
  end if;

  if new.trailer_id is not null then
    select organization_id, carrier_id into v_org, v_carrier_id from public.trailers where id = new.trailer_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Dispatch trailer must belong to the same organization.';
    end if;
    -- Trailers may be a shared/unassigned pool (carrier_id nullable, 0003) --
    -- only reject a trailer that belongs to a DIFFERENT carrier, not one
    -- with no carrier at all.
    if new.carrier_id is not null and v_carrier_id is not null and v_carrier_id is distinct from new.carrier_id then
      raise exception 'The selected trailer belongs to a different carrier.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists dispatches_guard_org on public.dispatches;
create trigger dispatches_guard_org
  before insert or update on public.dispatches
  for each row execute function public.guard_dispatch_org();
