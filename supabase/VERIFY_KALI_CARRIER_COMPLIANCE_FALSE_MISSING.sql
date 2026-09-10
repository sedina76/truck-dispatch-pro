-- ============================================================================
-- VERIFY_KALI_CARRIER_COMPLIANCE_FALSE_MISSING.sql
--
-- Determines whether Carrier Compliance ("Cargo Insurance / Carrier
-- Agreement Signed / General Liability / Form W-9 on File / Workers' Comp"
-- = Missing) is a FALSE NEGATIVE for the Kali Freights LLC carrier, or
-- whether the underlying evidence genuinely does not exist.
--
-- 100% READ-ONLY. SELECT only. No INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / GRANT / REVOKE, no transaction, no fixtures. Safe to run
-- against production at any time. Nothing is modified.
--
-- HOW TO USE
--   * Every block re-derives the target carrier from the same name match:
--       legal_name ILIKE '%kali%freight%'
--     If that matches 0 or >1 carriers, run BLOCK 1, copy the correct
--     carrier id, and replace every
--       (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
--     with  '<paste-uuid>'::uuid  before re-running.
--   * BLOCK 11 calls the real RPC. It is SECURITY DEFINER and checks
--     current_org_id() + role, which are NULL in the bare SQL editor, so it
--     will raise "Carrier not found in your organization." there. Run
--     BLOCK 11 only from an authenticated app/session context; BLOCKS 2-10
--     reproduce the same evidence the RPC reads, so the SQL editor alone is
--     enough to reach a verdict.
-- ============================================================================


-- ############################################################################
-- BLOCK 1 -- THE CARRIER (Section A)
-- ############################################################################
select
  c.id                as carrier_id,
  c.legal_name,
  c.dba_name,
  c.organization_id,
  o.name              as organization_name,
  c.mc_number,
  c.dot_number,
  c.is_active,
  c.created_at
from public.carriers c
join public.organizations o on o.id = c.organization_id
where c.legal_name ilike '%kali%freight%'
order by c.created_at;
-- Expect exactly 1 row. If 0 or >1, fix the match / use the id directly.


-- ############################################################################
-- BLOCK 2 -- CONVERSION RELATIONSHIP (Sections A + D + F)
-- Every onboarding application that either (a) converted to this carrier,
-- or (b) shares the name -- so an UNLINKED application is still visible.
-- ############################################################################
select
  a.id                     as application_id,
  a.status                 as application_status,
  a.legal_name,
  a.mc_number,
  a.dot_number,
  a.converted_carrier_id,
  a.converted_at,
  a.converted_by,
  (a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1))
                           as links_to_target_carrier,
  a.created_at
from public.carrier_onboarding_applications a
where a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
   or a.legal_name ilike '%kali%freight%'
order by a.created_at;
-- KEY: if NO row has links_to_target_carrier = true, the compliance
-- agreement adapter's  "carrier -> converted_carrier_id -> application"
-- lookup returns NULL and reports Carrier Agreement = MISSING regardless
-- of any signing that exists (Section D / F root cause candidate).


-- ############################################################################
-- BLOCK 3 -- CARRIER-OWNED DOCUMENTS (Section 14)  entity_type='carrier'
-- ############################################################################
select
  d.id, d.document_type, d.file_name, d.is_verified, d.verified_at,
  d.expiry_date, d.storage_bucket, d.created_at
from public.documents d
where d.entity_type = 'carrier'
  and d.entity_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
order by d.document_type, d.created_at desc;


-- ############################################################################
-- BLOCK 4 -- APPLICATION-OWNED DOCUMENTS still filed under the application
-- (Section 14). Post-0111 these should only be executed agreements
-- (signed_agreement) deliberately left in place; anything else here means
-- 0111's re-point never ran for this application.
-- ############################################################################
select
  d.id, d.entity_type, d.document_type, d.file_name, d.is_verified,
  d.expiry_date, d.created_at,
  exists (select 1 from public.carrier_agreement_signings s where s.generated_document_id = d.id)
                          as is_finalized_executed_agreement
from public.documents d
where d.entity_type = 'carrier_onboarding_application'
  and d.entity_id in (
    select a.id from public.carrier_onboarding_applications a
    where a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
       or a.legal_name ilike '%kali%freight%'
  )
order by d.document_type, d.created_at desc;


-- ############################################################################
-- BLOCK 5 -- W-9 EVIDENCE (Sections C + 9/10/15)
-- The compliance W-9 adapter is exactly:
--   EXISTS (select 1 from carrier_w9s where carrier_id = <carrier> and status = 'completed')
-- It does NOT read documents.entity_type at all.
-- ############################################################################
select
  w.id                       as carrier_w9_id,
  w.status,
  w.version,
  w.carrier_id,
  (w.carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1))
                             as carrier_id_matches_target,
  w.onboarding_application_id,
  w.certified_at,
  w.voided_at,
  w.superseded_by,
  w.registered_document_id,
  w.generated_storage_path,
  w.created_at,
  d.entity_type              as registered_doc_entity_type,
  d.entity_id                as registered_doc_entity_id,
  d.is_verified              as registered_doc_verified
from public.carrier_w9s w
left join public.documents d on d.id = w.registered_document_id
where w.carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
   or w.onboarding_application_id in (
     select a.id from public.carrier_onboarding_applications a
     where a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
        or a.legal_name ilike '%kali%freight%'
   )
order by w.version desc nulls last, w.created_at desc;
-- VERDICT KEYS:
--   * a row with carrier_id_matches_target = true AND status = 'completed'
--     -> compliance SHOULD report W-9 = VALID. If UI still says Missing =>
--        COMPLIANCE FALSE NEGATIVE (investigate further).
--   * rows exist only with carrier_id IS NULL (onboarding_application_id
--     set) -> the 0111 conversion re-point of carrier_w9s.carrier_id never
--     ran for this carrier -> W-9 EXISTS but adapter can't see it
--        => FALSE NEGATIVE, root cause = missing carrier_id linkage.
--   * only status IN ('draft','failed','voided') -> W-9 never finalized
--        => genuinely not "on file".
--   * no rows at all -> ACTUALLY MISSING.


-- ############################################################################
-- BLOCK 6 -- AGREEMENT SIGNING EVIDENCE (Sections D + 16)
-- Conversion is derived ONLY through the real relationship chain:
--   carrier_agreement_signings.application_id
--     -> carrier_onboarding_applications.id
--     -> carrier_onboarding_applications.converted_carrier_id
-- (carrier_agreement_signings has NO converted_carrier_id column of its
-- own -- 0082 -- the earlier draft referenced a nonexistent column.)
-- Compliance agreement adapter: for the application resolved via that
-- chain, EVERY published is_required_for_onboarding template of the org
-- must have a signing with status = 'completed'.
-- ############################################################################
select
  a.id                        as application_id,
  a.legal_name                as application_legal_name,
  a.status                    as application_status,
  a.converted_carrier_id,
  (a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1))
                              as application_links_to_target_carrier,
  t.id                        as template_id,
  t.template_key,
  t.version_number,
  t.name                      as template_name,
  t.status                    as template_status,
  t.is_required_for_onboarding,
  s.id                        as signing_id,
  s.status                    as signing_status,
  s.agreement_template_id,
  s.generated_document_id,
  s.assigned_at,
  s.completed_at,
  s.voided_at
from public.carrier_onboarding_applications a
join public.carrier_agreement_templates t
  on t.organization_id = a.organization_id
left join public.carrier_agreement_signings s
  on s.application_id = a.id
 and s.agreement_template_id = t.id
where a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
   or a.legal_name ilike '%kali%freight%'
order by a.created_at, t.is_required_for_onboarding desc, t.template_key, t.version_number, s.assigned_at desc nulls last;
-- VERDICT KEYS:
--   * no row has application_links_to_target_carrier = true
--       -> the adapter's carrier -> converted_carrier_id -> application
--          lookup returns NULL -> Carrier Agreement = MISSING regardless of
--          any signing. FALSE NEGATIVE via broken conversion linkage
--          (cross-check BLOCK 2).
--   * for the linked application, every row where
--     is_required_for_onboarding = true AND template_status = 'published'
--     has signing_status = 'completed'
--       -> compliance SHOULD report Carrier Agreement = VALID.
--          If UI still says Missing => FALSE NEGATIVE, investigate further.
--   * a required published template (note version_number) with NO completed
--     signing -> genuinely MISSING for that template version (often a
--     template re-published to a new version_number AFTER this carrier
--     converted -- the old signing points at the prior template id).
--   * a completed signing whose template is no longer 'published' or no
--     longer is_required_for_onboarding -> definition drift, report.


-- ############################################################################
-- BLOCK 7 -- GENERATED (IMMUTABLE) AGREEMENT DOCUMENT EVIDENCE (Section 16)
-- Confirms the executed-agreement PDFs exist and shows their (deliberately
-- unchanged, per 0111 + guard_finalized_executed_agreement_document())
-- entity_type/entity_id. Compliance MUST NOT require these to be
-- entity_type='carrier'.
-- ############################################################################
select
  a.id                       as application_id,
  a.legal_name               as application_legal_name,
  a.status                   as application_status,
  s.id                       as signing_id,
  s.status                   as signing_status,
  s.agreement_template_id    as template_id,
  s.generated_document_id,
  s.assigned_at,
  s.completed_at,
  d.entity_type              as doc_entity_type,
  d.entity_id                as doc_entity_id,
  d.document_type,
  d.file_name,
  d.is_verified,
  d.created_at               as doc_created_at
from public.carrier_agreement_signings s
join public.carrier_onboarding_applications a on a.id = s.application_id
join public.documents d on d.id = s.generated_document_id
where a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
   or a.legal_name ilike '%kali%freight%'
order by s.assigned_at desc;


-- ############################################################################
-- BLOCK 8 -- INSURANCE EVIDENCE (Sections E + 8)
-- 8a: structured insurance_policies rows -- THIS is what the compliance
--     insurance adapter reads (by carrier_id + policy_type). A generic
--     onboarding 'insurance_certificate' DOCUMENT does NOT feed this.
-- ############################################################################
select
  p.id                 as insurance_policy_id,
  p.policy_type,
  p.carrier_id,
  p.insurer_name,
  p.policy_number,
  p.effective_date,
  p.expiry_date,
  case
    when p.expiry_date is null then 'no expiry (treated VALID)'
    when p.expiry_date < current_date then 'EXPIRED'
    when p.expiry_date <= current_date + interval '30 days' then 'EXPIRING_SOON'
    else 'VALID'
  end                  as adapter_status,
  p.document_id,
  p.created_at
from public.insurance_policies p
where p.carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
order by p.policy_type, p.effective_date desc nulls last;
-- If this returns 0 rows for cargo / general_liability / workers_compensation,
-- those requirements are ACTUALLY MISSING as far as the engine's design is
-- concerned (structured policy never entered) -- even if 8b shows a cert.

-- 8b: any insurance CERTIFICATE documents on the carrier or its application
--     (collected during onboarding). These are NOT read by compliance.
select
  d.id, d.entity_type, d.entity_id, d.document_type, d.file_name,
  d.is_verified, d.expiry_date, d.created_at
from public.documents d
where d.document_type in ('insurance_certificate')
  and (
    (d.entity_type = 'carrier'
      and d.entity_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1))
    or (d.entity_type = 'carrier_onboarding_application'
      and d.entity_id in (
        select a.id from public.carrier_onboarding_applications a
        where a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
           or a.legal_name ilike '%kali%freight%'))
  )
order by d.created_at desc;


-- ############################################################################
-- BLOCK 9 + 10 -- VERIFICATION + EXPIRY SNAPSHOT (Sections 9/10)
-- Pulled together for the documents and policies above. (The 5 flagged
-- system requirements all have verification_required = FALSE in the 0102
-- seed, so is_verified does NOT drive their status -- shown for
-- completeness only.)
-- ############################################################################
select 'insurance_policy' as evidence_kind, p.policy_type::text as detail,
       null::boolean as is_verified, p.expiry_date,
       (p.expiry_date is not null and p.expiry_date < current_date) as is_expired
from public.insurance_policies p
where p.carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
union all
select 'document', d.document_type::text, d.is_verified, d.expiry_date,
       (d.expiry_date is not null and d.expiry_date < current_date)
from public.documents d
where (d.entity_type = 'carrier' and d.entity_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1))
   or (d.entity_type = 'carrier_onboarding_application' and d.entity_id in (
        select a.id from public.carrier_onboarding_applications a
        where a.converted_carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
           or a.legal_name ilike '%kali%freight%'))
order by evidence_kind, detail;


-- ############################################################################
-- BLOCK 10b -- WHAT THE ENGINE IS EVALUATING
-- Active carrier requirement definitions (system + this org's overrides),
-- plus any compliance_overrides / suspension for this carrier.
-- ############################################################################
select distinct on (requirement_key)
  requirement_key, display_name, classification, resolution_source, resolution_key,
  expiration_required, warning_days, verification_required, overridable,
  organization_id is not null as is_org_override
from public.compliance_requirement_definitions
where entity_type = 'carrier' and is_active
  and (organization_id = (select organization_id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
       or organization_id is null)
order by requirement_key, (organization_id is not null) desc;

select o.id, o.requirement_definition_id, rd.requirement_key, o.load_id,
       o.reason, o.created_at, o.expires_at, o.revoked_at
from public.compliance_overrides o
left join public.compliance_requirement_definitions rd on rd.id = o.requirement_definition_id
where o.carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
order by o.created_at desc;

select id, reason, suspended_at, lifted_at
from public.carrier_suspensions
where carrier_id = (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
order by suspended_at desc;


-- ############################################################################
-- BLOCK 11 -- THE AUTHORITATIVE RESULT (Section 11)
-- Only works from an authenticated context (current_org_id() must resolve).
-- In the bare SQL editor this raises "Carrier not found in your
-- organization." -- expected; BLOCKS 2-10 already contain the same facts.
-- ############################################################################
select public.carrier_dispatch_readiness(
  (select id from public.carriers where legal_name ilike '%kali%freight%' limit 1)
);
