-- Phase 2M.2E -- Broker Packet document-selection/generation acceptance.
-- Read-only. Run against Kali Freights LLC's live broker/carrier/packet
-- data to confirm what this audit's code review predicts. Nothing here
-- writes, re-points, or mutates any row.

-- 1. Identify the carrier, its current packet(s), and what's selected on
--    the draft packet described in the report (Selected Documents (1)).
select p.id as packet_id, p.status, p.broker_id, p.carrier_id, p.document_count, c.legal_name as carrier_name
from public.broker_packets p
join public.carriers c on c.id = p.carrier_id
where c.legal_name ilike '%kali%'
order by p.created_at desc;

-- 2. Which document is currently selected on that draft, and its exact
--    ownership/storage snapshot (answers Section A.1 and Section B for
--    whichever document is already added).
select i.id as item_id, i.document_type, i.source_filename, i.source_storage_bucket, i.source_storage_path,
  i.source_mime_type, i.source_file_size_bytes, i.source_expiry_date, i.source_verified_at, i.display_order
from public.broker_packet_items i
join public.broker_packets p on p.id = i.packet_id
join public.carriers c on c.id = p.carrier_id
where c.legal_name ilike '%kali%' and p.status = 'draft'
order by i.display_order;

-- 3. Current live ownership of the four documents in question, straight
--    from public.documents -- confirms Section B's exact column values
--    post-0111 (expect entity_type='carrier', entity_id=Kali's own
--    carrier id, for all four; storage_bucket='carrier-w9s' for the w9
--    row specifically, 'documents' for the rest).
select d.id, d.document_type, d.entity_type, d.entity_id, d.organization_id,
  d.storage_bucket, d.file_path, d.is_verified, d.verified_at, d.rejected_at, d.expiry_date, d.mime_type, d.file_size_bytes
from public.documents d
join public.carriers c on c.id = d.entity_id and d.entity_type = 'carrier'
where c.legal_name ilike '%kali%'
  and d.document_type in ('w9', 'insurance_certificate', 'motor_carrier_authority', 'voided_check')
order by d.document_type, d.created_at desc;
-- expect: exactly one CURRENT row per type here (the "latest" the guard
-- will accept); entity_type='carrier' and entity_id = Kali's own carrier
-- id on every row.

-- 4. Cross-carrier / cross-org isolation proof for the guard itself (not
--    UI-only): confirm no OTHER organization's or OTHER carrier's
--    document could satisfy guard_broker_packet_item()'s own relationship
--    check for Kali's packet -- i.e. no document exists whose
--    organization_id matches Kali's org but whose entity_id points at a
--    different carrier while somehow also matching Kali's packet
--    eligibility. This just re-confirms the invariant the guard enforces
--    structurally (entity_id = new.packet's own carrier_id), not a
--    loophole search.
select d.id, d.entity_type, d.entity_id, d.organization_id
from public.documents d
join public.broker_packets p on p.organization_id = d.organization_id
join public.carriers c on c.id = p.carrier_id
where c.legal_name ilike '%kali%' and p.status = 'draft'
  and d.entity_type = 'carrier' and d.entity_id <> p.carrier_id
  and d.document_type in ('w9', 'insurance_certificate', 'motor_carrier_authority', 'voided_check');
-- expect: 0 rows (no same-org, different-carrier document of these types
-- could ever pass the guard's entity_id = packet.carrier_id check)

-- 5. Duplicate-protection mechanism actually present on broker_packet_items
--    (answers Section I precisely, from the catalog rather than assumed).
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.broker_packet_items'::regclass and contype = 'u'
order by conname;
-- expect: broker_packet_items_packet_id_document_id_key -- unique
-- (packet_id, document_id), plus the display_order uniqueness pair.

-- 6. Executed-agreement isolation proof specific to Broker Packet: confirm
--    no document referenced by carrier_agreement_signings has ever
--    reached entity_type='carrier' (which is the only way it could ever
--    pass guard_broker_packet_item()'s relationship check) -- this is the
--    structural reason Broker Packet can never include an executed
--    agreement, independent of its document-type catalog also excluding
--    signed_agreement.
select d.id, d.entity_type, d.entity_id, s.application_id
from public.documents d
join public.carrier_agreement_signings s on s.generated_document_id = d.id
where d.entity_type = 'carrier';
-- expect: 0 rows

-- 7. Any existing generated/sent packet for Kali (if one already exists)
--    to spot-check E/F (storage bucket resolution, output correctness)
--    against a real artifact rather than only the current draft.
select p.id, p.status, p.version, p.generated_storage_path, p.generated_file_size_bytes, p.page_count, p.generated_at
from public.broker_packets p
join public.carriers c on c.id = p.carrier_id
where c.legal_name ilike '%kali%' and p.status in ('generated', 'sent', 'superseded')
order by p.version desc nulls last;
