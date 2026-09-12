-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0131_carrier_party_relationships.sql     ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse 0131.           ##
-- ##  APPLY AS ONE TRANSACTION. Run ONLY if 0132/0133 are NOT applied.      ##
-- ##                                                                        ##
-- ##  DROPs: activate_carrier_party(), guard_carrier_party_org() (+ its two ##
-- ##  triggers), carrier_customers, carrier_brokers, carrier_party_status.  ##
-- ##                                                                        ##
-- ##  DATA LOSS: every carrier<->broker / carrier<->customer relationship   ##
-- ##  row is destroyed. Confirm those tables hold nothing you need.         ##
-- ############################################################################

begin;

do $rb$
begin
  if to_regclass('public.carrier_brokers') is not null
     and exists (select 1 from public.carrier_brokers) then
    raise warning 'ROLLBACK 0131: carrier_brokers has % row(s) that will be DESTROYED.',
      (select count(*) from public.carrier_brokers);
  end if;
  if to_regclass('public.carrier_customers') is not null
     and exists (select 1 from public.carrier_customers) then
    raise warning 'ROLLBACK 0131: carrier_customers has % row(s) that will be DESTROYED.',
      (select count(*) from public.carrier_customers);
  end if;
end
$rb$;

drop function if exists public.activate_carrier_party(uuid,uuid,uuid,jsonb);

drop trigger if exists carrier_brokers_guard_org   on public.carrier_brokers;
drop trigger if exists carrier_customers_guard_org on public.carrier_customers;
drop function if exists public.guard_carrier_party_org();

drop table if exists public.carrier_customers;
drop table if exists public.carrier_brokers;

drop type if exists public.carrier_party_status;

do $rb$
begin
  if to_regclass('public.carrier_brokers') is not null
     or to_regclass('public.carrier_customers') is not null
     or to_regprocedure('public.activate_carrier_party(uuid,uuid,uuid,jsonb)') is not null
     or to_regprocedure('public.guard_carrier_party_org()') is not null
     or exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='carrier_party_status')
  then
    raise exception 'ROLLBACK 0131 incomplete -- a 0131 object still exists.';
  end if;
  raise notice 'ROLLBACK 0131 complete.';
end
$rb$;

commit;
