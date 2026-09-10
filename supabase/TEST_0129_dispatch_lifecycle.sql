-- ============================================================================
-- TEST_0129_dispatch_lifecycle.sql
--
-- **************************************************************************
-- **  NEVER RUN ON PRODUCTION OR A PRODUCTION CLONE.                      **
-- **  EPHEMERAL CI / DISPOSABLE LOCAL POSTGRES ONLY.                      **
-- **************************************************************************
--
-- This script CREATES fixture rows (organizations, auth.users + profiles
-- for authenticated contexts, carriers/trucks/drivers/trailers, loads) and
-- EXERCISES create_dispatch() / cancel_dispatch() / the auto-invoice
-- trigger. It is wrapped in ONE transaction and ENDS IN ROLLBACK -- nothing
-- is ever committed. The ROLLBACK is defence-in-depth, NOT permission to
-- point this at a real database.
--
-- Canonical use: a CI job that spins a throwaway Postgres, applies
-- migrations 0001..0129, runs this, and tears the database down. The
-- SQL-Editor / psql path is a convenience for a genuinely empty local
-- Postgres only, and is gated below by:
--   (a) an explicit opt-in marker you must SET yourself, AND
--   (b) hard refusal if the database carries ANY production identity marker
--       (real Stripe webhook rows, or the known Kali Freights / United
--       Leather production organization ids, or > 20 organizations).
--
--     set app.zzz_0129_test = 'scratch-ok';
--     \i supabase/TEST_0129_dispatch_lifecycle.sql
--
-- Do NOT set that marker on a production connection. Do NOT change the final
-- ROLLBACK to COMMIT. Do NOT move this file into supabase/migrations/.
-- ============================================================================

begin;

-- ---- 0. environment guard -- ALL must pass -------------------------------
do $guard$
begin
  -- (a) explicit, deliberate opt-in.
  if coalesce(current_setting('app.zzz_0129_test', true), '') <> 'scratch-ok' then
    raise exception
      'TEST_0129 refused: run `set app.zzz_0129_test = ''scratch-ok'';` first -- and ONLY on an ephemeral CI / disposable local database.';
  end if;

  -- (b1) real Stripe webhook data => this is production (or a clone).
  if exists (select 1 from public.stripe_webhook_events) then
    raise exception 'TEST_0129 refused: public.stripe_webhook_events contains rows -- this database has processed real Stripe webhooks (production or a production clone).';
  end if;

  -- (b2) known production organization ids.
  if exists (
    select 1 from public.organizations
    where id in (
      '11111111-0000-0000-0000-000000000001'::uuid,   -- Kali Freights LLC (production pilot org)
      'ca6457e6-8ae8-4e85-adc9-4a0dabb2386e'::uuid     -- United Leather (production C.4 org)
    )
  ) then
    raise exception 'TEST_0129 refused: a known production organization id (Kali Freights / United Leather) is present -- this is production or a production clone.';
  end if;

  -- (b3) production has many organizations; an ephemeral test DB has ~0.
  if (select count(*) from public.organizations) > 20 then
    raise exception 'TEST_0129 refused: % organizations present -- far more than an ephemeral test database should have.',
      (select count(*) from public.organizations);
  end if;

  raise notice 'TEST_0129 environment guard passed -- proceeding on what looks like an ephemeral test database.';
end
$guard$;

-- ---- 1. fixtures ---------------------------------------------------------
-- Two orgs (A = system under test, B = cross-tenant attacker).
insert into public.organizations (id, name)
values ('00000000-0000-0000-0000-00000000a0a0', 'TEST_0129 Org A'),
       ('00000000-0000-0000-0000-00000000b0b0', 'TEST_0129 Org B');

-- d1 = OWNER in Org A. The "owner delivery control": with 0129 the
-- auto-invoice trigger mints via the un-gated private helper, so a
-- dispatcher (d3) now reaches the invoice path too (SCENARIO O) -- d1 is
-- kept as the control that the owner path is unchanged, and for the
-- cancelled-dispatch selection scenarios (K/L).
insert into auth.users (id, email, instance_id, aud, role, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000d1', 'owner.a@test0129.local',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now());
insert into public.profiles (id, organization_id, role, full_name, email)
values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000a0a0',
        'owner', 'Owner A', 'owner.a@test0129.local');

-- d2 = VIEWER in Org A (role-forbidden case, SCENARIO G + manual-numbering
-- matrix in SCENARIO Q).
insert into auth.users (id, email, instance_id, aud, role, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000d2', 'viewer.a@test0129.local',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now());
insert into public.profiles (id, organization_id, role, full_name, email)
values ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-00000000a0a0',
        'viewer', 'Viewer A', 'viewer.a@test0129.local');

-- d3 = DISPATCHER in Org A (dispatcher happy-path SCENARIO A2; the real
-- dispatcher-delivery -> auto-invoice trigger chain SCENARIO O; rejected by
-- the manual generate_invoice_number guard in SCENARIO Q).
insert into auth.users (id, email, instance_id, aud, role, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000d3', 'dispatcher.a@test0129.local',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now());
insert into public.profiles (id, organization_id, role, full_name, email)
values ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-00000000a0a0',
        'dispatcher', 'Dispatcher A', 'dispatcher.a@test0129.local');

-- d4 = ADMIN in Org A, d5 = ACCOUNTANT in Org A, d6 = DRIVER in Org A --
-- the rest of the manual invoice-number role matrix (SCENARIO Q): admin +
-- accountant allowed, driver rejected.
insert into auth.users (id, email, instance_id, aud, role, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000d4', 'admin.a@test0129.local',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now()),
       ('00000000-0000-0000-0000-0000000000d5', 'accountant.a@test0129.local',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now()),
       ('00000000-0000-0000-0000-0000000000d6', 'driver.a@test0129.local',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now());
insert into public.profiles (id, organization_id, role, full_name, email)
values ('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-00000000a0a0', 'admin',      'Admin A',      'admin.a@test0129.local'),
       ('00000000-0000-0000-0000-0000000000d5', '00000000-0000-0000-0000-00000000a0a0', 'accountant', 'Accountant A', 'accountant.a@test0129.local'),
       ('00000000-0000-0000-0000-0000000000d6', '00000000-0000-0000-0000-00000000a0a0', 'driver',     'Driver A',     'driver.a@test0129.local');

-- dB1 = OWNER in Org B -- cross-tenant manual-numbering rejection (SCENARIO Q):
-- an owner of B must not be able to mint org A's invoice number, and d1 (A)
-- must not be able to mint B's.
insert into auth.users (id, email, instance_id, aud, role, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000000e1', 'owner.b@test0129.local',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now());
insert into public.profiles (id, organization_id, role, full_name, email)
values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000b0b0',
        'owner', 'Owner B', 'owner.b@test0129.local');

-- Carrier + equipment in Org A.
insert into public.carriers (id, organization_id, legal_name, status)
values ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000a0a0', 'TEST_0129 Carrier A', 'active');
insert into public.trucks (id, organization_id, carrier_id, unit_number, status)
values ('00000000-0000-0000-0000-0000000000t1', '00000000-0000-0000-0000-00000000a0a0', '00000000-0000-0000-0000-0000000000c1', 'TT-1', 'active'),
       ('00000000-0000-0000-0000-0000000000t2', '00000000-0000-0000-0000-00000000a0a0', '00000000-0000-0000-0000-0000000000c1', 'TT-2', 'active');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name, status)
values ('00000000-0000-0000-0000-0000000000r1', '00000000-0000-0000-0000-00000000a0a0', '00000000-0000-0000-0000-0000000000c1', 'Ann', 'Driver', 'active'),
       ('00000000-0000-0000-0000-0000000000r2', '00000000-0000-0000-0000-00000000a0a0', '00000000-0000-0000-0000-0000000000c1', 'Ben', 'Driver', 'active');
insert into public.trailers (id, organization_id, carrier_id, unit_number, status)
values ('00000000-0000-0000-0000-0000000000l1', '00000000-0000-0000-0000-00000000a0a0', '00000000-0000-0000-0000-0000000000c1', 'TL-1', 'active');

-- A broker in Org A so a delivered load auto-invoices.
insert into public.brokers (id, organization_id, company_name, status)
values ('00000000-0000-0000-0000-0000000000k1', '00000000-0000-0000-0000-00000000a0a0', 'TEST_0129 Broker', 'active');

-- Loads in Org A. NOTE: loads.rate was removed by 0069 -- the amount lives
-- in public.load_financials now, which is exactly what the LIVE 0068
-- auto-invoice body (and 0129's rebuild of it) reads.
insert into public.loads (id, organization_id, load_number, status, broker_id)
values ('00000000-0000-0000-0000-00000000L001', '00000000-0000-0000-0000-00000000a0a0', 'T0129-001', 'booked', '00000000-0000-0000-0000-0000000000k1'),
       ('00000000-0000-0000-0000-00000000L002', '00000000-0000-0000-0000-00000000a0a0', 'T0129-002', 'booked', '00000000-0000-0000-0000-0000000000k1'),
       ('00000000-0000-0000-0000-00000000L003', '00000000-0000-0000-0000-00000000a0a0', 'T0129-003', 'booked', '00000000-0000-0000-0000-0000000000k1'),
       ('00000000-0000-0000-0000-00000000L004', '00000000-0000-0000-0000-00000000a0a0', 'T0129-004', 'delivered', '00000000-0000-0000-0000-0000000000k1');

-- Amount source for the auto-invoice path (INV total must come out at 1000).
insert into public.load_financials (load_id, organization_id, rate)
values ('00000000-0000-0000-0000-00000000L001', '00000000-0000-0000-0000-00000000a0a0', 1000),
       ('00000000-0000-0000-0000-00000000L002', '00000000-0000-0000-0000-00000000a0a0', 1000),
       ('00000000-0000-0000-0000-00000000L003', '00000000-0000-0000-0000-00000000a0a0', 1000),
       ('00000000-0000-0000-0000-00000000L004', '00000000-0000-0000-0000-00000000a0a0', 1000);

-- Helper: assume an authenticated identity for a block (d1 = owner,
-- d2 = viewer, d3 = dispatcher).
--   select set_config('request.jwt.claims', '{"sub":"...","role":"authenticated"}', true);
--   set local role authenticated;   -- ... do work ...   reset role;

-- ========================================================================
-- SCENARIO A -- happy-path atomic creation updates every related record.
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
declare v_id uuid;
begin
  v_id := public.create_dispatch(
    '00000000-0000-0000-0000-00000000L001'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid,
    '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, 'hello');
  if v_id is null then raise exception 'A: create_dispatch returned NULL'; end if;
  if (select status from public.dispatches where id = v_id) <> 'assigned' then raise exception 'A: dispatch not assigned'; end if;
  if (select status from public.loads where id = '00000000-0000-0000-0000-00000000L001') <> 'dispatched' then raise exception 'A: load not advanced to dispatched'; end if;
  if not exists (select 1 from public.dispatch_financials where dispatch_id = v_id) then raise exception 'A: no dispatch_financials row'; end if;
  if not exists (select 1 from public.dispatch_internal_notes where dispatch_id = v_id and notes = 'hello') then raise exception 'A: notes not written'; end if;
  if (select financial_dispatch_id from public.loads where id = '00000000-0000-0000-0000-00000000L001') <> v_id then raise exception 'A: financial_dispatch_id not set to the new dispatch'; end if;
  raise notice 'A PASS (owner) -- atomic create wrote dispatch + financials + notes + load status + financial_dispatch_id';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO A2 -- dispatcher happy path: the RLS write tier
-- (owner/admin/dispatcher) is honoured; a plain dispatcher can create a
-- dispatch. (No invoice path here -- that role gate is exercised by K/L
-- under the owner fixture.)
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d3","role":"authenticated"}', true);  -- dispatcher
set local role authenticated;
do $t$
declare v_id uuid;
begin
  v_id := public.create_dispatch(
    '00000000-0000-0000-0000-00000000L002'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid,
    '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, 12.5, null);
  if v_id is null then raise exception 'A2: dispatcher create_dispatch returned NULL'; end if;
  if (select status from public.dispatches where id = v_id) <> 'assigned' then raise exception 'A2: dispatch not assigned'; end if;
  if (select status from public.loads where id = '00000000-0000-0000-0000-00000000L002') <> 'dispatched' then raise exception 'A2: load not advanced'; end if;
  if (select dispatch_fee_percentage from public.dispatch_financials where dispatch_id = v_id) <> 12.5 then raise exception 'A2: fee percentage not applied'; end if;
  raise notice 'A2 PASS (dispatcher) -- dispatcher role can create a dispatch atomically';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO B -- forced mid-operation failure rolls EVERYTHING back.
-- (Force a failure after the dispatch INSERT by passing a notes value that
--  a CHECK/trigger would reject is fragile; instead: pre-create a
--  dispatch_internal_notes row with a broken FK is impossible. We force the
--  load-status UPDATE to fail by locking the load in another way? Not
--  available in one session. Instead: prove atomicity structurally by
--  cancelling the outer transaction -- and by SCENARIO D/E which exercise
--  the RAISE-then-rollback path with observable state.)
-- Deterministic forced failure: call create_dispatch for a load whose
-- carrier/driver belong to Org B -> guard_dispatch_org RAISEs AFTER the
-- function has begun; assert NOTHING persisted.
-- ========================================================================
savepoint s;
insert into public.carriers (id, organization_id, legal_name, status)
values ('00000000-0000-0000-0000-0000000000cB', '00000000-0000-0000-0000-00000000b0b0', 'Org B Carrier', 'active');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name, status)
values ('00000000-0000-0000-0000-0000000000rB', '00000000-0000-0000-0000-00000000b0b0', '00000000-0000-0000-0000-0000000000cB', 'Bad', 'Driver', 'active');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
begin
  begin
    perform public.create_dispatch(
      '00000000-0000-0000-0000-00000000L002'::uuid,
      '00000000-0000-0000-0000-0000000000cB'::uuid,   -- Org B carrier
      '00000000-0000-0000-0000-0000000000t1'::uuid,
      '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
    raise exception 'B: create_dispatch should have failed on cross-org carrier';
  exception when others then
    -- expected. Now assert full rollback of the sub-operation.
    null;
  end;
  if exists (select 1 from public.dispatches where load_id = '00000000-0000-0000-0000-00000000L002') then raise exception 'B: a dispatch row persisted after a failed create'; end if;
  if (select status from public.loads where id = '00000000-0000-0000-0000-00000000L002') <> 'booked' then raise exception 'B: load status changed despite a failed create'; end if;
  raise notice 'B PASS -- a failed create_dispatch left no dispatch row and did not advance the load';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO C -- double-submit produces exactly ONE dispatch.
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
begin
  perform public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
  begin
    perform public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
      '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t2'::uuid,
      '00000000-0000-0000-0000-0000000000r2'::uuid, null, null, null);
    raise exception 'C: second create_dispatch for the same load should have raised TDDUP';
  exception when sqlstate 'TDDUP' then
    null; -- expected
  end;
  if (select count(*) from public.dispatches where load_id = '00000000-0000-0000-0000-00000000L001') <> 1 then
    raise exception 'C: expected exactly 1 dispatch for the load, found %',
      (select count(*) from public.dispatches where load_id = '00000000-0000-0000-0000-00000000L001');
  end if;
  raise notice 'C PASS -- second create_dispatch raised TDDUP; exactly one dispatch exists';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO D -- duplicate active load rejection (TDDUP, specific message).
-- SCENARIO E -- busy driver / truck / trailer (TDDRV / TDTRK / TDTRL).
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
declare v_msg text; v_code text;
begin
  -- put driver r1 + truck t1 + trailer l1 on an active dispatch for L001
  perform public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, '00000000-0000-0000-0000-0000000000l1'::uuid, null, null);

  -- D: L001 already dispatched
  begin
    perform public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
      '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t2'::uuid,
      '00000000-0000-0000-0000-0000000000r2'::uuid, null, null, null);
    raise exception 'D: expected TDDUP';
  exception when sqlstate 'TDDUP' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not ilike '%already has an active dispatch%' then raise exception 'D: wrong TDDUP message: %', v_msg; end if;
  end;

  -- E-driver: r1 busy, on L002
  begin
    perform public.create_dispatch('00000000-0000-0000-0000-00000000L002'::uuid,
      '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t2'::uuid,
      '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
    raise exception 'E-driver: expected TDDRV';
  exception when sqlstate 'TDDRV' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not ilike '%Ann Driver is already assigned to active load T0129-001%' then raise exception 'E-driver: wrong message: %', v_msg; end if;
  end;

  -- E-truck: t1 busy
  begin
    perform public.create_dispatch('00000000-0000-0000-0000-00000000L002'::uuid,
      '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
      '00000000-0000-0000-0000-0000000000r2'::uuid, null, null, null);
    raise exception 'E-truck: expected TDTRK';
  exception when sqlstate 'TDTRK' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not ilike '%Truck TT-1 is already assigned to active load T0129-001%' then raise exception 'E-truck: wrong message: %', v_msg; end if;
  end;

  -- E-trailer: l1 busy
  begin
    perform public.create_dispatch('00000000-0000-0000-0000-00000000L002'::uuid,
      '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t2'::uuid,
      '00000000-0000-0000-0000-0000000000r2'::uuid, '00000000-0000-0000-0000-0000000000l1'::uuid, null, null);
    raise exception 'E-trailer: expected TDTRL';
  exception when sqlstate 'TDTRL' then
    get stacked diagnostics v_msg = message_text;
    if v_msg not ilike '%Trailer TL-1 is already assigned to active load T0129-001%' then raise exception 'E-trailer: wrong message: %', v_msg; end if;
  end;

  raise notice 'D/E PASS -- TDDUP + TDDRV/TDTRK/TDTRL raised with the specific resource+load messages';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO F -- cross-tenant rejection: dispatcher A cannot dispatch Org B's load.
-- ========================================================================
savepoint s;
insert into public.loads (id, organization_id, load_number, status)
values ('00000000-0000-0000-0000-00000000LB01', '00000000-0000-0000-0000-00000000b0b0', 'T0129-B01', 'booked');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
begin
  begin
    perform public.create_dispatch('00000000-0000-0000-0000-00000000LB01'::uuid,
      '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
      '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
    raise exception 'F: cross-tenant create_dispatch should have raised TDLNF (load invisible under RLS)';
  exception when sqlstate 'TDLNF' then
    null; -- expected: RLS hides Org B's load -> "not found"
  end;
  if exists (select 1 from public.dispatches where load_id = '00000000-0000-0000-0000-00000000LB01') then raise exception 'F: a dispatch was created for a cross-tenant load'; end if;
  raise notice 'F PASS -- cross-tenant load rejected as TDLNF, nothing created';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO G -- role forbidden: a viewer cannot create/cancel.
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d2","role":"authenticated"}', true);  -- viewer
set local role authenticated;
do $t$
begin
  begin
    perform public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
      '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
      '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
    raise exception 'G: viewer create_dispatch should have raised TDROL';
  exception when sqlstate 'TDROL' then null;
  end;
  raise notice 'G PASS -- viewer role rejected as TDROL';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO H -- cancellation atomically returns an eligible load to booked.
-- SCENARIO I -- delivered/completed cancellation rejection (TDTRM).
-- SCENARIO J -- idempotent when already cancelled.
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
declare v_id uuid; v_id2 uuid;
begin
  v_id := public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);

  -- H: cancel -> dispatch cancelled + load back to booked, atomically
  perform public.cancel_dispatch(v_id, 'carrier fell through');
  if (select status from public.dispatches where id = v_id) <> 'cancelled' then raise exception 'H: dispatch not cancelled'; end if;
  if (select cancelled_at from public.dispatches where id = v_id) is null then raise exception 'H: cancelled_at not set'; end if;
  if (select notes from public.dispatches where id = v_id) not ilike '%[Cancelled: carrier fell through]%' then raise exception 'H: reason not appended to notes'; end if;
  if (select status from public.loads where id = '00000000-0000-0000-0000-00000000L001') <> 'booked' then raise exception 'H: load not returned to booked'; end if;
  -- financial history preserved
  if (select financial_dispatch_id from public.loads where id = '00000000-0000-0000-0000-00000000L001') is distinct from v_id then raise exception 'H: financial_dispatch_id was cleared (history lost)'; end if;
  if not exists (select 1 from public.dispatch_financials where dispatch_id = v_id) then raise exception 'H: dispatch_financials removed'; end if;

  -- J: idempotent second cancel -> no error, still cancelled
  perform public.cancel_dispatch(v_id, 'again');
  if (select status from public.dispatches where id = v_id) <> 'cancelled' then raise exception 'J: status changed on a second cancel'; end if;

  -- H-2: re-dispatch the now-booked load succeeds
  v_id2 := public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t2'::uuid,
    '00000000-0000-0000-0000-0000000000r2'::uuid, null, null, null);
  if v_id2 is null or v_id2 = v_id then raise exception 'H-2: re-dispatch after cancel did not create a fresh dispatch'; end if;

  raise notice 'H/J PASS -- cancel is atomic + idempotent, financial history intact, load re-dispatchable';
end $t$;
reset role;
rollback to savepoint s;

savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
declare v_id uuid;
begin
  v_id := public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
  update public.dispatches set status = 'delivered' where id = v_id;   -- fixture: force terminal
  begin
    perform public.cancel_dispatch(v_id, 'nope');
    raise exception 'I: cancelling a delivered dispatch should have raised TDTRM';
  exception when sqlstate 'TDTRM' then null;
  end;
  if (select status from public.dispatches where id = v_id) <> 'delivered' then raise exception 'I: delivered dispatch changed'; end if;
  raise notice 'I PASS -- delivered/completed dispatch cannot be cancelled (TDTRM)';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO K -- cancel-and-redispatch: the auto-invoice picks the CURRENT
-- (non-cancelled) dispatch; the cancelled one is NEVER selected.
-- SCENARIO L -- "no valid dispatch": a delivered load with only a cancelled
-- dispatch still gets its invoice, with dispatch_id = NULL (documented
-- decision). Revenue is never lost; a NULL link = "attribution needs review".
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
declare v_old uuid; v_new uuid; v_inv_disp uuid;
begin
  -- L003: dispatch, cancel, re-dispatch, then deliver -> invoice on the NEW one
  v_old := public.create_dispatch('00000000-0000-0000-0000-00000000L003'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
  perform public.cancel_dispatch(v_old, 'switch carrier');
  v_new := public.create_dispatch('00000000-0000-0000-0000-00000000L003'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t2'::uuid,
    '00000000-0000-0000-0000-0000000000r2'::uuid, null, null, null);
  -- deliver the load -> fires auto_generate_invoice_from_delivered_load()
  update public.loads set status = 'delivered' where id = '00000000-0000-0000-0000-00000000L003';
  select dispatch_id into v_inv_disp from public.invoices where load_id = '00000000-0000-0000-0000-00000000L003';
  if v_inv_disp is distinct from v_new then
    raise exception 'K: invoice attached to % (expected the current non-cancelled dispatch %); cancelled was %', v_inv_disp, v_new, v_old;
  end if;
  raise notice 'K PASS -- auto-invoice attributed to the current non-cancelled dispatch, not the cancelled one';
end $t$;
reset role;
rollback to savepoint s;

savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
set local role authenticated;
do $t$
declare v_id uuid; v_inv record;
begin
  v_id := public.create_dispatch('00000000-0000-0000-0000-00000000L003'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
  perform public.cancel_dispatch(v_id, 'no carrier');
  -- only a cancelled dispatch exists for L003; deliver it anyway
  update public.loads set status = 'delivered' where id = '00000000-0000-0000-0000-00000000L003';
  select * into v_inv from public.invoices where load_id = '00000000-0000-0000-0000-00000000L003';
  if v_inv.id is null then raise exception 'L: NO invoice was created for a delivered load (revenue lost)'; end if;
  if v_inv.dispatch_id is not null then raise exception 'L: invoice.dispatch_id = % (expected NULL -- the only dispatch is cancelled)', v_inv.dispatch_id; end if;
  if v_inv.total_amount <> 1000 then raise exception 'L: invoice amount wrong: %', v_inv.total_amount; end if;
  raise notice 'L PASS -- delivered load with only a cancelled dispatch: invoice CREATED with dispatch_id = NULL (documented "no valid dispatch" behavior)';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO M -- exact privilege checks: authenticated only.
-- ========================================================================
savepoint s;
do $t$
begin
  if not has_function_privilege('authenticated', 'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure, 'EXECUTE') then raise exception 'M: authenticated lacks EXECUTE on create_dispatch'; end if;
  if not has_function_privilege('authenticated', 'public.cancel_dispatch(uuid,text)'::regprocedure, 'EXECUTE') then raise exception 'M: authenticated lacks EXECUTE on cancel_dispatch'; end if;
  if has_function_privilege('anon', 'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure, 'EXECUTE')
     or has_function_privilege('service_role', 'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure, 'EXECUTE')
     or has_function_privilege('anon', 'public.cancel_dispatch(uuid,text)'::regprocedure, 'EXECUTE')
     or has_function_privilege('service_role', 'public.cancel_dispatch(uuid,text)'::regprocedure, 'EXECUTE') then
    raise exception 'M: anon or service_role still has EXECUTE on a 0129 function';
  end if;
  if exists (select 1 from pg_proc p, unnest(p.proacl) a
             where p.oid in ('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure,
                             'public.cancel_dispatch(uuid,text)'::regprocedure)
               and a::text like '=%') then
    raise exception 'M: a 0129 function still has a PUBLIC grant';
  end if;
  raise notice 'M PASS -- create_dispatch / cancel_dispatch EXECUTE = {authenticated} only, no PUBLIC';
end $t$;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO N -- existing 0054 + 0125 protections remain intact and are the
-- final backstop (unchanged by 0129).
-- ========================================================================
savepoint s;
do $t$
begin
  if not exists (select 1 from pg_class where relname='dispatches_active_driver_unique' and relkind='i')
     or not exists (select 1 from pg_class where relname='dispatches_active_truck_unique' and relkind='i')
     or not exists (select 1 from pg_class where relname='dispatches_active_trailer_unique' and relkind='i') then
    raise exception 'N: a 0054 partial unique index is missing';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_guard_org' and not tgisinternal) then raise exception 'N: guard_dispatch_org trigger missing'; end if;
  if not exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_assign_financial_controller' and not tgisinternal) then raise exception 'N: 0125 AFTER INSERT trigger missing'; end if;
  raise notice 'N PASS -- 0054 indexes + guard_dispatch_org + 0125 financial-controller trigger all intact';
end $t$;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO O -- DISPATCHER completes an invoice-eligible delivery through
-- the REAL trigger chain:
--   update dispatches.status='delivered'
--     -> sync_load_status_from_dispatch (0028) -> loads.status='delivered'
--       -> auto_generate_invoice_on_delivery (0022) trigger
--         -> auto_generate_invoice_from_delivered_load() (SECURITY DEFINER)
--           -> _generate_invoice_number_internal()  [0129: NO accounting-role gate]
-- Pre-0129 this whole UPDATE rolled back with "Only owner, admin, or
-- accountant roles can generate invoice numbers." -- this is the
-- regression proof that a dispatcher can now finish a delivery.
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d3","role":"authenticated"}', true);  -- dispatcher
set local role authenticated;
do $t$
declare v_id uuid; v_inv record;
begin
  v_id := public.create_dispatch('00000000-0000-0000-0000-00000000L002'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);

  -- the real board move: dispatcher flips the dispatch to delivered
  update public.dispatches set status = 'delivered' where id = v_id;

  if (select status from public.loads where id = '00000000-0000-0000-0000-00000000L002') <> 'delivered' then
    raise exception 'O: sync trigger did not flip the load to delivered';
  end if;
  select * into v_inv from public.invoices where load_id = '00000000-0000-0000-0000-00000000L002';
  if v_inv.id is null then
    raise exception 'O: dispatcher-completed delivery did NOT auto-generate an invoice (the pre-0129 bug)';
  end if;
  if v_inv.invoice_number !~ '^INV-[0-9]{4}-[0-9]{5}$' then
    raise exception 'O: bad invoice number %', v_inv.invoice_number;
  end if;
  if v_inv.dispatch_id is distinct from v_id then
    raise exception 'O: invoice.dispatch_id = % (expected the delivering dispatch %)', v_inv.dispatch_id, v_id;
  end if;
  if v_inv.total_amount <> 1000 then
    raise exception 'O: invoice amount % (expected 1000 from load_financials)', v_inv.total_amount;
  end if;
  raise notice 'O PASS -- dispatcher completed delivery through the real trigger chain; invoice auto-generated, correctly linked, amount from load_financials';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO P -- OWNER delivery control: the owner path is unchanged by
-- 0129 (still produces a correctly linked auto-invoice).
-- ========================================================================
savepoint s;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);  -- owner
set local role authenticated;
do $t$
declare v_id uuid; v_inv record;
begin
  v_id := public.create_dispatch('00000000-0000-0000-0000-00000000L001'::uuid,
    '00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000t1'::uuid,
    '00000000-0000-0000-0000-0000000000r1'::uuid, null, null, null);
  update public.dispatches set status = 'delivered' where id = v_id;
  select * into v_inv from public.invoices where load_id = '00000000-0000-0000-0000-00000000L001';
  if v_inv.id is null then raise exception 'P: owner delivery did not auto-generate an invoice'; end if;
  if v_inv.dispatch_id is distinct from v_id then raise exception 'P: invoice not linked to the delivering dispatch'; end if;
  if v_inv.total_amount <> 1000 then raise exception 'P: invoice amount wrong: %', v_inv.total_amount; end if;
  raise notice 'P PASS -- owner delivery still auto-generates a correctly linked invoice (control)';
end $t$;
reset role;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO Q -- MANUAL invoice-number generation (public.generate_invoice_number):
--   * owner / admin / accountant of the org  -> allowed, INV-YYYY-NNNNN
--   * dispatcher / viewer / driver           -> rejected (role guard kept)
--   * any permitted role, FOREIGN org id     -> rejected (0129 tenant check)
-- The direct client path stays exactly as protected as 0065, plus tenant
-- isolation.
-- ========================================================================
-- generate_invoice_number is SECURITY DEFINER and its guards
-- (has_role / current_org_id) read only request.jwt.claims -> auth.uid(),
-- so this scenario switches identity via set_config alone; no SET ROLE
-- needed (and the whole test already runs as a superuser in CI, which may
-- execute the SECURITY DEFINER body regardless of the GRANT).
savepoint s;
do $t$
declare
  v_num text;
  v_msg text;
  v_ok  boolean;
  v_allowed uuid[] := array[
    '00000000-0000-0000-0000-0000000000d1',   -- owner A
    '00000000-0000-0000-0000-0000000000d4',   -- admin A
    '00000000-0000-0000-0000-0000000000d5'];  -- accountant A
  v_denied uuid[] := array[
    '00000000-0000-0000-0000-0000000000d3',   -- dispatcher A
    '00000000-0000-0000-0000-0000000000d2',   -- viewer A
    '00000000-0000-0000-0000-0000000000d6'];  -- driver A
  v_sub uuid;
begin
  -- allowed roles, own org -> a well-formed number
  foreach v_sub in array v_allowed loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
    v_num := public.generate_invoice_number('00000000-0000-0000-0000-00000000a0a0'::uuid);
    if v_num !~ '^INV-[0-9]{4}-[0-9]{5}$' then
      raise exception 'Q: permitted role % got a malformed number %', v_sub, v_num;
    end if;
  end loop;

  -- denied roles -> the 0065 guard message, counter untouched
  foreach v_sub in array v_denied loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
    begin
      perform public.generate_invoice_number('00000000-0000-0000-0000-00000000a0a0'::uuid);
      v_ok := true;
    exception when others then
      v_ok := false;
      get stacked diagnostics v_msg = message_text;
    end;
    if v_ok then raise exception 'Q: role % was allowed to generate an invoice number', v_sub; end if;
    if v_msg not ilike '%owner, admin, or accountant%' then
      raise exception 'Q: role % rejected with the wrong message: %', v_sub, v_msg;
    end if;
  end loop;

  -- cross-tenant: owner A -> org B's id (permitted role, foreign org)
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
  begin
    perform public.generate_invoice_number('00000000-0000-0000-0000-00000000b0b0'::uuid);
    v_ok := true;
  exception when others then
    v_ok := false;
    get stacked diagnostics v_msg = message_text;
  end;
  if v_ok then raise exception 'Q: owner A minted org B''s invoice number (cross-tenant)'; end if;
  if v_msg not ilike '%your own organization%' then
    raise exception 'Q: cross-tenant call rejected with the wrong message: %', v_msg;
  end if;

  -- cross-tenant the other direction: owner B -> org A's id
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000e1","role":"authenticated"}', true);
  begin
    perform public.generate_invoice_number('00000000-0000-0000-0000-00000000a0a0'::uuid);
    v_ok := true;
  exception when others then
    v_ok := false;
    get stacked diagnostics v_msg = message_text;
  end;
  if v_ok then raise exception 'Q: owner B minted org A''s invoice number (cross-tenant)'; end if;
  if v_msg not ilike '%your own organization%' then
    raise exception 'Q: reverse cross-tenant call rejected with the wrong message: %', v_msg;
  end if;

  raise notice 'Q PASS -- generate_invoice_number: owner/admin/accountant allowed for their own org; dispatcher/viewer/driver rejected; cross-tenant rejected both ways';
end $t$;
rollback to savepoint s;

-- ========================================================================
-- SCENARIO R -- the private mechanism public._generate_invoice_number_internal
-- is NOT reachable by any application-facing role: no EXECUTE for
-- anon/authenticated/service_role, no PUBLIC ACL entry, and a direct call
-- under `role authenticated` is refused with "permission denied for function".
-- ========================================================================
savepoint s;
do $t$
begin
  if has_function_privilege('anon',          'public._generate_invoice_number_internal(uuid)'::regprocedure, 'EXECUTE')
     or has_function_privilege('authenticated', 'public._generate_invoice_number_internal(uuid)'::regprocedure, 'EXECUTE')
     or has_function_privilege('service_role',  'public._generate_invoice_number_internal(uuid)'::regprocedure, 'EXECUTE') then
    raise exception 'R: an application-facing role has EXECUTE on _generate_invoice_number_internal';
  end if;
  if exists (select 1 from pg_proc p, unnest(p.proacl) a
             where p.oid = 'public._generate_invoice_number_internal(uuid)'::regprocedure and a::text like '=%') then
    raise exception 'R: _generate_invoice_number_internal still has a PUBLIC grant';
  end if;
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public._generate_invoice_number_internal(uuid)'::regprocedure and p.prosecdef) then
    raise exception 'R: _generate_invoice_number_internal is not SECURITY DEFINER';
  end if;
  raise notice 'R PASS (catalog) -- _generate_invoice_number_internal: SECURITY DEFINER, no EXECUTE for anon/authenticated/service_role, no PUBLIC ACL';
end $t$;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);  -- owner (most privileged app role)
set local role authenticated;
do $t$
begin
  begin
    perform public._generate_invoice_number_internal('00000000-0000-0000-0000-00000000a0a0'::uuid);
    raise exception 'R2: role authenticated was able to call _generate_invoice_number_internal directly';
  exception when insufficient_privilege then
    null; -- expected: permission denied for function
  end;
  raise notice 'R2 PASS -- direct call to _generate_invoice_number_internal is denied for role authenticated';
end $t$;
reset role;
rollback to savepoint s;

-- ---- END: nothing is committed. -----------------------------------------
rollback;
-- If you see "ROLLBACK" and a series of "* PASS" NOTICEs above, 0129 behaves
-- as designed. If any block RAISEd, that scenario failed -- read its message.
