-- Run AFTER applying 0122_stripe_commercial_catalog_mapping.sql.
--
-- 100% READ-ONLY. SELECTs only -- no INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / TRUNCATE / mutation RPC, no BEGIN/ROLLBACK, no fixtures.
-- Safe on production.
--
-- Section 1 returns one row per named check with a boolean `pass`; every
-- `pass` must be true. Sections 2-3 print the mapped values for eyeballing
-- (Stripe Product/Price ids are non-secret).

-- ============================================================================
-- 1. PASS/FAIL MATRIX -- every `pass` must be true.
-- ============================================================================
with
ess as (select * from public.subscription_plans where id = 'f54f87ae-556d-4ae4-8db6-0fbbbac4b798'),
pro as (select * from public.subscription_plans where id = '2a9138f2-0514-4e32-a178-2171776e69a3'),
plans as (select * from public.subscription_plans)
select * from (
  values
    ( 1, 'Essential exact UUID + tier',
      (select count(*) = 1 from ess where tier = 'essential') ),
    ( 2, 'Essential stripe_product_id = prod_VBimjDJ5rSyvx5',
      (select stripe_product_id = 'prod_VBimjDJ5rSyvx5' from ess) ),
    ( 3, 'Essential stripe_price_id_monthly = price_1UBLLMKvkXN4pgdED3H0zeNs',
      (select stripe_price_id_monthly = 'price_1UBLLMKvkXN4pgdED3H0zeNs' from ess) ),
    ( 4, 'Essential stripe_price_id_annual  = price_1UBLb6KvkXN4pgdEL1Orixr0',
      (select stripe_price_id_annual = 'price_1UBLb6KvkXN4pgdEL1Orixr0' from ess) ),
    ( 5, 'Pro exact UUID + tier',
      (select count(*) = 1 from pro where tier = 'pro') ),
    ( 6, 'Pro stripe_product_id = prod_VBjAx1MTHvWdCu',
      (select stripe_product_id = 'prod_VBjAx1MTHvWdCu' from pro) ),
    ( 7, 'Pro stripe_price_id_monthly = price_1UBLhuKvkXN4pgdERSZvfTmV',
      (select stripe_price_id_monthly = 'price_1UBLhuKvkXN4pgdERSZvfTmV' from pro) ),
    ( 8, 'Pro stripe_price_id_annual  = price_1UBLuQKvkXN4pgdEwGxao6YC',
      (select stripe_price_id_annual = 'price_1UBLuQKvkXN4pgdEwGxao6YC' from pro) ),
    ( 9, 'exactly 2 distinct Product ids among mapped rows',
      (select count(distinct stripe_product_id) = 2 from plans where stripe_product_id is not null) ),
    (10, 'exactly 4 distinct Price ids across Essential + Pro',
      (select count(*) = 4 from (
         select distinct p
         from plans s
         cross join lateral unnest(array[s.stripe_price_id_monthly, s.stripe_price_id_annual]) as t(p)
         where s.id in ('f54f87ae-556d-4ae4-8db6-0fbbbac4b798','2a9138f2-0514-4e32-a178-2171776e69a3')
       ) d) ),
    (11, 'all mapped Product ids start prod_ and all mapped Price ids start price_',
      (select bool_and(
                left(stripe_product_id,5) = 'prod_'
            and left(stripe_price_id_monthly,6) = 'price_'
            and left(stripe_price_id_annual,6)  = 'price_')
       from plans where stripe_product_id is not null) ),
    (12, 'monthly != annual for both mapped plans',
      (select bool_and(stripe_price_id_monthly <> stripe_price_id_annual)
       from plans where stripe_product_id is not null) ),
    (13, 'Essential price amounts unchanged (5900 / 59000)',
      (select monthly_price_cents = 5900 and annual_price_cents = 59000 from ess) ),
    (14, 'Pro price amounts unchanged (9900 / 99000)',
      (select monthly_price_cents = 9900 and annual_price_cents = 99000 from pro) ),
    (15, 'Essential limits unchanged (5 / 15 / 50)',
      (select max_users = 5 and max_trucks = 15 and max_active_loads = 50 from ess) ),
    (16, 'Pro limits unchanged (NULL / NULL / NULL = unlimited)',
      (select max_users is null and max_trucks is null and max_active_loads is null from pro) ),
    (17, 'Essential features unchanged',
      (select features = '["Loads & dispatch", "Drivers, trucks & trailers", "Brokers, customers & carriers", "Invoicing & payments", "Documents"]'::jsonb from ess) ),
    (18, 'Pro features unchanged',
      (select features = '["Everything in Essential", "Settlements", "Compliance tracking", "QuickBooks integration", "Statements", "Advances & factoring"]'::jsonb from pro) ),
    (19, 'both commercial plans is_public = true AND is_active = true',
      (select (select is_public and is_active from ess) and (select is_public and is_active from pro)) ),
    (20, 'exactly 2 subscription_plans rows have a non-NULL stripe_product_id, and they are Essential + Pro',
      (select count(*) = 2 from plans where stripe_product_id is not null)
      and not exists (select 1 from plans where stripe_product_id is not null
                        and id not in ('f54f87ae-556d-4ae4-8db6-0fbbbac4b798','2a9138f2-0514-4e32-a178-2171776e69a3')) ),
    (21, 'legacy plans (starter/professional/enterprise) still have all stripe_* NULL',
      (not exists (select 1 from plans where tier in ('starter','professional','enterprise')
                     and (stripe_product_id is not null
                       or stripe_price_id_monthly is not null
                       or stripe_price_id_annual is not null))) ),
    (22, 'organizations count = 63',
      ((select count(*) from public.organizations) = 63) ),
    (23, 'organizations with billing_required = false = 63',
      ((select count(*) from public.organizations where billing_required = false) = 63) ),
    (24, 'organization_subscriptions count = 3',
      ((select count(*) from public.organization_subscriptions) = 3) ),
    (25, 'grandfathered subscription count = 3',
      ((select count(*) from public.organization_subscriptions where grandfathered_at is not null) = 3) ),
    (26, 'grandfathered subscriptions with any Stripe id = 0',
      (not exists (select 1 from public.organization_subscriptions
                     where grandfathered_at is not null
                       and (stripe_customer_id is not null
                         or stripe_subscription_id is not null
                         or stripe_price_id is not null))) ),
    (27, 'grandfather CHECK constraint organization_subscriptions_grandfather_has_no_stripe exists',
      (exists (select 1 from pg_constraint
                 where conrelid = 'public.organization_subscriptions'::regclass
                   and conname = 'organization_subscriptions_grandfather_has_no_stripe'
                   and contype = 'c')) ),
    (28, 'billing_records count = 0',
      ((select count(*) from public.billing_records) = 0) ),
    (29, 'stripe_webhook_events count = 0',
      ((select count(*) from public.stripe_webhook_events) = 0) )
) as checks(n, check_name, pass)
order by n;
-- expect: 29 rows, every `pass` = true.

-- ============================================================================
-- 2. Mapped commercial rows -- print for eyeball review (non-secret ids).
-- ============================================================================
select
  tier, name,
  monthly_price_cents, annual_price_cents,
  max_users, max_trucks, max_active_loads,
  is_public, is_active,
  stripe_product_id,
  stripe_price_id_monthly,
  stripe_price_id_annual,
  features
from public.subscription_plans
where id in ('f54f87ae-556d-4ae4-8db6-0fbbbac4b798', '2a9138f2-0514-4e32-a178-2171776e69a3')
order by monthly_price_cents;
-- expect:
--   essential | Essential | 5900 / 59000 | 5 / 15 / 50       | t | t
--     prod_VBimjDJ5rSyvx5 | price_1UBLLMKvkXN4pgdED3H0zeNs | price_1UBLb6KvkXN4pgdEL1Orixr0
--   pro       | Pro       | 9900 / 99000 | NULL / NULL / NULL | t | t
--     prod_VBjAx1MTHvWdCu | price_1UBLhuKvkXN4pgdERSZvfTmV | price_1UBLuQKvkXN4pgdEwGxao6YC

-- ============================================================================
-- 3. Legacy rows -- confirm untouched / still unmapped.
-- ============================================================================
select
  tier, name, monthly_price_cents, annual_price_cents, is_public, is_active,
  (stripe_product_id is null)       as stripe_product_id_is_null,
  (stripe_price_id_monthly is null) as stripe_price_id_monthly_is_null,
  (stripe_price_id_annual is null)  as stripe_price_id_annual_is_null
from public.subscription_plans
where tier in ('starter', 'professional', 'enterprise')
order by monthly_price_cents;
-- expect: 3 rows, every *_is_null = true; prices 4900/49000, 14900/149000,
--   39900/399000; starter is_public/is_active = f/f; professional and
--   enterprise is_public=f, is_active=t.
