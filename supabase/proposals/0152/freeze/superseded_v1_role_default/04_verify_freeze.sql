-- ##### SUPERSEDED v1 -- FAILED THE HOSTED NON-PRODUCTION TEST -- DO NOT RUN (see ../ROOT_CAUSE_AND_REDESIGN.md) #####
-- =============================================================================
-- 04_verify_freeze.sql -- DATABASE FREEZE, STEP 4: PROOF BATTERY (SQL half)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION. Run after 03_terminate_api_sessions.sql. Modifies NO application data:
--   * the whole script is ONE transaction that ENDS IN ROLLBACK;
--   * the only objects it creates are TEMPORARY (a results table and one temp function);
--   * every write "attempt" is a ZERO-ROW statement (`... where false`), so even if a block were unexpectedly not enforced it could change nothing;
--   * row counts of the key tables are taken before and after and compared.
-- SQL-only limits (stated honestly): (1) a role-level setting cannot be observed from another session, so "NEW sessions are read-only" is proven here by the catalog
-- setting + the absence of pre-freeze sessions + a simulation with transaction_read_only = on, and PROVEN END-TO-END by the REST/RPC probe of the hosted test plan
-- (HOSTED_TEST_PLAN.md, step 6) which connects as the real API path. (2) Both must PASS before any migration.
-- The final SELECT is the operator-visible result: every row PASS, and a last RESULT row.
-- =============================================================================
begin;

create temp table fz_results (ord serial, check_name text, result text, detail text) on commit drop;
create temp table fz_counts_before as
  select 'freeze_probe_items' as t, case when to_regclass('public.freeze_probe_items') is not null then (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.freeze_probe_items', false, true, '')))[1]::text::bigint end as n
  union all select 'loads', case when to_regclass('public.loads') is not null then (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.loads', false, true, '')))[1]::text::bigint end
  union all select 'activity_logs', case when to_regclass('public.activity_logs') is not null then (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.activity_logs', false, true, '')))[1]::text::bigint end;

-- a temporary SECURITY DEFINER function that attempts a zero-row write against a real table (created BEFORE the read-only simulation: DDL is blocked afterwards)
create function pg_temp.fz_definer_write() returns text language plpgsql security definer as $f$
begin
  if to_regclass('public.freeze_probe_items') is not null then
    execute 'insert into public.freeze_probe_items select * from public.freeze_probe_items where false';
  else
    execute 'insert into pg_temp.fz_results (check_name) select null where false';   -- fallback: temp table writes are allowed even in read-only mode
    raise exception 'no public.freeze_probe_items table to probe';
  end if;
  return 'WRITE ALLOWED';
end $f$;

do $chk$
declare
  v_run uuid; v_started timestamptz; v_roles text[]; v_role text; v_bad integer; v_op text := current_user; v_cron boolean := to_regclass('cron.job') is not null;
begin
  select run_id, started_at, api_roles into v_run, v_started, v_roles from ops_freeze.freeze_run where status = 'frozen' order by started_at desc limit 1;
  insert into fz_results (check_name, result, detail) values ('an active freeze run exists in ops_freeze', case when v_run is not null then 'PASS' else 'FAIL' end, coalesce(v_run::text, 'none'));
  if v_run is null then return; end if;

  foreach v_role in array v_roles loop
    insert into fz_results (check_name, result, detail) values
      ('role ' || v_role || ' has default_transaction_read_only=on (new sessions are read-only)',
       case when exists (select 1 from pg_db_role_setting s join pg_roles ro on ro.oid = s.setrole where ro.rolname = v_role and s.setdatabase = 0 and 'default_transaction_read_only=on' = any(s.setconfig)) then 'PASS' else 'FAIL' end,
       coalesce((select s.setconfig::text from pg_db_role_setting s join pg_roles ro on ro.oid = s.setrole where ro.rolname = v_role and s.setdatabase = 0), '(no row)'));
  end loop;
  select count(*) into v_bad from pg_db_role_setting s where s.setconfig::text ilike '%default_transaction_read_only%'
     and not (s.setdatabase = 0 and s.setrole in (select oid from pg_roles where rolname = any(v_roles)))
     and not (s.setdatabase = 0 and 'default_transaction_read_only=on' = any(s.setconfig) and s.setrole = (select oid from pg_roles where rolname = 'supabase_read_only_user'));   -- the platform's own supabase_read_only_user=on baseline is expected and is never touched
  insert into fz_results (check_name, result, detail) values ('no OTHER default_transaction_read_only setting exists (database/global/other roles)', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text);
  select count(*) into v_bad from pg_stat_activity a where coalesce(a.backend_type, 'client backend') = 'client backend' and a.usename::text = any(v_roles) and a.backend_start < v_started;
  insert into fz_results (check_name, result, detail) values ('stale sessions removed: no pre-freeze session of a frozen role remains', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text);
  select count(*) into v_bad from pg_stat_activity a where coalesce(a.backend_type, 'client backend') = 'client backend' and a.usename::text = any(v_roles) and a.backend_start >= v_started;
  insert into fz_results (check_name, result, detail) values ('INFO: sessions of frozen roles started after the freeze (read-only by the role setting)', 'INFO', v_bad::text);
  insert into fz_results (check_name, result, detail) values ('operator session is NOT frozen and was never terminated', case when current_user <> all (v_roles) and current_setting('transaction_read_only') = 'off' then 'PASS' else 'FAIL' end, v_op || ' / transaction_read_only=' || current_setting('transaction_read_only'));

  if v_cron then
    execute 'select count(*) from ops_freeze.cron_state cs left join cron.job j on j.jobid = cs.job_id where cs.run_id = $1 and cs.paused_by_freeze and (j.jobid is null or j.active)' into v_bad using v_run;
    insert into fz_results (check_name, result, detail) values ('reviewed cron writers are paused (cron.job.active = false)', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text || ' still active');
    execute 'select count(*) from ops_freeze.cron_state cs left join cron.job j on j.jobid = cs.job_id where cs.run_id = $1 and not cs.paused_by_freeze and (j.jobid is null or j.active is distinct from cs.prior_active)' into v_bad using v_run;
    insert into fz_results (check_name, result, detail) values ('jobs reviewed as non-writers were left exactly as they were', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text || ' changed');
  else
    select count(*) into v_bad from ops_freeze.cron_state where run_id = v_run;
    insert into fz_results (check_name, result, detail) values ('cron: no pg_cron job table on this database', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text || ' recorded jobs');
  end if;

  -- the operator can perform the approved migrations: writable session, create rights, ownership of the objects the migrations replace/alter
  insert into fz_results (check_name, result, detail) values
    ('operator can write (not in recovery, session not read-only)', case when not pg_is_in_recovery() and current_setting('transaction_read_only') = 'off' then 'PASS' else 'FAIL' end, 'recovery=' || pg_is_in_recovery()::text);
  insert into fz_results (check_name, result, detail) values
    ('operator has CREATE on schema public', case when has_schema_privilege(current_user, 'public', 'CREATE') then 'PASS' else 'FAIL' end, current_user::text);
  select count(*) into v_bad from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('dispatches', 'loads', 'carriers', 'trailers') and pg_get_userbyid(c.relowner) <> current_user
     and not pg_has_role(current_user, c.relowner, 'member');
  insert into fz_results (check_name, result, detail) values ('operator owns (or is a member of the owner of) the core tables the migrations alter', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text || ' not owned');
  create temp table fz_writable_probe (x int) on commit drop;
  insert into fz_writable_probe values (1);
  insert into fz_results (check_name, result, detail) values ('operator can write a TEMP table (proves an ordinary writable session)', 'PASS', 'ok');
end
$chk$;

-- ---- from here on the SESSION IS READ-ONLY (simulating what a frozen API session experiences). Temp-table writes stay allowed in read-only transactions.
set local transaction_read_only = on;

do $sim$
declare v_state text; v_msg text; v_ok boolean;
begin
  -- SELECT still works
  begin
    perform count(*) from information_schema.tables;
    if to_regclass('public.freeze_probe_items') is not null then perform 1 from public.freeze_probe_items limit 1; end if;
    insert into fz_results (check_name, result, detail) values ('ordinary SELECT still works (read-only inspection preserved)', 'PASS', 'ok');
  exception when others then
    insert into fz_results (check_name, result, detail) values ('ordinary SELECT still works (read-only inspection preserved)', 'FAIL', sqlerrm);
  end;

  if to_regclass('public.freeze_probe_items') is null then
    insert into fz_results (check_name, result, detail) values ('direct table write probes', 'FAIL', 'public.freeze_probe_items not found -- cannot probe (adjust the probe table in this script)');
    return;
  end if;

  -- direct INSERT / UPDATE / DELETE (zero-row statements: nothing could change even if not blocked)
  begin execute 'insert into public.freeze_probe_items select * from public.freeze_probe_items where false'; insert into fz_results (check_name, result, detail) values ('direct INSERT is blocked', 'FAIL', 'INSERT ALLOWED');
  exception when read_only_sql_transaction then insert into fz_results (check_name, result, detail) values ('direct INSERT is blocked', 'PASS', 'SQLSTATE 25006'); end;
  begin execute 'update public.freeze_probe_items set id = id where false'; insert into fz_results (check_name, result, detail) values ('direct UPDATE is blocked', 'FAIL', 'UPDATE ALLOWED');
  exception when read_only_sql_transaction then insert into fz_results (check_name, result, detail) values ('direct UPDATE is blocked', 'PASS', 'SQLSTATE 25006'); end;
  begin execute 'delete from public.freeze_probe_items where false'; insert into fz_results (check_name, result, detail) values ('direct DELETE is blocked', 'FAIL', 'DELETE ALLOWED');
  exception when read_only_sql_transaction then insert into fz_results (check_name, result, detail) values ('direct DELETE is blocked', 'PASS', 'SQLSTATE 25006'); end;
  -- a writable SECURITY DEFINER function (owner rights do not lift a read-only transaction)
  begin
    v_msg := pg_temp.fz_definer_write();
    insert into fz_results (check_name, result, detail) values ('a writable SECURITY DEFINER function is blocked', 'FAIL', v_msg);
  exception when read_only_sql_transaction then insert into fz_results (check_name, result, detail) values ('a writable SECURITY DEFINER function is blocked', 'PASS', 'SQLSTATE 25006');
            when others then insert into fz_results (check_name, result, detail) values ('a writable SECURITY DEFINER function is blocked', 'FAIL', sqlstate || ' ' || sqlerrm);
  end;
end
$sim$;

do $fin$
declare v_bad integer; v_n integer;
begin
  select count(*) into v_bad from (select 'freeze_probe_items' t, case when to_regclass('public.freeze_probe_items') is not null then (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.freeze_probe_items', false, true, '')))[1]::text::bigint end n
     union all select 'loads', case when to_regclass('public.loads') is not null then (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.loads', false, true, '')))[1]::text::bigint end
     union all select 'activity_logs', case when to_regclass('public.activity_logs') is not null then (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.activity_logs', false, true, '')))[1]::text::bigint end) a
     join fz_counts_before b using (t) where a.n is distinct from b.n;
  insert into fz_results (check_name, result, detail) values ('this verification modified no data (row counts of freeze_probe_items, loads, activity_logs unchanged)', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text || ' table(s) changed');
end
$fin$;

-- OPERATOR-VISIBLE RESULT (read the temp table inside the read-only transaction; the transaction is rolled back right after)
select ord, check_name, result, detail from fz_results
union all select 9999, 'RESULT', case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 'PASS' else 'FAIL' end,
       count(*) filter (where result = 'PASS')::text || ' passed, ' || count(*) filter (where result = 'FAIL')::text || ' failed. NEW-SESSION proof: run the REST/RPC probe (HOSTED_TEST_PLAN.md step 6) before any migration.' from fz_results
order by 1;

rollback;
