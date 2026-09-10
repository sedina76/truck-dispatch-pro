-- Run AFTER applying 0118_quickbooks_payment_imports.sql.
--
-- 100% READ-ONLY. No BEGIN/ROLLBACK, no fixtures, no writes -- every
-- statement is a catalog SELECT. Safe to run against production.
--
-- Expected result is under each query.

-- 1. Table exists in schema public.
select table_name
from information_schema.tables
where table_schema = 'public' and table_name = 'quickbooks_payment_imports';
-- expect: 1 row.

-- 2. Full column shape: names, types, nullability, defaults.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'quickbooks_payment_imports'
order by ordinal_position;
-- expect: id uuid NO; organization_id uuid NO; quickbooks_payment_id text NO;
--   quickbooks_invoice_id text NO; local_invoice_id uuid NO;
--   local_payment_id uuid YES;  <-- nullable
--   applied_amount numeric NO; quickbooks_txn_date date YES;
--   quickbooks_reference text YES; quickbooks_payment_method text YES;
--   import_state text NO default 'pending'; reconciliation_state text NO default 'ok';
--   reconciliation_detail text YES; last_error text YES; last_verified_at timestamptz YES;
--   imported_by uuid YES; imported_at timestamptz YES;
--   created_at timestamptz NO; updated_at timestamptz NO.

-- 3. Named constraints (unique + check).
select conname, contype, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.quickbooks_payment_imports'::regclass
order by contype, conname;
-- expect (at least):
--   quickbooks_payment_imports_alloc_unique         u  UNIQUE (organization_id, quickbooks_payment_id, quickbooks_invoice_id)
--   quickbooks_payment_imports_local_payment_unique  u  UNIQUE (local_payment_id)
--   quickbooks_payment_imports_imported_shape        c  CHECK ((import_state <> 'imported') OR (local_payment_id IS NOT NULL))
--   applied_amount check                             c  CHECK (applied_amount > 0)
--   import_state check                               c  CHECK (import_state IN ('pending','imported','failed'))
--   reconciliation_state check                       c  CHECK (reconciliation_state IN ('ok','reconciliation_required'))
--   quickbooks_payment_id / quickbooks_invoice_id    c  CHECK (btrim(...) <> '')
--   primary key on id.

-- 4. Foreign keys + their ON DELETE actions.
--    confdeltype: a=NO ACTION, r=RESTRICT, c=CASCADE, n=SET NULL, d=SET DEFAULT.
select
  conname,
  pg_get_constraintdef(oid) as definition,
  confdeltype
from pg_constraint
where conrelid = 'public.quickbooks_payment_imports'::regclass and contype = 'f'
order by conname;
-- expect:
--   organization_id -> organizations(id)   confdeltype = 'c' (CASCADE)
--   local_invoice_id -> invoices(id)       confdeltype = 'r' (RESTRICT)
--   local_payment_id -> payments(id)       confdeltype = 'r' (RESTRICT)
--   imported_by     -> profiles(id)        confdeltype = 'n' (SET NULL)

-- 5. RLS enabled (not forced).
select relname, relrowsecurity, relforcerowsecurity
from pg_class
where oid = 'public.quickbooks_payment_imports'::regclass;
-- expect: relrowsecurity = true, relforcerowsecurity = false.

-- 6. Policies: exactly 3 (SELECT/INSERT/UPDATE), no DELETE; every
--    qual/with_check has current_org_id() AND has_role('{owner,admin}').
select policyname, cmd, qual as using_expr, with_check as with_check_expr
from pg_policies
where schemaname = 'public' and tablename = 'quickbooks_payment_imports'
order by cmd, policyname;
-- expect: 3 rows. SELECT: using has current_org_id()+has_role, with_check null.
--   INSERT: with_check has current_org_id()+has_role, using null.
--   UPDATE: BOTH using AND with_check have current_org_id()+has_role('{owner,admin}').
--   NO row with cmd = DELETE.

-- 7. Table privileges by grantee.
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'quickbooks_payment_imports'
  and grantee in ('authenticated', 'anon', 'public')
order by grantee, privilege_type;
-- expect: grantee 'authenticated' -> exactly SELECT, INSERT, UPDATE (3 rows, NO DELETE).
--   NO rows for 'anon'. NO rows for 'public'.

-- 7b. Belt-and-suspenders: anon/public grant count must be zero.
select count(*) as anon_or_public_grants
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'quickbooks_payment_imports'
  and grantee in ('anon', 'public');
-- expect: 0.

-- 8. Guard trigger: BEFORE INSERT OR UPDATE, row-level, enabled; plus the
--    set_updated_at trigger.
select tgname, tgenabled, pg_get_triggerdef(oid) as definition
from pg_trigger
where tgrelid = 'public.quickbooks_payment_imports'::regclass and not tgisinternal
order by tgname;
-- expect:
--   quickbooks_payment_imports_guard -> BEFORE INSERT OR UPDATE ... FOR EACH ROW
--                                       EXECUTE FUNCTION guard_quickbooks_payment_import()
--   set_updated_at -> BEFORE UPDATE ... FOR EACH ROW EXECUTE FUNCTION set_updated_at()
--   both tgenabled = 'O'.

-- 9. Guard function body (proves the three same-org checks) + it is NOT
--    client-callable.
select
  p.proname,
  pg_get_functiondef(p.oid) as body,
  coalesce(has_function_privilege('anon',          p.oid, 'EXECUTE'), false) as anon_can_exec,
  coalesce(has_function_privilege('authenticated', p.oid, 'EXECUTE'), false) as authd_can_exec,
  coalesce(has_function_privilege('public',        p.oid, 'EXECUTE'), false) as public_can_exec
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'guard_quickbooks_payment_import';
-- expect: 1 row. body contains:
--   - "invoices i ... i.organization_id = new.organization_id"
--   - "payments p ... p.organization_id = new.organization_id"
--   - "p.invoice_id = new.local_invoice_id"
--   anon_can_exec = false, authd_can_exec = false, public_can_exec = false.

-- 10. Indexes.
select indexname, indexdef
from pg_indexes
where schemaname = 'public' and tablename = 'quickbooks_payment_imports'
order by indexname;
-- expect: pkey on (id); unique index for _alloc_unique on
--   (organization_id, quickbooks_payment_id, quickbooks_invoice_id);
--   unique index for _local_payment_unique on (local_payment_id);
--   quickbooks_payment_imports_org_idx on (organization_id);
--   quickbooks_payment_imports_invoice_idx on (organization_id, local_invoice_id).

-- 11. No token/secret columns (name sniff).
select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'quickbooks_payment_imports'
  and (column_name ilike '%token%' or column_name ilike '%secret%'
       or column_name ilike '%encrypt%' or column_name ilike '%password%'
       or column_name ilike '%access%' or column_name ilike '%refresh%');
-- expect: 0 rows.
