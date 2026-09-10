-- Run AFTER applying 0113_invoice_collectible_status_guard.sql.
--
-- Same disposable TEST-CPG-* fixture approach as the preflight script --
-- everything created here is discarded by the unconditional ROLLBACK at
-- the end. Nothing persists, no real data is touched.

begin;

-- 1. Confirm the live function now contains the broadened trigger
--    condition and the 4-value collectible allow-list.
select pg_get_functiondef(oid) like '%new.invoice_id is distinct from old.invoice_id%'
  and pg_get_functiondef(oid) like '%not in (''sent'', ''viewed'', ''overdue'', ''partially_paid'')%' as covers_reassignment_and_collectible_allowlist
from pg_proc where proname = 'guard_payment_amount' and pronamespace = 'public'::regnamespace;
-- expect: true

do $$
declare
  v_org_id uuid;
  v_inv_draft uuid;
  v_inv_disputed uuid;
  v_inv_sent uuid;
  v_inv_sent2 uuid;
  v_inv_viewed uuid;
  v_inv_partial uuid;
  v_inv_paid uuid;
  v_inv_void uuid;
  v_inv_zero_balance uuid;
  v_payment_id uuid;
  v_rollup record;
begin
  select id into v_org_id from public.organizations limit 1;
  if v_org_id is null then
    raise exception 'No organization exists to scope disposable test fixtures under -- cannot run this verification.';
  end if;

  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-DRAFT', 'draft', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30) returning id into v_inv_draft;
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-DISPUTED', 'disputed', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30) returning id into v_inv_disputed;
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-SENT', 'sent', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30) returning id into v_inv_sent;
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-SENT-2', 'sent', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30) returning id into v_inv_sent2;
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-VIEWED', 'viewed', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30) returning id into v_inv_viewed;
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, amount_paid, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-PARTIAL', 'partially_paid', 'TEST-COLLECTIBLE-GUARD', 500.00, 200.00, current_date, current_date + 30) returning id into v_inv_partial;
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, amount_paid, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-PAID', 'paid', 'TEST-COLLECTIBLE-GUARD', 500.00, 500.00, current_date, current_date + 30) returning id into v_inv_paid;
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-VOID', 'void', 'TEST-COLLECTIBLE-GUARD', 500.00, current_date, current_date + 30) returning id into v_inv_void;
  insert into public.invoices (organization_id, invoice_number, status, bill_to_name, total_amount, issue_date, due_date)
  values (v_org_id, 'TEST-CPG-ZEROBAL', 'sent', 'TEST-COLLECTIBLE-GUARD', 0.00, current_date, current_date + 30) returning id into v_inv_zero_balance;

  -- 2. New payment vs Draft -- now expected to be REJECTED (the fix).
  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_draft, 100.00, 'ach', now());
    raise notice 'POST-APPLY (draft): payment INSERT SUCCEEDED -- WRONG, 0113 should reject this.';
  exception when others then
    raise notice 'POST-APPLY (draft): payment INSERT REJECTED (%) -- correct.', sqlerrm;
  end;

  -- 3. New payment vs Disputed -- now expected to be REJECTED.
  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_disputed, 100.00, 'ach', now());
    raise notice 'POST-APPLY (disputed): payment INSERT SUCCEEDED -- WRONG, 0113 should reject this.';
  exception when others then
    raise notice 'POST-APPLY (disputed): payment INSERT REJECTED (%) -- correct.', sqlerrm;
  end;

  -- 4. Sent/Viewed/Partially Paid -- still ALLOWED with a valid amount.
  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_sent, 500.00, 'ach', now()) returning id into v_payment_id;
    raise notice 'POST-APPLY (sent, full amount): payment INSERT SUCCEEDED -- correct.';

    -- 5. Payment-rollup behavior unchanged: a full payment should roll
    --    the invoice to paid, balance_due to 0, paid_at set -- all via
    --    the untouched apply_payment_to_invoice() (0026).
    select status, amount_paid, balance_due, paid_at into v_rollup from public.invoices where id = v_inv_sent;
    if v_rollup.status <> 'paid' or v_rollup.amount_paid <> 500.00 or v_rollup.balance_due <> 0.00 or v_rollup.paid_at is null then
      raise notice 'POST-APPLY (rollup check): UNEXPECTED -- status=%, amount_paid=%, balance_due=%, paid_at=% (expected paid/500.00/0.00/not null).',
        v_rollup.status, v_rollup.amount_paid, v_rollup.balance_due, v_rollup.paid_at;
    else
      raise notice 'POST-APPLY (rollup check): correct -- invoice rolled up to paid/500.00/0.00 with paid_at set, exactly as apply_payment_to_invoice() already did before 0113.';
    end if;

    -- 6. Voiding this existing posted payment must still work (status
    --    leaves 'posted' -- the broadened trigger condition's first
    --    branch requires new.status='posted', so this remains untouched;
    --    invoice_id is not changing either, so the second branch doesn't
    --    fire).
    update public.payments set status = 'voided', void_reason = 'test cleanup' where id = v_payment_id;
    raise notice 'POST-APPLY (void existing payment): UPDATE to voided SUCCEEDED -- correct, unaffected by 0113.';

    -- 7. Same-status notes-only edit on an existing payment, AFTER the
    --    invoice's own status has since changed -- must NOT be re-blocked
    --    just because the invoice status changed since this payment was
    --    posted. Re-insert a fresh payment first (the one above is now
    --    voided), then change the invoice status out from under it, then
    --    edit the payment's notes only.
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_sent, 100.00, 'ach', now()) returning id into v_payment_id;
    update public.invoices set status = 'disputed' where id = v_inv_sent; -- invoice status changes AFTER the payment was posted
    update public.payments set notes = 'test note, no status/invoice_id change' where id = v_payment_id;
    raise notice 'POST-APPLY (notes-only edit after invoice status changed): UPDATE SUCCEEDED -- correct, not re-blocked.';
  exception when others then
    raise notice 'POST-APPLY (sent / rollup / void / notes-only sequence): UNEXPECTED FAILURE (%) -- investigate.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_viewed, 250.00, 'ach', now());
    raise notice 'POST-APPLY (viewed, partial amount): payment INSERT SUCCEEDED -- correct.';
  exception when others then
    raise notice 'POST-APPLY (viewed): UNEXPECTED FAILURE (%).', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_partial, 100.00, 'ach', now());
    raise notice 'POST-APPLY (partially_paid, additional amount): payment INSERT SUCCEEDED -- correct.';
  exception when others then
    raise notice 'POST-APPLY (partially_paid): UNEXPECTED FAILURE (%).', sqlerrm;
  end;

  -- 8. Paid/Void/zero-balance -- still REJECTED (unaffected by 0113;
  --    already blocked before it via the overpayment check / the
  --    unchanged void exclusion, now also covered explicitly by the
  --    allow-list for paid/void).
  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_paid, 50.00, 'ach', now());
    raise notice 'POST-APPLY (paid): payment INSERT SUCCEEDED -- WRONG.';
  exception when others then
    raise notice 'POST-APPLY (paid): payment INSERT REJECTED (%) -- correct.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_void, 100.00, 'ach', now());
    raise notice 'POST-APPLY (void): payment INSERT SUCCEEDED -- WRONG.';
  exception when others then
    raise notice 'POST-APPLY (void): payment INSERT REJECTED (%) -- correct.', sqlerrm;
  end;

  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_zero_balance, 10.00, 'ach', now());
    raise notice 'POST-APPLY (zero-balance, sent): payment INSERT SUCCEEDED -- WRONG.';
  exception when others then
    raise notice 'POST-APPLY (zero-balance, sent): payment INSERT REJECTED (%) -- correct.', sqlerrm;
  end;

  -- 9. NEW gap-closing behavior: reassigning an EXISTING posted payment
  --    to a non-collectible invoice (status stays 'posted' throughout --
  --    only invoice_id changes) must now be rejected. Uses the still-open
  --    TEST-CPG-SENT-2 invoice as the payment's original home.
  begin
    insert into public.payments (organization_id, invoice_id, amount, method, received_at) values (v_org_id, v_inv_sent2, 500.00, 'ach', now()) returning id into v_payment_id;
    raise notice 'POST-APPLY (reassignment setup): initial payment against TEST-CPG-SENT-2 INSERT SUCCEEDED -- correct.';

    update public.payments set invoice_id = v_inv_draft where id = v_payment_id;
    raise notice 'POST-APPLY (reassignment to draft): UPDATE SUCCEEDED -- WRONG, 0113 should reject reassigning a posted payment to a non-collectible invoice.';
  exception when others then
    raise notice 'POST-APPLY (reassignment to draft): UPDATE REJECTED (%) -- correct, confirms the reassignment gap is closed.', sqlerrm;
  end;
end $$;

-- Discards every fixture and payment attempt created above, unconditionally.
rollback;
