-- fixture_carrier_invoices.sql -- SYNTHETIC carrier invoices for the 0157 tests (NOT A MIGRATION). Applied after 0154/fixture_scenario.sql + fixture_submission.sql on the disposable local cluster only.
-- Org A carrier A1 is 'factored' with an active default relationship (fe000000-...03) and an eligible broker; carrier A2 is unconfigured; org B has carrier B1.
set session_replication_role = replica;
update public.carriers set invoice_code = upper('T' || substr(id::text, 1, 3)) where invoice_code is null;
insert into public.carrier_invoices (id, organization_id, invoice_document_type, issuance_status, payment_status, carrier_id, recipient_type, recipient_broker_id, currency, payment_terms_days, due_date, subtotal_amount, tax_amount, adjustments_amount, total_amount, amount_paid, invoice_number, issued_at, issued_by, voided_at, voided_by, void_reason)
select ('c1000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, org, doc::public.invoice_document_type, iss::public.invoice_issuance_status, pay::public.invoice_payment_status, car, case when doc = 'carrier_freight_invoice' then 'broker' else null end::public.invoice_recipient_type,
       case when doc = 'carrier_freight_invoice' then brk else null end, 'USD', 30, current_date + 30, total, 0, 0, total, paid, case when iss in ('issued', 'voided') then 'CI-' || lpad(n::text, 4, '0') else null end,
       case when iss in ('issued', 'voided') then now() else null end, case when iss in ('issued', 'voided') then 'aaaa0000-0000-0000-0000-000000000001'::uuid else null end,
       case when iss = 'voided' then now() else null end, case when iss = 'voided' then 'aaaa0000-0000-0000-0000-000000000001'::uuid else null end, case when iss = 'voided' then 'test void' else null end
from (values
  (1,  '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 2000.00, 0.00),   -- ELIGIBLE
  (2,  '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1500.00, 0.00),   -- eligible (second)
  (3,  '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'draft',           'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 900.00, 0.00),
  (4,  '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'ready_for_issue', 'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 900.00, 0.00),
  (5,  '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'partially_paid', 'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 900.00, 300.00),
  (6,  '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'paid',           'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 900.00, 900.00),
  (7,  '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'voided',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 900.00, 0.00),
  (8,  '11111111-1111-1111-1111-111111111111'::uuid, 'dispatch_service_invoice', 'issued',         'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, null,                                          400.00, 0.00),   -- dispatch-service fee invoice
  (9,  '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1100.00, 0.00),  -- carries a dispatch-fee line
  (10, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1200.00, 0.00),  -- issued while the carrier was direct billing
  (11, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a2a2a2a2-0000-0000-0000-000000000002'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 800.00, 0.00),    -- carrier A2 (unconfigured)
  (12, '22222222-2222-2222-2222-222222222222'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'b1b1b1b1-0000-0000-0000-000000000001'::uuid, 'b0b00000-0000-0000-0000-000000000001'::uuid, 700.00, 0.00),    -- other organization
  (13, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 640.00, 0.00),    -- snapshot total differs from the invoice
  (14, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 500.00, 0.00),    -- no issuance snapshot
  (15, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 600.00, 0.00),
  (16, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00),
  (17, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00),
  (18, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00),
  (19, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00),
  (20, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00),
  (21, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00),
  (22, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00),
  (23, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00),
  (24, '11111111-1111-1111-1111-111111111111'::uuid, 'carrier_freight_invoice', 'issued',          'unpaid',         'a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'a0b00000-0000-0000-0000-000000000001'::uuid, 1000.00, 0.00)     -- 15 issued outside the controlled workflow: no issuance-terms record; 16-24 spare eligible invoices for the drift tests
) v(n, org, doc, iss, pay, car, brk, total, paid);
insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, sort_order)
select ci.organization_id, ci.id, 'Freight ' || coalesce(ci.invoice_number, 'draft'), 1, ci.total_amount - case when ci.id = 'c1000000-0000-0000-0000-000000000009' then 100 else 0 end, 'freight_charge', 1 from public.carrier_invoices ci where ci.invoice_document_type = 'carrier_freight_invoice';
insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, sort_order)
values ('11111111-1111-1111-1111-111111111111', 'c1000000-0000-0000-0000-000000000009', 'Dispatch service fee (must never be factored)', 1, 100, 'dispatch_service_fee', 2);
insert into public.carrier_invoice_issuance_snapshots (invoice_id, organization_id, invoice_document_type, issuance_schema_version, issued_at, issued_by, currency, invoice_number, payment_terms_days, due_date, subtotal_amount, tax_amount, adjustments_amount, total_amount, amount_due_at_issuance, carrier_id, recipient_broker_id, snapshot_payload)
select ci.id, ci.organization_id, ci.invoice_document_type, 1, ci.issued_at, ci.issued_by, ci.currency, ci.invoice_number, 30, ci.due_date, ci.total_amount, 0, 0, case when ci.id = 'c1000000-0000-0000-0000-000000000013' then ci.total_amount + 1 else ci.total_amount end, ci.total_amount, ci.carrier_id, ci.recipient_broker_id,
       jsonb_build_object('factoring', case when ci.id = 'c1000000-0000-0000-0000-000000000010' or ci.carrier_id <> 'a1a1a1a1-0000-0000-0000-000000000001' then jsonb_build_object('mode', 'direct')
                                            else public._cif_freeze_0157('fe000000-0000-0000-0000-000000000003') || jsonb_build_object('mode', 'factored', 'company', jsonb_build_object('id', 'f0000000-0000-0000-0000-00000000000a'), 'remittance_instructions', 'Remit to FactorA lockbox',
                                                 'noa', jsonb_build_object('approved', true, 'reference', 'NOA-1', 'document_id', null), 'submission', jsonb_build_object('method', 'internal_queue', 'destination', null)) end)
from public.carrier_invoices ci where ci.issuance_status in ('issued', 'voided') and ci.id <> 'c1000000-0000-0000-0000-000000000014';
-- issuance-terms records (written by the controlled issuance workflow in production); invoice 15 deliberately has none. The frozen facts are derived from the relationship exactly as the workflow does.
insert into public.carrier_invoice_issuance_terms_0157 (invoice_id, organization_id, carrier_id, factoring_mode, recipient_type, recipient_broker_id, frozen, frozen_fingerprint, issuance_snapshot_id, issued_by, idempotency_key)
select ci.id, ci.organization_id, ci.carrier_id, case when (s.snapshot_payload -> 'factoring' ->> 'mode') = 'factored' then 'factored' else 'direct_billing' end, 'broker', ci.recipient_broker_id, f.fz,
       encode(sha256(convert_to(f.fz::text, 'UTF8')), 'hex'), s.id, 'aaaa0000-0000-0000-0000-000000000001', 'fixture-terms-' || ci.id::text
from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id = ci.id
cross join lateral (select case when (s.snapshot_payload -> 'factoring' ->> 'mode') = 'factored' then public._cif_freeze_0157('fe000000-0000-0000-0000-000000000003') else '{}'::jsonb end as fz) f
where ci.invoice_document_type = 'carrier_freight_invoice' and ci.issuance_status = 'issued' and ci.id <> 'c1000000-0000-0000-0000-000000000015';
set session_replication_role = origin;
-- D-57h: both dispatcher identities must be refused submission, with or without a grant.
-- Grants used by the suite authorize preview/preparation only; owner/admin are pilot operators.
-- extra identities for the authorization matrix: a second admin and a second dispatcher in organization A
set session_replication_role = replica;
insert into auth.users (id) values ('aaaa0000-0000-0000-0000-000000000002'), ('dddd0000-0000-0000-0000-000000000002') on conflict do nothing;
insert into public.profiles (id, organization_id, full_name, email, role) values
  ('aaaa0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Ada Admin', 'admin2@example.invalid', 'admin'),
  ('dddd0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Dan Dispatcher', 'disp2@example.invalid', 'dispatcher') on conflict do nothing;
set session_replication_role = origin;
