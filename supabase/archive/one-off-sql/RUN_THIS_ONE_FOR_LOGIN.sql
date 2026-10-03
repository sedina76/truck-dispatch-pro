-- THIS IS THE ONLY FILE YOU NEED RIGHT NOW.
-- Do not use apply_all.sql for this step -- that one is already done.
-- Copy EVERYTHING in this file and run it in the Supabase SQL Editor.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('11111111-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'alice@northbound.demo', crypt('password123', gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{"full_name":"Alice Owens"}', now(), now())
on conflict (id) do nothing;

insert into public.subscription_plans (id, tier, name, description, monthly_price_cents, annual_price_cents, max_users, max_trucks, max_active_loads, features)
values ('22222222-0000-0000-0000-000000000002', 'professional', 'Professional', 'For growing dispatch operations with multiple carriers.', 14900, 149000, 15, 75, 250,
    '["Everything in Starter","Settlements & compliance tracking","QuickBooks & Stripe integrations","Priority support"]'::jsonb)
on conflict (tier) do nothing;

insert into public.organizations (id, name, slug, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone)
values ('11111111-0000-0000-0000-000000000001', 'Northbound Logistics', 'northbound-logistics', 'MC-778812', 'DOT-2934821', '312-555-0142', 'ops@northbound.demo', '4820 Freight Way', 'Chicago', 'IL', '60607', 'America/Chicago')
on conflict (id) do nothing;

insert into public.organization_subscriptions (organization_id, plan_id, status, billing_cycle, current_period_start, current_period_end)
values ('11111111-0000-0000-0000-000000000001', '22222222-0000-0000-0000-000000000002', 'active', 'monthly', date_trunc('month', now()), date_trunc('month', now()) + interval '1 month')
on conflict do nothing;

update public.profiles set organization_id = '11111111-0000-0000-0000-000000000001', role = 'owner', phone = '312-555-0101'
  where id = '11111111-0000-0000-0000-0000000000a1';

-- After running this, log in with:
--   email: alice@northbound.demo
--   password: password123
