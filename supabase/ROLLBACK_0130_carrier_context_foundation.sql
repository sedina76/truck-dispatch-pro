-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0130_carrier_context_foundation.sql       ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse 0130.            ##
-- ##  APPLY AS ONE TRANSACTION. Run ONLY if 0131/0132/0133 are NOT applied  ##
-- ##  (they depend on 0130 objects). Roll those back first if they are.     ##
-- ##                                                                        ##
-- ##  This DROPs: record_unresolved_carrier_record(),                      ##
-- ##  carrier_ids_authorized_for_current_user(),                           ##
-- ##  carrier_ids_selectable_for_new_records(),                            ##
-- ##  guard_carrier_remittance_profile_org(),                              ##
-- ##  financial_idempotency_keys, unresolved_carrier_records,               ##
-- ##  carrier_remittance_profiles (and its seeded rows), the 3 platform_    ##
-- ##  settings columns, carriers.invoice_code + dispatch_service_terms_days ##
-- ##  (+ their index/CHECKs), and the unresolved_record_status enum.        ##
-- ##                                                                        ##
-- ##  DATA LOSS: any rows written to unresolved_carrier_records /           ##
-- ##  financial_idempotency_keys / edits to carrier_remittance_profiles     ##
-- ##  after 0130 are destroyed. Confirm those tables hold nothing you need. ##
-- ############################################################################

begin;

-- Guard: refuse if a later slice that depends on 0130 is still live.
do $rb$
begin
  if to_regclass('public.carrier_brokers') is not null then
    raise exception 'ROLLBACK 0130: public.carrier_brokers (0131) still exists -- roll back 0131 first. STOP.';
  end if;
  if to_regclass('public.unresolved_carrier_records') is not null
     and exists (select 1 from public.unresolved_carrier_records) then
    raise warning 'ROLLBACK 0130: unresolved_carrier_records has % row(s) that will be DESTROYED.',
      (select count(*) from public.unresolved_carrier_records);
  end if;
  if to_regclass('public.financial_idempotency_keys') is not null
     and exists (select 1 from public.financial_idempotency_keys) then
    raise warning 'ROLLBACK 0130: financial_idempotency_keys has % row(s) that will be DESTROYED.',
      (select count(*) from public.financial_idempotency_keys);
  end if;
end
$rb$;

drop function if exists public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb);
drop function if exists public.carrier_ids_authorized_for_current_user();
drop function if exists public.carrier_ids_selectable_for_new_records();

drop trigger if exists carrier_remittance_profiles_guard_org on public.carrier_remittance_profiles;
drop function if exists public.guard_carrier_remittance_profile_org();

drop table if exists public.financial_idempotency_keys;
drop table if exists public.unresolved_carrier_records;
drop table if exists public.carrier_remittance_profiles;

alter table public.platform_settings drop column if exists carrier_dashboards_enabled;
alter table public.platform_settings drop column if exists multi_carrier_ui_enabled;
alter table public.platform_settings drop column if exists dispatch_service_terms_days;

drop index if exists public.carriers_org_invoice_code_uq;
alter table public.carriers drop column if exists dispatch_service_terms_days;
alter table public.carriers drop column if exists invoice_code;

drop type if exists public.unresolved_record_status;

-- Postcondition: everything 0130 created is gone.
do $rb$
begin
  if to_regclass('public.carrier_remittance_profiles') is not null
     or to_regclass('public.unresolved_carrier_records') is not null
     or to_regclass('public.financial_idempotency_keys') is not null
     or to_regprocedure('public.carrier_ids_authorized_for_current_user()') is not null
     or to_regprocedure('public.carrier_ids_selectable_for_new_records()') is not null
     or to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)') is not null
     or exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='unresolved_record_status')
     or exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='invoice_code')
     or exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='dispatch_service_terms_days')
  then
    raise exception 'ROLLBACK 0130 incomplete -- a 0130 object still exists.';
  end if;
  raise notice 'ROLLBACK 0130 complete: all 0130 objects removed.';
end
$rb$;

commit;
