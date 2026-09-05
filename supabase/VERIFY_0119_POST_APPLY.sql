-- Run AFTER applying 0119_stripe_subscription_foundation.sql.
--
-- 100% READ-ONLY. No BEGIN/ROLLBACK, no writes, no fixtures, no RPC
-- invocation -- every statement is a catalog or aggregate SELECT. Safe on
-- production. Nothing here creates a stripe_webhook_events row.
--
-- Sections 1-9 verify the migration landed as authored.
-- Section 10 confirms 0119 changed no business data.
-- Sections 11-13 are the grandfather-candidate audit (advisory only).

-- ============================================================================
-- 1. subscription_status enum -- expect exactly these 8, in this order:
--    trialing, active, past_due, canceled, incomplete, paused,
--    incomplete_expired, unpaid
-- ============================================================================
select e.enumsortorder, e.enumlabel
from pg_type t
join pg_enum e on e.enumtypid = t.oid
join pg_namespace n on n.oid = t.typnamespace
where n.nspname = 'public' and t.typname = 'subscription_status'
order by e.enumsortorder;

-- ============================================================================
-- 2. organization_subscriptions -- new columns present, old columns intact.
-- ============================================================================
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'organization_subscriptions'
order by ordinal_position;
-- expect the 13 original columns (id, organization_id, plan_id, status,
-- billing_cycle, stripe_customer_id, stripe_subscription_id,
-- current_period_start, current_period_end, cancel_at_period_end,
-- canceled_at, created_at, updated_at) PLUS: stripe_price_id (text, YES),
-- trial_end (timestamptz, YES), checkout_pending_since (timestamptz, YES),
-- grandfathered_at (timestamptz, YES).

-- 2a. The three UNIQUE constraints.
select conname, contype, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid = 'public.organization_subscriptions'::regclass
  and conname in (
    'organization_subscriptions_organization_id_key',
    'organization_subscriptions_stripe_customer_id_key',
    'organization_subscriptions_stripe_subscription_id_key'
  )
order by conname;
-- expect 3 rows, all contype = 'u':
--   ... UNIQUE (organization_id)
--   ... UNIQUE (stripe_customer_id)
--   ... UNIQUE (stripe_subscription_id)

-- 2b. set_updated_at trigger present + enabled.
select tgname, tgenabled, pg_get_triggerdef(oid) as def
from pg_trigger
where tgrelid = 'public.organization_subscriptions'::regclass
  and not tgisinternal and tgname = 'set_updated_at';
-- expect 1 row, tgenabled = 'O', BEFORE UPDATE ... EXECUTE FUNCTION public.set_updated_at().

-- ============================================================================
-- 3. subscription_plans -- Stripe mapping columns + safe plan rows.
-- ============================================================================
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'subscription_plans'
  and column_name in ('stripe_product_id', 'stripe_price_id_monthly', 'stripe_price_id_annual')
order by column_name;
-- expect 3 rows, all text / nullable YES.

select
  id, name, tier,
  monthly_price_cents, annual_price_cents, is_active,
  (stripe_product_id is null)       as stripe_product_id_is_null,
  (stripe_price_id_monthly is null) as stripe_price_id_monthly_is_null,
  (stripe_price_id_annual is null)  as stripe_price_id_annual_is_null
from public.subscription_plans
order by monthly_price_cents;
-- expect all three *_is_null = true (no Stripe objects created yet).

-- ============================================================================
-- 4. billing_records -- UNIQUE(stripe_invoice_id) + zero duplicates.
-- ============================================================================
select conname, contype, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid = 'public.billing_records'::regclass
  and conname = 'billing_records_stripe_invoice_id_key';
-- expect 1 row, contype 'u', UNIQUE (stripe_invoice_id).

select count(*) as billing_records_total,
       count(stripe_invoice_id) as with_stripe_invoice_id
from public.billing_records;
-- expect 0 / 0.

-- ============================================================================
-- 5. stripe_webhook_events -- table shape.
-- ============================================================================
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'stripe_webhook_events'
order by ordinal_position;
-- expect 16 columns: id, stripe_event_id, type, api_version, payload,
-- organization_id, status, claim_token, error, attempts, last_attempt_at,
-- stripe_created_at, received_at, processed_at, created_at, updated_at.

-- 5a. constraints: stripe_event_id UNIQUE; status CHECK; claim_token invariant CHECK.
select conname, contype, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid = 'public.stripe_webhook_events'::regclass
order by contype, conname;
-- expect (among others):
--   UNIQUE (stripe_event_id)
--   CHECK (status = ANY (ARRAY['received','processing','processed','failed']))
--   stripe_webhook_events_claim_token_shape:
--     CHECK ((claim_token IS NOT NULL) = (status = 'processing'))
--   CHECK (btrim(stripe_event_id) <> '')
--   FK organization_id -> organizations(id)

-- 5b. FK ON DELETE action (confdeltype: n = SET NULL).
select conname, pg_get_constraintdef(oid) as def, confdeltype
from pg_constraint
where conrelid = 'public.stripe_webhook_events'::regclass and contype = 'f';
-- expect: organization_id -> public.organizations(id), confdeltype = 'n'.

-- 5c. indexes.
select indexname, indexdef
from pg_indexes
where schemaname = 'public' and tablename = 'stripe_webhook_events'
order by indexname;
-- expect: pkey(id); unique(stripe_event_id); (status); (type);
--   (organization_id); (received_at); (status, last_attempt_at).

-- 5d. row count -- expect 0 immediately after a schema-only migration.
select count(*) as stripe_webhook_events_rows from public.stripe_webhook_events;
-- If > 0: inspect with SAFE metadata only, NEVER the payload:
--   select id, stripe_event_id, type, status, claim_token is not null as claimed,
--          attempts, received_at, processed_at
--   from public.stripe_webhook_events order by received_at;

-- ============================================================================
-- 6. stripe_webhook_events security.
-- ============================================================================
select relname, relrowsecurity, relforcerowsecurity
from pg_class where oid = 'public.stripe_webhook_events'::regclass;
-- expect relrowsecurity = true.

select count(*) as tenant_policy_count
from pg_policies
where schemaname = 'public' and tablename = 'stripe_webhook_events';
-- expect 0.

select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'stripe_webhook_events'
order by grantee, privilege_type;
-- expect NO rows for public / anon / authenticated. service_role may appear
-- with full privileges (Supabase default, deliberately not revoked).

-- ============================================================================
-- 7. Webhook RPCs -- existence, signature, SECURITY DEFINER, search_path, grants.
-- ============================================================================
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as args,
  pg_get_function_result(p.oid)             as returns,
  p.prosecdef                               as security_definer,
  p.proconfig                               as config,
  coalesce(has_function_privilege('anon',          p.oid, 'EXECUTE'), false) as anon_exec,
  coalesce(has_function_privilege('authenticated', p.oid, 'EXECUTE'), false) as authd_exec,
  coalesce(has_function_privilege('service_role',  p.oid, 'EXECUTE'), false) as service_exec
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    '_stripe_assert_service_role',
    'claim_stripe_webhook_event',
    'complete_stripe_webhook_event',
    'fail_stripe_webhook_event'
  )
order by p.proname;
-- expect:
--   _stripe_assert_service_role()          -> void   ; secdef t; config {search_path=public};
--                                            anon/authd/service ALL false (internal, granted to nobody)
--   claim_stripe_webhook_event(text,text,text,jsonb,timestamp with time zone,interval)
--       -> TABLE(result text, claim_token uuid); secdef t; {search_path=public};
--          anon=false, authd=false, service=true
--   complete_stripe_webhook_event(text,uuid) -> boolean; secdef t; {search_path=public};
--          anon=false, authd=false, service=true
--   fail_stripe_webhook_event(text,uuid,text) -> boolean; secdef t; {search_path=public};
--          anon=false, authd=false, service=true

-- ============================================================================
-- 8-9. Installed function bodies -- read them and confirm the contract.
-- ============================================================================
select pg_get_functiondef(p.oid) as definition
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'claim_stripe_webhook_event',
    'complete_stripe_webhook_event',
    'fail_stripe_webhook_event'
  )
order by p.proname;
-- Confirm in the text:
--   * default p_stale_after = interval '15 minutes'
--   * "if p_stale_after is null or p_stale_after < interval '1 minute' then raise"
--     APPEARS BEFORE the INSERT INTO stripe_webhook_events and the UPDATE.
--   * claim UPDATE sets status='processing', claim_token = <fresh gen_random_uuid()>,
--     attempts = attempts + 1, last_attempt_at = now(), error = null.
--   * complete_ / fail_ WHERE include: status = 'processing' AND claim_token = p_claim_token.
--   * complete_ / fail_ SET claim_token = null.

-- ============================================================================
-- 10. 0119 changed NO business data -- counts.
-- ============================================================================
select
  (select count(*) from public.organizations)            as organizations,
  (select count(*) from public.organization_subscriptions) as organization_subscriptions,
  (select count(*) from public.billing_records)          as billing_records,
  (select count(*) from public.stripe_webhook_events)    as stripe_webhook_events;
-- expect: organizations = 63, organization_subscriptions = 2 (unchanged from
--   the 0119 preflight), billing_records = 0, stripe_webhook_events = 0.

-- ============================================================================
-- 11. GRANDFATHER CANDIDATE AUDIT -- every organization WITHOUT a
--     subscription row. READ-ONLY. Safe metadata + operational counts only;
--     no emails / phones / addresses / tax ids / PII.
-- ============================================================================
select
  o.id                                                as organization_id,
  o.name                                              as organization_name,
  o.is_active,
  o.created_at,
  (select count(*) from public.profiles pr where pr.organization_id = o.id)                                as member_count,
  (select count(*) from public.profiles pr where pr.organization_id = o.id and pr.role in ('owner','admin')) as owner_admin_count,
  (select count(*) from public.carriers  x where x.organization_id = o.id) as carriers,
  (select count(*) from public.brokers   x where x.organization_id = o.id) as brokers,
  (select count(*) from public.customers x where x.organization_id = o.id) as customers,
  (select count(*) from public.drivers   x where x.organization_id = o.id) as drivers,
  (select count(*) from public.trucks    x where x.organization_id = o.id) as trucks,
  (select count(*) from public.loads     x where x.organization_id = o.id) as loads,
  (select count(*) from public.invoices  x where x.organization_id = o.id) as invoices,
  (select count(*) from public.payments  x where x.organization_id = o.id) as payments,
  (select count(*) from public.documents x where x.organization_id = o.id) as documents,
  greatest(
    o.created_at,
    coalesce((select max(x.created_at) from public.loads     x where x.organization_id = o.id), o.created_at),
    coalesce((select max(x.created_at) from public.invoices  x where x.organization_id = o.id), o.created_at),
    coalesce((select max(x.created_at) from public.payments  x where x.organization_id = o.id), o.created_at),
    coalesce((select max(x.created_at) from public.documents x where x.organization_id = o.id), o.created_at),
    coalesce((select max(x.created_at) from public.carriers  x where x.organization_id = o.id), o.created_at),
    coalesce((select max(x.created_at) from public.brokers   x where x.organization_id = o.id), o.created_at)
  )                                                   as last_meaningful_activity
from public.organizations o
where not exists (
  select 1 from public.organization_subscriptions s where s.organization_id = o.id
)
order by o.created_at;
-- Advisory classification (apply by eye, do NOT encode in a migration):
--   name LIKE 'TEST-%' or contains a unix-ms timestamp  -> LIKELY TEST / DEMO
--   real name, 0 operational rows, <=1 member            -> LIKELY EMPTY / ABANDONED
--   real name, loads+invoices+payments >= 3              -> LIKELY REAL / ACTIVE
--   real name, 2+ operational rows                       -> LIKELY PILOT
--   anything else                                        -> REQUIRES MANUAL REVIEW

-- ============================================================================
-- 13. The TWO existing subscription rows -- safe fields, no Stripe ids.
-- ============================================================================
select
  s.id                                as subscription_row_id,
  s.organization_id,
  o.name                              as organization_name,
  p.tier                              as plan_tier,
  p.name                              as plan_name,
  s.status,
  s.billing_cycle,
  s.created_at,
  s.current_period_end,
  (s.grandfathered_at is null)        as grandfathered_at_is_null,
  (s.stripe_customer_id is null)      as stripe_customer_id_is_null,
  (s.stripe_subscription_id is null)  as stripe_subscription_id_is_null,
  (s.stripe_price_id is null)         as stripe_price_id_is_null
from public.organization_subscriptions s
join public.organizations o on o.id = s.organization_id
left join public.subscription_plans p on p.id = s.plan_id
order by s.created_at;
