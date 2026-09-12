-- =============================================================================
-- 0138_carrier_default_cutover_classifier_and_secured_rpcs.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0137 live. Phase 3B.1, part 3 of 3 (final). Cuts over from
-- organization-level to CARRIER-level default-factor semantics, installs
-- the readiness classifier (also usable as a safe preview RPC, item 11),
-- revises set_default_factoring_relationship() to be carrier-scoped and
-- owner/admin-only, adds approve_factoring_relationship_noa(), and locks
-- down factoring_relationships' column privileges so no direct
-- authenticated write can touch carrier ownership, the default flag, or
-- remittance/NOA configuration.
--
-- WHAT THIS MIGRATION DOES
--   A. CUTOVER (item 4): creates the NEW carrier-scoped partial unique
--      index (one active default PER CARRIER, carrier_id required) BEFORE
--      dropping the OLD organization-scoped one -- there is no window where
--      neither invariant holds. The new index's predicate additionally
--      requires carrier_id IS NOT NULL, so an unresolved legacy relationship
--      (0137) can never be "the" default for anything.
--   B. classify_carrier_factoring_readiness(carrier_id, broker_id?,
--      customer_id?) (items 5, 11): a read-only, SECURITY DEFINER, STABLE
--      function distinguishing all 12 states the spec requires. Doubles as
--      the safe preview RPC -- it creates no invoice, submission, package,
--      payment, or financial event; it only reads.
--   C. set_default_factoring_relationship(uuid) is REPLACED (same name,
--      new signature is NOT changed -- still one uuid arg, so no
--      application-code migration is forced -- but its BEHAVIOR changes
--      completely): now locks by carrier_id (item 10), owner/admin only,
--      validates completeness via the classifier, clears the prior default
--      ONLY for the same carrier, writes an audit event via log_activity(),
--      returns a structured jsonb result instead of void.
--   D. approve_factoring_relationship_noa(...) (item 7): the ONE sanctioned
--      path to set noa_approved = true. Owner/admin only, requires
--      carrier_id already set, requires template text or a document
--      reference, writes an audit event.
--   E. Column-privilege lockdown on factoring_relationships (items 7, 9):
--      authenticated loses table-level UPDATE entirely; re-granted ONLY on
--      the "operational" columns an accountant may still maintain directly
--      (advance/fee/reserve terms, fee timing, recourse type, payment
--      terms, fee defaults, is_active, effective dates, submission
--      config, relationship_name). carrier_id, factoring_company_id,
--      is_default, and every remittance/NOA field are excluded from direct
--      UPDATE for ANY authenticated role -- changed only through the two
--      RPCs above (is_default, NOA) or never re-pointed at all after
--      creation (carrier_id/factoring_company_id -- reassigning a
--      relationship's carrier/company is out of this phase's scope; a
--      relationship pointed at the wrong carrier/company is corrected by
--      creating a new one, not by silently repointing history).
--   F. guard_factoring_company_deactivation() (0072) is REPLACED to lock by
--      factoring_company_id instead of organization_id -- see the function
--      body for why this is now the correct, deadlock-free common lock key
--      shared with the revised set_default RPC (which locks company, then
--      carrier, in that fixed order; the deactivation guard only ever
--      takes the company lock, so the two can never deadlock against each
--      other).
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not touch factored_invoices, factoring_events, or any
--     submission/approval/funding/settlement/exception RPC (0073-0079)
--   * does not add invoice issuance, factoring submission, payment, DSI,
--     or settlement logic of any kind
--   * does not force carrier_id NOT NULL -- a genuinely unresolved legacy
--     relationship (0137) stays exactly as recorded, permanently excluded
--     from ever being a carrier's default by this migration's own index
--   * does not modify migrations 0001-0135
--
-- STRUCTURE: explicit BEGIN/COMMIT. PHASE 1 preconditions -> PHASE 2 DDL ->
-- PHASE 3 postconditions. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
begin
  if to_regclass('public.carrier_backfill_0137_provenance') is null then
    raise exception '0138 precondition: public.carrier_backfill_0137_provenance missing -- apply 0137 first. STOP.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id') then
    raise exception '0138 precondition: factoring_relationships.carrier_id missing -- apply 0136 first. STOP.';
  end if;
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null then
    raise exception '0138 precondition: classify_carrier_factoring_readiness(...) already exists -- partial apply? STOP.';
  end if;
  if exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_carrier') then
    raise exception '0138 precondition: factoring_relationships_one_default_per_carrier index already exists -- partial apply? STOP.';
  end if;

  -- The cutover's new index requires carrier_id IS NOT NULL for a default
  -- row -- confirm no CURRENTLY-default-and-active relationship still has
  -- a null carrier_id (0137 should have resolved every relationship that
  -- was ever flagged default, or left it default=false; this is a
  -- defensive re-check, not an expected finding).
  if exists (select 1 from public.factoring_relationships where is_default and is_active and carrier_id is null) then
    raise exception '0138 precondition ABORT: an active default factoring_relationships row still has a null carrier_id after 0137''s backfill -- resolve it (or clear its is_default flag) before applying the cutover. STOP.';
  end if;

  raise notice '0138 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- A. CUTOVER: create the new carrier-scoped index BEFORE dropping the old
-- org-scoped one -- no window where neither invariant holds.
create unique index factoring_relationships_one_default_per_carrier
  on public.factoring_relationships (carrier_id)
  where is_default and is_active and carrier_id is not null;

drop index public.factoring_relationships_one_default_per_org;

comment on index public.factoring_relationships_one_default_per_carrier is
  'Phase 3B.1 cutover (0138): at most one active default relationship PER CARRIER, never per organization. carrier_id IS NOT NULL is part of the predicate -- a relationship with no resolved carrier (0137''s unresolved set) can never be "the" default for anything. Replaces factoring_relationships_one_default_per_org (0071), dropped in this same migration.';

-- B. CLASSIFIER (items 5, 11) ------------------------------------------
-- Read-only, SECURITY DEFINER (so it can read factoring_relationships/
-- factoring_companies/carrier_brokers/carrier_customers consistently
-- regardless of the caller's own row-level visibility, same rationale as
-- every other cross-table classifier in this app), STABLE (no writes --
-- creates no invoice, submission, package, payment, or financial event,
-- per item 11's explicit requirement). Callable by owner/admin/dispatcher/
-- accountant only -- item 9's "no driver/viewer financial access".
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

  -- Carrier-party gate (item 3): checked BEFORE mode-based classification,
  -- and regardless of factoring_mode -- "must be active before either
  -- workflow proceeds." An ineligible-but-active party forces direct
  -- billing for THAT party specifically, reported as its own distinct
  -- classification (never silently folded into 'direct_billing') so the
  -- caller can tell "this carrier is globally factored, but THIS
  -- broker/customer is billed directly" apart from "this carrier is
  -- globally direct."
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

  -- Phase 3B.1.1 (item 1): 'unconfigured' blocks outright -- nobody has
  -- reviewed this carrier's real billing arrangement yet, so nothing is
  -- inferred and it never falls through to the 'factored' logic below.
  if v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', true, 'classification', 'factoring_policy_unconfigured', 'carrier_id', p_carrier_id);
  end if;

  if v_carrier.factoring_mode = 'direct' then
    return jsonb_build_object('success', true, 'classification', 'direct_billing', 'carrier_id', p_carrier_id);
  end if;

  -- factoring_mode = 'factored' from here.
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

-- C. set_default_factoring_relationship(uuid) -- REPLACED ----------------
-- Item 10's full contract: locks by carrier_id, owner/admin only,
-- validates completeness, clears the prior default only for the SAME
-- carrier, sets exactly one active default, writes an audit event,
-- concurrency-safe, accepts no browser carrier override (carrier_id is
-- derived from the relationship row, never a parameter), returns a
-- structured result. SECURITY DEFINER (was INVOKER in 0072) -- now that
-- accountant/dispatcher no longer have RLS UPDATE reach on is_default at
-- all (see the column-privilege lockdown below), relying on RLS to gate
-- the internal UPDATEs would leave EVERY caller, including owner/admin,
-- unable to run them; SECURITY DEFINER plus this function's own explicit
-- role check is the same pattern 0135's reassign_dispatch_resources()
-- already established for exactly this reason.
--
-- Lock order (deadlock-free with guard_factoring_company_deactivation()
-- below): factoring_company_id THEN carrier_id, always in that order, and
-- ONLY this function ever acquires the second (carrier) lock -- the
-- deactivation guard takes only the first (company) lock, so it can never
-- be waiting on a carrier-lock this function already holds while this
-- function waits on the SAME company-lock the deactivation guard holds.
--
-- 0072's version returned void -- Postgres cannot CREATE OR REPLACE a
-- function into a different return type, so the old one is dropped first.
drop function if exists public.set_default_factoring_relationship(uuid);

create or replace function public.set_default_factoring_relationship(p_relationship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_relationship record;
  v_company_active boolean;
  v_readiness jsonb;
begin
  if v_uid is null then
    raise exception 'set_default_factoring_relationship: authentication required.' using errcode = 'SFAUT';
  end if;
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'set_default_factoring_relationship: caller has no organization.' using errcode = 'SFAUT';
  end if;
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'set_default_factoring_relationship: only an owner or admin may change a carrier''s default factor.' using errcode = 'SFROL';
  end if;

  -- Resolve carrier_id/factoring_company_id WITHOUT locking yet, purely to
  -- know which two locks to acquire.
  select organization_id, carrier_id, factoring_company_id into v_relationship
  from public.factoring_relationships where id = p_relationship_id;
  if v_relationship.organization_id is null or v_relationship.organization_id <> v_org then
    raise exception 'set_default_factoring_relationship: this factoring relationship is not available.' using errcode = 'SFDNF';
  end if;
  if v_relationship.carrier_id is null then
    raise exception 'set_default_factoring_relationship: this relationship has no resolved carrier -- it cannot be set as a carrier''s default. See unresolved_carrier_records.' using errcode = 'SFCAR';
  end if;

  -- Fixed lock order: company, then carrier. Never taken in the other
  -- order anywhere in this codebase.
  perform pg_advisory_xact_lock(hashtext('factoring_company:' || v_relationship.factoring_company_id::text));
  perform pg_advisory_xact_lock(hashtext('factoring_default_relationship:carrier:' || v_relationship.carrier_id::text));

  -- Re-read under both locks -- the authoritative state.
  select id, organization_id, carrier_id, factoring_company_id, is_active
    into v_relationship
  from public.factoring_relationships
  where id = p_relationship_id
  for update;

  if v_relationship.id is null or v_relationship.organization_id <> v_org then
    raise exception 'set_default_factoring_relationship: this factoring relationship is not available.' using errcode = 'SFDNF';
  end if;
  if not v_relationship.is_active then
    raise exception 'set_default_factoring_relationship: this factoring relationship is inactive.' using errcode = 'SFINV';
  end if;

  select is_active into v_company_active from public.factoring_companies where id = v_relationship.factoring_company_id;
  if not coalesce(v_company_active, false) then
    raise exception 'set_default_factoring_relationship: this relationship''s factoring company is inactive.' using errcode = 'SFCMP';
  end if;

  -- Completeness (item 10's "validates relationship completeness"):
  -- everything the classifier checks for 'ready' EXCEPT the "is it the
  -- default yet" question itself (circular -- we are in the middle of
  -- making it the default). Re-implemented inline rather than calling the
  -- classifier (which reads is_default rather than the row being set).
  if v_relationship.carrier_id is null then
    raise exception 'set_default_factoring_relationship: relationship has no resolved carrier.' using errcode = 'SFCAR';
  end if;
  perform 1 from public.factoring_relationships
    where id = p_relationship_id
      and remittance_instructions is not null and btrim(remittance_instructions) <> ''
      and noa_approved
      and submission_method is not null
      and (effective_from is null or effective_from <= current_date)
      and (effective_to is null or effective_to >= current_date);
  if not found then
    v_readiness := jsonb_build_object('relationship_id', p_relationship_id);
    return jsonb_build_object(
      'success', false, 'incomplete', true, 'relationship_id', p_relationship_id, 'carrier_id', v_relationship.carrier_id,
      'message', 'This relationship is missing remittance instructions, an approved Notice of Assignment, a submission method, or its effective dates do not currently cover today -- it cannot become the default until complete.');
  end if;

  -- Clear the prior default ONLY for THIS carrier -- Carrier B's own
  -- default (or any other carrier's) is untouched (item 10: "Do not let
  -- changing Carrier A's default affect Carrier B").
  update public.factoring_relationships
  set is_default = false
  where carrier_id = v_relationship.carrier_id and is_default = true and id <> p_relationship_id;

  update public.factoring_relationships
  set is_default = true
  where id = p_relationship_id;

  perform public.log_activity(
    'carrier'::public.entity_type, v_relationship.carrier_id, 'factoring_default_changed',
    jsonb_build_object('relationship_id', p_relationship_id, 'factoring_company_id', v_relationship.factoring_company_id),
    v_org);

  return jsonb_build_object('success', true, 'carrier_id', v_relationship.carrier_id, 'relationship_id', p_relationship_id);
end;
$fn$;

revoke all on function public.set_default_factoring_relationship(uuid) from public;
grant execute on function public.set_default_factoring_relationship(uuid) to authenticated;

comment on function public.set_default_factoring_relationship(uuid) is
  'Phase 3B.1 (item 10): sets exactly one active default relationship PER CARRIER (never organization-wide). Owner/admin only. Locks factoring_company_id then carrier_id (fixed order, deadlock-free with guard_factoring_company_deactivation). Requires the relationship to be active, its company active, its carrier resolved, and complete (remittance instructions + approved NOA + submission method + currently within its effective window). Clears the prior default ONLY for the same carrier -- a different carrier''s default is never touched. Writes one audit event via log_activity(entity_type=carrier). Returns a structured jsonb result, never void.';

-- D. approve_factoring_relationship_noa(...) -- NEW (item 7) --------------
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
    raise exception 'approve_factoring_relationship_noa: this relationship has no resolved carrier -- its Notice of Assignment cannot be approved until one is. See unresolved_carrier_records.' using errcode = 'ANCAR';
  end if;
  if p_noa_document_id is not null then
    if not exists (select 1 from public.documents where id = p_noa_document_id and organization_id = v_org) then
      raise exception 'approve_factoring_relationship_noa: the referenced document does not belong to this organization.' using errcode = 'ANVAL';
    end if;
  end if;

  update public.factoring_relationships
  set noa_template_text = p_noa_template_text,
      noa_document_id = p_noa_document_id,
      noa_reference = p_noa_reference,
      noa_effective_date = p_noa_effective_date,
      noa_approved = true,
      noa_approved_by = v_uid,
      noa_approved_at = now()
  where id = p_relationship_id;

  perform public.log_activity(
    'carrier'::public.entity_type, v_relationship.carrier_id, 'factoring_noa_approved',
    jsonb_build_object('relationship_id', p_relationship_id, 'noa_reference', p_noa_reference, 'noa_effective_date', p_noa_effective_date),
    v_org);

  return jsonb_build_object('success', true, 'relationship_id', p_relationship_id, 'carrier_id', v_relationship.carrier_id);
end;
$fn$;

revoke all on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) from public;
grant execute on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) to authenticated;

comment on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) is
  'Phase 3B.1 (item 7): the ONE sanctioned path to set factoring_relationships.noa_approved = true. Owner/admin only. Requires a resolved carrier_id, a reference/version, an effective date, and either approved template language or an approved document reference. Writes one audit event via log_activity(entity_type=carrier).';

-- E. guard_factoring_company_deactivation() -- REPLACED (lock key change) --
-- Was keyed by organization_id (0072); now keyed by factoring_company_id
-- itself -- the correct common lock scope shared with set_default_
-- factoring_relationship()'s own company-then-carrier lock order above,
-- since "does this company still have SOME carrier's active default" is a
-- per-company question, not a per-organization or per-carrier one. Same
-- check, same behavior otherwise.
create or replace function public.guard_factoring_company_deactivation()
returns trigger
language plpgsql
as $$
declare
  v_has_active_default boolean;
begin
  if old.is_active and not new.is_active then
    perform pg_advisory_xact_lock(hashtext('factoring_company:' || old.id::text));

    select exists (
      select 1 from public.factoring_relationships
      where factoring_company_id = old.id and is_active = true and is_default = true
    ) into v_has_active_default;

    if v_has_active_default then
      raise exception 'This factoring company cannot be deactivated while one of its relationships is a carrier''s default. Choose another default relationship for that carrier first.';
    end if;
  end if;

  return new;
end;
$$;

-- Trigger definition itself (BEFORE UPDATE OF is_active) is unchanged --
-- only the function body's lock key changed. Re-attaching for clarity.
drop trigger if exists factoring_companies_guard_deactivation on public.factoring_companies;
create trigger factoring_companies_guard_deactivation
  before update of is_active on public.factoring_companies
  for each row execute function public.guard_factoring_company_deactivation();

-- F. COLUMN-PRIVILEGE LOCKDOWN (items 7, 9) -------------------------------
-- REGRANTing from scratch (not incrementally revoking) -- same rationale
-- as 0132/0134/0135's own narrowing: proves-by-construction the final
-- permitted set is EXACTLY this list, independent of whatever 0071's
-- original blanket grant happened to include.
revoke update on public.factoring_relationships from authenticated;
-- remittance_instructions/remittance_reference ARE included here (unlike
-- is_default/carrier_id/factoring_company_id/noa_*, which are excluded
-- entirely) -- this phase has no dedicated "update remittance" RPC, so
-- owner/admin's only path to editing them is a direct table UPDATE.
-- guard_factoring_relationship_protected_fields() (0136) is what actually
-- restricts them to owner/admin -- this GRANT only distinguishes
-- authenticated-as-a-whole from no-access-at-all, the same as it does for
-- is_active/submission_* below.
grant update (
  relationship_name, default_advance_percentage, default_factoring_fee_percentage,
  default_reserve_percentage, fee_timing, recourse_type, payment_terms_days,
  minimum_fee, wire_fee, ach_fee, other_fee_default, is_active,
  effective_from, effective_to,
  submission_method, submission_destination_email, submission_integration_id, submission_notes,
  remittance_instructions, remittance_reference
) on public.factoring_relationships to authenticated;

comment on column public.factoring_relationships.is_default is
  'UPDATE is revoked from authenticated (0138) -- change ONLY via public.set_default_factoring_relationship(), owner/admin only, carrier-scoped.';
comment on column public.factoring_relationships.carrier_id is
  'UPDATE is revoked from authenticated (0138) -- immutable after creation via this app''s current write paths. A relationship pointed at the wrong carrier is corrected by creating a new one, never by silently repointing history.';
comment on column public.factoring_relationships.factoring_company_id is
  'UPDATE is revoked from authenticated (0138) -- immutable after creation (see carrier_id).';
comment on column public.factoring_relationships.remittance_instructions is
  'UPDATE is revoked from authenticated (0138) -- owner/admin only, via direct table UPDATE (still permitted for owner/admin -- unlike is_default/NOA approval, remittance instructions have no dedicated RPC in this phase); enforced by guard_factoring_relationship_protected_fields() (0136), not by column grants alone, since that trigger is what actually distinguishes owner/admin from accountant (column grants apply identically to every authenticated org_role).';

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
begin
  if not exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_carrier') then
    raise exception '0138 postcondition: factoring_relationships_one_default_per_carrier index missing.';
  end if;
  if exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_org') then
    raise exception '0138 postcondition: the OLD factoring_relationships_one_default_per_org index still exists -- cutover incomplete.';
  end if;

  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is null then
    raise exception '0138 postcondition: classify_carrier_factoring_readiness(...) missing.';
  end if;
  if to_regprocedure('public.set_default_factoring_relationship(uuid)') is null then
    raise exception '0138 postcondition: set_default_factoring_relationship(uuid) missing.';
  end if;
  if to_regprocedure('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)') is null then
    raise exception '0138 postcondition: approve_factoring_relationship_noa(...) missing.';
  end if;

  if has_table_privilege('authenticated','public.factoring_relationships','UPDATE') then
    raise exception '0138 postcondition: authenticated holds a TABLE-LEVEL UPDATE grant on factoring_relationships -- must be column-scoped only.';
  end if;
  if has_column_privilege('authenticated','public.factoring_relationships','is_default','UPDATE') then
    raise exception '0138 postcondition: authenticated can UPDATE is_default directly.';
  end if;
  if has_column_privilege('authenticated','public.factoring_relationships','carrier_id','UPDATE') then
    raise exception '0138 postcondition: authenticated can UPDATE carrier_id directly.';
  end if;
  if has_column_privilege('authenticated','public.factoring_relationships','noa_approved','UPDATE') then
    raise exception '0138 postcondition: authenticated can UPDATE noa_approved directly.';
  end if;
  if not has_column_privilege('authenticated','public.factoring_relationships','is_active','UPDATE') then
    raise exception '0138 postcondition: authenticated should still be able to UPDATE is_active directly (operational field).';
  end if;
  if not has_column_privilege('authenticated','public.factoring_relationships','remittance_instructions','UPDATE') then
    raise exception '0138 postcondition: authenticated should still be able to UPDATE remittance_instructions directly (owner/admin-gated by the protected-fields trigger, 0136 -- not by this column grant).';
  end if;

  -- untouched: 0071/0072 tables and factored_invoices/factoring_events
  if to_regclass('public.factored_invoices') is null or to_regclass('public.factoring_events') is null then
    raise exception '0138 postcondition: factored_invoices/factoring_events disappeared.';
  end if;

  raise notice '0138 complete: carrier-scoped default-factor cutover done (old org-level index dropped, new carrier-level index live); classify_carrier_factoring_readiness(...) installed; set_default_factoring_relationship(...) now carrier-scoped/owner-admin-only/returns jsonb; approve_factoring_relationship_noa(...) installed; factoring_relationships UPDATE narrowed to operational columns for authenticated. Phase 3B.1 (carrier-specific factoring configuration foundation) complete -- no invoice issuance, submission, payment, DSI, or settlement logic added.';
end
$mig$;

commit;
