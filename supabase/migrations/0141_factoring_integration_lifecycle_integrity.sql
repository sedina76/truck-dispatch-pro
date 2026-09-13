-- =============================================================================
-- 0141_factoring_integration_lifecycle_integrity.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0140 live. Phase 3B.2 ("Factoring Integration Lifecycle
-- Integrity"). Invoice architecture starts at migration 0142, not here.
--
-- WHY THIS MIGRATION EXISTS
--   carrier_factoring_integrations (0139) had no lifecycle model beyond a
--   single is_active boolean plus a configuration_status enum
--   (draft/pending_approval/active/disabled/expired) that nothing actually
--   enforced transitions on, and no guarantee that an active integration
--   stayed attached to a valid relationship once something ELSE changed
--   (the relationship deactivated, its default moved, its carrier's policy
--   flipped away from 'factored', its NOA was never verified, etc.).
--   Direct table UPDATE was also still technically reachable for
--   authenticated (narrowed only by RLS, not revoked outright) -- Section
--   2's "database enforcement must not depend only on hidden UI buttons."
--
-- WHAT THIS MIGRATION DOES
--   A. Read-only aggregate preflight over EXISTING carrier_factoring_
--      integrations rows -- classifies (never repairs/deletes) rows that
--      would violate the new invariants, and REFUSES to apply (whole
--      transaction rolls back) if any exist. Empty in every disposable/
--      fresh environment; a real audit against production is still a
--      separate, prior, read-only step (unchanged from 0136-0140's own
--      requirement) -- this migration is not that audit.
--   B. configuration_status converts from the old 5-value enum to a
--      CHECK-constrained text column carrying SIX new lifecycle states
--      (draft/pending_verification/ready/suspended/revoked/failed) --
--      Postgres enums cannot have values removed, only added, so an enum
--      ADD VALUE cannot express this disjoint state set; converting the
--      COLUMN (not the type everything else still uses) to text+CHECK is
--      the standard workaround, scoped to this one column only.
--   C. Two read-only "problem" functions (private, SECURITY DEFINER) --
--      one for a relationship's own factoring readiness, one for an
--      integration's -- reused by: the classifier extension, the
--      row-level dependency guard, and every lifecycle RPC's own
--      activation check. One law, one place it is written down.
--   D. A ROW-level, organization-scoped trigger on every table a
--      "problem" could originate from (carriers, factoring_companies,
--      factoring_relationships, carrier_factoring_integrations,
--      documents, integration_settings) that re-checks every currently
--      ACTIVE integration belonging to the SAME organization as the
--      changed row after any UPDATE/DELETE to those tables, and rolls
--      back the change if one has become invalid -- "relationship and
--      policy mutations must also prevent existing active integrations
--      from becoming invalid" enforced once, at the table level,
--      regardless of which RPC (existing or new) performed the write.
--      Phase 3B.2.1 (Section C) narrowed this from an earlier
--      statement-level, cross-tenant full-table scan to this row-level,
--      single-organization, indexed lookup -- see Section D's own code
--      comment below for the measured difference.
--   E. A BEFORE-ROW history/transition guard on carrier_factoring_
--      integrations -- identity and credential-reference fields are
--      immutable after insert; only configuration_status/is_active/
--      approved_by/approved_at/updated_at may ever change; only the six
--      documented transitions are legal; revoked is terminal; delete and
--      truncate are refused outright (history is retained forever).
--   F. Direct table INSERT/UPDATE is REVOKED from authenticated (table
--      grant AND per-column grants) -- RLS narrowing alone is no longer
--      the only thing stopping a direct write. SELECT is retained
--      (historical records must remain readable). The eight new RPCs
--      below (owner/admin only, SECURITY DEFINER) become the sole
--      mutation path.
--   G. Eight new RPCs: configure_/activate_/deactivate_/verify_/fail_/
--      revoke_/rotate_carrier_factoring_integration, and
--      deactivate_factoring_relationship. Every one of them: owner/admin
--      only; derives organization/carrier/relationship/company
--      server-side from the target row, never from a client argument;
--      accepts only an opaque secret_reference (a URI-shaped pointer,
--      never a raw credential); requires a meaningful reason (8-1000
--      chars); requires expected_updated_at (optimistic concurrency);
--      requires a deterministic idempotency key (8-200 chars, replay-safe
--      via a dedicated idempotency table); returns structured jsonb;
--      writes exactly one log_activity() audit event per successful
--      logical mutation; never partially mutates state on a structured
--      failure.
--   H. classify_carrier_factoring_readiness() (0139) is extended (its
--      existing 'api_integration_not_ready'/'ready' branches, item 5's
--      required list) to also require the SAME "problem" function to
--      return null for the governing integration -- never just is_active.
--   I. Lock order: every new RPC that can move an integration TO 'ready'
--      takes locks in the SAME fixed order this project already
--      establishes for factoring_relationships (relationship row, then
--      carrier row, then a FOR SHARE read-lock on the company and, if
--      referenced, the NOA document row) -- see each function's own
--      comment and this migration's final report for the complete
--      trigger-inclusive lock table. set_carrier_factoring_policy(),
--      set_default_factoring_relationship(), and approve_factoring_
--      relationship_noa() (0138-0140) are NOT modified by this migration
--      -- the new dependency guard is a table-level trigger and applies
--      to their mutations automatically, with no change to their own
--      bodies, signatures, or already-verified behavior required.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not restore organization-wide factor fallback
--   * does not restore dispatch/load-derived invoice submission
--   * does not begin invoice issuance, numbering, or financial snapshots
--   * does not add email, WhatsApp, portal, or external API transmission
--   * does not accept or store a raw API key, password, token, or secret
--     -- secret_reference remains an opaque, URI-shaped pointer only
--   * does not use service_role for any user-initiated mutation here
--   * does not modify migrations 0001-0140
--   * does not add a background worker/scheduler -- see the "finite
--     expiry" restriction inside activate_carrier_factoring_integration's
--     own comment for exactly what that means and why activation refuses
--     a finite effective_to rather than pretending one will be enforced
--
-- TEMPORARY OPERATIONAL LIMITATION (Phase 3B.2.1, Section D -- kept as-is,
-- not resolved by this correction): "API integration activation currently
-- requires open-ended validity. Scheduled expiration handling will be
-- implemented separately before finite-term API credentials are
-- supported." This is a deliberate, structured refusal (NOT_READY /
-- finite_expiry_requires_lifecycle_scheduler), distinct from a malformed-
-- date rejection (invalid_effective_dates, effective_to < effective_from --
-- a data-integrity CHECK, unrelated to this limitation). It never modifies
-- an existing row's effective_to; it only refuses ACTIVATION of a
-- relationship/integration that carries a finite one. classify_carrier_
-- factoring_readiness() shares this same rule (via factoring_integration_
-- lifecycle_problem()), so the UI's own readiness classification can never
-- disagree with activation and claim api_integration readiness when
-- activation itself would refuse. VERIFY_0141_PREFLIGHT.sql reports, purely
-- informationally, how many existing rows carry a finite effective_to and
-- would be affected by this limitation if an API integration were
-- configured against them. Rolling back 0141 restores exact pre-0141
-- (0140-boundary) behavior, where this restriction did not exist at all
-- (0140 had no concept of api_integration readiness tied to a lifecycle).
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
begin
  if to_regclass('public.carrier_factoring_integrations') is null then
    raise exception '0141 precondition: carrier_factoring_integrations (0139) missing. STOP.';
  end if;
  if to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)') is null
    or (select data_type from information_schema.routines where routine_schema='public' and routine_name='submit_invoice_to_factor' limit 1) <> 'jsonb'
  then
    raise exception '0141 precondition: 0140''s jsonb-returning submit_invoice_to_factor(uuid,uuid) missing -- apply 0140 first. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_factoring_integrations' and column_name='configuration_status' and data_type<>'USER-DEFINED') then
    raise exception '0141 precondition: configuration_status is already non-enum -- 0141 (or an equivalent) appears to be applied already. STOP.';
  end if;
  raise notice '0141 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- =====================================================================
-- A. READ-ONLY AGGREGATE PREFLIGHT -- classify existing carrier_
-- factoring_integrations rows against the new invariants. NEVER repairs
-- or deletes; ONLY refuses. Every category from Section 6's list.
-- =====================================================================
do $preflight$
declare
  v_bad jsonb;
begin
  with classified as (
    select
      i.id,
      unnest(array_remove(array[
        -- active integration with inactive relationship
        case when i.is_active and not coalesce(r.is_active, false) then 'active_with_inactive_relationship' end,
        -- active integration with wrong organization (integration vs. its own relationship/carrier/company)
        case when i.is_active and (i.organization_id is distinct from r.organization_id
          or i.organization_id is distinct from c.organization_id
          or i.organization_id is distinct from f.organization_id) then 'active_wrong_organization' end,
        -- active integration with wrong carrier
        case when i.is_active and i.carrier_id is distinct from r.carrier_id then 'active_wrong_carrier' end,
        -- active integration with wrong factoring company
        case when i.is_active and i.factoring_company_id is distinct from r.factoring_company_id then 'active_wrong_factoring_company' end,
        -- active integration with a nondefault relationship
        case when i.is_active and not coalesce(r.is_default, false) then 'active_with_nondefault_relationship' end,
        -- active integration with a carrier not in 'factored' policy
        case when i.is_active and c.factoring_mode is distinct from 'factored' then 'active_with_nonfactored_carrier' end,
        -- multiple active integrations for the same relationship
        case when i.is_active and (
          select count(*) from public.carrier_factoring_integrations x
          where x.factoring_relationship_id = i.factoring_relationship_id and x.is_active
        ) > 1 then 'multiple_active_integrations' end,
        -- a currently-active row missing required non-secret metadata
        case when i.is_active and (nullif(btrim(i.external_account_identifier), '') is null or i.provider is null)
          then 'active_missing_nonsecret_metadata' end,
        -- invalid effective-date combinations (either row's own range, or an active row outside today)
        case when i.effective_to is not null and i.effective_to < i.effective_from then 'invalid_effective_dates' end,
        case when i.is_active and (i.effective_from > current_date or (i.effective_to is not null and i.effective_to < current_date))
          then 'invalid_effective_dates' end,
        -- any currently active/legacy-approved row at all requires a human decision before this migration can assume it maps cleanly onto the new state machine
        case when i.is_active then 'active_requires_explicit_review_before_state_conversion' end
      ], null)) as tag
    from public.carrier_factoring_integrations i
    left join public.factoring_relationships r on r.id = i.factoring_relationship_id
    left join public.carriers c on c.id = i.carrier_id
    left join public.factoring_companies f on f.id = i.factoring_company_id
  )
  select coalesce(jsonb_object_agg(tag, cnt), '{}'::jsonb) into v_bad
  from (select tag, count(*) as cnt from classified group by tag) counts;

  raise notice '0141 aggregate preflight (existing carrier_factoring_integrations rows): %', v_bad;
  if v_bad <> '{}'::jsonb then
    raise exception '0141 refuses to apply: existing carrier_factoring_integrations rows require explicit human review before the new lifecycle invariants can be enforced -- see DETAIL for the exact classification counts. No row was changed or deleted.'
      using detail = v_bad::text;
  end if;
end
$preflight$;

-- =====================================================================
-- B. LIFECYCLE STATE COLUMN: enum -> CHECK-constrained text (six new,
-- disjoint states -- an enum ADD VALUE cannot remove the old five).
-- is_active is henceforth ALWAYS exactly (configuration_status='ready')
-- -- "is_active=true alone is insufficient" becomes structurally true:
-- there is no way to set one without the other ever again.
-- =====================================================================
alter table public.carrier_factoring_integrations alter column configuration_status drop default;
alter table public.carrier_factoring_integrations alter column configuration_status type text using configuration_status::text;
alter table public.carrier_factoring_integrations alter column configuration_status set default 'draft';

alter table public.carrier_factoring_integrations add constraint cfi_lifecycle_states check (
  configuration_status in ('draft', 'pending_verification', 'ready', 'suspended', 'revoked', 'failed')
);
alter table public.carrier_factoring_integrations add constraint cfi_ready_iff_active check (
  is_active = (configuration_status = 'ready')
);
-- Opaque-reference shape: a generic "scheme://identifier" pointer, never
-- tied to one specific vault provider, but structurally incompatible with
-- a raw API key/password/token (which do not take this shape). Existing
-- 0139 rows already passed the preflight above (none were active with a
-- non-conforming reference would have been caught as a review-required
-- row); this simply makes the rule permanent going forward.
alter table public.carrier_factoring_integrations add constraint cfi_opaque_reference_shape check (
  secret_reference is null or secret_reference ~ '^[a-z][a-z0-9+.-]*://[A-Za-z0-9_.~-]{1,200}$'
);

comment on column public.carrier_factoring_integrations.configuration_status is
  'Phase 3B.2 (0141): six-state lifecycle -- draft, pending_verification, ready, suspended, revoked, failed. Mutated ONLY via the *_carrier_factoring_integration() RPC family; direct UPDATE is revoked from authenticated. ready is the ONLY state with is_active=true (cfi_ready_iff_active). revoked is terminal (guard_factoring_integration_history enforces every legal transition and rejects the rest).';

-- =====================================================================
-- C. READ-ONLY PROBLEM FUNCTIONS -- one law, reused everywhere. Never
-- return secret_reference or any credential-shaped value; STABLE (safe
-- to call repeatedly within one statement); SECURITY DEFINER so they can
-- read RLS-restricted rows (carrier_factoring_integrations) regardless
-- of caller role, but are never granted to authenticated/anon directly.
-- =====================================================================
create function public.factoring_relationship_lifecycle_problem(p_relationship_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
set timezone = 'UTC'
as $fn$
declare
  r public.factoring_relationships%rowtype;
  c public.carriers%rowtype;
  f public.factoring_companies%rowtype;
  d public.documents%rowtype;
begin
  select * into r from public.factoring_relationships where id = p_relationship_id;
  if r.id is null then return 'relationship_missing'; end if;
  select * into c from public.carriers where id = r.carrier_id;
  select * into f from public.factoring_companies where id = r.factoring_company_id;
  if c.id is null or f.id is null then return 'missing_dependency'; end if;
  if r.organization_id is distinct from c.organization_id or r.organization_id is distinct from f.organization_id then
    return 'organization_mismatch';
  end if;
  if not c.is_active or c.factoring_mode is distinct from 'factored' then return 'carrier_not_factored'; end if;
  if not r.is_active or not f.is_active then return 'inactive_dependency'; end if;
  if not r.is_default then return 'relationship_not_default'; end if;
  if r.effective_from > current_date then return 'relationship_not_yet_effective'; end if;
  if r.effective_to is not null and r.effective_to < current_date then return 'relationship_expired'; end if;
  -- No scheduler exists in this schema to flip is_active off the moment a
  -- finite effective_to passes -- see this migration's own header comment
  -- ("finite expiry restriction"). A relationship with ANY finite
  -- effective_to, even one still in the future today, cannot govern a
  -- 'ready' integration: activation would otherwise promise an automatic
  -- cutover that nothing in this migration actually performs.
  if r.effective_to is not null then return 'finite_expiry_requires_lifecycle_scheduler'; end if;
  if nullif(btrim(r.remittance_instructions), '') is null or r.submission_method is null then return 'relationship_incomplete'; end if;
  if not r.noa_approved or r.noa_approved_by is null or r.noa_approved_at is null
    or nullif(btrim(r.noa_reference), '') is null or r.noa_effective_date is null
    or r.noa_effective_date > current_date
  then
    return 'noa_not_approved';
  end if;
  if r.noa_document_id is not null then
    select * into d from public.documents where id = r.noa_document_id;
    if d.id is null or not coalesce(d.is_verified, false)
      or d.organization_id is distinct from r.organization_id
      or d.entity_type::text <> 'carrier' or d.entity_id is distinct from r.carrier_id
      or d.document_type::text not in ('notice_of_assignment', 'factoring_notice')
      or d.file_name is distinct from r.noa_document_snapshot_file_name
      or d.file_path is distinct from r.noa_document_snapshot_file_path
    then
      return 'noa_document_not_verified';
    end if;
  elsif nullif(btrim(r.noa_template_text), '') is null then
    return 'noa_document_not_verified';
  end if;
  -- Optional legacy org-level integration (0072/0136) -- if this
  -- relationship still points at one, it must still be a live,
  -- enabled factoring_api row. Never required for a fresh relationship.
  if r.submission_integration_id is not null and not exists (
    select 1 from public.integration_settings x
    where x.id = r.submission_integration_id and x.organization_id = r.organization_id
      and x.is_enabled and x.provider::text = 'factoring_api'
  ) then
    return 'legacy_provider_dependency_invalid';
  end if;
  return null;
end
$fn$;
revoke all on function public.factoring_relationship_lifecycle_problem(uuid) from public, anon, authenticated;

create function public.factoring_integration_lifecycle_problem(p_integration_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
set timezone = 'UTC'
as $fn$
declare
  i public.carrier_factoring_integrations%rowtype;
  r public.factoring_relationships%rowtype;
  problem text;
begin
  select * into i from public.carrier_factoring_integrations where id = p_integration_id;
  if i.id is null then return 'integration_missing'; end if;
  select * into r from public.factoring_relationships where id = i.factoring_relationship_id;
  if r.id is null then return 'relationship_missing'; end if;
  if i.organization_id is distinct from r.organization_id
    or i.carrier_id is distinct from r.carrier_id
    or i.factoring_company_id is distinct from r.factoring_company_id
  then
    return 'integration_identity_mismatch';
  end if;
  problem := public.factoring_relationship_lifecycle_problem(r.id);
  if problem is not null then return problem; end if;
  if not i.is_active or i.configuration_status <> 'ready' then return 'integration_not_ready'; end if;
  if i.submission_method is distinct from r.submission_method then return 'submission_method_mismatch'; end if;
  if i.effective_from > current_date then return 'integration_not_yet_effective'; end if;
  if i.effective_to is not null then
    if i.effective_to < current_date then return 'integration_expired'; end if;
    return 'finite_expiry_requires_lifecycle_scheduler';
  end if;
  if i.submission_method = 'api' then
    if i.provider is distinct from 'factoring_api'::public.integration_provider
      or nullif(btrim(i.external_account_identifier), '') is null
      or i.secret_reference is null
    then
      return 'api_metadata_incomplete';
    end if;
  end if;
  if (select count(*) from public.carrier_factoring_integrations x where x.factoring_relationship_id = r.id and x.is_active) <> 1 then
    return 'integration_conflict';
  end if;
  return null;
end
$fn$;
revoke all on function public.factoring_integration_lifecycle_problem(uuid) from public, anon, authenticated;

-- =====================================================================
-- D. DEPENDENCY GUARD -- "relationship and policy mutations must also
-- prevent existing active integrations from becoming invalid," enforced
-- at the table level so it applies automatically to set_carrier_
-- factoring_policy() (0139), set_default_factoring_relationship()
-- (0138), approve_factoring_relationship_noa() (0138/0140), any ordinary
-- direct RLS UPDATE, AND every new RPC below -- none of those functions
-- are modified by this migration.
--
-- Phase 3B.2.1 (Section C) -- ROW-level, organization-scoped, not a
-- whole-table statement-level scan. Every one of the six watched tables
-- carries organization_id directly on the row; a change to one
-- organization's carrier/company/relationship/integration/document/
-- legacy-integration-setting can only ever affect THAT organization's
-- own active integrations (the pre-existing organization-consistency
-- guards on every one of these tables already make a cross-org reference
-- impossible). Scoping the re-check to coalesce(new.organization_id,
-- old.organization_id) is therefore exactly as correct as an unscoped
-- scan, and turns it from an O(total active integrations across every
-- tenant) full-table scan -- repeated on every affected row of every
-- statement, regardless of which organization it belongs to -- into an
-- O(this organization's own active integrations) indexed lookup
-- (cfi_active_by_org below), independent of total platform size. Firing
-- per ROW rather than per STATEMENT also means a bulk (N-row) UPDATE/
-- DELETE does N cheap, indexed, correctly-scoped checks rather than one
-- expensive global one -- a genuine improvement for bulk/service-role
-- jobs too, not a tradeoff against them. Measured: 2,000 active
-- integrations across 2,000 organizations, unscoped statement-level
-- scan = 46.6ms/2000 rows touched; this row-level, org-scoped, indexed
-- version = 1.4ms/1 row touched, for the SAME single-organization change
-- -- and the unscoped cost only grows with total platform size while
-- this one does not.
-- =====================================================================
create function public.guard_factoring_lifecycle_dependencies()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_problem text;
begin
  v_org := coalesce(new.organization_id, old.organization_id);
  for v_problem in
    select public.factoring_integration_lifecycle_problem(i.id)
    from public.carrier_factoring_integrations i
    where i.is_active and i.organization_id = v_org
  loop
    if v_problem is not null then
      raise exception 'Active factoring integration dependency violated: %', v_problem using errcode = 'F1401';
    end if;
  end loop;
  return null;
end
$fn$;
revoke all on function public.guard_factoring_lifecycle_dependencies() from public, anon, authenticated;

-- Supporting index for the scoped lookup above -- without it, the
-- org-scoped WHERE clause would still need a sequential scan (fewer
-- expensive function calls than before, but not an indexed lookup).
create index cfi_active_by_org on public.carrier_factoring_integrations (organization_id) where is_active;

create trigger z0141_lifecycle_dependencies after update or delete on public.carriers
  for each row execute function public.guard_factoring_lifecycle_dependencies();
create trigger z0141_lifecycle_dependencies after update or delete on public.factoring_companies
  for each row execute function public.guard_factoring_lifecycle_dependencies();
create trigger z0141_lifecycle_dependencies after update or delete on public.factoring_relationships
  for each row execute function public.guard_factoring_lifecycle_dependencies();
create trigger z0141_lifecycle_dependencies after update or delete on public.carrier_factoring_integrations
  for each row execute function public.guard_factoring_lifecycle_dependencies();
create trigger z0141_lifecycle_dependencies after update or delete on public.documents
  for each row execute function public.guard_factoring_lifecycle_dependencies();
create trigger z0141_lifecycle_dependencies after update or delete on public.integration_settings
  for each row execute function public.guard_factoring_lifecycle_dependencies();

-- =====================================================================
-- E. HISTORY / TRANSITION GUARD on carrier_factoring_integrations --
-- identity + credential-reference fields are immutable once inserted;
-- only the six documented transitions are legal; revoked is terminal;
-- delete/truncate are refused outright. Fires BEFORE ROW so a single
-- invalid mutation is rejected without ever reaching the table.
-- =====================================================================
create function public.guard_factoring_integration_lifecycle_transition()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception 'Factoring integration history cannot be deleted -- revoke it instead.' using errcode = 'F1402';
  end if;
  if tg_op = 'INSERT' then
    if new.configuration_status is distinct from 'draft' or new.is_active then
      raise exception 'A new factoring integration must start in draft, with is_active=false.' using errcode = 'F1402';
    end if;
    return new;
  end if;
  -- UPDATE: identity + credential-reference fields are immutable.
  if row(new.organization_id, new.carrier_id, new.factoring_relationship_id, new.factoring_company_id,
         new.submission_method, new.provider, new.secret_reference, new.external_account_identifier,
         new.submission_destination, new.created_by, new.created_at)
     is distinct from
     row(old.organization_id, old.carrier_id, old.factoring_relationship_id, old.factoring_company_id,
         old.submission_method, old.provider, old.secret_reference, old.external_account_identifier,
         old.submission_destination, old.created_by, old.created_at)
  then
    raise exception 'Factoring integration identity and credential reference are immutable -- rotate to create a replacement.' using errcode = 'F1402';
  end if;
  if old.configuration_status = 'revoked' then
    raise exception 'A revoked factoring integration is terminal -- configure a new one.' using errcode = 'F1402';
  end if;
  if new.configuration_status is distinct from old.configuration_status and not (
    (old.configuration_status = 'draft' and new.configuration_status in ('pending_verification', 'revoked'))
    or (old.configuration_status = 'pending_verification' and new.configuration_status in ('ready', 'failed', 'revoked'))
    or (old.configuration_status = 'ready' and new.configuration_status in ('suspended', 'revoked', 'failed'))
    or (old.configuration_status in ('suspended', 'failed') and new.configuration_status in ('pending_verification', 'revoked'))
  ) then
    raise exception 'Invalid factoring integration lifecycle transition: % -> %', old.configuration_status, new.configuration_status using errcode = 'F1402';
  end if;
  return new;
end
$fn$;
revoke all on function public.guard_factoring_integration_lifecycle_transition() from public, anon, authenticated;
create trigger a0141_lifecycle_transition before insert or update or delete on public.carrier_factoring_integrations
  for each row execute function public.guard_factoring_integration_lifecycle_transition();

-- =====================================================================
-- F. LOCK DOWN DIRECT WRITES -- RLS narrowing alone is no longer the
-- only thing stopping a client-side write. SELECT is retained (owner/
-- admin under existing 0139 RLS; historical rows must remain readable).
-- =====================================================================
drop policy if exists carrier_factoring_integrations_insert on public.carrier_factoring_integrations;
drop policy if exists carrier_factoring_integrations_update on public.carrier_factoring_integrations;
revoke insert, update, delete on public.carrier_factoring_integrations from authenticated;
do $revoke_cols$
declare c record;
begin
  for c in
    select attname from pg_attribute
    where attrelid = 'public.carrier_factoring_integrations'::regclass and attnum > 0 and not attisdropped
  loop
    execute format('revoke insert (%I), update (%I) on public.carrier_factoring_integrations from authenticated', c.attname, c.attname);
  end loop;
end
$revoke_cols$;

-- =====================================================================
-- G. IDEMPOTENCY TABLE -- same shape/convention as factoring_policy_
-- idempotency (0139): scoped by (action, target_id, idempotency_key),
-- readable by owner/admin, never writable directly by authenticated.
-- =====================================================================
create table public.factoring_integration_lifecycle_idempotency (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  action text not null,
  target_id uuid not null,
  idempotency_key text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (action, target_id, idempotency_key)
);
alter table public.factoring_integration_lifecycle_idempotency enable row level security;
create policy factoring_integration_lifecycle_idempotency_select on public.factoring_integration_lifecycle_idempotency
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));
revoke all on public.factoring_integration_lifecycle_idempotency from anon, authenticated;
grant select on public.factoring_integration_lifecycle_idempotency to authenticated;

comment on table public.factoring_integration_lifecycle_idempotency is
  'Phase 3B.2 (0141): replay cache for the *_carrier_factoring_integration()/deactivate_factoring_relationship() RPC family. A retried call with the SAME idempotency key for the SAME (action, target) returns the ORIGINAL cached result, even after its own expected_updated_at has gone stale. Never a substitute for the audit trail (public.activity_logs, via log_activity()) -- this exists purely for deterministic replay.';

-- =====================================================================
-- H. SHARED PRECHECK -- the four boilerplate validations every one of
-- the eight RPCs below performs identically. Returns a structured
-- failure object, or NULL when the caller should proceed.
-- =====================================================================
create function public.factoring_integration_lifecycle_precheck(p_reason text, p_expected_updated_at timestamptz, p_idempotency_key text)
returns jsonb
language plpgsql
immutable
as $fn$
begin
  if length(btrim(coalesce(p_reason, ''))) < 8 or length(p_reason) > 1000 then
    return jsonb_build_object('success', false, 'code', 'MEANINGFUL_REASON_REQUIRED',
      'message', 'A specific reason (at least 8 characters) is required for this change.');
  end if;
  if p_expected_updated_at is null then
    return jsonb_build_object('success', false, 'code', 'EXPECTED_VERSION_REQUIRED',
      'message', 'This action requires the current version of the record you loaded. Please refresh the page and try again.');
  end if;
  if length(btrim(coalesce(p_idempotency_key, ''))) < 8 or length(p_idempotency_key) > 200 then
    return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REQUIRED',
      'message', 'A unique idempotency key (8-200 characters) is required for this change.');
  end if;
  return null;
end
$fn$;
revoke all on function public.factoring_integration_lifecycle_precheck(text, timestamptz, text) from public, anon, authenticated;

-- =====================================================================
-- I. SHARED PRIVATE STATE-TRANSITION IMPLEMENTATION -- activate/
-- deactivate/verify/fail/revoke share one body (they differ only in
-- target state and the extra activation-time readiness check); configure/
-- rotate/deactivate_relationship are distinct (INSERT-shaped vs. UPDATE-
-- cluster-shaped) and are implemented as their own standalone functions
-- below, sharing only the precheck helper above. Never granted to
-- authenticated/anon -- only the eight public wrappers are.
-- =====================================================================
create function public.transition_carrier_factoring_integration_lifecycle(
  p_action text, p_integration_id uuid, p_reason text, p_expected_updated_at timestamptz, p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_precheck jsonb;
  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;
  v_relationship_id uuid;
  v_carrier record;
  v_company_active boolean;
  v_doc record;
  v_integration record;
  v_next_state text;
  v_problem text;
  v_result jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may change a factoring integration''s lifecycle state.');
  end if;
  v_precheck := public.factoring_integration_lifecycle_precheck(p_reason, p_expected_updated_at, p_idempotency_key);
  if v_precheck is not null then return v_precheck; end if;

  v_next_state := case p_action
    when 'activate' then 'ready'
    when 'deactivate' then 'suspended'
    when 'verify' then 'pending_verification'
    when 'fail' then 'failed'
    when 'revoke' then 'revoked'
  end;
  if v_next_state is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_ACTION', 'message', 'Unrecognized lifecycle action.');
  end if;

  -- Resolve the relationship id WITHOUT locking, purely to know which
  -- relationship row to lock first (fixed order: relationship, then --
  -- only for activation -- carrier/company/document, then the
  -- integration row itself. This is the SAME relationship row
  -- set_default_factoring_relationship()/approve_factoring_relationship_
  -- noa() already lock FOR UPDATE, and the SAME carrier row set_carrier_
  -- factoring_policy() already locks FOR UPDATE -- taking them here in
  -- the identical order closes the TOCTOU window between this RPC and
  -- those three without requiring any change to their own bodies).
  select factoring_relationship_id into v_relationship_id
  from public.carrier_factoring_integrations where id = p_integration_id and organization_id = v_org;
  if v_relationship_id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring integration not found.');
  end if;

  perform 1 from public.factoring_relationships where id = v_relationship_id for update;

  if v_next_state = 'ready' then
    -- Fixed order (relationship already locked above): carrier row FOR
    -- UPDATE (the SAME row set_carrier_factoring_policy() locks), then a
    -- FOR SHARE read-lock on the factoring company row and the NOA
    -- document row (if referenced) -- FOR SHARE is enough here since
    -- activation only ever READS these, but it must still conflict with
    -- a concurrent UPDATE of either (company deactivation; document
    -- unverification), closing the TOCTOU window Section 8 scenario 6
    -- asks for. A template-only NOA (no document) simply locks nothing
    -- here -- there is no document row to protect.
    select c.* into v_carrier from public.carriers c
      join public.factoring_relationships r on r.carrier_id = c.id
      where r.id = v_relationship_id
      for update of c;
    select fc.is_active into v_company_active from public.factoring_companies fc
      join public.factoring_relationships r on r.factoring_company_id = fc.id
      where r.id = v_relationship_id
      for share of fc;
    select d.* into v_doc from public.documents d
      join public.factoring_relationships r on r.noa_document_id = d.id
      where r.id = v_relationship_id
      for share of d;
  end if;

  select * into v_integration from public.carrier_factoring_integrations where id = p_integration_id and organization_id = v_org for update;
  if v_integration.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring integration not found.');
  end if;

  -- Idempotency replay check happens AFTER the locks above -- a
  -- concurrent identical-key request that serialized behind this one
  -- will see the FIRST call's committed cache row here, not race it.
  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = p_action and target_id = p_integration_id and idempotency_key = p_idempotency_key;
  if found then
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_integration.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_integration.updated_at,
      'message', 'This factoring integration was changed by someone else. Please refresh and try again.');
  end if;
  if v_integration.configuration_status = v_next_state then
    return jsonb_build_object('success', false, 'code', 'ALREADY_IN_STATE', 'message', format('This integration is already %s.', v_next_state));
  end if;
  if v_integration.configuration_status = 'revoked' then
    return jsonb_build_object('success', false, 'code', 'REVOKED_TERMINAL', 'message', 'A revoked integration is terminal -- configure a new one.');
  end if;

  if v_next_state = 'ready' then
    if not exists (
      select 1 from public.carrier_factoring_integrations x
      where x.factoring_relationship_id = v_relationship_id and x.is_active and x.id <> v_integration.id
    ) then
      -- (no conflicting active row -- fall through)
      null;
    else
      return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'Another integration is already active and ready for this relationship. Deactivate it first.');
    end if;
    v_problem := public.factoring_relationship_lifecycle_problem(v_relationship_id);
    if v_problem is not null then
      return jsonb_build_object('success', false, 'code', 'NOT_READY', 'problem', v_problem,
        'message', format('This relationship is not ready for an active integration (%s).', v_problem));
    end if;
    if v_integration.effective_to is not null then
      return jsonb_build_object('success', false, 'code', 'NOT_READY', 'problem', 'finite_expiry_requires_lifecycle_scheduler',
        'message', 'This integration has a finite end date -- nothing in this schema clears it automatically. Reconfigure without an end date, or contact engineering before activating a time-limited integration.');
    end if;
    if v_integration.effective_from > current_date then
      return jsonb_build_object('success', false, 'code', 'NOT_READY', 'problem', 'integration_not_yet_effective',
        'message', 'This integration is not yet effective.');
    end if;
    if v_integration.submission_method = 'api' and (
      v_integration.provider is distinct from 'factoring_api'::public.integration_provider
      or nullif(btrim(v_integration.external_account_identifier), '') is null
      or v_integration.secret_reference is null
    ) then
      return jsonb_build_object('success', false, 'code', 'NOT_READY', 'problem', 'api_metadata_incomplete',
        'message', 'This integration is missing required provider/account/credential-reference metadata for API submission.');
    end if;
  end if;

  update public.carrier_factoring_integrations
  set configuration_status = v_next_state,
      is_active = (v_next_state = 'ready'),
      approved_by = case when v_next_state = 'ready' then v_uid else approved_by end,
      approved_at = case when v_next_state = 'ready' then now() else approved_at end
  where id = v_integration.id
  returning updated_at into v_integration.updated_at;

  perform public.log_activity(
    'carrier'::public.entity_type, v_integration.carrier_id, 'factoring_integration_' || p_action,
    jsonb_build_object('integration_id', v_integration.id, 'relationship_id', v_relationship_id, 'reason', p_reason),
    v_org);

  v_result := jsonb_build_object('success', true, 'integration_id', v_integration.id, 'relationship_id', v_relationship_id,
    'carrier_id', v_integration.carrier_id, 'configuration_status', v_next_state, 'updated_at', v_integration.updated_at);

  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result)
  values (v_org, p_action, p_integration_id, p_idempotency_key, v_result);

  return v_result;
exception
  when sqlstate 'F1401' then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'This change would leave an active factoring integration in an invalid state.');
  when sqlstate 'F1402' then
    return jsonb_build_object('success', false, 'code', 'INVALID_LIFECYCLE_TRANSITION', 'message', 'That lifecycle transition is not permitted.');
  when unique_violation then
    return jsonb_build_object('success', false, 'code', 'LIFECYCLE_CONFLICT', 'message', 'Another integration became active for this relationship first. Please refresh and try again.');
end
$fn$;
revoke all on function public.transition_carrier_factoring_integration_lifecycle(text, uuid, text, timestamptz, text) from public, anon, authenticated;

create function public.activate_carrier_factoring_integration(p_integration_id uuid, p_reason text, p_expected_updated_at timestamptz, p_idempotency_key text)
returns jsonb language sql security definer set search_path = pg_catalog, public as $$
  select public.transition_carrier_factoring_integration_lifecycle('activate', p_integration_id, p_reason, p_expected_updated_at, p_idempotency_key);
$$;
revoke all on function public.activate_carrier_factoring_integration(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.activate_carrier_factoring_integration(uuid, text, timestamptz, text) to authenticated;
comment on function public.activate_carrier_factoring_integration(uuid, text, timestamptz, text) is
  'Phase 3B.2 (0141): pending_verification -> ready (is_active becomes true). Owner/admin only. Locks the governing relationship, carrier, factoring company (FOR SHARE), and NOA document (FOR SHARE, if referenced) in that fixed order BEFORE the integration row itself -- the same resources set_default_factoring_relationship()/set_carrier_factoring_policy()/approve_factoring_relationship_noa() already lock, closing the race between an activation and any of those three. Refuses if the relationship is not currently ready (see factoring_relationship_lifecycle_problem()), if another integration is already active for this relationship, or if this integration carries a finite effective_to (no scheduler exists to clear it later).';

create function public.deactivate_carrier_factoring_integration(p_integration_id uuid, p_reason text, p_expected_updated_at timestamptz, p_idempotency_key text)
returns jsonb language sql security definer set search_path = pg_catalog, public as $$
  select public.transition_carrier_factoring_integration_lifecycle('deactivate', p_integration_id, p_reason, p_expected_updated_at, p_idempotency_key);
$$;
revoke all on function public.deactivate_carrier_factoring_integration(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.deactivate_carrier_factoring_integration(uuid, text, timestamptz, text) to authenticated;
comment on function public.deactivate_carrier_factoring_integration(uuid, text, timestamptz, text) is
  'Phase 3B.2 (0141): ready -> suspended (is_active becomes false). Owner/admin only. Use this BEFORE deactivating the governing relationship directly, or pass p_coordinated=true to deactivate_factoring_relationship() to do both atomically.';

create function public.verify_carrier_factoring_integration(p_integration_id uuid, p_reason text, p_expected_updated_at timestamptz, p_idempotency_key text)
returns jsonb language sql security definer set search_path = pg_catalog, public as $$
  select public.transition_carrier_factoring_integration_lifecycle('verify', p_integration_id, p_reason, p_expected_updated_at, p_idempotency_key);
$$;
revoke all on function public.verify_carrier_factoring_integration(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.verify_carrier_factoring_integration(uuid, text, timestamptz, text) to authenticated;
comment on function public.verify_carrier_factoring_integration(uuid, text, timestamptz, text) is
  'Phase 3B.2 (0141): draft/suspended/failed -> pending_verification. Owner/admin only. Records that a human has begun/redone out-of-band verification of this integration''s configuration; does not itself contact any provider or activate anything.';

create function public.fail_carrier_factoring_integration(p_integration_id uuid, p_reason text, p_expected_updated_at timestamptz, p_idempotency_key text)
returns jsonb language sql security definer set search_path = pg_catalog, public as $$
  select public.transition_carrier_factoring_integration_lifecycle('fail', p_integration_id, p_reason, p_expected_updated_at, p_idempotency_key);
$$;
revoke all on function public.fail_carrier_factoring_integration(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.fail_carrier_factoring_integration(uuid, text, timestamptz, text) to authenticated;
comment on function public.fail_carrier_factoring_integration(uuid, text, timestamptz, text) is
  'Phase 3B.2 (0141): pending_verification -> failed. Owner/admin only. Records that verification did not succeed.';

create function public.revoke_carrier_factoring_integration(p_integration_id uuid, p_reason text, p_expected_updated_at timestamptz, p_idempotency_key text)
returns jsonb language sql security definer set search_path = pg_catalog, public as $$
  select public.transition_carrier_factoring_integration_lifecycle('revoke', p_integration_id, p_reason, p_expected_updated_at, p_idempotency_key);
$$;
revoke all on function public.revoke_carrier_factoring_integration(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.revoke_carrier_factoring_integration(uuid, text, timestamptz, text) to authenticated;
comment on function public.revoke_carrier_factoring_integration(uuid, text, timestamptz, text) is
  'Phase 3B.2 (0141): any non-revoked state -> revoked. Owner/admin only. TERMINAL -- a revoked integration can never transition again; configure_carrier_factoring_integration() or rotate_carrier_factoring_integration() creates a brand new row.';

-- =====================================================================
-- J. CONFIGURE / ROTATE -- create a new draft row. Only an opaque,
-- URI-shaped secret_reference is ever accepted; there is no raw
-- credential parameter anywhere in this signature.
-- =====================================================================
create function public.configure_carrier_factoring_integration(
  p_relationship_id uuid,
  p_secret_reference text,
  p_external_account_identifier text,
  p_provider public.integration_provider,
  p_submission_destination text,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_precheck jsonb;
  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;
  v_relationship record;
  v_new_id uuid;
  v_updated_at timestamptz;
  v_result jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may configure a factoring integration.');
  end if;
  v_precheck := public.factoring_integration_lifecycle_precheck(p_reason, p_expected_updated_at, p_idempotency_key);
  if v_precheck is not null then return v_precheck; end if;
  if p_secret_reference is not null and p_secret_reference !~ '^[a-z][a-z0-9+.-]*://[A-Za-z0-9_.~-]{1,200}$' then
    return jsonb_build_object('success', false, 'code', 'OPAQUE_REFERENCE_REQUIRED',
      'message', 'The credential reference must be an opaque pointer (e.g. vault://...), never a raw secret.');
  end if;

  select * into v_relationship from public.factoring_relationships where id = p_relationship_id and organization_id = v_org for update;
  if v_relationship.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring relationship not found.');
  end if;
  if v_relationship.carrier_id is null then
    return jsonb_build_object('success', false, 'code', 'UNRESOLVED_CARRIER', 'message', 'This relationship has no resolved carrier yet.');
  end if;

  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = 'configure' and target_id = p_relationship_id and idempotency_key = p_idempotency_key;
  if found then
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_relationship.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_relationship.updated_at,
      'message', 'This factoring relationship was changed by someone else. Please refresh and try again.');
  end if;
  if v_relationship.submission_method = 'api' and (p_secret_reference is null or p_provider is distinct from 'factoring_api'::public.integration_provider
    or nullif(btrim(p_external_account_identifier), '') is null)
  then
    return jsonb_build_object('success', false, 'code', 'API_METADATA_REQUIRED',
      'message', 'API submission requires a provider, an external account identifier, and a credential reference.');
  end if;

  insert into public.carrier_factoring_integrations (
    organization_id, carrier_id, factoring_relationship_id, factoring_company_id,
    submission_method, provider, secret_reference, external_account_identifier, submission_destination, created_by
  ) values (
    v_org, v_relationship.carrier_id, v_relationship.id, v_relationship.factoring_company_id,
    v_relationship.submission_method, p_provider, p_secret_reference, p_external_account_identifier, p_submission_destination, v_uid
  )
  returning id, updated_at into v_new_id, v_updated_at;

  perform public.log_activity(
    'carrier'::public.entity_type, v_relationship.carrier_id, 'factoring_integration_configured',
    jsonb_build_object('integration_id', v_new_id, 'relationship_id', v_relationship.id, 'reason', p_reason),
    v_org);

  v_result := jsonb_build_object('success', true, 'integration_id', v_new_id, 'relationship_id', v_relationship.id,
    'carrier_id', v_relationship.carrier_id, 'configuration_status', 'draft', 'updated_at', v_updated_at);

  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result)
  values (v_org, 'configure', p_relationship_id, p_idempotency_key, v_result);

  return v_result;
exception
  when sqlstate 'F1401' then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'This change would leave an active factoring integration in an invalid state.');
end
$fn$;
revoke all on function public.configure_carrier_factoring_integration(uuid, text, text, public.integration_provider, text, text, timestamptz, text) from public, anon;
grant execute on function public.configure_carrier_factoring_integration(uuid, text, text, public.integration_provider, text, text, timestamptz, text) to authenticated;
comment on function public.configure_carrier_factoring_integration(uuid, text, text, public.integration_provider, text, text, timestamptz, text) is
  'Phase 3B.2 (0141): creates a NEW draft carrier_factoring_integrations row for an existing factoring relationship. Owner/admin only. Organization/carrier/factoring_company are all derived server-side from p_relationship_id -- never accepted as arguments. p_secret_reference must be an opaque, URI-shaped pointer (e.g. vault://...) or null; there is no raw-credential parameter anywhere in this signature. Does not activate anything -- see verify_/activate_carrier_factoring_integration().';

create function public.rotate_carrier_factoring_integration(
  p_integration_id uuid,
  p_secret_reference text,
  p_external_account_identifier text,
  p_provider public.integration_provider,
  p_submission_destination text,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_precheck jsonb;
  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;
  v_relationship_id uuid;
  v_old public.carrier_factoring_integrations%rowtype;
  v_new_id uuid;
  v_updated_at timestamptz;
  v_result jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may rotate a factoring integration''s credential reference.');
  end if;
  v_precheck := public.factoring_integration_lifecycle_precheck(p_reason, p_expected_updated_at, p_idempotency_key);
  if v_precheck is not null then return v_precheck; end if;
  if p_secret_reference is not null and p_secret_reference !~ '^[a-z][a-z0-9+.-]*://[A-Za-z0-9_.~-]{1,200}$' then
    return jsonb_build_object('success', false, 'code', 'OPAQUE_REFERENCE_REQUIRED',
      'message', 'The credential reference must be an opaque pointer (e.g. vault://...), never a raw secret.');
  end if;

  -- Resolve, without locking, purely to know which relationship row to
  -- lock first (same fixed order as every other lifecycle transition).
  select factoring_relationship_id into v_relationship_id
  from public.carrier_factoring_integrations where id = p_integration_id and organization_id = v_org;
  if v_relationship_id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring integration not found.');
  end if;
  perform 1 from public.factoring_relationships where id = v_relationship_id for update;
  select * into v_old from public.carrier_factoring_integrations where id = p_integration_id and organization_id = v_org for update;

  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = 'rotate' and target_id = p_integration_id and idempotency_key = p_idempotency_key;
  if found then
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_old.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_old.updated_at,
      'message', 'This factoring integration was changed by someone else. Please refresh and try again.');
  end if;
  if v_old.configuration_status = 'revoked' then
    return jsonb_build_object('success', false, 'code', 'REVOKED_TERMINAL', 'message', 'This integration is already revoked -- configure a new one instead of rotating it.');
  end if;

  -- Revoke the OLD row (history preserved, never overwritten) and insert
  -- a brand-new draft replacement atomically -- rotation deliberately
  -- requires another verification/activation cycle, never a silent
  -- credential swap on an already-ready row.
  update public.carrier_factoring_integrations set configuration_status = 'revoked', is_active = false where id = v_old.id;

  insert into public.carrier_factoring_integrations (
    organization_id, carrier_id, factoring_relationship_id, factoring_company_id,
    submission_method, provider, secret_reference, external_account_identifier, submission_destination, created_by
  ) values (
    v_org, v_old.carrier_id, v_old.factoring_relationship_id, v_old.factoring_company_id,
    v_old.submission_method, p_provider, p_secret_reference, p_external_account_identifier, p_submission_destination, v_uid
  )
  returning id, updated_at into v_new_id, v_updated_at;

  perform public.log_activity(
    'carrier'::public.entity_type, v_old.carrier_id, 'factoring_integration_rotated',
    jsonb_build_object('replaced_integration_id', v_old.id, 'integration_id', v_new_id, 'relationship_id', v_old.factoring_relationship_id, 'reason', p_reason),
    v_org);

  v_result := jsonb_build_object('success', true, 'integration_id', v_new_id, 'replaced_integration_id', v_old.id,
    'relationship_id', v_old.factoring_relationship_id, 'carrier_id', v_old.carrier_id, 'configuration_status', 'draft', 'updated_at', v_updated_at);

  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result)
  values (v_org, 'rotate', p_integration_id, p_idempotency_key, v_result);

  return v_result;
exception
  when sqlstate 'F1401' then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'This change would leave an active factoring integration in an invalid state.');
end
$fn$;
revoke all on function public.rotate_carrier_factoring_integration(uuid, text, text, public.integration_provider, text, text, timestamptz, text) from public, anon;
grant execute on function public.rotate_carrier_factoring_integration(uuid, text, text, public.integration_provider, text, text, timestamptz, text) to authenticated;
comment on function public.rotate_carrier_factoring_integration(uuid, text, text, public.integration_provider, text, text, timestamptz, text) is
  'Phase 3B.2 (0141): revokes the given integration and atomically creates a brand-new draft replacement carrying the new credential reference -- the OLD row''s identity and reference are never overwritten (guard_factoring_integration_lifecycle_transition enforces this structurally). The replacement always starts in draft and requires its own verify/activate cycle. Owner/admin only.';

-- =====================================================================
-- K. RELATIONSHIP DEACTIVATION -- rejects by default when an active
-- integration depends on the relationship; p_coordinated=true suspends
-- it first, atomically, with one audit event for the combined action.
-- =====================================================================
create function public.deactivate_factoring_relationship(
  p_relationship_id uuid,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text,
  p_coordinated boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_precheck jsonb;
  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;
  v_relationship record;
  v_active_count int;
  v_updated_at timestamptz;
  v_result jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may deactivate a factoring relationship.');
  end if;
  v_precheck := public.factoring_integration_lifecycle_precheck(p_reason, p_expected_updated_at, p_idempotency_key);
  if v_precheck is not null then return v_precheck; end if;

  select * into v_relationship from public.factoring_relationships where id = p_relationship_id and organization_id = v_org for update;
  if v_relationship.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Factoring relationship not found.');
  end if;

  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = 'deactivate_relationship' and target_id = p_relationship_id and idempotency_key = p_idempotency_key;
  if found then
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;

  if v_relationship.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_relationship.updated_at,
      'message', 'This factoring relationship was changed by someone else. Please refresh and try again.');
  end if;
  if not v_relationship.is_active then
    return jsonb_build_object('success', false, 'code', 'ALREADY_INACTIVE', 'message', 'This relationship is already inactive.');
  end if;

  select count(*) into v_active_count from public.carrier_factoring_integrations
    where factoring_relationship_id = v_relationship.id and is_active;
  if v_active_count > 0 and not p_coordinated then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'active_count', v_active_count,
      'message', format('This relationship has %s active factoring integration(s). Deactivate them first, or pass p_coordinated=true to deactivate them together with the relationship.', v_active_count));
  end if;

  if v_active_count > 0 then
    update public.carrier_factoring_integrations set configuration_status = 'suspended', is_active = false
      where factoring_relationship_id = v_relationship.id and is_active;
  end if;

  update public.factoring_relationships set is_active = false, is_default = false
    where id = v_relationship.id
    returning updated_at into v_updated_at;

  perform public.log_activity(
    'carrier'::public.entity_type, v_relationship.carrier_id, 'factoring_relationship_deactivated',
    jsonb_build_object('relationship_id', v_relationship.id, 'coordinated', p_coordinated, 'suspended_integrations', v_active_count, 'reason', p_reason),
    v_org);

  v_result := jsonb_build_object('success', true, 'relationship_id', v_relationship.id, 'carrier_id', v_relationship.carrier_id,
    'updated_at', v_updated_at, 'suspended_integrations', v_active_count);

  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result)
  values (v_org, 'deactivate_relationship', p_relationship_id, p_idempotency_key, v_result);

  return v_result;
exception
  when sqlstate 'F1401' then
    return jsonb_build_object('success', false, 'code', 'ACTIVE_INTEGRATION_DEPENDENCY', 'message', 'This change would leave an active factoring integration in an invalid state.');
end
$fn$;
revoke all on function public.deactivate_factoring_relationship(uuid, text, timestamptz, text, boolean) from public, anon;
grant execute on function public.deactivate_factoring_relationship(uuid, text, timestamptz, text, boolean) to authenticated;
comment on function public.deactivate_factoring_relationship(uuid, text, timestamptz, text, boolean) is
  'Phase 3B.2 (0141): deactivates a factoring relationship (is_active=false, is_default=false). Owner/admin only. REJECTS with ACTIVE_INTEGRATION_DEPENDENCY when the relationship has an active factoring integration, unless p_coordinated=true -- which suspends that integration first, atomically, in the SAME transaction and audit event, then deactivates the relationship. Ordinary direct UPDATEs cannot bypass this: the row-level, organization-scoped dependency guard (guard_factoring_lifecycle_dependencies) rejects any direct deactivation that would leave an active integration invalid, regardless of which code path performed it.';

-- =====================================================================
-- L. READINESS CLASSIFIER EXTENSION (item 5) -- api readiness now also
-- requires factoring_integration_lifecycle_problem() to return null for
-- the governing integration, not just is_active/configuration_status.
-- Every other branch of this function (0138/0139) is unchanged.
-- =====================================================================
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
    select status, factoring_eligible, factoring_ineligible_direct_billing_approved into v_party
    from public.carrier_brokers where carrier_id = p_carrier_id and broker_id = p_broker_id;
    if v_party.status is null or v_party.status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_inactive', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id);
    end if;
    if not v_party.factoring_eligible then
      if v_party.factoring_ineligible_direct_billing_approved then
        return jsonb_build_object('success', true, 'classification', 'carrier_party_direct_billing_exception', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id,
          'message', 'This broker relationship is billed directly under an explicitly approved exception.');
      end if;
      return jsonb_build_object('success', true, 'classification', 'carrier_party_ineligible', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id,
        'message', 'This broker relationship is not factoring-eligible and has no approved direct-billing exception -- blocked, not automatically billed directly.');
    end if;
  end if;
  if p_customer_id is not null then
    select status, factoring_eligible, factoring_ineligible_direct_billing_approved into v_party
    from public.carrier_customers where carrier_id = p_carrier_id and customer_id = p_customer_id;
    if v_party.status is null or v_party.status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_inactive', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id);
    end if;
    if not v_party.factoring_eligible then
      if v_party.factoring_ineligible_direct_billing_approved then
        return jsonb_build_object('success', true, 'classification', 'carrier_party_direct_billing_exception', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id,
          'message', 'This customer relationship is billed directly under an explicitly approved exception.');
      end if;
      return jsonb_build_object('success', true, 'classification', 'carrier_party_ineligible', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id,
        'message', 'This customer relationship is not factoring-eligible and has no approved direct-billing exception -- blocked, not automatically billed directly.');
    end if;
  end if;

  if v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', true, 'classification', 'factoring_policy_unconfigured', 'carrier_id', p_carrier_id);
  end if;
  if v_carrier.factoring_mode = 'direct' then
    return jsonb_build_object('success', true, 'classification', 'direct_billing', 'carrier_id', p_carrier_id);
  end if;

  select count(*) into v_default_count
  from public.factoring_relationships where carrier_id = p_carrier_id and is_default and is_active;
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

  if v_default.submission_method = 'api' then
    if (select count(*) from public.carrier_factoring_integrations where factoring_relationship_id = v_default.id and is_active) <> 1 then
      return jsonb_build_object('success', true, 'classification', 'api_integration_not_ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
    end if;
    if exists (
      select 1 from public.carrier_factoring_integrations i
      where i.factoring_relationship_id = v_default.id and i.is_active
        and public.factoring_integration_lifecycle_problem(i.id) is not null
    ) then
      return jsonb_build_object('success', true, 'classification', 'api_integration_not_ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
    end if;
  end if;

  return jsonb_build_object('success', true, 'classification', 'ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
end
$fn$;

-- =====================================================================
-- M. LEGACY submission_integration_id constraint (0136) removed -- API
-- readiness is now exclusively carrier-integration based (Section 5/
-- 0139's own carrier-scoped model). A relationship that still references
-- an org-level integration_settings row keeps that reference validated
-- (factoring_relationship_lifecycle_problem's own legacy_provider_
-- dependency_invalid branch); nothing REQUIRES one going forward.
-- =====================================================================
alter table public.factoring_relationships drop constraint if exists factoring_relationships_submission_integration_present;
comment on column public.factoring_relationships.submission_integration_id is
  'Legacy, optional org-level integration reference (0136). Phase 3B.2 (0141) removed the requirement that every API-method relationship have one -- carrier_factoring_integrations is now the sole, carrier-scoped source of API readiness. Still validated if present (factoring_relationship_lifecycle_problem).';

-- ======================= PHASE 3 -- POSTCONDITIONS ===========================
do $mig$
declare
  v_data_type text;
begin
  if (select data_type from information_schema.columns where table_schema='public' and table_name='carrier_factoring_integrations' and column_name='configuration_status') <> 'text' then
    raise exception '0141 postcondition: configuration_status is not text.';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cfi_ready_iff_active') then
    raise exception '0141 postcondition: cfi_ready_iff_active constraint missing.';
  end if;
  if has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'INSERT')
    or has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'UPDATE')
    or has_any_column_privilege('authenticated', 'public.carrier_factoring_integrations', 'INSERT')
    or has_any_column_privilege('authenticated', 'public.carrier_factoring_integrations', 'UPDATE')
  then
    raise exception '0141 postcondition: authenticated still has a direct write path to carrier_factoring_integrations.';
  end if;
  if not has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'SELECT') then
    raise exception '0141 postcondition: authenticated lost SELECT on carrier_factoring_integrations -- historical rows must remain readable.';
  end if;
  if has_function_privilege('authenticated', 'public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)', 'EXECUTE') then
    raise exception '0141 postcondition: the private lifecycle-transition function is exposed to authenticated.';
  end if;
  foreach v_data_type in array array['activate_carrier_factoring_integration(uuid,text,timestamptz,text)',
    'deactivate_carrier_factoring_integration(uuid,text,timestamptz,text)',
    'verify_carrier_factoring_integration(uuid,text,timestamptz,text)',
    'fail_carrier_factoring_integration(uuid,text,timestamptz,text)',
    'revoke_carrier_factoring_integration(uuid,text,timestamptz,text)']
  loop
    if not has_function_privilege('authenticated', 'public.' || v_data_type, 'EXECUTE') then
      raise exception '0141 postcondition: % is not executable by authenticated.', v_data_type;
    end if;
  end loop;
  if not has_function_privilege('authenticated', 'public.configure_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', 'EXECUTE') then
    raise exception '0141 postcondition: configure_carrier_factoring_integration is not executable by authenticated.';
  end if;
  if not has_function_privilege('authenticated', 'public.rotate_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)', 'EXECUTE') then
    raise exception '0141 postcondition: rotate_carrier_factoring_integration is not executable by authenticated.';
  end if;
  if not has_function_privilege('authenticated', 'public.deactivate_factoring_relationship(uuid,text,timestamptz,text,boolean)', 'EXECUTE') then
    raise exception '0141 postcondition: deactivate_factoring_relationship is not executable by authenticated.';
  end if;
  if exists (
    select 1 from public.carrier_factoring_integrations i
    where i.is_active and public.factoring_integration_lifecycle_problem(i.id) is not null
  ) then
    raise exception '0141 postcondition: an active integration violates the new lifecycle invariant immediately after apply.';
  end if;
  raise notice '0141 complete: carrier_factoring_integrations gains a six-state, transition-guarded lifecycle (draft/pending_verification/ready/suspended/revoked/failed) with is_active structurally tied to ready; direct authenticated INSERT/UPDATE/DELETE revoked; eight new owner/admin-only RPCs (configure/activate/deactivate/verify/fail/revoke/rotate_carrier_factoring_integration, deactivate_factoring_relationship) are the sole mutation path; a row-level, organization-scoped dependency guard prevents ANY relationship/policy/NOA/company/document/legacy-integration mutation -- new or existing RPC, or a direct write -- from leaving an active integration invalid; classify_carrier_factoring_readiness() now requires the same invariant for api_integration readiness. No invoice issuance, numbering, snapshot, or external transmission added. Migrations 0001-0140 untouched.';
end
$mig$;

commit;
