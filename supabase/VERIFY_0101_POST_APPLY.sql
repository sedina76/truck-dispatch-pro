-- =============================================================================
-- VERIFY_0101_POST_APPLY.sql
-- Phase 2O.1 -- read-only post-apply verification for
-- supabase/migrations/0101_driver_photo_shareable_insert_grant.sql.
-- Run this immediately after applying 0101. Every query here is a plain
-- SELECT -- nothing here mutates anything.
-- =============================================================================

-- 1. authenticated now has INSERT(photo_shareable); SELECT/UPDATE unchanged.
select
  has_column_privilege('authenticated', 'public.drivers', 'photo_shareable', 'SELECT') as has_select,
  has_column_privilege('authenticated', 'public.drivers', 'photo_shareable', 'UPDATE') as has_update,
  has_column_privilege('authenticated', 'public.drivers', 'photo_shareable', 'INSERT') as has_insert_after_0101;
-- Expected: all three true.

-- 2. Sensitive encrypted columns still fully protected -- unchanged from
-- preflight, must all still be false.
select
  col,
  has_column_privilege('authenticated', 'public.drivers', col, 'SELECT') as can_select,
  has_column_privilege('authenticated', 'public.drivers', col, 'INSERT') as can_insert,
  has_column_privilege('authenticated', 'public.drivers', col, 'UPDATE') as can_update
from unnest(array['ssn_encrypted', 'direct_deposit_account_encrypted', 'direct_deposit_routing_encrypted']) as col;
-- Expected: every one of the 9 booleans is still false.

-- 3. RLS still enabled, unchanged.
select relrowsecurity as rls_enabled
from pg_class
where oid = 'public.drivers'::regclass;
-- Expected: true (unchanged from preflight).

-- 4. drivers_insert policy text is byte-for-byte unchanged from preflight
-- (compare this output against the preflight run's own output for the
-- same query -- 0101 contains no ALTER/DROP/CREATE POLICY statement at all).
select policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'drivers' and policyname = 'drivers_insert';

-- 5. No broad table-level INSERT was introduced -- confirm INSERT remains
-- column-scoped (no bare "INSERT" table privilege, only column-level
-- entries), and confirm the full INSERT-column set is now EXACTLY the
-- preflight set plus photo_shareable, nothing else.
select has_table_privilege('authenticated', 'public.drivers', 'INSERT') as has_bare_table_insert;
-- Expected: true -- NOTE this is expected to read true both before and
-- after 0101, and is NOT itself evidence of a broad grant: Postgres
-- reports has_table_privilege(...,'INSERT') = true whenever ANY
-- column-level INSERT grant exists on the table, by design (it answers
-- "can this role INSERT into this table at all, for at least one
-- column", not "does this role have grant on the whole row"). The real
-- test for "no broad/unscoped INSERT" is the column enumeration below:
-- if authenticated had been granted plain `GRANT INSERT ON public.drivers`
-- (unscoped), every column -- including the three encrypted ones --
-- would show has_column_privilege(...,'INSERT') = true. Query 2 above
-- already proves that is NOT the case.

select grantee, table_name, column_name, privilege_type
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'drivers' and grantee = 'authenticated' and privilege_type = 'INSERT'
order by column_name;
-- Expected: identical to the preflight run's own output for this same
-- query, PLUS exactly one new row: column_name = 'photo_shareable'. No
-- other row added or removed. No encrypted PII column present.

-- 6. Live functional check (informational, safe): confirms the exact
-- previously-failing insert shape now succeeds when performed with a
-- disposable value and is not committed (rolled back), without needing a
-- real driver/org fixture. Run only if you want an immediate functional
-- signal in addition to the privilege introspection above -- the real
-- acceptance matrix (Phase 2O.1 section 7) is more thorough and uses real
-- TEST-DRV0101-* fixtures instead.
-- begin;
--   savepoint pre_check;
--   -- this INSERT is expected to now raise a NOT NULL/FK violation on
--   -- organization_id/carrier_id (disposable, harmless) rather than the
--   -- old 42501 permission error -- the point is only to confirm the
--   -- COLUMN-PRIVILEGE check no longer fires first.
--   insert into public.drivers (organization_id, carrier_id, first_name, last_name, photo_shareable)
--   values ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-000000000000', 'zzz-preflight-check', 'zzz', false);
--   rollback to savepoint pre_check;
-- rollback;
