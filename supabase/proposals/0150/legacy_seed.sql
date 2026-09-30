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

-- =============================================================================
-- legacy_seed.sql -- PROPOSAL 0150 disposable fixture: LEGACY (pre-0133) loads/dispatches.
-- NOT APPROVED FOR PRODUCTION. DISPOSABLE SCRATCH DATABASE ONLY. NOT A MIGRATION.
-- Applied by tests.py AFTER 0130-0132 and the 0149 fixture and BEFORE 0133, so that the REAL 0133 backfill
-- classifies them. Triggers are disabled for this superuser seed only (legacy rows predate the 0132 guard).
-- Every zero-dispatch load in the 0149 fixture (l1..l18, l_delivered, l_draft, l_o2) is also a 0133 C4_zero_dispatch load.
-- =============================================================================
\set ON_ERROR_STOP on
set session_replication_role = replica;

insert into public.drivers (id, organization_id, carrier_id, first_name, last_name) values
  (td0149_t.id('dq1'), td0149_t.id('o1'), td0149_t.id('ca'), 'Q', 'Q1'), (td0149_t.id('dq2'), td0149_t.id('o1'), td0149_t.id('cb'), 'Q', 'Q2'),
  (td0149_t.id('dq3'), td0149_t.id('o1'), td0149_t.id('ca'), 'Q', 'Q3'), (td0149_t.id('dq4'), td0149_t.id('o1'), td0149_t.id('cb'), 'Q', 'Q4');
insert into public.trucks (id, organization_id, carrier_id, unit_number) values
  (td0149_t.id('tq1'), td0149_t.id('o1'), td0149_t.id('ca'), 'TQ-1'), (td0149_t.id('tq2'), td0149_t.id('o1'), td0149_t.id('cb'), 'TQ-2'),
  (td0149_t.id('tq3'), td0149_t.id('o1'), td0149_t.id('ca'), 'TQ-3'), (td0149_t.id('tq4'), td0149_t.id('o1'), td0149_t.id('cb'), 'TQ-4');

insert into public.loads (id, organization_id, load_number, status) values
  (td0149_t.id('k_c1'),  td0149_t.id('o1'), 'LD-K001', 'dispatched'),   -- C1: financial controller
  (td0149_t.id('k_c2'),  td0149_t.id('o1'), 'LD-K002', 'dispatched'),   -- C2: sole non-cancelled dispatch
  (td0149_t.id('k_c3'),  td0149_t.id('o1'), 'LD-K003', 'booked'),       -- C3: sole cancelled dispatch
  (td0149_t.id('k_c4'),  td0149_t.id('o1'), 'LD-K004', 'dispatched'),   -- C4_conflicting_carriers (HAS dispatches)
  (td0149_t.id('k_c5'),  td0149_t.id('o1'), 'LD-K005', 'booked'),       -- two CANCELLED dispatches of different carriers -> C4_conflicting_carriers (HAS dispatches)
  (td0149_t.id('k_o2'),  td0149_t.id('o2'), 'LD-K901', 'dispatched');   -- other org, C2

insert into public.loads (id, organization_id, load_number, status, carrier_id, carrier_resolution) values
  (td0149_t.id('k_pre'), td0149_t.id('o1'), 'LD-K006', 'booked', td0149_t.id('ca'), 'resolved');   -- PRE_EXISTING

insert into public.dispatches (id, organization_id, load_id, carrier_id, driver_id, truck_id, status, cancelled_at) values
  (td0149_t.id('kd_c1'),  td0149_t.id('o1'), td0149_t.id('k_c1'), td0149_t.id('ca'), td0149_t.id('da1'), td0149_t.id('ta1'), 'assigned', null),
  (td0149_t.id('kd_c2'),  td0149_t.id('o1'), td0149_t.id('k_c2'), td0149_t.id('cb'), td0149_t.id('db1'), td0149_t.id('tb1'), 'en_route_to_pickup', null),
  (td0149_t.id('kd_c3'),  td0149_t.id('o1'), td0149_t.id('k_c3'), td0149_t.id('ca'), td0149_t.id('da2'), td0149_t.id('ta2'), 'cancelled', now()),
  (td0149_t.id('kd_c4a'), td0149_t.id('o1'), td0149_t.id('k_c4'), td0149_t.id('ca'), td0149_t.id('dq1'), td0149_t.id('tq1'), 'assigned', null),
  (td0149_t.id('kd_c4b'), td0149_t.id('o1'), td0149_t.id('k_c4'), td0149_t.id('cb'), td0149_t.id('dq2'), td0149_t.id('tq2'), 'assigned', null),
  (td0149_t.id('kd_c5a'), td0149_t.id('o1'), td0149_t.id('k_c5'), td0149_t.id('ca'), td0149_t.id('dq3'), td0149_t.id('tq3'), 'cancelled', now()),
  (td0149_t.id('kd_c5b'), td0149_t.id('o1'), td0149_t.id('k_c5'), td0149_t.id('cb'), td0149_t.id('dq4'), td0149_t.id('tq4'), 'cancelled', now()),
  (td0149_t.id('kd_o2'),  td0149_t.id('o2'), td0149_t.id('k_o2'), td0149_t.id('cx'), td0149_t.id('dx1'), td0149_t.id('tx1'), 'assigned', null);
update public.loads set financial_dispatch_id = td0149_t.id('kd_c1') where id = td0149_t.id('k_c1');

reset session_replication_role;
