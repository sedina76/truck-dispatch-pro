-- Read-only diagnostic for LD-100023's mileage discrepancy (1200 entered
-- at booking vs. 1189.8 shown on New Dispatch). NO writes anywhere in
-- this script -- safe to run against production at any time, no
-- transaction/rollback needed, and LD-100023 itself is NOT modified.
--
-- WHY THIS SCRIPT EXISTS, not a direct repair: full code-path discovery
-- (see 0115_mileage_concept_separation.sql's own header comment) found
-- that NOTHING in this codebase automatically recalculates or overwrites
-- loads.total_miles -- it is written only at booking (create_load_with_
-- stops()) and by the plain Edit Load form (updateLoad(), which submits
-- exactly whatever numeric value is typed into a plain input, unrounded).
-- The only way total_miles could now read differently than what was
-- originally entered is (a) a later manual edit, or (b) the value
-- actually stored at booking never having been 1200 to begin with (human
-- recall vs. what was truly submitted) -- and updateLoad()'s own
-- log_activity() call carries NO before/after value payload (a genuine,
-- separately-reported gap), so there is no stored diff to mechanically
-- distinguish these two cases. This script surfaces every piece of
-- evidence that DOES exist, so a human can make that judgment call --
-- this author has no live database access and cannot run it themselves.

-- 1. LD-100023's current stored values, across every mileage-adjacent
--    column that exists today (route_miles/actual_miles will only appear
--    once 0115 is applied -- omit those two lines if running this before
--    then).
select
  id,
  load_number,
  total_miles as contracted_miles_now,
  created_at,
  updated_at,
  (updated_at > created_at) as row_has_been_updated_since_creation,
  extract(epoch from (updated_at - created_at)) / 3600.0 as hours_between_creation_and_last_update
from public.loads
where load_number = 'LD-100023';
-- REVIEW: if updated_at is meaningfully later than created_at, SOMETHING
-- on this row was edited after booking (not necessarily total_miles
-- specifically -- this column-agnostic timestamp is the best available
-- signal given updateLoad()'s own logging gap). If updated_at equals (or
-- is within moments of) created_at, the row has likely never been
-- touched since booking, which would point toward explanation (b) above
-- (1189.8 was what was actually submitted, not a later change) rather
-- than (a).

-- 2. Every activity_logs entry for this specific load, in order --
--    action/timestamp/actor only (no diff payload exists for a plain
--    "updated" action, per the gap noted above, but the ACTION TYPE and
--    TIMING and ACTOR are still real, stored evidence).
select
  al.action,
  al.created_at,
  al.actor_id,
  p.full_name as actor_name,
  al.changes
from public.activity_logs al
join public.loads l on l.id = al.entity_id and al.entity_type = 'load'
left join public.profiles p on p.id = al.actor_id
where l.load_number = 'LD-100023'
order by al.created_at;
-- REVIEW: an "updated" entry with a timestamp AFTER "created" tells you
-- WHEN and WHO edited this load at least once -- it does not, by itself,
-- prove the edit touched total_miles specifically (this action type
-- carries no column-level diff). If a "load_number_changed"-style entry
-- (0114's own richer logging pattern) existed for total_miles the same
-- way it does for load_number, this question would already be answered
-- mechanically -- it does not yet, which is exactly the gap reported
-- alongside this script.

-- 3. Any dispatch(es) for this load, and whatever route-calculated
--    distance already exists for them (dispatch_route_intelligence,
--    0060) -- a genuinely different, CURRENT-LEG-remaining-distance
--    quantity, but worth seeing alongside the booked figure for context,
--    and useful once 0115's route_miles exists to compare against.
select
  d.id as dispatch_id,
  d.status as dispatch_status,
  d.dispatched_at,
  dri.target_stop_id,
  dri.route_distance_meters,
  round((dri.route_distance_meters / 1609.344)::numeric, 1) as route_distance_miles_current_leg_only,
  dri.initial_distance_meters,
  round((dri.initial_distance_meters / 1609.344)::numeric, 1) as initial_distance_miles_current_leg_only,
  dri.calculated_at,
  dri.calculation_status
from public.dispatches d
join public.loads l on l.id = d.load_id
left join public.dispatch_route_intelligence dri on dri.dispatch_id = d.id
where l.load_number = 'LD-100023'
order by d.dispatched_at;
-- REVIEW: route_distance_meters/initial_distance_meters here are the
-- CURRENT LEG (truck position -> next stop), not a full pickup-to-
-- delivery distance -- do not treat either as directly comparable to the
-- 1189.8 figure without accounting for that. If this load has never had
-- a dispatch, or the dispatch has never had a GPS ping / "Refresh ETA"
-- call, this will return no rows or all-null route columns -- expected,
-- not an error.

-- 4. Where the request itself might still be recoverable: this script
--    cannot inspect application/hosting request logs (outside the
--    database entirely, and this author has no access to them) -- if
--    your hosting platform retains server-action/request logs covering
--    the load's created_at timestamp, that is the most direct remaining
--    source of "what was actually submitted," independent of anything
--    the database itself can show.
