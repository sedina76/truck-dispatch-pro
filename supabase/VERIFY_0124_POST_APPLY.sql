-- Run AFTER applying 0124_stripe_checkout_attempt_identity.sql.
--
-- 100% READ-ONLY. SELECTs only -- no INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / TRUNCATE / mutation RPC, no BEGIN/ROLLBACK, no fixtures.
-- Safe on production.
--
-- Section 1 returns one row per named check with a boolean `pass`; every
-- `pass` must be true (28 checks). Sections 2-4 print catalog detail for
-- eyeball review.

-- ============================================================================
-- 1. PASS/FAIL MATRIX -- every `pass` must be true (28 checks).
-- ============================================================================
with
col as (
  select column_name, data_type, is_nullable, column_default
  from information_schema.columns
  where table_schema = 'public' and table_name = 'organization_subscriptions'
),
subs as (select * from public.organization_subscriptions),
plans as (select * from public.subscription_plans)
select * from (
  values
    ( 1, 'stripe_checkout_attempt_id exists exactly once',
      ((select count(*) from col where column_name = 'stripe_checkout_attempt_id') = 1) ),
    ( 2, 'stripe_checkout_attempt_id type = uuid',
      (select data_type = 'uuid' from col where column_name = 'stripe_checkout_attempt_id') ),
    ( 3, 'stripe_checkout_attempt_id is nullable',
      (select is_nullable = 'YES' from col where column_name = 'stripe_checkout_attempt_id') ),
    ( 4, 'stripe_checkout_attempt_id has no default',
      (select column_default is null from col where column_name = 'stripe_checkout_attempt_id') ),
    ( 5, 'no constraint references stripe_checkout_attempt_id',
      (not exists (
         select 1 from pg_constraint c
         join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
         where c.conrelid = 'public.organization_subscriptions'::regclass
           and a.attname = 'stripe_checkout_attempt_id')) ),
    ( 6, 'no index references stripe_checkout_attempt_id',
      (not exists (
         select 1 from pg_index i
         join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
         where i.indrelid = 'public.organization_subscriptions'::regclass
           and a.attname = 'stripe_checkout_attempt_id')) ),
    ( 7, 'every existing row has stripe_checkout_attempt_id NULL',
      (not exists (select 1 from subs where stripe_checkout_attempt_id is not null)) ),
    ( 8, 'every grandfathered row has stripe_checkout_attempt_id NULL',
      (not exists (select 1 from subs
                    where grandfathered_at is not null
                      and stripe_checkout_attempt_id is not null)) ),
    ( 9, 'exactly 3 organization_subscriptions rows (unchanged)',
      ((select count(*) from subs) = 3) ),
    (10, 'exactly 3 grandfathered rows (unchanged)',
      ((select count(*) from subs where grandfathered_at is not null) = 3) ),
    (11, 'no grandfathered row has any Stripe customer/subscription/price id',
      (not exists (select 1 from subs
                    where grandfathered_at is not null
                      and (stripe_customer_id is not null
                        or stripe_subscription_id is not null
                        or stripe_price_id is not null))) ),
    (12, 'no grandfathered row has checkout / session / attempt state',
      (not exists (select 1 from subs
                    where grandfathered_at is not null
                      and (checkout_pending_since is not null
                        or stripe_checkout_session_id is not null
                        or stripe_checkout_attempt_id is not null))) ),
    (13, 'the three 0123 columns are still present',
      ((select count(*) from col where column_name in
         ('past_due_since','stripe_event_at','stripe_checkout_session_id')) = 3) ),
    (14, 'checkout_pending_since column still present',
      (exists (select 1 from col where column_name = 'checkout_pending_since')) ),
    (15, 'grandfather CHECK exists AND its effective predicate is exactly the 0121 invariant',
      ((select btrim(regexp_replace(regexp_replace(lower(pg_get_constraintdef(c.oid)), '[()]', '', 'g'), '\s+', ' ', 'g'))
        from pg_constraint c
        where c.conrelid = 'public.organization_subscriptions'::regclass
          and c.conname = 'organization_subscriptions_grandfather_has_no_stripe'
          and c.contype = 'c')
       = 'check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null') ),
    (16, 'organization_id_key is UNIQUE over EXACTLY the single column organization_id',
      ((select array_agg(a.attname order by k.ord)
        from pg_constraint c
        cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
        where c.conrelid = 'public.organization_subscriptions'::regclass
          and c.conname = 'organization_subscriptions_organization_id_key'
          and c.contype = 'u')
       = array['organization_id']::name[]) ),
    (17, 'set_updated_at trigger exists',
      (exists (select 1 from pg_trigger
                 where tgrelid = 'public.organization_subscriptions'::regclass
                   and tgname = 'set_updated_at' and not tgisinternal)) ),
    (18, 'RLS enabled on organization_subscriptions',
      ((select relrowsecurity from pg_class where oid = 'public.organization_subscriptions'::regclass)) ),
    (19, 'tenant SELECT policy organization_subscriptions_select exists',
      (exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'organization_subscriptions'
                   and policyname = 'organization_subscriptions_select')) ),
    (20, 'platform-admin ALL policy organization_subscriptions_platform_admin_all exists',
      (exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'organization_subscriptions'
                   and policyname = 'organization_subscriptions_platform_admin_all')) ),
    (21, 'no INSERT/UPDATE/DELETE-scoped policy on organization_subscriptions',
      (not exists (select 1 from pg_policies
                     where schemaname = 'public' and tablename = 'organization_subscriptions'
                       and cmd in ('INSERT','UPDATE','DELETE'))) ),
    (22, 'organizations count = 63',
      ((select count(*) from public.organizations) = 63) ),
    (23, 'organizations with billing_required = false = 63',
      ((select count(*) from public.organizations where billing_required = false) = 63) ),
    (24, 'subscription_plans count = 5',
      ((select count(*) from plans) = 5) ),
    (25, 'exactly Essential + Pro are public + active',
      ((select count(*) from plans where is_public = true and is_active = true) = 2
       and not exists (select 1 from plans where is_public = true and is_active = true and tier not in ('essential','pro'))) ),
    (26, 'Essential Stripe mapping unchanged',
      (exists (select 1 from plans
                 where id = 'f54f87ae-556d-4ae4-8db6-0fbbbac4b798' and tier = 'essential'
                   and stripe_product_id = 'prod_VBimjDJ5rSyvx5'
                   and stripe_price_id_monthly = 'price_1UBLLMKvkXN4pgdED3H0zeNs'
                   and stripe_price_id_annual  = 'price_1UBLb6KvkXN4pgdEL1Orixr0')) ),
    (27, 'Pro Stripe mapping unchanged',
      (exists (select 1 from plans
                 where id = '2a9138f2-0514-4e32-a178-2171776e69a3' and tier = 'pro'
                   and stripe_product_id = 'prod_VBjAx1MTHvWdCu'
                   and stripe_price_id_monthly = 'price_1UBLhuKvkXN4pgdERSZvfTmV'
                   and stripe_price_id_annual  = 'price_1UBLuQKvkXN4pgdEwGxao6YC')) ),
    (28, 'billing_records = 0 AND stripe_webhook_events = 0',
      ((select count(*) from public.billing_records) = 0
       and (select count(*) from public.stripe_webhook_events) = 0) )
) as checks(n, check_name, pass)
order by n;
-- expect: 28 rows, every `pass` = true.

-- ============================================================================
-- 2. The new column -- print definition for eyeball review.
-- ============================================================================
select column_name, data_type, is_nullable, column_default, ordinal_position
from information_schema.columns
where table_schema = 'public' and table_name = 'organization_subscriptions'
  and column_name = 'stripe_checkout_attempt_id';
-- expect 1 row: stripe_checkout_attempt_id | uuid | YES | (null)

-- ============================================================================
-- 3. Grandfather CHECK + organization_id UNIQUE -- print ACTUAL catalog defs.
-- ============================================================================
select
  c.conname,
  c.contype,
  pg_get_constraintdef(c.oid) as definition,
  btrim(regexp_replace(regexp_replace(lower(pg_get_constraintdef(c.oid)),
        '[()]', '', 'g'), '\s+', ' ', 'g')) as normalized
from pg_constraint c
where c.conrelid = 'public.organization_subscriptions'::regclass
  and c.conname = 'organization_subscriptions_grandfather_has_no_stripe';
-- expect 1 row, contype 'c', normalized =
--   check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null

select
  c.conname,
  c.contype,
  pg_get_constraintdef(c.oid) as definition,
  (select array_agg(a.attname order by k.ord)
   from unnest(c.conkey) with ordinality as k(attnum, ord)
   join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) as constrained_columns
from pg_constraint c
where c.conrelid = 'public.organization_subscriptions'::regclass
  and c.conname = 'organization_subscriptions_organization_id_key';
-- expect 1 row, contype 'u', definition 'UNIQUE (organization_id)',
--   constrained_columns = {organization_id}

-- ============================================================================
-- 4. Policies on organization_subscriptions -- confirm only SELECT (tenant)
--    + the 0016 platform-admin ALL policy exist.
-- ============================================================================
select policyname, cmd, roles
from pg_policies
where schemaname = 'public' and tablename = 'organization_subscriptions'
order by policyname;
-- expect exactly:
--   organization_subscriptions_select              | SELECT | {public}   (0010)
--   organization_subscriptions_platform_admin_all  | ALL    | {public}   (0016)
-- and NOTHING else (no tenant INSERT/UPDATE/DELETE policy).

-- ============================================================================
-- 5. Every organization_subscriptions row -- confirm all checkout/attempt
--    state is NULL and grandfathered rows are pristine.
-- ============================================================================
select
  organization_id,
  status,
  grandfathered_at is not null            as is_grandfathered,
  stripe_checkout_attempt_id,
  checkout_pending_since,
  stripe_checkout_session_id,
  stripe_customer_id,
  stripe_subscription_id,
  stripe_price_id
from public.organization_subscriptions
order by grandfathered_at nulls last, organization_id;
-- expect 3 rows, all grandfathered, every column from
-- stripe_checkout_attempt_id rightward = NULL.
