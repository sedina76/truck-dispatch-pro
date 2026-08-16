-- =============================================================================
-- 0035_carrier_settlements_bugfixes_2.sql
-- Two more real bugs found continuing the live Carrier Settlement test.
--
-- BUG 3 (Test H, approval/freeze): settlement_line_items had draft-only
-- guards on INSERT (guard_settlement_line_item_duplicate /
-- guard_settlement_adjustment_draft_insert) and DELETE
-- (settlement_line_items_guard_draft_delete), but no trigger at all on
-- UPDATE. Confirmed live: after approving a settlement, a direct UPDATE
-- of a load_pay line's amount/carrier_rate/customer_revenue succeeded --
-- silently breaking the frozen-snapshot guarantee (spec section 39: "carrier
-- rate changes must not retroactively alter settlement snapshots") for the
-- one path (UPDATE) the existing guards didn't cover, even though no
-- current app action performs such an update itself. Fix: bind the
-- EXISTING guard_settlement_line_item_draft() function (already correct --
-- it already resolves coalesce(new.settlement_id, old.settlement_id) and
-- blocks when status not in ('draft','pending')) to BEFORE UPDATE too.
-- No new function, no schema change.
--
-- BUG 4 (Test O/N, Carrier Profile YTD summary): get_carrier_settlement_summary()
-- (0033) filtered its `settled`/`items` CTEs with only `status <> 'void'`,
-- so DRAFT settlements -- still being edited, not yet approved, could still
-- be deleted entirely -- were counted into "YTD Gross Carrier Pay", YTD
-- deductions/advances/Quick-Pay-fees, completed-load count, total customer
-- revenue, total carrier pay, and total gross margin. Confirmed live: with
-- 3 finalized settlements (approved/partially_paid, true YTD gross pay
-- $20,400, 3 loads, revenue $25,000, carrier pay $20,400, margin $4,600)
-- plus 4 unrelated leftover drafts sitting in the test carrier's queue
-- ($1,500 + $0 + $2,200/$250 advance + $1,900), the function returned
-- ytd_gross_pay $26,000 and completed_loads 6 -- silently inflated by
-- settlements that were never actually finalized. The same `status <>
-- 'void'` pattern already exists in get_driver_settlement_summary() (0031)
-- -- out of scope for this carrier-settlement test round, flagged
-- separately, not changed here.
--
-- Fix: restrict `settled`/`items` (and last_settlement_date) to actually
-- finalized statuses -- approved/partially_paid/paid -- matching the
-- unpaid_approved_count/unpaid_approved_balance columns in the same
-- function, which already used exactly that filter.
--
-- BUG 5 (Test Q, settlement PDF/detail): spec requires the settlement PDF
-- to show Pickup/Delivery per load. get_payable_carrier_loads() (0033)
-- already joins load_stops and returns pickup_city/pickup_state/
-- delivery_city/delivery_state, but that data was discarded the moment a
-- load became a settlement_line_items row -- neither
-- calculate_carrier_load_settlement() (the single-load add path) nor the
-- settlement_line_items table itself carried it, so it could never be
-- shown later on the settlement detail page or PDF regardless of load
-- data. Fixed by snapshotting it into settlement_line_items, same as
-- every other load-level field (spec section 39: frozen at add-time).
-- =============================================================================

alter table public.settlement_line_items
  add column pickup_city text,
  add column pickup_state text,
  add column delivery_city text,
  add column delivery_state text;

drop function if exists public.calculate_carrier_load_settlement(uuid, uuid);
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

drop trigger if exists settlement_line_items_guard_draft_update on public.settlement_line_items;
create trigger settlement_line_items_guard_draft_update
  before update on public.settlement_line_items
  for each row execute function public.guard_settlement_line_item_draft();

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
