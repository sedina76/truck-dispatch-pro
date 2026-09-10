-- =============================================================================
-- CLEANUP_TEST_2N4_FIXTURES.sql (revised, Phase 2N.4A safety hardening)
-- OPTIONAL, one-off manual cleanup -- NOT a migration, no schema/behavior
-- change. Removes the disposable TEST-2N4-* fixtures created during Phase
-- 2N.4's live 0100 acceptance testing that could NOT be removed through
-- any application-sanctioned path, by design:
--
--   - broker_packet_items_immutability_guard (0095/0098) refuses DELETE on
--     any broker_packet_items row once its packet has left 'draft' --
--     "Items may only be removed while a broker packet is in draft."
--   - That in turn blocks deleting the parent broker_packets row (FK) and
--     any documents row an item still references (FK).
--   - guard_broker_permanent_delete_trigger (0094) refuses to delete a
--     broker with ANY broker_packets row at all -- "This broker has
--     operational or financial history and cannot be permanently
--     deleted." -- via delete_broker_safely() or any other path,
--     including service_role.
--
-- This is the SAME protection real historical Broker Packet data gets --
-- it is correct, intentional behavior, not a defect. It simply means a
-- disposable test fixture that exercises real Broker Packet generation
-- (as Phase 2N.4's mandatory live-generation acceptance required) can
-- never be cleaned up via the API/RPC surface once generated. This script
-- is the one-off, manually-authorized exception.
--
-- 2N.4A REVISION -- isolation hardening per explicit review request:
--   - Target organization ids are captured EXACTLY ONCE, at the very top
--     of the transaction, into a temporary table -- every downstream
--     DELETE reads from that captured set, never re-running a LIKE scan
--     against the live `organizations` table. This closes even the
--     theoretical race of a legitimate new org happening to be named
--     something matching 'TEST-2N4%' mid-transaction: it would simply
--     not be in the already-captured set, so it can never be touched.
--   - The captured set is additionally intersected with the EXACT three
--     organization ids known from this session's own Phase 2N.4 test run
--     (hardcoded below) -- a belt-and-suspenders check: even if the name
--     pattern were somehow wrong or over-broad, only these three specific
--     ids can ever be affected. If Supabase's live data does not contain
--     all three, the script still runs correctly against whichever subset
--     actually matches both conditions.
--   - The associated auth.users ids are likewise captured ONCE, via
--     `profiles.organization_id` (a real, indexed FK -- not a text
--     pattern), BEFORE any profiles row is deleted -- auth.users deletion
--     below uses that captured id set, never an email LIKE pattern.
--   - Every table delete below filters on organization_id (a real FK
--     column) against the captured set -- never a bare/unscoped DELETE,
--     never a LIKE against any table other than the one-time capture of
--     `organizations` itself.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Capture the exact target set ONCE. Every statement after this block reads
-- only from these two temporary tables (visible only within this session/
-- transaction, dropped automatically at COMMIT) -- never re-touching
-- `organizations` or `auth.users` with a pattern match again.
-- ---------------------------------------------------------------------------
create temporary table _cleanup_target_orgs on commit drop as
select id from public.organizations
where name like 'TEST-2N4%'
  and id in (
    'd518f55f-7595-4cf7-84b8-b55a89cb323d',
    '032e1f3c-8f82-407c-88c2-1ee87458ae38',
    '34bb4087-ce04-4baf-91f4-722836eb690e'
  );

create temporary table _cleanup_target_users on commit drop as
select p.id from public.profiles p
where p.organization_id in (select id from _cleanup_target_orgs);

-- Sanity gate: refuse to proceed at all if the captured set is not EXACTLY
-- the three known ids (protects against running this unmodified against a
-- database where those three orgs no longer exist under those ids, or
-- where the name pattern unexpectedly matched something else -- in either
-- case this raises and the transaction aborts, touching nothing).
do $$
begin
  if (select count(*) from _cleanup_target_orgs) <> 3 then
    raise exception 'Safety gate: expected exactly 3 captured TEST-2N4 organizations, found %. Aborting -- no rows touched.', (select count(*) from _cleanup_target_orgs);
  end if;
end $$;

alter table public.broker_packet_items disable trigger broker_packet_items_immutability_guard;
alter table public.brokers disable trigger guard_broker_permanent_delete_trigger;

delete from public.email_send_log
where organization_id in (select id from _cleanup_target_orgs);

delete from public.broker_packet_items
where organization_id in (select id from _cleanup_target_orgs);

delete from public.broker_packets
where organization_id in (select id from _cleanup_target_orgs);

delete from public.carrier_w9_pii_access_log
where organization_id in (select id from _cleanup_target_orgs);

delete from public.carrier_w9s
where organization_id in (select id from _cleanup_target_orgs);

delete from public.documents
where organization_id in (select id from _cleanup_target_orgs);

delete from public.carrier_financials
where organization_id in (select id from _cleanup_target_orgs);

delete from public.carriers
where organization_id in (select id from _cleanup_target_orgs);

delete from public.brokers
where organization_id in (select id from _cleanup_target_orgs);

delete from public.profiles
where organization_id in (select id from _cleanup_target_orgs);

delete from auth.users
where id in (select id from _cleanup_target_users);

delete from public.organizations
where id in (select id from _cleanup_target_orgs);

alter table public.broker_packet_items enable trigger broker_packet_items_immutability_guard;
alter table public.brokers enable trigger guard_broker_permanent_delete_trigger;

commit;

-- Verification (run after commit): every count below should be 0, and both
-- trigger rows must show tgenabled = 'O' (origin -- i.e. enabled).
select
  (select count(*) from public.organizations where name like 'TEST-2N4%') as leftover_orgs,
  (select count(*) from public.carriers where legal_name like 'TEST-2N4%') as leftover_carriers,
  (select count(*) from public.brokers where company_name like 'TEST-2N4%' or legal_name like 'TEST-2N4%') as leftover_brokers,
  (select count(*) from public.broker_packets bp where not exists (select 1 from public.organizations o where o.id = bp.organization_id)) as orphan_check_broker_packets,
  (select count(*) from public.broker_packet_items bpi where not exists (select 1 from public.organizations o where o.id = bpi.organization_id)) as orphan_check_broker_packet_items,
  (select count(*) from public.documents d where d.file_name like '%TEST-2N4%' or d.file_path like '%test-2n4%') as leftover_documents_by_name,
  (select count(*) from auth.users where email like 'test-2n4-%@example.com') as leftover_users,
  (select tgenabled from pg_trigger where tgname = 'broker_packet_items_immutability_guard') as items_trigger_enabled_flag,
  (select tgenabled from pg_trigger where tgname = 'guard_broker_permanent_delete_trigger') as brokers_trigger_enabled_flag;
