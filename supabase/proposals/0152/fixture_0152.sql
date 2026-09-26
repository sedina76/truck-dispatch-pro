-- fixture_0152.sql -- PROPOSAL 0152 disposable fixture (NOT A MIGRATION). Users/loads/resources from the 0151 fixture + the 0152 target layer.
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
\set ON_ERROR_STOP on
-- ---- extra fixture (users, loads, resources, helpers) ------------------------------------------------
insert into auth.users (id) select td0149_t.id(n) from unnest(array['u_owner1','u_admin1','u_driver1','u_viewer1','u_owner2','u_disp1b']) n;
insert into public.profiles (id, organization_id, full_name, email, role) values
  (td0149_t.id('u_owner1'),  td0149_t.id('o1'), 'Olive Owner',   'owner1@example.invalid',  'owner'),
  (td0149_t.id('u_admin1'),  td0149_t.id('o1'), 'Adam Admin',    'admin1@example.invalid',  'admin'),
  (td0149_t.id('u_disp1b'),  td0149_t.id('o1'), 'Dora Dispatch', 'disp1b@example.invalid',  'dispatcher'),
  (td0149_t.id('u_driver1'), td0149_t.id('o1'), 'Dave Driver',   'driver1@example.invalid', 'driver'),
  (td0149_t.id('u_viewer1'), td0149_t.id('o1'), 'Vic Viewer',    'viewer1@example.invalid', 'viewer'),
  (td0149_t.id('u_owner2'),  td0149_t.id('o2'), 'Orin Otherorg', 'owner2@example.invalid',  'owner');
insert into public.loads (id, organization_id, load_number, status)
  select td0149_t.id('f' || g), td0149_t.id('o1'), 'LD-F' || (1000 + g), 'booked' from generate_series(1, 40) g;
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  select td0149_t.id('fd' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'F', 'D' || g from generate_series(1, 40) g;
insert into public.trucks (id, organization_id, carrier_id, unit_number)
  select td0149_t.id('ft' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'FT-' || g from generate_series(1, 40) g;
insert into public.trailers (id, organization_id, carrier_id, unit_number)
  select td0149_t.id('fr' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'FR-' || g from generate_series(1, 40) g;

insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values (td0149_t.id('fdx2'), td0149_t.id('o2'), td0149_t.id('cx'), 'X', 'X2');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values (td0149_t.id('ftx2'), td0149_t.id('o2'), td0149_t.id('cx'), 'FTX-2');

create table td0149_t.f1 (seq bigserial primary key, tag text, state text, msg text, result jsonb);
grant select, insert on td0149_t.f1 to authenticated;
grant usage on sequence td0149_t.f1_seq_seq to authenticated;

-- tr(): the exact call the app makes; captures SQLSTATE / message / jsonb result under <tag>.
create function td0149_t.tr(p_tag text, p_user text, p_dispatch uuid, p_status public.dispatch_status, p_reason text default null, p_key text default null) returns void
language plpgsql as $$
declare v_state text; v_msg text; v_res jsonb;
begin
  perform set_config('test.current_uid', case when p_user is null then '' else td0149_t.id(p_user)::text end, false);
  begin
    v_res := public.transition_dispatch_status(p_dispatch, p_status, p_reason, p_key);
  exception when others then
    get stacked diagnostics v_state := returned_sqlstate, v_msg := message_text;
  end;
  insert into td0149_t.f1 (tag, state, msg, result) values (p_tag, v_state, v_msg, v_res);
end $$;
grant execute on function td0149_t.tr(text, text, uuid, public.dispatch_status, text, text) to authenticated;

-- mk(): a dispatch through the REAL create_dispatch (org 1, carrier ca, load fN, driver fdN, truck ftN, trailer frN).
create function td0149_t.mk(p_tag text, p_i int) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
  v_id := public.create_dispatch(td0149_t.id('f' || p_i), td0149_t.id('ca'), td0149_t.id('ft' || p_i), td0149_t.id('fd' || p_i), td0149_t.id('fr' || p_i), null, null);
  insert into td0149_t.f1 (tag, result) values (p_tag, jsonb_build_object('id', v_id));
  return v_id;
end $$;
grant execute on function td0149_t.mk(text, int) to authenticated;
create function td0149_t.did(p_tag text) returns uuid language sql stable as $$ select (result ->> 'id')::uuid from td0149_t.f1 where tag = p_tag $$;
create function td0149_t.st(p_tag text) returns text language sql stable as $$ select state from td0149_t.f1 where tag = p_tag order by seq desc limit 1 $$;
create function td0149_t.msg(p_tag text) returns text language sql stable as $$ select msg from td0149_t.f1 where tag = p_tag order by seq desc limit 1 $$;
create function td0149_t.res(p_tag text) returns jsonb language sql stable as $$ select result from td0149_t.f1 where tag = p_tag order by seq desc limit 1 $$;
grant execute on function td0149_t.did(text), td0149_t.st(text), td0149_t.msg(text), td0149_t.res(text) to authenticated;
create function td0149_t.n_log(p_dispatch uuid, p_action text) returns bigint language sql stable security definer as $$ select count(*) from public.activity_logs where entity_id = p_dispatch and action = p_action $$;
create function td0149_t.n_led(p_dispatch uuid, p_key text) returns bigint language sql stable security definer as $$ select count(*) from public.dispatch_status_transitions where dispatch_id = p_dispatch and idempotency_key = p_key $$;
grant execute on function td0149_t.n_log(uuid, text), td0149_t.n_led(uuid, text) to authenticated;

-- =============================================================================
-- 0152 layer: targets for every repaired RPC, a uniform call() wrapper and ledger/audit counters.
-- =============================================================================
create table td0149_t.tgt (tag text primary key, id uuid not null, t0 timestamptz, a1 uuid, a2 uuid, a3 uuid, a4 uuid);
grant select on td0149_t.tgt to authenticated;
create table td0149_t.rec (seq bigserial primary key, rpc text, tag text, outcome text, msg text, n_led bigint, n_act bigint);
grant select, insert on td0149_t.rec to authenticated;
grant usage on sequence td0149_t.rec_seq_seq to authenticated;

-- resources for reassign variants (org 1: a/b sets per target; org 2: one set per foreign target)
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  select td0149_t.id('fda' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'A', 'DA' || g from generate_series(1, 12) g
  union all select td0149_t.id('fdb' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'B', 'DB' || g from generate_series(1, 12) g
  union all select td0149_t.id('fdo' || g), td0149_t.id('o2'), td0149_t.id('cx'), 'O', 'DO' || g from generate_series(1, 6) g;
insert into public.trucks (id, organization_id, carrier_id, unit_number)
  select td0149_t.id('fta' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'RTA-' || g from generate_series(1, 12) g
  union all select td0149_t.id('ftb' || g), td0149_t.id('o1'), td0149_t.id('ca'), 'RTB-' || g from generate_series(1, 12) g
  union all select td0149_t.id('fto' || g), td0149_t.id('o2'), td0149_t.id('cx'), 'RTO-' || g from generate_series(1, 6) g;
insert into public.loads (id, organization_id, load_number, status)
  select td0149_t.id('flo' || g), td0149_t.id('o2'), 'LD-FO' || (2000 + g), 'booked' from generate_series(1, 3) g;

-- reassign targets: dispatches created through the REAL create_dispatch (org 1: loads f1..f12; org 2: flo1..flo3)
do $t$
declare g int; v uuid;
begin
  for g in 1..12 loop
    perform set_config('test.current_uid', td0149_t.id('u_disp1')::text, false);
    v := public.create_dispatch(td0149_t.id('f' || g), td0149_t.id('ca'), td0149_t.id('ft' || g), td0149_t.id('fd' || g), td0149_t.id('fr' || g), null, null);
    insert into td0149_t.tgt (tag, id, t0, a1, a2, a3, a4) values ('rea:' || g, v, (select updated_at from public.dispatches where id = v), td0149_t.id('fda' || g), td0149_t.id('fta' || g), td0149_t.id('fdb' || g), td0149_t.id('ftb' || g));
  end loop;
  for g in 1..3 loop
    perform set_config('test.current_uid', td0149_t.id('u_disp2')::text, false);
    v := public.create_dispatch(td0149_t.id('flo' || g), td0149_t.id('cx'), td0149_t.id('fto' || g), td0149_t.id('fdo' || g), null, null, null);
    insert into td0149_t.tgt (tag, id, t0, a1, a2, a3, a4) values ('rea:x' || g, v, (select updated_at from public.dispatches where id = v), td0149_t.id('fdo' || (g + 3)), td0149_t.id('fto' || (g + 3)), td0149_t.id('fdo' || (g + 3)), td0149_t.id('fto' || (g + 3)));
  end loop;
end $t$;

-- policy targets: carriers (default factoring_mode 'unconfigured')
insert into public.carriers (id, organization_id, legal_name)
  select td0149_t.id('pc' || g), td0149_t.id('o1'), 'Policy Carrier ' || g from generate_series(1, 12) g
  union all select td0149_t.id('pcx' || g), td0149_t.id('o2'), 'Policy Carrier X' || g from generate_series(1, 3) g;
insert into td0149_t.tgt (tag, id, t0)
  select 'pol:' || g, td0149_t.id('pc' || g), (select updated_at from public.carriers where id = td0149_t.id('pc' || g)) from generate_series(1, 12) g
  union all select 'pol:x' || g, td0149_t.id('pcx' || g), (select updated_at from public.carriers where id = td0149_t.id('pcx' || g)) from generate_series(1, 3) g;

-- factoring: one company per org; relationships (configure / deactivate targets); draft integrations (rotate / verify targets)
insert into public.factoring_companies (id, organization_id, name, is_active) values
  (td0149_t.id('fco1'), td0149_t.id('o1'), 'Factor One', true), (td0149_t.id('fco2'), td0149_t.id('o2'), 'Factor Two', true);
do $t$
declare g int; kind text; v uuid; t0 timestamptz; org text; fco text; car text;
begin
  perform set_config('test.current_uid', td0149_t.id('u_owner1')::text, false);   -- factoring guards require an owner/admin
  for kind in select unnest(array['cfg', 'dea']) loop
    for g in 1..15 loop
      org := case when g <= 12 then 'o1' else 'o2' end;
      fco := case when g <= 12 then 'fco1' else 'fco2' end;
      car := case when g <= 12 then 'ca' else 'cx' end;
      v := td0149_t.id('rel_' || kind || g);
      insert into public.factoring_relationships
        (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type,
         remittance_instructions, noa_template_text, noa_reference, noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active)
      values (v, td0149_t.id(org), td0149_t.id(fco), td0149_t.id(car), 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire', 'NOA', 'v1', current_date - 10, true,
              td0149_t.id('u_owner1'), now(), 'portal_manual', false, true);
      select updated_at into t0 from public.factoring_relationships where id = v;
      insert into td0149_t.tgt (tag, id, t0) values (kind || ':' || case when g <= 12 then g::text else 'x' || (g - 12) end, v, t0);
    end loop;
  end loop;
  for kind in select unnest(array['rot', 'ver']) loop
    for g in 1..15 loop
      org := case when g <= 12 then 'o1' else 'o2' end;
      v := td0149_t.id('ig_' || kind || g);
      insert into public.carrier_factoring_integrations (id, organization_id, carrier_id, factoring_relationship_id, factoring_company_id, submission_method, submission_destination, created_by)
      values (v, td0149_t.id(org), td0149_t.id(case when g <= 12 then 'ca' else 'cx' end), td0149_t.id('rel_cfg' || g), td0149_t.id(case when g <= 12 then 'fco1' else 'fco2' end), 'portal_manual', 'instructions', td0149_t.id('u_owner1'));
      select updated_at into t0 from public.carrier_factoring_integrations where id = v;
      insert into td0149_t.tgt (tag, id, t0) values (kind || ':' || case when g <= 12 then g::text else 'x' || (g - 12) end, v, t0);
    end loop;
  end loop;
end $t$;

-- legacy invoice reviews and carrier-invoice drafts
insert into public.brokers (id, organization_id, company_name) values (td0149_t.id('brk1'), td0149_t.id('o1'), 'Broker One'), (td0149_t.id('brk2'), td0149_t.id('o2'), 'Broker Two');
do $t$
declare g int; v uuid; inv uuid; t0 timestamptz; org text; tg text;
begin
  perform set_config('test.current_uid', td0149_t.id('u_owner1')::text, false);
  for g in 1..15 loop
    org := case when g <= 12 then 'o1' else 'o2' end;
    tg := case when g <= 12 then g::text else 'x' || (g - 12) end;
    inv := td0149_t.id('lginv' || g);
    insert into public.invoices (id, organization_id, broker_id, status, total_amount, invoice_number) values (inv, td0149_t.id(org), td0149_t.id(case when g <= 12 then 'brk1' else 'brk2' end), 'sent', 100, 'INV-LEG-' || g);
    v := td0149_t.id('rev' || g);
    insert into public.legacy_invoice_carrier_migration_review (id, organization_id, legacy_invoice_id, classification) values (v, td0149_t.id(org), inv, 'missing_carrier_evidence');
    select updated_at into t0 from public.legacy_invoice_carrier_migration_review where id = v;
    insert into td0149_t.tgt (tag, id, t0) values ('rev:' || tg, v, t0);

    v := td0149_t.id('drf' || g);
    insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
    values (v, td0149_t.id(org), 'carrier_freight_invoice', td0149_t.id(case when g <= 12 then 'ca' else 'cx' end), 'broker', td0149_t.id(case when g <= 12 then 'brk1' else 'brk2' end),
            td0149_t.id(case when g <= 12 then 'u_owner1' else 'u_owner2' end));
    select updated_at into t0 from public.carrier_invoices where id = v;
    insert into td0149_t.tgt (tag, id, t0) values ('drf:' || tg, v, t0);
  end loop;
end $t$;

create function td0149_t.led(p_rpc text) returns bigint language plpgsql stable security definer as $$
declare n bigint;
begin
  execute format('select count(*) from public.%I', case p_rpc when 'rea' then 'dispatch_resource_reassignments' when 'pol' then 'factoring_policy_idempotency'
    when 'cfg' then 'factoring_integration_lifecycle_idempotency' when 'rot' then 'factoring_integration_lifecycle_idempotency' when 'ver' then 'factoring_integration_lifecycle_idempotency'
    when 'dea' then 'factoring_integration_lifecycle_idempotency' when 'rev' then 'legacy_invoice_review_idempotency' when 'drf' then 'carrier_invoice_lifecycle_idempotency' end) into n;
  return n;
end $$;
create function td0149_t.act() returns bigint language sql stable security definer as $$ select count(*) from public.activity_logs $$;
grant execute on function td0149_t.led(text), td0149_t.act() to authenticated;

-- call(): the RPC as the app calls it, normalised to an outcome: S = success true, F:<code>, X:<sqlstate>. p_rpc is the target kind.
create function td0149_t.call(p_rpc text, p_user text, p_target text, p_key text, p_variant text default 'a', out outcome text, out msg text)
language plpgsql as $$
declare t td0149_t.tgt; r jsonb;
begin
  perform set_config('test.current_uid', case when p_user is null then '' else td0149_t.id(p_user)::text end, false);
  select * into t from td0149_t.tgt where tag = p_rpc || ':' || p_target;
  begin
    if p_rpc = 'rea' then
      r := public.reassign_dispatch_resources(t.id, case when p_variant = 'a' then t.a1 else t.a3 end, case when p_variant = 'a' then t.a2 else t.a4 end, null, 'a valid reason', p_key, t.t0);
    elsif p_rpc = 'pol' then
      r := public.set_carrier_factoring_policy(t.id, case when p_variant = 'a' then 'direct' else 'factored' end::public.carrier_factoring_mode, 'a valid reason', t.t0, p_key);
    elsif p_rpc = 'cfg' then
      r := public.configure_carrier_factoring_integration(t.id, null, 'ACCT-' || p_variant, null, 'dest-' || p_variant, 'a valid reason', t.t0, p_key);
    elsif p_rpc = 'rot' then
      r := public.rotate_carrier_factoring_integration(t.id, null, 'ACCT-' || p_variant, null, 'dest-' || p_variant, 'a valid reason', t.t0, p_key);
    elsif p_rpc = 'ver' then
      r := public.verify_carrier_factoring_integration(t.id, 'a valid reason ' || p_variant, t.t0, p_key);
    elsif p_rpc = 'dea' then
      r := public.deactivate_factoring_relationship(t.id, 'a valid reason', t.t0, p_key, p_variant = 'b');
    elsif p_rpc = 'rev' then
      r := public.review_legacy_invoice_carrier_migration(t.id, 'resolution ' || p_variant, 'notes', t.t0, p_key);
    elsif p_rpc = 'drf' then
      r := public.update_carrier_invoice_draft(t.id, jsonb_build_object('notes', 'note ' || p_variant), t.t0, 'a valid reason', p_key);
    else raise exception 'unknown rpc %', p_rpc; end if;
    outcome := case when (r ->> 'success') = 'true' then 'S' else 'F:' || coalesce(r ->> 'code', r ->> 'reason', 'unspecified') end;
    msg := coalesce(r ->> 'message', '');
    if (r ->> 'idempotent_replay') = 'true' then outcome := outcome || '+R'; end if;
  exception when others then
    get stacked diagnostics outcome := returned_sqlstate, msg := message_text;
    outcome := 'X:' || outcome;
  end;
  msg := regexp_replace(msg, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<uuid>', 'g');
end $$;
grant execute on function td0149_t.call(text, text, text, text, text) to authenticated;

create function td0149_t.step(p_rpc text, p_tag text, p_user text, p_target text, p_key text, p_variant text default 'a') returns void language plpgsql as $$
declare o record; l0 bigint; a0 bigint;
begin
  -- counters are read BEFORE and stored AFTER as deltas via the two rows: n_led/n_act hold the totals after the call.
  select * into o from td0149_t.call(p_rpc, p_user, p_target, p_key, p_variant);
  insert into td0149_t.rec (rpc, tag, outcome, msg, n_led, n_act) values (p_rpc, p_tag, o.outcome, o.msg, td0149_t.led(p_rpc), td0149_t.act());
end $$;
grant execute on function td0149_t.step(text, text, text, text, text, text) to authenticated;

create function td0149_t.boom() returns trigger language plpgsql as $$
begin
  if current_setting('td0149.boom', true) = tg_table_name then raise exception 'FORCED downstream failure in %', tg_table_name using errcode = 'P0F11'; end if;
  return new;
end $$;
create trigger td0149_boom before insert on public.activity_logs for each row execute function td0149_t.boom();
