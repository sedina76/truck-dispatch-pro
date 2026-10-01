-- hosted_test/03_diagnostic_function.sql -- NON-PRODUCTION ONLY. Creates ONE read-only diagnostic function (writes nothing) so the external probe can record which backend served
-- a request and which session/transaction settings that backend had. Persistent in the test project until 99_synthetic_cleanup.sql drops it. Volatile on purpose so PostgREST
-- runs it as a POST (write-mode) transaction -- the same transaction mode as the write probes.
create or replace function public.freeze_probe_diag() returns jsonb language sql volatile security invoker set search_path = pg_catalog, public as
$$ select jsonb_build_object(
     'session_user', session_user, 'current_user', current_user,
     'default_transaction_read_only', current_setting('default_transaction_read_only'),
     'transaction_read_only', current_setting('transaction_read_only'),
     'pid', pg_backend_pid(),
     'backend_start', (select a.backend_start from pg_stat_activity a where a.pid = pg_backend_pid()),
     'application_name', current_setting('application_name', true)) $$;
grant execute on function public.freeze_probe_diag() to anon, authenticated, service_role;
select to_regprocedure('public.freeze_probe_diag()') is not null as diag_function_created;
