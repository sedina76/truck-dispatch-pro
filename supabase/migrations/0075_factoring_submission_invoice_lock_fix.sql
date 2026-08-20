-- =============================================================================
-- 0075_factoring_submission_invoice_lock_fix.sql
-- Phase 2H.4 POST-0073/0074 LIVE VERIFICATION: repairs a second real,
-- live-confirmed defect in submit_invoice_to_factor() -- found during
-- Test 10 (role matrix) of the live matrix: a dispatcher, who unarguably
-- belongs to FINANCIAL_ROLES and must be able to submit invoices for
-- factoring (spec section 8, repeated throughout every Phase 2H.4
-- instruction), received "Invoice not found." on every attempt, even
-- though a PLAIN `select` of the exact same invoice row, as the exact
-- same dispatcher session, succeeded and returned the row correctly.
-- Confirmed live, isolated down to the single line responsible, before
-- writing this fix -- not inferred from reading the code alone.
--
-- ROOT CAUSE: `select ... from public.invoices inv where inv.id =
-- p_invoice_id for update;` -- PostgreSQL's row security documentation is
-- explicit that `SELECT ... FOR UPDATE` (and FOR SHARE) additionally
-- requires the row to satisfy the table's UPDATE-applicable policy USING
-- expression, not merely its SELECT policy, because acquiring the lock
-- implies a potential subsequent update. invoices' own UPDATE policy
-- (invoices_update, 0010_rls_policies.sql -- entirely unrelated to
-- factoring, unchanged since this app's very first migration) is
-- `has_role(['owner','admin','accountant'])` -- dispatcher is
-- deliberately excluded from ever editing an invoice's fields, which is
-- correct and untouched here. But this function never actually issues an
-- UPDATE to invoices at all (invoice accounting state is explicitly never
-- touched by factoring submission, spec section 2's own hard requirement)
-- -- the `for update` clause was only ever meant to serialize concurrent
-- submission attempts for the same invoice, not to claim write intent
-- that was never real.
--
-- FIX: replace the row-level `for update` lock on invoices with a
-- session-scoped advisory lock keyed on the invoice id
-- (pg_advisory_xact_lock), exactly the same mechanism already
-- established for exactly this class of problem in
-- 0072_factoring_default_relationship_rpc.sql. An advisory lock is not
-- gated by ANY table's RLS policy -- it provides the identical
-- serialization guarantee (every concurrent submission attempt for the
-- SAME invoice id blocks on the same lock key until the first commits or
-- rolls back) without requiring the caller to satisfy a write-policy for
-- a write this function never performs. The relationship's own
-- `select ... for update` is UNCHANGED and correct as-is:
-- factoring_relationships_update (0071) already grants UPDATE to all
-- four FINANCIAL_ROLES (owner/admin/dispatcher/accountant), so it never
-- exhibited this problem -- confirmed by inspection, not assumed.
--
-- Signature is completely unchanged -- body-only fix, plain
-- `create or replace function`, no DROP/CASCADE, no 42P13 risk.
-- =============================================================================

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

  -- Serializes every concurrent submission attempt for this exact invoice
  -- (see header comment for why this replaced a `for update` row lock).
  -- pg_advisory_xact_lock auto-releases on commit or rollback, same as
  -- every other advisory lock in this app (0072).
  perform pg_advisory_xact_lock(hashtext('factoring_submission:' || p_invoice_id::text));

  select inv.id, inv.organization_id, inv.status, inv.total_amount, inv.amount_paid
    into v_invoice
  from public.invoices inv
  where inv.id = p_invoice_id;

  if v_invoice.id is null or v_invoice.organization_id <> v_org_id then
    raise exception 'Invoice not found.';
  end if;

  if v_invoice.status not in ('sent', 'viewed') or v_invoice.amount_paid <> 0 then
    raise exception 'This invoice is not eligible for factoring.';
  end if;

  -- Duplicate/non-terminal check -- race-free because the advisory lock
  -- above is already held for this exact invoice id.
  select fi.id into v_existing_active
  from public.factored_invoices fi
  where fi.invoice_id = p_invoice_id and fi.status not in ('rejected', 'cancelled')
  limit 1;
  if v_existing_active is not null then
    raise exception 'This invoice has already been submitted to a factor.';
  end if;

  -- Lock + validate the relationship -- unchanged from 0074.
  -- factoring_relationships_update (0071) grants UPDATE to all four
  -- FINANCIAL_ROLES, so `for update` here never excludes dispatcher.
  select rel.id, rel.organization_id, rel.factoring_company_id, rel.is_active,
         rel.default_advance_percentage, rel.default_factoring_fee_percentage, rel.default_reserve_percentage,
         rel.fee_timing, rel.other_fee_default, rel.effective_from, rel.effective_to
    into v_relationship
  from public.factoring_relationships rel
  where rel.id = p_relationship_id
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

  select comp.is_active into v_company_active
  from public.factoring_companies comp
  where comp.id = v_relationship.factoring_company_id;
  if not coalesce(v_company_active, false) then
    raise exception 'The selected factoring company is inactive.';
  end if;

  v_face_value := v_invoice.total_amount;
  v_advance_amount := round(v_face_value * v_relationship.default_advance_percentage / 100, 2);
  v_fee_amount := round(v_face_value * v_relationship.default_factoring_fee_percentage / 100, 2);
  v_reserve_amount := round(v_face_value * v_relationship.default_reserve_percentage / 100, 2);
  v_other_fees := coalesce(v_relationship.other_fee_default, 0);
  v_funding_amount := v_advance_amount - v_other_fees - (case when v_relationship.fee_timing = 'deducted_at_funding' then v_fee_amount else 0 end);

  if v_funding_amount < 0 then
    raise exception 'Estimated funding amount for this invoice would be negative under the selected relationship''s terms.';
  end if;

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

  insert into public.factoring_events (
    organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by
  ) values (
    v_org_id, v_new_id, 'submitted', null, 'submitted', auth.uid()
  );

  return query select v_new_id, 'submitted'::public.factored_invoice_status;
end;
$$;

grant execute on function public.submit_invoice_to_factor(uuid, uuid) to authenticated;
