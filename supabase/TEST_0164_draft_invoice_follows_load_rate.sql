-- =============================================================================
-- TEST_0164_draft_invoice_follows_load_rate.sql -- PRODUCTION TWIN ONLY
-- (supabase/ci/twin-db.sh). NEVER run on a real database. Ends in ROLLBACK.
--
--   R1  delivered load (rate 7499.31) -> draft invoice 7499.31; the
--       dispatcher corrects the rate to 7500 -> the draft invoice is 7500.00
--   R2  a hand-edited draft freight line is NOT overwritten
--   R3  a SENT invoice is NOT changed by a rate change
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values
 ('16400000-0000-0000-0000-00000000000a', 'o164@test.invalid', 'authenticated', 'authenticated'),
 ('16400000-0000-0000-0000-00000000000d', 'd164@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"16400000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T164 Org', 't164-org') is not null; reset role;
select id as org from public.organizations where slug = 't164-org' \gset
set local app.bypass_profile_guard = 'true';
update public.profiles set organization_id = :'org', role = 'dispatcher' where id = '16400000-0000-0000-0000-00000000000d';
set local app.bypass_profile_guard = 'false';
insert into public.brokers (id, organization_id, company_name, legal_name) values ('16400000-0000-0000-0000-0000000000b1', :'org', 'B164', 'B164 LLC');

-- three delivered loads with auto-created draft invoices at 7499.31
create or replace function pg_temp.delivered_load(p_n text) returns uuid language plpgsql as $$
declare v_load uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"16400000-0000-0000-0000-00000000000d","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_load := public.create_load_with_stops(
    jsonb_build_object('broker_id', '16400000-0000-0000-0000-0000000000b1', 'status', 'booked', 'rate', 7499.31, 'total_miles', 100),
    jsonb_build_array(jsonb_build_object('stop_type', 'pickup', 'stop_sequence', 1, 'city', 'A', 'state', 'TX'),
                      jsonb_build_object('stop_type', 'delivery', 'stop_sequence', 2, 'city', 'B', 'state', 'TX')));
  update public.loads set status = 'delivered' where id = v_load;
  execute 'reset role';
  return v_load;
end $$;
select pg_temp.delivered_load('1') as l1 \gset
select pg_temp.delivered_load('2') as l2 \gset
select pg_temp.delivered_load('3') as l3 \gset
select set_config('t164.ids', :'l1' || ',' || :'l2' || ',' || :'l3', true);

do $$
declare ids uuid[] := string_to_array(current_setting('t164.ids'), ',')::uuid[];
begin
  if (select count(*) from public.invoices where load_id = any(ids) and status = 'draft' and total_amount = 7499.31) <> 3 then
    raise exception 'SETUP: expected 3 draft invoices at 7499.31';
  end if;
end $$;

-- R2 setup: hand-edit load 2's freight line; R3 setup: load 3's invoice is sent (POD verified)
update public.invoice_line_items set unit_price = 8000 where invoice_id = (select id from public.invoices where load_id = :'l2');
insert into public.documents (organization_id, entity_type, entity_id, document_type, file_name, file_path, is_verified)
  values (:'org', 'load', :'l3', 'pod', 'pod.jpg', 'x/pod.jpg', true);
update public.invoices set status = 'sent' where load_id = :'l3';

-- the dispatcher corrects all three rates to 7500 (load edit form: load_financials upsert)
select set_config('request.jwt.claims', '{"sub":"16400000-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
insert into public.load_financials (load_id, organization_id, rate)
  select unnest(array[:'l1', :'l2', :'l3']::uuid[]), :'org', 7500
  on conflict (load_id) do update set rate = excluded.rate;
reset role;

do $$
declare ids uuid[] := string_to_array(current_setting('t164.ids'), ',')::uuid[];
begin
  if (select total_amount from public.invoices where load_id = ids[1]) <> 7500 then raise exception 'FAIL R1: draft invoice is %', (select total_amount from public.invoices where load_id = ids[1]); end if;
  raise notice 'OK R1: rate corrected to 7500 by the dispatcher -> draft invoice is now 7500.00.';
  if (select total_amount from public.invoices where load_id = ids[2]) <> 8000 then raise exception 'FAIL R2: hand-edited draft changed'; end if;
  raise notice 'OK R2: a hand-edited draft line (8000) is left alone.';
  if (select total_amount from public.invoices where load_id = ids[3]) <> 7499.31 then raise exception 'FAIL R3: sent invoice changed'; end if;
  raise notice 'OK R3: a sent invoice is not changed by a rate change.';
end $$;

do $$ begin raise notice 'ALL 0164 CHECKS PASSED'; end $$;
rollback;
