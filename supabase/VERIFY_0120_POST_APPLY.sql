-- Run AFTER applying 0120_grandfather_existing_pilot_orgs.sql.
--
-- 100% READ-ONLY. Plain SELECTs only -- no BEGIN/ROLLBACK, no writes, no
-- fixtures. Safe on production. No PII is selected (no emails / phones /
-- addresses / tax ids); no Stripe identifiers are printed (only IS NULL).

-- ============================================================================
-- 1. Exactly 3 organization_subscriptions rows, exactly 3 grandfathered.
-- ============================================================================
select
  (select count(*) from public.organization_subscriptions)                                    as total_rows,
  (select count(*) from public.organization_subscriptions where grandfathered_at is not null) as grandfathered_rows;
-- expect: total_rows = 3, grandfathered_rows = 3.

-- ============================================================================
-- 2. The 3 grandfathered rows are PRECISELY the approved organizations, with
--    the expected plan/status/cycle, and every Stripe field NULL.
-- ============================================================================
select
  o.name                              as organization_name,
  s.organization_id,
  p.tier                              as plan_tier,
  p.name                              as plan_name,
  s.status,
  s.billing_cycle,
  (s.grandfathered_at is not null)    as grandfathered,
  (s.current_period_start is null)    as period_start_is_null,
  (s.current_period_end is null)      as period_end_is_null,
  (s.trial_end is null)               as trial_end_is_null,
  (s.checkout_pending_since is null)  as checkout_pending_since_is_null,
  (s.stripe_customer_id is null)      as stripe_customer_id_is_null,
  (s.stripe_subscription_id is null)  as stripe_subscription_id_is_null,
  (s.stripe_price_id is null)         as stripe_price_id_is_null
from public.organization_subscriptions s
join public.organizations o        on o.id = s.organization_id
left join public.subscription_plans p on p.id = s.plan_id
order by o.created_at;
-- expect exactly 3 rows:
--   Kali Freights LLC | professional | active   | monthly | grandfathered=t | all stripe_*_is_null=t
--   Kali Logistic     | enterprise   | trialing | monthly | grandfathered=t | all stripe_*_is_null=t
--   Kali Freight LLC  | professional | active   | monthly | grandfathered=t |
--        period_start_is_null=t, period_end_is_null=t, trial_end_is_null=t,
--        checkout_pending_since_is_null=t, all stripe_*_is_null=t

-- ============================================================================
-- 2b. STRENGTHENED: the Kali Freight LLC row matches the EXACT
--     0120-created shape, field for field. Every column below must be true.
-- ============================================================================
select
  s.organization_id,
  (s.plan_id = (select id from public.subscription_plans where tier = 'professional' and is_active = true)) as plan_is_active_professional,
  (s.status = 'active')                    as status_is_active,
  (s.billing_cycle = 'monthly')            as cycle_is_monthly,
  (s.grandfathered_at is not null)         as grandfathered_at_set,
  (s.current_period_start is null)         as period_start_null,
  (s.current_period_end is null)           as period_end_null,
  (s.cancel_at_period_end = false)         as cancel_flag_false,
  (s.canceled_at is null)                  as canceled_at_null,
  (s.trial_end is null)                    as trial_end_null,
  (s.checkout_pending_since is null)       as checkout_pending_since_null,
  (s.stripe_customer_id is null)           as stripe_customer_id_null,
  (s.stripe_subscription_id is null)       as stripe_subscription_id_null,
  (s.stripe_price_id is null)              as stripe_price_id_null
from public.organization_subscriptions s
where s.organization_id = '054ef09f-6cfb-461a-aeb2-3ec9fdd62d47'::uuid;
-- expect exactly 1 row, EVERY boolean column = true.

-- ============================================================================
-- 3. Approved-org grandfather assertions (id-anchored -- name-independent).
-- ============================================================================
select
  x.label,
  x.organization_id,
  exists (
    select 1 from public.organization_subscriptions s
    where s.organization_id = x.organization_id and s.grandfathered_at is not null
  ) as is_grandfathered,
  (select count(*) from public.organization_subscriptions s where s.organization_id = x.organization_id) as sub_row_count
from (
  values
    ('Kali Freight LLC',  '054ef09f-6cfb-461a-aeb2-3ec9fdd62d47'::uuid),
    ('Kali Freights LLC', '11111111-0000-0000-0000-000000000001'::uuid),
    ('Kali Logistic',     '1f29315a-e193-481f-bd5f-5f1b40da7f05'::uuid)
) as x(label, organization_id);
-- expect all three is_grandfathered = true, sub_row_count = 1.

-- ============================================================================
-- 4. NO excluded organization was grandfathered.
-- ============================================================================
-- 4a. No TEST-* organization has a subscription row at all.
select count(*) as test_orgs_with_any_subscription
from public.organization_subscriptions s
join public.organizations o on o.id = s.organization_id
where o.name like 'TEST-%' or o.name like 'TEST\_%' escape '\';
-- expect 0.

-- 4b. The three named non-test excludes are NOT grandfathered (and have no
--     subscription row).
select
  o.name,
  o.id as organization_id,
  (select count(*) from public.organization_subscriptions s where s.organization_id = o.id)                                as sub_row_count,
  (select count(*) from public.organization_subscriptions s where s.organization_id = o.id and s.grandfathered_at is not null) as grandfathered_row_count
from public.organizations o
where o.name in ('ASAM''s Group LLC', 'ASAM''s Group LLC.', 'Medfusion')
order by o.name;
-- expect: each -> sub_row_count = 0, grandfathered_row_count = 0.

-- 4c. Belt-and-suspenders: EVERY grandfathered row belongs to one of the 3
--     approved organization ids.
select count(*) as grandfathered_rows_outside_approved_set
from public.organization_subscriptions
where grandfathered_at is not null
  and organization_id not in (
    '054ef09f-6cfb-461a-aeb2-3ec9fdd62d47'::uuid,
    '11111111-0000-0000-0000-000000000001'::uuid,
    '1f29315a-e193-481f-bd5f-5f1b40da7f05'::uuid
  );
-- expect 0.

-- ============================================================================
-- 5. The two pre-existing rows kept their plan / status / cycle / periods.
-- ============================================================================
select
  o.name,
  s.plan_id,
  s.status,
  s.billing_cycle,
  s.current_period_start,
  s.current_period_end,
  s.cancel_at_period_end,
  s.canceled_at
from public.organization_subscriptions s
join public.organizations o on o.id = s.organization_id
where s.organization_id in (
  '11111111-0000-0000-0000-000000000001'::uuid,
  '1f29315a-e193-481f-bd5f-5f1b40da7f05'::uuid
)
order by o.name;
-- expect UNCHANGED from the pre-0120 state:
--   Kali Freights LLC | plan_id = 22222222-0000-0000-0000-000000000002 | active   | monthly
--                     | period 2026-07-01 .. 2026-08-01 | cancel_at_period_end=f | canceled_at=null
--   Kali Logistic     | plan_id = 98abd950-b529-41f3-b66d-055a25c5a76d | trialing | monthly
--                     | period 2026-08-13 .. 2026-09-13 | cancel_at_period_end=f | canceled_at=null

-- ============================================================================
-- 6. Plan catalog unchanged (still Starter / Professional / Enterprise,
--    same prices, no Stripe mapping).
-- ============================================================================
select id, name, tier, monthly_price_cents, annual_price_cents, is_active,
       (stripe_product_id is null)       as stripe_product_id_is_null,
       (stripe_price_id_monthly is null) as stripe_price_id_monthly_is_null,
       (stripe_price_id_annual is null)  as stripe_price_id_annual_is_null
from public.subscription_plans
order by monthly_price_cents;
-- expect 3 rows: Starter 4900/49000, Professional 14900/149000,
--   Enterprise 39900/399000; all is_active=true; all *_is_null=true.

-- ============================================================================
-- 7. Nothing else moved.
-- ============================================================================
select
  (select count(*) from public.organizations)         as organizations,        -- expect 63
  (select count(*) from public.stripe_webhook_events) as stripe_webhook_events, -- expect 0
  (select count(*) from public.billing_records)       as billing_records;      -- expect 0
