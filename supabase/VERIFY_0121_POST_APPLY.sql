-- Run AFTER applying 0121_commercial_plan_catalog.sql.
--
-- 100% READ-ONLY. Plain SELECTs only -- no BEGIN/ROLLBACK, no writes, no
-- fixtures. Safe on production. No PII selected; no Stripe identifiers
-- printed (only IS NULL).

-- ============================================================================
-- 1. ORGANIZATIONS -- immediate post-0121 production expectation.
--    (Future orgs created after 0121 will make billing_required=true > 0;
--     that is intentional and not a failure of this check when run later.)
-- ============================================================================
select
  count(*)                                            as total_organizations,          -- expect 63
  count(*) filter (where billing_required = false)    as billing_required_false,       -- expect 63 (immediately post-0121)
  count(*) filter (where billing_required = true)     as billing_required_true,         -- expect 0  (immediately post-0121)
  count(*) filter (where billing_required is null)    as billing_required_null          -- expect 0  (column is NOT NULL)
from public.organizations;

-- ============================================================================
-- 2. SUBSCRIPTIONS -- unchanged by 0121.
-- ============================================================================
select
  (select count(*) from public.organization_subscriptions)                                    as total_subscriptions,  -- expect 3
  (select count(*) from public.organization_subscriptions where grandfathered_at is not null) as grandfathered,        -- expect 3
  (select count(*) from public.organization_subscriptions
     where grandfathered_at is not null
       and (stripe_customer_id is not null or stripe_subscription_id is not null or stripe_price_id is not null))
                                                                                             as grandfather_with_stripe_id; -- expect 0

-- 2a. The three grandfather rows are the same three approved organizations,
--     with plan/status/cycle preserved and all Stripe ids NULL.
select
  o.name                              as organization_name,
  s.organization_id,
  p.tier                              as plan_tier,
  s.status,
  s.billing_cycle,
  (s.grandfathered_at is not null)    as grandfathered,
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
--   Kali Freight LLC  | professional | active   | monthly | grandfathered=t | all stripe_*_is_null=t

-- ============================================================================
-- 3. LEGACY PLANS -- retained, reclassified, prices unchanged.
-- ============================================================================
select
  tier, name, monthly_price_cents, annual_price_cents,
  max_users, max_trucks, max_active_loads,
  is_public, is_active,
  (stripe_product_id is null)       as stripe_product_id_is_null,
  (stripe_price_id_monthly is null) as stripe_price_id_monthly_is_null,
  (stripe_price_id_annual is null)  as stripe_price_id_annual_is_null
from public.subscription_plans
where tier in ('starter', 'professional', 'enterprise')
order by monthly_price_cents;
-- expect exactly 3 rows:
--   starter      | Starter      | 4900  | 49000  | 3  | 5   | 15   | is_public=f | is_active=f
--   professional | Professional | 14900 | 149000 | 15 | 75  | 250  | is_public=f | is_active=t
--   enterprise   | Enterprise   | 39900 | 399000 | 50 | 200 | 1000 | is_public=f | is_active=t
-- (max_* and prices identical to the pre-0121 values.)

-- 3a. Exactly one row per legacy tier.
select tier, count(*) as row_count
from public.subscription_plans
where tier in ('starter', 'professional', 'enterprise')
group by tier
order by tier;
-- expect: starter 1, professional 1, enterprise 1.

-- ============================================================================
-- 4. PUBLIC COMMERCIAL PLANS -- Essential + Pro, exact shape, no Stripe ids.
-- ============================================================================
select
  tier, name, description,
  monthly_price_cents, annual_price_cents,
  max_users, max_trucks, max_active_loads,
  features,
  is_public, is_active,
  (stripe_product_id is null)       as stripe_product_id_is_null,
  (stripe_price_id_monthly is null) as stripe_price_id_monthly_is_null,
  (stripe_price_id_annual is null)  as stripe_price_id_annual_is_null
from public.subscription_plans
where tier in ('essential', 'pro')
order by monthly_price_cents;
-- expect exactly 2 rows:
--   essential | Essential | 5900 / 59000 | 5 / 15 / 50       | is_public=t | is_active=t | all stripe_*_is_null=t
--     features: ["Loads & dispatch","Drivers, trucks & trailers",
--               "Brokers, customers & carriers","Invoicing & payments","Documents"]
--   pro       | Pro       | 9900 / 99000 | NULL / NULL / NULL | is_public=t | is_active=t | all stripe_*_is_null=t
--     features: ["Everything in Essential","Settlements","Compliance tracking",
--               "QuickBooks integration","Statements","Advances & factoring"]

-- 4a. Exactly two plans are is_public = true AND is_active = true, and both
--     are commercial tiers.
select count(*) as public_active_plans,
       count(*) filter (where tier in ('essential', 'pro')) as public_active_commercial
from public.subscription_plans
where is_public = true and is_active = true;
-- expect: public_active_plans = 2, public_active_commercial = 2.

-- 4b. No non-commercial plan is public.
select count(*) as non_commercial_public_plans
from public.subscription_plans
where is_public = true and tier not in ('essential', 'pro');
-- expect 0.

-- 4c. Every commercial Stripe mapping column is still NULL (no Stripe object).
select
  count(*)                                                     as commercial_plans,          -- expect 2
  count(*) filter (where stripe_product_id is not null
                      or stripe_price_id_monthly is not null
                      or stripe_price_id_annual is not null)    as any_stripe_id_populated    -- expect 0
from public.subscription_plans
where tier in ('essential', 'pro');

-- ============================================================================
-- 5. ENUM -- subscription_tier contains exactly these five, legacy first.
-- ============================================================================
select e.enumsortorder, e.enumlabel
from pg_type t
join pg_enum e on e.enumtypid = t.oid
join pg_namespace n on n.oid = t.typnamespace
where n.nspname = 'public' and t.typname = 'subscription_tier'
order by e.enumsortorder;
-- expect labels: starter, professional, enterprise, essential, pro.

-- 5a. Exact ordered label-set assertion (single boolean).
select (
  select array_agg(e.enumlabel::text order by e.enumsortorder)
  from pg_enum e
  join pg_type t on t.oid = e.enumtypid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname = 'subscription_tier'
) = array['starter', 'professional', 'enterprise', 'essential', 'pro']::text[]
  as subscription_tier_labels_exact;
-- expect: subscription_tier_labels_exact = true.

-- ============================================================================
-- 6. DB INVARIANT -- grandfather/no-Stripe CHECK exists and all rows satisfy it.
-- ============================================================================
select conname, contype, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.organization_subscriptions'::regclass
  and conname = 'organization_subscriptions_grandfather_has_no_stripe';
-- expect 1 row, contype 'c':
--   CHECK ((grandfathered_at IS NULL) OR ((stripe_customer_id IS NULL)
--          AND (stripe_subscription_id IS NULL) AND (stripe_price_id IS NULL)))

select count(*) as rows_violating_grandfather_no_stripe
from public.organization_subscriptions
where not (
  grandfathered_at is null
  or (stripe_customer_id is null
      and stripe_subscription_id is null
      and stripe_price_id is null)
);
-- expect 0.

-- ============================================================================
-- 7. OTHER BILLING TABLES -- unchanged.
-- ============================================================================
select
  (select count(*) from public.stripe_webhook_events) as stripe_webhook_events, -- expect 0
  (select count(*) from public.billing_records)       as billing_records;        -- expect 0

-- ============================================================================
-- 8. COLUMN SHAPE -- the two new columns are NOT NULL with the intended
--    defaults.
-- ============================================================================
select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'subscription_plans' and column_name = 'is_public')
    or (table_name = 'organizations' and column_name = 'billing_required')
  )
order by table_name;
-- expect:
--   organizations.billing_required     | boolean | NO | true
--   subscription_plans.is_public       | boolean | NO | false
