-- =============================================================================
-- 0036_carrier_settlements_dependency_fix.sql
-- 0035_carrier_settlements_bugfixes_2.sql silently failed to apply as a
-- whole (confirmed live: settlement_line_items.pickup_city didn't exist,
-- calculate_carrier_load_settlement still returned the old 10-column
-- shape, and a direct UPDATE of an approved settlement_line_items row
-- still succeeded -- BUG 3's trigger never got created either).
--
-- First attempt at this file (this same migration number) assumed the
-- cause was a pg_depend edge from get_payable_carrier_loads() (0033) --
-- which calls calculate_carrier_load_settlement() via `cross join
-- lateral` -- blocking the plain DROP FUNCTION and added `cascade` plus
-- an unconditional `create function` for get_payable_carrier_loads to
-- recreate it after the cascade. That assumption was wrong: confirmed
-- live just now that a plain function call inside another LANGUAGE SQL
-- function's body does NOT register as a hard catalog dependency in this
-- Postgres version -- the cascade had nothing to cascade to, so
-- get_payable_carrier_loads was never dropped, and the unconditional
-- `create function public.get_payable_carrier_loads(...)` collided with
-- the still-existing original: `42723: function "get_payable_carrier_loads"
-- already exists with same argument types`. That is what actually rolled
-- the whole script back the second time; it also explains why the
-- original 0035 (no cascade, no get_payable_carrier_loads statement at
-- all) never had a chance to reach this specific failure -- its own root
-- cause remains unconfirmed, but every statement in this file is now
-- idempotent regardless, so it applies cleanly however the DB got here.
--
-- Fix: `create or replace function get_payable_carrier_loads` instead of
-- a plain `create function`, so this succeeds whether or not the cascade
-- actually dropped it. `cascade` is left on the calculate_carrier_load_
-- settlement drop as a harmless no-op safety net. Every other statement
-- here was already idempotent (`if not exists` / `create or replace` /
-- `drop trigger if exists`).
-- =============================================================================

alter table public.settlement_line_items
  add column if not exists pickup_city text,
  add column if not exists pickup_state text,
  add column if not exists delivery_city text,
  add column if not exists delivery_state text;

drop function if exists public.calculate_carrier_load_settlement(uuid, uuid) cascade;

create function public.calculate_carrier_load_settlement(
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
    disp.load_rate,
    disp.carrier_net_amount,
    disp.dispatch_fee_amount,
    case when disp.load_rate <> 0 then round(disp.dispatch_fee_amount / disp.load_rate * 100, 10) else null end,
    trim(coalesce(d.first_name, '') || ' ' || coalesce(d.last_name, '')),
    t.unit_number,
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence limit 1),
    (select ls.city from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1),
    (select ls.state from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1)
  from public.dispatches disp
  join public.loads l on l.id = disp.load_id
  left join public.drivers d on d.id = disp.driver_id
  left join public.trucks t on t.id = disp.truck_id
  where disp.carrier_id = p_carrier_id and disp.load_id = p_load_id
  order by disp.dispatched_at desc
  limit 1;
$$;

grant execute on function public.calculate_carrier_load_settlement(uuid, uuid) to authenticated;

-- Recreated verbatim from 0033 -- not itself buggy, it just needs to
-- exist again in case the cascade above dropped it. create or replace
-- (not plain create) since, in practice, it usually won't have been.
create or replace function public.get_payable_carrier_loads(
  p_carrier_id uuid,
  p_period_start date,
  p_period_end date
)
returns table (
  load_id uuid,
  dispatch_id uuid,
  load_number text,
  pickup_city text,
  pickup_state text,
  delivery_city text,
  delivery_state text,
  delivery_date date,
  miles numeric,
  customer_revenue numeric,
  carrier_rate numeric,
  gross_margin numeric,
  margin_percent numeric,
  driver_name text,
  truck_unit text
)
language sql
stable
as $$
  with candidates as (
    select disp.id as dispatch_id, l.id as load_id
    from public.dispatches disp
    join public.loads l on l.id = disp.load_id
    where disp.carrier_id = p_carrier_id
      and l.status in ('delivered', 'pod_received')
      and coalesce(disp.completed_at, disp.dispatched_at)::date between p_period_start and p_period_end
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
$$;

grant execute on function public.get_payable_carrier_loads(uuid, date, date) to authenticated;

-- BUG 3 fix, re-applied.
drop trigger if exists settlement_line_items_guard_draft_update on public.settlement_line_items;
create trigger settlement_line_items_guard_draft_update
  before update on public.settlement_line_items
  for each row execute function public.guard_settlement_line_item_draft();

-- BUG 4 fix, re-applied.
create or replace function public.get_carrier_settlement_summary(p_carrier_id uuid, p_year integer default extract(year from current_date)::integer)
returns table (
  ytd_gross_pay numeric,
  ytd_deductions numeric,
  ytd_advances numeric,
  ytd_quick_pay_fees numeric,
  ytd_net_paid numeric,
  unpaid_approved_count bigint,
  unpaid_approved_balance numeric,
  last_settlement_date date,
  completed_loads bigint,
  total_customer_revenue numeric,
  total_carrier_pay numeric,
  total_gross_margin numeric
)
language sql
stable
as $$
  with settled as (
    select * from public.settlements
    where carrier_id = p_carrier_id
      and status in ('approved', 'partially_paid', 'paid')
      and extract(year from coalesce(period_end, created_at::date)) = p_year
  ),
  items as (
    select sli.* from public.settlement_line_items sli
    join public.settlements s on s.id = sli.settlement_id
    where s.carrier_id = p_carrier_id and s.status in ('approved', 'partially_paid', 'paid') and sli.item_type = 'load_pay'
  )
  select
    coalesce((select sum(gross_amount) from settled), 0),
    coalesce((select sum(deductions_amount) from settled), 0),
    coalesce((select sum(advances_amount) from settled), 0),
    coalesce((select sum(quick_pay_fee_amount) from settled), 0),
    coalesce((select sum(amount_paid) from settled), 0),
    (select count(*) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid'))::bigint,
    coalesce((select sum(balance_due) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid')), 0),
    (select max(period_end) from public.settlements where carrier_id = p_carrier_id and status in ('approved', 'partially_paid', 'paid')),
    (select count(*) from items)::bigint,
    coalesce((select sum(customer_revenue) from items), 0),
    coalesce((select sum(carrier_rate) from items), 0),
    coalesce((select sum(customer_revenue) - sum(carrier_rate) from items), 0);
$$;

grant execute on function public.get_carrier_settlement_summary(uuid, integer) to authenticated;
