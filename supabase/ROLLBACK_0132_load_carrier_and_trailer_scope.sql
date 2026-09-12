-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0132_load_carrier_and_trailer_scope.sql  ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse 0132.           ##
-- ##  APPLY AS ONE TRANSACTION. Run ONLY BEFORE 0133 has populated          ##
-- ##  loads.carrier_id -- this script REFUSES if any load.carrier_id is set ##
-- ##  (roll back 0133 first with ROLLBACK_0133_*.sql).                      ##
-- ##                                                                        ##
-- ##  DROPs: dispatches_guard_carrier_scope + guard_dispatch_carrier_scope(),##
-- ##  loads_guard_carrier_change + guard_load_carrier_change(),             ##
-- ##  trailers_derive_ownership_scope (+ fn), trailers.ownership_scope       ##
-- ##  (+ CHECK), loads.carrier_id / carrier_resolution / carrier_locked_at  ##
-- ##  (+ FK/CHECK), trailers_guard_ownership_scope_change (+ fn),          ##
-- ##  approve_trailer_ownership_scope(...), trailer_ownership_scope_audit   ##
-- ##  (AND ITS ROWS -- see DATA LOSS below), trailer_ownership_scope enum.  ##
-- ##  Trailer carrier_id values themselves are NOT touched.                 ##
-- ##                                                                        ##
-- ##  DATA LOSS: any rows written to trailer_ownership_scope_audit by       ##
-- ##  approve_trailer_ownership_scope() after 0132 are destroyed. Confirm   ##
-- ##  that table holds nothing you need before running this.               ##
-- ############################################################################

begin;

do $rb$
begin
  if exists (select 1 from public.loads where carrier_id is not null) then
    raise exception 'ROLLBACK 0132: % load(s) have a non-NULL carrier_id -- 0133 (or the app) has populated it. Roll back 0133 first. STOP.',
      (select count(*) from public.loads where carrier_id is not null);
  end if;
  if to_regclass('public.trailer_ownership_scope_audit') is not null
     and exists (select 1 from public.trailer_ownership_scope_audit) then
    raise warning 'ROLLBACK 0132: trailer_ownership_scope_audit has % row(s) that will be DESTROYED.',
      (select count(*) from public.trailer_ownership_scope_audit);
  end if;
end
$rb$;

drop trigger if exists dispatches_guard_carrier_scope on public.dispatches;
drop function if exists public.guard_dispatch_carrier_scope();

drop trigger if exists loads_guard_carrier_change on public.loads;
drop function if exists public.guard_load_carrier_change();

drop trigger if exists trailers_derive_ownership_scope on public.trailers;
drop function if exists public.trailers_derive_ownership_scope();

-- shared-trailer approval infrastructure (correction #4) -- must drop
-- BEFORE the trailer_ownership_scope type, since these reference it.
drop trigger if exists trailers_guard_ownership_scope_change on public.trailers;
drop function if exists public.guard_trailer_ownership_scope_change();
drop function if exists public.approve_trailer_ownership_scope(uuid, public.trailer_ownership_scope, text, uuid);
drop table if exists public.trailer_ownership_scope_audit;

alter table public.trailers drop constraint if exists trailers_ownership_scope_consistency;
alter table public.trailers drop column if exists ownership_scope;

alter table public.loads drop column if exists carrier_locked_at;
alter table public.loads drop column if exists carrier_resolution;   -- drops CHECK loads_carrier_resolution_values
alter table public.loads drop column if exists carrier_id;           -- drops the FK to carriers

drop type if exists public.trailer_ownership_scope;

do $rb$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_id')
     or exists (select 1 from information_schema.columns where table_schema='public' and table_name='trailers' and column_name='ownership_scope')
     or to_regprocedure('public.guard_load_carrier_change()') is not null
     or to_regprocedure('public.guard_dispatch_carrier_scope()') is not null
     or to_regprocedure('public.guard_trailer_ownership_scope_change()') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='approve_trailer_ownership_scope')
     or to_regclass('public.trailer_ownership_scope_audit') is not null
     or exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='trailer_ownership_scope')
  then
    raise exception 'ROLLBACK 0132 incomplete -- a 0132 object still exists.';
  end if;
  raise notice 'ROLLBACK 0132 complete. Trailer carrier_id values untouched.';
end
$rb$;

commit;
