-- =============================================================================
-- TEST_0168_carrier_invoice_double_billing_guards.sql -- PRODUCTION TWIN ONLY
-- (supabase/ci/twin-db.sh). NEVER run on a real database. Ends in ROLLBACK.
--   G1  a "broker pays us" load cannot go on a carrier freight invoice
--   G2  a "broker pays the carrier" load can (draft created)
--   G3  switching the carrier back to "broker pays us" keeps that load
--       (it is on a carrier freight invoice)
--   G4  a broker invoice cannot be created for a load on a live carrier
--       freight invoice, even if its dispatch were "broker pays us"
--   G5  the draft can be marked ready and issued; the issuance snapshot (what
--       the invoice PDF and factor package are drawn from) has the carrier,
--       broker and load
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values ('16800000-0000-0000-0000-00000000000a', 'o168@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"16800000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T168 Org', 't168-org') is not null; reset role;
select id as org from public.organizations where slug = 't168-org' \gset

insert into public.brokers (id, organization_id, company_name, legal_name) values ('16800000-0000-0000-0000-0000000000b1', :'org', 'B168', 'B168 LLC');
insert into public.carriers (id, organization_id, legal_name, invoice_code, factoring_mode, load_proceeds_model) values
 ('16800000-0000-0000-0000-0000000000c1', :'org', 'Direct Pay Carrier', 'DPC', 'direct', 'carrier_paid_directly'),
 ('16800000-0000-0000-0000-0000000000c2', :'org', 'Pays Us Carrier', 'PUC', 'direct', null);
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
 ('16800000-0000-0000-0000-0000000000d1', :'org', '16800000-0000-0000-0000-0000000000c1', 'A', 'One'),
 ('16800000-0000-0000-0000-0000000000d2', :'org', '16800000-0000-0000-0000-0000000000c2', 'B', 'Two');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
 ('16800000-0000-0000-0000-0000000000e1', :'org', '16800000-0000-0000-0000-0000000000c1', 'T1'),
 ('16800000-0000-0000-0000-0000000000e2', :'org', '16800000-0000-0000-0000-0000000000c2', 'T2');
insert into public.loads (id, organization_id, load_number, status, carrier_id, broker_id) values
 ('16800000-0000-0000-0000-0000000000f1', :'org', 'L168-1', 'booked', '16800000-0000-0000-0000-0000000000c1', '16800000-0000-0000-0000-0000000000b1'),
 ('16800000-0000-0000-0000-0000000000f2', :'org', 'L168-2', 'booked', '16800000-0000-0000-0000-0000000000c2', '16800000-0000-0000-0000-0000000000b1');
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, city, state) values
 (:'org', '16800000-0000-0000-0000-0000000000f1', 'pickup', 1, 'Austin', 'TX'),
 (:'org', '16800000-0000-0000-0000-0000000000f1', 'delivery', 2, 'Tulsa', 'OK');
insert into public.load_financials (load_id, organization_id, rate) values
 ('16800000-0000-0000-0000-0000000000f1', :'org', 2000), ('16800000-0000-0000-0000-0000000000f2', :'org', 3000);

create or replace function pg_temp.as_owner(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', '{"sub":"16800000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
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

do $$
declare r text;
begin
  r := pg_temp.as_owner($q$select public.create_dispatch('16800000-0000-0000-0000-0000000000f1', '16800000-0000-0000-0000-0000000000c1', '16800000-0000-0000-0000-0000000000e1', '16800000-0000-0000-0000-0000000000d1', null, 10, null)::text$q$);
  if r not like 'ok:%' then raise exception 'SETUP d1: %', r; end if;
  r := pg_temp.as_owner($q$select public.create_dispatch('16800000-0000-0000-0000-0000000000f2', '16800000-0000-0000-0000-0000000000c2', '16800000-0000-0000-0000-0000000000e2', '16800000-0000-0000-0000-0000000000d2', null, 10, null)::text$q$);
  if r not like 'ok:%' then raise exception 'SETUP d2: %', r; end if;
  r := pg_temp.as_owner($q$update public.loads set status = 'delivered' where load_number in ('L168-1', 'L168-2') and organization_id = public.current_org_id() returning 1$q$);
end $$;
-- L168-2 ("broker pays us") got its broker draft on delivery; remove it so only the new guard is in play
delete from public.invoice_line_items where invoice_id in (select id from public.invoices where load_id = '16800000-0000-0000-0000-0000000000f2');
delete from public.invoices where load_id = '16800000-0000-0000-0000-0000000000f2';

do $$
declare r text;
begin
  -- G1
  r := pg_temp.as_owner($q$select public.create_carrier_invoice_draft_from_loads('16800000-0000-0000-0000-0000000000c2', array['16800000-0000-0000-0000-0000000000f2']::uuid[], 'broker', '16800000-0000-0000-0000-0000000000b1', 'g1-key')::text$q$);
  if r not like '%Broker pays us%' then raise exception 'FAIL G1: %', r; end if;
  if exists (select 1 from public.carrier_invoice_loads where load_id = '16800000-0000-0000-0000-0000000000f2') then raise exception 'FAIL G1: load attached'; end if;
  raise notice 'OK G1: a "broker pays us" load cannot go on the carrier''s own invoice.';

  -- G2
  r := pg_temp.as_owner($q$select public.create_carrier_invoice_draft_from_loads('16800000-0000-0000-0000-0000000000c1', array['16800000-0000-0000-0000-0000000000f1']::uuid[], 'broker', '16800000-0000-0000-0000-0000000000b1', 'g2-key')::text$q$);
  if r not like 'ok:%"success": true%' then raise exception 'FAIL G2: %', r; end if;
  raise notice 'OK G2: a "broker pays the carrier" load goes on the carrier freight invoice draft.';
  perform set_config('t168.inv', (substr(r, 4)::jsonb ->> 'invoice_id'), true);

  -- G3
  r := pg_temp.as_owner($q$select public.set_carrier_broker_pays('16800000-0000-0000-0000-0000000000c1', 'dispatcher_receives_funds')::text$q$);
  if r not like '%L168-1 (on a carrier freight invoice)%' then raise exception 'FAIL G3: %', r; end if;
  if (select proceeds_model::text from public.dispatches where load_id = '16800000-0000-0000-0000-0000000000f1') <> 'carrier_paid_directly' then raise exception 'FAIL G3: load moved'; end if;
  raise notice 'OK G3: switching the carrier back keeps the load that is on its freight invoice.';
end $$;

-- G4: even with the dispatch forced to "broker pays us", the broker invoice is refused
update public.dispatches set proceeds_model = 'dispatcher_receives_funds' where load_id = '16800000-0000-0000-0000-0000000000f1';
do $$
declare r text;
begin
  r := pg_temp.as_owner($q$insert into public.invoices (organization_id, invoice_number, load_id, broker_id, status, bill_to_name, subtotal_amount, total_amount)
        values (public.current_org_id(), 'INV-168-X', '16800000-0000-0000-0000-0000000000f1', '16800000-0000-0000-0000-0000000000b1', 'draft', 'B168', 2000, 2000) returning 1$q$);
  if r not like 'err:%carrier freight invoice%' then raise exception 'FAIL G4: %', r; end if;
  raise notice 'OK G4: no broker invoice for a load on a live carrier freight invoice.';
end $$;

-- G5 (dispatch restored first: issuing re-checks the load)
update public.dispatches set proceeds_model = 'carrier_paid_directly' where load_id = '16800000-0000-0000-0000-0000000000f1';
do $$
declare r text; v_inv uuid := current_setting('t168.inv')::uuid; snap jsonb;
begin
  -- the carrier's billing relationship with the broker (carrier page: "Brokers this carrier invoices")
  r := pg_temp.as_owner($q$select public.activate_carrier_party('16800000-0000-0000-0000-0000000000c1', '16800000-0000-0000-0000-0000000000b1', null,
        '{"billing_email": "ap@b168.test", "payment_terms_days": 30, "factoring_eligible": true}'::jsonb)::text$q$);
  if r not like 'ok:%' then raise exception 'FAIL G5 relationship: %', r; end if;
  r := pg_temp.as_owner(format($q$select public.mark_carrier_invoice_ready_for_issue(%L, (select updated_at from public.carrier_invoices where id = %L), 'g5-ready')::text$q$, v_inv, v_inv));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL G5 ready: %', r; end if;
  r := pg_temp.as_owner(format($q$select public.issue_prepared_carrier_invoice(%L, (select updated_at from public.carrier_invoices where id = %L), 'First issue for testing', 'g5-issue')::text$q$, v_inv, v_inv));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL G5 issue: %', r; end if;
  select snapshot_payload into snap from public.carrier_invoice_issuance_snapshots where invoice_id = v_inv;
  if snap->'issuer'->>'legal_name' <> 'Direct Pay Carrier' or snap->'recipient'->>'legal_name' <> 'B168' or snap->'loads'->0->>'load_number' <> 'L168-1'
     or (snap->>'total_amount')::numeric <> 2000 or snap->>'invoice_number' not like 'DPC-%' then
    raise exception 'FAIL G5 snapshot: %', snap;
  end if;
  raise notice 'OK G5: issued % for 2000.00; snapshot has carrier, broker and load L168-1.', snap->>'invoice_number';
end $$;

do $$ begin raise notice 'ALL 0168 CHECKS PASSED'; end $$;
rollback;
