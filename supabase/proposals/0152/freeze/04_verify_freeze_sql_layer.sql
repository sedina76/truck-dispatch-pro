-- =============================================================================
-- 04_verify_freeze_sql_layer.sql -- DATABASE FREEZE v2, STEP 4: SQL-LAYER CHECKS. THIS SCRIPT CAN NEVER DECLARE THE FREEZE SUCCESSFUL.
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION.
-- Why it cannot: the v1 verifier reported PASS while a real PostgREST insert still succeeded, because it SIMULATED a frozen session (SET LOCAL transaction_read_only = on)
-- and checked a catalog row -- neither observes the real API path. This SQL runs as the operator, which is EXEMPT by design, so it can only prove that the enforcement
-- objects are installed, complete and functional; whether the real API requests arrive as a non-exempt session is proven ONLY by the external probe.
-- Its final verdict is therefore either SQL_LAYER_FAIL or SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED -- never "PASS".
-- Safety: one transaction that ENDS IN ROLLBACK. The only thing it modifies (inside that transaction) is the freeze_run row's exempt list, to prove the trigger really fires on
-- every frozen table (zero-row `delete ... where false` statements: statement triggers fire even for zero rows, so no data can change); the rollback restores it.
-- =============================================================================
begin;
create temp table fz_results (ord serial, check_name text, result text, detail text) on commit drop;

do $chk$
declare
  v_after_migrations constant boolean := false;   -- set to true ONLY when approved migrations ran since the freeze started (then trigger/ACL fingerprints may legitimately differ)
  c_trigger constant text := '0_ops_freeze_block_writes';
  v_run uuid; v_scope text[]; v_exempt text[]; v_op text; v_pre_trig text; v_pre_acl text; v_started timestamptz;
  v_bad integer; v_total integer; r record; v_cron boolean := to_regclass('cron.job') is not null; v_state text; v_msg text; v_role text;
begin
  select run_id, scope_schemas, exempt_roles, operator, pre_trigger_fp, pre_acl_fp, started_at into v_run, v_scope, v_exempt, v_op, v_pre_trig, v_pre_acl, v_started
    from ops_freeze_v2.freeze_run where status = 'frozen' order by started_at desc limit 1;
  insert into fz_results (check_name, result, detail) values ('exactly one active freeze run exists', case when v_run is not null and (select count(*) from ops_freeze_v2.freeze_run where status = 'frozen') = 1 then 'PASS' else 'FAIL' end, coalesce(v_run::text, 'none'));
  if v_run is null then return; end if;

  select count(*) into v_total from ops_freeze_v2.scope_tables(v_scope);
  select count(*) into v_bad from ops_freeze_v2.scope_tables(v_scope) s where not exists (
    select 1 from pg_trigger t where t.tgrelid = s.oid and t.tgname = c_trigger and not t.tgisinternal and t.tgenabled = 'A' and (t.tgtype::int & 1) = 0 and (t.tgtype::int & 2) = 2
      and (t.tgtype::int & (4 | 8 | 16 | 32)) = (4 | 8 | 16 | 32) and t.tgfoid = 'ops_freeze_v2.block_writes()'::regprocedure);
  insert into fz_results (check_name, result, detail) values ('EVERY table in the scope schemas has the enabled-ALWAYS BEFORE INSERT/UPDATE/DELETE/TRUNCATE statement trigger', case when v_bad = 0 and v_total > 0 then 'PASS' else 'FAIL' end,
    v_total::text || ' tables, ' || v_bad::text || ' uncovered (run 03_refresh_coverage.sql if migrations added tables)');
  select count(*) into v_bad from pg_trigger t where t.tgname = c_trigger and not t.tgisinternal and t.tgrelid not in (select table_oid from ops_freeze_v2.frozen_table where run_id = v_run);
  insert into fz_results (check_name, result, detail) values ('no freeze trigger exists outside the recorded tables', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text);

  insert into fz_results (check_name, result, detail) values ('the trigger function is SECURITY DEFINER with a pinned search_path and is not executable by API roles',
    case when exists (select 1 from pg_proc p where p.oid = 'ops_freeze_v2.block_writes()'::regprocedure and p.prosecdef and p.proconfig::text ilike '%search_path%')
          and not has_function_privilege('anon', 'ops_freeze_v2.block_writes()', 'execute') and not has_function_privilege('authenticated', 'ops_freeze_v2.block_writes()', 'execute')
          and not has_function_privilege('service_role', 'ops_freeze_v2.block_writes()', 'execute') and not has_schema_privilege('anon', 'ops_freeze_v2', 'usage')
          and not has_schema_privilege('authenticated', 'ops_freeze_v2', 'usage') and not has_schema_privilege('service_role', 'ops_freeze_v2', 'usage') then 'PASS' else 'FAIL' end, '');
  -- the decision the trigger takes, evaluated for the identities that matter (the SAME function the trigger calls)
  foreach v_role in array array['authenticator', 'anon', 'authenticated', 'service_role', 'pgbouncer', 'supabase_read_only_user'] loop
    insert into fz_results (check_name, result, detail) values ('session_user ' || v_role || ' is NOT exempt (writes blocked)', case when not ops_freeze_v2.session_is_exempt(v_role) then 'PASS' else 'FAIL' end, '');
  end loop;
  insert into fz_results (check_name, result, detail) values ('the operator session_user IS exempt (migrations keep working)', case when ops_freeze_v2.session_is_exempt(session_user::text) and session_user = v_op then 'PASS' else 'FAIL' end, session_user::text);
  select count(*) into v_bad from unnest(v_exempt) e join pg_roles ro on ro.rolname = e where e <> v_op and not ro.rolsuper;
  insert into fz_results (check_name, result, detail) values ('every exempt role is the operator or a superuser; none is an API/platform role', case when v_bad = 0 and not (v_exempt && array['authenticator','anon','authenticated','service_role','pgbouncer']) then 'PASS' else 'FAIL' end, v_exempt::text);

  insert into fz_results (check_name, result, detail) values ('non-freeze triggers on the scope tables are unchanged since the freeze started',
    case when ops_freeze_v2.fingerprint_triggers(v_scope) = v_pre_trig then 'PASS' when v_after_migrations then 'INFO' else 'FAIL' end,
    case when ops_freeze_v2.fingerprint_triggers(v_scope) = v_pre_trig then 'identical' else 'DIFFERENT (expected only after approved migrations)' end);
  insert into fz_results (check_name, result, detail) values ('table ACLs / owners / RLS flags of the scope objects are unchanged since the freeze started (the freeze grants and revokes nothing)',
    case when ops_freeze_v2.fingerprint_acl(v_scope) = v_pre_acl then 'PASS' when v_after_migrations then 'INFO' else 'FAIL' end,
    case when ops_freeze_v2.fingerprint_acl(v_scope) = v_pre_acl then 'identical' else 'DIFFERENT (expected only after approved migrations)' end);

  if v_cron then
    execute 'select count(*) from ops_freeze_v2.cron_state cs left join cron.job j on j.jobid = cs.job_id where cs.run_id = $1 and cs.paused_by_freeze and (j.jobid is null or j.active)' into v_bad using v_run;
    insert into fz_results (check_name, result, detail) values ('reviewed cron writers are paused (cron.job.active = false)', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text || ' still active');
    execute 'select count(*) from ops_freeze_v2.cron_state cs left join cron.job j on j.jobid = cs.job_id where cs.run_id = $1 and not cs.paused_by_freeze and (j.jobid is null or j.active is distinct from cs.prior_active)' into v_bad using v_run;
    insert into fz_results (check_name, result, detail) values ('jobs reviewed as non-writers were left exactly as they were', case when v_bad = 0 then 'PASS' else 'FAIL' end, v_bad::text || ' changed');
  else
    insert into fz_results (check_name, result, detail) values ('cron: pg_cron is not installed here (nothing to pause; cron NOT exercised)', 'INFO', '');
  end if;
  insert into fz_results (check_name, result, detail) values ('operator session can write and is not in recovery', case when current_setting('transaction_read_only') = 'off' and not pg_is_in_recovery() then 'PASS' else 'FAIL' end, session_user::text);
  insert into fz_results (check_name, result, detail) values ('INFO: sessions of the API login roles right now (any of them may be pooled; irrelevant to the trigger, listed for the record)', 'INFO',
    coalesce((select string_agg(usename || '=' || n, ', ') from (select a.usename::text as usename, count(*) as n from pg_stat_activity a where a.usename::text in ('authenticator', 'pgbouncer') group by 1) x), 'none'));

  -- REAL enforcement test on every frozen table: inside THIS transaction only, empty the exempt list so the operator session is treated like an API session, then run a zero-row
  -- DELETE (statement triggers fire for zero rows). Each must fail with SQLSTATE 25006 and the freeze marker text. The whole transaction is rolled back afterwards.
  update ops_freeze_v2.freeze_run set exempt_roles = array[]::text[] where run_id = v_run;
  v_bad := 0;
  for r in select f.schema_name, f.table_name from ops_freeze_v2.frozen_table f where f.run_id = v_run order by 1, 2 loop
    begin
      execute format('delete from %I.%I where false', r.schema_name, r.table_name);
      v_bad := v_bad + 1;
    exception when others then
      get stacked diagnostics v_msg = message_text;
      v_state := sqlstate;
      if not (v_state = '25006' and v_msg like 'TDP_MAINTENANCE_FREEZE:%') then v_bad := v_bad + 1; end if;
    end;
  end loop;
  insert into fz_results (check_name, result, detail) values ('the trigger really FIRES and BLOCKS on every frozen table when the session is not exempt (zero-row DELETE -> 25006 TDP_MAINTENANCE_FREEZE)',
    case when v_bad = 0 then 'PASS' else 'FAIL' end, (select count(*) from ops_freeze_v2.frozen_table where run_id = v_run)::text || ' tables probed, ' || v_bad::text || ' not blocked');
  update ops_freeze_v2.freeze_run set exempt_roles = v_exempt where run_id = v_run;   -- restored here as well as by the ROLLBACK below
end
$chk$;

select ord, check_name, result, detail from fz_results
union all select 9999, 'VERDICT', case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 'SQL_LAYER_OK__NOT_A_FREEZE_PROOF__EXTERNAL_API_PROBE_REQUIRED' else 'SQL_LAYER_FAIL' end,
       count(*) filter (where result = 'PASS')::text || ' passed, ' || count(*) filter (where result = 'FAIL')::text || ' failed. This script runs as the exempt operator and cannot observe the API path. Run hosted_test/api_freeze_probe.py --phase frozen; do NOT start migrations until it reports FREEZE_PROVEN.' from fz_results
order by 1;
rollback;
