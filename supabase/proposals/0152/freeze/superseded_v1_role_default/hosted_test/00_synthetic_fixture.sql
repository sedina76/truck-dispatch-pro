-- =============================================================================
-- hosted_test/00_synthetic_fixture.sql -- SYNTHETIC test objects for the hosted NON-PRODUCTION freeze test (PROPOSAL 0152). NOT FOR PRODUCTION.
-- Run ONLY in the temporary test Supabase project (never in production). Everything is created by this file and removed by 99_synthetic_cleanup.sql.
-- Purpose: public.freeze_probe_items is the dedicated SQL write-probe table for 04_verify_freeze.sql, and a writable SECURITY DEFINER RPC that the REST API can reach, and (if pg_cron is enabled) one cron job that keeps writing, so the
-- freeze can be proven end-to-end without touching any real table.
-- =============================================================================
begin;
create table if not exists public.freeze_probe_items (id bigserial primary key, note text not null default 'probe', created_at timestamptz not null default now());
grant select, insert, update, delete on public.freeze_probe_items to anon, authenticated, service_role;
grant usage on sequence public.freeze_probe_items_id_seq to anon, authenticated, service_role;
create or replace function public.freeze_probe_write() returns bigint language sql security definer set search_path = public as
  $$ insert into public.freeze_probe_items (note) values ('rpc') returning id $$;
grant execute on function public.freeze_probe_write() to anon, authenticated, service_role;
insert into public.freeze_probe_items (note) values ('seed');
commit;

-- Result (read-only): confirms exactly what this file created.
select current_database() as db, current_user as run_as,
       to_regclass('public.freeze_probe_items') is not null as table_created,
       to_regprocedure('public.freeze_probe_write()') is not null as rpc_created,
       (select count(*) from public.freeze_probe_items) as rows_now,
       (select coalesce(bool_or(rowsecurity), false) from pg_tables where schemaname = 'public' and tablename = 'freeze_probe_items') as rls_enabled;

-- Optional (requires the pg_cron extension enabled in this test project: Dashboard > Database > Extensions). Skip if unavailable.
-- select cron.schedule('freeze_probe_cron', '* * * * *', $$insert into public.freeze_probe_items (note) values ('cron')$$);
-- select jobid, jobname, active from cron.job where jobname = 'freeze_probe_cron';   -- note the jobid: it is the ONLY id that goes in v_cron_pause_ids
