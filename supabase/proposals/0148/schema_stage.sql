-- NOT APPROVED FOR PRODUCTION. Disposable synthetic model only.
create type public.carrier_factoring_mode as enum ('unconfigured', 'direct', 'factored');

alter table public.carriers
  add column factoring_mode public.carrier_factoring_mode not null default 'unconfigured';

comment on column public.carriers.factoring_mode is
  'AR-side factoring policy for THIS carrier''s invoices (Phase 3B.1, item 3; Phase 3B.1.1, item 1). Three states: ''unconfigured'' (default for every existing/new carrier -- blocks invoice issuance outright, a later phase, until explicitly set) / ''direct'' (paid under carrier remittance instructions) / ''factored'' (invoice issuance requires a complete, ready -- see public.classify_carrier_factoring_readiness() -- default factoring_relationships row for this carrier). Changed ONLY via public.set_carrier_factoring_policy() (owner/admin, reason + audit event required, 0139+) -- never a direct UPDATE (see the column-privilege lockdown, 0138/0139). Distinct from carriers.factoring_company_name (0003/0033/0070), which is the UNRELATED AP-side hint for who a carrier''s OWN factor is when THIS ORGANIZATION pays that carrier a settlement.';

create type public.factoring_submission_method as enum (
  'secure_email', 'api', 'portal_manual', 'internal_queue'
);

alter type public.integration_provider add value if not exists 'factoring_api';

alter table public.factoring_relationships
  add column carrier_id uuid references public.carriers (id) on delete restrict,

  add column remittance_instructions text,
  add column remittance_reference text,

  add column noa_template_text text,
  add column noa_document_id uuid references public.documents (id) on delete set null,
  add column noa_reference text,
  add column noa_effective_date date,
  add column noa_approved boolean not null default false,
  add column noa_approved_by uuid references public.profiles (id) on delete set null,
  add column noa_approved_at timestamptz,

  add column submission_method public.factoring_submission_method,
  add column submission_destination_email text,
  add column submission_integration_id uuid references public.integration_settings (id) on delete restrict,
  add column submission_notes text;

comment on column public.factoring_relationships.carrier_id is
  'The carrier this relationship applies to (Phase 3B.1). Null only for a not-yet-backfilled or genuinely unresolved legacy row -- see unresolved_carrier_records (record_type=''factoring_relationship'') and 0137''s backfill report. A relationship with carrier_id null can never be a carrier''s default (see 0138''s carrier-scoped partial unique index).';
comment on column public.factoring_relationships.noa_approved is
  'True only once an owner/admin has approved this relationship''s Notice of Assignment language/document (see guard_factoring_relationship_protected_fields() below and approve_factoring_relationship_noa(), 0138). Accountants may view and maintain operational billing fields on this row but cannot set this true.';
comment on column public.factoring_relationships.submission_integration_id is
  'When submission_method=''api'', must reference an ENABLED integration_settings row (provider=''factoring_api'') in the same organization -- validated by guard_factoring_relationship_org() below. The integration''s own credentials/secrets live in integration_settings per 0008''s existing vault-reference convention, never here.';

alter table public.factoring_relationships
  add constraint factoring_relationships_noa_approval_complete check (
    not noa_approved or (
      (noa_template_text is not null or noa_document_id is not null)
      and noa_approved_by is not null
      and noa_approved_at is not null
      and noa_effective_date is not null
    )
  ),
  add constraint factoring_relationships_submission_email_present check (
    submission_method is distinct from 'secure_email'::public.factoring_submission_method
    or (submission_destination_email is not null and submission_destination_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
  ),
  add constraint factoring_relationships_submission_integration_present check (
    submission_method is distinct from 'api'::public.factoring_submission_method
    or submission_integration_id is not null
  );

create or replace function public.guard_factoring_relationship_org()
returns trigger
language plpgsql
as $$
declare
  v_company_org uuid;
  v_carrier_org uuid;
  v_document_org uuid;
  v_integration_org uuid;
  v_integration_enabled boolean;
  v_integration_provider public.integration_provider;
begin
  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'Factoring relationship must reference a factoring company in the same organization.';
  end if;

  if new.carrier_id is not null then
    select organization_id into v_carrier_org from public.carriers where id = new.carrier_id;
    if v_carrier_org is null or v_carrier_org <> new.organization_id then
      raise exception 'Factoring relationship must reference a carrier in the same organization.';
    end if;
  end if;

  if new.noa_document_id is not null then
    select organization_id into v_document_org from public.documents where id = new.noa_document_id;
    if v_document_org is null or v_document_org <> new.organization_id then
      raise exception 'Factoring relationship''s Notice of Assignment document must belong to the same organization.';
    end if;
  end if;

  if new.submission_integration_id is not null then
    select organization_id, is_enabled, provider
      into v_integration_org, v_integration_enabled, v_integration_provider
    from public.integration_settings where id = new.submission_integration_id;
    if v_integration_org is null or v_integration_org <> new.organization_id then
      raise exception 'Factoring relationship''s submission integration must belong to the same organization.';
    end if;
    if v_integration_provider is distinct from 'factoring_api'::public.integration_provider then
      raise exception 'Factoring relationship''s submission integration must be a factoring_api integration.';
    end if;
    if not coalesce(v_integration_enabled, false) then
      raise exception 'Factoring relationship''s submission integration is not enabled.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists factoring_relationships_guard_org on public.factoring_relationships;
create trigger factoring_relationships_guard_org
  before insert or update on public.factoring_relationships
  for each row execute function public.guard_factoring_relationship_org();

create or replace function public.guard_factoring_relationship_protected_fields()
returns trigger
language plpgsql
as $$
declare
  v_uid uuid := auth.uid();
  v_is_default_touched boolean;
  v_noa_touched boolean;
  v_remittance_touched boolean;
begin
  if v_uid is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_is_default_touched := coalesce(new.is_default, false);
    v_noa_touched :=
      new.noa_template_text is not null or new.noa_document_id is not null
      or new.noa_reference is not null or new.noa_effective_date is not null
      or coalesce(new.noa_approved, false) or new.noa_approved_by is not null or new.noa_approved_at is not null;
    v_remittance_touched := new.remittance_instructions is not null or new.remittance_reference is not null;
  else
    v_is_default_touched := new.is_default is distinct from old.is_default and new.is_default;
    v_noa_touched :=
      new.noa_template_text is distinct from old.noa_template_text
      or new.noa_document_id is distinct from old.noa_document_id
      or new.noa_reference is distinct from old.noa_reference
      or new.noa_effective_date is distinct from old.noa_effective_date
      or new.noa_approved is distinct from old.noa_approved
      or new.noa_approved_by is distinct from old.noa_approved_by
      or new.noa_approved_at is distinct from old.noa_approved_at;
    v_remittance_touched :=
      new.remittance_instructions is distinct from old.remittance_instructions
      or new.remittance_reference is distinct from old.remittance_reference;
  end if;

  if (v_is_default_touched or v_noa_touched or v_remittance_touched)
     and not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'guard_factoring_relationship_protected_fields: only an owner or admin may set the default factor or alter remittance/Notice of Assignment configuration.' using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists factoring_relationships_guard_protected_fields on public.factoring_relationships;
create trigger factoring_relationships_guard_protected_fields
  before insert or update on public.factoring_relationships
  for each row execute function public.guard_factoring_relationship_protected_fields();


create or replace function public.classify_carrier_factoring_readiness(
  p_carrier_id uuid,
  p_broker_id uuid default null,
  p_customer_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_carrier record;
  v_party record;
  v_default_count int;
  v_default record;
  v_company_active boolean;
  v_missing text[] := '{}'::text[];
begin
  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'classification', 'error', 'message', 'No organization on this account.');
  end if;
  if not public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]) then
    return jsonb_build_object('success', false, 'classification', 'error', 'message', 'You do not have permission to view factoring configuration.');
  end if;

  select id, organization_id, factoring_mode into v_carrier
  from public.carriers where id = p_carrier_id;
  if v_carrier.id is null or v_carrier.organization_id <> v_org then
    return jsonb_build_object('success', false, 'classification', 'error', 'message', 'Carrier not found.');
  end if;

  if p_broker_id is not null then
    select status, factoring_eligible into v_party
    from public.carrier_brokers where carrier_id = p_carrier_id and broker_id = p_broker_id;
    if v_party.status is null or v_party.status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_inactive', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id);
    end if;
    if not v_party.factoring_eligible then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_ineligible', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id, 'message', 'This broker relationship is not factoring-eligible -- billed directly regardless of the carrier''s own factoring mode.');
    end if;
  end if;
  if p_customer_id is not null then
    select status, factoring_eligible into v_party
    from public.carrier_customers where carrier_id = p_carrier_id and customer_id = p_customer_id;
    if v_party.status is null or v_party.status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_inactive', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id);
    end if;
    if not v_party.factoring_eligible then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_ineligible', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id, 'message', 'This customer relationship is not factoring-eligible -- billed directly regardless of the carrier''s own factoring mode.');
    end if;
  end if;

  if v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', true, 'classification', 'factoring_policy_unconfigured', 'carrier_id', p_carrier_id);
  end if;

  if v_carrier.factoring_mode = 'direct' then
    return jsonb_build_object('success', true, 'classification', 'direct_billing', 'carrier_id', p_carrier_id);
  end if;

  select count(*) into v_default_count
  from public.factoring_relationships
  where carrier_id = p_carrier_id and is_default and is_active;

  if v_default_count > 1 then
    return jsonb_build_object('success', true, 'classification', 'multiple_defaults', 'carrier_id', p_carrier_id, 'default_count', v_default_count);
  end if;

  if not exists (select 1 from public.factoring_relationships where carrier_id = p_carrier_id) then
    return jsonb_build_object('success', true, 'classification', 'no_factoring_configuration', 'carrier_id', p_carrier_id);
  end if;

  select id, factoring_company_id, is_active, effective_from, effective_to,
         remittance_instructions, noa_approved, submission_method
    into v_default
  from public.factoring_relationships
  where carrier_id = p_carrier_id and is_default
  order by is_active desc, effective_from desc
  limit 1;

  if v_default.id is null then
    return jsonb_build_object('success', true, 'classification', 'no_default', 'carrier_id', p_carrier_id);
  end if;

  if not v_default.is_active then
    return jsonb_build_object('success', true, 'classification', 'default_inactive', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
  end if;

  select is_active into v_company_active from public.factoring_companies where id = v_default.factoring_company_id;
  if not coalesce(v_company_active, false) then
    return jsonb_build_object('success', true, 'classification', 'factoring_company_inactive', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
  end if;

  if v_default.effective_from is not null and v_default.effective_from > current_date then
    return jsonb_build_object('success', true, 'classification', 'default_not_yet_effective', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'effective_from', v_default.effective_from);
  end if;
  if v_default.effective_to is not null and v_default.effective_to < current_date then
    return jsonb_build_object('success', true, 'classification', 'default_expired', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'effective_to', v_default.effective_to);
  end if;

  if v_default.remittance_instructions is null or btrim(v_default.remittance_instructions) = '' then
    v_missing := array_append(v_missing, 'remittance_instructions');
  end if;
  if not v_default.noa_approved then
    v_missing := array_append(v_missing, 'noa_approved');
  end if;
  if v_default.submission_method is null then
    v_missing := array_append(v_missing, 'submission_method');
  end if;

  if array_length(v_missing, 1) > 0 then
    return jsonb_build_object('success', true, 'classification', 'relationship_incomplete', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'missing', to_jsonb(v_missing));
  end if;

  return jsonb_build_object('success', true, 'classification', 'ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
end;
$fn$;

revoke all on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) from public;
grant execute on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) to authenticated;

comment on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) is
  'Phase 3B.1 read-only carrier-factor classifier and preview RPC (items 5, 11; Phase 3B.1.1 item 1 adds factoring_policy_unconfigured -- see 0139 for the further per-carrier-integration-aware corrections, item 7, which create-or-replaces this same function and its comment again). Never creates an invoice, submission, package, payment, or financial event. Classifications: factoring_policy_unconfigured, direct_billing, no_factoring_configuration, no_default, default_inactive, default_expired, default_not_yet_effective, factoring_company_inactive, relationship_incomplete, multiple_defaults, carrier_party_inactive, carrier_party_ineligible, ready, error. Callable by owner/admin/dispatcher/accountant; never driver/viewer.';
CREATE UNIQUE INDEX factoring_relationships_one_default_per_carrier ON public.factoring_relationships(carrier_id) WHERE is_default AND is_active AND carrier_id IS NOT NULL;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.activity_logs FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.brokers FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.carriers FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.customers FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.dispatches FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.documents FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.drivers FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factored_invoices FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_companies FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_events FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_relationships FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.integration_settings FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.invoice_line_items FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.invoices FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.load_stops FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.loads FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.organizations FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.payments FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.profiles FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.settlement_line_items FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.settlements FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.trailers FROM anon;
REVOKE DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.trucks FROM anon;
