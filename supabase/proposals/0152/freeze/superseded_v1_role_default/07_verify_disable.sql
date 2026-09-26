-- =============================================================================
-- 07_verify_disable.sql -- DATABASE FREEZE, STEP 7: POST-DISABLE VERIFICATION (SQL half)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION. ONE read-only SELECT (changes nothing). Proves the catalog is back to the RECORDED prior state.
-- "New application sessions can write again" is proven end-to-end by the REST/RPC write probe (HOSTED_TEST_PLAN.md step 9) -- it must also pass.
-- =============================================================================
with run as (select * from ops_freeze.freeze_run where status = 'restored' order by restored_at desc limit 1),
     cron_ok as (select case when to_regclass('cron.job') is null then not exists (select 1 from ops_freeze.cron_state cs join run on run.run_id = cs.run_id where true)
                    else (xpath('/row/c/text()', query_to_xml(
                      'select (count(*) filter (where j.jobid is null or j.schedule is distinct from cs.schedule or md5(j.command) is distinct from cs.command_md5 or j.active is distinct from cs.prior_active) = 0)::text as c from ops_freeze.cron_state cs left join cron.job j on j.jobid = cs.job_id where cs.run_id = (select run_id from ops_freeze.freeze_run where status = ''restored'' order by restored_at desc limit 1)',
                      false, true, '')))[1]::text = 'true' end as ok)
select 1 as ord, 'a restored run exists and no freeze is active' as check_name,
       case when (select count(*) from run) = 1 and not exists (select 1 from ops_freeze.freeze_run where status = 'frozen') then 'PASS' else 'FAIL' end as result, coalesce((select run_id::text from run), 'none') as detail
union all select 2, 'every frozen role has EXACTLY its recorded prior setconfig again',
       case when not exists (select 1 from ops_freeze.role_state rs join run on run.run_id = rs.run_id
                              left join (select ro.rolname, s.setconfig from pg_db_role_setting s join pg_roles ro on ro.oid = s.setrole where s.setdatabase = 0) cur on cur.rolname = rs.role_name
                             where (select coalesce(array_agg(x order by x), '{}') from unnest(coalesce(cur.setconfig, '{}'::text[])) x) is distinct from (select coalesce(array_agg(x order by x), '{}') from unnest(coalesce(rs.prior_role_setconfig, '{}'::text[])) x))
            then 'PASS' else 'FAIL' end, (select count(*) from ops_freeze.role_state rs join run on run.run_id = rs.run_id)::text || ' role(s) compared'
union all select 3, 'no default_transaction_read_only setting remains on any role/database (unless it existed before the freeze)',
       case when not exists (select 1 from pg_db_role_setting s where s.setconfig::text ilike '%default_transaction_read_only%' and not (s.setdatabase = 0 and 'default_transaction_read_only=on' = any(s.setconfig) and s.setrole = (select oid from pg_roles where rolname = 'supabase_read_only_user'))
                               and not exists (select 1 from ops_freeze.role_state rs join run on run.run_id = rs.run_id join pg_roles ro on ro.rolname = rs.role_name where ro.oid = s.setrole and rs.prior_role_setconfig::text ilike '%default_transaction_read_only%'))
            then 'PASS' else 'FAIL' end, ''
union all select 4, 'cron jobs paused by the freeze are active again (and unchanged); other jobs untouched', case when (select ok from cron_ok) then 'PASS' else 'FAIL' end, ''
union all select 5, 'no pre-restore (read-only) session of a frozen role remains',
       case when not exists (select 1 from run join pg_stat_activity a on a.usename::text = any(run.api_roles) and coalesce(a.backend_type, 'client backend') = 'client backend' and a.backend_start < run.restored_at) then 'PASS' else 'FAIL' end, ''
union all select 6, 'this (operator) session is writable', case when current_setting('transaction_read_only') = 'off' and not pg_is_in_recovery() then 'PASS' else 'FAIL' end, current_user::text
union all select 9999, 'RESULT: run the REST/RPC write probe (HOSTED_TEST_PLAN.md step 9) as well', 'INFO', '' 
order by 1;
