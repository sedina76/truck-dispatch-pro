-- =============================================================================
-- 0042_profile_sharing.sql
-- Shareable Driver / Carrier Profile workflow. Inspected first: drivers
-- (0003, expanded 0014), carriers (0003), insurance_policies (0014),
-- documents (0005, polymorphic entity_type already includes 'driver'/
-- 'carrier'/'load'), loads/load_stops/dispatches (0004), email_send_log
-- (0039, the pattern this mirrors for honest-blocked send logging),
-- statements' private-bucket + signed-URL pattern (0029, the pattern this
-- mirrors for PDF storage).
--
-- KEY DECISIONS:
-- 1. NOT a generic "take the full driver/carrier row and hide some fields"
--    view. Two new SQL functions, get_external_driver_profile() and
--    get_external_carrier_profile(), each with an explicit column list in
--    their SELECT -- the allowlist lives at the query level, so a future
--    sensitive column added to drivers/carriers can never silently leak
--    into an external PDF just by existing (spec section 21).
-- 2. drivers.photo_shareable (new, default false): the spec calls for the
--    driver photo to appear "if approved for sharing" -- no such consent
--    concept existed anywhere in the schema, so rather than silently
--    treating "a photo_url is set" as implicit approval, this is an
--    explicit, safe-by-default opt-in column staff must turn on per driver.
-- 3. profile_share_log is the single audit trail for every generate/
--    download/email attempt (spec section 12), with a frozen JSONB
--    snapshot of exactly what was shared (spec section 13) so later
--    changes to the live driver/carrier/load never rewrite history.
--    Never SECURITY DEFINER -- runs under the caller's own RLS.
-- 4. guard_profile_share_org: same-org guard on load_id/driver_id/
--    carrier_id (this session's standard cross-table-FK pattern) PLUS a
--    document-safety guard -- every id in document_ids_included must
--    already belong to the same org and to the driver/carrier on this
--    share, and if its document_type is in the sensitive list (cdl,
--    medical_card), the caller must be owner/admin. This is enforced at
--    the database level, not only in the UI, so a crafted API call can't
--    bypass it (spec section 23).
-- 5. Private 'shared-profiles' storage bucket, path
--    {organization_id}/{load_id}/{profile_share_id}/profile.pdf, signed
--    URLs only, no public bucket -- identical pattern to 'statements'
--    (0029) and 'expense-documents' (0040).
-- =============================================================================

create type public.profile_share_type as enum ('driver', 'carrier', 'combined');
create type public.profile_share_status as enum ('GENERATED', 'SENT', 'BLOCKED', 'FAILED');

-- ---------------------------------------------------------------------------
-- Explicit consent flag for including a driver's photo in an EXTERNAL
-- (broker/customer-facing) profile. Default false -- a photo_url being set
-- is not by itself "approved for sharing".
-- ---------------------------------------------------------------------------
alter table public.drivers add column photo_shareable boolean not null default false;

comment on column public.drivers.photo_shareable is
  'Explicit staff opt-in for including this driver''s photo in an external (broker/customer-facing) shared profile. Default false -- a photo_url existing is not itself consent to share it externally.';

-- photo_shareable needs to be selectable/settable like any ordinary driver
-- field -- drivers already has column-level grants locked down (0014) to
-- exclude only the three encrypted PII columns, so it's added to both.
grant select (photo_shareable) on public.drivers to authenticated;
grant update (photo_shareable) on public.drivers to authenticated;

-- ---------------------------------------------------------------------------
-- profile_share_log: audit trail + immutable snapshot for every generated
-- external profile (spec sections 12/13/19).
-- ---------------------------------------------------------------------------
create table public.profile_share_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete restrict,
  driver_id uuid references public.drivers (id) on delete set null,
  carrier_id uuid references public.carriers (id) on delete set null,
  profile_type public.profile_share_type not null,
  recipient_email text not null,
  recipient_party_type text check (recipient_party_type in ('broker', 'customer')),
  document_ids_included uuid[] not null default '{}'::uuid[],
  snapshot jsonb not null,
  storage_path text,
  status public.profile_share_status not null default 'GENERATED',
  error text,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.profiles (id) on delete set null,
  sent_at timestamptz,
  sent_by uuid references public.profiles (id) on delete set null,
  constraint profile_share_log_requires_subject check (driver_id is not null or carrier_id is not null),
  constraint profile_share_log_failure_requires_error check (status not in ('BLOCKED', 'FAILED') or error is not null)
);

comment on table public.profile_share_log is
  'Every Share Profile generate/download/email attempt for a load''s assigned driver/carrier. snapshot is a frozen JSONB copy of exactly what was shared (spec section 13) -- later edits to the live driver/carrier/load never change a historical row. document_ids_included stores document IDs only, never document contents (spec section 12).';

create index idx_profile_share_log_load on public.profile_share_log (load_id, generated_at desc);
create index idx_profile_share_log_org on public.profile_share_log (organization_id, generated_at desc);

alter table public.profile_share_log enable row level security;

create policy profile_share_log_select on public.profile_share_log
  for select using (organization_id = public.current_org_id());

create policy profile_share_log_insert on public.profile_share_log
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- Sending is the only post-insert mutation ever allowed (GENERATED -> SENT/
-- BLOCKED/FAILED, plus sent_at/sent_by/error) -- see guard_profile_share_
-- immutable below for what's actually enforced. Same role list as insert:
-- whoever could generate a share can also attempt to send it.
create policy profile_share_log_update on public.profile_share_log
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- No delete policy -- append-only audit trail, matching email_send_log
-- (0039) and driver_pii_access_log (0014).

-- ---------------------------------------------------------------------------
-- guard_profile_share_org: same-org guard on every FK, plus document
-- safety (spec sections 20/23).
-- ---------------------------------------------------------------------------
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

drop trigger if exists profile_share_log_guard_org on public.profile_share_log;
create trigger profile_share_log_guard_org
  before insert on public.profile_share_log
  for each row execute function public.guard_profile_share_org();

-- ---------------------------------------------------------------------------
-- guard_profile_share_immutable: once written, a share record is a
-- historical fact. The only legal updates are the send outcome (status/
-- error/sent_at/sent_by) -- everything else (snapshot, recipient,
-- document list, which driver/carrier/load) is frozen, matching "no
-- overwrite" (spec section 33) and "do not rely only on CSS hiding /
-- silently regenerate historical profiles" (spec section 19/22).
-- ---------------------------------------------------------------------------
create or replace function public.guard_profile_share_immutable()
returns trigger
language plpgsql
as $$
begin
  -- storage_path is reserve-row-then-upload-then-fill (same pattern as
  -- statements/actions.ts::generateStatement): the row is inserted first
  -- so the PDF's storage path can be keyed on a real id, then filled in by
  -- a follow-up UPDATE once the upload succeeds. That ONE null-to-value
  -- transition is allowed; any change after it's already set is not (no
  -- swapping the file a share record points to after the fact).
  if new.storage_path is distinct from old.storage_path and old.storage_path is not null then
    raise exception 'A generated profile''s storage path cannot be changed once set.';
  end if;
  if new.snapshot is distinct from old.snapshot
    or new.recipient_email is distinct from old.recipient_email
    or new.profile_type is distinct from old.profile_type
    or new.document_ids_included is distinct from old.document_ids_included
    or new.load_id is distinct from old.load_id
    or new.driver_id is distinct from old.driver_id
    or new.carrier_id is distinct from old.carrier_id
  then
    raise exception 'A generated profile share is a historical record and cannot be modified -- only its storage path (once, on first upload) and send outcome (status/error/sent_at/sent_by) may change.';
  end if;
  if old.status <> 'GENERATED' and new.status is distinct from old.status then
    raise exception 'A share''s send outcome can only be recorded once.';
  end if;
  return new;
end;
$$;

drop trigger if exists profile_share_log_guard_immutable on public.profile_share_log;
create trigger profile_share_log_guard_immutable
  before update on public.profile_share_log
  for each row execute function public.guard_profile_share_immutable();

-- ---------------------------------------------------------------------------
-- get_external_driver_profile: THE allowlist for driver data on an
-- external profile. Explicit column list -- no select(*), so a future
-- sensitive column added to drivers cannot silently appear here (spec
-- section 21). Never returns SSN, DOB, address, emergency contact,
-- employment application, bank info, pay rate, or any HR/background/drug
-- test detail -- this function has no SELECT path to any of them at all.
-- ---------------------------------------------------------------------------
create or replace function public.get_external_driver_profile(p_driver_id uuid)
returns table (
  driver_id uuid,
  full_name text,
  phone text,
  photo_url text,
  status public.driver_status,
  cdl_class text,
  cdl_state text,
  cdl_expiry_date date,
  cdl_endorsements text,
  medical_card_expiry_date date,
  years_experience numeric,
  completed_trips bigint
)
language sql
stable
as $$
  select
    d.id,
    trim(d.first_name || ' ' || d.last_name),
    d.phone,
    case when d.photo_shareable then d.photo_url else null end,
    d.status,
    d.cdl_class,
    d.cdl_state,
    d.cdl_expiry_date,
    d.cdl_endorsements,
    d.medical_card_expiry_date,
    case when d.hire_date is not null then round((current_date - d.hire_date) / 365.25, 1) else null end,
    (select count(*) from public.dispatches disp where disp.driver_id = d.id and disp.status = 'completed')
  from public.drivers d
  where d.id = p_driver_id;
$$;

grant execute on function public.get_external_driver_profile(uuid) to authenticated;

comment on function public.get_external_driver_profile(uuid) is
  'Broker/customer-safe driver allowlist. Deliberately excludes: SSN, DOB, home address, emergency contact, employment application fields, bank/direct-deposit info, pay rate/type, background check/drug test/MVR details, internal notes -- none of those columns are referenced in this function''s body at all.';

-- ---------------------------------------------------------------------------
-- get_external_carrier_profile: same allowlist principle for carriers.
-- Never returns settlement amounts, pay rate, Quick Pay fee, advances,
-- deductions, margin, banking, internal notes, or EIN -- no SELECT path to
-- settlements/settlement_line_items/dispatch_advances/carriers.ein exists
-- in this function.
--
-- "Auto Liability" (spec wording) is mapped to insurance_policies'
-- 'general_liability' policy_type -- the closest and only carrier-level
-- liability coverage this schema tracks (0014_company_driver_compliance_
-- expansion.sql defines general_liability/cargo/physical_damage/
-- workers_compensation; there is no separate "auto_liability" type).
-- ---------------------------------------------------------------------------
create or replace function public.get_external_carrier_profile(p_carrier_id uuid)
returns table (
  carrier_id uuid,
  legal_name text,
  dba_name text,
  mc_number text,
  dot_number text,
  phone text,
  email text,
  address text,
  is_active boolean,
  auto_liability_status text,
  auto_liability_expiry date,
  cargo_insurance_status text,
  cargo_insurance_expiry date,
  completed_loads bigint
)
language sql
stable
as $$
  with gl as (
    select expiry_date from public.insurance_policies
    where carrier_id = p_carrier_id and policy_type = 'general_liability'
    order by expiry_date desc nulls last
    limit 1
  ),
  cargo as (
    select expiry_date from public.insurance_policies
    where carrier_id = p_carrier_id and policy_type = 'cargo'
    order by expiry_date desc nulls last
    limit 1
  )
  select
    c.id, c.legal_name, c.dba_name, c.mc_number, c.dot_number, c.phone, c.email,
    nullif(concat_ws(', ', c.address_line1, c.city, c.state, c.postal_code), ''),
    c.is_active,
    -- Lowercase 'active'/'expired'/'missing' -- matches the same status
    -- vocabulary StatusBadge (src/components/ui/status-badge.tsx) already
    -- maps to success/danger/neutral tones everywhere else in this app,
    -- so the profile UI needs no special-casing to color these correctly.
    case when gl.expiry_date is null then 'missing' when gl.expiry_date >= current_date then 'active' else 'expired' end,
    gl.expiry_date,
    case when cargo.expiry_date is null then 'missing' when cargo.expiry_date >= current_date then 'active' else 'expired' end,
    cargo.expiry_date,
    (select count(*) from public.dispatches disp where disp.carrier_id = c.id and disp.status = 'completed')
  from public.carriers c
  left join gl on true
  left join cargo on true
  where c.id = p_carrier_id;
$$;

grant execute on function public.get_external_carrier_profile(uuid) to authenticated;

comment on function public.get_external_carrier_profile(uuid) is
  'Broker/customer-safe carrier allowlist. Deliberately excludes: settlement amounts, carrier pay rate, Quick Pay fee, advances, deductions, company margin, banking info, internal notes, EIN -- none of those columns/tables are referenced in this function''s body at all.';

-- ---------------------------------------------------------------------------
-- Private storage bucket for generated profile-share PDFs (spec section
-- 14). No public URL ever; every read is a fresh short-lived signed URL,
-- identical convention to 'statements' (0029) and 'expense-documents'
-- (0040/0041).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shared-profiles', 'shared-profiles', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

drop policy if exists shared_profiles_select on storage.objects;
create policy shared_profiles_select on storage.objects
  for select using (
    bucket_id = 'shared-profiles'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

drop policy if exists shared_profiles_insert on storage.objects;
create policy shared_profiles_insert on storage.objects
  for insert with check (
    bucket_id = 'shared-profiles'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy -- a generated profile PDF is never edited or
-- replaced in place; a new share is a new object at a new profile_share_id
-- path, matching every other document/receipt bucket in this codebase.
