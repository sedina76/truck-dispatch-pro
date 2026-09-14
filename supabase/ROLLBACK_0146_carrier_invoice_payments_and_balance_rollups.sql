-- ============================================================================
-- ROLLBACK_0146_carrier_invoice_payments_and_balance_rollups.sql
-- Restores the EXACT 0145 boundary -- both the payment ledger 0146 added
-- AND the schema_version=2 issuance compatibility correction (Phase
-- 3B.5.2) it applied to the INSTALLED issue_carrier_invoice()/_issue_
-- dispatch_service_invoice_internal() definitions (CREATE OR REPLACE back
-- to 0145's own exact, original bodies). Refuses if any payment history
-- exists, if any schema_version=2 issuance snapshot exists, if any other
-- object depends on what 0146 introduced, or if a later migration (0147+)
-- already exists. Disposable-test-cluster use only -- never run against a
-- real database. See this migration's own header (Section A/A.1) for what
-- 0146 did and did not touch.
-- ============================================================================
begin;

-- ======================= PRECONDITIONS / REFUSAL ============================
do $rb$
declare
  v_payment_count integer;
  v_later_migration_count integer;
  v_v2_snapshot_count integer;
begin
  if to_regclass('public.carrier_invoice_payments') is null then
    raise exception 'ROLLBACK_0146: carrier_invoice_payments does not exist -- 0146 does not appear to be applied. STOP.';
  end if;

  select count(*) into v_payment_count from public.carrier_invoice_payments;
  if v_payment_count > 0 then
    raise exception 'ROLLBACK_0146 refused: % carrier_invoice_payments row(s) exist -- record_carrier_invoice_payment()/void_carrier_invoice_payment() are the only paths that could have created them. Rolling back would remove the sole documented, guarded payment mechanism while real financial records issued through it remain in the database (and remain reflected in carrier_invoices.amount_paid/payment_status, which this rollback cannot safely revert without erasing payment history). Refusing to guess whether that is safe. Resolve manually (e.g. keep 0146 applied) before attempting this rollback again. STOP.', v_payment_count;
  end if;

  -- Phase 3B.5.2, Section J: refuse if ANY schema_version=2 issuance
  -- snapshot exists -- restoring 0145's own original issue_carrier_
  -- invoice()/_issue_dispatch_service_invoice_internal() bodies (which
  -- understand ONLY schema_version=1) while a v2-snapshotted, already-
  -- issued invoice remains in the database would leave that invoice's own
  -- immutable financial history stranded against a validator this
  -- rollback is about to remove entirely. Never rewritten, never deleted
  -- -- resolve manually (e.g. keep 0146 applied) instead.
  select count(*) into v_v2_snapshot_count
  from public.carrier_invoice_issuance_snapshots
  where (snapshot_payload ->> 'schema_version') = '2';
  if v_v2_snapshot_count > 0 then
    raise exception 'ROLLBACK_0146 refused: % schema_version=2 issuance snapshot(s) exist -- these could only have been written by this migration''s own replaced issue_carrier_invoice()/_issue_dispatch_service_invoice_internal(). Restoring 0145''s original (schema_version=1-only) bodies would leave this already-issued financial history behind a validator this rollback removes. Refusing to guess whether that is safe. Resolve manually (e.g. keep 0146 applied) before attempting this rollback again. STOP.', v_v2_snapshot_count;
  end if;

  -- Refuse if a later migration file's own objects are already present
  -- (matches 0145's own rollback precedent) -- a crude but effective
  -- signal: look for any function whose name suggests migration 0147+.
  select count(*) into v_later_migration_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname ~ '_01(4[7-9]|[5-9][0-9])_'; -- 0147-0199 style internal names, if any ever appear
  if v_later_migration_count > 0 then
    raise exception 'ROLLBACK_0146 refused: % object(s) matching a later migration''s naming convention were found -- a dependent migration may already be applied on top of 0146. Refusing to roll back underneath it. STOP.', v_later_migration_count;
  end if;

  raise notice 'ROLLBACK_0146 preconditions passed. Zero payment history, zero schema_version=2 snapshots, no later migration detected. Safe to restore the exact 0145 boundary.';
end
$rb$;

-- ======================= restore 0145's EXACT issuance function bodies =====
-- Phase 3B.5.2, Section J. CREATE OR REPLACE back to 0145's own installed
-- text, byte-for-byte (re-typed here since CREATE OR REPLACE requires the
-- whole body, exactly as 0146 itself, and 0145 before it, already did for
-- this same function) -- schema_version=1, 0145's own factoring encoding
-- ('factoring_mode'/'factoring_relationship_id'), 'issuing_user_id' and
-- the always-null 'dispatch_service' key restored exactly as they were.
-- _issue_dispatch_service_invoice_internal is restored FIRST (issue_
-- carrier_invoice calls it internally; see this migration's own PHASE 1C
-- header for why definition order does not matter to a plpgsql body, kept
-- here purely for reading-order consistency with PHASE 1C). Installed
-- here via CREATE OR REPLACE (0145's own original text used plain CREATE
-- FUNCTION, since the function did not exist before 0145 -- 0146 already
-- replaced it, so OR REPLACE is required here; this DDL-verb difference
-- is NOT part of the stored function body/prosrc and has zero effect on
-- the exact-source-comparison goal this rollback must satisfy).
create or replace function public._issue_dispatch_service_invoice_internal(
  p_invoice_id uuid,
  p_row public.carrier_invoices,
  p_uid uuid,
  p_org uuid,
  p_reason text,
  p_idempotency_key text,
  p_operation text,
  p_schema_version integer,
  p_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_load_ids uuid[];
  v_load_id uuid;
  v_load public.loads%rowtype;
  v_version_id uuid;
  v_version public.carrier_dispatch_service_agreement_versions%rowtype;
  v_carrier public.carriers%rowtype;
  v_remit public.carrier_remittance_profiles%rowtype;
  v_org_row public.organizations%rowtype;
  v_agreement_status public.dispatch_service_agreement_status;
  v_any_version_exists boolean;
  v_any_approved_exists boolean;
  v_freight_invoice_id uuid;
  v_freight_invoice_number text;
  v_freight_issued_at timestamptz;
  v_freight_snapshot jsonb;
  v_freight_amount numeric(12, 2);
  v_fee numeric(10, 2);
  v_subtotal numeric(12, 2) := 0;
  v_total numeric(12, 2);
  v_payment_terms integer;
  v_due_date date;
  v_number text;
  v_li_id uuid;
  v_billing_lines jsonb := '[]'::jsonb;
  v_line_no integer := 0;
  v_snapshot_payload jsonb;
  v_result jsonb;
  v_constraint text;
begin
  ------------------------------------------------------------------
  -- Loads (lock-order position 3): reuse the SAME "at least one source
  -- load, ascending id, FOR UPDATE" pattern 0144's freight path already
  -- established. Dispatch-service invoices need no load_stops/route
  -- validation at all (Section J never snapshots a route) -- so the
  -- load_stops parent-lock trigger (0144) never comes into play here.
  ------------------------------------------------------------------
  select array_agg(load_id) into v_load_ids from public.carrier_invoice_loads where invoice_id = p_invoice_id;
  if v_load_ids is null or array_length(v_load_ids, 1) is null then
    return jsonb_build_object('success', false, 'code', 'INVOICE_INCOMPLETE', 'message', 'At least one covered load must be attached before issuance.');
  end if;

  for v_load_id in select unnest(v_load_ids) as id order by 1 loop
    perform 1 from public.loads where id = v_load_id for update;
  end loop;

  if exists (select 1 from public.loads where id = any(v_load_ids) and carrier_id is distinct from p_row.carrier_id) then
    return jsonb_build_object('success', false, 'code', 'LOAD_NOT_ELIGIBLE', 'message', 'One or more covered loads no longer belong to this invoice''s carrier.');
  end if;
  if exists (select 1 from public.loads where id = any(v_load_ids) and status not in ('delivered', 'pod_received', 'invoiced', 'closed')) then
    return jsonb_build_object('success', false, 'code', 'LOAD_NOT_ELIGIBLE', 'message', 'One or more covered loads are not yet delivered/completed.');
  end if;

  ------------------------------------------------------------------
  -- Phase 3B.4.1, Section A: acquire the SAME carrier-scoped effective-
  -- dates advisory lock every agreement-lifecycle RPC acquires, BEFORE
  -- looking up or locking any version row -- serializes this lookup
  -- against a concurrent approve/supersede/deactivate for this SAME
  -- carrier. Because this lock is held for this entire transaction, and
  -- every lifecycle RPC holds the IDENTICAL lock for its own entire
  -- transaction, whichever side gets here first fully completes (commit
  -- or rollback) before the other proceeds -- the version this call then
  -- reads is always a fully-resolved, never a torn, state.
  ------------------------------------------------------------------
  perform pg_advisory_xact_lock(public._carrier_dispatch_service_agreement_effective_dates_lock_key(p_org, p_row.carrier_id));

  ------------------------------------------------------------------
  -- Applicable agreement version (lock-order position 4): the SINGLE
  -- approved version for (carrier, TODAY) governs every covered load in
  -- THIS invoice (Section F's own suggested simplification, extended
  -- uniformly rather than per-load-service-date -- documented explicitly
  -- as a deliberate simplification, not an oversight; a future migration
  -- may revisit per-load service-date lookup if a real need arises).
  ------------------------------------------------------------------
  select v.id into v_version_id
  from public.carrier_dispatch_service_agreement_versions v
  join public.carrier_dispatch_service_agreements a on a.id = v.agreement_id
  where v.carrier_id = p_row.carrier_id and v.organization_id = p_org
    and a.status = 'active' and v.status = 'approved'
    and v.effective_from <= current_date and (v.effective_to is null or v.effective_to >= current_date)
  order by v.effective_from desc
  limit 1;

  if v_version_id is null then
    select exists (
      select 1 from public.carrier_dispatch_service_agreement_versions where carrier_id = p_row.carrier_id and organization_id = p_org
    ) into v_any_version_exists;
    if not v_any_version_exists then
      return jsonb_build_object('success', false, 'code', 'AGREEMENT_REQUIRED', 'message', 'This carrier has no dispatch-service agreement. Create and approve one before issuing.');
    end if;
    select exists (
      select 1 from public.carrier_dispatch_service_agreement_versions where carrier_id = p_row.carrier_id and organization_id = p_org and status = 'approved'
    ) into v_any_approved_exists;
    if not v_any_approved_exists then
      return jsonb_build_object('success', false, 'code', 'AGREEMENT_NOT_APPROVED', 'message', 'This carrier''s dispatch-service agreement has no approved version yet.');
    end if;
    return jsonb_build_object('success', false, 'code', 'AGREEMENT_NOT_EFFECTIVE', 'message', 'This carrier has an approved dispatch-service agreement version, but none is effective today.');
  end if;

  select * into v_version from public.carrier_dispatch_service_agreement_versions where id = v_version_id for update;

  -- Re-validate under lock -- a concurrent supersede/deactivate could
  -- have landed between the unlocked lookup above and this lock
  -- (STALE_AGREEMENT, never a silent stale read).
  if v_version.status <> 'approved'
    or v_version.effective_from > current_date
    or (v_version.effective_to is not null and v_version.effective_to < current_date)
  then
    return jsonb_build_object('success', false, 'code', 'STALE_AGREEMENT', 'message', 'The dispatch-service agreement version changed while this invoice was being issued. Reload and try again.');
  end if;
  if v_version.currency <> p_row.currency then
    return jsonb_build_object('success', false, 'code', 'AGREEMENT_CURRENCY_MISMATCH', 'message', 'The agreement version''s currency does not match this invoice''s currency.');
  end if;

  ------------------------------------------------------------------
  -- Carrier (lock-order position 5) -- SAME table/order as 0144's
  -- freight path (loads always locked before carriers, in both paths).
  -- Phase 3B.4.1, Section C: a carrier not found/wrong-org (CARRIER_
  -- MISMATCH, matching 0144's own established meaning) or inactive
  -- (CARRIER_INACTIVE -- a distinct, dispatch-service-specific code, for
  -- accurate UI behavior, rather than overloading CARRIER_MISMATCH the
  -- way 0144's freight path does) can never receive a NEW dispatch-
  -- service invoice. This FOR UPDATE lock is held for the rest of this
  -- transaction -- a concurrent deactivation of this SAME carrier row
  -- either fully precedes this check (seen here, rejected) or blocks
  -- until this transaction commits/rolls back (never interleaves).
  ------------------------------------------------------------------
  select * into v_carrier from public.carriers where id = p_row.carrier_id for update;
  if v_carrier.id is null or v_carrier.organization_id <> p_org then
    return jsonb_build_object('success', false, 'code', 'CARRIER_MISMATCH', 'message', 'The carrier on this invoice is not available.');
  end if;
  if not v_carrier.is_active then
    return jsonb_build_object('success', false, 'code', 'CARRIER_INACTIVE', 'message', 'This carrier is inactive and cannot receive new dispatch-service invoices.');
  end if;
  select * into v_remit from public.carrier_remittance_profiles where carrier_id = v_carrier.id for share;

  ------------------------------------------------------------------
  -- Dispatch organization identity (lock-order position 6) -- a brand-
  -- new resource; FOR SHARE is sufficient (read-only identity capture).
  --
  -- Phase 3B.4.1, Section G: organizations.remittance_instructions (the
  -- ONLY remittance/payment-instruction field 0145 itself introduced --
  -- see PHASE 2 -- and the sole field this snapshot's own 'issuer'
  -- block ever reads for remittance) is the single authoritative
  -- source. A dispatch-service invoice is a LEGAL demand for payment
  -- FROM the carrier TO this organization -- issuing one with an empty
  -- remittance_instructions would mean telling the carrier to pay an
  -- organization with no stated instructions for how, which this
  -- schema never fabricates a substitute for (no bank-account/routing
  -- data is ever added here -- only the free-text instructions field
  -- itself, exactly as the carrier's own remittance snapshot already
  -- works). Checked immediately after locking the row, before any
  -- per-load work or number allocation.
  ------------------------------------------------------------------
  select * into v_org_row from public.organizations where id = p_org for share;
  if v_org_row.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'The dispatch organization was not found.');
  end if;
  if v_org_row.remittance_instructions is null or btrim(v_org_row.remittance_instructions) = '' then
    return jsonb_build_object('success', false, 'code', 'DISPATCH_REMITTANCE_REQUIRED', 'message', 'This organization has no remittance/payment instructions on file yet. Add them before issuing a dispatch-service invoice.');
  end if;

  ------------------------------------------------------------------
  -- Per-load fee calculation (lock-order position 7 for the freight
  -- basis, percentage_of_freight only) + billing-ledger insert
  -- (position 8) + line item, one row per covered load, ascending id.
  ------------------------------------------------------------------
  for v_load_id in select unnest(v_load_ids) as id order by 1 loop
    select * into v_load from public.loads where id = v_load_id;

    if v_version.fee_method = 'percentage_of_freight' then
      select ci.id, ci.invoice_number, ci.issued_at into v_freight_invoice_id, v_freight_invoice_number, v_freight_issued_at
      from public.carrier_invoice_loads cil
      join public.carrier_invoices ci on ci.id = cil.invoice_id
      where cil.load_id = v_load_id
        and ci.invoice_document_type = 'carrier_freight_invoice'
        and ci.issuance_status = 'issued'
        and ci.carrier_id = p_row.carrier_id
      order by ci.issued_at desc
      limit 1;

      if v_freight_invoice_id is null then
        return jsonb_build_object('success', false, 'code', 'FREIGHT_INVOICE_REQUIRED', 'message', 'Load '||v_load.load_number||' has no issued carrier freight invoice yet -- required before a percentage-based dispatch-service fee can be calculated.', 'load_id', v_load_id);
      end if;

      -- FOR SHARE: the freight invoice is already issued/immutable, but
      -- still explicitly locked, matching this project's own established
      -- "lock even an already-immutable row before reading it into a NEW
      -- snapshot" convention (0144: NOA document, remittance profile).
      perform 1 from public.carrier_invoices where id = v_freight_invoice_id for share;
      if (select carrier_id from public.carrier_invoices where id = v_freight_invoice_id) is distinct from p_row.carrier_id then
        return jsonb_build_object('success', false, 'code', 'FREIGHT_INVOICE_CARRIER_MISMATCH', 'message', 'The related freight invoice no longer belongs to this dispatch-service invoice''s carrier.', 'load_id', v_load_id);
      end if;

      select snapshot_payload into v_freight_snapshot from public.carrier_invoice_issuance_snapshots where invoice_id = v_freight_invoice_id for share;
      select (elem ->> 'agreed_freight_charge')::numeric into v_freight_amount
      from jsonb_array_elements(coalesce(v_freight_snapshot -> 'loads', '[]'::jsonb)) elem
      where (elem ->> 'load_id')::uuid = v_load_id;

      if v_freight_amount is null or v_freight_amount <= 0 then
        return jsonb_build_object('success', false, 'code', 'FEE_CALCULATION_INVALID', 'message', 'No authoritative freight amount was found for load '||v_load.load_number||' in the related freight invoice''s snapshot.', 'load_id', v_load_id);
      end if;

      v_fee := round(v_freight_amount * (v_version.percentage_rate / 100.0), 2);
    else -- flat_per_load
      v_freight_invoice_id := null;
      v_freight_invoice_number := null;
      v_freight_amount := null;
      v_fee := v_version.flat_fee_per_load;
    end if;

    if v_version.minimum_fee is not null and v_fee < v_version.minimum_fee then
      v_fee := v_version.minimum_fee;
    end if;
    if v_version.maximum_fee is not null and v_fee > v_version.maximum_fee then
      v_fee := v_version.maximum_fee;
    end if;
    if v_fee <= 0 then
      return jsonb_build_object('success', false, 'code', 'FEE_CALCULATION_INVALID', 'message', 'The calculated dispatch-service fee for load '||v_load.load_number||' is not a positive amount.', 'load_id', v_load_id);
    end if;

    begin
      insert into public.carrier_dispatch_service_billing_lines
        (organization_id, invoice_id, carrier_id, agreement_version_id, load_id, source_freight_invoice_id,
         fee_method, authoritative_freight_amount, calculated_fee, currency)
      values
        (p_org, p_invoice_id, p_row.carrier_id, v_version_id, v_load_id, v_freight_invoice_id,
         v_version.fee_method, v_freight_amount, v_fee, v_version.currency);
    exception
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'carrier_dispatch_service_billing_lines_load_id_key' then
          raise;
        end if;
        return jsonb_build_object('success', false, 'code', 'LOAD_ALREADY_BILLED', 'message', 'Load '||v_load.load_number||' has already been billed for dispatch service.', 'load_id', v_load_id);
    end;

    insert into public.carrier_invoice_line_items
      (organization_id, invoice_id, line_type, source_load_id, description, quantity, unit_price)
    values
      (p_org, p_invoice_id, 'dispatch_service_fee', v_load_id,
       'Dispatch service fee -- Load '||v_load.load_number||
         case when v_version.fee_method = 'percentage_of_freight' then ' ('||v_version.percentage_rate||'% of '||v_freight_invoice_number||')' else ' (flat rate)' end,
       1, v_fee)
    returning id into v_li_id;

    v_line_no := v_line_no + 1;
    v_billing_lines := v_billing_lines || jsonb_build_object(
      'load_id', v_load_id, 'load_number', v_load.load_number,
      'fee_method', v_version.fee_method,
      'source_freight_invoice_id', v_freight_invoice_id, 'source_freight_invoice_number', v_freight_invoice_number,
      'authoritative_freight_amount', v_freight_amount, 'calculated_fee', v_fee
    );
    v_subtotal := v_subtotal + v_fee;
  end loop;

  -- Phase 3B.4.1, Section C: "revalidate immediately before snapshot
  -- construction" -- v_carrier has been locked FOR UPDATE since before
  -- this loop began, so nothing could actually have changed it since;
  -- this is a deliberate, defensive re-read of the row this transaction
  -- already holds (not a new lock, not a new resource), guarding against
  -- any future refactor that might reorder the carrier lock relative to
  -- this point without noticing the invariant it depends on.
  if not (select is_active from public.carriers where id = v_carrier.id) then
    return jsonb_build_object('success', false, 'code', 'CARRIER_INACTIVE', 'message', 'This carrier is inactive and cannot receive new dispatch-service invoices.');
  end if;

  v_total := v_subtotal + p_row.tax_amount + p_row.adjustments_amount;
  if v_total <= 0 then
    return jsonb_build_object('success', false, 'code', 'FEE_CALCULATION_INVALID', 'message', 'The invoice total must be greater than zero.');
  end if;

  v_payment_terms := coalesce(v_version.payment_terms_days, v_carrier.dispatch_service_terms_days, (select dispatch_service_terms_days from public.platform_settings limit 1));
  v_due_date := current_date + v_payment_terms;

  v_number := public._generate_carrier_invoice_number_internal('dispatch_service_invoice'::public.invoice_document_type, p_org,
    (select dispatch_invoice_prefix from public.platform_settings limit 1));

  ------------------------------------------------------------------
  -- Snapshot (Section J) -- dispatch organization identity/remittance,
  -- carrier recipient identity, agreement identity/terms, per-load
  -- billing detail. Never broker/customer, never any factoring
  -- identity/NOA/integration/secret_reference/carrier-factoring
  -- destination -- Section A/I's legal-separation requirement.
  ------------------------------------------------------------------
  v_snapshot_payload := jsonb_build_object(
    'schema_version', 1,
    'invoice_id', p_invoice_id,
    'invoice_document_type', 'dispatch_service_invoice',
    'invoice_number', v_number,
    'organization_id', p_org,
    'issued_at', now(),
    'issued_by', p_uid,
    'currency', v_version.currency,
    'payment_terms_days', v_payment_terms,
    'due_date', v_due_date,
    'subtotal_amount', v_subtotal,
    'tax_amount', p_row.tax_amount,
    'adjustments_amount', p_row.adjustments_amount,
    'total_amount', v_total,
    'issuer', jsonb_build_object(
      'organization_id', v_org_row.id, 'legal_name', v_org_row.name, 'dba_name', v_org_row.dba_name,
      'mc_number', v_org_row.mc_number, 'dot_number', v_org_row.dot_number,
      'address_line1', v_org_row.address_line1, 'address_line2', v_org_row.address_line2,
      'city', v_org_row.city, 'state', v_org_row.state, 'postal_code', v_org_row.postal_code, 'country', v_org_row.country,
      'phone', v_org_row.business_phone, 'email', v_org_row.business_email,
      'remittance_instructions', v_org_row.remittance_instructions
    ),
    'recipient', jsonb_build_object(
      'type', 'carrier', 'carrier_id', v_carrier.id, 'legal_name', v_carrier.legal_name, 'dba_name', v_carrier.dba_name,
      'mc_number', v_carrier.mc_number, 'dot_number', v_carrier.dot_number,
      'address_line1', v_carrier.address_line1, 'address_line2', v_carrier.address_line2,
      'city', v_carrier.city, 'state', v_carrier.state, 'postal_code', v_carrier.postal_code, 'country', v_carrier.country,
      'contact_name', v_carrier.contact_name, 'phone', v_carrier.phone, 'email', v_carrier.email,
      'remittance', case when v_remit.carrier_id is null then null else jsonb_build_object(
        'remittance_name', v_remit.remittance_name, 'remittance_email', v_remit.remittance_email,
        'remittance_instructions', v_remit.remittance_instructions
      ) end
    ),
    'agreement', jsonb_build_object(
      'agreement_id', v_version.agreement_id, 'version_id', v_version.id, 'version_number', v_version.version_number,
      'fee_method', v_version.fee_method, 'percentage_rate', v_version.percentage_rate, 'flat_fee_per_load', v_version.flat_fee_per_load,
      'minimum_fee', v_version.minimum_fee, 'maximum_fee', v_version.maximum_fee,
      'effective_from', v_version.effective_from, 'effective_to', v_version.effective_to,
      'approved_by', v_version.approved_by, 'approved_at', v_version.approved_at
    ),
    'billing_lines', v_billing_lines,
    'line_items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', li.id, 'description', li.description, 'quantity', li.quantity,
        'unit_price', li.unit_price, 'amount', li.line_total, 'source_load_id', li.source_load_id
      ) order by li.sort_order, li.created_at), '[]'::jsonb)
      from public.carrier_invoice_line_items li where li.invoice_id = p_invoice_id and li.line_type = 'dispatch_service_fee'
    ),
    'factoring', null,
    'issuing_user_id', p_uid
  );

  if public.jsonb_contains_forbidden_key(
    v_snapshot_payload,
    array['secret_reference', 'api_key', 'access_token', 'refresh_token', 'password', 'client_secret', 'credential', 'credentials', 'private_key']
  ) then
    raise exception 'issue_carrier_invoice (dispatch-service): internal invariant violated -- the constructed snapshot payload contains a forbidden credential-shaped key. Aborting.' using errcode = '55000';
  end if;

  begin
    if p_row.issuance_status = 'draft' then
      update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = p_invoice_id;
    end if;

    insert into public.carrier_invoice_issuance_snapshots
      (invoice_id, organization_id, invoice_document_type, issued_by, currency, invoice_number,
       payment_terms_days, due_date, subtotal_amount, tax_amount, adjustments_amount, total_amount,
       amount_due_at_issuance, carrier_id, recipient_broker_id, recipient_customer_id, snapshot_payload)
    values
      (p_invoice_id, p_org, 'dispatch_service_invoice', p_uid, v_version.currency, v_number,
       v_payment_terms, v_due_date, v_subtotal, p_row.tax_amount, p_row.adjustments_amount, v_total,
       v_total, p_row.carrier_id, null, null, v_snapshot_payload);

    update public.carrier_invoices
      set issuance_status = 'issued', invoice_number = v_number, issued_at = now(), issued_by = p_uid,
          subtotal_amount = v_subtotal, total_amount = v_total, due_date = v_due_date, payment_terms_days = v_payment_terms,
          currency = v_version.currency
      where id = p_invoice_id;

    perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'dispatch_service_invoice_issued',
      jsonb_build_object('invoice_number', v_number, 'total_amount', v_total, 'agreement_version_id', v_version.id, 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'ISSUED', 'invoice_id', p_invoice_id, 'invoice_number', v_number,
      'total_amount', v_total, 'issued_at', (select issued_at from public.carrier_invoices where id = p_invoice_id)
    );

    insert into public.carrier_invoice_lifecycle_idempotency
      (organization_id, idempotency_key, invoice_id, operation, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (p_org, p_idempotency_key, p_invoice_id, p_operation, p_fingerprint, p_schema_version, v_result, 'completed', p_uid);
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'civ_idempotency_unique' then
        raise;
      end if;
      select result into v_result from public.carrier_invoice_lifecycle_idempotency
      where organization_id = p_org and operation = p_operation and idempotency_key = p_idempotency_key;
      return v_result;
  end;

  return v_result;
end;
$fn$;

comment on function public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text) is
  'Phase 3B.4: internal-only (EXECUTE revoked from every role) -- the entire dispatch-service-specific issuance body, called exclusively from issue_carrier_invoice()''s own STEP 10 after that function''s fully-shared STEPS 1-9 have already run. Never includes broker/customer/factoring identity; never alters a carrier_freight_invoice; never posts a settlement deduction; never trusts a client-supplied fee -- every fee is computed here, from locked, server-read sources only.';

revoke all on function public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text) from public, anon, authenticated;

-- Redefine issue_carrier_invoice() itself: STEPS 1-9 UNCHANGED verbatim
-- from 0144 (re-typed here since CREATE OR REPLACE requires the whole
-- body); STEP 10 now dispatches to the function above instead of an
-- unconditional early return; the freight-invoice-specific STEPS 11
-- onward are otherwise BYTE-IDENTICAL to 0144's own body, with exactly
-- ONE substantive change: the loads_payload snapshot subquery's
-- 'agreed_freight_charge' now reads load_financials.rate (Section A's
-- critical finding), never loads.rate.
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
  -- STEP 1: authenticate + role.
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
  -- STEP 3: canonical SHA-256 fingerprint (0143 mechanism).
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
  -- STEP 6: revalidate organization / not-found.
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
  -- STEP 9: payment_status unpaid and amount_paid zero.
  ------------------------------------------------------------------
  if v_row.payment_status <> 'unpaid' or v_row.amount_paid <> 0 then
    return jsonb_build_object('success', false, 'code', 'PAYMENT_STATE_INVALID', 'message', 'This invoice has payment activity recorded and cannot be issued through this path.');
  end if;

  ------------------------------------------------------------------
  -- STEP 10 (Phase 3B.4 correction): dispatch_service_invoice now goes
  -- through the full atomic path (_issue_dispatch_service_invoice_
  -- internal) instead of an unconditional DISPATCH_SERVICE_AGREEMENT_
  -- REQUIRED early return -- structured AGREEMENT_REQUIRED/AGREEMENT_
  -- NOT_APPROVED/AGREEMENT_NOT_EFFECTIVE now distinguish exactly why, if
  -- issuance cannot proceed.
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'dispatch_service_invoice' then
    return public._issue_dispatch_service_invoice_internal(
      p_invoice_id, v_row, v_uid, v_org, p_reason, p_idempotency_key, v_operation, v_schema_version, v_fingerprint
    );
  end if;

  ------------------------------------------------------------------
  -- STEP 11 (global lock-order position 3): lock every source load,
  -- ascending id, BEFORE any carrier/factoring lock.
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
  -- that gap structurally: every load_stops INSERT must itself lock the
  -- SAME parent loads row this RPC already holds (step 11), so a
  -- concurrent insert attempt blocks here until this transaction
  -- commits or rolls back -- never observed mid-issuance, never
  -- silently racing the snapshot.
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
  -- STEP 12: provisional (unlocked) relationship discovery, THEN lock
  -- factoring_relationships (position 4) BEFORE carriers (position 5).
  ------------------------------------------------------------------
  if v_carrier.factoring_mode is null then
    select factoring_mode into v_carrier.factoring_mode from public.carriers where id = v_row.carrier_id;
  end if;

  select r.id into v_provisional_relationship_id
  from public.factoring_relationships r
  where r.carrier_id = v_row.carrier_id and r.is_default and r.is_active
  limit 1;

  if v_provisional_relationship_id is not null then
    select * into v_relationship from public.factoring_relationships where id = v_provisional_relationship_id for update;
  end if;

  select * into v_carrier from public.carriers where id = v_row.carrier_id for update;

  if v_carrier.factoring_mode = 'factored' then
    if v_provisional_relationship_id is null then
      if exists (select 1 from public.factoring_relationships where carrier_id = v_carrier.id and is_default and is_active) then
        return jsonb_build_object('success', false, 'code', 'STALE_CONFIGURATION', 'message', 'This carrier''s factoring configuration changed while this invoice was being issued. Reload and try again.');
      end if;
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier is factored but has no ready default factoring relationship.');
    end if;
    if v_relationship.carrier_id <> v_carrier.id or not v_relationship.is_default or not v_relationship.is_active then
      return jsonb_build_object('success', false, 'code', 'STALE_CONFIGURATION', 'message', 'This carrier''s factoring configuration changed while this invoice was being issued. Reload and try again.');
    end if;
  elsif v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', false, 'code', 'FACTORING_POLICY_UNCONFIGURED', 'message', 'This carrier has no factoring policy configured yet (direct or factored).');
  end if;

  v_classification := public.carrier_invoice_factoring_readiness_problem(p_invoice_id);
  if v_carrier.factoring_mode = 'factored' and v_classification is not null then
    return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s factoring configuration is not ready for issuance.', 'reason', v_classification);
  end if;

  if v_carrier.factoring_mode = 'factored' then
    select * into v_company from public.factoring_companies where id = v_relationship.factoring_company_id for share;
    if v_relationship.noa_document_id is not null then
      select * into v_doc from public.documents where id = v_relationship.noa_document_id for share;
    end if;
    if v_relationship.submission_method = 'api' then
      select * into v_integration from public.carrier_factoring_integrations
        where factoring_relationship_id = v_relationship.id and is_active
        for share;
    end if;
    v_factoring_payload := jsonb_build_object(
      'factoring_mode', 'factored',
      'factoring_company_legal_name', v_company.legal_name,
      'factoring_relationship_id', v_relationship.id,
      'noa_approved', v_relationship.noa_approved,
      'submission_method', v_relationship.submission_method,
      'submission_destination',
        case v_relationship.submission_method
          when 'secure_email' then v_relationship.submission_destination_email
          when 'api' then null
          else null
        end
    );
  else
    v_factoring_payload := jsonb_build_object('factoring_mode', v_carrier.factoring_mode);
  end if;

  ------------------------------------------------------------------
  -- STEP 13a: carrier remittance profile (position 9, FOR SHARE).
  ------------------------------------------------------------------
  select * into v_remit from public.carrier_remittance_profiles where carrier_id = v_carrier.id for share;

  ------------------------------------------------------------------
  -- STEP 14: recipient (position 10) -- broker or customer, then the
  -- carrier-party row, both FOR UPDATE.
  ------------------------------------------------------------------
  if v_row.recipient_type = 'broker' then
    select * into v_broker from public.brokers where id = v_row.recipient_broker_id for update;
    select status, billing_email, payment_terms_days into v_party_status, v_party_billing_email, v_party_payment_terms
      from public.carrier_brokers where carrier_id = v_carrier.id and broker_id = v_row.recipient_broker_id
      for update;
  else
    select * into v_customer from public.customers where id = v_row.recipient_customer_id for update;
    select status, billing_email, payment_terms_days into v_party_status, v_party_billing_email, v_party_payment_terms
      from public.carrier_customers where carrier_id = v_carrier.id and customer_id = v_row.recipient_customer_id
      for update;
  end if;

  v_problem := public.carrier_invoice_recipient_problem(p_invoice_id);
  if v_problem is not null then
    return jsonb_build_object('success', false, 'code', 'RECIPIENT_INELIGIBLE', 'message', 'The recipient is not eligible for this invoice.', 'reason', v_problem);
  end if;

  ------------------------------------------------------------------
  -- STEP 16 (global lock-order position 11): lock every line item row,
  -- ascending id, THEN recalculate totals from the now-locked set.
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
  -- private, per-(document_type,issuer,year) invoice number.
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'carrier_freight_invoice' then
    v_number := public._generate_carrier_invoice_number_internal('carrier_freight_invoice'::public.invoice_document_type, v_carrier.id, v_carrier.invoice_code);
  else
    -- Unreachable (STEP 10 already returned for dispatch_service_invoice).
    v_number := public._generate_carrier_invoice_number_internal(
      'dispatch_service_invoice'::public.invoice_document_type, v_org,
      (select dispatch_invoice_prefix from public.platform_settings limit 1));
  end if;

  ------------------------------------------------------------------
  -- Recipient identity + loads payloads, built from already-locked rows
  -- only. Phase 3B.4 correction: 'agreed_freight_charge' now reads
  -- load_financials.rate (the real, current post-0069 authoritative
  -- source), never loads.rate (dropped by 0069 in real production --
  -- Section A's critical finding).
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
      'load_id', l.id, 'load_number', l.load_number, 'agreed_freight_charge', lf.rate,
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
  from public.loads l
  left join public.load_financials lf on lf.load_id = l.id
  where l.id = any(v_load_ids);

  ------------------------------------------------------------------
  -- Build the complete server-generated immutable snapshot payload.
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
  -- Apply phase: insert exactly one snapshot; set invoice_number/
  -- issued_at/issued_by/issuance_status='issued'/totals/due_date; write
  -- exactly one audit event; store the idempotency result -- all in ONE
  -- savepoint-scoped block.
  ------------------------------------------------------------------
  begin
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
  'Phase 3B.4: STEPS 1-9 (auth/org/fingerprint/advisory-lock/invoice-lock/idempotency/status) are fully shared across both invoice_document_type values. carrier_freight_invoice issuance is unchanged in every respect except one correction: the loads-payload snapshot now reads agreed_freight_charge from load_financials.rate (the real, current post-0069 authoritative source) instead of the nonexistent-in-production loads.rate 0144 mistakenly read. dispatch_service_invoice issuance now dispatches to _issue_dispatch_service_invoice_internal() for its own full atomic lock order (loads -> agreement version -> carriers -> dispatch organization -> related freight invoice/snapshot where percentage-based -> billing ledger -> number -> snapshot+status+audit+idempotency) instead of an unconditional DISPATCH_SERVICE_AGREEMENT_REQUIRED early return. Never includes broker/customer or any carrier factoring identity in a dispatch-service snapshot; never alters a carrier_freight_invoice; never posts a settlement deduction; never trusts a client-supplied fee.';

-- ======================= drop 0146's own objects, in dependency order ======
drop function public.void_carrier_invoice_payment(uuid, timestamptz, text, text);
drop function public.record_carrier_invoice_payment(uuid, numeric, date, text, text, timestamptz, text, text);

-- Phase 3B.5.1: the centralized snapshot-integrity + external-reference
-- validators record_carrier_invoice_payment() called internally. No hard
-- catalog dependency exists (a plpgsql body is opaque text, not tracked in
-- pg_depend), but dropped here, after their only caller, for the same
-- dependency-safe ordering discipline as everything else in this script.
drop function public.carrier_invoice_payment_snapshot_problem(uuid);
drop function public._carrier_invoice_payment_external_reference_problem(text);

drop trigger a0146_guard_payment_currency on public.carrier_invoice_payments;
drop function public.guard_carrier_invoice_payment_currency();
drop trigger a0146_guard_payment_lifecycle on public.carrier_invoice_payments;
drop function public.guard_carrier_invoice_payment_lifecycle();

drop table public.carrier_invoice_payments;

drop function public._generate_carrier_invoice_payment_number_internal();
drop sequence public.carrier_invoice_payment_number_seq;

drop type public.carrier_invoice_payer_type;
drop type public.carrier_invoice_payment_method;
drop type public.carrier_invoice_payment_status;

-- carrier_invoices itself was never altered by 0146 (no new column, no
-- new constraint, no new trigger on that table) -- nothing to revert on
-- it. carrier_invoice_lifecycle_idempotency (0142/0143) was reused, not
-- extended -- any rows this migration's own RPCs wrote to it (operation
-- in ('record_carrier_invoice_payment','void_carrier_invoice_payment'))
-- are already guaranteed absent by the payment-count refusal check above
-- (no payment could exist without a corresponding idempotency row, and
-- vice versa is not required -- but for exact-boundary cleanliness,
-- delete any orphaned idempotency rows for these two operations, which
-- can only exist if a payment attempt FAILED after inserting its
-- idempotency row but that never happens in this design -- inserted
-- together, same transaction, same savepoint-scoped block. Still,
-- explicit and harmless).
delete from public.carrier_invoice_lifecycle_idempotency
where operation in ('record_carrier_invoice_payment', 'void_carrier_invoice_payment');

-- ======================= POSTCONDITIONS =====================================
do $rb$
begin
  if to_regclass('public.carrier_invoice_payments') is not null then
    raise exception 'ROLLBACK_0146 postcondition: carrier_invoice_payments still exists.';
  end if;
  if to_regprocedure('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)') is not null then
    raise exception 'ROLLBACK_0146 postcondition: record_carrier_invoice_payment(...) still exists.';
  end if;
  if to_regprocedure('public.void_carrier_invoice_payment(uuid,timestamptz,text,text)') is not null then
    raise exception 'ROLLBACK_0146 postcondition: void_carrier_invoice_payment(...) still exists.';
  end if;
  if to_regtype('public.carrier_invoice_payment_status') is not null then
    raise exception 'ROLLBACK_0146 postcondition: carrier_invoice_payment_status still exists.';
  end if;
  if to_regtype('public.carrier_invoice_payment_method') is not null then
    raise exception 'ROLLBACK_0146 postcondition: carrier_invoice_payment_method still exists.';
  end if;
  if to_regtype('public.carrier_invoice_payer_type') is not null then
    raise exception 'ROLLBACK_0146 postcondition: carrier_invoice_payer_type still exists.';
  end if;
  if exists (select 1 from pg_class where relkind = 'S' and relname = 'carrier_invoice_payment_number_seq') then
    raise exception 'ROLLBACK_0146 postcondition: carrier_invoice_payment_number_seq still exists.';
  end if;
  if to_regprocedure('public._generate_carrier_invoice_payment_number_internal()') is not null then
    raise exception 'ROLLBACK_0146 postcondition: _generate_carrier_invoice_payment_number_internal() still exists.';
  end if;
  if to_regprocedure('public.carrier_invoice_payment_snapshot_problem(uuid)') is not null then
    raise exception 'ROLLBACK_0146 postcondition: carrier_invoice_payment_snapshot_problem(uuid) still exists.';
  end if;
  if to_regprocedure('public._carrier_invoice_payment_external_reference_problem(text)') is not null then
    raise exception 'ROLLBACK_0146 postcondition: _carrier_invoice_payment_external_reference_problem(text) still exists.';
  end if;
  if exists (
    select 1 from public.carrier_invoice_lifecycle_idempotency
    where operation in ('record_carrier_invoice_payment', 'void_carrier_invoice_payment')
  ) then
    raise exception 'ROLLBACK_0146 postcondition: orphaned payment-operation idempotency rows remain.';
  end if;

  -- Phase 3B.5.2, Section J: the restored issuance functions must exactly
  -- match 0145's own original schema_version=1 shape -- never a stray
  -- schema_version=2 build, never a partial/mixed restoration.
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''schema_version'', 1%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''schema_version'', 2%'
  then
    raise exception 'ROLLBACK_0146 postcondition: issue_carrier_invoice was not restored to the exact 0145 schema_version=1 shape.';
  end if;
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%''schema_version'', 1%'
     or (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) ilike '%''schema_version'', 2%'
  then
    raise exception 'ROLLBACK_0146 postcondition: _issue_dispatch_service_invoice_internal was not restored to the exact 0145 schema_version=1 shape.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''factoring_mode''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''factoring_relationship_id''%'
  then
    raise exception 'ROLLBACK_0146 postcondition: issue_carrier_invoice does not carry 0145''s own original factoring key names -- restoration is not exact.';
  end if;
  if has_function_privilege('authenticated', 'public.issue_carrier_invoice(uuid,timestamptz,text,text)', 'EXECUTE') is not true then
    raise exception 'ROLLBACK_0146 postcondition: authenticated lost EXECUTE on issue_carrier_invoice.';
  end if;
  if has_function_privilege('authenticated', 'public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)', 'EXECUTE')
  then
    raise exception 'ROLLBACK_0146 postcondition: _issue_dispatch_service_invoice_internal is no longer internal-only.';
  end if;

  raise notice 'ROLLBACK_0146 complete: exact 0145 boundary restored -- issue_carrier_invoice()/_issue_dispatch_service_invoice_internal() restored to their exact original schema_version=1 bodies (Phase 3B.5.2''s compatibility correction fully undone); carrier_invoice_payments and its guard triggers/RPCs/enums/sequence/internal generator/version-aware validator/external-reference validator dropped; the payment/version-validation-operation idempotency rows, if any, removed from the reused carrier_invoice_lifecycle_idempotency table. carrier_invoices, carrier_invoice_issuance_snapshots, and every other 0001-0145 object left untouched.';
end
$rb$;

commit;
