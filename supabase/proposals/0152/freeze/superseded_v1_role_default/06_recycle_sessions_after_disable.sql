-- =============================================================================
-- 06_recycle_sessions_after_disable.sql -- DATABASE FREEZE, STEP 6: RECYCLE THE READ-ONLY SESSIONS OPENED DURING THE FREEZE
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION. Run right after 05_disable_freeze.sql.
-- Sessions that started while the freeze was active carry the read-only default for their whole life. This terminates ONLY sessions of the roles recorded in the
-- most recent RESTORED run whose backend_start is before the restore time. Same never-terminate rules as step 3 (not this session, not the operator, not a
-- superuser, not a role outside the recorded list). Clients/pools reconnect automatically and get writable sessions.
-- =============================================================================
do $recycle$
declare v_run uuid; v_restored timestamptz; v_roles text[]; r record; v_n integer := 0; v_fail integer := 0;
begin
  select run_id, restored_at, api_roles into v_run, v_restored, v_roles from ops_freeze.freeze_run where status = 'restored' order by restored_at desc limit 1;
  if v_run is null then raise exception 'RECYCLE REFUSED: no restored run in ops_freeze. Nothing was terminated.'; end if;
  if exists (select 1 from ops_freeze.freeze_run where status = 'frozen') then raise exception 'RECYCLE REFUSED: a freeze is active again. Nothing was terminated.'; end if;
  for r in select a.pid from pg_stat_activity a join pg_roles ro on ro.oid = a.usesysid
            where coalesce(a.backend_type, 'client backend') = 'client backend' and a.pid <> pg_backend_pid() and a.usename::text = any(v_roles) and not ro.rolsuper
              and a.usename::text <> current_user and a.usename::text <> session_user and a.backend_start < v_restored loop
    if pg_terminate_backend(r.pid) then v_n := v_n + 1; else v_fail := v_fail + 1; end if;
  end loop;
  if v_fail > 0 then raise exception 'RECYCLE INCOMPLETE: % session(s) could not be signalled.', v_fail; end if;
  raise notice 'recycled % session(s)', v_n;
end
$recycle$;

select r.run_id,
       (select count(*) from pg_stat_activity a where a.usename::text = any(r.api_roles) and a.backend_start < r.restored_at and coalesce(a.backend_type, 'client backend') = 'client backend') as read_only_sessions_remaining,
       case when (select count(*) from pg_stat_activity a where a.usename::text = any(r.api_roles) and a.backend_start < r.restored_at and coalesce(a.backend_type, 'client backend') = 'client backend') = 0
            then 'OK: continue with 07_verify_disable.sql' else 'NOT OK: re-run this script' end as verdict
from ops_freeze.freeze_run r where r.status = 'restored' order by r.restored_at desc limit 1;
