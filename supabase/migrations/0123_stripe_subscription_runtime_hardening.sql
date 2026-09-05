-- =============================================================================
-- 0123_stripe_subscription_runtime_hardening.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW.
--
-- Minimal additive schema hardening for the Stripe SaaS-billing runtime.
-- Performs EXACTLY three schema statements:
--
--   ALTER TABLE public.organization_subscriptions ADD COLUMN past_due_since             timestamptz;
--   ALTER TABLE public.organization_subscriptions ADD COLUMN stripe_event_at            timestamptz;
--   ALTER TABLE public.organization_subscriptions ADD COLUMN stripe_checkout_session_id text;
--
-- and NOTHING ELSE -- no COMMENT, no DEFAULT, no backfill, no data write, no
-- new rows, no Stripe ids populated, no checkout/webhook state populated.
--
--   past_due_since             timestamptz NULL
--     Durable anchor for the exact 7-day past_due grace period. The runtime
--     (LATER phase, NOT here) will set it once per continuous past_due
--     episode -- past_due_since = coalesce(past_due_since, <event.created>)
--     -- and clear it when status leaves past_due. 0123 only adds the
--     column.
--
--   stripe_event_at            timestamptz NULL
--     Row-level ordering fence for Stripe subscription-lifecycle events.
--     stripe_webhook_events.stripe_created_at fences a single event id;
--     it does NOT stop different event ids (checkout.session.completed,
--     customer.subscription.updated, ...deleted) from arriving out of
--     order and mutating the SAME organization_subscriptions row. The
--     runtime (LATER) will apply a subscription-state mutation only when
--     incoming event.created >= stored stripe_event_at. 0123 only adds
--     the column.
--
--   stripe_checkout_session_id text NULL
--     Durable pointer to the current in-flight Stripe Checkout Session for
--     resume / dedupe / reconciliation. checkout_pending_since says WHEN
--     checkout became pending; this says WHICH session owns that state.
--     NO UNIQUE constraint (this is an in-flight pointer, not a global
--     identity key -- see report) and NO index (access is via the
--     already-unique organization_id row). The runtime (LATER) sets and
--     clears it. 0123 only adds the column.
--
-- Grandfather protection: the 0121 CHECK
--   organization_subscriptions_grandfather_has_no_stripe
--     grandfathered_at IS NULL
--     OR (stripe_customer_id IS NULL AND stripe_subscription_id IS NULL
--         AND stripe_price_id IS NULL)
-- is NOT weakened, dropped, replaced, or rewritten. 0123 validates its
-- EFFECTIVE PREDICATE (via pg_get_constraintdef, normalized) both before
-- and after mutation, and fails closed if it has materially drifted. The
-- three new columns are operational metadata and are not part of that
-- invariant. 0123 populates NONE of them -- every existing row
-- (grandfathered or not) keeps all three NULL after this migration.
--
-- This migration DOES NOT:
--   * use IF NOT EXISTS / UPSERT / INSERT / UPDATE / DELETE
--   * add a COMMENT, DEFAULT, index, UNIQUE, CHECK, FK, or trigger
--   * change RLS, policies, grants, or any function/RPC (including the
--     0119 claim/complete/fail webhook RPCs)
--   * create resolve_billing_access or any billing/webhook RPC
--   * touch any table other than public.organization_subscriptions
--   * touch billing_records, stripe_webhook_events, subscription_plans,
--     organizations, middleware, signup, onboarding, settings UI,
--     QuickBooks (0115-0118), or migrations 0119-0122
--
-- STRUCTURE: one guarded PL/pgSQL DO block, atomic. PHASE 1 runs every
-- catalog + data precondition (no writes). PHASE 2 runs exactly the three
-- ADD COLUMN statements. PHASE 3 re-verifies. Any RAISE at any phase rolls
-- the whole block back. NOT idempotent past PHASE 1 -- a re-run RAISEs at
-- "target column already exists".
-- =============================================================================

do $$
declare
  -- The 0121 grandfather CHECK, normalized: lower-cased, ALL parentheses
  -- removed (PostgreSQL's parenthesization/nesting of AND/OR chains varies
  -- by version and is not semantically meaningful once operator precedence
  -- is fixed -- AND binds tighter than OR, so "X or A and B and C" is
  -- unambiguously "X or (A and B and C)"), whitespace collapsed to single
  -- spaces, trimmed. Any material drift (column swap, operator swap,
  -- missing/added operand) changes this token sequence and fails closed.
  c_expected_gf_check constant text :=
    'check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null';

  v_missing text;
  v_n       integer;
  v_def     text;
  v_norm    text;
  v_cols    name[];
begin
  -- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS =======================

  -- Table exists.
  if to_regclass('public.organization_subscriptions') is null then
    raise exception '0123 precondition failed: table public.organization_subscriptions does not exist.';
  end if;

  -- The three target columns must be ABSENT (fail closed -- no IF NOT EXISTS).
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'past_due_since'
  ) then
    raise exception '0123 precondition failed: organization_subscriptions.past_due_since already exists -- 0123 partially applied? STOP.';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'stripe_event_at'
  ) then
    raise exception '0123 precondition failed: organization_subscriptions.stripe_event_at already exists -- 0123 partially applied? STOP.';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'stripe_checkout_session_id'
  ) then
    raise exception '0123 precondition failed: organization_subscriptions.stripe_checkout_session_id already exists -- 0123 partially applied? STOP.';
  end if;

  -- Existing columns the runtime depends on must all be present.
  select string_agg(c, ', ') into v_missing
  from unnest(array[
    'id','organization_id','plan_id','status','billing_cycle',
    'stripe_customer_id','stripe_subscription_id','stripe_price_id',
    'current_period_start','current_period_end','cancel_at_period_end',
    'canceled_at','trial_end','checkout_pending_since','grandfathered_at',
    'created_at','updated_at'
  ]) as c
  where not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = c
  );
  if v_missing is not null then
    raise exception '0123 precondition failed: organization_subscriptions is missing expected column(s): %.', v_missing;
  end if;

  -- Grandfather CHECK (0121) -- validate NAME + type + EFFECTIVE PREDICATE.
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid = 'public.organization_subscriptions'::regclass
    and c.conname  = 'organization_subscriptions_grandfather_has_no_stripe'
    and c.contype  = 'c';
  if v_def is null then
    raise exception '0123 precondition failed: CHECK organization_subscriptions_grandfather_has_no_stripe is missing or not a CHECK. STOP.';
  end if;
  v_norm := btrim(regexp_replace(regexp_replace(lower(v_def), '[()]', '', 'g'), '\s+', ' ', 'g'));
  if v_norm <> c_expected_gf_check then
    raise exception '0123 precondition failed: grandfather CHECK predicate has drifted. Expected (normalized): "%". Actual pg_get_constraintdef: "%". STOP.',
      c_expected_gf_check, v_def;
  end if;

  -- organization_id uniqueness (0119) -- validate it is UNIQUE on
  -- organization_subscriptions over EXACTLY the single column organization_id.
  select array_agg(a.attname order by k.ord) into v_cols
  from pg_constraint c
  cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
  where c.conrelid = 'public.organization_subscriptions'::regclass
    and c.conname  = 'organization_subscriptions_organization_id_key'
    and c.contype  = 'u';
  if v_cols is null then
    raise exception '0123 precondition failed: UNIQUE organization_subscriptions_organization_id_key is missing (or not a UNIQUE constraint). STOP.';
  end if;
  if cardinality(v_cols) <> 1 or v_cols[1] <> 'organization_id' then
    raise exception '0123 precondition failed: organization_subscriptions_organization_id_key covers % , expected exactly {organization_id}. STOP.', v_cols;
  end if;

  -- updated_at trigger exists.
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.organization_subscriptions'::regclass
      and tgname  = 'set_updated_at'
      and not tgisinternal
  ) then
    raise exception '0123 precondition failed: trigger set_updated_at on organization_subscriptions is missing. STOP.';
  end if;

  -- RLS still enabled + the tenant SELECT policy still present.
  if not (
    select relrowsecurity from pg_class where oid = 'public.organization_subscriptions'::regclass
  ) then
    raise exception '0123 precondition failed: RLS is not enabled on organization_subscriptions. STOP.';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'organization_subscriptions'
      and policyname = 'organization_subscriptions_select'
  ) then
    raise exception '0123 precondition failed: policy organization_subscriptions_select is missing. STOP.';
  end if;

  -- ---- Data-state preconditions (fail closed on drift) ----
  if (select count(*) from public.organizations) <> 63 then
    raise exception '0123 precondition failed: expected 63 organizations, found %.',
      (select count(*) from public.organizations);
  end if;
  if (select count(*) from public.organizations where billing_required = false) <> 63 then
    raise exception '0123 precondition failed: expected 63 organizations with billing_required=false, found %.',
      (select count(*) from public.organizations where billing_required = false);
  end if;
  if (select count(*) from public.organization_subscriptions) <> 3 then
    raise exception '0123 precondition failed: expected 3 organization_subscriptions rows, found %.',
      (select count(*) from public.organization_subscriptions);
  end if;
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0123 precondition failed: expected 3 grandfathered subscription rows, found %.',
      (select count(*) from public.organization_subscriptions where grandfathered_at is not null);
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0123 precondition failed: a grandfathered subscription row has a non-NULL Stripe id.';
  end if;
  if (select count(*) from public.billing_records) <> 0 then
    raise exception '0123 precondition failed: billing_records is not empty.';
  end if;
  if (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0123 precondition failed: stripe_webhook_events is not empty.';
  end if;
  if (select count(*) from public.subscription_plans) <> 5 then
    raise exception '0123 precondition failed: expected 5 subscription_plans rows, found %.',
      (select count(*) from public.subscription_plans);
  end if;
  if (select count(*) from public.subscription_plans where is_public = true and is_active = true) <> 2 then
    raise exception '0123 precondition failed: expected exactly 2 public active plans.';
  end if;
  if (select count(*) from public.subscription_plans
      where is_public = true and is_active = true and tier not in ('essential', 'pro')) <> 0 then
    raise exception '0123 precondition failed: a non-(essential|pro) plan is public + active.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where id = 'f54f87ae-556d-4ae4-8db6-0fbbbac4b798' and tier = 'essential'
      and stripe_product_id       = 'prod_VBimjDJ5rSyvx5'
      and stripe_price_id_monthly = 'price_1UBLLMKvkXN4pgdED3H0zeNs'
      and stripe_price_id_annual  = 'price_1UBLb6KvkXN4pgdEL1Orixr0'
  ) then
    raise exception '0123 precondition failed: the Essential Stripe catalog mapping is not the expected 0122 value.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where id = '2a9138f2-0514-4e32-a178-2171776e69a3' and tier = 'pro'
      and stripe_product_id       = 'prod_VBjAx1MTHvWdCu'
      and stripe_price_id_monthly = 'price_1UBLhuKvkXN4pgdERSZvfTmV'
      and stripe_price_id_annual  = 'price_1UBLuQKvkXN4pgdEwGxao6YC'
  ) then
    raise exception '0123 precondition failed: the Pro Stripe catalog mapping is not the expected 0122 value.';
  end if;

  -- ======================= PHASE 2 -- SCHEMA MUTATION =======================
  -- Exactly three ADD COLUMN statements. Nullable. No DEFAULT. No COMMENT,
  -- index, UNIQUE, CHECK, FK, or trigger.
  alter table public.organization_subscriptions
    add column past_due_since timestamptz;
  alter table public.organization_subscriptions
    add column stripe_event_at timestamptz;
  alter table public.organization_subscriptions
    add column stripe_checkout_session_id text;

  -- ======================= PHASE 3 -- POSTCONDITIONS =======================

  -- Column shape: exists, timestamptz|text, nullable, no default.
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'past_due_since'
      and data_type = 'timestamp with time zone'
      and is_nullable = 'YES'
      and column_default is null
  ) then
    raise exception '0123 postcondition failed: past_due_since is not (timestamptz, nullable, no default).';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'stripe_event_at'
      and data_type = 'timestamp with time zone'
      and is_nullable = 'YES'
      and column_default is null
  ) then
    raise exception '0123 postcondition failed: stripe_event_at is not (timestamptz, nullable, no default).';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'stripe_checkout_session_id'
      and data_type = 'text'
      and is_nullable = 'YES'
      and column_default is null
  ) then
    raise exception '0123 postcondition failed: stripe_checkout_session_id is not (text, nullable, no default).';
  end if;

  -- All three new columns NULL on every existing row (no backfill).
  --  (Dynamic execute so this parses cleanly right after the ALTERs.)
  execute 'select count(*) from public.organization_subscriptions where past_due_since is not null' into v_n;
  if v_n <> 0 then
    raise exception '0123 postcondition failed: past_due_since is non-NULL on % existing row(s).', v_n;
  end if;
  execute 'select count(*) from public.organization_subscriptions where stripe_event_at is not null' into v_n;
  if v_n <> 0 then
    raise exception '0123 postcondition failed: stripe_event_at is non-NULL on % existing row(s).', v_n;
  end if;
  execute 'select count(*) from public.organization_subscriptions where stripe_checkout_session_id is not null' into v_n;
  if v_n <> 0 then
    raise exception '0123 postcondition failed: stripe_checkout_session_id is non-NULL on % existing row(s).', v_n;
  end if;

  -- Same three NULL on every grandfathered row specifically.
  execute $q$
    select count(*) from public.organization_subscriptions
    where grandfathered_at is not null
      and (past_due_since is not null
        or stripe_event_at is not null
        or stripe_checkout_session_id is not null)
  $q$ into v_n;
  if v_n <> 0 then
    raise exception '0123 postcondition failed: a grandfathered row has a non-NULL new column.';
  end if;

  -- Counts / invariants unchanged.
  if (select count(*) from public.organization_subscriptions) <> 3 then
    raise exception '0123 postcondition failed: organization_subscriptions count changed.';
  end if;
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0123 postcondition failed: grandfathered subscription count changed.';
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0123 postcondition failed: a grandfathered row gained a Stripe id.';
  end if;

  -- Grandfather CHECK predicate STILL exact (re-validate after mutation).
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid = 'public.organization_subscriptions'::regclass
    and c.conname  = 'organization_subscriptions_grandfather_has_no_stripe'
    and c.contype  = 'c';
  if v_def is null then
    raise exception '0123 postcondition failed: the grandfather CHECK is gone.';
  end if;
  v_norm := btrim(regexp_replace(regexp_replace(lower(v_def), '[()]', '', 'g'), '\s+', ' ', 'g'));
  if v_norm <> c_expected_gf_check then
    raise exception '0123 postcondition failed: the grandfather CHECK predicate changed. Actual: "%".', v_def;
  end if;

  -- organization_id UNIQUE STILL exactly {organization_id} (re-validate).
  select array_agg(a.attname order by k.ord) into v_cols
  from pg_constraint c
  cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
  where c.conrelid = 'public.organization_subscriptions'::regclass
    and c.conname  = 'organization_subscriptions_organization_id_key'
    and c.contype  = 'u';
  if v_cols is null or cardinality(v_cols) <> 1 or v_cols[1] <> 'organization_id' then
    raise exception '0123 postcondition failed: organization_subscriptions_organization_id_key is no longer UNIQUE on exactly {organization_id} (got %).', v_cols;
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.organization_subscriptions'::regclass
      and tgname = 'set_updated_at' and not tgisinternal
  ) then
    raise exception '0123 postcondition failed: the set_updated_at trigger is gone.';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.organization_subscriptions'::regclass) then
    raise exception '0123 postcondition failed: RLS is no longer enabled.';
  end if;
  if (select count(*) from public.organizations) <> 63
     or (select count(*) from public.organizations where billing_required = false) <> 63 then
    raise exception '0123 postcondition failed: organizations / billing_required counts changed.';
  end if;
  if (select count(*) from public.billing_records) <> 0
     or (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0123 postcondition failed: billing_records / stripe_webhook_events are no longer empty.';
  end if;
  if (select count(*) from public.subscription_plans) <> 5 then
    raise exception '0123 postcondition failed: subscription_plans count changed.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where id = 'f54f87ae-556d-4ae4-8db6-0fbbbac4b798'
      and stripe_product_id = 'prod_VBimjDJ5rSyvx5'
      and stripe_price_id_monthly = 'price_1UBLLMKvkXN4pgdED3H0zeNs'
      and stripe_price_id_annual = 'price_1UBLb6KvkXN4pgdEL1Orixr0'
  ) or not exists (
    select 1 from public.subscription_plans
    where id = '2a9138f2-0514-4e32-a178-2171776e69a3'
      and stripe_product_id = 'prod_VBjAx1MTHvWdCu'
      and stripe_price_id_monthly = 'price_1UBLhuKvkXN4pgdERSZvfTmV'
      and stripe_price_id_annual = 'price_1UBLuQKvkXN4pgdEwGxao6YC'
  ) then
    raise exception '0123 postcondition failed: an Essential/Pro Stripe catalog mapping changed.';
  end if;

  raise notice '0123 complete: added organization_subscriptions.past_due_since, .stripe_event_at, .stripe_checkout_session_id (all timestamptz|text, NULL, no default). No COMMENT, no data row inserted/updated/deleted. Grandfather CHECK predicate, organization_id UNIQUE shape, updated_at trigger, and RLS all validated intact.';
end $$;
