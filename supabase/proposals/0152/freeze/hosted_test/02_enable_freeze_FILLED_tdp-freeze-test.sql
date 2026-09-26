-- FILLED FOR tdp-freeze-test ONLY (hosted NON-PRODUCTION, PostgreSQL 17.6, operator postgres, database postgres). DO NOT RUN ANYWHERE ELSE.
-- v2 trigger freeze. Exempt LOGIN roles: postgres (the SQL Editor operator) and supabase_admin (superuser, platform-internal, unreachable from the API). Scope: schema public only
-- (auth/storage/realtime/etc. are platform schemas: the script REFUSES if any other schema holds tables nobody classified). pg_cron is not installed here: no cron ids.
-- No ALTER ROLE, no privilege change, no session termination. authenticator, pgbouncer and every platform role are untouched.
-- =============================================================================
-- 02_enable_freeze.sql -- DATABASE FREEZE v2, STEP 2: ENABLE (mutating, one transaction, fail closed)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION. Read ROOT_CAUSE_AND_REDESIGN.md first.
--
-- MECHANISM (replaces the failed v1 "ALTER ROLE authenticator SET default_transaction_read_only"): a BEFORE INSERT/UPDATE/DELETE/TRUNCATE STATEMENT-level trigger,
-- named "0_ops_freeze_block_writes" (sorts first), ENABLE ALWAYS, on every table of the listed application schemas. The trigger function decides on SESSION_USER (the
-- role that LOGGED IN -- `authenticator` for every PostgREST request, whatever role the request later SET ROLEs to, and also inside SECURITY DEFINER functions),
-- never on current_user. Only roles in v_exempt_login_roles (the operator, plus superusers) may write. Effective immediately for EVERY session, pooled or new; no
-- session termination is needed. It does not depend on how the API opens its transactions (explicit READ WRITE cannot override a trigger).
-- It changes NO role setting, NO privilege, NO ACL, NO RLS policy, NO table data. Everything it creates is in the private schema ops_freeze_v2 or is the one trigger.
-- Fill in the constants from 01_discovery_readonly.sql. Empty/mismatching values abort with nothing changed.
-- =============================================================================
begin;
do $freeze$
declare
  -- ===== OPERATOR: FILL IN FROM THE DISCOVERY REPORT. Empty / mismatching values abort the script. ==================================================
  v_operator_role   constant text   := 'postgres';                          -- must equal current_user AND session_user (the SQL Editor's role, normally postgres)
  v_expected_major  constant integer := 17;                          -- PostgreSQL major version expected (server_version_num / 10000)
  v_confirm         constant text   := 'FREEZE postgres';                          -- type exactly:  FREEZE <database name>      (e.g. FREEZE postgres)
  v_exempt_login_roles constant text[] := array['postgres', 'supabase_admin']::text[];          -- LOGIN roles that may still write: the operator (required) and superusers only (e.g. array['postgres','supabase_admin'])
  v_scope_schemas   constant text[] := array['public']::text[];             -- application schemas whose tables are frozen (e.g. array['public'])
  v_reviewed_out_of_scope_schemas constant text[] := array[]::text[]; -- other schemas that hold tables and were REVIEWED as not application data (rare)
  v_cron_pause_ids  constant bigint[] := array[]::bigint[];         -- pg_cron job ids that WRITE data and must be paused
  v_cron_keep_ids   constant bigint[] := array[]::bigint[];         -- pg_cron job ids reviewed as NOT writing application data (left running)
  -- =====================================================================================================================================================
  c_trigger constant text := '0_ops_freeze_block_writes';
  c_never_exempt constant text[] := array['authenticator', 'anon', 'authenticated', 'service_role', 'supabase_auth_admin', 'supabase_storage_admin', 'supabase_realtime_admin',
                                          'pgbouncer', 'supabase_read_only_user', 'dashboard_user', 'supabase_etl_admin', 'supabase_replication_admin', 'supabase_privileged_role'];
  c_platform_schemas constant text[] := array['auth', 'storage', 'realtime', 'extensions', 'vault', 'graphql', 'graphql_public', 'pgsodium', 'pgsodium_masks', 'supabase_functions',
                                              'supabase_migrations', 'cron', 'net', 'pgbouncer', '_realtime', '_analytics', 'pgtle', 'information_schema', 'ops_freeze', 'ops_freeze_v2'];
  r record;
  v_run uuid := gen_random_uuid();
  v_role text;
  v_n integer;
  v_has_cron boolean := to_regclass('cron.job') is not null;
  v_bool boolean;
  v_trig_fp text; v_acl_fp text; v_tables integer;
begin
  -- ---------------------------------------------------------------- PHASE 1: VALIDATION (fail closed; nothing has been changed yet)
  if v_operator_role = '' or v_expected_major = 0 or v_confirm = '' or cardinality(v_exempt_login_roles) = 0 or cardinality(v_scope_schemas) = 0 then
    raise exception 'FREEZE REFUSED: v_operator_role, v_expected_major, v_confirm, v_exempt_login_roles and v_scope_schemas must all be filled in from the discovery report. Nothing was changed.';
  end if;
  if v_confirm <> 'FREEZE ' || current_database() then raise exception 'FREEZE REFUSED: v_confirm must be exactly ''FREEZE %''. Nothing was changed.', current_database(); end if;
  if current_user <> v_operator_role or session_user <> v_operator_role then
    raise exception 'FREEZE REFUSED: current_user/session_user is %/% but v_operator_role is %. Nothing was changed.', current_user, session_user, v_operator_role;
  end if;
  if current_setting('server_version_num')::integer / 10000 <> v_expected_major then
    raise exception 'FREEZE REFUSED: server major version is % but v_expected_major is %. Nothing was changed.', current_setting('server_version_num')::integer / 10000, v_expected_major;
  end if;
  if current_setting('transaction_read_only') <> 'off' or pg_is_in_recovery() then raise exception 'FREEZE REFUSED: this session cannot write (read-only or standby). Nothing was changed.'; end if;
  if not (v_operator_role = any(v_exempt_login_roles)) then raise exception 'FREEZE REFUSED: the operator role must be in v_exempt_login_roles (otherwise the operator could not migrate). Nothing was changed.'; end if;
  foreach v_role in array v_exempt_login_roles loop
    select * into r from pg_roles where rolname = v_role;
    if not found then raise exception 'FREEZE REFUSED: exempt role % does not exist. Nothing was changed.', v_role; end if;
    if v_role = any(c_never_exempt) then raise exception 'FREEZE REFUSED: role % is an API/platform role and may never be exempt from the freeze. Nothing was changed.', v_role; end if;
    if v_role <> v_operator_role and not r.rolsuper then raise exception 'FREEZE REFUSED: exempt role % is neither the operator nor a superuser. Nothing was changed.', v_role; end if;
  end loop;
  if to_regclass('ops_freeze_v2.freeze_run') is not null then
    if exists (select 1 from ops_freeze_v2.freeze_run where status = 'frozen') then raise exception 'FREEZE REFUSED: a freeze run is already active in ops_freeze_v2. Nothing was changed.'; end if;
  end if;
  foreach v_role in array v_scope_schemas loop
    if not exists (select 1 from pg_namespace where nspname = v_role) then raise exception 'FREEZE REFUSED: scope schema % does not exist. Nothing was changed.', v_role; end if;
    if v_role = any(c_platform_schemas) or v_role like 'pg\_%' then raise exception 'FREEZE REFUSED: scope schema % is a platform/system schema. Nothing was changed.', v_role; end if;
  end loop;
  -- every schema that owns ordinary tables must be in scope, on the platform list, or explicitly reviewed (a writable table nobody classified would stay open)
  for r in select n.nspname::text as s, count(*) as n from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind in ('r', 'p') and c.relpersistence in ('p', 'u') and n.nspname <> all (v_scope_schemas || v_reviewed_out_of_scope_schemas || c_platform_schemas)
              and n.nspname not like 'pg\_%' group by 1 loop
    raise exception 'FREEZE REFUSED: schema % has % table(s) that are neither in v_scope_schemas nor reviewed (v_reviewed_out_of_scope_schemas) nor a platform schema. Classify it. Nothing was changed.', r.s, r.n;
  end loop;
  select count(*) into v_tables from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = any(v_scope_schemas) and c.relkind in ('r', 'p') and c.relpersistence in ('p', 'u');
  if v_tables = 0 then raise exception 'FREEZE REFUSED: no tables found in the scope schemas. Nothing was changed.'; end if;
  if exists (select 1 from pg_trigger t where t.tgname = c_trigger and not t.tgisinternal) then raise exception 'FREEZE REFUSED: a trigger named % already exists (unexpected prior state). Nothing was changed.', c_trigger; end if;
  for r in select n.nspname || '.' || c.relname as t from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = any(v_scope_schemas) and c.relkind in ('r', 'p') and c.relpersistence in ('p', 'u') and not pg_has_role(current_user, c.relowner, 'USAGE') limit 5 loop
    raise exception 'FREEZE REFUSED: the operator does not own (or is not a member of the owner of) table % -- cannot create the trigger. Nothing was changed.', r.t;
  end loop;
  if v_has_cron then
    -- every cron.job reference below is DYNAMIC SQL reached only when to_regclass('cron.job') is not null: PL/pgSQL parses/plans a static query when the statement is
    -- reached, and a missing relation is an error at that point (an `if v_has_cron and exists (... cron.job ...)` does NOT short-circuit the planner).
    for r in execute 'select jobid, jobname, active from cron.job' loop
      if r.active and not (r.jobid = any(v_cron_pause_ids) or r.jobid = any(v_cron_keep_ids)) then
        raise exception 'FREEZE REFUSED: active pg_cron job % (%) is neither in v_cron_pause_ids nor v_cron_keep_ids -- classify it. Nothing was changed.', r.jobid, r.jobname;
      end if;
    end loop;
    execute 'select count(*) from cron.job where jobid = any($1)' into v_n using v_cron_pause_ids || v_cron_keep_ids;
    if v_n <> cardinality(v_cron_pause_ids) + cardinality(v_cron_keep_ids) then raise exception 'FREEZE REFUSED: a listed cron job id does not exist (or an id is listed twice). Nothing was changed.'; end if;
    execute 'select exists (select 1 from cron.job where jobid = any($1) and not active)' into v_bool using v_cron_pause_ids;
    if v_bool then raise exception 'FREEZE REFUSED: a job in v_cron_pause_ids is not active (ambiguous prior state). Nothing was changed.'; end if;
  elsif cardinality(v_cron_pause_ids) + cardinality(v_cron_keep_ids) > 0 then
    raise exception 'FREEZE REFUSED: cron job ids were listed but cron.job is not present. Nothing was changed.';
  end if;

  -- ---------------------------------------------------------------- PHASE 2: OBJECTS + EXACT PRIOR-STATE RECORD (private schema; API roles get nothing)
  perform set_config('lock_timeout', '5s', true);   -- a table that cannot be locked in 5 s aborts the whole transaction (nothing changed) instead of queueing writers
  create schema if not exists ops_freeze_v2;
  revoke all on schema ops_freeze_v2 from public;
  create table if not exists ops_freeze_v2.freeze_run (run_id uuid primary key, started_at timestamptz not null default now(), operator text not null, server_version text not null,
    database_name text not null, status text not null check (status in ('frozen', 'restored')), exempt_roles text[] not null, scope_schemas text[] not null,
    pre_trigger_fp text not null, pre_acl_fp text not null, table_count integer not null, restored_at timestamptz);
  create unique index if not exists freeze_run_one_active on ops_freeze_v2.freeze_run ((true)) where status = 'frozen';
  create table if not exists ops_freeze_v2.frozen_table (run_id uuid not null references ops_freeze_v2.freeze_run (run_id), schema_name text not null, table_name text not null, table_oid oid not null,
    primary key (run_id, table_oid));
  create table if not exists ops_freeze_v2.cron_state (run_id uuid not null references ops_freeze_v2.freeze_run (run_id), job_id bigint not null, jobname text, schedule text, command_md5 text,
    prior_active boolean not null, paused_by_freeze boolean not null, primary key (run_id, job_id));
  revoke all on all tables in schema ops_freeze_v2 from public, anon, authenticated, service_role;

  create or replace function ops_freeze_v2.scope_tables(p_schemas text[]) returns table (oid oid, schema_name text, table_name text) language sql stable set search_path = pg_catalog, pg_temp as
  $f$ select c.oid, n.nspname::text, c.relname::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = any(p_schemas) and c.relkind in ('r', 'p') and c.relpersistence in ('p', 'u') $f$;
  create or replace function ops_freeze_v2.fingerprint_triggers(p_schemas text[]) returns text language sql stable set search_path = pg_catalog, pg_temp as
  $f$ select md5(coalesce(string_agg(n.nspname || '.' || c.relname || ':' || t.tgname || ':' || t.tgenabled::text || ':' || pg_get_triggerdef(t.oid), '|' order by n.nspname, c.relname, t.tgname), ''))
        from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = any(p_schemas) and not t.tgisinternal and t.tgname <> '0_ops_freeze_block_writes' $f$;
  create or replace function ops_freeze_v2.fingerprint_acl(p_schemas text[]) returns text language sql stable set search_path = pg_catalog, pg_temp as
  $f$ select md5(coalesce(string_agg(n.nspname || '.' || c.relname || ':' || coalesce(c.relacl::text, '') || ':' || c.relowner::text || ':' || c.relrowsecurity::text || ':' || c.relforcerowsecurity::text,
                                     '|' order by n.nspname, c.relname), ''))
        from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = any(p_schemas) and c.relkind in ('r', 'p', 'S', 'v', 'm') $f$;
  create or replace function ops_freeze_v2.session_is_exempt(p_session_user text) returns boolean language sql stable security definer set search_path = pg_catalog, pg_temp as
  $f$ select coalesce((select p_session_user = any(exempt_roles) from ops_freeze_v2.freeze_run where status = 'frozen' order by started_at desc limit 1), false) $f$;
  create or replace function ops_freeze_v2.block_writes() returns trigger language plpgsql security definer set search_path = pg_catalog, pg_temp as
  $f$ begin
    if ops_freeze_v2.session_is_exempt(session_user::text) then return null; end if;   -- session_user = the role that logged in (authenticator for PostgREST), NOT the SET ROLE / definer role
    raise exception 'TDP_MAINTENANCE_FREEZE: writes are temporarily disabled during a scheduled system upgrade' using errcode = '25006';
  end $f$;
  revoke all on function ops_freeze_v2.scope_tables(text[]), ops_freeze_v2.fingerprint_triggers(text[]), ops_freeze_v2.fingerprint_acl(text[]),
    ops_freeze_v2.session_is_exempt(text), ops_freeze_v2.block_writes() from public, anon, authenticated, service_role;

  v_trig_fp := ops_freeze_v2.fingerprint_triggers(v_scope_schemas);
  v_acl_fp := ops_freeze_v2.fingerprint_acl(v_scope_schemas);
  insert into ops_freeze_v2.freeze_run (run_id, operator, server_version, database_name, status, exempt_roles, scope_schemas, pre_trigger_fp, pre_acl_fp, table_count)
  values (v_run, current_user, current_setting('server_version'), current_database(), 'frozen', v_exempt_login_roles, v_scope_schemas, v_trig_fp, v_acl_fp, v_tables);
  insert into ops_freeze_v2.frozen_table (run_id, schema_name, table_name, table_oid) select v_run, s.schema_name, s.table_name, s.oid from ops_freeze_v2.scope_tables(v_scope_schemas) s;
  if v_has_cron then
    execute 'insert into ops_freeze_v2.cron_state (run_id, job_id, jobname, schedule, command_md5, prior_active, paused_by_freeze)
             select $1, j.jobid, j.jobname, j.schedule, md5(j.command), j.active, (j.jobid = any($2)) from cron.job j'
      using v_run, v_cron_pause_ids;
  end if;

  -- ---------------------------------------------------------------- PHASE 3: APPLY (one trigger per table + reviewed cron pauses)
  for r in select * from ops_freeze_v2.scope_tables(v_scope_schemas) order by schema_name, table_name loop
    execute format('create trigger %I before insert or update or delete or truncate on %I.%I for each statement execute function ops_freeze_v2.block_writes()', c_trigger, r.schema_name, r.table_name);
    execute format('alter table %I.%I enable always trigger %I', r.schema_name, r.table_name, c_trigger);
  end loop;
  if v_has_cron then
    for r in select job_id from ops_freeze_v2.cron_state where run_id = v_run and paused_by_freeze loop
      execute 'select cron.alter_job(job_id := $1, active := false)' using r.job_id;
    end loop;
  end if;

  -- ---------------------------------------------------------------- PHASE 4: SELF-CHECK (any failure rolls everything back)
  select count(*) into v_n from pg_trigger t join pg_class c on c.oid = t.tgrelid join ops_freeze_v2.frozen_table f on f.table_oid = c.oid and f.run_id = v_run
   where t.tgname = c_trigger and t.tgenabled = 'A' and not t.tgisinternal and (t.tgtype::int & 1) = 0 and (t.tgtype::int & 2) = 2 and (t.tgtype::int & (4 | 8 | 16 | 32)) = (4 | 8 | 16 | 32);
  if v_n <> v_tables then raise exception 'FREEZE FAILED SELF-CHECK: % of % tables have the enabled BEFORE statement trigger. Transaction rolled back.', v_n, v_tables; end if;
  if ops_freeze_v2.fingerprint_triggers(v_scope_schemas) <> v_trig_fp or ops_freeze_v2.fingerprint_acl(v_scope_schemas) <> v_acl_fp then
    raise exception 'FREEZE FAILED SELF-CHECK: another trigger or ACL changed while freezing. Transaction rolled back.';
  end if;
  if v_has_cron then
    execute 'select exists (select 1 from ops_freeze_v2.cron_state cs join cron.job j on j.jobid = cs.job_id where cs.run_id = $1 and cs.paused_by_freeze and j.active)' into v_bool using v_run;
    if v_bool then raise exception 'FREEZE FAILED SELF-CHECK: a job that should be paused is still active. Transaction rolled back.'; end if;
  end if;
  raise notice 'FREEZE ENABLED run_id=% tables=% paused_jobs=%', v_run, v_tables, v_cron_pause_ids;
end
$freeze$;
commit;

-- OPERATOR-VISIBLE RESULT. THIS IS ONLY THE SQL LAYER. The freeze is NOT proven until the external API probe (hosted_test/api_freeze_probe.py --phase frozen) shows every write blocked.
select 'SQL_LAYER_ENABLED' as result, r.run_id, r.started_at, r.operator, r.exempt_roles::text as exempt_login_roles, r.table_count as tables_frozen,
       (select count(*) from ops_freeze_v2.cron_state c where c.run_id = r.run_id and c.paused_by_freeze) as cron_jobs_paused,
       'NEXT: run 04_verify_freeze_sql_layer.sql, THEN the external API probe. Do NOT start any migration until BOTH pass.' as next_step
from ops_freeze_v2.freeze_run r where r.status = 'frozen' order by r.started_at desc limit 1;
