-- =============================================================================
-- 0124_stripe_checkout_attempt_identity.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW.
--
-- Minimal additive schema hardening for crash-safe Stripe SaaS Checkout.
-- Performs EXACTLY ONE schema statement:
--
--   ALTER TABLE public.organization_subscriptions ADD COLUMN stripe_checkout_attempt_id uuid;
--
-- and NOTHING ELSE -- no DEFAULT, no NOT NULL, no COMMENT, no index, no
-- UNIQUE, no CHECK, no FK, no trigger, no backfill, no data write, no new
-- rows, no Stripe ids populated, no RLS / policy / grant / RPC change.
--
--   stripe_checkout_attempt_id uuid NULL
--     The IMMUTABLE logical identity of one Checkout attempt. Generated
--     application-side with crypto.randomUUID() (v4; collision-resistant)
--     when a brand-new attempt is claimed, and thereafter kept UNCHANGED
--     across every worker takeover / crash retry of that same attempt. It
--     is used to derive the Stripe Checkout Session CREATE idempotency key
--     (tdp_saas_checkout_v3_<subscriptionRowId>_<attemptId>) so that an
--     arbitrary number of worker crashes recover the SAME Session rather
--     than creating a second one.
--
--     It is NOT worker ownership (that stays on checkout_pending_since, the
--     mutable short-lived lease timestamp).
--     It is NOT a Stripe status.
--     It is NOT entitlement (that stays status-gated; status remains
--     'incomplete' until a future signed webhook).
--     It contains no PII.
--     It is a per-organization value: the organization_subscriptions row is
--     already UNIQUE on organization_id, so lookup never needs global
--     uniqueness -> NO UNIQUE constraint. Access is always via that unique
--     organization_id row -> NO index.
--     It is replaced (to a fresh uuid) or cleared to NULL ONLY when the
--     prior attempt is DEFINITIVELY dead (stored Session retrieved as
--     expired; Stripe 404 resource_missing on the stored Session; a Stripe
--     CREATE definitive rejection proving no Session was made) or is
--     deliberately abandoned by a future explicit change-selection
--     operation. Ambiguous external-read failures never clear it.
--
-- Column-role contract on organization_subscriptions after 0124:
--   stripe_checkout_attempt_id   IMMUTABLE logical attempt identity (0124)
--   checkout_pending_since        MUTABLE short-lived worker lease timestamp (0119)
--   stripe_checkout_session_id    Stripe Session pointer once known (0123)
--   plan_id / billing_cycle       FROZEN pending commercial intent of the
--                                 current attempt (never entitlement)
--   status = 'incomplete'         non-entitling local provisioning state
--
-- Grandfather protection: the 0121 CHECK
--   organization_subscriptions_grandfather_has_no_stripe
--     grandfathered_at IS NULL
--     OR (stripe_customer_id IS NULL AND stripe_subscription_id IS NULL
--         AND stripe_price_id IS NULL)
-- is NOT weakened, dropped, replaced, or rewritten. 0124 validates its
-- EFFECTIVE PREDICATE (via pg_get_constraintdef, normalized) both before
-- and after mutation and fails closed on material drift. The new column is
-- operational metadata and is not part of that invariant. 0124 populates
-- it on NO row -- every existing row (grandfathered or not) keeps
-- stripe_checkout_attempt_id = NULL after this migration.
--
-- This migration DOES NOT:
--   * use IF NOT EXISTS / UPSERT / INSERT / UPDATE / DELETE
--   * add a DEFAULT, NOT NULL, COMMENT, index, UNIQUE, CHECK, FK, or trigger
--   * change RLS, policies, grants, or any function / RPC (including the
--     0119 claim/complete/fail webhook RPCs)
--   * create resolve_billing_access or any billing / webhook RPC
--   * touch any table other than public.organization_subscriptions
--   * touch billing_records, stripe_webhook_events, subscription_plans,
--     organizations, middleware, signup, onboarding, settings UI,
--     QuickBooks (0115-0118), or migrations 0119-0123
--
-- STRUCTURE: one guarded PL/pgSQL DO block, atomic. PHASE 1 runs every
-- catalog + data precondition (no writes). PHASE 2 runs exactly the one
-- ADD COLUMN. PHASE 3 re-verifies. Any RAISE at any phase rolls the whole
-- block back. NOT idempotent past PHASE 1 -- a re-run RAISEs at "target
-- column already exists".
-- =============================================================================

do $$
declare
  -- The 0121 grandfather CHECK, normalized: lower-cased, ALL parentheses
  -- removed (PostgreSQL's parenthesization of AND/OR chains varies by
  -- version and is not semantically meaningful once precedence is fixed --
  -- AND binds tighter than OR, so "X or A and B and C" is unambiguously
  -- "X or (A and B and C)"), whitespace collapsed, trimmed. Any material
  -- drift (column swap, operator swap, missing/added operand) changes this
  -- token sequence and fails closed.
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
    raise exception '0124 precondition failed: table public.organization_subscriptions does not exist.';
  end if;

  -- The target column must be ABSENT (fail closed -- no IF NOT EXISTS).
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'stripe_checkout_attempt_id'
  ) then
    raise exception '0124 precondition failed: organization_subscriptions.stripe_checkout_attempt_id already exists -- 0124 partially applied? STOP.';
  end if;

  -- Existing columns the runtime depends on must all be present. This
  -- includes the three 0123 columns (now dependencies of the C.2 runtime)
  -- and the 0119 lease column checkout_pending_since.
  select string_agg(c, ', ') into v_missing
  from unnest(array[
    'id','organization_id','plan_id','status','billing_cycle',
    'stripe_customer_id','stripe_subscription_id','stripe_price_id',
    'current_period_start','current_period_end','cancel_at_period_end',
    'canceled_at','trial_end','checkout_pending_since','grandfathered_at',
    'past_due_since','stripe_event_at','stripe_checkout_session_id',
    'created_at','updated_at'
  ]) as c
  where not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = c
  );
  if v_missing is not null then
    raise exception '0124 precondition failed: organization_subscriptions is missing expected column(s): %.', v_missing;
  end if;

  -- Grandfather CHECK (0121) -- validate NAME + type + EFFECTIVE PREDICATE.
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid = 'public.organization_subscriptions'::regclass
    and c.conname  = 'organization_subscriptions_grandfather_has_no_stripe'
    and c.contype  = 'c';
  if v_def is null then
    raise exception '0124 precondition failed: CHECK organization_subscriptions_grandfather_has_no_stripe is missing or not a CHECK. STOP.';
  end if;
  v_norm := btrim(regexp_replace(regexp_replace(lower(v_def), '[()]', '', 'g'), '\s+', ' ', 'g'));
  if v_norm <> c_expected_gf_check then
    raise exception '0124 precondition failed: grandfather CHECK predicate has drifted. Expected (normalized): "%". Actual pg_get_constraintdef: "%". STOP.',
      c_expected_gf_check, v_def;
  end if;

  -- organization_id uniqueness (0119) -- UNIQUE on EXACTLY the single
  -- column organization_id.
  select array_agg(a.attname order by k.ord) into v_cols
  from pg_constraint c
  cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
  where c.conrelid = 'public.organization_subscriptions'::regclass
    and c.conname  = 'organization_subscriptions_organization_id_key'
    and c.contype  = 'u';
  if v_cols is null then
    raise exception '0124 precondition failed: UNIQUE organization_subscriptions_organization_id_key is missing (or not a UNIQUE constraint). STOP.';
  end if;
  if cardinality(v_cols) <> 1 or v_cols[1] <> 'organization_id' then
    raise exception '0124 precondition failed: organization_subscriptions_organization_id_key covers % , expected exactly {organization_id}. STOP.', v_cols;
  end if;

  -- updated_at trigger exists.
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.organization_subscriptions'::regclass
      and tgname  = 'set_updated_at'
      and not tgisinternal
  ) then
    raise exception '0124 precondition failed: trigger set_updated_at on organization_subscriptions is missing. STOP.';
  end if;

  -- RLS still enabled + the tenant SELECT policy still present + the 0016
  -- platform-admin ALL policy still present. NO tenant write policy must
  -- exist (writes stay service-role only).
  if not (
    select relrowsecurity from pg_class where oid = 'public.organization_subscriptions'::regclass
  ) then
    raise exception '0124 precondition failed: RLS is not enabled on organization_subscriptions. STOP.';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'organization_subscriptions'
      and policyname = 'organization_subscriptions_select'
  ) then
    raise exception '0124 precondition failed: policy organization_subscriptions_select is missing. STOP.';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'organization_subscriptions'
      and policyname = 'organization_subscriptions_platform_admin_all'
  ) then
    raise exception '0124 precondition failed: policy organization_subscriptions_platform_admin_all is missing. STOP.';
  end if;
  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'organization_subscriptions'
      and cmd in ('INSERT','UPDATE','DELETE')
  ) then
    raise exception '0124 precondition failed: an INSERT/UPDATE/DELETE-scoped tenant policy exists on organization_subscriptions. STOP.';
  end if;

  -- ---- Data-state preconditions (fail closed on drift) ----
  if (select count(*) from public.organizations) <> 63 then
    raise exception '0124 precondition failed: expected 63 organizations, found %.',
      (select count(*) from public.organizations);
  end if;
  if (select count(*) from public.organizations where billing_required = false) <> 63 then
    raise exception '0124 precondition failed: expected 63 organizations with billing_required=false, found %.',
      (select count(*) from public.organizations where billing_required = false);
  end if;
  if (select count(*) from public.organization_subscriptions) <> 3 then
    raise exception '0124 precondition failed: expected 3 organization_subscriptions rows, found %.',
      (select count(*) from public.organization_subscriptions);
  end if;
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0124 precondition failed: expected 3 grandfathered subscription rows, found %.',
      (select count(*) from public.organization_subscriptions where grandfathered_at is not null);
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0124 precondition failed: a grandfathered subscription row has a non-NULL Stripe id.';
  end if;
  -- No checkout state has leaked into production yet (Phase C has never run
  -- for real). Fail closed if it has -- a human should look first.
  if exists (
    select 1 from public.organization_subscriptions
    where checkout_pending_since is not null
       or stripe_checkout_session_id is not null
       or stripe_customer_id is not null
  ) then
    raise exception '0124 precondition failed: an organization_subscriptions row already carries checkout_pending_since / stripe_checkout_session_id / stripe_customer_id. STOP and inspect.';
  end if;
  if (select count(*) from public.billing_records) <> 0 then
    raise exception '0124 precondition failed: billing_records is not empty.';
  end if;
  if (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0124 precondition failed: stripe_webhook_events is not empty.';
  end if;
  if (select count(*) from public.subscription_plans) <> 5 then
    raise exception '0124 precondition failed: expected 5 subscription_plans rows, found %.',
      (select count(*) from public.subscription_plans);
  end if;
  if (select count(*) from public.subscription_plans where is_public = true and is_active = true) <> 2 then
    raise exception '0124 precondition failed: expected exactly 2 public active plans.';
  end if;
  if (select count(*) from public.subscription_plans
      where is_public = true and is_active = true and tier not in ('essential', 'pro')) <> 0 then
    raise exception '0124 precondition failed: a non-(essential|pro) plan is public + active.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where id = 'f54f87ae-556d-4ae4-8db6-0fbbbac4b798' and tier = 'essential'
      and stripe_product_id       = 'prod_VBimjDJ5rSyvx5'
      and stripe_price_id_monthly = 'price_1UBLLMKvkXN4pgdED3H0zeNs'
      and stripe_price_id_annual  = 'price_1UBLb6KvkXN4pgdEL1Orixr0'
  ) then
    raise exception '0124 precondition failed: the Essential Stripe catalog mapping is not the expected 0122 value.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where id = '2a9138f2-0514-4e32-a178-2171776e69a3' and tier = 'pro'
      and stripe_product_id       = 'prod_VBjAx1MTHvWdCu'
      and stripe_price_id_monthly = 'price_1UBLhuKvkXN4pgdERSZvfTmV'
      and stripe_price_id_annual  = 'price_1UBLuQKvkXN4pgdEwGxao6YC'
  ) then
    raise exception '0124 precondition failed: the Pro Stripe catalog mapping is not the expected 0122 value.';
  end if;

  -- ======================= PHASE 2 -- SCHEMA MUTATION =======================
  -- Exactly one ADD COLUMN. uuid. Nullable. No DEFAULT. No NOT NULL. No
  -- COMMENT, index, UNIQUE, CHECK, FK, or trigger.
  alter table public.organization_subscriptions
    add column stripe_checkout_attempt_id uuid;

  -- ======================= PHASE 3 -- POSTCONDITIONS =======================

  -- Column shape: exists exactly once, uuid, nullable, no default.
  if (select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'organization_subscriptions'
        and column_name = 'stripe_checkout_attempt_id') <> 1 then
    raise exception '0124 postcondition failed: stripe_checkout_attempt_id does not exist exactly once.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organization_subscriptions'
      and column_name = 'stripe_checkout_attempt_id'
      and data_type = 'uuid'
      and is_nullable = 'YES'
      and column_default is null
  ) then
    raise exception '0124 postcondition failed: stripe_checkout_attempt_id is not (uuid, nullable, no default).';
  end if;

  -- No constraint / index attached to the new column.
  if exists (
    select 1
    from pg_constraint c
    join pg_attribute a
      on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    where c.conrelid = 'public.organization_subscriptions'::regclass
      and a.attname = 'stripe_checkout_attempt_id'
  ) then
    raise exception '0124 postcondition failed: a constraint references stripe_checkout_attempt_id (expected none).';
  end if;
  if exists (
    select 1
    from pg_index i
    join pg_attribute a
      on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
    where i.indrelid = 'public.organization_subscriptions'::regclass
      and a.attname = 'stripe_checkout_attempt_id'
  ) then
    raise exception '0124 postcondition failed: an index references stripe_checkout_attempt_id (expected none).';
  end if;

  -- NULL on every existing row (no backfill). Dynamic execute so this
  -- parses cleanly right after the ALTER.
  execute 'select count(*) from public.organization_subscriptions where stripe_checkout_attempt_id is not null' into v_n;
  if v_n <> 0 then
    raise exception '0124 postcondition failed: stripe_checkout_attempt_id is non-NULL on % existing row(s).', v_n;
  end if;

  -- NULL on every grandfathered row specifically, and grandfathered rows
  -- otherwise untouched (still no Stripe ids, still no checkout state).
  execute $q$
    select count(*) from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_checkout_attempt_id is not null
        or stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null
        or stripe_checkout_session_id is not null
        or checkout_pending_since is not null)
  $q$ into v_n;
  if v_n <> 0 then
    raise exception '0124 postcondition failed: a grandfathered row is not pristine.';
  end if;

  -- Counts / invariants unchanged.
  if (select count(*) from public.organization_subscriptions) <> 3 then
    raise exception '0124 postcondition failed: organization_subscriptions count changed.';
  end if;
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0124 postcondition failed: grandfathered subscription count changed.';
  end if;

  -- Grandfather CHECK predicate STILL exact (re-validate after mutation).
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid = 'public.organization_subscriptions'::regclass
    and c.conname  = 'organization_subscriptions_grandfather_has_no_stripe'
    and c.contype  = 'c';
  if v_def is null then
    raise exception '0124 postcondition failed: the grandfather CHECK is gone.';
  end if;
  v_norm := btrim(regexp_replace(regexp_replace(lower(v_def), '[()]', '', 'g'), '\s+', ' ', 'g'));
  if v_norm <> c_expected_gf_check then
    raise exception '0124 postcondition failed: the grandfather CHECK predicate changed. Actual: "%".', v_def;
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
    raise exception '0124 postcondition failed: organization_subscriptions_organization_id_key is no longer UNIQUE on exactly {organization_id} (got %).', v_cols;
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.organization_subscriptions'::regclass
      and tgname = 'set_updated_at' and not tgisinternal
  ) then
    raise exception '0124 postcondition failed: the set_updated_at trigger is gone.';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.organization_subscriptions'::regclass) then
    raise exception '0124 postcondition failed: RLS is no longer enabled.';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'organization_subscriptions'
      and policyname = 'organization_subscriptions_select'
  ) or not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'organization_subscriptions'
      and policyname = 'organization_subscriptions_platform_admin_all'
  ) then
    raise exception '0124 postcondition failed: an expected policy on organization_subscriptions is gone.';
  end if;
  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'organization_subscriptions'
      and cmd in ('INSERT','UPDATE','DELETE')
  ) then
    raise exception '0124 postcondition failed: an INSERT/UPDATE/DELETE-scoped tenant policy appeared.';
  end if;

  if (select count(*) from public.organizations) <> 63
     or (select count(*) from public.organizations where billing_required = false) <> 63 then
    raise exception '0124 postcondition failed: organizations / billing_required counts changed.';
  end if;
  if (select count(*) from public.billing_records) <> 0
     or (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0124 postcondition failed: billing_records / stripe_webhook_events are no longer empty.';
  end if;
  if (select count(*) from public.subscription_plans) <> 5 then
    raise exception '0124 postcondition failed: subscription_plans count changed.';
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
    raise exception '0124 postcondition failed: an Essential/Pro Stripe catalog mapping changed.';
  end if;

  raise notice '0124 complete: added organization_subscriptions.stripe_checkout_attempt_id (uuid, NULL, no default, no constraint, no index). No data row inserted/updated/deleted; every existing row NULL. Grandfather CHECK predicate, organization_id UNIQUE shape, updated_at trigger, RLS, and the SELECT + platform-admin policies all validated intact; no tenant write policy present.';
end $$;
