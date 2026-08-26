-- Phase 2M.2D -- run AFTER applying 0111_carrier_onboarding_document_linkage_repair.sql.

-- 1. Zero stranded documents remain for any already-converted application
--    -- the backfill should have re-pointed all of them (compare against
--    the PREFLIGHT capture's counts, which should now all be gone).
select a.id as application_id, a.legal_name, count(d.id) as still_stranded
from public.carrier_onboarding_applications a
join public.documents d on d.entity_type = 'carrier_onboarding_application' and d.entity_id = a.id
where a.status = 'converted' and a.converted_carrier_id is not null
group by a.id, a.legal_name;
-- expect: 0 rows

-- 2. Spot-check: Kali Freights' documents now show entity_type='carrier'
--    with entity_id = its own carrier id (adjust the name filter if it
--    differs from what's live).
select d.id, d.document_type, d.entity_type, d.entity_id, c.legal_name
from public.documents d
join public.carriers c on c.id = d.entity_id and d.entity_type = 'carrier'
where c.legal_name ilike '%kali%'
order by d.document_type;
-- expect: one row per onboarding document type this carrier had (w9,
-- insurance_certificate, motor_carrier_authority, voided_check, ...),
-- all with entity_type = 'carrier' and entity_id = Kali's own carrier id

-- 3. New function now performs the broader re-pointing, AND excludes
--    finalized executed agreements the same way the trigger recognizes
--    them (not a hardcoded document_type guess).
select pg_get_functiondef(oid) like '%entity_type = ''carrier_onboarding_application''::public.entity_type%'
  and pg_get_functiondef(oid) like '%entity_type = ''carrier''::public.entity_type, entity_id = v_carrier_id%' as has_broad_repoint,
  pg_get_functiondef(oid) like '%not exists%carrier_agreement_signings%generated_document_id%' as excludes_executed_agreements
from pg_proc where proname = 'convert_carrier_onboarding_application' and pronamespace = 'public'::regnamespace;
-- expect: true, true

-- 4. Executed agreements: confirm none were mutated by the backfill --
--    every document referenced by a signing must still show
--    entity_type='carrier_onboarding_application' with entity_id equal
--    to its own signing's application_id (proves the immutable
--    original was left completely alone, not silently re-pointed).
select d.id, d.entity_type, d.entity_id, s.application_id
from public.documents d
join public.carrier_agreement_signings s on s.generated_document_id = d.id
where d.entity_type <> 'carrier_onboarding_application' or d.entity_id <> s.application_id;
-- expect: 0 rows

-- 5. Kali Freights spot-check, specifically: its signed_agreement (if any)
--    is untouched while its ordinary documents are re-pointed. Confirms
--    #4 isn't vacuously true for lack of any signed agreements existing.
select d.id, d.document_type, d.entity_type, d.entity_id,
  exists (select 1 from public.carrier_agreement_signings s where s.generated_document_id = d.id) as is_executed_agreement
from public.documents d
join public.carrier_onboarding_applications a on a.id = d.entity_id or (d.entity_type = 'carrier' and a.converted_carrier_id = d.entity_id)
where a.legal_name ilike '%kali%'
order by is_executed_agreement desc, d.document_type;
-- expect: is_executed_agreement=true rows still show
-- entity_type='carrier_onboarding_application'; is_executed_agreement=
-- false rows (w9, insurance_certificate, motor_carrier_authority,
-- voided_check, ...) show entity_type='carrier'

-- 6. Cross-org/cross-carrier sanity: no document now points at a carrier
--    outside its own organization (this should NEVER happen given the
--    join key, but worth confirming explicitly).
select d.id, d.organization_id as document_org, c.organization_id as carrier_org
from public.documents d
join public.carriers c on c.id = d.entity_id
where d.entity_type = 'carrier' and d.organization_id <> c.organization_id;
-- expect: 0 rows

select id, status, escalated_at from public.operational_exceptions
where id in ('cd58ae7a-9ea7-415a-b299-700a87b803fd', '70cd450c-40bb-4497-b658-fa3714a128bf', '8f624ba6-a816-4f4b-87ec-24c1d12a4a0f');
-- expect: identical to the PREFLIGHT capture
