-- ============================================================================
-- 0160_factoring_fee_from_reserve_reconciliation_fix.sql
--
-- Found by the factoring lifecycle autopilot (supabase/TEST_FACTORING_
-- LIFECYCLE_E2E.sql). Two defects in the legacy invoice factoring lifecycle
-- (0076/0077):
--
-- 1. "Deduct fee from reserve" relationships could NEVER close.
--    factored_invoice_reconciliation_status() (0077) required BOTH
--      (a) outstanding_reserve = 0           -- the whole reserve released
--      (b) face - fee - other = funded + released   -- the money balances
--    With the fee taken from the reserve the factor releases
--    (reserve - fee), so after a correct, complete settlement (a) is false
--    by exactly the fee; and if the full reserve is released instead, (b) is
--    false by the fee. Example ($1,000 invoice, 90/3/10): funded 900,
--    released 70 -> balanced, but outstanding 30 -> 'partially_reconciled'
--    forever, so close_factored_invoice() refuses and the app never shows
--    "Close Factoring Transaction".
--    Fix: reconciled = customer paid the factor AND the money balances (b).
--    (a) added nothing for "deducted at funding" (where a balanced
--    settlement already releases the full reserve) and was wrong for
--    "deducted from reserve".
--
-- 2. fund_factored_invoice() (0076) accepted any positive amount, e.g.
--    $5,000 on a $1,000 invoice (a typo). A trigger now refuses an actual
--    funded amount greater than the invoice face value. 0076's function is
--    left untouched; existing rows are never re-validated (only a CHANGE of
--    actual_funded_amount is checked).
--
-- Also recomputes the stored reconciliation_status of every open
-- (funded / partially_settled) factored invoice whose customer payment was
-- already reported, so invoices stuck by (1) become closable immediately.
-- Nothing else on those rows changes: no status, amount, or event is
-- written, and no invoice is closed automatically.
--
-- Safe to re-run. Rollback: re-apply 0077's function body and
-- `drop trigger factored_invoices_guard_funded_amount ...` (see bottom).
-- ============================================================================

begin;

-- 1 -------------------------------------------------------------------------
-- Same signature, volatility and grants as 0077 -- every caller
-- (report_customer_payment_to_factor, release_factoring_reserve,
-- resolve_factoring_dispute) picks the fix up without being redefined.
-- p_outstanding_reserve is kept (unused) so the signature is unchanged.
create or replace function public.factored_invoice_reconciliation_status(
  p_customer_paid_factor_at timestamptz,
  p_outstanding_reserve numeric,
  p_invoice_face_value numeric,
  p_factoring_fee_amount numeric,
  p_other_fees numeric,
  p_actual_funded_amount numeric,
  p_reserve_released_amount numeric
)
returns text
language sql
stable
as $$
  select case
    when p_customer_paid_factor_at is null then 'unreconciled'
    when (p_invoice_face_value - p_factoring_fee_amount - coalesce(p_other_fees, 0))
         - (coalesce(p_actual_funded_amount, 0) + coalesce(p_reserve_released_amount, 0)) <> 0 then 'partially_reconciled'
    else 'reconciled'
  end;
$$;

comment on function public.factored_invoice_reconciliation_status(timestamptz, numeric, numeric, numeric, numeric, numeric, numeric) is
  '0160: reconciled = customer paid the factor AND funded + reserve released = face - fee - other fees. No longer also requires the full reserve to be released (that made "deduct fee from reserve" relationships impossible to close). p_outstanding_reserve is retained only for signature compatibility.';

grant execute on function public.factored_invoice_reconciliation_status(timestamptz, numeric, numeric, numeric, numeric, numeric, numeric) to authenticated;

-- 2 -------------------------------------------------------------------------
create or replace function public.guard_factored_invoice_funded_amount()
returns trigger
language plpgsql
as $$
begin
  if new.actual_funded_amount is not null
     and new.actual_funded_amount is distinct from old.actual_funded_amount
     and new.actual_funded_amount > new.invoice_face_value then
    raise exception 'Funded amount (%) cannot be more than the invoice amount (%).', new.actual_funded_amount, new.invoice_face_value;
  end if;
  return new;
end;
$$;

drop trigger if exists factored_invoices_guard_funded_amount on public.factored_invoices;
create trigger factored_invoices_guard_funded_amount
  before update of actual_funded_amount on public.factored_invoices
  for each row execute function public.guard_factored_invoice_funded_amount();

-- 3 -------------------------------------------------------------------------
-- Recompute stored reconciliation for open, customer-paid factored invoices.
do $$
declare v_changed int;
begin
  with recomputed as (
    select fi.id,
           public.factored_invoice_reconciliation_status(
             fi.customer_paid_factor_at, fi.outstanding_reserve, fi.invoice_face_value, fi.factoring_fee_amount,
             fi.other_fees, fi.actual_funded_amount, fi.reserve_released_amount) as new_status
    from public.factored_invoices fi
    where fi.status in ('funded', 'partially_settled')
      and fi.customer_paid_factor_at is not null
  )
  update public.factored_invoices fi
     set reconciliation_status = r.new_status
    from recomputed r
   where fi.id = r.id
     and fi.reconciliation_status is distinct from r.new_status;
  get diagnostics v_changed = row_count;
  raise notice '0160: reconciliation_status recomputed for % open factored invoice(s).', v_changed;
end $$;

commit;

-- Rollback (only if ever needed):
--   1. re-run the factored_invoice_reconciliation_status definition from
--      0077_factoring_settlement_reconciliation_rpc.sql
--   2. drop trigger if exists factored_invoices_guard_funded_amount on public.factored_invoices;
--      drop function if exists public.guard_factored_invoice_funded_amount();
