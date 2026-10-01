-- ============================================================================
-- VERIFY_PHANTOM_DOCUMENTS_METADATA_ONLY.sql
--
-- Lists public.documents rows that were most likely created by a
-- METADATA-ONLY form (the old /documents/new and /compliance/* "paste the
-- Entity ID" forms) -- i.e. a documents row that may have NO underlying
-- storage object at its file_path.
--
-- 100% READ-ONLY. SELECT only. No INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / GRANT / REVOKE, no transaction. Safe on production.
-- DELETES NOTHING. This only produces a list to verify by hand against the
-- Supabase Storage browser before anyone decides what (if anything) to do.
--
-- WHY THE HEURISTIC WORKS
--   Every REAL byte-upload path in this codebase (uploadLoadDocument(),
--   expense/fuel receipt upload, the W-9 / carrier-agreement / broker-
--   packet / setup-package / statement generators) sets file_size_bytes
--   AND mime_type AND (for the interactive ones) uploaded_by. The old
--   generic metadata forms set NONE of those and wrote a hand-typed or
--   server-fabricated file_path with no upload behind it.
--
-- CAVEATS -- do not treat a row here as proven phantom:
--   * Very old / seed rows may also lack file_size_bytes/mime_type yet
--     still have a real object.
--   * storage_bucket may not be 'documents' -- an object could exist in a
--     different bucket than a naive check assumes.
--   * The ONLY authoritative test is: look for the object at
--     (storage_bucket, file_path) in Supabase Storage. That cannot be done
--     from SQL -- use the Storage browser or the Storage API for each id
--     below.
-- ============================================================================


-- ############################################################################
-- RESULT 1 -- SUMMARY: metadata-only candidates by entity_type
-- (file_size_bytes IS NULL AND mime_type IS NULL)
-- ############################################################################
select
  d.entity_type,
  count(*)                                             as candidate_rows,
  count(*) filter (where d.uploaded_by is null)        as also_no_uploader,
  count(*) filter (where d.is_verified)                as marked_verified,
  min(d.created_at)                                    as earliest,
  max(d.created_at)                                    as latest
from public.documents d
where d.file_size_bytes is null
  and d.mime_type is null
group by d.entity_type
order by candidate_rows desc;


-- ############################################################################
-- RESULT 2 -- FULL LIST of metadata-only candidates (verify each against
-- Supabase Storage before any action)
-- ############################################################################
select
  d.id,
  d.organization_id,
  o.name                                               as organization_name,
  d.entity_type,
  d.entity_id,
  d.document_type,
  d.file_name,
  coalesce(d.storage_bucket, 'documents')              as storage_bucket,
  d.file_path,
  d.is_verified,
  d.uploaded_by,
  d.created_at,
  -- Rows whose path matches the short-lived generic-router path shape
  -- <org-uuid>/<entity_type>/<entity-uuid>/<ts>-<rand>-<name> are almost
  -- certainly from the metadata-only /documents/new that this repair
  -- removed.
  (d.file_path ~ '^[0-9a-fA-F-]{36}/(carrier|driver|load|broker|customer)/[0-9a-fA-F-]{36}/')
                                                       as matches_removed_generic_form_path
from public.documents d
join public.organizations o on o.id = d.organization_id
where d.file_size_bytes is null
  and d.mime_type is null
order by d.created_at desc;


-- ############################################################################
-- RESULT 3 -- Cross-check: is a metadata-only row referenced by any real
-- workflow record? If so it is almost certainly NOT phantom (the workflow
-- that made the reference also produced a real artifact) -- and must not
-- be touched regardless.
-- ############################################################################
select
  d.id                                                 as document_id,
  d.entity_type,
  d.document_type,
  d.file_path,
  exists (select 1 from public.carrier_w9s w where w.registered_document_id = d.id)                as referenced_by_carrier_w9,
  exists (select 1 from public.carrier_agreement_signings s where s.generated_document_id = d.id)  as referenced_by_agreement_signing,
  exists (select 1 from public.insurance_policies p where p.document_id = d.id)                    as referenced_by_insurance_policy,
  exists (select 1 from public.expenses e where e.receipt_document_id = d.id)                      as referenced_by_expense
from public.documents d
where d.file_size_bytes is null
  and d.mime_type is null
  and (
       exists (select 1 from public.carrier_w9s w where w.registered_document_id = d.id)
    or exists (select 1 from public.carrier_agreement_signings s where s.generated_document_id = d.id)
    or exists (select 1 from public.insurance_policies p where p.document_id = d.id)
    or exists (select 1 from public.expenses e where e.receipt_document_id = d.id)
  )
order by d.created_at desc;
-- Any row here: LEAVE ALONE. It belongs to a dedicated workflow and is not
-- a phantom from the generic form, even though it lacks file_size_bytes/
-- mime_type.
