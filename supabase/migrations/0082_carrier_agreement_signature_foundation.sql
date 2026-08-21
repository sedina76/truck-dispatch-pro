-- =============================================================================
-- 0082_carrier_agreement_signature_foundation.sql
-- Phase 2L.3: Carrier agreement, typed initials, and electronic signature
-- DATABASE FOUNDATION.
-- PROPOSED ONLY -- NOT APPLIED.
--
-- Five tables, per the approved Phase 2L.3 design report (reduced from
-- the seven candidate objects originally listed -- two combinations, each
-- justified in this file's own comments below):
--   1. carrier_agreement_templates  -- combines "template" + "version":
--      one row per version, linked by template_key/version_number.
--   2. carrier_agreement_clauses    -- child rows of a template version.
--   3. carrier_agreement_signings   -- combines "signing instance" +
--      "signature": permanently 1:1, so one row with nullable
--      signature/consent fields until completion.
--   4. carrier_agreement_initials   -- kept separate (per-clause
--      enforceability/timestamps a JSONB blob on signings couldn't give).
--   5. carrier_agreement_audit_events -- dedicated, append-only evidence
--      trail, deliberately NOT the general log_activity() (which has no
--      DB-level immutability guarantee) -- mirrors
--      carrier_onboarding_pii_access_log (0081) exactly.
--
-- Everything in this file is either schema, RLS, a guard trigger, or a
-- pure read-only helper function (compute_carrier_agreement_content_
-- hash()). Per the approved design, NO business-mutation RPC is written
-- here -- assign_carrier_agreement(), record_carrier_agreement_initial(),
-- and complete_carrier_agreement_signing() are all fully specified in the
-- design report but deliberately deferred, mirroring exactly how 0081
-- deferred submit_carrier_onboarding_application()/convert_carrier_
-- onboarding_application(). No portal UI, no staff UI, no PDF generation,
-- no application-submission gating, no carrier conversion, no Setup
-- Package generation, no email. 0081 is not modified.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- PART 1 -- enum additions/creations.
-- ---------------------------------------------------------------------------

-- The eventual generated signed-agreement PDF (a later checkpoint) will
-- register as entity_type='carrier_onboarding_application' with this
-- document_type -- additive, existing values untouched.
alter type public.document_type add value if not exists 'signed_agreement';

create type public.carrier_agreement_template_status as enum ('draft', 'published', 'retired');
create type public.carrier_agreement_signing_status as enum ('assigned', 'in_progress', 'completed', 'voided');
-- Single value today, by design -- typed initials/signatures only.
-- Extensible later (e.g. 'drawn') via alter type ... add value, with zero
-- table redesign, exactly like every other enum in this schema.
create type public.carrier_agreement_signature_type as enum ('typed');
create type public.carrier_agreement_actor_type as enum ('staff', 'carrier_signer');

-- ---------------------------------------------------------------------------
-- PART 2 -- carrier_agreement_templates. Row-per-version: template_key
-- stays stable across versions, version_number increments; there is no
-- separate mutable "template" wrapper row, since the "replace = a new
-- immutable row" convention already established by public.documents and
-- driver_applications applies equally well here -- a version IS a
-- complete, self-contained template row.
-- ---------------------------------------------------------------------------

create table public.carrier_agreement_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  template_key text not null,
  version_number integer not null,
  name text not null,
  description text,
  status public.carrier_agreement_template_status not null default 'draft',
  is_required_for_onboarding boolean not null default false,
  requires_signer_title boolean not null default true,
  content_hash text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  published_by uuid references public.profiles (id) on delete set null,
  unique (organization_id, template_key, version_number)
);

comment on table public.carrier_agreement_templates is
  'One row per agreement version (template_key stable across versions, version_number increments). A published/retired row is permanently immutable except for the status column itself -- see guard_carrier_agreement_template_immutability(). Editing content after publish means creating a NEW row (new id, same template_key, version_number + 1, status=draft), never editing this one.';

comment on column public.carrier_agreement_templates.content_hash is
  'SHA-256 hex digest of this version''s own identity + every clause, computed via compute_carrier_agreement_content_hash() once, at publish time (while status is still draft, so the immutability guard does not block setting it). Never recomputed after -- the content it covers cannot change.';

drop trigger if exists set_updated_at on public.carrier_agreement_templates;
create trigger set_updated_at before update on public.carrier_agreement_templates
  for each row execute function public.set_updated_at();

-- Immutability + terminal-status guard. Fires on every UPDATE and DELETE
-- (not scoped to a WHEN clause on status changes only) because content
-- immutability must hold for ANY attempted change while not draft, not
-- just a status change.
create or replace function public.guard_carrier_agreement_template_immutability()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'Cannot delete a published or retired agreement template -- its history must be preserved.';
    end if;
    return old;
  end if;

  -- UPDATE path. Draft rows are freely editable (this is also the ONLY
  -- path that may set content_hash/published_at/published_by, since it's
  -- the draft -> published transition itself).
  if old.status = 'draft' then
    return new;
  end if;

  -- Not draft: every column except `status` must be byte-identical to
  -- OLD. published_at/published_by are deliberately included in this
  -- check, not exempted -- they are set exactly once, during the
  -- draft -> published transition above, and never touched again.
  if new.organization_id is distinct from old.organization_id
    or new.template_key is distinct from old.template_key
    or new.version_number is distinct from old.version_number
    or new.name is distinct from old.name
    or new.description is distinct from old.description
    or new.is_required_for_onboarding is distinct from old.is_required_for_onboarding
    or new.requires_signer_title is distinct from old.requires_signer_title
    or new.content_hash is distinct from old.content_hash
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
    or new.published_at is distinct from old.published_at
    or new.published_by is distinct from old.published_by
  then
    raise exception 'Cannot modify a published or retired agreement template -- create a new version instead.';
  end if;

  -- The only legal status transition once published is -> retired.
  -- retired is terminal (no further status change at all).
  if old.status = 'published' and new.status not in ('published', 'retired') then
    raise exception 'Invalid agreement template status transition: % -> %', old.status, new.status;
  end if;
  if old.status = 'retired' and new.status <> 'retired' then
    raise exception 'A retired agreement template cannot change status again.';
  end if;

  return new;
end;
$$;

drop trigger if exists carrier_agreement_templates_immutability_guard on public.carrier_agreement_templates;
create trigger carrier_agreement_templates_immutability_guard
  before update or delete on public.carrier_agreement_templates
  for each row execute function public.guard_carrier_agreement_template_immutability();

alter table public.carrier_agreement_templates enable row level security;

create policy carrier_agreement_templates_select on public.carrier_agreement_templates
  for select using (organization_id = public.current_org_id());

create policy carrier_agreement_templates_insert on public.carrier_agreement_templates
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy carrier_agreement_templates_update on public.carrier_agreement_templates
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- RLS-level delete is further restricted to draft-only -- redundant with
-- (not a replacement for) the trigger's own DELETE guard above, which
-- applies regardless of caller (including a future service-role RPC).
-- Belt-and-suspenders is deliberate here, matching this migration's own
-- "use guard triggers, do not rely on UI/RLS enforcement alone" mandate.
create policy carrier_agreement_templates_delete on public.carrier_agreement_templates
  for delete using (
    organization_id = public.current_org_id()
    and status = 'draft'
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- PART 3 -- carrier_agreement_clauses.
-- ---------------------------------------------------------------------------

create table public.carrier_agreement_clauses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  agreement_template_id uuid not null references public.carrier_agreement_templates (id) on delete cascade,
  clause_key text not null,
  title text not null,
  body text not null,
  display_order integer not null default 0,
  requires_initials boolean not null default false,
  created_at timestamptz not null default now(),
  unique (agreement_template_id, clause_key)
);

comment on table public.carrier_agreement_clauses is
  'Plain/markdown-safe clause text, never raw HTML (rendered as text by any future UI, same discipline as dispatch_messages.body). A clause requiring initials becomes impossible to satisfy without a real carrier_agreement_initials row -- enforced by a future completion RPC via an anti-join, not by this table alone.';

-- Combines two checks in one pass (both needing the same parent-template
-- lookup): (1) organization_id consistency -- an ordinary FK proves
-- agreement_template_id references a REAL template row, never that its
-- organization_id agrees with this clause's own; (2) immutability -- no
-- insert/update/delete once the parent template has left draft.
create or replace function public.guard_carrier_agreement_clause_immutability()
returns trigger
language plpgsql
as $$
declare
  v_template_status public.carrier_agreement_template_status;
  v_template_org uuid;
  v_check_template_id uuid;
  v_check_org uuid;
begin
  v_check_template_id := coalesce(new.agreement_template_id, old.agreement_template_id);
  v_check_org := coalesce(new.organization_id, old.organization_id);

  select status, organization_id into v_template_status, v_template_org
  from public.carrier_agreement_templates where id = v_check_template_id;

  if v_template_org is null or v_template_org <> v_check_org then
    raise exception 'Clause organization must match its agreement template''s organization.';
  end if;

  if v_template_status is distinct from 'draft' then
    raise exception 'Cannot modify clauses on a published or retired agreement template -- create a new version instead.';
  end if;

  if TG_OP = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists carrier_agreement_clauses_immutability_guard on public.carrier_agreement_clauses;
create trigger carrier_agreement_clauses_immutability_guard
  before insert or update or delete on public.carrier_agreement_clauses
  for each row execute function public.guard_carrier_agreement_clause_immutability();

alter table public.carrier_agreement_clauses enable row level security;

create policy carrier_agreement_clauses_select on public.carrier_agreement_clauses
  for select using (organization_id = public.current_org_id());

create policy carrier_agreement_clauses_insert on public.carrier_agreement_clauses
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy carrier_agreement_clauses_update on public.carrier_agreement_clauses
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy carrier_agreement_clauses_delete on public.carrier_agreement_clauses
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- PART 4 -- carrier_agreement_signings. Combines "signing instance" +
-- "signature": a permanent 1:1 relationship (a voided instance is never
-- reused for a redo -- a new signing gets a new row, preserving the
-- voided one's evidence), so every signature/consent field below is
-- simply nullable until completion.
-- ---------------------------------------------------------------------------

create table public.carrier_agreement_signings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  application_id uuid not null references public.carrier_onboarding_applications (id) on delete cascade,
  -- restrict, not cascade: a template with any real signing history must
  -- never be deletable at all (defense in depth alongside the template's
  -- own draft-only delete guard in Part 2).
  agreement_template_id uuid not null references public.carrier_agreement_templates (id) on delete restrict,
  status public.carrier_agreement_signing_status not null default 'assigned',
  assigned_at timestamptz not null default now(),
  assigned_by uuid references public.profiles (id) on delete set null,
  opened_at timestamptz,
  completed_at timestamptz,
  -- Copied from the template at assignment -- an independent, defensive
  -- snapshot specific to this signing event (see compute_carrier_
  -- agreement_content_hash()); the template's own content_hash should
  -- always agree, since the template is immutable from the moment it's
  -- published, but this signing keeps its own copy regardless.
  content_hash text,
  -- Computed server-side by the future completion RPC -- never accepted
  -- from a browser. NOT computed in this migration (see Part 6/Part 7).
  evidence_hash text,
  signer_name text,
  signer_title text,
  signature_type public.carrier_agreement_signature_type,
  typed_signature text,
  consent_text_version text,
  consent_accepted_at timestamptz,
  signed_at timestamptz,
  ip_address text,
  user_agent text,
  voided_at timestamptz,
  voided_by uuid references public.profiles (id) on delete set null,
  voided_reason text,
  -- Set later, once a future phase generates the signed PDF -- see Part 8
  -- (deliberately exempted from the completed-immutability guard below).
  generated_document_id uuid references public.documents (id) on delete set null
);

comment on table public.carrier_agreement_signings is
  'One row per (application, agreement_template) signing -- combines "signing instance" and "signature" into a single permanently-1:1 row. Immutable once status=completed except for status/voided_at/voided_by/voided_reason -- see guard_carrier_agreement_signing_completed_immutability(). Completion itself has no direct staff UPDATE path (see the update RLS policy below); only a future SECURITY DEFINER RPC (complete_carrier_agreement_signing(), deferred) can reach status=completed.';

-- Cross-org guard: an ordinary FK proves application_id/agreement_
-- template_id reference real rows, never that their organization_id
-- agrees with this signing's own.
create or replace function public.guard_carrier_agreement_signing_org()
returns trigger
language plpgsql
as $$
declare
  v_application_org uuid;
  v_template_org uuid;
begin
  select organization_id into v_application_org from public.carrier_onboarding_applications where id = new.application_id;
  select organization_id into v_template_org from public.carrier_agreement_templates where id = new.agreement_template_id;

  if v_application_org is null or v_application_org <> new.organization_id then
    raise exception 'Signing organization must match its application''s organization.';
  end if;
  if v_template_org is null or v_template_org <> new.organization_id then
    raise exception 'Signing organization must match its agreement template''s organization.';
  end if;

  return new;
end;
$$;

drop trigger if exists carrier_agreement_signings_guard_org on public.carrier_agreement_signings;
create trigger carrier_agreement_signings_guard_org
  before insert on public.carrier_agreement_signings
  for each row execute function public.guard_carrier_agreement_signing_org();

-- Status-transition guard -- the exact approved graph, same pattern
-- already proven exhaustively (56/56 transitions) for
-- carrier_onboarding_application_status in 0081/2L.2.
create or replace function public.guard_carrier_agreement_signing_status_transition()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'assigned' and new.status in ('in_progress', 'voided') then
    return new;
  elsif old.status = 'in_progress' and new.status in ('completed', 'voided') then
    return new;
  elsif old.status = 'completed' and new.status = 'voided' then
    return new;
  else
    raise exception 'Invalid carrier agreement signing status transition: % -> %', old.status, new.status;
  end if;
end;
$$;

drop trigger if exists carrier_agreement_signings_status_guard on public.carrier_agreement_signings;
create trigger carrier_agreement_signings_status_guard
  before update on public.carrier_agreement_signings
  for each row
  when (old.status is distinct from new.status)
  execute function public.guard_carrier_agreement_signing_status_transition();

-- Completed-signing immutability guard. Fires on every UPDATE (not
-- scoped to status changes only) once old.status='completed' -- voiding
-- a completed signature must add void metadata, never alter what was
-- actually signed. generated_document_id is deliberately exempted: a
-- future PDF-generation phase sets it AFTER completion, and that is a
-- legitimate, expected mutation of a completed row -- everything else on
-- this list is real evidentiary content and must never change again.
create or replace function public.guard_carrier_agreement_signing_completed_immutability()
returns trigger
language plpgsql
as $$
begin
  if old.status <> 'completed' then
    return new;
  end if;

  if new.organization_id is distinct from old.organization_id
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
    or new.user_agent is distinct from old.user_agent
  then
    raise exception 'A completed agreement signing is immutable -- only status/voided_at/voided_by/voided_reason (voiding) or generated_document_id (later PDF registration) may change.';
  end if;

  return new;
end;
$$;

drop trigger if exists carrier_agreement_signings_completed_immutability_guard on public.carrier_agreement_signings;
create trigger carrier_agreement_signings_completed_immutability_guard
  before update on public.carrier_agreement_signings
  for each row execute function public.guard_carrier_agreement_signing_completed_immutability();

alter table public.carrier_agreement_signings enable row level security;

create policy carrier_agreement_signings_select on public.carrier_agreement_signings
  for select using (organization_id = public.current_org_id());

-- assign: owner/admin/dispatcher -- matches who can already create
-- onboarding invitations (0081).
create policy carrier_agreement_signings_insert on public.carrier_agreement_signings
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- update: owner/admin only, and the with-check clause restricts what
-- this policy can actually ACHIEVE to status='voided' -- an owner/admin
-- cannot use this policy to drive a row to in_progress or completed
-- themselves (both remain topologically legal per the status-transition
-- trigger above, which would otherwise allow it). Completion specifically
-- requires validating carrier-entered evidence (initials, consent,
-- signature) that no RLS policy can express -- only a future SECURITY
-- DEFINER RPC, which bypasses RLS entirely, may ever set status=
-- completed. This is the concrete mechanism behind this table's own
-- comment ("no direct staff UPDATE path to completed").
create policy carrier_agreement_signings_update on public.carrier_agreement_signings
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (
    organization_id = public.current_org_id()
    and status = 'voided'
  );

-- ---------------------------------------------------------------------------
-- PART 5 -- carrier_agreement_initials.
-- ---------------------------------------------------------------------------

create table public.carrier_agreement_initials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  signing_instance_id uuid not null references public.carrier_agreement_signings (id) on delete cascade,
  -- restrict, not cascade: a clause with recorded initials must never be
  -- capable of disappearing via a cascading delete (defense in depth --
  -- the clause immutability guard in Part 3 already prevents deleting a
  -- published clause at all).
  clause_id uuid not null references public.carrier_agreement_clauses (id) on delete restrict,
  typed_initials text not null,
  entered_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  ip_address text,
  user_agent text,
  unique (signing_instance_id, clause_id)
);

comment on table public.carrier_agreement_initials is
  'Typed initials as text evidence -- never a generated handwritten-style image. At most one row per (signing_instance, clause); may be inserted/corrected only while its signing instance is assigned or in_progress -- see guard_carrier_agreement_initial_consistency(). No insert/update policy exists for any staff role -- written exclusively by a future SECURITY DEFINER workflow RPC (record_carrier_agreement_initial(), deferred), mirroring driver_applications'' own "no insert policy, RPC only" precedent (0018).';

drop trigger if exists set_updated_at on public.carrier_agreement_initials;
create trigger set_updated_at before update on public.carrier_agreement_initials
  for each row execute function public.set_updated_at();

-- Combines two checks that both need the same signing-instance/clause
-- lookup: (1) cross-template consistency -- the clause must belong to
-- the SAME agreement_template_id the signing instance references, and
-- organization_id must agree across signing/clause/initial; (2) pre-
-- completion editability -- an initial may only be inserted/corrected
-- while its signing instance is assigned or in_progress; once completed
-- or voided, immutable.
create or replace function public.guard_carrier_agreement_initial_consistency()
returns trigger
language plpgsql
as $$
declare
  v_signing_org uuid;
  v_signing_template uuid;
  v_signing_status public.carrier_agreement_signing_status;
  v_clause_org uuid;
  v_clause_template uuid;
begin
  select organization_id, agreement_template_id, status
    into v_signing_org, v_signing_template, v_signing_status
  from public.carrier_agreement_signings where id = new.signing_instance_id;

  select organization_id, agreement_template_id
    into v_clause_org, v_clause_template
  from public.carrier_agreement_clauses where id = new.clause_id;

  if v_signing_org is null then
    raise exception 'Signing instance not found.';
  end if;
  if v_clause_org is null then
    raise exception 'Clause not found.';
  end if;
  if v_signing_org <> new.organization_id or v_clause_org <> new.organization_id then
    raise exception 'Initial organization must match both the signing instance and the clause.';
  end if;
  if v_signing_template <> v_clause_template then
    raise exception 'Clause does not belong to the agreement template referenced by this signing instance.';
  end if;
  if v_signing_status not in ('assigned', 'in_progress') then
    raise exception 'Initials can only be recorded or corrected while a signing is assigned or in progress.';
  end if;

  return new;
end;
$$;

drop trigger if exists carrier_agreement_initials_consistency_guard on public.carrier_agreement_initials;
create trigger carrier_agreement_initials_consistency_guard
  before insert or update on public.carrier_agreement_initials
  for each row execute function public.guard_carrier_agreement_initial_consistency();

alter table public.carrier_agreement_initials enable row level security;

create policy carrier_agreement_initials_select on public.carrier_agreement_initials
  for select using (organization_id = public.current_org_id());

-- No insert/update/delete policy for any authenticated role -- see the
-- table comment above.

-- ---------------------------------------------------------------------------
-- PART 6 -- carrier_agreement_audit_events. Dedicated, append-only
-- evidence trail -- deliberately NOT the general log_activity()/
-- activity_logs, which has no DB-level immutability guarantee. Mirrors
-- carrier_onboarding_pii_access_log (0081) exactly: select-only RLS, no
-- insert/update/delete policy for any authenticated role.
-- ---------------------------------------------------------------------------

create table public.carrier_agreement_audit_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  signing_instance_id uuid not null references public.carrier_agreement_signings (id) on delete cascade,
  -- Free text, not a rigid enum -- mirrors operational_exceptions.
  -- source_type's own "keeps this additive/extensible without another
  -- migration" precedent. Expected values (not enforced here): agreement_
  -- assigned, agreement_viewed, initial_recorded, initial_changed,
  -- consent_accepted, signature_completed, agreement_completed,
  -- agreement_voided.
  event_type text not null,
  event_data jsonb,
  occurred_at timestamptz not null default now(),
  ip_address text,
  user_agent text,
  actor_type public.carrier_agreement_actor_type not null,
  actor_id uuid references public.profiles (id) on delete set null
);

comment on table public.carrier_agreement_audit_events is
  'Append-only signature/agreement evidence trail. No update/delete policy exists for any role -- written exclusively by future SECURITY DEFINER workflow RPCs. actor_id is null when actor_type=carrier_signer (the carrier has no profiles row).';

create or replace function public.guard_carrier_agreement_audit_event_org()
returns trigger
language plpgsql
as $$
declare
  v_signing_org uuid;
begin
  select organization_id into v_signing_org from public.carrier_agreement_signings where id = new.signing_instance_id;
  if v_signing_org is null or v_signing_org <> new.organization_id then
    raise exception 'Audit event organization must match its signing instance''s organization.';
  end if;
  return new;
end;
$$;

drop trigger if exists carrier_agreement_audit_events_guard_org on public.carrier_agreement_audit_events;
create trigger carrier_agreement_audit_events_guard_org
  before insert on public.carrier_agreement_audit_events
  for each row execute function public.guard_carrier_agreement_audit_event_org();

alter table public.carrier_agreement_audit_events enable row level security;

create policy carrier_agreement_audit_events_select on public.carrier_agreement_audit_events
  for select using (organization_id = public.current_org_id());

-- No insert/update/delete policy for any authenticated role -- see the
-- table comment above.

-- ---------------------------------------------------------------------------
-- PART 7 -- compute_carrier_agreement_content_hash(). Pure, read-only,
-- deterministic helper -- safe to ship now, distinct from the deferred
-- mutation RPCs, exactly as find_potential_duplicate_carriers() (0081)
-- shipped as a read-only helper while its own phase's mutation RPCs were
-- deferred.
--
-- SECURITY INVOKER, not DEFINER: this function only reads
-- carrier_agreement_templates/clauses, both of which the calling
-- owner/admin already has full RLS-scoped read access to (they're the
-- only ones who can manage templates in the first place). It doesn't
-- need to bypass RLS, so it shouldn't -- same minimal-privilege reasoning
-- already established for find_potential_duplicate_carriers() (0081).
-- ---------------------------------------------------------------------------

create or replace function public.compute_carrier_agreement_content_hash(p_template_id uuid)
returns text
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_template_key text;
  v_version_number integer;
  v_name text;
  v_clause_concat text;
  v_input text;
begin
  select template_key, version_number, name
    into v_template_key, v_version_number, v_name
  from public.carrier_agreement_templates
  where id = p_template_id;

  if v_template_key is null then
    raise exception 'Agreement template not found.';
  end if;

  -- Deterministic ordering (display_order, then id as a stable tiebreaker)
  -- and a fixed field order per clause -- the same content always
  -- produces the same hash. Only identity/content/requires_initials
  -- fields are included -- created_at and any other mutable bookkeeping
  -- is deliberately excluded.
  select string_agg(
    concat_ws('|', clause_key, title, body, display_order::text, requires_initials::text),
    E'\n' order by display_order, id
  )
  into v_clause_concat
  from public.carrier_agreement_clauses
  where agreement_template_id = p_template_id;

  v_input := concat_ws('|', v_template_key, v_version_number::text, v_name) || E'\n' || coalesce(v_clause_concat, '');

  return encode(digest(v_input, 'sha256'), 'hex');
end;
$$;

comment on function public.compute_carrier_agreement_content_hash(uuid) is
  'Deterministic SHA-256 over a template''s own identity (template_key, version_number, name) plus every clause''s (clause_key, title, body, display_order, requires_initials), ordered by (display_order, id). Excludes all mutable timestamps. The same immutable agreement content always produces the same hash -- intended to be called once, at publish time, to set carrier_agreement_templates.content_hash (while status is still draft). Does NOT compute the final signing evidence_hash -- that is a future completion RPC''s responsibility (see the design report).';

grant execute on function public.compute_carrier_agreement_content_hash(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- PART 8 -- indexes. Only what's justified by a known access path, per
-- the approved design -- no redundant index where a unique constraint
-- already backs the same lookup (template version lookup and initials
-- lookup are both already covered that way).
-- ---------------------------------------------------------------------------

-- Every render of a template's clauses needs them in display order.
create index carrier_agreement_clauses_template_order_idx on public.carrier_agreement_clauses (agreement_template_id, display_order);

-- The staff workspace's "show me this application's agreements" query.
create index carrier_agreement_signings_org_application_idx on public.carrier_agreement_signings (organization_id, application_id);

-- Chronological event-history display for a given signing.
create index carrier_agreement_audit_events_signing_occurred_idx on public.carrier_agreement_audit_events (signing_instance_id, occurred_at);
