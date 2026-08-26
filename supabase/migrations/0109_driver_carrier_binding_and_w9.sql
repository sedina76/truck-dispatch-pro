-- ---------------------------------------------------------------------------
-- PRE-APPLY -- Phase 2Q.2B -- Multi-Carrier Driver Assignment + Driver W-9.
--
-- DO NOT APPLY WITHOUT APPROVAL. Authored for review only, mirroring the
-- same "written but not yet applied" convention as 0108/0099.
--
-- WHY THIS IS NEEDED (audited first; see PHASE 2Q.2B report Sections 1-2,
-- 10-14):
--   1. driver_applications has NO carrier_id column at all today -- every
--      carrier-invited application (2Q.2, 0108) is bound only to an
--      organization, never a specific carrier. In a single-carrier org
--      this is invisible; in a real multi-carrier org, every invitation
--      email and onboarding-portal screen names the ORGANIZATION (e.g.
--      "Kali"), never the carrier the driver will actually work for --
--      confirmed root cause of the reported "invitations only say Kali"
--      symptom. Fixed by adding driver_applications.carrier_id, selected
--      by staff at Invite Driver time, never reassignable afterward, and
--      by conversion now using ONLY the application's own carrier_id
--      (see PART 3) rather than a staff-chosen dropdown at conversion.
--   2. No employment/worker-type classification exists anywhere for a
--      driver (drivers.pay_type is a PAYROLL mechanic -- per_mile/
--      percentage/hourly/salary -- not a tax/employment classification;
--      trucks/trailers.ownership_type is an EQUIPMENT ownership axis,
--      unrelated to who employs the driver). A genuine gap, not a
--      duplicate -- audited before adding driver_worker_type.
--   3. No Driver W-9 concept exists. Reuses carrier_w9s' entire proven
--      shape/RPC family (0099) field-for-field -- same tax-classification
--      enum, same TIN-encryption pattern, same certify-then-finalize
--      split, same supersession/void semantics -- as its own, separate
--      table (driver_w9s), never attached to a carrier's own W-9 (Section
--      K: "They are separate tax identities"). TIN encryption reuses the
--      EXISTING driver_pii_key (already provisioned for driver SSNs in
--      submit_driver_application(), 0018) rather than carrier_pii_key,
--      since this is driver PII, not carrier PII.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART 1 -- driver_worker_type + carrier binding on driver_applications/drivers.
-- ---------------------------------------------------------------------------
create type public.driver_worker_type as enum ('company_driver', 'independent_contractor', 'owner_operator');

comment on type public.driver_worker_type is
  'Employment/tax classification, distinct from drivers.pay_type (a payroll MECHANIC: per_mile/percentage/hourly/salary) and from trucks/trailers.ownership_type (an EQUIPMENT ownership axis). Drives whether a Driver W-9 is required (2Q.2B): company_driver (W-2) = not required; independent_contractor and owner_operator (1099) = required.';

alter table public.driver_applications
  add column if not exists carrier_id uuid references public.carriers (id) on delete restrict,
  add column if not exists worker_type public.driver_worker_type;

alter table public.drivers
  add column if not exists worker_type public.driver_worker_type;

comment on column public.driver_applications.carrier_id is
  'Which of the organization''s carriers this application is for, selected by staff at Invite Driver time (2Q.2B). Nullable only for backward compatibility with rows created before this column existed and with the public, anonymous /driver-application flow (which has never had a carrier-selection step) -- every NEW carrier-invited application is required, at the application layer and by driver_applications_insert_staff below, to set this. Never reassignable after creation: no UPDATE grant exists for this column (see PART 1b).';

-- 1b. Grants -- additive to 0018/0108's existing narrow column allow-lists.
-- carrier_id gets INSERT only, deliberately no UPDATE grant: "no silent
-- carrier reassignment" (2Q.2B Section D) is enforced at the privilege
-- level, not just by omitting a form field. worker_type gets both INSERT
-- and UPDATE (staff may need to correct a classification before the driver
-- reaches the Tax/W-9 step).
grant select (carrier_id, worker_type) on public.driver_applications to authenticated;
grant insert (carrier_id, worker_type) on public.driver_applications to authenticated;
grant update (worker_type) on public.driver_applications to authenticated;
grant select (worker_type) on public.drivers to authenticated;
grant update (worker_type) on public.drivers to authenticated;

-- 1c. Tighten driver_applications_insert_staff (0108) to also validate
-- carrier_id server-side, never trusting a browser-supplied id: must
-- belong to this organization and be active. Recreated (not merely
-- altered -- Postgres has no ALTER POLICY ... USING/WITH CHECK in one
-- statement across versions this project targets) with the exact same
-- shape 0108 defined, plus the new predicate.
drop policy if exists driver_applications_insert_staff on public.driver_applications;
create policy driver_applications_insert_staff on public.driver_applications
  for insert
  with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
    and status = 'invited'
    and (
      carrier_id is null
      or exists (select 1 from public.carriers where id = carrier_id and organization_id = public.current_org_id() and is_active)
    )
  );

-- ---------------------------------------------------------------------------
-- PART 2 -- indexes.
-- ---------------------------------------------------------------------------
create index if not exists driver_applications_carrier_id_idx on public.driver_applications (carrier_id);

-- ---------------------------------------------------------------------------
-- PART 3 -- convert_driver_application_to_driver: use the application's own
-- carrier_id when one is set (every carrier-invited application, from this
-- migration forward), never a caller-supplied one -- Section G: "Caller
-- must NOT be able to supply another carrier during conversion." The
-- public, anonymous-flow application (carrier_id always null, no
-- invitation, no carrier-selection step ever existed for it) keeps the
-- EXISTING staff-chooses-a-carrier-at-conversion behavior unchanged --
-- p_carrier_id is now optional and is validated/used ONLY for that case.
-- Also carries the driver's worker_type forward and, mirroring 0099's own
-- W-9 re-pointing precedent exactly, re-points this application's current
-- non-voided Driver W-9 (if any) onto the new driver -- no bytes moved, no
-- re-render, no certification change.
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
  v_w9_document_id uuid;
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

  if v_app.carrier_id is not null then
    v_carrier_id := v_app.carrier_id; -- authoritative once set at invite time; any p_carrier_id argument is ignored
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

  -- Re-point the current non-voided Driver W-9 (if any) onto the new
  -- driver -- mirrors convert_carrier_onboarding_application()'s own W-9
  -- handling (0099) exactly.
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
-- grant execute unchanged -- already granted to authenticated by 0018,
-- and the new argument has a default so every existing caller (the
-- public-flow "Hire & Convert" form, which only ever passes 2 positional
-- arguments) keeps working unmodified.

-- ---------------------------------------------------------------------------
-- PART 4 -- driver_w9s. Field-for-field mirror of carrier_w9s (0099) --
-- see this file's header comment for why it is its own table rather than
-- an extension of carrier_w9s.
-- ---------------------------------------------------------------------------
create type public.driver_w9_status as enum ('draft', 'completed', 'superseded', 'voided', 'failed');

create table public.driver_w9s (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  application_id uuid references public.driver_applications (id) on delete restrict,
  driver_id uuid references public.drivers (id) on delete restrict,
  carrier_id uuid references public.carriers (id) on delete set null,
  version integer,
  status public.driver_w9_status not null default 'draft',
  form_revision text not null default '2024-03',

  name_on_tax_return text,
  business_name text,

  tax_classification public.w9_tax_classification,
  llc_classification text check (llc_classification is null or llc_classification in ('C', 'S', 'P')),
  other_classification_description text,
  has_foreign_partners_owners boolean not null default false,

  exempt_payee_code text,
  fatca_exemption_code text,

  address_line1 text,
  city text,
  state text,
  postal_code text,
  requester_name_address text,
  account_numbers text,

  tin_type public.w9_tin_type,
  tin_encrypted bytea,
  tin_last4 text check (tin_last4 is null or tin_last4 ~ '^[0-9]{4}$'),

  certified_name text,
  certified_title text,
  certified_at timestamptz,
  certification_version text not null default 'w9-electronic-v1',

  generated_storage_path text,
  generated_pdf_sha256 text check (generated_pdf_sha256 is null or generated_pdf_sha256 ~ '^[0-9a-f]{64}$'),
  generated_file_size_bytes bigint check (generated_file_size_bytes is null or generated_file_size_bytes between 1 and 52428800),
  page_count integer check (page_count is null or page_count between 1 and 10),
  generated_at timestamptz,
  generated_by uuid references public.profiles (id) on delete set null,

  superseded_by uuid references public.driver_w9s (id) on delete set null,
  superseded_at timestamptz,

  voided_at timestamptz,
  voided_by uuid references public.profiles (id) on delete set null,
  void_reason text,

  failure_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,

  constraint driver_w9s_has_subject check (application_id is not null or driver_id is not null),
  constraint driver_w9s_generated_shape check (
    (status <> 'completed')
    or (
      generated_storage_path is not null and generated_pdf_sha256 is not null
      and generated_file_size_bytes is not null and page_count is not null and generated_at is not null
    )
  )
);

comment on table public.driver_w9s is
  'A DRIVER''s own Form W-9, collected during carrier-invited onboarding (2Q.2B) when worker_type requires it (independent_contractor/owner_operator). Deliberately separate from carrier_w9s (0099) -- a driver''s tax identity is never the same as the carrier''s. carrier_id is denormalized from the application at creation for staff filtering only, never authoritative on its own.';
comment on column public.driver_w9s.tin_encrypted is
  'pgp_sym_encrypt''d with driver_pii_key -- the SAME key already used for driver SSNs (submit_driver_application(), 0018) since this is driver PII, not carrier PII (which uses carrier_pii_key).';

create index driver_w9s_application_id_idx on public.driver_w9s (application_id);
create index driver_w9s_driver_id_idx on public.driver_w9s (driver_id);
create index driver_w9s_organization_id_idx on public.driver_w9s (organization_id);

create trigger set_updated_at
  before update on public.driver_w9s
  for each row execute function public.set_updated_at();

alter table public.driver_w9s enable row level security;

-- Staff can view (owner/admin/accountant -- mirrors carrier_w9s' own
-- W9StatusCard role gate exactly: dispatcher/viewer get status only via
-- the app layer's own masked summary, never raw table access). No
-- insert/update/delete policy -- every write goes through the RPCs below,
-- exactly like carrier_w9s.
create policy driver_w9s_select on public.driver_w9s
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

revoke select on public.driver_w9s from authenticated, anon;
grant select (
  id, organization_id, application_id, driver_id, carrier_id, version, status, form_revision,
  name_on_tax_return, business_name, tax_classification, llc_classification, other_classification_description,
  has_foreign_partners_owners, exempt_payee_code, fatca_exemption_code,
  address_line1, city, state, postal_code, requester_name_address, account_numbers,
  tin_type, tin_last4, certified_name, certified_title, certified_at, certification_version,
  generated_storage_path, generated_pdf_sha256, generated_file_size_bytes, page_count, generated_at,
  superseded_by, superseded_at, voided_at, void_reason, failure_reason, created_at, updated_at
) on public.driver_w9s to authenticated;
-- tin_encrypted deliberately excluded from the grant, exactly like
-- carrier_w9s -- readable only inside reveal_driver_w9_tin() below, which
-- runs as the table owner.

-- ---------------------------------------------------------------------------
-- PART 5 -- driver_w9_pii_access_log. Mirrors carrier_w9_pii_access_log
-- (0099) exactly.
-- ---------------------------------------------------------------------------
create table public.driver_w9_pii_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  w9_id uuid not null references public.driver_w9s (id) on delete cascade,
  accessed_by uuid not null references public.profiles (id) on delete set null,
  reason text not null,
  accessed_at timestamptz not null default now()
);

comment on table public.driver_w9_pii_access_log is
  'Immutable audit trail of every Driver W-9 TIN reveal. Written exclusively by reveal_driver_w9_tin(); no insert/update/delete policy exists for authenticated/anon.';

alter table public.driver_w9_pii_access_log enable row level security;

create policy driver_w9_pii_access_log_select on public.driver_w9_pii_access_log
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- PART 6 -- private storage bucket for the generated PDF. Own bucket, not
-- shared with carrier-w9s (Section K: separate tax identities all the way
-- down to storage, mirroring how carrier-w9s already got its own bucket
-- rather than reusing 'documents', 0099 PART 1B).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('driver-w9s', 'driver-w9s', false, 5242880, array['application/pdf'])
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- PART 7 -- RPCs. Same dual-caller shape as carrier_w9s' own RPCs (0099
-- PART 7 header comment, reproduced in spirit here): the driver-onboarding
-- portal has no Supabase Auth session at all (src/lib/driver-onboarding/
-- session.ts), so portal-side calls happen via the service-role client
-- from a trusted server action that has ALREADY verified the onboarding
-- session cookie -- every RPC a driver must call pre-conversion accepts an
-- explicit p_organization_id and is granted to service_role in addition
-- to authenticated. Staff-side callers get identical enforcement from the
-- same body via current_org_id()/has_role().
-- ---------------------------------------------------------------------------

create or replace function public.create_driver_w9_draft(
  p_organization_id uuid, p_application_id uuid, p_driver_id uuid
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_carrier_id uuid;
begin
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'Application or driver not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
      raise exception 'You do not have permission to create a W-9.';
    end if;
  end if;
  if p_application_id is null and p_driver_id is null then
    raise exception 'A W-9 must be associated with a driver application or a driver.';
  end if;

  if p_application_id is not null then
    select carrier_id into v_carrier_id from public.driver_applications where id = p_application_id and organization_id = p_organization_id;
  else
    select carrier_id into v_carrier_id from public.drivers where id = p_driver_id and organization_id = p_organization_id;
  end if;

  insert into public.driver_w9s (organization_id, application_id, driver_id, carrier_id, created_by)
  values (p_organization_id, p_application_id, p_driver_id, v_carrier_id, case when auth.role() = 'service_role' then null else auth.uid() end)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_driver_w9_draft(uuid, uuid, uuid) from public, anon;
grant execute on function public.create_driver_w9_draft(uuid, uuid, uuid) to authenticated, service_role;

create or replace function public.update_driver_w9_draft(
  p_w9_id uuid, p_organization_id uuid,
  p_name_on_tax_return text, p_business_name text,
  p_tax_classification public.w9_tax_classification, p_llc_classification text, p_other_classification_description text,
  p_has_foreign_partners_owners boolean, p_exempt_payee_code text, p_fatca_exemption_code text,
  p_address_line1 text, p_city text, p_state text, p_postal_code text
) returns void language plpgsql security definer set search_path = public as $$
declare v_w9 public.driver_w9s;
begin
  select * into v_w9 from public.driver_w9s where id = p_w9_id for update;
  if v_w9.id is null or v_w9.organization_id <> p_organization_id then raise exception 'W-9 record not found in your organization.'; end if;
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'W-9 record not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
      raise exception 'You do not have permission to edit this W-9.';
    end if;
  end if;
  if v_w9.status <> 'draft' or v_w9.certified_at is not null then
    raise exception 'Only an uncertified draft W-9 may be edited.';
  end if;

  update public.driver_w9s set
    name_on_tax_return = nullif(btrim(p_name_on_tax_return), ''),
    business_name = nullif(btrim(p_business_name), ''),
    tax_classification = p_tax_classification,
    llc_classification = nullif(btrim(p_llc_classification), ''),
    other_classification_description = nullif(btrim(p_other_classification_description), ''),
    has_foreign_partners_owners = coalesce(p_has_foreign_partners_owners, false),
    exempt_payee_code = nullif(btrim(p_exempt_payee_code), ''),
    fatca_exemption_code = nullif(btrim(p_fatca_exemption_code), ''),
    address_line1 = nullif(btrim(p_address_line1), ''),
    city = nullif(btrim(p_city), ''),
    state = nullif(btrim(p_state), ''),
    postal_code = nullif(btrim(p_postal_code), '')
  where id = p_w9_id;
end;
$$;

revoke execute on function public.update_driver_w9_draft(uuid, uuid, text, text, public.w9_tax_classification, text, text, boolean, text, text, text, text, text, text) from public, anon;
grant execute on function public.update_driver_w9_draft(uuid, uuid, text, text, public.w9_tax_classification, text, text, boolean, text, text, text, text, text, text) to authenticated, service_role;

-- set_driver_w9_tin(): same isolation reasoning as set_carrier_w9_tin()
-- (0099) -- the one and only place a plaintext TIN is ever an argument.
create or replace function public.set_driver_w9_tin(
  p_w9_id uuid, p_organization_id uuid, p_tin_type public.w9_tin_type, p_tin text
) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_w9 public.driver_w9s; v_digits text; v_key text;
begin
  select * into v_w9 from public.driver_w9s where id = p_w9_id for update;
  if v_w9.id is null or v_w9.organization_id <> p_organization_id then raise exception 'W-9 record not found in your organization.'; end if;
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'W-9 record not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
      raise exception 'You do not have permission to edit this W-9.';
    end if;
  end if;
  if v_w9.status <> 'draft' or v_w9.certified_at is not null then
    raise exception 'Only an uncertified draft W-9 may be edited.';
  end if;

  v_digits := regexp_replace(coalesce(p_tin, ''), '[^0-9]', '', 'g');
  if length(v_digits) <> 9 then
    raise exception 'A Social Security Number or Employer Identification Number must be exactly 9 digits.';
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');
  update public.driver_w9s set
    tin_type = p_tin_type,
    tin_encrypted = pgp_sym_encrypt(v_digits, v_key),
    tin_last4 = right(v_digits, 4)
  where id = p_w9_id;
end;
$$;

revoke execute on function public.set_driver_w9_tin(uuid, uuid, public.w9_tin_type, text) from public, anon;
grant execute on function public.set_driver_w9_tin(uuid, uuid, public.w9_tin_type, text) to authenticated, service_role;

create or replace function public.certify_driver_w9(
  p_w9_id uuid, p_organization_id uuid, p_certified_name text, p_certified_title text
) returns integer language plpgsql security definer set search_path = public as $$
declare v_w9 public.driver_w9s; v_subject uuid; v_version integer;
begin
  select * into v_w9 from public.driver_w9s where id = p_w9_id for update;
  if v_w9.id is null or v_w9.organization_id <> p_organization_id then raise exception 'W-9 record not found in your organization.'; end if;
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'W-9 record not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
      raise exception 'You do not have permission to certify this W-9.';
    end if;
  end if;
  if v_w9.status <> 'draft' or v_w9.certified_at is not null then
    raise exception 'This W-9 has already been certified.';
  end if;

  if nullif(btrim(v_w9.name_on_tax_return), '') is null then raise exception 'A taxpayer name is required.'; end if;
  if v_w9.tax_classification is null then raise exception 'A federal tax classification is required.'; end if;
  if v_w9.tax_classification = 'llc' and v_w9.llc_classification is null then
    raise exception 'An LLC must specify its tax classification (C, S, or P).';
  end if;
  if v_w9.tax_classification = 'other' and nullif(btrim(v_w9.other_classification_description), '') is null then
    raise exception 'An "Other" classification requires a description.';
  end if;
  if nullif(btrim(v_w9.address_line1), '') is null or nullif(btrim(v_w9.city), '') is null
    or nullif(btrim(v_w9.state), '') is null or nullif(btrim(v_w9.postal_code), '') is null then
    raise exception 'A complete address is required.';
  end if;
  if v_w9.tin_encrypted is null or v_w9.tin_type is null then raise exception 'A Taxpayer Identification Number is required.'; end if;
  if nullif(btrim(p_certified_name), '') is null then raise exception 'A certifying signer name is required.'; end if;
  if v_w9.has_foreign_partners_owners and not (
    v_w9.tax_classification in ('partnership', 'trust_estate')
    or (v_w9.tax_classification = 'llc' and v_w9.llc_classification = 'P')
  ) then
    raise exception 'Line 3b (foreign partners, owners, or beneficiaries) only applies to a Partnership, Trust/estate, or an LLC taxed as a partnership.';
  end if;

  v_subject := coalesce(v_w9.driver_id, v_w9.application_id);
  perform pg_advisory_xact_lock(hashtext(v_w9.organization_id::text), hashtext('driver-w9:' || v_subject::text));
  select coalesce(max(version), 0) + 1 into v_version
  from public.driver_w9s
  where organization_id = v_w9.organization_id
    and coalesce(driver_id, application_id) = v_subject
    and version is not null;

  update public.driver_w9s set
    version = v_version,
    certified_name = btrim(p_certified_name),
    certified_title = nullif(btrim(p_certified_title), ''),
    certified_at = now()
  where id = p_w9_id;

  return v_version;
end;
$$;

revoke execute on function public.certify_driver_w9(uuid, uuid, text, text) from public, anon;
grant execute on function public.certify_driver_w9(uuid, uuid, text, text) to authenticated, service_role;

-- finalize_driver_w9(): service-role only. Unlike finalize_carrier_w9(),
-- deliberately does NOT register a public.documents row -- driver
-- onboarding never otherwise uses the generic documents table (its CDL/
-- medical-card captures live in driver_applications.uploaded_documents,
-- a jsonb array, not polymorphic documents rows), so there is no packet-
-- builder or similar consumer this phase that needs that linkage. This
-- table's own generated_storage_path is the sole source of truth,
-- exactly how the driver-onboarding review UI and staff Driver Profile
-- read it (getMyW9Url()-equivalent signed-URL pattern).
create or replace function public.finalize_driver_w9(
  p_w9_id uuid, p_storage_path text, p_file_size_bytes bigint, p_page_count integer, p_generated_pdf_sha256 text
) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_w9 public.driver_w9s; v_subject uuid; v_higher uuid; v_previous uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may finalize a W-9.'; end if;
  select * into v_w9 from public.driver_w9s where id = p_w9_id for update;
  if v_w9.id is null or v_w9.status <> 'draft' or v_w9.certified_at is null then
    raise exception 'Certified W-9 not found.';
  end if;

  v_subject := coalesce(v_w9.driver_id, v_w9.application_id);
  perform pg_advisory_xact_lock(hashtext(v_w9.organization_id::text), hashtext('driver-w9:' || v_subject::text));

  if p_storage_path <> format('%s/%s/w9-v%s.pdf', v_w9.organization_id, v_w9.id, v_w9.version) then
    raise exception 'Invalid W-9 storage path.';
  end if;
  if p_file_size_bytes <= 0 or p_file_size_bytes > 52428800 then raise exception 'Generated W-9 exceeds the 50 MB limit.'; end if;
  if p_page_count not between 1 and 10 then raise exception 'Generated W-9 has an unexpected page count.'; end if;
  if p_generated_pdf_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'Generated PDF hash is not a valid lowercase SHA-256 value.'; end if;

  update public.driver_w9s set
    status = 'completed', generated_storage_path = p_storage_path, generated_file_size_bytes = p_file_size_bytes,
    page_count = p_page_count, generated_pdf_sha256 = p_generated_pdf_sha256, generated_at = now(), generated_by = null
  where id = p_w9_id;

  select id into v_higher from public.driver_w9s
  where organization_id = v_w9.organization_id
    and coalesce(driver_id, application_id) = v_subject
    and version > v_w9.version and status = 'completed'
  limit 1;

  if v_higher is not null then
    update public.driver_w9s set status = 'superseded', superseded_by = v_higher, superseded_at = now() where id = p_w9_id;
  else
    for v_previous in
      select id from public.driver_w9s
      where organization_id = v_w9.organization_id
        and coalesce(driver_id, application_id) = v_subject
        and version < v_w9.version and status = 'completed'
    loop
      update public.driver_w9s set status = 'superseded', superseded_by = p_w9_id, superseded_at = now() where id = v_previous;
    end loop;
  end if;
end;
$$;

revoke execute on function public.finalize_driver_w9(uuid, text, bigint, integer, text) from public, authenticated, anon;
grant execute on function public.finalize_driver_w9(uuid, text, bigint, integer, text) to service_role;

create or replace function public.fail_driver_w9(p_w9_id uuid, p_failure_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may fail a W-9.'; end if;
  update public.driver_w9s set
    status = 'failed',
    failure_reason = left(coalesce(nullif(btrim(p_failure_reason), ''), 'W-9 generation failed.'), 500)
  where id = p_w9_id and status = 'draft' and certified_at is not null;
  if not found then raise exception 'Certified W-9 not found.'; end if;
end;
$$;

revoke execute on function public.fail_driver_w9(uuid, text) from public, authenticated, anon;
grant execute on function public.fail_driver_w9(uuid, text) to service_role;

create or replace function public.void_driver_w9(p_w9_id uuid, p_organization_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'W-9 record not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin']::public.org_role[]) then
      raise exception 'Only owners and admins may void a W-9.';
    end if;
  end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A void reason is required.'; end if;

  update public.driver_w9s set voided_at = now(), voided_by = case when auth.role() = 'service_role' then null else auth.uid() end, void_reason = left(btrim(p_reason), 500), status = 'voided'
  where id = p_w9_id and organization_id = p_organization_id and status in ('draft', 'completed');
  if not found then raise exception 'W-9 record not found or cannot be voided.'; end if;
end;
$$;

revoke execute on function public.void_driver_w9(uuid, uuid, text) from public, anon;
grant execute on function public.void_driver_w9(uuid, uuid, text) to authenticated, service_role;

create or replace function public.delete_driver_w9_draft(p_w9_id uuid, p_organization_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'W-9 record not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
      raise exception 'You do not have permission to delete this W-9 draft.';
    end if;
  end if;
  delete from public.driver_w9s where id = p_w9_id and organization_id = p_organization_id and status = 'draft' and certified_at is null;
  if not found then raise exception 'Draft W-9 not found or already certified.'; end if;
end;
$$;

revoke execute on function public.delete_driver_w9_draft(uuid, uuid) from public, anon;
grant execute on function public.delete_driver_w9_draft(uuid, uuid) to authenticated, service_role;

-- reveal_driver_w9_tin(): staff-only (owner/admin), reason required, one
-- audit row per reveal -- no service_role grant, mirrors
-- reveal_carrier_w9_tin() exactly.
create or replace function public.reveal_driver_w9_tin(p_w9_id uuid, p_reason text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_org_id uuid; v_key text; v_encrypted bytea;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to reveal this TIN.';
  end if;

  select organization_id, tin_encrypted into v_org_id, v_encrypted
  from public.driver_w9s where id = p_w9_id;

  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'W-9 record not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may reveal this field.';
  end if;
  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');

  insert into public.driver_w9_pii_access_log (organization_id, w9_id, accessed_by, reason)
  values (v_org_id, p_w9_id, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;

revoke execute on function public.reveal_driver_w9_tin(uuid, text) from public, anon;
grant execute on function public.reveal_driver_w9_tin(uuid, text) to authenticated;
