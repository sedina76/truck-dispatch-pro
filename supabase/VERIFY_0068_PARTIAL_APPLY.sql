-- =============================================================================
-- VERIFY_0068_PARTIAL_APPLY.sql
-- READ-ONLY. Run this in the Supabase SQL editor BEFORE re-applying the
-- repaired 0068_financial_function_cutover.sql, to confirm the live
-- database's actual state after the first attempt's mid-file 42P13
-- failure. Nothing here modifies data or schema.
--
-- Background: Postgres's simple query protocol treats a single
-- semicolon-separated multi-statement script as one implicit transaction
-- -- this exact codebase already documented this behavior firsthand in
-- 0036_carrier_settlements_dependency_fix.sql's header, when 0035 "silently
-- failed to apply as a whole." If 0068 was run the same way (the whole
-- file pasted/sent as one script), the failure on
-- calculate_carrier_load_settlement (statement 7 of 8 in the file, AFTER
-- the six 0067 mirror-trigger DROPs) should have rolled the entire file
-- back, including those drops. This file exists to CONFIRM that rather
-- than assume it.
-- =============================================================================

-- 1. Did any 0068 mirror-trigger drops survive? Expect all 7 rows present.
--    Any missing row = that specific 0067 mirror trigger is gone and the
--    repaired 0068 must NOT try to drop it again (already gone), and the
--    corresponding extension table has been writer-only (app code) since
--    the moment it disappeared.
select tgname, tgrelid::regclass as table_name, tgenabled
from pg_trigger
where tgname in (
  'loads_mirror_financials',
  'dispatches_mirror_financials',
  'dispatches_mirror_internal_notes',
  'carriers_mirror_financials',
  'customers_mirror_financials',
  'brokers_mirror_financials',
  'drivers_mirror_compensation'
)
order by tgname;

-- 2. Did the per-dispatch sync trigger get swapped? Expect
--    dispatches_sync_financials PRESENT and dispatch_financials_sync
--    ABSENT if 0068 fully rolled back (i.e. 0068's writer cutover has not
--    landed at all yet).
select tgname, tgrelid::regclass as table_name
from pg_trigger
where tgname in ('dispatches_sync_financials', 'dispatch_financials_sync');

-- 3. Live return signature of the function that actually failed. Expect
--    the 0036 14-column shape (dispatch_id, load_number, delivery_date,
--    miles, customer_revenue, carrier_rate, gross_margin, margin_percent,
--    driver_name, truck_unit, pickup_city, pickup_state, delivery_city,
--    delivery_state) -- NOT the attempted 10-column shape. If this comes
--    back 10-column, some other process applied a partial/different
--    version and the repaired file's assumptions need re-checking before
--    proceeding.
select pg_get_function_result(oid) as return_type
from pg_proc
where proname = 'calculate_carrier_load_settlement';

-- 4. Live return signatures of the other three functions 0068 touches,
--    to confirm none of them partially landed in some intermediate state.
select proname, pg_get_function_result(oid) as return_type
from pg_proc
where proname in ('get_load_profitability', 'calculate_driver_load_pay', 'get_ready_to_bill_loads')
order by proname;

-- 5. auto_generate_invoice_from_delivered_load(): did the 0068 rewrite
--    (reads load_financials/broker_financials/customer_financials) land,
--    or is it still the pre-0068 version (reads NEW.rate / brokers /
--    customers payment_terms_days directly)? Expect reads_old_column =
--    true, reads_extension_table = false if 0068 fully rolled back.
select prosrc ilike '%load_financials%' as reads_extension_table,
       prosrc ilike '%NEW.rate%' as reads_old_column
from pg_proc
where proname = 'auto_generate_invoice_from_delivered_load';

-- 6. create_load_with_stops(): does it already insert into
--    load_financials (0068's version), or only into loads.rate (pre-0068,
--    relying entirely on the loads_mirror_financials trigger from query 1
--    to backfill load_financials)? Expect false if 0068 fully rolled
--    back -- and if so, query 1's loads_mirror_financials row being
--    PRESENT is what's currently keeping load_financials correct for
--    every load created through the New Load form.
select prosrc ilike '%insert into public.load_financials%' as writes_extension_table
from pg_proc
where proname = 'create_load_with_stops';

-- 7. Sanity spot-check: any load_financials/dispatch_financials rows that
--    are out of sync with their base-table counterpart right now (would
--    indicate the mirror trigger stopped firing for some rows without
--    being fully dropped, e.g. it errored silently on a subset).
select l.id, l.rate as loads_rate, lf.rate as load_financials_rate
from public.loads l
join public.load_financials lf on lf.load_id = l.id
where l.rate is distinct from lf.rate
limit 20;
