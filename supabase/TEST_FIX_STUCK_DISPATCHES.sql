-- =============================================================================
-- TEST_FIX_STUCK_DISPATCHES.sql -- PRODUCTION TWIN ONLY, and run LAST: the
-- maintenance scripts commit, so this test cleans up its own rows at the end.
--   S1  preview lists exactly the stuck dispatch (load delivered, dispatch not)
--   S2  the fix marks it delivered, dated the delivery stop's departure
--   S3  preview is empty afterwards; re-running the fix changes nothing
-- =============================================================================
\set ON_ERROR_STOP 1
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values ('16700000-0000-0000-0000-00000000000a', 'o167@test.invalid', 'authenticated', 'authenticated');
begin;
select set_config('request.jwt.claims', '{"sub":"16700000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T167 Org', 't167-org') is not null; reset role;
commit;
select id as org from public.organizations where slug = 't167-org' \gset
insert into public.carriers (id, organization_id, legal_name) values ('16700000-0000-0000-0000-0000000000c1', :'org', 'Stuck Carrier');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values ('16700000-0000-0000-0000-0000000000d1', :'org', '16700000-0000-0000-0000-0000000000c1', 'S', 'D');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values ('16700000-0000-0000-0000-0000000000e1', :'org', '16700000-0000-0000-0000-0000000000c1', 'S1');
insert into public.loads (id, organization_id, load_number, status, carrier_id) values ('16700000-0000-0000-0000-0000000000f1', :'org', 'L167-1', 'booked', '16700000-0000-0000-0000-0000000000c1');
insert into public.load_financials (load_id, organization_id, rate) values ('16700000-0000-0000-0000-0000000000f1', :'org', 1000);
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, city, state, departed_at) values
 (:'org', '16700000-0000-0000-0000-0000000000f1', 'delivery', 2, 'B', 'TX', '2026-09-15 15:00+00');
begin;
select set_config('request.jwt.claims', '{"sub":"16700000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
select public.create_dispatch('16700000-0000-0000-0000-0000000000f1', '16700000-0000-0000-0000-0000000000c1', '16700000-0000-0000-0000-0000000000e1', '16700000-0000-0000-0000-0000000000d1', null, 10, null) is not null;
reset role;
commit;
-- the pre-0166 state: load delivered on the load page, dispatch left behind
set session_replication_role = replica;
update public.loads set status = 'delivered' where id = '16700000-0000-0000-0000-0000000000f1';
set session_replication_role = origin;

-- S1: the preview runs and lists this load (its output is checked by eye in the log)
\ir maintenance/STUCK_DISPATCHES_PREVIEW_READONLY.sql
do $$ begin
  if (select count(*) from public.dispatches d join public.loads l on l.id = d.load_id
       where l.status::text in ('delivered', 'pod_received', 'invoiced', 'closed') and d.status not in ('delivered', 'completed', 'cancelled')) <> 1 then
    raise exception 'FAIL S1: expected exactly 1 stuck dispatch';
  end if;
  raise notice 'OK S1: one stuck dispatch (L167-1) before the fix.';
end $$;

\ir maintenance/FIX_STUCK_DISPATCHES.sql
do $$
declare d record;
begin
  select * into d from public.dispatches where load_id = '16700000-0000-0000-0000-0000000000f1';
  if d.status::text <> 'delivered' or d.delivered_at <> '2026-09-15 15:00+00' then raise exception 'FAIL S2: % %', d.status, d.delivered_at; end if;
  if (select status::text from public.loads where id = '16700000-0000-0000-0000-0000000000f1') <> 'delivered' then raise exception 'FAIL S2: load changed'; end if;
  raise notice 'OK S2: dispatch marked delivered on 2026-09-15 (delivery stop departure); load unchanged.';
end $$;
\ir maintenance/FIX_STUCK_DISPATCHES.sql
\ir maintenance/STUCK_DISPATCHES_PREVIEW_READONLY.sql
do $$ begin raise notice 'OK S3: preview empty and the fix is safe to re-run.'; end $$;

-- clean up (the scripts committed)
set session_replication_role = replica;
delete from public.activity_logs where organization_id = :'org';
delete from public.dispatch_financials where organization_id = :'org';
delete from public.dispatches where organization_id = :'org';
delete from public.invoice_line_items where organization_id = :'org';
delete from public.invoices where organization_id = :'org';
delete from public.load_stops where organization_id = :'org';
delete from public.load_financials where organization_id = :'org';
delete from public.loads where organization_id = :'org';
delete from public.trucks where organization_id = :'org';
delete from public.drivers where organization_id = :'org';
delete from public.carriers where organization_id = :'org';
set session_replication_role = origin;
do $$ begin raise notice 'ALL STUCK-DISPATCH FIX CHECKS PASSED'; end $$;
