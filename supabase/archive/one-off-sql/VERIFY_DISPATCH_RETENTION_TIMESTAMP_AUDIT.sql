-- Read-only diagnostic: dispatches currently in a delivered/completed/
-- cancelled status whose own operational timestamp (delivered_at /
-- cancelled_at, 0057_dispatch_board_upgrade.sql) is missing. NO writes
-- anywhere in this script -- safe to run against production at any time.
--
-- WHY THIS MATTERS for the completed-dispatch retention workflow: the
-- Dispatch Board's 24-hour retention rule (board-retention.ts) FAILS OPEN
-- when this timestamp is null -- such a row is never hidden by the
-- default board, exactly per instruction ("must not disappear
-- immediately through an invented backfill"). This script exists purely
-- to find and report how many such rows currently exist, and why, so a
-- human can decide whether a deliberate, individually-reviewed repair
-- (matching 0080_dispatch_ops_delivered_and_messaging.sql's own Part A2
-- precedent -- checked stop timestamps, checked activity-log provenance,
-- fell back to updated_at only when neither existed, applied per row
-- after individual review) is warranted. No number here is backfilled by
-- this script itself.
--
-- ROOT CAUSE, confirmed by code audit, of any rows found here dated AFTER
-- 0080 was applied: src/app/driver-portal/actions.ts's
-- updateMyDispatchStatus() -- the action a DRIVER uses to mark their own
-- trip Delivered from the Driver Portal -- never called
-- computeOperationalTimestampUpdates() (src/lib/dispatch/operational-
-- timestamps.ts), unlike the two staff-facing paths
-- (updateDispatchBoardStatus() and updateDispatch()), which both already
-- did. Fixed going forward as part of this same phase; this script finds
-- whatever the gap already produced historically.

-- 1. Every dispatch currently missing its own terminal-status timestamp.
select
  d.id as dispatch_id,
  d.organization_id,
  o.name as organization_name,
  l.load_number,
  d.status,
  d.delivered_at,
  d.cancelled_at,
  d.dispatched_at,
  d.updated_at,
  d.created_at,
  round(extract(epoch from (d.updated_at - d.dispatched_at)) / 3600.0, 1) as hours_between_dispatched_and_last_update
from public.dispatches d
join public.organizations o on o.id = d.organization_id
join public.loads l on l.id = d.load_id
where (d.status in ('delivered', 'completed') and d.delivered_at is null)
   or (d.status = 'cancelled' and d.cancelled_at is null)
order by d.updated_at desc;
-- REVIEW: each row here is CURRENTLY always shown on the active board
-- (fail-open), regardless of how old it is -- confirm that's acceptable
-- for these specific rows, or individually investigate/repair per row
-- (final delivery stop arrived_at/departed_at, then activity_logs
-- provenance, then updated_at as a last resort -- 0080's own vetted
-- priority order) rather than a blanket backfill.

-- 2. For each row above, whether load_stops has a real, recorded
--    delivery-stop departure (Priority 1 in 0080's own repair order) --
--    the most trustworthy alternative to delivered_at/cancelled_at, if
--    available, checked here rather than assumed.
select
  d.id as dispatch_id,
  l.load_number,
  ls.stop_type,
  ls.arrived_at,
  ls.departed_at
from public.dispatches d
join public.loads l on l.id = d.load_id
join public.load_stops ls on ls.load_id = d.load_id and ls.stop_type = 'delivery'
where (d.status in ('delivered', 'completed') and d.delivered_at is null)
order by d.id, ls.stop_sequence desc;

-- 3. For each row from section 1, the most recent activity_logs entry
--    naming a status change to delivered/completed/cancelled (Priority 2
--    in 0080's own repair order) -- some rows may have this even though
--    the dedicated timestamp column doesn't (e.g. updateDispatchBoardStatus()
--    already logs {field:'status', new_value:...} on every move).
select
  al.entity_id as dispatch_id,
  al.action,
  al.changes,
  al.created_at as logged_at
from public.activity_logs al
where al.entity_type = 'dispatch'
  and al.entity_id in (
    select d.id from public.dispatches d
    where (d.status in ('delivered', 'completed') and d.delivered_at is null)
       or (d.status = 'cancelled' and d.cancelled_at is null)
  )
order by al.entity_id, al.created_at desc;
