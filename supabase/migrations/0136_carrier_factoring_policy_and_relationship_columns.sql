-- =============================================================================
-- 0136_carrier_factoring_policy_and_relationship_columns.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- Phase 3B.1 ("Carrier-Specific Factoring Configuration Foundation"), part 1
-- of 3 (0136 -> 0137 -> 0138). Prepares the database so every carrier can
-- have its OWN factoring configuration -- this must exist before carrier
-- invoices are issued (a future phase) because an issued invoice must
-- freeze the correct factor, Notice of Assignment, and remittance
-- instructions for THAT carrier, not an organization-wide default.
--
-- WHAT THIS MIGRATION DOES
--   A. carriers.factoring_mode -- explicit 'unconfigured' | 'direct' |
--      'factored' policy per carrier (item 3; corrected in Phase 3B.1.1,
--      item 1, before this migration's first commit -- see that phase's
--      report for why 'direct' was never a safe default). Defaults to
--      'unconfigured' for every existing carrier -- nobody has reviewed
--      its real billing arrangement yet, so nothing is silently assumed.
--      Entirely distinct from the PRE-EXISTING carriers.factoring_company_name
--      (0003) -- that free-text field is the AP-side "carrier-payee
--      factoring" hint (who a CARRIER'S OWN factor is, for settlement
--      payee purposes, 0033/0070); this migration is the AR-side concern
--      (which factor THIS ORGANIZATION sells THIS CARRIER's invoices to).
--      Neither field is renamed, reused, or removed.
--   B. factoring_relationships (0071) gains: carrier_id (NULLABLE in this
--      migration -- backfilled in 0137, cutover to carrier-scoped
--      uniqueness in 0138; never forced NOT NULL, so a genuinely
--      unresolved legacy row can still exist, exactly like loads.carrier_id
--      in 0132/0133), remittance instructions, full Notice of Assignment
--      configuration, and submission-method configuration (items 2, 6, 7).
--   C. Two new enums: carrier_factoring_mode, factoring_submission_method.
--      One new integration_provider value: 'factoring_api' (so the "api"
--      submission method can reference an enabled, org-scoped integration
--      row via the EXISTING integration_settings table, 0008 -- no new
--      secret-storage surface; secrets stay exactly where 0008 already
--      documents they belong, an external vault, never this column).
--   D. guard_factoring_relationship_org() (0071) is extended (create or
--      replace, in THIS migration -- 0071 itself is untouched) to also
--      validate carrier_id, noa_document_id, and submission_integration_id
--      belong to the same organization, and now fires on UPDATE too, not
--      only INSERT -- closing the gap where an UPDATE could swap in a
--      cross-org carrier_id/document/integration reference.
--   E. A NEW trigger, guard_factoring_relationship_protected_fields(),
--      restricts is_default / remittance / NOA fields to owner or admin
--      for INTERACTIVE callers (item 7, item 9) -- a trusted service/
--      migration context (auth.uid() is null) is unaffected, exactly the
--      same convention record_unresolved_carrier_record() (0130) already
--      established. This is enforced as a plain trigger, not RLS alone,
--      because this app's settings/factoring/actions.ts writes through the
--      SERVICE-ROLE client (RLS does not apply to it) -- a trigger is the
--      only DB-level checkpoint that still fires regardless of which
--      client performed the write.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not backfill carrier_id on any existing row (0137)
--   * does not touch, create, or drop any unique index on is_default/
--     is_active (0138 does the carrier-scoped cutover)
--   * does not add the classifier, the preview RPC, or revise
--     set_default_factoring_relationship() (0138)
--   * does not touch factored_invoices, factoring_events, or any
--     submission/approval/funding/settlement/exception RPC (0073-0079) --
--     those remain entirely out of scope for this phase, unchanged
--   * does not begin invoice issuance, factoring submission, payment, DSI,
--     or settlement implementation
--   * does not modify migrations 0001-0135
--
-- STRUCTURE: explicit BEGIN/COMMIT. PHASE 1 preconditions -> PHASE 2 DDL ->
-- PHASE 3 postconditions. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
begin
  if to_regclass('public.factoring_relationships') is null then
    raise exception '0136 precondition: public.factoring_relationships missing -- apply 0071 first. STOP.';
  end if;
  if to_regclass('public.carriers') is null then
    raise exception '0136 precondition: public.carriers missing. STOP.';
  end if;
  if to_regclass('public.integration_settings') is null then
    raise exception '0136 precondition: public.integration_settings missing -- apply 0008 first. STOP.';
  end if;
  if to_regclass('public.unresolved_carrier_records') is null then
    raise exception '0136 precondition: public.unresolved_carrier_records missing -- apply 0130 first. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='factoring_mode') then
    raise exception '0136 precondition: carriers.factoring_mode already exists -- partial apply? STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id') then
    raise exception '0136 precondition: factoring_relationships.carrier_id already exists -- partial apply? STOP.';
  end if;
  if to_regtype('public.carrier_factoring_mode') is not null then
    raise exception '0136 precondition: type public.carrier_factoring_mode already exists. STOP.';
  end if;
  if to_regtype('public.factoring_submission_method') is not null then
    raise exception '0136 precondition: type public.factoring_submission_method already exists. STOP.';
  end if;
  raise notice '0136 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- A. carriers.factoring_mode --------------------------------------------
-- Phase 3B.1.1 (item 1) correction: THREE states, not two. The original
-- design defaulted every existing carrier straight to 'direct', which is
-- itself an undisclosed, unreviewed billing decision -- nobody has
-- actually confirmed that carrier's real arrangement. 'unconfigured' is
-- the only honest default: it blocks invoice issuance outright (a later
-- phase) until an owner/admin explicitly chooses 'direct' or 'factored'
-- via set_carrier_factoring_policy() (0139+). Missing configuration must
-- NEVER silently become direct billing -- 'unconfigured' is what makes
-- that structurally impossible, rather than merely a comment's promise.
create type public.carrier_factoring_mode as enum ('unconfigured', 'direct', 'factored');

alter table public.carriers
  add column factoring_mode public.carrier_factoring_mode not null default 'unconfigured';

comment on column public.carriers.factoring_mode is
  'AR-side factoring policy for THIS carrier''s invoices (Phase 3B.1, item 3; Phase 3B.1.1, item 1). Three states: ''unconfigured'' (default for every existing/new carrier -- blocks invoice issuance outright, a later phase, until explicitly set) / ''direct'' (paid under carrier remittance instructions) / ''factored'' (invoice issuance requires a complete, ready -- see public.classify_carrier_factoring_readiness() -- default factoring_relationships row for this carrier). Changed ONLY via public.set_carrier_factoring_policy() (owner/admin, reason + audit event required, 0139+) -- never a direct UPDATE (see the column-privilege lockdown, 0138/0139). Distinct from carriers.factoring_company_name (0003/0033/0070), which is the UNRELATED AP-side hint for who a carrier''s OWN factor is when THIS ORGANIZATION pays that carrier a settlement.';

-- B. factoring_relationships new columns ---------------------------------
create type public.factoring_submission_method as enum (
  'secure_email', 'api', 'portal_manual', 'internal_queue'
);

-- One new integration_provider value -- lets the "api" submission method
-- reference an enabled, org-scoped row in the EXISTING integration_settings
-- table (0008), which already documents (and this migration does not
-- change) that real secrets belong in an external vault, never in a plain
-- jsonb column. No new secret-storage surface is created anywhere below.
alter type public.integration_provider add value if not exists 'factoring_api';

alter table public.factoring_relationships
  -- Carrier ownership (items 2, 4). NULLABLE here on purpose: 0137
  -- backfills what can be determined deterministically; a genuinely
  -- unresolved legacy relationship keeps carrier_id null indefinitely
  -- (recorded in unresolved_carrier_records, never guessed) -- the SAME
  -- posture loads.carrier_id (0132/0133) already established. ON DELETE
  -- RESTRICT: a carrier with any factoring history can never be hard-
  -- deleted out from under it (matches every other FK in this table).
  add column carrier_id uuid references public.carriers (id) on delete restrict,

  -- Remittance instructions (item 2). Free-form display text, not a
  -- structured bank-credential field -- deliberately so: this is the
  -- disclosure information a Notice of Assignment / invoice footer shows
  -- ("remit to <factor>, account ending ####, ..."), not an ACH/wire
  -- execution credential. Real payment-execution secrets never belong
  -- here regardless (item 2's "do not store API secrets, bank
  -- credentials, or sensitive integration tokens in ordinary factoring
  -- tables").
  add column remittance_instructions text,
  add column remittance_reference text,

  -- Notice of Assignment (item 7): EITHER approved template language OR an
  -- approved document/template reference (or both) -- never neither, once
  -- noa_approved is true (enforced by the CHECK constraint below).
  add column noa_template_text text,
  add column noa_document_id uuid references public.documents (id) on delete set null,
  add column noa_reference text,
  add column noa_effective_date date,
  add column noa_approved boolean not null default false,
  add column noa_approved_by uuid references public.profiles (id) on delete set null,
  add column noa_approved_at timestamptz,

  -- Submission method configuration (item 6). Configuration status alone
  -- must never imply anything has actually been submitted -- this
  -- migration adds no submission/transmission logic at all, only the
  -- declarative configuration a later phase's submission RPC will read.
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

-- Completeness CHECKs -- data-shape invariants a CHECK constraint CAN
-- express (cross-table validation, e.g. "the integration is actually
-- enabled," is the guard trigger's job, below).
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

-- Extend the org-consistency guard (0071) to cover the new cross-table
-- references, and to fire on UPDATE as well as INSERT (0071 only checked
-- INSERT -- an UPDATE could otherwise swap in a cross-org carrier_id,
-- noa_document_id, or submission_integration_id undetected).
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

-- New protected-field guard (items 7, 9): is_default, remittance, and NOA
-- fields require owner/admin for any INTERACTIVE (JWT-bearing) caller.
-- auth.uid() is null for a trusted service/migration context (the SAME
-- convention record_unresolved_carrier_record(), 0130, already
-- established) -- this is a plain trigger, not an RLS policy, because
-- settings/factoring/actions.ts writes through the service-role client,
-- which RLS does not apply to at all; a trigger is the only DB checkpoint
-- that still fires regardless of which client performed the write.
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

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='factoring_mode') then
    raise exception '0136 postcondition: carriers.factoring_mode missing.';
  end if;
  if (select count(*) from public.carriers where factoring_mode <> 'unconfigured') <> 0 then
    raise exception '0136 postcondition: an existing carrier was not defaulted to factoring_mode=unconfigured.';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id') then
    raise exception '0136 postcondition: factoring_relationships.carrier_id missing.';
  end if;
  if (select count(*) from public.factoring_relationships where carrier_id is not null) <> 0 then
    raise exception '0136 postcondition: this migration must not populate carrier_id itself -- found a non-null value (backfill is 0137).';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='factoring_relationships'
      and column_name in ('remittance_instructions','remittance_reference','noa_template_text','noa_document_id',
                           'noa_reference','noa_effective_date','noa_approved','noa_approved_by','noa_approved_at',
                           'submission_method','submission_destination_email','submission_integration_id','submission_notes')
  ) is false then
    raise exception '0136 postcondition: one or more new factoring_relationships columns are missing.';
  end if;

  if not exists (select 1 from pg_trigger where tgname='factoring_relationships_guard_org' and tgrelid='public.factoring_relationships'::regclass and not tgisinternal) then
    raise exception '0136 postcondition: factoring_relationships_guard_org trigger missing.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='factoring_relationships_guard_protected_fields' and tgrelid='public.factoring_relationships'::regclass and not tgisinternal) then
    raise exception '0136 postcondition: factoring_relationships_guard_protected_fields trigger missing.';
  end if;

  -- untouched: 0071's own default-per-org index and RPCs still present
  -- (0138 cuts these over, not this migration).
  if not exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_org') then
    raise exception '0136 postcondition: 0071''s factoring_relationships_one_default_per_org index disappeared -- must not happen until 0138.';
  end if;
  if to_regprocedure('public.set_default_factoring_relationship(uuid)') is null then
    raise exception '0136 postcondition: 0072 set_default_factoring_relationship(uuid) disappeared.';
  end if;

  raise notice '0136 complete: carriers.factoring_mode (three-state: unconfigured/direct/factored, default ''unconfigured'' for all existing carriers) added; factoring_relationships gained carrier_id (nullable) + remittance + NOA + submission-method columns; org-consistency guard extended to UPDATE and to the new references; new owner/admin-only protected-fields guard installed. 0071''s org-level default index and 0072''s RPC are untouched, pending 0138''s carrier-scoped cutover.';
end
$mig$;

commit;
