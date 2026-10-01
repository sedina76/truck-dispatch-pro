-- HOSTED NON-PRODUCTION CAPABILITY PROBE (tdp-freeze-test). Run ONCE in the SQL Editor of the NON-PRODUCTION test project only.
-- TEMPORARILY MUTATING, GUARANTEED ROLLED BACK: this is ONE statement (a DO block) that ALWAYS ends by raising an exception carrying the
-- report. A failed statement is rolled back atomically by PostgreSQL, so NOTHING it did (each probe is additionally wrapped in its own
-- sub-transaction that is also rolled back) can persist. The SQL Editor will show the report as an ERROR -- that is intended.
-- It never touches postgres/supabase_admin/auth/storage/realtime/replication/ETL roles, never sets default_transaction_read_only on pgbouncer,
-- terminates nothing, and creates no objects. authenticator is probed with the REAL freeze setting; pgbouncer only with a harmless custom parameter.
do $probe$
declare
  v_report text := '';
  v_before text; v_after text; v_in text;
  v_role text; v_ok boolean; v_state text; v_msg text;
  c_probe text[][] := array[['authenticator', 'default_transaction_read_only = on'], ['pgbouncer', 'tdp_freeze_probe.marker = ''1''']];
  i int;
begin
  v_report := format('PROBE REPORT (all changes rolled back) | db=%s | user=%s/%s | pg=%s | project-check: this must be tdp-freeze-test', current_database(), current_user, session_user, current_setting('server_version_num'));
  for i in 1 .. array_length(c_probe, 1) loop
    v_role := c_probe[i][1];
    if not exists (select 1 from pg_roles where rolname = v_role) then v_report := v_report || format(E'\n%s: role does not exist', v_role); continue; end if;
    select coalesce(string_agg(s.setdatabase::text || ':' || s.setconfig::text, ';' order by s.setdatabase), '(none)') into v_before
      from pg_db_role_setting s where s.setrole = (select oid from pg_roles where rolname = v_role);
    v_ok := false; v_state := null; v_msg := null; v_in := null;
    begin
      execute format('alter role %I set %s', v_role, c_probe[i][2]);
      select coalesce(string_agg(s.setdatabase::text || ':' || s.setconfig::text, ';' order by s.setdatabase), '(none)') into v_in
        from pg_db_role_setting s where s.setrole = (select oid from pg_roles where rolname = v_role);
      v_ok := true;
      raise exception 'PROBE_ROLLBACK' using errcode = 'P0001';   -- forces the sub-transaction to roll the ALTER back
    exception when others then
      if sqlerrm <> 'PROBE_ROLLBACK' then v_ok := false; v_state := sqlstate; v_msg := sqlerrm; end if;
    end;
    select coalesce(string_agg(s.setdatabase::text || ':' || s.setconfig::text, ';' order by s.setdatabase), '(none)') into v_after
      from pg_db_role_setting s where s.setrole = (select oid from pg_roles where rolname = v_role);
    v_report := v_report || format(E'\n%s: ALTER ROLE %s => %s%s | setting before=%s | inside probe=%s | after rollback=%s | restored_exactly=%s | postgres ADMIN on role=%s',
      v_role, c_probe[i][2], case when v_ok then 'ALLOWED' else 'DENIED' end, case when v_ok then '' else ' (' || v_state || ': ' || v_msg || ')' end,
      v_before, coalesce(v_in, 'n/a'), v_after, (v_before = v_after)::text, exists (select 1 from pg_auth_members m where m.roleid = (select oid from pg_roles where rolname = v_role) and m.member = (select oid from pg_roles where rolname = current_user) and m.admin_option)::text);
  end loop;
  v_report := v_report || format(E'\nplatform baseline: supabase_read_only_user default_transaction_read_only setting present=%s (expected true; never altered)',
    exists (select 1 from pg_db_role_setting s join pg_roles ro on ro.oid = s.setrole where ro.rolname = 'supabase_read_only_user' and 'default_transaction_read_only=on' = any(s.setconfig)));
  raise exception '%', v_report using errcode = 'P0001';
end
$probe$;
