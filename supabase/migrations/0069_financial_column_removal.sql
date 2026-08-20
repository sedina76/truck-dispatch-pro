-- =============================================================================
-- 0069_financial_column_removal.sql
-- Phase 2G.10: FINAL step of the financial-column-isolation cutover.
-- PROPOSED ONLY -- NOT APPLIED. Depends on 0067 (extension tables must
-- exist) and 0068 (reporting functions/writer cutover must already be
-- live -- this migration assumes application code has ALREADY been
-- deployed writing directly to the extension tables, per 2G.10's writer
-- cutover). Applying 0069 before that app-code deploy would make it
-- impossible to ever set a load rate, dispatch fee, carrier/customer/
-- broker terms, or driver pay again -- the columns those forms/actions
-- used to write would simply no longer exist.
--
-- WHAT THIS DOES:
--   1. Removes the transitional COALESCE(extension.field, base.field)
--      fallback from the four reporting functions 0068 redefined --
--      by this point the extension tables are the ONLY source being
--      written, so the fallback is dead code, and leaving it in would
--      itself be "a duplicate source of truth" reference even if it
--      never actually resolves to the old column anymore.
--   2. Drops the old sensitive columns from loads/dispatches/carriers/
--      customers/brokers/drivers.
--   3. Drops the now-orphaned mirror trigger FUNCTIONS from 0067 (their
--      triggers were already dropped in 0068; the function bodies
--      themselves were left in place until now in case 0068 needed to
--      be rolled back independently -- once 0069 runs, there is nothing
--      left for them to mirror FROM, so they're removed too) and the
--      superseded sync_dispatch_financials() (replaced by
--      sync_dispatch_financials_v2() in 0068, which operates on
--      dispatch_financials instead).
--
-- NOT done here: no historical value is recomputed. Every extension-table
-- row already holds the exact numeric value its parent column held at
-- 0067's backfill time (or whatever the writer cutover wrote since) --
-- dropping the old column merely removes the now-redundant duplicate, it
-- never changes what's stored in load_financials/dispatch_financials/etc.
-- NULL meaning is preserved identically (a NULL detention_rate/
-- layover_rate stays NULL in load_financials, exactly as it was on loads).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Final function redefinitions -- coalesce fallback removed, pure
-- extension-table reads. Everything else byte-for-byte identical to 0068.
-- ---------------------------------------------------------------------------

create or replace function public.get_ready_to_bill_loads()
returns table (
  load_id uuid,
  load_number text,
  status public.load_status,
  customer_id uuid,
  customer_name text,
  broker_id uuid,
  broker_name text,
  origin_city text,
  origin_state text,
  destination_city text,
  destination_state text,
  delivered_at timestamptz,
  rate numeric,
  has_verified_pod boolean,
  has_bol boolean,
  bol_required boolean,
  has_rate_confirmation boolean,
  rate_confirmation_required boolean,
  ready_to_bill boolean
)
language sql
stable
as $$
  with pickup_stop as (
    select distinct on (load_id) load_id, city, state
    from public.load_stops
    where stop_type = 'pickup'
    order by load_id, scheduled_at asc nulls last
  ),
  delivery_stop as (
    select distinct on (load_id) load_id, city, state
    from public.load_stops
    where stop_type = 'delivery'
    order by load_id, scheduled_at desc nulls last
  ),
  latest_dispatch as (
    select distinct on (load_id) load_id, delivered_at
    from public.dispatches
    where delivered_at is not null
    order by load_id, delivered_at desc
  )
  select
    l.id, l.load_number, l.status,
    l.customer_id, c.company_name,
    l.broker_id, b.company_name,
    ps.city, ps.state,
    ds.city, ds.state,
    ld.delivered_at,
    lf.rate,
    r.has_verified_pod, r.has_bol, r.bol_required, r.has_rate_confirmation, r.rate_confirmation_required, r.ready_to_bill
  from public.loads l
  join public.load_financials lf on lf.load_id = l.id
  left join public.customers c on c.id = l.customer_id
  left join public.brokers b on b.id = l.broker_id
  left join pickup_stop ps on ps.load_id = l.id
  left join delivery_stop ds on ds.load_id = l.id
  left join latest_dispatch ld on ld.load_id = l.id
  left join public.invoices i on i.load_id = l.id
  cross join lateral public.get_load_billing_readiness(l.id) r
  where l.status in ('delivered', 'pod_received')
    and i.id is null
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  order by ld.delivered_at asc nulls last, l.load_number asc;
$$;

create or replace function public.calculate_driver_load_pay(
  p_driver_id uuid,
  p_load_id uuid,
  p_as_of_date date default null
)
returns table (
  dispatch_id uuid,
  load_number text,
  delivery_date date,
  miles numeric,
  load_rate numeric,
  pay_method public.driver_pay_method,
  pay_rate numeric,
  gross_pay numeric
)
language sql
stable
as $$
  with d as (
    select disp.id as dispatch_id, l.load_number, l.total_miles,
           dfin.load_rate,
           coalesce(disp.completed_at, disp.dispatched_at)::date as delivery_date
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    join public.dispatch_financials dfin on dfin.dispatch_id = disp.id
    where disp.driver_id = p_driver_id and disp.load_id = p_load_id
      and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
    order by disp.dispatched_at desc
    limit 1
  ),
  rate as (
    select dpr.pay_method, dpr.percentage_rate, dpr.rate_per_mile, dpr.flat_rate
    from public.driver_pay_rates dpr, d
    where dpr.driver_id = p_driver_id
      and dpr.effective_from <= coalesce(p_as_of_date, d.delivery_date)
      and (dpr.effective_to is null or dpr.effective_to >= coalesce(p_as_of_date, d.delivery_date))
    order by dpr.effective_from desc
    limit 1
  )
  select
    d.dispatch_id, d.load_number, d.delivery_date, d.total_miles, d.load_rate,
    rate.pay_method,
    case rate.pay_method
      when 'percentage' then rate.percentage_rate
      when 'per_mile' then rate.rate_per_mile
      when 'flat_rate' then rate.flat_rate
    end as pay_rate,
    case rate.pay_method
      when 'percentage' then round(d.load_rate * (rate.percentage_rate / 100.0), 2)
      when 'per_mile' then round(coalesce(d.total_miles, 0) * rate.rate_per_mile, 2)
      when 'flat_rate' then rate.flat_rate
      else null
    end as gross_pay
  from d left join rate on true;
$$;

-- Phase 2G.11 repair: the version of this function originally drafted for
-- 0069 (like 0068's own first live attempt, which failed with 42P13 and
-- was fixed in that migration) was written against 0033's ORIGINAL
-- 10-column shape, not the actual live one -- last redefined by
-- 0036_carrier_settlements_dependency_fix.sql, and unchanged in shape by
-- 0068's repair -- which has 14 columns: pickup_city, pickup_state,
-- delivery_city, delivery_state are consumed directly by
-- src/app/(app)/settlements/actions.ts and must not be dropped. Fixed here
-- BEFORE this migration is ever applied, so it can't reintroduce the same
-- 42P13/data-loss regression 0068 already hit live. Coalesce-to-dispatches
-- fallback is correctly absent (not merely omitted) -- by the time this
-- statement would run, the columns it would have fallen back to are being
-- dropped later in this same migration, so a fallback here would be
-- referencing columns already scheduled for removal.
create or replace function public.calculate_carrier_load_settlement(
  p_carrier_id uuid,
  p_load_id uuid
)
returns table (
  dispatch_id uuid,
  load_number text,
  delivery_date date,
  miles numeric,
  customer_revenue numeric,
  carrier_rate numeric,
  gross_margin numeric,
  margin_percent numeric,
  driver_name text,
  truck_unit text,
  pickup_city text,
  pickup_state text,
  delivery_city text,
  delivery_state text
)
language sql
stable
as $$
  select
    disp.id, l.load_number,
    coalesce(disp.completed_at, disp.dispatched_at)::date,
    l.total_miles,
    df.load_rate,
    df.carrier_net_amount,
    df.dispatch_fee_amount,
    case when df.load_rate <> 0 then round(df.dispatch_fee_amount / df.load_rate * 100, 10) else null end,
    trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')),
    t.unit_number,
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1)
  from public.dispatches disp
  join public.loads l on l.id = disp.load_id
  join public.dispatch_financials df on df.dispatch_id = disp.id
  left join public.drivers d on d.id = disp.driver_id
  left join public.trucks t on t.id = disp.truck_id
  where disp.carrier_id = p_carrier_id and disp.load_id = p_load_id
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  order by disp.dispatched_at desc
  limit 1;
$$;

-- get_load_profitability() -- same pure-extension-table read, coalesce
-- removed from the `base`/`disp` CTEs only; every other line identical to
-- 0068's version (see that migration for the full body/reasoning).
drop function if exists public.get_load_profitability(uuid);

create function public.get_load_profitability(p_load_id uuid default null)
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
  pending_direct_cost numeric,
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
           l.broker_id, l.customer_id, l.total_miles as miles, lf.rate as booked_rate
    from public.loads l
    join public.load_financials lf on lf.load_id = l.id
    where (p_load_id is null or l.id = p_load_id)
      and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
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
    select distinct on (d.load_id)
      d.load_id, d.id as dispatch_id, d.carrier_id, d.driver_id,
      df.carrier_net_amount,
      coalesce(d.completed_at, d.dispatched_at)::date as delivery_date
    from public.dispatches d
    join public.dispatch_financials df on df.dispatch_id = d.id
    where d.load_id in (select load_id from base)
    order by d.load_id, d.dispatched_at desc
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
  direct_exp as (
    select * from public.get_load_direct_expenses(p_load_id)
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
      d.carrier_net_amount as carrier_estimate_cost,
      coalesce(dx.approved_direct_expense_total, 0) as other_direct_cost,
      coalesce(dx.pending_direct_expense_total, 0) as pending_direct_cost,
      coalesce(dx.pending_expense_count, 0) as pending_expense_count
    from base b
    left join disp d on d.load_id = b.load_id
    left join inv on inv.load_id = b.load_id
    left join carrier_finalized cf on cf.load_id = b.load_id
    left join driver_finalized df on df.load_id = b.load_id
    left join driver_estimate de on de.load_id = b.load_id
    left join direct_exp dx on dx.load_id = b.load_id
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
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.other_direct_cost end as other_direct_cost,
    r.pending_direct_cost,
    case when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost end as total_direct_cost,
    case when r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost) end as gross_profit,
    case when r.revenue is null or r.revenue = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost)) / r.revenue * 100, 6) end as margin_percent,
    case when b.miles is null or b.miles = 0 or r.revenue is null then null else round(r.revenue / b.miles, 4) end as revenue_per_mile,
    case when b.miles is null or b.miles = 0 or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost) / b.miles, 4) end as cost_per_mile,
    case when b.miles is null or b.miles = 0 or r.revenue is null or coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then null
         else round((r.revenue - (coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) + r.other_direct_cost)) / b.miles, 4) end as profit_per_mile,
    case
      when b.load_status not in ('delivered', 'pod_received', 'invoiced', 'closed') then 'NOT_DELIVERED'
      when r.revenue is null then 'MISSING_REVENUE'
      when coalesce(r.carrier_finalized_cost, r.driver_finalized_cost, r.driver_estimate_cost, r.carrier_estimate_cost) is null then 'MISSING_COST'
      when r.pending_expense_count > 0 then 'PENDING_EXPENSES'
      when r.revenue_source = 'invoice' and (r.carrier_finalized_cost is not null or r.driver_finalized_cost is not null) then 'COMPLETE'
      else 'ESTIMATED'
    end::public.profitability_status as profitability_status
  from base b
  left join stops st on st.load_id = b.load_id
  left join resolved r on r.load_id = b.load_id;
$$;

-- ---------------------------------------------------------------------------
-- 2. Drop the orphaned mirror-trigger functions (triggers already dropped
-- in 0068) and the superseded sync_dispatch_financials().
-- ---------------------------------------------------------------------------
drop function if exists public.mirror_load_financials();
drop function if exists public.mirror_dispatch_financials();
drop function if exists public.mirror_dispatch_internal_notes();
drop function if exists public.mirror_carrier_financials();
drop function if exists public.mirror_customer_financials();
drop function if exists public.mirror_broker_financials();
drop function if exists public.mirror_driver_compensation();
drop function if exists public.sync_dispatch_financials();

-- ---------------------------------------------------------------------------
-- 3. Drop the old sensitive columns. Extension-table data is untouched --
-- nothing here writes to load_financials/dispatch_financials/
-- dispatch_internal_notes/carrier_financials/customer_financials/
-- broker_financials/driver_compensation, only the base tables lose the
-- now-duplicate columns.
-- ---------------------------------------------------------------------------
alter table public.loads
  drop column if exists rate,
  drop column if exists detention_rate,
  drop column if exists layover_rate;

alter table public.dispatches
  drop column if exists dispatch_fee_percentage,
  drop column if exists load_rate,
  drop column if exists dispatch_fee_amount,
  drop column if exists carrier_net_amount,
  drop column if exists notes;

alter table public.carriers
  drop column if exists dispatch_fee_percentage,
  drop column if exists payment_terms_days,
  drop column if exists factoring_company_name;

alter table public.customers
  drop column if exists payment_terms_days;

alter table public.brokers
  drop column if exists payment_terms_days,
  drop column if exists credit_rating,
  drop column if exists average_days_to_pay;

alter table public.drivers
  drop column if exists pay_type,
  drop column if exists pay_rate;
