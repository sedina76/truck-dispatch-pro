-- =============================================================================
-- 0074_factoring_submission_rpc_ambiguity_fix.sql
-- Phase 2H.4 POST-0073 LIVE VERIFICATION: repairs a real, live-confirmed
-- defect in submit_invoice_to_factor() (0073) found during test 1 of the
-- live matrix -- calling it raised, from the database itself:
--
--   code: 42702
--   message: column reference "status" is ambiguous
--   details: It could refer to either a PL/pgSQL variable or a table column.
--
-- ROOT CAUSE: `returns table (factored_invoice_id uuid, status public.
-- factored_invoice_status)` makes Postgres implicitly declare `status` as
-- a PL/pgSQL variable in scope for the ENTIRE function body (the standard,
-- well-known behavior of OUT/RETURNS TABLE parameters) -- so every
-- UNQUALIFIED `status` column reference inside a query in the function
-- body became ambiguous the moment that OUT parameter was named `status`.
-- Two call sites hit this: the invoices SELECT (line ~113 of 0073) and the
-- factored_invoices duplicate-check WHERE clause (line ~133 of 0073).
-- Confirmed live via a real RPC call through an authenticated session
-- before writing this fix -- not inferred from reading the code alone.
--
-- FIX: table-alias every column reference in every query inside the
-- function body (`inv.status`, `fi.status`, etc.) so no bare column name
-- can ever again collide with a RETURNS TABLE/OUT parameter, current or
-- future. This is a body-only change -- the function's SIGNATURE (name,
-- argument names/types, RETURNS TABLE shape) is completely unchanged, so
-- this is a plain, safe `create or replace function`, not a DROP/CASCADE
-- -- no 42P13 return-type-change risk (the 0068 precedent this project
-- stays careful never to repeat). Every business rule, check, message,
-- and calculation is reproduced verbatim from 0073; only column
-- references gained table qualifiers.
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

  -- Lock the invoice row FIRST -- see 0073's header comment for the full
  -- concurrency reasoning, unchanged here. `inv.status` (table-aliased,
  -- the actual fix) rather than the bare `status` that collided with the
  -- `status` OUT parameter above.
  select inv.id, inv.organization_id, inv.status, inv.total_amount, inv.amount_paid
    into v_invoice
  from public.invoices inv
  where inv.id = p_invoice_id
  for update;

  if v_invoice.id is null or v_invoice.organization_id <> v_org_id then
    raise exception 'Invoice not found.';
  end if;

  if v_invoice.status not in ('sent', 'viewed') or v_invoice.amount_paid <> 0 then
    raise exception 'This invoice is not eligible for factoring.';
  end if;

  -- Duplicate/non-terminal check -- `fi.status` (table-aliased, the
  -- second and last ambiguous call site) rather than the bare `status`
  -- that also collided with the OUT parameter.
  select fi.id into v_existing_active
  from public.factored_invoices fi
  where fi.invoice_id = p_invoice_id and fi.status not in ('rejected', 'cancelled')
  limit 1;
  if v_existing_active is not null then
    raise exception 'This invoice has already been submitted to a factor.';
  end if;

  -- Lock + validate the relationship. No bare `status` reference here in
  -- either 0073 or this fix -- factoring_relationships has no status
  -- column -- but every reference is aliased anyway for consistency and
  -- to make this function immune to the same class of bug if a column
  -- were ever added later.
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

  -- Amounts -- unchanged from 0073, no ambiguity here (these are PL/pgSQL
  -- variable assignments and record-field accesses, not raw queries).
  v_face_value := v_invoice.total_amount;
  v_advance_amount := round(v_face_value * v_relationship.default_advance_percentage / 100, 2);
  v_fee_amount := round(v_face_value * v_relationship.default_factoring_fee_percentage / 100, 2);
  v_reserve_amount := round(v_face_value * v_relationship.default_reserve_percentage / 100, 2);
  v_other_fees := coalesce(v_relationship.other_fee_default, 0);
  v_funding_amount := v_advance_amount - v_other_fees - (case when v_relationship.fee_timing = 'deducted_at_funding' then v_fee_amount else 0 end);

  if v_funding_amount < 0 then
    raise exception 'Estimated funding amount for this invoice would be negative under the selected relationship''s terms.';
  end if;

  -- INSERT column lists are never subject to this ambiguity (they always
  -- resolve to the target table's own columns, not PL/pgSQL variables) --
  -- unchanged from 0073.
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
