-- =============================================================================
-- TEST_0163_settle_by_delivery_date.sql -- PRODUCTION TWIN ONLY
-- (supabase/ci/twin-db.sh). NEVER run on a real database. Ends in ROLLBACK.
--
-- A load dispatched 10 days ago and delivered today:
--   S1  carrier + driver "payable loads" find it in a period covering TODAY
--   S2  ...and NOT in a period covering only the dispatch day
--   S3  delivery_date on carrier pay / driver pay / profitability = today
--   S4  a dispatch without delivered_at still falls back to its dispatch date
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values
 ('16300000-0000-0000-0000-00000000000a', 'o163@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"16300000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T163 Org', 't163-org') is not null; reset role;
select id as org from public.organizations where slug = 't163-org' \gset

insert into public.carriers (id, organization_id, legal_name) values ('16300000-0000-0000-0000-0000000000c1', :'org', 'C163');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values ('16300000-0000-0000-0000-0000000000d1', :'org', '16300000-0000-0000-0000-0000000000c1', 'D', 'One');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values ('16300000-0000-0000-0000-0000000000a1', :'org', '16300000-0000-0000-0000-0000000000c1', 'T163');
insert into public.driver_pay_rates (organization_id, driver_id, pay_method, percentage_rate, effective_from) values (:'org', '16300000-0000-0000-0000-0000000000d1', 'percentage', 20, current_date - 60);
-- two loads: L1 delivered today (dispatched 10 days ago); L2 delivered_at unknown (dispatched 20 days ago)
insert into public.loads (id, organization_id, load_number, status, total_miles) values
 ('16300000-0000-0000-0000-0000000000f1', :'org', 'T163-1', 'booked', 500),
 ('16300000-0000-0000-0000-0000000000f2', :'org', 'T163-2', 'booked', 400);
insert into public.load_financials (load_id, organization_id, rate) values ('16300000-0000-0000-0000-0000000000f1', :'org', 2000), ('16300000-0000-0000-0000-0000000000f2', :'org', 1000);

select set_config('request.jwt.claims', '{"sub":"16300000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
select public.create_dispatch('16300000-0000-0000-0000-0000000000f1', '16300000-0000-0000-0000-0000000000c1', '16300000-0000-0000-0000-0000000000a1', '16300000-0000-0000-0000-0000000000d1', null, 10, null) as d1 \gset
reset role;
update public.dispatches set dispatched_at = now() - interval '10 days', status = 'delivered', delivered_at = now() where id = :'d1';
set local role authenticated;
select public.create_dispatch('16300000-0000-0000-0000-0000000000f2', '16300000-0000-0000-0000-0000000000c1', '16300000-0000-0000-0000-0000000000a1', '16300000-0000-0000-0000-0000000000d1', null, 10, null) as d2 \gset
reset role;
update public.dispatches set dispatched_at = now() - interval '20 days', status = 'delivered', delivered_at = null where id = :'d2';

set local role authenticated;
create temp table r163 as
select 'carrier_today' k, count(*) filter (where load_number = 'T163-1') n from public.get_payable_carrier_loads('16300000-0000-0000-0000-0000000000c1', current_date, current_date)
union all select 'driver_today', count(*) filter (where load_number = 'T163-1') from public.get_payable_loads('16300000-0000-0000-0000-0000000000d1', current_date, current_date)
union all select 'carrier_dispatch_day', count(*) filter (where load_number = 'T163-1') from public.get_payable_carrier_loads('16300000-0000-0000-0000-0000000000c1', current_date - 10, current_date - 10)
union all select 'driver_dispatch_day', count(*) filter (where load_number = 'T163-1') from public.get_payable_loads('16300000-0000-0000-0000-0000000000d1', current_date - 10, current_date - 10)
union all select 'carrier_fallback', count(*) filter (where load_number = 'T163-2') from public.get_payable_carrier_loads('16300000-0000-0000-0000-0000000000c1', current_date - 20, current_date - 20)
union all select 'carrier_date_is_today', count(*) from public.calculate_carrier_load_settlement('16300000-0000-0000-0000-0000000000c1', '16300000-0000-0000-0000-0000000000f1') where delivery_date = current_date
union all select 'driver_date_is_today', count(*) from public.calculate_driver_load_pay('16300000-0000-0000-0000-0000000000d1', '16300000-0000-0000-0000-0000000000f1') where delivery_date = current_date
union all select 'profit_date_is_today', count(*) from public.get_load_profitability('16300000-0000-0000-0000-0000000000f1') where delivery_date = current_date;
reset role;

do $$
declare got text := (select string_agg(k || '=' || n, ' ' order by k) from r163);
begin
  if got <> 'carrier_date_is_today=1 carrier_dispatch_day=0 carrier_fallback=1 carrier_today=1 driver_date_is_today=1 driver_dispatch_day=0 driver_today=1 profit_date_is_today=1' then
    raise exception 'FAIL 0163: %', got;
  end if;
  raise notice 'OK S1: carrier + driver payable lists find the load in the period of its delivery day.';
  raise notice 'OK S2: it is NOT in the period of its dispatch day.';
  raise notice 'OK S3: delivery_date = delivery day on carrier pay, driver pay and profitability.';
  raise notice 'OK S4: a dispatch without a delivered time still falls back to its dispatch date.';
  raise notice 'ALL 0163 CHECKS PASSED';
end $$;
rollback;
