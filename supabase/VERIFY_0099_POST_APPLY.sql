-- =============================================================================
-- VERIFY_0099_POST_APPLY.sql
-- Phase 2N.2 -- read-only post-apply verification for
-- supabase/migrations/0099_carrier_w9.sql. Run this immediately after
-- applying 0099. Every query here is a plain SELECT.
-- =============================================================================

-- 1. Enums/types exist with the expected values.
select enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'carrier_w9_status' order by enumsortorder;
-- Expected: draft, completed, superseded, voided, failed (5 rows).
select enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'w9_tax_classification' order by enumsortorder;
-- Expected: 7 rows (individual_sole_proprietor..other).
select enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'w9_tin_type' order by enumsortorder;
-- Expected: ssn, ein.
select exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'entity_type' and e.enumlabel = 'carrier_w9') as entity_type_has_carrier_w9;
-- Expected: true.

-- 2. Table/columns exist.
select column_name, data_type, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'carrier_w9s' order by ordinal_position;
select column_name, data_type, is_nullable from information_schema.columns
where table_schema = 'public' and table_name = 'carrier_w9_pii_access_log' order by ordinal_position;

-- 3. Constraints (subject relationship, generated shape, void shape, supersede shape).
select conname, pg_get_constraintdef(oid) from pg_constraint
where conrelid = 'public.carrier_w9s'::regclass and contype = 'c' order by conname;
-- Expected: carrier_w9s_has_subject, carrier_w9s_generated_shape,
-- carrier_w9s_void_shape, carrier_w9s_supersede_shape, plus the inline
-- CHECKs on llc_classification/tin_last4/generated_pdf_sha256/
-- generated_file_size_bytes/page_count.

-- 4. Indexes (implicit from PK/unique + explicit).
select indexname, indexdef from pg_indexes where schemaname = 'public' and tablename = 'carrier_w9s';

-- 5. RLS enabled + policies.
select relrowsecurity from pg_class where relname = 'carrier_w9s';
-- Expected: true.
select policyname, cmd, qual, with_check from pg_policies where schemaname = 'public' and tablename = 'carrier_w9s' order by policyname;
select policyname, cmd, qual from pg_policies where schemaname = 'public' and tablename = 'carrier_w9_pii_access_log' order by policyname;

-- 6. Column grants -- tin_encrypted must NOT appear in the authenticated
-- SELECT grant list; every other column should.
select grantee, privilege_type, string_agg(column_name, ', ' order by column_name) as columns
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'carrier_w9s' and grantee = 'authenticated'
group by grantee, privilege_type order by privilege_type;
-- Expected: SELECT list does NOT include tin_encrypted; INSERT list is
-- limited to id/organization_id/onboarding_application_id/carrier_id/
-- created_by; UPDATE list is limited to status.
select exists (
  select 1 from information_schema.column_privileges
  where table_schema = 'public' and table_name = 'carrier_w9s' and grantee = 'authenticated'
    and privilege_type = 'SELECT' and column_name = 'tin_encrypted'
) as tin_encrypted_is_selectable_by_authenticated;
-- Expected: false. This is the single most important row in this file.

-- 7. RPC existence + grants (service_role-only vs authenticated+service_role vs authenticated-only).
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
  has_function_privilege('authenticated', p.oid, 'execute') as authenticated_can_execute,
  has_function_privilege('service_role', p.oid, 'execute') as service_role_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in (
  'create_carrier_w9_draft', 'update_carrier_w9_draft', 'set_carrier_w9_tin', 'certify_carrier_w9',
  'finalize_carrier_w9', 'fail_carrier_w9', 'void_carrier_w9', 'delete_carrier_w9_draft', 'reveal_carrier_w9_tin'
) order by p.proname;
-- Expected: finalize_carrier_w9 and fail_carrier_w9 -> authenticated=false,
-- service_role=true. reveal_carrier_w9_tin -> authenticated=true,
-- service_role=false (staff-only, no service-role grant at all). Every
-- other function -> both true.

-- 8. Encryption boundary: reveal_carrier_w9_tin is SECURITY DEFINER and
-- uses carrier_pii_key (not a new key).
select prosecdef, prosrc like '%carrier_pii_key%' as uses_carrier_pii_key, prosrc like '%p_reason is null or btrim(p_reason) = ''''%' as requires_nonblank_reason
from pg_proc where proname = 'reveal_carrier_w9_tin';
-- Expected: prosecdef=true, uses_carrier_pii_key=true, requires_nonblank_reason=true.

-- 9. Status graph / immutability guard present and structurally correct.
select
  prosrc like '%old.certified_at is not null and (%' as freezes_after_certification,
  prosrc like '%old.status <> ''draft'' and (%new.generated_storage_path%' as freezes_artifact_after_draft,
  prosrc like '%Superseded, voided, and failed W-9 records are terminal%' as enforces_terminal_states
from pg_proc where proname = 'guard_carrier_w9_immutability';

-- 10. Storage bucket created correctly.
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'carrier-w9s';
-- Expected: public=false, file_size_limit=52428800, allowed_mime_types={application/pdf}.
-- Confirm NO storage.objects policy exists for this bucket (service-role/
-- signed-URL only, matching every other private bucket in this schema):
select policyname, qual from pg_policies where schemaname = 'storage' and tablename = 'objects' and qual ilike '%carrier-w9s%';
-- Expected: zero rows.

-- 11. Conversion integration: convert_carrier_onboarding_application still
-- has its original 0086 ACL (unchanged signature) and now references
-- carrier_w9s.
select has_function_privilege('authenticated', 'public.convert_carrier_onboarding_application(uuid)', 'execute') as authenticated_can_execute;
-- Expected: true (unchanged from 0086).
select prosrc like '%carrier_w9s%' as references_carrier_w9s, prosrc like '%v_w9_document_id%' as re_links_document
from pg_proc where proname = 'convert_carrier_onboarding_application';
-- Expected: both true.

-- 12. Live functional smoke (safe, no mutation -- calling with a
-- nonexistent id proves the function runs and its guard clauses fire
-- correctly without ever touching real data):
select public.reveal_carrier_w9_tin('00000000-0000-0000-0000-000000000000'::uuid, 'post-apply smoke test');
-- Expected: raises 'W-9 record not found in your organization.' (proves
-- the function executes, resolves current_org_id(), and correctly finds
-- no row -- never a raw Postgres error).

-- =============================================================================
-- 2N.2A additions below
-- =============================================================================

-- 13. documents.storage_bucket exists, correct shape, existing rows
-- default to 'documents' with zero backfill needed.
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'documents' and column_name = 'storage_bucket';
-- Expected: one row, is_nullable=NO, column_default mentioning 'documents'.
select count(*) as total_documents, count(*) filter (where storage_bucket = 'documents') as defaulted_to_documents
from public.documents;
-- Expected: total_documents = defaulted_to_documents for every row that
-- existed before 0099 (any mismatch means something already wrote a
-- non-default value -- investigate before trusting the default assumption
-- elsewhere).

-- 14. A generated W-9 document (if any exist yet) correctly records
-- storage_bucket = 'carrier-w9s', never 'documents'.
select id, entity_type, entity_id, storage_bucket, file_path from public.documents where document_type = 'w9';
-- Expected: every row's storage_bucket = 'carrier-w9s'.

-- 15. Broker Packet W-9 eligibility (EXPECTED STILL BLOCKED -- 2N.2A
-- deliberately did not touch 0095). This documents the current, honest
-- state rather than a passing/failing "test":
select
  (select prosrc like '%source_storage_bucket <> ''documents''%' from pg_proc where proname = 'guard_broker_packet_item') as broker_packet_guard_still_single_bucket,
  (select prosrc like '%''documents'', v_document.file_path%' from pg_proc where proname = 'add_broker_packet_item') as add_item_still_hardcodes_documents;
-- Expected: both true. A W-9 document is NOT YET eligible for Broker
-- Packet inclusion -- this is confirmed unchanged, not silently fixed,
-- pending a separately authorized future migration (see the 2N.2A report).

-- 16. Line-3b server-side enforcement present in certify_carrier_w9().
select prosrc like '%Line 3b (foreign partners, owners, or beneficiaries) only applies%' as line_3b_check_present
from pg_proc where proname = 'certify_carrier_w9';
-- Expected: true.

-- 17. Staff role boundaries -- confirm the actual grants match the
-- approved role matrix exactly (see 2N.2/2N.2A reports' role tables).
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
  has_function_privilege('authenticated', p.oid, 'execute') as authenticated_can_execute,
  has_function_privilege('service_role', p.oid, 'execute') as service_role_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'reveal_carrier_w9_tin';
-- Expected: authenticated=true, service_role=false (staff-only reveal,
-- unreachable from the carrier portal or generation workflow).

-- 18. Conversion relationship: after converting a real application with a
-- completed W-9 (run this against a disposable TEST-* fixture only, never
-- production data), confirm the W-9 and its registered document both now
-- carry the new carrier_id/entity_id while onboarding_application_id
-- remains set on the W-9 row (historical evidence preserved both ways).
-- Template (fill in real TEST-* ids before running):
-- select w9.id, w9.onboarding_application_id, w9.carrier_id, d.entity_type, d.entity_id
-- from public.carrier_w9s w9 left join public.documents d on d.id = w9.registered_document_id
-- where w9.onboarding_application_id = '<TEST application id>';
-- Expected: carrier_id populated, onboarding_application_id still populated,
-- d.entity_type = 'carrier', d.entity_id = the new carrier's id.

-- 19. Completed W-9 immutability: attempting to update a completed row's
-- frozen fields must fail (run against a disposable TEST-* completed W-9,
-- expect an exception, never a silent success):
-- update public.carrier_w9s set name_on_tax_return = 'SHOULD NOT WORK' where id = '<TEST completed w9 id>';
-- Expected: raises 'A certified W-9''s tax identity, classification, TIN,
-- address, and certification cannot be changed.'
