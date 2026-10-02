-- ============================================================================
-- 0163_settle_by_delivery_date.sql
--
-- Owner decision (2026-10-01): settlements and per-load profitability use
-- the DELIVERY date, not the dispatch date.
--
-- dispatches.completed_at is never written, so every "delivery_date" in
-- carrier/driver settlements and load profitability was really
-- coalesce(completed_at, dispatched_at) = the DISPATCH date: a load
-- dispatched Sep 29 and delivered Oct 2 landed in September's settlement
-- and showed Sep 29 as its delivery date. dispatches.delivered_at (0057) is
-- stamped when the load is delivered, so the date becomes
--   coalesce(completed_at, delivered_at, dispatched_at)
-- i.e. delivered date when known, dispatch date only as a last fallback.
--
-- Affects: which pay period a load falls in (get_payable_carrier_loads,
-- get_payable_loads), the delivery_date shown on new settlement lines
-- (calculate_carrier_load_settlement, calculate_driver_load_pay -- whose
-- driver pay-rate lookup now uses the rate effective on the delivery day),
-- and get_load_profitability's delivery_date. Settlements ALREADY created
-- are not changed (their lines store their own dates). Nothing else in the
-- five bodies changes; signatures, security, search_path and grants stay.
--
-- Bodies generated from the production twin (pg_get_functiondef); the
-- precondition refuses unless production has exactly those bodies.
-- ============================================================================

begin;

do $pre$
declare r record; v text;
begin
  for r in select * from (values
    ('public.calculate_carrier_load_settlement(uuid,uuid)', 'cb82d5869ebd95d197145051c4366e66', '7c6c6869f8f28686a3823a4dc1bceb3a'),
    ('public.calculate_driver_load_pay(uuid,uuid,date)', '739a66ea61ca12173a08c70de35a0497', '8f4941535ead52259ada149b35dd1ad9'),
    ('public.get_load_profitability(uuid)', '8fc6dee7fa3d1414a77e6ce454fb85be', 'd8a90010b413b4e7a0dd7545ef33682f'),
    ('public.get_payable_carrier_loads(uuid,date,date)', '0b4a6162b59bcd5437daaebc25094ab6', '3adaf51180076e2c4113c131cab166ae'),
    ('public.get_payable_loads(uuid,date,date)', 'e7052984e0ddbf1e37160311b5932f82', '68bb8c1a40ae228a5d4d5f9e7157275b')
  ) t(sig, old_md5, new_md5) loop
    select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v
    from pg_proc where oid = to_regprocedure(r.sig);
    if v is null then raise exception '0163 precondition: % is missing. STOP -- nothing changed.', r.sig; end if;
    if v not in (r.old_md5, r.new_md5) then   -- new_md5: already applied (safe re-run)
      raise exception '0163 precondition: % is not the expected version (md5 %). STOP -- nothing changed.', r.sig, v;
    end if;
  end loop;
end $pre$;

CREATE OR REPLACE FUNCTION public.calculate_carrier_load_settlement(p_carrier_id uuid, p_load_id uuid)
 RETURNS TABLE(dispatch_id uuid, load_number text, delivery_date date, miles numeric, customer_revenue numeric, carrier_rate numeric, gross_margin numeric, margin_percent numeric, driver_name text, truck_unit text, pickup_city text, pickup_state text, delivery_city text, delivery_state text)
 LANGUAGE sql
 STABLE
AS $function$
  select
    disp.id, l.load_number,
    coalesce(disp.completed_at, disp.delivered_at, disp.dispatched_at)::date,
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
$function$;

CREATE OR REPLACE FUNCTION public.calculate_driver_load_pay(p_driver_id uuid, p_load_id uuid, p_as_of_date date DEFAULT NULL::date)
 RETURNS TABLE(dispatch_id uuid, load_number text, delivery_date date, miles numeric, load_rate numeric, pay_method driver_pay_method, pay_rate numeric, gross_pay numeric)
 LANGUAGE sql
 STABLE
AS $function$
  with d as (
    select disp.id as dispatch_id, l.load_number, l.total_miles,
           dfin.load_rate,
           coalesce(disp.completed_at, disp.delivered_at, disp.dispatched_at)::date as delivery_date
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
$function$;

CREATE OR REPLACE FUNCTION public.get_load_profitability(p_load_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(load_id uuid, load_number text, organization_id uuid, delivery_date date, load_status load_status, broker_id uuid, customer_id uuid, carrier_id uuid, driver_id uuid, origin_city text, origin_state text, destination_city text, destination_state text, miles numeric, revenue numeric, revenue_source text, carrier_cost numeric, driver_cost numeric, transportation_cost numeric, transportation_cost_source text, other_direct_cost numeric, pending_direct_cost numeric, total_direct_cost numeric, gross_profit numeric, margin_percent numeric, revenue_per_mile numeric, cost_per_mile numeric, profit_per_mile numeric, profitability_status profitability_status)
 LANGUAGE sql
 STABLE
AS $function$
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
      coalesce(d.completed_at, d.delivered_at, d.dispatched_at)::date as delivery_date
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
$function$;

CREATE OR REPLACE FUNCTION public.get_payable_carrier_loads(p_carrier_id uuid, p_period_start date, p_period_end date)
 RETURNS TABLE(load_id uuid, dispatch_id uuid, load_number text, pickup_city text, pickup_state text, delivery_city text, delivery_state text, delivery_date date, miles numeric, customer_revenue numeric, carrier_rate numeric, gross_margin numeric, margin_percent numeric, driver_name text, truck_unit text)
 LANGUAGE sql
 STABLE
AS $function$
  with candidates as (
    select disp.id as dispatch_id, l.id as load_id
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    where disp.carrier_id = p_carrier_id
      and l.status in ('delivered', 'pod_received')
      and coalesce(disp.completed_at, disp.delivered_at, disp.dispatched_at)::date between p_period_start and p_period_end
      and not exists (
        select 1 from public.settlement_line_items sli
        join public.settlements s on s.id = sli.settlement_id
        where sli.item_type = 'load_pay' and sli.load_id = l.id and s.status <> 'void'
      )
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as pickup_city,
           max(state) filter (where stop_type = 'pickup') as pickup_state,
           max(city) filter (where stop_type = 'delivery') as delivery_city,
           max(state) filter (where stop_type = 'delivery') as delivery_state
    from public.load_stops
    where load_id in (select load_id from candidates)
    group by load_id
  )
  select
    c.load_id, c.dispatch_id, p.load_number, s.pickup_city, s.pickup_state, s.delivery_city, s.delivery_state,
    p.delivery_date, p.miles, p.customer_revenue, p.carrier_rate, p.gross_margin, p.margin_percent, p.driver_name, p.truck_unit
  from candidates c
  left join stops s on s.load_id = c.load_id
  cross join lateral public.calculate_carrier_load_settlement(p_carrier_id, c.load_id) p
  order by p.delivery_date asc nulls last;
$function$;

CREATE OR REPLACE FUNCTION public.get_payable_loads(p_driver_id uuid, p_period_start date, p_period_end date)
 RETURNS TABLE(load_id uuid, dispatch_id uuid, load_number text, pickup_city text, pickup_state text, delivery_city text, delivery_state text, delivery_date date, miles numeric, load_rate numeric, pay_method driver_pay_method, pay_rate numeric, gross_pay numeric)
 LANGUAGE sql
 STABLE
AS $function$
  with candidates as (
    select disp.id as dispatch_id, l.id as load_id
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    where disp.driver_id = p_driver_id
      and l.status in ('delivered', 'pod_received')
      and coalesce(disp.completed_at, disp.delivered_at, disp.dispatched_at)::date between p_period_start and p_period_end
      and not exists (
        select 1 from public.driver_settlement_items dsi
        join public.driver_settlements ds on ds.id = dsi.driver_settlement_id
        where dsi.load_id = l.id and ds.status <> 'void'
      )
  ),
  stops as (
    select load_id,
           max(city) filter (where stop_type = 'pickup') as pickup_city,
           max(state) filter (where stop_type = 'pickup') as pickup_state,
           max(city) filter (where stop_type = 'delivery') as delivery_city,
           max(state) filter (where stop_type = 'delivery') as delivery_state
    from public.load_stops
    where load_id in (select load_id from candidates)
    group by load_id
  )
  select
    c.load_id, c.dispatch_id, p.load_number, s.pickup_city, s.pickup_state, s.delivery_city, s.delivery_state,
    p.delivery_date, p.miles, p.load_rate, p.pay_method, p.pay_rate, p.gross_pay
  from candidates c
  left join stops s on s.load_id = c.load_id
  cross join lateral public.calculate_driver_load_pay(p_driver_id, c.load_id) p
  order by p.delivery_date asc nulls last;
$function$;

do $post$
declare n int;
begin
  select count(*) into n from pg_proc
  where oid in ('public.calculate_carrier_load_settlement(uuid,uuid)'::regprocedure, 'public.calculate_driver_load_pay(uuid,uuid,date)'::regprocedure,
                'public.get_load_profitability(uuid)'::regprocedure, 'public.get_payable_carrier_loads(uuid,date,date)'::regprocedure,
                'public.get_payable_loads(uuid,date,date)'::regprocedure)
    and prosrc ~ 'coalesce\(\w+\.completed_at, \w+\.delivered_at, \w+\.dispatched_at\)'
    and prosrc !~ 'coalesce\(\w+\.completed_at, \w+\.dispatched_at\)';
  if n <> 5 then raise exception '0163 postcondition: % of 5 functions use the delivery date.', n; end if;
end $post$;

commit;
