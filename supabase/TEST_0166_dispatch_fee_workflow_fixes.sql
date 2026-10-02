-- =============================================================================
-- TEST_0166_dispatch_fee_workflow_fixes.sql -- PRODUCTION TWIN ONLY
-- (supabase/ci/twin-db.sh). NEVER run on a real database. Ends in ROLLBACK.
-- Same fixture as TEST_0165 (carrier c1: L165-1 7500 and L165-2 2000
-- delivered this week, L165-3 3000 delivered 35 days ago, L165-5 1000 booked).
--
--   W1  a load marked Delivered on the LOAD page: its dispatch becomes
--       delivered (dated now) and the fee is billable this week
--   W2  load rate corrected 7500 -> 8000 after dispatch: dispatch fee 800,
--       the DRAFT invoice line follows (800, "10% of $8,000.00"), total too
--   W3  a fee that drops to zero leaves the draft
--   W4  once SENT, a later rate change does not touch the invoice
--   W5  never on both: an invoiced load is not offered to (and cannot be
--       added to) a carrier settlement; a settled load is not invoiced
--   W6  a cancelled load is not billed
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values
 ('16500000-0000-0000-0000-00000000000a', 'o165@test.invalid', 'authenticated', 'authenticated'),
 ('16500000-0000-0000-0000-00000000000c', 'a165@test.invalid', 'authenticated', 'authenticated'),
 ('16500000-0000-0000-0000-00000000000d', 'd165@test.invalid', 'authenticated', 'authenticated'),
 ('16500000-0000-0000-0000-00000000000b', 'x165@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"16500000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T165 Org', 't165-org') is not null; reset role;
select set_config('request.jwt.claims', '{"sub":"16500000-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T165 Other', 't165-other') is not null; reset role;
select id as org from public.organizations where slug = 't165-org' \gset
set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = :'org', role = 'accountant' where id = '16500000-0000-0000-0000-00000000000c';
update public.profiles set organization_id = :'org', role = 'dispatcher' where id = '16500000-0000-0000-0000-00000000000d';
set local app.bypass_profile_guard = 'false';

-- fixtures (superuser): carriers, drivers, trucks, loads, dispatches
-- both carriers: the broker pays the carrier (0167), so their fees go on Dispatch Fee Invoices
insert into public.carriers (id, organization_id, legal_name, dispatch_service_terms_days, load_proceeds_model) values
 ('16500000-0000-0000-0000-0000000000c1', :'org', 'Road Runner Trucking', 7, 'carrier_paid_directly'),
 ('16500000-0000-0000-0000-0000000000c2', :'org', 'Other Carrier', 7, 'carrier_paid_directly');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
 ('16500000-0000-0000-0000-0000000000d1', :'org', '16500000-0000-0000-0000-0000000000c1', 'Dana', 'One'),
 ('16500000-0000-0000-0000-0000000000d2', :'org', '16500000-0000-0000-0000-0000000000c2', 'Eli', 'Two');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
 ('16500000-0000-0000-0000-0000000000e1', :'org', '16500000-0000-0000-0000-0000000000c1', 'T1'),
 ('16500000-0000-0000-0000-0000000000e2', :'org', '16500000-0000-0000-0000-0000000000c2', 'T2');
insert into public.loads (id, organization_id, load_number, status, carrier_id) values
 ('16500000-0000-0000-0000-0000000000f1', :'org', 'L165-1', 'booked', '16500000-0000-0000-0000-0000000000c1'),
 ('16500000-0000-0000-0000-0000000000f2', :'org', 'L165-2', 'booked', '16500000-0000-0000-0000-0000000000c1'),
 ('16500000-0000-0000-0000-0000000000f3', :'org', 'L165-3', 'booked', '16500000-0000-0000-0000-0000000000c1'),
 ('16500000-0000-0000-0000-0000000000f4', :'org', 'L165-4', 'booked', '16500000-0000-0000-0000-0000000000c2'),
 ('16500000-0000-0000-0000-0000000000f5', :'org', 'L165-5', 'booked', '16500000-0000-0000-0000-0000000000c1');
insert into public.load_financials (load_id, organization_id, rate) values
 ('16500000-0000-0000-0000-0000000000f1', :'org', 7500), ('16500000-0000-0000-0000-0000000000f2', :'org', 2000),
 ('16500000-0000-0000-0000-0000000000f3', :'org', 3000), ('16500000-0000-0000-0000-0000000000f4', :'org', 5000),
 ('16500000-0000-0000-0000-0000000000f5', :'org', 1000);

create or replace function pg_temp.as_user(p_user uuid, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql into v;
    execute 'reset role';
    return 'ok:' || coalesce(v, '');
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $$;

-- dispatch each load as the owner (real create_dispatch), then deliver at chosen dates
do $$
declare r record; v_d uuid;
begin
  for r in select * from (values
      ('16500000-0000-0000-0000-0000000000f1'::uuid, '16500000-0000-0000-0000-0000000000c1'::uuid, '16500000-0000-0000-0000-0000000000e1'::uuid, '16500000-0000-0000-0000-0000000000d1'::uuid, 2),
      ('16500000-0000-0000-0000-0000000000f2', '16500000-0000-0000-0000-0000000000c1', '16500000-0000-0000-0000-0000000000e1', '16500000-0000-0000-0000-0000000000d1', 1),
      ('16500000-0000-0000-0000-0000000000f3', '16500000-0000-0000-0000-0000000000c1', '16500000-0000-0000-0000-0000000000e1', '16500000-0000-0000-0000-0000000000d1', 35),
      ('16500000-0000-0000-0000-0000000000f4', '16500000-0000-0000-0000-0000000000c2', '16500000-0000-0000-0000-0000000000e2', '16500000-0000-0000-0000-0000000000d2', 1)) t(load_id, carrier_id, truck_id, driver_id, days_ago) loop
    perform set_config('request.jwt.claims', '{"sub":"16500000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
    execute 'set local role authenticated';
    v_d := public.create_dispatch(r.load_id, r.carrier_id, r.truck_id, r.driver_id, null, 10, null);
    execute 'reset role';
    update public.dispatches set status = 'delivered', delivered_at = now() - make_interval(days => r.days_ago) where id = v_d;
  end loop;
end $$;

-- advances, fuel, repair
insert into public.dispatch_advances (id, organization_id, carrier_id, expense_type, amount, paid_date, status, load_id) values
 ('16500000-0000-0000-0000-0000000000a1', :'org', '16500000-0000-0000-0000-0000000000c1', 'fuel', 200, current_date - 3, 'pending', '16500000-0000-0000-0000-0000000000f1'),
 ('16500000-0000-0000-0000-0000000000a2', :'org', '16500000-0000-0000-0000-0000000000c1', 'lumper', 50, current_date - 2, 'pending', null),
 ('16500000-0000-0000-0000-0000000000a3', :'org', '16500000-0000-0000-0000-0000000000c1', 'toll', 30, current_date - 2, 'waived', null),
 ('16500000-0000-0000-0000-0000000000a4', :'org', '16500000-0000-0000-0000-0000000000c2', 'fuel', 99, current_date - 2, 'pending', null);
insert into public.fuel_logs (id, organization_id, truck_id, carrier_id, gallons, price_per_gallon, total_amount, purchased_at, station_name, state, paid_by, recovery_type, recoverable_amount) values
 ('16500000-0000-0000-0000-0000000000b1', :'org', '16500000-0000-0000-0000-0000000000e1', '16500000-0000-0000-0000-0000000000c1', 75, 4, 300, now() - interval '2 days', 'Pilot', 'TX', 'dispatch_company', 'carrier_settlement', 300),
 ('16500000-0000-0000-0000-0000000000b2', :'org', '16500000-0000-0000-0000-0000000000e1', '16500000-0000-0000-0000-0000000000c1', 50, 4, 200, now() - interval '2 days', 'Loves', 'OK', 'carrier', 'carrier_direct', 0);
insert into public.maintenance_records (id, organization_id, truck_id, carrier_id, service_type, vendor_name, cost, service_date, paid_by, recovery_type, recoverable_amount) values
 ('16500000-0000-0000-0000-0000000000b3', :'org', '16500000-0000-0000-0000-0000000000e1', '16500000-0000-0000-0000-0000000000c1', 'Tire repair', 'Roadside Co', 400, current_date - 1, 'dispatch_company', 'carrier_settlement', 400);
select set_config('t165.c1', '16500000-0000-0000-0000-0000000000c1', true);

-- W1 setup: dispatch L165-5, then the dispatcher marks the LOAD delivered (load edit form)
select set_config('request.jwt.claims', '{"sub":"16500000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
select public.create_dispatch('16500000-0000-0000-0000-0000000000f5', '16500000-0000-0000-0000-0000000000c1', '16500000-0000-0000-0000-0000000000e1', '16500000-0000-0000-0000-0000000000d1', null, 10, null) as d5 \gset
reset role;
select set_config('t166.d5', :'d5', true);
select set_config('request.jwt.claims', '{"sub":"16500000-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
update public.loads set status = 'delivered' where id = '16500000-0000-0000-0000-0000000000f5';
reset role;

do $$
declare r text; v_inv uuid; v_total numeric; d record;
  c1 uuid := '16500000-0000-0000-0000-0000000000c1';
  acct uuid := '16500000-0000-0000-0000-00000000000c';
  disp uuid := '16500000-0000-0000-0000-00000000000d';
begin
  -- W1
  select * into d from public.dispatches where id = current_setting('t166.d5')::uuid;
  if d.status::text <> 'delivered' or d.delivered_at is null or d.delivered_at::date <> current_date then
    raise exception 'FAIL W1: dispatch % %', d.status, d.delivered_at;
  end if;
  r := pg_temp.as_user(acct, format($q$select string_agg(description || '=' || amount || '@' || service_date, ',') from public.preview_carrier_fee_invoice(%L, current_date - 7, current_date) where line_type = 'dispatch_fee'$q$, c1));
  if r not like '%Load L165-5 (10% of $1,000.00)=100.00@' || current_date || '%' then raise exception 'FAIL W1 preview: %', r; end if;
  raise notice 'OK W1: load marked Delivered on the load page -> dispatch delivered today; its 100.00 fee is billable.';

  -- W2
  r := pg_temp.as_user(acct, format('select public.create_carrier_fee_invoice(%L, current_date - 7, current_date)::text', c1));
  if r not like 'ok:%' then raise exception 'FAIL W2 create: %', r; end if;
  v_inv := substr(r, 4)::uuid;
  perform set_config('t166.inv', v_inv::text, true);
  select total_amount into v_total from public.carrier_fee_invoices where id = v_inv;
  if v_total <> 2000 then raise exception 'FAIL W2 setup total %', v_total; end if;   -- 1900 (TEST_0165) + 100
  r := pg_temp.as_user(disp, $q$update public.load_financials set rate = 8000 where load_id = '16500000-0000-0000-0000-0000000000f1' returning rate::text$q$);
  if r <> 'ok:8000.00' then raise exception 'FAIL W2 rate: %', r; end if;
  if (select df.dispatch_fee_amount from public.dispatch_financials df join public.dispatches x on x.id = df.dispatch_id where x.load_id = '16500000-0000-0000-0000-0000000000f1') <> 800 then
    raise exception 'FAIL W2: dispatch fee did not follow the rate';
  end if;
  if not exists (select 1 from public.carrier_fee_invoice_lines where invoice_id = v_inv and load_number = 'L165-1' and line_type = 'dispatch_fee'
                  and amount = 800 and load_rate = 8000 and description = 'Dispatch fee -- Load L165-1 (10% of $8,000.00)') then
    raise exception 'FAIL W2: draft line %', (select amount || ' ' || description from public.carrier_fee_invoice_lines where invoice_id = v_inv and load_number = 'L165-1' and line_type = 'dispatch_fee');
  end if;
  if (select total_amount from public.carrier_fee_invoices where id = v_inv) <> 2050 then raise exception 'FAIL W2 total %', (select total_amount from public.carrier_fee_invoices where id = v_inv); end if;
  raise notice 'OK W2: rate 7500 -> 8000: dispatch fee 800.00, draft line and total follow (2050.00).';

  -- W3
  update public.dispatch_financials set dispatch_fee_percentage = 0
   where dispatch_id = (select id from public.dispatches where load_id = '16500000-0000-0000-0000-0000000000f2');
  if exists (select 1 from public.carrier_fee_invoice_lines where invoice_id = v_inv and load_number = 'L165-2' and line_type = 'dispatch_fee') then raise exception 'FAIL W3: zero-fee line stayed'; end if;
  if (select total_amount from public.carrier_fee_invoices where id = v_inv) <> 1850 then raise exception 'FAIL W3 total'; end if;
  raise notice 'OK W3: a fee that drops to 0 leaves the draft (total 1850.00).';

  -- W4
  r := pg_temp.as_user(acct, format('select public.send_carrier_fee_invoice(%L)::text', v_inv));
  if r not like 'ok:%' then raise exception 'FAIL W4 send: %', r; end if;
  r := pg_temp.as_user(disp, $q$update public.load_financials set rate = 9000 where load_id = '16500000-0000-0000-0000-0000000000f1' returning rate::text$q$);
  if r <> 'ok:9000.00' then raise exception 'FAIL W4 rate: %', r; end if;
  if (select amount from public.carrier_fee_invoice_lines where invoice_id = v_inv and load_number = 'L165-1' and line_type = 'dispatch_fee') <> 800
     or (select total_amount from public.carrier_fee_invoices where id = v_inv) <> 1850 then
    raise exception 'FAIL W4: a sent invoice changed';
  end if;
  if (select df.dispatch_fee_amount from public.dispatch_financials df join public.dispatches x on x.id = df.dispatch_id where x.load_id = '16500000-0000-0000-0000-0000000000f1') <> 900 then
    raise exception 'FAIL W4: dispatch fee should be 900 now';
  end if;
  raise notice 'OK W4: after sending, rate -> 9000 changes the dispatch fee (900) but not the sent invoice (800, total 1850).';
end $$;

-- W5: carrier settlement for the old load L165-3 (delivered 35 days ago)
insert into public.settlements (id, organization_id, carrier_id, status, period_start, period_end)
values ('16600000-0000-0000-0000-0000000000a1', :'org', '16500000-0000-0000-0000-0000000000c1', 'draft', current_date - 60, current_date - 20);
insert into public.settlement_line_items (organization_id, settlement_id, item_type, description, amount, load_id, dispatch_id, load_number, carrier_rate)
select :'org', '16600000-0000-0000-0000-0000000000a1', 'load_pay', 'Load L165-3', 2700, d.load_id, d.id, 'L165-3', 2700
from public.dispatches d where d.load_id = '16500000-0000-0000-0000-0000000000f3';

-- W6: a delivered load that is then cancelled
insert into public.loads (id, organization_id, load_number, status, carrier_id) values
 ('16500000-0000-0000-0000-0000000000f6', :'org', 'L165-6', 'booked', '16500000-0000-0000-0000-0000000000c1');
insert into public.load_financials (load_id, organization_id, rate) values ('16500000-0000-0000-0000-0000000000f6', :'org', 4000);
select set_config('request.jwt.claims', '{"sub":"16500000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
select public.create_dispatch('16500000-0000-0000-0000-0000000000f6', '16500000-0000-0000-0000-0000000000c1', '16500000-0000-0000-0000-0000000000e1', '16500000-0000-0000-0000-0000000000d1', null, 10, null) is not null;
reset role;
update public.dispatches set status = 'delivered', delivered_at = now() - interval '40 days' where load_id = '16500000-0000-0000-0000-0000000000f6';
update public.loads set status = 'cancelled' where id = '16500000-0000-0000-0000-0000000000f6';

do $$
declare r text;
  c1 uuid := '16500000-0000-0000-0000-0000000000c1';
  acct uuid := '16500000-0000-0000-0000-00000000000c';
  owner uuid := '16500000-0000-0000-0000-00000000000a';
begin
  -- W5: the invoiced load L165-1 is not offered to a settlement for this week
  r := pg_temp.as_user(owner, format($q$select coalesce(string_agg(load_number, ',' order by load_number), '') from public.get_payable_carrier_loads(%L, current_date - 7, current_date)$q$, c1));
  -- (since 0167 a "broker pays the carrier" load is never offered to a settlement at all)
  if r like '%L165-1%' or r like '%L165-2%' or r like '%L165-5%' then raise exception 'FAIL W5 payable: %', r; end if;
  begin
    insert into public.settlement_line_items (organization_id, settlement_id, item_type, description, amount, load_id, load_number, carrier_rate)
    select organization_id, '16600000-0000-0000-0000-0000000000a1', 'load_pay', 'Load L165-1', 7200, '16500000-0000-0000-0000-0000000000f1', 'L165-1', 7200
      from public.carriers where id = c1;
    raise exception 'FAIL W5: an invoiced load was added to a settlement';
  exception when others then
    if sqlerrm not like '%already billed to the carrier on a Dispatch Fee Invoice%' then raise; end if;
  end;
  -- the settled load L165-3 is not offered on a fee invoice for its period
  r := pg_temp.as_user(acct, format($q$select coalesce(string_agg(description, ','), '') from public.preview_carrier_fee_invoice(%L, current_date - 60, current_date - 20) where line_type = 'dispatch_fee'$q$, c1));
  if r like '%L165-3%' then raise exception 'FAIL W5 preview: %', r; end if;
  raise notice 'OK W5: an invoiced load is not offered to (or accepted by) a carrier settlement; a settled load is not invoiced.';

  -- W6
  if r like '%L165-6%' then raise exception 'FAIL W6: cancelled load billed: %', r; end if;
  raise notice 'OK W6: a cancelled load is not billed.';
end $$;

do $$ begin raise notice 'ALL 0166 CHECKS PASSED'; end $$;
rollback;
