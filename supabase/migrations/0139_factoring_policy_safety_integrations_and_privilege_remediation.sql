-- =============================================================================
-- 0139_factoring_policy_safety_integrations_and_privilege_remediation.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0138 live. Phase 3B.1.1 ("Factoring Policy Safety, Per-Carrier
-- Integration Readiness, and Privilege Remediation").
--
-- PACKAGING DECISION (item 1's explicit question): 0136/0137/0138 were
-- uncommitted and unapplied, so the carriers.factoring_mode three-state
-- correction (item 1) and the classifier's new factoring_policy_
-- unconfigured branch were made DIRECTLY in 0136/0138 themselves (edited
-- in place, before their first commit) -- NOT here. Everything else in
-- this phase is genuinely NEW capability layered on top, so it lives in
-- this one additive migration rather than fragmenting into several. 0001-
-- 0135 are NOT touched anywhere in this phase.
--
-- WHAT THIS MIGRATION DOES
--   A. Privilege remediation (item 4): closes the Supabase default-
--      privilege-inheritance gap on EVERY provenance/audit/ledger/
--      idempotency table introduced in 0130-0138 that did not already
--      explicitly revoke insert/update/delete from authenticated (a full
--      matrix is in the report). carrier_backfill_0133_provenance is
--      explicitly named in the task and fixed here even though 0133
--      itself is an already-reviewed, unapplied-to-production migration
--      this phase leaves untouched -- the FIX is additive (0139), not a
--      rewrite of 0133.
--   B. Cutover safety hardening (item 8): a NOT VALID check constraint
--      requires carrier_id on any FUTURE insert/update of
--      factoring_relationships -- a legacy unresolved (carrier_id null)
--      row is grandfathered but becomes IMMUTABLE (any further write to
--      it, including one unrelated to carrier_id, is rejected) until its
--      carrier_id is resolved, matching "unresolved legacy relationships
--      must be immutable and unusable" verbatim.
--   C. Carrier-party explicit direct-billing exception (item 1, item 7):
--      carrier_brokers/carrier_customers gain an owner/admin-only-
--      approved exception flag -- factoring_eligible=false alone no
--      longer implies direct billing; it now requires this EXPLICIT
--      approval, or the classifier reports a blocking, unresolved state.
--   D. carrier_factoring_integrations (item 2): per-(carrier, relationship)
--      submission-channel configuration -- lets Carrier A use Factor API
--      A, Carrier B use Factor API B, Carrier D share Carrier A's factor
--      with different credentials, etc. No secrets stored -- only an
--      opaque secret_reference into an external vault/secret store.
--   E. set_carrier_factoring_policy(...) (item 6): the ONE sanctioned path
--      to change carriers.factoring_mode -- owner/admin only, reason
--      required, optimistic-concurrency-checked, idempotent, blocks
--      factored->direct while open factored-invoice activity exists,
--      validates readiness before allowing ->factored, writes an audit
--      event, returns a structured result.
--   F. classify_carrier_factoring_readiness(...) REPLACED again (item 7):
--      now carrier_factoring_integrations-aware
--      (api_integration_missing/api_integration_not_ready), and the
--      carrier-party branch distinguishes an EXPLICITLY-approved direct-
--      billing exception from a merely-ineligible (blocking, unresolved)
--      party.
--   G. approve_factoring_relationship_noa(...) REPLACED (item 9): now
--      validates the referenced document belongs to the SAME CARRIER (not
--      merely the same organization), is an allowed NOA document_type, and
--      is_verified=true -- and SNAPSHOTS the document's identity onto the
--      relationship at approval time, so a later edit/replacement of the
--      underlying documents row can never silently alter an already-
--      approved NOA (the generic documents table has no versioning
--      concept at all -- this snapshot is the "dedicated versioned
--      reference" item 9 allows building when the generic model can't
--      enforce this safely).
--   H. Column-privilege lockdown + RLS for carrier_factoring_integrations,
--      matching item 2's role rules exactly (owner/admin full access;
--      accountant/dispatcher get status ONLY, via
--      get_carrier_factoring_integration_status(), never the raw secret_
--      reference column; driver/viewer nothing).
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not implement external API transmission/submission of any kind
--   * does not begin invoice issuance
--   * does not modify migrations 0001-0135
--   * does not touch factored_invoices/factoring_events
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
begin
  if to_regclass('public.carrier_backfill_0137_provenance') is null then
    raise exception '0139 precondition: 0137 (carrier_backfill_0137_provenance) missing. STOP.';
  end if;
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is null then
    raise exception '0139 precondition: 0138 (classify_carrier_factoring_readiness) missing. STOP.';
  end if;
  if to_regclass('public.carrier_factoring_integrations') is not null then
    raise exception '0139 precondition: carrier_factoring_integrations already exists -- partial apply? STOP.';
  end if;
  if to_regprocedure('public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)') is not null then
    raise exception '0139 precondition: set_carrier_factoring_policy(...) already exists -- partial apply? STOP.';
  end if;
  raise notice '0139 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- =====================================================================
-- A. PRIVILEGE REMEDIATION (item 4) -- close the Supabase default-
-- privilege-inheritance gap on every provenance/audit/ledger/idempotency
-- table from 0130-0138 that had not already explicitly revoked authenticated
-- insert/update/delete. RLS-enabled-with-no-write-policy already makes
-- these writes a structural no-op (Postgres denies a command outright when
-- RLS is on and no policy matches it, REGARDLESS of the underlying GRANT)
-- -- this migration closes the gap at the GRANT layer too, so both layers
-- agree and has_table_privilege() itself reports the true intended state,
-- not just "RLS happens to save us."
-- =====================================================================

-- unresolved_carrier_records (0130): UPDATE is intentionally granted
-- (owner/admin resolve exceptions via UPDATE, per its own RLS policy) --
-- INSERT and DELETE were never explicitly revoked from authenticated.
revoke insert, delete on public.unresolved_carrier_records from authenticated;

-- financial_idempotency_keys (0130): read-only ledger for authenticated;
-- INSERT/UPDATE/DELETE were never explicitly revoked.
revoke insert, update, delete on public.financial_idempotency_keys from authenticated;

-- carrier_backfill_0133_provenance (0133): the table explicitly named in
-- this task. 0133 itself is untouched (still unapplied to production) --
-- this is a pure additive REVOKE in a later migration, not a rewrite.
revoke insert, update, delete on public.carrier_backfill_0133_provenance from authenticated, anon;

-- Bonus finding (same class of gap, discovered while auditing 0130-0138):
-- carrier_remittance_profiles (0130) and carrier_brokers/carrier_customers
-- (0131) explicitly grant select/insert/update but never explicitly
-- revoke DELETE -- all three already have "no DELETE policy" at the RLS
-- layer (per their own 0130/0131 comments), so this closes the same
-- belt-and-braces gap at the GRANT layer.
revoke delete on public.carrier_remittance_profiles from authenticated;
revoke delete on public.carrier_brokers from authenticated;
revoke delete on public.carrier_customers from authenticated;

-- trailer_ownership_scope_audit (0132), dispatch_status_transitions
-- (0134), dispatch_resource_reassignments (0135), carrier_backfill_0137_
-- provenance (0137): already correctly revoke insert/update/delete from
-- authenticated explicitly -- confirmed by inspection, no action needed;
-- listed here (as a comment) so the audit trail of what was checked is
-- complete, not just what was fixed.

-- =====================================================================
-- B. CUTOVER SAFETY HARDENING (item 8): a legacy unresolved (carrier_id
-- null) factoring_relationships row is grandfathered by NOT VALID (existing
-- rows are never re-validated at ALTER time) but becomes IMMUTABLE for any
-- FUTURE write -- any INSERT/UPDATE against a null-carrier row (including
-- one that never touches carrier_id) is rejected unless that same
-- statement also resolves carrier_id. This is exactly "unresolved legacy
-- relationships must be immutable and unusable for new invoice issuance"
-- -- resolution requires setting carrier_id in the same write, which is
-- itself the act of resolving it (an explicit, deliberate, out-of-band
-- correction -- exactly like unresolved_carrier_records' own
-- resolved_by/resolution_note pattern, never a silent guess).
-- =====================================================================
alter table public.factoring_relationships
  add constraint factoring_relationships_new_writes_need_carrier
  check (carrier_id is not null) not valid;

comment on constraint factoring_relationships_new_writes_need_carrier on public.factoring_relationships is
  'Phase 3B.1.1 (item 8). NOT VALID: existing (0137-backfill-era) null-carrier rows are grandfathered, never retroactively rejected -- but any FUTURE write to factoring_relationships (insert or update, including a legacy row) must leave carrier_id non-null, or it is rejected outright. Makes an unresolved legacy relationship structurally immutable until its carrier_id is explicitly resolved as part of the very write that fixes it.';

-- set_default_factoring_relationship() (0138) already rejects a null-
-- carrier_id relationship (errcode SFCAR) -- confirmed by inspection, not
-- re-implemented here.

-- =====================================================================
-- C. CARRIER-PARTY EXPLICIT DIRECT-BILLING EXCEPTION (items 1, 7): the
-- OLD design let factoring_eligible=false alone silently imply "direct
-- billing for this party" -- an automatic guess. Now it requires an
-- EXPLICIT, owner/admin-approved exception; without it, an ineligible
-- party is a BLOCKING, unresolved state, not an automatic fallback.
-- =====================================================================
alter table public.carrier_brokers
  add column factoring_ineligible_direct_billing_approved boolean not null default false,
  add column factoring_ineligible_direct_billing_approved_by uuid references public.profiles (id) on delete set null,
  add column factoring_ineligible_direct_billing_approved_at timestamptz,
  add constraint carrier_brokers_direct_billing_exception_complete check (
    not factoring_ineligible_direct_billing_approved
    or (factoring_ineligible_direct_billing_approved_by is not null and factoring_ineligible_direct_billing_approved_at is not null)
  );
alter table public.carrier_customers
  add column factoring_ineligible_direct_billing_approved boolean not null default false,
  add column factoring_ineligible_direct_billing_approved_by uuid references public.profiles (id) on delete set null,
  add column factoring_ineligible_direct_billing_approved_at timestamptz,
  add constraint carrier_customers_direct_billing_exception_complete check (
    not factoring_ineligible_direct_billing_approved
    or (factoring_ineligible_direct_billing_approved_by is not null and factoring_ineligible_direct_billing_approved_at is not null)
  );

comment on column public.carrier_brokers.factoring_ineligible_direct_billing_approved is
  'Phase 3B.1.1 (items 1, 7): explicit, owner/admin-only approval that THIS party is billed directly despite factoring_eligible=false. Without it, an ineligible party classifies as a BLOCKING carrier_party_ineligible state (unresolved), never an automatic direct-billing guess.';
comment on column public.carrier_customers.factoring_ineligible_direct_billing_approved is
  'Same as carrier_brokers.factoring_ineligible_direct_billing_approved.';

-- Owner/admin-only guard for the exception flag (same trusted-service-
-- context convention as guard_factoring_relationship_protected_fields,
-- 0136): auth.uid() is null for a migration/service context and is
-- trusted; an interactive (JWT-bearing) caller must be owner/admin.
create or replace function public.guard_carrier_party_direct_billing_exception()
returns trigger
language plpgsql
as $$
declare
  v_uid uuid := auth.uid();
  v_touched boolean;
begin
  if v_uid is null then
    return new;
  end if;
  if tg_op = 'INSERT' then
    v_touched := coalesce(new.factoring_ineligible_direct_billing_approved, false);
  else
    v_touched :=
      new.factoring_ineligible_direct_billing_approved is distinct from old.factoring_ineligible_direct_billing_approved
      or new.factoring_ineligible_direct_billing_approved_by is distinct from old.factoring_ineligible_direct_billing_approved_by
      or new.factoring_ineligible_direct_billing_approved_at is distinct from old.factoring_ineligible_direct_billing_approved_at;
  end if;
  if v_touched and not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'guard_carrier_party_direct_billing_exception: only an owner or admin may approve the ineligible-party direct-billing exception.' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists carrier_brokers_guard_direct_billing_exception on public.carrier_brokers;
create trigger carrier_brokers_guard_direct_billing_exception
  before insert or update on public.carrier_brokers
  for each row execute function public.guard_carrier_party_direct_billing_exception();

drop trigger if exists carrier_customers_guard_direct_billing_exception on public.carrier_customers;
create trigger carrier_customers_guard_direct_billing_exception
  before insert or update on public.carrier_customers
  for each row execute function public.guard_carrier_party_direct_billing_exception();

-- =====================================================================
-- D. carrier_factoring_integrations (item 2) -- per-(carrier,
-- relationship) submission-channel configuration.
-- =====================================================================
create type public.integration_configuration_status as enum (
  'draft', 'pending_approval', 'active', 'disabled', 'expired'
);

create table public.carrier_factoring_integrations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  factoring_relationship_id uuid not null references public.factoring_relationships (id) on delete restrict,
  factoring_company_id uuid not null references public.factoring_companies (id) on delete restrict,
  submission_method public.factoring_submission_method not null,
  provider public.integration_provider,
  -- NEVER a raw secret -- an opaque reference into Supabase Vault, an
  -- environment-managed credential store, or an approved integration-
  -- secret system (item 2's explicit rule). Enforced structurally by
  -- the "no secret-shaped column" test, matching factoring_relationships'
  -- own posture (0136).
  secret_reference text,
  external_account_identifier text,
  submission_destination text,
  configuration_status public.integration_configuration_status not null default 'draft',
  is_active boolean not null default false,
  effective_from date not null default current_date,
  effective_to date,
  created_by uuid references public.profiles (id) on delete set null,
  approved_by uuid references public.profiles (id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cfi_valid_effective_range check (effective_to is null or effective_from is null or effective_to >= effective_from),
  constraint cfi_active_requires_approval check (not is_active or (approved_by is not null and approved_at is not null)),
  constraint cfi_secure_email_destination check (
    submission_method is distinct from 'secure_email'::public.factoring_submission_method
    or (submission_destination is not null and submission_destination ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
  ),
  constraint cfi_api_requires_secret_ref check (
    submission_method is distinct from 'api'::public.factoring_submission_method or secret_reference is not null
  ),
  constraint cfi_portal_requires_instructions check (
    submission_method is distinct from 'portal_manual'::public.factoring_submission_method or submission_destination is not null
  )
);

comment on table public.carrier_factoring_integrations is
  'Phase 3B.1.1 (item 2): per-carrier, per-relationship submission-channel configuration -- lets different carriers use different factors/credentials/methods, and the same factor with different credentials per carrier. secret_reference is an OPAQUE pointer only; no raw secret is ever stored here. Configuration status never implies external transmission has occurred (item 3).';

-- At most one ACTIVE integration per relationship -- a relationship has
-- one submission channel in effect at a time (item 2: "at most one active
-- submission integration for a specific purpose unless multiple endpoints
-- are explicitly supported" -- multiple endpoints are not yet a supported
-- concept in this phase, so this is unconditional for now).
create unique index cfi_one_active_per_relationship
  on public.carrier_factoring_integrations (factoring_relationship_id)
  where is_active;

create trigger set_updated_at before update on public.carrier_factoring_integrations
  for each row execute function public.set_updated_at();

-- Org/carrier/company/relationship consistency (item 2: "the relationship,
-- carrier, factoring company, and organization must match"). Fires on
-- INSERT and UPDATE -- matches 0136's own extended guard's posture.
create or replace function public.guard_carrier_factoring_integration_org()
returns trigger
language plpgsql
as $$
declare
  v_carrier_org uuid;
  v_rel_org uuid; v_rel_carrier uuid; v_rel_company uuid;
  v_company_org uuid;
begin
  select organization_id into v_carrier_org from public.carriers where id = new.carrier_id;
  if v_carrier_org is null or v_carrier_org <> new.organization_id then
    raise exception 'carrier_factoring_integrations: carrier must belong to the same organization.';
  end if;

  select organization_id, carrier_id, factoring_company_id into v_rel_org, v_rel_carrier, v_rel_company
  from public.factoring_relationships where id = new.factoring_relationship_id;
  if v_rel_org is null or v_rel_org <> new.organization_id then
    raise exception 'carrier_factoring_integrations: factoring_relationship must belong to the same organization.';
  end if;
  if v_rel_carrier is distinct from new.carrier_id then
    raise exception 'carrier_factoring_integrations: factoring_relationship must belong to the SAME carrier as this integration -- Carrier A cannot use Carrier B''s relationship.';
  end if;
  if v_rel_company <> new.factoring_company_id then
    raise exception 'carrier_factoring_integrations: factoring_company must match the factoring_relationship''s own company.';
  end if;

  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'carrier_factoring_integrations: factoring_company must belong to the same organization.';
  end if;

  return new;
end;
$$;

drop trigger if exists carrier_factoring_integrations_guard_org on public.carrier_factoring_integrations;
create trigger carrier_factoring_integrations_guard_org
  before insert or update on public.carrier_factoring_integrations
  for each row execute function public.guard_carrier_factoring_integration_org();

-- RLS + grants (item 2's role rules): owner/admin get full row access
-- (including secret_reference); accountant/dispatcher get NEITHER select
-- NOR write on the raw table -- they read status exclusively through
-- get_carrier_factoring_integration_status() below, which never returns
-- secret_reference. driver/viewer: nothing, anywhere.
alter table public.carrier_factoring_integrations enable row level security;

create policy carrier_factoring_integrations_select on public.carrier_factoring_integrations
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));
create policy carrier_factoring_integrations_insert on public.carrier_factoring_integrations
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));
create policy carrier_factoring_integrations_update on public.carrier_factoring_integrations
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]))
  with check (organization_id = public.current_org_id());
-- No DELETE policy -- inactivate (is_active=false / configuration_status=
-- 'disabled'), never delete, matching every other financial-adjacent
-- config table in this schema.

revoke all on public.carrier_factoring_integrations from anon;
revoke all on public.carrier_factoring_integrations from authenticated;
grant select, insert, update on public.carrier_factoring_integrations to authenticated;
-- RLS above is what actually narrows this to owner/admin -- the table-
-- level grant alone would (per the Supabase default-privilege lesson,
-- item 4) otherwise look broader than intended; explicit REGRANT-from-
-- scratch here proves-by-construction the final grant, matching this
-- migration's own privilege-remediation section A.

-- Non-secret status reader for accountant/dispatcher (and owner/admin) --
-- item 2: "accountant may view non-secret configuration status but not
-- credentials," "dispatcher may see readiness and submission status but
-- not secrets." SECURITY DEFINER so it can read the RLS-restricted base
-- table on their behalf, returning only non-secret columns.
create or replace function public.get_carrier_factoring_integration_status(p_carrier_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_carrier_org uuid;
  v_result jsonb;
begin
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]) then
    return jsonb_build_object('success', false, 'message', 'Not permitted.');
  end if;
  select organization_id into v_carrier_org from public.carriers where id = p_carrier_id;
  if v_carrier_org is null or v_carrier_org <> v_org then
    return jsonb_build_object('success', false, 'message', 'Carrier not found.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id,
    'factoring_relationship_id', i.factoring_relationship_id,
    'submission_method', i.submission_method,
    'provider', i.provider,
    'external_account_identifier', i.external_account_identifier,
    'configuration_status', i.configuration_status,
    'is_active', i.is_active,
    'effective_from', i.effective_from,
    'effective_to', i.effective_to
  ) order by i.created_at desc), '[]'::jsonb)
    into v_result
  from public.carrier_factoring_integrations i
  where i.carrier_id = p_carrier_id and i.organization_id = v_org;

  return jsonb_build_object('success', true, 'carrier_id', p_carrier_id, 'integrations', v_result);
end;
$fn$;

revoke all on function public.get_carrier_factoring_integration_status(uuid) from public;
grant execute on function public.get_carrier_factoring_integration_status(uuid) to authenticated;

comment on function public.get_carrier_factoring_integration_status(uuid) is
  'Phase 3B.1.1 (item 2): the ONLY way accountant/dispatcher may read carrier_factoring_integrations -- never secret_reference. Owner/admin may also read the raw table directly (RLS permits it) for full management.';

-- =====================================================================
-- E. set_carrier_factoring_policy(...) (item 6) -- the ONE sanctioned
-- path to change carriers.factoring_mode.
-- =====================================================================
create table public.factoring_policy_idempotency (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  idempotency_key text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (carrier_id, idempotency_key)
);

alter table public.factoring_policy_idempotency enable row level security;
create policy factoring_policy_idempotency_select on public.factoring_policy_idempotency
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));
revoke all on public.factoring_policy_idempotency from anon;
revoke all on public.factoring_policy_idempotency from authenticated;
grant select on public.factoring_policy_idempotency to authenticated;

create or replace function public.set_carrier_factoring_policy(
  p_carrier_id uuid,
  p_mode public.carrier_factoring_mode,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_carrier record;
  v_cached jsonb;
  v_open_activity int;
  v_readiness jsonb;
begin
  if v_uid is null then
    raise exception 'set_carrier_factoring_policy: authentication required.' using errcode = 'FPAUT';
  end if;
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'set_carrier_factoring_policy: caller has no organization.' using errcode = 'FPAUT';
  end if;
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'set_carrier_factoring_policy: only an owner or admin may change a carrier''s factoring policy.' using errcode = 'FPROL';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'set_carrier_factoring_policy: a reason is required.' using errcode = 'FPRSN';
  end if;

  if p_idempotency_key is not null then
    select result into v_cached from public.factoring_policy_idempotency
      where carrier_id = p_carrier_id and idempotency_key = p_idempotency_key;
    if found then
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('carrier_factoring_policy:' || p_carrier_id::text));

  select id, organization_id, factoring_mode, updated_at into v_carrier
  from public.carriers where id = p_carrier_id for update;

  if v_carrier.id is null or v_carrier.organization_id <> v_org then
    raise exception 'set_carrier_factoring_policy: carrier not found.' using errcode = 'FPDNF';
  end if;

  -- Optimistic concurrency (mirrors reassign_dispatch_resources, 0135):
  -- a mismatch is a STRUCTURED result, never an exception -- no write.
  if p_expected_updated_at is null then
    return jsonb_build_object('success', false, 'expected_version_required', true, 'carrier_id', p_carrier_id,
      'current_updated_at', v_carrier.updated_at,
      'message', 'This policy change requires the version of the carrier you loaded. Please reload and try again.');
  end if;
  if v_carrier.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'stale_record', true, 'carrier_id', p_carrier_id,
      'current_updated_at', v_carrier.updated_at,
      'message', 'This carrier was changed by someone else. Please refresh and try again.');
  end if;

  if v_carrier.factoring_mode = p_mode then
    v_readiness := jsonb_build_object('success', true, 'no_op', true, 'carrier_id', p_carrier_id, 'mode', p_mode);
  else
    -- factored -> direct: block if open factored-invoice activity exists.
    if v_carrier.factoring_mode = 'factored' and p_mode = 'direct' then
      select count(*) into v_open_activity
      from public.factored_invoices fi
      join public.factoring_relationships fr on fr.id = fi.factoring_relationship_id
      where fr.carrier_id = p_carrier_id
        and fi.status not in ('rejected', 'cancelled', 'closed');
      if v_open_activity > 0 then
        return jsonb_build_object('success', false, 'blocked', true, 'reason', 'open_factored_activity',
          'carrier_id', p_carrier_id, 'open_count', v_open_activity,
          'message', format('This carrier has %s open factored invoice(s) in flight -- resolve or close them before switching to direct billing.', v_open_activity));
      end if;
    end if;

    -- ->factored: must be ready (mirrors the classifier's own logic,
    -- re-derived here rather than calling the classifier, which itself
    -- reads factoring_mode and would be circular mid-transition).
    if p_mode = 'factored' then
      if not exists (
        select 1 from public.factoring_relationships fr
        join public.factoring_companies fc on fc.id = fr.factoring_company_id
        where fr.carrier_id = p_carrier_id and fr.is_default and fr.is_active and fc.is_active
          and (fr.effective_from is null or fr.effective_from <= current_date)
          and (fr.effective_to is null or fr.effective_to >= current_date)
          and fr.remittance_instructions is not null and btrim(fr.remittance_instructions) <> ''
          and fr.noa_approved
          and fr.submission_method is not null
      ) then
        return jsonb_build_object('success', false, 'not_ready', true, 'carrier_id', p_carrier_id,
          'message', 'This carrier has no complete, ready default factoring relationship yet -- see classify_carrier_factoring_readiness() for exactly what is missing.');
      end if;
    end if;

    update public.carriers set factoring_mode = p_mode where id = p_carrier_id;

    perform public.log_activity(
      'carrier'::public.entity_type, p_carrier_id, 'factoring_policy_changed',
      jsonb_build_object('old_mode', v_carrier.factoring_mode, 'new_mode', p_mode, 'reason', p_reason),
      v_org);

    v_readiness := jsonb_build_object('success', true, 'no_op', false, 'carrier_id', p_carrier_id, 'mode', p_mode);
  end if;

  if p_idempotency_key is not null then
    insert into public.factoring_policy_idempotency (organization_id, carrier_id, idempotency_key, result)
    values (v_org, p_carrier_id, p_idempotency_key, v_readiness)
    on conflict (carrier_id, idempotency_key) do nothing;
  end if;

  return v_readiness;
end;
$fn$;

revoke all on function public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text) from public;
grant execute on function public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text) to authenticated;

comment on function public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text) is
  'Phase 3B.1.1 (item 6): the ONE sanctioned path to change carriers.factoring_mode. Owner/admin only, reason required, optimistic-concurrency-checked (expected_updated_at mandatory), idempotent, blocks factored->direct while open factored-invoice activity exists, validates readiness before allowing ->factored, writes one audit event via log_activity(). Never exposes a secret. Direct table UPDATE of factoring_mode is revoked from authenticated (see the column-privilege lockdown below).';

-- factoring_mode column-privilege lockdown -- no direct browser update,
-- ever; only this RPC. carriers has never had a column-level UPDATE
-- lockdown before this migration -- it still carries a blanket TABLE-
-- LEVEL UPDATE grant to authenticated (its original, unmodified 0003
-- grant), so a column-level "revoke update (factoring_mode)" alone would
-- be a no-op (Postgres column-level REVOKE only removes a privilege that
-- was itself granted at the column level; it does not narrow a broader
-- table-level grant that already covers that column). REGRANTing from
-- scratch -- same rationale as 0132/0134/0135/0138's own narrowing --
-- proves-by-construction that the final permitted set is EXACTLY every
-- other column, matching the actual current column set (0003 base +
-- 0069's removal of dispatch_fee_percentage/payment_terms_days/
-- factoring_company_name + 0125's load_proceeds_model + 0130's
-- invoice_code/dispatch_service_terms_days). factoring_mode itself is
-- excluded from this list on purpose.
revoke update on public.carriers from authenticated;
grant update (
  legal_name, dba_name, mc_number, dot_number, ein, contact_name, phone, email,
  address_line1, address_line2, city, state, postal_code, country, notes,
  is_active, onboarded_at, load_proceeds_model, invoice_code, dispatch_service_terms_days
) on public.carriers to authenticated;

comment on column public.carriers.factoring_mode is
  'AR-side factoring policy for THIS carrier''s invoices (Phase 3B.1, item 3; Phase 3B.1.1, items 1, 6). Three states: ''unconfigured'' (default -- blocks invoice issuance outright until explicitly set) / ''direct'' / ''factored''. UPDATE is revoked from authenticated at the TABLE level for this column (0139) -- changed ONLY via public.set_carrier_factoring_policy(), owner/admin, reason + audit event required. Distinct from the historical carriers.factoring_company_name (0003), removed in 0069 and relocated to carrier_financials (0070) -- an unrelated AP-side settlement-payee hint, never this column.';

-- =====================================================================
-- F. classify_carrier_factoring_readiness(...) -- REPLACED again (item 7):
-- integrations-aware, explicit-exception-aware. Same signature as 0138.
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
  v_integration record;
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

  -- Carrier-party gate: checked before mode-based classification,
  -- regardless of mode. factoring_eligible=false is now BLOCKING
  -- (carrier_party_ineligible) unless an EXPLICIT, owner/admin-approved
  -- direct-billing exception exists for this specific party (item 1, 7)
  -- -- never an automatic guess.
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

  -- factoring_mode = 'factored' from here.
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

  -- Item 7: api-method readiness now depends on carrier_factoring_
  -- integrations, not merely factoring_relationships.submission_integration_id.
  if v_default.submission_method = 'api' then
    select configuration_status, is_active, effective_from, effective_to into v_integration
    from public.carrier_factoring_integrations
    where factoring_relationship_id = v_default.id and carrier_id = p_carrier_id
    order by is_active desc, created_at desc
    limit 1;

    if v_integration.configuration_status is null then
      return jsonb_build_object('success', true, 'classification', 'api_integration_missing', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
    end if;
    if not v_integration.is_active or v_integration.configuration_status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'api_integration_not_ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'configuration_status', v_integration.configuration_status);
    end if;
    if v_integration.effective_to is not null and v_integration.effective_to < current_date then
      return jsonb_build_object('success', true, 'classification', 'api_integration_not_ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'configuration_status', 'expired');
    end if;
  end if;

  return jsonb_build_object('success', true, 'classification', 'ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
end;
$fn$;

revoke all on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) from public;
grant execute on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) to authenticated;

comment on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) is
  'Phase 3B.1/3B.1.1 read-only carrier-factor classifier and preview RPC. Never creates an invoice, submission, package, payment, or financial event; never returns a secret (secret_reference is never selected). Classifications: factoring_policy_unconfigured, direct_billing, no_factoring_configuration, no_default, default_inactive, default_expired, default_not_yet_effective, factoring_company_inactive, relationship_incomplete, multiple_defaults, api_integration_missing, api_integration_not_ready, carrier_party_inactive, carrier_party_ineligible, carrier_party_direct_billing_exception, ready, error.';

-- =====================================================================
-- G. approve_factoring_relationship_noa(...) -- REPLACED (item 9):
-- validates the document belongs to the SAME CARRIER, is an allowed NOA
-- type, and is verified; snapshots its identity so a later document edit
-- can never silently alter an already-approved NOA.
-- =====================================================================
alter table public.factoring_relationships
  add column noa_document_snapshot_file_name text,
  add column noa_document_snapshot_file_path text;

comment on column public.factoring_relationships.noa_document_snapshot_file_path is
  'Phase 3B.1.1 (item 9): the referenced document''s file_path/file_name AT THE MOMENT of NOA approval. The generic documents table has no versioning concept -- this snapshot is what keeps an already-approved NOA''s identity frozen even if that documents row is later edited or replaced.';

create or replace function public.approve_factoring_relationship_noa(
  p_relationship_id uuid,
  p_noa_reference text,
  p_noa_effective_date date,
  p_noa_template_text text default null,
  p_noa_document_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_relationship record;
  v_doc record;
begin
  if v_uid is null then
    raise exception 'approve_factoring_relationship_noa: authentication required.' using errcode = 'ANAUT';
  end if;
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'approve_factoring_relationship_noa: caller has no organization.' using errcode = 'ANAUT';
  end if;
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'approve_factoring_relationship_noa: only an owner or admin may approve a Notice of Assignment.' using errcode = 'ANROL';
  end if;
  if p_noa_reference is null or btrim(p_noa_reference) = '' then
    raise exception 'approve_factoring_relationship_noa: a reference/version is required.' using errcode = 'ANVAL';
  end if;
  if p_noa_effective_date is null then
    raise exception 'approve_factoring_relationship_noa: an effective date is required.' using errcode = 'ANVAL';
  end if;
  if p_noa_template_text is null and p_noa_document_id is null then
    raise exception 'approve_factoring_relationship_noa: either approved template language or an approved document reference is required.' using errcode = 'ANVAL';
  end if;

  select id, organization_id, carrier_id into v_relationship
  from public.factoring_relationships where id = p_relationship_id
  for update;

  if v_relationship.id is null or v_relationship.organization_id <> v_org then
    raise exception 'approve_factoring_relationship_noa: this factoring relationship is not available.' using errcode = 'ANDNF';
  end if;
  if v_relationship.carrier_id is null then
    raise exception 'approve_factoring_relationship_noa: this relationship has no resolved carrier -- its Notice of Assignment cannot be approved until one is.' using errcode = 'ANCAR';
  end if;

  if p_noa_document_id is not null then
    select organization_id, entity_type, entity_id, document_type, is_verified, file_name, file_path
      into v_doc
    from public.documents where id = p_noa_document_id;

    if v_doc.organization_id is null or v_doc.organization_id <> v_org then
      raise exception 'approve_factoring_relationship_noa: the referenced document does not belong to this organization.' using errcode = 'ANVAL';
    end if;
    -- Item 9: Carrier A must never be able to approve Carrier B's
    -- document -- the document must be filed directly against THIS
    -- relationship's own carrier.
    if v_doc.entity_type <> 'carrier'::public.entity_type or v_doc.entity_id <> v_relationship.carrier_id then
      raise exception 'approve_factoring_relationship_noa: the referenced document must belong to this relationship''s own carrier.' using errcode = 'ANVAL';
    end if;
    if v_doc.document_type not in ('notice_of_assignment'::public.document_type, 'factoring_notice'::public.document_type) then
      raise exception 'approve_factoring_relationship_noa: the referenced document must be a notice_of_assignment or factoring_notice document type.' using errcode = 'ANVAL';
    end if;
    if not coalesce(v_doc.is_verified, false) then
      raise exception 'approve_factoring_relationship_noa: the referenced document must be verified before it can be used as an approved Notice of Assignment.' using errcode = 'ANVAL';
    end if;
  end if;

  update public.factoring_relationships
  set noa_template_text = p_noa_template_text,
      noa_document_id = p_noa_document_id,
      noa_document_snapshot_file_name = v_doc.file_name,
      noa_document_snapshot_file_path = v_doc.file_path,
      noa_reference = p_noa_reference,
      noa_effective_date = p_noa_effective_date,
      noa_approved = true,
      noa_approved_by = v_uid,
      noa_approved_at = now()
  where id = p_relationship_id;

  perform public.log_activity(
    'carrier'::public.entity_type, v_relationship.carrier_id, 'factoring_noa_approved',
    jsonb_build_object('relationship_id', p_relationship_id, 'noa_reference', p_noa_reference, 'noa_effective_date', p_noa_effective_date,
                        'noa_document_id', p_noa_document_id),
    v_org);

  return jsonb_build_object('success', true, 'relationship_id', p_relationship_id, 'carrier_id', v_relationship.carrier_id);
end;
$fn$;

revoke all on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) from public;
grant execute on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) to authenticated;

comment on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) is
  'Phase 3B.1.1 (item 9): validates the referenced document belongs to the SAME organization AND the relationship''s own carrier (never a different carrier''s document), is document_type notice_of_assignment/factoring_notice, and is_verified=true -- then snapshots its file identity onto the relationship so a later edit of the documents row can never silently alter an already-approved NOA. Owner/admin only.';

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
begin
  if has_table_privilege('authenticated','public.unresolved_carrier_records','INSERT')
     or has_table_privilege('authenticated','public.unresolved_carrier_records','DELETE') then
    raise exception '0139 postcondition: authenticated can INSERT or DELETE unresolved_carrier_records directly.';
  end if;
  if has_table_privilege('authenticated','public.financial_idempotency_keys','INSERT')
     or has_table_privilege('authenticated','public.financial_idempotency_keys','UPDATE')
     or has_table_privilege('authenticated','public.financial_idempotency_keys','DELETE') then
    raise exception '0139 postcondition: authenticated can write financial_idempotency_keys directly.';
  end if;
  if has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','INSERT')
     or has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','UPDATE')
     or has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','DELETE') then
    raise exception '0139 postcondition: authenticated can write carrier_backfill_0133_provenance directly.';
  end if;

  if to_regclass('public.carrier_factoring_integrations') is null then
    raise exception '0139 postcondition: carrier_factoring_integrations missing.';
  end if;
  if to_regprocedure('public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)') is null then
    raise exception '0139 postcondition: set_carrier_factoring_policy(...) missing.';
  end if;
  if has_table_privilege('authenticated','public.carriers','UPDATE') then
    raise exception '0139 postcondition: authenticated holds a TABLE-LEVEL UPDATE grant on carriers -- must be column-scoped only.';
  end if;
  if has_column_privilege('authenticated','public.carriers','factoring_mode','UPDATE') then
    raise exception '0139 postcondition: authenticated can UPDATE carriers.factoring_mode directly.';
  end if;
  if not has_column_privilege('authenticated','public.carriers','is_active','UPDATE') then
    raise exception '0139 postcondition: authenticated should still be able to UPDATE carriers.is_active directly (operational field, unaffected by this lockdown).';
  end if;
  -- secret_reference has no column-level distinction from the rest of the
  -- row (Postgres GRANTs cannot vary by application org_role -- every
  -- interactive caller shares the authenticated DB role) -- owner/admin's
  -- own legitimate need to read it is what the table-level GRANT above
  -- serves; RLS is what actually narrows SELECT to owner/admin only,
  -- so THAT is what must be verified here, not the grant.
  if not (select relrowsecurity from pg_class where oid = 'public.carrier_factoring_integrations'::regclass) then
    raise exception '0139 postcondition: carrier_factoring_integrations does not have row level security enabled.';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'carrier_factoring_integrations'
      and policyname = 'carrier_factoring_integrations_select' and cmd = 'SELECT'
  ) then
    raise exception '0139 postcondition: carrier_factoring_integrations_select policy missing -- secret_reference would be readable by any authenticated org member.';
  end if;
  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'carrier_factoring_integrations'
      and policyname <> 'carrier_factoring_integrations_select' and cmd = 'SELECT'
  ) then
    raise exception '0139 postcondition: an unexpected extra SELECT policy exists on carrier_factoring_integrations.';
  end if;

  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is null then
    raise exception '0139 postcondition: classifier missing after replace.';
  end if;

  raise notice '0139 complete: privilege remediation applied across 0130-0138''s provenance/audit/ledger/idempotency tables; factoring_relationships hardened against unresolved-legacy mutation; carrier-party explicit direct-billing exception installed; carrier_factoring_integrations + status reader installed; set_carrier_factoring_policy(...) installed with factoring_mode locked down to RPC-only; classifier + NOA approval replaced to be integration- and carrier-ownership-aware. No invoice issuance, submission, or external transmission added. Migrations 0001-0135 untouched.';
end
$mig$;

commit;
