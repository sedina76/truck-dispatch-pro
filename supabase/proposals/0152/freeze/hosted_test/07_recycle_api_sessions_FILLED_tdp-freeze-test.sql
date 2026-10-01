-- FILLED FOR tdp-freeze-test ONLY. Terminates ONLY idle sessions of authenticator (never postgres, supabase_admin, pgbouncer or any platform role).
-- =============================================================================
-- 07_recycle_api_sessions_optional.sql -- OPTIONAL: terminate the idle pooled sessions of the listed API login role(s) (sessions only; no setting or data is touched)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION AS A FREEZE STEP. The v2 freeze does NOT need this (the trigger acts on statements, not sessions). Its purpose is the
-- hosted TEST: run api_freeze_probe.py --phase frozen --label pooled FIRST (existing connections), then this script, then --label new (new connections) so the probe can prove
-- that both populations are blocked. PostgREST reconnects by itself; the API has a brief blip. Never terminates: this session, the operator, superusers, or any role on the
-- never-terminate list (postgres, supabase_admin, pgbouncer, auth/storage/realtime/replication/ETL/read-only roles). Fill in the constants; empty/mismatching values abort.
-- =============================================================================
do $recycle$
declare
  v_operator_role constant text   := 'postgres';                        -- must equal current_user AND session_user
  v_confirm       constant text   := 'RECYCLE postgres';                        -- type exactly:  RECYCLE <database name>
  v_api_roles     constant text[] := array['authenticator'];           -- login role(s) whose sessions are recycled (hosted test: array['authenticator'])
  c_never constant text[] := array['postgres', 'supabase_admin', 'pgbouncer', 'supabase_auth_admin', 'supabase_storage_admin', 'supabase_realtime_admin', 'supabase_replication_admin',
                                   'supabase_etl_admin', 'supabase_privileged_role', 'supabase_read_only_user', 'dashboard_user', 'anon', 'authenticated', 'service_role'];
  r record; v_n integer := 0; v_fail integer := 0; v_role text;
begin
  if v_operator_role = '' or v_confirm = '' or cardinality(v_api_roles) = 0 then raise exception 'RECYCLE REFUSED: fill in v_operator_role, v_confirm and v_api_roles. Nothing was terminated.'; end if;
  if v_confirm <> 'RECYCLE ' || current_database() then raise exception 'RECYCLE REFUSED: v_confirm must be exactly ''RECYCLE %''. Nothing was terminated.', current_database(); end if;
  if current_user <> v_operator_role or session_user <> v_operator_role then raise exception 'RECYCLE REFUSED: run by %/% but v_operator_role is %. Nothing was terminated.', current_user, session_user, v_operator_role; end if;
  foreach v_role in array v_api_roles loop
    if v_role = any(c_never) or v_role = v_operator_role or exists (select 1 from pg_roles where rolname = v_role and rolsuper) or not exists (select 1 from pg_roles where rolname = v_role and rolcanlogin) then
      raise exception 'RECYCLE REFUSED: role % is the operator, a superuser, a never-terminate platform role, or not a login role. Nothing was terminated.', v_role;
    end if;
  end loop;
  for r in select a.pid from pg_stat_activity a join pg_roles ro on ro.oid = a.usesysid
            where coalesce(a.backend_type, 'client backend') = 'client backend' and a.pid <> pg_backend_pid() and a.usename::text = any(v_api_roles) and not ro.rolsuper loop
    if pg_terminate_backend(r.pid) then v_n := v_n + 1; else v_fail := v_fail + 1; end if;
  end loop;
  if v_fail > 0 then raise exception 'RECYCLE INCOMPLETE: % session(s) could not be signalled.', v_fail; end if;
  raise notice 'recycled % session(s) of %', v_n, v_api_roles;
end
$recycle$;
select 'RECYCLED' as result, (select count(*) from pg_stat_activity a where a.usename = 'authenticator' and coalesce(a.backend_type, 'client backend') = 'client backend') as authenticator_sessions_now,
       'NEXT: api_freeze_probe.py --phase frozen --label new --compare-pids <the pooled evidence file>' as next_step;
