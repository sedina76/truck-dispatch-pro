-- =============================================================================
-- 0073_factoring_invoice_submission_rpc.sql
-- Phase 2H.4: the sole atomic entry point for "submit this invoice to a
-- factor" -- resolves + validates the relationship/company, snapshots
-- commercial terms, creates the factored_invoices row already in
-- 'submitted' status, and writes its corresponding factoring_events row,
-- all in one transaction. PROPOSED ONLY -- NOT APPLIED.
--
-- Entirely new function -- submit_invoice_to_factor() has never existed
-- in any prior migration (confirmed via repo-wide grep), so there is no
-- prior signature to audit against and no 42P13 return-type-change risk
-- (the 0068 precedent this project is careful never to repeat). No
-- existing function's signature is altered by this migration.
--
-- Scope discipline (Phase 2H.4 boundary): this migration does nothing
-- about approval, rejection, funding, reserve release, recourse,
-- chargeback, or reconciliation -- it only ever inserts a factored_invoices
-- row already in 'submitted' state and its matching 'submitted'
-- factoring_events row. Every other status/event in 0071's model is
-- untouched and unreachable from this function.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- INSERT-DIRECTLY-AS-SUBMITTED, not draft-then-update (spec section 2):
-- guard_factored_invoice_status_transition() (0071) is a `before update of
-- status` trigger -- it does not fire on INSERT at all, so there is no
-- INSERT-time requirement that a new row start at 'draft'. This phase's
-- UI has no "save a draft factoring request" concept; the row's real
-- first observable state IS 'submitted', matching the moment the user
-- clicks Submit. Inserting directly avoids an extra write, avoids ever
-- creating a transient 'draft' row nothing would clean up, and does not
-- bypass the transition trigger -- there is simply no transition to guard
-- against on a fresh row's first INSERT.
--
-- ELIGIBILITY (spec section 3, resolved against the actual invoice
-- lifecycle -- see the Phase 2H.4 pre-implementation audit for the full
-- classification):
--   HARD GATE -- invoice.status in ('sent', 'viewed') AND amount_paid = 0.
--     'draft' is excluded (never issued to the customer -- and issuing is
--     itself gated by check_invoice_ready_to_send()'s verified-POD
--     requirement, 0023, reused here for free rather than re-implemented:
--     any invoice that ever reached 'sent' already passed that gate).
--     'void'/'disputed' are excluded outright. 'paid' is excluded (nothing
--     to sell). 'partially_paid' is ALSO excluded -- deliberately: 0071
--     defines invoice_face_value as one plain snapshot number with no
--     documented relationship to invoices.balance_due for a
--     partially-paid invoice, and inventing that formula (face value vs.
--     remaining balance once the customer has already paid the org
--     directly) is exactly the kind of financial-formula invention spec
--     section 6 says to stop and flag rather than guess. Narrowing
--     eligibility to invoices with zero payments applied removes the
--     ambiguity entirely (face_value = total_amount = balance_due
--     unambiguously whenever amount_paid = 0) instead of inventing an
--     answer. Documented in the Phase 2H.4 report as the resolution.
--   INFORMATIONAL, not re-checked here -- POD/BOL/rate-confirmation
--     readiness: already enforced once, irreversibly, by
--     check_invoice_ready_to_send() at the moment the invoice first
--     became 'sent'. Re-deriving billing readiness here would be a
--     second interpretation of the same concept spec section 3
--     explicitly prohibits duplicating; the invoice's OWN status is the
--     single source of truth reused instead.
--   NOT REPRESENTED -- invoices has no currency column (single implicit
--     currency for the whole app); no factor-specific per-invoice
--     eligibility field exists anywhere in 0071.
--   HARD GATE -- no existing non-terminal-for-resubmission factored_invoices
--     row (status not in ('rejected','cancelled') -- the EXACT predicate
--     of factored_invoices_one_active_per_invoice, 0071/Phase 2H.2, not a
--     re-guess of it. Note this is deliberately NOT the same set as the
--     transition graph's terminal states (rejected/cancelled/closed/
--     chargeback all have no outgoing transitions) -- 'closed' and
--     'chargeback' still occupy the slot and block resubmission, exactly
--     as 0071 was reviewed and fixed to do in Phase 2H.2.
--   HARD GATE -- selected relationship: same organization, is_active,
--     effective_from <= current_date <= effective_to (or open-ended).
--   HARD GATE -- selected relationship's factoring_company: is_active.
-- ---------------------------------------------------------------------------
create or replace function public.submit_invoice_to_factor(
  p_invoice_id uuid,
  p_relationship_id uuid
)
returns table (factored_invoice_id uuid, status public.factored_invoice_status)
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_invoice record;
  v_relationship record;
  v_company_active boolean;
  v_existing_active uuid;
  v_face_value numeric(10, 2);
  v_advance_amount numeric(10, 2);
  v_fee_amount numeric(10, 2);
  v_reserve_amount numeric(10, 2);
  v_other_fees numeric(10, 2);
  v_funding_amount numeric(10, 2);
  v_new_id uuid;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to submit invoices for factoring.';
  end if;

  -- Lock the invoice row FIRST (spec section 7 step 4) -- every concurrent
  -- submission attempt for this exact invoice serializes on this one
  -- lock, so the duplicate check below is race-free rather than a bare
  -- pre-insert SELECT (spec section 9). Locking a DIFFERENT invoice never
  -- contends with this at all.
  select id, organization_id, status, total_amount, amount_paid
    into v_invoice
  from public.invoices
  where id = p_invoice_id
  for update;

  if v_invoice.id is null or v_invoice.organization_id <> v_org_id then
    raise exception 'Invoice not found.';
  end if;

  if v_invoice.status not in ('sent', 'viewed') or v_invoice.amount_paid <> 0 then
    raise exception 'This invoice is not eligible for factoring.';
  end if;

  -- Duplicate/non-terminal check -- see header comment for why this is
  -- the exact factored_invoices_one_active_per_invoice predicate, and why
  -- it's race-free here specifically because the invoice row lock above
  -- is already held.
  select id into v_existing_active
  from public.factored_invoices
  where invoice_id = p_invoice_id and status not in ('rejected', 'cancelled')
  limit 1;
  if v_existing_active is not null then
    raise exception 'This invoice has already been submitted to a factor.';
  end if;

  -- Lock + validate the relationship (spec section 4: re-validated inside
  -- the transaction, never trusted from the UI alone).
  select id, organization_id, factoring_company_id, is_active,
         default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage,
         fee_timing, other_fee_default, effective_from, effective_to
    into v_relationship
  from public.factoring_relationships
  where id = p_relationship_id
  for update;

  if v_relationship.id is null or v_relationship.organization_id <> v_org_id then
    raise exception 'This factoring relationship is not available.';
  end if;
  if not v_relationship.is_active then
    raise exception 'The selected factoring relationship is inactive.';
  end if;
  if v_relationship.effective_from > current_date or (v_relationship.effective_to is not null and v_relationship.effective_to < current_date) then
    raise exception 'The selected factoring relationship is not currently effective.';
  end if;

  select is_active into v_company_active
  from public.factoring_companies
  where id = v_relationship.factoring_company_id;
  if not coalesce(v_company_active, false) then
    raise exception 'The selected factoring company is inactive.';
  end if;

  -- Amounts (spec section 6) -- NUMERIC arithmetic throughout, rounded to
  -- factored_invoices' own numeric(10,2) scale, never JS floating point.
  -- invoice_face_value = invoices.total_amount, unambiguous because
  -- amount_paid = 0 was just confirmed above (see header comment).
  -- advance/fee/reserve amounts are each independently
  -- percentage-of-face-value -- 0071 stores the three relationship
  -- percentages as independent columns with no summing constraint (Phase
  -- 2H.2 review confirmed no advance+reserve=100 formula exists), so
  -- there is no other relationship between them to reproduce.
  -- expected_funding_amount = advance - other_fees - (the factoring fee,
  -- ONLY when fee_timing says it's deducted at funding rather than later
  -- from the reserve) -- the direct, documented meaning of fee_timing
  -- itself (Phase 2H.2/2H.3 UI copy: "Deduct fee at funding" vs "Deduct
  -- fee from reserve"), not an invented formula. wire_fee/ach_fee/
  -- minimum_fee on the relationship have no corresponding column on
  -- factored_invoices at all and are deliberately NOT itemized into this
  -- calculation -- only other_fee_default has a direct destination
  -- (factored_invoices.other_fees).
  v_face_value := v_invoice.total_amount;
  v_advance_amount := round(v_face_value * v_relationship.default_advance_percentage / 100, 2);
  v_fee_amount := round(v_face_value * v_relationship.default_factoring_fee_percentage / 100, 2);
  v_reserve_amount := round(v_face_value * v_relationship.default_reserve_percentage / 100, 2);
  v_other_fees := coalesce(v_relationship.other_fee_default, 0);
  v_funding_amount := v_advance_amount - v_other_fees - (case when v_relationship.fee_timing = 'deducted_at_funding' then v_fee_amount else 0 end);

  if v_funding_amount < 0 then
    raise exception 'Estimated funding amount for this invoice would be negative under the selected relationship''s terms.';
  end if;

  -- recourse_type/relationship_name are NOT part of 0071's snapshot
  -- columns (factored_invoices has no such columns at all -- confirmed
  -- live) -- they remain live-joined display values via
  -- factoring_relationship_id, same as the Phase 2H.2 review already
  -- established for every OTHER non-snapshotted relationship field. Not
  -- invented here.
  insert into public.factored_invoices (
    organization_id, invoice_id, factoring_company_id, factoring_relationship_id,
    status, submitted_at, submitted_by,
    invoice_face_value, advance_percentage, expected_advance_amount,
    factoring_fee_percentage, factoring_fee_amount,
    reserve_percentage, reserve_amount,
    other_fees, fee_timing, expected_funding_amount
  ) values (
    v_org_id, p_invoice_id, v_relationship.factoring_company_id, p_relationship_id,
    'submitted', now(), auth.uid(),
    v_face_value, v_relationship.default_advance_percentage, v_advance_amount,
    v_relationship.default_factoring_fee_percentage, v_fee_amount,
    v_relationship.default_reserve_percentage, v_reserve_amount,
    v_other_fees, v_relationship.fee_timing, v_funding_amount
  )
  returning id into v_new_id;

  -- factoring_events is append-only, authoritative factoring lifecycle
  -- history (spec section 11) -- never replaced by log_activity, which
  -- the application layer may additionally write to for the general
  -- organization activity stream (same "both, for different audiences"
  -- pattern already established in Phase 2H.3's settings actions).
  -- from_status is null: this factored_invoices row did not exist a
  -- moment ago, so there is no prior status to record, only the new one.
  insert into public.factoring_events (
    organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by
  ) values (
    v_org_id, v_new_id, 'submitted', null, 'submitted', auth.uid()
  );

  return query select v_new_id, 'submitted'::public.factored_invoice_status;
end;
$$;

grant execute on function public.submit_invoice_to_factor(uuid, uuid) to authenticated;
