-- ============================================================================
-- VERIFY_LD100035_CARRIER_SCOPE_READONLY.sql
--
-- Diagnoses why saving a new dispatch on load LD-100035 (carrier: KALI FR. /
-- Kali Freights LLC, driver: Sedina Ali, truck: T-112) is rejected by
-- public.guard_dispatch_carrier_scope() (0132), WITHOUT attempting the save.
--
-- 100% READ-ONLY. SELECT only. No INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / GRANT / REVOKE, no transaction, no fixtures. Safe to run
-- against production at any time. Nothing is modified.
--
-- HOW TO USE
--   Run in the Supabase SQL editor (or your own psql session). BLOCK 1
--   finds the load; copy its id/organization_id/carrier_id into BLOCKS 2-5
--   if you'd rather hardcode them, but every block below re-derives them
--   from the load_number match, so you can just run the whole file.
-- ============================================================================


-- ############################################################################
-- BLOCK 1 -- THE LOAD (current carrier pin, resolution state)
-- This is loads.carrier_id / carrier_resolution exactly as
-- guard_dispatch_carrier_scope() (0132) reads them. carrier_id, once set by
-- a dispatch's first-claim, is PERMANENT even after that dispatch is
-- cancelled (see 0132 lines 512-524) -- this is the field that determines
-- whether a NEW carrier can ever be assigned to this load again.
-- ############################################################################
select
  l.id                  as load_id,
  l.load_number,
  l.organization_id,
  l.status              as load_status,
  l.carrier_id          as load_pinned_carrier_id,
  c.legal_name          as load_pinned_carrier_name,
  l.carrier_resolution,
  l.carrier_locked_at,
  l.financial_dispatch_id,
  l.created_at
from public.loads l
left join public.carriers c on c.id = l.carrier_id
where l.load_number = 'LD-100035';
-- Expect exactly 1 row. If load_pinned_carrier_id is NOT NULL and does not
-- match KALI FR.'s carrier id (see BLOCK 3), that mismatch is the entire
-- explanation -- CARRIER_MISMATCH will fire every time until resolved.


-- ############################################################################
-- BLOCK 2 -- EVERY DISPATCH EVER CREATED ON THIS LOAD, in order
-- Shows exactly which carrier(s) have touched this load and whether the
-- guard's "atomic first-dispatch claim" (0132) already ran for one of them.
-- A CANCELLED dispatch here still explains a permanent carrier pin (its
-- cancellation never clears loads.carrier_id -- 0129's cancel_dispatch()
-- preserves it as history).
-- ############################################################################
select
  d.id                  as dispatch_id,
  d.status              as dispatch_status,
  d.carrier_id,
  c.legal_name          as carrier_name,
  d.driver_id,
  dr.first_name || ' ' || dr.last_name as driver_name,
  d.truck_id,
  t.unit_number         as truck_unit,
  d.trailer_id,
  d.created_at,
  d.updated_at
from public.dispatches d
join public.loads l on l.id = d.load_id
left join public.carriers c on c.id = d.carrier_id
left join public.drivers dr on dr.id = d.driver_id
left join public.trucks t on t.id = d.truck_id
where l.load_number = 'LD-100035'
order by d.created_at;
-- KEY: if the MOST RECENT non-cancelled-at-claim-time dispatch (or the
-- first dispatch ever, if none since) has a carrier_id that differs from
-- KALI FR.'s id, that is the pinned carrier from BLOCK 1 and the source of
-- the CARRIER_MISMATCH rejection. Its dispatch_status here tells you
-- whether that prior assignment is 'cancelled' or still active.


-- ############################################################################
-- BLOCK 3 -- THE CARRIER SELECTED IN THE ATTEMPTED DISPATCH (KALI FR.)
-- Confirms the exact id/name of the carrier being selected on the New
-- Dispatch form, for direct comparison against BLOCK 1's pinned carrier.
-- ############################################################################
select
  c.id                  as carrier_id,
  c.legal_name,
  c.dba_name,
  c.organization_id,
  c.is_active
from public.carriers c
where c.legal_name ilike '%kali%'
order by c.created_at;
-- Expect exactly 1 row. If 0 or >1, narrow the ilike pattern.


-- ############################################################################
-- BLOCK 4 -- DRIVER / TRUCK CURRENT ACTIVE-DISPATCH STATE (Sedina Ali / T-112)
-- Rules out (or confirms) a driver/truck conflict as a CONTRIBUTING factor,
-- independent of the carrier-scope question above. Statuses matching
-- ACTIVE_DISPATCH_STATUSES (src/lib/dispatch/conflicts.ts) mean "currently
-- holding" -- 'assigned','accepted','en_route_to_pickup','at_pickup',
-- 'loaded','en_route_to_delivery','at_delivery'.
-- ############################################################################
select
  'driver' as resource, dr.id, dr.first_name || ' ' || dr.last_name as label, dr.carrier_id,
  d.id as active_dispatch_id, d.status as active_dispatch_status, dl.load_number
from public.drivers dr
left join public.dispatches d
  on d.driver_id = dr.id
  and d.status in ('assigned','accepted','en_route_to_pickup','at_pickup','loaded','en_route_to_delivery','at_delivery')
left join public.loads dl on dl.id = d.load_id
where dr.first_name ilike '%sedina%' and dr.last_name ilike '%ali%'
union all
select
  'truck', t.id, t.unit_number, t.carrier_id,
  d.id, d.status, dl.load_number
from public.trucks t
left join public.dispatches d
  on d.truck_id = t.id
  and d.status in ('assigned','accepted','en_route_to_pickup','at_pickup','loaded','en_route_to_delivery','at_delivery')
left join public.loads dl on dl.id = d.load_id
where t.unit_number = 'T-112';


-- ############################################################################
-- BLOCK 5 -- UNRESOLVED-CARRIER-RECORD CHECK (rules out CARRIER_UNRESOLVED)
-- Only relevant if BLOCK 1's carrier_resolution = 'unresolved'.
-- unresolved_carrier_records is generic (record_type + record_id), not a
-- direct FK to loads -- for record_type = 'load', record_id IS the load id.
-- ############################################################################
select r.*
from public.unresolved_carrier_records r
where r.record_type = 'load'
  and r.record_id = (select id from public.loads where load_number = 'LD-100035');
