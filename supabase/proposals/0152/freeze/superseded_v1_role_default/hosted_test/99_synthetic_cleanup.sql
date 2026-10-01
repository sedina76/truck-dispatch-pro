-- =============================================================================
-- hosted_test/99_synthetic_cleanup.sql -- removes ONLY what 00_synthetic_fixture.sql created (PROPOSAL 0152). Run in the test project after the freeze is DISABLED.
-- (Deleting the whole temporary project is the simplest cleanup; this file exists for a project you intend to keep.)
-- =============================================================================
begin;
do $c$ begin
  if to_regclass('cron.job') is not null then
    execute 'select cron.unschedule(jobid) from cron.job where jobname = ''freeze_probe_cron''';
  end if;
end $c$;
drop function if exists public.freeze_probe_write();
drop table if exists public.freeze_probe_items; -- dedicated 04_verify_freeze.sql write-probe fixture
commit;
-- The ops_freeze schema is the freeze tooling's audit trail; keep it, or (test project only) drop it explicitly:  drop schema ops_freeze cascade;
