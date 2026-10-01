-- ============================================================================
-- TEST_FACTORING_LIFECYCLE_E2E.sql -- end-to-end "autopilot" of the legacy
-- invoice factoring lifecycle, run as real authenticated users (RLS on),
-- exactly the database calls the app's buttons make
-- (src/app/(app)/invoices/factoring-actions.ts):
--
--   A. happy path:  submit -> pending -> approve -> fund -> customer pays
--                   -> release reserve -> close
--   B. rejection:   submit -> reject (and the invoice can be resubmitted)
--   C. dispute:     ... fund -> dispute -> resolve
--   D. recourse:    ... fund -> recourse -> chargeback, and a buyback
--   E. guard rails: wrong org, dispatcher limits, double submit, overfunding
--
-- Each step is recorded PASS/FAIL (expected outcome vs actual) instead of
-- aborting, then the script FAILS at the end if any step failed.
--
-- Runs on a THROWAWAY database built from migrations 0001..0119 + the
-- Supabase stub (supabase/ci/platform_stub.sql). Refuses to run on anything
-- that looks like a real database. Never point this at production.
--
-- Note: migration 0140 later REPLACES submit_invoice_to_factor() so it
-- refuses every legacy submission (CARRIER_INVOICE_SNAPSHOT_REQUIRED); this
-- test exercises the pre-0140 submission so the post-submission steps
-- (unchanged since 0076-0078, still live for already-factored invoices)
-- can be driven end to end.
-- ============================================================================
\set ON_ERROR_STOP 1
\pset pager off

do $$ begin
  if (select count(*) from public.organizations) > 0 then
    raise exception 'REFUSING: this database already has organizations -- run only on a fresh throwaway database.';
  end if;
end $$;

create table if not exists pg_temp.results (n serial, step text, expected text, actual text, ok boolean, detail text);
-- the steps run AS the test users (RLS on), and record their own results
grant all on pg_temp.results to authenticated;
grant usage on all sequences in schema pg_temp to authenticated;

-- run(step, sql, expect_ok): executes sql in a subtransaction as the CURRENT
-- role/claims; records whether it succeeded or failed vs expectation.
create or replace function pg_temp.run(p_step text, p_sql text, p_expect_ok boolean default true) returns void
language plpgsql as $$
declare v_err text;
begin
  begin
    execute p_sql;
    insert into pg_temp.results (step, expected, actual, ok, detail)
    values (p_step, case when p_expect_ok then 'succeeds' else 'refused' end, 'succeeded', p_expect_ok, null);
  exception when others then
    get stacked diagnostics v_err = message_text;
    insert into pg_temp.results (step, expected, actual, ok, detail)
    values (p_step, case when p_expect_ok then 'succeeds' else 'refused' end, 'refused', not p_expect_ok, v_err);
  end;
end $$;

create or replace function pg_temp.check(p_step text, p_cond boolean, p_detail text) returns void
language sql as $$
  insert into pg_temp.results (step, expected, actual, ok, detail)
  values (p_step, 'true', case when p_cond then 'true' else 'false' end, coalesce(p_cond, false), p_detail);
$$;

create or replace function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
$$;

-- ---------------------------------------------------------------- fixtures --
insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'owner-a@test.invalid', 'authenticated', 'authenticated'),
  ('cccccccc-0000-0000-0000-00000000000c', 'disp-a@test.invalid',  'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'owner-b@test.invalid', 'authenticated', 'authenticated');

select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
set role authenticated;
select public.create_organization_with_owner('Org A Freight', 'org-a-freight');
reset role;
select pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
set role authenticated;
select public.create_organization_with_owner('Org B Logistics', 'org-b-logistics');
reset role;

set app.bypass_profile_guard = 'true';
update public.profiles set organization_id = (select id from public.organizations where slug = 'org-a-freight'), role = 'dispatcher'
 where id = 'cccccccc-0000-0000-0000-00000000000c';
set app.bypass_profile_guard = 'false';

-- Org A: factor + relationship (90% advance, 3% fee from reserve, 10% reserve)
-- and four $1,000 invoices in "sent" status, all created as the owner.
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
set role authenticated;
insert into public.factoring_companies (organization_id, name) values (public.current_org_id(), 'Apex Test Factoring');
insert into public.factoring_relationships (organization_id, factoring_company_id, default_advance_percentage, default_factoring_fee_percentage,
  default_reserve_percentage, fee_timing, recourse_type, is_default, effective_from)
select public.current_org_id(), id, 90, 3, 10, 'deducted_from_reserve', 'recourse', true, current_date - 1 from public.factoring_companies;
insert into public.invoices (organization_id, invoice_number, bill_to_name, status, subtotal_amount, total_amount, sent_at)
select public.current_org_id(), 'E2E-' || g, 'Test Broker LLC', 'sent', 1000, 1000, now() from generate_series(1, 5) g;
reset role;

create temp table ids as
select (select id from public.factoring_relationships limit 1) as rel,
       (select id from public.invoices where invoice_number = 'E2E-1') as inv1,
       (select id from public.invoices where invoice_number = 'E2E-2') as inv2,
       (select id from public.invoices where invoice_number = 'E2E-3') as inv3,
       (select id from public.invoices where invoice_number = 'E2E-4') as inv4,
       (select id from public.invoices where invoice_number = 'E2E-5') as inv5;
grant select on ids to authenticated;

create or replace function pg_temp.fi(p_inv uuid) returns uuid language sql as $$
  select id from public.factored_invoices where invoice_id = p_inv and status not in ('rejected', 'cancelled') order by created_at desc limit 1
$$;
create or replace function pg_temp.st(p_inv uuid) returns text language sql as $$
  select status::text from public.factored_invoices where invoice_id = p_inv order by created_at desc limit 1
$$;

-- ======================================================= A. happy path ====
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
set role authenticated;
select pg_temp.run('A1 submit invoice to factor', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv1 from ids), (select rel from ids)));
select pg_temp.check('A1 status = submitted', pg_temp.st((select inv1 from ids)) = 'submitted', pg_temp.st((select inv1 from ids)));
select pg_temp.check('A1 advance/reserve calculated (900 / 100 / fee 30)',
  (select expected_advance_amount = 900 and reserve_amount = 100 and factoring_fee_amount = 30 from public.factored_invoices where id = pg_temp.fi((select inv1 from ids))),
  (select format('advance %s reserve %s fee %s expected funding %s', expected_advance_amount, reserve_amount, factoring_fee_amount, expected_funding_amount) from public.factored_invoices where id = pg_temp.fi((select inv1 from ids))));
select pg_temp.run('A2 mark pending (factor reviewing)', format('select public.mark_factored_invoice_pending(%L)', pg_temp.fi((select inv1 from ids))));
select pg_temp.check('A2 status = pending', pg_temp.st((select inv1 from ids)) = 'pending', pg_temp.st((select inv1 from ids)));
select pg_temp.run('A3 approve', format('select public.approve_factored_invoice(%L)', pg_temp.fi((select inv1 from ids))));
select pg_temp.check('A3 status = approved', pg_temp.st((select inv1 from ids)) = 'approved', pg_temp.st((select inv1 from ids)));
select pg_temp.run('A4 fund (factor paid $900 advance)', format('select public.fund_factored_invoice(%L, 900, %L)', pg_temp.fi((select inv1 from ids)), 'ACH-E2E-1'));
select pg_temp.check('A4 status = funded', pg_temp.st((select inv1 from ids)) = 'funded', pg_temp.st((select inv1 from ids)));
select pg_temp.run('A5 broker paid factor $1,000', format('select public.report_customer_payment_to_factor(%L, 1000)', pg_temp.fi((select inv1 from ids))));
select pg_temp.check('A5 status after customer payment', pg_temp.st((select inv1 from ids)) in ('partially_settled', 'funded'), pg_temp.st((select inv1 from ids)));
select pg_temp.run('A6 factor released reserve $70 (100 reserve - 30 fee)', format('select public.release_factoring_reserve(%L, 70, %L, %L)', pg_temp.fi((select inv1 from ids)), 'e2e-release-1', 'RES-E2E-1'));
select pg_temp.run('A6b same release again is a no-op/refused (idempotent)', format('select public.release_factoring_reserve(%L, 70, %L, %L)', pg_temp.fi((select inv1 from ids)), 'e2e-release-1', 'RES-E2E-1'));
select pg_temp.run('A7 close factored invoice', format('select public.close_factored_invoice(%L)', pg_temp.fi((select inv1 from ids))));
select pg_temp.check('A7 status = closed', pg_temp.st((select inv1 from ids)) = 'closed', pg_temp.st((select inv1 from ids)));
select pg_temp.check('A  full event trail recorded',
  (select count(*) >= 6 from public.factoring_events where factored_invoice_id = (select id from public.factored_invoices where invoice_id = (select inv1 from ids))),
  (select string_agg(event_type, ' > ' order by created_at) from public.factoring_events where factored_invoice_id = (select id from public.factored_invoices where invoice_id = (select inv1 from ids))));

-- ========================================================= B. rejection ===
select pg_temp.run('B1 submit', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv2 from ids), (select rel from ids)));
select pg_temp.run('B1b mark pending', format('select public.mark_factored_invoice_pending(%L)', pg_temp.fi((select inv2 from ids))));
select pg_temp.run('B2 reject with reason', format('select public.reject_factored_invoice(%L, %L)', pg_temp.fi((select inv2 from ids)), 'Missing signed BOL'));
select pg_temp.check('B2 status = rejected', pg_temp.st((select inv2 from ids)) = 'rejected', pg_temp.st((select inv2 from ids)));
select pg_temp.run('B3 resubmit after rejection', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv2 from ids), (select rel from ids)));
select pg_temp.check('B3 new submission = submitted', pg_temp.st((select inv2 from ids)) = 'submitted', pg_temp.st((select inv2 from ids)));

-- =========================================================== C. dispute ===
select pg_temp.run('C1 submit', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv3 from ids), (select rel from ids)));
select pg_temp.run('C1b mark pending', format('select public.mark_factored_invoice_pending(%L)', pg_temp.fi((select inv3 from ids))));
select pg_temp.run('C2 approve', format('select public.approve_factored_invoice(%L)', pg_temp.fi((select inv3 from ids))));
select pg_temp.run('C3 fund', format('select public.fund_factored_invoice(%L, 900, null)', pg_temp.fi((select inv3 from ids))));
select pg_temp.run('C4 broker disputes', format('select public.mark_factored_invoice_disputed(%L, %L, %L)', pg_temp.fi((select inv3 from ids)), 'Broker claims shortage', 'CLM-1'));
select pg_temp.check('C4 status = disputed', pg_temp.st((select inv3 from ids)) = 'disputed', pg_temp.st((select inv3 from ids)));
select pg_temp.run('C5 dispute resolved', format('select public.resolve_factoring_dispute(%L, %L)', pg_temp.fi((select inv3 from ids)), 'Shortage photo cleared it'));
select pg_temp.check('C5 status = partially_settled (by design, 0078)', pg_temp.st((select inv3 from ids)) = 'partially_settled', pg_temp.st((select inv3 from ids)));

-- ========================================================== D. recourse ===
select pg_temp.run('D1 submit', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv4 from ids), (select rel from ids)));
select pg_temp.run('D1b mark pending', format('select public.mark_factored_invoice_pending(%L)', pg_temp.fi((select inv4 from ids))));
select pg_temp.run('D2 approve', format('select public.approve_factored_invoice(%L)', pg_temp.fi((select inv4 from ids))));
select pg_temp.run('D3 fund', format('select public.fund_factored_invoice(%L, 900, null)', pg_temp.fi((select inv4 from ids))));
select pg_temp.run('D3b broker disputes', format('select public.mark_factored_invoice_disputed(%L, %L, null)', pg_temp.fi((select inv4 from ids)), 'Broker refuses to pay'));
select pg_temp.run('D4 broker never paid -> recourse', format('select public.start_factoring_recourse(%L, 900, %L, %L)', pg_temp.fi((select inv4 from ids)), 'Broker unpaid 90 days', 'REC-1'));
select pg_temp.check('D4 status = recourse', pg_temp.st((select inv4 from ids)) = 'recourse', pg_temp.st((select inv4 from ids)));
select pg_temp.run('D5 factor charges back $900', format('select public.record_factoring_chargeback(%L, 900, %L, %L)', pg_temp.fi((select inv4 from ids)), 'CB-1', 'Recourse chargeback'));
select pg_temp.check('D5 status = chargeback', pg_temp.st((select inv4 from ids)) = 'chargeback', pg_temp.st((select inv4 from ids)));
-- buyback is the ALTERNATIVE to a chargeback (both start from recourse, 0078)
insert into public.invoices (organization_id, invoice_number, bill_to_name, status, subtotal_amount, total_amount, sent_at)
values (public.current_org_id(), 'E2E-7', 'Test Broker LLC', 'sent', 1000, 1000, now());
create temp table ids3 as select (select id from public.invoices where invoice_number = 'E2E-7') as inv;
select pg_temp.run('D6 submit/pending/approve/fund/dispute/recourse (buyback path)', format(
  'select * from public.submit_invoice_to_factor(%1$L, %2$L); '
  'select public.mark_factored_invoice_pending(public.factored_invoices.id) from public.factored_invoices where invoice_id = %1$L; '
  'select public.approve_factored_invoice(id) from public.factored_invoices where invoice_id = %1$L; '
  'select public.fund_factored_invoice(id, 900, null) from public.factored_invoices where invoice_id = %1$L; '
  'select public.mark_factored_invoice_disputed(id, %3$L, null) from public.factored_invoices where invoice_id = %1$L; '
  'select public.start_factoring_recourse(id, 900, %4$L, null) from public.factored_invoices where invoice_id = %1$L;',
  (select inv from ids3), (select rel from ids), 'Broker out of business', 'Recourse'));
select pg_temp.run('D7 carrier buys the invoice back', format('select public.record_factoring_buyback(%L, 900, %L, %L)', pg_temp.fi((select inv from ids3)), 'BB-1', 'Bought back'));
select pg_temp.check('D7 status = closed after buyback', pg_temp.st((select inv from ids3)) = 'closed', pg_temp.st((select inv from ids3)));

-- ============== F. fee deducted AT FUNDING (other fee-timing option) =====
reset role;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
set role authenticated;
insert into public.factoring_relationships (organization_id, factoring_company_id, default_advance_percentage, default_factoring_fee_percentage,
  default_reserve_percentage, fee_timing, recourse_type, is_default, effective_from)
select public.current_org_id(), id, 90, 3, 10, 'deducted_at_funding', 'non_recourse', false, current_date - 1 from public.factoring_companies;
insert into public.invoices (organization_id, invoice_number, bill_to_name, status, subtotal_amount, total_amount, sent_at)
values (public.current_org_id(), 'E2E-6', 'Test Broker LLC', 'sent', 1000, 1000, now());
create temp table ids2 as select (select id from public.factoring_relationships where fee_timing = 'deducted_at_funding') as rel,
  (select id from public.invoices where invoice_number = 'E2E-6') as inv;
select pg_temp.run('F1 submit (fee at funding)', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv from ids2), (select rel from ids2)));
select pg_temp.check('F1 expected funding = 870 (900 advance - 30 fee)', (select expected_funding_amount = 870 from public.factored_invoices where id = pg_temp.fi((select inv from ids2))), (select expected_funding_amount::text from public.factored_invoices where id = pg_temp.fi((select inv from ids2))));
select pg_temp.run('F2 pending', format('select public.mark_factored_invoice_pending(%L)', pg_temp.fi((select inv from ids2))));
select pg_temp.run('F3 approve', format('select public.approve_factored_invoice(%L)', pg_temp.fi((select inv from ids2))));
select pg_temp.run('F4 fund $870', format('select public.fund_factored_invoice(%L, 870, null)', pg_temp.fi((select inv from ids2))));
select pg_temp.run('F5 broker paid factor', format('select public.report_customer_payment_to_factor(%L, 1000)', pg_temp.fi((select inv from ids2))));
select pg_temp.run('F6 release full $100 reserve', format('select public.release_factoring_reserve(%L, 100, %L, null)', pg_temp.fi((select inv from ids2)), 'e2e-release-f'));
select pg_temp.run('F7 close', format('select public.close_factored_invoice(%L)', pg_temp.fi((select inv from ids2))));
select pg_temp.check('F7 status = closed', pg_temp.st((select inv from ids2)) = 'closed', pg_temp.st((select inv from ids2)));

-- ======================================================= E. guard rails ===
select pg_temp.run('E1 double-submit same invoice is refused', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv2 from ids), (select rel from ids)), false);
select pg_temp.run('E2a pending (resubmitted invoice)', format('select public.mark_factored_invoice_pending(%L)', pg_temp.fi((select inv2 from ids))));
select pg_temp.run('E2b approve', format('select public.approve_factored_invoice(%L)', pg_temp.fi((select inv2 from ids))));
select pg_temp.run('E2 funding more than the invoice is refused', format('select public.fund_factored_invoice(%L, 5000, null)', pg_temp.fi((select inv2 from ids))), false);
select pg_temp.run('E2c closing before the broker paid is refused', format('select public.close_factored_invoice(%L)', pg_temp.fi((select inv3 from ids))), false);
reset role;

select pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
set role authenticated;
select pg_temp.run('E3 another company cannot submit Org A''s invoice', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv5 from ids), (select rel from ids)), false);
select pg_temp.check('E4 another company cannot even see Org A''s factored invoices', (select count(*) = 0 from public.factored_invoices), (select count(*)::text from public.factored_invoices));
reset role;

select pg_temp.as_user('cccccccc-0000-0000-0000-00000000000c');
set role authenticated;
select pg_temp.run('E5 dispatcher can submit (same role tier as the app)', format('select * from public.submit_invoice_to_factor(%L, %L)', (select inv5 from ids), (select rel from ids)));
reset role;

-- ============================================================== report ====
\echo
\echo ==================== FACTORING LIFECYCLE AUTOPILOT ====================
select n as "#", case when ok then 'PASS' else 'FAIL' end as result, step, coalesce(detail, '') as detail from pg_temp.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from pg_temp.results;
do $$ begin
  if exists (select 1 from pg_temp.results where not ok) then
    raise exception 'FACTORING LIFECYCLE: % step(s) failed', (select count(*) from pg_temp.results where not ok);
  end if;
end $$;
\echo ALL FACTORING LIFECYCLE STEPS PASSED
