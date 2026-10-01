-- ============================================================================
-- VERIFY_FUEL_DRIVER_CARRIER_MISMATCH.sql
--
-- Finds historical fuel_logs whose "who purchased" driver belongs to a
-- DIFFERENT carrier than the truck it was logged against
-- (drivers.carrier_id <> trucks.carrier_id). This is the same-org but
-- wrong-carrier combination the fuel-form repair now blocks going forward.
--
-- 100% READ-ONLY. SELECT only. No INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / GRANT / REVOKE, no transaction. Safe on production.
-- MODIFIES NOTHING. This only produces a list for review -- historical
-- fuel logs are never rewritten by this repair, and updateFuelLog() only
-- re-checks alignment when driver_id itself changes, so these rows stay
-- editable for their other fields.
-- ============================================================================


-- ############################################################################
-- RESULT 1 -- SUMMARY: how many purchaser-driver / truck-carrier mismatches
-- ############################################################################
select
  count(*)                                                   as total_fuel_logs,
  count(*) filter (where fl.driver_id is not null)           as with_purchaser_driver,
  count(*) filter (
    where fl.driver_id is not null
      and d.carrier_id is distinct from t.carrier_id
  )                                                          as purchaser_driver_carrier_mismatch,
  count(*) filter (
    where fl.driver_id is not null
      and d.carrier_id is distinct from t.carrier_id
      and (fl.expense_id is not null or fl.recovered_amount > 0)
  )                                                          as mismatch_with_money_attached
from public.fuel_logs fl
left join public.trucks t  on t.id = fl.truck_id
left join public.drivers d on d.id = fl.driver_id;


-- ############################################################################
-- RESULT 2 -- FULL LIST of purchaser-driver / truck-carrier mismatches
-- (blast-radius detail -- review, do not modify)
-- ############################################################################
select
  fl.id                                as fuel_log_id,
  fl.organization_id,
  o.name                               as organization_name,
  fl.purchased_at,
  fl.total_amount,
  t.unit_number                        as truck,
  tc.legal_name                        as truck_carrier,
  (d.first_name || ' ' || d.last_name) as purchaser_driver,
  dc.legal_name                        as driver_carrier,
  fl.paid_by,
  fl.recovery_type,
  fl.recovered_amount,
  (fl.expense_id is not null or fl.recovered_amount > 0) as has_money_attached
from public.fuel_logs fl
join public.trucks   t  on t.id = fl.truck_id
join public.drivers  d  on d.id = fl.driver_id
left join public.carriers tc on tc.id = t.carrier_id
left join public.carriers dc on dc.id = d.carrier_id
where fl.driver_id is not null
  and d.carrier_id is distinct from t.carrier_id
order by has_money_attached desc, fl.purchased_at desc;
-- INTERPRETATION:
--   * has_money_attached = false  -> low risk. The mismatch is attribution
--     noise only; fl.carrier_id (DB-derived from the truck) and every
--     downstream expense/recovery already follow the TRUCK's carrier, not
--     the driver's. Fixing driver_id is optional cleanup.
--   * has_money_attached = true   -> review individually. Still: fl.carrier_id
--     and the linked expense/settlement follow the truck's carrier
--     (guard_fuel_log_org derives carrier_id from trucks, never from
--     driver_id), so the FINANCIAL attribution is already correct -- the
--     driver_id is a reporting label out of step with it. No automatic fix.


-- ############################################################################
-- RESULT 3 -- Responsible-driver (recovery) vs truck carrier -- INFORMATIONAL
-- responsible_driver_id is INTENTIONALLY org-wide (payment-responsibility-
-- fields.tsx design comment) -- a difference here is NOT a defect, listed
-- only so the picture is complete.
-- ############################################################################
select
  fl.id                                as fuel_log_id,
  fl.recovery_type,
  fl.recoverable_amount,
  t.unit_number                        as truck,
  tc.legal_name                        as truck_carrier,
  (rd.first_name || ' ' || rd.last_name) as responsible_driver,
  rdc.legal_name                       as responsible_driver_carrier
from public.fuel_logs fl
join public.trucks t on t.id = fl.truck_id
join public.drivers rd on rd.id = fl.responsible_driver_id
left join public.carriers tc  on tc.id = t.carrier_id
left join public.carriers rdc on rdc.id = rd.carrier_id
where fl.responsible_driver_id is not null
  and rd.carrier_id is distinct from t.carrier_id
order by fl.purchased_at desc;


-- ############################################################################
-- RESULT 4 -- Test-fixture drivers visible in the org (flag only -- do NOT
-- delete, do NOT name-filter in the app; the carrier filter removes them
-- from a truck naturally when their carrier differs)
-- ############################################################################
select
  d.id,
  d.organization_id,
  (d.first_name || ' ' || d.last_name) as driver_name,
  d.status,
  c.legal_name                         as carrier,
  (select count(*) from public.fuel_logs f where f.driver_id = d.id) as fuel_logs_as_purchaser
from public.drivers d
left join public.carriers c on c.id = d.carrier_id
where d.first_name ilike 'zzz%' or d.last_name ilike 'zzz%'
   or d.first_name ilike '%test%' or d.last_name ilike '%test%'
order by d.organization_id, driver_name;
