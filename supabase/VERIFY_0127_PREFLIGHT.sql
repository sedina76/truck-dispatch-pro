-- ============================================================================
-- 0127 PRE-APPLY PREFLIGHT  --  READ-ONLY. SELECT + catalog introspection only.
-- Does NOT call apply_stripe_subscription_state / _stripe_upsert_billing_record
-- / any claim/complete/fail webhook RPC. No ALTER/CREATE/DROP/INSERT/UPDATE/
-- DELETE/TRUNCATE. No transaction control.
--
-- Purpose:
--   RESULT SET A -- structural gate: 0127 PHASE-2 objects must be ABSENT
--                   (proves 0127 not partially applied) AND every 0119-0126
--                   dependency 0127 PHASE 1 requires must be LIVE.
--   RESULT SET B -- 0127 PHASE-1 data-state gates, expected vs. actual NOW.
--                   Any DRIFT row means 0127 applied VERBATIM will self-abort
--                   in its own PHASE 1 and roll back.
--   RESULT SET C -- diagnostic detail for the stuck webhook deliveries.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- RESULT SET A -- STRUCTURAL GATE. Every row must show ok = true to proceed
-- to apply-planning. Any false => STOP.
--   checks  1- 6 : 0127 PHASE-2 objects must be ABSENT (proves NOT partially
--                   applied) and billing_records must still be pre-hardening.
--   checks  7-31 : 0119-0126 dependencies 0127 PHASE 1 requires must be LIVE.
-- ---------------------------------------------------------------------------
select check_no, label,
       case when ok then 'PASS' else 'FAIL -- STOP' end as result,
       ok
from (
  values
    -- ---- 0127 PHASE-2 objects must NOT exist yet -------------------------
    ( 1, 'reconciliation_required_at column ABSENT on organization_subscriptions',
      not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='organization_subscriptions'
                    and column_name='reconciliation_required_at')),
    ( 2, 'reconciliation_reason column ABSENT',
      not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='organization_subscriptions'
                    and column_name='reconciliation_reason')),
    ( 3, 'reconciliation_context column ABSENT',
      not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='organization_subscriptions'
                    and column_name='reconciliation_context')),
    ( 4, '_stripe_upsert_billing_record(uuid,uuid,jsonb) ABSENT',
      to_regprocedure('public._stripe_upsert_billing_record(uuid,uuid,jsonb)') is null),
    ( 5, 'apply_stripe_subscription_state (ANY signature) ABSENT  <= explains SQLSTATE 42883',
      not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public' and p.proname='apply_stripe_subscription_state')),
    ( 6, 'billing_records still PRE-hardening: authenticated HAS INSERT (0127 will revoke it)',
      has_table_privilege('authenticated','public.billing_records','INSERT')),

    -- ---- 0119 core objects ---------------------------------------------------
    ( 7, '0119: table organization_subscriptions exists', to_regclass('public.organization_subscriptions') is not null),
    ( 8, '0119: table billing_records exists',            to_regclass('public.billing_records') is not null),
    ( 9, '0119: table stripe_webhook_events exists',      to_regclass('public.stripe_webhook_events') is not null),
    (10, '0119: table subscription_plans exists',         to_regclass('public.subscription_plans') is not null),
    (11, '0119: _stripe_assert_service_role() exists',    to_regprocedure('public._stripe_assert_service_role()') is not null),
    (12, '0119: claim_stripe_webhook_event(text,text,text,jsonb,timestamptz,interval) exists',
      to_regprocedure('public.claim_stripe_webhook_event(text,text,text,jsonb,timestamptz,interval)') is not null),
    (13, '0119: complete_stripe_webhook_event(text,uuid) exists',
      to_regprocedure('public.complete_stripe_webhook_event(text,uuid)') is not null),
    (14, '0119: fail_stripe_webhook_event(text,uuid,text) exists',
      to_regprocedure('public.fail_stripe_webhook_event(text,uuid,text)') is not null),
    (15, '0119: organization_subscriptions_organization_id_key UNIQUE on {organization_id}',
      exists (select 1 from pg_constraint c
              where c.conrelid='public.organization_subscriptions'::regclass
                and c.conname='organization_subscriptions_organization_id_key' and c.contype='u'
                and (select array_agg(a.attname order by k.ord)
                     from unnest(c.conkey) with ordinality k(attnum,ord)
                     join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum) = array['organization_id'])),
    (16, '0119: organization_subscriptions_stripe_customer_id_key UNIQUE exists',
      exists (select 1 from pg_constraint where conrelid='public.organization_subscriptions'::regclass
              and conname='organization_subscriptions_stripe_customer_id_key' and contype='u')),
    (17, '0119: organization_subscriptions_stripe_subscription_id_key UNIQUE exists',
      exists (select 1 from pg_constraint where conrelid='public.organization_subscriptions'::regclass
              and conname='organization_subscriptions_stripe_subscription_id_key' and contype='u')),
    (18, '0119: billing_records_stripe_invoice_id_key UNIQUE exists',
      exists (select 1 from pg_constraint where conrelid='public.billing_records'::regclass
              and conname='billing_records_stripe_invoice_id_key' and contype='u')),
    (19, '0119: billing_records.status CHECK domain open|paid|void|uncollectible present',
      exists (select 1 from pg_constraint c where c.conrelid='public.billing_records'::regclass and c.contype='c'
              and pg_get_constraintdef(c.oid) ilike '%open%' and pg_get_constraintdef(c.oid) ilike '%paid%'
              and pg_get_constraintdef(c.oid) ilike '%void%' and pg_get_constraintdef(c.oid) ilike '%uncollectible%')),
    (20, '0119: stripe_webhook_events_claim_token_shape CHECK present',
      exists (select 1 from pg_constraint where conrelid='public.stripe_webhook_events'::regclass
              and conname='stripe_webhook_events_claim_token_shape' and contype='c')),
    (21, '0119: RLS enabled on all three tables + read-only policies, no write policy',
      (select relrowsecurity from pg_class where oid='public.organization_subscriptions'::regclass)
      and (select relrowsecurity from pg_class where oid='public.billing_records'::regclass)
      and (select relrowsecurity from pg_class where oid='public.stripe_webhook_events'::regclass)
      and exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and policyname='organization_subscriptions_select')
      and exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and policyname='organization_subscriptions_platform_admin_all')
      and exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_select')
      and exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_platform_admin_select')
      and not exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and cmd in ('INSERT','UPDATE','DELETE'))
      and not exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and cmd in ('INSERT','UPDATE','DELETE'))
      and not exists (select 1 from pg_policies where schemaname='public' and tablename='stripe_webhook_events')),
    (22, '0119: subscription_status enum = exactly the 8 Stripe-aligned labels',
      (select array_agg(e.enumlabel::text order by e.enumlabel)
       from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
       where n.nspname='public' and t.typname='subscription_status')
       = array['active','canceled','incomplete','incomplete_expired','past_due','paused','trialing','unpaid']::text[]),

    -- ---- 0121 grandfather CHECK -------------------------------------------
    (23, '0121: grandfather CHECK predicate exact (normalized)',
      btrim(regexp_replace(regexp_replace(lower(
        coalesce((select pg_get_constraintdef(c.oid) from pg_constraint c
                  where c.conrelid='public.organization_subscriptions'::regclass
                    and c.conname='organization_subscriptions_grandfather_has_no_stripe' and c.contype='c'),'')
      ),'[()]','','g'),'\s+',' ','g'))
      = 'check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null'),

    -- ---- 0121 organizations.billing_required ----------------------------------
    (24, '0121: organizations.billing_required (boolean NOT NULL) exists',
      exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='organizations' and column_name='billing_required'
                and data_type='boolean' and is_nullable='NO')),

    -- ---- 0122 catalog anchors ---------------------------------------------
    (25, '0122: exactly 2 public+active subscription_plans',
      (select count(*) from public.subscription_plans where is_public and is_active) = 2),
    (26, '0122: Essential plan catalog mapping = expected',
      exists (select 1 from public.subscription_plans
              where id='f54f87ae-556d-4ae4-8db6-0fbbbac4b798' and tier='essential'
                and stripe_product_id='prod_VBimjDJ5rSyvx5'
                and stripe_price_id_monthly='price_1UBLLMKvkXN4pgdED3H0zeNs'
                and stripe_price_id_annual='price_1UBLb6KvkXN4pgdEL1Orixr0' and is_public and is_active)),
    (27, '0122: Pro plan catalog mapping = expected',
      exists (select 1 from public.subscription_plans
              where id='2a9138f2-0514-4e32-a178-2171776e69a3' and tier='pro'
                and stripe_product_id='prod_VBjAx1MTHvWdCu'
                and stripe_price_id_monthly='price_1UBLhuKvkXN4pgdERSZvfTmV'
                and stripe_price_id_annual='price_1UBLuQKvkXN4pgdEwGxao6YC' and is_public and is_active)),

    -- ---- helper functions the RPC relies on -----------------------------
    (28, 'helper current_org_id() / has_role(org_role[]) / is_platform_admin() all exist',
      to_regprocedure('public.current_org_id()') is not null
      and to_regprocedure('public.has_role(public.org_role[])') is not null
      and to_regprocedure('public.is_platform_admin()') is not null),

    -- ---- 0124 landmark --------------------------------------------------
    (29, '0124: organization_subscriptions.stripe_checkout_attempt_id column exists',
      exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='organization_subscriptions'
                and column_name='stripe_checkout_attempt_id')),

    -- ---- 0125/0126 landmarks -----------------------------------------------
    (30, '0125: platform_settings exists AND model_a_enabled = FALSE',
      to_regclass('public.platform_settings') is not null
      and (select model_a_enabled from public.platform_settings where id = true) is false),
    (31, '0126: loads.financial_dispatch_id carries the 0126 backfill comment',
      coalesce(col_description('public.loads'::regclass,
        (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='financial_dispatch_id')),'')
      ilike '%backfilled by migration 0126%')
) as t(check_no, label, ok);


-- ---------------------------------------------------------------------------
-- RESULT SET B -- 0127 PHASE-1 DATA-STATE GATES, expected vs. actual NOW.
-- These are hard-coded `raise`-on-mismatch inside 0127 PHASE 1. Any row where
-- actual <> expected means 0127 applied VERBATIM will self-abort and roll
-- back -- it needs a reviewed update to these frozen counts before it can
-- apply. Informational: this file does NOT propose the update.
-- ---------------------------------------------------------------------------
select label, expected, actual,
       case when actual = expected then 'ok'
            else 'DRIFT -- 0127 PHASE 1 will RAISE here' end as state
from (
  values
    ('organizations total',                       '64',
       (select count(*)::text from public.organizations)),
    ('organizations billing_required = false',    '63',
       (select count(*)::text from public.organizations where billing_required = false)),
    ('organization_subscriptions total',          '4',
       (select count(*)::text from public.organization_subscriptions)),
    ('organization_subscriptions grandfathered',  '3',
       (select count(*)::text from public.organization_subscriptions where grandfathered_at is not null)),
    ('grandfathered rows with a Stripe id',       '0',
       (select count(*)::text from public.organization_subscriptions
         where grandfathered_at is not null
           and (stripe_customer_id is not null or stripe_subscription_id is not null or stripe_price_id is not null))),
    ('billing_records total',                     '0',
       (select count(*)::text from public.billing_records)),
    ('stripe_webhook_events total',               '0',
       (select count(*)::text from public.stripe_webhook_events)),
    ('subscription_plans total',                  '5',
       (select count(*)::text from public.subscription_plans)),
    ('United Leather (ca6457e6-...) row still in C.4 in-flight shape', 'true',
       (select case when exists (
          select 1 from public.organization_subscriptions
          where organization_id = 'ca6457e6-8ae8-4e85-adc9-4a0dabb2386e'
            and status = 'incomplete' and grandfathered_at is null
            and stripe_customer_id is not null and stripe_checkout_session_id is not null
            and stripe_checkout_attempt_id is not null
            and stripe_subscription_id is null and stripe_price_id is null
        ) then 'true' else 'false' end))
) as t(label, expected, actual);


-- ---------------------------------------------------------------------------
-- RESULT SET C -- diagnostic detail for the stuck deliveries (read-only).
-- ---------------------------------------------------------------------------
select stripe_event_id, type, status, organization_id,
       received_at, processed_at, attempts, error
from public.stripe_webhook_events
order by received_at desc
limit 50;

select organization_id, status, plan_id, billing_cycle,
       stripe_customer_id, stripe_subscription_id, stripe_price_id,
       stripe_checkout_session_id, stripe_checkout_attempt_id,
       trial_end, current_period_start, current_period_end, stripe_event_at, grandfathered_at
from public.organization_subscriptions
order by grandfathered_at nulls first, created_at;
