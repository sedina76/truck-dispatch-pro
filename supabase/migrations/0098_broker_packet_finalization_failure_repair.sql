-- =============================================================================
-- 0098_broker_packet_finalization_failure_repair.sql
-- Phase 2M.2G: repair two independent, sequentially-unmasked defects in
-- finalize_broker_packet() / fail_broker_packet() (0095). Neither was
-- reachable before 0097 shipped, because reserve_broker_packet() never
-- successfully produced a real 'generating' packet until then.
--
-- DEFECT 1 -- public.guard_broker_packet_item_immutability() (0095) permits
-- item column changes only while the parent packet's status is 'draft';
-- every other status unconditionally raises "Generated broker packet items
-- are immutable." -- including finalize_broker_packet()'s own legitimate,
-- one-time write of source_content_hash/start_page/end_page while the
-- parent is 'generating' (lines 628-636 of 0095). Confirmed live: every
-- call to finalize_broker_packet() fails today, unconditionally.
--
-- The proven precedent is guard_carrier_setup_package_item_immutability()
-- (0087_carrier_setup_packages.sql): it permits changes specifically when
-- status = 'generating', then separately enforces write-once via
-- `old.source_content_hash is not null or old.start_page is not null or
-- old.end_page is not null`. 0095's trigger never had this carve-out.
--
-- Fix: split into three branches by parent status, matching the item
-- classification below (all 18 non-generated-value columns on
-- broker_packet_items were enumerated against the live 0095 table
-- definition before writing this):
--   A. Always immutable at every status: organization_id, packet_id,
--      document_id, document_type, source_filename, source_storage_bucket,
--      source_storage_path, source_mime_type, source_file_size_bytes,
--      source_created_at, source_expiry_date, source_verified_at,
--      included_at.
--   B. Draft-editable: display_order only (unchanged from 0095 -- the
--      existing draft branch is copied verbatim).
--   C. Finalization-populated, exactly once, only while status =
--      'generating': source_content_hash, start_page, end_page. Write-once
--      is enforced by requiring all three to be NULL beforehand -- mirrors
--      0087 exactly. display_order additionally freezes here (it is not
--      draft-editable once generating).
--   D. Fully immutable once status leaves 'generating'/'draft' (generated,
--      sent, superseded, failed, voided): unchanged catch-all raise.
-- No service-role bypass, trigger-disable mechanism, or session-variable
-- bypass is introduced -- the row's own parent status is what authorizes
-- the one-time write, exactly as instructed.
--
-- DEFECT 2 -- finalize_broker_packet() and fail_broker_packet() are both
-- service-role-only (auth.role() <> 'service_role' guard --confirmed via
-- grep to be the ONLY two service-role-gated functions anywhere in the
-- broker-packet surface of 0095; every other broker-packet RPC is
-- authenticated-session-only and unaffected). Both call log_activity()
-- with no explicit organization, so it falls back to current_org_id(),
-- which reads the caller's session/JWT claims -- always NULL for a
-- service-role caller with no user session. Confirmed live:
-- fail_broker_packet() aborts entirely with "null value in column
-- organization_id of relation activity_logs violates not-null
-- constraint" -- the whole transaction rolls back, the packet's status
-- never actually reaches 'failed'. Tracing forward, finalize_broker_packet
-- carries the SAME exposure at two more call sites (the 'superseded'
-- activity per retired sibling, and its own closing 'generated'/
-- 'superseded' activity) -- so fixing Defect 1 alone would still leave
-- finalize_broker_packet() 100% non-functional, aborting at its own
-- closing log_activity call instead.
--
-- This is the SAME bug class already fixed once before, for a different
-- caller, in 0044_driver_portal_upgrade.sql: log_activity() already grew a
-- backward-compatible 5th parameter, p_organization_id default null, for
-- exactly this reason (driver-portal's service-role client marking a
-- dispatch delivered). Confirmed live signature by inspecting every
-- create-or-replace of public.log_activity in the migration history
-- (0009: original 4-arg; 0044: added optional 5th p_organization_id;
-- 0046: identical repeat of the 5-arg version, idempotent guard for
-- environments where 0044 had not yet applied) -- no migration after 0046
-- redefines log_activity(), so the live signature is:
--   public.log_activity(p_entity_type public.entity_type, p_entity_id uuid,
--     p_action text, p_changes jsonb default null,
--     p_organization_id uuid default null) returns uuid
-- Carrier Setup Packages (0087) were independently checked and are NOT
-- affected -- finalize_carrier_setup_package()/fail_carrier_setup_package()
-- call no log_activity at all, so this defect is specific to 0095's new
-- code, not a pre-existing or widespread pattern.
--
-- Fix: call log_activity() at all three affected sites using named-argument
-- syntax with p_organization_id explicitly supplied from the packet row
-- already held in each function (v_packet.organization_id in
-- finalize_broker_packet(); captured via `returning organization_id into
-- v_org_id` on fail_broker_packet()'s existing UPDATE -- no extra SELECT,
-- no added round trip, same single-statement atomicity as before). Named
-- arguments are used specifically because they disambiguate against the
-- 4-arg overload by parameter name rather than by position, so a future
-- editor cannot silently regress this back onto the unsafe overload by
-- adding or removing a positional argument. No call site outside these two
-- functions is touched -- mark_broker_packet_sent() and void_broker_packet()
-- are authenticated-session-only and were independently confirmed to
-- resolve current_org_id() correctly; they are out of this repair's scope.
--
-- log_activity() itself is NOT modified -- its 5-arg overload already
-- exists and already does the right thing; only these two Broker Packet
-- call sites needed to actually use it.
--
-- FOURTH-DEFECT STATIC TRACE (Phase 2M.2G section 9): every remaining
-- lifecycle transition was re-traced against the CURRENT (0097-repaired)
-- guard_broker_packet_immutability() before writing this migration:
--   B. generating -> generated (finalize's own UPDATE): allowed by the
--      status-transition graph; the generated-artifact freeze block is
--      gated on `old.status <> 'generating'`, which is false here, so the
--      one-time artifact-field write is permitted. No defect.
--   C. sibling generated/sent -> superseded (finalize's retirement loop):
--      allowed by the transition graph for both 'generated' and 'sent'
--      old-statuses; the fields this UPDATE touches (status,
--      superseded_by, superseded_at) are not covered by any freeze check.
--      No defect.
--   D. generating -> failed (fail_broker_packet's UPDATE): allowed by the
--      transition graph; the generated-artifact freeze block is gated on
--      `old.status <> 'generating'`, false here, so nulling those fields
--      is permitted. No defect.
--   E. generated -> sent (mark_broker_packet_sent): allowed by the
--      transition graph; the fields it touches (last_sent_at,
--      last_sent_by, last_email_send_log_id, last_sent_recipient_name/
--      email) are not covered by any freeze check. No defect.
--   F. generated/sent -> voided (void_broker_packet): allowed by the
--      transition graph for both old-statuses; voided_at/voided_by/
--      void_reason are not covered by any freeze check. No defect.
-- No fourth structurally-guaranteed defect was found. This migration
-- contains exactly the two defects above and nothing else.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- DEFECT 1 REPAIR: item immutability trigger function.
-- ---------------------------------------------------------------------------
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
    -- Unchanged from 0095: draft-time mutation is limited to reordering.
    -- Every other identity field is still write-once even in draft, since
    -- it's set atomically by add_broker_packet_item() and never meant to
    -- be edited in place (removing and re-adding is the supported way to
    -- change a selection).
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

  if v_status = 'generating' then
    -- 0098 repair: this is finalize_broker_packet()'s own one-time write
    -- of the authoritative source_content_hash/start_page/end_page,
    -- mirroring guard_carrier_setup_package_item_immutability()'s proven
    -- 'generating' carve-out (0087) with the same write-once guard.
    -- display_order is NOT draft-editable here -- it is frozen the moment
    -- a packet leaves draft, same as every other identity/source field.
    if new.organization_id is distinct from old.organization_id or new.packet_id is distinct from old.packet_id
      or new.document_id is distinct from old.document_id or new.document_type is distinct from old.document_type
      or new.display_order is distinct from old.display_order
      or new.source_filename is distinct from old.source_filename or new.source_storage_bucket is distinct from old.source_storage_bucket
      or new.source_storage_path is distinct from old.source_storage_path or new.source_mime_type is distinct from old.source_mime_type
      or new.source_file_size_bytes is distinct from old.source_file_size_bytes or new.source_created_at is distinct from old.source_created_at
      or new.source_expiry_date is distinct from old.source_expiry_date or new.source_verified_at is distinct from old.source_verified_at
      or new.included_at is distinct from old.included_at then
      raise exception 'Only the one-time finalization hash and page range may be set while a broker packet is generating.';
    end if;
    if old.source_content_hash is not null or old.start_page is not null or old.end_page is not null then
      raise exception 'A broker packet item''s finalization values can only be written once.';
    end if;
    return new;
  end if;

  -- Every other status (generated, sent, superseded, failed, voided):
  -- unchanged from 0095, fully immutable.
  raise exception 'Generated broker packet items are immutable.';
end;
$$;

comment on function public.guard_broker_packet_item_immutability() is
  'Enforces broker_packet_items lifecycle integrity at the row boundary. Draft: display_order only is mutable (0095, unchanged). Generating: source_content_hash/start_page/end_page populate exactly once, from NULL, and every other column stays frozen (0098 repair -- this carve-out did not previously exist, so finalize_broker_packet() could never actually write these values). Every other status: fully immutable.';

-- No trigger recreation needed: broker_packet_items_immutability_guard
-- already references this function by name; CREATE OR REPLACE FUNCTION
-- updates its behavior in place.

-- ---------------------------------------------------------------------------
-- DEFECT 2 REPAIR: finalize_broker_packet() -- identical to 0095 except
-- the two log_activity() calls now explicitly pass p_organization_id.
-- ---------------------------------------------------------------------------
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
      -- 0098 repair: explicit p_organization_id -- this function is
      -- service-role-only, so current_org_id() (the 4-arg overload's
      -- fallback) is always NULL here. See migration header.
      perform public.log_activity(
        p_entity_type := 'broker_packet'::public.entity_type, p_entity_id := v_previous, p_action := 'broker_packet_superseded',
        p_changes := jsonb_build_object('superseded_by', v_packet.id), p_organization_id := v_packet.organization_id
      );
    end loop;
  end if;

  -- 0098 repair: same explicit p_organization_id fix as above.
  perform public.log_activity(
    p_entity_type := 'broker_packet'::public.entity_type, p_entity_id := v_packet.id,
    p_action := case when v_final_status = 'superseded' then 'broker_packet_superseded' else 'broker_packet_generated' end,
    p_changes := jsonb_build_object('version', v_packet.version, 'document_count', v_packet.document_count, 'superseded_by', v_higher),
    p_organization_id := v_packet.organization_id
  );
end;
$$;

comment on function public.finalize_broker_packet(uuid,text,bigint,integer,text,jsonb) is
  'Service-role-only: generating -> generated/superseded, atomic with source-hash population, bidirectional supersession, and advisory-lock serialization. Activity logging explicitly supplies p_organization_id (0098 repair) since this path never has a user session for current_org_id() to resolve.';

-- ---------------------------------------------------------------------------
-- DEFECT 2 REPAIR: fail_broker_packet() -- identical semantics to 0095
-- (generating -> failed, same artifact-nulling, same failure_reason
-- handling) except the UPDATE now captures organization_id via RETURNING
-- (no extra SELECT/lock -- same single-statement atomicity as before) and
-- the log_activity() call explicitly supplies it.
-- ---------------------------------------------------------------------------
create or replace function public.fail_broker_packet(p_packet_id uuid, p_failure_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_org_id uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may fail broker packets.'; end if;
  update public.broker_packets set
    status = 'failed', generated_storage_path = null, generated_file_size_bytes = null,
    generated_pdf_sha256 = null, page_count = null,
    failure_reason = left(coalesce(nullif(btrim(p_failure_reason), ''), 'Broker packet generation failed.'), 500)
  where id = p_packet_id and status = 'generating'
  returning organization_id into v_org_id;
  if not found then raise exception 'Generating broker packet not found.'; end if;
  -- 0098 repair: explicit p_organization_id -- see migration header.
  perform public.log_activity(
    p_entity_type := 'broker_packet'::public.entity_type, p_entity_id := p_packet_id, p_action := 'broker_packet_failed',
    p_changes := null, p_organization_id := v_org_id
  );
end;
$$;

comment on function public.fail_broker_packet(uuid,text) is
  'Service-role-only: generating -> failed, nulls artifact fields, freezes failure_reason. Activity logging explicitly supplies p_organization_id (0098 repair), captured via RETURNING on the same UPDATE -- no added round trip.';

-- No grant/revoke changes: CREATE OR REPLACE FUNCTION with unchanged
-- signatures preserves the existing ACLs from 0095 untouched --
-- guard_broker_packet_item_immutability() is a trigger function (no direct
-- grants), finalize_broker_packet(uuid,text,bigint,integer,text,jsonb) and
-- fail_broker_packet(uuid,text) both remain revoked from
-- public/authenticated/anon and granted only to service_role.
