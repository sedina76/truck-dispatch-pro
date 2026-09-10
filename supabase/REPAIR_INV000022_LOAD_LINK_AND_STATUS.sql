-- ---------------------------------------------------------------------------
-- CONTROLLED HISTORICAL REPAIR -- INV-000022 / LD-100022 ONLY.
--
-- DO NOT APPLY WITHOUT EXPLICIT AUTHORIZATION. NOT YET RUN SUCCESSFULLY.
--
-- REVISION -- migration 0112 (invoice_party_organization_guard) IS ALREADY
-- APPLIED to this database. The first version of this script was authored
-- and dry-run BEFORE that was true; the dry-run correctly failed with:
--   P0001: An invoice's linked load cannot be changed once set.
--   guard_invoice_party_organization() line 8
-- -- exactly the load_id-immutability check 0112 adds, firing because this
-- repair's UPDATE changes load_id from NULL to a real value. That is
-- 0112 working exactly as designed for every OTHER write; this repair is
-- the one legitimate, pre-authorized exception (restoring a load_id
-- wrongly stripped by a since-fixed application bug, never a real
-- relink), so the guard trigger is disabled for the minimum possible
-- scope -- this exact repair's own UPDATE statement -- and re-enabled
-- before the transaction ever commits. 0112 and
-- guard_invoice_party_organization() are NOT altered, weakened, dropped,
-- or recreated anywhere in this file -- only the trigger's tgenabled flag
-- is toggled off and back on, transactionally.
--
-- SAFETY ARGUMENT for why this cannot leave the trigger disabled:
-- ALTER TABLE ... DISABLE/ENABLE TRIGGER is ordinary transactional DDL in
-- PostgreSQL -- its effect on pg_trigger.tgenabled is exactly as
-- transactional as a row UPDATE. Both the DISABLE and the ENABLE below
-- happen inside the SAME transaction as every assertion and the write
-- itself, so a full ROLLBACK of the outer transaction would already undo
-- the disable on its own.
--
-- SAVEPOINT CORRECTION -- this is not left as the only safety net. The
-- disable/assert/write/re-enable sequence is wrapped in a nested
-- `begin ... exception when others ... end` sub-block, which PL/pgSQL
-- implements via an IMPLICIT SAVEPOINT established at the sub-block's own
-- `begin`. If anything inside it raises -- the disable itself, any row
-- assertion, the write, or the re-enable/its own verification -- PL/pgSQL
-- automatically rolls back to that savepoint FIRST (undoing the disable
-- at the catalog level immediately, before any other code runs), and only
-- then does the exception handler run. The handler explicitly re-issues
-- ENABLE TRIGGER anyway -- redundant with what the savepoint rollback
-- already did, deliberately: two independent mechanisms guaranteeing the
-- same outcome, not one relied on alone -- before re-raising the original
-- error so the whole outer transaction still aborts. This means the
-- trigger is restored to enabled at the EARLIEST possible point
-- (immediately on any failure, via the savepoint) rather than only at the
-- final outer ROLLBACK, and is restored by two mechanisms, not one.
--
-- SECOND CORRECTION -- the trailing guard-verification UPDATE (the
-- no-op `set notes = notes`, used only to force the re-enabled trigger to
-- actually fire against the restored row) is itself now wrapped in its
-- own explicit SQL SAVEPOINT/ROLLBACK TO SAVEPOINT/RELEASE SAVEPOINT --
-- three plain top-level statements, no PL/pgSQL -- so that verification
-- can never commit a secondary effect (updated_at or any other trigger
-- side effect) of its own, while a real guard failure there still
-- propagates and aborts the whole transaction exactly like any other
-- assertion in this file. The real repair performed earlier, inside the
-- DO block above, is unaffected either way -- this savepoint only ever
-- unwinds the verification statement's own effects, nothing that came
-- before it.
--
-- THIRD CORRECTION -- tightened identification and organization
-- assertions: PAY-000026 is now looked up and locked by its exact primary
-- key (ff025ea3-fa06-4cf7-916f-7bdf30b1bca0), with payment_number checked
-- as a separate, independent assertion rather than used as the lookup
-- key. load_financials for the target load is now selected FOR UPDATE and
-- asserted in its own right (exactly one row, correct load_id,
-- organization_id, and rate=3500.00), not merely inferred from the load
-- row. organization_id on the invoice, load, payment, AND load_financials
-- is now asserted against the specific expected organization
-- (11111111-0000-0000-0000-000000000001) independently for each row --
-- not merely asserted equal to one another, which could not have caught
-- all four being wrong in the same way. invoice_number, load_number, and
-- the invoice's dispatch_id are now asserted against their exact expected
-- values too. None of this changes the repair UPDATE itself, the trigger
-- disable/re-enable handling, the activity log, the verification
-- savepoint, or the final default ROLLBACK.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- STEP 0 -- READ-ONLY. Confirm the failed dry-run left no trace, before
-- attempting anything else. Run this block by itself first.
-- ===========================================================================

-- 0a. INV-000022 is still exactly as it was: unlinked, draft.
select id, invoice_number, load_id, status, paid_at
from public.invoices
where id = 'bd083e64-0ab7-4736-bb76-862a51cdca49'::uuid;
-- expect: load_id = null, status = 'draft', paid_at = null.

-- 0b. No historical-repair activity log was committed by the failed attempt
--     (a rolled-back transaction cannot have committed one, but confirm
--     rather than assume).
select * from public.activity_logs
where entity_type = 'invoice' and entity_id = 'bd083e64-0ab7-4736-bb76-862a51cdca49'::uuid
  and action = 'historical_repair_load_link_and_status_reconciled';
-- expect: 0 rows.

-- 0c. The 0112 guard trigger is present and enabled -- untouched by the
--     failed dry-run.
select tgname, tgrelid::regclass as table_name, tgenabled
from pg_trigger
where tgname = 'invoices_guard_party_org';
-- expect: 1 row, table_name = invoices, tgenabled = 'O' (enabled).

-- ===========================================================================
-- STEP 1 -- THE REPAIR ITSELF. Ends in ROLLBACK by default (see the very
-- last line) -- running this exactly as written changes nothing.
-- ===========================================================================

begin;

-- Strongest available lock on the whole table for the duration of this
-- narrow, sensitive operation -- explicitly requested, on top of the
-- row-level FOR UPDATE locks below (which alone would be sufficient for
-- the row-level assertions, but not for the trigger-disable window).
lock table public.invoices in access exclusive mode;

-- Assert the exact guard trigger exists and is enabled BEFORE touching it.
-- Not inside the savepoint-protected sub-block below -- nothing risky has
-- happened yet, so a plain abort here is already correct.
do $$
declare
  v_tgenabled "char";
begin
  select tgenabled into v_tgenabled from pg_trigger where tgname = 'invoices_guard_party_org' and tgrelid = 'public.invoices'::regclass;
  if not found then
    raise exception 'Assertion failed: trigger invoices_guard_party_org not found on public.invoices. STOP.';
  end if;
  if v_tgenabled <> 'O' then
    raise exception 'Assertion failed: trigger invoices_guard_party_org expected enabled (O), found tgenabled=%. STOP.', v_tgenabled;
  end if;
end $$;

-- Everything from here through re-enabling the trigger runs inside ONE
-- outer DO block, with the sensitive sequence wrapped in a nested
-- `begin ... exception ... end` sub-block -- see this file's header
-- "SAVEPOINT CORRECTION" note for exactly what that buys beyond relying
-- on the outer transaction alone. ALTER TABLE is DDL, so it must be
-- issued via EXECUTE from inside PL/pgSQL rather than as a plain
-- statement here.
do $$
declare
  v_expected_org constant uuid := '11111111-0000-0000-0000-000000000001'::uuid;
  v_tgenabled "char";
  v_invoice public.invoices;
  v_load public.loads;
  v_payment public.payments;
  v_load_financials public.load_financials;
  v_other_invoice_id uuid;
  v_row_count integer;
  v_loads_on_target integer;
begin
  begin -- implicit SAVEPOINT starts here
    execute 'alter table public.invoices disable trigger invoices_guard_party_org';

    select tgenabled into v_tgenabled from pg_trigger where tgname = 'invoices_guard_party_org' and tgrelid = 'public.invoices'::regclass;
    if v_tgenabled <> 'D' then
      raise exception 'Assertion failed: trigger invoices_guard_party_org expected disabled (D) after ALTER, found tgenabled=%. STOP.', v_tgenabled;
    end if;

    select * into v_invoice from public.invoices where id = 'bd083e64-0ab7-4736-bb76-862a51cdca49'::uuid for update;
    if not found then raise exception 'Assertion failed: invoice bd083e64-0ab7-4736-bb76-862a51cdca49 not found.'; end if;

    select * into v_load from public.loads where id = '588e08be-56eb-481a-af8c-8dba9f1753a7'::uuid for update;
    if not found then raise exception 'Assertion failed: load 588e08be-56eb-481a-af8c-8dba9f1753a7 not found.'; end if;

    -- Payment identified by exact primary key, not by its (mutable, in
    -- principle) payment_number -- payment_number is separately asserted
    -- below rather than used as the lookup key.
    select * into v_payment from public.payments where id = 'ff025ea3-fa06-4cf7-916f-7bdf30b1bca0'::uuid for update;
    if not found then raise exception 'Assertion failed: payment ff025ea3-fa06-4cf7-916f-7bdf30b1bca0 not found.'; end if;
    if v_payment.payment_number <> 'PAY-000026' then
      raise exception 'Assertion failed: payment ff025ea3-... payment_number expected PAY-000026, found %. STOP.', v_payment.payment_number;
    end if;

    -- load_financials for the exact target load -- its own row, locked
    -- and asserted independently rather than assumed from the load row.
    select * into v_load_financials from public.load_financials where load_id = '588e08be-56eb-481a-af8c-8dba9f1753a7'::uuid for update;
    if not found then raise exception 'Assertion failed: load_financials for load 588e08be-56eb-481a-af8c-8dba9f1753a7 not found (expected exactly one row -- load_id is its primary key). STOP.'; end if;
    if v_load_financials.load_id <> '588e08be-56eb-481a-af8c-8dba9f1753a7'::uuid then
      raise exception 'Assertion failed: load_financials.load_id expected 588e08be-..., found %. STOP.', v_load_financials.load_id;
    end if;
    if v_load_financials.organization_id <> v_expected_org then
      raise exception 'Assertion failed: load_financials.organization_id expected %, found %. STOP.', v_expected_org, v_load_financials.organization_id;
    end if;
    if v_load_financials.rate <> 3500.00 then
      raise exception 'Assertion failed: load_financials.rate expected 3500.00, found %. STOP.', v_load_financials.rate;
    end if;

    -- Organization asserted against the exact expected value for all four
    -- rows independently -- not merely asserted equal to one another,
    -- which would pass even if all four were wrong in the same way.
    if v_invoice.organization_id <> v_expected_org then
      raise exception 'Assertion failed: invoice organization_id expected %, found %. STOP.', v_expected_org, v_invoice.organization_id;
    end if;
    if v_load.organization_id <> v_expected_org then
      raise exception 'Assertion failed: load organization_id expected %, found %. STOP.', v_expected_org, v_load.organization_id;
    end if;
    if v_payment.organization_id <> v_expected_org then
      raise exception 'Assertion failed: payment organization_id expected %, found %. STOP.', v_expected_org, v_payment.organization_id;
    end if;

    if v_invoice.invoice_number <> 'INV-000022' then
      raise exception 'Assertion failed: invoice_number expected INV-000022, found %. STOP.', v_invoice.invoice_number;
    end if;
    if v_load.load_number <> 'LD-100022' then
      raise exception 'Assertion failed: load_number expected LD-100022, found %. STOP.', v_load.load_number;
    end if;
    if v_invoice.dispatch_id is distinct from '6b138dce-e94d-4013-8bf5-de78ab03bf8b'::uuid then
      raise exception 'Assertion failed: invoice dispatch_id expected 6b138dce-e94d-4013-8bf5-de78ab03bf8b, found %. STOP.', v_invoice.dispatch_id;
    end if;

    if v_invoice.load_id is not null then
      raise exception 'Assertion failed: invoice load_id expected NULL, found %. Data has changed since this script was authored -- STOP.', v_invoice.load_id;
    end if;
    if v_invoice.status <> 'draft' then
      raise exception 'Assertion failed: invoice status expected draft, found %. STOP.', v_invoice.status;
    end if;
    if v_invoice.total_amount <> 3500.00 then
      raise exception 'Assertion failed: invoice total_amount expected 3500.00, found %. STOP.', v_invoice.total_amount;
    end if;
    if v_invoice.amount_paid <> 3500.00 then
      raise exception 'Assertion failed: invoice amount_paid expected 3500.00, found %. STOP.', v_invoice.amount_paid;
    end if;
    if v_invoice.balance_due <> 0.00 then
      raise exception 'Assertion failed: invoice balance_due expected 0.00, found %. STOP.', v_invoice.balance_due;
    end if;
    if v_payment.invoice_id is distinct from v_invoice.id then
      raise exception 'Assertion failed: PAY-000026 is not linked to invoice bd083e64-.... STOP.';
    end if;
    if v_payment.amount <> 3500.00 then
      raise exception 'Assertion failed: PAY-000026 amount expected 3500.00, found %. STOP.', v_payment.amount;
    end if;
    if v_payment.status <> 'posted' then
      raise exception 'Assertion failed: PAY-000026 status expected posted, found %. STOP.', v_payment.status;
    end if;

    if v_invoice.broker_id is distinct from v_load.broker_id or v_invoice.customer_id is distinct from v_load.customer_id then
      raise exception 'Assertion failed: invoice broker_id/customer_id (%/%) does not match load broker_id/customer_id (%/%). STOP.',
        v_invoice.broker_id, v_invoice.customer_id, v_load.broker_id, v_load.customer_id;
    end if;

    select id into v_other_invoice_id from public.invoices where load_id = v_load.id;
    if v_other_invoice_id is not null then
      raise exception 'Assertion failed: load 588e08be-... is already linked to a different invoice %. STOP.', v_other_invoice_id;
    end if;

    -- All assertions passed. Update only what is proven necessary, scoped
    -- to this exact single row by primary key.
    update public.invoices
    set load_id = v_load.id,
        status = 'paid',
        paid_at = v_payment.received_at
    where id = v_invoice.id;

    get diagnostics v_row_count = row_count;
    if v_row_count <> 1 then
      raise exception 'Assertion failed: expected exactly 1 invoice row updated, affected %. STOP.', v_row_count;
    end if;

    select count(*) into v_loads_on_target from public.invoices where load_id = v_load.id;
    if v_loads_on_target <> 1 then
      raise exception 'Assertion failed: load 588e08be-... expected exactly 1 linked invoice after repair, found %. STOP.', v_loads_on_target;
    end if;

    perform public.log_activity(
      p_entity_type => 'invoice'::public.entity_type,
      p_entity_id => v_invoice.id,
      p_action => 'historical_repair_load_link_and_status_reconciled',
      p_changes => jsonb_build_object(
        'reason', 'Restored load_id stripped by the pre-fix updateInvoice() bug, and reconciled status to paid based on PAY-000026 (a full posted payment apply_payment_to_invoice() could never promote past draft). guard_invoice_party_organization() (0112) was disabled for this statement only, inside a savepoint-protected sub-block, and re-enabled before commit.',
        'old_load_id', null,
        'new_load_id', v_load.id,
        'old_status', 'draft',
        'new_status', 'paid',
        'basis_payment_number', 'PAY-000026'
      ),
      p_organization_id => v_invoice.organization_id
    );

    execute 'alter table public.invoices enable trigger invoices_guard_party_org';

    select tgenabled into v_tgenabled from pg_trigger where tgname = 'invoices_guard_party_org' and tgrelid = 'public.invoices'::regclass;
    if v_tgenabled <> 'O' then
      raise exception 'Assertion failed: trigger invoices_guard_party_org expected enabled (O) after re-enable, found tgenabled=%. STOP.', v_tgenabled;
    end if;

  exception when others then
    -- The implicit savepoint established at this sub-block's `begin` has
    -- ALREADY been rolled back to by the time this handler runs (standard
    -- PL/pgSQL behavior), which already undoes the disable above at the
    -- catalog level. This re-issues ENABLE anyway -- deliberately
    -- redundant, a second independent mechanism guaranteeing the trigger
    -- is on, not a substitute for the first -- then re-raises so the
    -- outer transaction (and this whole DO block) still aborts.
    execute 'alter table public.invoices enable trigger invoices_guard_party_org';
    raise;
  end;
end $$;

-- Direct-invocation proof (Section 2's own requirement): force the
-- now-re-enabled trigger to actually re-evaluate this exact row, rather
-- than only reasoning about whether it would pass. A no-op UPDATE (no
-- WHEN clause exists on this trigger, so it fires on any UPDATE
-- regardless of whether a value actually changes) re-runs
-- guard_invoice_party_organization() against the row's now-restored
-- load_id/broker_id/customer_id. If the row did not actually satisfy the
-- guard's own rules, THIS is what would raise -- not a re-statement of
-- the same assertions already checked by hand above.
--
-- CORRECTION -- this verification UPDATE must not commit its own
-- secondary effects (updated_at, or any other trigger side effect the
-- verification itself incidentally causes) -- it exists purely to make
-- the trigger fire and prove it accepts the row, not to make a second,
-- unintended write. Wrapped in its own explicit SQL SAVEPOINT, as three
-- plain top-level statements (no PL/pgSQL, no DO block) so the rollback
-- is a bare SQL command: if guard_invoice_party_organization() raises here,
-- that exception still propagates and aborts the whole outer transaction
-- exactly like any other assertion in this file; if it does NOT raise
-- (the expected, passing case), rolling back to this savepoint discards
-- the no-op UPDATE's own effects while leaving every change already made
-- and committed-so-far in the outer transaction -- specifically the real
-- historical repair performed inside the DO block above -- completely
-- untouched. RELEASE SAVEPOINT then drops the savepoint itself now that
-- it's no longer needed, without affecting anything it protected.
savepoint verify_restored_guard;
update public.invoices set notes = notes where id = 'bd083e64-0ab7-4736-bb76-862a51cdca49'::uuid;
rollback to savepoint verify_restored_guard;
release savepoint verify_restored_guard;

-- Before/after verification -- review this output before deciding whether
-- to COMMIT or ROLLBACK.
select id, invoice_number, load_id, status, total_amount, amount_paid, balance_due, paid_at
from public.invoices
where id = 'bd083e64-0ab7-4736-bb76-862a51cdca49'::uuid;

select tgname, tgenabled from pg_trigger where tgname = 'invoices_guard_party_org';
-- expect: tgenabled = 'O' -- re-confirms the enable survived the
-- direct-invocation UPDATE above, immediately before this transaction
-- ends.

select * from public.activity_logs
where entity_type = 'invoice' and entity_id = 'bd083e64-0ab7-4736-bb76-862a51cdca49'::uuid
  and action = 'historical_repair_load_link_and_status_reconciled';

-- Reviewer: change to COMMIT only after confirming every output above
-- matches the required final state exactly, including tgenabled = 'O'.
-- Left as ROLLBACK so this script is inert if run as-is.
rollback;
-- commit;
