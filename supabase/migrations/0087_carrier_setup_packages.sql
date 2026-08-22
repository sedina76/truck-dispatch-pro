-- =============================================================================
-- 0087_carrier_setup_packages.sql
-- Phase 2L.5A: immutable broker-facing carrier setup packages.
-- =============================================================================

create type public.carrier_setup_package_status as enum (
  'generating', 'generated', 'sent', 'failed', 'voided'
);

create table public.carrier_setup_packages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  onboarding_application_id uuid not null references public.carrier_onboarding_applications(id) on delete restrict,
  carrier_id uuid references public.carriers(id) on delete restrict,
  broker_id uuid references public.brokers(id) on delete set null,
  version integer not null check (version > 0),
  status public.carrier_setup_package_status not null default 'generating',
  recipient_name text,
  recipient_email text,
  prepared_for_name text,
  carrier_snapshot jsonb not null,
  organization_snapshot jsonb not null,
  equipment_snapshot jsonb,
  generated_storage_path text,
  generated_file_size_bytes bigint check (generated_file_size_bytes is null or generated_file_size_bytes >= 0),
  page_count integer check (page_count is null or page_count between 1 and 250),
  document_count integer not null check (document_count between 1 and 12),
  generated_by uuid references public.profiles(id) on delete set null,
  generated_at timestamptz,
  last_sent_at timestamptz,
  last_sent_by uuid references public.profiles(id) on delete set null,
  last_sent_recipient_name text,
  last_sent_recipient_email text,
  last_email_send_log_id uuid,
  voided_at timestamptz,
  voided_by uuid references public.profiles(id) on delete set null,
  void_reason text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (onboarding_application_id, version),
  constraint carrier_setup_package_generated_shape check (
    status not in ('generated', 'sent')
    or (generated_storage_path is not null and generated_file_size_bytes is not null and page_count is not null and generated_at is not null)
  ),
  constraint carrier_setup_package_failed_shape check (
    status <> 'failed' or (failure_reason is not null and generated_storage_path is null)
  ),
  constraint carrier_setup_package_voided_shape check (
    status <> 'voided' or (voided_at is not null and voided_by is not null and void_reason is not null)
  )
);

create index carrier_setup_packages_org_application_created_idx
  on public.carrier_setup_packages (organization_id, onboarding_application_id, created_at desc);

create table public.carrier_setup_package_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  package_id uuid not null references public.carrier_setup_packages(id) on delete restrict,
  document_id uuid not null references public.documents(id) on delete restrict,
  document_type public.document_type not null,
  display_order integer not null check (display_order > 0),
  source_filename text not null,
  source_storage_bucket text not null,
  source_storage_path text not null,
  source_mime_type text,
  source_file_size_bytes bigint check (source_file_size_bytes is null or source_file_size_bytes between 1 and 10485760),
  source_created_at timestamptz not null,
  source_expiry_date date,
  source_verified_at timestamptz not null,
  source_content_hash text,
  start_page integer,
  end_page integer,
  included_at timestamptz not null default now(),
  unique (package_id, document_id),
  unique (package_id, display_order),
  constraint carrier_setup_package_item_hash_format check (
    source_content_hash is null or source_content_hash ~ '^[0-9a-f]{64}$'
  ),
  constraint carrier_setup_package_item_page_range check (
    (start_page is null and end_page is null)
    or (start_page is not null and end_page is not null and start_page > 0 and end_page >= start_page)
  )
);

alter table public.email_send_log
  add column carrier_setup_package_id uuid references public.carrier_setup_packages(id) on delete restrict;

alter table public.carrier_setup_packages
  add constraint carrier_setup_packages_last_email_send_log_fk
  foreign key (last_email_send_log_id) references public.email_send_log(id) on delete set null;

create index email_send_log_carrier_setup_package_idx
  on public.email_send_log (carrier_setup_package_id, sent_at desc)
  where carrier_setup_package_id is not null;

create or replace function public.guard_email_send_log_setup_package_org()
returns trigger language plpgsql set search_path=public as $$
declare v_org uuid;
begin
  if new.carrier_setup_package_id is null then return new; end if;
  select organization_id into v_org from public.carrier_setup_packages where id=new.carrier_setup_package_id;
  if v_org is null or v_org<>new.organization_id then
    raise exception 'Email setup package must belong to the same organization.';
  end if;
  return new;
end;
$$;

create trigger email_send_log_setup_package_org_guard
  before insert or update of carrier_setup_package_id,organization_id on public.email_send_log
  for each row execute function public.guard_email_send_log_setup_package_org();

create or replace function public.guard_carrier_setup_package_relationships()
returns trigger language plpgsql set search_path = public as $$
declare
  v_application public.carrier_onboarding_applications;
  v_related_org uuid;
begin
  select * into v_application from public.carrier_onboarding_applications
  where id = new.onboarding_application_id;
  if v_application.id is null or v_application.organization_id <> new.organization_id then
    raise exception 'Setup package application must belong to the same organization.';
  end if;
  if v_application.status not in ('approved', 'converted') then
    raise exception 'Only approved or converted onboarding applications can have setup packages.';
  end if;
  if v_application.status = 'converted' then
    if new.carrier_id is null or new.carrier_id is distinct from v_application.converted_carrier_id then
      raise exception 'Converted setup packages must reference the application''s canonical carrier.';
    end if;
    select organization_id into v_related_org from public.carriers where id = new.carrier_id and is_active;
    if v_related_org is null or v_related_org <> new.organization_id then
      raise exception 'The converted carrier must be active and belong to the same organization.';
    end if;
  elsif new.carrier_id is not null then
    raise exception 'An approved, unconverted application cannot reference a canonical carrier.';
  end if;
  if new.broker_id is not null then
    select organization_id into v_related_org from public.brokers where id = new.broker_id;
    if v_related_org is null or v_related_org <> new.organization_id then
      raise exception 'Prepared-for broker must belong to the same organization.';
    end if;
  end if;
  return new;
end;
$$;

create trigger carrier_setup_packages_relationship_guard
  before insert on public.carrier_setup_packages
  for each row execute function public.guard_carrier_setup_package_relationships();

create or replace function public.guard_carrier_setup_package_item()
returns trigger language plpgsql set search_path = public as $$
declare
  v_package public.carrier_setup_packages;
  v_document public.documents;
  v_latest_id uuid;
begin
  select * into v_package from public.carrier_setup_packages where id = new.package_id;
  select * into v_document from public.documents where id = new.document_id;
  if v_package.id is null or v_package.organization_id <> new.organization_id then
    raise exception 'Package item must belong to its package organization.';
  end if;
  if v_package.status <> 'generating' then
    raise exception 'Items may only be added while a package is generating.';
  end if;
  if v_document.id is null or v_document.organization_id <> new.organization_id
    or v_document.entity_type <> 'carrier_onboarding_application'
    or v_document.entity_id <> v_package.onboarding_application_id then
    raise exception 'Selected document does not belong to this onboarding application.';
  end if;
  select id into v_latest_id from public.documents
  where organization_id = new.organization_id
    and entity_type = 'carrier_onboarding_application'
    and entity_id = v_package.onboarding_application_id
    and document_type = v_document.document_type
  order by created_at desc, id desc limit 1;
  if v_latest_id is distinct from v_document.id then
    raise exception 'Only the latest document of each type may be included.';
  end if;
  if not v_document.is_verified or v_document.verified_at is null or v_document.rejected_at is not null then
    raise exception 'Selected documents must be verified and not rejected.';
  end if;
  if v_document.expiry_date is not null and v_document.expiry_date < current_date then
    raise exception 'Expired documents cannot be included in a setup package.';
  end if;
  if coalesce(v_document.mime_type,'') not in ('application/pdf', 'image/jpeg', 'image/png') then
    raise exception 'Only PDF, JPEG, and PNG documents may be included.';
  end if;
  if v_document.file_size_bytes is null or v_document.file_size_bytes <= 0 or v_document.file_size_bytes > 10485760 then
    raise exception 'Each source document must have a known size of 10 MB or less.';
  end if;
  if v_document.document_type = 'signed_agreement' then
    raise exception 'Signed agreement inclusion is unavailable until an executed agreement PDF exists.';
  end if;
  if v_document.document_type not in (
    'w9','insurance_certificate','motor_carrier_authority','notice_of_assignment',
    'factoring_notice','voided_check','vehicle_registration','ifta_credential',
    'inspection_report','other'
  ) then
    raise exception 'This document type is not approved for broker setup packages.';
  end if;
  if new.document_type is distinct from v_document.document_type
    or new.source_filename is distinct from v_document.file_name
    or new.source_storage_bucket <> 'carrier-onboarding-documents'
    or new.source_storage_path is distinct from v_document.file_path
    or new.source_mime_type is distinct from v_document.mime_type
    or new.source_file_size_bytes is distinct from v_document.file_size_bytes
    or new.source_created_at is distinct from v_document.created_at
    or new.source_expiry_date is distinct from v_document.expiry_date
    or new.source_verified_at is distinct from v_document.verified_at then
    raise exception 'Package item source snapshot does not match its document.';
  end if;
  return new;
end;
$$;

create trigger carrier_setup_package_items_guard
  before insert on public.carrier_setup_package_items
  for each row execute function public.guard_carrier_setup_package_item();

create or replace function public.guard_carrier_setup_package_immutability()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.organization_id is distinct from old.organization_id
    or new.onboarding_application_id is distinct from old.onboarding_application_id
    or new.carrier_id is distinct from old.carrier_id
    or new.broker_id is distinct from old.broker_id
    or new.version is distinct from old.version
    or new.recipient_name is distinct from old.recipient_name
    or new.recipient_email is distinct from old.recipient_email
    or new.prepared_for_name is distinct from old.prepared_for_name
    or new.carrier_snapshot is distinct from old.carrier_snapshot
    or new.organization_snapshot is distinct from old.organization_snapshot
    or new.equipment_snapshot is distinct from old.equipment_snapshot
    or new.document_count is distinct from old.document_count
    or new.generated_by is distinct from old.generated_by
    or new.created_at is distinct from old.created_at then
    raise exception 'A setup package''s frozen identity and contents cannot be changed.';
  end if;
  if old.generated_storage_path is not null and new.generated_storage_path is distinct from old.generated_storage_path then
    raise exception 'A generated package PDF cannot be replaced.';
  end if;
  if old.status = 'generating' and new.status not in ('generated', 'failed') then
    raise exception 'Invalid setup package status transition.';
  elsif old.status = 'generated' and new.status not in ('generated', 'sent', 'voided') then
    raise exception 'Invalid setup package status transition.';
  elsif old.status = 'sent' and new.status not in ('sent', 'voided') then
    raise exception 'Invalid setup package status transition.';
  elsif old.status in ('failed', 'voided') and new.status <> old.status then
    raise exception 'Failed and voided setup packages are terminal.';
  end if;
  return new;
end;
$$;

create trigger carrier_setup_packages_immutability_guard
  before update on public.carrier_setup_packages
  for each row execute function public.guard_carrier_setup_package_immutability();

create or replace function public.guard_carrier_setup_package_item_immutability()
returns trigger language plpgsql set search_path = public as $$
declare v_status public.carrier_setup_package_status;
begin
  if tg_op = 'DELETE' then
    select status into v_status from public.carrier_setup_packages where id = old.package_id;
    if v_status is distinct from 'generating' then raise exception 'Generated package items cannot be deleted.'; end if;
    return old;
  end if;
  select status into v_status from public.carrier_setup_packages where id = old.package_id;
  if v_status <> 'generating' then raise exception 'Generated package items are immutable.'; end if;
  if new.organization_id is distinct from old.organization_id or new.package_id is distinct from old.package_id
    or new.document_id is distinct from old.document_id or new.document_type is distinct from old.document_type
    or new.display_order is distinct from old.display_order or new.source_filename is distinct from old.source_filename
    or new.source_storage_bucket is distinct from old.source_storage_bucket or new.source_storage_path is distinct from old.source_storage_path
    or new.source_mime_type is distinct from old.source_mime_type or new.source_file_size_bytes is distinct from old.source_file_size_bytes
    or new.source_created_at is distinct from old.source_created_at or new.source_expiry_date is distinct from old.source_expiry_date
    or new.source_verified_at is distinct from old.source_verified_at or new.included_at is distinct from old.included_at then
    raise exception 'Package item source identity cannot be changed.';
  end if;
  if old.source_content_hash is not null or old.start_page is not null or old.end_page is not null then
    raise exception 'Package item finalization values can only be written once.';
  end if;
  return new;
end;
$$;

create trigger carrier_setup_package_items_immutability_guard
  before update or delete on public.carrier_setup_package_items
  for each row execute function public.guard_carrier_setup_package_item_immutability();

alter table public.carrier_setup_packages enable row level security;
alter table public.carrier_setup_package_items enable row level security;

create trigger carrier_setup_packages_set_updated_at
  before update on public.carrier_setup_packages
  for each row execute function public.set_updated_at();

create policy carrier_setup_packages_select on public.carrier_setup_packages for select using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
);
create policy carrier_setup_package_items_select on public.carrier_setup_package_items for select using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
);

create or replace function public.reserve_carrier_setup_package(
  p_application_id uuid, p_broker_id uuid, p_recipient_name text,
  p_recipient_email text, p_document_ids uuid[]
) returns table(package_id uuid, package_version integer)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_app public.carrier_onboarding_applications;
  v_carrier public.carriers;
  v_org public.organizations;
  v_broker public.brokers;
  v_id uuid := gen_random_uuid();
  v_version integer;
  v_count integer;
  v_total_bytes bigint;
  v_factoring_company_name text;
begin
  select * into v_app from public.carrier_onboarding_applications where id = p_application_id for update;
  if v_app.id is null or v_app.organization_id <> public.current_org_id() then raise exception 'Application not found in your organization.'; end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then raise exception 'You do not have permission to generate setup packages.'; end if;
  if v_app.status not in ('approved','converted') then raise exception 'Only approved or converted applications can generate setup packages.'; end if;
  if p_document_ids is null or coalesce(array_length(p_document_ids,1),0) not between 1 and 12 then raise exception 'Select between 1 and 12 documents.'; end if;
  if (select count(distinct x) from unnest(p_document_ids) x) <> array_length(p_document_ids,1) then raise exception 'A document may only be selected once.'; end if;
  if v_app.status = 'converted' then
    select * into v_carrier from public.carriers where id = v_app.converted_carrier_id and organization_id = v_app.organization_id and is_active;
    if v_carrier.id is null then raise exception 'The converted carrier must be active and belong to this organization.'; end if;
    select factoring_company_name into v_factoring_company_name
    from public.carrier_financials where carrier_id=v_carrier.id and organization_id=v_app.organization_id;
  end if;
  if p_broker_id is not null then
    select * into v_broker from public.brokers where id = p_broker_id and organization_id = v_app.organization_id;
    if v_broker.id is null then raise exception 'Broker not found in your organization.'; end if;
  end if;
  select * into v_org from public.organizations where id = v_app.organization_id;
  select count(*), coalesce(sum(d.file_size_bytes),0) into v_count, v_total_bytes
  from public.documents d where d.id = any(p_document_ids);
  if v_count <> array_length(p_document_ids,1) then raise exception 'One or more selected document IDs are invalid.'; end if;
  if v_total_bytes > 41943040 then raise exception 'Selected source documents exceed the 40 MB package limit.'; end if;
  perform pg_advisory_xact_lock(hashtext(v_app.organization_id::text), hashtext('carrier-setup-package:' || v_app.id::text));
  select coalesce(max(version),0)+1 into v_version from public.carrier_setup_packages where onboarding_application_id = v_app.id;

  insert into public.carrier_setup_packages (
    id, organization_id, onboarding_application_id, carrier_id, broker_id, version,
    recipient_name, recipient_email, prepared_for_name, carrier_snapshot,
    organization_snapshot, equipment_snapshot, document_count, generated_by
  ) values (
    v_id, v_app.organization_id, v_app.id, v_carrier.id, p_broker_id, v_version,
    nullif(btrim(p_recipient_name),''), nullif(btrim(p_recipient_email),''), v_broker.company_name,
    jsonb_strip_nulls(jsonb_build_object(
      'legal_name', coalesce(v_carrier.legal_name,v_app.legal_name), 'dba_name', coalesce(v_carrier.dba_name,v_app.dba_name),
      'mc_number', coalesce(v_carrier.mc_number,v_app.mc_number), 'dot_number', coalesce(v_carrier.dot_number,v_app.dot_number),
      'contact_name', coalesce(v_carrier.contact_name,v_app.contact_name), 'phone', coalesce(v_carrier.phone,v_app.phone),
      'email', coalesce(v_carrier.email,v_app.email),
      'address', nullif(concat_ws(', ',coalesce(v_carrier.address_line1,v_app.address_line1),coalesce(v_carrier.address_line2,v_app.address_line2),coalesce(v_carrier.city,v_app.city),coalesce(v_carrier.state,v_app.state),coalesce(v_carrier.postal_code,v_app.postal_code),coalesce(v_carrier.country,v_app.country)),'') ,
      'factoring_company_name', coalesce(v_factoring_company_name,case when v_app.has_factoring then v_app.factoring_company_name else null end),
      'compliance', (select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('document_type',d.document_type,'expiry_date',d.expiry_date,'verified_at',d.verified_at)) order by d.document_type::text),'[]'::jsonb) from public.documents d where d.id=any(p_document_ids) and d.document_type in ('insurance_certificate','motor_carrier_authority'))
    )),
    jsonb_strip_nulls(jsonb_build_object('name',v_org.name,'dba_name',v_org.dba_name,'mc_number',v_org.mc_number,'dot_number',v_org.dot_number,'phone',v_org.business_phone,'email',v_org.business_email,'address',nullif(concat_ws(', ',v_org.address_line1,v_org.address_line2,v_org.city,v_org.state,v_org.postal_code,v_org.country),''),'logo_url',v_org.logo_url)),
    case when v_app.equipment_data is null then null else jsonb_strip_nulls(jsonb_build_object(
      'equipment_type',v_app.equipment_data->'equipment_type','truck_count',v_app.equipment_data->'truck_count','trailer_count',v_app.equipment_data->'trailer_count','trailer_types',v_app.equipment_data->'trailer_types','preferred_freight',v_app.equipment_data->'preferred_freight','operating_regions',v_app.equipment_data->'operating_regions')) end,
    v_count, auth.uid()
  );

  insert into public.carrier_setup_package_items (
    organization_id, package_id, document_id, document_type, display_order,
    source_filename, source_storage_bucket, source_storage_path, source_mime_type,
    source_file_size_bytes, source_created_at, source_expiry_date, source_verified_at
  )
  select d.organization_id, v_id, d.id, d.document_type, u.ord::integer,
    d.file_name, 'carrier-onboarding-documents', d.file_path, d.mime_type,
    d.file_size_bytes, d.created_at, d.expiry_date, d.verified_at
  from unnest(p_document_ids) with ordinality u(document_id,ord)
  join public.documents d on d.id=u.document_id
  order by u.ord;
  return query select v_id,v_version;
end;
$$;

create or replace function public.finalize_carrier_setup_package(
  p_package_id uuid, p_storage_path text, p_file_size_bytes bigint,
  p_page_count integer, p_item_results jsonb
) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_package public.carrier_setup_packages; v_item jsonb; v_updated integer := 0;
begin
  select * into v_package from public.carrier_setup_packages where id=p_package_id for update;
  if v_package.id is null or v_package.status <> 'generating' then raise exception 'Generating package not found.'; end if;
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may finalize packages.'; end if;
  if p_storage_path <> format('%s/%s/%s/carrier-setup-package-v%s.pdf',v_package.organization_id,v_package.onboarding_application_id,v_package.id,v_package.version) then raise exception 'Invalid package storage path.'; end if;
  if p_file_size_bytes <= 0 or p_file_size_bytes > 52428800 then raise exception 'Generated package exceeds the 50 MB limit.'; end if;
  if p_page_count not between 1 and 250 then raise exception 'Generated package exceeds the 250-page limit.'; end if;
  if jsonb_typeof(p_item_results) <> 'array' or jsonb_array_length(p_item_results) <> v_package.document_count then raise exception 'Final item results are incomplete.'; end if;
  for v_item in select value from jsonb_array_elements(p_item_results) loop
    update public.carrier_setup_package_items set
      source_content_hash=v_item->>'source_content_hash', start_page=(v_item->>'start_page')::integer, end_page=(v_item->>'end_page')::integer
    where id=(v_item->>'item_id')::uuid and package_id=v_package.id
      and source_content_hash is null and start_page is null and end_page is null;
    v_updated := v_updated + found::integer;
  end loop;
  if v_updated <> v_package.document_count then raise exception 'Final item results do not match package items.'; end if;
  update public.carrier_setup_packages set status='generated', generated_storage_path=p_storage_path,
    generated_file_size_bytes=p_file_size_bytes,page_count=p_page_count,generated_at=now()
  where id=v_package.id;
end;
$$;

create or replace function public.fail_carrier_setup_package(p_package_id uuid,p_failure_reason text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may fail packages.'; end if;
  update public.carrier_setup_packages set status='failed',generated_storage_path=null,
    generated_file_size_bytes=null,page_count=null,failure_reason=left(coalesce(nullif(btrim(p_failure_reason),''),'Package generation failed.'),500)
  where id=p_package_id and status='generating';
  if not found then raise exception 'Generating package not found.'; end if;
end;
$$;

create or replace function public.mark_carrier_setup_package_sent(p_package_id uuid,p_email_send_log_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_org uuid; v_recipient_email text; v_recipient_name text;
begin
  select organization_id into v_org from public.carrier_setup_packages where id=p_package_id for update;
  if v_org is null or v_org<>public.current_org_id() then raise exception 'Package not found in your organization.'; end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then raise exception 'You do not have permission to send setup packages.'; end if;
  select recipient, metadata->>'recipient_name' into v_recipient_email,v_recipient_name
  from public.email_send_log where id=p_email_send_log_id and organization_id=v_org and carrier_setup_package_id=p_package_id and status='sent';
  if v_recipient_email is null then raise exception 'A successful package email log is required.'; end if;
  update public.carrier_setup_packages set status='sent',last_sent_at=now(),last_sent_by=auth.uid(),last_email_send_log_id=p_email_send_log_id,last_sent_recipient_name=v_recipient_name,last_sent_recipient_email=v_recipient_email where id=p_package_id and status in ('generated','sent');
  if not found then raise exception 'This package cannot be marked sent.'; end if;
end;
$$;

create or replace function public.void_carrier_setup_package(p_package_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.has_role(array['owner','admin']::public.org_role[]) then raise exception 'Only owners and admins may void setup packages.'; end if;
  if nullif(btrim(p_reason),'') is null then raise exception 'A void reason is required.'; end if;
  update public.carrier_setup_packages set status='voided',voided_at=now(),voided_by=auth.uid(),void_reason=left(btrim(p_reason),500)
  where id=p_package_id and organization_id=public.current_org_id() and status in ('generated','sent');
  if not found then raise exception 'Package not found or cannot be voided.'; end if;
end;
$$;

revoke execute on function public.reserve_carrier_setup_package(uuid,uuid,text,text,uuid[]) from public,anon;
revoke execute on function public.finalize_carrier_setup_package(uuid,text,bigint,integer,jsonb) from public,authenticated,anon;
revoke execute on function public.fail_carrier_setup_package(uuid,text) from public,authenticated,anon;
revoke execute on function public.mark_carrier_setup_package_sent(uuid,uuid) from public,anon;
revoke execute on function public.void_carrier_setup_package(uuid,text) from public,anon;
grant execute on function public.finalize_carrier_setup_package(uuid,text,bigint,integer,jsonb) to service_role;
grant execute on function public.fail_carrier_setup_package(uuid,text) to service_role;
grant execute on function public.reserve_carrier_setup_package(uuid,uuid,text,text,uuid[]) to authenticated;
grant execute on function public.mark_carrier_setup_package_sent(uuid,uuid) to authenticated;
grant execute on function public.void_carrier_setup_package(uuid,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('carrier-setup-packages','carrier-setup-packages',false,52428800,array['application/pdf'])
on conflict(id) do nothing;

create policy carrier_setup_packages_storage_select on storage.objects for select using (
  bucket_id='carrier-setup-packages' and (storage.foldername(name))[1]=public.current_org_id()::text
  and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
);
create policy carrier_setup_packages_storage_insert on storage.objects for insert with check (
  bucket_id='carrier-setup-packages' and (storage.foldername(name))[1]=public.current_org_id()::text
  and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
  and exists (
    select 1 from public.carrier_setup_packages p
    where p.id::text=(storage.foldername(name))[3]
      and p.organization_id=public.current_org_id()
      and p.onboarding_application_id::text=(storage.foldername(name))[2]
      and p.status='generating'
      and name=format('%s/%s/%s/carrier-setup-package-v%s.pdf',p.organization_id,p.onboarding_application_id,p.id,p.version)
  )
);

comment on table public.carrier_setup_packages is 'Immutable, versioned broker-facing carrier setup package history anchored to an onboarding application. EIN and internal financial terms are deliberately absent from snapshots.';
comment on table public.carrier_setup_package_items is 'Exact immutable source-document snapshot for a setup package, including SHA-256 content hash and final PDF page range.';
