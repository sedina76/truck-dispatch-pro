-- =============================================================================
-- TEST_CORE_WORKFLOW_E2E.sql -- PRODUCTION TWIN ONLY (supabase/ci/twin-db.sh).
-- NEVER run on a real database. One transaction, ends in ROLLBACK.
--
-- The core money loop, performed exactly the way the app's server code does
-- it (same RPCs / parameters / table writes, same client role), as real
-- users under RLS: owner, dispatcher, accountant, and the driver portal
-- (service role).
--
--   W1  dispatcher creates a load with stops (create_load_with_stops)
--   W2  dispatcher dispatches it (create_dispatch): fee 10% -> 750 / 6750
--   W3  board status moves; driver portal marks delivered (service role)
--   W4  delivery auto-creates a draft invoice for the exact rate
--   W5  invoice cannot be sent before the POD is verified; POD upload +
--       verify; then it can be sent
--   W6  payments: partial -> partially_paid, overpayment refused, rest ->
--       paid, void -> back to partially_paid, re-pay -> paid
--   W7  broker statement for the period: charges, payments, closing balance
--   W8  carrier settlement: payable load, advance deducted, approve, pay
--   W9  driver settlement (25%): payable load, approve, pay
--   W10 the load cannot be settled twice; ready-to-bill excludes it
--   W11 another company sees none of it
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

create or replace function pg_temp.login(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
end $$;
create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like p_like then raise exception 'expected error like "%", got "%"', p_like, sqlerrm; end if;
    return;
  end;
  raise exception 'expected an error like "%" but the statement succeeded: %', p_like, p_sql;
end $$;
grant execute on function pg_temp.expect_error(text, text) to authenticated, service_role;

-- ---- people & company -------------------------------------------------------
insert into auth.users (id, email, aud, role) values
 ('e2e00000-0000-0000-0000-00000000000a', 'owner@e2e.invalid', 'authenticated', 'authenticated'),
 ('e2e00000-0000-0000-0000-00000000000d', 'disp@e2e.invalid',  'authenticated', 'authenticated'),
 ('e2e00000-0000-0000-0000-00000000000c', 'acct@e2e.invalid',  'authenticated', 'authenticated'),
 ('e2e00000-0000-0000-0000-00000000000b', 'other@e2e.invalid', 'authenticated', 'authenticated');
select pg_temp.login('e2e00000-0000-0000-0000-00000000000a');
select public.create_organization_with_owner('E2E Freight', 'e2e-freight') is not null as org_created;
reset role;
select pg_temp.login('e2e00000-0000-0000-0000-00000000000b');
select public.create_organization_with_owner('E2E Other Co', 'e2e-other') is not null as other_org_created;
reset role;
set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = (select id from public.organizations where slug = 'e2e-freight'), role = 'dispatcher' where id = 'e2e00000-0000-0000-0000-00000000000d';
update public.profiles set organization_id = (select id from public.organizations where slug = 'e2e-freight'), role = 'accountant' where id = 'e2e00000-0000-0000-0000-00000000000c';
set local app.bypass_profile_guard = 'false';
select id as org from public.organizations where slug = 'e2e-freight' \gset

-- owner sets up partners and equipment through the normal screens (RLS)
select pg_temp.login('e2e00000-0000-0000-0000-00000000000a');
insert into public.brokers (organization_id, company_name, legal_name, email) values (:'org', 'Acme Brokerage', 'Acme Brokerage LLC', 'ap@acme.invalid') returning id as broker \gset
insert into public.carriers (organization_id, legal_name) values (:'org', 'Road Runner Trucking') returning id as carrier \gset
insert into public.drivers (organization_id, carrier_id, first_name, last_name) values (:'org', :'carrier', 'Dana', 'Driver') returning id as driver \gset
insert into public.trucks (organization_id, carrier_id, unit_number) values (:'org', :'carrier', 'T-100') returning id as truck \gset
insert into public.driver_pay_rates (organization_id, driver_id, pay_method, percentage_rate, effective_from)
  values (:'org', :'driver', 'percentage', 25, current_date - 30);
reset role;

-- ---- W1 load ---------------------------------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000d');
select public.create_load_with_stops(
  jsonb_build_object('broker_id', :'broker', 'customer_id', null, 'status', 'booked', 'commodity', 'Steel coils', 'weight_lbs', 42000,
                     'equipment_type', 'flatbed', 'total_miles', 1000, 'rate', 7500, 'rate_confirmation_number', 'RC-1', 'special_instructions', null),
  jsonb_build_array(
    jsonb_build_object('stop_type', 'pickup', 'stop_sequence', 1, 'facility_name', 'Mill', 'city', 'Gary', 'state', 'IN', 'scheduled_at', (now() - interval '2 days')::text, 'timezone', 'America/Chicago', 'timezone_source', 'manual'),
    jsonb_build_object('stop_type', 'delivery', 'stop_sequence', 2, 'facility_name', 'Yard', 'city', 'Dallas', 'state', 'TX', 'scheduled_at', (now() - interval '1 day')::text, 'timezone', 'America/Chicago', 'timezone_source', 'manual'))
) as load \gset
reset role;
do $$ declare l uuid := current_setting('e2e.load', true)::uuid; begin end $$;
select set_config('e2e.load', :'load', true);
do $$
declare v_load uuid := current_setting('e2e.load')::uuid;
begin
  if (select rate from public.load_financials where load_id = v_load) <> 7500.00 then raise exception 'FAIL W1: rate is %', (select rate from public.load_financials where load_id = v_load); end if;
  if (select load_number from public.loads where id = v_load) is null then raise exception 'FAIL W1: no load number'; end if;
  if (select count(*) from public.load_stops where load_id = v_load) <> 2 then raise exception 'FAIL W1: stops'; end if;
  raise notice 'OK W1: load % created by the dispatcher; rate exactly 7500.00; 2 stops.', (select load_number from public.loads where id = v_load);
end $$;

-- ---- W2 dispatch ---------------------------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000d');
select public.create_dispatch(:'load', :'carrier', :'truck', :'driver', null, 10, 'Call on arrival') as dispatch \gset
reset role;
select set_config('e2e.dispatch', :'dispatch', true);
do $$
declare v_load uuid := current_setting('e2e.load')::uuid; v_d uuid := current_setting('e2e.dispatch')::uuid; f record;
begin
  select * into f from public.dispatch_financials where dispatch_id = v_d;
  if f.load_rate <> 7500 or f.dispatch_fee_amount <> 750 or f.carrier_net_amount <> 6750 then
    raise exception 'FAIL W2: financials % / % / %', f.load_rate, f.dispatch_fee_amount, f.carrier_net_amount;
  end if;
  if (select status::text from public.loads where id = v_load) <> 'dispatched' then raise exception 'FAIL W2: load status'; end if;
  if (select carrier_id from public.loads where id = v_load) is distinct from (select carrier_id from public.dispatches where id = v_d) then raise exception 'FAIL W2: load carrier not set'; end if;
  if (select financial_dispatch_id from public.loads where id = v_load) is distinct from v_d then raise exception 'FAIL W2: financial dispatch not set'; end if;
  raise notice 'OK W2: dispatched; fee 10%% -> 750.00, carrier net 6750.00; load carrier + financial dispatch set.';
end $$;

-- ---- W3 status moves (board, then driver portal delivers) ------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000d');
select public.transition_dispatch_status(:'dispatch', 'accepted');
select public.transition_dispatch_status(:'dispatch', 'en_route_to_pickup');
select public.transition_dispatch_status(:'dispatch', 'at_pickup');
select public.transition_dispatch_status(:'dispatch', 'loaded');
select public.transition_dispatch_status(:'dispatch', 'en_route_to_delivery');
select public.transition_dispatch_status(:'dispatch', 'at_delivery');
reset role;
-- driver portal: service-role update of the driver's own dispatch (driver-portal/actions.ts)
select pg_temp.service();
update public.dispatches set status = 'delivered', delivered_at = now() where id = :'dispatch' and driver_id = :'driver';
insert into public.load_tracking_events (organization_id, load_id, dispatch_id, status, source, reported_by, notes)
  values (:'org', :'load', :'dispatch', null, 'driver_app', null, 'Status updated to delivered');
reset role;
do $$
declare v_load uuid := current_setting('e2e.load')::uuid; v_d uuid := current_setting('e2e.dispatch')::uuid; d record;
begin
  select * into d from public.dispatches where id = v_d;
  if d.status::text <> 'delivered' or d.en_route_pickup_at is null or d.loaded_at is null or d.in_transit_at is null or d.delivered_at is null then
    raise exception 'FAIL W3: dispatch % timestamps % % % %', d.status, d.en_route_pickup_at, d.loaded_at, d.in_transit_at, d.delivered_at;
  end if;
  if (select status::text from public.loads where id = v_load) <> 'delivered' then raise exception 'FAIL W3: load is %', (select status from public.loads where id = v_load); end if;
  raise notice 'OK W3: board moves accepted..at_delivery; driver portal delivered; load delivered; timestamps stamped.';
end $$;

-- ---- W4 auto invoice ----------------------------------------------------------------
select id as invoice from public.invoices where load_id = :'load' \gset
select set_config('e2e.invoice', :'invoice', true);
do $$
declare i record; v_inv uuid := current_setting('e2e.invoice')::uuid;
begin
  select * into i from public.invoices where id = v_inv;
  if i.status::text <> 'draft' or i.total_amount <> 7500 or i.subtotal_amount <> 7500 or i.balance_due <> 7500 then
    raise exception 'FAIL W4: invoice % total % balance %', i.status, i.total_amount, i.balance_due;
  end if;
  if i.broker_id is distinct from (select broker_id from public.loads where id = i.load_id) or i.dispatch_id is null then raise exception 'FAIL W4: party/dispatch'; end if;
  if i.invoice_number !~ ('^INV-' || extract(year from current_date)::int || '-[0-9]{5}$') then raise exception 'FAIL W4: number %', i.invoice_number; end if;
  if (select count(*) from public.invoice_line_items where invoice_id = v_inv) <> 1 then raise exception 'FAIL W4: line items'; end if;
  raise notice 'OK W4: delivery auto-created draft invoice % for exactly 7500.00 (1 line, broker + dispatch linked).', i.invoice_number;
end $$;

-- ---- W5 POD gate -------------------------------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
select pg_temp.expect_error(format('update public.invoices set status = %L where id = %L', 'sent', :'invoice'), '%Proof of Delivery%');
reset role;
-- driver uploads POD (service role, upload-pod route)
select pg_temp.service();
insert into public.documents (organization_id, entity_type, entity_id, document_type, file_name, file_path, file_size_bytes, mime_type, uploaded_by)
  values (:'org', 'load', :'load', 'pod', 'pod.jpg', :'org' || '/' || :'load' || '/1_pod.jpg', 12345, 'image/jpeg', null) returning id as pod \gset
reset role;
-- dispatcher verifies it (verifyPod)
select pg_temp.login('e2e00000-0000-0000-0000-00000000000d');
update public.documents set is_verified = true, verified_by = 'e2e00000-0000-0000-0000-00000000000d', verified_at = now(), rejected_at = null, rejected_by = null, rejection_reason = null where id = :'pod';
select (r.ready_to_bill)::text as ready from public.get_load_billing_readiness(:'load') r \gset
reset role;
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
update public.invoices set status = 'sent' where id = :'invoice';
reset role;
do $$ begin
  if (select status::text from public.invoices where id = current_setting('e2e.invoice')::uuid) <> 'sent' then raise exception 'FAIL W5: invoice not sent'; end if;
  raise notice 'OK W5: invoice refused before POD verification; driver POD uploaded, dispatcher verified, accountant sent it.';
end $$;

-- ---- W6 payments -------------------------------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
insert into public.payments (organization_id, invoice_id, amount, method, received_at, reference_number, recorded_by)
  values (:'org', :'invoice', 3000, 'ach', now(), 'ACH-1', 'e2e00000-0000-0000-0000-00000000000c') returning id as pay1 \gset
select pg_temp.expect_error(format('insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (%L, %L, 5000, %L, now())', :'org', :'invoice', 'ach'), '%');
reset role;
do $$ declare i record; begin
  select * into i from public.invoices where id = current_setting('e2e.invoice')::uuid;
  if i.status::text <> 'partially_paid' or i.amount_paid <> 3000 or i.balance_due <> 4500 then raise exception 'FAIL W6a: % paid % balance %', i.status, i.amount_paid, i.balance_due; end if;
end $$;
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
insert into public.payments (organization_id, invoice_id, amount, method, received_at, reference_number, recorded_by)
  values (:'org', :'invoice', 4500, 'check', now(), 'CHK-2', 'e2e00000-0000-0000-0000-00000000000c') returning id as pay2 \gset
reset role;
do $$ declare i record; begin
  select * into i from public.invoices where id = current_setting('e2e.invoice')::uuid;
  if i.status::text <> 'paid' or i.balance_due <> 0 or i.paid_at is null then raise exception 'FAIL W6b: % balance % paid_at %', i.status, i.balance_due, i.paid_at; end if;
end $$;
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
update public.payments set status = 'voided', voided_by = 'e2e00000-0000-0000-0000-00000000000c', voided_at = now(), void_reason = 'bounced' where id = :'pay2' and status = 'posted';
reset role;
do $$ declare i record; begin
  select * into i from public.invoices where id = current_setting('e2e.invoice')::uuid;
  if i.status::text <> 'partially_paid' or i.balance_due <> 4500 then raise exception 'FAIL W6c: after void % balance %', i.status, i.balance_due; end if;
end $$;
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
insert into public.payments (organization_id, invoice_id, amount, method, received_at, reference_number, recorded_by)
  values (:'org', :'invoice', 4500, 'wire', now(), 'WIRE-3', 'e2e00000-0000-0000-0000-00000000000c');
reset role;
do $$ declare i record; begin
  select * into i from public.invoices where id = current_setting('e2e.invoice')::uuid;
  if i.status::text <> 'paid' or i.balance_due <> 0 then raise exception 'FAIL W6d: % balance %', i.status, i.balance_due; end if;
  raise notice 'OK W6: 3000 -> partially_paid (4500 due); 5000 overpayment refused; 4500 -> paid; void -> partially_paid; re-pay -> paid.';
end $$;

-- ---- W7 statement -------------------------------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
select s.* from public.get_statement_period_summary(:'broker', null, current_date - 7, current_date) s \gset st_
select count(*) as st_tx from public.get_statement_transactions(:'broker', null, current_date - 7, current_date) \gset
insert into public.statements (organization_id, party_type, broker_id, customer_id, statement_type, period_start, period_end, as_of_date, opening_balance, closing_balance, status, generated_by)
  values (:'org', 'broker', :'broker', null, 'period', current_date - 7, current_date, current_date, 0, 0, 'generated', 'e2e00000-0000-0000-0000-00000000000c') returning statement_number \gset
reset role;
select set_config('e2e.st', json_build_object('tx', :'st_tx'::int, 'num', :'statement_number', 'open', :'st_opening_balance'::numeric,
  'charges', :'st_period_charges'::numeric, 'payments', :'st_period_payments'::numeric, 'close', :'st_closing_balance'::numeric)::text, true);
do $$ declare j jsonb := current_setting('e2e.st')::jsonb; begin
  if (j->>'num') !~ '^STM-[0-9]{6}$' then raise exception 'FAIL W7: statement number %', j->>'num'; end if;
  if (j->>'open')::numeric <> 0 or (j->>'charges')::numeric <> 7500 or (j->>'payments')::numeric <> 7500 or (j->>'close')::numeric <> 0 then
    raise exception 'FAIL W7: opening % charges % payments % closing % (voided payment must not count)', j->>'open', j->>'charges', j->>'payments', j->>'close';
  end if;
  if (j->>'tx')::int < 4 then raise exception 'FAIL W7: expected >= 4 transactions, got %', j->>'tx'; end if;
end $$;
do $$ begin raise notice 'OK W7: broker statement: opening 0, charges 7500.00, payments 7500.00 (voided payment excluded), closing 0; STM number.'; end $$;

-- ---- W8 carrier settlement -----------------------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000d');
insert into public.dispatch_advances (organization_id, carrier_id, driver_id, dispatch_id, load_id, expense_type, description, amount, paid_date)
  values (:'org', :'carrier', :'driver', :'dispatch', :'load', 'fuel', 'Fuel advance', 200, current_date) returning id as adv \gset
reset role;
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
insert into public.settlements (organization_id, carrier_id, status, period_start, period_end)
  values (:'org', :'carrier', 'draft', current_date - 7, current_date) returning id as cset \gset
create temp table e2e_payable as select * from public.get_payable_carrier_loads(:'carrier', current_date - 7, current_date);
insert into public.settlement_line_items (organization_id, settlement_id, item_type, description, amount, load_id, dispatch_id, load_number, delivery_date, miles, customer_revenue, carrier_rate, pay_basis)
  select :'org', :'cset', 'load_pay', 'Load ' || p.load_number, p.carrier_rate, p.load_id, p.dispatch_id, p.load_number, p.delivery_date, p.miles, p.customer_revenue, p.carrier_rate, 'dispatch_fee_snapshot'
  from e2e_payable p;
select public.deduct_pending_advances_into_settlement(:'cset') as deducted \gset
select public.approve_carrier_settlement(:'cset');
reset role;
select set_config('e2e.cset', :'cset', true);
do $$ declare s record; v_n int; begin
  select count(*) into v_n from e2e_payable;
  if v_n <> 1 then raise exception 'FAIL W8: expected 1 payable load, got %', v_n; end if;
  if (select carrier_rate from e2e_payable) <> 6750 then raise exception 'FAIL W8: carrier rate %', (select carrier_rate from e2e_payable); end if;
  select * into s from public.settlements where id = current_setting('e2e.cset')::uuid;
  if s.status::text <> 'approved' or s.net_amount <> 6550 then raise exception 'FAIL W8: settlement % gross % ded % net %', s.status, s.gross_amount, s.deductions_amount, s.net_amount; end if;
end $$;
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
insert into public.carrier_settlement_payments (organization_id, settlement_id, amount, method, paid_date, reference_number, recorded_by)
  values (:'org', :'cset', 6550, 'ach', current_date, 'CP-1', 'e2e00000-0000-0000-0000-00000000000c');
reset role;
do $$ declare s record; begin
  select * into s from public.settlements where id = current_setting('e2e.cset')::uuid;
  if s.status::text <> 'paid' or s.balance_due <> 0 then raise exception 'FAIL W8: after payment % balance %', s.status, s.balance_due; end if;
  if (select status::text from public.dispatch_advances where carrier_id = s.carrier_id) <> 'deducted' then raise exception 'FAIL W8: advance not deducted'; end if;
  raise notice 'OK W8: carrier settlement 6750.00 - 200.00 fuel advance = 6550.00; approved; paid in full.';
end $$;

-- ---- W9 driver settlement ---------------------------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
insert into public.driver_settlements (organization_id, driver_id, carrier_id, period_start, period_end, created_by)
  values (:'org', :'driver', :'carrier', current_date - 7, current_date, 'e2e00000-0000-0000-0000-00000000000c') returning id as dset \gset
insert into public.driver_settlement_items (organization_id, driver_settlement_id, load_id, dispatch_id, load_number, delivery_date, miles, load_rate, pay_method, pay_rate, gross_pay, created_by)
  select :'org', :'dset', p.load_id, p.dispatch_id, p.load_number, p.delivery_date, p.miles, p.load_rate, p.pay_method, p.pay_rate, p.gross_pay, 'e2e00000-0000-0000-0000-00000000000c'
  from public.get_payable_loads(:'driver', current_date - 7, current_date) p;
select public.approve_driver_settlement(:'dset');
reset role;
select set_config('e2e.dset', :'dset', true);
do $$ declare s record; begin
  select * into s from public.driver_settlements where id = current_setting('e2e.dset')::uuid;
  if s.status::text <> 'approved' or s.net_pay <> 1875 then raise exception 'FAIL W9: % gross % net %', s.status, s.gross_pay, s.net_pay; end if;
end $$;
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
insert into public.driver_settlement_payments (organization_id, driver_settlement_id, amount, method, paid_date, recorded_by)
  values (:'org', :'dset', 1875, 'ach', current_date, 'e2e00000-0000-0000-0000-00000000000c');
reset role;
do $$ declare s record; begin
  select * into s from public.driver_settlements where id = current_setting('e2e.dset')::uuid;
  if s.status::text <> 'paid' then raise exception 'FAIL W9: after payment %', s.status; end if;
  raise notice 'OK W9: driver settlement 25%% of 7500.00 = 1875.00; approved; paid.';
end $$;

-- ---- W10 no double settlement; ready-to-bill ---------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000c');
select count(*) as again_carrier from public.get_payable_carrier_loads(:'carrier', current_date - 7, current_date) \gset
select count(*) as again_driver from public.get_payable_loads(:'driver', current_date - 7, current_date) \gset
select count(*) as rtb from public.get_ready_to_bill_loads() where load_id = :'load' \gset
reset role;
select set_config('e2e.w10', :'again_carrier' || ',' || :'again_driver' || ',' || :'rtb', true);
do $$ begin
  if current_setting('e2e.w10') <> '0,0,0' then raise exception 'FAIL W10: carrier/driver/ready-to-bill counts %', current_setting('e2e.w10'); end if;
  raise notice 'OK W10: the load cannot be settled again (carrier or driver) and is not offered as ready-to-bill.';
end $$;

-- ---- W11 isolation -------------------------------------------------------------------
select pg_temp.login('e2e00000-0000-0000-0000-00000000000b');
select (select count(*) from public.loads where id = :'load') + (select count(*) from public.invoices where id = :'invoice')
     + (select count(*) from public.settlements where id = :'cset') + (select count(*) from public.driver_settlements where id = :'dset')
     + (select count(*) from public.payments where invoice_id = :'invoice') as leaked \gset
reset role;
select set_config('e2e.leaked', :'leaked', true);
do $$ begin
  if current_setting('e2e.leaked') <> '0' then raise exception 'FAIL W11: another company sees % row(s)', current_setting('e2e.leaked'); end if;
  raise notice 'OK W11: another company sees none of the load, invoice, payments or settlements.';
  raise notice 'ALL CORE WORKFLOW CHECKS PASSED';
end $$;
rollback;
