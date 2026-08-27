-- ---------------------------------------------------------------------------
-- PRE-APPLY -- Payment Collectible-Status Hardening.
--
-- DO NOT APPLY WITHOUT APPROVAL.
--
-- ROOT CAUSE (audited first, not assumed -- see this phase's own report):
-- guard_payment_amount() (0026_accounts_receivable.sql, UNCHANGED by this
-- migration -- see below) only ever excludes ONE invoice status from
-- receiving a payment: 'void'. Every other status -- including 'draft'
-- (never actually sent to anyone) and 'disputed' (actively contested) --
-- is currently accepted. The New Invoice/Record Payment picker UI already
-- narrows its own candidate list, but a forged or direct
-- insert/reassignment could still bypass it entirely, since the database
-- itself was the more permissive layer, not the other way around.
--
-- Confirmed collectible statuses, exactly as specified: sent, viewed,
-- overdue, partially_paid. Note: 'overdue' is never actually written into
-- invoices.status by any code path in this schema -- it is a purely
-- DERIVED display value (public.invoice_effective_status(), 0026) computed
-- from stored status + due_date; a genuinely overdue invoice's real
-- stored status remains 'sent'/'viewed'/'partially_paid'. 'overdue' is
-- included in the allow-list below anyway, both because it was explicitly
-- specified and for forward-compatibility if that ever changes -- it is
-- inert today, not incorrect.
--
-- EXACT INSERT/UPDATE SEMANTICS INSPECTED BEFORE WRITING THIS (not
-- assumed): the live guard_payment_amount() re-validates ONLY when
--   new.status = 'posted' and old.status is distinct from new.status
-- -- true on every INSERT (OLD is NULL, so "distinct from" is
-- unconditionally true) and true on the one defensive UPDATE case that
-- flips status INTO 'posted' from something else (there is no un-void
-- path in the app today, but the guard doesn't trust one couldn't be
-- added later). Critically, this condition is FALSE for:
--   - voiding a payment (new.status='voided' -- new.status='posted' is
--     false, so the entire block, and everything in it, is skipped).
--   - a plain notes-only edit on an already-posted payment (old.status=
--     'posted', new.status='posted' -- "distinct from" is false).
-- This is exactly why "voiding continues to work" and "an existing
-- posted payment's later edit is never re-blocked just because the
-- invoice's status changed since" are both ALREADY true of the live
-- function, and this migration preserves that condition unchanged for
-- both cases -- neither is touched.
--
-- GAP THIS MIGRATION CLOSES, found during that same inspection: the
-- existing condition never fires for an UPDATE that changes invoice_id
-- while status stays 'posted' the whole time (old.status='posted',
-- new.status='posted' -- "distinct from" is false) -- meaning a
-- reassignment of an already-posted payment to a different invoice
-- currently bypasses re-validation entirely. Confirmed before writing
-- this: no existing workflow anywhere in this codebase ever does this
-- (src/app/(app)/payments/actions.ts's own header comment: "amount/
-- method/invoice/reference are immutable after creation") -- same
-- "defend it anyway, even with no known caller" posture as this session's
-- earlier invoices.load_id immutability guard (migration 0112).
--
-- REPAIR: guard_payment_amount() is redefined (create or replace, same
-- object, same trigger, same name, same table -- 0026 itself is NOT
-- edited, re-applied, or altered in any way) to:
--   1. Fire on the existing condition, OR when new.invoice_id is
--      distinct from old.invoice_id (the reassignment case) -- an INSERT
--      still always matches (old.invoice_id is NULL, new.invoice_id is
--      not, on any real insert).
--   2. Replace the single `= 'void'` exclusion with the full 4-value
--      collectible allow-list.
-- Amount-null/non-positive and overpayment checks are unchanged in
-- substance, just re-ordered to sit under the broadened trigger
-- condition.
-- ---------------------------------------------------------------------------

create or replace function public.guard_payment_amount()
returns trigger
language plpgsql
as $$
declare
  v_balance numeric(10, 2);
  v_invoice_status public.invoice_status;
begin
  if (new.status = 'posted' and old.status is distinct from new.status)
     or (new.invoice_id is distinct from old.invoice_id) then
    if new.amount is null or new.amount <= 0 then
      raise exception 'Payment amount must be greater than zero.';
    end if;

    select balance_due, status into v_balance, v_invoice_status
    from public.invoices
    where id = new.invoice_id
    for update;

    if v_invoice_status is null then
      raise exception 'Invoice not found.';
    end if;

    if v_invoice_status not in ('sent', 'viewed', 'overdue', 'partially_paid') then
      raise exception 'Cannot record a payment against an invoice with status %. Only Sent, Viewed, Overdue, or Partially Paid invoices are collectible.', v_invoice_status;
    end if;

    if v_balance is null or v_balance <= 0 then
      raise exception 'This invoice has no balance due -- there is nothing left to record a payment against.';
    end if;

    if new.amount > v_balance then
      raise exception 'Payment amount ($%) exceeds the invoice balance due ($%). Overpayment is not supported -- record a partial payment for the remaining balance instead.', new.amount, v_balance;
    end if;
  end if;
  return new;
end;
$$;

comment on function public.guard_payment_amount() is
  'BEFORE INSERT OR UPDATE guard on public.payments. Re-validates amount/invoice on (a) any transition of status INTO posted (covers every INSERT, since OLD is null), or (b) a reassignment of invoice_id while status stays posted -- neither case includes voiding a payment (status leaving posted) or a same-status notes-only edit, both of which remain unaffected. Collectible statuses: sent, viewed, overdue, partially_paid (0113) -- replaces the original narrower "not void" exclusion (0026). Locks the target invoice row (FOR UPDATE) for the duration of this check, same as the original.';

-- No trigger recreation needed: payments_guard_amount (0026) already
-- references this function by name; CREATE OR REPLACE FUNCTION updates
-- its behavior in place, exactly like every prior revision pattern in
-- this schema (e.g. guard_invoice_party_organization(), 0112).
