-- =============================================================================
-- PROD_PROBE_FIXTURE_PROPOSAL.sql -- PROPOSAL ONLY. NOT APPLIED. Needs SEPARATE written Owner approval. NOT in supabase/migrations/.
-- Dedicated, data-free probe objects for api_freeze_probe_production.py, so the external freeze proof never touches a business table:
--   public.ops_freeze_probe_items (writable by anon/authenticated/service_role so the BASELINE can prove the probe works), a writable SECURITY DEFINER RPC, a read-only diag RPC.
-- SECURITY NOTE (why this is time-boxed): while it exists, anyone holding the public anon key can insert tiny rows into this one table. It holds no business data, note is capped at
-- 40 characters, and it must be created immediately before the window and DROPPED by PROD_PROBE_FIXTURE_CLEANUP.sql right after restoration is proven (runbook step 17-18).
-- Apply as the SQL Editor operator, once, in ONE transaction. Creating a table is additive and reversible; it changes no existing object.
-- =============================================================================
begin;
do $p$ begin
  if to_regclass('public.ops_freeze_probe_items') is not null or to_regprocedure('public.ops_freeze_probe_write()') is not null or to_regprocedure('public.ops_freeze_probe_diag()') is not null then
    raise exception 'probe fixture: an ops_freeze_probe object already exists -- run PROD_PROBE_FIXTURE_CLEANUP.sql first. STOP.';
  end if;
end $p$;
create table public.ops_freeze_probe_items (id bigserial primary key, note text not null default 'probe' check (char_length(note) <= 40), created_at timestamptz not null default now());
alter table public.ops_freeze_probe_items enable row level security;
create policy ops_freeze_probe_items_all on public.ops_freeze_probe_items for all to anon, authenticated using (true) with check (char_length(note) <= 40);
grant select, insert, update, delete on public.ops_freeze_probe_items to anon, authenticated, service_role;
grant usage on sequence public.ops_freeze_probe_items_id_seq to anon, authenticated, service_role;
create function public.ops_freeze_probe_write() returns bigint language sql security definer set search_path = pg_catalog, public as
  $$ insert into public.ops_freeze_probe_items (note) values ('rpc') returning id $$;
revoke all on function public.ops_freeze_probe_write() from public;
grant execute on function public.ops_freeze_probe_write() to anon, authenticated, service_role;
create function public.ops_freeze_probe_diag() returns jsonb language sql volatile security invoker set search_path = pg_catalog, public as
  $$ select jsonb_build_object('pid', pg_backend_pid(), 'backend_start', (select a.backend_start from pg_stat_activity a where a.pid = pg_backend_pid())) $$;
revoke all on function public.ops_freeze_probe_diag() from public;
grant execute on function public.ops_freeze_probe_diag() to anon, authenticated, service_role;
insert into public.ops_freeze_probe_items (note) values ('seed');
commit;
select to_regclass('public.ops_freeze_probe_items') is not null as table_created, to_regprocedure('public.ops_freeze_probe_write()') is not null as write_rpc_created,
       to_regprocedure('public.ops_freeze_probe_diag()') is not null as diag_rpc_created, (select count(*) from public.ops_freeze_probe_items) as rows_now;
