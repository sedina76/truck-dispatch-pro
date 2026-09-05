-- =============================================================================
-- 0120_grandfather_existing_pilot_orgs.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW.
--
-- Grandfather EXACTLY THREE explicitly product-owner-approved organizations
-- onto pre-Stripe entitlements, so that when the SaaS-billing gate is later
-- tightened they retain full access with NO Stripe customer / card:
--
--   1. Kali Freight LLC   054ef09f-6cfb-461a-aeb2-3ec9fdd62d47
--        - has NO organization_subscriptions row today
--        - 0120 INSERTS one: Professional / active / monthly,
--          grandfathered_at = now(), every Stripe field NULL,
--          current_period_start/end NULL (permanent entitlement, not a
--          Stripe billing period -- see note below).
--
--   2. Kali Freights LLC  11111111-0000-0000-0000-000000000001
--        - has ONE existing pre-Stripe row (Professional / active / monthly)
--        - 0120 sets grandfathered_at = coalesce(grandfathered_at, now())
--          and touches NOTHING else. Its legacy plan/status/cycle/periods
--          are intentionally preserved.
--
--   3. Kali Logistic      1f29315a-e193-481f-bd5f-5f1b40da7f05
--        - has ONE existing pre-Stripe row (Enterprise / trialing / monthly)
--        - 0120 sets grandfathered_at = coalesce(grandfathered_at, now())
--          and touches NOTHING else. Its legacy plan/status/cycle/periods
--          are intentionally preserved.
--
-- This migration DOES NOT:
--   * grandfather any other organization -- NO "INSERT ... SELECT every org
--     without a subscription". The TEST-* fixtures, "ASAM's Group LLC",
--     "ASAM's Group LLC.", and "Medfusion" are DELIBERATELY EXCLUDED.
--   * change plan_id / status / billing_cycle / periods / cancel flags /
--     trial_end / any Stripe column on the two existing rows
--   * rename plans, change prices, change feature limits, or create
--     Essential/Pro -- the public launch catalog is a separate phase
--   * create any Stripe Product / Price / Customer / Subscription, or call
--     Stripe
--   * touch billing_records, stripe_webhook_events, middleware, signup,
--     checkout, QuickBooks (0115-0118), or 0119
--
-- current_period_start / current_period_end nullability: both columns are
-- `timestamptz` with NO NOT NULL and NO default (0002_core_saas_tables.sql
-- lines 139-140). Audited src/: the only references are WRITES on INSERT in
-- two superadmin actions (companies/actions.ts, companies/platform-actions.ts);
-- NOTHING in the app READS these columns. So a NULL period on a permanent
-- grandfather row breaks nothing, and 0120 does not fabricate a renewal date.
--
-- STRUCTURE: one PL/pgSQL DO block, explicitly TWO-PHASE.
--   PHASE 1 is 100% read-only: EVERY production-state precondition
--   (A, H, E/F/G, C, D, B, plus a drift check) is validated with ZERO
--   mutations. Only if all pass does PHASE 2 run any INSERT/UPDATE. Any
--   PHASE 1 RAISE aborts the statement before a single row is written.
--   Re-running the already-applied migration is a clean no-op: PHASE 1
--   accepts an existing Kali Freight LLC row ONLY if it matches, field for
--   field, the exact row PHASE 2 creates.
-- =============================================================================

do $$
declare
  -- The three approved organizations. UUIDs verified read-only against
  -- production immediately before authoring (exactly one exact-name match
  -- for "Kali Freight LLC").
  v_kf_id  constant uuid := '054ef09f-6cfb-461a-aeb2-3ec9fdd62d47';  -- Kali Freight LLC
  v_kfs_id constant uuid := '11111111-0000-0000-0000-000000000001';  -- Kali Freights LLC
  v_kl_id  constant uuid := '1f29315a-e193-481f-bd5f-5f1b40da7f05';  -- Kali Logistic

  v_professional_plan_id uuid;
  v_kf_has_row           boolean;
  v_kf_prior_ok          boolean := false;   -- exact prior-0120 grandfather already present?
  v_total_subs           integer;
  v_grandfathered        integer;
  v_expected_total       integer;
begin
  -- ==========================================================================
  -- PHASE 1 -- READ-ONLY VALIDATION. No INSERT/UPDATE anywhere in this phase.
  -- ==========================================================================

  -- A -- all three approved organizations exist, by id AND by exact name
  --      (guards against an id typo silently pointing at another tenant).
  if not exists (select 1 from public.organizations where id = v_kf_id  and name = 'Kali Freight LLC') then
    raise exception '0120 precondition A failed: % is not an organization named "Kali Freight LLC".', v_kf_id;
  end if;
  if not exists (select 1 from public.organizations where id = v_kfs_id and name = 'Kali Freights LLC') then
    raise exception '0120 precondition A failed: % is not an organization named "Kali Freights LLC".', v_kfs_id;
  end if;
  if not exists (select 1 from public.organizations where id = v_kl_id  and name = 'Kali Logistic') then
    raise exception '0120 precondition A failed: % is not an organization named "Kali Logistic".', v_kl_id;
  end if;

  -- H -- the Professional plan resolves to EXACTLY ONE active row. Never
  --      hardcoded: resolved by the stable (tier, is_active) values.
  if (select count(*) from public.subscription_plans where tier = 'professional' and is_active = true) <> 1 then
    raise exception '0120 precondition H failed: expected exactly one active professional plan, found %.',
      (select count(*) from public.subscription_plans where tier = 'professional' and is_active = true);
  end if;
  select id into v_professional_plan_id
  from public.subscription_plans
  where tier = 'professional' and is_active = true;

  -- E/F/G -- NONE of the three approved orgs may have ANY Stripe linkage.
  --          A Stripe-linked subscription must NEVER be grandfathered.
  if exists (
    select 1 from public.organization_subscriptions
    where organization_id in (v_kf_id, v_kfs_id, v_kl_id)
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0120 precondition E/F/G failed: one of the approved orgs has a Stripe-linked subscription -- refusing to grandfather.';
  end if;

  -- C -- Kali Freights LLC has EXACTLY one subscription row.
  if (select count(*) from public.organization_subscriptions where organization_id = v_kfs_id) <> 1 then
    raise exception '0120 precondition C failed: Kali Freights LLC must have exactly one subscription row, found %.',
      (select count(*) from public.organization_subscriptions where organization_id = v_kfs_id);
  end if;

  -- D -- Kali Logistic has EXACTLY one subscription row.
  if (select count(*) from public.organization_subscriptions where organization_id = v_kl_id) <> 1 then
    raise exception '0120 precondition D failed: Kali Logistic must have exactly one subscription row, found %.',
      (select count(*) from public.organization_subscriptions where organization_id = v_kl_id);
  end if;

  -- B -- Kali Freight LLC state.
  --   * no row      -> PHASE 2 will INSERT it.
  --   * exact prior-0120 grandfather row (matches EVERY semantic field 0120
  --     itself sets) -> accepted as a completed prior run; PHASE 2 skips it.
  --   * a row that differs in ANY expected field -> RAISE. 0120 never
  --     normalizes or overwrites an unexpected subscription.
  v_kf_has_row := exists (select 1 from public.organization_subscriptions where organization_id = v_kf_id);

  if v_kf_has_row then
    v_kf_prior_ok := exists (
      select 1 from public.organization_subscriptions
      where organization_id        = v_kf_id
        and plan_id                = v_professional_plan_id
        and status                 = 'active'
        and billing_cycle          = 'monthly'
        and grandfathered_at       is not null
        and current_period_start   is null
        and current_period_end     is null
        and cancel_at_period_end   = false
        and canceled_at            is null
        and trial_end              is null
        and checkout_pending_since is null
        and stripe_customer_id     is null
        and stripe_subscription_id is null
        and stripe_price_id        is null
    );
    if not v_kf_prior_ok then
      raise exception '0120 precondition B failed: Kali Freight LLC already has a subscription row that does NOT match the exact 0120 grandfather shape -- refusing to normalize or overwrite it.';
    end if;
  end if;

  -- Drift check -- this migration is scoped to the audited production state,
  -- not written to be generally reusable. The ONLY two legitimate totals
  -- are 2 (Kali Freight LLC row not yet created) and 3 (an exact prior-0120
  -- run already created it). Anything else means the subscription
  -- population changed between the audit and this application -- a human
  -- must re-review before proceeding. This does not conflict with
  -- idempotency: both legitimate states are accepted.
  select count(*) into v_total_subs from public.organization_subscriptions;
  v_expected_total := case when v_kf_prior_ok then 3 else 2 end;
  if v_total_subs <> v_expected_total then
    raise exception '0120 drift check failed: expected exactly % organization_subscriptions rows, found %. Production changed since the audit -- re-review before applying.',
      v_expected_total, v_total_subs;
  end if;

  -- ==========================================================================
  -- PHASE 2 -- WRITES. Reached only after EVERY PHASE 1 precondition passed.
  -- ==========================================================================

  -- Kali Freight LLC -- INSERT only if genuinely missing. (v_kf_prior_ok
  -- means the exact row already exists; nothing to do.)
  if not v_kf_has_row then
    insert into public.organization_subscriptions (
      organization_id, plan_id, status, billing_cycle,
      current_period_start, current_period_end,
      cancel_at_period_end, canceled_at,
      stripe_customer_id, stripe_subscription_id, stripe_price_id,
      trial_end, checkout_pending_since,
      grandfathered_at
    ) values (
      v_kf_id, v_professional_plan_id, 'active', 'monthly',
      null, null,                    -- permanent grandfather, not a Stripe period
      false, null,
      null, null, null,              -- no Stripe linkage
      null, null,                    -- no fabricated trial, no checkout in flight
      now()
    );
  end if;

  -- Kali Freights LLC + Kali Logistic -- stamp grandfathered_at ONLY.
  -- coalesce() preserves an existing timestamp from a prior run. Legacy
  -- plan/status/cycle/periods are intentionally left as-is.
  update public.organization_subscriptions
     set grandfathered_at = coalesce(grandfathered_at, now())
   where organization_id = v_kfs_id;

  update public.organization_subscriptions
     set grandfathered_at = coalesce(grandfathered_at, now())
   where organization_id = v_kl_id;

  -- ==========================================================================
  -- POSTCONDITIONS.
  -- ==========================================================================
  select count(*) into v_total_subs from public.organization_subscriptions;
  if v_total_subs <> 3 then
    raise exception '0120 postcondition failed: expected 3 organization_subscriptions rows, found %.', v_total_subs;
  end if;

  select count(*) into v_grandfathered
  from public.organization_subscriptions where grandfathered_at is not null;
  if v_grandfathered <> 3 then
    raise exception '0120 postcondition failed: expected 3 grandfathered rows, found %.', v_grandfathered;
  end if;

  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and organization_id not in (v_kf_id, v_kfs_id, v_kl_id)
  ) then
    raise exception '0120 postcondition failed: a non-approved organization is marked grandfathered.';
  end if;

  -- Kali Freight LLC row matches the exact Professional / active / monthly /
  -- permanent-grandfather shape (same predicate PHASE 1 accepts).
  if not exists (
    select 1 from public.organization_subscriptions
    where organization_id        = v_kf_id
      and plan_id                = v_professional_plan_id
      and status                 = 'active'
      and billing_cycle          = 'monthly'
      and grandfathered_at       is not null
      and current_period_start   is null
      and current_period_end     is null
      and cancel_at_period_end   = false
      and canceled_at            is null
      and trial_end              is null
      and checkout_pending_since is null
      and stripe_customer_id     is null
      and stripe_subscription_id is null
      and stripe_price_id        is null
  ) then
    raise exception '0120 postcondition failed: the Kali Freight LLC subscription row does not match the expected Professional/active/monthly permanent-grandfather shape.';
  end if;

  -- All three approved grandfather rows have every Stripe id NULL.
  if exists (
    select 1 from public.organization_subscriptions
    where organization_id in (v_kf_id, v_kfs_id, v_kl_id)
      and (stripe_customer_id is not null
        or stripe_subscription_id is not null
        or stripe_price_id is not null)
  ) then
    raise exception '0120 postcondition failed: an approved grandfather row has a non-NULL Stripe id.';
  end if;

  raise notice '0120 complete: grandfathered exactly Kali Freight LLC (Professional/active/monthly, periods NULL), Kali Freights LLC, and Kali Logistic. No Stripe objects created. No other organization, plan, or Stripe column touched.';
end $$;
