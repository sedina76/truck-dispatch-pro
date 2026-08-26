-- ---------------------------------------------------------------------------
-- PRE-APPLY -- Phase 2Q.2C -- Driver W-9 / Approval State Synchronization
-- Repair.
--
-- DO NOT APPLY WITHOUT APPROVAL.
--
-- ROOT CAUSE 1 (the reported "staff page says Not Started" defect):
-- 0109's driver_w9s authenticated SELECT grant omitted three columns
-- (generated_by, voided_by, created_by) that the application code's own
-- DRIVER_W9_STAFF_SAFE_COLUMNS select list requests. PostgreSQL requires
-- privilege on EVERY column named in a select list, or the ENTIRE query
-- is denied -- it does not silently drop the ungranted column and return
-- the rest. supabase-js does not surface that denial as a thrown error
-- either; `{ data }` comes back null, which the staff page's own code
-- (unable to tell "denied" from "no row exists") correctly-but-
-- misleadingly rendered as "Not started". The driver's own read
-- (getMyDriverW9(), service-role, bypasses grants entirely) was never
-- affected -- which is exactly why the write clearly succeeded (the
-- driver-facing "Form W-9 -- Completed" screen was real) while the staff
-- read silently failed. This is the SAME defect class carrier_w9s'
-- W9_STAFF_SAFE_COLUMNS's own header comment already documents -- 0109
-- just didn't keep its GRANT list and its TS select-list constant in
-- sync. Fixed here by extending the grant, not by narrowing the TS
-- constant -- the constant's three extra columns are legitimate,
-- generally-useful staff-safe fields (who generated/voided/created this
-- row), not accidental scope creep.
--
-- ROOT CAUSE 2 (the reported "Approved reverted" defect): traced every
-- UPDATE of driver_applications.status reachable from applicant-side
-- onboarding code (the [token] bootstrap route: only invited->in_progress;
-- submitDriverOnboardingApplication(): blocked outright unless status is
-- in_progress/needs_correction; every saveDriver*Info()/attach*Document()
-- action: blocked by requireEditableApplication() unless in_progress/
-- needs_correction) -- NONE of them can write or reach an approved row.
-- The only code path that CAN overwrite status unconditionally is the
-- staff-side updateApplicationStatus() generic dropdown, which had two
-- real defects of its own (fixed in application code, see report item 2 --
-- no migration needed for those): no current-status guard at all, and an
-- uncontrolled (defaultValue) <select> vulnerable to submitting a stale
-- value after a Next.js server-action soft-refresh -- the exact same bug
-- class already found and fixed once this engagement (2M.2A, Broker
-- Packet Requirements Checklist). No database change is needed for root
-- cause 2 -- it is fixed entirely in application code below.
--
-- THIRD GAP FOUND DURING THIS INVESTIGATION (Objective G was not actually
-- DB-enforced): convert_driver_application_to_driver() never checked W-9
-- completeness for a 1099/owner-operator applicant -- only the staff
-- UI's own conditional Convert-button visibility did. Fixed here by
-- adding the check inside the function itself, so conversion is blocked
-- server-side regardless of what the UI shows or hides.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART 1 -- extend the driver_w9s authenticated SELECT grant to match
-- DRIVER_W9_STAFF_SAFE_COLUMNS exactly. tin_encrypted remains excluded,
-- unchanged -- readable only inside reveal_driver_w9_tin().
-- ---------------------------------------------------------------------------
grant select (generated_by, voided_by, created_by) on public.driver_w9s to authenticated;

-- ---------------------------------------------------------------------------
-- PART 2 -- convert_driver_application_to_driver(): add the missing
-- server-side W-9 gate for 1099/owner-operator applicants (Objective G).
-- Everything else (carrier_id authority, approved-status requirement,
-- for-update row lock, W-9 re-pointing at conversion) is unchanged from
-- 0109.
-- ---------------------------------------------------------------------------
create or replace function public.convert_driver_application_to_driver(p_application_id uuid, p_carrier_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app public.driver_applications;
  v_driver_id uuid;
  v_carrier_id uuid;
  v_w9_id uuid;
begin
  select * into v_app from public.driver_applications where id = p_application_id for update;
  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may convert an application';
  end if;
  if v_app.status = 'converted' then
    raise exception 'This application has already been converted';
  end if;
  if v_app.status <> 'approved' then
    raise exception 'Only approved applications can be converted to a driver. Set this application to Approved first.';
  end if;

  -- Objective G, now DB-enforced rather than UI-only: a 1099/owner-
  -- operator applicant must have a completed Driver W-9 before
  -- conversion, regardless of what any client shows or hides.
  if v_app.worker_type in ('independent_contractor', 'owner_operator') then
    if not exists (select 1 from public.driver_w9s where application_id = p_application_id and status = 'completed') then
      raise exception 'A completed Form W-9 is required before converting this applicant to a driver.';
    end if;
  end if;

  if v_app.carrier_id is not null then
    v_carrier_id := v_app.carrier_id;
  else
    if p_carrier_id is null then raise exception 'Select a carrier to convert this application into a driver record.'; end if;
    v_carrier_id := p_carrier_id;
  end if;
  if not exists (select 1 from public.carriers where id = v_carrier_id and organization_id = v_app.organization_id) then
    raise exception 'Carrier not found in your organization';
  end if;

  insert into public.drivers (
    organization_id, carrier_id, first_name, middle_name, last_name, phone, email,
    date_of_birth, address_line1, city, state, postal_code,
    emergency_contact_name, emergency_contact_phone,
    cdl_number, cdl_state, cdl_class, cdl_endorsements, cdl_expiry_date,
    medical_card_expiry_date, status, ssn_encrypted, ssn_last4, worker_type
  ) values (
    v_app.organization_id, v_carrier_id, v_app.first_name, v_app.middle_name, v_app.last_name,
    v_app.phone, v_app.email, v_app.date_of_birth, v_app.address_line1, v_app.city, v_app.state, v_app.postal_code,
    v_app.emergency_contact_name, v_app.emergency_contact_phone,
    v_app.cdl_number, v_app.cdl_state, v_app.cdl_class, v_app.cdl_endorsements, v_app.cdl_expiry_date,
    v_app.medical_card_expiry_date, 'applicant', v_app.ssn_encrypted, v_app.ssn_last4, v_app.worker_type
  )
  returning id into v_driver_id;

  update public.driver_applications
    set status = 'converted', converted_driver_id = v_driver_id, updated_at = now()
    where id = p_application_id;

  select id into v_w9_id
  from public.driver_w9s
  where application_id = p_application_id and driver_id is null and status <> 'voided'
  order by version desc nulls last
  limit 1;

  if v_w9_id is not null then
    update public.driver_w9s set driver_id = v_driver_id where id = v_w9_id;
  end if;

  return v_driver_id;
end;
$$;
