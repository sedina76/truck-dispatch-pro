-- Run BEFORE applying 0113_invoice_collectible_status_guard.sql.
--
-- Uses disposable TEST-CPG-* invoice/payment fixtures, scoped under
-- whichever real organization happens to be first in your database (read
-- read-only, never assumed) -- everything this file creates is discarded
-- by the unconditional ROLLBACK at the very end. Nothing here persists,
-- and no real invoice/payment/organization row is ever modified.
--
-- Purpose: confirm the CURRENT (pre-0113) gap actually exists, rather
-- than assuming it from reading the code -- draft/disputed invoices are
-- expected to currently ACCEPT a payment (the bug this migration fixes).
-- Each test is wrapped in its own SAVEPOINT (via a nested
-- begin/exception) so one test's expected failure doesn't abort the
-- others.

begin;

do $$
declare
  v_org_id uuid;
  v_inv_draft uuid;
  v_inv_disputed uuid;
  v_inv_sent uuid;
  v_inv_viewed uuid;
  v_inv_partial uuid;
  v_inv_paid uuid;
  v_inv_void uuid;
  v_inv_zero_balance uuid;
  v_payment_id uuid;
begin
  select id into v_org_id from public.organizations limit 1;
  if v_org_id is null then
    raise exception 'No organization exists to scope disposable test fixtures under -- cannot run this verification.';
  end if;

  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values
    (v_org_id, 'TEST-CPG-DRAFT', 'draft', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30)
  returning id into v_inv_draft;

  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-DISPUTED', 'disputed', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30)
  returning id into v_inv_disputed;

  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-SENT', 'sent', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30)
  returning id into v_inv_sent;

  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-VIEWED', 'viewed', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30)
  returning id into v_inv_viewed;

  -- Partially paid requires amount_paid strictly between 0 and total (the
  -- invoice's own guard_invoice_status() enforces this even on this
  -- direct insert, since it fires on distinct-from-old status -- OLD is
  -- null on insert, so new.status IS distinct, and the check applies).
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, amount_paid, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-PARTIAL', 'partially_paid', 'TEST-COLLECTIBLE-GUARD', 500.00, 200.00, current_date, current_date + 30)
  returning id into v_inv_partial;

  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, amount_paid, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-PAID', 'paid', 'TEST-COLLECTIBLE-GUARD', 500.00, 500.00, current_date, current_date + 30)
  returning id into v_inv_paid;

  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-VOID', 'void', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30)
  returning id into v_inv_void;

  -- A collectible status with a zero balance -- an edge case a full total
  -- of 0 produces without ever touching amount_paid.
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-ZEROBAL', 'sent', 'TEST-COLLECTIBLE-GUARD', 0.00, current_date, current_date + 30)
  returning id into v_inv_zero_balance;

  -- Each test below: attempt a payment insert, report the outcome, and
  -- roll back to a savepoint regardless (implicit, via the nested
  -- begin/exception) so a later test is never affected by an earlier
  -- one's success or expected failure.

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_draft, 100.00, 'ach', now());
    raise notice 'PREFLIGHT (draft): payment INSERT SUCCEEDED -- confirms the pre-fix gap (expected before 0113 is applied).';
  exception when others then
    raise notice 'PREFLIGHT (draft): payment INSERT REJECTED (%) -- unexpected before 0113 is applied; something else already blocks this.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_disputed, 100.00, 'ach', now());
    raise notice 'PREFLIGHT (disputed): payment INSERT SUCCEEDED -- confirms the pre-fix gap (expected before 0113 is applied).';
  exception when others then
    raise notice 'PREFLIGHT (disputed): payment INSERT REJECTED (%) -- unexpected before 0113 is applied; something else already blocks this.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_sent, 100.00, 'ach', now());
    raise notice 'PREFLIGHT (sent): payment INSERT SUCCEEDED -- expected, both before and after 0113.';
  exception when others then
    raise notice 'PREFLIGHT (sent): payment INSERT REJECTED (%) -- unexpected; a valid payment against a sent invoice should always succeed.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_viewed, 100.00, 'ach', now());
    raise notice 'PREFLIGHT (viewed): payment INSERT SUCCEEDED -- expected, both before and after 0113.';
  exception when others then
    raise notice 'PREFLIGHT (viewed): payment INSERT REJECTED (%) -- unexpected; a valid payment against a viewed invoice should always succeed.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_partial, 100.00, 'ach', now());
    raise notice 'PREFLIGHT (partially_paid): payment INSERT SUCCEEDED -- expected, both before and after 0113.';
  exception when others then
    raise notice 'PREFLIGHT (partially_paid): payment INSERT REJECTED (%) -- unexpected; a valid payment against a partially paid invoice should always succeed.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_paid, 50.00, 'ach', now());
    raise notice 'PREFLIGHT (paid): payment INSERT SUCCEEDED -- unexpected; a paid (zero-balance) invoice should already reject via the existing overpayment check.';
  exception when others then
    raise notice 'PREFLIGHT (paid): payment INSERT REJECTED (%) -- expected already, via the pre-existing overpayment check (balance_due=0), independent of 0113.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_void, 100.00, 'ach', now());
    raise notice 'PREFLIGHT (void): payment INSERT SUCCEEDED -- unexpected; void invoices are already rejected by the live, unmodified guard.';
  exception when others then
    raise notice 'PREFLIGHT (void): payment INSERT REJECTED (%) -- expected already, unaffected by 0113.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_zero_balance, 10.00, 'ach', now());
    raise notice 'PREFLIGHT (zero-balance, sent): payment INSERT SUCCEEDED -- unexpected; the existing overpayment check (any amount > 0 balance) should already reject this.';
  exception when others then
    raise notice 'PREFLIGHT (zero-balance, sent): payment INSERT REJECTED (%) -- expected already, via the pre-existing overpayment check, independent of 0113.', sqlerrm;
  end;
end $$;

-- Discards every fixture and payment attempt created above, unconditionally.
rollback;
