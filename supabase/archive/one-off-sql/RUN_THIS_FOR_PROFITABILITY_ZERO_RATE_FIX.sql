-- =============================================================================
-- 0038_profitability_zero_rate_fix.sql
-- Bug found in the live Profitability test: a load with no invoice and
-- loads.rate = 0 (the column's own not-null default -- meaning "never
-- priced", not "genuinely free freight") resolved revenue to 0.00 instead
-- of NULL, via `coalesce(inv.invoice_revenue, b.booked_rate)`. A committed
-- $0.00 revenue is not null, so the profitability_status CASE's `when
-- r.revenue is null then 'MISSING_REVENUE'` branch never fired -- the row
-- fell through to ESTIMATED with $0.00 revenue displayed, misrepresenting
-- an unpriced load as a real, calculated (if small) profit/loss figure.
-- Confirmed live: TEST-PROF-MISSREV (rate 0, no invoice) returned
-- revenue=0.00, revenue_source=null, status=ESTIMATED instead of the
-- intended MISSING_REVENUE.
--
-- Fix: nullif(b.booked_rate, 0) before the coalesce, so a genuinely-unset
-- (0) load rate is treated the same as no rate at all -- consistent with
-- the same "never convert missing to $0" principle already applied to
-- transportation cost. A load actually priced at a nonzero rate is
-- unaffected; only the true edge case (rate never entered) changes.
-- create or replace of the existing 0037 function only -- same signature,
-- no schema change.
-- =============================================================================

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
      coalesce(inv.invoice_revenue, nullif(b.booked_rate, 0)) as revenue,
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
