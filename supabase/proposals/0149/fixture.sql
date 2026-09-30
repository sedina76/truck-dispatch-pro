-- =============================================================================
-- fixture.sql -- PROPOSAL 0149 disposable-database fixture.
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY. NOT A MIGRATION.
--
-- Applied by tests.py AFTER: TEST_SUPPORT_0130_0133_schema.sql, the 0129 BASELINE
-- create_dispatch()/cancel_dispatch() (extracted verbatim from migration 0129),
-- and the REAL migrations 0130..0135 (which install the real
-- guard_dispatch_carrier_scope() 0132 trigger the create path fires).
--
-- Adds only what the real create_dispatch()/cancel_dispatch() need that the shared
-- support schema does not model: dispatch_financials + dispatch_internal_notes
-- (0067 shapes and RLS policies, verbatim), RLS on the standard operational tables
-- (0010's loop, verbatim), a deterministic two-organisation seed, and test helpers.
-- dispatch_financials_sync (0068) is NOT modelled: it only computes money columns
-- and is irrelevant to the enum/text comparison under repair.
-- =============================================================================

-- BEGIN_GUARD
do $g$
begin
  if coalesce(current_setting('app.zzz_0149_test', true), '') <> 'scratch-ok' then
    raise exception 'TEST_0149 refused: set app.zzz_0149_test = ''scratch-ok'' -- and ONLY on the disposable cluster tests.py creates.';
  end if;
  if inet_server_addr() is not null
     or current_setting('listen_addresses') <> ''
     or current_user <> 'postgres'
     or current_database() !~ '^td0149_'
     or current_setting('port') <> '55491'
     or current_setting('data_directory') !~ '^/private/tmp/td0149-local-[A-Za-z0-9_]+/data$'
     or current_setting('unix_socket_directories') <> regexp_replace(current_setting('data_directory'), '/data$', '/socket')
  then
    raise exception 'TEST_0149 refused: not the disposable local td0149 cluster (never run this against Supabase/production).';
  end if;
end
$g$;
-- END_GUARD

-- ---- 0067: dispatch_financials / dispatch_internal_notes -------------------
create table public.dispatch_financials (
  dispatch_id uuid primary key references public.dispatches (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  dispatch_fee_percentage numeric(5, 2) not null default 10.00,
  load_rate numeric(10, 2) not null default 0,
  dispatch_fee_amount numeric(10, 2) not null default 0,
  carrier_net_amount numeric(10, 2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.dispatch_financials enable row level security;
create policy dispatch_financials_select on public.dispatch_financials
  for select using (organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy dispatch_financials_insert on public.dispatch_financials
  for insert with check (organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy dispatch_financials_update on public.dispatch_financials
  for update using (organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());

create table public.dispatch_internal_notes (
  dispatch_id uuid primary key references public.dispatches (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.dispatch_internal_notes enable row level security;
create policy dispatch_internal_notes_select on public.dispatch_internal_notes
  for select using (organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy dispatch_internal_notes_insert on public.dispatch_internal_notes
  for insert with check (organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));
create policy dispatch_internal_notes_update on public.dispatch_internal_notes
  for update using (organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());

-- ---- 0010: standard operational RLS (loop verbatim, subset of tables) -------
-- (trailers RLS already comes from the support schema.)
do $$
declare
  t text;
  standard_tables text[] := array['carriers', 'drivers', 'trucks', 'loads', 'dispatches'];
begin
  foreach t in array standard_tables loop
    execute format('alter table public.%I enable row level security;', t);
    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);
    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
        );
    $p$, t);
    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);
    execute format($p$
      create policy %1$I_delete on public.%1$I
        for delete using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin']::public.org_role[])
        );
    $p$, t);
  end loop;
end $$;

-- Supabase grants `authenticated` USAGE on schema auth (the real RPCs call auth.uid() as invoker).
grant usage on schema auth to authenticated;

-- ---- test helpers (schema td0149_t; never part of any proposal SQL) ---------
create schema td0149_t;
grant usage on schema td0149_t to authenticated;

create function td0149_t.id(p_name text) returns uuid language sql immutable
  as $$ select md5('td0149:' || p_name)::uuid $$;
grant execute on function td0149_t.id(text) to authenticated;

create table td0149_t.results (
  seq bigserial primary key, tag text not null, state text, msg text, detail text, new_id uuid
);
grant select, insert on td0149_t.results to authenticated;
grant usage on sequence td0149_t.results_seq_seq to authenticated;

-- try_*: run the real RPC, capture SQLSTATE/message/detail instead of aborting
-- (the exception block rolls back that call's own writes, like a failed RPC).
create function td0149_t.try_create(
  p_load uuid, p_carrier uuid, p_truck uuid, p_driver uuid, p_trailer uuid default null,
  p_fee numeric default null, p_notes text default null,
  out state text, out msg text, out detail text, out new_id uuid)
language plpgsql as $$
begin
  new_id := public.create_dispatch(p_load, p_carrier, p_truck, p_driver, p_trailer, p_fee, p_notes);
exception when others then
  get stacked diagnostics state := returned_sqlstate, msg := message_text, detail := pg_exception_detail;
  new_id := null;
end $$;
grant execute on function td0149_t.try_create(uuid, uuid, uuid, uuid, uuid, numeric, text) to authenticated;

create function td0149_t.try_cancel(p_dispatch uuid, p_reason text default null,
  out state text, out msg text, out detail text)
language plpgsql as $$
begin
  perform public.cancel_dispatch(p_dispatch, p_reason);
exception when others then
  get stacked diagnostics state := returned_sqlstate, msg := message_text, detail := pg_exception_detail;
end $$;
grant execute on function td0149_t.try_cancel(uuid, text) to authenticated;

-- run_*: as user <uid name>, record the outcome in td0149_t.results under <tag>.
create function td0149_t.run_create(p_tag text, p_user text, p_load uuid, p_carrier uuid, p_truck uuid, p_driver uuid,
  p_trailer uuid default null, p_fee numeric default null, p_notes text default null) returns void
language plpgsql as $$
begin
  perform set_config('test.current_uid', case when p_user is null then '' else td0149_t.id(p_user)::text end, false);
  insert into td0149_t.results (tag, state, msg, detail, new_id)
  select p_tag, r.state, r.msg, r.detail, r.new_id
  from td0149_t.try_create(p_load, p_carrier, p_truck, p_driver, p_trailer, p_fee, p_notes) r;
end $$;
grant execute on function td0149_t.run_create(text, text, uuid, uuid, uuid, uuid, uuid, numeric, text) to authenticated;

create function td0149_t.run_cancel(p_tag text, p_user text, p_dispatch uuid, p_reason text default null) returns void
language plpgsql as $$
begin
  perform set_config('test.current_uid', case when p_user is null then '' else td0149_t.id(p_user)::text end, false);
  insert into td0149_t.results (tag, state, msg, detail)
  select p_tag, r.state, r.msg, r.detail from td0149_t.try_cancel(p_dispatch, p_reason) r;
end $$;
grant execute on function td0149_t.run_cancel(text, text, uuid, text) to authenticated;

-- run_transition: the Dispatch Board's cancel path -- transition_dispatch_status() (0134, SECURITY DEFINER)
-- delegates to cancel_dispatch(); records the outcome under <tag>.
create function td0149_t.run_transition(p_tag text, p_user text, p_dispatch uuid, p_status public.dispatch_status, p_reason text default null) returns void
language plpgsql as $$
declare v_state text; v_msg text; v_detail text;
begin
  perform set_config('test.current_uid', case when p_user is null then '' else td0149_t.id(p_user)::text end, false);
  begin
    perform public.transition_dispatch_status(p_dispatch, p_status, p_reason, null);
  exception when others then
    get stacked diagnostics v_state := returned_sqlstate, v_msg := message_text, v_detail := pg_exception_detail;
  end;
  insert into td0149_t.results (tag, state, msg, detail) values (p_tag, v_state, v_msg, v_detail);
end $$;
grant execute on function td0149_t.run_transition(text, text, uuid, public.dispatch_status, text) to authenticated;

-- probe_create: like run_create but ALWAYS rolls its own effects back, so it can be
-- used repeatedly (e.g. once per dispatch_status value) without leaving rows.
create function td0149_t.probe_create(p_user text, p_load uuid, p_carrier uuid, p_truck uuid, p_driver uuid,
  p_trailer uuid default null,
  out state text, out msg text, out detail text, out created boolean)
language plpgsql as $$
declare r record;
begin
  perform set_config('test.current_uid', case when p_user is null then '' else td0149_t.id(p_user)::text end, false);
  begin
    select * into r from td0149_t.try_create(p_load, p_carrier, p_truck, p_driver, p_trailer);
    state := r.state; msg := r.msg; detail := r.detail; created := (r.new_id is not null);
    raise exception 'TD0149_SENTINEL';
  exception when others then
    if sqlerrm <> 'TD0149_SENTINEL' then raise; end if;
  end;
end $$;
grant execute on function td0149_t.probe_create(text, uuid, uuid, uuid, uuid, uuid) to authenticated;

-- ---- deterministic seed (superuser; bypasses RLS) ----------------------------
insert into public.organizations (id, name, slug) values
  (td0149_t.id('o1'), 'Org One', 'td0149-o1'), (td0149_t.id('o2'), 'Org Two', 'td0149-o2');
insert into auth.users (id) values (td0149_t.id('u_disp1')), (td0149_t.id('u_acct1')), (td0149_t.id('u_disp2'));
insert into public.profiles (id, organization_id, full_name, email, role) values
  (td0149_t.id('u_disp1'), td0149_t.id('o1'), 'Dana Dispatcher', 'disp1@example.invalid', 'dispatcher'),
  (td0149_t.id('u_acct1'), td0149_t.id('o1'), 'Alex Accountant', 'acct1@example.invalid', 'accountant'),
  (td0149_t.id('u_disp2'), td0149_t.id('o2'), 'Olga Otherorg', 'disp2@example.invalid', 'dispatcher');

insert into public.carriers (id, organization_id, legal_name) values
  (td0149_t.id('ca'), td0149_t.id('o1'), 'Alpha Freight'),
  (td0149_t.id('cb'), td0149_t.id('o1'), 'Bravo Freight'),
  (td0149_t.id('cx'), td0149_t.id('o2'), 'Xray Freight');
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  (td0149_t.id('da1'), td0149_t.id('o1'), td0149_t.id('ca'), 'Ann', 'A1'),
  (td0149_t.id('da2'), td0149_t.id('o1'), td0149_t.id('ca'), 'Al', 'A2'),
  (td0149_t.id('da3'), td0149_t.id('o1'), td0149_t.id('ca'), 'Amy', 'A3'),
  (td0149_t.id('db1'), td0149_t.id('o1'), td0149_t.id('cb'), 'Bob', 'B1'),
  (td0149_t.id('dx1'), td0149_t.id('o2'), td0149_t.id('cx'), 'Xena', 'X1');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  (td0149_t.id('ta1'), td0149_t.id('o1'), td0149_t.id('ca'), 'TA-1'),
  (td0149_t.id('ta2'), td0149_t.id('o1'), td0149_t.id('ca'), 'TA-2'),
  (td0149_t.id('ta3'), td0149_t.id('o1'), td0149_t.id('ca'), 'TA-3'),
  (td0149_t.id('tb1'), td0149_t.id('o1'), td0149_t.id('cb'), 'TB-1'),
  (td0149_t.id('tx1'), td0149_t.id('o2'), td0149_t.id('cx'), 'TX-1');
insert into public.trailers (id, organization_id, carrier_id, unit_number) values
  (td0149_t.id('ra1'), td0149_t.id('o1'), td0149_t.id('ca'), 'RA-1'),
  (td0149_t.id('ra2'), td0149_t.id('o1'), td0149_t.id('ca'), 'RA-2'),
  (td0149_t.id('rb1'), td0149_t.id('o1'), td0149_t.id('cb'), 'RB-1'),
  (td0149_t.id('r_unres'), td0149_t.id('o1'), null, 'R-UNRES');

-- 18 dispatchable O1 loads (l1..l18), one delivered O1 load, one draft O1 load, one O2 load.
insert into public.loads (id, organization_id, load_number, status)
select td0149_t.id('l' || g), td0149_t.id('o1'), 'LD-' || (100000 + g), 'booked' from generate_series(1, 18) g;
insert into public.loads (id, organization_id, load_number, status) values
  (td0149_t.id('l_delivered'), td0149_t.id('o1'), 'LD-199001', 'delivered'),
  (td0149_t.id('l_draft'), td0149_t.id('o1'), 'LD-199002', 'draft'),
  (td0149_t.id('l_o2'), td0149_t.id('o2'), 'LD-299001', 'booked');
grant select on all tables in schema td0149_t to authenticated;
