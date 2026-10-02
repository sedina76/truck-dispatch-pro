-- =============================================================================
-- TEST_0167_broker_pays_carrier_setting.sql -- PRODUCTION TWIN ONLY
-- (supabase/ci/twin-db.sh). NEVER run on a real database. Ends in ROLLBACK.
--
-- Carrier "Blue Line" starts as "broker pays us" (default) with four loads:
--   LA delivered (auto draft broker invoice), LB dispatched not delivered,
--   LC delivered and its broker invoice SENT, LD delivered and SETTLED.
--   B1  only an owner/admin can change the setting, and only through the
--       setting itself (no direct column update, even by the owner)
--   B2  switch to "broker pays the carrier": LA (draft removed) and LB move,
--       LC (invoiced) and LD (settled) are kept and reported
--   B3  LB delivered: no broker invoice is created, one can't be created by
--       hand, it isn't in Ready to Bill or offered to a carrier settlement,
--       and its fee (with LA's) is on the Dispatch Fee Invoice preview
--   B4  a new dispatch for this carrier is "broker pays the carrier"
--   B5  switch back: LA and LB are billed to the broker again (Ready to
--       Bill, carrier settlement), and leave the fee invoice preview
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values
 ('16700000-0000-0000-0000-00000000000a', 'o167b@test.invalid', 'authenticated', 'authenticated'),
 ('16700000-0000-0000-0000-00000000000c', 'a167b@test.invalid', 'authenticated', 'authenticated'),
 ('16700000-0000-0000-0000-00000000000d', 'd167b@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"16700000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T167B Org', 't167b-org') is not null; reset role;
select id as org from public.organizations where slug = 't167b-org' \gset
set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = :'org', role = 'accountant' where id = '16700000-0000-0000-0000-00000000000c';
update public.profiles set organization_id = :'org', role = 'dispatcher' where id = '16700000-0000-0000-0000-00000000000d';
set local app.bypass_profile_guard = 'false';

insert into public.brokers (id, organization_id, company_name, legal_name) values ('16700000-0000-0000-0000-0000000000b1', :'org', 'B167', 'B167 LLC');
insert into public.carriers (id, organization_id, legal_name) values ('16700000-0000-0000-0000-0000000000c1', :'org', 'Blue Line');
-- one driver + truck per load (a driver can only be on one active load)
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  select ('16700000-0000-0000-0000-0000000000d' || n)::uuid, :'org', '16700000-0000-0000-0000-0000000000c1', 'Driver', n::text from generate_series(1, 5) n;
insert into public.trucks (id, organization_id, carrier_id, unit_number)
  select ('16700000-0000-0000-0000-0000000000e' || n)::uuid, :'org', '16700000-0000-0000-0000-0000000000c1', 'BL' || n from generate_series(1, 5) n;
insert into public.loads (id, organization_id, load_number, status, carrier_id, broker_id) values
 ('16700000-0000-0000-0000-0000000000f1', :'org', 'LA', 'booked', '16700000-0000-0000-0000-0000000000c1', '16700000-0000-0000-0000-0000000000b1'),
 ('16700000-0000-0000-0000-0000000000f2', :'org', 'LB', 'booked', '16700000-0000-0000-0000-0000000000c1', '16700000-0000-0000-0000-0000000000b1'),
 ('16700000-0000-0000-0000-0000000000f3', :'org', 'LC', 'booked', '16700000-0000-0000-0000-0000000000c1', '16700000-0000-0000-0000-0000000000b1'),
 ('16700000-0000-0000-0000-0000000000f4', :'org', 'LD', 'booked', '16700000-0000-0000-0000-0000000000c1', '16700000-0000-0000-0000-0000000000b1'),
 ('16700000-0000-0000-0000-0000000000f5', :'org', 'LE', 'booked', '16700000-0000-0000-0000-0000000000c1', '16700000-0000-0000-0000-0000000000b1');
insert into public.load_financials (load_id, organization_id, rate)
select id, :'org', 1000 from public.loads where organization_id = :'org';

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

-- dispatch LA..LD (default arrangement: broker pays us); deliver LA, LC, LD on the load page
do $$
declare r record; v text;
begin
  for r in select id, row_number() over (order by load_number) as n from public.loads where load_number in ('LA', 'LB', 'LC', 'LD') and organization_id = (select id from public.organizations where slug = 't167b-org') loop
    v := pg_temp.as_user('16700000-0000-0000-0000-00000000000a', format(
      'select public.create_dispatch(%L, %L, %L, %L, null, 10, null)::text', r.id,
      '16700000-0000-0000-0000-0000000000c1', '16700000-0000-0000-0000-0000000000e' || r.n, '16700000-0000-0000-0000-0000000000d' || r.n));
    if v not like 'ok:%' then raise exception 'SETUP dispatch: %', v; end if;
  end loop;
  v := pg_temp.as_user('16700000-0000-0000-0000-00000000000d', $q$update public.loads set status = 'delivered' where load_number in ('LA', 'LC', 'LD') and organization_id = public.current_org_id() returning 1$q$);
  if v not like 'ok:%' then raise exception 'SETUP deliver: %', v; end if;
end $$;
-- LC's broker invoice is sent (POD verified); LD is on a carrier settlement
insert into public.documents (organization_id, entity_type, entity_id, document_type, file_name, file_path, is_verified)
  values (:'org', 'load', '16700000-0000-0000-0000-0000000000f3', 'pod', 'pod.jpg', 'x/pod.jpg', true);
update public.invoices set status = 'sent', sent_at = now() where load_id = '16700000-0000-0000-0000-0000000000f3';
insert into public.settlements (id, organization_id, carrier_id, status, period_start, period_end)
  values ('16700000-0000-0000-0000-0000000000a1', :'org', '16700000-0000-0000-0000-0000000000c1', 'draft', current_date - 7, current_date);
insert into public.settlement_line_items (organization_id, settlement_id, item_type, description, amount, load_id, dispatch_id, load_number, carrier_rate)
  select :'org', '16700000-0000-0000-0000-0000000000a1', 'load_pay', 'Load LD', 900, d.load_id, d.id, 'LD', 900
  from public.dispatches d where d.load_id = '16700000-0000-0000-0000-0000000000f4';

do $$
declare r text; j jsonb;
  c1 uuid := '16700000-0000-0000-0000-0000000000c1';
  owner uuid := '16700000-0000-0000-0000-00000000000a';
  acct uuid := '16700000-0000-0000-0000-00000000000c';
  disp uuid := '16700000-0000-0000-0000-00000000000d';
begin
  if (select count(*) from public.invoices i join public.loads l on l.id = i.load_id where l.load_number in ('LA', 'LC', 'LD') and l.organization_id = (select organization_id from public.carriers where id = c1)) <> 3 then
    raise exception 'SETUP: expected 3 broker invoices';
  end if;

  -- B1
  r := pg_temp.as_user(acct, format($q$select public.set_carrier_broker_pays(%L, 'carrier_paid_directly')::text$q$, c1));
  if r not like 'err:%owner or admin%' then raise exception 'FAIL B1 accountant: %', r; end if;
  r := pg_temp.as_user(disp, format($q$select public.set_carrier_broker_pays(%L, 'carrier_paid_directly')::text$q$, c1));
  if r not like 'err:%owner or admin%' then raise exception 'FAIL B1 dispatcher: %', r; end if;
  r := pg_temp.as_user(owner, format($q$update public.carriers set load_proceeds_model = 'carrier_paid_directly' where id = %L returning 1$q$, c1));
  if r not like 'err:%Who does the broker pay%' then raise exception 'FAIL B1 direct update: %', r; end if;
  raise notice 'OK B1: only owner/admin, and only through the setting.';

  -- B2
  r := pg_temp.as_user(owner, format($q$select public.set_carrier_broker_pays(%L, 'carrier_paid_directly')::text$q$, c1));
  if r not like 'ok:%' then raise exception 'FAIL B2: %', r; end if;
  j := substr(r, 4)::jsonb;
  if (j->>'loads_switched')::int <> 2 or (j->>'broker_drafts_removed')::int <> 1 or jsonb_array_length(j->'kept') <> 2
     or j->'kept'->>0 not like 'LC (already invoiced%' or j->'kept'->>1 not like 'LD (already settled%' then
    raise exception 'FAIL B2 result: %', j;
  end if;
  if exists (select 1 from public.invoices where load_id = '16700000-0000-0000-0000-0000000000f1') then raise exception 'FAIL B2: LA draft still there'; end if;
  if (select string_agg(l.load_number || '=' || d.proceeds_model, ',' order by l.load_number) from public.dispatches d join public.loads l on l.id = d.load_id where d.carrier_id = c1)
     <> 'LA=carrier_paid_directly,LB=carrier_paid_directly,LC=dispatcher_receives_funds,LD=dispatcher_receives_funds' then
    raise exception 'FAIL B2 stamps: %', (select string_agg(l.load_number || '=' || d.proceeds_model, ',' order by l.load_number) from public.dispatches d join public.loads l on l.id = d.load_id where d.carrier_id = c1);
  end if;
  raise notice 'OK B2: switched LA (draft broker invoice removed) and LB; kept LC (invoiced) and LD (settled): %', j->'kept';

  -- B3
  r := pg_temp.as_user(disp, $q$update public.loads set status = 'delivered' where load_number = 'LB' and organization_id = public.current_org_id() returning 1$q$);
  if r <> 'ok:1' then raise exception 'FAIL B3 deliver: %', r; end if;
  if exists (select 1 from public.invoices where load_id = '16700000-0000-0000-0000-0000000000f2') then raise exception 'FAIL B3: broker invoice auto-created'; end if;
  r := pg_temp.as_user(acct, $q$insert into public.invoices (organization_id, invoice_number, load_id, broker_id, status, bill_to_name, subtotal_amount, total_amount)
        values (public.current_org_id(), 'INV-X-1', '16700000-0000-0000-0000-0000000000f2', '16700000-0000-0000-0000-0000000000b1', 'draft', 'B167', 1000, 1000) returning 1$q$);
  if r not like 'err:%broker pays the carrier for this load%' then raise exception 'FAIL B3 manual invoice: %', r; end if;
  r := pg_temp.as_user(acct, $q$select coalesce(string_agg(load_number, ','), '') from public.get_ready_to_bill_loads()$q$);
  if r like '%LA%' or r like '%LB%' then raise exception 'FAIL B3 ready to bill: %', r; end if;
  r := pg_temp.as_user(owner, format($q$select coalesce(string_agg(load_number, ',' order by load_number), '') from public.get_payable_carrier_loads(%L, current_date - 7, current_date)$q$, c1));
  if r <> 'ok:LC' then raise exception 'FAIL B3 payable (expected only LC): %', r; end if;
  r := pg_temp.as_user(acct, format($q$select coalesce(string_agg(load_number || '=' || amount, ',' order by load_number), '') from public.preview_carrier_fee_invoice(%L, current_date - 7, current_date) where line_type = 'dispatch_fee'$q$, c1));
  if r <> 'ok:LA=100.00,LB=100.00' then raise exception 'FAIL B3 fee preview: %', r; end if;
  raise notice 'OK B3: LB delivered -> no broker invoice (auto or by hand), not in Ready to Bill or settlements; fees LA + LB on the Dispatch Fee Invoice.';

  -- B4
  r := pg_temp.as_user(owner, format('select public.create_dispatch(%L, %L, %L, %L, null, 10, null)::text', '16700000-0000-0000-0000-0000000000f5', c1,
        '16700000-0000-0000-0000-0000000000e5', '16700000-0000-0000-0000-0000000000d5'));
  if r not like 'ok:%' then raise exception 'FAIL B4 dispatch: %', r; end if;
  if (select proceeds_model::text from public.dispatches where id = substr(r, 4)::uuid) <> 'carrier_paid_directly' then raise exception 'FAIL B4 stamp'; end if;
  raise notice 'OK B4: a new dispatch for this carrier is "broker pays the carrier".';

  -- B5
  r := pg_temp.as_user(owner, format($q$select public.set_carrier_broker_pays(%L, 'dispatcher_receives_funds')::text$q$, c1));
  if r not like 'ok:%' then raise exception 'FAIL B5: %', r; end if;
  j := substr(r, 4)::jsonb;
  if (j->>'loads_switched')::int <> 3 then raise exception 'FAIL B5 result: %', j; end if;   -- LA, LB, LE
  r := pg_temp.as_user(acct, $q$select coalesce(string_agg(load_number, ',' order by load_number), '') from public.get_ready_to_bill_loads() where load_number in ('LA', 'LB')$q$);
  if r <> 'ok:LA,LB' then raise exception 'FAIL B5 ready to bill: %', r; end if;
  r := pg_temp.as_user(acct, format($q$select count(*)::text from public.preview_carrier_fee_invoice(%L, current_date - 7, current_date) where line_type = 'dispatch_fee'$q$, c1));
  if r <> 'ok:0' then raise exception 'FAIL B5 fee preview: %', r; end if;
  r := pg_temp.as_user(owner, format($q$select coalesce(string_agg(load_number, ',' order by load_number), '') from public.get_payable_carrier_loads(%L, current_date - 7, current_date)$q$, c1));
  if r <> 'ok:LA,LB,LC' then raise exception 'FAIL B5 payable: %', r; end if;
  raise notice 'OK B5: switched back -> LA and LB are billed to the broker (Ready to Bill, settlement) and off the fee invoice.';
end $$;

do $$ begin raise notice 'ALL 0167 CHECKS PASSED'; end $$;
rollback;
