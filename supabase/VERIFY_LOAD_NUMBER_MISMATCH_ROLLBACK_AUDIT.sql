-- Read-only audit: confirms the observed failed load-creation attempt(s)
-- (the deployment-order mismatch -- app code no longer sends
-- "load_number", but migration 0114 is not yet applied, so the live
-- (pre-0114) create_load_with_stops() body still tries to insert
-- p_load->>'load_number' verbatim, which is now NULL) left ZERO trace.
-- No writes anywhere in this script -- safe to run at any time, including
-- against production, with no transaction/rollback needed.
--
-- WHY THIS IS GUARANTEED, NOT JUST HOPED FOR (confirmed by re-reading the
-- exact LIVE function body in supabase/migrations/0068_financial_function_
-- cutover.sql, not a reconstruction):
--   1. The `insert into public.loads (...)` statement is the FIRST insert
--      in create_load_with_stops()'s body -- textually and
--      execution-order-wise before the load_financials insert and before
--      the load_stops loop.
--   2. loads.load_number is `text not null` (0004_operations.sql) with no
--      default. A NOT NULL violation means Postgres refuses to create the
--      row AT ALL -- not partially, not transiently. There is categorically
--      no such thing as "a loads row with a null load_number that then got
--      cleaned up" -- the row never existed for even an instant.
--   3. create_load_with_stops() has no `exception when ... then` handler
--      anywhere in its body (confirmed by inspection) -- an unhandled
--      exception aborts the ENTIRE function invocation immediately.
--      Since the loads insert is first, the load_financials insert and
--      the load_stops loop are never reached at all.
--   4. Each PostgREST RPC call (supabase.rpc(...)) is its own single,
--      autocommit transaction from the database's point of view -- an
--      aborted function invocation means that whole transaction rolls
--      back, full stop. There is nothing partially committed to find.
--
-- The queries below verify this holds in practice, not just in theory --
-- run them any time (before or after this specific incident) to confirm
-- no orphaned row of any of these three kinds exists in this database.

-- 1. Any loads row with a null or empty load_number should be impossible
--    given the NOT NULL constraint -- this is a belt-and-suspenders check
--    that the constraint itself hasn't somehow been weakened.
select count(*) as loads_with_null_or_empty_load_number
from public.loads
where load_number is null or load_number = '';
-- expect: 0

-- 2. Any load_financials row whose load_id does not correspond to an
--    existing loads row would be exactly the kind of orphan a partial,
--    non-atomic failure could leave behind -- confirms none exists.
select count(*) as orphaned_load_financials_rows
from public.load_financials lf
where not exists (select 1 from public.loads l where l.id = lf.load_id);
-- expect: 0

-- 3. Same check for load_stops.
select count(*) as orphaned_load_stops_rows
from public.load_stops ls
where not exists (select 1 from public.loads l where l.id = ls.load_id);
-- expect: 0

-- 4. For extra confidence, a direct timestamp-scoped look: any loads,
--    load_financials, or load_stops row created around the time of the
--    observed error (adjust the timestamp below to match your incident
--    window) -- expected to show either nothing at all from that failed
--    attempt, or only rows from OTHER, successful requests around the
--    same time (distinguishable by having a real, non-null load_number).
-- select * from public.loads where created_at between '<incident start>' and '<incident end>' order by created_at;
