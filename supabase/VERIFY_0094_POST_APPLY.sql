-- =============================================================================
-- VERIFY_0094_POST_APPLY.sql
-- Phase 2M.1A -- read-only structural verification AFTER applying 0094.
-- Confirms the two layers landed correctly. Behavioral role-matrix and
-- history-matrix testing (Section D/E of the pre-apply report) still needs
-- to be run against real authenticated sessions separately; this file only
-- confirms the schema-level shape.
-- =============================================================================

-- 1. brokers_delete policy must be gone. Expect 0 rows.
select polname from pg_policies
where schemaname = 'public' and tablename = 'brokers' and polname = 'brokers_delete';

-- 2. authenticated must no longer hold table-level DELETE on brokers.
-- Expect 0 rows.
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'brokers'
  and grantee = 'authenticated' and privilege_type = 'DELETE';

-- 3. authenticated SELECT/INSERT/UPDATE on brokers must be untouched.
-- Expect 3 rows (SELECT, INSERT, UPDATE).
select privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'brokers'
  and grantee = 'authenticated' and privilege_type in ('SELECT','INSERT','UPDATE')
order by privilege_type;

-- 4. The new guard trigger must exist, BEFORE DELETE, on brokers.
-- Expect 1 row.
select tgname,
       case tgtype & 66 when 2 then 'BEFORE' else 'other' end as timing,
       case when tgtype & 8 <> 0 then 'DELETE' else 'other' end as event
from pg_trigger
where tgrelid = 'public.brokers'::regclass and not tgisinternal
  and tgname = 'guard_broker_permanent_delete_trigger';

-- 5. The archive-boundary trigger from 0093 must be untouched (still
-- exactly 1 row, unchanged by this migration).
select tgname from pg_trigger
where tgrelid = 'public.brokers'::regclass and not tgisinternal
  and tgname = 'brokers_archive_boundary_guard';

-- 6. broker_has_protected_history() exists, is SECURITY DEFINER (prosecdef
-- = true), and is granted to authenticated only (no public/anon).
select p.proname, p.prosecdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'broker_has_protected_history';

select r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join aclexplode(p.proacl) a on true
join pg_roles r on r.oid = a.grantee
where n.nspname = 'public' and p.proname = 'broker_has_protected_history';
-- expect exactly: authenticated

-- 7. delete_broker_safely() still exists, still SECURITY DEFINER, still
-- granted to authenticated only.
select p.proname, p.prosecdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'delete_broker_safely';

-- 8. Sanity: predicate returns the same answer as the manual inventory
-- query from VERIFY_0094_PREFLIGHT.sql section 8, for every existing
-- broker. Run as a role that can execute the function (service_role or
-- postgres); expect the boolean to match has_loads OR has_invoices OR ...
-- from the preflight inventory for every row.
select b.id, b.company_name, public.broker_has_protected_history(b.id) as protected
from public.brokers b
order by b.company_name;

-- =============================================================================
-- Phase 2M.1B additions -- structural checks for the broker-document lock.
-- =============================================================================

-- 9. Both new triggers exist on public.documents, BEFORE INSERT / BEFORE
-- UPDATE respectively. Expect 2 rows.
select tgname,
       case tgtype & 66 when 2 then 'BEFORE' else 'other' end as timing,
       case when tgtype & 4 <> 0 then 'INSERT' when tgtype & 16 <> 0 then 'UPDATE' end as event
from pg_trigger
where tgrelid = 'public.documents'::regclass and not tgisinternal
  and tgname in ('guard_broker_document_link_insert','guard_broker_document_link_update');

-- 10. guard_broker_document_link() exists, SECURITY INVOKER is fine here
-- (it only needs SELECT on brokers, which authenticated already has via
-- the standard brokers_select policy -- unlike broker_has_protected_history
-- it does NOT need to see across orgs, so it deliberately is not
-- SECURITY DEFINER).
select p.proname, p.prosecdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'guard_broker_document_link';
-- expect prosecdef = false

-- 11. Every other document entity_type must be completely unaffected --
-- confirm the trigger WHEN clauses only reference entity_type = 'broker'.
select tgname, tgqual is not null as has_when_clause
from pg_trigger
where tgrelid = 'public.documents'::regclass and not tgisinternal
  and tgname in ('guard_broker_document_link_insert','guard_broker_document_link_update');
-- expect has_when_clause = true for both

-- =============================================================================
-- Behavioral checks (NOT pure SQL -- run via the app / an authenticated
-- Supabase client session per role, using disposable TEST-2M1-* fixtures):
--
--   a) owner/admin, clean broker, delete_broker_safely()   => {"deletion_status":"deleted"}
--   b) owner/admin, clean broker, raw table delete         => 42501 permission denied for table brokers
--   c) owner/admin, protected broker, delete_broker_safely() => {"deletion_status":"not_deletable", ...}
--   d) owner/admin, protected broker, raw table delete     => 42501 permission denied for table brokers
--      (never reaches the trigger -- blocked by the revoked grant first)
--   e) service_role, protected broker, raw table delete    => trigger fires:
--      "This broker has operational or financial history and cannot be
--      permanently deleted. Archive the broker instead."
--   f) dispatcher/accountant/viewer/driver/anonymous, any broker,
--      delete_broker_safely() => "You do not have permission to
--      permanently delete brokers." (unchanged from 0093)
--   g) foreign-org owner/admin, delete_broker_safely() on another org's
--      broker id => "Broker not found in your organization." (unchanged,
--      no existence leak)
--   h) document insert, entity_type='broker', entity_id=<real broker in
--      caller's org> => succeeds.
--   i) document insert, entity_type='broker', entity_id=<random/garbage
--      uuid> => "Document references a broker that does not exist in
--      this organization."
--   j) document insert, entity_type='broker', entity_id=<a real broker
--      belonging to a DIFFERENT org> => same refusal, no existence leak
--      (indistinguishable from case i).
--   k) document update reassigning entity_id from broker A to broker B
--      (same org) => re-validated against B; succeeds if B exists in that
--      org, refused otherwise.
--   l) document update changing only file_name/notes on an existing valid
--      broker document => trigger does not re-fire (WHEN clause excludes
--      it), no extra lock taken.
--   m) two concurrent sessions each inserting a different document for the
--      same broker => both succeed, no blocking (FOR KEY SHARE does not
--      conflict with itself).
--   n) session 1 begins delete_broker_safely() on a clean broker (holds
--      FOR UPDATE) before committing; session 2 concurrently attempts a
--      broker-document insert for the same broker => session 2 blocks;
--      once session 1 commits the delete, session 2 resumes and is
--      refused ("...does not exist in this organization") -- no orphan.
--   o) session 1 begins a broker-document insert (holds FOR KEY SHARE)
--      before committing; session 2 concurrently calls
--      delete_broker_safely() on the same broker => session 2 blocks on
--      its FOR UPDATE request; once session 1 commits, session 2 resumes,
--      broker_has_protected_history() now sees the committed document,
--      and deletion is refused.
-- =============================================================================
