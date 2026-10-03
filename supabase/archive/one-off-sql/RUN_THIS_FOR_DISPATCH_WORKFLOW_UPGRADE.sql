-- =============================================================================
-- 0048_dispatch_workflow_upgrade.sql
-- Dispatch page upgrade. Reuses the existing dispatches/loads/load_stops/
-- carriers/drivers/trucks/trailers schema verbatim -- no new tables, no new
-- enum values (dispatch_status already has 'cancelled'; trucks/trailers
-- already have ownership_type 'owner_operator' for Assignment Type).
--
-- ONE genuine gap found and fixed here: every other multi-FK table in this
-- schema (expenses, driver_pay_rates, profile_share_log, ...) has a
-- guard_*_org() trigger validating that its foreign keys belong to the
-- same organization as the row itself -- dispatches never got one. RLS on
-- `dispatches` only checks the dispatch row's own organization_id; it does
-- NOT verify that a submitted carrier_id/truck_id/driver_id/trailer_id
-- actually belongs to that org. Without this trigger, a crafted request
-- could assign another organization's carrier/driver/truck/trailer to a
-- dispatch. Also validates relationship consistency (the assigned
-- driver/truck actually belongs to the assigned carrier; a trailer, if
-- set, either belongs to that carrier or is unassigned/shared).
-- =============================================================================

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
