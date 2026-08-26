-- =============================================================================
-- 0095_broker_packets.sql
-- Phase 2M.2B: Broker Packet foundation -- our company/carrier profile,
-- packaged and sent to a broker for carrier setup, kept deliberately
-- separate from carrier_setup_packages (0087/0088), which is the internal
-- onboarding artifact for a THIRD-PARTY carrier this org dispatches for.
-- Same shape where it genuinely is the same problem (immutable, versioned,
-- snapshot-based, hash-verified document assembly); a new table where the
-- business object actually differs (broker-owned, draft-first lifecycle,
-- no onboarding_application_id).
--
-- Audited before writing (Phase 2M.2A): documents.entity_type has carried
-- 'organization' and 'carrier' as valid enum members since 0001, but
-- neither has a real, populated upload workflow today (only the freeform
-- /documents/new page can reach them, with none of 0094's per-broker
-- validation). Broker packet source eligibility below intentionally
-- allows entity_type in ('broker','carrier','organization') because the
-- schema already supports all three -- this is not inventing a new
-- relationship, it's choosing among ones that already exist -- but every
-- one is independently re-validated in guard_broker_packet_item() rather
-- than trusted from upload time, exactly because that upstream validation
-- gap exists. Closing that upload-time gap (a guard_broker_document_link-
-- style trigger for carrier/organization documents) is explicitly NOT in
-- scope here; noted as a remaining risk in the accompanying report.
-- =============================================================================

create type public.broker_packet_status as enum (
  'draft', 'generating', 'generated', 'sent', 'superseded', 'failed', 'voided'
);

alter type public.entity_type add value if not exists 'broker_packet';

-- ---------------------------------------------------------------------------
-- broker_packets: one row per version. version is NULL while status='draft'
-- (a draft that's abandoned/voided without ever generating never burns a
-- version number); assigned exactly once, at the draft -> generating
-- transition, by reserve_broker_packet().
-- ---------------------------------------------------------------------------
create table public.broker_packets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  broker_id uuid not null references public.brokers(id) on delete restrict,
  carrier_id uuid references public.carriers(id) on delete restrict,
  version integer check (version is null or version > 0),
  status public.broker_packet_status not null default 'draft',
  created_by uuid references public.profiles(id) on delete set null,
  generated_by uuid references public.profiles(id) on delete set null,
  generated_at timestamptz,
  organization_snapshot jsonb,
  carrier_snapshot jsonb,
  broker_snapshot jsonb,
  generated_storage_path text,
  generated_file_size_bytes bigint check (generated_file_size_bytes is null or generated_file_size_bytes >= 0),
  generated_pdf_sha256 text check (generated_pdf_sha256 is null or generated_pdf_sha256 ~ '^[0-9a-f]{64}$'),
  page_count integer check (page_count is null or page_count between 1 and 250),
  document_count integer not null default 0 check (document_count between 0 and 12),
  last_sent_at timestamptz,
  last_sent_by uuid references public.profiles(id) on delete set null,
  last_sent_recipient_name text,
  last_sent_recipient_email text,
  last_email_send_log_id uuid,
  superseded_by uuid references public.broker_packets(id) on delete set null,
  superseded_at timestamptz,
  voided_at timestamptz,
  voided_by uuid references public.profiles(id) on delete set null,
  void_reason text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- 'voided' is reachable either from 'draft' (never reserved, version
  -- still null) or from 'generated'/'sent' (already has a version) -- so
  -- only statuses that are unreachable without having gone through
  -- reserve_broker_packet() actually require one.
  constraint broker_packet_version_required_once_reserved check (status in ('draft', 'voided') or version is not null),
  constraint broker_packet_generated_shape check (
    status not in ('generated', 'sent', 'superseded')
    or (generated_storage_path is not null and generated_file_size_bytes is not null
        and generated_pdf_sha256 is not null and page_count is not null and generated_at is not null)
  ),
  constraint broker_packet_failed_shape check (
    status <> 'failed' or (failure_reason is not null and generated_storage_path is null and generated_pdf_sha256 is null)
  ),
  constraint broker_packet_superseded_shape check (
    status <> 'superseded' or (superseded_at is not null and superseded_by is not null)
  )
);

-- Version uniqueness is broker-scoped and only meaningful once assigned.
create unique index broker_packets_broker_version_idx
  on public.broker_packets (broker_id, version) where version is not null;
create index broker_packets_org_broker_created_idx
  on public.broker_packets (organization_id, broker_id, created_at desc);

create table public.broker_packet_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  packet_id uuid not null references public.broker_packets(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  document_type public.document_type not null,
  display_order integer not null check (display_order > 0),
  source_filename text not null,
  source_storage_bucket text not null,
  source_storage_path text not null,
  source_mime_type text,
  source_file_size_bytes bigint check (source_file_size_bytes is null or source_file_size_bytes between 1 and 10485760),
  source_created_at timestamptz not null,
  source_expiry_date date,
  source_verified_at timestamptz not null,
  source_content_hash text,
  start_page integer,
  end_page integer,
  included_at timestamptz not null default now(),
  unique (packet_id, document_id),
  unique (packet_id, display_order),
  constraint broker_packet_item_hash_format check (source_content_hash is null or source_content_hash ~ '^[0-9a-f]{64}$'),
  constraint broker_packet_item_page_range check (
    (start_page is null and end_page is null)
    or (start_page is not null and end_page is not null and start_page > 0 and end_page >= start_page)
  )
);

-- ---------------------------------------------------------------------------
-- broker_packet_requirements: a small per-broker checklist, not a workflow
-- engine and not historical -- freely editable at any time; a generated
-- packet's own frozen items/snapshots are what the historical record
-- actually depends on, so changing a requirement never touches the past.
-- ---------------------------------------------------------------------------
create table public.broker_packet_requirements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  broker_id uuid not null references public.brokers(id) on delete cascade,
  document_type public.document_type not null,
  is_required boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (broker_id, document_type)
);

create trigger broker_packets_set_updated_at
  before update on public.broker_packets
  for each row execute function public.set_updated_at();
create trigger broker_packet_requirements_set_updated_at
  before update on public.broker_packet_requirements
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Relationship guards (BEFORE INSERT) -- org/broker/carrier consistency,
-- exactly the same defense-in-depth style as 0087/0093/0094: never trust
-- that a caller-supplied FK actually belongs to the same organization.
-- ---------------------------------------------------------------------------
create or replace function public.guard_broker_packet_relationships()
returns trigger language plpgsql set search_path = public as $$
declare v_broker_org uuid; v_carrier_org uuid;
begin
  select organization_id into v_broker_org from public.brokers where id = new.broker_id;
  if v_broker_org is null or v_broker_org <> new.organization_id then
    raise exception 'Broker packet must belong to the broker organization.';
  end if;
  if new.carrier_id is not null then
    select organization_id into v_carrier_org from public.carriers where id = new.carrier_id;
    if v_carrier_org is null or v_carrier_org <> new.organization_id then
      raise exception 'Broker packet carrier must belong to the same organization.';
    end if;
  end if;
  return new;
end;
$$;

create trigger broker_packets_relationship_guard
  before insert on public.broker_packets
  for each row execute function public.guard_broker_packet_relationships();

create or replace function public.guard_broker_packet_requirement_organization()
returns trigger language plpgsql set search_path = public as $$
declare v_broker_org uuid;
begin
  select organization_id into v_broker_org from public.brokers where id = new.broker_id;
  if v_broker_org is null or v_broker_org <> new.organization_id then
    raise exception 'Broker packet requirement must belong to the broker organization.';
  end if;
  return new;
end;
$$;

create trigger broker_packet_requirements_organization_guard
  before insert or update on public.broker_packet_requirements
  for each row execute function public.guard_broker_packet_requirement_organization();

-- ---------------------------------------------------------------------------
-- Item eligibility guard (BEFORE INSERT). Divergence from 0087's analog,
-- deliberate: items here are added one at a time over several RPC calls
-- during 'draft' (not inserted all-at-once during 'generating' like a
-- setup package reservation), so the required status here is 'draft', not
-- 'generating'.
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
  if new.source_storage_bucket <> 'documents' then
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

create trigger broker_packet_items_guard
  before insert on public.broker_packet_items
  for each row execute function public.guard_broker_packet_item();

-- ---------------------------------------------------------------------------
-- Immutability guards -- identical philosophy to 0087/0088. The packet
-- guard additionally protects generated_pdf_sha256 (the 2M.2B amendment)
-- alongside the artifact fields it ships with.
-- ---------------------------------------------------------------------------
create or replace function public.guard_broker_packet_immutability()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.organization_id is distinct from old.organization_id
    or new.broker_id is distinct from old.broker_id
    or new.carrier_id is distinct from old.carrier_id
    or new.version is distinct from old.version
    or new.organization_snapshot is distinct from old.organization_snapshot
    or new.carrier_snapshot is distinct from old.carrier_snapshot
    or new.broker_snapshot is distinct from old.broker_snapshot
    or new.generated_by is distinct from old.generated_by
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at then
    raise exception 'A broker packet''s frozen identity and snapshots cannot be changed.';
  end if;

  if old.document_count is distinct from new.document_count and old.status <> 'draft' then
    raise exception 'Document count is frozen once a broker packet leaves draft.';
  end if;

  if old.status <> 'generating'
    and (
      new.generated_storage_path is distinct from old.generated_storage_path
      or new.generated_file_size_bytes is distinct from old.generated_file_size_bytes
      or new.generated_pdf_sha256 is distinct from old.generated_pdf_sha256
      or new.page_count is distinct from old.page_count
      or new.generated_at is distinct from old.generated_at
    ) then
    raise exception 'A finalized broker packet''s generated artifact metadata cannot be changed.';
  end if;

  if old.status = 'draft' and new.status not in ('draft', 'generating', 'voided') then
    raise exception 'Invalid broker packet status transition.';
  -- generating -> superseded (2M.2C amendment): finalize_broker_packet()
  -- takes this path directly -- never generating -> generated -> superseded
  -- as two steps -- when a HIGHER version for the same broker already
  -- committed 'generated'/'sent' by the time this one finalizes (the
  -- out-of-order-completion case). The artifact is still real and
  -- immutable (generated_shape's constraint already requires the full
  -- artifact for 'superseded' too), it is simply never exposed as current
  -- even momentarily. See finalize_broker_packet()'s own comment for the
  -- full bidirectional supersession logic this transition supports.
  elsif old.status = 'generating' and new.status not in ('generating', 'generated', 'superseded', 'failed') then
    raise exception 'Invalid broker packet status transition.';
  elsif old.status = 'generated' and new.status not in ('generated', 'sent', 'superseded', 'voided') then
    raise exception 'Invalid broker packet status transition.';
  elsif old.status = 'sent' and new.status not in ('sent', 'superseded', 'voided') then
    raise exception 'Invalid broker packet status transition.';
  elsif old.status in ('failed', 'superseded', 'voided') and new.status <> old.status then
    raise exception 'Failed, superseded, and voided broker packets are terminal.';
  end if;
  return new;
end;
$$;

create trigger broker_packets_immutability_guard
  before update on public.broker_packets
  for each row execute function public.guard_broker_packet_immutability();

create or replace function public.guard_broker_packet_item_immutability()
returns trigger language plpgsql set search_path = public as $$
declare v_status public.broker_packet_status;
begin
  if tg_op = 'DELETE' then
    select status into v_status from public.broker_packets where id = old.packet_id;
    if v_status is distinct from 'draft' then raise exception 'Items may only be removed while a broker packet is in draft.'; end if;
    return old;
  end if;
  select status into v_status from public.broker_packets where id = old.packet_id;
  if v_status = 'draft' then
    -- Draft-time mutation is limited to reordering; every other identity
    -- field is still write-once even in draft, since it's set atomically
    -- by add_broker_packet_item() and never meant to be edited in place
    -- (removing and re-adding is the supported way to change a selection).
    if new.organization_id is distinct from old.organization_id or new.packet_id is distinct from old.packet_id
      or new.document_id is distinct from old.document_id or new.document_type is distinct from old.document_type
      or new.source_filename is distinct from old.source_filename or new.source_storage_bucket is distinct from old.source_storage_bucket
      or new.source_storage_path is distinct from old.source_storage_path or new.source_mime_type is distinct from old.source_mime_type
      or new.source_file_size_bytes is distinct from old.source_file_size_bytes or new.source_created_at is distinct from old.source_created_at
      or new.source_expiry_date is distinct from old.source_expiry_date or new.source_verified_at is distinct from old.source_verified_at
      or new.included_at is distinct from old.included_at
      or new.source_content_hash is distinct from old.source_content_hash
      or new.start_page is distinct from old.start_page or new.end_page is distinct from old.end_page then
      raise exception 'Only display_order may change while a broker packet is in draft.';
    end if;
    return new;
  end if;
  raise exception 'Generated broker packet items are immutable.';
end;
$$;

create trigger broker_packet_items_immutability_guard
  before update or delete on public.broker_packet_items
  for each row execute function public.guard_broker_packet_item_immutability();

alter table public.broker_packets enable row level security;
alter table public.broker_packet_items enable row level security;
alter table public.broker_packet_requirements enable row level security;

-- SELECT-only RLS: metadata visibility, including for Viewer (approved
-- decision 2M.2B item 2 -- Viewer sees history/status but never obtains a
-- storage-object read, since the storage.objects policy below does NOT
-- include viewer; a visible generated_storage_path column here is just a
-- string, not the bytes). No INSERT/UPDATE/DELETE policy exists on either
-- table -- every mutation is a SECURITY DEFINER RPC, so there is no raw
-- authenticated write path to close later the way 0094 had to close one
-- for brokers.
create policy broker_packets_select on public.broker_packets for select using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner','admin','dispatcher','accountant','viewer']::public.org_role[])
);
create policy broker_packet_items_select on public.broker_packet_items for select using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner','admin','dispatcher','accountant','viewer']::public.org_role[])
);

-- Requirements are not historical, so ordinary role-gated CRUD via RLS is
-- fine -- no invariant here needs a trusted RPC boundary (unlike broker
-- contacts' one-primary-per-category rule).
create policy broker_packet_requirements_select on public.broker_packet_requirements for select using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner','admin','dispatcher','accountant','viewer']::public.org_role[])
);
create policy broker_packet_requirements_insert on public.broker_packet_requirements for insert with check (
  organization_id = public.current_org_id()
  and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
);
create policy broker_packet_requirements_update on public.broker_packet_requirements for update using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
) with check (organization_id = public.current_org_id());
create policy broker_packet_requirements_delete on public.broker_packet_requirements for delete using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
);

grant select on public.broker_packets, public.broker_packet_items to authenticated;
grant select, insert, update, delete on public.broker_packet_requirements to authenticated;

-- =============================================================================
-- RPCs
-- =============================================================================

create or replace function public.create_broker_packet_draft(p_broker_id uuid, p_carrier_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_broker public.brokers; v_id uuid;
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to create broker packets.';
  end if;
  select * into v_broker from public.brokers where id = p_broker_id and organization_id = public.current_org_id();
  if v_broker.id is null then raise exception 'Broker not found in your organization.'; end if;
  insert into public.broker_packets (organization_id, broker_id, carrier_id, created_by)
  values (v_broker.organization_id, p_broker_id, p_carrier_id, auth.uid())
  returning id into v_id;
  perform public.log_activity('broker_packet'::public.entity_type, v_id, 'broker_packet_created', jsonb_build_object('broker_id', p_broker_id));
  return v_id;
end;
$$;

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
    v_document.file_name, 'documents', v_document.file_path, v_document.mime_type,
    v_document.file_size_bytes, v_document.created_at, v_document.expiry_date, v_document.verified_at
  ) returning id into v_id;
  update public.broker_packets set document_count = (select count(*) from public.broker_packet_items where packet_id = p_packet_id)
  where id = p_packet_id;
  return v_id;
end;
$$;

create or replace function public.remove_broker_packet_item(p_packet_id uuid, p_item_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to manage broker packets.';
  end if;
  if not exists (select 1 from public.broker_packets where id = p_packet_id and organization_id = public.current_org_id()) then
    raise exception 'Broker packet not found in your organization.';
  end if;
  delete from public.broker_packet_items where id = p_item_id and packet_id = p_packet_id;
  if not found then raise exception 'Broker packet item not found.'; end if;
  update public.broker_packets set document_count = (select count(*) from public.broker_packet_items where packet_id = p_packet_id)
  where id = p_packet_id;
end;
$$;

-- Reassigns display_order 1..N per the caller's desired sequence. Offsets
-- into a disjoint negative range first so the intermediate state never
-- collides with the unique (packet_id, display_order) index -- the whole
-- renumbering happens inside one statement's worth of transaction, so no
-- other session can observe the negative intermediate values.
create or replace function public.reorder_broker_packet_items(p_packet_id uuid, p_item_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to manage broker packets.';
  end if;
  if not exists (select 1 from public.broker_packets where id = p_packet_id and organization_id = public.current_org_id() and status = 'draft') then
    raise exception 'Broker packet not found, not in your organization, or no longer a draft.';
  end if;
  select count(*) into v_count from public.broker_packet_items where packet_id = p_packet_id;
  if v_count <> coalesce(array_length(p_item_ids, 1), 0) or v_count <> (select count(distinct x) from unnest(p_item_ids) x) then
    raise exception 'Reorder list must name every current item exactly once.';
  end if;
  update public.broker_packet_items set display_order = -ord
  from unnest(p_item_ids) with ordinality as u(item_id, ord)
  where broker_packet_items.id = u.item_id and broker_packet_items.packet_id = p_packet_id;
  update public.broker_packet_items set display_order = -display_order
  where packet_id = p_packet_id and display_order < 0;
end;
$$;

create or replace function public.delete_broker_packet_draft(p_packet_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to delete broker packet drafts.';
  end if;
  if not exists (select 1 from public.broker_packets where id = p_packet_id and organization_id = public.current_org_id() and status = 'draft') then
    raise exception 'Draft broker packet not found in your organization.';
  end if;
  delete from public.broker_packet_items where packet_id = p_packet_id;
  delete from public.broker_packets where id = p_packet_id;
  perform public.log_activity('broker_packet'::public.entity_type, p_packet_id, 'broker_packet_draft_deleted', null);
end;
$$;

-- Draft -> generating: role/org/lock/requirements/snapshot/version, all in
-- one transaction. EIN and any bank/routing-style value are deliberately
-- never read into a snapshot -- carriers.ein exists on the source table
-- but is never selected here, mirroring 0087's identical omission.
create or replace function public.reserve_broker_packet(p_packet_id uuid)
returns table(packet_id uuid, packet_version integer)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_packet public.broker_packets;
  v_broker public.brokers;
  v_carrier public.carriers;
  v_org public.organizations;
  v_version integer;
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to generate broker packets.';
  end if;
  select * into v_packet from public.broker_packets where id = p_packet_id and organization_id = public.current_org_id() for update;
  if v_packet.id is null then raise exception 'Broker packet not found in your organization.'; end if;
  if v_packet.status <> 'draft' then raise exception 'Only a draft broker packet can be generated.'; end if;
  if v_packet.document_count < 1 then raise exception 'Select at least one document before generating.'; end if;

  if exists (
    select 1 from public.broker_packet_requirements r
    where r.broker_id = v_packet.broker_id and r.organization_id = v_packet.organization_id and r.is_required
      and not exists (select 1 from public.broker_packet_items i where i.packet_id = v_packet.id and i.document_type = r.document_type)
  ) then
    raise exception 'This broker packet is missing a required document type.';
  end if;

  select * into v_broker from public.brokers where id = v_packet.broker_id;
  select * into v_org from public.organizations where id = v_packet.organization_id;
  if v_packet.carrier_id is not null then
    select * into v_carrier from public.carriers where id = v_packet.carrier_id and organization_id = v_packet.organization_id and is_active;
    if v_carrier.id is null then raise exception 'The selected carrier must be active and belong to this organization.'; end if;
  end if;

  perform pg_advisory_xact_lock(hashtext(v_packet.organization_id::text), hashtext('broker-packet:' || v_packet.broker_id::text));
  select coalesce(max(version), 0) + 1 into v_version from public.broker_packets where broker_id = v_packet.broker_id and version is not null;

  update public.broker_packets set
    status = 'generating',
    version = v_version,
    generated_by = auth.uid(),
    organization_snapshot = jsonb_strip_nulls(jsonb_build_object(
      'name', v_org.name, 'dba_name', v_org.dba_name, 'mc_number', v_org.mc_number, 'dot_number', v_org.dot_number,
      'phone', v_org.business_phone, 'email', v_org.business_email,
      'address', nullif(concat_ws(', ', v_org.address_line1, v_org.address_line2, v_org.city, v_org.state, v_org.postal_code, v_org.country), ''),
      'logo_url', v_org.logo_url
    )),
    carrier_snapshot = case when v_carrier.id is null then null else jsonb_strip_nulls(jsonb_build_object(
      'legal_name', v_carrier.legal_name, 'dba_name', v_carrier.dba_name, 'mc_number', v_carrier.mc_number, 'dot_number', v_carrier.dot_number,
      'contact_name', v_carrier.contact_name, 'phone', v_carrier.phone, 'email', v_carrier.email,
      'address', nullif(concat_ws(', ', v_carrier.address_line1, v_carrier.address_line2, v_carrier.city, v_carrier.state, v_carrier.postal_code, v_carrier.country), ''),
      'factoring_company_name', v_carrier.factoring_company_name
    )) end,
    -- Broker MC/DOT are optional per 2M.2B decision 3: present when
    -- populated, cleanly absent otherwise (jsonb_strip_nulls), and never
    -- block reservation either way.
    broker_snapshot = jsonb_strip_nulls(jsonb_build_object(
      'legal_name', v_broker.legal_name, 'dba_name', v_broker.dba_name, 'mc_number', v_broker.mc_number, 'dot_number', v_broker.dot_number
    ))
  where id = p_packet_id;

  return query select v_packet.id, v_version;
end;
$$;

-- Service-role-only: called by the trusted server after the PDF is
-- rendered and uploaded. Deterministic path check mirrors 0087; the
-- generated_pdf_sha256 format is checked twice on purpose (the column
-- CHECK constraint is the ultimate authority, but failing fast here with
-- a clearer message is worth the duplication).
create or replace function public.finalize_broker_packet(
  p_packet_id uuid, p_storage_path text, p_file_size_bytes bigint,
  p_page_count integer, p_generated_pdf_sha256 text, p_item_results jsonb
) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_packet public.broker_packets; v_item jsonb; v_updated integer := 0; v_previous uuid; v_higher uuid; v_final_status public.broker_packet_status;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may finalize broker packets.'; end if;
  select * into v_packet from public.broker_packets where id = p_packet_id for update;
  if v_packet.id is null or v_packet.status <> 'generating' then raise exception 'Generating broker packet not found.'; end if;

  -- 2M.2C amendment: take the SAME advisory lock reserve_broker_packet()
  -- uses, keyed identically (org, 'broker-packet:'||broker_id). This is
  -- what actually makes the invariant "at most one current
  -- generated/sent packet per broker" hold under concurrency -- the row
  -- lock above only protects THIS packet's own row; two different
  -- packets finalizing for the SAME broker touch two different rows and
  -- would never otherwise contend with each other. Consistent lock
  -- order across both functions (own-row FOR UPDATE, acquired first,
  -- then this shared advisory key) means no two transactions ever need
  -- each other's held resource in the opposite order -- a single shared
  -- key queues callers, it cannot deadlock.
  perform pg_advisory_xact_lock(hashtext(v_packet.organization_id::text), hashtext('broker-packet:' || v_packet.broker_id::text));

  if p_storage_path <> format('%s/%s/%s/broker-packet-v%s.pdf', v_packet.organization_id, v_packet.broker_id, v_packet.id, v_packet.version) then
    raise exception 'Invalid broker packet storage path.';
  end if;
  if p_file_size_bytes <= 0 or p_file_size_bytes > 52428800 then raise exception 'Generated broker packet exceeds the 50 MB limit.'; end if;
  if p_page_count not between 1 and 250 then raise exception 'Generated broker packet exceeds the 250-page limit.'; end if;
  if p_generated_pdf_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'Generated PDF hash is not a valid lowercase SHA-256 value.'; end if;
  if jsonb_typeof(p_item_results) <> 'array' or jsonb_array_length(p_item_results) <> v_packet.document_count then
    raise exception 'Final item results are incomplete.';
  end if;

  for v_item in select value from jsonb_array_elements(p_item_results) loop
    update public.broker_packet_items set
      source_content_hash = v_item->>'source_content_hash',
      start_page = (v_item->>'start_page')::integer,
      end_page = (v_item->>'end_page')::integer
    where id = (v_item->>'item_id')::uuid and packet_id = v_packet.id
      and source_content_hash is null and start_page is null and end_page is null;
    v_updated := v_updated + found::integer;
  end loop;
  if v_updated <> v_packet.document_count then raise exception 'Final item results do not match broker packet items.'; end if;

  -- Bidirectional supersession, transactional with finalization, and now
  -- race-free thanks to the advisory lock above serializing every
  -- finalize call for this broker into a strict order:
  --
  --   1. If a HIGHER version for this broker already committed
  --      'generated'/'sent' (the out-of-order-completion case: v2
  --      finalized before v1), THIS packet goes straight to 'superseded'
  --      -- never exposed as 'generated'/current even momentarily. Its
  --      artifact is still fully written and immutable (the
  --      generated_shape CHECK already requires the full artifact for
  --      'superseded' too) -- only its final status differs from the
  --      normal path.
  --   2. Otherwise, this packet becomes the new 'generated' current
  --      version, and any EXISTING lower-version 'generated'/'sent'
  --      packets for this broker retire to 'superseded' (unchanged from
  --      the 2M.2B fix -- version < self, never id <> self).
  --
  -- Because the advisory lock makes every finalize for this broker fully
  -- serialize (acquire lock, decide, commit, release, next one
  -- acquires), there is no window where two finalizes can each decide
  -- "I am highest" independently -- whichever actually finalizes when a
  -- higher version already exists ALWAYS sees that fact truthfully. This
  -- is what closes the gap 2M.2B's version-ordering fix alone did not:
  -- that fix only ever stopped a lower version from wrongly superseding
  -- a higher one; it never stopped a lower version from independently
  -- becoming 'generated' (briefly) alongside an already-current higher
  -- one. This fix produces a strict, race-free total order: after every
  -- transaction settles, exactly one non-voided packet per broker is
  -- ever 'generated'/'sent', and it is always the highest version that
  -- ever successfully finished.
  select id into v_higher from public.broker_packets
  where broker_id = v_packet.broker_id and version > v_packet.version and status in ('generated', 'sent')
  limit 1;

  if v_higher is not null then
    v_final_status := 'superseded';
    update public.broker_packets set
      status = 'superseded', generated_storage_path = p_storage_path, generated_file_size_bytes = p_file_size_bytes,
      generated_pdf_sha256 = p_generated_pdf_sha256, page_count = p_page_count, generated_at = now(),
      superseded_by = v_higher, superseded_at = now()
    where id = v_packet.id;
  else
    v_final_status := 'generated';
    update public.broker_packets set
      status = 'generated', generated_storage_path = p_storage_path, generated_file_size_bytes = p_file_size_bytes,
      generated_pdf_sha256 = p_generated_pdf_sha256, page_count = p_page_count, generated_at = now()
    where id = v_packet.id;

    for v_previous in
      select id from public.broker_packets
      where broker_id = v_packet.broker_id and version < v_packet.version and status in ('generated', 'sent')
    loop
      update public.broker_packets set status = 'superseded', superseded_by = v_packet.id, superseded_at = now() where id = v_previous;
      perform public.log_activity('broker_packet'::public.entity_type, v_previous, 'broker_packet_superseded', jsonb_build_object('superseded_by', v_packet.id));
    end loop;
  end if;

  perform public.log_activity(
    'broker_packet'::public.entity_type, v_packet.id,
    case when v_final_status = 'superseded' then 'broker_packet_superseded' else 'broker_packet_generated' end,
    jsonb_build_object('version', v_packet.version, 'document_count', v_packet.document_count, 'superseded_by', v_higher)
  );
end;
$$;

create or replace function public.fail_broker_packet(p_packet_id uuid, p_failure_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may fail broker packets.'; end if;
  update public.broker_packets set
    status = 'failed', generated_storage_path = null, generated_file_size_bytes = null,
    generated_pdf_sha256 = null, page_count = null,
    failure_reason = left(coalesce(nullif(btrim(p_failure_reason), ''), 'Broker packet generation failed.'), 500)
  where id = p_packet_id and status = 'generating';
  if not found then raise exception 'Generating broker packet not found.'; end if;
  perform public.log_activity('broker_packet'::public.entity_type, p_packet_id, 'broker_packet_failed', null);
end;
$$;

create or replace function public.mark_broker_packet_sent(p_packet_id uuid, p_email_send_log_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_broker_id uuid; v_recipient_email text; v_recipient_name text;
begin
  select organization_id, broker_id into v_org, v_broker_id from public.broker_packets where id = p_packet_id for update;
  if v_org is null or v_org <> public.current_org_id() then raise exception 'Broker packet not found in your organization.'; end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then raise exception 'You do not have permission to send broker packets.'; end if;
  select recipient, metadata->>'recipient_name' into v_recipient_email, v_recipient_name
  from public.email_send_log where id = p_email_send_log_id and organization_id = v_org and broker_packet_id = p_packet_id and status = 'sent';
  if v_recipient_email is null then raise exception 'A successful broker packet email log is required.'; end if;
  update public.broker_packets set
    status = 'sent', last_sent_at = now(), last_sent_by = auth.uid(), last_email_send_log_id = p_email_send_log_id,
    last_sent_recipient_name = v_recipient_name, last_sent_recipient_email = v_recipient_email
  where id = p_packet_id and status in ('generated', 'sent');
  if not found then raise exception 'This broker packet cannot be marked sent.'; end if;
  perform public.log_activity('broker_packet'::public.entity_type, p_packet_id, 'broker_packet_sent', jsonb_build_object('broker_id', v_broker_id));
end;
$$;

create or replace function public.void_broker_packet(p_packet_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(array['owner','admin']::public.org_role[]) then raise exception 'Only owners and admins may void broker packets.'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A void reason is required.'; end if;
  update public.broker_packets set voided_at = now(), voided_by = auth.uid(), void_reason = left(btrim(p_reason), 500), status = 'voided'
  where id = p_packet_id and organization_id = public.current_org_id() and status in ('draft', 'generated', 'sent');
  if not found then raise exception 'Broker packet not found or cannot be voided.'; end if;
  perform public.log_activity('broker_packet'::public.entity_type, p_packet_id, 'broker_packet_voided', null);
end;
$$;

revoke execute on function public.create_broker_packet_draft(uuid,uuid) from public, anon;
revoke execute on function public.add_broker_packet_item(uuid,uuid) from public, anon;
revoke execute on function public.remove_broker_packet_item(uuid,uuid) from public, anon;
revoke execute on function public.reorder_broker_packet_items(uuid,uuid[]) from public, anon;
revoke execute on function public.delete_broker_packet_draft(uuid) from public, anon;
revoke execute on function public.reserve_broker_packet(uuid) from public, anon;
revoke execute on function public.finalize_broker_packet(uuid,text,bigint,integer,text,jsonb) from public, authenticated, anon;
revoke execute on function public.fail_broker_packet(uuid,text) from public, authenticated, anon;
revoke execute on function public.mark_broker_packet_sent(uuid,uuid) from public, anon;
revoke execute on function public.void_broker_packet(uuid,text) from public, anon;

grant execute on function public.create_broker_packet_draft(uuid,uuid) to authenticated;
grant execute on function public.add_broker_packet_item(uuid,uuid) to authenticated;
grant execute on function public.remove_broker_packet_item(uuid,uuid) to authenticated;
grant execute on function public.reorder_broker_packet_items(uuid,uuid[]) to authenticated;
grant execute on function public.delete_broker_packet_draft(uuid) to authenticated;
grant execute on function public.reserve_broker_packet(uuid) to authenticated;
grant execute on function public.finalize_broker_packet(uuid,text,bigint,integer,text,jsonb) to service_role;
grant execute on function public.fail_broker_packet(uuid,text) to service_role;
grant execute on function public.mark_broker_packet_sent(uuid,uuid) to authenticated;
grant execute on function public.void_broker_packet(uuid,text) to authenticated;

-- =============================================================================
-- Storage: dedicated private bucket, deliberately separate from
-- carrier-setup-packages (different business object, different
-- access/retention story -- see 2M.2A section 15).
-- =============================================================================
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('broker-packets', 'broker-packets', false, 52428800, array['application/pdf'])
on conflict (id) do nothing;

-- SELECT excludes viewer and driver on purpose (2M.2B decision 2): table-row
-- metadata is visible to viewer via broker_packets_select above, but the
-- actual PDF bytes are not.
create policy broker_packets_storage_select on storage.objects for select using (
  bucket_id = 'broker-packets' and (storage.foldername(name))[1] = public.current_org_id()::text
  and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
);
create policy broker_packets_storage_insert on storage.objects for insert with check (
  bucket_id = 'broker-packets' and (storage.foldername(name))[1] = public.current_org_id()::text
  and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
  and exists (
    select 1 from public.broker_packets p
    where p.id::text = (storage.foldername(name))[3]
      and p.organization_id = public.current_org_id()
      and p.broker_id::text = (storage.foldername(name))[2]
      and p.status = 'generating'
      and name = format('%s/%s/%s/broker-packet-v%s.pdf', p.organization_id, p.broker_id, p.id, p.version)
  )
);

-- =============================================================================
-- 2M.2C: polymorphic document referential integrity for entity_type in
-- ('carrier', 'organization') -- the two relationships Broker Packet's own
-- candidate eligibility (guard_broker_packet_item() above) relies on
-- besides 'broker', which 0094 already closed with
-- guard_broker_document_link_insert/update. Two independent guards, one
-- per relationship shape, since the two are not actually the same check:
--
--   'organization' documents are self-referential by construction
--   (entity_id names the SAME organization the document already belongs
--   to) -- documents.organization_id already carries a real, enforced FK
--   to organizations(id) on delete cascade, so there is nothing further
--   to look up or lock: the only possible defect is entity_id disagreeing
--   with organization_id, which is a same-row column comparison, not a
--   cross-table existence question. No lock needed, no race possible.
--
--   'carrier' documents need the same polymorphic-FK-substitute pattern
--   0094 used for brokers: FOR KEY SHARE on the referenced carriers row,
--   matching id + organization_id both, refusing the write if no such
--   row exists in this organization.
--
-- IMPORTANT LIMITATION, stated plainly rather than silently assumed
-- solved: unlike brokers, public.carriers has NO delete-boundary
-- protection today -- carriers was swept into the same 0010
-- standard_tables loop brokers originally was, and never received an
-- 0094-equivalent repair. A raw `DELETE FROM carriers` is still possible
-- for any owner/admin/dispatcher right now, with zero history check, and
-- this migration does not add one -- that would be a carriers-table
-- security repair fully analogous in shape to 0093->0094, and is not
-- "narrowly scoped" to Broker Packet's own needs. The guard below closes
-- everything that IS in scope and fully closeable from the documents
-- side:
--   - a document can never be linked to a random, foreign-org, or
--     already-nonexistent carrier (validated, and re-validated on every
--     relevant update)
--   - a document-insert racing a concurrent carrier deletion is decided
--     correctly by the FOR KEY SHARE / (implicit FOR UPDATE of a raw
--     DELETE) lock conflict, for that specific race window
-- What is NOT closed, because it cannot be from this side: a carrier
-- that already has documents referencing it can still be deleted
-- afterward at any later, non-concurrent moment, with zero history
-- check, immediately orphaning those documents -- exactly the situation
-- brokers were in before 0094 existed. Flagged as a remaining risk in
-- the accompanying report; recommend a dedicated future migration
-- mirroring 0094's two-layer shape for carriers, out of scope here.
-- =============================================================================
create or replace function public.guard_document_carrier_link()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (
    select 1 from public.carriers
    where id = new.entity_id and organization_id = new.organization_id
    for key share
  ) then
    raise exception 'Document references a carrier that does not exist in this organization.';
  end if;
  return new;
end;
$$;

comment on function public.guard_document_carrier_link() is
  'Before a documents row is inserted, or updated into/within entity_type=''carrier'', takes FOR KEY SHARE on the referenced carriers row (matching id + organization_id) and refuses the write if it does not exist -- the polymorphic equivalent of a real FK, mirroring guard_broker_document_link() (0094). Does not protect against a carrier being deleted AFTER documents already reference it -- carriers has no delete-boundary trigger; see this migration''s header comment on this section.';

create trigger guard_document_carrier_link_insert
  before insert on public.documents
  for each row when (new.entity_type = 'carrier')
  execute function public.guard_document_carrier_link();

create trigger guard_document_carrier_link_update
  before update on public.documents
  for each row when (
    new.entity_type = 'carrier'
    and (
      old.entity_type is distinct from 'carrier'
      or old.entity_id is distinct from new.entity_id
      or old.organization_id is distinct from new.organization_id
    )
  )
  execute function public.guard_document_carrier_link();

-- 'organization' documents: pure self-consistency, no lock needed (see
-- header comment above).
create or replace function public.guard_document_organization_link()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.entity_id <> new.organization_id then
    raise exception 'An organization-level document must reference its own organization.';
  end if;
  return new;
end;
$$;

comment on function public.guard_document_organization_link() is
  'Before a documents row is inserted, or updated into/within entity_type=''organization'', confirms entity_id equals organization_id. No existence lookup is needed: organization_id already carries a real FK to organizations(id) on delete cascade, so a mismatched entity_id is the only possible defect.';

create trigger guard_document_organization_link_insert
  before insert on public.documents
  for each row when (new.entity_type = 'organization')
  execute function public.guard_document_organization_link();

create trigger guard_document_organization_link_update
  before update on public.documents
  for each row when (
    new.entity_type = 'organization'
    and (
      old.entity_type is distinct from 'organization'
      or old.entity_id is distinct from new.entity_id
      or old.organization_id is distinct from new.organization_id
    )
  )
  execute function public.guard_document_organization_link();

revoke execute on function public.guard_document_carrier_link() from public, anon;
grant execute on function public.guard_document_carrier_link() to authenticated;
revoke execute on function public.guard_document_organization_link() from public, anon;
grant execute on function public.guard_document_organization_link() to authenticated;

-- =============================================================================
-- Email ledger association -- schema only, per instructions (no send UI
-- built this phase). Identical shape to 0087's carrier_setup_package_id
-- column/guard/index.
-- =============================================================================
alter table public.email_send_log
  add column broker_packet_id uuid references public.broker_packets(id) on delete restrict;

create index email_send_log_broker_packet_idx
  on public.email_send_log (broker_packet_id, sent_at desc)
  where broker_packet_id is not null;

create or replace function public.guard_email_send_log_broker_packet_org()
returns trigger language plpgsql set search_path = public as $$
declare v_org uuid;
begin
  if new.broker_packet_id is null then return new; end if;
  select organization_id into v_org from public.broker_packets where id = new.broker_packet_id;
  if v_org is null or v_org <> new.organization_id then
    raise exception 'Email broker packet must belong to the same organization.';
  end if;
  return new;
end;
$$;

create trigger email_send_log_broker_packet_org_guard
  before insert or update of broker_packet_id, organization_id on public.email_send_log
  for each row execute function public.guard_email_send_log_broker_packet_org();

alter table public.broker_packets
  add constraint broker_packets_last_email_send_log_fk
  foreign key (last_email_send_log_id) references public.email_send_log(id) on delete set null;

-- =============================================================================
-- CRITICAL: extend the shared broker-delete protected-history predicate.
-- This is the single most important statement in this migration -- see
-- Phase 2M.2A section 20 / this task's section J. broker_packets.broker_id
-- is a real FK (on delete restrict), so it also participates in the
-- automatic FOR KEY SHARE / FOR UPDATE lock conflict that already protects
-- loads/invoices/statements/carrier_setup_packages/email_send_log against
-- delete_broker_safely()'s `for update` lock -- no new concurrency gap,
-- unlike the documents case 0094 had to reason through separately.
--
-- ANY broker_packets row -- including a never-generated draft -- counts as
-- protected history. A draft is real, attributable staff work-in-progress
-- (created_by, timestamps, possibly selected items); silently allowing
-- broker deletion to detach it would violate the same "no partial/silent
-- loss of evidence" principle 0094 exists for. An authorized
-- delete_broker_packet_draft() call remains available to clear a draft
-- first if the broker genuinely needs to be deleted.
-- =============================================================================
create or replace function public.broker_has_protected_history(p_broker_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.loads where broker_id = p_broker_id)
      or exists(select 1 from public.invoices where broker_id = p_broker_id)
      or exists(select 1 from public.documents where entity_type = 'broker' and entity_id = p_broker_id)
      or exists(select 1 from public.statements where broker_id = p_broker_id)
      or exists(select 1 from public.carrier_setup_packages where broker_id = p_broker_id)
      or exists(select 1 from public.email_send_log where broker_id = p_broker_id)
      or exists(select 1 from public.broker_packets where broker_id = p_broker_id);
$$;

comment on function public.broker_has_protected_history(uuid) is
  'Single source of truth for whether a broker has protected operational/financial history (loads, invoices, broker documents, statements, carrier setup packages, broker-linked email history, or any broker packet -- including an undeleted draft). Used by both delete_broker_safely() and guard_broker_permanent_delete_trigger so the two checks cannot drift.';

comment on table public.broker_packets is 'Immutable, versioned broker-facing company/carrier profile packet history, keyed to a broker. Distinct business object from carrier_setup_packages (internal carrier onboarding); EIN and any bank/routing values are deliberately absent from every snapshot.';
comment on table public.broker_packet_items is 'Exact immutable source-document snapshot for a broker packet, including SHA-256 content hash and final PDF page range, populated only at finalize_broker_packet().';
comment on table public.broker_packet_requirements is 'Per-broker document checklist. Not historical -- freely editable at any time; a generated packet''s own frozen items are unaffected by later requirement changes.';
comment on column public.broker_packets.generated_pdf_sha256 is 'SHA-256 of the exact final assembled PDF bytes, computed before upload and frozen at finalize_broker_packet(). Distinct from broker_packet_items.source_content_hash (per-source-document hashes) -- both are kept because they prove different things: the item hashes prove which exact source files were included, this hash proves the exact final artifact a downloader receives.';
