-- ##### SUPERSEDED v1 -- FAILED THE HOSTED NON-PRODUCTION TEST -- DO NOT RUN (see ../ROOT_CAUSE_AND_REDESIGN.md) #####
-- =============================================================================
-- 03_terminate_api_sessions.sql -- DATABASE FREEZE, STEP 3: TERMINATE PRE-FREEZE API/POOLER SESSIONS
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION. Run right after 02_enable_freeze.sql committed.
-- A role-level setting applies only to sessions that START after it exists; sessions opened earlier (pooled connections, stale tabs' connections) keep writing until
-- they end. This script terminates ONLY sessions that (a) belong to a role recorded as frozen in ops_freeze for the active run, (b) began BEFORE the freeze started,
-- (c) are client backends. It never terminates: this session, any session of the operator role, any superuser session, any role that is not in the recorded frozen
-- list, or anything that started after the freeze (those are already read-only). Single statement per session; a failure to signal is reported, not hidden.
-- =============================================================================
do $term$
declare
  v_run uuid; v_started timestamptz; v_roles text[]; r record; v_n integer := 0; v_fail integer := 0;
begin
  select run_id, started_at, api_roles into v_run, v_started, v_roles from ops_freeze.freeze_run where status = 'frozen' order by started_at desc limit 1;
  if v_run is null then raise exception 'TERMINATE REFUSED: no active freeze run in ops_freeze. Nothing was terminated.'; end if;
  if current_user = any(v_roles) or session_user = any(v_roles) then raise exception 'TERMINATE REFUSED: the operator role is in the frozen list (impossible state). Nothing was terminated.'; end if;
  for r in
    select a.pid, a.usename::text as usename from pg_stat_activity a join pg_roles ro on ro.oid = a.usesysid
     where coalesce(a.backend_type, 'client backend') = 'client backend' and a.pid <> pg_backend_pid()
       and a.usename::text = any(v_roles) and not ro.rolsuper
       and a.usename::text <> current_user and a.usename::text <> session_user
       and a.backend_start < v_started
  loop
    if pg_terminate_backend(r.pid) then v_n := v_n + 1; else v_fail := v_fail + 1; end if;
  end loop;
  update ops_freeze.freeze_run set terminated_sessions = coalesce(terminated_sessions, 0) + v_n where run_id = v_run;
  if v_fail > 0 then raise exception 'TERMINATE INCOMPLETE: % session(s) could not be signalled (privileges?). Run recorded; investigate before continuing.', v_fail; end if;
  raise notice 'terminated % pre-freeze session(s) of frozen roles %', v_n, v_roles;
end
$term$;

-- OPERATOR-VISIBLE RESULT: sessions of frozen roles that started BEFORE the freeze must now be zero (new ones are read-only).
select r.run_id, r.terminated_sessions,
       (select count(*) from pg_stat_activity a where a.usename::text = any(r.api_roles) and a.backend_start < r.started_at and coalesce(a.backend_type, 'client backend') = 'client backend') as pre_freeze_sessions_remaining,
       (select count(*) from pg_stat_activity a where a.usename::text = any(r.api_roles) and a.backend_start >= r.started_at and coalesce(a.backend_type, 'client backend') = 'client backend') as post_freeze_sessions_read_only,
       case when (select count(*) from pg_stat_activity a where a.usename::text = any(r.api_roles) and a.backend_start < r.started_at and coalesce(a.backend_type, 'client backend') = 'client backend') = 0
            then 'OK: continue with 04_verify_freeze.sql' else 'NOT OK: re-run this script; do not start migrations' end as verdict
from ops_freeze.freeze_run r where r.status = 'frozen' order by r.started_at desc limit 1;
