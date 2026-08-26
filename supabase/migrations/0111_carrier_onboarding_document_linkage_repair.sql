-- ---------------------------------------------------------------------------
-- PRE-APPLY -- Phase 2M.2D -- Carrier Onboarding -> Broker Packet Document
-- Linkage Repair.
--
-- DO NOT APPLY WITHOUT APPROVAL.
--
-- ROOT CAUSE (audited first, not assumed -- see report Sections A/B):
-- convert_carrier_onboarding_application() (0086, amended by 0099) has
-- ALWAYS re-pointed exactly one thing onto the new carrier at conversion
-- time: the current, non-voided carrier_w9s row's own registered
-- documents row (entity_type 'carrier_onboarding_application' ->
-- 'carrier'). It never re-pointed any OTHER onboarding-uploaded document
-- (insurance_certificate, motor_carrier_authority, notice_of_assignment,
-- factoring_notice, voided_check, other) -- those permanently stayed
-- filed under entity_type='carrier_onboarding_application' and the OLD
-- application id, forever, even after a real carrier record existed.
--
-- Broker Packet's candidates.ts (2M.2A) already knows how to FIND these
-- stranded documents (by looking up the originating application via
-- carrier_onboarding_applications.converted_carrier_id) and correctly
-- refuses to offer them as directly addable, because
-- guard_broker_packet_item() (0095/0100) only accepts entity_type IN
-- ('broker','carrier','organization') -- never
-- 'carrier_onboarding_application'. That combination is exactly what
-- produced the reported "UNLINKED -- contact support" result: the org
-- genuinely has the document, Broker Packet can see it, but nothing has
-- ever moved it onto a footing the packet-item guard accepts.
--
-- REPAIR: extend the SAME re-pointing convert_carrier_onboarding_
-- application() already does for the W-9 to cover EVERY onboarding
-- document, going forward, in this one function -- no new columns, no new
-- tables, no bytes moved, no file re-uploaded, no W-9 regenerated. Plus
-- a one-time, idempotent backfill UPDATE for already-converted carriers
-- (Kali Freights and any other) whose documents are still stranded --
-- scoped entirely through carrier_onboarding_applications.
-- converted_carrier_id, so it can never cross an organization or carrier
-- boundary: each document's destination is looked up from its OWN
-- originating application row, never guessed or batched by name/type.
--
-- REVISION HISTORY -- a first apply attempt of this exact file FAILED
-- live (ERROR P0001, "A finalized executed agreement document is
-- immutable.", raised by guard_finalized_executed_agreement_document()
-- during the Part 2 backfill UPDATE). Root cause: a "document" in
-- public.documents is not a uniform thing -- a small subset of rows
-- (document_type='signed_agreement', the executed dispatch-agreement PDF
-- rendered by the carrier-agreements feature, 0089) are recognized as
-- FINALIZED and made immutable by a BEFORE UPDATE/DELETE trigger the
-- moment any public.carrier_agreement_signings row's generated_document_id
-- points at them -- that trigger fires on ANY column change (`new is
-- distinct from old`, not just specific columns), including the
-- entity_type/entity_id re-pointing this migration performs. The original
-- version of this file's two UPDATE statements had no awareness of this
-- and attempted to re-point every stranded onboarding document
-- indiscriminately, including any signed_agreement rows, which the
-- trigger correctly refused.
--
-- Fix: both UPDATE statements below now exclude any document referenced
-- by carrier_agreement_signings.generated_document_id -- the exact same
-- condition the trigger itself checks, not a fragile document_type name
-- guess -- so this migration can never even attempt a write the trigger
-- would reject. Executed agreements are NEVER re-pointed and remain
-- fully immutable; this is safe and loses nothing, because nothing
-- consumes an executed agreement via entity_type/entity_id in the first
-- place -- Carrier Setup Packages' own agreement resolution
-- (src/lib/carrier-setup-packages/candidates.ts) already reads
-- carrier_agreement_signings joined by application_id directly, and
-- Broker Packet's own document-type catalog (w9/insurance_certificate/
-- motor_carrier_authority/notice_of_assignment/factoring_notice/
-- voided_check/other) does not include signed_agreement at all -- an
-- executed agreement was never a candidate for Broker Packet to select.
--
-- Because Postgres runs a multi-statement SQL Editor paste as one
-- implicit transaction by default, and the failure occurred partway
-- through Part 2, the FULL prior attempt (including Part 1's CREATE OR
-- REPLACE FUNCTION) is expected to have rolled back in its entirety --
-- verified with a read-only query before this revision was written, not
-- assumed (see report Section 3/the accompanying VERIFY_0111_PREFLIGHT.sql
-- addition below). Postgres statement-level atomicity also independently
-- guarantees the single failing UPDATE itself could not have partially
-- applied, regardless of the surrounding transaction's fate.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART 1 -- convert_carrier_onboarding_application(): re-point EVERY
-- onboarding document (not just the W-9's) onto the new carrier. Every
-- other line is byte-for-byte unchanged from 0099's version -- ownership
-- check, role check, duplicate MC/DOT guard, advisory locks, carrier +
-- carrier_financials insert, application status update, and the existing
-- W-9-specific re-pointing (which updates carrier_w9s.carrier_id itself,
-- a different table this new step does not touch) are all preserved.
-- ---------------------------------------------------------------------------
create or replace function public.convert_carrier_onboarding_application(p_application_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_app public.carrier_onboarding_applications;
  v_carrier_id uuid;
  v_missing_required_agreement boolean;
  v_mc_number text;
  v_dot_number text;
  v_duplicate_carrier_id uuid;
  v_w9_id uuid;
  v_w9_document_id uuid;
begin
  select * into v_app
  from public.carrier_onboarding_applications
  where id = p_application_id
  for update;

  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may convert an application to a carrier.';
  end if;
  if v_app.status <> 'approved' then
    raise exception 'Only an approved application can be converted (current status=%).', v_app.status;
  end if;

  select exists (
    select 1
    from (
      select distinct t.template_key
      from public.carrier_agreement_templates t
      where t.organization_id = v_app.organization_id
        and t.status = 'published'
        and t.is_required_for_onboarding
    ) required_keys
    where 1 <> (
      select count(*)
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t
        on t.id = s.agreement_template_id
      where s.application_id = p_application_id
        and s.status <> 'voided'
        and t.template_key = required_keys.template_key
    )
    or not exists (
      select 1
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t
        on t.id = s.agreement_template_id
      where s.application_id = p_application_id
        and s.status = 'completed'
        and t.template_key = required_keys.template_key
    )
  ) into v_missing_required_agreement;

  if v_missing_required_agreement then
    raise exception 'One or more required dispatch agreements have not been completed for this application.';
  end if;

  v_mc_number := nullif(btrim(v_app.mc_number), '');
  v_dot_number := nullif(btrim(v_app.dot_number), '');

  if v_mc_number is not null then
    perform pg_advisory_xact_lock(hashtext(v_app.organization_id::text), hashtext('carrier-mc:' || v_mc_number));
  end if;
  if v_dot_number is not null then
    perform pg_advisory_xact_lock(hashtext(v_app.organization_id::text), hashtext('carrier-dot:' || v_dot_number));
  end if;

  select c.id into v_duplicate_carrier_id
  from public.carriers c
  where c.organization_id = v_app.organization_id
    and (
      (v_mc_number is not null and btrim(c.mc_number) = v_mc_number)
      or (v_dot_number is not null and btrim(c.dot_number) = v_dot_number)
    )
  limit 1;

  if v_duplicate_carrier_id is not null then
    raise exception 'A carrier with the same MC or DOT number already exists in this organization.';
  end if;

  insert into public.carriers (
    organization_id, legal_name, dba_name, mc_number, dot_number, contact_name, phone, email,
    address_line1, address_line2, city, state, postal_code, country
  ) values (
    v_app.organization_id, v_app.legal_name, v_app.dba_name, v_app.mc_number, v_app.dot_number,
    v_app.contact_name, v_app.phone, v_app.email, v_app.address_line1, v_app.address_line2,
    v_app.city, v_app.state, v_app.postal_code, coalesce(nullif(btrim(v_app.country), ''), 'US')
  )
  returning id into v_carrier_id;

  insert into public.carrier_financials (
    carrier_id, organization_id, dispatch_fee_percentage, payment_terms_days, factoring_company_name
  ) values (
    v_carrier_id, v_app.organization_id,
    coalesce(v_app.proposed_dispatch_fee_percentage, 10.00), coalesce(v_app.proposed_payment_terms_days, 7),
    case when v_app.has_factoring then nullif(btrim(v_app.factoring_company_name), '') else null end
  );

  update public.carrier_onboarding_applications
  set status = 'converted', converted_at = now(), converted_by = auth.uid(), converted_carrier_id = v_carrier_id
  where id = p_application_id;

  -- 2M.2D repair: re-point EVERY ORDINARY onboarding-uploaded document
  -- (insurance certificate, operating authority, notice of assignment,
  -- factoring notice, voided check, other, and any W-9 document alike)
  -- onto the new carrier -- the SAME re-pointing 0099 already proved safe
  -- for the W-9 case alone, now applied to the whole set in one
  -- statement. Storage bucket/path are never touched -- no bytes move,
  -- nothing is re-uploaded, only ownership attribution changes.
  --
  -- Excludes any document referenced by carrier_agreement_signings.
  -- generated_document_id -- the exact condition
  -- guard_finalized_executed_agreement_document() (0089) itself checks
  -- to recognize a FINALIZED EXECUTED AGREEMENT and make it immutable.
  -- Re-pointing entity_type/entity_id on one of those rows is exactly
  -- what a first attempt at this migration did and had rejected live
  -- (see this file's REVISION HISTORY note above) -- an executed
  -- agreement is never touched here; it keeps its original entity_type/
  -- entity_id and remains fully immutable, associated with the carrier
  -- only through its own existing carrier_agreement_signings.
  -- application_id -> carrier_onboarding_applications.converted_carrier_id
  -- chain, never through this column.
  update public.documents
  set entity_type = 'carrier'::public.entity_type, entity_id = v_carrier_id
  where entity_type = 'carrier_onboarding_application'::public.entity_type
    and entity_id = p_application_id
    and not exists (
      select 1 from public.carrier_agreement_signings s where s.generated_document_id = documents.id
    );

  -- 2N.2 addition (unchanged): re-point the current (non-voided) W-9's
  -- own carrier_w9s row -- a different table than documents, still
  -- necessary alongside the update above.
  select id, registered_document_id into v_w9_id, v_w9_document_id
  from public.carrier_w9s
  where onboarding_application_id = p_application_id and carrier_id is null and status <> 'voided'
  order by version desc nulls last
  limit 1;

  if v_w9_id is not null then
    update public.carrier_w9s set carrier_id = v_carrier_id where id = v_w9_id;
    if v_w9_document_id is not null then
      update public.documents set entity_type = 'carrier'::public.entity_type, entity_id = v_carrier_id
      where id = v_w9_document_id;
    end if;
  end if;

  return v_carrier_id;
end;
$$;

comment on function public.convert_carrier_onboarding_application(uuid) is
  'Atomically converts an approved onboarding application into public.carriers plus its carrier_financials row, re-points every ORDINARY onboarding-uploaded document (2M.2D) plus the current non-voided W-9 (2N.2) onto the new carrier -- no bytes moved, no re-render, no certification change, onboarding_application_id never cleared. Never re-points a finalized executed agreement document (carrier_agreement_signings.generated_document_id) -- those remain immutable and fully untouched, associated with the carrier only via their own existing application_id -> converted_carrier_id chain. carriers.ein remains unset (unchanged from 0086).';

-- ---------------------------------------------------------------------------
-- PART 2 -- one-time, idempotent backfill for carriers already converted
-- before this repair (Kali Freights and any other). Scoped entirely
-- through each document's OWN originating application row -- the join
-- key (application id) uniquely determines both the organization and the
-- correct destination carrier, so this can never cross an organization or
-- carrier boundary, and re-running it is a no-op the second time (after
-- the first run, no matching entity_type='carrier_onboarding_application'
-- row remains for an already-converted application).
-- ---------------------------------------------------------------------------
-- Same exclusion as Part 1: never re-point a document that is a finalized
-- executed agreement (carrier_agreement_signings.generated_document_id).
-- This is the exact statement that failed live on the first attempt --
-- adding this one condition is the entire fix.
update public.documents d
set entity_type = 'carrier'::public.entity_type, entity_id = a.converted_carrier_id
from public.carrier_onboarding_applications a
where d.entity_type = 'carrier_onboarding_application'::public.entity_type
  and d.entity_id = a.id
  and a.status = 'converted'
  and a.converted_carrier_id is not null
  and not exists (
    select 1 from public.carrier_agreement_signings s where s.generated_document_id = d.id
  );
