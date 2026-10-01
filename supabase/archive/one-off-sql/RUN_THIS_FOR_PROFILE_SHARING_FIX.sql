-- =============================================================================
-- 0043_profile_sharing_fix.sql
-- Live-test bugfix for 0042_profile_sharing.sql (Test H5).
--
-- BUG: guard_profile_share_org() only gated SENSITIVE document types
-- (cdl, medical_card) behind an owner/admin role check. It never checked
-- whether a document's type was on any allowlist at all -- a document of
-- an unsupported/arbitrary type (e.g. 'other', which the Share dialog
-- never offers as a candidate in the first place) that genuinely belonged
-- to the correct driver/carrier and organization was silently accepted
-- as if it were "safe", because the function only distinguished
-- safe-vs-sensitive for the ROLE check, not membership in either
-- allowlist to begin with. Confirmed live: a document_type='other' row
-- belonging to the correct driver was successfully attached by an Owner.
--
-- FIX: explicit allowlist of every document_type this feature is willing
-- to attach at all (the exact same 4 values SAFE_DOCUMENT_TYPES +
-- SENSITIVE_DOCUMENT_TYPES enumerate in src/lib/profile-share/generate.ts)
-- -- anything else is rejected outright, regardless of ownership or role.
-- =============================================================================

create or replace function public.guard_profile_share_org()
returns trigger
language plpgsql
as $$
declare
  v_org uuid;
  v_doc record;
  v_matched integer := 0;
begin
  select organization_id into v_org from public.loads where id = new.load_id;
  if v_org is null or v_org <> new.organization_id then
    raise exception 'Load must belong to the same organization.';
  end if;

  if new.driver_id is not null then
    select organization_id into v_org from public.drivers where id = new.driver_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Driver must belong to the same organization.';
    end if;
  end if;

  if new.carrier_id is not null then
    select organization_id into v_org from public.carriers where id = new.carrier_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'Carrier must belong to the same organization.';
    end if;
  end if;

  if new.document_ids_included is not null and array_length(new.document_ids_included, 1) > 0 then
    for v_doc in
      select id, organization_id, entity_type, entity_id, document_type
      from public.documents
      where id = any(new.document_ids_included)
    loop
      v_matched := v_matched + 1;
      if v_doc.organization_id <> new.organization_id then
        raise exception 'Attached document does not belong to your organization.';
      end if;
      if not (
        (v_doc.entity_type = 'driver' and v_doc.entity_id = new.driver_id)
        or (v_doc.entity_type = 'carrier' and v_doc.entity_id = new.carrier_id)
      ) then
        raise exception 'Attached document does not belong to the driver/carrier on this share.';
      end if;
      -- Explicit allowlist -- fixes the gap found live in Test H5.
      -- Matches SAFE_DOCUMENT_TYPES + SENSITIVE_DOCUMENT_TYPES exactly
      -- (src/lib/profile-share/generate.ts). Anything else (w9, other,
      -- bol, rate_confirmation, etc.) is never attachable to an external
      -- profile share, regardless of ownership or role.
      if v_doc.document_type::text not in ('insurance_certificate', 'motor_carrier_authority', 'cdl', 'medical_card') then
        raise exception 'This document type is not eligible for external profile sharing.';
      end if;
      if v_doc.document_type::text in ('cdl', 'medical_card') and not public.has_role(array['owner', 'admin']::public.org_role[]) then
        raise exception 'Only owners and admins may include sensitive identity/compliance documents.';
      end if;
    end loop;
    if v_matched <> array_length(new.document_ids_included, 1) then
      raise exception 'One or more attached document ids are invalid.';
    end if;
  end if;

  return new;
end;
$$;
