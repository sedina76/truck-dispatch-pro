-- hosted_test/02_fixture_baseline_readonly.sql -- READ-ONLY (one SELECT; changes nothing, does not call nextval or the RPC).
-- Fingerprint of the synthetic fixture: run BEFORE the freeze (baseline), right after the freeze is enabled/verified (must be IDENTICAL: nothing wrote),
-- and after the freeze is disabled and the deliberate write probes are done (row_count / max_id / sequence intentionally change; grants, owner, RLS must not).
select current_database() as db,
       to_regclass('public.freeze_probe_items') is not null as table_exists,
       to_regprocedure('public.freeze_probe_write()') is not null as rpc_exists,
       (select count(*) from public.freeze_probe_items) as row_count,
       (select coalesce(max(id), 0) from public.freeze_probe_items) as max_id,
       (select md5(coalesce(string_agg(id::text || '|' || note || '|' || created_at::text, ';' order by id), '')) from public.freeze_probe_items) as rows_md5,
       (select last_value from pg_sequences where schemaname = 'public' and sequencename = 'freeze_probe_items_id_seq') as sequence_last_value,
       (select coalesce(bool_or(rowsecurity), false) from pg_tables where schemaname = 'public' and tablename = 'freeze_probe_items') as rls_enabled,
       (select tableowner from pg_tables where schemaname = 'public' and tablename = 'freeze_probe_items') as table_owner,
       (select md5(coalesce(relacl::text, '')) from pg_class where oid = to_regclass('public.freeze_probe_items')) as table_acl_md5,
       (select md5(coalesce(proacl::text, '') || '|' || prosecdef::text || '|' || pg_get_userbyid(proowner) || '|' || coalesce(proconfig::text, ''))
          from pg_proc where oid = to_regprocedure('public.freeze_probe_write()')) as rpc_acl_definer_md5,
       (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname like 'freeze\_probe%' and c.relkind in ('r','S')) as fixture_relations;
