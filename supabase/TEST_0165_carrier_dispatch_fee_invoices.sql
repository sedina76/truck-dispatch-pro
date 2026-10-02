-- =============================================================================
-- TEST_0165_carrier_dispatch_fee_invoices.sql -- PRODUCTION TWIN ONLY
-- (supabase/ci/twin-db.sh). NEVER run on a real database. Ends in ROLLBACK.
--
-- One carrier, one week: 2 loads delivered in the week (7500 @10%, 2000 @10%),
-- 1 delivered last month, 1 load of ANOTHER carrier; advances (fuel 200,
-- lumper 50, a waived 30, another carrier's 99); fuel paid by us to recover
-- (300) and fuel the carrier paid itself; a repair to recover (400).
--   F1  a dispatcher cannot preview or create carrier invoices
--   F2  preview = exactly 6 lines: fees 750 + 200, advances 200 + 50,
--       fuel 300, repair 400 = 1900.00
--   F3  create: DFI-YYYY-00001, total 1900.00, draft; advances marked
--       deducted; fuel/repair recovery status 'recovered'
--   F4  nothing is billable twice: same period again -> refused; a carrier
--       settlement cannot also recover the repair
--   F5  send: status sent, issue date today, due date = today + terms
--   F6  payments: 1000 -> partially_paid; overpayment refused; 900 -> paid;
--       an invoice with payments cannot be voided
--   F7  void a draft releases everything (fee billable again, advance back
--       to pending, fuel balance restored) and keeps its total on record
--   F8  removing a line from a draft releases that advance
--   F9  no direct writes; another company sees nothing
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

do $$
declare r text; v_total numeric; v_n int; v_inv uuid; v_num text; i record;
  c1 uuid := '16500000-0000-0000-0000-0000000000c1';
  acct uuid := '16500000-0000-0000-0000-00000000000c';
begin
  -- F1
  r := pg_temp.as_user('16500000-0000-0000-0000-00000000000d', format('select count(*)::text from public.preview_carrier_fee_invoice(%L, current_date - 7, current_date)', c1));
  if r not like 'err:%owner, admin or accountant%' then raise exception 'FAIL F1 preview: %', r; end if;
  r := pg_temp.as_user('16500000-0000-0000-0000-00000000000d', format('select public.create_carrier_fee_invoice(%L, current_date - 7, current_date)::text', c1));
  if r not like 'err:%owner, admin or accountant%' then raise exception 'FAIL F1 create: %', r; end if;
  raise notice 'OK F1: a dispatcher cannot preview or create carrier invoices.';

  -- F2
  r := pg_temp.as_user(acct, format($q$select count(*) || '|' || sum(amount) || '|' || string_agg(line_type || '=' || amount, ',' order by line_type, amount)
                                       from public.preview_carrier_fee_invoice(%L, current_date - 7, current_date)$q$, c1));
  if r <> 'ok:6|1900.00|advance=50.00,advance=200.00,dispatch_fee=200.00,dispatch_fee=750.00,fuel=300.00,maintenance=400.00' then
    raise exception 'FAIL F2 preview: %', r;
  end if;
  raise notice 'OK F2: preview = fees 750 + 200, advances 200 + 50, fuel 300, repair 400 = 1900.00 (last month, other carrier, waived and carrier-paid excluded).';

  -- F3
  r := pg_temp.as_user(acct, format('select public.create_carrier_fee_invoice(%L, current_date - 7, current_date, %L)::text', c1, 'Week 40'));
  if r not like 'ok:%' then raise exception 'FAIL F3 create: %', r; end if;
  v_inv := substr(r, 4)::uuid;
  select * into i from public.carrier_fee_invoices where id = v_inv;
  if i.invoice_number <> 'DFI-' || extract(year from current_date)::int || '-00001' or i.total_amount <> 1900 or i.status <> 'draft' or i.carrier_id <> c1 then
    raise exception 'FAIL F3: % % % %', i.invoice_number, i.total_amount, i.status, i.carrier_id;
  end if;
  if (select count(*) from public.dispatch_advances where deducted_carrier_fee_invoice_id = v_inv and status = 'deducted') <> 2
     or (select status::text from public.dispatch_advances where id = '16500000-0000-0000-0000-0000000000a3') <> 'waived' then
    raise exception 'FAIL F3: advances not marked correctly';
  end if;
  if (select recovery_status::text || recovered_amount from public.fuel_logs where id = '16500000-0000-0000-0000-0000000000b1') <> 'recovered300.00'
     or (select recovery_status::text || recovered_amount from public.maintenance_records where id = '16500000-0000-0000-0000-0000000000b3') <> 'recovered400.00' then
    raise exception 'FAIL F3: recovery caches not updated';
  end if;
  raise notice 'OK F3: % created as draft for 1900.00; advances marked deducted; fuel and repair show recovered.', i.invoice_number;
  perform set_config('t165.inv', v_inv::text, true);

  -- F4
  r := pg_temp.as_user(acct, format('select public.create_carrier_fee_invoice(%L, current_date - 7, current_date)::text', c1));
  if r not like 'err:Nothing to bill%' then raise exception 'FAIL F4 second invoice: %', r; end if;
  insert into public.settlements (id, organization_id, carrier_id, status) values ('16500000-0000-0000-0000-0000000000a9', i.organization_id, c1, 'draft');
  begin
    insert into public.settlement_line_items (organization_id, settlement_id, item_type, description, amount, linked_maintenance_id)
      values (i.organization_id, '16500000-0000-0000-0000-0000000000a9', 'deduction', 'repair', 100, '16500000-0000-0000-0000-0000000000b3');
    raise exception 'FAIL F4: settlement recovered the repair again';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like '%cannot exceed the remaining recoverable balance%' then raise exception 'FAIL F4: unexpected %', sqlerrm; end if;
  end;
  raise notice 'OK F4: same period again -> "Nothing to bill"; a settlement cannot recover the already-invoiced repair.';

  -- F5
  r := pg_temp.as_user(acct, format('select public.send_carrier_fee_invoice(%L)::text', v_inv));
  if r not like 'ok:%' then raise exception 'FAIL F5: %', r; end if;
  select * into i from public.carrier_fee_invoices where id = v_inv;
  if i.status <> 'sent' or i.issue_date <> current_date or i.due_date <> current_date + 7 or i.sent_at is null then raise exception 'FAIL F5: % % %', i.status, i.issue_date, i.due_date; end if;
  raise notice 'OK F5: sent; issued today, due in 7 days (carrier terms).';

  -- F6
  r := pg_temp.as_user(acct, format($q$select public.record_carrier_fee_invoice_payment(%L, 1000, 'ach', current_date, 'ACH-1', null)::text$q$, v_inv));
  if r not like 'ok:%' then raise exception 'FAIL F6 pay1: %', r; end if;
  if (select status || balance_due from public.carrier_fee_invoices where id = v_inv) <> 'partially_paid900.00' then raise exception 'FAIL F6 after pay1'; end if;
  r := pg_temp.as_user(acct, format($q$select public.record_carrier_fee_invoice_payment(%L, 1000, 'ach', current_date, null, null)::text$q$, v_inv));
  if r not like 'err:Payment exceeds the balance due (900.00)%' then raise exception 'FAIL F6 overpay: %', r; end if;
  r := pg_temp.as_user(acct, format('select public.void_carrier_fee_invoice(%L, %L)::text', v_inv, 'test'));
  if r not like 'err:%payments recorded%' then raise exception 'FAIL F6 void with payments: %', r; end if;
  r := pg_temp.as_user(acct, format($q$select public.record_carrier_fee_invoice_payment(%L, 900, 'check', current_date, 'CHK-2', null)::text$q$, v_inv));
  if (select status || balance_due from public.carrier_fee_invoices where id = v_inv) <> 'paid0.00' or (select paid_at from public.carrier_fee_invoices where id = v_inv) is null then
    raise exception 'FAIL F6 after pay2: %', r;
  end if;
  raise notice 'OK F6: 1000 -> partially paid (900 due); 1000 more refused; void refused while paid; 900 -> paid.';
end $$;

-- F7 / F8: a new delivered load + advance -> a draft; remove a line; void the draft
insert into public.dispatch_advances (id, organization_id, carrier_id, expense_type, amount, paid_date, status) values
 ('16500000-0000-0000-0000-0000000000a5', :'org', '16500000-0000-0000-0000-0000000000c1', 'scale', 15, current_date, 'pending'),
 ('16500000-0000-0000-0000-0000000000a6', :'org', '16500000-0000-0000-0000-0000000000c1', 'parking', 25, current_date, 'pending');
update public.fuel_logs set recoverable_amount = 300 where id = '16500000-0000-0000-0000-0000000000b1';
do $$
declare v_d uuid; r text; v_inv uuid; v_line uuid;
  c1 uuid := '16500000-0000-0000-0000-0000000000c1';
  acct uuid := '16500000-0000-0000-0000-00000000000c';
begin
  perform set_config('request.jwt.claims', '{"sub":"16500000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_d := public.create_dispatch('16500000-0000-0000-0000-0000000000f5', c1, '16500000-0000-0000-0000-0000000000e1', '16500000-0000-0000-0000-0000000000d1', null, 10, null);
  execute 'reset role';
  update public.dispatches set status = 'delivered', delivered_at = now() where id = v_d;

  r := pg_temp.as_user(acct, format('select public.create_carrier_fee_invoice(%L, current_date, current_date)::text', c1));
  if r not like 'ok:%' then raise exception 'FAIL F7 create: %', r; end if;
  v_inv := substr(r, 4)::uuid;
  if (select total_amount from public.carrier_fee_invoices where id = v_inv) <> 140 then   -- fee 100 + 15 + 25
    raise exception 'FAIL F7: draft total %', (select total_amount from public.carrier_fee_invoices where id = v_inv);
  end if;
  if (select invoice_number from public.carrier_fee_invoices where id = v_inv) not like '%-00002' then raise exception 'FAIL F7: numbering'; end if;

  -- F8: remove the parking line
  select id into v_line from public.carrier_fee_invoice_lines where invoice_id = v_inv and dispatch_advance_id = '16500000-0000-0000-0000-0000000000a6';
  r := pg_temp.as_user(acct, format('select public.remove_carrier_fee_invoice_line(%L)::text', v_line));
  if r not like 'ok:%' or (select status::text from public.dispatch_advances where id = '16500000-0000-0000-0000-0000000000a6') <> 'pending'
     or (select total_amount from public.carrier_fee_invoices where id = v_inv) <> 115 then
    raise exception 'FAIL F8: %', r;
  end if;
  raise notice 'OK F8: removing a line from a draft releases that advance (total 140 -> 115).';

  -- F7: void the draft
  r := pg_temp.as_user(acct, format('select public.void_carrier_fee_invoice(%L, %L)::text', v_inv, 'wrong period'));
  if r not like 'ok:%' then raise exception 'FAIL F7 void: %', r; end if;
  if (select status || total_amount from public.carrier_fee_invoices where id = v_inv) <> 'void115.00' then raise exception 'FAIL F7: void record'; end if;
  if (select status::text from public.dispatch_advances where id = '16500000-0000-0000-0000-0000000000a5') <> 'pending' then raise exception 'FAIL F7: advance not released'; end if;
  r := pg_temp.as_user(acct, format($q$select count(*)::text from public.preview_carrier_fee_invoice(%L, current_date, current_date) where line_type = 'dispatch_fee'$q$, c1));
  if r <> 'ok:1' then raise exception 'FAIL F7: fee not billable again (%)', r; end if;
  raise notice 'OK F7: voiding a draft releases the fee and advances; the void keeps its total (115.00) on record.';
end $$;

-- F9
do $$
declare r text; v_inv uuid := current_setting('t165.inv')::uuid;
begin
  r := pg_temp.as_user('16500000-0000-0000-0000-00000000000a', format($q$insert into public.carrier_fee_invoices (organization_id, carrier_id, invoice_number, period_start, period_end) values (public.current_org_id(), %L, 'X-1', current_date, current_date) returning id::text$q$, current_setting('t165.c1')));
  if r not like 'err:permission denied%' then raise exception 'FAIL F9 direct insert: %', r; end if;
  r := pg_temp.as_user('16500000-0000-0000-0000-00000000000a', format($q$update public.carrier_fee_invoices set total_amount = 1 where id = %L returning id::text$q$, v_inv));
  if r not like 'err:permission denied%' then raise exception 'FAIL F9 direct update: %', r; end if;
  r := pg_temp.as_user('16500000-0000-0000-0000-00000000000b', format($q$select ((select count(*) from public.carrier_fee_invoices) + (select count(*) from public.carrier_fee_invoice_lines))::text$q$));
  if r <> 'ok:0' then raise exception 'FAIL F9: other company sees %', r; end if;
  r := pg_temp.as_user('16500000-0000-0000-0000-00000000000b', format('select public.send_carrier_fee_invoice(%L)::text', v_inv));
  if r not like 'err:Invoice not found%' then raise exception 'FAIL F9: other company acted: %', r; end if;
  raise notice 'OK F9: no direct writes (functions only); another company sees and changes nothing.';
  raise notice 'ALL 0165 CHECKS PASSED';
end $$;
rollback;
