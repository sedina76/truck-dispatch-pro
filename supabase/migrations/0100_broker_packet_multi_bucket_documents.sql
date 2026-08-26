-- =============================================================================
-- 0100_broker_packet_multi_bucket_documents.sql
-- Phase 2N.2B: the smallest safe repair that lets Broker Packet consume an
-- authoritative document living in a private bucket other than
-- `documents` (starting with W-9, `carrier-w9s`), without duplicating
-- bytes, without a second W-9 generation, and without granting any new
-- direct access to that bucket.
--
-- NOT YET APPLIED -- authored for review only. MUST be applied strictly
-- AFTER 0099 (0099_carrier_w9.sql), since it references
-- public.documents.storage_bucket, a column 0099 adds. Applying 0100
-- before 0099 would fail outright (column does not exist yet) -- this is
-- an ordering dependency, not a risk to sequence around silently.
--
-- Replaces exactly two objects, both originally created by
-- 0095_broker_packets.sql: guard_broker_packet_item() and
-- add_broker_packet_item(). This is DELIBERATELY its own separately
-- numbered, separately authorized migration -- not bundled into 0099 --
-- for the same reason 0096/0097/0098 were each their own migration: a
-- behavioral change to an already-production-proven Broker Packet
-- trigger/RPC deserves its own live regression cycle, never coupled to an
-- unrelated feature's migration. Every other Broker Packet object
-- (broker_packets, broker_packet_items, every other RPC/trigger) is
-- completely untouched.
--
-- Audited live before writing this (2N.2B section 1): add_broker_packet_item()
-- hardcodes the literal 'documents' when inserting
-- broker_packet_items.source_storage_bucket (never reads a real column,
-- because none existed before 0099). guard_broker_packet_item() separately
-- rejects any source_storage_bucket other than the literal 'documents'.
-- generateBrokerPacket() (src/app/(app)/brokers/[id]/packets/actions.ts,
-- Phase 2M.3) was ALREADY bucket-agnostic at the download step
-- (`service.storage.from(item.source_storage_bucket).download(...)`) --
-- only its own extra equality check against the single-value constant
-- BROKER_PACKET_SOURCE_BUCKET needed broadening, done in the accompanying
-- application-code change (src/lib/broker-packets/types.ts), not here.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- guard_broker_packet_item(): every line is byte-for-byte identical to the
-- live 0095 body EXCEPT the single bucket check. Old:
--   if new.source_storage_bucket <> 'documents' then
--     raise exception 'A source document has an invalid storage location.';
--   end if;
-- New: an explicit, reviewed allowlist (documents, carrier-w9s -- adding a
-- third authoritative bucket in the future means editing this literal
-- list in its own migration, never silently) PLUS a cross-check that the
-- item's own bucket snapshot actually matches the referenced document's
-- own recorded bucket -- belt-and-suspenders: a document can never be
-- added under a bucket claim that doesn't match its own real location,
-- regardless of what a future caller might pass.
-- ---------------------------------------------------------------------------

create or replace function public.guard_broker_packet_item()
returns trigger language plpgsql set search_path = public as $$
declare
  v_packet public.broker_packets;
  v_document public.documents;
  v_latest_id uuid;
  v_count integer;
begin
  select * into v_packet from public.broker_packets where id = new.packet_id;
  if v_packet.id is null or v_packet.organization_id <> new.organization_id then
    raise exception 'Packet item must belong to its packet organization.';
  end if;
  if v_packet.status <> 'draft' then
    raise exception 'Items may only be added while a broker packet is in draft.';
  end if;

  select * into v_document from public.documents where id = new.document_id;
  if v_document.id is null or v_document.organization_id <> new.organization_id then
    raise exception 'Selected document does not belong to this organization.';
  end if;
  if not (
    (v_document.entity_type = 'broker' and v_document.entity_id = v_packet.broker_id)
    or (v_packet.carrier_id is not null and v_document.entity_type = 'carrier' and v_document.entity_id = v_packet.carrier_id)
    or (v_document.entity_type = 'organization' and v_document.entity_id = v_packet.organization_id)
  ) then
    raise exception 'Selected document is not eligible for this broker packet.';
  end if;

  select id into v_latest_id from public.documents
  where organization_id = new.organization_id
    and entity_type = v_document.entity_type and entity_id = v_document.entity_id
    and document_type = v_document.document_type
  order by created_at desc, id desc limit 1;
  if v_latest_id is distinct from v_document.id then
    raise exception 'Only the latest document of each type may be included.';
  end if;

  if not v_document.is_verified or v_document.verified_at is null or v_document.rejected_at is not null then
    raise exception 'Selected documents must be verified and not rejected.';
  end if;
  if v_document.expiry_date is not null and v_document.expiry_date < current_date then
    raise exception 'Expired documents cannot be included in a broker packet.';
  end if;
  if coalesce(v_document.mime_type, '') not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception 'Only PDF, JPEG, and PNG documents may be included.';
  end if;
  if v_document.file_size_bytes is null or v_document.file_size_bytes <= 0 or v_document.file_size_bytes > 10485760 then
    raise exception 'Each source document must have a known size of 10 MB or less.';
  end if;
  -- 2N.2B repair: explicit allowlist of buckets Broker Packet is trusted
  -- to read from, PLUS a cross-check that the item's own bucket snapshot
  -- matches the document's own recorded storage_bucket (0099) -- a
  -- mismatch in either direction is rejected. This does not grant any new
  -- direct access to carrier-w9s: it only permits the trusted server-side
  -- Broker Packet generation path (service-role, src/app/(app)/brokers/
  -- [id]/packets/actions.ts) to download from it -- the W-9 PDF role
  -- policy and carrier-w9s storage access policy are both completely
  -- untouched by this migration.
  if new.source_storage_bucket not in ('documents', 'carrier-w9s') then
    raise exception 'A source document has an invalid storage location.';
  end if;
  if new.source_storage_bucket is distinct from v_document.storage_bucket then
    raise exception 'A source document has an invalid storage location.';
  end if;
  if new.document_type is distinct from v_document.document_type
    or new.source_filename is distinct from v_document.file_name
    or new.source_storage_path is distinct from v_document.file_path
    or new.source_mime_type is distinct from v_document.mime_type
    or new.source_file_size_bytes is distinct from v_document.file_size_bytes
    or new.source_created_at is distinct from v_document.created_at
    or new.source_expiry_date is distinct from v_document.expiry_date
    or new.source_verified_at is distinct from v_document.verified_at then
    raise exception 'Packet item source snapshot does not match its document.';
  end if;

  select count(*) into v_count from public.broker_packet_items where packet_id = new.packet_id;
  if v_count >= 12 then
    raise exception 'A broker packet may include at most 12 documents.';
  end if;
  return new;
end;
$$;

comment on function public.guard_broker_packet_item() is
  'Enforces every Broker Packet source-document eligibility rule (org/status/entity-relationship/latest-of-type/verified/not-expired/MIME/size), unchanged from 0095, plus (2N.2B) an explicit source-bucket allowlist (documents, carrier-w9s) and a bucket/document cross-check -- a document can never be added under a bucket claim that does not match its own recorded storage_bucket (0099).';

-- No trigger recreation needed: broker_packet_items_guard already
-- references this function by name; CREATE OR REPLACE FUNCTION updates
-- its behavior in place.

-- ---------------------------------------------------------------------------
-- add_broker_packet_item(): every line is byte-for-byte identical to the
-- live 0095 body EXCEPT one value in the INSERT -- the hardcoded literal
-- 'documents' becomes v_document.storage_bucket (the real, server-loaded
-- value). No RPC parameter for the bucket is added or ever accepted --
-- the client has no way to influence this value at all, exactly as
-- before.
-- ---------------------------------------------------------------------------

create or replace function public.add_broker_packet_item(p_packet_id uuid, p_document_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_packet public.broker_packets; v_document public.documents; v_next_order integer; v_id uuid;
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to manage broker packets.';
  end if;
  select * into v_packet from public.broker_packets where id = p_packet_id and organization_id = public.current_org_id() for update;
  if v_packet.id is null then raise exception 'Broker packet not found in your organization.'; end if;
  select * into v_document from public.documents where id = p_document_id and organization_id = v_packet.organization_id;
  if v_document.id is null then raise exception 'Document not found in your organization.'; end if;
  select coalesce(max(display_order), 0) + 1 into v_next_order from public.broker_packet_items where packet_id = p_packet_id;
  insert into public.broker_packet_items (
    organization_id, packet_id, document_id, document_type, display_order,
    source_filename, source_storage_bucket, source_storage_path, source_mime_type,
    source_file_size_bytes, source_created_at, source_expiry_date, source_verified_at
  ) values (
    v_packet.organization_id, p_packet_id, v_document.id, v_document.document_type, v_next_order,
    v_document.file_name, v_document.storage_bucket, v_document.file_path, v_document.mime_type,
    v_document.file_size_bytes, v_document.created_at, v_document.expiry_date, v_document.verified_at
  ) returning id into v_id;
  update public.broker_packets set document_count = (select count(*) from public.broker_packet_items where packet_id = p_packet_id)
  where id = p_packet_id;
  return v_id;
end;
$$;

comment on function public.add_broker_packet_item(uuid, uuid) is
  'Adds a document to a draft broker packet, snapshotting its exact source metadata (2N.2B: including the real storage_bucket read server-side from the document row, never accepted as a caller parameter) so the packet''s own record of what it contains can never silently drift from the source document, even if the document is later edited.';

-- No grant/revoke changes: both CREATE OR REPLACE FUNCTION calls have
-- unchanged signatures, so their existing ACLs from 0095
-- (guard_broker_packet_item: trigger function, no direct grants;
-- add_broker_packet_item: revoked from public/anon, granted to
-- authenticated) are preserved automatically.

-- ---------------------------------------------------------------------------
-- Application-code counterpart (not part of this SQL file, listed here
-- for completeness -- see the accompanying commit):
--   src/lib/broker-packets/types.ts: BROKER_PACKET_SOURCE_BUCKET (a single
--     string) -> BROKER_PACKET_SOURCE_BUCKETS (a Set<string>, {"documents",
--     "carrier-w9s"}), matching this migration's allowlist exactly.
--   src/app/(app)/brokers/[id]/packets/actions.ts: generateBrokerPacket()'s
--     one equality check (`item.source_storage_bucket !== BROKER_PACKET_SOURCE_BUCKET`)
--     becomes a membership check (`!BROKER_PACKET_SOURCE_BUCKETS.has(item.source_storage_bucket)`).
--     The download call itself (`service.storage.from(item.source_storage_bucket)...`)
--     is UNCHANGED -- it was already bucket-agnostic.
-- ---------------------------------------------------------------------------
