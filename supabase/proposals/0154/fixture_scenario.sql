-- fixture_scenario.sql -- SYNTHETIC scenario for the tests of proposals 0154-0156 (NOT A MIGRATION). Run only on the disposable local cluster.
set session_replication_role = replica;
alter table public.factoring_relationships drop constraint factoring_relationships_new_writes_need_carrier;
insert into public.organizations (id, name, slug) values ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Org C (sole inactive carrier)', 'org-c') on conflict do nothing;
insert into public.carriers (id, organization_id, legal_name, is_active) values ('c1c1c1c1-0000-0000-0000-000000000001', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'Carrier C1 inactive', false) on conflict do nothing;
insert into public.factoring_companies (id, organization_id, name, is_active) values
  ('f0000000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'FactorA', true), ('f0000000-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'FactorB', true),
  ('f0000000-0000-0000-0000-00000000000c', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'FactorC', true);
-- loads/dispatches (org A) for invoices
insert into public.loads (id, organization_id, load_number, status) values
  ('10ad0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'S-1', 'booked'), ('10ad0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'S-2', 'booked'),
  ('10ad0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'S-3', 'booked'), ('10ad0000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'S-4', 'booked'),
  ('10ad0000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'S-5', 'booked');
insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status) values
  ('d15a0000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'delivered'),
  ('d15a0000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000002', 'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'delivered'),
  ('d15a0000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000003', 'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'delivered'),
  ('d15a0000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000004', 'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'delivered'),
  ('d15a0000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000005', 'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'cancelled');
insert into public.invoices (id, organization_id, load_id, dispatch_id, broker_id, status, total_amount, amount_paid, invoice_number) values
  ('1a000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000001', 'd15a0000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'sent', 1000, 0, 'S-INV-1'),
  ('1a000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000002', 'd15a0000-0000-0000-0000-000000000002', 'a0b00000-0000-0000-0000-000000000001', 'sent', 1000, 0, 'S-INV-2'),
  ('1a000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000003', 'd15a0000-0000-0000-0000-000000000003', 'a0b00000-0000-0000-0000-000000000001', 'sent', 1000, 0, 'S-INV-3'),
  ('1a000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000004', 'd15a0000-0000-0000-0000-000000000004', 'a0b00000-0000-0000-0000-000000000001', 'sent', 1000, 0, 'S-INV-4'),
  ('1a000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', null, null, 'a0b00000-0000-0000-0000-000000000001', 'sent', 1000, 0, 'S-INV-5-no-evidence'),
  ('1a000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', '10ad0000-0000-0000-0000-000000000005', 'd15a0000-0000-0000-0000-000000000005', 'a0b00000-0000-0000-0000-000000000001', 'sent', 1000, 0, 'S-INV-6-cancelled-dispatch');
insert into public.factoring_relationships (id, organization_id, factoring_company_id, relationship_name, carrier_id, is_active, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type) values
  ('fe000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'f0000000-0000-0000-0000-00000000000b', 'R-sole-active-org-B', 'b1b1b1b1-0000-0000-0000-000000000001', true, 80, 3, 20, 'deducted_at_funding', 'recourse'),      -- supported (L2)
  ('fe000000-0000-0000-0000-000000000002', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'f0000000-0000-0000-0000-00000000000c', 'R-sole-inactive-org-C', 'c1c1c1c1-0000-0000-0000-000000000001', true, 80, 3, 20, 'deducted_at_funding', 'recourse'), -- unsafe (F-02)
  ('fe000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'f0000000-0000-0000-0000-00000000000a', 'R-all-invoices-A1', 'a1a1a1a1-0000-0000-0000-000000000001', true, 80, 3, 20, 'deducted_at_funding', 'recourse'),   -- supported (L1)
  ('fe000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'f0000000-0000-0000-0000-00000000000a', 'R-partial-A2', 'a2a2a2a2-0000-0000-0000-000000000002', true, 80, 3, 20, 'deducted_at_funding', 'recourse'),       -- unsafe (F-01 partial)
  ('fe000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'f0000000-0000-0000-0000-00000000000a', 'R-conflict', null, true, 80, 3, 20, 'deducted_at_funding', 'recourse'),                                                  -- ambiguous (A1 vs A2)
  ('fe000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'f0000000-0000-0000-0000-00000000000a', 'R-no-invoices', null, true, 80, 3, 20, 'deducted_at_funding', 'recourse'),                                                -- ambiguous (no evidence, 3 carriers)
  ('fe000000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111', 'f0000000-0000-0000-0000-00000000000a', 'R-assignable-A2', null, true, 80, 3, 20, 'deducted_at_funding', 'recourse'),                                             -- assignable
  ('fe000000-0000-0000-0000-000000000008', '11111111-1111-1111-1111-111111111111', 'f0000000-0000-0000-0000-00000000000a', 'R-cross-org-carrier', 'b1b1b1b1-0000-0000-0000-000000000001', true, 80, 3, 20, 'deducted_at_funding', 'recourse'),      -- refused
  ('fe000000-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111', 'f0000000-0000-0000-0000-00000000000a', 'R-cancelled-dispatch-only', null, true, 80, 3, 20, 'deducted_at_funding', 'recourse');                               -- ambiguous
insert into public.factored_invoices (id, organization_id, invoice_id, factoring_company_id, factoring_relationship_id, status, invoice_face_value, advance_percentage, expected_advance_amount, factoring_fee_percentage, factoring_fee_amount, reserve_percentage, reserve_amount, other_fees, fee_timing, expected_funding_amount)
select ('fa000000-0000-0000-0000-00000000000' || n::text)::uuid, '11111111-1111-1111-1111-111111111111', ('1a000000-0000-0000-0000-00000000000' || inv::text)::uuid, 'f0000000-0000-0000-0000-00000000000a', ('fe000000-0000-0000-0000-00000000000' || rel::text)::uuid, 'submitted', 1000, 80, 800, 3, 30, 20, 200, 0, 'deducted_at_funding', 770
from (values (1, 1, 3), (2, 2, 3), (3, 1, 4), (4, 5, 4), (5, 1, 5), (6, 3, 5), (7, 3, 7), (8, 4, 7), (9, 6, 9)) v(n, inv, rel);
alter table public.factoring_relationships add constraint factoring_relationships_new_writes_need_carrier check (carrier_id is not null) not valid;
set session_replication_role = origin;
