-- =============================================================================
-- 03_refresh_coverage.sql -- DATABASE FREEZE v2, STEP 3: COVER TABLES CREATED SINCE THE FREEZE STARTED (mutating, one transaction, idempotent)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION.
-- Migrations applied while frozen (0130..0152) may create NEW tables in the scope schemas; those have no trigger yet and would be writable through the API. Run this after
-- EVERY migration that creates a table (and once more before disabling). It adds the same trigger to every scope table that lacks it, records them, and changes nothing else.
-- Nothing to fill in: it reads the active run. Aborts (nothing changed) if there is no active run, the operator differs, or a table cannot be locked within 5 s.
-- =============================================================================
begin;
do $refresh$
declare
  v_run uuid; v_scope text[]; v_operator text; r record; v_added integer := 0;
  c_trigger constant text := '0_ops_freeze_block_writes';
begin
  select run_id, scope_schemas, operator into v_run, v_scope, v_operator from ops_freeze_v2.freeze_run where status = 'frozen' order by started_at desc limit 1;
  if v_run is null then raise exception 'REFRESH REFUSED: no active freeze run. Nothing was changed.'; end if;
  if current_user <> v_operator or session_user <> v_operator then raise exception 'REFRESH REFUSED: run by % but the freeze operator is %. Nothing was changed.', session_user, v_operator; end if;
  perform set_config('lock_timeout', '5s', true);
  for r in select s.* from ops_freeze_v2.scope_tables(v_scope) s
            where not exists (select 1 from pg_trigger t where t.tgrelid = s.oid and t.tgname = c_trigger and not t.tgisinternal) order by s.schema_name, s.table_name loop
    if not pg_has_role(current_user, (select relowner from pg_class where oid = r.oid), 'USAGE') then
      raise exception 'REFRESH REFUSED: the operator cannot create a trigger on %.% (not owner). Nothing was changed.', r.schema_name, r.table_name;
    end if;
    execute format('create trigger %I before insert or update or delete or truncate on %I.%I for each statement execute function ops_freeze_v2.block_writes()', c_trigger, r.schema_name, r.table_name);
    execute format('alter table %I.%I enable always trigger %I', r.schema_name, r.table_name, c_trigger);
    insert into ops_freeze_v2.frozen_table (run_id, schema_name, table_name, table_oid) values (v_run, r.schema_name, r.table_name, r.oid) on conflict do nothing;
    v_added := v_added + 1;
  end loop;
  update ops_freeze_v2.freeze_run set table_count = (select count(*) from ops_freeze_v2.frozen_table where run_id = v_run) where run_id = v_run;
  raise notice 'REFRESH: % new table(s) covered', v_added;
end
$refresh$;
commit;

-- OPERATOR-VISIBLE RESULT
select 'COVERAGE_REFRESHED' as result, r.run_id, r.table_count as tables_frozen,
       (select count(*) from ops_freeze_v2.scope_tables(r.scope_schemas) s where not exists (select 1 from pg_trigger t where t.tgrelid = s.oid and t.tgname = '0_ops_freeze_block_writes' and t.tgenabled = 'A')) as uncovered_tables,
       'NEXT: run 04_verify_freeze_sql_layer.sql (set v_after_migrations := true if migrations ran since the freeze started)' as next_step
from ops_freeze_v2.freeze_run r where r.status = 'frozen' order by r.started_at desc limit 1;
