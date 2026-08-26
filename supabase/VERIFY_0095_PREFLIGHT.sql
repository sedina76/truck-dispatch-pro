-- =============================================================================
-- VERIFY_0095_PREFLIGHT.sql
-- Phase 2M.2B -- read-only preflight for 0095_broker_packets.sql.
-- Run every query below BEFORE applying 0095. None of these mutate data.
-- =============================================================================

-- 1. Existing broker integrity: every broker has a real organization, no
-- orphans. Expect 0 rows.
select b.id, b.company_name
from public.brokers b
left join public.organizations o on o.id = b.organization_id
where o.id is null;

-- 2. Existing carrier/organization alignment: every active carrier belongs
-- to a real organization. Expect 0 rows.
select c.id, c.legal_name
from public.carriers c
left join public.organizations o on o.id = c.organization_id
where o.id is null;

-- 3. Documents that could become Broker Packet candidates today (entity_type
-- in broker/carrier/organization), for a sanity read of what the new
-- candidate list will actually surface. Informational only.
select entity_type, document_type, count(*) as document_count
from public.documents
where entity_type in ('broker', 'carrier', 'organization')
group by entity_type, document_type
order by entity_type, document_type;

-- 4. Invalid document relationships among those candidates: entity_id does
-- not resolve to a real row in the corresponding table, or crosses
-- organizations. Expect 0 rows -- if not, guard_broker_packet_item() will
-- correctly reject these as sources, but it's worth knowing they exist.
select d.id, d.organization_id, d.entity_type, d.entity_id
from public.documents d
where d.entity_type = 'broker'
  and not exists (select 1 from public.brokers b where b.id = d.entity_id and b.organization_id = d.organization_id)
union all
select d.id, d.organization_id, d.entity_type, d.entity_id
from public.documents d
where d.entity_type = 'carrier'
  and not exists (select 1 from public.carriers c where c.id = d.entity_id and c.organization_id = d.organization_id)
union all
select d.id, d.organization_id, d.entity_type, d.entity_id
from public.documents d
where d.entity_type = 'organization'
  and d.entity_id <> d.organization_id;

-- 5. Unexpected MIME types among those candidates (would be excluded from
-- eligibility, not blocking -- informational).
select entity_type, document_type, mime_type, count(*)
from public.documents
where entity_type in ('broker', 'carrier', 'organization')
  and coalesce(mime_type, '') not in ('application/pdf', 'image/jpeg', 'image/png')
group by entity_type, document_type, mime_type;

-- 6. Unverified / rejected / expired candidates among those same documents
-- (would show as "unverified"/"rejected"/"expired" in the picker, not an
-- error -- informational).
select entity_type, document_type,
  count(*) filter (where not is_verified or verified_at is null) as unverified_count,
  count(*) filter (where rejected_at is not null) as rejected_count,
  count(*) filter (where expiry_date is not null and expiry_date < current_date) as expired_count
from public.documents
where entity_type in ('broker', 'carrier', 'organization')
group by entity_type, document_type;

-- 7. Duplicate broker_financials/profile relationships (unrelated to this
-- migration's tables, but flagged since 0095 reads brokers/carriers/
-- organizations for snapshots -- a duplicate here would not break 0095,
-- just worth a clean read). Expect 0 rows.
select broker_id, count(*) from public.broker_financials group by broker_id having count(*) > 1;

-- 8. Current broker_has_protected_history() definition -- confirm the six
-- clauses this migration is about to become the seventh clause of, so the
-- diff is reviewable. Expect to see exactly loads/invoices/documents/
-- statements/carrier_setup_packages/email_send_log, no broker_packets yet.
select pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'broker_has_protected_history';

-- 9. Storage bucket name conflict check. Expect 0 rows (bucket does not
-- exist yet).
select id, name, public from storage.buckets where id = 'broker-packets';

-- 10. Enum/type conflict checks. Expect 0 rows for both -- neither type
-- name nor entity_type value should already exist.
select typname from pg_type where typname = 'broker_packet_status';
select enumlabel from pg_enum e
join pg_type t on t.oid = e.enumtypid
where t.typname = 'entity_type' and e.enumlabel = 'broker_packet';

-- 11. Table name conflicts. Expect 0 rows for all three.
select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('broker_packets', 'broker_packet_items', 'broker_packet_requirements');

-- 12. email_send_log column conflict check. Expect 0 rows (column does not
-- exist yet).
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'email_send_log' and column_name = 'broker_packet_id';

-- 13. Confirm the exact document_type enum values 0095's default catalog
-- assumes already exist (w9, insurance_certificate, motor_carrier_authority,
-- notice_of_assignment, factoring_notice, voided_check, other). Expect 7
-- rows.
select enumlabel from pg_enum e
join pg_type t on t.oid = e.enumtypid
where t.typname = 'document_type'
  and enumlabel in ('w9','insurance_certificate','motor_carrier_authority','notice_of_assignment','factoring_notice','voided_check','other');

-- =============================================================================
-- 2M.2C additions -- polymorphic document guard (carrier/organization) and
-- supersession-invariant preflight.
-- =============================================================================

-- 14. Confirm no guard_document_carrier_link/organization_link trigger or
-- function already exists (collision check). Expect 0 rows for both.
select tgname from pg_trigger where tgrelid = 'public.documents'::regclass and not tgisinternal
  and tgname in ('guard_document_carrier_link_insert','guard_document_carrier_link_update',
                 'guard_document_organization_link_insert','guard_document_organization_link_update');
select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('guard_document_carrier_link','guard_document_organization_link');

-- 15. KNOWN, DOCUMENTED, OUT-OF-SCOPE GAP -- confirm current state so it's
-- on record, not silently assumed: carriers has a raw, unprotected DELETE
-- policy (the same shape brokers had before 0094), and no
-- carrier_has_protected_history()-equivalent exists. Expect 1 row for the
-- policy, 0 rows for the (nonexistent) protection function. This
-- migration does NOT close this gap -- see 0095's own header comment on
-- the carrier/organization guard section.
select polname, cmd from pg_policies where schemaname = 'public' and tablename = 'carriers' and polname = 'carriers_delete';
select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'carrier_has_protected_history';

-- 16. Inventory of carriers currently carrying a 'carrier'-typed document
-- (informational -- these are exactly the rows that would become
-- vulnerable to the gap in item 15 if a raw carrier delete were ever
-- issued against them; not acted on by this migration).
select d.id as document_id, d.entity_id as carrier_id, c.legal_name
from public.documents d
join public.carriers c on c.id = d.entity_id and c.organization_id = d.organization_id
where d.entity_type = 'carrier';

-- 17. Existing broker_packets/broker_packet_items rows -- must be empty
-- since neither table exists yet pre-apply; included for symmetry with
-- the post-apply supersession-invariant check. Expect an error (relation
-- does not exist) if run before 0095 -- this line documents the
-- post-apply query's shape, not a live pre-apply check.
-- select broker_id, count(*) filter (where status in ('generated','sent')) as current_count
-- from public.broker_packets group by broker_id having count(*) filter (where status in ('generated','sent')) > 1;
