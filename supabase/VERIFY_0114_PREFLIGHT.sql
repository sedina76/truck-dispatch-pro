-- Run BEFORE applying 0114_organization_scoped_load_numbers.sql.
--
-- Purpose: confirm the CURRENT (pre-0114) state, and surface the exact
-- counter-initialization collision risk this migration's own backfill
-- must account for -- rather than assuming either from reading the code.
-- Read-only except for one disposable, rolled-back fixture block at the
-- very end (matching the established VERIFY_0113_PREFLIGHT.sql pattern);
-- everything is discarded by the unconditional ROLLBACK.

begin;

-- 1. Confirm load_number_counters, allocate_load_number(), and the
--    change-guard trigger/RPC do NOT exist yet -- this migration must be
--    the one that introduces them, not a duplicate of something already
--    live. (loads_guard_load_number_immutable is the ORIGINAL, first-draft
--    trigger name -- superseded, before ever being applied, by
--    loads_guard_load_number_change/change_load_number in the revision
--    that adds the controlled Owner/Admin override -- checked here too,
--    purely so this preflight still reports 0 for it regardless of which
--    draft of 0114 someone might be comparing against.)
select
  (select count(*) from pg_tables where schemaname = 'public' and tablename = 'load_number_counters') as counter_table_exists,
  (select count(*) from pg_proc where proname = 'allocate_load_number' and pronamespace = 'public'::regnamespace) as allocator_exists,
  (select count(*) from pg_trigger where tgname = 'loads_guard_load_number_immutable') as old_immutability_trigger_exists,
  (select count(*) from pg_trigger where tgname = 'loads_guard_load_number_change') as change_guard_trigger_exists,
  (select count(*) from pg_proc where proname = 'change_load_number' and pronamespace = 'public'::regnamespace) as change_load_number_rpc_exists;
-- expect: 0, 0, 0, 0, 0

-- 2. Confirm the live create_load_with_stops() still reads load_number
--    from the client-supplied p_load JSON (the exact behavior 0114 must
--    remove).
select pg_get_functiondef(oid) like '%load_number%p_load%'
    or pg_get_functiondef(oid) like '%p_load ->> ''load_number''%' as still_reads_client_load_number
from pg_proc where proname = 'create_load_with_stops' and pronamespace = 'public'::regnamespace;
-- expect: true

-- 3. Confirm today's unique constraint backstop already exists (0004) --
--    0114 relies on this remaining in place, not on introducing it.
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.loads'::regclass and contype = 'u' and pg_get_constraintdef(oid) ilike '%load_number%';
-- expect: one row, unique(organization_id, load_number) (or equivalent index-backed constraint)

-- 3b. OLD RPC SIGNATURE AUDIT (hardening pass, requirement 1): enumerate
--     every overload of create_load_with_stops that currently exists in
--     THIS database, by exact argument signature -- confirms there is
--     only the one (p_load jsonb, p_stops jsonb) shape 0114 will replace,
--     never a second legacy overload (e.g. a positional p_load_number
--     parameter) that 0114 would need to explicitly DROP FUNCTION or that
--     could remain callable afterward with a client-supplied number
--     honored. Also confirms the pre-apply function is still plain
--     INVOKER (prosecdef = false) -- 0114 flips this to SECURITY DEFINER,
--     so this row is the "before" baseline to compare against post-apply.
select
  p.oid::regprocedure as exact_overload_signature,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as is_security_definer
from pg_proc p
where p.proname = 'create_load_with_stops' and p.pronamespace = 'public'::regnamespace;
-- expect: exactly ONE row, identity_arguments = 'jsonb, jsonb', is_security_definer = false

-- 3c. OWNERSHIP-CONSISTENCY CHECK (hardening pass, requirement 2): 0114's
--     privilege design depends on allocate_load_number() and (post-apply)
--     create_load_with_stops() sharing the SAME owner as the rest of this
--     schema's SECURITY DEFINER helpers -- that shared ownership is what
--     lets create_load_with_stops() call allocate_load_number() with NO
--     explicit grant at all (owners always have implicit EXECUTE on what
--     they own). Confirm that assumption actually holds in THIS database
--     before relying on it.
select proname, proowner::regrole as owner
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('current_org_id', 'has_role', 'generate_invoice_number', 'log_activity', 'create_load_with_stops')
order by proname;
-- REVIEW: every row's "owner" column must be IDENTICAL. If any differs,
-- STOP before applying 0114 -- the no-explicit-grant design in section 2
-- of this migration's own header comment would not work as written, and
-- an explicit grant (or a corrected owner) would need to be added first.

-- 4. COLLISION-RISK REPORT (Section 6): every organization with at least
--    one EXISTING load_number matching the exact 6-digit shape the new
--    counter format uses (^LD-[0-9]{6}$) -- these are exactly the
--    organizations whose counter the migration's backfill will seed above
--    zero, and are the ones to double check post-apply. An organization
--    NOT listed here starts fresh at LD-000001 on its first real
--    allocation with zero risk.
select
  l.organization_id,
  o.name as organization_name,
  count(*) as matching_load_count,
  max(substring(l.load_number from 4)::integer) as highest_matching_number,
  'LD-' || lpad((max(substring(l.load_number from 4)::integer) + 1)::text, 6, '0') as next_number_after_backfill
from public.loads l
join public.organizations o on o.id = l.organization_id
where l.load_number ~ '^LD-[0-9]{6}$'
group by l.organization_id, o.name
order by matching_load_count desc;
-- REVIEW THIS OUTPUT BEFORE APPLYING. Any organization listed here already
-- has 6-digit-format load numbers (whether genuinely sequential historical
-- loads, or a coincidentally-matching seed/test value like LD-100001) --
-- the backfill will start that organization's counter just past its
-- highest one, per spec ("start after the highest valid existing
-- number... ignore nonstandard/test numbers"). A load_number of a
-- DIFFERENT shape (5 digits, 7 digits, a non-numeric suffix, etc.) is
-- correctly excluded from this report and from the backfill calculation.
--
-- HARDENING PASS, requirement 4 (counter initialization report for the
-- pilot organization): this author has no live database access (this
-- entire engagement runs with zero SQL execution capability -- every
-- script here is written for the user to run in the Supabase SQL Editor),
-- so the pilot organization's actual row cannot be read and quoted in
-- this report ahead of time. Find that organization's own row in the
-- output above by its organization_name -- its highest_matching_number
-- and next_number_after_backfill columns ARE the exact, explicit answer
-- requested: "the exact highest matching historical LD-[0-9]{6} number"
-- and "the exact first generated number after applying 0114," for that
-- specific organization. Approve (or object to) that specific number
-- before applying -- the initialization RULE itself is intentionally
-- unchanged in this hardening pass, per instruction.

-- 4b. PILOT ORGANIZATION, isolated (Northbound Logistics, the seed data's
--     demo org -- supabase/seed/seed.sql line 53 --
--     11111111-0000-0000-0000-000000000001): the same computation as
--     section 4 above, narrowed to just this one organization_id so its
--     specific highest_matching_number/proposed_first_automatic_number
--     can be read and approved on its own, without scanning the full
--     cross-organization report for its row. Equivalent to section 4's
--     own calculation -- substring(load_number from '^LD-([0-9]{6})$')
--     (a regex capture group) and substring(load_number from 4)
--     (positional) extract the identical 6-digit value for any row
--     already matching ^LD-[0-9]{6}$; coalesce(..., 0) additionally
--     handles "no matching row at all yet" by proposing LD-000001,
--     matching what a brand-new counter row would produce on first use.
with valid_numbers as (
  select
    organization_id,
    substring(load_number from '^LD-([0-9]{6})$')::integer as number_value
  from public.loads
  where organization_id = '11111111-0000-0000-0000-000000000001'::uuid
    and load_number ~ '^LD-[0-9]{6}$'
)
select
  '11111111-0000-0000-0000-000000000001'::uuid as organization_id,
  coalesce(max(number_value), 0) as highest_matching_number,
  'LD-' || lpad((coalesce(max(number_value), 0) + 1)::text, 6, '0')
    as proposed_first_automatic_number
from valid_numbers;
-- REVIEW: this is the exact, explicit number to approve before applying
-- 0114, for this specific organization.

-- 5. For contrast/completeness: every load_number that will be correctly
--    EXCLUDED from the backfill calculation (does not match the 6-digit
--    shape) -- confirms "nonstandard/test numbers" really are being
--    ignored, not silently included.
select organization_id, load_number
from public.loads
where load_number !~ '^LD-[0-9]{6}$'
order by organization_id, load_number;
-- Expect: any load_number with a different digit count or non-numeric
-- content (e.g. a 5-digit legacy number). These rows are NEVER read,
-- modified, or renamed by 0114 -- listed here purely so their exclusion
-- from the counter calculation above can be visually confirmed.

-- 5b. REVISION 2 READINESS REPORT: the post-apply script's controlled-
--     override test suite (owner/admin/dispatcher/cross-org scenarios)
--     impersonates REAL, EXISTING profiles by role -- it cannot fabricate
--     one. Any role listed with zero here means that specific post-apply
--     test will report SKIPPED (not FAIL) rather than exercise real
--     role-based enforcement live; not a blocker, just worth knowing
--     ahead of time.
select role, count(*) as profile_count, count(distinct organization_id) as distinct_organizations
from public.profiles
where role in ('owner', 'admin', 'dispatcher')
group by role
order by role;
-- REVIEW: ideally at least one 'owner', one 'admin' (same organization as
-- the owner, for the "admin may also change it" test to run against the
-- same fixture), one 'dispatcher', and a second organization's own
-- owner/admin (for the cross-organization test) all exist.

-- 6. Disposable fixture check: confirm a plain client-supplied load_number
--    insert still works today (the pre-fix baseline createLoadWithStops()
--    RPC path currently allows), and that two different organizations can
--    each independently hold their own "LD-000001"-shaped value with no
--    cross-organization uniqueness conflict (today's unique constraint is
--    already organization-scoped, not global -- confirms the baseline
--    this migration must preserve, not merely target).
do $$
declare
  v_org_a uuid;
  v_org_b uuid;
begin
  select id into v_org_a from public.organizations order by created_at limit 1;
  select id into v_org_b from public.organizations order by created_at offset 1 limit 1;
  if v_org_a is null then
    raise exception 'No organization exists to scope disposable test fixtures under -- cannot run this verification.';
  end if;

  insert into public.loads (organization_id, load_number, status, booked_by)
  values (v_org_a, 'TEST-0114-PRE-A', 'draft', null);
  raise notice 'PREFLIGHT: client-supplied load_number insert SUCCEEDED for org A (expected before 0114 -- the gap this migration closes).';

  if v_org_b is not null then
    begin
      insert into public.loads (organization_id, load_number, status, booked_by) values (v_org_a, 'TEST-0114-SHARED', 'draft', null);
      insert into public.loads (organization_id, load_number, status, booked_by) values (v_org_b, 'TEST-0114-SHARED', 'draft', null);
      raise notice 'PREFLIGHT: identical load_number value accepted independently for two different organizations -- confirms uniqueness is already organization-scoped, not global (baseline 0114 must preserve).';
    exception when others then
      raise notice 'PREFLIGHT: UNEXPECTED -- identical load_number across two organizations was rejected (%). Investigate the existing unique constraint''s scope before proceeding.', sqlerrm;
    end;
  else
    raise notice 'PREFLIGHT: only one organization exists in this database -- the two-organizations-independent-numbering scenario cannot be exercised here; re-run this check post-apply once a second organization exists, or accept the migration''s own POST_APPLY script as sufficient coverage.';
  end if;
end $$;

-- Discards every fixture created above, unconditionally. Nothing from
-- this script persists.
rollback;
