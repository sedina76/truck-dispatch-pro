-- =============================================================================
-- 0140_factoring_authorization_and_submission_safety.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0139 live. Phase 3B.1.4 ("Factoring Authorization and Legacy
-- Submission Safety Closure"), CORRECTED by Phase 3B.1.5 ("Immutable
-- Invoice Boundary and Complete Concurrency Proof"). This file was edited
-- in place -- 0140 was still uncommitted and unapplied when the correction
-- was made, so this is the SAME migration number, not a new 0141.
--
-- PHASE 3B.1.5 CORRECTION (read this before Section B below): the
-- original 0140 (Phase 3B.1.4) gated submit_invoice_to_factor() on a
-- carrier LIVE-DERIVED from dispatch_id/load_id, treating "a carrier can
-- be resolved and is factored+ready" as sufficient to authorize
-- submission. That was wrong: invoices carry no durable, database-issued
-- snapshot of carrier identity, financial terms, NOA, or remittance
-- instructions at the moment they were created -- a live join to
-- dispatches/loads is CURRENT operational state, not a frozen financial
-- record of what was true and approved when this invoice was issued. Two
-- different things can both be true for the exact same invoice a day
-- apart (a load's carrier gets corrected, a carrier's default relationship
-- changes, a policy flips from factored to direct) with NO trace of what
-- was actually in effect at submission time -- exactly the historical-
-- identity guarantee factoring submission requires and cannot safely
-- fake. Section A of Phase 3B.1.5 is explicit: live derivation may be used
-- ONLY to explain/diagnose/locate/detect-conflicts -- it must NEVER
-- authorize submission.
--
-- WHY THIS MIGRATION EXISTS (still true, unrelated to the correction above):
--   (1) factoring_companies_insert / factoring_relationships_insert (0071)
--       grant INSERT to ALL FOUR FINANCIAL_ROLES. A dispatcher's own
--       authenticated session could create a factoring company or a
--       carrier's factoring relationship directly against the database --
--       Section C below retains the fix for this.
--   (2) submit_invoice_to_factor() (0073-0075) had NO carrier concept at
--       all. Phase 3B.1.5 does not restore a carrier-derivation gate --
--       it replaces the entire legacy submission path with an
--       unconditional, structured, fail-closed rejection (Section B)
--       until a future invoice-issuance migration introduces a genuine
--       database-issued snapshot/version marker.
--
-- WHAT THIS MIGRATION DOES
--   A. Tightens factoring_companies / factoring_relationships RLS to the
--      Phase 3B.1.4 authorization matrix (Section A, retained unchanged by
--      3B.1.5's own Section C): company create/update/delete -> owner/
--      admin only. Relationship create/delete -> owner/admin only;
--      relationship UPDATE (ordinary operational/contact terms only) ->
--      owner/admin AND accountant, dispatcher EXCLUDED. SELECT is
--      UNCHANGED (all four FINANCIAL_ROLES may still view).
--   B. approve_factoring_relationship_noa() (0139) REPLACED to fix a real
--      bug found live during this phase's own two-session concurrency
--      testing: approving via template text alone (no document reference)
--      raised "record v_doc is not assigned yet", because 0139's version
--      referenced v_doc.file_name/file_path unconditionally even though
--      v_doc is only assigned inside the `p_noa_document_id is not null`
--      branch. Fixed with two plain nullable variables; no other behavior
--      changes. 0139's own file is untouched.
--   C. submit_invoice_to_factor() (0073-0075) REPLACED. Return type
--      changes from `table(factored_invoice_id, status)` to `jsonb` --
--      0140 was never applied to production, so this is a completely
--      free redefinition, not a "body-only fix" preserving an already-
--      live signature (that convention was only ever meant to protect an
--      ALREADY-APPLIED function; nothing here has been applied). After
--      the same auth/role check, invoice-lookup, status-eligibility, and
--      already-submitted checks 0073-0075 always had (all unrelated to
--      carrier derivation, all retained), the function now returns a
--      structured, unconditional rejection --
--      {success:false, code:'CARRIER_INVOICE_SNAPSHOT_REQUIRED',
--      snapshot_required:true, message:'...'} -- for every single
--      invoice, because NO invoice in this schema yet carries the
--      database-issued snapshot/version marker a safe submission would
--      require. This is not a bug to fix later in this migration; it is
--      the intended, permanent behavior of THIS migration. A future
--      invoice-issuance migration will add that marker and REPLACE this
--      one unconditional check with a real marker-presence test -- see
--      the function body's own comment for exactly where that change
--      belongs.
--
-- DISPOSITION (Phase 3B.1.5 Section A/B, superseding 3B.1.4's Section F):
-- Option 2 (fail closed), not Option 1. Phase 3B.1.4 mischaracterized its
-- own carrier-derivation gate as a safe "adaptation" -- it was not: no
-- amount of re-deriving dispatch/load state live can substitute for an
-- immutable snapshot a factoring submission's financial identity actually
-- requires. This migration does not invent that snapshot (still out of
-- scope -- invoice-issuance-phase work) and does not pretend a derived
-- carrier is good enough. It fails every legacy submission closed,
-- unconditionally, with a clear, structured, machine-checkable reason.
-- Historical factored_invoices/factoring_events rows are never touched,
-- rewritten, or deleted by this migration.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not add email, WhatsApp, or external API transmission
--   * does not touch carrier_factoring_integrations (already owner/admin
--     -only end to end since 0139)
--   * does not touch factored_invoices/factoring_events schemas, or any of
--     the 0076-0079 review/approval/funding/settlement/exception RPCs
--   * does not add a durable carrier_id column or any snapshot/version
--     marker to invoices -- that is invoice-issuance-phase work; this
--     migration's only job is to fail closed until that marker exists
--   * does not derive, infer, or persist a carrier_id onto any invoice
--   * does not clone, reissue, or mark any invoice submitted
--   * does not modify migrations 0001-0139
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
begin
  if to_regclass('public.carrier_factoring_integrations') is null then
    raise exception '0140 precondition: 0139 (carrier_factoring_integrations) missing. STOP.';
  end if;
  if to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)') is null then
    raise exception '0140 precondition: submit_invoice_to_factor(uuid,uuid) missing -- apply 0075 first. STOP.';
  end if;
  raise notice '0140 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- =====================================================================
-- A. AUTHORIZATION TIGHTENING (Section A, Phase 3B.1.4 -- retained as-is
-- by Phase 3B.1.5's own Section C). REGRANTing/re-creating each policy
-- from scratch (drop then create) -- same "prove-by-construction"
-- convention this project already uses for column grants (0132/0134/0135/
-- 0138/0139) applied here to RLS policies instead.
-- =====================================================================

-- factoring_companies: create/update/delete -> owner/admin only. SELECT
-- unchanged (all FINANCIAL_ROLES may still view company identity/status).
drop policy if exists factoring_companies_insert on public.factoring_companies;
create policy factoring_companies_insert on public.factoring_companies
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));

drop policy if exists factoring_companies_update on public.factoring_companies;
create policy factoring_companies_update on public.factoring_companies
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]))
  with check (organization_id = public.current_org_id());

drop policy if exists factoring_companies_delete on public.factoring_companies;
create policy factoring_companies_delete on public.factoring_companies
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));

comment on table public.factoring_companies is
  'Phase 3B.1.4 (Section A): create/update/delete are owner/admin only. SELECT remains open to all FINANCIAL_ROLES (owner/admin/dispatcher/accountant) -- dispatcher retains VIEW-ONLY visibility, never configuration authority.';

-- factoring_relationships: create/delete -> owner/admin only. UPDATE ->
-- owner/admin AND accountant (ordinary operational/contact terms only --
-- carrier_id/factoring_company_id/is_default/remittance/NOA fields are
-- already excluded from direct UPDATE entirely by 0138/0139's own column-
-- privilege lockdown and protected-fields trigger, regardless of RLS).
-- Dispatcher is excluded from INSERT/UPDATE/DELETE outright -- "dispatcher
-- oversight means visibility across authorized carriers... [not] authority
-- to configure where carrier receivables are sent" (Section A). SELECT
-- unchanged.
drop policy if exists factoring_relationships_insert on public.factoring_relationships;
create policy factoring_relationships_insert on public.factoring_relationships
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));

drop policy if exists factoring_relationships_update on public.factoring_relationships;
create policy factoring_relationships_update on public.factoring_relationships
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());

drop policy if exists factoring_relationships_delete on public.factoring_relationships;
create policy factoring_relationships_delete on public.factoring_relationships
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));

comment on table public.factoring_relationships is
  'Phase 3B.1.4 (Section A): create/delete are owner/admin only. UPDATE is owner/admin + accountant (ordinary operational/contact terms only -- carrier_id/factoring_company_id/is_default/remittance/NOA are separately locked down by 0138/0139''s column grants and protected-fields trigger regardless of this policy). Dispatcher retains VIEW-ONLY visibility (SELECT, unchanged) -- oversight, never configuration authority.';

-- =====================================================================
-- B. BUG FIX (found live, Phase 3B.1.5 Section D's real two-session
-- concurrency testing -- Scenario 5, approve_factoring_relationship_noa()
-- racing a submission attempt): 0139's version references v_doc.file_name/
-- v_doc.file_path in its UPDATE unconditionally, but v_doc (a plain
-- `record`) is only ever assigned INSIDE the `if p_noa_document_id is not
-- null` branch -- approving via template text alone (p_noa_document_id
-- null, a documented, explicitly supported call shape: "either approved
-- template language or an approved document reference is required")
-- leaves v_doc unassigned, and Postgres raises 'record "v_doc" is not
-- assigned yet' the moment its fields are referenced. Fixed here via
-- `create or replace` (0139's own file is untouched) by replacing the
-- single record variable with two plain, explicitly nullable text
-- variables that default to null and are populated only when a document
-- is actually referenced. No other behavior changes.
-- =====================================================================
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
  v_doc_snapshot_file_name text;
  v_doc_snapshot_file_path text;
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

    -- Phase 3B.1.5 fix: only populated on this branch -- stays null
    -- (the correct, intended value) for a template-only approval.
    v_doc_snapshot_file_name := v_doc.file_name;
    v_doc_snapshot_file_path := v_doc.file_path;
  end if;

  update public.factoring_relationships
  set noa_template_text = p_noa_template_text,
      noa_document_id = p_noa_document_id,
      noa_document_snapshot_file_name = v_doc_snapshot_file_name,
      noa_document_snapshot_file_path = v_doc_snapshot_file_path,
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
  'Phase 3B.1.1 (item 9) + Phase 3B.1.5 bug fix (0140): validates the referenced document belongs to the SAME organization AND the relationship''s own carrier (never a different carrier''s document), is document_type notice_of_assignment/factoring_notice, and is_verified=true -- then snapshots its file identity onto the relationship so a later edit of the documents row can never silently alter an already-approved NOA. A template-only approval (no document reference) correctly leaves the snapshot columns null instead of raising "record not assigned yet" (0139''s original bug, found live via Phase 3B.1.5''s two-session NOA-approval concurrency test). Owner/admin only.';

-- =====================================================================
-- C. LEGACY SUBMISSION: UNCONDITIONAL, STRUCTURED, FAIL-CLOSED REJECTION
-- (Phase 3B.1.5, Sections A/B). Return type changes from
-- `table(factored_invoice_id, status)` to `jsonb` -- 0140 has never been
-- applied to production, so this is a free redefinition (drop+create),
-- not a signature-preserving "body-only fix"; every existing caller
-- (invoices/factoring-actions.ts) is updated in this same phase to parse
-- the new jsonb shape. SECURITY INVOKER, unchanged.
-- =====================================================================
drop function if exists public.submit_invoice_to_factor(uuid, uuid);

create function public.submit_invoice_to_factor(
  p_invoice_id uuid,
  p_relationship_id uuid
)
returns jsonb
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_invoice record;
  v_existing_active uuid;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  -- Dispatcher retains this explicit, documented submission authority
  -- (Section A's matrix: "Only if existing business policy explicitly
  -- authorizes it" -- documented in migration 0075's own header comment,
  -- unrelated to and unaffected by this rejection). This role check is
  -- deliberately NOT the thing that blocks a legacy submission -- EVERY
  -- role below, including owner/admin, hits the same unconditional
  -- rejection at the bottom of this function. Authorization and snapshot
  -- eligibility are two independent gates; passing the first only earns
  -- the right to be told "no" by the second.
  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to submit invoices for factoring.';
  end if;

  -- Serializes every concurrent submission ATTEMPT for this exact invoice
  -- (matches 0075's own advisory-lock fix). Still meaningful here even
  -- though every attempt now ends in the same rejection: it guarantees
  -- the "already submitted" check immediately below is race-free, and it
  -- keeps this function's lock behavior directly comparable/testable
  -- against the real two-session scenarios Phase 3B.1.5 Section D
  -- requires. pg_advisory_xact_lock auto-releases on commit or rollback.
  perform pg_advisory_xact_lock(hashtext('factoring_submission:' || p_invoice_id::text));

  select inv.id, inv.organization_id, inv.status, inv.amount_paid
    into v_invoice
  from public.invoices inv
  where inv.id = p_invoice_id;

  if v_invoice.id is null or v_invoice.organization_id <> v_org_id then
    raise exception 'Invoice not found.';
  end if;

  if v_invoice.status not in ('sent', 'viewed') or v_invoice.amount_paid <> 0 then
    raise exception 'This invoice is not eligible for factoring.';
  end if;

  -- A genuinely already-submitted invoice gets its OWN specific message
  -- (matches 0073-0075's original behavior exactly) rather than the
  -- generic snapshot-required rejection below -- this is a more accurate
  -- diagnosis and protects historical factored_invoices/factoring_events
  -- rows from ever being reasoned about as if they didn't exist. Race-free
  -- because the advisory lock above is already held for this exact
  -- invoice id.
  select fi.id into v_existing_active
  from public.factored_invoices fi
  where fi.invoice_id = p_invoice_id and fi.status not in ('rejected', 'cancelled')
  limit 1;
  if v_existing_active is not null then
    raise exception 'This invoice has already been submitted to a factor.';
  end if;

  -- =====================================================================
  -- Phase 3B.1.5 (Sections A/B): THE unconditional fail-closed rejection.
  --
  -- No column, table, or marker anywhere in this schema records an
  -- authoritative, database-issued snapshot of this invoice's carrier
  -- identity, financial terms, NOA, or remittance instructions at the
  -- moment it was created -- confirmed absent (Phase 3B.1.4's own audit,
  -- reaffirmed here). A live join through dispatch_id/load_id to
  -- dispatches.carrier_id/loads.carrier_id (the previous, now-REMOVED
  -- version of this gate) is CURRENT operational state, mutable by
  -- unrelated actions (a load correction, a default-relationship change,
  -- a policy flip) at any time after this invoice was issued -- it is not
  -- a financial record of what was true and approved when the invoice was
  -- created, and must never be presented or treated as one (Phase 3B.1.5,
  -- Section A). This function therefore stops here, for every invoice,
  -- with no exception -- there is no branch below this comment that ever
  -- proceeds to create a factored_invoices row, a factoring_events row, a
  -- 'submitted' status, or any other side effect.
  --
  -- FUTURE MIGRATION: when the invoice-issuance phase introduces a real,
  -- database-issued snapshot/version marker (e.g., a NOT NULL
  -- invoices.carrier_factoring_snapshot_id referencing an immutable
  -- snapshot row captured at issuance time), THIS is the one place to
  -- replace: swap the unconditional `return jsonb_build_object(...)`
  -- below for a check on that marker's presence, then resume this
  -- function's real submission logic (carrier/company/relationship
  -- validation, fee calculation, the factored_invoices/factoring_events
  -- insert) gated on the SNAPSHOT's own frozen values -- never on a fresh
  -- live derivation. Do not restore the dispatch/load-carrier-derivation
  -- gate this replaced; it was the mistake being corrected.
  -- =====================================================================
  return jsonb_build_object(
    'success', false,
    'code', 'CARRIER_INVOICE_SNAPSHOT_REQUIRED',
    'snapshot_required', true,
    'message', 'This invoice was created before carrier-specific financial snapshots were enabled. Review and reissue it through the new invoice workflow.'
  );
end;
$$;

grant execute on function public.submit_invoice_to_factor(uuid, uuid) to authenticated;

comment on function public.submit_invoice_to_factor(uuid, uuid) is
  'Phase 2H.4 (0073-0075) legacy submission entry point -- Phase 3B.1.5 (0140) REPLACES its body: after the existing auth/role, invoice-lookup, status-eligibility, and already-submitted checks (all retained, none carrier-related), this function now returns an UNCONDITIONAL structured rejection -- {success:false, code:''CARRIER_INVOICE_SNAPSHOT_REQUIRED'', snapshot_required:true, message:''...''} -- for every invoice, because no invoice yet carries a database-issued carrier/financial snapshot. Never derives, infers, or persists a carrier_id; never creates a factored_invoices or factoring_events row; never marks anything submitted. Returns jsonb (changed from table(factored_invoice_id,status) -- 0140 was never applied to production, so this is a free redefinition). A future invoice-issuance migration replaces the one unconditional check this comment marks, once a real snapshot/version marker exists.';

-- ======================= PHASE 3 -- POSTCONDITIONS ===========================
do $mig$
declare
  v_data_type text;
begin
  -- Phase 3B.1.6: an INSERT policy has NO `qual` (USING) -- only
  -- `with_check` is ever populated for INSERT. The original version of
  -- this check read `qual` here, which is always NULL for an INSERT
  -- policy -- inside exists(... and qual not like ...), a NULL never
  -- satisfies the WHERE clause, so the exists() was always false and this
  -- postcondition never actually raised regardless of the policy's real
  -- content. Fixed to read `with_check`, the column that actually holds
  -- this policy's rule (found via this phase's own re-verification of the
  -- rollback/reapply cycle, not a hypothetical).
  if exists (
    select 1 from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_insert'
      and with_check not like '%owner%admin%'
  ) then
    raise exception '0140 postcondition: factoring_companies_insert does not look owner/admin-scoped.';
  end if;
  if not exists (
    select 1 from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_update'
      and qual like '%accountant%' and qual not like '%dispatcher%'
  ) then
    raise exception '0140 postcondition: factoring_relationships_update does not look owner/admin/accountant-scoped (dispatcher must be excluded).';
  end if;

  if to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)') is null then
    raise exception '0140 postcondition: submit_invoice_to_factor(uuid,uuid) missing after replace.';
  end if;
  if to_regprocedure('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)') is null then
    raise exception '0140 postcondition: approve_factoring_relationship_noa(...) missing after replace.';
  end if;

  -- Defensive, non-destructive self-check: the function's return type is
  -- genuinely jsonb now (a stale table-returning version would fail this
  -- migration earlier at the DROP/CREATE step, but this confirms the
  -- catalog agrees, not just that some function by this name exists).
  select data_type into v_data_type
  from information_schema.routines
  where routine_schema = 'public' and routine_name = 'submit_invoice_to_factor'
  limit 1;
  if v_data_type is null or v_data_type <> 'jsonb' then
    raise exception '0140 postcondition: submit_invoice_to_factor does not return jsonb (found %).', v_data_type;
  end if;

  raise notice '0140 complete: factoring_companies/factoring_relationships create/update/delete narrowed to owner/admin (+ accountant for relationship UPDATE only, dispatcher view-only); submit_invoice_to_factor() now unconditionally, structurally rejects every legacy submission ({success:false, code:CARRIER_INVOICE_SNAPSHOT_REQUIRED}) because no invoice carries a database-issued carrier/financial snapshot -- no factored_invoices/factoring_events row, no submitted status, no ledger success row is ever created by this function. No email/WhatsApp/API transmission added. Migrations 0001-0139 untouched.';
end
$mig$;

commit;
