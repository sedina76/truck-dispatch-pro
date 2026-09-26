-- fixture_issuance.sql -- SYNTHETIC records for the 0157 issuance-workflow tests (NOT A MIGRATION). Applied after fixture_carrier_invoices.sql on the disposable local cluster only.
-- Org A: carrier A1 (factored, default relationship fe..03, broker 1 eligible), carrier A2 (unconfigured), carrier A6 (direct billing), broker 2 (NOT factoring-eligible for A1). Org B: carrier B1 + one load.
set session_replication_role = replica;
insert into public.carriers (id, organization_id, legal_name, is_active, factoring_mode, invoice_code) values ('a6a6a6a6-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'Carrier AD Direct LLC', true, 'direct', 'A6X') on conflict do nothing;
insert into public.carrier_remittance_profiles (organization_id, carrier_id, remittance_name, remittance_instructions) select '11111111-1111-1111-1111-111111111111', 'a6a6a6a6-0000-0000-0000-000000000006', 'A6 remit', 'Pay A6 directly' where not exists (select 1 from public.carrier_remittance_profiles where carrier_id = 'a6a6a6a6-0000-0000-0000-000000000006');
insert into public.brokers (id, organization_id, company_name) values ('a0b00000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Broker Two (not factoring-eligible)') on conflict do nothing;
insert into public.carrier_brokers (organization_id, carrier_id, broker_id, status, factoring_eligible, billing_email, payment_terms_days)
  values ('11111111-1111-1111-1111-111111111111', 'a6a6a6a6-0000-0000-0000-000000000006', 'a0b00000-0000-0000-0000-000000000001', 'active', false, 'ap@example.invalid', 30),
         ('11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000002', 'active', false, 'ap2@example.invalid', 30) on conflict do nothing;
-- loads: 1-6 A1/broker1 delivered (1000,500,300,200,400,600); 7 booked; 8 rate 0; 9 broker2; 10 carrier A2; 11 no carrier; 12-16 A3 (700 each); 20-49 A1 spare (300 each); 50 org B
insert into public.loads (id, organization_id, load_number, status, broker_id, carrier_id, carrier_resolution)
select ('10ad2000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, org, 'W-' || n, st::public.load_status, brk, car, case when car is null then null else 'resolved' end
from (values
  (1, '11111111-1111-1111-1111-111111111111'::uuid, 'delivered', 'a0b00000-0000-0000-0000-000000000001'::uuid, 'a1a1a1a1-0000-0000-0000-000000000001'::uuid),
  (2, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001'),
  (3, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001'),
  (4, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001'),
  (5, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001'),
  (6, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001'),
  (7, '11111111-1111-1111-1111-111111111111', 'booked',    'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001'),
  (8, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001'),
  (9, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000002', 'a1a1a1a1-0000-0000-0000-000000000001'),
  (10, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002'),
  (11, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', null),
  (12, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a6a6a6a6-0000-0000-0000-000000000006'),
  (13, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a6a6a6a6-0000-0000-0000-000000000006'),
  (14, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a6a6a6a6-0000-0000-0000-000000000006'),
  (15, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a6a6a6a6-0000-0000-0000-000000000006'),
  (16, '11111111-1111-1111-1111-111111111111', 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a6a6a6a6-0000-0000-0000-000000000006'),
  (50, '22222222-2222-2222-2222-222222222222', 'delivered', 'b0b00000-0000-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000001')) v(n, org, st, brk, car);
insert into public.loads (id, organization_id, load_number, status, broker_id, carrier_id, carrier_resolution)
select ('10ad2000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid, '11111111-1111-1111-1111-111111111111', 'W-' || n, 'delivered', 'a0b00000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved' from generate_series(20, 49) n;
insert into public.load_financials (load_id, organization_id, rate)
select l.id, l.organization_id, case (substr(l.load_number, 3))::int when 1 then 1000 when 2 then 500 when 3 then 300 when 4 then 200 when 5 then 400 when 6 then 600 when 7 then 300 when 8 then 0 when 9 then 250 when 10 then 100 when 11 then 100 when 50 then 800 else case when (substr(l.load_number, 3))::int between 12 and 16 then 700 else 300 end end
from public.loads l where l.id::text like '10ad2000-%';
insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state)
select l.organization_id, l.id, t.st::public.stop_type, t.sq, 'Facility', 'Dallas', 'TX' from public.loads l cross join (values ('pickup', 1), ('delivery', 2)) t(st, sq) where l.id::text like '10ad2000-%';
-- an approved, currently effective dispatch-service agreement for carrier A1 only (10 percent of freight) -- a SEPARATE receivable
insert into public.carrier_dispatch_service_agreements (id, organization_id, carrier_id, agreement_number, status) values ('a9000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'AGR-A1', 'active');
insert into public.carrier_dispatch_service_agreement_versions (id, agreement_id, organization_id, carrier_id, version_number, status, fee_method, percentage_rate, currency, effective_from, approved_by, approved_at, reason)
  values ('a9000000-0000-0000-0000-000000000002', 'a9000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 1, 'approved', 'percentage_of_freight', 10, 'USD', current_date - 30, 'aaaa0000-0000-0000-0000-000000000001', now(), 'synthetic');
update public.carrier_dispatch_service_agreements set current_version_id = 'a9000000-0000-0000-0000-000000000002' where id = 'a9000000-0000-0000-0000-000000000001';
set session_replication_role = origin;
