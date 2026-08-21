-- =============================================================================
-- 0081_carrier_onboarding_foundation.sql
-- Phase 2L.2: Carrier Onboarding schema + secure invitation model.
-- PROPOSED ONLY -- NOT APPLIED.
--
-- Foundation/security only, per the approved Phase 2L.2 design. This
-- migration creates no working end-to-end flow -- no code in this repo
-- calls any function defined here yet. What it establishes:
--
--   1. carrier_onboarding_applications -- a DRAFT/APPLICATION record,
--      deliberately NOT public.carriers. An application is reviewed by
--      staff and, if approved, converted into a real carrier -- same
--      relationship driver_applications (0018) already has to
--      public.drivers, including its own converted_carrier_id (mirrors
--      converted_driver_id).
--   2. carrier_onboarding_invitations -- secure, hashed-token invitations,
--      architecturally identical to driver_portal_sessions (0015): RLS
--      enabled, ZERO policies, service-role-only access, raw token never
--      stored.
--   3. carrier_onboarding_requirements -- organization-specific configurable
--      document requirements (required/optional/excluded per document_type).
--   4. carrier_onboarding_pii_access_log -- immutable EIN-reveal audit
--      trail, mirrors driver_application_pii_access_log (0018) exactly.
--   5. EIN encryption for the application's own ein_encrypted/ein_last4
--      columns, reusing the exact pgp_sym_encrypt/app_encryption_keys
--      mechanism 0014/0018 already established for driver SSN -- with its
--      OWN named key (carrier_pii_key), not a shared key with driver PII.
--
-- Explicitly NOT in this migration (deferred to later 2L checkpoints, per
-- the approved design):
--   submit_carrier_onboarding_application(), convert_carrier_onboarding_
--   application(), document promotion, the carrier portal, the staff
--   onboarding workspace, email invitations, agreement templates,
--   electronic signatures, typed initials, signature audit, setup package
--   generation, any carriers.ein change, any carrier_financials mutation.
--
-- No existing table, column, function, trigger, RLS policy, or storage
-- bucket is modified. Every change below is additive: two new enum
-- values, two new enums, four new tables, three new functions, one new
-- app_encryption_keys row, one new storage bucket.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- PART 1 -- enum additions (additive, existing values untouched).
-- ---------------------------------------------------------------------------

-- Lets onboarding documents live in the existing polymorphic public.documents
-- table (entity_id = carrier_onboarding_applications.id) instead of a
-- separate document model or a JSONB blob (driver_applications.
-- uploaded_documents' pattern) -- chosen specifically so verify/reject/
-- expiry/getLatestDocument() all work unmodified for onboarding documents.
-- See the approved Phase 2L.2 design report, item 11.
alter type public.entity_type add value if not exists 'carrier_onboarding_application';

-- The one new document type the 2L.1/2L.2 audits found justified. A single
-- type covers whatever banking-verification artifact an org accepts
-- (voided check today, could be a bank letter tomorrow) -- no distinct
-- workflow was ever identified that would need a second, separate
-- "banking_document" type alongside it.
alter type public.document_type add value if not exists 'voided_check';

-- ---------------------------------------------------------------------------
-- PART 2 -- new enums.
-- ---------------------------------------------------------------------------

-- Deliberately narrower than the starting proposal: 'sent'/'viewed'/
-- 'in_progress' are dropped in favor of the invitation's own first_viewed_at
-- / last_viewed_at (Part 5 below) -- those are facts about the invitation,
-- not the application, and duplicating them here as parallel status
-- transitions risks the two disagreeing. 'rejected' is added (absent from
-- the starting proposal) to mirror driver_application_status's own distinct
-- rejected vs. needs_correction split -- an outright "no" is a different
-- business event than "needs more info" and conflating them would
-- misrepresent a closed application as still open. See design report items
-- 4-5 for the full transition graph and reasoning.
create type public.carrier_onboarding_application_status as enum (
  'draft', 'submitted', 'needs_correction', 'approved', 'rejected', 'converted', 'cancelled', 'expired'
);

create type public.carrier_onboarding_requirement_level as enum ('required', 'optional', 'excluded');

-- ---------------------------------------------------------------------------
-- PART 3 -- carrier_pii_key: a SEPARATE named key from driver_pii_key
-- (0014). app_encryption_keys is already a named multi-key store for
-- exactly this reason -- sharing one symmetric key across two unrelated PII
-- categories (driver SSN, carrier EIN) would mean a compromise of one
-- exposes the other unnecessarily, for no benefit.
-- ---------------------------------------------------------------------------

insert into public.app_encryption_keys (key_name, key_value)
values ('carrier_pii_key', encode(gen_random_bytes(32), 'hex'))
on conflict (key_name) do nothing;

-- ---------------------------------------------------------------------------
-- PART 4 -- carrier_onboarding_applications.
--
-- Not a blind mirror of public.carriers: is_active/onboarded_at are
-- carrier-only concepts (meaningless before a carrier exists);
-- dispatch_fee_percentage/payment_terms_days are prefixed proposed_ and
-- kept separate from carrier_financials -- an applicant's self-declared
-- terms are a starting position, never blindly copied into the operational
-- rate at conversion (that stays a staff decision, made explicitly by the
-- future convert_carrier_onboarding_application() RPC, not by this schema).
-- application_notes is named distinctly from both carriers.notes (internal
-- staff notes) and review_notes (staff-only, below) to keep authorship
-- unambiguous.
-- ---------------------------------------------------------------------------

create table public.carrier_onboarding_applications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  status public.carrier_onboarding_application_status not null default 'draft',

  -- Company
  legal_name text,
  dba_name text,
  mc_number text,
  dot_number text,

  -- Contact
  contact_name text,
  phone text,
  email text,

  -- Address
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  postal_code text,
  country text,

  -- Business / sensitive -- see Part 6 (EIN encryption) and Part 7 (column
  -- grants) below. Never selectable by authenticated directly.
  ein_encrypted bytea,
  ein_last4 text,
  application_notes text,

  -- Applicant-declared financial/factoring terms -- proposed only, see
  -- header comment above. Never read by any existing report/RPC.
  proposed_dispatch_fee_percentage numeric(5, 2),
  proposed_payment_terms_days integer,
  factoring_company_name text,
  has_factoring boolean,

  -- Draft/proposed equipment only (2L.1 audit item 24/2L.2 design item 12)
  -- -- never creates real trucks/trailers/drivers rows. Shape intentionally
  -- left open (no CHECK/schema on the JSONB) since the portal form that
  -- populates it doesn't exist yet (2L.5).
  equipment_data jsonb,

  -- Workflow
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles (id) on delete set null,
  review_notes text,
  converted_at timestamptz,
  converted_by uuid references public.profiles (id) on delete set null,
  converted_carrier_id uuid references public.carriers (id) on delete set null
);

comment on table public.carrier_onboarding_applications is
  'Draft/application record for carrier onboarding -- NEVER the canonical carrier. Reviewed by staff and, if approved, converted into a real public.carriers row (converted_carrier_id) by a future SECURITY DEFINER conversion function -- mirrors driver_applications/converted_driver_id (0018) exactly. ein_encrypted is never selectable by authenticated; see reveal_carrier_onboarding_ein().';

comment on column public.carrier_onboarding_applications.ein_encrypted is
  'PGP-symmetric-encrypted with carrier_pii_key (a key SEPARATE from driver_pii_key). Never selectable by authenticated directly -- see the column-level revoke in this same migration and reveal_carrier_onboarding_ein().';

drop trigger if exists set_updated_at on public.carrier_onboarding_applications;
create trigger set_updated_at before update on public.carrier_onboarding_applications
  for each row execute function public.set_updated_at();

alter table public.carrier_onboarding_applications enable row level security;

-- select: standard operational tier -- any org member (matches carriers/
-- documents' own existing select policy shape from 0010), not narrowed to
-- FINANCIAL_ROLES -- the application record itself is not treated as a
-- financial document; only ein_encrypted specifically is (via the column
-- grant below and the reveal RPC's own owner/admin-only gate).
create policy carrier_onboarding_applications_select on public.carrier_onboarding_applications
  for select using (organization_id = public.current_org_id());

-- insert: owner/admin/dispatcher -- matches who can already create a
-- carrier today (carriers_insert, 0010) and who the approved design (item
-- 15) grants "create invite / send / review" to. A fresh insert here only
-- ever creates an empty shell row (status='draft', no applicant data yet --
-- the applicant has no session at insert time regardless of this policy);
-- it is not a channel for staff to fabricate applicant answers.
create policy carrier_onboarding_applications_insert on public.carrier_onboarding_applications
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- update: owner/admin/dispatcher, same tier -- the REAL restriction on
-- which fields staff can touch is the column-level grant below (workflow
-- fields only, mirrors driver_applications' update grant exactly), not
-- this row-level policy.
create policy carrier_onboarding_applications_update on public.carrier_onboarding_applications
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- No delete policy -- an onboarding application is a historical/audit-
-- relevant record, matching driver_applications (which also has none).

-- ---------------------------------------------------------------------------
-- PART 5 -- column-level grants. RLS alone does not stop selecting/writing
-- a specific column -- this is the real enforcement for ein_encrypted,
-- exactly mirroring driver_applications' own revoke/grant block (0018).
-- ---------------------------------------------------------------------------

revoke select on public.carrier_onboarding_applications from authenticated, anon;
grant select (
  id, organization_id, status,
  legal_name, dba_name, mc_number, dot_number,
  contact_name, phone, email,
  address_line1, address_line2, city, state, postal_code, country,
  ein_last4, application_notes,
  proposed_dispatch_fee_percentage, proposed_payment_terms_days, factoring_company_name, has_factoring,
  equipment_data,
  created_at, updated_at, submitted_at,
  reviewed_at, reviewed_by, review_notes,
  converted_at, converted_by, converted_carrier_id
) on public.carrier_onboarding_applications to authenticated;
-- ein_encrypted intentionally excluded -- the only path to its plaintext is
-- reveal_carrier_onboarding_ein() (Part 8), which is SECURITY DEFINER and
-- therefore unaffected by this revoke.

revoke insert on public.carrier_onboarding_applications from authenticated, anon;
grant insert (
  id, organization_id, status,
  legal_name, dba_name, mc_number, dot_number,
  contact_name, phone, email,
  address_line1, address_line2, city, state, postal_code, country,
  ein_last4, application_notes,
  proposed_dispatch_fee_percentage, proposed_payment_terms_days, factoring_company_name, has_factoring,
  equipment_data
) on public.carrier_onboarding_applications to authenticated;
-- ein_encrypted intentionally excluded from insert too -- staff never write
-- a raw or pre-encrypted EIN value directly; only a future SECURITY
-- DEFINER function (which encrypts server-side, mirroring
-- submit_driver_application's own v_ssn_encrypted := pgp_sym_encrypt(...)
-- pattern) will ever populate it.

revoke update on public.carrier_onboarding_applications from authenticated, anon;
grant update (status, reviewed_by, reviewed_at, review_notes) on public.carrier_onboarding_applications to authenticated;
-- Matches driver_applications' own update grant list exactly (status,
-- reviewed_by, reviewed_at, review_notes) -- converted_at/converted_by/
-- converted_carrier_id are deliberately excluded here too, same as that
-- precedent: only the future SECURITY DEFINER conversion function may set
-- them, never a plain authenticated UPDATE.

-- ---------------------------------------------------------------------------
-- PART 6 -- carrier_onboarding_pii_access_log. Immutable audit trail of
-- every EIN reveal, mirrors driver_application_pii_access_log (0018)
-- exactly -- kept as its own table rather than widening that one, since it
-- references carrier_onboarding_applications, not driver_applications, and
-- the two shouldn't be joined loosely.
-- ---------------------------------------------------------------------------

create table public.carrier_onboarding_pii_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  application_id uuid not null references public.carrier_onboarding_applications (id) on delete cascade,
  accessed_by uuid not null references public.profiles (id) on delete set null,
  reason text not null,
  accessed_at timestamptz not null default now()
);

comment on table public.carrier_onboarding_pii_access_log is
  'Immutable audit trail of every applicant EIN reveal. Written exclusively by reveal_carrier_onboarding_ein(); no insert/update/delete policy exists for authenticated/anon.';

alter table public.carrier_onboarding_pii_access_log enable row level security;

create policy carrier_onboarding_pii_access_log_select on public.carrier_onboarding_pii_access_log
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- No insert/update/delete policy -- rows are created exclusively by
-- reveal_carrier_onboarding_ein() below, which runs as SECURITY DEFINER
-- and so bypasses RLS regardless of the caller's own grants.

-- ---------------------------------------------------------------------------
-- PART 7 -- reveal_carrier_onboarding_ein(): owner/admin-only, reason
-- required, every successful reveal logged. Mirrors
-- reveal_driver_application_pii() (0018) exactly, with one strengthening:
-- that precedent's p_reason is optional (text default null); this one
-- requires a real, non-blank reason before it will decrypt anything.
-- ---------------------------------------------------------------------------

create or replace function public.reveal_carrier_onboarding_ein(p_application_id uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_encrypted bytea;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to reveal this EIN.';
  end if;

  select organization_id, ein_encrypted into v_org_id, v_encrypted
  from public.carrier_onboarding_applications where id = p_application_id;

  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Application not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may reveal this field';
  end if;
  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('carrier_pii_key');

  insert into public.carrier_onboarding_pii_access_log (organization_id, application_id, accessed_by, reason)
  values (v_org_id, p_application_id, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;

grant execute on function public.reveal_carrier_onboarding_ein(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- PART 8 -- find_potential_duplicate_carriers(): candidate detection only.
-- Never merges, rejects, creates, or modifies anything -- read-only,
-- returns candidates for a future staff "Link to Existing" / "Create New"
-- decision (2L.4+), which this migration does not implement.
--
-- SECURITY INVOKER, not DEFINER (a refinement from the approved design
-- report, which described this as security definer -- see the 0081 final
-- report's discrepancy note): this function only reads carriers and
-- carrier_onboarding_applications, both of which the calling
-- owner/admin/dispatcher session can already read via its own RLS/column
-- grants. It doesn't need to bypass RLS, so it shouldn't -- matches the
-- same minimal-privilege reasoning already established by
-- submit_invoice_to_factor() (0075), which is security invoker for the
-- identical reason.
-- ---------------------------------------------------------------------------

create or replace function public.find_potential_duplicate_carriers(
  p_application_id uuid
)
returns table (carrier_id uuid, legal_name text, matched_on text[])
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_org_id uuid;
  v_mc text;
  v_dot text;
  v_ein_last4 text;
begin
  if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to search for duplicate carriers.';
  end if;

  select organization_id, nullif(btrim(mc_number), ''), nullif(btrim(dot_number), ''), ein_last4
    into v_org_id, v_mc, v_dot, v_ein_last4
  from public.carrier_onboarding_applications
  where id = p_application_id;

  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Application not found in your organization';
  end if;

  return query
  select c.id, c.legal_name,
    array_remove(array[
      case when v_mc is not null and btrim(c.mc_number) = v_mc then 'mc_number' end,
      case when v_dot is not null and btrim(c.dot_number) = v_dot then 'dot_number' end,
      case when v_ein_last4 is not null and right(c.ein, 4) = v_ein_last4 then 'ein_last4' end
    ], null)
  from public.carriers c
  where c.organization_id = v_org_id
    and (
      (v_mc is not null and btrim(c.mc_number) = v_mc)
      or (v_dot is not null and btrim(c.dot_number) = v_dot)
      or (v_ein_last4 is not null and right(c.ein, 4) = v_ein_last4)
    );
end;
$$;

grant execute on function public.find_potential_duplicate_carriers(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- PART 9 -- application status-transition guard. Enforces the exact
-- approved graph at the DB layer, not left to application-code discipline
-- alone -- matches this codebase's existing convention of enforcing
-- invariants as DB constraints/triggers (e.g. the 0054 active-uniqueness
-- guards) rather than trusting every future caller to get it right.
-- ---------------------------------------------------------------------------

create or replace function public.guard_carrier_onboarding_application_status_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'draft' and new.status in ('submitted', 'cancelled', 'expired') then
    return new;
  elsif old.status = 'submitted' and new.status in ('needs_correction', 'approved', 'rejected', 'cancelled') then
    return new;
  elsif old.status = 'needs_correction' and new.status in ('submitted', 'cancelled') then
    return new;
  elsif old.status = 'approved' and new.status in ('converted', 'cancelled') then
    return new;
  else
    raise exception 'Invalid carrier onboarding application status transition: % -> %', old.status, new.status;
  end if;
end;
$$;

drop trigger if exists carrier_onboarding_applications_status_guard on public.carrier_onboarding_applications;
create trigger carrier_onboarding_applications_status_guard
  before update on public.carrier_onboarding_applications
  for each row
  when (old.status is distinct from new.status)
  execute function public.guard_carrier_onboarding_application_status_transition();

-- ---------------------------------------------------------------------------
-- PART 10 -- carrier_onboarding_invitations. Architecturally identical to
-- driver_portal_sessions (0015): RLS enabled, ZERO policies -- accessed
-- exclusively via the service_role key from trusted server-side code.
-- Raw tokens are never stored, only their sha256 hash (token_hash) --
-- generated application-side with node:crypto randomBytes(32), the same
-- mechanism src/lib/driver-portal/session.ts already uses.
-- ---------------------------------------------------------------------------

create table public.carrier_onboarding_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  application_id uuid not null references public.carrier_onboarding_applications (id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null references public.profiles (id) on delete set null,
  first_viewed_at timestamptz,
  last_viewed_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references public.profiles (id) on delete set null,
  submitted_at timestamptz
);

comment on table public.carrier_onboarding_invitations is
  'Secure, hashed-token carrier onboarding invitations. RLS enabled with ZERO policies -- deliberately mirrors driver_portal_sessions (0015): accessed exclusively via the service_role key from trusted server code, never a client-side RLS-scoped query. The raw token exists only in the invite URL / applicant browser cookie -- never at rest here.';

comment on column public.carrier_onboarding_invitations.token_hash is
  'sha256 hex digest of the raw invitation token. The raw token is NEVER stored -- generated via node:crypto randomBytes(32), hashed before insert, mirroring src/lib/driver-portal/session.ts exactly.';

alter table public.carrier_onboarding_invitations enable row level security;
-- No policies created -- RLS enabled with zero policies denies all access
-- to `authenticated` and `anon`; only the service_role key (which bypasses
-- RLS entirely) can read or write this table. This is intentional, not an
-- oversight -- see the table comment above.

create index carrier_onboarding_invitations_application_id_idx on public.carrier_onboarding_invitations (application_id);

-- ---------------------------------------------------------------------------
-- PART 11 -- guard_carrier_onboarding_invitation_org(): the invitation's
-- application_id must resolve to the SAME organization_id as the
-- invitation row itself -- an ordinary FK can't prove this (it only proves
-- application_id references a real row, not that the two organization_id
-- values agree). Same shape as guard_factoring_relationship_org() (0071).
-- ---------------------------------------------------------------------------

create or replace function public.guard_carrier_onboarding_invitation_org()
returns trigger
language plpgsql
as $$
declare
  v_application_org uuid;
begin
  select organization_id into v_application_org
  from public.carrier_onboarding_applications
  where id = new.application_id;

  if v_application_org is null or v_application_org <> new.organization_id then
    raise exception 'Carrier onboarding invitation must reference an application in the same organization.';
  end if;
  return new;
end;
$$;

drop trigger if exists carrier_onboarding_invitations_guard_org on public.carrier_onboarding_invitations;
create trigger carrier_onboarding_invitations_guard_org
  before insert on public.carrier_onboarding_invitations
  for each row execute function public.guard_carrier_onboarding_invitation_org();

-- ---------------------------------------------------------------------------
-- PART 12 -- carrier_onboarding_requirements. Organization-specific
-- configurable document requirements -- one row per org/document_type.
-- ---------------------------------------------------------------------------

create table public.carrier_onboarding_requirements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  document_type public.document_type not null,
  requirement public.carrier_onboarding_requirement_level not null default 'optional',
  display_order integer not null default 0,
  custom_label text,
  instructions text,
  requires_expiry_date boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, document_type)
);

comment on table public.carrier_onboarding_requirements is
  'Per-organization configuration of which document types are required/optional/excluded during carrier onboarding. Never a global/hardcoded list -- this app is multi-tenant.';

drop trigger if exists set_updated_at on public.carrier_onboarding_requirements;
create trigger set_updated_at before update on public.carrier_onboarding_requirements
  for each row execute function public.set_updated_at();

alter table public.carrier_onboarding_requirements enable row level security;

-- select: any org member (owner/admin/dispatcher/accountant/viewer) -- read
-- access matches every other operational table's own select tier.
create policy carrier_onboarding_requirements_select on public.carrier_onboarding_requirements
  for select using (organization_id = public.current_org_id());

-- write: owner/admin ONLY -- narrower than the general operational-write
-- tier (owner/admin/dispatcher) elsewhere in this schema. This is
-- organization-wide policy configuration, not day-to-day onboarding work --
-- flagged in the approved design report (item 24) as a judgment call, not
-- an explicit instruction, since dispatcher-configurable would also be
-- defensible.
create policy carrier_onboarding_requirements_insert on public.carrier_onboarding_requirements
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy carrier_onboarding_requirements_update on public.carrier_onboarding_requirements
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy carrier_onboarding_requirements_delete on public.carrier_onboarding_requirements
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- PART 13 -- indexes. Only what's justified by a known access path (design
-- report item 18/19) -- no speculative MC/DOT indexes; carriers_org_mc_dot
-- lookups run through find_potential_duplicate_carriers() at approval time
-- only, low frequency, low per-org row count.
-- ---------------------------------------------------------------------------

-- Every staff workspace list/KPI query filters by org and groups/filters by
-- status (2L.1 audit's own proposed KPI row: Active/In Review/Needs Action).
create index carrier_onboarding_applications_org_status_idx on public.carrier_onboarding_applications (organization_id, status);

-- Default sort for the applications table.
create index carrier_onboarding_applications_org_created_idx on public.carrier_onboarding_applications (organization_id, created_at desc);

-- carrier_onboarding_invitations_application_id_idx already created in
-- Part 10 above (resolving "which invitation(s) belong to this
-- application" from the staff side).

-- token_hash's own `unique` constraint (Part 10) already backs an index
-- for the lookup path -- no separate index needed.

-- carrier_onboarding_requirements' own `unique (organization_id,
-- document_type)` constraint (Part 12) already backs an index for the
-- common "all requirements for this org" query -- no separate index
-- needed.

-- ---------------------------------------------------------------------------
-- PART 14 -- storage bucket. Private, server-mediated-only -- mirrors
-- driver-application-documents (0018), with one deliberate tightening
-- (documented in the approved design report, item 20): unlike that
-- precedent's upload route (explicitly accepting any caller who knows a
-- valid application UUID, accepted there because it's write-only and
-- low-stakes for an open public form), carrier onboarding's whole premise
-- is a token-gated invitation -- so the future upload route for this
-- bucket must verify a valid, non-expired, non-revoked invitation token
-- before accepting a file, not merely a guessable-resistant UUID. That
-- route does not exist yet (deferred to 2L.5); this migration only creates
-- the bucket itself.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'carrier-onboarding-documents',
  'carrier-onboarding-documents',
  false,
  10485760, -- 10 MB, matches driver-application-documents
  array['application/pdf', 'image/jpeg', 'image/png', 'image/heic']
)
on conflict (id) do nothing;

-- No Storage RLS policies -- deliberately mirrors driver-application-
-- documents (0018), which also has none: all access goes through
-- service-role-mediated server routes that independently verify the
-- caller (a valid invitation token, once that route exists) before ever
-- touching Storage, not through a client-side Storage RLS policy.
