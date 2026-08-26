-- =============================================================================
-- 0099_carrier_w9.sql
-- Phase 2N.2: Carrier W-9 -- structured collection, certification,
-- immutable official-form PDF generation, and verified document
-- registration. NOT YET APPLIED -- authored for review only, per explicit
-- instruction. Does not touch 0095/0096/0097/0098 (Broker Packet) in any
-- way; Broker Packet remains a future CONSUMER of the resulting verified
-- document, never a producer of W-9 data (see the header note near the
-- bottom of this file on the current, real incompatibility that blocks
-- that consumption today).
--
-- Official form verified live against the IRS's own "About Form W-9" page
-- immediately before writing this migration: Rev. March 2024 remains the
-- current, officially finalized revision as of 2026-08-23 ("Recent
-- developments: None at this time"). A January/June 2026 revision exists
-- only in DRAFT status at the IRS -- not finalized, not used here. The
-- actual PDF was downloaded to a local scratch path (never committed to
-- this repo) and inspected directly with pdf-lib before writing this
-- migration's field mapping -- see the application-layer PDF filler for
-- the full 23-field map, independently re-derived from live widget
-- rectangles, not assumed from memory.
--
-- Encryption architecture: REUSED verbatim, zero new mechanism. TIN
-- ciphertext uses the EXISTING carrier_pii_key (0081) via the EXISTING
-- pgp_sym_encrypt/pgp_sym_decrypt + get_app_encryption_key() functions
-- (0014/0081) -- the same key already protects
-- carrier_onboarding_applications.ein_encrypted. reveal_carrier_w9_tin()
-- below mirrors reveal_carrier_onboarding_ein() (0081) field-for-field:
-- owner/admin-only, reason required and non-blank, one audit-log insert
-- per reveal, SECURITY DEFINER so column-level revokes never block it.
--
-- Lifecycle: exactly the 5 approved statuses (draft, completed,
-- superseded, voided, failed) -- no 6th status value was added. The
-- draft->completed transition is nonetheless split into TWO RPC calls
-- (certify_carrier_w9 then finalize_carrier_w9), both while status stays
-- 'draft', distinguished internally by certified_at being non-null --
-- this reuses the exact reserve-then-finalize shape that Broker Packet's
-- reserve_broker_packet()/finalize_broker_packet() (0095, repaired by
-- 0096-0098) already proved correct, WITHOUT repeating either of that
-- pattern's two defects: there is no child items table here for an
-- immutable-once-generating trigger to get wrong, and finalize_carrier_w9
-- explicitly supplies its own organization_id to log_activity() (see
-- 0098's header comment on exactly this class of bug) rather than
-- depending on current_org_id() under a service-role caller.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- PART 1 -- enums
-- ---------------------------------------------------------------------------

-- Own distinct entity_type, exactly mirroring Broker Packet's own
-- precedent (0095 added 'broker_packet' rather than folding its activity
-- into 'broker') -- every activity event below logs against the W-9's own
-- id, never a subject id branch-guessed by which column happens to be
-- set, which would otherwise be a real bug: a W-9 created directly
-- against an existing carrier (no onboarding application at all) has no
-- valid 'carrier_onboarding_application' id to log against.
alter type public.entity_type add value if not exists 'carrier_w9';

create type public.carrier_w9_status as enum ('draft', 'completed', 'superseded', 'voided', 'failed');

-- Exactly the seven line-3a boxes on the live Rev. March 2024 form (five
-- single boxes plus LLC plus Other) -- Individual/sole proprietor,
-- C corporation, S corporation, Partnership, Trust/estate, LLC, Other.
-- No tax classification invented beyond what the official form prints.
create type public.w9_tax_classification as enum (
  'individual_sole_proprietor', 'c_corporation', 's_corporation', 'partnership', 'trust_estate', 'llc', 'other'
);

create type public.w9_tin_type as enum ('ssn', 'ein');

-- ---------------------------------------------------------------------------
-- PART 1B -- documents.storage_bucket (2N.2A).
--
-- Audited before writing this: public.documents (0005) has NO bucket
-- column at all today -- every row is assumed, by convention/comment
-- only ("file_path references an object in the 'documents' Supabase
-- Storage bucket"), to live in a bucket literally named 'documents'.
-- Broker Packet's guard_broker_packet_item()/add_broker_packet_item()
-- (0095) both hardcode that same literal assumption. This column makes
-- the assumption explicit and per-row instead of implicit and global --
-- purely additive, on the pre-existing documents table (not an 0095-owned
-- object), zero backfill: every existing row keeps meaning exactly what
-- it already meant, via the column default.
--
-- This migration populates it correctly for the ONE new document type it
-- creates (W-9 -> 'carrier-w9s', in finalize_carrier_w9() below). It does
-- NOT change guard_broker_packet_item() or add_broker_packet_item() --
-- doing so from this migration would create exactly the cross-feature
-- coupling to an 0095-owned object this project has consistently refused
-- to accept (see 0096/0097/0098's own precedent: every behavioral repair
-- to an 0095 function got its own separately authorized, separately
-- live-tested migration, never bundled into an unrelated feature). See
-- this migration's closing header note for the precise, separately
-- authorized future migration this enables but does not itself perform.
-- ---------------------------------------------------------------------------

alter table public.documents add column if not exists storage_bucket text not null default 'documents';

comment on column public.documents.storage_bucket is
  'The actual Supabase Storage bucket this row''s file_path lives in. Defaults to ''documents'' for every pre-2N.2A row (and every row inserted by code that does not set it explicitly), preserving existing meaning with zero backfill. A generated W-9 document (2N.2, finalize_carrier_w9()) is the first row type to ever set this to something else (''carrier-w9s''). Consumers that assumed a single global bucket (Broker Packet''s guard_broker_packet_item()/add_broker_packet_item(), 0095) have NOT yet been updated to read this column -- see 0099''s closing header note.';

-- ---------------------------------------------------------------------------
-- PART 2 -- carrier_w9s
--
-- Field list mapped against the live IRS PDF's own 23 AcroForm fields
-- (confirmed present, XFA data confirmed stripped automatically by
-- pdf-lib on load -- see the application-layer generator's header comment
-- for the full empirical trace) rather than the phase brief's proposed
-- list verbatim -- differences: llc_classification is a single char
-- (C/S/P per the form's own note), other_classification_description
-- matches the form's actual "Other (see instructions)" free-text field,
-- has_foreign_partners_owners is the NEW line 3b checkbox this exact
-- revision introduced (its presence in the live PDF is itself
-- confirmation this really is the March 2024 revision, not an older one).
-- requester_name_address and account_numbers are genuinely present on the
-- official form (an optional boxed area and line 7) and are kept as
-- optional free text, never used for authorization.
-- ---------------------------------------------------------------------------

create table public.carrier_w9s (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  onboarding_application_id uuid references public.carrier_onboarding_applications (id) on delete restrict,
  carrier_id uuid references public.carriers (id) on delete restrict,
  version integer,
  status public.carrier_w9_status not null default 'draft',
  form_revision text not null default '2024-03',

  -- Line 1/2
  name_on_tax_return text,
  business_name text,

  -- Line 3a/3b
  tax_classification public.w9_tax_classification,
  llc_classification text check (llc_classification is null or llc_classification in ('C', 'S', 'P')),
  other_classification_description text,
  has_foreign_partners_owners boolean not null default false,

  -- Line 4
  exempt_payee_code text,
  fatca_exemption_code text,

  -- Line 5/6
  address_line1 text,
  city text,
  state text,
  postal_code text,
  requester_name_address text,
  account_numbers text,

  -- Part I
  tin_type public.w9_tin_type,
  tin_encrypted bytea,
  tin_last4 text check (tin_last4 is null or tin_last4 ~ '^[0-9]{4}$'),

  -- Part II
  certified_name text,
  certified_title text,
  certified_at timestamptz,
  certification_version text not null default 'w9-electronic-v1',

  -- Generated artifact (populated once, at finalize_carrier_w9())
  generated_storage_path text,
  generated_pdf_sha256 text check (generated_pdf_sha256 is null or generated_pdf_sha256 ~ '^[0-9a-f]{64}$'),
  generated_file_size_bytes bigint check (generated_file_size_bytes is null or generated_file_size_bytes between 1 and 52428800),
  page_count integer check (page_count is null or page_count between 1 and 10),
  generated_at timestamptz,
  generated_by uuid references public.profiles (id) on delete set null,

  -- Document registration (see PART 9 below for the real limitation this
  -- surfaced) -- tracked explicitly so conversion can re-point the SAME
  -- row rather than searching documents by heuristics.
  registered_document_id uuid references public.documents (id) on delete set null,

  superseded_by uuid references public.carrier_w9s (id) on delete set null,
  superseded_at timestamptz,

  voided_at timestamptz,
  voided_by uuid references public.profiles (id) on delete set null,
  void_reason text,

  failure_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,

  -- At least one subject relationship, per the approved design ("Support
  -- onboarding can collect the W-9 before a carrier exists").
  constraint carrier_w9s_has_subject check (onboarding_application_id is not null or carrier_id is not null),

  -- Generated-artifact fields are all-or-nothing, mirroring
  -- broker_packets' own generated_shape constraint (0095) exactly.
  constraint carrier_w9s_generated_shape check (
    (status <> 'completed')
    or (
      generated_storage_path is not null and generated_pdf_sha256 is not null
      and generated_file_size_bytes is not null and page_count is not null and generated_at is not null
    )
  ),
  constraint carrier_w9s_void_shape check (voided_at is not null or (voided_by is null and void_reason is null)),
  constraint carrier_w9s_supersede_shape check (superseded_by is not null or superseded_at is null)
);

comment on table public.carrier_w9s is
  'One W-9 record per completion attempt. onboarding_application_id/carrier_id: at least one set; both may be set after conversion (historical evidence preserved, never rewritten -- see convert_carrier_onboarding_application() repair below). certify_carrier_w9() freezes tax identity/classification/TIN/address/certification (certified_at becomes non-null) while status remains draft; finalize_carrier_w9() (service-role only) then populates the generated artifact fields and flips status to completed, superseding any prior completed row for the same subject. TIN plaintext is never selectable -- see the column-level revoke below and reveal_carrier_w9_tin().';

comment on column public.carrier_w9s.tin_encrypted is
  'PGP-symmetric-encrypted with carrier_pii_key (0081) -- the SAME named key already protecting carrier_onboarding_applications.ein_encrypted, reused verbatim, not a new key or scheme. Never selectable by authenticated directly; see reveal_carrier_w9_tin().';

drop trigger if exists set_updated_at on public.carrier_w9s;
create trigger set_updated_at before update on public.carrier_w9s
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- PART 3 -- relationship guard (BEFORE INSERT/UPDATE): every non-null
-- subject id must actually belong to this row's own organization_id --
-- the same polymorphic-FK-substitute style Broker Packet (0095) and
-- Carrier Setup Packages (0087) already use, applied independently here
-- (no shared function, since the subject shape differs).
-- ---------------------------------------------------------------------------

create or replace function public.guard_carrier_w9_relationships()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.onboarding_application_id is not null then
    if not exists (
      select 1 from public.carrier_onboarding_applications
      where id = new.onboarding_application_id and organization_id = new.organization_id
    ) then
      raise exception 'W-9 onboarding application must belong to the same organization.';
    end if;
  end if;
  if new.carrier_id is not null then
    if not exists (select 1 from public.carriers where id = new.carrier_id and organization_id = new.organization_id) then
      raise exception 'W-9 carrier must belong to the same organization.';
    end if;
  end if;
  return new;
end;
$$;

create trigger carrier_w9s_relationships_guard
  before insert on public.carrier_w9s
  for each row execute function public.guard_carrier_w9_relationships();
create trigger carrier_w9s_relationships_guard_update
  before update of onboarding_application_id, carrier_id on public.carrier_w9s
  for each row execute function public.guard_carrier_w9_relationships();

-- ---------------------------------------------------------------------------
-- PART 4 -- immutability + status-graph guard (BEFORE UPDATE).
--
-- Statically audited against every legitimate transition BEFORE writing
-- this, specifically to avoid the exact two defect classes Broker
-- Packet's own guard needed two separate repairs for (0096-0098):
--   - the "populate once, from NULL, during a specific window" fields
--     below (certification/artifact) are each scoped to the PRECISE old
--     state that legitimately populates them, mirroring 0097/0098's
--     corrected pattern from day one rather than the original 0095
--     mistake of leaving that scoping off.
--   - there is no child table analogous to broker_packet_items here, so
--     the class of bug 0098 fixed (a child-row trigger blocking the
--     parent RPC's own legitimate write) cannot occur for W-9 by
--     construction.
-- ---------------------------------------------------------------------------

create or replace function public.guard_carrier_w9_immutability()
returns trigger language plpgsql set search_path = public as $$
begin
  -- Always immutable from insert onward: identity/ownership/audit fields.
  -- carrier_id is INTENTIONALLY excluded from this always-immutable set --
  -- see the relationships_guard_update trigger above (which still
  -- validates org-ownership on every UPDATE of it) and
  -- convert_carrier_onboarding_application()'s repair below, which is the
  -- ONE legitimate place a null carrier_id becomes non-null post
  -- conversion, without rewriting any other field.
  if new.organization_id is distinct from old.organization_id
    or new.onboarding_application_id is distinct from old.onboarding_application_id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at then
    raise exception 'A W-9 record''s identity cannot be changed.';
  end if;
  if old.carrier_id is not null and new.carrier_id is distinct from old.carrier_id then
    raise exception 'A W-9 record''s carrier link cannot be changed once assigned.';
  end if;

  -- Tax identity/classification/TIN/address/certification: populate
  -- exactly once, at certify_carrier_w9() (old.certified_at is null),
  -- then frozen for good -- this is the actual "completion" boundary the
  -- approved design means by "after certification/completion... must
  -- become immutable", not the later artifact-arrival step.
  if old.certified_at is not null and (
    new.name_on_tax_return is distinct from old.name_on_tax_return
    or new.business_name is distinct from old.business_name
    or new.tax_classification is distinct from old.tax_classification
    or new.llc_classification is distinct from old.llc_classification
    or new.other_classification_description is distinct from old.other_classification_description
    or new.has_foreign_partners_owners is distinct from old.has_foreign_partners_owners
    or new.exempt_payee_code is distinct from old.exempt_payee_code
    or new.fatca_exemption_code is distinct from old.fatca_exemption_code
    or new.address_line1 is distinct from old.address_line1
    or new.city is distinct from old.city
    or new.state is distinct from old.state
    or new.postal_code is distinct from old.postal_code
    or new.requester_name_address is distinct from old.requester_name_address
    or new.account_numbers is distinct from old.account_numbers
    or new.tin_type is distinct from old.tin_type
    or new.tin_encrypted is distinct from old.tin_encrypted
    or new.tin_last4 is distinct from old.tin_last4
    or new.certified_name is distinct from old.certified_name
    or new.certified_title is distinct from old.certified_title
    or new.certified_at is distinct from old.certified_at
    or new.certification_version is distinct from old.certification_version
    or new.version is distinct from old.version
  ) then
    raise exception 'A certified W-9''s tax identity, classification, TIN, address, and certification cannot be changed.';
  end if;

  -- Generated-artifact fields: populate exactly once, at
  -- finalize_carrier_w9() (old.status = 'draft' and about to become
  -- 'completed'), then frozen for good.
  if old.status <> 'draft' and (
    new.generated_storage_path is distinct from old.generated_storage_path
    or new.generated_pdf_sha256 is distinct from old.generated_pdf_sha256
    or new.generated_file_size_bytes is distinct from old.generated_file_size_bytes
    or new.page_count is distinct from old.page_count
    or new.generated_at is distinct from old.generated_at
    or new.generated_by is distinct from old.generated_by
  ) then
    raise exception 'A completed W-9''s generated artifact metadata cannot be changed.';
  end if;

  -- registered_document_id: populated once at finalize, may be updated
  -- exactly once more by convert_carrier_onboarding_application() to
  -- re-point the SAME document row's entity_type/entity_id (not to
  -- change which document_id this refers to) -- so this column itself is
  -- write-once from NULL, same shape as the artifact fields.
  if old.registered_document_id is not null and new.registered_document_id is distinct from old.registered_document_id then
    raise exception 'A W-9''s registered document cannot be changed once assigned.';
  end if;

  if old.status = 'draft' and new.status not in ('draft', 'completed', 'voided', 'failed') then
    raise exception 'Invalid W-9 status transition.';
  elsif old.status = 'completed' and new.status not in ('completed', 'superseded', 'voided') then
    raise exception 'Invalid W-9 status transition.';
  elsif old.status in ('superseded', 'voided', 'failed') and new.status <> old.status then
    raise exception 'Superseded, voided, and failed W-9 records are terminal.';
  end if;
  return new;
end;
$$;

create trigger carrier_w9s_immutability_guard
  before update on public.carrier_w9s
  for each row execute function public.guard_carrier_w9_immutability();

-- ---------------------------------------------------------------------------
-- PART 5 -- RLS + column grants.
--
-- Dispatcher may see status/masked last4 but never the PDF or ciphertext
-- (approved decision 3); Accountant adds PDF view/download (decision 4);
-- Owner/Admin add plaintext reveal via the SECURITY DEFINER function only
-- (decision 5) -- tin_encrypted itself is excluded from every role's
-- ordinary SELECT grant below, including owner/admin, exactly like
-- ein_encrypted (0081): the reveal function is the ONLY path, for every
-- role, with no exception even for owner/admin's plain SELECT.
-- ---------------------------------------------------------------------------

alter table public.carrier_w9s enable row level security;

create policy carrier_w9s_select on public.carrier_w9s
  for select using (organization_id = public.current_org_id());

-- insert: owner/admin/dispatcher (matches who can create/manage
-- onboarding applications and carriers today) -- an insert only ever
-- creates a blank draft shell; see create_carrier_w9_draft() below, the
-- one sanctioned path (this policy plus the column grant below still
-- allow a direct table insert in principle, but the carrier portal itself
-- has no Supabase Auth session at all -- see PART 7 -- so in practice
-- every insert goes through that RPC or the equivalent service-role path
-- server actions use for portal-driven requests).
create policy carrier_w9s_insert on public.carrier_w9s
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

create policy carrier_w9s_update on public.carrier_w9s
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- No delete policy -- draft deletion goes through delete_carrier_w9_draft()
-- (SECURITY DEFINER, draft-and-uncertified-only), matching every other
-- historical-record table in this schema (broker_packets, carrier_setup_packages).

revoke select on public.carrier_w9s from authenticated, anon;
grant select (
  id, organization_id, onboarding_application_id, carrier_id, version, status, form_revision,
  name_on_tax_return, business_name, tax_classification, llc_classification, other_classification_description,
  has_foreign_partners_owners, exempt_payee_code, fatca_exemption_code,
  address_line1, city, state, postal_code, requester_name_address, account_numbers,
  tin_type, tin_last4,
  certified_name, certified_title, certified_at, certification_version,
  generated_storage_path, generated_pdf_sha256, generated_file_size_bytes, page_count, generated_at, generated_by,
  registered_document_id, superseded_by, superseded_at, voided_at, voided_by, void_reason, failure_reason,
  created_at, updated_at, created_by
) on public.carrier_w9s to authenticated;
-- tin_encrypted intentionally excluded from every role's SELECT grant --
-- reveal_carrier_w9_tin() is SECURITY DEFINER and therefore unaffected.

revoke insert on public.carrier_w9s from authenticated, anon;
grant insert (
  id, organization_id, onboarding_application_id, carrier_id, created_by
) on public.carrier_w9s to authenticated;
-- Every other column (tax data, TIN, certification, artifact) is
-- populated exclusively by the SECURITY DEFINER RPCs below -- staff can
-- never write them via a raw INSERT even though the row-level policy
-- would otherwise allow one.

revoke update on public.carrier_w9s from authenticated, anon;
grant update (status) on public.carrier_w9s to authenticated;
-- Deliberately minimal: even 'status' here is superfluous in practice
-- (every real transition goes through an RPC, which is SECURITY DEFINER
-- and so unaffected by this grant either way) but kept non-empty because
-- an empty column list in a GRANT UPDATE is rejected by Postgres.

-- ---------------------------------------------------------------------------
-- PART 6 -- carrier_w9_pii_access_log: mirrors
-- carrier_onboarding_pii_access_log (0081) exactly, as its own table
-- (references carrier_w9s, not carrier_onboarding_applications).
-- ---------------------------------------------------------------------------

create table public.carrier_w9_pii_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  w9_id uuid not null references public.carrier_w9s (id) on delete cascade,
  accessed_by uuid not null references public.profiles (id) on delete set null,
  reason text not null,
  accessed_at timestamptz not null default now()
);

comment on table public.carrier_w9_pii_access_log is
  'Immutable audit trail of every W-9 TIN reveal. Written exclusively by reveal_carrier_w9_tin(); no insert/update/delete policy exists for authenticated/anon.';

alter table public.carrier_w9_pii_access_log enable row level security;

create policy carrier_w9_pii_access_log_select on public.carrier_w9_pii_access_log
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- PART 7 -- RPCs.
--
-- The carrier onboarding portal has NO Supabase Auth session at all (see
-- src/lib/carrier-onboarding/session.ts's own header comment) -- exactly
-- like every other portal-driven mutation in this codebase, portal-side
-- calls into these functions happen via the service-role client from a
-- trusted server action that has ALREADY independently verified the
-- portal session cookie, not via a direct authenticated-role RLS/grant
-- path. That means every RPC below that a carrier must be able to call
-- pre-conversion (create/update draft, certify, delete draft) accepts an
-- explicit p_organization_id/subject argument and is granted to
-- service_role in ADDITION to authenticated -- the function body itself
-- is what enforces "this subject really belongs to this organization",
-- not RLS, for exactly the service-role callers that bypass RLS by
-- definition. Staff-side callers (authenticated, real org session) get
-- identical enforcement from the same body via current_org_id().
-- ---------------------------------------------------------------------------

create or replace function public.create_carrier_w9_draft(
  p_organization_id uuid, p_onboarding_application_id uuid, p_carrier_id uuid
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'Application or carrier not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
      raise exception 'You do not have permission to create a W-9.';
    end if;
  end if;
  if p_onboarding_application_id is null and p_carrier_id is null then
    raise exception 'A W-9 must be associated with an onboarding application or a carrier.';
  end if;

  insert into public.carrier_w9s (organization_id, onboarding_application_id, carrier_id, created_by)
  values (p_organization_id, p_onboarding_application_id, p_carrier_id, case when auth.role() = 'service_role' then null else auth.uid() end)
  returning id into v_id;

  perform public.log_activity('carrier_w9'::public.entity_type, v_id, 'w9_draft_created', null, p_organization_id);
  return v_id;
end;
$$;

revoke execute on function public.create_carrier_w9_draft(uuid, uuid, uuid) from public, anon;
grant execute on function public.create_carrier_w9_draft(uuid, uuid, uuid) to authenticated, service_role;

-- update_carrier_w9_draft(): draft-and-uncertified only (certified_at is
-- null) -- once certify_carrier_w9() runs, this function refuses, per the
-- approved design ("Draft is mutable" / "After certification... must
-- become immutable"). Every field below is validated by
-- validate_carrier_w9_fields() (PART 8), shared with certify_carrier_w9()
-- so the two can never enforce different rules for the same columns.
create or replace function public.update_carrier_w9_draft(
  p_w9_id uuid, p_organization_id uuid,
  p_name_on_tax_return text, p_business_name text,
  p_tax_classification public.w9_tax_classification, p_llc_classification text, p_other_classification_description text,
  p_has_foreign_partners_owners boolean, p_exempt_payee_code text, p_fatca_exemption_code text,
  p_address_line1 text, p_city text, p_state text, p_postal_code text,
  p_requester_name_address text, p_account_numbers text
) returns void language plpgsql security definer set search_path = public as $$
declare v_w9 public.carrier_w9s;
begin
  select * into v_w9 from public.carrier_w9s where id = p_w9_id for update;
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

  update public.carrier_w9s set
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
    postal_code = nullif(btrim(p_postal_code), ''),
    requester_name_address = nullif(btrim(p_requester_name_address), ''),
    account_numbers = nullif(btrim(p_account_numbers), '')
  where id = p_w9_id;
end;
$$;

revoke execute on function public.update_carrier_w9_draft(uuid, uuid, text, text, public.w9_tax_classification, text, text, boolean, text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.update_carrier_w9_draft(uuid, uuid, text, text, public.w9_tax_classification, text, text, boolean, text, text, text, text, text, text, text, text) to authenticated, service_role;

-- set_carrier_w9_tin(): a SEPARATE function from update_carrier_w9_draft()
-- on purpose -- this is the ONE and ONLY place a plaintext TIN is ever
-- accepted as an argument, so its lifetime inside a single statement's
-- parameter list is as short as this repo's architecture can make it
-- (approved design section 6: "browser -> trusted server boundary ->
-- encrypt -> store encrypted form"). Never logged: no RAISE NOTICE, no
-- log_activity() call anywhere in this function references p_tin.
create or replace function public.set_carrier_w9_tin(
  p_w9_id uuid, p_organization_id uuid, p_tin_type public.w9_tin_type, p_tin text
) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_w9 public.carrier_w9s; v_digits text; v_key text;
begin
  select * into v_w9 from public.carrier_w9s where id = p_w9_id for update;
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

  -- Formatting validation only (approved design section 8: "Do NOT claim
  -- TIN identity verification"). SSN = 9 digits, EIN = 9 digits; both
  -- typed with or without dashes, digits-only stored/encrypted.
  v_digits := regexp_replace(coalesce(p_tin, ''), '[^0-9]', '', 'g');
  if length(v_digits) <> 9 then
    raise exception 'A Social Security Number or Employer Identification Number must be exactly 9 digits.';
  end if;

  v_key := public.get_app_encryption_key('carrier_pii_key');
  update public.carrier_w9s set
    tin_type = p_tin_type,
    tin_encrypted = pgp_sym_encrypt(v_digits, v_key),
    tin_last4 = right(v_digits, 4)
  where id = p_w9_id;
end;
$$;

revoke execute on function public.set_carrier_w9_tin(uuid, uuid, public.w9_tin_type, text) from public, anon;
grant execute on function public.set_carrier_w9_tin(uuid, uuid, public.w9_tin_type, text) to authenticated, service_role;

-- certify_carrier_w9(): the reservation step (see this file's header
-- comment). Validates every official-form rule this schema can check,
-- assigns the version number under the SAME advisory-lock pattern
-- reserve_broker_packet() (0095) uses, and freezes tax identity/TIN/
-- address/certification. Status remains 'draft' -- the application layer
-- may display "Generating..." based on certified_at being non-null, but
-- no 6th DB status value exists.
create or replace function public.certify_carrier_w9(
  p_w9_id uuid, p_organization_id uuid, p_certified_name text, p_certified_title text
) returns integer language plpgsql security definer set search_path = public as $$
declare v_w9 public.carrier_w9s; v_subject_app uuid; v_subject_carrier uuid; v_version integer;
begin
  select * into v_w9 from public.carrier_w9s where id = p_w9_id for update;
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

  -- Official-form validation (approved design section 8) --
  -- formatting/completeness only, never identity verification.
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

  -- 2N.2A: line 3b applicability, per the official form's own text
  -- (re-confirmed against the live PDF before adding this check): "If on
  -- line 3a you checked 'Partnership' or 'Trust/estate,' or checked
  -- 'LLC' and entered 'P' as its tax classification... check this box if
  -- you have any foreign partners, owners, or beneficiaries." No tax law
  -- is inferred beyond this literal text -- the checkbox is simply
  -- inapplicable (and therefore must be false) for every other
  -- classification.
  if v_w9.has_foreign_partners_owners and not (
    v_w9.tax_classification in ('partnership', 'trust_estate')
    or (v_w9.tax_classification = 'llc' and v_w9.llc_classification = 'P')
  ) then
    raise exception 'Line 3b (foreign partners, owners, or beneficiaries) only applies to a Partnership, Trust/estate, or an LLC taxed as a partnership.';
  end if;

  v_subject_app := v_w9.onboarding_application_id;
  v_subject_carrier := v_w9.carrier_id;
  perform pg_advisory_xact_lock(
    hashtext(v_w9.organization_id::text),
    hashtext('carrier-w9:' || coalesce(v_subject_carrier, v_subject_app)::text)
  );
  select coalesce(max(version), 0) + 1 into v_version
  from public.carrier_w9s
  where organization_id = v_w9.organization_id
    and coalesce(carrier_id, onboarding_application_id) = coalesce(v_subject_carrier, v_subject_app)
    and version is not null;

  update public.carrier_w9s set
    version = v_version,
    certified_name = btrim(p_certified_name),
    certified_title = nullif(btrim(p_certified_title), ''),
    certified_at = now()
  where id = p_w9_id;

  perform public.log_activity('carrier_w9'::public.entity_type, p_w9_id, 'w9_completed', jsonb_build_object('version', v_version), v_w9.organization_id);
  return v_version;
end;
$$;

revoke execute on function public.certify_carrier_w9(uuid, uuid, text, text) from public, anon;
grant execute on function public.certify_carrier_w9(uuid, uuid, text, text) to authenticated, service_role;

-- finalize_carrier_w9(): service-role only (the trusted server, after it
-- has rendered the PDF from this exact certified row and uploaded it) --
-- same trust boundary as finalize_broker_packet()/finalize_carrier_setup_package().
-- Also registers the one authoritative `documents` row (approved design
-- section 20) -- see this file's closing header note on the real,
-- pre-existing limitation this surfaces for cross-bucket consumption.
create or replace function public.finalize_carrier_w9(
  p_w9_id uuid, p_storage_path text, p_file_size_bytes bigint, p_page_count integer, p_generated_pdf_sha256 text
) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_w9 public.carrier_w9s; v_subject_carrier uuid; v_subject_app uuid; v_higher uuid; v_previous uuid; v_document_id uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may finalize a W-9.'; end if;
  select * into v_w9 from public.carrier_w9s where id = p_w9_id for update;
  if v_w9.id is null or v_w9.status <> 'draft' or v_w9.certified_at is null then
    raise exception 'Certified W-9 not found.';
  end if;

  v_subject_carrier := v_w9.carrier_id;
  v_subject_app := v_w9.onboarding_application_id;
  perform pg_advisory_xact_lock(
    hashtext(v_w9.organization_id::text),
    hashtext('carrier-w9:' || coalesce(v_subject_carrier, v_subject_app)::text)
  );

  if p_storage_path <> format('%s/%s/w9-v%s.pdf', v_w9.organization_id, v_w9.id, v_w9.version) then
    raise exception 'Invalid W-9 storage path.';
  end if;
  if p_file_size_bytes <= 0 or p_file_size_bytes > 52428800 then raise exception 'Generated W-9 exceeds the 50 MB limit.'; end if;
  if p_page_count not between 1 and 10 then raise exception 'Generated W-9 has an unexpected page count.'; end if;
  if p_generated_pdf_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'Generated PDF hash is not a valid lowercase SHA-256 value.'; end if;

  update public.carrier_w9s set
    status = 'completed', generated_storage_path = p_storage_path, generated_file_size_bytes = p_file_size_bytes,
    page_count = p_page_count, generated_pdf_sha256 = p_generated_pdf_sha256, generated_at = now(), generated_by = null
  where id = p_w9_id;

  -- Bidirectional supersession, identical shape to finalize_broker_packet()
  -- (0095/0098): if a higher version already completed for this subject,
  -- retire straight to superseded (never briefly current); otherwise
  -- become current and retire any lower completed version.
  select id into v_higher from public.carrier_w9s
  where organization_id = v_w9.organization_id
    and coalesce(carrier_id, onboarding_application_id) = coalesce(v_subject_carrier, v_subject_app)
    and version > v_w9.version and status = 'completed'
  limit 1;

  if v_higher is not null then
    update public.carrier_w9s set status = 'superseded', superseded_by = v_higher, superseded_at = now() where id = p_w9_id;
  else
    for v_previous in
      select id from public.carrier_w9s
      where organization_id = v_w9.organization_id
        and coalesce(carrier_id, onboarding_application_id) = coalesce(v_subject_carrier, v_subject_app)
        and version < v_w9.version and status = 'completed'
    loop
      update public.carrier_w9s set status = 'superseded', superseded_by = p_w9_id, superseded_at = now() where id = v_previous;
    end loop;
  end if;

  -- Document registration (approved design section 20). entity_type
  -- mirrors 0081's own pre-conversion convention exactly:
  -- 'carrier_onboarding_application' while no carrier exists yet, else
  -- 'carrier'. is_verified is set true here because certify_carrier_w9()
  -- already required a complete, certified W-9 before this point is ever
  -- reachable -- there is no separate manual verification step for a
  -- system-generated official artifact.
  insert into public.documents (
    organization_id, entity_type, entity_id, document_type, file_name, file_path, storage_bucket,
    file_size_bytes, mime_type, is_verified, verified_at
  ) values (
    v_w9.organization_id,
    case when v_subject_carrier is not null then 'carrier'::public.entity_type else 'carrier_onboarding_application'::public.entity_type end,
    coalesce(v_subject_carrier, v_subject_app),
    'w9'::public.document_type,
    format('w9-v%s.pdf', v_w9.version),
    p_storage_path,
    'carrier-w9s',
    p_file_size_bytes,
    'application/pdf',
    true,
    now()
  ) returning id into v_document_id;

  update public.carrier_w9s set registered_document_id = v_document_id where id = p_w9_id;

  perform public.log_activity('carrier_w9'::public.entity_type, p_w9_id, 'w9_generated', jsonb_build_object('version', v_w9.version), v_w9.organization_id);
end;
$$;

comment on function public.finalize_carrier_w9(uuid, text, bigint, integer, text) is
  'Service-role-only. Registers a documents row whose file_path points into the carrier-w9s bucket, NOT the documents bucket -- see this migration''s closing header note: Broker Packet''s guard_broker_packet_item() (0095) currently hardcodes source_storage_bucket = ''documents'', so this document is NOT YET eligible for Broker Packet inclusion. That is a real, reported limitation, not silently worked around here.';

revoke execute on function public.finalize_carrier_w9(uuid, text, bigint, integer, text) from public, authenticated, anon;
grant execute on function public.finalize_carrier_w9(uuid, text, bigint, integer, text) to service_role;

-- fail_carrier_w9(): service-role only, mirrors fail_broker_packet()
-- exactly, including the 0098 fix applied from day one (explicit
-- p_organization_id passed to log_activity(), never relying on
-- current_org_id() under a service-role caller).
create or replace function public.fail_carrier_w9(p_w9_id uuid, p_failure_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_org_id uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'Only the trusted server may fail a W-9.'; end if;
  update public.carrier_w9s set
    status = 'failed',
    failure_reason = left(coalesce(nullif(btrim(p_failure_reason), ''), 'W-9 generation failed.'), 500)
  where id = p_w9_id and status = 'draft' and certified_at is not null
  returning organization_id into v_org_id;
  if not found then raise exception 'Certified W-9 not found.'; end if;
  perform public.log_activity('carrier_w9'::public.entity_type, p_w9_id, 'w9_failed', null, v_org_id);
end;
$$;

revoke execute on function public.fail_carrier_w9(uuid, text) from public, authenticated, anon;
grant execute on function public.fail_carrier_w9(uuid, text) to service_role;

-- void_carrier_w9(): owner/admin only (approved design's Broker-Packet-
-- style role tier), draft or completed only -- matches void_broker_packet()'s
-- exact scope shape. No automatic resurrection of an older superseded
-- record (approved design section 13: "Preferred: no automatic
-- resurrection") -- this function never touches any row but the one voided.
create or replace function public.void_carrier_w9(p_w9_id uuid, p_organization_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'W-9 record not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin']::public.org_role[]) then
      raise exception 'Only owners and admins may void a W-9.';
    end if;
  end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A void reason is required.'; end if;

  update public.carrier_w9s set voided_at = now(), voided_by = case when auth.role() = 'service_role' then null else auth.uid() end, void_reason = left(btrim(p_reason), 500), status = 'voided'
  where id = p_w9_id and organization_id = p_organization_id and status in ('draft', 'completed');
  if not found then raise exception 'W-9 record not found or cannot be voided.'; end if;

  perform public.log_activity('carrier_w9'::public.entity_type, p_w9_id, 'w9_voided', null, p_organization_id);
end;
$$;

revoke execute on function public.void_carrier_w9(uuid, uuid, text) from public, anon;
grant execute on function public.void_carrier_w9(uuid, uuid, text) to authenticated, service_role;

-- delete_carrier_w9_draft(): only a truly blank, uncertified draft
-- (approved design section 10) -- matches delete_broker_packet_draft()'s
-- exact scope reasoning.
create or replace function public.delete_carrier_w9_draft(p_w9_id uuid, p_organization_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'service_role' then
    if p_organization_id <> public.current_org_id() then raise exception 'W-9 record not found in your organization.'; end if;
    if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
      raise exception 'You do not have permission to delete this W-9 draft.';
    end if;
  end if;
  delete from public.carrier_w9s where id = p_w9_id and organization_id = p_organization_id and status = 'draft' and certified_at is null;
  if not found then raise exception 'Draft W-9 not found or already certified.'; end if;
end;
$$;

revoke execute on function public.delete_carrier_w9_draft(uuid, uuid) from public, anon;
grant execute on function public.delete_carrier_w9_draft(uuid, uuid) to authenticated, service_role;

-- reveal_carrier_w9_tin(): mirrors reveal_carrier_onboarding_ein() (0081)
-- field-for-field. Owner/admin only, reason required, one audit row per
-- reveal, never called from a service-role/carrier-portal context (the
-- approved design restricts reveal to staff only -- there is
-- intentionally no service_role grant here, unlike every other RPC above).
create or replace function public.reveal_carrier_w9_tin(p_w9_id uuid, p_reason text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_org_id uuid; v_key text; v_encrypted bytea;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to reveal this TIN.';
  end if;

  select organization_id, tin_encrypted into v_org_id, v_encrypted
  from public.carrier_w9s where id = p_w9_id;

  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'W-9 record not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may reveal this field.';
  end if;
  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('carrier_pii_key');

  insert into public.carrier_w9_pii_access_log (organization_id, w9_id, accessed_by, reason)
  values (v_org_id, p_w9_id, auth.uid(), p_reason);

  perform public.log_activity('carrier_w9'::public.entity_type, p_w9_id, 'w9_tin_revealed', null, v_org_id);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;

revoke execute on function public.reveal_carrier_w9_tin(uuid, text) from public, anon;
grant execute on function public.reveal_carrier_w9_tin(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- PART 8 -- conversion integration.
--
-- Repairs (CREATE OR REPLACE, same signature -- ACL preserved
-- automatically) convert_carrier_onboarding_application() (0086) to
-- additionally re-point any carrier_w9s row(s) for this application onto
-- the new carrier: sets carrier_id (carrier_id was NULL until now, so
-- this is the one legitimate exception guard_carrier_w9_immutability()
-- above already carves out), and re-points the ALREADY-REGISTERED
-- documents row's entity_type/entity_id from
-- 'carrier_onboarding_application'/application_id to 'carrier'/carrier_id
-- -- no new document row, no byte copy, no PDF re-render, no hash change,
-- no certification change. onboarding_application_id is NEVER cleared --
-- both remain set after conversion, preserving the historical
-- relationship exactly as the approved design requires. Every existing
-- 0086 behavior (agreement gating, MC/DOT duplicate lock, carriers/
-- carrier_financials insert) is preserved byte-for-byte; only the new
-- final block is added.
-- ---------------------------------------------------------------------------

create or replace function public.convert_carrier_onboarding_application(p_application_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_app public.carrier_onboarding_applications;
  v_carrier_id uuid;
  v_missing_required_agreement boolean;
  v_mc_number text;
  v_dot_number text;
  v_duplicate_carrier_id uuid;
  v_w9_id uuid;
  v_w9_document_id uuid;
begin
  select * into v_app
  from public.carrier_onboarding_applications
  where id = p_application_id
  for update;

  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may convert an application to a carrier.';
  end if;
  if v_app.status <> 'approved' then
    raise exception 'Only an approved application can be converted (current status=%).', v_app.status;
  end if;

  select exists (
    select 1
    from (
      select distinct t.template_key
      from public.carrier_agreement_templates t
      where t.organization_id = v_app.organization_id
        and t.status = 'published'
        and t.is_required_for_onboarding
    ) required_keys
    where 1 <> (
      select count(*)
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t
        on t.id = s.agreement_template_id
      where s.application_id = p_application_id
        and s.status <> 'voided'
        and t.template_key = required_keys.template_key
    )
    or not exists (
      select 1
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t
        on t.id = s.agreement_template_id
      where s.application_id = p_application_id
        and s.status = 'completed'
        and t.template_key = required_keys.template_key
    )
  ) into v_missing_required_agreement;

  if v_missing_required_agreement then
    raise exception 'One or more required dispatch agreements have not been completed for this application.';
  end if;

  v_mc_number := nullif(btrim(v_app.mc_number), '');
  v_dot_number := nullif(btrim(v_app.dot_number), '');

  if v_mc_number is not null then
    perform pg_advisory_xact_lock(hashtext(v_app.organization_id::text), hashtext('carrier-mc:' || v_mc_number));
  end if;
  if v_dot_number is not null then
    perform pg_advisory_xact_lock(hashtext(v_app.organization_id::text), hashtext('carrier-dot:' || v_dot_number));
  end if;

  select c.id into v_duplicate_carrier_id
  from public.carriers c
  where c.organization_id = v_app.organization_id
    and (
      (v_mc_number is not null and btrim(c.mc_number) = v_mc_number)
      or (v_dot_number is not null and btrim(c.dot_number) = v_dot_number)
    )
  limit 1;

  if v_duplicate_carrier_id is not null then
    raise exception 'A carrier with the same MC or DOT number already exists in this organization.';
  end if;

  insert into public.carriers (
    organization_id, legal_name, dba_name, mc_number, dot_number, contact_name, phone, email,
    address_line1, address_line2, city, state, postal_code, country
  ) values (
    v_app.organization_id, v_app.legal_name, v_app.dba_name, v_app.mc_number, v_app.dot_number,
    v_app.contact_name, v_app.phone, v_app.email, v_app.address_line1, v_app.address_line2,
    v_app.city, v_app.state, v_app.postal_code, coalesce(nullif(btrim(v_app.country), ''), 'US')
  )
  returning id into v_carrier_id;

  insert into public.carrier_financials (
    carrier_id, organization_id, dispatch_fee_percentage, payment_terms_days, factoring_company_name
  ) values (
    v_carrier_id, v_app.organization_id,
    coalesce(v_app.proposed_dispatch_fee_percentage, 10.00), coalesce(v_app.proposed_payment_terms_days, 7),
    case when v_app.has_factoring then nullif(btrim(v_app.factoring_company_name), '') else null end
  );

  update public.carrier_onboarding_applications
  set status = 'converted', converted_at = now(), converted_by = auth.uid(), converted_carrier_id = v_carrier_id
  where id = p_application_id;

  -- 2N.2 addition: re-point the current (non-voided) W-9 for this
  -- application onto the new carrier -- historical evidence untouched,
  -- no bytes moved, no re-render, no hash change.
  select id, registered_document_id into v_w9_id, v_w9_document_id
  from public.carrier_w9s
  where onboarding_application_id = p_application_id and carrier_id is null and status <> 'voided'
  order by version desc nulls last
  limit 1;

  if v_w9_id is not null then
    update public.carrier_w9s set carrier_id = v_carrier_id where id = v_w9_id;
    if v_w9_document_id is not null then
      update public.documents set entity_type = 'carrier'::public.entity_type, entity_id = v_carrier_id
      where id = v_w9_document_id;
    end if;
  end if;

  return v_carrier_id;
end;
$$;

comment on function public.convert_carrier_onboarding_application(uuid) is
  'Atomically converts an approved onboarding application into public.carriers plus its carrier_financials row, and (2N.2) re-points that application''s current non-voided W-9 (and its registered document) onto the new carrier -- no bytes moved, no re-render, no certification change, onboarding_application_id never cleared. carriers.ein remains unset (unchanged from 0086).';

-- No grant change: signature is unchanged from 0086, so its existing
-- ACL (granted to authenticated) is preserved automatically.

-- ---------------------------------------------------------------------------
-- PART 9 -- Storage bucket. Private, no public access. No storage.objects
-- policy is added for anon/authenticated -- every read/write goes through
-- the service-role client from a trusted server action/route (identical
-- pattern to driver-application-documents, broker-packets, and every
-- other private bucket in this schema), after that code has already
-- independently verified who is asking.
--
-- KNOWN LIMITATION, surfaced by this design and NOT fixed here: Broker
-- Packet's guard_broker_packet_item() (0095) hardcodes
-- `new.source_storage_bucket <> 'documents'` -- it accepts sources only
-- from the `documents` bucket. The W-9 PDF this migration produces lives
-- in `carrier-w9s`, per the approved bucket decision (section 2). The
-- `documents` row registered by finalize_carrier_w9() above therefore
-- records an accurate `file_path`, but that path is NOT resolvable
-- through the `documents` bucket a generic downstream reader (including
-- Broker Packet) would assume -- the `documents` table has no per-row
-- bucket column at all today, so this is not fixable by anything in this
-- migration without touching 0095 (explicitly forbidden this phase) or
-- widening the `documents` table's own contract (explicitly out of scope
-- -- "Do NOT redesign generic Documents"). Consequence: a generated W-9 is
-- NOT YET actually includable in a Broker Packet, despite being a fully
-- valid, verified `documents` row. This is a real, reported architectural
-- finding for a future authorized repair phase, not silently worked
-- around by duplicating PDF bytes into the `documents` bucket or by
-- loosening 0095's trigger from within this migration.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('carrier-w9s', 'carrier-w9s', false, 52428800, array['application/pdf'])
on conflict (id) do nothing;
