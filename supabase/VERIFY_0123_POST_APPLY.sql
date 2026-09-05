-- Run AFTER applying 0123_stripe_subscription_runtime_hardening.sql.
--
-- 100% READ-ONLY. SELECTs only -- no INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / TRUNCATE / mutation RPC, no BEGIN/ROLLBACK, no fixtures.
-- Safe on production.
--
-- Section 1 returns one row per named check with a boolean `pass`; every
-- `pass` must be true. Section 2 prints the three new column definitions.

-- ============================================================================
-- 1. PASS/FAIL MATRIX -- every `pass` must be true (35 checks).
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
    -- past_due_since
    ( 1, 'past_due_since column exists',
      (select count(*) = 1 from col where column_name = 'past_due_since') ),
    ( 2, 'past_due_since type = timestamptz',
      (select data_type = 'timestamp with time zone' from col where column_name = 'past_due_since') ),
    ( 3, 'past_due_since is nullable',
      (select is_nullable = 'YES' from col where column_name = 'past_due_since') ),
    ( 4, 'past_due_since has no default',
      (select column_default is null from col where column_name = 'past_due_since') ),
    -- stripe_event_at
    ( 5, 'stripe_event_at column exists',
      (select count(*) = 1 from col where column_name = 'stripe_event_at') ),
    ( 6, 'stripe_event_at type = timestamptz',
      (select data_type = 'timestamp with time zone' from col where column_name = 'stripe_event_at') ),
    ( 7, 'stripe_event_at is nullable',
      (select is_nullable = 'YES' from col where column_name = 'stripe_event_at') ),
    ( 8, 'stripe_event_at has no default',
      (select column_default is null from col where column_name = 'stripe_event_at') ),
    -- stripe_checkout_session_id
    ( 9, 'stripe_checkout_session_id column exists',
      (select count(*) = 1 from col where column_name = 'stripe_checkout_session_id') ),
    (10, 'stripe_checkout_session_id type = text',
      (select data_type = 'text' from col where column_name = 'stripe_checkout_session_id') ),
    (11, 'stripe_checkout_session_id is nullable',
      (select is_nullable = 'YES' from col where column_name = 'stripe_checkout_session_id') ),
    (12, 'stripe_checkout_session_id has no default',
      (select column_default is null from col where column_name = 'stripe_checkout_session_id') ),
    -- data state
    (13, 'exactly 3 organization_subscriptions rows',
      ((select count(*) from subs) = 3) ),
    (14, 'exactly 3 grandfathered rows',
      ((select count(*) from subs where grandfathered_at is not null) = 3) ),
    (15, 'all existing past_due_since values are NULL',
      (not exists (select 1 from subs where past_due_since is not null)) ),
    (16, 'all existing stripe_event_at values are NULL',
      (not exists (select 1 from subs where stripe_event_at is not null)) ),
    (17, 'all existing stripe_checkout_session_id values are NULL',
      (not exists (select 1 from subs where stripe_checkout_session_id is not null)) ),
    (18, 'grandfathered rows have all three new fields NULL',
      (not exists (select 1 from subs
                    where grandfathered_at is not null
                      and (past_due_since is not null
                        or stripe_event_at is not null
                        or stripe_checkout_session_id is not null))) ),
    (19, 'grandfathered rows still have stripe_customer_id / _subscription_id / _price_id all NULL',
      (not exists (select 1 from subs
                    where grandfathered_at is not null
                      and (stripe_customer_id is not null
                        or stripe_subscription_id is not null
                        or stripe_price_id is not null))) ),
    (20, 'grandfather CHECK exists AND its effective predicate is exactly the 0121 invariant',
      ((select btrim(regexp_replace(regexp_replace(lower(pg_get_constraintdef(c.oid)), '[()]', '', 'g'), '\s+', ' ', 'g'))
        from pg_constraint c
        where c.conrelid = 'public.organization_subscriptions'::regclass
          and c.conname = 'organization_subscriptions_grandfather_has_no_stripe'
          and c.contype = 'c')
       = 'check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null') ),
    (21, 'organization_id_key is UNIQUE on organization_subscriptions over EXACTLY the single column organization_id',
      ((select array_agg(a.attname order by k.ord)
        from pg_constraint c
        cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
        where c.conrelid = 'public.organization_subscriptions'::regclass
          and c.conname = 'organization_subscriptions_organization_id_key'
          and c.contype = 'u')
       = array['organization_id']::name[]) ),
    (22, 'set_updated_at trigger exists',
      (exists (select 1 from pg_trigger
                 where tgrelid = 'public.organization_subscriptions'::regclass
                   and tgname = 'set_updated_at' and not tgisinternal)) ),
    (23, 'RLS enabled on organization_subscriptions',
      ((select relrowsecurity from pg_class where oid = 'public.organization_subscriptions'::regclass)) ),
    (24, 'tenant SELECT policy organization_subscriptions_select exists',
      (exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'organization_subscriptions'
                   and policyname = 'organization_subscriptions_select')) ),
    (25, 'no INSERT-scoped policy on organization_subscriptions (writes are service-role only)',
      (not exists (select 1 from pg_policies
                     where schemaname = 'public' and tablename = 'organization_subscriptions'
                       and cmd = 'INSERT')) ),
    (26, 'no UPDATE-scoped policy, and the only FOR ALL policy is the 0016 platform_admin_all',
      (not exists (select 1 from pg_policies
                     where schemaname = 'public' and tablename = 'organization_subscriptions'
                       and cmd = 'UPDATE')
       and not exists (select 1 from pg_policies
                         where schemaname = 'public' and tablename = 'organization_subscriptions'
                           and cmd = 'ALL'
                           and policyname <> 'organization_subscriptions_platform_admin_all')) ),
    (27, 'no DELETE-scoped policy on organization_subscriptions',
      (not exists (select 1 from pg_policies
                     where schemaname = 'public' and tablename = 'organization_subscriptions'
                       and cmd = 'DELETE')) ),
    (28, 'organizations count = 63',
      ((select count(*) from public.organizations) = 63) ),
    (29, 'organizations with billing_required = false = 63',
      ((select count(*) from public.organizations where billing_required = false) = 63) ),
    (30, 'subscription_plans count = 5',
      ((select count(*) from plans) = 5) ),
    (31, 'exactly Essential + Pro are public + active',
      ((select count(*) from plans where is_public = true and is_active = true) = 2
       and not exists (select 1 from plans where is_public = true and is_active = true and tier not in ('essential','pro'))) ),
    (32, 'Essential Stripe mapping unchanged',
      (exists (select 1 from plans
                 where id = 'f54f87ae-556d-4ae4-8db6-0fbbbac4b798' and tier = 'essential'
                   and stripe_product_id = 'prod_VBimjDJ5rSyvx5'
                   and stripe_price_id_monthly = 'price_1UBLLMKvkXN4pgdED3H0zeNs'
                   and stripe_price_id_annual  = 'price_1UBLb6KvkXN4pgdEL1Orixr0')) ),
    (33, 'Pro Stripe mapping unchanged',
      (exists (select 1 from plans
                 where id = '2a9138f2-0514-4e32-a178-2171776e69a3' and tier = 'pro'
                   and stripe_product_id = 'prod_VBjAx1MTHvWdCu'
                   and stripe_price_id_monthly = 'price_1UBLhuKvkXN4pgdERSZvfTmV'
                   and stripe_price_id_annual  = 'price_1UBLuQKvkXN4pgdEwGxao6YC')) ),
    (34, 'billing_records count = 0',
      ((select count(*) from public.billing_records) = 0) ),
    (35, 'stripe_webhook_events count = 0',
      ((select count(*) from public.stripe_webhook_events) = 0) )
) as checks(n, check_name, pass)
order by n;
-- expect: 35 rows, every `pass` = true.

-- ============================================================================
-- 2. The three new columns -- print definitions for eyeball review.
-- ============================================================================
select column_name, data_type, is_nullable, column_default, ordinal_position
from information_schema.columns
where table_schema = 'public' and table_name = 'organization_subscriptions'
  and column_name in ('past_due_since', 'stripe_event_at', 'stripe_checkout_session_id')
order by column_name;
-- expect 3 rows:
--   past_due_since             | timestamp with time zone | YES | (null)
--   stripe_checkout_session_id | text                     | YES | (null)
--   stripe_event_at            | timestamp with time zone | YES | (null)

-- ============================================================================
-- 3. Grandfather CHECK + organization_id UNIQUE -- print the ACTUAL catalog
--    definitions for eyeball inspection.
-- ============================================================================
select
  c.conname,
  c.contype,
  pg_get_constraintdef(c.oid)                                                        as definition,
  btrim(regexp_replace(regexp_replace(lower(pg_get_constraintdef(c.oid)),
        '[()]', '', 'g'), '\s+', ' ', 'g'))                                          as normalized
from pg_constraint c
where c.conrelid = 'public.organization_subscriptions'::regclass
  and c.conname = 'organization_subscriptions_grandfather_has_no_stripe';
-- expect 1 row, contype 'c', normalized =
--   check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null

select
  c.conname,
  c.contype,
  pg_get_constraintdef(c.oid)                                                        as definition,
  (select array_agg(a.attname order by k.ord)
   from unnest(c.conkey) with ordinality as k(attnum, ord)
   join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum)           as constrained_columns
from pg_constraint c
where c.conrelid = 'public.organization_subscriptions'::regclass
  and c.conname = 'organization_subscriptions_organization_id_key';
-- expect 1 row, contype 'u', definition 'UNIQUE (organization_id)',
--   constrained_columns = {organization_id}

-- ============================================================================
-- 4. Policies on organization_subscriptions -- for eyeball confirmation that
--    only SELECT (tenant) + the 0016 platform-admin ALL policy exist.
-- ============================================================================
select policyname, cmd, roles
from pg_policies
where schemaname = 'public' and tablename = 'organization_subscriptions'
order by policyname;
-- expect exactly:
--   organization_subscriptions_select              | SELECT | {public}   (0010)
--   organization_subscriptions_platform_admin_all  | ALL    | {public}   (0016)
-- and NOTHING else (no tenant INSERT/UPDATE/DELETE policy).
