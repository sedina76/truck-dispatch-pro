-- =============================================================================
-- VERIFY_0100_PREFLIGHT.sql
-- Phase 2N.2B -- read-only preflight for
-- supabase/migrations/0100_broker_packet_multi_bucket_documents.sql.
-- Run this AFTER 0099 is applied and BEFORE 0100 is applied. Every query
-- here is a plain SELECT -- nothing here mutates anything.
-- =============================================================================

-- 1. Confirm the ordering dependency: documents.storage_bucket must
-- already exist (0099) before 0100 can be applied at all.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'documents' and column_name = 'storage_bucket';
-- Expected: one row, is_nullable=NO, default mentioning 'documents'. If
-- zero rows, 0099 has NOT been applied yet -- STOP, apply 0099 first.

-- 2. Confirm the exact current (pre-0100) hardcoded single-bucket
-- assumptions still match what 0100 expects to replace -- if either of
-- these has already changed since 0095/0098 (by some other means), the
-- diff this migration performs would be wrong.
select
  (select prosrc like '%if new.source_storage_bucket <> ''documents'' then%' from pg_proc where proname = 'guard_broker_packet_item') as guard_still_single_literal_check,
  (select prosrc like '%v_document.file_name, ''documents'', v_document.file_path%' from pg_proc where proname = 'add_broker_packet_item') as add_item_still_hardcodes_literal;
-- Expected: both true.

-- 3. Confirm no unexpected storage_bucket values already exist on
-- documents that 0100's allowlist doesn't anticipate (informational --
-- 0100 does not reject existing rows, only future broker_packet_items
-- inserts, but an unexpected value here means the allowlist should be
-- widened before relying on it).
select storage_bucket, count(*) from public.documents group by storage_bucket order by 1;
-- Expected: 'documents' (the overwhelming majority) and, once any W-9 has
-- been generated, 'carrier-w9s'. Any other value is unexpected -- investigate.

-- 4. Confirm no conflicting overload of either function already exists
-- (both should have exactly one signature, matching 0095's).
select proname, pg_get_function_identity_arguments(oid) as args, count(*) over (partition by proname)
from pg_proc where proname in ('guard_broker_packet_item', 'add_broker_packet_item');
-- Expected: exactly one row per function name (no accidental overload).

-- 5. Confirm the trigger binding is still exactly what 0100 assumes it
-- will continue to reference by name (no trigger recreation happens in
-- 0100 -- it relies on broker_packet_items_guard already pointing at
-- guard_broker_packet_item() by name).
select tgname, tgrelid::regclass, tgfoid::regproc from pg_trigger
where tgname = 'broker_packet_items_guard';
-- Expected: one row, tgrelid = broker_packet_items, tgfoid = guard_broker_packet_item.

-- 6. Confirm at least one real W-9 document exists to actually exercise
-- multi-bucket acceptance post-apply (optional -- informational only; a
-- fresh TEST-* W-9 can also be generated as part of live acceptance).
select count(*) from public.documents where document_type = 'w9' and storage_bucket = 'carrier-w9s';
