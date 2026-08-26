-- =============================================================================
-- VERIFY_0100_POST_APPLY.sql
-- Phase 2N.2B -- read-only post-apply verification for
-- supabase/migrations/0100_broker_packet_multi_bucket_documents.sql.
-- Run this immediately after applying 0100. Every query here is a plain
-- SELECT except the final, clearly-marked disposable-fixture live tests
-- (sections 6-8), which use only TEST-2N2B-* data and clean up after
-- themselves.
-- =============================================================================

-- 1. Function definitions/signatures/grants unchanged from 0095 (only
-- prosrc should differ).
select p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef,
  has_function_privilege('authenticated', p.oid, 'execute') as authenticated_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('guard_broker_packet_item', 'add_broker_packet_item')
order by p.proname;
-- Expected: guard_broker_packet_item -- trigger function, no direct
-- EXECUTE grant meaningfully checked (it's fired by the trigger, not
-- called directly). add_broker_packet_item -- authenticated_can_execute = true
-- (unchanged from 0095).

-- 2. Bucket allowlist present, cross-check present.
select
  prosrc like '%new.source_storage_bucket not in (''documents'', ''carrier-w9s'')%' as has_explicit_allowlist,
  prosrc like '%new.source_storage_bucket is distinct from v_document.storage_bucket%' as has_bucket_document_cross_check
from pg_proc where proname = 'guard_broker_packet_item';
-- Expected: both true.

-- 3. add_broker_packet_item() reads the real column, no longer hardcodes.
select
  prosrc like '%v_document.file_name, v_document.storage_bucket, v_document.file_path%' as reads_real_storage_bucket,
  prosrc like '%''documents'', v_document.file_path%' as still_has_old_hardcoded_literal
from pg_proc where proname = 'add_broker_packet_item';
-- Expected: reads_real_storage_bucket = true, still_has_old_hardcoded_literal = false.

-- 4. Ordinary-documents regression, structural: every historical
-- broker_packet_items row (created before 0100) still shows
-- source_storage_bucket='documents' -- 0100 does not rewrite any existing
-- row, only affects future INSERTs.
select source_storage_bucket, count(*) from public.broker_packet_items group by source_storage_bucket order by 1;
-- Expected: overwhelmingly 'documents'; 'carrier-w9s' only appears on
-- items added AFTER 0100, never on historical rows that predate it
-- (compare created_at/included_at against 0100's apply time if in doubt).

-- 5. No accidental overload / no unexpected second trigger.
select count(*) from pg_trigger where tgrelid = 'public.broker_packet_items'::regclass and tgtype & 2 = 2; -- BEFORE triggers
-- Expected: same count as before 0100 (this migration adds no new trigger).

-- =============================================================================
-- 6-8: live disposable-fixture acceptance (TEST-2N2B-* only). Run these
-- as a service-role script, not raw SQL, since they need real PDF bytes,
-- real Storage uploads, and a real authenticated session -- included here
-- as the exact scenario list this file's existence promises to verify,
-- for the live acceptance pass that follows 0100's application.
-- =============================================================================

-- 6. W-9 consumption flow (design, executed live in the follow-up
-- acceptance session, not as raw SQL here):
--   1. Complete a TEST-2N2B-* W-9 -> confirm its documents row has
--      storage_bucket='carrier-w9s'.
--   2. Create a Broker Packet draft for a real (test) carrier-linked broker.
--   3. Confirm the W-9 appears as a Broker Packet candidate.
--   4. add_broker_packet_item() the W-9 -> confirm
--      broker_packet_items.source_storage_bucket='carrier-w9s'.
--   5. Generate the packet -> confirm the renderer downloaded the exact
--      W-9 bytes from carrier-w9s (source_content_hash equals an
--      independently computed SHA-256 of those exact bytes).
--   6. Confirm the merged Broker Packet PDF contains the W-9's pages at
--      the item's own recorded page range.
--   7. Confirm NO call to reveal_carrier_w9_tin() occurred (check
--      carrier_w9_pii_access_log has zero new rows for this W-9).
--   8. Confirm the original carrier-w9s object's bytes are unchanged
--      (re-download, re-hash, compare to carrier_w9s.generated_pdf_sha256).

-- 7. Mixed-source packet (one 'documents' item + one 'carrier-w9s' item):
-- confirm both appear in display_order, both hashes correct, page ranges
-- correct, final PDF contains both in the right order, no bucket
-- confusion (each item downloaded from ITS OWN recorded bucket).

-- 8. Tamper cases (each expected to be rejected by
-- guard_broker_packet_item()'s new checks):
--   a. A broker_packet_items row inserted with source_storage_bucket=
--      'carrier-w9s' while the referenced documents row says
--      storage_bucket='documents' -- rejected by the cross-check.
--   b. The reverse mismatch -- also rejected.
--   c. A documents row with storage_bucket='some-random-bucket' --
--      rejected by the allowlist check, regardless of what the item
--      claims.
--   d. Confirm add_broker_packet_item(p_packet_id, p_document_id) has no
--      third parameter for bucket at all -- a client cannot override it
--      even in principle:
select pg_get_function_identity_arguments(oid) from pg_proc where proname = 'add_broker_packet_item';
-- Expected: exactly "p_packet_id uuid, p_document_id uuid" -- no bucket parameter.

-- 9. Full Broker Packet regression (executed live, not raw SQL): add
-- item, reserve, generate, finalize, v1->v2 supersession, out-of-order
-- finalization, item immutability, source hash, historical download,
-- email/send -- re-run the SAME matrix already proven in Phase
-- 2M.2D/2M.3/2M.4, to confirm 0100 changes nothing about ordinary
-- (documents-bucket) Broker Packet behavior.
