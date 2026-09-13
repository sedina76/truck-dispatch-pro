-- ============================================================================
-- TEST_SUPPORT_0136_0138_factoring_schema.sql -- disposable database only.
--
-- Faithfully reproduces exactly the PRE-0136 factoring schema (0071, 0072)
-- plus the two small pieces of dependency scaffolding 0136 references that
-- TEST_SUPPORT_0130_0133_schema.sql has no reason to already provide
-- (documents, integration_settings/integration_provider) -- NOT the
-- carrier-context objects (unresolved_carrier_records, carrier_brokers,
-- carrier_customers, etc.), which are created by the REAL 0130/0131
-- migrations when `\i`'d in the normal chain, and must NOT be duplicated
-- here.
--
-- Load order in a TEST_0136/0137/0138 file:
--   \i TEST_SUPPORT_0130_0133_schema.sql
--   \i TEST_SUPPORT_0136_0138_factoring_schema.sql
--   \i migrations/0130_carrier_context_foundation.sql
--   \i migrations/0131_carrier_party_relationships.sql
--   \i migrations/0132_load_carrier_and_trailer_scope.sql
--   \i migrations/0133_deterministic_carrier_backfill.sql
--   \i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
--   \i migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql
--   \i migrations/0136_carrier_factoring_policy_and_relationship_columns.sql
--   \i migrations/0137_deterministic_factoring_carrier_backfill.sql
--   \i migrations/0138_carrier_default_cutover_classifier_and_secured_rpcs.sql
-- ============================================================================

-- Real Supabase projects grant authenticated/anon USAGE on schema auth +
-- EXECUTE on auth.uid() out of the box (part of the platform's standard
-- bootstrap) -- TEST_SUPPORT_0130_0133_schema.sql's synthetic auth.uid()
-- stub never needed this before now because every existing invoker-mode
-- guard trigger only did table lookups, never called auth.* directly.
-- 0136's guard_factoring_relationship_protected_fields() is the first to
-- call auth.uid() from a plain (non-SECURITY-DEFINER) trigger, so the
-- disposable harness needs the same grant a real project already has.
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;

-- --- 0005: documents (minimal -- only what 0136's noa_document_id FK, its
-- org-consistency guard, and 0139's approve_factoring_relationship_noa()
-- carrier-ownership/document-type/is_verified validation need) ------------
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  document_type public.document_type not null,
  file_name text not null,
  file_path text not null,
  is_verified boolean not null default false,
  verified_by uuid references public.profiles (id) on delete set null,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

-- --- 0008: integration_settings + integration_provider (minimal) ----------
create type public.integration_provider as enum (
  'dat','truckstop','loadboard_123','quickbooks','stripe','twilio',
  'sendgrid','motive','samsara','rmis','highway','carrier411');

create table public.integration_settings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  provider public.integration_provider not null,
  is_enabled boolean not null default false,
  credentials jsonb not null default '{}'::jsonb,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, provider));

-- --- 0071: factoring_companies / factoring_relationships / factored_
-- invoices / factoring_events (faithful pre-0136 reproduction) ------------
create type public.factored_invoice_status as enum (
  'draft','submitted','pending','approved','rejected','cancelled',
  'funded','partially_settled','disputed','recourse','chargeback','closed');

-- Phase 3B.3C (0144): legal_name added -- issue_carrier_invoice()'s
-- snapshot reads the real 0071 legal_name column (falling back to name
-- when absent); nullable, so existing fixtures that never mention it are
-- unaffected.
create table public.factoring_companies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  name text not null,
  legal_name text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create trigger set_updated_at before update on public.factoring_companies
  for each row execute function public.set_updated_at();

create table public.factoring_relationships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  factoring_company_id uuid not null references public.factoring_companies (id) on delete restrict,
  relationship_name text,
  default_advance_percentage numeric(5,2) not null check (default_advance_percentage >= 0 and default_advance_percentage <= 100),
  default_factoring_fee_percentage numeric(5,2) not null check (default_factoring_fee_percentage >= 0 and default_factoring_fee_percentage <= 100),
  default_reserve_percentage numeric(5,2) not null check (default_reserve_percentage >= 0 and default_reserve_percentage <= 100),
  fee_timing text not null check (fee_timing in ('deducted_at_funding','deducted_from_reserve')),
  recourse_type text not null check (recourse_type in ('recourse','non_recourse')),
  payment_terms_days integer,
  minimum_fee numeric(10,2), wire_fee numeric(10,2), ach_fee numeric(10,2), other_fee_default numeric(10,2),
  is_default boolean not null default false,
  is_active boolean not null default true,
  effective_from date not null default current_date,
  effective_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint factoring_relationships_valid_effective_range check (effective_to is null or effective_from is null or effective_to >= effective_from),
  constraint factoring_relationships_default_must_be_active check (not is_default or is_active)
);

create unique index factoring_relationships_one_default_per_org
  on public.factoring_relationships (organization_id)
  where is_default and is_active;

create trigger set_updated_at before update on public.factoring_relationships
  for each row execute function public.set_updated_at();

-- Phase 3B.1.4: the real 0071 RLS enablement + policies were missing from
-- this stub entirely (harmless before now -- no prior TEST_0136-0139 file
-- exercised factoring_companies/factoring_relationships direct-write
-- authorization) -- TEST_0140 is the first to need it, since 0140 itself
-- rewrites these exact policies. Faithfully reproduced from 0071, byte-
-- for-byte, so 0140's `drop policy ...; create policy ...` has real,
-- correct "before" objects to replace, and so a dispatcher/accountant
-- session in the disposable harness is genuinely RLS-gated exactly as in
-- production, not accidentally unrestricted because RLS was never turned
-- on here.
alter table public.factoring_companies enable row level security;
create policy factoring_companies_select on public.factoring_companies
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_companies_insert on public.factoring_companies
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_companies_update on public.factoring_companies
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy factoring_companies_delete on public.factoring_companies
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));

alter table public.factoring_relationships enable row level security;
create policy factoring_relationships_select on public.factoring_relationships
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_relationships_insert on public.factoring_relationships
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_relationships_update on public.factoring_relationships
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy factoring_relationships_delete on public.factoring_relationships
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));

create or replace function public.guard_factoring_relationship_org()
returns trigger language plpgsql as $$
declare v_company_org uuid;
begin
  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'Factoring relationship must reference a factoring company in the same organization.';
  end if;
  return new;
end;
$$;

create trigger factoring_relationships_guard_org
  before insert on public.factoring_relationships
  for each row execute function public.guard_factoring_relationship_org();

create table public.factored_invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  factoring_company_id uuid not null references public.factoring_companies (id) on delete restrict,
  factoring_relationship_id uuid not null references public.factoring_relationships (id) on delete restrict,
  status public.factored_invoice_status not null default 'draft',
  submitted_at timestamptz,
  submitted_by uuid,
  invoice_face_value numeric(10,2) not null check (invoice_face_value >= 0),
  advance_percentage numeric(5,2) not null check (advance_percentage >= 0 and advance_percentage <= 100),
  expected_advance_amount numeric(10,2) not null check (expected_advance_amount >= 0),
  factoring_fee_percentage numeric(5,2) not null check (factoring_fee_percentage >= 0 and factoring_fee_percentage <= 100),
  factoring_fee_amount numeric(10,2) not null check (factoring_fee_amount >= 0),
  reserve_percentage numeric(5,2) not null check (reserve_percentage >= 0 and reserve_percentage <= 100),
  reserve_amount numeric(10,2) not null check (reserve_amount >= 0),
  other_fees numeric(10,2) not null default 0,
  fee_timing text not null check (fee_timing in ('deducted_at_funding','deducted_from_reserve')),
  expected_funding_amount numeric(10,2) not null check (expected_funding_amount >= 0),
  reserve_released_amount numeric(10,2) not null default 0,
  recourse_amount numeric(10,2) not null default 0,
  chargeback_amount numeric(10,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_factored_invoices_invoice_id on public.factored_invoices (invoice_id);

create or replace function public.guard_factored_invoice_org()
returns trigger language plpgsql as $$
declare v_invoice_org uuid; v_company_org uuid;
begin
  select organization_id into v_invoice_org from public.invoices where id = new.invoice_id;
  if v_invoice_org is null or v_invoice_org <> new.organization_id then
    raise exception 'Factored invoice must reference an invoice in the same organization.';
  end if;
  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'Factored invoice must reference a factoring company in the same organization.';
  end if;
  return new;
end;
$$;

create trigger factored_invoices_guard_org
  before insert on public.factored_invoices
  for each row execute function public.guard_factored_invoice_org();

create table public.factoring_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  factored_invoice_id uuid not null references public.factored_invoices (id) on delete cascade,
  event_type text not null,
  from_status text,
  to_status text,
  performed_by uuid,
  created_at timestamptz not null default now());

-- --- 0072: set_default_factoring_relationship (pre-0138 form) + company
-- deactivation guard ---------------------------------------------------
create or replace function public.set_default_factoring_relationship(p_relationship_id uuid)
returns void language plpgsql security invoker as $$
declare
  v_org_id uuid;
  v_relationship record;
  v_company_active boolean;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then raise exception 'No organization on this account.'; end if;
  if not public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]) then
    raise exception 'You do not have permission to change factoring settings.';
  end if;
  perform pg_advisory_xact_lock(hashtext('factoring_default_relationship:' || v_org_id::text));
  select id, organization_id, factoring_company_id, is_active into v_relationship
  from public.factoring_relationships where id = p_relationship_id for update;
  if v_relationship.id is null or v_relationship.organization_id <> v_org_id then
    raise exception 'This factoring relationship is not available.';
  end if;
  if not v_relationship.is_active then raise exception 'This factoring relationship is inactive.'; end if;
  select is_active into v_company_active from public.factoring_companies where id = v_relationship.factoring_company_id;
  if not coalesce(v_company_active, false) then
    raise exception 'This factoring relationship''s factoring company is inactive.';
  end if;
  update public.factoring_relationships set is_default = false
    where organization_id = v_org_id and is_default = true and id <> p_relationship_id;
  update public.factoring_relationships set is_default = true where id = p_relationship_id;
end;
$$;

grant execute on function public.set_default_factoring_relationship(uuid) to authenticated;

create or replace function public.guard_factoring_company_deactivation()
returns trigger language plpgsql as $$
declare v_has_active_default boolean;
begin
  if old.is_active and not new.is_active then
    perform pg_advisory_xact_lock(hashtext('factoring_default_relationship:' || old.organization_id::text));
    select exists (
      select 1 from public.factoring_relationships
      where factoring_company_id = old.id and is_active = true and is_default = true
    ) into v_has_active_default;
    if v_has_active_default then
      raise exception 'This factoring company cannot be deactivated while one of its relationships is the default. Choose another default relationship first.';
    end if;
  end if;
  return new;
end;
$$;

create trigger factoring_companies_guard_deactivation
  before update of is_active on public.factoring_companies
  for each row execute function public.guard_factoring_company_deactivation();

-- --- 0073-0075: submit_invoice_to_factor (final pre-0140 form, 0075) -----
-- Faithful reproduction of the LIVE (0075) function body, byte-for-byte
-- copied from that migration -- this is what 0140's TEST/VERIFY files
-- exercise as "the pre-0140 baseline" before asserting what 0140 itself
-- changes. Not a simplified stub: real production runs exactly this body
-- today.
create or replace function public.submit_invoice_to_factor(
  p_invoice_id uuid,
  p_relationship_id uuid
)
returns table (factored_invoice_id uuid, status public.factored_invoice_status)
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_invoice record;
  v_relationship record;
  v_company_active boolean;
  v_existing_active uuid;
  v_face_value numeric(10, 2);
  v_advance_amount numeric(10, 2);
  v_fee_amount numeric(10, 2);
  v_reserve_amount numeric(10, 2);
  v_other_fees numeric(10, 2);
  v_funding_amount numeric(10, 2);
  v_new_id uuid;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to submit invoices for factoring.';
  end if;

  perform pg_advisory_xact_lock(hashtext('factoring_submission:' || p_invoice_id::text));

  select inv.id, inv.organization_id, inv.status, inv.total_amount, inv.amount_paid
    into v_invoice
  from public.invoices inv
  where inv.id = p_invoice_id;

  if v_invoice.id is null or v_invoice.organization_id <> v_org_id then
    raise exception 'Invoice not found.';
  end if;

  if v_invoice.status not in ('sent', 'viewed') or v_invoice.amount_paid <> 0 then
    raise exception 'This invoice is not eligible for factoring.';
  end if;

  select fi.id into v_existing_active
  from public.factored_invoices fi
  where fi.invoice_id = p_invoice_id and fi.status not in ('rejected', 'cancelled')
  limit 1;
  if v_existing_active is not null then
    raise exception 'This invoice has already been submitted to a factor.';
  end if;

  select rel.id, rel.organization_id, rel.factoring_company_id, rel.is_active,
         rel.default_advance_percentage, rel.default_factoring_fee_percentage, rel.default_reserve_percentage,
         rel.fee_timing, rel.other_fee_default, rel.effective_from, rel.effective_to
    into v_relationship
  from public.factoring_relationships rel
  where rel.id = p_relationship_id
  for update;

  if v_relationship.id is null or v_relationship.organization_id <> v_org_id then
    raise exception 'This factoring relationship is not available.';
  end if;
  if not v_relationship.is_active then
    raise exception 'The selected factoring relationship is inactive.';
  end if;
  if v_relationship.effective_from > current_date or (v_relationship.effective_to is not null and v_relationship.effective_to < current_date) then
    raise exception 'The selected factoring relationship is not currently effective.';
  end if;

  select comp.is_active into v_company_active
  from public.factoring_companies comp
  where comp.id = v_relationship.factoring_company_id;
  if not coalesce(v_company_active, false) then
    raise exception 'The selected factoring company is inactive.';
  end if;

  v_face_value := v_invoice.total_amount;
  v_advance_amount := round(v_face_value * v_relationship.default_advance_percentage / 100, 2);
  v_fee_amount := round(v_face_value * v_relationship.default_factoring_fee_percentage / 100, 2);
  v_reserve_amount := round(v_face_value * v_relationship.default_reserve_percentage / 100, 2);
  v_other_fees := coalesce(v_relationship.other_fee_default, 0);
  v_funding_amount := v_advance_amount - v_other_fees - (case when v_relationship.fee_timing = 'deducted_at_funding' then v_fee_amount else 0 end);

  if v_funding_amount < 0 then
    raise exception 'Estimated funding amount for this invoice would be negative under the selected relationship''s terms.';
  end if;

  insert into public.factored_invoices (
    organization_id, invoice_id, factoring_company_id, factoring_relationship_id,
    status, submitted_at, submitted_by,
    invoice_face_value, advance_percentage, expected_advance_amount,
    factoring_fee_percentage, factoring_fee_amount,
    reserve_percentage, reserve_amount,
    other_fees, fee_timing, expected_funding_amount
  ) values (
    v_org_id, p_invoice_id, v_relationship.factoring_company_id, p_relationship_id,
    'submitted', now(), auth.uid(),
    v_face_value, v_relationship.default_advance_percentage, v_advance_amount,
    v_relationship.default_factoring_fee_percentage, v_fee_amount,
    v_relationship.default_reserve_percentage, v_reserve_amount,
    v_other_fees, v_relationship.fee_timing, v_funding_amount
  )
  returning id into v_new_id;

  insert into public.factoring_events (
    organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by
  ) values (
    v_org_id, v_new_id, 'submitted', null, 'submitted', auth.uid()
  );

  return query select v_new_id, 'submitted'::public.factored_invoice_status;
end;
$$;

grant execute on function public.submit_invoice_to_factor(uuid, uuid) to authenticated;
