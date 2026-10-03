-- =============================================================================
-- TEST_INVOICE_FACTORING_SETUP.sql -- PRODUCTION TWIN ONLY (supabase/ci/twin-db.sh).
-- NEVER run on a real database. Ends in ROLLBACK. The carrier invoice page's
-- "Set up factoring" box, step by step as the owner:
--   F1 add the factoring company   F2 link it to the carrier (terms)
--   F3 remit-to + how it takes paperwork   F4 approve the NOA
--   F5 make it the carrier's default   F6 switch the carrier to "Factors"
--   F7 an invoice issued afterwards is payable to the factor
--   F8 "Stop factoring" switches the carrier back
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values ('17100000-0000-0000-0000-00000000000a', 'o171@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"17100000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T171 Org', 't171-org') is not null; reset role;
select id as org from public.organizations where slug = 't171-org' \gset

insert into public.brokers (id, organization_id, company_name, legal_name) values ('17100000-0000-0000-0000-0000000000b1', :'org', 'B171', 'B171 LLC');
insert into public.carriers (id, organization_id, legal_name, invoice_code, factoring_mode, load_proceeds_model) values
 ('17100000-0000-0000-0000-0000000000c1', :'org', 'Direct Pay Carrier', 'DPC', 'direct', 'carrier_paid_directly'),
 ('17100000-0000-0000-0000-0000000000c2', :'org', 'Pays Us Carrier', 'PUC', 'direct', null);
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
 ('17100000-0000-0000-0000-0000000000d1', :'org', '17100000-0000-0000-0000-0000000000c1', 'A', 'One'),
 ('17100000-0000-0000-0000-0000000000d2', :'org', '17100000-0000-0000-0000-0000000000c2', 'B', 'Two');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
 ('17100000-0000-0000-0000-0000000000e1', :'org', '17100000-0000-0000-0000-0000000000c1', 'T1'),
 ('17100000-0000-0000-0000-0000000000e2', :'org', '17100000-0000-0000-0000-0000000000c2', 'T2');
insert into public.loads (id, organization_id, load_number, status, carrier_id, broker_id) values
 ('17100000-0000-0000-0000-0000000000f1', :'org', 'L171-1', 'booked', '17100000-0000-0000-0000-0000000000c1', '17100000-0000-0000-0000-0000000000b1'),
 ('17100000-0000-0000-0000-0000000000f2', :'org', 'L171-2', 'booked', '17100000-0000-0000-0000-0000000000c2', '17100000-0000-0000-0000-0000000000b1');
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, city, state) values
 (:'org', '17100000-0000-0000-0000-0000000000f1', 'pickup', 1, 'Austin', 'TX'),
 (:'org', '17100000-0000-0000-0000-0000000000f1', 'delivery', 2, 'Tulsa', 'OK');
insert into public.load_financials (load_id, organization_id, rate) values
 ('17100000-0000-0000-0000-0000000000f1', :'org', 2000), ('17100000-0000-0000-0000-0000000000f2', :'org', 3000);

create or replace function pg_temp.as_owner(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', '{"sub":"17100000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
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
  r := pg_temp.as_owner($q$select public.create_dispatch('17100000-0000-0000-0000-0000000000f1', '17100000-0000-0000-0000-0000000000c1', '17100000-0000-0000-0000-0000000000e1', '17100000-0000-0000-0000-0000000000d1', null, 10, null)::text$q$);
  if r not like 'ok:%' then raise exception 'SETUP d1: %', r; end if;
  r := pg_temp.as_owner($q$select public.create_dispatch('17100000-0000-0000-0000-0000000000f2', '17100000-0000-0000-0000-0000000000c2', '17100000-0000-0000-0000-0000000000e2', '17100000-0000-0000-0000-0000000000d2', null, 10, null)::text$q$);
  if r not like 'ok:%' then raise exception 'SETUP d2: %', r; end if;
  r := pg_temp.as_owner($q$update public.loads set status = 'delivered' where load_number in ('L171-1', 'L171-2') and organization_id = public.current_org_id() returning 1$q$);
end $$;
-- L171-2 ("broker pays us") got its broker draft on delivery; remove it so only the new guard is in play
delete from public.invoice_line_items where invoice_id in (select id from public.invoices where load_id = '17100000-0000-0000-0000-0000000000f2');
delete from public.invoices where load_id = '17100000-0000-0000-0000-0000000000f2';

-- the carrier's billing relationship with the broker
do $$
declare r text;
begin
  r := pg_temp.as_owner($q$select public.activate_carrier_party('17100000-0000-0000-0000-0000000000c1', '17100000-0000-0000-0000-0000000000b1', null,
        '{"billing_email": "ap@b171.test", "payment_terms_days": 30, "factoring_eligible": true}'::jsonb)::text$q$);
  if r not like 'ok:%' then raise exception 'SETUP relationship: %', r; end if;
end $$;

-- F1..F6: the invoice page's "Set up factoring" steps, in order, as the owner (same statements the server action runs)
do $$
declare r text; v_co uuid; v_rel uuid; v_upd text;
begin
  r := pg_temp.as_owner($q$insert into public.factoring_companies (organization_id, name, email, address_line1, city, state, postal_code) values (public.current_org_id(), 'Apex Funding', 'ops@apex.test', '1 Main St', 'Dallas', 'TX', '75001') returning id::text$q$);
  if r not like 'ok:%' then raise exception 'FAIL F1 company: %', r; end if;
  v_co := substr(r, 4)::uuid;
  raise notice 'OK F1: factoring company added.';

  r := pg_temp.as_owner(format($q$insert into public.factoring_relationships (organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type, effective_from)
        values (public.current_org_id(), %L, '17100000-0000-0000-0000-0000000000c1', 97, 3, 0, 'deducted_at_funding', 'recourse', current_date) returning id::text$q$, v_co));
  if r not like 'ok:%' then raise exception 'FAIL F2 relationship: %', r; end if;
  v_rel := substr(r, 4)::uuid;
  raise notice 'OK F2: linked to the carrier (97%% advance, 3%% fee).';

  r := pg_temp.as_owner(format($q$update public.factoring_relationships set remittance_instructions = 'Apex Funding, 1 Main St, Dallas, TX 75001', submission_method = 'secure_email', submission_destination_email = 'ops@apex.test' where id = %L returning 1$q$, v_rel));
  if r not like 'ok:%' then raise exception 'FAIL F3 setup: %', r; end if;
  raise notice 'OK F3: remit-to and paperwork email saved.';

  r := pg_temp.as_owner(format($q$select public.approve_factoring_relationship_noa(%L, 'Apex Funding NOA', current_date, 'Notice of Assignment: Direct Pay Carrier has assigned its receivables to Apex Funding.', null)::text$q$, v_rel));
  if r not like 'ok:%' then raise exception 'FAIL F4 NOA: %', r; end if;
  raise notice 'OK F4: NOA approved.';

  r := pg_temp.as_owner(format($q$select public.set_default_factoring_relationship(%L)::text$q$, v_rel));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL F5 default: %', r; end if;
  raise notice 'OK F5: made the carrier''s default factor.';

  select updated_at::text into v_upd from public.carriers where id = '17100000-0000-0000-0000-0000000000c1';
  r := pg_temp.as_owner(format($q$select public.set_carrier_factoring_policy('17100000-0000-0000-0000-0000000000c1', 'factored', 'Set up from the invoice page', %L::timestamptz, null)::text$q$, v_upd));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL F6 policy: %', r; end if;
  if (select factoring_mode::text from public.carriers where id = '17100000-0000-0000-0000-0000000000c1') <> 'factored' then raise exception 'FAIL F6: carrier not factored'; end if;
  raise notice 'OK F6: carrier switched to "Factors".';
end $$;

-- F7: an invoice issued now is payable to the factor
do $$
declare r text; v uuid; upd text; snap jsonb;
begin
  r := pg_temp.as_owner($q$select public.create_carrier_invoice_draft_from_loads('17100000-0000-0000-0000-0000000000c1', array['17100000-0000-0000-0000-0000000000f1']::uuid[], 'broker', '17100000-0000-0000-0000-0000000000b1', 'cif-00000000-0000-0000-0000-000000000071')::text$q$);
  if r not like 'ok:%"success": true%' then raise exception 'FAIL F7 draft: %', r; end if;
  v := (substr(r, 4)::jsonb ->> 'invoice_id')::uuid;
  r := pg_temp.as_owner(format($q$select public.mark_carrier_invoice_ready_for_issue(%L, (select updated_at from public.carrier_invoices where id = %L), 'cif-00000000-0000-0000-0000-000000000072')::text$q$, v, v));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL F7 ready: %', r; end if;
  upd := substr(r, 4)::jsonb ->> 'updated_at';
  r := pg_temp.as_owner(format($q$select public.issue_prepared_carrier_invoice(%L, %L::timestamptz, 'Load delivered, ready to bill', 'cif-00000000-0000-0000-0000-000000000073')::text$q$, v, upd));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL F7 issue: %', r; end if;
  select snapshot_payload into snap from public.carrier_invoice_issuance_snapshots where invoice_id = v;
  -- the saved (nested) shape the app's normalizeIssuedSnapshot() maps for the PDF / packet / email
  if coalesce(snap->'factoring'->>'mode', '') <> 'factored' or coalesce(snap->'factoring'->'company'->>'name', '') <> 'Apex Funding'
     or coalesce(snap->'factoring'->'submission'->>'method', '') <> 'secure_email' or coalesce(snap->'factoring'->'submission'->>'destination', '') <> 'ops@apex.test'
     or coalesce(snap->'factoring'->>'remittance_instructions', '') not like 'Apex Funding, 1 Main St%' or coalesce(snap->'factoring'->'noa'->>'reference', '') <> 'Apex Funding NOA' then
    raise exception 'FAIL F7: factoring not on the issued invoice as expected: %', snap->'factoring';
  end if;
  raise notice 'OK F7: issued invoice is payable to the factor (Apex Funding, remit-to and paperwork email recorded).';
end $$;

-- F8: "Stop factoring" switches back to direct
do $$
declare r text; v_upd text;
begin
  select updated_at::text into v_upd from public.carriers where id = '17100000-0000-0000-0000-0000000000c1';
  r := pg_temp.as_owner(format($q$select public.set_carrier_factoring_policy('17100000-0000-0000-0000-0000000000c1', 'direct', 'Stopped factoring from the invoice page', %L::timestamptz, null)::text$q$, v_upd));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL F8: %', r; end if;
  raise notice 'OK F8: Stop factoring switches the carrier back to "Doesn''t factor".';
end $$;

do $$ begin raise notice 'ALL INVOICE-PAGE FACTORING SETUP CHECKS PASSED'; end $$;
rollback;
