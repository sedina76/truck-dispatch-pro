-- =============================================================================
-- 0085_carrier_signing_workflow_repairs.sql
-- Phase 2L.4C: narrow post-0084 carrier signing workflow repairs.
--
-- 1. Make the database own the signing's immutable template-content-hash
--    snapshot at assignment time. New assignments must reference a properly
--    published template; existing/historical signing rows are not changed.
-- 2. Preserve 0082's assigned -> in_progress -> completed status graph while
--    allowing complete_carrier_agreement_signing() to finish a newly assigned
--    signing atomically. No invitation, document, template-version,
--    conversion, or other onboarding behavior is changed here.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- PART 1 -- authoritative template/hash snapshot for NEW signings only.
-- Caller-supplied content_hash is deliberately ignored and replaced with the
-- immutable published template's stored value, preventing stale or forged
-- snapshots from any present or future assignment path.
-- ---------------------------------------------------------------------------

create or replace function public.set_carrier_agreement_signing_content_hash()
returns trigger
language plpgsql
as $$
declare
  v_template_status public.carrier_agreement_template_status;
  v_template_content_hash text;
begin
  select status, content_hash
    into v_template_status, v_template_content_hash
  from public.carrier_agreement_templates
  where id = new.agreement_template_id;

  if not found then
    raise exception 'Agreement template not found.';
  end if;

  if v_template_status <> 'published' then
    raise exception 'Only a published agreement template can be assigned.';
  end if;

  if v_template_content_hash is null or btrim(v_template_content_hash) = '' then
    raise exception 'This agreement template has not been published correctly and cannot be assigned.';
  end if;

  new.content_hash := v_template_content_hash;
  return new;
end;
$$;

drop trigger if exists carrier_agreement_signings_content_hash_snapshot on public.carrier_agreement_signings;
create trigger carrier_agreement_signings_content_hash_snapshot
  before insert on public.carrier_agreement_signings
  for each row execute function public.set_carrier_agreement_signing_content_hash();

-- ---------------------------------------------------------------------------
-- PART 2 -- completion RPC repair. Row lock remains the first operation.
-- An assigned signing is advanced to in_progress inside this same transaction
-- before validation and final completion, preserving 0082's status graph. Any
-- later exception rolls the intermediate transition back with all other work.
-- ---------------------------------------------------------------------------

create or replace function public.complete_carrier_agreement_signing(
  p_signing_id uuid,
  p_signer_name text,
  p_signer_title text,
  p_typed_signature text,
  p_consent_text_version text,
  p_ip_address text,
  p_user_agent text
)
returns table (
  signing_id uuid,
  status public.carrier_agreement_signing_status,
  signed_at timestamptz,
  evidence_hash text,
  already_completed boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_signing public.carrier_agreement_signings;
  v_application_org uuid;
  v_template_org uuid;
  v_requires_title boolean;
  v_template_content_hash text;
  v_computed_content_hash text;
  v_missing_initials integer;
  v_evidence_hash text;
  v_now timestamptz := now();
begin
  -- Lock first. Concurrent calls for the same signing serialize here.
  select * into v_signing
  from public.carrier_agreement_signings
  where id = p_signing_id
  for update;

  if v_signing.id is null then
    raise exception 'Signing not found.';
  end if;

  -- Safe retry: return the original evidence without another mutation/event.
  if v_signing.status = 'completed' then
    return query
      select v_signing.id, v_signing.status, v_signing.signed_at,
        v_signing.evidence_hash, true;
    return;
  end if;

  if v_signing.status = 'voided' then
    raise exception 'This agreement is voided and cannot be completed.';
  end if;

  if v_signing.status not in ('assigned', 'in_progress') then
    raise exception 'This agreement is not ready to be completed (status=%).', v_signing.status;
  end if;

  -- Preserve the 0082 graph. This update and every validation/write below are
  -- one transaction, so a later exception also rolls this transition back.
  if v_signing.status = 'assigned' then
    update public.carrier_agreement_signings
    set status = 'in_progress'
    where id = v_signing.id;
    v_signing.status := 'in_progress';
  end if;

  -- Reconfirm the signing/application/template relationship even though FKs
  -- and 0082's insert guard also protect it.
  select organization_id into v_application_org
  from public.carrier_onboarding_applications
  where id = v_signing.application_id;

  select organization_id, requires_signer_title, content_hash
    into v_template_org, v_requires_title, v_template_content_hash
  from public.carrier_agreement_templates
  where id = v_signing.agreement_template_id;

  if v_application_org is null or v_application_org <> v_signing.organization_id
    or v_template_org is null or v_template_org <> v_signing.organization_id
  then
    raise exception 'Agreement signing application/template relationship is invalid.';
  end if;

  -- Retirement is intentionally irrelevant here. The exact assigned template
  -- row remains immutable, and its live deterministic hash must still match
  -- both its stored published hash and the signing's assignment snapshot.
  v_computed_content_hash := public.compute_carrier_agreement_content_hash(v_signing.agreement_template_id);
  if v_signing.content_hash is null or btrim(v_signing.content_hash) = ''
    or v_template_content_hash is null or btrim(v_template_content_hash) = ''
    or v_signing.content_hash is distinct from v_template_content_hash
    or v_signing.content_hash is distinct from v_computed_content_hash
  then
    raise exception 'This agreement''s content does not match its assignment snapshot -- it cannot be completed. Contact the office.';
  end if;

  select count(*) into v_missing_initials
  from public.carrier_agreement_clauses c
  where c.agreement_template_id = v_signing.agreement_template_id
    and c.requires_initials
    and not exists (
      select 1
      from public.carrier_agreement_initials i
      where i.signing_instance_id = v_signing.id
        and i.clause_id = c.id
    );

  if v_missing_initials > 0 then
    raise exception 'All clauses requiring initials must be initialed before signing (% remaining).', v_missing_initials;
  end if;

  if p_signer_name is null or btrim(p_signer_name) = '' then
    raise exception 'Full legal name is required.';
  end if;
  if v_requires_title and (p_signer_title is null or btrim(p_signer_title) = '') then
    raise exception 'Signer title is required for this agreement.';
  end if;
  if p_typed_signature is null or btrim(p_typed_signature) = '' then
    raise exception 'Typed signature is required.';
  end if;
  if p_consent_text_version is null or btrim(p_consent_text_version) = '' then
    raise exception 'Electronic records/signature consent must be accepted.';
  end if;

  v_evidence_hash := encode(digest(concat_ws('|',
    v_signing.id::text,
    v_signing.content_hash,
    p_signer_name,
    coalesce(p_signer_title, ''),
    p_typed_signature,
    p_consent_text_version,
    v_now::text
  ), 'sha256'), 'hex');

  update public.carrier_agreement_signings
  set signer_name = p_signer_name,
    signer_title = p_signer_title,
    signature_type = 'typed',
    typed_signature = p_typed_signature,
    consent_text_version = p_consent_text_version,
    consent_accepted_at = v_now,
    ip_address = p_ip_address,
    user_agent = p_user_agent,
    evidence_hash = v_evidence_hash,
    signed_at = v_now,
    completed_at = v_now,
    status = 'completed'
  where id = v_signing.id;

  insert into public.carrier_agreement_audit_events
    (organization_id, signing_instance_id, event_type, actor_type,
      occurred_at, ip_address, user_agent)
  values
    (v_signing.organization_id, v_signing.id, 'agreement_completed',
      'carrier_signer', v_now, p_ip_address, p_user_agent);

  return query
    select v_signing.id,
      'completed'::public.carrier_agreement_signing_status,
      v_now, v_evidence_hash, false;
end;
$$;

comment on function public.complete_carrier_agreement_signing(uuid, text, text, text, text, text, text) is
  'Atomic carrier agreement completion boundary. Locks first; returns completed retries idempotently; advances assigned to in_progress inside the transaction to preserve the 0082 status graph; verifies application/template organization, deterministic content hash, required initials, signer inputs, and consent; then writes evidence and exactly one completion event. Any failure rolls back every mutation. EXECUTE restricted to service_role only.';

revoke execute on function public.complete_carrier_agreement_signing(uuid, text, text, text, text, text, text) from public;
revoke execute on function public.complete_carrier_agreement_signing(uuid, text, text, text, text, text, text) from authenticated, anon;
grant execute on function public.complete_carrier_agreement_signing(uuid, text, text, text, text, text, text) to service_role;

