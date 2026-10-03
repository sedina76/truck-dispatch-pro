-- Read-only, organization-wide audit: candidate loads where manual
-- (contracted) and routed mileage MAY have been conflated. NO writes
-- anywhere in this script -- safe to run at any time.
--
-- HONEST SCOPE LIMITS, stated up front rather than overclaiming
-- precision: this codebase has no route-calculation feature that
-- populates a stable, full pickup-to-delivery distance yet (0115 adds the
-- route_miles COLUMN; nothing populates it in this phase -- see that
-- migration's own header comment). The only calculated-distance data that
-- exists anywhere today is dispatch_route_intelligence (0060), and it is
-- a CURRENT-LEG-remaining-distance snapshot tied to a dispatch's live GPS
-- tracking, not a stable planned total -- comparing it to total_miles is
-- therefore only a rough sanity signal, never proof of conflation, and
-- says nothing at all about a load with no dispatch or no GPS data yet.
-- Section 2 below is a second, even weaker, purely-timing-based signal
-- for exactly that reason -- both sections are candidates for human
-- review, not a definitive list.

-- 1. Loads with dispatch_route_intelligence data whose CURRENT-LEG
--    distance disagrees substantially with total_miles. A real
--    disagreement here does NOT by itself prove total_miles is wrong --
--    a truck partway through a multi-stop route, or already past its
--    origin, will show a current-leg distance smaller than the full
--    trip's total_miles by design (this is remaining distance, not total
--    distance) -- so this section is explicitly a SANITY CHECK LIST for a
--    human to review, not an automatic "these are wrong" verdict.
select
  l.organization_id,
  o.name as organization_name,
  l.load_number,
  l.total_miles as contracted_miles,
  round((dri.route_distance_meters / 1609.344)::numeric, 1) as route_distance_miles_current_leg_only,
  round(
    (l.total_miles - (dri.route_distance_meters / 1609.344))::numeric, 1
  ) as difference_contracted_minus_current_leg,
  dri.calculated_at as route_calculated_at,
  d.status as dispatch_status
from public.loads l
join public.dispatches d on d.load_id = l.id
join public.dispatch_route_intelligence dri on dri.dispatch_id = d.id
join public.organizations o on o.id = l.organization_id
where l.total_miles is not null
  and dri.route_distance_meters is not null
  -- Only flag a genuinely large gap -- 15% or 50 miles, whichever is
  -- larger -- to avoid drowning a real signal in routine "truck is
  -- partway through the trip" noise, which is expected and not a defect.
  and abs(l.total_miles - (dri.route_distance_meters / 1609.344)) > greatest(l.total_miles * 0.15, 50)
order by difference_contracted_minus_current_leg desc nulls last;

-- 2. Loads whose row has been updated well after creation, with a
--    contracted mileage value present -- a WEAK, column-agnostic proxy
--    for "this load may have been edited after booking" (updateLoad()'s
--    own activity log entry carries no before/after diff for any field,
--    total_miles included -- see 0115's own header comment and
--    VERIFY_LD100023_MILEAGE_AUDIT.sql for the same gap called out for
--    that specific load). This catches every kind of post-booking edit,
--    not specifically a mileage edit -- read it as "worth a manual
--    second look," never as a confirmed mileage change.
select
  l.organization_id,
  o.name as organization_name,
  l.load_number,
  l.total_miles as contracted_miles,
  l.created_at,
  l.updated_at,
  round(extract(epoch from (l.updated_at - l.created_at)) / 3600.0, 1) as hours_between_creation_and_last_update
from public.loads l
join public.organizations o on o.id = l.organization_id
where l.total_miles is not null
  and l.updated_at > l.created_at + interval '5 minutes'
order by l.updated_at desc
limit 200;
-- REVIEW: cap of 200 rows is deliberate -- this is meant as a starting
-- worklist for spot-checking, not an exhaustive report; widen or remove
-- the limit if you want the full list.
