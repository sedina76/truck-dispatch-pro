-- =============================================================================
-- 0121_commercial_plan_catalog.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW.
--
-- Introduce the public Stripe commercial plan catalog (ESSENTIAL, PRO) as
-- NEW rows alongside the retained legacy plans, and add the two durable
-- classification fields the future billing gate needs. SCHEMA + a tightly
-- guarded one-time data classification only.
--
-- WHAT 0121 DOES:
--   * ADDS enum values public.subscription_tier: 'essential', 'pro'
--     (additive; starter/professional/enterprise preserved, not reordered)
--   * ADDS subscription_plans.is_public   boolean NOT NULL DEFAULT false
--   * ADDS organizations.billing_required boolean NOT NULL DEFAULT true
--   * marks the 3 legacy plans is_public = false
--   * deactivates Starter (is_active = false) -- ONLY after proving it has
--     zero subscription references. Starter is NEVER deleted.
--   * INSERTs Essential ($59 / $590) and Pro ($99 / $990) as
--     is_public = true, is_active = true, with EVERY Stripe mapping column
--     NULL (no Stripe object exists yet)
--   * backfills billing_required = false for the ENTIRE audited production
--     population (all 63 organizations), guarded by an exact count check.
--     Organizations created AFTER 0121 inherit billing_required = true from
--     the column default -- intentional.
--   * adds CHECK organization_subscriptions_grandfather_has_no_stripe:
--       grandfathered_at IS NULL
--       OR (stripe_customer_id IS NULL AND stripe_subscription_id IS NULL
--           AND stripe_price_id IS NULL)
--
-- WHAT 0121 DOES NOT DO:
--   * rename, reprice, or re-tier any legacy plan
--   * touch Professional / Enterprise is_active (they stay active legacy plans)
--   * delete any plan
--   * change any organization_subscriptions row's plan/status/cycle/periods/
--     grandfathered_at/Stripe columns
--   * create or reference any Stripe Product / Price / Customer, or call Stripe
--   * touch billing_records, stripe_webhook_events, middleware, signup,
--     onboarding, /settings/*, the superadmin console, QuickBooks
--     (0115-0118), invoice/payment logic, or entitlement code
--   * implement entitlement enforcement -- the max_* limits are SOFT display
--     values only, exactly as they are today
--
-- ------------------------------------------------------------------------------
-- FAILURE / ATOMICITY SEMANTICS -- read carefully:
--
--   0121 has an UNAVOIDABLE transaction boundary: PostgreSQL forbids using a
--   new enum value in the same transaction that added it, and PART 3 INSERTs
--   rows with tier = 'essential'/'pro'. So `commit;` must close the enum
--   transaction before PART 3 (same as repo migrations 0033 / 0050).
--
--   PRE-MUTATION PREFLIGHT (below) runs FIRST, before any ALTER TYPE / ALTER
--   TABLE / COMMENT / INSERT / UPDATE / ADD CONSTRAINT. It validates every
--   production assumption checkable against the PRE-0121 schema (including,
--   without casting to the not-yet-existing enum labels, that 'essential' /
--   'pro' are absent from subscription_tier, and that the two new columns
--   and the new constraint do NOT already exist).
--
--   * If the PRE-MUTATION PREFLIGHT fails: ZERO 0121 schema or data changes
--     have occurred. Nothing to clean up.
--
--   * If a failure occurs AFTER the enum `commit;` (in PART 2, or in the
--     PART 3 DO block's PRECHECK #2, or during a PART 3 write): the enum
--     additions ('essential','pro') -- and possibly the two ADD COLUMNs if
--     PART 2 completed -- REMAIN. The PART 3 DO block is internally atomic
--     (its data writes + the ADD CONSTRAINT roll back together), so no
--     partial catalog/backfill/constraint state is left. But the migration
--     AS A WHOLE is NOT atomic. Manual review is required; remediation is
--     trivial (orphan enum labels are harmless; DROP the two columns if
--     they landed, then re-run once the production-state discrepancy that
--     tripped PRECHECK #2 is understood).
--
--   This file does NOT claim "any failure rolls the entire migration back".
-- ------------------------------------------------------------------------------
--
-- billing_required  vs  grandfathered_at -- DIFFERENT concepts:
--   organizations.billing_required (org-level): should the ABSENCE of a
--     subscription row force this org into Stripe billing onboarding?
--     false = legacy/pre-billing, exempt.
--   organization_subscriptions.grandfathered_at (subscription-level): this
--     org HAS a permanent entitlement subscription that requires no Stripe
--     customer, card, checkout, or recurring billing.
--
-- WHAT THE NEW CHECK GUARANTEES (accurate scope): a grandfathered
-- subscription row carries NO Stripe customer/subscription/price id. It does
-- NOT, by itself, form a complete bidirectional state machine; application +
-- webhook guards must separately prevent converting a Stripe-managed
-- subscription into a grandfathered one.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- PRE-MUTATION PREFLIGHT -- runs BEFORE any schema or data change. If any
-- check RAISEs here, zero 0121 changes have been made.
-- -----------------------------------------------------------------------------
do $$
declare
  v_starter_id      uuid;
  v_professional_id uuid;
  v_enterprise_id   uuid;
  v_labels          text[];
begin
  -- 1. organizations count = 63
  if (select count(*) from public.organizations) <> 63 then
    raise exception '0121 preflight #1.1 failed: expected 63 organizations, found %.',
      (select count(*) from public.organizations);
  end if;

  -- 2. organization_subscriptions count = 3
  if (select count(*) from public.organization_subscriptions) <> 3 then
    raise exception '0121 preflight #1.2 failed: expected 3 organization_subscriptions rows, found %.',
      (select count(*) from public.organization_subscriptions);
  end if;

  -- 3. grandfathered subscription count = 3
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0121 preflight #1.3 failed: expected 3 grandfathered subscription rows, found %.',
      (select count(*) from public.organization_subscriptions where grandfathered_at is not null);
  end if;

  -- 4. all grandfather rows have NULL Stripe ids
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0121 preflight #1.4 failed: a grandfathered subscription row has a non-NULL Stripe id.';
  end if;

  -- 5-7. exactly one Starter / Professional / Enterprise legacy plan
  if (select count(*) from public.subscription_plans where tier = 'starter') <> 1 then
    raise exception '0121 preflight #1.5 failed: expected exactly one starter plan.';
  end if;
  if (select count(*) from public.subscription_plans where tier = 'professional') <> 1 then
    raise exception '0121 preflight #1.6 failed: expected exactly one professional plan.';
  end if;
  if (select count(*) from public.subscription_plans where tier = 'enterprise') <> 1 then
    raise exception '0121 preflight #1.7 failed: expected exactly one enterprise plan.';
  end if;
  select id into v_starter_id      from public.subscription_plans where tier = 'starter';
  select id into v_professional_id from public.subscription_plans where tier = 'professional';
  select id into v_enterprise_id   from public.subscription_plans where tier = 'enterprise';

  -- 8. Professional references = 2
  if (select count(*) from public.organization_subscriptions where plan_id = v_professional_id) <> 2 then
    raise exception '0121 preflight #1.8 failed: expected 2 subscriptions referencing the professional plan, found %.',
      (select count(*) from public.organization_subscriptions where plan_id = v_professional_id);
  end if;

  -- 9. Enterprise references = 1
  if (select count(*) from public.organization_subscriptions where plan_id = v_enterprise_id) <> 1 then
    raise exception '0121 preflight #1.9 failed: expected 1 subscription referencing the enterprise plan, found %.',
      (select count(*) from public.organization_subscriptions where plan_id = v_enterprise_id);
  end if;

  -- 10. Starter references = 0
  if (select count(*) from public.organization_subscriptions where plan_id = v_starter_id) <> 0 then
    raise exception '0121 preflight #1.10 failed: the starter plan has % subscription reference(s).',
      (select count(*) from public.organization_subscriptions where plan_id = v_starter_id);
  end if;

  -- 11-12. subscription_tier must NOT already contain 'essential' / 'pro'.
  --        Inspected via pg_enum -- NEVER by casting the (not-yet-existing)
  --        string literals to the enum type.
  if exists (
    select 1
    from pg_enum e
    join pg_type t      on t.oid = e.enumtypid
    join pg_namespace n  on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'subscription_tier'
      and e.enumlabel in ('essential', 'pro')
  ) then
    raise exception '0121 preflight #1.11/12 failed: subscription_tier already contains ''essential'' and/or ''pro'' -- 0121 is not cleanly unapplied. STOP.';
  end if;
  -- exact pre-0121 label set
  select array_agg(e.enumlabel::text order by e.enumsortorder)
    into v_labels
  from pg_enum e
  join pg_type t     on t.oid = e.enumtypid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public' and t.typname = 'subscription_tier';
  if v_labels is distinct from array['starter', 'professional', 'enterprise']::text[] then
    raise exception '0121 preflight #1.11/12 failed: subscription_tier labels are %, expected exactly {starter, professional, enterprise}. STOP.', v_labels;
  end if;

  -- 13. no conflicting plan names
  if exists (select 1 from public.subscription_plans where name in ('Essential', 'Pro')) then
    raise exception '0121 preflight #1.13 failed: a plan named "Essential" or "Pro" already exists.';
  end if;

  -- 14. stripe_webhook_events = 0
  if (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0121 preflight #1.14 failed: stripe_webhook_events is not empty.';
  end if;

  -- 15. billing_records = 0
  if (select count(*) from public.billing_records) <> 0 then
    raise exception '0121 preflight #1.15 failed: billing_records is not empty.';
  end if;

  -- 16. grandfather/no-Stripe invariant currently holds for every sub row
  if exists (
    select 1 from public.organization_subscriptions
    where not (
      grandfathered_at is null
      or (stripe_customer_id is null
          and stripe_subscription_id is null
          and stripe_price_id is null)
    )
  ) then
    raise exception '0121 preflight #1.16 failed: an organization_subscriptions row already violates the grandfather/no-Stripe invariant.';
  end if;

  -- 17. subscription_plans.is_public column must be ABSENT (never applied).
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'subscription_plans' and column_name = 'is_public'
  ) then
    raise exception '0121 preflight #1.17 failed: subscription_plans.is_public already exists -- 0121 partially applied? Manual review required. STOP.';
  end if;

  -- 18. organizations.billing_required column must be ABSENT (never applied).
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organizations' and column_name = 'billing_required'
  ) then
    raise exception '0121 preflight #1.18 failed: organizations.billing_required already exists -- 0121 partially applied? Manual review required. STOP.';
  end if;

  -- 19. grandfather CHECK constraint must be ABSENT (never applied).
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.organization_subscriptions'::regclass
      and conname = 'organization_subscriptions_grandfather_has_no_stripe'
  ) then
    raise exception '0121 preflight #1.19 failed: constraint organization_subscriptions_grandfather_has_no_stripe already exists -- 0121 partially applied? Manual review required. STOP.';
  end if;

  raise notice '0121 PRE-MUTATION PREFLIGHT passed -- proceeding to schema changes.';
end $$;


-- -----------------------------------------------------------------------------
-- PART 1 -- subscription_tier: add the two public commercial tiers.
--
-- Plain ADD VALUE (no IF NOT EXISTS): preflight #1.11/12 has already proven
-- both labels absent, and this migration is a one-time manual apply that
-- should FAIL CLOSED rather than mask a partial application. This is a
-- deliberate deviation from the repo's usual `add value if not exists`
-- convention (0014/0024/0033/...), justified by the authoritative preflight.
-- -----------------------------------------------------------------------------
alter type public.subscription_tier add value 'essential';
alter type public.subscription_tier add value 'pro';

-- Unavoidable transaction boundary: PostgreSQL forbids using an enum value
-- in the transaction that added it, and PART 3 INSERTs tier='essential'/'pro'
-- rows. In the Supabase SQL Editor each top-level statement autocommits so
-- this is a no-op there; under a wrapped-transaction apply it is required.
-- Same pattern as 0033 / 0050. See FAILURE / ATOMICITY SEMANTICS above.
commit;


-- -----------------------------------------------------------------------------
-- PART 2 -- additive classification columns. NO `IF NOT EXISTS`: preflight
-- #1.17/#1.18 proved both columns absent, and silently accepting a
-- pre-existing column would mask a partial 0121. NOT NULL + constant DEFAULT
-- => filled at ADD COLUMN time, no table rewrite.
-- -----------------------------------------------------------------------------
alter table public.subscription_plans
  add column is_public boolean not null default false;

alter table public.organizations
  add column billing_required boolean not null default true;

comment on column public.subscription_plans.is_public is
  'true = a public self-service commercial plan shown in pricing/checkout (future filter: is_public AND is_active). false = a legacy plan retained only for existing/grandfathered subscriptions.';
comment on column public.organizations.billing_required is
  'false = legacy/pre-billing organization; a future fail-closed billing gate must NOT force it into Stripe checkout merely for lacking a subscription row. true (column default, inherited by orgs created after 0121) = normal SaaS billing rules apply. DISTINCT from organization_subscriptions.grandfathered_at (a permanent Stripe-free entitlement on a subscription row).';


-- -----------------------------------------------------------------------------
-- PART 3 -- SECOND validation (PRECHECK #2) + guarded catalog/backfill/
-- invariant. ONE DO block: PRECHECK #2 re-verifies every assumption the data
-- phase depends on (necessary because the enum `commit;` above already broke
-- atomicity), then every DATA write + the ADD CONSTRAINT run together. Any
-- failure inside this block RAISEs and rolls the block back with zero
-- partial catalog/backfill/constraint state.
-- -----------------------------------------------------------------------------
do $$
declare
  v_starter_id      uuid;
  v_professional_id uuid;
  v_enterprise_id   uuid;
  v_updated         integer;
begin
  -- ======================= PRECHECK #2 -- READ-ONLY =======================

  -- PART 1 / PART 2 landed as expected.
  if not exists (
    select 1 from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'subscription_tier'
      and e.enumlabel = 'essential'
  ) or not exists (
    select 1 from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'subscription_tier'
      and e.enumlabel = 'pro'
  ) then
    raise exception '0121 precheck #2 failed: subscription_tier is missing ''essential'' and/or ''pro'' after PART 1.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'subscription_plans' and column_name = 'is_public'
  ) then
    raise exception '0121 precheck #2 failed: subscription_plans.is_public missing after PART 2.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'organizations' and column_name = 'billing_required'
  ) then
    raise exception '0121 precheck #2 failed: organizations.billing_required missing after PART 2.';
  end if;
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.organization_subscriptions'::regclass
      and conname = 'organization_subscriptions_grandfather_has_no_stripe'
  ) then
    raise exception '0121 precheck #2 failed: constraint organization_subscriptions_grandfather_has_no_stripe already exists -- refusing to re-add.';
  end if;

  -- Production state still matches every assumption the data phase needs.
  if (select count(*) from public.organizations) <> 63 then
    raise exception '0121 precheck #2 failed: expected 63 organizations, found %. Production changed after the pre-mutation preflight -- STOP and review.',
      (select count(*) from public.organizations);
  end if;
  if (select count(*) from public.organization_subscriptions) <> 3 then
    raise exception '0121 precheck #2 failed: expected 3 organization_subscriptions rows, found %.',
      (select count(*) from public.organization_subscriptions);
  end if;
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0121 precheck #2 failed: expected 3 grandfathered subscription rows, found %.',
      (select count(*) from public.organization_subscriptions where grandfathered_at is not null);
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0121 precheck #2 failed: a grandfathered subscription row has a non-NULL Stripe id.';
  end if;

  if (select count(*) from public.subscription_plans where tier = 'starter') <> 1 then
    raise exception '0121 precheck #2 failed: expected exactly one starter plan.';
  end if;
  if (select count(*) from public.subscription_plans where tier = 'professional') <> 1 then
    raise exception '0121 precheck #2 failed: expected exactly one professional plan.';
  end if;
  if (select count(*) from public.subscription_plans where tier = 'enterprise') <> 1 then
    raise exception '0121 precheck #2 failed: expected exactly one enterprise plan.';
  end if;
  select id into v_starter_id      from public.subscription_plans where tier = 'starter';
  select id into v_professional_id from public.subscription_plans where tier = 'professional';
  select id into v_enterprise_id   from public.subscription_plans where tier = 'enterprise';

  if (select count(*) from public.organization_subscriptions where plan_id = v_professional_id) <> 2 then
    raise exception '0121 precheck #2 failed: expected 2 subscriptions referencing the professional plan, found %.',
      (select count(*) from public.organization_subscriptions where plan_id = v_professional_id);
  end if;
  if (select count(*) from public.organization_subscriptions where plan_id = v_enterprise_id) <> 1 then
    raise exception '0121 precheck #2 failed: expected 1 subscription referencing the enterprise plan, found %.',
      (select count(*) from public.organization_subscriptions where plan_id = v_enterprise_id);
  end if;
  if (select count(*) from public.organization_subscriptions where plan_id = v_starter_id) <> 0 then
    raise exception '0121 precheck #2 failed: the starter plan has % subscription reference(s) -- refusing to deactivate it.',
      (select count(*) from public.organization_subscriptions where plan_id = v_starter_id);
  end if;

  -- 'essential'/'pro' exist as labels now, so a tier comparison is safe here.
  if exists (select 1 from public.subscription_plans where tier in ('essential', 'pro')) then
    raise exception '0121 precheck #2 failed: an essential- or pro-tier plan row already exists.';
  end if;
  if exists (select 1 from public.subscription_plans where name in ('Essential', 'Pro')) then
    raise exception '0121 precheck #2 failed: a plan named "Essential" or "Pro" already exists.';
  end if;

  if (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0121 precheck #2 failed: stripe_webhook_events is not empty.';
  end if;
  if (select count(*) from public.billing_records) <> 0 then
    raise exception '0121 precheck #2 failed: billing_records is not empty.';
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where not (
      grandfathered_at is null
      or (stripe_customer_id is null
          and stripe_subscription_id is null
          and stripe_price_id is null)
    )
  ) then
    raise exception '0121 precheck #2 failed: an organization_subscriptions row violates the grandfather/no-Stripe invariant -- refusing to add the CHECK.';
  end if;

  -- ======================= DATA WRITES =======================

  -- 2a. Legacy plans -> not public.
  update public.subscription_plans set is_public = false
   where id in (v_starter_id, v_professional_id, v_enterprise_id);

  -- 2b. Starter -> inactive (precheck proved 0 references). Never deleted.
  update public.subscription_plans set is_active = false where id = v_starter_id;

  -- 2c. Essential -- public commercial plan. Limits 5 / 15 / 50 are SOFT
  --     display values (no enforcement). Stripe mapping stays NULL.
  insert into public.subscription_plans
    (tier, name, description,
     monthly_price_cents, annual_price_cents,
     max_users, max_trucks, max_active_loads,
     features, is_active, is_public,
     stripe_product_id, stripe_price_id_monthly, stripe_price_id_annual)
  values
    ('essential', 'Essential',
     'Core dispatch, fleet, partners, invoicing and documents for growing carriers.',
     5900, 59000,
     5, 15, 50,
     '["Loads & dispatch", "Drivers, trucks & trailers", "Brokers, customers & carriers", "Invoicing & payments", "Documents"]'::jsonb,
     true, true,
     null, null, null);

  -- 2d. Pro -- public commercial plan. NULL limits = unlimited. Stripe
  --     mapping stays NULL.
  insert into public.subscription_plans
    (tier, name, description,
     monthly_price_cents, annual_price_cents,
     max_users, max_trucks, max_active_loads,
     features, is_active, is_public,
     stripe_product_id, stripe_price_id_monthly, stripe_price_id_annual)
  values
    ('pro', 'Pro',
     'Everything in Essential plus settlements, compliance, QuickBooks, statements and factoring.',
     9900, 99000,
     null, null, null,
     '["Everything in Essential", "Settlements", "Compliance tracking", "QuickBooks integration", "Statements", "Advances & factoring"]'::jsonb,
     true, true,
     null, null, null);

  -- 2e. Classify the ENTIRE audited production population as legacy/pre-
  --     billing. No WHERE clause is intentional -- safe ONLY because
  --     precheck #2 proved exactly 63 rows; the row_count check is the
  --     second guard. Orgs created after 0121 default to
  --     billing_required = true.
  update public.organizations set billing_required = false;
  get diagnostics v_updated = row_count;
  if v_updated <> 63 then
    raise exception '0121 backfill failed: expected billing_required=false on 63 organizations, updated %.', v_updated;
  end if;

  -- 2f. Grandfather/no-Stripe DB invariant (prechecked clean above).
  alter table public.organization_subscriptions
    add constraint organization_subscriptions_grandfather_has_no_stripe
    check (
      grandfathered_at is null
      or (stripe_customer_id is null
          and stripe_subscription_id is null
          and stripe_price_id is null)
    );

  -- ======================= POSTCONDITIONS =======================
  if (select count(*) from public.organizations) <> 63 then
    raise exception '0121 postcondition failed: organization count changed.';
  end if;
  if (select count(*) from public.organizations where billing_required = false) <> 63 then
    raise exception '0121 postcondition failed: not all 63 organizations are billing_required=false.';
  end if;
  if (select count(*) from public.organization_subscriptions) <> 3 then
    raise exception '0121 postcondition failed: organization_subscriptions count changed.';
  end if;
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0121 postcondition failed: grandfathered subscription count changed.';
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0121 postcondition failed: a grandfathered subscription row has a Stripe id.';
  end if;
  if (select count(*) from public.subscription_plans where is_public = true and is_active = true) <> 2 then
    raise exception '0121 postcondition failed: expected exactly 2 public active plans.';
  end if;
  if (select count(*) from public.subscription_plans where is_public = true and tier not in ('essential', 'pro')) <> 0 then
    raise exception '0121 postcondition failed: a non-commercial plan is marked public.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where tier = 'essential' and name = 'Essential'
      and monthly_price_cents = 5900 and annual_price_cents = 59000
      and max_users = 5 and max_trucks = 15 and max_active_loads = 50
      and is_public = true and is_active = true
      and stripe_product_id is null and stripe_price_id_monthly is null and stripe_price_id_annual is null
  ) then
    raise exception '0121 postcondition failed: Essential plan row does not match the expected shape.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where tier = 'pro' and name = 'Pro'
      and monthly_price_cents = 9900 and annual_price_cents = 99000
      and max_users is null and max_trucks is null and max_active_loads is null
      and is_public = true and is_active = true
      and stripe_product_id is null and stripe_price_id_monthly is null and stripe_price_id_annual is null
  ) then
    raise exception '0121 postcondition failed: Pro plan row does not match the expected shape.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where tier = 'starter' and monthly_price_cents = 4900 and annual_price_cents = 49000
      and is_public = false and is_active = false
  ) then
    raise exception '0121 postcondition failed: Starter row not in the expected legacy state (price unchanged, is_public=false, is_active=false).';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where tier = 'professional' and monthly_price_cents = 14900 and annual_price_cents = 149000
      and is_public = false and is_active = true
  ) then
    raise exception '0121 postcondition failed: Professional row not in the expected legacy state (price unchanged, is_public=false, still active).';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where tier = 'enterprise' and monthly_price_cents = 39900 and annual_price_cents = 399000
      and is_public = false and is_active = true
  ) then
    raise exception '0121 postcondition failed: Enterprise row not in the expected legacy state (price unchanged, is_public=false, still active).';
  end if;

  raise notice '0121 complete: Essential + Pro public plans created (no Stripe objects); Starter/Professional/Enterprise set is_public=false; Starter deactivated (0 references); all 63 organizations set billing_required=false (new orgs default true); grandfather/no-Stripe CHECK added. No subscription, grandfather, or Stripe state changed.';
end $$;
