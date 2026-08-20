-- =============================================================================
-- 0068_financial_function_cutover.sql
-- Phase 2G.8: repoints every reporting RPC confirmed (Phase 2G.7) to leak
-- financial data via direct call -- get_load_profitability(),
-- calculate_driver_load_pay(), and 0065's get_ready_to_bill_loads() -- to
-- read from the new extension tables (0067) instead of the base tables'
-- soon-to-be-removed columns, and adds an explicit role guard to each so
-- viewer/driver get an empty result even calling the RPC directly, not
-- merely "the UI no longer shows a button for it." PROPOSED ONLY -- NOT
-- APPLIED. Depends on 0067 (the tables read here must already exist).
--
-- SCOPE DECISION: every function below is redefined with the SMALLEST
-- possible diff from its existing, live body -- only the rate/financial-
-- amount SOURCE and the role guard change; every other line of business
-- logic (profitability math, pay-rate resolution, settlement-vs-estimate
-- precedence) is reproduced verbatim from the current migration history
-- (0041_expense_cost_management_fix.sql for get_load_profitability,
-- 0031_driver_settlements.sql for calculate_driver_load_pay,
-- 0065_billing_readiness.sql for get_ready_to_bill_loads) rather than
-- rewritten from scratch, to avoid silently changing real profitability/
-- settlement numbers while fixing an authorization gap.
--
-- NOT redefined here, and why: get_load_direct_expenses() reads only
-- `expenses` and its own cost-category tables -- both already covered by
-- 0066's SELECT tightening (owner/admin/dispatcher/accountant), and this
-- function is not SECURITY DEFINER, so it automatically inherits that
-- protection once 0066 is applied. Redefining it here would be a no-op at
-- best and a second, competing place to maintain the same rule at worst.
--
-- UPDATE (Phase 2G.10): calculate_carrier_load_settlement() (the real
-- function behind what the Phase 2G.9 report called
-- "get_carrier_settlement_line_items" -- confirmed via full search that no
-- function has that exact name) is now redefined too, further down this
-- file, alongside the full writer cutover (mirror triggers retired, fee
-- computation moved to dispatch_financials, auto-invoice trigger
-- repointed). get_driver_settlement_items doesn't exist under that name
-- either -- the equivalent, get_payable_loads(), was confirmed by
-- inspection to already inherit protection transitively through
-- calculate_driver_load_pay() (already redefined below), needing no
-- separate change.
--
-- UPDATE (Phase 2G.10 repair, post-live-failure): the first attempt at
-- this file's calculate_carrier_load_settlement() failed live with
-- `42P13: cannot change return type of existing function` -- its
-- `returns table` was written from 0033_carrier_settlements.sql's
-- ORIGINAL 10-column shape, but the actual live function (last redefined
-- by 0036_carrier_settlements_dependency_fix.sql, confirmed via full
-- migration-history search -- 0034/0035 also touched it in between) has
-- grown to 14 columns: pickup_city, pickup_state, delivery_city,
-- delivery_state were added by 0036 and are consumed directly by
-- src/app/(app)/settlements/actions.ts (both createCarrierSettlement()
-- and addSettlementLoad(), which write them straight into
-- settlement_line_items). Silently dropping them would have been a real
-- data-loss regression on top of the catalog error. Fixed by restoring
-- all 14 columns verbatim from 0036 -- source is now dispatch_financials
-- (coalesce-to-old-column, matching get_load_profitability's/
-- calculate_driver_load_pay's own defensive pattern above) instead of
-- dispatches, but the public return shape is byte-for-byte what 0036
-- shipped. Because the signature is unchanged, this stays a plain `create
-- or replace` -- no `drop function` needed, so the existing `grant
-- execute ... to authenticated` (0036) is preserved automatically rather
-- than needing to be re-issued.
--
-- NOTE for whoever eventually revises 0069_financial_column_removal.sql:
-- its own copy of calculate_carrier_load_settlement() still has the same
-- 10-column shape this fix just corrected here. That file is unapplied
-- and out of scope for this repair, but it will hit the identical 42P13
-- (or, worse, silently ship with the same data-loss regression, since by
-- the time 0069 runs this corrected 14-column version will already be
-- live) unless it's corrected the same way before it's ever applied.
--
-- STILL OPEN (not fixed in this pass -- lower priority, see the Phase
-- 2G.8/2G.9 reports): other 0031-0040 settlement/summary functions not
-- confirmed to read the moved columns directly (checked
-- get_carrier_settlement_summary/get_driver_settlement_summary this phase --
-- neither touches loads.rate/dispatches.load_rate/etc., both read only
-- from settlements/settlement_line_items, the already-finalized recorded
-- amounts). Auditing their full call graph correctly, without
-- breaking real settlement math, needs its own dedicated pass rather than
-- being rushed inside an already-large migration.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- get_load_profitability(): rate now sourced from load_financials,
-- carrier_net_amount (the dispatch-estimate fallback cost) from
-- dispatch_financials. Role guard added as a final WHERE, matching the
-- same "unauthorized caller gets zero rows, not an error" convention
-- get_ready_to_bill_loads() (0065) already established.
-- ---------------------------------------------------------------------------
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
           l.broker_id, l.customer_id, l.total_miles as miles,
           coalesce(lf.rate, l.rate) as booked_rate
    from public.loads l
    left join public.load_financials lf on lf.load_id = l.id
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
      coalesce(df.carrier_net_amount, d.carrier_net_amount) as carrier_net_amount,
      coalesce(d.completed_at, d.dispatched_at)::date as delivery_date
    from public.dispatches d
    left join public.dispatch_financials df on df.dispatch_id = d.id
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
-- calculate_driver_load_pay(): load_rate now sourced from
-- dispatch_financials. Role guard added to the `d` CTE's WHERE -- if it
-- fails, `d` (and therefore the final result) is empty.
-- ---------------------------------------------------------------------------
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
           coalesce(dfin.load_rate, disp.load_rate) as load_rate,
           coalesce(disp.completed_at, disp.dispatched_at)::date as delivery_date
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    left join public.dispatch_financials dfin on dfin.dispatch_id = disp.id
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

-- ---------------------------------------------------------------------------
-- get_ready_to_bill_loads() (0065_billing_readiness.sql): rate now sourced
-- from load_financials. Role guard was already present (added directly in
-- 0065 during the Phase 2G.6 review) -- unchanged here.
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
    coalesce(lf.rate, l.rate),
    r.has_verified_pod, r.has_bol, r.bol_required, r.has_rate_confirmation, r.rate_confirmation_required, r.ready_to_bill
  from public.loads l
  left join public.load_financials lf on lf.load_id = l.id
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

-- =============================================================================
-- Phase 2G.10: WRITER CUTOVER. The mirror triggers added in 0067 always
-- copy old-column -> new-table. That is correct for the brief window
-- between 0067 applying and application code being repointed, but it is
-- explicitly NOT the permanent model -- once app writers below start
-- writing the extension tables directly, a mirror still running in the
-- old->new direction would silently overwrite fresh data with stale/
-- default values from columns the app no longer populates. This section:
--   (a) drops every 0067 mirror trigger (all six) -- superseded;
--   (b) moves dispatch fee computation from a trigger on `dispatches` to
--       a trigger on `dispatch_financials` itself, since the app now
--       writes dispatch_fee_percentage there directly, not to dispatches;
--   (c) redefines auto_generate_invoice_from_delivered_load() (the live
--       auto-invoice-on-delivery trigger) to read rate/payment_terms_days
--       from the extension tables -- it previously read NEW.rate and
--       brokers/customers.payment_terms_days directly, both of which stop
--       being populated once the writer cutover below lands;
--   (d) redefines calculate_carrier_load_settlement() (found this phase's
--       full search -- reads dispatches.load_rate/carrier_net_amount/
--       dispatch_fee_amount/dispatch_fee_percentage directly, not covered
--       by 0068's original three redefinitions) with the same source +
--       role-guard treatment. get_payable_carrier_loads() needs no
--       separate redefinition -- it only reaches those columns through a
--       `cross join lateral calculate_carrier_load_settlement(...)`, so it
--       inherits the fix automatically (an unauthorized caller's lateral
--       join simply produces zero rows). get_payable_loads() (driver
--       side) already inherits the same protection transitively through
--       the already-redefined calculate_driver_load_pay() -- confirmed by
--       inspection, not redefined again here.
-- =============================================================================

drop trigger if exists loads_mirror_financials on public.loads;
drop trigger if exists dispatches_mirror_financials on public.dispatches;
drop trigger if exists dispatches_mirror_internal_notes on public.dispatches;
drop trigger if exists carriers_mirror_financials on public.carriers;
drop trigger if exists customers_mirror_financials on public.customers;
drop trigger if exists brokers_mirror_financials on public.brokers;
drop trigger if exists drivers_mirror_compensation on public.drivers;

-- ---------------------------------------------------------------------------
-- Dispatch fee computation moves to dispatch_financials. Same formula as
-- the original sync_dispatch_financials() (0009_functions_triggers.sql),
-- just reading/writing the new table's own columns instead of
-- dispatches'. load_rate's snapshot-from-the-load fallback now reads
-- load_financials.rate instead of loads.rate.
-- ---------------------------------------------------------------------------
drop trigger if exists dispatches_sync_financials on public.dispatches;

create or replace function public.sync_dispatch_financials_v2()
returns trigger
language plpgsql
as $$
declare
  v_load_rate numeric(10, 2);
begin
  if new.load_rate is null or new.load_rate = 0 then
    select rate into v_load_rate from public.load_financials where load_id = (
      select load_id from public.dispatches where id = new.dispatch_id
    );
    new.load_rate := coalesce(v_load_rate, 0);
  end if;

  new.dispatch_fee_amount := round(new.load_rate * (new.dispatch_fee_percentage / 100.0), 2);
  new.carrier_net_amount := new.load_rate - new.dispatch_fee_amount;

  return new;
end;
$$;

create trigger dispatch_financials_sync
  before insert or update of load_rate, dispatch_fee_percentage
  on public.dispatch_financials
  for each row execute function public.sync_dispatch_financials_v2();

-- ---------------------------------------------------------------------------
-- Auto-invoice-on-delivery: same trigger (unchanged name/table/timing --
-- only the function body changes, via create or replace, exactly like
-- every prior revision of this function -- 0022, 0028, 0044), now reading
-- rate/payment_terms from the extension tables instead of NEW.rate /
-- brokers.payment_terms_days / customers.payment_terms_days.
-- ---------------------------------------------------------------------------
create or replace function public.auto_generate_invoice_from_delivered_load()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bill_to_name text;
  v_bill_to_email text;
  v_bill_to_address text;
  v_payment_terms integer;
  v_org_default_terms integer;
  v_invoice_number text;
  v_dispatch_id uuid;
  v_invoice_id uuid;
  v_rate numeric(10, 2);
begin
  if NEW.status is distinct from 'delivered' then
    return NEW;
  end if;
  if TG_OP = 'UPDATE' and OLD.status is not distinct from 'delivered' then
    return NEW;
  end if;

  if exists (select 1 from public.invoices where load_id = NEW.id) then
    return NEW;
  end if;

  if NEW.broker_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', address_line1, city, state, postal_code)), '')
      into v_bill_to_name, v_bill_to_email, v_bill_to_address
    from public.brokers where id = NEW.broker_id;
    select payment_terms_days into v_payment_terms from public.broker_financials where broker_id = NEW.broker_id;
  elsif NEW.customer_id is not null then
    select company_name, email,
           nullif(trim(both ', ' from concat_ws(', ', billing_address_line1, city, state, postal_code)), '')
      into v_bill_to_name, v_bill_to_email, v_bill_to_address
    from public.customers where id = NEW.customer_id;
    select payment_terms_days into v_payment_terms from public.customer_financials where customer_id = NEW.customer_id;
  else
    return NEW;
  end if;

  select default_payment_terms_days into v_org_default_terms
  from public.organizations where id = NEW.organization_id;

  select id into v_dispatch_id from public.dispatches where load_id = NEW.id limit 1;
  select rate into v_rate from public.load_financials where load_id = NEW.id;
  v_rate := coalesce(v_rate, 0);
  v_invoice_number := public.generate_invoice_number(NEW.organization_id);

  insert into public.invoices (
    organization_id, invoice_number, load_id, dispatch_id, broker_id, customer_id,
    status, bill_to_name, bill_to_email, bill_to_address,
    subtotal_amount, total_amount, issue_date, due_date, notes
  ) values (
    NEW.organization_id, v_invoice_number, NEW.id, v_dispatch_id, NEW.broker_id, NEW.customer_id,
    'draft', v_bill_to_name, v_bill_to_email, v_bill_to_address,
    v_rate, v_rate, current_date,
    current_date + coalesce(v_payment_terms, v_org_default_terms, 30),
    'Auto-generated on delivery for load ' || NEW.load_number
  )
  on conflict (load_id) where load_id is not null do nothing
  returning id into v_invoice_id;

  if v_invoice_id is not null then
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (NEW.organization_id, v_invoice_id, 'Freight charges -- Load ' || NEW.load_number, 1, v_rate, 0);

    perform public.log_activity('invoice', v_invoice_id, 'created', null, NEW.organization_id);
  end if;

  return NEW;
end;
$$;
-- Trigger definition itself (name/table/timing/columns) is unchanged --
-- see 0028's identical comment on why only the function body changes.

-- ---------------------------------------------------------------------------
-- calculate_carrier_load_settlement(): same minimal-diff treatment as
-- get_load_profitability -- source + role guard only. Business logic and
-- the full 14-column return shape (join structure, column order,
-- driver-name concat, AND the pickup/delivery city/state columns added by
-- 0036) are reproduced verbatim from 0036_carrier_settlements_dependency_
-- fix.sql -- the function's actual last-live definition, not 0033's
-- original 10-column one. margin_percent is still computed as
-- fee/rate*100 (not read from dispatch_fee_percentage) to match 0036's
-- exact formula and avoid a precision-behavior change alongside the
-- authorization fix. load_rate/carrier_net_amount/dispatch_fee_amount
-- read from dispatch_financials with a coalesce-to-dispatches fallback,
-- matching get_load_profitability's/calculate_driver_load_pay's own
-- defensive style above, in case any dispatch predates the 0067 mirror
-- backfill or was inserted through a path that bypassed it.
-- ---------------------------------------------------------------------------
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
    coalesce(df.load_rate, disp.load_rate) as load_rate,
    coalesce(df.carrier_net_amount, disp.carrier_net_amount) as carrier_net_amount,
    coalesce(df.dispatch_fee_amount, disp.dispatch_fee_amount) as dispatch_fee_amount,
    case when coalesce(df.load_rate, disp.load_rate) <> 0
         then round(coalesce(df.dispatch_fee_amount, disp.dispatch_fee_amount) / coalesce(df.load_rate, disp.load_rate) * 100, 10)
         else null end as margin_percent,
    trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')),
    t.unit_number,
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1)
  from public.dispatches disp
  join public.loads l on l.id = disp.load_id
  left join public.dispatch_financials df on df.dispatch_id = disp.id
  left join public.drivers d on d.id = disp.driver_id
  left join public.trucks t on t.id = disp.truck_id
  where disp.carrier_id = p_carrier_id and disp.load_id = p_load_id
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
  order by disp.dispatched_at desc
  limit 1;
$$;

-- Signature is unchanged from 0036's live version, so `create or replace`
-- above already preserved the existing grant -- this just re-asserts it
-- explicitly and idempotently, matching 0036's own convention.
grant execute on function public.calculate_carrier_load_settlement(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- create_load_with_stops() (0061_stop_timezone_correctness.sql, the New
-- Load form's atomic insert): rate no longer goes into the loads insert --
-- it's inserted into load_financials in the SAME function, right after
-- v_load_id is known, keeping load+stops+financials atomic in one
-- function call exactly like load+stops already were. Found during this
-- phase's full search -- this is the ONE other real writer of
-- loads.rate beyond the plain JS updateLoad()/createLoad() actions
-- (already repointed in loads/actions.ts).
-- ---------------------------------------------------------------------------
create or replace function public.create_load_with_stops(
  p_load jsonb,
  p_stops jsonb
)
returns uuid
language plpgsql
as $$
declare
  v_org_id uuid;
  v_load_id uuid;
  v_stop jsonb;
  v_stop_count integer;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'Could not determine the current organization for this user.';
  end if;

  v_stop_count := coalesce(jsonb_array_length(p_stops), 0);
  if v_stop_count = 0 then
    raise exception 'At least a pickup and a delivery stop are required.';
  end if;

  insert into public.loads (
    organization_id, load_number, broker_id, customer_id, status, commodity,
    weight_lbs, equipment_type, total_miles, rate_confirmation_number,
    special_instructions, booked_by
  )
  values (
    v_org_id,
    p_load ->> 'load_number',
    nullif(p_load ->> 'broker_id', '')::uuid,
    nullif(p_load ->> 'customer_id', '')::uuid,
    coalesce(nullif(p_load ->> 'status', ''), 'draft')::public.load_status,
    nullif(p_load ->> 'commodity', ''),
    nullif(p_load ->> 'weight_lbs', '')::integer,
    nullif(p_load ->> 'equipment_type', ''),
    nullif(p_load ->> 'total_miles', '')::numeric,
    nullif(p_load ->> 'rate_confirmation_number', ''),
    nullif(p_load ->> 'special_instructions', ''),
    auth.uid()
  )
  returning id into v_load_id;

  insert into public.load_financials (load_id, organization_id, rate)
  values (v_load_id, v_org_id, coalesce(nullif(p_load ->> 'rate', '')::numeric, 0));

  for v_stop in select * from jsonb_array_elements(p_stops)
  loop
    insert into public.load_stops (
      organization_id, load_id, stop_type, stop_sequence, facility_name,
      address_line1, address_line2, city, state, postal_code, country,
      contact_name, contact_phone, scheduled_at, scheduled_window_end,
      reference_number, notes, timezone, timezone_source
    )
    values (
      v_org_id,
      v_load_id,
      (v_stop ->> 'stop_type')::public.stop_type,
      (v_stop ->> 'stop_sequence')::integer,
      nullif(v_stop ->> 'facility_name', ''),
      nullif(v_stop ->> 'address_line1', ''),
      nullif(v_stop ->> 'address_line2', ''),
      v_stop ->> 'city',
      v_stop ->> 'state',
      nullif(v_stop ->> 'postal_code', ''),
      coalesce(nullif(v_stop ->> 'country', ''), 'US'),
      nullif(v_stop ->> 'contact_name', ''),
      nullif(v_stop ->> 'contact_phone', ''),
      nullif(v_stop ->> 'scheduled_at', '')::timestamptz,
      nullif(v_stop ->> 'scheduled_window_end', '')::timestamptz,
      nullif(v_stop ->> 'reference_number', ''),
      nullif(v_stop ->> 'notes', ''),
      nullif(v_stop ->> 'timezone', ''),
      nullif(v_stop ->> 'timezone_source', '')
    );
  end loop;

  perform public.log_activity('load'::public.entity_type, v_load_id, 'created', p_load, v_org_id);

  return v_load_id;
end;
$$;
