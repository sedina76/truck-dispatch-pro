-- =============================================================================
-- VERIFY_0099_PREFLIGHT.sql
-- Phase 2N.2 -- read-only preflight for the Carrier W-9 migration
-- (0099_carrier_w9.sql). Run this BEFORE applying 0099. Every query here
-- is a plain SELECT -- nothing here mutates anything.
-- =============================================================================

-- 1. Confirm 0099 is not already partially applied (objects should NOT exist yet).
select
  exists (select 1 from pg_type where typname = 'carrier_w9_status') as carrier_w9_status_type_exists,
  exists (select 1 from pg_type where typname = 'w9_tax_classification') as w9_tax_classification_type_exists,
  exists (select 1 from pg_type where typname = 'w9_tin_type') as w9_tin_type_exists,
  exists (select 1 from pg_class where relname = 'carrier_w9s' and relkind = 'r') as carrier_w9s_table_exists,
  exists (select 1 from pg_class where relname = 'carrier_w9_pii_access_log' and relkind = 'r') as carrier_w9_pii_access_log_exists,
  exists (select 1 from pg_proc where proname = 'finalize_carrier_w9') as finalize_carrier_w9_exists,
  exists (select 1 from storage.buckets where id = 'carrier-w9s') as carrier_w9s_bucket_exists,
  exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'entity_type' and e.enumlabel = 'carrier_w9') as entity_type_has_carrier_w9;
-- Expected: every column false. If any is true, 0099 (or a same-named
-- object created some other way) may already be partially live -- STOP
-- and report before applying.

-- 2. Confirm no existing 'w9' documents would collide with anything 0099
-- assumes (it does not delete/modify any existing documents row -- this
-- is purely informational).
select count(*) as existing_w9_documents,
  count(*) filter (where entity_type = 'carrier') as existing_w9_documents_on_carrier,
  count(*) filter (where entity_type = 'carrier_onboarding_application') as existing_w9_documents_on_application
from public.documents where document_type = 'w9';

-- 3. Confirm the reusable EIN/TIN encryption prerequisites (0014/0081)
-- are actually live -- 0099 depends on all three existing already.
select
  exists (select 1 from pg_proc where proname = 'get_app_encryption_key') as get_app_encryption_key_exists,
  exists (select 1 from public.app_encryption_keys where key_name = 'carrier_pii_key') as carrier_pii_key_exists,
  exists (select 1 from pg_extension where extname = 'pgcrypto') as pgcrypto_extension_exists;
-- Expected: all three true. If any is false, 0099 will fail at apply
-- time (get_app_encryption_key('carrier_pii_key') would return NULL,
-- making pgp_sym_encrypt fail) -- STOP and report before applying.

-- 4. Confirm document_type already has 'w9' (0099 does not add it --
-- it's expected to already exist).
select exists (
  select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'document_type' and e.enumlabel = 'w9'
) as document_type_has_w9;
-- Expected: true.

-- 5. Confirm entity_type already has the values 0099's finalize/convert
-- functions reference ('carrier', 'carrier_onboarding_application') --
-- both predate this migration (0081) and should already exist.
select enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid
where t.typname = 'entity_type' and e.enumlabel in ('carrier', 'carrier_onboarding_application')
order by enumlabel;
-- Expected: both rows present.

-- 6. Confirm convert_carrier_onboarding_application(uuid) is currently
-- exactly the 0086 version (0099 replaces it) -- a live diff mismatch
-- here means something changed it since 0086 that this migration's
-- CREATE OR REPLACE would silently discard. Compare row count/behavior
-- manually if this returns unexpected content; this query only surfaces
-- the current live source for review.
select prosrc from pg_proc where proname = 'convert_carrier_onboarding_application';

-- 7. Confirm no unexpected duplicate "current" W-9 candidates could exist
-- (trivially true pre-apply since the table doesn't exist yet -- included
-- for symmetry/documentation and to be rerun harmlessly after apply too).
select 'carrier_w9s does not exist yet -- no duplicate-current check possible pre-apply' as note
where not exists (select 1 from pg_class where relname = 'carrier_w9s');

-- 8. Confirm no other migration file has already claimed 0099 or a
-- higher number than expected (run this from the shell, not SQL --
-- included here as a reminder): `ls supabase/migrations | sort -V | tail -5`
-- should show 0098 as the highest existing file before 0099 is applied.

-- 9. Storage bucket name collision check (should be free).
select id, public, file_size_limit from storage.buckets where id = 'carrier-w9s';
-- Expected: zero rows.

-- 10. Confirm current_role() and has_role() exist and are callable (0099's
-- RPCs depend on both, same as every other feature in this schema).
select
  exists (select 1 from pg_proc where proname = 'current_role') as current_role_exists,
  exists (select 1 from pg_proc where proname = 'has_role') as has_role_exists,
  exists (select 1 from pg_proc where proname = 'current_org_id') as current_org_id_exists,
  exists (select 1 from pg_proc where proname = 'log_activity' and pronargs = 5) as log_activity_5arg_exists;
-- Expected: all four true.

-- 11. (2N.2A) Confirm documents.storage_bucket does NOT already exist
-- under a different meaning -- 0099 adds it as `not null default
-- 'documents'`; if a column with this exact name already exists with
-- different semantics, STOP and report before applying.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'documents' and column_name = 'storage_bucket';
-- Expected: zero rows (column does not exist yet).

-- 12. (2N.2A) Confirm guard_broker_packet_item()/add_broker_packet_item()
-- (0095) are UNCHANGED from their original hardcoded-'documents' form --
-- 0099 does NOT touch either function; this is purely a live confirmation
-- that nothing else has changed them since 0095/0098, which would affect
-- how the future Broker-Packet-multi-bucket repair migration should be
-- designed.
select
  (select prosrc like '%source_storage_bucket <> ''documents''%' from pg_proc where proname = 'guard_broker_packet_item') as guard_still_hardcodes_documents_bucket,
  (select prosrc like '%''documents'', v_document.file_path%' from pg_proc where proname = 'add_broker_packet_item') as insert_still_hardcodes_documents_literal;
-- Expected: both true (unchanged from 0095) -- confirms the future repair
-- migration's design (documented in the 2N.2A report) is still accurate.
