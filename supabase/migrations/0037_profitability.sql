-- =============================================================================
-- 0037_profitability.sql
-- Profitability & Load Margin module. Inspected first (per instructions):
-- loads, dispatches, invoices, invoice_line_items, expenses, fuel_logs,
-- carriers, drivers, settlements, settlement_line_items, driver_settlements,
-- driver_settlement_items, driver_pay_rates, load_stops, brokers, customers.
--
-- KEY SCHEMA FINDINGS THAT SHAPE THIS DESIGN:
--
-- 1. expenses/fuel_logs have NO load_id or dispatch_id column -- only
--    carrier_id/truck_id/driver_id. There is no reliable way to attribute
--    an expense row to one specific load with the current schema. Per
--    instructions ("report that limitation rather than inventing
--    attribution"), other_direct_cost is returned as NULL (not 0) on every
--    row -- never guessed via truck/date-range heuristics, never silently
--    zeroed. total_direct_cost uses coalesce(other_direct_cost, 0) only
--    for the arithmetic, so a real transportation cost isn't nulled out by
--    an always-missing category, but other_direct_cost itself stays
--    honestly NULL. This limitation is also called out in the chat report.
--
-- 2. dispatches always carries both carrier_id and driver_id (both NOT
--    NULL) -- the schema does not structurally distinguish "outsourced to
--    a carrier" from "run by a company driver" at the dispatch level.
--    driver_pay_rates (0031) is the deliberate opt-in signal: staff only
--    create a pay-rate row for a driver they intend to pay via Driver
--    Settlement. Absent that row, a dispatch defaults to the carrier path
--    (dispatches.carrier_net_amount is always populated once a dispatch
--    exists -- computed by the pre-existing sync_dispatch_financials()
--    trigger, 0009). This mirrors exactly how the Carrier/Driver Settlement
--    modules already coexist: both are opt-in, and "never both" is a
--    business-process expectation, not a DB constraint, on either side.
--
-- 3. Canonical revenue: invoices.subtotal_amount - discount_amount for the
--    most recent non-void invoice on the load, when one exists (tax is
--    excluded -- it isn't company revenue). This is the actual billed
--    amount, independent of any later edit to loads.rate (invoice line
--    items are stored values, never a live re-read of the load). Before an
--    invoice exists, loads.rate is used as an explicit ESTIMATE only.
--
-- 4. Canonical transportation cost, in priority order (never both carrier
--    and driver cost for the same load -- see finding #2):
--      a. Non-void, finalized (approved/partially_paid/paid) Carrier
--         Settlement load_pay line -- sli.carrier_rate. COMPLETE.
--      b. Non-void, finalized Driver Settlement item -- dsi.gross_pay.
--         COMPLETE.
--      c. driver_pay_rates exists for this driver as of the delivery date
--         -- calculate_driver_load_pay() (0031, reused verbatim, not
--         reimplemented). ESTIMATED.
--      d. dispatches.carrier_net_amount, if a dispatch exists. ESTIMATED.
--      e. Otherwise NULL -- MISSING_COST. Never coerced to $0.
--    Advances are never added: carrier_rate/gross_pay are the settlement's
--    own gross load-pay snapshot columns, already exclusive of the
--    advances/deductions/quick-pay buckets tracked separately on
--    settlements/driver_settlements (0031/0033) -- summing them in here
--    would double count exactly what those buckets already represent.
--
-- 5. Historical stability: every COMPLETE-status figure is read from an
--    already-frozen settlement snapshot column (sli.carrier_rate /
--    dsi.gross_pay -- both documented as frozen-at-add-time in their own
--    migrations). Nothing here re-reads a carrier's current rate, a
--    driver's current pay rate, or live load_stops for a load whose cost
--    is already finalized. ESTIMATED rows are explicitly, visibly
--    estimates (profitability_status says so) precisely because they DO
--    still move if the source data changes before a settlement exists.
--
-- 6. Void handling: every settlement/driver_settlement join filters
--    status in ('approved','partially_paid','paid') -- void and draft
--    rows are excluded, matching the same finalized-status convention
--    fixed into get_carrier_settlement_summary in 0035/0036. `distinct on`
--    picks the single most recent matching line per load, so a voided-
--    and-replaced settlement's old row can never be counted alongside its
--    replacement.
--
-- ONE canonical function, get_load_profitability(), is the sole source of
-- per-load truth. Every aggregation function below (by broker/customer/
-- carrier/driver/lane/period) selects FROM it and only adds a GROUP BY --
-- none of them reimplement the revenue/cost/margin formulas. All are
-- LANGUAGE SQL, none SECURITY DEFINER -- run under the caller's own RLS on
-- loads/dispatches/invoices/settlements/etc, so cross-org data is
-- impossible to leak, matching every canonical RPC already in this
-- codebase (get_ar_invoices, get_payable_carrier_loads, etc).
-- =============================================================================

create type public.profitability_status as enum (
  'COMPLETE', 'ESTIMATED', 'MISSING_COST', 'MISSING_REVENUE', 'NOT_DELIVERED'
);

-- ---------------------------------------------------------------------------
-- get_load_profitability: THE canonical per-load profitability source.
-- p_load_id null returns every load in the caller's org (RLS-scoped); a
-- specific id returns just that one row -- same function serves Load
-- Detail (one row) and Reports/Dashboard (full set), so there is never a
-- second, competing calculation and never an N+1 per-load RPC loop.
-- ---------------------------------------------------------------------------
create or replace function public.get_load_profitability(p_load_id uuid default null)
returns table (
  load_id uuid,
  load_number text,
  organization_id uuid,
  delivery_date date,
  load_status public.load_status,
  broker_id uuid,
  customer_id uuid,
  carrier_id uuid,
  driver_id uuid,
  origin_city text,
  origin_state text,
  destination_city text,
  destination_state text,
  miles numeric,
  revenue numeric,
  revenue_source text,
  carrier_cost numeric,
  driver_cost numeric,
  transportation_cost numeric,
  transportation_cost_source text,
  other_direct_cost numeric,
  total_direct_cost numeric,
  gross_profit numeric,
  margin_percent numeric,
  revenue_per_mile numeric,
  cost_per_mile numeric,
  profit_per_mile numeric,
  profitability_status public.profitability_status
)
language sql
stable
as $$
  with base as (
    select l.id as load_id, l.load_number, l.organization_id, l.status as load_status,
           l.broker_id, l.customer_id, l.total_miles as miles, l.rate as booked_rate
    from public.loads l
    where p_load_id is null or l.id = p_load_id
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as origin_city,
           max(state) filter (where stop_type = 'pickup') as origin_state,
           max(city) filter (where stop_type = 'delivery') as destination_city,
           max(state) filter (where stop_type = 'delivery') as destination_state
    from public.load_stops
    where load_id in (select load_id from base)
    group by load_id
  ),
  -- canonical assignment for a load: most recent dispatch (mirrors
  -- calculate_carrier_load_settlement's own `order by dispatched_at desc
  -- limit 1` convention, 0033).
  disp as (
    select distinct on (load_id)
      load_id, id as dispatch_id, carrier_id, driver_id, carrier_net_amount,
      coalesce(completed_at, dispatched_at)::date as delivery_date
    from public.dispatches
    where load_id in (select load_id from base)
    order by load_id, dispatched_at desc
  ),
  inv as (
    select distinct on (load_id)
      load_id, (subtotal_amount - discount_amount) as invoice_revenue
    from public.invoices
    where load_id in (select load_id from base) and status <> 'void'
    order by load_id, issue_date desc, created_at desc
  ),
  carrier_finalized as (
    select distinct on (sli.load_id)
      sli.load_id, sli.carrier_rate as cost
    from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where sli.item_type = 'load_pay'
      and sli.load_id in (select load_id from base)
      and s.status in ('approved', 'partially_paid', 'paid')
    order by sli.load_id, sli.created_at desc
  ),
  driver_finalized as (
    select distinct on (dsi.load_id)
      dsi.load_id, dsi.gross_pay as cost
    from public.driver_settlement_items dsi
    join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
    where dsi.load_id in (select load_id from base)
      and ds.status in ('approved', 'partially_paid', 'paid')
    order by dsi.load_id, dsi.created_at desc
  ),
  -- opt-in signal: a driver only has a driver_pay_rates row if staff mean
  -- to pay them via Driver Settlement (finding #2 above).
  rated_drivers as (
    select distinct driver_id from public.driver_pay_rates
  ),
  driver_estimate as (
    select b.load_id, calc.gross_pay as cost
    from base b
    join disp d on d.load_id = b.load_id
    join rated_drivers rd on rd.driver_id = d.driver_id
    cross join lateral public.calculate_driver_load_pay(d.driver_id, b.load_id) calc
  ),
  resolved as (
    select
      b.load_id,
      d.delivery_date,
      d.carrier_id,
      d.driver_id,
      coalesce(inv.invoice_revenue, b.booked_rate) as revenue,
      case when inv.invoice_revenue is not null then 'invoice'
           when b.booked_rate is not null and b.booked_rate <> 0 then 'load_rate_estimated'
           else null end as revenue_source,
      cf.cost as carrier_finalized_cost,
      df.cost as driver_finalized_cost,
      de.cost as driver_estimate_cost,
      d.carrier_net_amount as carrier_estimate_cost
    from base b
    left join disp d on d.load_id = b.load_id
    left join inv on inv.load_id = b.load_id
    left join carrier_finalized cf on cf.load_id = b.load_id
    left join driver_finalized df on df.load_id = b.load_id
    left join driver_estimate de on de.load_id = b.load_id
  )
  select
    b.load_id, b.load_number, b.organization_id,
    r.delivery_date, b.load_status, b.broker_id, b.customer_id,
    r.carrier_id, r.driver_id,
    st.origin_city, st.origin_state, st.destination_city, st.destination_state,
    b.miles,
    r.revenue, r.revenue_source,
    case when r.carrier_finalized_cost is not null then r.carrier_finalized_cost
         when r.driver_finalized_cost is null and r.driver_estimate_cost is null and r.carrier_estimate_cost is not null then r.carrier_estimate_cost
         else 0 end as carrier_cost,
    case when r.driver_finalized_cost is not null then r.driver_finalized_cost
         when r.carrier_finalized_cost is null and r.driver_estimate_cost is not null then r.driver_estimate_cost
         else 0 end as driver_cost,
    coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) as transportation_cost,
    case when r.carrier_finalized_cost is not null then 'carrier_settlement_finalized'
         when r.driver_finalized_cost is not null then 'driver_settlement_finalized'
         when r.driver_estimate_cost is not null then 'driver_pay_estimated'
         when r.carrier_estimate_cost is not null then 'carrier_dispatch_estimated'
         else null end as transportation_cost_source,
    null::numeric as other_direct_cost,
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + 0 end as total_direct_cost,
    case when r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) end as gross_profit,
    case when r.revenue is null or r.revenue = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost)) / r.revenue * 100, 6) end as margin_percent,
    case when b.miles is null or b.miles = 0 or r.revenue is null then null else round(r.revenue / b.miles, 4) end as revenue_per_mile,
    case when b.miles is null or b.miles = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round(coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) / b.miles, 4) end as cost_per_mile,
    case when b.miles is null or b.miles = 0 or r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost)) / b.miles, 4) end as profit_per_mile,
    case
      when b.load_status not in ('delivered', 'pod_received', 'invoiced', 'closed') then 'NOT_DELIVERED'
      when r.revenue is null then 'MISSING_REVENUE'
      when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then 'MISSING_COST'
      when r.revenue_source = 'invoice' and (r.carrier_finalized_cost is not null or r.driver_finalized_cost is not null) then 'COMPLETE'
      else 'ESTIMATED'
    end::public.profitability_status as profitability_status
  from base b
  left join stops st on st.load_id = b.load_id
  left join resolved r on r.load_id = b.load_id;
$$;

grant execute on function public.get_load_profitability(uuid) to authenticated;

comment on function public.get_load_profitability(uuid) is
  'Canonical, sole source of load-level profitability. Every page (Load Detail, Broker/Customer/Carrier/Driver profiles, Reports, Dashboard) reads from this function or from one of the get_profitability_by_*() aggregations below -- never a second, independently-written revenue/cost/margin calculation.';

-- ---------------------------------------------------------------------------
-- Aggregations. Every one of these selects FROM get_load_profitability(null)
-- and only adds a GROUP BY / filter -- none recomputes revenue, cost, or
-- margin. NOT_DELIVERED rows are excluded from every aggregation (nothing
-- to aggregate yet); everything else (COMPLETE/ESTIMATED/MISSING_*) is
-- included so a MISSING_COST load still counts toward load/revenue totals
-- without silently contributing a wrong-but-plausible cost number.
-- ---------------------------------------------------------------------------
create or replace function public.get_profitability_summary(p_period_start date default null, p_period_end date default null)
returns table (
  load_count bigint,
  complete_count bigint,
  estimated_count bigint,
  missing_cost_count bigint,
  missing_revenue_count bigint,
  total_revenue numeric,
  total_transportation_cost numeric,
  total_gross_profit numeric,
  avg_margin_percent numeric,
  total_miles numeric,
  avg_revenue_per_mile numeric,
  avg_profit_per_mile numeric
)
language sql
stable
as $$
  select
    count(*)::bigint,
    count(*) filter (where profitability_status = 'COMPLETE')::bigint,
    count(*) filter (where profitability_status = 'ESTIMATED')::bigint,
    count(*) filter (where profitability_status = 'MISSING_COST')::bigint,
    count(*) filter (where profitability_status = 'MISSING_REVENUE')::bigint,
    coalesce(sum(revenue), 0),
    coalesce(sum(transportation_cost), 0),
    coalesce(sum(gross_profit), 0),
    case when sum(revenue) is not null and sum(revenue) <> 0
      then round(sum(gross_profit) / sum(revenue) * 100, 6) else null end,
    coalesce(sum(miles), 0),
    case when sum(miles) > 0 then round(sum(revenue) / sum(miles), 4) else null end,
    case when sum(miles) > 0 and sum(gross_profit) is not null then round(sum(gross_profit) / sum(miles), 4) else null end
  from public.get_load_profitability(null)
  where profitability_status <> 'NOT_DELIVERED'
    and (p_period_start is null or delivery_date >= p_period_start)
    and (p_period_end is null or delivery_date <= p_period_end);
$$;

grant execute on function public.get_profitability_summary(date, date) to authenticated;

create or replace function public.get_profitability_by_broker(p_period_start date default null, p_period_end date default null)
returns table (
  broker_id uuid, broker_name text, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select lp.broker_id, b.company_name, count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  left join public.brokers b on b.id = lp.broker_id
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.broker_id is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.broker_id, b.company_name
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_broker(date, date) to authenticated;

create or replace function public.get_profitability_by_customer(p_period_start date default null, p_period_end date default null)
returns table (
  customer_id uuid, customer_name text, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select lp.customer_id, c.company_name, count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  left join public.customers c on c.id = lp.customer_id
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.customer_id is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.customer_id, c.company_name
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_customer(date, date) to authenticated;

create or replace function public.get_profitability_by_carrier(p_period_start date default null, p_period_end date default null)
returns table (
  carrier_id uuid, carrier_name text, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select lp.carrier_id, c.legal_name, count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  left join public.carriers c on c.id = lp.carrier_id
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.carrier_id is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.carrier_id, c.legal_name
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_carrier(date, date) to authenticated;

-- Staff-only (internal reporting/report pages under (app), never the
-- Driver Portal) -- commercial margin data must not reach drivers.
create or replace function public.get_profitability_by_driver(p_period_start date default null, p_period_end date default null)
returns table (
  driver_id uuid, driver_name text, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select lp.driver_id, trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')), count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  left join public.drivers d on d.id = lp.driver_id
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.driver_id is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.driver_id, d.first_name, d.last_name
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_driver(date, date) to authenticated;

create or replace function public.get_profitability_by_lane(p_period_start date default null, p_period_end date default null)
returns table (
  origin_city text, origin_state text, destination_city text, destination_state text,
  load_count bigint, total_revenue numeric, total_transportation_cost numeric,
  total_gross_profit numeric, avg_margin_percent numeric, avg_revenue_per_mile numeric
)
language sql
stable
as $$
  select lp.origin_city, lp.origin_state, lp.destination_city, lp.destination_state, count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end,
    case when sum(lp.miles) > 0 then round(sum(lp.revenue) / sum(lp.miles), 4) else null end
  from public.get_load_profitability(null) lp
  where lp.profitability_status <> 'NOT_DELIVERED'
    and lp.origin_city is not null and lp.destination_city is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by lp.origin_city, lp.origin_state, lp.destination_city, lp.destination_state
  order by sum(lp.gross_profit) desc nulls last;
$$;

grant execute on function public.get_profitability_by_lane(date, date) to authenticated;

-- p_granularity: 'day' | 'week' | 'month' (validated -- anything else
-- falls back to 'month' rather than raising, since this only ever feeds a
-- date_trunc call).
create or replace function public.get_profitability_by_period(p_granularity text default 'month', p_period_start date default null, p_period_end date default null)
returns table (
  period_start date, load_count bigint, total_revenue numeric,
  total_transportation_cost numeric, total_gross_profit numeric, avg_margin_percent numeric
)
language sql
stable
as $$
  select date_trunc(case when p_granularity in ('day', 'week', 'month') then p_granularity else 'month' end, lp.delivery_date)::date,
    count(*)::bigint,
    coalesce(sum(lp.revenue), 0), coalesce(sum(lp.transportation_cost), 0), coalesce(sum(lp.gross_profit), 0),
    case when sum(lp.revenue) <> 0 then round(sum(lp.gross_profit) / sum(lp.revenue) * 100, 6) else null end
  from public.get_load_profitability(null) lp
  where lp.profitability_status <> 'NOT_DELIVERED' and lp.delivery_date is not null
    and (p_period_start is null or lp.delivery_date >= p_period_start)
    and (p_period_end is null or lp.delivery_date <= p_period_end)
  group by 1
  order by 1 desc;
$$;

grant execute on function public.get_profitability_by_period(text, date, date) to authenticated;
