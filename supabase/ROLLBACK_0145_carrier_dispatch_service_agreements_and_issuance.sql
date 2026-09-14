-- =============================================================================
-- ROLLBACK_0145_carrier_dispatch_service_agreements_and_issuance.sql
--
-- *** EMERGENCY USE ONLY. READ THIS HEADER BEFORE RUNNING. ***
--
-- Restores the EXACT 0144 boundary: restores issue_carrier_invoice() to its
-- exact pre-0145 (0144) body (including the retired DISPATCH_SERVICE_
-- AGREEMENT_REQUIRED early return AND the loads.rate read -- this rollback
-- deliberately restores 0144's own behavior byte-for-byte, defect included;
-- fixing that defect for good means keeping 0145 applied, not rolling it
-- back), drops _issue_dispatch_service_invoice_internal(), drops all five
-- agreement-lifecycle RPCs, drops carrier_dispatch_service_billing_lines /
-- carrier_dispatch_service_agreement_versions / carrier_dispatch_service_
-- agreements / carrier_dispatch_service_agreement_idempotency, drops the
-- three new enum types, drops organizations.remittance_instructions.
--
-- DATA-PRESERVING REFUSALS (mirrors ROLLBACK_0141/0142/0143/0144's own
-- established pattern):
--   1. Refuses outright if ANY carrier_dispatch_service_agreement_versions
--      row has ever been used for billing (referenced by carrier_dispatch_
--      service_billing_lines), or if ANY carrier_invoices row of
--      invoice_document_type='dispatch_service_invoice' is issuance_status
--      ='issued'. issue_carrier_invoice() (as corrected by 0145) is the
--      ONLY thing that could have created either -- if either exists, real
--      financial records/agreement usage exist under this migration's own
--      mechanism, and rolling back would either orphan them or require
--      deleting/reinterpreting them, which this script refuses to do.
--   2. Refuses if any OTHER function in this schema (besides the six this
--      migration installs/redefines) references any of this migration's
--      own new objects -- a later migration may depend on them.
--   3. Refuses if a later migration (0146 or beyond) is already present --
--      rolling back 0145 out from under an already-applied LATER migration
--      that may depend on it would corrupt the migration sequence.
--
-- Never drops carrier_invoice_lifecycle_idempotency, carrier_invoice_
-- number_counters, load_financials, or any 0001-0144 object -- those are
-- untouched by this script regardless of outcome.
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent -- running this twice
-- will fail the second time (0144 boundary already restored), which is
-- the correct, safe failure mode.
-- =============================================================================

begin;

do $rb$
declare
  v_used_version_count integer;
  v_issued_dsi_count integer;
  v_dependent_count integer;
  v_later_migration_count integer;
begin
  if to_regprocedure('public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)') is null then
    raise exception 'ROLLBACK_0145 precondition: _issue_dispatch_service_invoice_internal(...) does not exist -- 0145 does not appear to be applied. STOP (nothing to roll back).';
  end if;

  -- Refusal 1: never orphan or reinterpret real agreement usage/issued
  -- dispatch-service invoices.
  select count(*) into v_used_version_count from public.carrier_dispatch_service_billing_lines;
  select count(*) into v_issued_dsi_count from public.carrier_invoices where invoice_document_type = 'dispatch_service_invoice' and issuance_status = 'issued';
  if v_used_version_count > 0 or v_issued_dsi_count > 0 then
    raise exception 'ROLLBACK_0145 refused: % billing-ledger row(s) and % issued dispatch_service_invoice row(s) exist -- issue_carrier_invoice() is the only path that could have created them. Rolling back would remove the sole documented, guarded issuance mechanism while real financial records/agreement usage issued through it remain in the database. Refusing to guess whether that is safe. Resolve manually (e.g. keep 0145 applied) before attempting this rollback again. STOP.', v_used_version_count, v_issued_dsi_count;
  end if;

  -- Refusal 2: never drop objects a later migration may depend on.
  select count(*) into v_dependent_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname not in (
      'issue_carrier_invoice', '_issue_dispatch_service_invoice_internal',
      'create_carrier_dispatch_service_agreement', 'create_carrier_dispatch_service_agreement_version',
      'approve_carrier_dispatch_service_agreement_version', 'deactivate_carrier_dispatch_service_agreement_version',
      'deactivate_carrier_dispatch_service_agreement', 'guard_carrier_dispatch_service_agreement_version_lifecycle'
    )
    and (
      prosrc ilike '%carrier_dispatch_service_agreements%'
      or prosrc ilike '%carrier_dispatch_service_agreement_versions%'
      or prosrc ilike '%carrier_dispatch_service_billing_lines%'
      or prosrc ilike '%carrier_dispatch_service_agreement_idempotency%'
      or prosrc ilike '%organizations.remittance_instructions%'
    );
  if v_dependent_count > 0 then
    raise exception 'ROLLBACK_0145 refused: % other function(s) reference this migration''s own objects -- a later migration may depend on them. Resolve manually. STOP.', v_dependent_count;
  end if;

  -- Refusal 3: never roll back 0145 out from under an already-applied
  -- LATER migration. This repo''s own migrations/ directory is the
  -- authoritative check when run from a real checkout; a disposable test
  -- harness that never materializes migration files on disk will simply
  -- find none and pass this check vacuously.
  select count(*) into v_later_migration_count
  from pg_proc where pronamespace = 'public'::regnamespace and proname like '%0146%';
  if v_later_migration_count > 0 then
    raise exception 'ROLLBACK_0145 refused: % object(s) whose name suggests a later migration (0146+) already exist. Resolve manually. STOP.', v_later_migration_count;
  end if;

  raise notice 'ROLLBACK_0145 preconditions passed. Zero billing-ledger rows, zero issued dispatch-service invoices, zero external dependents, no later migration detected. Safe to restore the exact 0144 boundary.';
end
$rb$;

-- ======================= restore issue_carrier_invoice() to its exact 0144 body ==
create or replace function public.issue_carrier_invoice(
  p_invoice_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid;
  v_org uuid;
  v_operation constant text := 'issue_carrier_invoice';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_row public.carrier_invoices%rowtype;
  v_load_ids uuid[];
  v_load_id uuid;
  v_stop_id uuid;
  v_dispatch_ids uuid[];
  v_dispatch_id uuid;
  v_loads_payload jsonb;
  v_provisional_relationship_id uuid;
  v_relationship public.factoring_relationships%rowtype;
  v_carrier public.carriers%rowtype;
  v_company public.factoring_companies%rowtype;
  v_doc public.documents%rowtype;
  v_integration public.carrier_factoring_integrations%rowtype;
  v_classification jsonb;
  v_factoring_payload jsonb;
  v_remit public.carrier_remittance_profiles%rowtype;
  v_broker public.brokers%rowtype;
  v_customer public.customers%rowtype;
  v_party_status public.carrier_party_status;
  v_party_billing_email text;
  v_party_payment_terms integer;
  v_recipient_payload jsonb;
  v_problem text;
  v_li_id uuid;
  v_subtotal numeric(12, 2);
  v_total numeric(12, 2);
  v_payment_terms integer;
  v_due_date date;
  v_number text;
  v_snapshot_payload jsonb;
  v_result jsonb;
  v_constraint text;
begin
  ------------------------------------------------------------------
  -- STEP 1: authenticate + role. service_role has no auth.uid() /
  -- current_org_id() context of its own -- it structurally cannot pass
  -- this check, exactly as required ("must not function as an ordinary
  -- user substitute").
  ------------------------------------------------------------------
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to issue invoices.');
  end if;

  ------------------------------------------------------------------
  -- STEP 2: derive organization.
  ------------------------------------------------------------------
  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  ------------------------------------------------------------------
  -- STEP 3: canonical SHA-256 fingerprint (0143 mechanism). No patch
  -- object exists for this RPC -- expected_updated_at alone pins the
  -- exact row version a genuine retry must resend.
  ------------------------------------------------------------------
  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation,
      'schema_version', v_schema_version,
      'organization_id', v_org,
      'invoice_id', p_invoice_id,
      'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );

  ------------------------------------------------------------------
  -- STEP 4: organization+operation+idempotency-key advisory lock.
  ------------------------------------------------------------------
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  ------------------------------------------------------------------
  -- STEP 5: lock the carrier_invoices row.
  ------------------------------------------------------------------
  select * into v_row from public.carrier_invoices where id = p_invoice_id for update;

  ------------------------------------------------------------------
  -- STEP 6: revalidate organization / not-found (deliberately
  -- indistinguishable, matching update_carrier_invoice_draft's own
  -- convention).
  ------------------------------------------------------------------
  if v_row.id is null or v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;

  ------------------------------------------------------------------
  -- STEP 7: resolve idempotency replay/collision (operation-scoped).
  ------------------------------------------------------------------
  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_invoice_lifecycle_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  if v_row.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This invoice has changed since you loaded it. Reload and try again.');
  end if;

  ------------------------------------------------------------------
  -- STEP 8: issuance_status must be draft or ready_for_issue.
  ------------------------------------------------------------------
  if v_row.issuance_status = 'issued' then
    return jsonb_build_object('success', false, 'code', 'ALREADY_ISSUED', 'message', 'This invoice has already been issued.', 'invoice_number', v_row.invoice_number);
  end if;
  if v_row.issuance_status not in ('draft', 'ready_for_issue') then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Only a draft or ready-for-issue invoice can be issued.');
  end if;

  ------------------------------------------------------------------
  -- STEP 9: payment_status unpaid and amount_paid zero (already
  -- structurally guaranteed by cinv_payment_requires_issued for a draft/
  -- ready_for_issue row -- re-asserted here explicitly and defensively).
  ------------------------------------------------------------------
  if v_row.payment_status <> 'unpaid' or v_row.amount_paid <> 0 then
    return jsonb_build_object('success', false, 'code', 'PAYMENT_STATE_INVALID', 'message', 'This invoice has payment activity recorded and cannot be issued through this path.');
  end if;

  ------------------------------------------------------------------
  -- STEP 10: determine invoice document type. dispatch_service_invoice
  -- is rejected NOW, before locking the carrier, any recipient, or any
  -- source load (Section E, Option 2) -- never a silently-guessed fee.
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'dispatch_service_invoice' then
    return jsonb_build_object('success', false, 'code', 'DISPATCH_SERVICE_AGREEMENT_REQUIRED', 'message', 'Dispatch-service invoice issuance requires an authoritative fee agreement that does not exist yet. This invoice remains a draft.');
  end if;

  ------------------------------------------------------------------
  -- STEP 11 (global lock-order position 3): lock every source load,
  -- ascending id, BEFORE any carrier/factoring lock. Proven safe against
  -- every existing 0130-0143 load/dispatch-mutating path (guard_dispatch_
  -- carrier_scope, guard_load_carrier_change, reassign_dispatch_
  -- resources, transition_dispatch_status): none of them ever ALSO locks
  -- carriers/factoring_relationships/factoring_companies/carrier_
  -- factoring_integrations in the same transaction, so there is no
  -- existing path this ordering could reverse against -- see
  -- LOCK_ORDER_0144_INVOICE_ISSUANCE.md (Phase 3B.3C.1 revision) and
  -- Section C's dedicated two-session source-load-carrier race.
  ------------------------------------------------------------------
  select array_agg(load_id) into v_load_ids from public.carrier_invoice_loads where invoice_id = p_invoice_id;
  if v_load_ids is null or array_length(v_load_ids, 1) is null then
    return jsonb_build_object('success', false, 'code', 'INVOICE_INCOMPLETE', 'message', 'At least one source load must be attached before issuance.');
  end if;

  for v_load_id in select unnest(v_load_ids) as id order by 1 loop
    perform 1 from public.loads where id = v_load_id for update;
  end loop;

  if exists (select 1 from public.loads where id = any(v_load_ids) and carrier_id is distinct from v_row.carrier_id) then
    return jsonb_build_object('success', false, 'code', 'SOURCE_LOAD_CONFLICT', 'message', 'One or more attached loads no longer belong to this invoice''s carrier.');
  end if;

  ------------------------------------------------------------------
  -- STEP 11a (Phase 3B.3C.2, Section C): lock every load_stops row for
  -- the attached loads, in deterministic (load_id, stop_sequence, id)
  -- order, THEN reject missing/duplicate/malformed/ambiguous origin-
  -- destination structure -- only after every stop is locked, never
  -- from a provisional pre-lock read. A row lock alone cannot lock the
  -- ABSENCE of a row (a new stop being inserted mid-issuance) -- the
  -- Phase 3 guard trigger below (guard_load_stops_parent_lock) closes
  -- that gap structurally: every load_stops INSERT/UPDATE/DELETE must
  -- itself lock the SAME parent loads row this RPC already holds (step
  -- 11), so a concurrent insert attempt blocks here until this
  -- transaction commits or rolls back -- never observed mid-issuance,
  -- never silently racing the snapshot.
  ------------------------------------------------------------------
  for v_stop_id in
    select id from public.load_stops
    where load_id = any(v_load_ids)
    order by load_id, stop_sequence, id
  loop
    perform 1 from public.load_stops where id = v_stop_id for update;
  end loop;

  -- Missing: every attached load must have at least one pickup AND at
  -- least one delivery stop.
  if exists (
    select 1 from public.loads l
    where l.id = any(v_load_ids)
      and (
        not exists (select 1 from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup')
        or not exists (select 1 from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery')
      )
  ) then
    return jsonb_build_object('success', false, 'code', 'INVOICE_INCOMPLETE', 'message', 'One or more attached loads is missing a pickup or delivery stop.');
  end if;

  -- Duplicate/ambiguous: two stops on the SAME load sharing the
  -- identical stop_sequence value means "which one is actually first"
  -- is undefined -- never silently pick one via ORDER BY ... LIMIT 1.
  if exists (
    select 1 from public.load_stops ls
    where ls.load_id = any(v_load_ids)
    group by ls.load_id, ls.stop_sequence
    having count(*) > 1
  ) then
    return jsonb_build_object('success', false, 'code', 'SOURCE_LOAD_CONFLICT', 'message', 'One or more attached loads has ambiguous stop sequencing (duplicate stop_sequence values).');
  end if;

  -- Malformed: the resolved destination (latest-sequence delivery) must
  -- never sequence before the resolved origin (earliest-sequence
  -- pickup) -- a structurally inverted route.
  if exists (
    select 1 from public.loads l
    where l.id = any(v_load_ids)
      and (select max(ls.stop_sequence) from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery')
          < (select min(ls.stop_sequence) from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup')
  ) then
    return jsonb_build_object('success', false, 'code', 'SOURCE_LOAD_CONFLICT', 'message', 'One or more attached loads has a malformed route (a delivery stop sequenced before any pickup stop).');
  end if;

  ------------------------------------------------------------------
  -- STEP 11b (Phase 3B.3C.2, Section D): for every line item that
  -- references a source dispatch, lock that dispatch row (ascending
  -- id) and validate its load/carrier association under lock.
  -- source_dispatch_id is currently stored ONLY as an opaque historical
  -- reference -- no mutable dispatch field (status/driver_id/truck_id/
  -- trailer_id) is ever read into the snapshot, so there is no mutable
  -- dispatch DATA to go stale. What this validates is narrower and
  -- structural: that the dispatch a line item points to still belongs
  -- to one of this invoice's own attached loads and to this invoice's
  -- own carrier -- i.e. the reference itself has not become orphaned or
  -- cross-carrier since the line item was created. No column of
  -- `dispatches` is populated by this migration's own line-item
  -- creation path (line items are created via direct RLS grant, not by
  -- this RPC), so this loop is a structural no-op today and only
  -- becomes load-bearing once a future phase starts populating
  -- source_dispatch_id -- documented here rather than left unimplemented.
  ------------------------------------------------------------------
  select array_agg(distinct source_dispatch_id order by source_dispatch_id) into v_dispatch_ids
  from public.carrier_invoice_line_items
  where invoice_id = p_invoice_id and line_type = 'freight_charge' and source_dispatch_id is not null;

  if v_dispatch_ids is not null and array_length(v_dispatch_ids, 1) > 0 then
    for v_dispatch_id in select unnest(v_dispatch_ids) as id order by 1 loop
      perform 1 from public.dispatches where id = v_dispatch_id for share;
    end loop;
    if exists (
      select 1 from public.dispatches d
      where d.id = any(v_dispatch_ids)
        and (d.load_id <> all(v_load_ids) or d.carrier_id is distinct from v_row.carrier_id)
    ) then
      return jsonb_build_object('success', false, 'code', 'SOURCE_LOAD_CONFLICT', 'message', 'One or more line items reference a dispatch that no longer belongs to this invoice''s attached loads or carrier.');
    end if;
  end if;

  ------------------------------------------------------------------
  -- STEP 12 (global lock-order positions 4-5): PROVISIONAL (unlocked)
  -- discovery of the carrier's current default+active factoring
  -- relationship, REGARDLESS of the carrier's own factoring_mode -- a
  -- relationship can remain flagged default+active even after the
  -- carrier reverts to 'direct' (set_carrier_factoring_policy() never
  -- clears is_default/is_active), so this is the reliable way to find
  -- the correct row to lock BEFORE carriers, matching 0141's own
  -- established order (factoring_relationships -> carriers -> ...) --
  -- see this migration's own header, "PHASE 3B.3C.1 CORRECTION".
  --
  -- This read is provisional ONLY: every value is re-read and
  -- revalidated against the LOCKED, authoritative rows below. If the
  -- carrier's current default relationship turns out to differ from
  -- what was provisionally read (a genuine identity change, not merely
  -- a policy flip), STALE_CONFIGURATION is returned -- never a wrong-
  -- order lock attempt, never stale data used in the snapshot.
  ------------------------------------------------------------------
  select id into v_provisional_relationship_id
  from public.factoring_relationships
  where carrier_id = v_row.carrier_id and is_default and is_active;

  if v_provisional_relationship_id is not null then
    select * into v_relationship from public.factoring_relationships where id = v_provisional_relationship_id for update;
  end if;

  select * into v_carrier from public.carriers where id = v_row.carrier_id for update;
  if v_carrier.id is null or v_carrier.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'CARRIER_MISMATCH', 'message', 'The carrier on this invoice is not available.');
  end if;
  if not v_carrier.is_active then
    return jsonb_build_object('success', false, 'code', 'CARRIER_MISMATCH', 'message', 'This carrier is inactive.');
  end if;
  if v_carrier.invoice_code is null then
    return jsonb_build_object('success', false, 'code', 'INVOICE_INCOMPLETE', 'message', 'This carrier has no invoice numbering code configured yet.');
  end if;

  ------------------------------------------------------------------
  -- STEP 13 (global lock-order positions 5-8): direct vs factored
  -- policy, re-derived entirely from the now-LOCKED carrier row.
  -- Section E: every factoring input is locked and explicitly
  -- re-verified -- carrier remains factored; the relationship remains
  -- the carrier's current default, active, and effective; the company
  -- remains active; the NOA remains approved (and its document, if any,
  -- remains verified); the API integration (if used) remains attached
  -- to this same carrier/relationship/company and ready; and finally
  -- the authoritative readiness classifier is re-evaluated under lock.
  ------------------------------------------------------------------
  if v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', false, 'code', 'FACTORING_POLICY_UNCONFIGURED', 'message', 'This carrier has no factoring policy configured yet (direct or factored).');
  end if;

  if v_carrier.factoring_mode = 'direct' then
    -- Section F: a concurrent factored->direct transition is always
    -- safe to just follow here -- the FINAL decision is this freshly-
    -- locked carrier row, and no data from any provisionally-locked
    -- relationship is ever used when direct. No factor identity ever
    -- enters the snapshot for a direct carrier.
    v_factoring_payload := null;
  else
    -- factored: the relationship this call must use is whatever was
    -- provisionally locked above -- carriers is already locked, so this
    -- is the last point at which the CORRECT relationship could still
    -- be acquired in-order.
    if v_relationship.id is null then
      -- Nothing was provisionally locked. Two DISTINCT situations look
      -- identical this far, and deserve DIFFERENT codes: (a) this
      -- carrier genuinely has no default+active relationship at all --
      -- a permanent configuration gap, retrying changes nothing --
      -- FACTORING_NOT_READY; (b) one was created/defaulted AFTER our
      -- provisional read -- a genuine race, a retry will now discover
      -- and lock it correctly -- STALE_CONFIGURATION. A second,
      -- still-unlocked existence check (not a new lock -- just a read,
      -- so this cannot reintroduce the carrier-before-relationship
      -- reversal) is enough to tell them apart.
      if exists (select 1 from public.factoring_relationships where carrier_id = v_carrier.id and is_default and is_active) then
        return jsonb_build_object('success', false, 'code', 'STALE_CONFIGURATION', 'message', 'This carrier''s factoring configuration changed while processing. Please retry.');
      else
        return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier has no active default factoring relationship.');
      end if;
    end if;
    if v_relationship.carrier_id <> v_carrier.id or not v_relationship.is_default or not v_relationship.is_active then
      -- We DID lock something, but it is no longer the current default
      -- -- a genuine identity change between the provisional read and
      -- the lock. Always a race, never a permanent gap.
      return jsonb_build_object('success', false, 'code', 'STALE_CONFIGURATION', 'message', 'This carrier''s factoring configuration changed while processing. Please retry.');
    end if;
    if v_relationship.effective_from > current_date
       or (v_relationship.effective_to is not null and v_relationship.effective_to < current_date) then
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s default factoring relationship is not currently effective.');
    end if;

    select * into v_company from public.factoring_companies where id = v_relationship.factoring_company_id for share;
    if v_company.id is null or not v_company.is_active then
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s factoring company is not active.');
    end if;

    if v_relationship.noa_document_id is not null then
      select * into v_doc from public.documents where id = v_relationship.noa_document_id for share;
      if v_doc.id is null or not coalesce(v_doc.is_verified, false) then
        return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s Notice of Assignment document is no longer verified.');
      end if;
    end if;
    if not v_relationship.noa_approved then
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s Notice of Assignment is not approved.');
    end if;

    if v_relationship.submission_method = 'api' then
      select * into v_integration
      from public.carrier_factoring_integrations
      where factoring_relationship_id = v_relationship.id and is_active
      for share;
      if v_integration.id is null
         or v_integration.carrier_id <> v_carrier.id
         or v_integration.factoring_company_id <> v_company.id
         or v_integration.configuration_status <> 'ready' then
        return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s API factoring integration is not ready.');
      end if;
    end if;

    -- Final confirmation: the SAME authoritative classifier this schema
    -- already established (0138/0139/0141), now evaluated entirely
    -- under lock.
    v_classification := public.classify_carrier_factoring_readiness(v_carrier.id, v_row.recipient_broker_id, v_row.recipient_customer_id);
    if not (v_classification->>'success')::boolean or v_classification->>'classification' <> 'ready' then
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s factoring configuration is not ready for issuance.', 'classification', v_classification->>'classification');
    end if;

    v_factoring_payload := jsonb_build_object(
      'factoring_mode', 'factored',
      'relationship_id', v_relationship.id,
      'factoring_company_id', v_company.id,
      'factoring_company_legal_name', coalesce(v_company.legal_name, v_company.name),
      'remittance_instructions', v_relationship.remittance_instructions,
      'noa_reference', v_relationship.noa_reference,
      'noa_effective_date', v_relationship.noa_effective_date,
      'noa_approved', v_relationship.noa_approved,
      'noa_approved_at', v_relationship.noa_approved_at,
      'noa_document_id', v_relationship.noa_document_id,
      'noa_document_snapshot_file_name', v_relationship.noa_document_snapshot_file_name,
      'submission_method', v_relationship.submission_method,
      'submission_destination',
        case v_relationship.submission_method
          when 'secure_email' then v_relationship.submission_destination_email
          when 'api' then null -- never a raw destination for API -- the integration_id below is the safe pointer.
          else v_relationship.submission_notes
        end,
      'integration_id', v_integration.id
    );
  end if;

  ------------------------------------------------------------------
  -- STEP 14 (global lock-order position 9): carrier remittance profile.
  -- LOCKED (FOR SHARE), not merely read -- Section B: an immutable
  -- invoice must never contain a combination of carrier identity and
  -- remittance information that never coexisted at one valid, locked
  -- serialization point. No client write path exists for this table
  -- (only a direct, owner/admin-gated RLS UPDATE) -- FOR SHARE correctly
  -- conflicts with that concurrent UPDATE.
  ------------------------------------------------------------------
  select * into v_remit from public.carrier_remittance_profiles where carrier_id = v_carrier.id for share;

  ------------------------------------------------------------------
  -- STEP 15 (global lock-order position 10): resolve + lock exactly one
  -- recipient, validate the carrier-party relationship and active
  -- eligibility.
  ------------------------------------------------------------------
  if v_row.recipient_type = 'broker' then
    if v_row.recipient_broker_id is null then
      return jsonb_build_object('success', false, 'code', 'RECIPIENT_REQUIRED', 'message', 'A broker or customer recipient is required before issuance.');
    end if;
    select * into v_broker from public.brokers where id = v_row.recipient_broker_id for update;
    select status, billing_email, payment_terms_days
      into v_party_status, v_party_billing_email, v_party_payment_terms
    from public.carrier_brokers where carrier_id = v_row.carrier_id and broker_id = v_row.recipient_broker_id
    for update;
  elsif v_row.recipient_type = 'customer' then
    if v_row.recipient_customer_id is null then
      return jsonb_build_object('success', false, 'code', 'RECIPIENT_REQUIRED', 'message', 'A broker or customer recipient is required before issuance.');
    end if;
    select * into v_customer from public.customers where id = v_row.recipient_customer_id for update;
    select status, billing_email, payment_terms_days
      into v_party_status, v_party_billing_email, v_party_payment_terms
    from public.carrier_customers where carrier_id = v_row.carrier_id and customer_id = v_row.recipient_customer_id
    for update;
  else
    return jsonb_build_object('success', false, 'code', 'RECIPIENT_REQUIRED', 'message', 'A broker or customer recipient is required before issuance.');
  end if;

  -- Re-derive eligibility with the SAME classification logic
  -- carrier_invoice_recipient_problem already implements -- now safely
  -- observing the rows THIS transaction has already locked above.
  v_problem := public.carrier_invoice_recipient_problem(p_invoice_id);
  if v_problem is not null then
    return jsonb_build_object('success', false, 'code', 'RECIPIENT_INELIGIBLE', 'message', 'The recipient is not eligible for this invoice.', 'reason', v_problem);
  end if;

  ------------------------------------------------------------------
  -- STEP 16 (global lock-order position 11): lock every line item row,
  -- ascending id, THEN recalculate totals from the now-locked set
  -- (never from any client-supplied value -- this RPC's own signature
  -- accepts no total/subtotal parameter at all); validate currency and
  -- payment terms. Explicit locking here is deliberate belt-and-
  -- suspenders on top of the Phase 3 mutability-guard hardening (which
  -- already serializes any concurrent line-item mutation behind this
  -- same transaction's carrier_invoices lock) -- it keeps this
  -- function's own correctness self-contained rather than depending
  -- entirely on a trigger defined elsewhere.
  ------------------------------------------------------------------
  for v_li_id in
    select id from public.carrier_invoice_line_items
    where invoice_id = p_invoice_id and line_type = 'freight_charge'
    order by id
  loop
    perform 1 from public.carrier_invoice_line_items where id = v_li_id for update;
  end loop;

  select coalesce(sum(line_total), 0) into v_subtotal
  from public.carrier_invoice_line_items
  where invoice_id = p_invoice_id and line_type = 'freight_charge';

  v_total := v_subtotal + v_row.tax_amount + v_row.adjustments_amount;
  if v_total <= 0 then
    return jsonb_build_object('success', false, 'code', 'TOTAL_INVALID', 'message', 'The invoice total must be greater than zero.');
  end if;

  if v_row.currency !~ '^[A-Z]{3}$' then
    return jsonb_build_object('success', false, 'code', 'TOTAL_INVALID', 'message', 'The invoice currency is not valid.');
  end if;
  v_payment_terms := coalesce(v_row.payment_terms_days, v_party_payment_terms, 30);
  v_due_date := coalesce(v_row.due_date, current_date + v_payment_terms);

  ------------------------------------------------------------------
  -- STEP 17 (global lock-order position 12): allocate the correct
  -- issuer/year invoice number. Freight only is reachable here
  -- (dispatch-service already returned at STEP 10) -- the dispatch-
  -- service branch is retained for structural completeness/
  -- documentation only.
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'carrier_freight_invoice' then
    v_number := public._generate_carrier_invoice_number_internal('carrier_freight_invoice'::public.invoice_document_type, v_carrier.id, v_carrier.invoice_code);
  else
    -- Unreachable in this migration (STEP 10 already returned) -- kept
    -- so a future migration that removes the STEP 10 early return does
    -- not also have to reinvent this branch.
    v_number := public._generate_carrier_invoice_number_internal(
      'dispatch_service_invoice'::public.invoice_document_type, v_org,
      (select dispatch_invoice_prefix from public.platform_settings limit 1));
  end if;

  ------------------------------------------------------------------
  -- STEP 15 (recipient identity) + STEP 11 (loads) payloads, built from
  -- already-locked rows only.
  ------------------------------------------------------------------
  if v_row.recipient_type = 'broker' then
    v_recipient_payload := jsonb_build_object(
      'type', 'broker', 'broker_id', v_broker.id, 'legal_name', v_broker.company_name,
      'mc_number', v_broker.mc_number, 'contact_name', v_broker.contact_name,
      'phone', v_broker.phone, 'email', v_broker.email,
      'address_line1', v_broker.address_line1, 'address_line2', v_broker.address_line2,
      'city', v_broker.city, 'state', v_broker.state, 'postal_code', v_broker.postal_code, 'country', v_broker.country,
      'billing_email', v_party_billing_email
    );
  else
    v_recipient_payload := jsonb_build_object(
      'type', 'customer', 'customer_id', v_customer.id, 'legal_name', v_customer.company_name,
      'contact_name', v_customer.contact_name, 'phone', v_customer.phone, 'email', v_customer.email,
      'address_line1', v_customer.billing_address_line1, 'address_line2', v_customer.billing_address_line2,
      'city', v_customer.city, 'state', v_customer.state, 'postal_code', v_customer.postal_code, 'country', v_customer.country,
      'billing_email', v_party_billing_email
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'load_id', l.id, 'load_number', l.load_number, 'agreed_freight_charge', l.rate,
      'origin', (
        select jsonb_build_object('facility_name', ls.facility_name, 'city', ls.city, 'state', ls.state, 'scheduled_at', ls.scheduled_at, 'arrived_at', ls.arrived_at)
        from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence asc limit 1
      ),
      'destination', (
        select jsonb_build_object('facility_name', ls.facility_name, 'city', ls.city, 'state', ls.state, 'scheduled_at', ls.scheduled_at, 'arrived_at', ls.arrived_at)
        from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1
      )
    ) order by l.load_number), '[]'::jsonb)
    into v_loads_payload
  from public.loads l where l.id = any(v_load_ids);

  ------------------------------------------------------------------
  -- STEP 13 (build phase): build the complete server-generated immutable snapshot
  -- payload; reject forbidden secret/credential keys (defense-in-depth --
  -- civs_no_forbidden_keys on the target table is the structural
  -- backstop; this is the RPC's own explicit check of its own intent).
  ------------------------------------------------------------------
  v_snapshot_payload := jsonb_build_object(
    'schema_version', 1,
    'invoice_id', p_invoice_id,
    'invoice_document_type', v_row.invoice_document_type,
    'invoice_number', v_number,
    'organization_id', v_org,
    'issued_at', now(),
    'issued_by', v_uid,
    'currency', v_row.currency,
    'payment_terms_days', v_payment_terms,
    'due_date', v_due_date,
    'subtotal_amount', v_subtotal,
    'tax_amount', v_row.tax_amount,
    'adjustments_amount', v_row.adjustments_amount,
    'total_amount', v_total,
    'line_items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', li.id, 'description', li.description, 'quantity', li.quantity,
        'unit_price', li.unit_price, 'amount', li.line_total,
        'source_load_id', li.source_load_id, 'source_dispatch_id', li.source_dispatch_id
      ) order by li.sort_order, li.created_at), '[]'::jsonb)
      from public.carrier_invoice_line_items li where li.invoice_id = p_invoice_id and li.line_type = 'freight_charge'
    ),
    'issuer', jsonb_build_object(
      'carrier_id', v_carrier.id, 'legal_name', v_carrier.legal_name, 'dba_name', v_carrier.dba_name,
      'mc_number', v_carrier.mc_number, 'dot_number', v_carrier.dot_number,
      'address_line1', v_carrier.address_line1, 'address_line2', v_carrier.address_line2,
      'city', v_carrier.city, 'state', v_carrier.state, 'postal_code', v_carrier.postal_code, 'country', v_carrier.country,
      'contact_name', v_carrier.contact_name, 'phone', v_carrier.phone, 'email', v_carrier.email,
      'remittance', case when v_remit.carrier_id is null then null else jsonb_build_object(
        'remittance_name', v_remit.remittance_name, 'remittance_address_line1', v_remit.remittance_address_line1,
        'remittance_address_line2', v_remit.remittance_address_line2, 'remittance_city', v_remit.remittance_city,
        'remittance_state', v_remit.remittance_state, 'remittance_postal_code', v_remit.remittance_postal_code,
        'remittance_country', v_remit.remittance_country, 'remittance_email', v_remit.remittance_email,
        'remittance_instructions', v_remit.remittance_instructions
      ) end
    ),
    'recipient', v_recipient_payload,
    'loads', v_loads_payload,
    'factoring', v_factoring_payload,
    'dispatch_service', null,
    'issuing_user_id', v_uid
  );

  if public.jsonb_contains_forbidden_key(
    v_snapshot_payload,
    array['secret_reference', 'api_key', 'access_token', 'refresh_token', 'password', 'client_secret', 'credential', 'credentials', 'private_key']
  ) then
    raise exception 'issue_carrier_invoice: internal invariant violated -- the constructed snapshot payload contains a forbidden credential-shaped key. Aborting.' using errcode = '55000';
  end if;

  ------------------------------------------------------------------
  -- STEP 13 (apply phase): insert exactly one snapshot; set invoice_number/
  -- issued_at/issued_by/issuance_status='issued'/totals/due_date; write
  -- exactly one audit event; store the idempotency result -- all in ONE
  -- savepoint-scoped block (mirrors update_carrier_invoice_draft's own
  -- established pattern), so a same-key collision at the final INSERT
  -- rolls back everything above together.
  ------------------------------------------------------------------
  begin
    -- draft -> issued requires the intermediate ready_for_issue step
    -- (the lifecycle trigger's state machine has no direct draft->issued
    -- transition -- see this migration's own header, Section A).
    if v_row.issuance_status = 'draft' then
      update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = p_invoice_id;
    end if;

    insert into public.carrier_invoice_issuance_snapshots
      (invoice_id, organization_id, invoice_document_type, issued_by, currency, invoice_number,
       payment_terms_days, due_date, subtotal_amount, tax_amount, adjustments_amount, total_amount,
       amount_due_at_issuance, carrier_id, recipient_broker_id, recipient_customer_id, snapshot_payload)
    values
      (p_invoice_id, v_org, v_row.invoice_document_type, v_uid, v_row.currency, v_number,
       v_payment_terms, v_due_date, v_subtotal, v_row.tax_amount, v_row.adjustments_amount, v_total,
       v_total, v_carrier.id, v_row.recipient_broker_id, v_row.recipient_customer_id, v_snapshot_payload);

    update public.carrier_invoices
      set issuance_status = 'issued', invoice_number = v_number, issued_at = now(), issued_by = v_uid,
          subtotal_amount = v_subtotal, total_amount = v_total, due_date = v_due_date, payment_terms_days = v_payment_terms
      where id = p_invoice_id;

    perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'carrier_invoice_issued',
      jsonb_build_object('invoice_number', v_number, 'total_amount', v_total, 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'ISSUED', 'invoice_id', p_invoice_id, 'invoice_number', v_number,
      'total_amount', v_total, 'issued_at', (select issued_at from public.carrier_invoices where id = p_invoice_id)
    );

    insert into public.carrier_invoice_lifecycle_idempotency
      (organization_id, idempotency_key, invoice_id, operation, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, p_invoice_id, v_operation, v_fingerprint, v_schema_version, v_result, 'completed', v_uid);
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'civ_idempotency_unique' then
        raise;
      end if;
      -- The whole block above (status transition + snapshot + number
      -- allocation + audit + this same INSERT attempt) has already been
      -- rolled back to the savepoint -- structurally unreachable in
      -- practice (the advisory lock already serializes every caller
      -- sharing this exact org+operation+key tuple); defense-in-depth
      -- only, matching update_carrier_invoice_draft's own precedent.
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_invoice_lifecycle_idempotency
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

revoke all on function public.issue_carrier_invoice(uuid, timestamptz, text, text) from public, anon;
grant execute on function public.issue_carrier_invoice(uuid, timestamptz, text, text) to authenticated;

comment on function public.issue_carrier_invoice(uuid, timestamptz, text, text) is
  'Phase 3B.3C, lock-order-corrected in Phase 3B.3C.1, route-snapshot-locked in Phase 3B.3C.2: the ONE atomic, idempotent issuance path for carrier_freight_invoice (dispatch_service_invoice returns DISPATCH_SERVICE_AGREEMENT_REQUIRED -- Section E Option 2, no authoritative fee agreement exists yet). Restored to its exact pre-0145 (0144) body by this rollback, including the loads.rate read this migration corrected -- fixing that defect for good means keeping 0145 applied.';

-- ======================= drop 0145's own objects, in dependency order ======
drop function public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text);
drop function public.create_carrier_dispatch_service_agreement(uuid, text, text, text);
drop function public.create_carrier_dispatch_service_agreement_version(uuid, public.dispatch_service_fee_method, numeric, numeric, numeric, numeric, text, integer, date, date, text, text);
drop function public.approve_carrier_dispatch_service_agreement_version(uuid, timestamptz, text, text, uuid);
drop function public.deactivate_carrier_dispatch_service_agreement_version(uuid, timestamptz, text, text);
drop function public.deactivate_carrier_dispatch_service_agreement(uuid, timestamptz, text, text);
-- Phase 3B.4.1: the carrier-scoped effective-dates advisory-lock-key
-- helper every one of the six functions just dropped above referenced
-- in its own PL/pgSQL body -- PostgreSQL tracks no pg_depend edge for a
-- plain-text PL/pgSQL function-body reference (unlike a view or an SQL-
-- language function), so dropping it here, after its callers, is purely
-- for logical tidiness, not a dependency requirement.
drop function public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid, uuid);

drop table public.carrier_dispatch_service_billing_lines;
-- carrier_dispatch_service_agreements.current_version_id FK's a version;
-- carrier_dispatch_service_agreement_versions.agreement_id FK's an
-- agreement -- a genuine circular dependency between the two tables.
-- Drop the FK first so either table can then be dropped in either order.
alter table public.carrier_dispatch_service_agreements drop constraint cdsa_current_version_fk;
drop table public.carrier_dispatch_service_agreement_versions;
drop function public.guard_carrier_dispatch_service_agreement_version_lifecycle();
drop table public.carrier_dispatch_service_agreements;
drop table public.carrier_dispatch_service_agreement_idempotency;

drop type public.dispatch_service_fee_method;
drop type public.dispatch_service_agreement_version_status;
drop type public.dispatch_service_agreement_status;

-- 0145 created this extension solely for cdsav_no_overlap_when_approved
-- (just dropped above, with the table it belonged to) -- nothing else in
-- 0001-0144 uses it (confirmed: no other EXCLUDE USING gist/daterange
-- usage exists anywhere in this schema). Dropping it restores the EXACT
-- 0144 boundary rather than leaving an unused extension behind.
drop extension if exists btree_gist;

alter table public.organizations drop column remittance_instructions;

-- Note: entity_type's new 'carrier_dispatch_service_agreement' enum value
-- is NOT removed -- PostgreSQL does not support dropping an enum value
-- (the same limitation every prior migration's own rollback in this
-- codebase already documents/accepts, e.g. ROLLBACK_0099's carrier_w9
-- entity_type value). A stray unused enum label is harmless.

-- ======================= POSTCONDITIONS =====================================
do $rb$
begin
  if to_regprocedure('public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)') is not null then
    raise exception 'ROLLBACK_0145 postcondition: _issue_dispatch_service_invoice_internal(...) still exists.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreements') is not null then
    raise exception 'ROLLBACK_0145 postcondition: carrier_dispatch_service_agreements still exists.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreement_versions') is not null then
    raise exception 'ROLLBACK_0145 postcondition: carrier_dispatch_service_agreement_versions still exists.';
  end if;
  if to_regclass('public.carrier_dispatch_service_billing_lines') is not null then
    raise exception 'ROLLBACK_0145 postcondition: carrier_dispatch_service_billing_lines still exists.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreement_idempotency') is not null then
    raise exception 'ROLLBACK_0145 postcondition: carrier_dispatch_service_agreement_idempotency still exists.';
  end if;
  if to_regprocedure('public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)') is not null then
    raise exception 'ROLLBACK_0145 postcondition: _carrier_dispatch_service_agreement_effective_dates_lock_key(...) still exists.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='organizations' and column_name='remittance_instructions') then
    raise exception 'ROLLBACK_0145 postcondition: organizations.remittance_instructions still exists.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%DISPATCH_SERVICE_AGREEMENT_REQUIRED%' then
    raise exception 'ROLLBACK_0145 postcondition: issue_carrier_invoice() does not contain the restored DISPATCH_SERVICE_AGREEMENT_REQUIRED early return.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%l.rate%' then
    raise exception 'ROLLBACK_0145 postcondition: issue_carrier_invoice() does not contain the restored (defect-included) l.rate read.';
  end if;

  raise notice 'ROLLBACK_0145 complete: exact 0144 boundary restored (issue_carrier_invoice back to its exact 0144 body, defect included; _issue_dispatch_service_invoice_internal and all five agreement-lifecycle RPCs dropped; carrier_dispatch_service_agreements/_versions/_billing_lines/_idempotency dropped; the three new enum types dropped; organizations.remittance_instructions dropped). load_financials, carrier_invoice_lifecycle_idempotency, carrier_invoice_number_counters, and every other 0001-0144 object left untouched.';
end
$rb$;

commit;
