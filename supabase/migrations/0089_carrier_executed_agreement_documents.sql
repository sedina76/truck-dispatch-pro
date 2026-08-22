-- =============================================================================
-- 0089_carrier_executed_agreement_documents.sql
-- Phase 2L.6A: immutable executed carrier-agreement PDF artifacts.
--
-- This migration is intentionally additive/hardening only. It does not create
-- PDFs, backfill historical signings, or alter existing setup packages.
-- =============================================================================

create type public.carrier_agreement_document_generation_status as enum (
  'pending', 'generating', 'generated', 'failed'
);

alter table public.carrier_agreement_signings
  add column document_generation_status public.carrier_agreement_document_generation_status not null default 'pending',
  add column document_generation_token uuid,
  add column document_generation_started_at timestamptz,
  add column document_generation_failure_reason text,
  add column executed_pdf_sha256 text;

alter table public.carrier_agreement_signings
  add constraint carrier_agreement_signings_pdf_hash_format check (
    executed_pdf_sha256 is null or executed_pdf_sha256 ~ '^[0-9a-f]{64}$'
  ),
  add constraint carrier_agreement_signings_document_generation_shape check (
    (document_generation_status = 'pending'
      and generated_document_id is null and executed_pdf_sha256 is null
      and document_generation_token is null and document_generation_started_at is null
      and document_generation_failure_reason is null)
    or (document_generation_status = 'generating'
      and generated_document_id is null and executed_pdf_sha256 is null
      and document_generation_token is not null and document_generation_started_at is not null
      and document_generation_failure_reason is null)
    or (document_generation_status = 'generated'
      and generated_document_id is not null and executed_pdf_sha256 is not null
      and document_generation_token is null and document_generation_started_at is not null
      and document_generation_failure_reason is null)
    or (document_generation_status = 'failed'
      and generated_document_id is null and executed_pdf_sha256 is null
      and document_generation_token is null and document_generation_started_at is not null
      and document_generation_failure_reason is not null)
  );

alter table public.carrier_agreement_signings
  drop constraint carrier_agreement_signings_generated_document_id_fkey,
  add constraint carrier_agreement_signings_generated_document_id_fkey
    foreign key (generated_document_id) references public.documents(id) on delete restrict;

create unique index carrier_agreement_signings_generated_document_unique_idx
  on public.carrier_agreement_signings (generated_document_id)
  where generated_document_id is not null;

create unique index documents_signed_agreement_file_path_unique_idx
  on public.documents (file_path)
  where document_type = 'signed_agreement';

create or replace function public.guard_carrier_agreement_signing_document_initial_state()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.document_generation_status <> 'pending'
    or new.document_generation_token is not null
    or new.document_generation_started_at is not null
    or new.document_generation_failure_reason is not null
    or new.generated_document_id is not null
    or new.executed_pdf_sha256 is not null then
    raise exception 'A new signing must begin with pending executed-document generation.';
  end if;
  return new;
end;
$$;

create trigger carrier_agreement_signings_document_initial_state_guard
  before insert on public.carrier_agreement_signings
  for each row execute function public.guard_carrier_agreement_signing_document_initial_state();

create or replace function public.guard_finalized_executed_agreement_document()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_document_id uuid := old.id;
begin
  if exists (
    select 1 from public.carrier_agreement_signings s
    where s.generated_document_id = v_document_id
  ) then
    if tg_op = 'DELETE' then
      raise exception 'A finalized executed agreement document cannot be deleted.';
    end if;
    if new is distinct from old then
      raise exception 'A finalized executed agreement document is immutable.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger zz_documents_finalized_executed_agreement_guard
  before update or delete on public.documents
  for each row execute function public.guard_finalized_executed_agreement_document();

create or replace function public.guard_carrier_agreement_signing_completed_immutability()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_document public.documents;
  v_template_version integer;
  v_expected_path text;
begin
  if old.status in ('completed', 'voided') and (
    new.organization_id is distinct from old.organization_id
    or new.application_id is distinct from old.application_id
    or new.agreement_template_id is distinct from old.agreement_template_id
    or new.assigned_at is distinct from old.assigned_at
    or new.assigned_by is distinct from old.assigned_by
    or new.opened_at is distinct from old.opened_at
    or new.completed_at is distinct from old.completed_at
    or new.content_hash is distinct from old.content_hash
    or new.evidence_hash is distinct from old.evidence_hash
    or new.signer_name is distinct from old.signer_name
    or new.signer_title is distinct from old.signer_title
    or new.signature_type is distinct from old.signature_type
    or new.typed_signature is distinct from old.typed_signature
    or new.consent_text_version is distinct from old.consent_text_version
    or new.consent_accepted_at is distinct from old.consent_accepted_at
    or new.signed_at is distinct from old.signed_at
    or new.ip_address is distinct from old.ip_address
    or new.user_agent is distinct from old.user_agent)
  then
    raise exception 'A completed agreement signing''s execution evidence is immutable.';
  end if;

  if old.generated_document_id is not null
    and new.generated_document_id is distinct from old.generated_document_id then
    raise exception 'A finalized executed agreement document cannot be replaced or removed.';
  end if;
  if old.executed_pdf_sha256 is not null
    and new.executed_pdf_sha256 is distinct from old.executed_pdf_sha256 then
    raise exception 'A finalized executed agreement PDF hash cannot be changed.';
  end if;

  if (new.document_generation_status, new.document_generation_token,
      new.document_generation_started_at, new.document_generation_failure_reason,
      new.generated_document_id, new.executed_pdf_sha256)
    is distinct from
     (old.document_generation_status, old.document_generation_token,
      old.document_generation_started_at, old.document_generation_failure_reason,
      old.generated_document_id, old.executed_pdf_sha256)
    and auth.role() <> 'service_role' then
    raise exception 'Only the trusted server may change executed-agreement generation state.';
  end if;

  if old.document_generation_status in ('pending', 'failed')
    and new.document_generation_status not in (old.document_generation_status, 'generating') then
    raise exception 'Invalid executed-agreement generation transition.';
  elsif old.document_generation_status = 'generating'
    and new.document_generation_status not in ('generating', 'generated', 'failed') then
    raise exception 'Invalid executed-agreement generation transition.';
  end if;
  if old.generated_document_id is null and new.generated_document_id is not null
    and not (old.document_generation_status = 'generating' and new.document_generation_status = 'generated') then
    raise exception 'An executed agreement document may only be linked during trusted finalization.';
  end if;

  if new.generated_document_id is not null then
    select * into v_document from public.documents where id = new.generated_document_id;
    select version_number into v_template_version
    from public.carrier_agreement_templates where id = new.agreement_template_id;
    v_expected_path := format('%s/%s/%s/executed-agreement-v%s.pdf',
      new.organization_id, new.application_id, new.id, v_template_version);
    if v_document.id is null
      or v_document.organization_id <> new.organization_id
      or v_document.entity_type <> 'carrier_onboarding_application'
      or v_document.entity_id <> new.application_id
      or v_document.document_type <> 'signed_agreement'
      or v_document.mime_type <> 'application/pdf'
      or not v_document.is_verified
      or v_document.verified_at is null
      or v_document.rejected_at is not null
      or v_document.verified_by is not null
      or v_document.uploaded_by is not null
      or v_document.visibility <> 'internal_only'
      or v_document.file_path is distinct from v_expected_path
    then
      raise exception 'The executed agreement document relationship is invalid.';
    end if;
  end if;

  if old.document_generation_status = 'generated'
    and new.document_generation_status <> 'generated' then
    raise exception 'Generated executed-agreement state is terminal.';
  end if;

  return new;
end;
$$;

create or replace function public.reserve_carrier_agreement_executed_document(p_signing_id uuid)
returns table (
  reservation_status public.carrier_agreement_document_generation_status,
  reservation_token uuid,
  generated_document_id uuid
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_signing public.carrier_agreement_signings;
  v_token uuid;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Only the trusted server may reserve executed agreement generation.';
  end if;

  select * into v_signing
  from public.carrier_agreement_signings
  where id = p_signing_id
  for update;

  if v_signing.id is null then raise exception 'Signing not found.'; end if;
  if v_signing.status not in ('completed', 'voided')
    or v_signing.signed_at is null or v_signing.evidence_hash is null then
    raise exception 'Only a signing with completed execution evidence can generate an executed document.';
  end if;

  if v_signing.document_generation_status = 'generated' then
    return query select 'generated'::public.carrier_agreement_document_generation_status,
      null::uuid, v_signing.generated_document_id;
    return;
  end if;

  if v_signing.document_generation_status = 'generating'
    and v_signing.document_generation_started_at > now() - interval '15 minutes' then
    return query select 'generating'::public.carrier_agreement_document_generation_status,
      null::uuid, null::uuid;
    return;
  end if;

  v_token := gen_random_uuid();
  update public.carrier_agreement_signings
  set document_generation_status = 'generating',
      document_generation_token = v_token,
      document_generation_started_at = now(),
      document_generation_failure_reason = null
  where id = v_signing.id;

  return query select 'generating'::public.carrier_agreement_document_generation_status,
    v_token, null::uuid;
end;
$$;

create or replace function public.finalize_carrier_agreement_executed_document(
  p_signing_id uuid,
  p_reservation_token uuid,
  p_storage_path text,
  p_file_name text,
  p_file_size_bytes bigint,
  p_executed_pdf_sha256 text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_signing public.carrier_agreement_signings;
  v_template_version integer;
  v_expected_path text;
  v_document_id uuid;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Only the trusted server may finalize executed agreements.';
  end if;
  if p_file_size_bytes <= 0 or p_file_size_bytes > 10485760 then
    raise exception 'Executed agreement PDF size is invalid.';
  end if;
  if p_executed_pdf_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'Executed agreement PDF hash is invalid.';
  end if;

  select * into v_signing from public.carrier_agreement_signings
  where id = p_signing_id for update;
  if v_signing.id is null then raise exception 'Signing not found.'; end if;
  if v_signing.document_generation_status = 'generated' then return v_signing.generated_document_id; end if;
  if v_signing.document_generation_status <> 'generating'
    or v_signing.document_generation_token is distinct from p_reservation_token then
    raise exception 'Executed agreement generation reservation is invalid or stale.';
  end if;

  select version_number into v_template_version
  from public.carrier_agreement_templates where id = v_signing.agreement_template_id;
  v_expected_path := format('%s/%s/%s/executed-agreement-v%s.pdf',
    v_signing.organization_id, v_signing.application_id, v_signing.id, v_template_version);
  if p_storage_path is distinct from v_expected_path then
    raise exception 'Executed agreement storage path is invalid.';
  end if;

  select id into v_document_id from public.documents
  where file_path = p_storage_path and document_type = 'signed_agreement';
  if v_document_id is null then
    insert into public.documents (
      organization_id, entity_type, entity_id, document_type, file_name,
      file_path, file_size_bytes, mime_type, is_verified, verified_at,
      verified_by, uploaded_by, visibility, notes
    ) values (
      v_signing.organization_id, 'carrier_onboarding_application', v_signing.application_id,
      'signed_agreement', p_file_name, p_storage_path, p_file_size_bytes,
      'application/pdf', true, now(), null, null, 'internal_only',
      format('System-generated executed agreement for signing %s.', v_signing.id)
    ) returning id into v_document_id;
  else
    if not exists (
      select 1 from public.documents d
      where d.id = v_document_id
        and d.organization_id = v_signing.organization_id
        and d.entity_type = 'carrier_onboarding_application'
        and d.entity_id = v_signing.application_id
        and d.document_type = 'signed_agreement'
        and d.file_name = p_file_name
        and d.file_size_bytes = p_file_size_bytes
        and d.mime_type = 'application/pdf'
        and d.is_verified and d.verified_at is not null and d.rejected_at is null
        and d.verified_by is null and d.uploaded_by is null
        and d.visibility = 'internal_only'
    ) then
      raise exception 'Existing executed agreement document metadata does not match this signing.';
    end if;
  end if;

  update public.carrier_agreement_signings
  set generated_document_id = v_document_id,
      executed_pdf_sha256 = p_executed_pdf_sha256,
      document_generation_status = 'generated',
      document_generation_token = null,
      document_generation_failure_reason = null
  where id = v_signing.id;

  return v_document_id;
end;
$$;

create or replace function public.fail_carrier_agreement_executed_document(
  p_signing_id uuid, p_reservation_token uuid, p_failure_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Only the trusted server may fail executed agreement generation.';
  end if;
  update public.carrier_agreement_signings
  set document_generation_status = 'failed',
      document_generation_token = null,
      document_generation_failure_reason = left(coalesce(nullif(btrim(p_failure_reason), ''), 'Executed agreement generation failed.'), 500)
  where id = p_signing_id
    and document_generation_status = 'generating'
    and document_generation_token = p_reservation_token
    and generated_document_id is null;
  if not found then raise exception 'Active executed agreement generation reservation not found.'; end if;
end;
$$;

revoke execute on function public.reserve_carrier_agreement_executed_document(uuid) from public, authenticated, anon;
revoke execute on function public.finalize_carrier_agreement_executed_document(uuid,uuid,text,text,bigint,text) from public, authenticated, anon;
revoke execute on function public.fail_carrier_agreement_executed_document(uuid,uuid,text) from public, authenticated, anon;
grant execute on function public.reserve_carrier_agreement_executed_document(uuid) to service_role;
grant execute on function public.finalize_carrier_agreement_executed_document(uuid,uuid,text,text,bigint,text) to service_role;
grant execute on function public.fail_carrier_agreement_executed_document(uuid,uuid,text) to service_role;

-- Signed agreements are the sole exception to the ordinary latest-document-
-- per-type rule: multiple immutable agreement families/versions may coexist.
create or replace function public.guard_carrier_setup_package_item()
returns trigger language plpgsql set search_path = public as $$
declare
  v_package public.carrier_setup_packages;
  v_document public.documents;
  v_latest_id uuid;
begin
  select * into v_package from public.carrier_setup_packages where id = new.package_id;
  select * into v_document from public.documents where id = new.document_id;
  if v_package.id is null or v_package.organization_id <> new.organization_id then raise exception 'Package item must belong to its package organization.'; end if;
  if v_package.status <> 'generating' then raise exception 'Items may only be added while a package is generating.'; end if;
  if v_document.id is null or v_document.organization_id <> new.organization_id
    or v_document.entity_type <> 'carrier_onboarding_application'
    or v_document.entity_id <> v_package.onboarding_application_id then
    raise exception 'Selected document does not belong to this onboarding application.';
  end if;

  if v_document.document_type = 'signed_agreement' then
    if not exists (
      select 1 from public.carrier_agreement_signings s
      where s.organization_id = new.organization_id
        and s.application_id = v_package.onboarding_application_id
        and s.status = 'completed'
        and s.document_generation_status = 'generated'
        and s.generated_document_id = v_document.id
        and s.executed_pdf_sha256 ~ '^[0-9a-f]{64}$'
    ) then
      raise exception 'Selected signed agreement is not an eligible completed executed artifact.';
    end if;
  else
    select id into v_latest_id from public.documents
    where organization_id = new.organization_id
      and entity_type = 'carrier_onboarding_application'
      and entity_id = v_package.onboarding_application_id
      and document_type = v_document.document_type
    order by created_at desc, id desc limit 1;
    if v_latest_id is distinct from v_document.id then raise exception 'Only the latest document of each type may be included.'; end if;
  end if;

  if not v_document.is_verified or v_document.verified_at is null or v_document.rejected_at is not null then raise exception 'Selected documents must be verified and not rejected.'; end if;
  if v_document.expiry_date is not null and v_document.expiry_date < current_date then raise exception 'Expired documents cannot be included in a setup package.'; end if;
  if coalesce(v_document.mime_type,'') not in ('application/pdf', 'image/jpeg', 'image/png') then raise exception 'Only PDF, JPEG, and PNG documents may be included.'; end if;
  if v_document.file_size_bytes is null or v_document.file_size_bytes <= 0 or v_document.file_size_bytes > 10485760 then raise exception 'Each source document must have a known size of 10 MB or less.'; end if;
  if v_document.document_type not in (
    'w9','insurance_certificate','motor_carrier_authority','notice_of_assignment',
    'factoring_notice','voided_check','vehicle_registration','ifta_credential',
    'inspection_report','signed_agreement','other'
  ) then raise exception 'This document type is not approved for broker setup packages.'; end if;
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

comment on column public.carrier_agreement_signings.executed_pdf_sha256 is
  'Immutable lowercase SHA-256 of the exact finalized executed-agreement PDF bytes; distinct from agreement content_hash and signing evidence_hash.';

-- =============================================================================
-- READ-ONLY PRE-APPLY PREFLIGHT. Run separately before applying 0089.
-- Every query should return zero rows.
-- =============================================================================

-- Completed/voided evidence rows with an invalid generated document link.
-- select s.id, s.status, s.generated_document_id
-- from public.carrier_agreement_signings s
-- left join public.documents d on d.id = s.generated_document_id
-- where s.generated_document_id is not null and (
--   d.id is null or d.organization_id <> s.organization_id
--   or d.entity_type <> 'carrier_onboarding_application'
--   or d.entity_id <> s.application_id or d.document_type <> 'signed_agreement'
--   or d.mime_type <> 'application/pdf'
--   or not d.is_verified or d.verified_at is null or d.rejected_at is not null
--   or d.verified_by is not null or d.uploaded_by is not null
--   or d.visibility <> 'internal_only'
-- );

-- One generated document referenced by multiple signings.
-- select generated_document_id, count(*) from public.carrier_agreement_signings
-- where generated_document_id is not null group by generated_document_id having count(*) > 1;

-- Completed signing/template content-hash mismatches.
-- select s.id, s.content_hash, t.content_hash
-- from public.carrier_agreement_signings s
-- join public.carrier_agreement_templates t on t.id = s.agreement_template_id
-- where s.status in ('completed','voided') and s.signed_at is not null
--   and (s.content_hash is distinct from t.content_hash
--     or s.content_hash is distinct from public.compute_carrier_agreement_content_hash(t.id));

-- Completed evidence missing a required initial.
-- select s.id as signing_id, c.id as clause_id
-- from public.carrier_agreement_signings s
-- join public.carrier_agreement_clauses c on c.agreement_template_id = s.agreement_template_id and c.requires_initials
-- left join public.carrier_agreement_initials i on i.signing_instance_id = s.id and i.clause_id = c.id
-- where s.status in ('completed','voided') and s.signed_at is not null and i.id is null;

-- Completed evidence with missing/malformed evidence hashes.
-- select id, evidence_hash from public.carrier_agreement_signings
-- where status in ('completed','voided') and signed_at is not null
--   and (evidence_hash is null or evidence_hash !~ '^[0-9a-f]{64}$');

-- Signed-agreement path collisions.
-- select file_path, count(*) from public.documents where document_type = 'signed_agreement'
-- group by file_path having count(*) > 1;
