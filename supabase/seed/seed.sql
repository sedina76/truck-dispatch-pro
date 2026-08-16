-- =============================================================================
-- seed.sql
-- Local/dev demo data for one tenant organization ("Northbound Logistics").
-- Run with: supabase db reset   (applies migrations, then this seed)
--
-- NOTE on auth.users: in a real deployment, users are created via Supabase
-- Auth (signup, invite, or the Admin API), which fires handle_new_user()
-- and auto-creates the matching public.profiles row. Directly inserting
-- into auth.users below is a local-dev-only convenience so this seed file
-- can run standalone against `supabase start`. Do not do this against a
-- hosted/production project.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Fixed UUIDs for readability/cross-referencing throughout this file.
-- ---------------------------------------------------------------------------
-- Organization
--   11111111-0000-0000-0000-000000000001  Northbound Logistics
-- Users
--   11111111-0000-0000-0000-0000000000a1  Alice Owens (owner)
--   11111111-0000-0000-0000-0000000000a2  Dan Ortiz (dispatcher)
--   11111111-0000-0000-0000-0000000000a3  Priya Shah (accountant)

-- ---------------------------------------------------------------------------
-- Auth users (local dev only -- see NOTE above)
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('11111111-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'alice@northbound.demo', crypt('password123', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{"full_name":"Alice Owens"}', now(), now()),
  ('11111111-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dan@northbound.demo', crypt('password123', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{"full_name":"Dan Ortiz"}', now(), now()),
  ('11111111-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'priya@northbound.demo', crypt('password123', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{"full_name":"Priya Shah"}', now(), now())
on conflict (id) do nothing;
-- Each insert above fires handle_new_user(), creating a matching
-- public.profiles row (role defaults to 'dispatcher'; corrected below).

-- ---------------------------------------------------------------------------
-- Subscription plan catalog (global)
-- ---------------------------------------------------------------------------
insert into public.subscription_plans (id, tier, name, description, monthly_price_cents, annual_price_cents, max_users, max_trucks, max_active_loads, features)
values
  ('22222222-0000-0000-0000-000000000001', 'starter', 'Starter', 'For owner-operators and small fleets getting started.', 4900, 49000, 3, 10, 25,
    '["Load & dispatch tracking","Basic invoicing","Email support"]'::jsonb),
  ('22222222-0000-0000-0000-000000000002', 'professional', 'Professional', 'For growing dispatch operations with multiple carriers.', 14900, 149000, 15, 75, 250,
    '["Everything in Starter","Settlements & compliance tracking","QuickBooks & Stripe integrations","Priority support"]'::jsonb),
  ('22222222-0000-0000-0000-000000000003', 'enterprise', 'Enterprise', 'For high-volume dispatch companies needing full integration coverage.', 39900, 399000, null, null, null,
    '["Everything in Professional","DAT/Truckstop/123Loadboard integrations","Telematics (Motive, Samsara)","RMIS/Highway/Carrier411 monitoring","Dedicated support"]'::jsonb)
on conflict (tier) do nothing;

-- ---------------------------------------------------------------------------
-- Organization + subscription
-- ---------------------------------------------------------------------------
insert into public.organizations (id, name, slug, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone)
values ('11111111-0000-0000-0000-000000000001', 'Northbound Logistics', 'northbound-logistics', 'MC-778812', 'DOT-2934821', '312-555-0142', 'ops@northbound.demo', '4820 Freight Way', 'Chicago', 'IL', '60607', 'America/Chicago')
on conflict (id) do nothing;

insert into public.organization_subscriptions (organization_id, plan_id, status, billing_cycle, current_period_start, current_period_end)
values ('11111111-0000-0000-0000-000000000001', '22222222-0000-0000-0000-000000000002', 'active', 'monthly', date_trunc('month', now()), date_trunc('month', now()) + interval '1 month')
on conflict do nothing;

-- Correct the auto-created profiles (organization + role + a couple of fields)
update public.profiles set organization_id = '11111111-0000-0000-0000-000000000001', role = 'owner', phone = '312-555-0101'
  where id = '11111111-0000-0000-0000-0000000000a1';
update public.profiles set organization_id = '11111111-0000-0000-0000-000000000001', role = 'dispatcher', phone = '312-555-0102'
  where id = '11111111-0000-0000-0000-0000000000a2';
update public.profiles set organization_id = '11111111-0000-0000-0000-000000000001', role = 'accountant', phone = '312-555-0103'
  where id = '11111111-0000-0000-0000-0000000000a3';

-- ---------------------------------------------------------------------------
-- Carriers, brokers, customers
-- ---------------------------------------------------------------------------
insert into public.carriers (id, organization_id, legal_name, dba_name, mc_number, dot_number, contact_name, phone, email, city, state, dispatch_fee_percentage, payment_terms_days, onboarded_at)
values
  ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', 'Ortiz Trucking LLC', 'Ortiz Trucking', 'MC-551209', 'DOT-1928374', 'Marco Ortiz', '773-555-0110', 'marco@ortiztrucking.demo', 'Cicero', 'IL', 8.00, 7, current_date - interval '9 months'),
  ('33333333-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001', 'Silver Line Freight Inc', 'Silver Line', 'MC-604488', 'DOT-2093184', 'Elena Cruz', '414-555-0177', 'elena@silverlinefreight.demo', 'Milwaukee', 'WI', 10.00, 7, current_date - interval '4 months')
on conflict do nothing;

insert into public.brokers (id, organization_id, company_name, mc_number, contact_name, phone, email, city, state, payment_terms_days, average_days_to_pay)
values
  ('44444444-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', 'Coyote Logistics', 'MC-198221', 'Ryan Blake', '312-555-0900', 'ryan.blake@coyotedemo.com', 'Chicago', 'IL', 30, 27.5),
  ('44444444-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001', 'TQL Freight Brokerage', 'MC-204931', 'Sam Whitfield', '513-555-0800', 'sam.whitfield@tqldemo.com', 'Cincinnati', 'OH', 30, 33.0)
on conflict do nothing;

insert into public.customers (id, organization_id, company_name, contact_name, phone, email, city, state, payment_terms_days)
values ('55555555-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', 'Midwest Building Supply', 'Karen Voss', '630-555-0455', 'karen@midwestbuilding.demo', 'Aurora', 'IL', 30)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Drivers, trucks, trailers, current assignments
-- ---------------------------------------------------------------------------
insert into public.drivers (id, organization_id, carrier_id, first_name, last_name, phone, email, cdl_number, cdl_state, cdl_expiry_date, medical_card_expiry_date, hire_date, status, pay_type, pay_rate)
values
  ('66666666-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', 'Luis', 'Ramirez', '773-555-0201', 'luis.ramirez@ortiztrucking.demo', 'IL-CDL-88213', 'IL', current_date + interval '5 months', current_date + interval '10 months', current_date - interval '8 months', 'active', 'per_mile', 0.62),
  ('66666666-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', 'Tasha', 'Boone', '773-555-0202', 'tasha.boone@ortiztrucking.demo', 'IL-CDL-77104', 'IL', current_date + interval '20 days', current_date + interval '2 months', current_date - interval '3 months', 'active', 'per_mile', 0.60),
  ('66666666-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000002', 'Gregor', 'Novak', '414-555-0303', 'gregor.novak@silverlinefreight.demo', 'WI-CDL-44991', 'WI', current_date - interval '10 days', current_date + interval '6 months', current_date - interval '14 months', 'active', 'percentage', 75.00)
on conflict do nothing;

insert into public.trucks (id, organization_id, carrier_id, unit_number, vin, make, model, year, license_plate, license_state, ownership_type, status, current_odometer, registration_expiry_date, annual_inspection_expiry_date, ifta_sticker_expiry_date)
values
  ('77777777-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', 'T-101', '1FUJGLDR8NLAA1001', 'Freightliner', 'Cascadia', 2021, 'IL-TRK101', 'IL', 'owned', 'active', 214300, current_date + interval '4 months', current_date + interval '2 months', current_date + interval '5 months'),
  ('77777777-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', 'T-102', '1FUJGLDR8NLAA1002', 'Peterbilt', '579', 2020, 'IL-TRK102', 'IL', 'leased', 'active', 301880, current_date + interval '7 months', current_date + interval '20 days', current_date + interval '5 months'),
  ('77777777-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000002', 'SL-01', '1XKAD49X1LJ123003', 'Kenworth', 'T680', 2022, 'WI-TRK001', 'WI', 'owner_operator', 'active', 98220, current_date + interval '9 months', current_date + interval '3 months', current_date + interval '5 months')
on conflict do nothing;

insert into public.trailers (id, organization_id, carrier_id, unit_number, trailer_type, length_ft, license_plate, license_state, ownership_type, status, registration_expiry_date, annual_inspection_expiry_date)
values
  ('88888888-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', 'TR-201', 'dry_van', 53, 'IL-TRL201', 'IL', 'owned', 'active', current_date + interval '6 months', current_date + interval '3 months'),
  ('88888888-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000002', 'SLT-01', 'reefer', 53, 'WI-TRL001', 'WI', 'leased', 'active', current_date + interval '8 months', current_date + interval '4 months')
on conflict do nothing;

insert into public.truck_driver_assignments (organization_id, truck_id, driver_id, assigned_at, is_current)
values
  ('11111111-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', '66666666-0000-0000-0000-000000000001', now() - interval '3 months', true),
  ('11111111-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000002', '66666666-0000-0000-0000-000000000002', now() - interval '2 months', true),
  ('11111111-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000003', '66666666-0000-0000-0000-000000000003', now() - interval '1 month', true)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Loads, stops, dispatches
-- ---------------------------------------------------------------------------
insert into public.loads (id, organization_id, load_number, broker_id, customer_id, status, commodity, weight_lbs, equipment_type, total_miles, rate, rate_confirmation_number, booked_by)
values
  ('99999999-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', 'LD-100001', '44444444-0000-0000-0000-000000000001', null, 'delivered', 'Packaged Foods', 42000, 'dry_van', 287.5, 1150.00, 'RC-778812-01', '11111111-0000-0000-0000-0000000000a2'),
  ('99999999-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001', 'LD-100002', '44444444-0000-0000-0000-000000000002', null, 'in_transit', 'Frozen Goods', 38500, 'reefer', 512.0, 1875.00, 'RC-778812-02', '11111111-0000-0000-0000-0000000000a2'),
  ('99999999-0000-0000-0000-000000000003', '11111111-0000-0000-0000-000000000001', 'LD-100003', null, '55555555-0000-0000-0000-000000000001', 'booked', 'Lumber', 44000, 'flatbed', 96.0, 620.00, null, '11111111-0000-0000-0000-0000000000a2')
on conflict do nothing;

insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at, arrived_at, departed_at)
values
  ('11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001', 'pickup', 1, 'ConAgra DC', 'Chicago', 'IL', now() - interval '4 days', now() - interval '4 days', now() - interval '4 days' + interval '1 hour'),
  ('11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001', 'delivery', 2, 'Kroger DC', 'Indianapolis', 'IN', now() - interval '3 days', now() - interval '3 days', now() - interval '3 days' + interval '45 minutes'),
  ('11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000002', 'pickup', 1, 'Tyson Foods Plant', 'Joliet', 'IL', now() - interval '1 day', now() - interval '1 day', now() - interval '1 day' + interval '90 minutes'),
  ('11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000002', 'delivery', 2, 'Sysco DC', 'Cincinnati', 'OH', now() + interval '1 day', null, null),
  ('11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000003', 'pickup', 1, '84 Lumber Yard', 'Aurora', 'IL', now() + interval '2 days', null, null),
  ('11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000003', 'delivery', 2, 'Midwest Building Supply Yard', 'Aurora', 'IL', now() + interval '2 days', null, null)
on conflict do nothing;

insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, trailer_id, status, dispatch_fee_percentage, load_rate, dispatched_by, dispatched_at, completed_at)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', '66666666-0000-0000-0000-000000000001', '88888888-0000-0000-0000-000000000001', 'completed', 8.00, 1150.00, '11111111-0000-0000-0000-0000000000a2', now() - interval '5 days', now() - interval '3 days'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000002', '33333333-0000-0000-0000-000000000002', '77777777-0000-0000-0000-000000000003', '66666666-0000-0000-0000-000000000003', '88888888-0000-0000-0000-000000000002', 'en_route_to_delivery', 10.00, 1875.00, '11111111-0000-0000-0000-0000000000a2', now() - interval '1 day', null)
on conflict do nothing;

insert into public.load_tracking_events (organization_id, load_id, dispatch_id, status, location_description, source, reported_by, occurred_at)
values
  ('11111111-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002', 'in_transit', 'I-65 near Lafayette, IN', 'dispatcher', '11111111-0000-0000-0000-0000000000a2', now() - interval '6 hours')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Documents & compliance
-- ---------------------------------------------------------------------------
insert into public.documents (organization_id, entity_type, entity_id, document_type, file_name, file_path, issued_date, expiry_date, is_verified, uploaded_by)
values
  ('11111111-0000-0000-0000-000000000001', 'driver', '66666666-0000-0000-0000-000000000002', 'cdl', 'boone_cdl.pdf', 'org-11111111/drivers/66666666-0000-0000-0000-000000000002/cdl.pdf', current_date - interval '4 years', current_date + interval '20 days', true, '11111111-0000-0000-0000-0000000000a2'),
  ('11111111-0000-0000-0000-000000000001', 'carrier', '33333333-0000-0000-0000-000000000001', 'insurance_certificate', 'ortiz_coi_2026.pdf', 'org-11111111/carriers/33333333-0000-0000-0000-000000000001/coi.pdf', current_date - interval '2 months', current_date + interval '10 months', true, '11111111-0000-0000-0000-0000000000a1'),
  ('11111111-0000-0000-0000-000000000001', 'load', '99999999-0000-0000-0000-000000000001', 'rate_confirmation', 'ld-100001-ratecon.pdf', 'org-11111111/loads/99999999-0000-0000-0000-000000000001/ratecon.pdf', current_date - interval '5 days', null, true, '11111111-0000-0000-0000-0000000000a2'),
  ('11111111-0000-0000-0000-000000000001', 'load', '99999999-0000-0000-0000-000000000001', 'pod', 'ld-100001-pod.pdf', 'org-11111111/loads/99999999-0000-0000-0000-000000000001/pod.pdf', current_date - interval '3 days', null, true, '11111111-0000-0000-0000-0000000000a2')
on conflict do nothing;

insert into public.compliance_items (organization_id, entity_type, entity_id, item_type, expiry_date, status)
values
  ('11111111-0000-0000-0000-000000000001', 'driver', '66666666-0000-0000-0000-000000000002', 'cdl_expiry', current_date + interval '20 days', 'expiring_soon'),
  ('11111111-0000-0000-0000-000000000001', 'driver', '66666666-0000-0000-0000-000000000003', 'cdl_expiry', current_date - interval '10 days', 'expired'),
  ('11111111-0000-0000-0000-000000000001', 'carrier', '33333333-0000-0000-0000-000000000001', 'insurance_expiry', current_date + interval '10 months', 'valid'),
  ('11111111-0000-0000-0000-000000000001', 'truck', '77777777-0000-0000-0000-000000000002', 'annual_inspection', current_date + interval '20 days', 'expiring_soon')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Invoices, line items, payments
-- ---------------------------------------------------------------------------
insert into public.invoices (id, organization_id, invoice_number, dispatch_id, load_id, broker_id, status, bill_to_name, bill_to_email, issue_date, due_date, created_by)
values ('bbbbbbbb-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', 'INV-000001', 'aaaaaaaa-0000-0000-0000-000000000001', '99999999-0000-0000-0000-000000000001', '44444444-0000-0000-0000-000000000001', 'sent', 'Coyote Logistics', 'ap@coyotedemo.com', current_date - interval '3 days', current_date + interval '27 days', '11111111-0000-0000-0000-0000000000a3')
on conflict do nothing;

insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
values ('11111111-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Linehaul - LD-100001 (Chicago, IL -> Indianapolis, IN)', 1, 1150.00, 1)
on conflict do nothing;

insert into public.payments (organization_id, invoice_id, amount, method, reference_number, received_at, recorded_by)
values ('11111111-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 500.00, 'ach', 'ACH-88213', now() - interval '1 day', '11111111-0000-0000-0000-0000000000a3')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Settlements
-- ---------------------------------------------------------------------------
insert into public.settlements (id, organization_id, settlement_number, carrier_id, dispatch_id, driver_id, status, period_start, period_end, payment_method)
values ('cccccccc-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001', 'STL-000001', '33333333-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', '66666666-0000-0000-0000-000000000001', 'approved', current_date - interval '7 days', current_date, 'ach')
on conflict do nothing;

insert into public.settlement_line_items (organization_id, settlement_id, description, item_type, amount, sort_order)
values
  ('11111111-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'Carrier net pay - LD-100001', 'earning', 1058.00, 1),
  ('11111111-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'Fuel advance recoupment', 'deduction', 75.00, 2)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Expenses, fuel, maintenance
-- ---------------------------------------------------------------------------
insert into public.expenses (organization_id, carrier_id, truck_id, driver_id, category, amount, expense_date, vendor_name, description, recorded_by)
values ('11111111-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', '66666666-0000-0000-0000-000000000001', 'tolls', 42.75, current_date - interval '4 days', 'Illinois Tollway', 'I-Pass tolls, LD-100001', '11111111-0000-0000-0000-0000000000a2')
on conflict do nothing;

insert into public.fuel_logs (organization_id, truck_id, driver_id, gallons, price_per_gallon, total_amount, odometer_reading, state, station_name, purchased_at)
values ('11111111-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', '66666666-0000-0000-0000-000000000001', 128.4, 3.899, 500.60, 214300, 'IN', 'Pilot Flying J #412', now() - interval '4 days')
on conflict do nothing;

insert into public.maintenance_records (organization_id, truck_id, service_type, description, cost, odometer_reading, vendor_name, service_date, next_service_due_date, next_service_due_odometer, recorded_by)
values ('11111111-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000002', 'Oil & Filter Change', 'Full synthetic oil change, replaced fuel filters', 385.00, 301880, 'TA Truck Service', current_date - interval '10 days', current_date + interval '80 days', 316880, '11111111-0000-0000-0000-0000000000a2')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Tasks & notes
-- ---------------------------------------------------------------------------
insert into public.tasks (organization_id, entity_type, entity_id, title, description, status, priority, due_at, assigned_to, created_by)
values ('11111111-0000-0000-0000-000000000001', 'driver', '66666666-0000-0000-0000-000000000002', 'Collect renewed CDL from Tasha Boone', 'CDL expires in 20 days -- request updated copy before next dispatch.', 'open', 'high', now() + interval '5 days', '11111111-0000-0000-0000-0000000000a2', '11111111-0000-0000-0000-0000000000a1')
on conflict do nothing;

insert into public.notes (organization_id, entity_type, entity_id, body, created_by)
values ('11111111-0000-0000-0000-000000000001', 'carrier', '33333333-0000-0000-0000-000000000002', 'Silver Line prefers 24hr notice for reefer loads out of Milwaukee.', '11111111-0000-0000-0000-0000000000a2')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Integration settings (disabled placeholders, no real credentials)
-- ---------------------------------------------------------------------------
insert into public.integration_settings (organization_id, provider, is_enabled, config)
values
  ('11111111-0000-0000-0000-000000000001', 'quickbooks', false, '{}'::jsonb),
  ('11111111-0000-0000-0000-000000000001', 'stripe', true, '{"mode":"test"}'::jsonb),
  ('11111111-0000-0000-0000-000000000001', 'dat', false, '{}'::jsonb)
on conflict do nothing;
