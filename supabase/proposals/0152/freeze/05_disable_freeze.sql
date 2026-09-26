-- =============================================================================
-- 05_disable_freeze.sql -- DATABASE FREEZE v2, STEP 5: DISABLE (mutating, one transaction, restores from the recorded state)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION.
-- Drops ONLY the trigger "0_ops_freeze_block_writes" (wherever it exists), resumes ONLY the cron jobs this freeze paused (aborting if a job changed or was re-activated by someone
-- else), and marks the run restored. No role setting, privilege or data is touched, so there is nothing else to restore. No session recycling is needed: the trigger acts on
-- statements, not sessions. Nothing to fill in. Aborts (nothing changed) if there is no active run, the operator differs, or a table cannot be locked within 10 s.
-- =============================================================================
begin;
do $unfreeze$
declare
  v_run uuid; v_operator text; r record; v_ok boolean; v_dropped integer := 0; v_cron boolean := to_regclass('cron.job') is not null;
  c_trigger constant text := '0_ops_freeze_block_writes';
begin
  select run_id, operator into v_run, v_operator from ops_freeze_v2.freeze_run where status = 'frozen' order by started_at desc limit 1;
  if v_run is null then raise exception 'DISABLE REFUSED: no active freeze run in ops_freeze_v2 (if the triggers exist anyway, use EMERGENCY_UNFREEZE.sql). Nothing was changed.'; end if;
  if current_user <> v_operator or session_user <> v_operator then raise exception 'DISABLE REFUSED: run by % but the freeze operator is %. Nothing was changed.', session_user, v_operator; end if;
  perform set_config('lock_timeout', '10s', true);
  for r in select n.nspname::text as s, c.relname::text as t from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join pg_namespace n on n.oid = c.relnamespace
            where tg.tgname = c_trigger and not tg.tgisinternal order by 1, 2 loop
    execute format('drop trigger %I on %I.%I', c_trigger, r.s, r.t);
    v_dropped := v_dropped + 1;
  end loop;
  if exists (select 1 from pg_trigger where tgname = c_trigger and not tgisinternal) then raise exception 'DISABLE FAILED: freeze triggers remain. Transaction rolled back.'; end if;

  if not v_cron and exists (select 1 from ops_freeze_v2.cron_state where run_id = v_run) then raise exception 'DISABLE REFUSED: cron.job is absent but cron jobs were recorded. Transaction rolled back.'; end if;
  if v_cron then
    for r in select cs.job_id, cs.jobname, cs.schedule, cs.command_md5, cs.prior_active from ops_freeze_v2.cron_state cs where cs.run_id = v_run and cs.paused_by_freeze order by cs.job_id loop
      execute 'select exists (select 1 from cron.job j where j.jobid = $1 and j.schedule = $2 and md5(j.command) = $3)' into v_ok using r.job_id, r.schedule, r.command_md5;
      if not v_ok then raise exception 'DISABLE ABORTED: cron job % (%) changed (or was removed) since it was paused -- review manually. Transaction rolled back.', r.job_id, r.jobname; end if;
      execute 'select exists (select 1 from cron.job j where j.jobid = $1 and j.active)' into v_ok using r.job_id;
      if v_ok then raise exception 'DISABLE ABORTED: cron job % (%) was re-activated by someone else during the freeze -- review manually. Transaction rolled back.', r.job_id, r.jobname; end if;
      if r.prior_active then execute 'select cron.alter_job(job_id := $1, active := true)' using r.job_id; end if;
    end loop;
  end if;
  update ops_freeze_v2.freeze_run set status = 'restored', restored_at = now() where run_id = v_run;
  raise notice 'FREEZE DISABLED run_id=% triggers_dropped=%', v_run, v_dropped;
end
$unfreeze$;
commit;

-- OPERATOR-VISIBLE RESULT (SQL layer only). NEXT: 06_verify_disable.sql, then the external probe with --phase restored (writes must succeed again).
select 'SQL_LAYER_DISABLED' as result, r.run_id, r.restored_at,
       (select count(*) from pg_trigger where tgname = '0_ops_freeze_block_writes' and not tgisinternal) as freeze_triggers_remaining,
       (select count(*) from ops_freeze_v2.cron_state c where c.run_id = r.run_id and c.paused_by_freeze) as cron_jobs_resumed,
       'NEXT: 06_verify_disable.sql, then api_freeze_probe.py --phase restored' as next_step
from ops_freeze_v2.freeze_run r where r.status = 'restored' order by r.restored_at desc limit 1;
