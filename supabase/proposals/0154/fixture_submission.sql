-- fixture_submission.sql -- SYNTHETIC "ready to factor" carrier A1 + extra invoices for the 0156 tests (NOT A MIGRATION). Applied after fixture_scenario.sql on the disposable local cluster only.
set session_replication_role = replica;
update public.carriers set factoring_mode = 'factored' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
insert into public.carrier_brokers (organization_id, carrier_id, broker_id, status, factoring_eligible, billing_email, payment_terms_days)
  values ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', true, 'ap@example.invalid', 30);
update public.factoring_relationships set is_default = true, remittance_instructions = 'Remit to FactorA lockbox', submission_method = 'internal_queue',
       noa_template_text = 'Approved NOA language', noa_reference = 'NOA-1', noa_effective_date = current_date - 30, noa_approved = true,
       noa_approved_by = 'aaaa0000-0000-0000-0000-000000000001', noa_approved_at = now()
 where id = 'fe000000-0000-0000-0000-000000000003';
update public.loads set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002', carrier_resolution = 'resolved' where id = '10ad0000-0000-0000-0000-000000000002';
insert into public.invoices (id, organization_id, load_id, dispatch_id, broker_id, customer_id, status, total_amount, amount_paid, invoice_number) values
  ('1a000000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'd15a0000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', null, 'sent', 1234.56, 0, 'S-INV-7-good'),
  ('1a000000-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'd15a0000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', (select id from public.customers where organization_id = '11111111-1111-1111-1111-111111111111' limit 1), 'sent', 500, 0, 'S-INV-8-both-recipients'),
  ('1a000000-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'd15a0000-0000-0000-0000-000000000001', null, null, 'sent', 500, 0, 'S-INV-9-no-recipient'),
  ('1a000000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', null, null, 'a0b00000-0000-0000-0000-000000000001', null, 'sent', 500, 0, 'S-INV-10-no-evidence'),
  ('1a000000-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000002', 'd15a0000-0000-0000-0000-000000000002', 'a0b00000-0000-0000-0000-000000000001', null, 'sent', 500, 0, 'S-INV-11-conflict-dispatch-A1-load-A2'),
  ('1a000000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000003', 'd15a0000-0000-0000-0000-000000000003', 'a0b00000-0000-0000-0000-000000000001', null, 'sent', 500, 0, 'S-INV-12-proves-A2'),
  ('1a000000-0000-0000-0000-00000000000e', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'd15a0000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', null, 'sent', 700, 0, 'S-INV-14-good-second'),
  ('1a000000-0000-0000-0000-00000000000d', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'd15a0000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', null, 'sent', 500, 250, 'S-INV-13-partially-paid');
insert into public.payments (id, organization_id, invoice_id) values ('9a000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '1a000000-0000-0000-0000-00000000000d');
set session_replication_role = origin;
