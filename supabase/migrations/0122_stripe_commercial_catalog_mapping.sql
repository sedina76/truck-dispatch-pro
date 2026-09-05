-- =============================================================================
-- 0122_stripe_commercial_catalog_mapping.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW.
--
-- ONE-TIME, FAIL-CLOSED mapping migration. Writes the six reviewed Stripe
-- SANDBOX catalog identifiers into the two commercial subscription_plans
-- rows created by 0121 (Essential, Pro). Nothing else changes.
--
-- The six identifiers below were manually copied from the Truck Dispatch Pro
-- Stripe SANDBOX Product/Price rows and are hard-coded reviewed literals --
-- NOT placeholders, NOT env vars, NOT browser/dynamic input:
--
--   Essential (id f54f87ae-556d-4ae4-8db6-0fbbbac4b798, tier 'essential')
--     stripe_product_id       = prod_VBimjDJ5rSyvx5
--     stripe_price_id_monthly = price_1UBLLMKvkXN4pgdED3H0zeNs   ($59 / month)
--     stripe_price_id_annual  = price_1UBLb6KvkXN4pgdEL1Orixr0   ($590 / year)
--
--   Pro (id 2a9138f2-0514-4e32-a178-2171776e69a3, tier 'pro')
--     stripe_product_id       = prod_VBjAx1MTHvWdCu
--     stripe_price_id_monthly = price_1UBLhuKvkXN4pgdERSZvfTmV   ($99 / month)
--     stripe_price_id_annual  = price_1UBLuQKvkXN4pgdEwGxao6YC   ($990 / year)
--
-- This migration:
--   * runs ONE guarded PL/pgSQL DO block (atomic: any RAISE rolls it back)
--   * asserts the full expected pre-0122 production state BEFORE the first
--     UPDATE (14 state guards + literal-ID validation)
--   * performs EXACTLY TWO UPDATE statements, each on one subscription_plans
--     row, setting ONLY stripe_product_id / stripe_price_id_monthly /
--     stripe_price_id_annual, each asserting ROW_COUNT = 1
--   * re-verifies the result (postconditions) before committing
--
-- This migration does NOT:
--   * use IF NOT EXISTS / UPSERT / INSERT
--   * change schema / enums / constraints / triggers / RLS
--   * touch any legacy plan (starter / professional / enterprise) row
--   * touch organizations, organization_subscriptions, billing_records,
--     stripe_webhook_events, middleware, signup, onboarding, billing UI,
--     QuickBooks (0115-0118), or migrations 0119-0121
--   * call Stripe or create any Stripe object
--
-- The automatic public.set_updated_at() trigger will bump
-- subscription_plans.updated_at on the two updated rows -- that is expected
-- and is the only incidental change.
--
-- ONE-TIME: a re-run raises at guard 5 ("Essential/Pro already has a
-- non-NULL Stripe mapping column"). It is NOT idempotent past that point,
-- by design.
-- =============================================================================

do $$
declare
  -- Internal DB anchors (0121).
  c_ess_id   constant uuid := 'f54f87ae-556d-4ae4-8db6-0fbbbac4b798';
  c_pro_id   constant uuid := '2a9138f2-0514-4e32-a178-2171776e69a3';

  -- Reviewed Stripe SANDBOX catalog literals.
  c_ess_prod constant text := 'prod_VBimjDJ5rSyvx5';
  c_ess_mo   constant text := 'price_1UBLLMKvkXN4pgdED3H0zeNs';
  c_ess_yr   constant text := 'price_1UBLb6KvkXN4pgdEL1Orixr0';
  c_pro_prod constant text := 'prod_VBjAx1MTHvWdCu';
  c_pro_mo   constant text := 'price_1UBLhuKvkXN4pgdERSZvfTmV';
  c_pro_yr   constant text := 'price_1UBLuQKvkXN4pgdEwGxao6YC';

  v_updated  integer;
  v_distinct integer;
begin
  -- ========================= PRE-MUTATION GUARDS =========================

  -- 1-2. exactly one Essential row and one Pro row.
  if (select count(*) from public.subscription_plans where tier = 'essential') <> 1 then
    raise exception '0122 guard 1 failed: expected exactly one tier=essential plan, found %.',
      (select count(*) from public.subscription_plans where tier = 'essential');
  end if;
  if (select count(*) from public.subscription_plans where tier = 'pro') <> 1 then
    raise exception '0122 guard 2 failed: expected exactly one tier=pro plan, found %.',
      (select count(*) from public.subscription_plans where tier = 'pro');
  end if;

  -- 3. Essential exact anchor (id + tier + name + prices + limits + flags).
  if not exists (
    select 1 from public.subscription_plans
    where id = c_ess_id
      and tier = 'essential'
      and name = 'Essential'
      and monthly_price_cents = 5900
      and annual_price_cents = 59000
      and max_users = 5
      and max_trucks = 15
      and max_active_loads = 50
      and is_public = true
      and is_active = true
  ) then
    raise exception '0122 guard 3 failed: the Essential row does not match its exact expected anchor (id/tier/name/prices/limits/flags).';
  end if;

  -- 4. Pro exact anchor.
  if not exists (
    select 1 from public.subscription_plans
    where id = c_pro_id
      and tier = 'pro'
      and name = 'Pro'
      and monthly_price_cents = 9900
      and annual_price_cents = 99000
      and max_users is null
      and max_trucks is null
      and max_active_loads is null
      and is_public = true
      and is_active = true
  ) then
    raise exception '0122 guard 4 failed: the Pro row does not match its exact expected anchor (id/tier/name/prices/unlimited-limits/flags).';
  end if;

  -- 5. all six target stripe_* columns on Essential/Pro are NULL.
  if exists (
    select 1 from public.subscription_plans
    where id in (c_ess_id, c_pro_id)
      and (stripe_product_id is not null
        or stripe_price_id_monthly is not null
        or stripe_price_id_annual is not null)
  ) then
    raise exception '0122 guard 5 failed: Essential and/or Pro already carries a non-NULL Stripe mapping column -- 0122 already applied? STOP.';
  end if;

  -- 6. legacy plans have all stripe_* NULL.
  if exists (
    select 1 from public.subscription_plans
    where tier in ('starter', 'professional', 'enterprise')
      and (stripe_product_id is not null
        or stripe_price_id_monthly is not null
        or stripe_price_id_annual is not null)
  ) then
    raise exception '0122 guard 6 failed: a legacy plan (starter/professional/enterprise) already carries a Stripe mapping.';
  end if;

  -- 7. NO subscription_plans row currently has any stripe_* mapping.
  if exists (
    select 1 from public.subscription_plans
    where stripe_product_id is not null
       or stripe_price_id_monthly is not null
       or stripe_price_id_annual is not null
  ) then
    raise exception '0122 guard 7 failed: some subscription_plans row already carries a Stripe mapping.';
  end if;

  -- 8. organizations count = 63.
  if (select count(*) from public.organizations) <> 63 then
    raise exception '0122 guard 8 failed: expected 63 organizations, found %.',
      (select count(*) from public.organizations);
  end if;

  -- 9. organizations with billing_required = false = 63.
  if (select count(*) from public.organizations where billing_required = false) <> 63 then
    raise exception '0122 guard 9 failed: expected 63 organizations with billing_required=false, found %.',
      (select count(*) from public.organizations where billing_required = false);
  end if;

  -- 10. organization_subscriptions count = 3.
  if (select count(*) from public.organization_subscriptions) <> 3 then
    raise exception '0122 guard 10 failed: expected 3 organization_subscriptions rows, found %.',
      (select count(*) from public.organization_subscriptions);
  end if;

  -- 11. grandfathered subscription count = 3.
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0122 guard 11 failed: expected 3 grandfathered subscription rows, found %.',
      (select count(*) from public.organization_subscriptions where grandfathered_at is not null);
  end if;

  -- 12. grandfathered subscriptions with any Stripe identifier = 0.
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0122 guard 12 failed: a grandfathered subscription row has a non-NULL Stripe id.';
  end if;

  -- 13. billing_records count = 0.
  if (select count(*) from public.billing_records) <> 0 then
    raise exception '0122 guard 13 failed: billing_records is not empty.';
  end if;

  -- 14. stripe_webhook_events count = 0.
  if (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0122 guard 14 failed: stripe_webhook_events is not empty.';
  end if;

  -- ========================= LITERAL-ID VALIDATION =========================

  -- Products: nonblank, start 'prod_', distinct.
  if btrim(c_ess_prod) = '' or btrim(c_pro_prod) = '' then
    raise exception '0122 id-validation failed: a Product id literal is blank.';
  end if;
  if left(c_ess_prod, 5) <> 'prod_' or left(c_pro_prod, 5) <> 'prod_' then
    raise exception '0122 id-validation failed: a Product id literal does not start with "prod_".';
  end if;
  if c_ess_prod = c_pro_prod then
    raise exception '0122 id-validation failed: the Essential and Pro Product ids are identical.';
  end if;

  -- Prices: nonblank, start 'price_', four distinct values, none equal a Product id.
  if btrim(c_ess_mo) = '' or btrim(c_ess_yr) = '' or btrim(c_pro_mo) = '' or btrim(c_pro_yr) = '' then
    raise exception '0122 id-validation failed: a Price id literal is blank.';
  end if;
  if left(c_ess_mo, 6) <> 'price_'
     or left(c_ess_yr, 6) <> 'price_'
     or left(c_pro_mo, 6) <> 'price_'
     or left(c_pro_yr, 6) <> 'price_' then
    raise exception '0122 id-validation failed: a Price id literal does not start with "price_".';
  end if;
  select count(*) into v_distinct
  from (select distinct u from unnest(array[c_ess_mo, c_ess_yr, c_pro_mo, c_pro_yr]) as t(u)) d;
  if v_distinct <> 4 then
    raise exception '0122 id-validation failed: the four Price id literals are not all distinct (% distinct).', v_distinct;
  end if;
  if c_ess_mo in (c_ess_prod, c_pro_prod)
     or c_ess_yr in (c_ess_prod, c_pro_prod)
     or c_pro_mo in (c_ess_prod, c_pro_prod)
     or c_pro_yr in (c_ess_prod, c_pro_prod) then
    raise exception '0122 id-validation failed: a Price id literal equals a Product id literal.';
  end if;

  -- ========================= WRITES (exactly two) =========================

  update public.subscription_plans
     set stripe_product_id       = c_ess_prod,
         stripe_price_id_monthly = c_ess_mo,
         stripe_price_id_annual  = c_ess_yr
   where id = c_ess_id
     and tier = 'essential';
  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    raise exception '0122 write failed: the Essential UPDATE affected % row(s), expected exactly 1.', v_updated;
  end if;

  update public.subscription_plans
     set stripe_product_id       = c_pro_prod,
         stripe_price_id_monthly = c_pro_mo,
         stripe_price_id_annual  = c_pro_yr
   where id = c_pro_id
     and tier = 'pro';
  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    raise exception '0122 write failed: the Pro UPDATE affected % row(s), expected exactly 1.', v_updated;
  end if;

  -- ========================= POSTCONDITIONS =========================

  -- Essential carries exactly its intended three ids, still public + active.
  if not exists (
    select 1 from public.subscription_plans
    where id = c_ess_id and tier = 'essential'
      and stripe_product_id = c_ess_prod
      and stripe_price_id_monthly = c_ess_mo
      and stripe_price_id_annual = c_ess_yr
      and is_public = true and is_active = true
  ) then
    raise exception '0122 postcondition failed: the Essential row does not carry exactly its intended three Stripe ids (or lost public/active).';
  end if;

  -- Pro carries exactly its intended three ids, still public + active.
  if not exists (
    select 1 from public.subscription_plans
    where id = c_pro_id and tier = 'pro'
      and stripe_product_id = c_pro_prod
      and stripe_price_id_monthly = c_pro_mo
      and stripe_price_id_annual = c_pro_yr
      and is_public = true and is_active = true
  ) then
    raise exception '0122 postcondition failed: the Pro row does not carry exactly its intended three Stripe ids (or lost public/active).';
  end if;

  -- All six mapped values non-NULL and correctly prefixed (re-derived from
  -- the table, not the constants).
  if exists (
    select 1 from public.subscription_plans
    where id in (c_ess_id, c_pro_id)
      and (stripe_product_id is null
        or stripe_price_id_monthly is null
        or stripe_price_id_annual is null
        or left(stripe_product_id, 5) <> 'prod_'
        or left(stripe_price_id_monthly, 6) <> 'price_'
        or left(stripe_price_id_annual, 6) <> 'price_')
  ) then
    raise exception '0122 postcondition failed: a mapped Stripe id is NULL or malformed.';
  end if;

  -- 2 distinct Product ids; 4 distinct Price ids; monthly != annual per plan.
  if (select count(distinct stripe_product_id) from public.subscription_plans where stripe_product_id is not null) <> 2 then
    raise exception '0122 postcondition failed: expected exactly 2 distinct stripe_product_id values.';
  end if;
  select count(*) into v_distinct
  from (
    select distinct p
    from public.subscription_plans s
    cross join lateral unnest(array[s.stripe_price_id_monthly, s.stripe_price_id_annual]) as t(p)
    where s.id in (c_ess_id, c_pro_id)
  ) d;
  if v_distinct <> 4 then
    raise exception '0122 postcondition failed: the four mapped Price ids are not all distinct (% distinct).', v_distinct;
  end if;
  if exists (
    select 1 from public.subscription_plans
    where id in (c_ess_id, c_pro_id)
      and stripe_price_id_monthly = stripe_price_id_annual
  ) then
    raise exception '0122 postcondition failed: a plan has stripe_price_id_monthly = stripe_price_id_annual.';
  end if;

  -- Exactly two mapped rows, and they are precisely Essential + Pro.
  if (select count(*) from public.subscription_plans where stripe_product_id is not null) <> 2 then
    raise exception '0122 postcondition failed: expected exactly 2 subscription_plans rows with a non-NULL stripe_product_id.';
  end if;
  if exists (
    select 1 from public.subscription_plans
    where stripe_product_id is not null and id not in (c_ess_id, c_pro_id)
  ) then
    raise exception '0122 postcondition failed: a row other than Essential/Pro carries a stripe_product_id.';
  end if;

  -- Legacy plans remain completely unmapped.
  if exists (
    select 1 from public.subscription_plans
    where tier in ('starter', 'professional', 'enterprise')
      and (stripe_product_id is not null
        or stripe_price_id_monthly is not null
        or stripe_price_id_annual is not null)
  ) then
    raise exception '0122 postcondition failed: a legacy plan now carries a Stripe mapping.';
  end if;

  -- Global counts unchanged.
  if (select count(*) from public.organizations) <> 63
     or (select count(*) from public.organizations where billing_required = false) <> 63 then
    raise exception '0122 postcondition failed: organizations / billing_required counts changed.';
  end if;
  if (select count(*) from public.organization_subscriptions) <> 3
     or (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0122 postcondition failed: organization_subscriptions / grandfathered counts changed.';
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0122 postcondition failed: a grandfathered subscription row gained a Stripe id.';
  end if;
  if (select count(*) from public.billing_records) <> 0
     or (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0122 postcondition failed: billing_records / stripe_webhook_events are no longer empty.';
  end if;

  raise notice '0122 complete: Essential -> %, %, % ; Pro -> %, %, %. Exactly two subscription_plans rows updated; no other row, table, or object changed.',
    c_ess_prod, c_ess_mo, c_ess_yr, c_pro_prod, c_pro_mo, c_pro_yr;
end $$;
