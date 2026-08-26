-- Phase 2M.2D -- run BEFORE (re-)applying 0111_carrier_onboarding_document_linkage_repair.sql.
-- A first apply attempt of this file FAILED live (ERROR P0001, finalized
-- executed agreement immutability) -- run this in full before trying the
-- revised version, to confirm exactly what state the failed attempt left
-- behind. All read-only.

-- 1. Did the failed attempt's CREATE OR REPLACE FUNCTION (Part 1) commit,
--    or roll back along with the later failing statement? A multi-
--    statement SQL Editor paste runs as one implicit transaction by
--    default, so this is expected to show FALSE/FALSE (fully rolled
--    back, live function is still the original 0099 shape) -- confirm,
--    don't assume.
select
  pg_get_functiondef(oid) like '%2M.2D%' as has_0111_repair_comment,
  pg_get_functiondef(oid) like '%not exists%carrier_agreement_signings%' as has_immutability_exclusion
from pg_proc
where proname = 'convert_carrier_onboarding_application' and pronamespace = 'public'::regnamespace;
-- expect: both false if the failed attempt fully rolled back (the normal,
-- expected case); true/true only if this revised file has already been
-- successfully applied once.

-- 2. Did the failing backfill UPDATE leave ANY document partially
--    re-pointed? Postgres statement-level atomicity means a single
--    UPDATE that errors cannot partially apply regardless of the
--    transaction's fate, but confirm rather than assume: count of
--    onboarding documents still stranded on an already-converted
--    application (should match whatever this same query returned before
--    the FIRST attempt -- if it's lower now, something partially
--    committed and needs investigation before proceeding).
select a.id as application_id, a.legal_name, a.converted_carrier_id, count(d.id) as stranded_document_count
from public.carrier_onboarding_applications a
join public.documents d on d.entity_type = 'carrier_onboarding_application' and d.entity_id = a.id
where a.status = 'converted' and a.converted_carrier_id is not null
group by a.id, a.legal_name, a.converted_carrier_id
order by a.legal_name;

-- 3. Identify which of those stranded documents are (or are not) a
--    finalized executed agreement -- this is exactly what the revised
--    migration must exclude. Does not select document contents, only
--    identifying metadata.
select
  d.id, d.document_type, d.entity_id as application_id, a.legal_name,
  exists (select 1 from public.carrier_agreement_signings s where s.generated_document_id = d.id) as is_finalized_executed_agreement
from public.documents d
join public.carrier_onboarding_applications a on a.id = d.entity_id
where d.entity_type = 'carrier_onboarding_application' and a.status = 'converted' and a.converted_carrier_id is not null
order by is_finalized_executed_agreement desc, a.legal_name;
-- expect: is_finalized_executed_agreement = true only for
-- document_type='signed_agreement' rows -- everything else (w9,
-- insurance_certificate, motor_carrier_authority, notice_of_assignment,
-- factoring_notice, voided_check, other) should show false.

-- 4. Confirm no executed agreement is currently corrupted (wrong
--    entity_type/entity_id relative to its own signing's application) --
--    this is the invariant a partial/successful bad re-point would have
--    broken.
select d.id, d.entity_type, d.entity_id, s.id as signing_id, s.application_id
from public.documents d
join public.carrier_agreement_signings s on s.generated_document_id = d.id
where d.entity_type <> 'carrier_onboarding_application' or d.entity_id <> s.application_id;
-- expect: 0 rows

-- 5. Standing rule: compliance exceptions unchanged.
select id, status, escalated_at from public.operational_exceptions
where id in ('cd58ae7a-9ea7-415a-b299-700a87b803fd', '70cd450c-40bb-4497-b658-fa3714a128bf', '8f624ba6-a816-4f4b-87ec-24c1d12a4a0f');
