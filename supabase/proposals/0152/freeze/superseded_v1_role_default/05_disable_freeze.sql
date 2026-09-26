-- =============================================================================
-- 05_disable_freeze.sql -- DATABASE FREEZE, STEP 5: DISABLE (RESTORE THE EXACT PRIOR STATE)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION. Uses ONLY the state recorded by 02_enable_freeze.sql; nothing is guessed.
--   * each frozen role: if it had NO role-level default_transaction_read_only before -> RESET it; the recorded setconfig row must then match exactly
--     (any unrelated setting it had, e.g. statement_timeout, is untouched);
--   * cron: ONLY the jobs this freeze paused are re-activated, and only if they are still paused and unchanged (schedule/command hash) since;
--   * the run is marked 'restored'. No privilege is ever granted or revoked by the freeze tooling, so there is nothing to re-grant.
-- Single transaction; aborts (changing nothing) on ANY mismatch. Next: 06_recycle_sessions_after_disable.sql (sessions opened DURING the freeze keep the
-- read-only default until they end), then 07_verify_disable.sql and the REST/RPC write probe.
-- =============================================================================
begin;

do $unfreeze$
declare
  v_run uuid; v_roles text[]; r record; v_now text[]; v_ok boolean; v_cron boolean := to_regclass('cron.job') is not null;
begin
  select run_id, api_roles into v_run, v_roles from ops_freeze.freeze_run where status = 'frozen' order by started_at desc limit 1;
  if v_run is null then raise exception 'DISABLE REFUSED: no run with status=frozen in ops_freeze (already restored, or never enabled). Nothing was changed.'; end if;
  if current_setting('transaction_read_only') <> 'off' or pg_is_in_recovery() then raise exception 'DISABLE REFUSED: this session cannot write. Nothing was changed.'; end if;
  if current_user = any(v_roles) or session_user = any(v_roles) then raise exception 'DISABLE REFUSED: the operator role is a frozen role (impossible state). Nothing was changed.'; end if;

  -- restore roles from the RECORDED prior state
  for r in select role_name, prior_role_setconfig, prior_ro_value from ops_freeze.role_state where run_id = v_run order by role_name loop
    if r.prior_ro_value is null then
      execute format('alter role %I reset default_transaction_read_only', r.role_name);
    else
      execute format('alter role %I set default_transaction_read_only = %L', r.role_name, r.prior_ro_value);
    end if;
    select s.setconfig into v_now from pg_db_role_setting s join pg_roles ro on ro.oid = s.setrole where ro.rolname = r.role_name and s.setdatabase = 0;
    v_ok := (select coalesce(array_agg(x order by x), '{}'::text[]) from unnest(coalesce(v_now, '{}'::text[])) x) is not distinct from (select coalesce(array_agg(x order by x), '{}'::text[]) from unnest(coalesce(r.prior_role_setconfig, '{}'::text[])) x);
    if not v_ok then raise exception 'DISABLE ABORTED: role % setconfig after restore (%) differs from the recorded prior state (%). Transaction rolled back.', r.role_name, v_now, r.prior_role_setconfig; end if;
  end loop;

  -- restore ONLY the cron jobs this freeze paused
  if not v_cron and exists (select 1 from ops_freeze.cron_state where run_id = v_run) then
    raise exception 'DISABLE REFUSED: cron.job is absent but cron jobs were recorded. Transaction rolled back.';
  end if;
  if v_cron then
    for r in select cs.job_id, cs.jobname, cs.schedule, cs.command_md5, cs.prior_active from ops_freeze.cron_state cs where cs.run_id = v_run and cs.paused_by_freeze order by cs.job_id loop
      execute 'select exists (select 1 from cron.job j where j.jobid = $1 and j.schedule = $2 and md5(j.command) = $3)'
        into v_ok using r.job_id, r.schedule, r.command_md5;
      if not v_ok then
        raise exception 'DISABLE ABORTED: cron job % (%) changed (or was removed) since it was paused -- review manually. Transaction rolled back.', r.job_id, r.jobname;
      end if;
      execute 'select exists (select 1 from cron.job j where j.jobid = $1 and j.active)' into v_ok using r.job_id;
      if v_ok then
        raise exception 'DISABLE ABORTED: cron job % (%) was re-activated by someone else during the freeze -- review manually. Transaction rolled back.', r.job_id, r.jobname;
      end if;
      if r.prior_active then execute 'select cron.alter_job(job_id := $1, active := true)' using r.job_id; end if;
    end loop;
  end if;

  update ops_freeze.freeze_run set status = 'restored', restored_at = now() where run_id = v_run;
  raise notice 'FREEZE DISABLED run_id=%', v_run;
end
$unfreeze$;

commit;

-- OPERATOR-VISIBLE RESULT
select 'RESTORED' as result, r.run_id, r.restored_at, r.api_roles::text as roles_restored,
       (select count(*) from ops_freeze.cron_state c where c.run_id = r.run_id and c.paused_by_freeze) as cron_jobs_resumed,
       'NEXT: run 06_recycle_sessions_after_disable.sql, then 07_verify_disable.sql and the REST/RPC write probe' as next_step
from ops_freeze.freeze_run r where r.status = 'restored' order by r.restored_at desc limit 1;
