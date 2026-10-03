-- =============================================================================
-- TEST_INVOICES_ONE_TAB.sql -- PRODUCTION TWIN ONLY (supabase/ci/twin-db.sh).
-- NEVER run on a real database. Ends in ROLLBACK. App flow behind the one
-- Invoices tab for a "broker pays the carrier" load:
--   M1  Create Invoice (one load) makes a carrier invoice draft
--   M2  discarding keeps status 'draft' but releases the ledger row, so the
--       app's "live" check (unreleased ledger row) frees the load
--   M3  the same load can be drafted again
--   M4  one-click issue: mark ready, then issue with the updated_at the
--       mark-ready result returned; the issued invoice still lists its load
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values ('17000000-0000-0000-0000-00000000000a', 'o170@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"17000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T170 Org', 't170-org') is not null; reset role;
select id as org from public.organizations where slug = 't170-org' \gset

insert into public.brokers (id, organization_id, company_name, legal_name) values ('17000000-0000-0000-0000-0000000000b1', :'org', 'B170', 'B170 LLC');
insert into public.carriers (id, organization_id, legal_name, invoice_code, factoring_mode, load_proceeds_model) values
 ('17000000-0000-0000-0000-0000000000c1', :'org', 'Direct Pay Carrier', 'DPC', 'direct', 'carrier_paid_directly'),
 ('17000000-0000-0000-0000-0000000000c2', :'org', 'Pays Us Carrier', 'PUC', 'direct', null);
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
 ('17000000-0000-0000-0000-0000000000d1', :'org', '17000000-0000-0000-0000-0000000000c1', 'A', 'One'),
 ('17000000-0000-0000-0000-0000000000d2', :'org', '17000000-0000-0000-0000-0000000000c2', 'B', 'Two');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
 ('17000000-0000-0000-0000-0000000000e1', :'org', '17000000-0000-0000-0000-0000000000c1', 'T1'),
 ('17000000-0000-0000-0000-0000000000e2', :'org', '17000000-0000-0000-0000-0000000000c2', 'T2');
insert into public.loads (id, organization_id, load_number, status, carrier_id, broker_id) values
 ('17000000-0000-0000-0000-0000000000f1', :'org', 'L170-1', 'booked', '17000000-0000-0000-0000-0000000000c1', '17000000-0000-0000-0000-0000000000b1'),
 ('17000000-0000-0000-0000-0000000000f2', :'org', 'L170-2', 'booked', '17000000-0000-0000-0000-0000000000c2', '17000000-0000-0000-0000-0000000000b1');
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, city, state) values
 (:'org', '17000000-0000-0000-0000-0000000000f1', 'pickup', 1, 'Austin', 'TX'),
 (:'org', '17000000-0000-0000-0000-0000000000f1', 'delivery', 2, 'Tulsa', 'OK');
insert into public.load_financials (load_id, organization_id, rate) values
 ('17000000-0000-0000-0000-0000000000f1', :'org', 2000), ('17000000-0000-0000-0000-0000000000f2', :'org', 3000);

create or replace function pg_temp.as_owner(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claims', '{"sub":"17000000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
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
  r := pg_temp.as_owner($q$select public.create_dispatch('17000000-0000-0000-0000-0000000000f1', '17000000-0000-0000-0000-0000000000c1', '17000000-0000-0000-0000-0000000000e1', '17000000-0000-0000-0000-0000000000d1', null, 10, null)::text$q$);
  if r not like 'ok:%' then raise exception 'SETUP d1: %', r; end if;
  r := pg_temp.as_owner($q$select public.create_dispatch('17000000-0000-0000-0000-0000000000f2', '17000000-0000-0000-0000-0000000000c2', '17000000-0000-0000-0000-0000000000e2', '17000000-0000-0000-0000-0000000000d2', null, 10, null)::text$q$);
  if r not like 'ok:%' then raise exception 'SETUP d2: %', r; end if;
  r := pg_temp.as_owner($q$update public.loads set status = 'delivered' where load_number in ('L170-1', 'L170-2') and organization_id = public.current_org_id() returning 1$q$);
end $$;
-- L170-2 ("broker pays us") got its broker draft on delivery; remove it so only the new guard is in play
delete from public.invoice_line_items where invoice_id in (select id from public.invoices where load_id = '17000000-0000-0000-0000-0000000000f2');
delete from public.invoices where load_id = '17000000-0000-0000-0000-0000000000f2';

-- the carrier's billing relationship with the broker (auto-created by the app)
do $$
declare r text;
begin
  r := pg_temp.as_owner($q$select public.activate_carrier_party('17000000-0000-0000-0000-0000000000c1', '17000000-0000-0000-0000-0000000000b1', null,
        '{"billing_email": "ap@b170.test", "payment_terms_days": 30, "factoring_eligible": true}'::jsonb)::text$q$);
  if r not like 'ok:%' then raise exception 'SETUP relationship: %', r; end if;
end $$;

do $$
declare r text; v1 uuid; v2 uuid; upd text;
begin
  -- M1
  r := pg_temp.as_owner($q$select public.create_carrier_invoice_draft_from_loads('17000000-0000-0000-0000-0000000000c1', array['17000000-0000-0000-0000-0000000000f1']::uuid[], 'broker', '17000000-0000-0000-0000-0000000000b1', 'cif-00000000-0000-0000-0000-000000000001')::text$q$);
  if r not like 'ok:%"success": true%' then raise exception 'FAIL M1: %', r; end if;
  v1 := (substr(r, 4)::jsonb ->> 'invoice_id')::uuid;
  if not exists (select 1 from public.carrier_invoice_billable_ledger_0157 where load_id = '17000000-0000-0000-0000-0000000000f1' and released_at is null and invoice_id = v1) then raise exception 'FAIL M1: no live ledger row'; end if;
  raise notice 'OK M1: Create Invoice made the carrier''s draft for the load.';

  -- M2
  r := pg_temp.as_owner(format($q$select public.discard_carrier_invoice_draft(%L, (select updated_at from public.carrier_invoices where id = %L), 'Created by mistake', 'cif-00000000-0000-0000-0000-000000000002')::text$q$, v1, v1));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL M2: %', r; end if;
  if (select issuance_status::text from public.carrier_invoices where id = v1) <> 'draft' then raise exception 'FAIL M2: status changed'; end if;
  if exists (select 1 from public.carrier_invoice_billable_ledger_0157 where invoice_id = v1 and released_at is null) then raise exception 'FAIL M2: ledger still live'; end if;
  if not exists (select 1 from public.carrier_invoice_loads where invoice_id = v1) then raise exception 'FAIL M2: expected the link row to stay (why the app uses the ledger)'; end if;
  raise notice 'OK M2: a discarded draft stays "draft" but its ledger row is released (app hides it, load is free).';

  -- M3
  r := pg_temp.as_owner($q$select public.create_carrier_invoice_draft_from_loads('17000000-0000-0000-0000-0000000000c1', array['17000000-0000-0000-0000-0000000000f1']::uuid[], 'broker', '17000000-0000-0000-0000-0000000000b1', 'cif-00000000-0000-0000-0000-000000000003')::text$q$);
  if r not like 'ok:%"success": true%' then raise exception 'FAIL M3: %', r; end if;
  v2 := (substr(r, 4)::jsonb ->> 'invoice_id')::uuid;
  raise notice 'OK M3: the load can be invoiced again.';

  -- M4
  r := pg_temp.as_owner(format($q$select public.mark_carrier_invoice_ready_for_issue(%L, (select updated_at from public.carrier_invoices where id = %L), 'cif-00000000-0000-0000-0000-000000000004')::text$q$, v2, v2));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL M4 ready: %', r; end if;
  upd := substr(r, 4)::jsonb ->> 'updated_at';
  if upd is null then raise exception 'FAIL M4: mark-ready returned no updated_at'; end if;
  r := pg_temp.as_owner(format($q$select public.issue_prepared_carrier_invoice(%L, %L::timestamptz, 'Load delivered, ready to bill', 'cif-00000000-0000-0000-0000-000000000005')::text$q$, v2, upd));
  if r not like 'ok:%"success": true%' then raise exception 'FAIL M4 issue: %', r; end if;
  if (select issuance_status::text from public.carrier_invoices where id = v2) <> 'issued' then raise exception 'FAIL M4: not issued'; end if;
  -- the invoice page lists an issued invoice's loads from its unreleased ledger rows
  if not exists (select 1 from public.carrier_invoice_billable_ledger_0157 where invoice_id = v2 and released_at is null) then raise exception 'FAIL M4: issued invoice has no live ledger row (its page would show no loads)'; end if;
  raise notice 'OK M4: one-click issue (mark ready, then issue with the returned updated_at) works: %', (select invoice_number from public.carrier_invoices where id = v2);
end $$;

do $$ begin raise notice 'ALL INVOICES-ONE-TAB CHECKS PASSED'; end $$;
rollback;
