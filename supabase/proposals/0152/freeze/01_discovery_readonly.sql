-- =============================================================================
-- 01_discovery_readonly.sql -- DATABASE FREEZE v2, STEP 1: READ-ONLY DISCOVERY (v2 adds the table/schema inventory and trigger inventory the trigger freeze needs)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION. Run first on the NON-PRODUCTION Supabase project, then (after approval) on production.
-- ONE select statement (the Supabase SQL Editor shows only the last statement's result). It changes NOTHING: no DDL, no DML, no settings, no session
-- termination, no cron change. Optional catalog objects (pg_cron, ops_freeze) are read through query_to_xml() inside CASE so that their absence is a
-- report line, not an error. It never selects passwords or query text of other sessions.
-- Use the report to fill in the explicit identities of 02_enable_freeze.sql (operator, exempt login roles, scope schemas). Nothing here is guessed for you.
-- =============================================================================
with
me as (select r.rolname, r.rolsuper, r.rolcreaterole, r.rolcreatedb, r.rolreplication, r.rolbypassrls, r.oid
       from pg_roles r where r.rolname = current_user),
memb as (select g.rolname as member_of, m.admin_option
         from pg_auth_members m join pg_roles g on g.oid = m.roleid join me on me.oid = m.member),
login_roles as (select r.oid, r.rolname, r.rolsuper, r.rolcreaterole, r.rolbypassrls, r.rolconnlimit, r.rolvaliduntil,
                       coalesce((select string_agg(g.rolname || case when m.admin_option then '(admin)' else '' end, ', ' order by g.rolname)
                                 from pg_auth_members m join pg_roles g on g.oid = m.roleid where m.member = r.oid), '') as member_of,
                       coalesce(r.rolconfig::text, '') as rolconfig
                from pg_roles r where r.rolcanlogin and r.rolname !~ '^pg_'),
sess as (select coalesce(a.usename::text, '(background)') as usename, coalesce(nullif(a.application_name, ''), '(none)') as app,
                coalesce(host(a.client_addr), 'local-socket') as client, a.state, a.backend_start, a.pid
         from pg_stat_activity a where coalesce(a.backend_type, 'client backend') = 'client backend' and a.pid <> pg_backend_pid()),
cron_rows as (
  select case when to_regclass('cron.job') is null then '(pg_cron job table cron.job not present or not readable)'
              else coalesce((xpath('/row/j/text()', query_to_xml(
                'select coalesce(string_agg(format(''id=%s | name=%s | schedule=%s | active=%s | user=%s | db=%s | cmd=%s'', jobid, coalesce(jobname, ''''), schedule, active, username, database, left(regexp_replace(command, ''\s+'', '' '', ''g''), 220)), E''\n'' order by jobid), ''(no jobs)'') as j from cron.job',
                false, true, '')))[1]::text, '(unreadable)') end as j),
frz as (
  select case when to_regclass('ops_freeze.freeze_run') is null then '(no ops_freeze state: freeze has never been enabled here)'
              else coalesce((xpath('/row/j/text()', query_to_xml(
                'select coalesce(string_agg(format(''run=%s | status=%s | started=%s | operator=%s | restored=%s'', run_id, status, started_at, operator, coalesce(restored_at::text, ''-'')), E''\n'' order by started_at), ''(no runs)'') as j from ops_freeze.freeze_run',
                false, true, '')))[1]::text, '(unreadable)') end as j),
frz2 as (
  select case when to_regclass('ops_freeze_v2.freeze_run') is null then '(no ops_freeze_v2 state: the v2 freeze has never been enabled here)'
              else coalesce((xpath('/row/j/text()', query_to_xml(
                'select coalesce(string_agg(format(''run=%s | status=%s | started=%s | operator=%s | exempt=%s | tables=%s | restored=%s'', run_id, status, started_at, operator, exempt_roles, table_count, coalesce(restored_at::text, ''-'')), E''\n'' order by started_at), ''(no runs)'') as j from ops_freeze_v2.freeze_run',
                false, true, '')))[1]::text, '(unreadable)') end as j),
rows as (
  select 10 as ord, 'VERSION' as section, 'version()' as item, version()::text as detail
  union all select 11, 'VERSION', 'server_version_num / database', current_setting('server_version_num') || ' / ' || current_database()
  union all select 12, 'VERSION', 'hosted platform hint (supabase_admin role exists?)', exists (select 1 from pg_roles where rolname = 'supabase_admin')::text
  union all select 20, 'IDENTITY', 'current_user / session_user', current_user || ' / ' || session_user
  union all select 21, 'IDENTITY', 'attributes of current_user (super, createrole, createdb, replication, bypassrls)',
         (select rolsuper::text || ', ' || rolcreaterole::text || ', ' || rolcreatedb::text || ', ' || rolreplication::text || ', ' || rolbypassrls::text from me)
  union all select 22, 'IDENTITY', 'memberships of current_user (role(admin option))', coalesce((select string_agg(member_of || case when admin_option then '(admin)' else '' end, ', ' order by member_of) from memb), '(none)')
  union all select 23, 'IDENTITY', 'pg_signal_backend member? (needed to terminate sessions of non-superuser roles)', (pg_has_role(current_user, 'pg_signal_backend', 'member') or (select rolsuper from me))::text
  union all select 24, 'IDENTITY', 'pg_read_all_stats member? (needed to see other roles'' application_name/client)', (pg_has_role(current_user, 'pg_read_all_stats', 'member') or (select rolsuper from me))::text
  union all select 25, 'IDENTITY', 'server default_transaction_read_only now / source', current_setting('default_transaction_read_only') || ' / ' || (select source from pg_settings where name = 'default_transaction_read_only')
  union all select 26, 'IDENTITY', 'this session transaction_read_only', current_setting('transaction_read_only')
  union all select 30, 'LOGIN ROLES', l.rolname || case when l.rolname = current_user then '  <-- OPERATOR (never frozen)' else '' end,
         format('super=%s createrole=%s bypassrls=%s connlimit=%s member_of=[%s] rolconfig=%s', l.rolsuper, l.rolcreaterole, l.rolbypassrls, l.rolconnlimit, l.member_of, coalesce(nullif(l.rolconfig, ''), '(none)')) from login_roles l
  union all select 31, 'CAPABILITY', 'can current_user ALTER ROLE ... SET on ' || l.rolname || '?  (needs superuser, or CREATEROLE with ADMIN OPTION on it; role must not be superuser)',
         (case when l.rolsuper then 'NO (target is superuser)' when (select rolsuper from me) then 'YES (superuser)'
               when (select rolcreaterole from me) and exists (select 1 from pg_auth_members m join me on me.oid = m.member where m.roleid = l.oid and m.admin_option) then 'YES (createrole + admin option)'
               when (select rolcreaterole from me) then 'MAYBE (createrole without admin option: allowed only on PostgreSQL <= 15) -- test in the non-production project'
               else 'NO' end)
         from login_roles l where l.rolname <> current_user
  union all select 32, 'CAPABILITY', 'can current_user terminate sessions of ' || l.rolname || '?',
         (case when l.rolsuper then 'NO (target is superuser)' when (select rolsuper from me) or pg_has_role(current_user, 'pg_signal_backend', 'member') then 'YES' else 'NO' end)
         from login_roles l where l.rolname <> current_user
  union all select 40, 'API MODEL', 'membership of anon / authenticated / service_role / authenticator (who can SET ROLE to what)',
         coalesce((select string_agg(m2.rolname || ' -> ' || g2.rolname, E'\n' order by m2.rolname, g2.rolname) from pg_auth_members am join pg_roles m2 on m2.oid = am.member join pg_roles g2 on g2.oid = am.roleid
                   where g2.rolname in ('anon', 'authenticated', 'service_role', 'authenticator') or m2.rolname in ('authenticator', 'authenticated', 'anon', 'service_role')), '(none)')
  union all select 45, 'TABLES', 'ordinary tables per schema (schema | tables | owners) -- every schema with tables must be classified as scope / reviewed / platform in 02_enable_freeze.sql',
         coalesce((select string_agg(x.s || ' | ' || x.n || ' | ' || x.o, E'\n' order by x.s) from (select n.nspname::text as s, count(*) as n, string_agg(distinct pg_get_userbyid(c.relowner), ',') as o
                   from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p') and c.relpersistence in ('p', 'u') and n.nspname !~ '^pg_' and n.nspname <> 'information_schema' group by 1) x), '(none)')
  union all select 46, 'TABLES', 'tables in the PROPOSED scope schema public NOT owned by / usable by current_user (the trigger freeze cannot cover these: must be NONE)',
         coalesce((select string_agg(n.nspname || '.' || c.relname || ' (owner ' || pg_get_userbyid(c.relowner) || ')', E'\n') from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relpersistence in ('p', 'u') and not pg_has_role(current_user, c.relowner, 'USAGE')), 'NONE')
  union all select 47, 'TABLES', 'existing trigger named 0_ops_freeze_block_writes (must be NONE before the freeze)', coalesce((select string_agg(n.nspname || '.' || c.relname, ', ') from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where t.tgname = '0_ops_freeze_block_writes' and not t.tgisinternal), 'NONE')
  union all select 48, 'TABLES', 'user triggers currently on public tables (count) -- recorded as a fingerprint by the freeze', (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal)::text
  union all select 49, 'TABLES', 'default privileges (tables created later inherit these: new tables are API-writable until 03_refresh_coverage.sql)',
         coalesce((select string_agg(pg_get_userbyid(d.defaclrole) || ' in ' || coalesce(n.nspname, 'ALL') || ' [' || d.defaclobjtype::text || '] ' || d.defaclacl::text, E'\n') from pg_default_acl d left join pg_namespace n on n.oid = d.defaclnamespace), '(none)')
  union all select 50, 'SETTINGS', 'pg_db_role_setting  (database / role : setconfig)',
         coalesce((select string_agg(coalesce(d.datname, 'ALL-DBS') || ' / ' || coalesce(r.rolname, 'ALL-ROLES') || ' : ' || s.setconfig::text, E'\n' order by d.datname nulls first, r.rolname nulls first)
                   from pg_db_role_setting s left join pg_database d on d.oid = s.setdatabase left join pg_roles r on r.oid = s.setrole), '(none)')
  union all select 51, 'SETTINGS', 'any existing default_transaction_read_only setting at role / database / global level (must be NONE before the freeze)',
         coalesce((select string_agg(coalesce(d.datname, 'ALL-DBS') || ' / ' || coalesce(r.rolname, 'ALL-ROLES') || ' : ' || s.setconfig::text, E'\n')
                   from pg_db_role_setting s left join pg_database d on d.oid = s.setdatabase left join pg_roles r on r.oid = s.setrole
                   where s.setconfig::text ilike '%default_transaction_read_only%'), 'NONE')
  union all select 60, 'SESSIONS', s.usename || ' | app=' || s.app || ' | client=' || s.client,
         format('sessions=%s oldest_backend_start=%s states=%s', count(*), min(s.backend_start), string_agg(distinct coalesce(s.state, '?'), ','))
         from sess s group by s.usename, s.app, s.client
  union all select 61, 'SESSIONS', 'total client sessions (excluding this one)', (select count(*) from sess)::text
  union all select 70, 'CRON', 'pg_cron extension installed', exists (select 1 from pg_extension where extname = 'pg_cron')::text
  union all select 71, 'CRON', 'jobs (every job; a job is a scheduled writer unless proven read-only)', j from cron_rows
  union all select 80, 'OTHER SCHEDULED / EXTERNAL WRITERS', 'installed extensions', coalesce((select string_agg(extname || ' ' || extversion, ', ' order by extname) from pg_extension), '(none)')
  union all select 81, 'OTHER SCHEDULED / EXTERNAL WRITERS', 'event triggers', coalesce((select string_agg(evtname || ' (' || evtevent || ')', ', ') from pg_event_trigger), '(none)')
  union all select 82, 'OTHER SCHEDULED / EXTERNAL WRITERS', 'logical replication subscriptions (inbound writers) / publications',
         coalesce((select string_agg(subname, ', ') from pg_subscription), '(none)') || ' / ' || coalesce((select string_agg(pubname, ', ') from pg_publication), '(none)')
  union all select 83, 'OTHER SCHEDULED / EXTERNAL WRITERS', 'user triggers that call outbound HTTP (Supabase Database Webhooks: functions in supabase_functions / net)',
         (select count(*) from pg_trigger t join pg_proc p on p.oid = t.tgfoid join pg_namespace n on n.oid = p.pronamespace where not t.tgisinternal and n.nspname in ('supabase_functions', 'net'))::text
  union all select 84, 'OTHER SCHEDULED / EXTERNAL WRITERS', 'active replication connections (physical/logical clients)', (select count(*) from pg_stat_replication)::text
  union all select 90, 'FREEZE STATE', 'LEGACY v1 ops_freeze runs (superseded design; informational)', j from frz
  union all select 91, 'FREEZE STATE', 'ops_freeze_v2 runs (status=frozen means a v2 freeze is already active)', j from frz2
)
select ord, section, item, detail from rows order by ord, section, item;
