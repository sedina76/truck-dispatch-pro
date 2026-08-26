-- =============================================================================
-- VERIFY_0094_PREFLIGHT.sql
-- Phase 2M.1A -- read-only preflight for 0094_broker_permanent_delete_boundary.
-- Run every query below BEFORE applying 0094. None of these mutate data.
-- Expected results are noted per block; anything else means the live
-- database has drifted from the assumptions the migration was written
-- against, and 0094 should be re-reviewed before applying.
-- =============================================================================

-- 1. Confirm the raw-delete policy this migration removes actually exists
-- as expected (owner/admin, org-scoped -- exactly the 0010 standard_tables
-- shape). Expect exactly 1 row.
select polname, cmd, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'brokers' and polname = 'brokers_delete';

-- 2. Confirm `authenticated` currently holds table-level DELETE on brokers
-- (the grant 0094 revokes). Expect 1 row with privilege_type = 'DELETE'.
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'brokers'
  and grantee = 'authenticated' and privilege_type = 'DELETE';

-- 3. Confirm delete_broker_safely() exists today with the signature 0094
-- expects to replace. Expect 1 row.
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'delete_broker_safely';

-- 4. Confirm the six protected-history relationships exist with the exact
-- column names the shared predicate assumes. Expect 6 rows, one per table.
select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'loads' and column_name = 'broker_id') or
    (table_name = 'invoices' and column_name = 'broker_id') or
    (table_name = 'documents' and column_name in ('entity_type','entity_id')) or
    (table_name = 'statements' and column_name = 'broker_id') or
    (table_name = 'carrier_setup_packages' and column_name = 'broker_id') or
    (table_name = 'email_send_log' and column_name = 'broker_id')
  )
order by table_name, column_name;

-- 5. Confirm no DELETE trigger already exists on public.brokers (so 0094's
-- new trigger name is not colliding with, or duplicating, something else).
-- Expect 0 rows.
select tgname, tgtype
from pg_trigger
where tgrelid = 'public.brokers'::regclass
  and not tgisinternal
  and tgname = 'guard_broker_permanent_delete_trigger';

-- 5b. Full inventory of every non-internal trigger currently on
-- public.brokers, for context. Expect to see only
-- brokers_archive_boundary_guard (0093) and the broker_financials-syncing
-- AAI trigger from 0067 (whatever it is currently named) -- no delete
-- trigger.
select tgname, case tgtype & 66 when 2 then 'BEFORE' when 64 then 'INSTEAD OF' else 'AFTER' end as timing,
       case when tgtype & 8 <> 0 then 'DELETE' when tgtype & 4 <> 0 then 'INSERT' when tgtype & 16 <> 0 then 'UPDATE' end as event
from pg_trigger
where tgrelid = 'public.brokers'::regclass and not tgisinternal;

-- 6. Current RPC execute grants for the functions this migration touches.
-- Expect delete_broker_safely: authenticated only (no public/anon).
-- broker_has_protected_history should not exist yet (0 rows) since it's
-- new in 0094.
select p.proname, r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join aclexplode(p.proacl) a on true
join pg_roles r on r.oid = a.grantee
where n.nspname = 'public' and p.proname in ('delete_broker_safely','broker_has_protected_history')
order by p.proname, r.rolname;

-- 7. Current RLS state on public.brokers. Expect rowsecurity = true.
select relname, relrowsecurity, relforcerowsecurity
from pg_class
where oid = 'public.brokers'::regclass;

-- 8. Inventory of brokers currently carrying protected history (read-only;
-- confirms which live rows would be refused by delete_broker_safely() /
-- the new trigger today, and which are currently "clean" -- do NOT act on
-- this list, it is informational only).
select
  b.id, b.company_name, b.organization_id,
  exists(select 1 from public.loads l where l.broker_id = b.id) as has_loads,
  exists(select 1 from public.invoices i where i.broker_id = b.id) as has_invoices,
  exists(select 1 from public.documents d where d.entity_type = 'broker' and d.entity_id = b.id) as has_documents,
  exists(select 1 from public.statements s where s.broker_id = b.id) as has_statements,
  exists(select 1 from public.carrier_setup_packages c where c.broker_id = b.id) as has_setup_packages,
  exists(select 1 from public.email_send_log e where e.broker_id = b.id) as has_email_log
from public.brokers b
order by b.company_name;

-- =============================================================================
-- Phase 2M.1B additions -- broker-document referential lock preflight.
-- =============================================================================

-- 9. Confirm no existing entity_type='broker' documents row is already
-- orphaned or cross-org (informational -- this migration does not touch
-- historical data even if it finds any; live scan on 2026-08-22 found 0
-- rows of this type at all, so this is expected to return 0 rows).
select d.id, d.organization_id, d.entity_id,
       b.id is null as orphaned,
       (b.id is not null and b.organization_id <> d.organization_id) as cross_org_mismatch
from public.documents d
left join public.brokers b on b.id = d.entity_id
where d.entity_type = 'broker'
  and (b.id is null or b.organization_id <> d.organization_id);

-- 10. Confirm no trigger with these names already exists on public.documents
-- (collision check). Expect 0 rows.
select tgname from pg_trigger
where tgrelid = 'public.documents'::regclass and not tgisinternal
  and tgname in ('guard_broker_document_link_insert','guard_broker_document_link_update');

-- 11. Confirm guard_broker_document_link() does not already exist. Expect
-- 0 rows (new in this migration).
select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'guard_broker_document_link';
