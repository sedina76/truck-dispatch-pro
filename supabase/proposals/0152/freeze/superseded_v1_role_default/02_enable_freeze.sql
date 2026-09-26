-- ##### SUPERSEDED v1 -- FAILED THE HOSTED NON-PRODUCTION TEST -- DO NOT RUN (see ../ROOT_CAUSE_AND_REDESIGN.md) #####
-- =============================================================================
-- 02_enable_freeze.sql -- DATABASE FREEZE, STEP 2: ENABLE READ-ONLY PROTECTION FOR THE API/POOLER LOGIN ROLES
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION. Run ONLY after 01_discovery_readonly.sql has been reviewed and the MAINTENANCE_MODE app gate
-- is verified. Nothing here is guessed: every identity below must be filled in by the operator from the discovery report; while any is empty this script
-- ABORTS in Phase 1 and changes nothing. Single transaction (all-or-nothing). Never touches the operator role, superusers, or Supabase-internal roles.
--
-- WHAT IT DOES (and only this):
--   1. validates everything (identity, version, roles, prior settings, sessions, cron jobs, no freeze already active);
--   2. records the EXACT prior state in ops_freeze.* (a private schema; no API role has any privilege on it): each role's pg_db_role_setting row, the database
--      and global rows, and every cron job's prior `active` flag;
--   3. ALTER ROLE <each listed API/pooler login role> SET default_transaction_read_only = on  (new sessions of those roles cannot write -- direct table
--      writes, RPCs including SECURITY DEFINER ones, and BYPASSRLS/service-role writes all fail with SQLSTATE 25006; SELECT keeps working);
--   4. pauses ONLY the cron jobs listed in v_cron_pause_ids (cron.alter_job ... active := false).
-- It does NOT terminate sessions (03_terminate_api_sessions.sql does, after this commits), does not revoke any privilege, and changes no data table.
-- The freeze is reversed by 05_disable_freeze.sql using the state captured here.
-- =============================================================================
begin;

do $freeze$
declare
  -- ===== OPERATOR: FILL IN FROM THE DISCOVERY REPORT. Empty / mismatching values abort the script. ==================================================
  v_operator_role   constant text   := '';                          -- must equal current_user AND session_user (e.g. the SQL Editor's role)
  v_expected_major  constant integer := 0;                          -- PostgreSQL major version expected (discovery: server_version_num / 10000)
  v_confirm         constant text   := '';                          -- type exactly:  FREEZE <database name>      (e.g. FREEZE postgres)
  v_api_roles       constant text[] := array[]::text[];             -- login roles used by PostgREST / pooler / other APP connections to freeze (e.g. array['authenticator'])
  v_reviewed_other_roles constant text[] := array[]::text[];        -- other login roles with sessions that you REVIEWED and accept remain untouched (Supabase-internal ones)
  v_cron_pause_ids  constant bigint[] := array[]::bigint[];         -- pg_cron job ids that WRITE data and must be paused
  v_cron_keep_ids   constant bigint[] := array[]::bigint[];         -- pg_cron job ids reviewed as NOT writing application data (left running)
  -- =====================================================================================================================================================
  c_never_freeze constant text[] := array['postgres', 'supabase_admin', 'supabase_auth_admin', 'supabase_storage_admin', 'supabase_realtime_admin',
                                           'supabase_replication_admin', 'supabase_etl_admin', 'supabase_privileged_role', 'supabase_read_only_user', 'pgbouncer', 'dashboard_user', 'authenticated', 'anon', 'service_role'];
  r record;
  v_run uuid := gen_random_uuid();
  v_sess text;
  v_n integer;
  v_prior text[];
  v_bad_cron boolean;
  v_has_cron boolean := to_regclass('cron.job') is not null;
begin
  -- ---------------------------------------------------------------- PHASE 1: VALIDATION (fail closed)
  if v_operator_role = '' or v_expected_major = 0 or v_confirm = '' or cardinality(v_api_roles) = 0 then
    raise exception 'FREEZE REFUSED: v_operator_role, v_expected_major, v_confirm and v_api_roles must all be filled in from the discovery report. Nothing was changed.';
  end if;
  if v_confirm <> 'FREEZE ' || current_database() then raise exception 'FREEZE REFUSED: v_confirm must be exactly ''FREEZE %''. Nothing was changed.', current_database(); end if;
  if current_user <> v_operator_role or session_user <> v_operator_role then
    raise exception 'FREEZE REFUSED: current_user/session_user is %/% but v_operator_role is %. Nothing was changed.', current_user, session_user, v_operator_role;
  end if;
  if current_setting('server_version_num')::integer / 10000 <> v_expected_major then
    raise exception 'FREEZE REFUSED: server major version is % but v_expected_major is %. Nothing was changed.', current_setting('server_version_num')::integer / 10000, v_expected_major;
  end if;
  if current_setting('transaction_read_only') <> 'off' or pg_is_in_recovery() then raise exception 'FREEZE REFUSED: this session cannot write (read-only or standby). Nothing was changed.'; end if;
  if to_regclass('ops_freeze.freeze_run') is not null then   -- (separate statement: PL/pgSQL plans a query only when it executes, so a missing table is never referenced)
    if exists (select 1 from ops_freeze.freeze_run where status = 'frozen') then
      raise exception 'FREEZE REFUSED: an ops_freeze run with status=frozen already exists (a freeze is already active). Nothing was changed.';
    end if;
  end if;

  foreach v_sess in array v_api_roles loop
    select * into r from pg_roles where rolname = v_sess;
    if not found then raise exception 'FREEZE REFUSED: role % does not exist. Nothing was changed.', v_sess; end if;
    if not r.rolcanlogin then raise exception 'FREEZE REFUSED: role % is not a login role. Nothing was changed.', v_sess; end if;
    if r.rolsuper then raise exception 'FREEZE REFUSED: role % is a superuser. Nothing was changed.', v_sess; end if;
    if v_sess = current_user or v_sess = session_user or v_sess = v_operator_role then raise exception 'FREEZE REFUSED: role % is the operator. Nothing was changed.', v_sess; end if;
    if v_sess = any(c_never_freeze) then raise exception 'FREEZE REFUSED: role % is on the never-freeze list (operator/Supabase-internal/API-switch roles). Nothing was changed.', v_sess; end if;
    if v_sess = any(v_reviewed_other_roles) then raise exception 'FREEZE REFUSED: role % is listed both as frozen and as reviewed-other. Nothing was changed.', v_sess; end if;
    -- prior settings must not already touch default_transaction_read_only at any precedence level that would override or duplicate ours
    if exists (select 1 from pg_db_role_setting s where s.setrole = r.oid and s.setconfig::text ilike '%default_transaction_read_only%') then
      raise exception 'FREEZE REFUSED: role % already has a default_transaction_read_only setting (unexpected prior state; review manually). Nothing was changed.', v_sess;
    end if;
  end loop;
  if exists (select 1 from pg_db_role_setting s where s.setrole = 0 and s.setconfig::text ilike '%default_transaction_read_only%') then
    raise exception 'FREEZE REFUSED: a database-level or global default_transaction_read_only setting already exists (unexpected). Nothing was changed.';
  end if;
  if current_setting('default_transaction_read_only') <> 'off' then raise exception 'FREEZE REFUSED: default_transaction_read_only is already % for this session. Nothing was changed.', current_setting('default_transaction_read_only'); end if;

  -- every client session must belong to the operator, a frozen role, a reviewed-other role, or a superuser/internal role from the never-freeze list
  for r in select a.usename::text as usename, count(*) as n from pg_stat_activity a
            where coalesce(a.backend_type, 'client backend') = 'client backend' and a.usename is not null and a.pid <> pg_backend_pid()
              and a.usename::text <> all (v_api_roles || v_reviewed_other_roles || array[v_operator_role] || c_never_freeze)
            group by 1 loop
    raise exception 'FREEZE REFUSED: % unexpected session(s) of role % (not the operator, not a listed API role, not a reviewed-other role). Add it to v_reviewed_other_roles or v_api_roles after review. Nothing was changed.', r.n, r.usename;
  end loop;

  -- cron: every ACTIVE job must be classified; every listed id must exist; pause-listed jobs must currently be active
  if v_has_cron then
    for r in execute 'select jobid, jobname, active from cron.job' loop
      if r.active and not (r.jobid = any(v_cron_pause_ids) or r.jobid = any(v_cron_keep_ids)) then
        raise exception 'FREEZE REFUSED: active pg_cron job % (%) is neither in v_cron_pause_ids nor v_cron_keep_ids -- classify it. Nothing was changed.', r.jobid, r.jobname;
      end if;
    end loop;
    execute 'select count(*) from cron.job where jobid = any($1)' into v_n using v_cron_pause_ids || v_cron_keep_ids;
    if v_n <> cardinality(v_cron_pause_ids) + cardinality(v_cron_keep_ids) then raise exception 'FREEZE REFUSED: a listed cron job id does not exist (or an id is listed twice). Nothing was changed.'; end if;
    execute 'select exists (select 1 from cron.job where jobid = any($1) and not active)' into v_bad_cron using v_cron_pause_ids;
    if v_bad_cron then raise exception 'FREEZE REFUSED: a job in v_cron_pause_ids is not active (ambiguous prior state). Nothing was changed.'; end if;
  elsif cardinality(v_cron_pause_ids) + cardinality(v_cron_keep_ids) > 0 then
    raise exception 'FREEZE REFUSED: cron job ids were listed but cron.job is not present. Nothing was changed.';
  end if;

  -- ---------------------------------------------------------------- PHASE 2: RECORD THE EXACT PRIOR STATE
  create schema if not exists ops_freeze;
  revoke all on schema ops_freeze from public;
  create table if not exists ops_freeze.freeze_run (run_id uuid primary key, started_at timestamptz not null default now(), operator text not null, server_version text not null,
    database_name text not null, status text not null check (status in ('frozen', 'restored')), api_roles text[] not null, restored_at timestamptz, terminated_sessions integer);
  create table if not exists ops_freeze.role_state (run_id uuid not null references ops_freeze.freeze_run (run_id), role_name text not null, prior_role_setconfig text[], prior_ro_value text,
    primary key (run_id, role_name));
  create table if not exists ops_freeze.db_state (run_id uuid not null references ops_freeze.freeze_run (run_id), scope text not null, setconfig text[], primary key (run_id, scope));
  create table if not exists ops_freeze.cron_state (run_id uuid not null references ops_freeze.freeze_run (run_id), job_id bigint not null, jobname text, schedule text, command_md5 text,
    prior_active boolean not null, paused_by_freeze boolean not null, primary key (run_id, job_id));
  revoke all on all tables in schema ops_freeze from public, anon, authenticated, service_role;

  insert into ops_freeze.freeze_run (run_id, operator, server_version, database_name, status, api_roles)
  values (v_run, current_user, current_setting('server_version'), current_database(), 'frozen', v_api_roles);
  insert into ops_freeze.db_state (run_id, scope, setconfig)
  select v_run, 'database:' || d.datname, s.setconfig from pg_database d left join pg_db_role_setting s on s.setdatabase = d.oid and s.setrole = 0 where d.datname = current_database();
  insert into ops_freeze.db_state (run_id, scope, setconfig) select v_run, 'global', (select s.setconfig from pg_db_role_setting s where s.setdatabase = 0 and s.setrole = 0);
  foreach v_sess in array v_api_roles loop
    select s.setconfig into v_prior from pg_db_role_setting s join pg_roles ro on ro.oid = s.setrole where ro.rolname = v_sess and s.setdatabase = 0;
    insert into ops_freeze.role_state (run_id, role_name, prior_role_setconfig, prior_ro_value) values (v_run, v_sess, v_prior, null);
  end loop;
  if v_has_cron then
    execute 'insert into ops_freeze.cron_state (run_id, job_id, jobname, schedule, command_md5, prior_active, paused_by_freeze)
             select $1, j.jobid, j.jobname, j.schedule, md5(j.command), j.active, (j.jobid = any($2)) from cron.job j'
      using v_run, v_cron_pause_ids;
  end if;

  -- ---------------------------------------------------------------- PHASE 3: APPLY
  foreach v_sess in array v_api_roles loop
    execute format('alter role %I set default_transaction_read_only = on', v_sess);
  end loop;
  if v_has_cron then
    for r in select job_id from ops_freeze.cron_state where run_id = v_run and paused_by_freeze loop
      execute 'select cron.alter_job(job_id := $1, active := false)' using r.job_id;
    end loop;
  end if;

  -- ---------------------------------------------------------------- PHASE 4: SELF-CHECK
  foreach v_sess in array v_api_roles loop
    if not exists (select 1 from pg_db_role_setting s join pg_roles ro on ro.oid = s.setrole where ro.rolname = v_sess and s.setdatabase = 0 and 'default_transaction_read_only=on' = any(s.setconfig)) then
      raise exception 'FREEZE FAILED SELF-CHECK: role % did not receive the setting. Transaction rolled back.', v_sess;
    end if;
  end loop;
  if v_has_cron then
    execute 'select exists (select 1 from ops_freeze.cron_state cs join cron.job j on j.jobid = cs.job_id where cs.run_id = $1 and cs.paused_by_freeze and j.active)'
      into v_bad_cron using v_run;
  end if;
  if v_bad_cron then
    raise exception 'FREEZE FAILED SELF-CHECK: a job that should be paused is still active. Transaction rolled back.';
  end if;
  raise notice 'FREEZE ENABLED run_id=% roles=% paused_jobs=%', v_run, v_api_roles, v_cron_pause_ids;
end
$freeze$;

commit;

-- OPERATOR-VISIBLE RESULT (the last statement's rows are what the SQL Editor shows). Next: 03_terminate_api_sessions.sql, then 04_verify_freeze.sql.
select 'FROZEN' as result, r.run_id, r.started_at, r.operator, r.api_roles::text as frozen_roles,
       (select count(*) from ops_freeze.cron_state c where c.run_id = r.run_id and c.paused_by_freeze) as cron_jobs_paused,
       'NEXT: run 03_terminate_api_sessions.sql' as next_step
from ops_freeze.freeze_run r where r.status = 'frozen' order by r.started_at desc limit 1;
