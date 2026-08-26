-- =============================================================================
-- 0097_broker_packet_immutability_reservation_repair.sql
-- Phase 2M.2F: repair guard_broker_packet_immutability() (0095) -- its
-- identity/snapshot freeze block rejects the legitimate draft -> generating
-- reservation transition unconditionally, for every packet, with or without
-- a carrier. This defect was never visible before because 0096's fix was a
-- precondition for reaching it: reserve_broker_packet()'s UPDATE previously
-- failed to even parse (the factoring_company_name column-reference bug),
-- so this trigger never got to run against a real transition until now.
--
-- Root cause: the block below has no condition on old.status at all --
-- it treats populating version/organization_snapshot/carrier_snapshot/
-- broker_snapshot/generated_by for the FIRST time (NULL -> a real value,
-- exactly what reserve_broker_packet() does) identically to mutating them
-- after the fact, and rejects both:
--
--   if new.organization_id is distinct from old.organization_id
--     or new.broker_id is distinct from old.broker_id
--     or new.carrier_id is distinct from old.carrier_id
--     or new.version is distinct from old.version
--     or new.organization_snapshot is distinct from old.organization_snapshot
--     or new.carrier_snapshot is distinct from old.carrier_snapshot
--     or new.broker_snapshot is distinct from old.broker_snapshot
--     or new.generated_by is distinct from old.generated_by
--     or new.created_by is distinct from old.created_by
--     or new.created_at is distinct from old.created_at then
--     raise exception 'A broker packet''s frozen identity and snapshots cannot be changed.';
--   end if;
--
-- Fix: split this single block into two, by lifecycle intent, rather than
-- broadly gating the whole thing on old.status <> 'draft' (which would
-- also legalize draft-time reassignment of organization_id/broker_id/
-- created_by/created_at -- exactly the ownership/audit fields that must
-- never move, checked and audited against current application/RPC code
-- before writing this):
--
--   A. ALWAYS immutable, from the moment a row is inserted, regardless of
--      status: organization_id, broker_id, carrier_id, created_by,
--      created_at. Audited every RPC (create_broker_packet_draft,
--      add_broker_packet_item, remove_broker_packet_item,
--      reorder_broker_packet_items, delete_broker_packet_draft,
--      reserve_broker_packet, finalize_broker_packet, fail_broker_packet,
--      mark_broker_packet_sent, void_broker_packet) and the application
--      code in src/app/(app)/brokers/[id]/packets/ -- carrier_id is set
--      exactly once, at create_broker_packet_draft()'s INSERT, and no RPC
--      or application code path ever updates it afterward. There is no
--      legitimate draft-time carrier-reassignment flow, so carrier_id
--      stays in this group rather than being made draft-mutable.
--
--   B. Populated exactly once, during the draft -> generating reservation,
--      then frozen: version, organization_snapshot, carrier_snapshot,
--      broker_snapshot, generated_by. Mirrors the EXACT pattern the very
--      next check in this same function already uses correctly for
--      document_count (`and old.status <> 'draft'`) -- that check was
--      never broken; this repair simply brings the identity block's
--      snapshot fields in line with the pattern the function's own author
--      already got right one check later.
--
-- Everything else in this function -- the document_count freeze, the
-- generated-artifact freeze (already correctly scoped to
-- old.status <> 'generating'), and the full status-transition graph -- is
-- unchanged. Both were independently re-traced against every legitimate
-- lifecycle transition (draft->generating, generating->generated,
-- generating->superseded, generating->failed, generated->sent,
-- generated->superseded, generated->voided, sent->superseded,
-- sent->voided, draft->voided) before writing this migration and found
-- structurally sound -- no third defect identified. See the accompanying
-- Phase 2M.2F report for the full trace.
-- =============================================================================

create or replace function public.guard_broker_packet_immutability()
returns trigger language plpgsql set search_path = public as $$
begin
  -- A. Always immutable from insert onward, at every status -- ownership
  -- and audit identity, never editable through any path.
  if new.organization_id is distinct from old.organization_id
    or new.broker_id is distinct from old.broker_id
    or new.carrier_id is distinct from old.carrier_id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at then
    raise exception 'A broker packet''s identity cannot be changed.';
  end if;

  -- B. Reservation-populated fields: legitimately transition once, from
  -- their NULL draft-state values to authoritative values, during
  -- draft -> generating (old.status = 'draft', so this check does not
  -- fire); frozen for every subsequent update once the row has left
  -- draft. Same shape as the document_count check immediately below,
  -- which was already correct.
  if old.status <> 'draft'
    and (
      new.version is distinct from old.version
      or new.organization_snapshot is distinct from old.organization_snapshot
      or new.carrier_snapshot is distinct from old.carrier_snapshot
      or new.broker_snapshot is distinct from old.broker_snapshot
      or new.generated_by is distinct from old.generated_by
    ) then
    raise exception 'A broker packet''s reservation snapshot cannot be changed once assigned.';
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

comment on function public.guard_broker_packet_immutability() is
  'Enforces broker_packets lifecycle integrity at the row boundary, independent of caller (including the trusted reservation/finalization RPCs -- no SECURITY DEFINER or role-based bypass exists here by design). organization_id/broker_id/carrier_id/created_by/created_at are immutable from insert onward. version/organization_snapshot/carrier_snapshot/broker_snapshot/generated_by populate exactly once during draft -> generating (0097 repair) and are frozen thereafter. document_count freezes once a packet leaves draft. Generated-artifact fields populate exactly once during generating -> generated/superseded and are frozen thereafter. The status-transition graph is enforced last.';

-- No trigger recreation needed: broker_packets_immutability_guard already
-- references this function by name; CREATE OR REPLACE FUNCTION updates its
-- behavior in place.
