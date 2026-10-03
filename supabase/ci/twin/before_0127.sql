-- Test-only twin shim: production gained a 64th organization (United Leather,
-- a sandbox Checkout fixture with an in-flight Stripe Checkout) before 0127,
-- which 0127 asserts. Recreate it.
insert into public.organizations (id, name, slug)
values ('ca6457e6-8ae8-4e85-adc9-4a0dabb2386e', 'United Leather', 'twin-united-leather');
delete from public.organization_subscriptions where organization_id = 'ca6457e6-8ae8-4e85-adc9-4a0dabb2386e';
insert into public.organization_subscriptions
  (organization_id, plan_id, status, billing_cycle, stripe_customer_id, stripe_checkout_session_id, stripe_checkout_attempt_id)
select 'ca6457e6-8ae8-4e85-adc9-4a0dabb2386e', id, 'incomplete', 'monthly', 'cus_twin', 'cs_twin', gen_random_uuid()
from public.subscription_plans where tier = 'essential';
