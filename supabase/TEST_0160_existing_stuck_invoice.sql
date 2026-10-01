-- TEST_0160: an invoice ALREADY stuck before 0160 (fee deducted from reserve,
-- fully and correctly settled, but 'partially_reconciled') becomes closable
-- once 0160 is applied -- without 0160 touching its status or amounts.
-- Throwaway database only (0001..0119 + stub, 0160 NOT pre-applied).
\set ON_ERROR_STOP 1
do $$ begin if (select count(*) from public.organizations) > 0 then raise exception 'REFUSING: not a fresh database'; end if; end $$;
insert into auth.users (id, email, aud, role) values ('aaaaaaaa-0000-0000-0000-00000000000a', 'owner-a@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', false);
set role authenticated;
select public.create_organization_with_owner('Org A Freight', 'org-a-freight');
insert into public.factoring_companies (organization_id, name) values (public.current_org_id(), 'Apex Test Factoring');
insert into public.factoring_relationships (organization_id, factoring_company_id, default_advance_percentage, default_factoring_fee_percentage,
  default_reserve_percentage, fee_timing, recourse_type, is_default, effective_from)
select public.current_org_id(), id, 90, 3, 10, 'deducted_from_reserve', 'recourse', true, current_date - 1 from public.factoring_companies;
insert into public.invoices (organization_id, invoice_number, bill_to_name, status, subtotal_amount, total_amount, sent_at)
values (public.current_org_id(), 'STUCK-1', 'Test Broker LLC', 'sent', 1000, 1000, now());
select * from public.submit_invoice_to_factor((select id from public.invoices), (select id from public.factoring_relationships));
select public.mark_factored_invoice_pending(id) from public.factored_invoices;
select public.approve_factored_invoice(id) from public.factored_invoices;
select public.fund_factored_invoice(id, 900, null) from public.factored_invoices;
select public.report_customer_payment_to_factor(id, 1000) from public.factored_invoices;
select public.release_factoring_reserve(id, 70, 'k1', null) from public.factored_invoices;
reset role;
create temp table before as select status, reconciliation_status, actual_funded_amount, reserve_released_amount, updated_at from public.factored_invoices;
do $$ begin
  if (select reconciliation_status from before) <> 'partially_reconciled' then raise exception 'precondition: expected the invoice to be stuck'; end if;
end $$;
\echo -- before 0160: stuck
select status, reconciliation_status, actual_funded_amount, reserve_released_amount from before;

\i migrations/0160_factoring_fee_from_reserve_reconciliation_fix.sql

\echo -- after 0160: reconciled, nothing else changed
select status, reconciliation_status, actual_funded_amount, reserve_released_amount from public.factored_invoices;
do $$ declare b record; a record; begin
  select * into b from before; select * into a from public.factored_invoices;
  if a.reconciliation_status <> 'reconciled' then raise exception 'FAIL: still %', a.reconciliation_status; end if;
  if a.status <> b.status or a.actual_funded_amount <> b.actual_funded_amount or a.reserve_released_amount <> b.reserve_released_amount then
    raise exception 'FAIL: 0160 changed more than reconciliation_status'; end if;
  if (select count(*) from public.factoring_events where event_type = 'closed') <> 0 then raise exception 'FAIL: 0160 must not close anything itself'; end if;
end $$;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', false);
set role authenticated;
select public.close_factored_invoice(id) from public.factored_invoices;
reset role;
do $$ begin if (select status from public.factored_invoices) <> 'closed' then raise exception 'FAIL: could not close'; end if; end $$;
\i migrations/0160_factoring_fee_from_reserve_reconciliation_fix.sql
\echo TEST_0160 PASSED: stuck invoice became closable; re-running 0160 is safe
