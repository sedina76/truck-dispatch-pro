-- =============================================================================
-- 0034_carrier_settlements_bugfixes.sql
-- Two real bugs found during the live Carrier Settlement test.
--
-- BUG 1 -- margin_percent imprecise (Test A: $7,000 revenue / $5,400
-- carrier pay / $1,600 margin / 22.857142...% margin):
-- calculate_carrier_load_settlement() (0033) returned margin_percent as
-- disp.dispatch_fee_percentage -- the STORED, independently-editable
-- numeric(5,2) rate field on the dispatch row, not a derived ratio of the
-- actual gross_margin/customer_revenue amounts. Live result was 22.86
-- (the stored rate, rounded to 2dp at entry time) instead of the true
-- 22.857142857142857...% the actual dollar amounts imply. The two agree
-- only when dispatch_fee_amount was itself computed fresh from that exact
-- percentage and never independently adjusted afterward (e.g. a manual
-- override, a negotiated flat accessorial, or -- as in this test itself --
-- any value that doesn't reduce to a clean 2-decimal percentage of the
-- load rate); real settlements can and do drift from that. gross_margin
-- (disp.dispatch_fee_amount, NUMERIC(10,2)) was already exact and is
-- unchanged; only margin_percent is corrected, to the authoritative ratio
-- actually implied by the exact dollar figures: round(dispatch_fee_amount
-- / load_rate * 100, 10).
--
-- BUG 2 -- settlement creation completely broken (found immediately in
-- Test D): public.settlements.settlement_number (0006_financials.sql) is
-- `text not null` with NO default and no generator function was ever
-- added for it -- unlike invoices/statements/driver_settlements, which
-- all get theirs from a dedicated generate_*_number() sequence default.
-- createCarrierSettlement() (settlements/actions.ts) never supplies
-- settlement_number either, so every real "New Carrier Settlement"
-- submission in the live app fails outright with `null value in column
-- "settlement_number" violates not-null constraint` -- confirmed live.
-- Fixed the same way as every other numbered document this session:
-- CS-###### sequence + generate_carrier_settlement_number(), set as the
-- column default so the existing insert (which never mentions the column)
-- starts working with no app code change. "CS-" (not driver settlements'
-- existing "SET-") to keep the two settlement types visually distinct.
-- =============================================================================

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
  truck_unit text
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
    t.unit_number
  from public.dispatches disp
  join public.loads l on l.id = disp.load_id
  left join public.drivers d on d.id = disp.driver_id
  left join public.trucks t on t.id = disp.truck_id
  where disp.carrier_id = p_carrier_id and disp.load_id = p_load_id
  order by disp.dispatched_at desc
  limit 1;
$$;

grant execute on function public.calculate_carrier_load_settlement(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- BUG 2 fix: settlement_number default, matching generate_statement_number()
-- (0029) / generate_driver_settlement_number() (0031) exactly.
-- ---------------------------------------------------------------------------
create sequence if not exists public.carrier_settlement_number_seq;
create or replace function public.generate_carrier_settlement_number()
returns text language plpgsql security definer set search_path = public as $$
begin
  return 'CS-' || lpad(nextval('public.carrier_settlement_number_seq')::text, 6, '0');
end;
$$;
grant execute on function public.generate_carrier_settlement_number() to authenticated;

alter table public.settlements
  alter column settlement_number set default public.generate_carrier_settlement_number();
