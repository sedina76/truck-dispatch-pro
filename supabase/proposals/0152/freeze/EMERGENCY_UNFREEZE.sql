-- =============================================================================
-- EMERGENCY_UNFREEZE.sql -- stateless emergency removal of the v2 database freeze (mutating; run as the operator/SQL-Editor role, e.g. postgres)
-- Use when 05_disable_freeze.sql cannot run (ops_freeze_v2 damaged/missing) or an emergency write path must reopen NOW. It depends on NO recorded state: it drops every trigger
-- named "0_ops_freeze_block_writes" and nothing else. It does NOT resume paused cron jobs (see EMERGENCY_RECOVERY.md, section 3) and does NOT change MAINTENANCE_MODE.
-- One statement. If a table cannot be locked within 15 s it aborts with nothing changed -- re-run it. Never touches roles, privileges, settings or data.
-- =============================================================================
do $emergency$
declare r record; n integer := 0;
begin
  perform set_config('lock_timeout', '15s', true);
  for r in select nsp.nspname::text as s, c.relname::text as t from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join pg_namespace nsp on nsp.oid = c.relnamespace
            where tg.tgname = '0_ops_freeze_block_writes' and not tg.tgisinternal order by 1, 2 loop
    execute format('drop trigger %I on %I.%I', '0_ops_freeze_block_writes', r.s, r.t);
    n := n + 1;
  end loop;
  raise notice 'EMERGENCY UNFREEZE: dropped % freeze trigger(s)', n;
end
$emergency$;
select 'EMERGENCY_UNFREEZE_DONE' as result, (select count(*) from pg_trigger where tgname = '0_ops_freeze_block_writes' and not tgisinternal) as freeze_triggers_remaining,
       'The ops_freeze_v2 run row (if any) still says frozen: run 05_disable_freeze.sql only if it can complete, or leave it and record the emergency in the change ticket.' as note;
