-- Run AFTER applying 0117_quickbooks_customer_invoice_mapping.sql.
--
-- 100% READ-ONLY. No BEGIN/ROLLBACK, no fixtures, no writes. Every
-- statement is a catalog SELECT. Safe to run against production.
--
-- Expected result summary is under each query.

-- 1. Both tables exist in schema public.
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('quickbooks_customer_mappings', 'quickbooks_invoice_syncs')
order by table_name;
-- expect: exactly 2 rows -- quickbooks_customer_mappings, quickbooks_invoice_syncs.

-- 2. Named constraints are present.
select conrelid::regclass::text as table_name, conname, contype
from pg_constraint
where conrelid in ('public.quickbooks_customer_mappings'::regclass,
                   'public.quickbooks_invoice_syncs'::regclass)
  and conname in (
    'quickbooks_customer_mappings_local_unique',
    'quickbooks_customer_mappings_qbo_unique',
    'quickbooks_invoice_syncs_invoice_unique',
    'quickbooks_invoice_syncs_synced_shape'
  )
order by table_name, conname;
-- expect: 4 rows.
--   quickbooks_customer_mappings_local_unique  u
--   quickbooks_customer_mappings_qbo_unique    u
--   quickbooks_invoice_syncs_invoice_unique    u
--   quickbooks_invoice_syncs_synced_shape      c

-- 3. RLS is enabled (and not forced -- ordinary enable, so service_role bypasses).
select relname, relrowsecurity, relforcerowsecurity
from pg_class
where oid in ('public.quickbooks_customer_mappings'::regclass,
              'public.quickbooks_invoice_syncs'::regclass)
order by relname;
-- expect: both rows relrowsecurity = true, relforcerowsecurity = false.

-- 4. Policies: command, USING (qual), WITH CHECK. There must be exactly
--    3 policies per table (SELECT / INSERT / UPDATE), NO DELETE policy,
--    and every qual/with_check must contain BOTH current_org_id() AND
--    has_role('{owner,admin}').
select
  schemaname, tablename, policyname, cmd,
  qual        as using_expr,
  with_check  as with_check_expr
from pg_policies
where schemaname = 'public'
  and tablename in ('quickbooks_customer_mappings', 'quickbooks_invoice_syncs')
order by tablename, cmd, policyname;
-- expect: 6 rows total (3 per table). cmd values: SELECT, INSERT, UPDATE only.
--   SELECT : using_expr    has current_org_id() AND has_role('{owner,admin}'); with_check null
--   INSERT : with_check    has current_org_id() AND has_role('{owner,admin}'); using null
--   UPDATE : BOTH using_expr AND with_check_expr have current_org_id() AND has_role('{owner,admin}')
--   NO row with cmd = DELETE.

-- 5. Table privileges by grantee. authenticated must have SELECT/INSERT/
--    UPDATE and NOT DELETE; anon and PUBLIC must have nothing.
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('quickbooks_customer_mappings', 'quickbooks_invoice_syncs')
  and grantee in ('authenticated', 'anon', 'public')
order by table_name, grantee, privilege_type;
-- expect: for EACH table, grantee 'authenticated' -> exactly SELECT, INSERT, UPDATE
--   (3 rows, NO DELETE, NO TRUNCATE/REFERENCES/TRIGGER).
--   NO rows for grantee 'anon'. NO rows for grantee 'public'.

-- 5b. Explicit "does anon/public have ANYTHING" check (belt-and-suspenders).
select count(*) as anon_or_public_grants
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('quickbooks_customer_mappings', 'quickbooks_invoice_syncs')
  and grantee in ('anon', 'public');
-- expect: anon_or_public_grants = 0.

-- 6. Guard triggers exist, BEFORE INSERT OR UPDATE, row-level, enabled.
select
  tgrelid::regclass::text as table_name,
  tgname,
  tgenabled,                       -- 'O' = enabled (origin/local)
  pg_get_triggerdef(oid)           as definition
from pg_trigger
where tgrelid in ('public.quickbooks_customer_mappings'::regclass,
                  'public.quickbooks_invoice_syncs'::regclass)
  and not tgisinternal
order by table_name, tgname;
-- expect (per table): the set_updated_at trigger AND the guard trigger --
--   quickbooks_customer_mappings_guard  -> BEFORE INSERT OR UPDATE ... FOR EACH ROW
--                                          EXECUTE FUNCTION guard_quickbooks_customer_mapping()
--   quickbooks_invoice_syncs_guard      -> BEFORE INSERT OR UPDATE ... FOR EACH ROW
--                                          EXECUTE FUNCTION guard_quickbooks_invoice_sync()
--   all tgenabled = 'O'.

-- 7. Guard functions are NOT client-callable (EXECUTE revoked from
--    public/anon/authenticated).
select
  p.proname,
  coalesce(has_function_privilege('anon',          p.oid, 'EXECUTE'), false) as anon_can_exec,
  coalesce(has_function_privilege('authenticated', p.oid, 'EXECUTE'), false) as authd_can_exec
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('guard_quickbooks_customer_mapping', 'guard_quickbooks_invoice_sync')
order by p.proname;
-- expect: both rows anon_can_exec = false AND authd_can_exec = false.

-- 8. No token / secret columns leaked into these tables (name sniff).
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name in ('quickbooks_customer_mappings', 'quickbooks_invoice_syncs')
  and (column_name ilike '%token%' or column_name ilike '%secret%'
       or column_name ilike '%encrypt%' or column_name ilike '%password%'
       or column_name ilike '%access%' or column_name ilike '%refresh%')
order by table_name, column_name;
-- expect: at most the non-secret QuickBooks row-version columns
--   quickbooks_customer_mappings.quickbooks_sync_token (text)
--   quickbooks_invoice_syncs.quickbooks_sync_token (text)
--   -- these hold QuickBooks' optimistic-concurrency SyncToken, NOT an
--   -- OAuth/access/refresh token. NOTHING named *_encrypted / *secret /
--   -- *password / *access* / *refresh*.
