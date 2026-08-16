-- Concurrency backstop for dispatch assignment conflicts. checkAssignment
-- Conflicts() (src/app/(app)/dispatch/actions.ts) is a SELECT-then-INSERT
-- check -- correct for the common case, but not atomic: two dispatchers
-- submitting for the same driver/truck/trailer at nearly the same moment
-- can both pass that SELECT before either INSERT lands. These partial
-- unique indexes make "at most one active dispatch per driver/truck/
-- trailer" a real, race-proof database guarantee, so exactly one of the
-- two concurrent inserts/updates can ever succeed. The status list must
-- stay in sync with ACTIVE_DISPATCH_STATUSES in actions.ts.
--
-- The application never relies on the raw unique_violation this produces
-- for its user-facing message -- src/lib/dispatch/errors.ts recognizes
-- these specific index names and re-derives the same friendly "already on
-- an active dispatch" message checkAssignmentConflicts() would have given,
-- by looking up the row that won the race.
create unique index if not exists dispatches_active_driver_unique
  on public.dispatches (driver_id)
  where status in ('assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded', 'en_route_to_delivery', 'at_delivery');

create unique index if not exists dispatches_active_truck_unique
  on public.dispatches (truck_id)
  where status in ('assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded', 'en_route_to_delivery', 'at_delivery');

create unique index if not exists dispatches_active_trailer_unique
  on public.dispatches (trailer_id)
  where trailer_id is not null
    and status in ('assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded', 'en_route_to_delivery', 'at_delivery');
