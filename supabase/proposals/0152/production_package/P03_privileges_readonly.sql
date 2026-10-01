-- =============================================================================
-- P03_privileges_readonly.sql -- PRODUCTION READ-ONLY DISCOVERY, part 3: table/column/function privileges and exposure of trusted-null-uid paths.
-- PROPOSAL 0152 -- NOT RUN. Owner authorization + the project-reference check in README.md are REQUIRED before running anywhere.
-- ONE SELECT, catalog reads only (has_*_privilege() functions are read-only). Answers the adversarial-review question F-05: does anon (or service_role) hold EXECUTE
-- on SECURITY DEFINER functions that treat auth.uid() IS NULL as a trusted caller (e.g. public.record_unresolved_carrier_record)? Expected by the migrations: anon = false.
-- =============================================================================
with fn as (
  select p.oid, p.oid::regprocedure::text as sig, p.prosecdef, p.proowner::regrole::text as owner, p.proconfig, p.proacl,
         has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec,
         has_function_privilege('service_role', p.oid, 'EXECUTE') as svc_exec,
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')) as public_exec
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
),
rows as (
  select 10 as ord, 'FUNCTIONS SUMMARY' as section, 'public functions / SECURITY DEFINER / definer with anon EXECUTE / definer with PUBLIC EXECUTE / definer with service_role EXECUTE' as item,
         (select count(*) from fn)::text || ' / ' || (select count(*) from fn where prosecdef)::text || ' / ' || (select count(*) from fn where prosecdef and anon_exec)::text || ' / '
         || (select count(*) from fn where prosecdef and public_exec)::text || ' / ' || (select count(*) from fn where prosecdef and svc_exec)::text as detail
  union all select 20, 'SECURITY DEFINER WITH anon EXECUTE (must be NONE; investigate every row)', sig, format('owner=%s config=%s acl=%s', owner, coalesce(proconfig::text, '(none)'), coalesce(proacl::text, '(default)')) from fn where prosecdef and anon_exec
  union all select 21, 'SECURITY DEFINER WITH PUBLIC EXECUTE (must be NONE)', sig, format('owner=%s acl=%s', owner, coalesce(proacl::text, '(default)')) from fn where prosecdef and public_exec
  union all select 22, 'SECURITY DEFINER WITHOUT a pinned search_path (must be NONE)', sig, 'owner=' || owner from fn where prosecdef and not coalesce(proconfig::text ilike '%search_path%', false)
  union all select 23, 'SECURITY DEFINER search_path lacking pg_temp (informational; see adversarial finding F-17)', sig, proconfig::text from fn where prosecdef and proconfig::text ilike '%search_path%' and proconfig::text not ilike '%pg_temp%'
  union all select 24, 'SECURITY DEFINER with service_role EXECUTE (informational list)', sig, 'authenticated=' || auth_exec::text from fn where prosecdef and svc_exec
  union all select 30, 'TABLE PRIVILEGES to anon (any privilege; investigate every row)', n.nspname || '.' || c.relname,
         (select string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants g where g.table_schema = n.nspname and g.table_name = c.relname and g.grantee = 'anon')
         from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'p') and exists (select 1 from information_schema.role_table_grants g where g.table_schema = n.nspname and g.table_name = c.relname and g.grantee = 'anon')
  union all select 31, 'TABLE PRIVILEGES to authenticated (write privileges only)', c.relname::text,
         (select string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants g where g.table_schema = 'public' and g.table_name = c.relname and g.grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'))
         from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'public' and g.table_name = c.relname and g.grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'))
  union all select 32, 'COLUMN-LEVEL privileges of authenticated (tables that use column grants)', a.attrelid::regclass::text || '.' || a.attname, 'has UPDATE=' || has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE')::text
         from pg_attribute a where a.attrelid in (to_regclass('public.factoring_relationships'), to_regclass('public.carriers'), to_regclass('public.dispatches')) and a.attnum > 0 and not a.attisdropped and has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE')
  union all select 40, 'ROLE ATTRIBUTES (API/platform roles)', r.rolname::text, format('super=%s bypassrls=%s login=%s createrole=%s config=%s', r.rolsuper, r.rolbypassrls, r.rolcanlogin, r.rolcreaterole, coalesce(r.rolconfig::text, '(none)'))
         from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role', 'authenticator', 'postgres', 'supabase_admin', 'pgbouncer')
  union all select 50, 'INVOICE/PAYMENT/FACTORING TABLE DELETE privileges (cascade-history risk, finding F-23)', c.relname::text,
         'authenticated DELETE=' || has_table_privilege('authenticated', c.oid, 'DELETE')::text || ' service_role DELETE=' || has_table_privilege('service_role', c.oid, 'DELETE')::text
         from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('invoices', 'payments', 'factored_invoices', 'factoring_relationships', 'factoring_events', 'loads', 'dispatches', 'carriers')
)
select ord, section, item, detail from rows order by ord, section, item;
