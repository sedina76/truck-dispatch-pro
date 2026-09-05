-- =============================================================================
-- 0119_stripe_subscription_foundation.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW.
--
-- Stripe SaaS-subscription foundation, Phase 1: SCHEMA + SECURITY ONLY.
-- Extends the EXISTING SaaS billing tables from 0002 (subscription_plans,
-- organization_subscriptions, billing_records) -- no parallel subscription
-- model is created. Adds one platform-internal table
-- (stripe_webhook_events) for durable webhook idempotency / replay
-- protection, plus the service-role-only atomic claim/retry primitives
-- (claim_/complete_/fail_stripe_webhook_event) that freeze the
-- exactly-once-business-effect contract in the database itself rather than
-- in handler code.
--
-- This migration DOES NOT:
--   * install or call Stripe, or create any Stripe Product / Price / object
--   * insert, update, or delete ANY existing row (no grandfather rows --
--     that is 0120, reviewed separately)
--   * change any organization, subscription, or plan
--   * relax or alter any existing RLS policy
--   * touch freight billing (public.invoices / invoice_line_items /
--     payments / billing packets / AR) -- SaaS billing stays separate
--   * touch QuickBooks (0115-0118) -- Stripe SaaS billing is a different
--     system from the tenant's own QuickBooks accounting integration
--   * change middleware, application code, or deployment
--
-- Everything here is additive: new enum values, new nullable columns, new
-- UNIQUE constraints (all on columns proven duplicate-free by
-- VERIFY_0119_PREFLIGHT.sql), one new table, and three service-role-only
-- functions (PART 6). No existing row, policy, trigger, or function is
-- changed or removed.
--
-- Authority split (frozen product direction): Truck Dispatch Pro is
-- authoritative for application capabilities/entitlements; Stripe is
-- authoritative for subscription/payment state and the active Price.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- PART 1 -- subscription_status enum: add the two Stripe Subscription.status
-- values the enum is missing. Additive only; nothing is removed or renamed.
--
-- Existing values (0001, unchanged since):
--   trialing, active, past_due, canceled, incomplete, paused
--
-- PostgreSQL note: `alter type ... add value` is permitted inside a
-- transaction on PG12+ as long as the new label is not USED in the same
-- transaction (as a default, comparison, cast literal, or CHECK operand).
-- 0119 never references these new labels again anywhere below, so NO
-- `commit;` boundary is needed -- this is the add-only pattern this repo
-- already uses in 0024 / 0056 / 0083. (0033 / 0050 add `commit;` only
-- because they DO use their new values in a later CHECK/DEFAULT in the
-- same file; that does not apply here.) `if not exists` makes re-running
-- the file a no-op.
--
-- NOT added: 'checkout_pending' / 'no_subscription'. Those are application
-- provisioning conditions (see organization_subscriptions.checkout_pending_since
-- below, and "no row at all"), NOT Stripe Subscription.status values.
-- -----------------------------------------------------------------------------
alter type public.subscription_status add value if not exists 'incomplete_expired';
alter type public.subscription_status add value if not exists 'unpaid';


-- -----------------------------------------------------------------------------
-- PART 2 -- organization_subscriptions: Stripe foundation columns + intended
-- uniqueness + updated_at maintenance.
--
-- Existing columns (0002, confirmed live -- no later ALTER):
--   id, organization_id, plan_id, status, billing_cycle,
--   stripe_customer_id, stripe_subscription_id,
--   current_period_start, current_period_end,
--   cancel_at_period_end, canceled_at, created_at, updated_at
-- -----------------------------------------------------------------------------

-- The Stripe Price the subscription is currently on (mirrored from
-- subscription.items.data[0].price.id by the webhook handler, later phase).
-- Opaque Stripe string -- NOT a credential, NOT FK'd to subscription_plans
-- (the plan<->price mapping lives on subscription_plans, PART 3).
alter table public.organization_subscriptions
  add column if not exists stripe_price_id text;

-- Stripe subscription.trial_end (14-day trial per frozen product direction).
alter table public.organization_subscriptions
  add column if not exists trial_end timestamptz;

-- Application provisioning marker: set when a Checkout Session is created,
-- cleared when checkout.session.completed / subscription.created is
-- processed. A value older than the checkout window ==> abandoned checkout.
-- This is deliberately a timestamp on the row, NOT a subscription_status
-- enum value.
alter table public.organization_subscriptions
  add column if not exists checkout_pending_since timestamptz;

-- Set ONLY by migration 0120 (grandfather backfill, reviewed separately):
-- NON-NULL marks an organization that predates paid billing and is on
-- full/Pro access with no Stripe customer or card. Column defined here so
-- 0120 is a pure data migration.
--
-- Why grandfathered_at (a timestamp) and NOT an is_comp boolean:
--   * It is already a boolean signal (IS NOT NULL) AND carries "since
--     when" for audit/reporting -- strictly more information than a bare
--     boolean.
--   * A future genuinely-different concept (a comped partner/free deal
--     that is NOT a legacy pre-billing org) deserves its own explicit
--     column at that time, not an overloaded reuse of this one.
--   0119 therefore adds grandfathered_at ONLY; no is_comp.
alter table public.organization_subscriptions
  add column if not exists grandfathered_at timestamptz;

comment on column public.organization_subscriptions.stripe_price_id is
  'Active Stripe Price id, mirrored from Stripe by the webhook handler. Opaque; never client-supplied.';
comment on column public.organization_subscriptions.trial_end is
  'Stripe subscription.trial_end, mirrored from Stripe.';
comment on column public.organization_subscriptions.checkout_pending_since is
  'App provisioning marker: Checkout Session created at this time, not yet confirmed by webhook. Not a Stripe status.';
comment on column public.organization_subscriptions.grandfathered_at is
  'Non-null = organization predates paid billing; full access, no Stripe customer required. Written only by migration 0120.';

-- Intended uniqueness. PostgreSQL UNIQUE allows multiple NULLs, so the many
-- organizations with no row yet, and the existing rows whose stripe_* ids
-- are NULL, are all unaffected. Guarded by VERIFY_0119_PREFLIGHT.sql
-- sections D / E / F returning zero conflict rows.
alter table public.organization_subscriptions
  add constraint organization_subscriptions_organization_id_key unique (organization_id);
alter table public.organization_subscriptions
  add constraint organization_subscriptions_stripe_customer_id_key unique (stripe_customer_id);
alter table public.organization_subscriptions
  add constraint organization_subscriptions_stripe_subscription_id_key unique (stripe_subscription_id);

-- updated_at maintenance: 0009 already attached public.set_updated_at() to
-- every public table that had an updated_at column when 0009 ran (this one
-- did, from 0002). Re-assert idempotently so the trigger is explicit in
-- this file and guaranteed present regardless of environment drift.
drop trigger if exists set_updated_at on public.organization_subscriptions;
create trigger set_updated_at before update on public.organization_subscriptions
  for each row execute function public.set_updated_at();


-- -----------------------------------------------------------------------------
-- PART 3 -- subscription_plans <-> Stripe Price mapping.
--
-- Design decision: extend subscription_plans DIRECTLY rather than add a
-- child price table. For the frozen launch (2 public plans -- ESSENTIAL,
-- PRO -- USD only, exactly two billing cycles that already live on
-- organization_subscriptions.billing_cycle) a child table adds a join and a
-- lifecycle for no benefit. If multi-currency / regional pricing is needed
-- later, introduce subscription_plan_prices THEN and backfill from these
-- columns. All nullable; no Stripe objects are created here.
--
-- The server maps (tier, billing_cycle) -> the correct column below to get
-- the Price id. A browser-supplied Stripe Price id is never trusted.
-- -----------------------------------------------------------------------------
alter table public.subscription_plans
  add column if not exists stripe_product_id text;
alter table public.subscription_plans
  add column if not exists stripe_price_id_monthly text;
alter table public.subscription_plans
  add column if not exists stripe_price_id_annual text;

comment on column public.subscription_plans.stripe_product_id is
  'Stripe Product id for this plan/tier. Nullable until Stripe objects are created in a later phase.';
comment on column public.subscription_plans.stripe_price_id_monthly is
  'Stripe Price id for the monthly cycle. Server-resolved from (tier, billing_cycle); never client-supplied.';
comment on column public.subscription_plans.stripe_price_id_annual is
  'Stripe Price id for the annual cycle. Server-resolved from (tier, billing_cycle); never client-supplied.';


-- -----------------------------------------------------------------------------
-- PART 4 -- billing_records idempotency.
--
-- billing_records (0002) is the ONLY SaaS invoice-history table; no second
-- one is created. UNIQUE(stripe_invoice_id) lets invoice.paid /
-- invoice.payment_failed deliveries upsert instead of duplicating. NULLs
-- allowed (rows not sourced from a Stripe invoice). Guarded by
-- VERIFY_0119_PREFLIGHT.sql section G.
-- -----------------------------------------------------------------------------
alter table public.billing_records
  add constraint billing_records_stripe_invoice_id_key unique (stripe_invoice_id);


-- -----------------------------------------------------------------------------
-- PART 5 -- stripe_webhook_events: platform-internal webhook idempotency /
-- replay protection + operational audit.
--
-- CONTRACT (frozen here; the raceable transitions live in the PART 6
-- functions, NOT in handler code):
--
--   Stripe delivers each event AT LEAST ONCE, possibly concurrently, and
--   redelivers a failing endpoint for ~3 days. This table gives us
--   exactly-once BUSINESS EFFECT as far as the DB can guarantee.
--
--   state machine (status column):
--     received   -- row persisted with the verified payload; no worker has
--                   claimed it yet.
--     processing -- a worker has claimed it and is running business effects.
--                   Carries last_attempt_at.
--     processed  -- TERMINAL. Business effects ran exactly once. A duplicate
--                   Stripe delivery must return 2xx and MUST NOT run effects
--                   again.
--     failed     -- this attempt failed; RETRYABLE. A duplicate Stripe
--                   delivery (or a scheduled sweep) may reclaim and
--                   reprocess it. Never creates a second row.
--
--   The handler NEVER does "INSERT ON CONFLICT DO NOTHING; if 0 rows -> 200".
--   That loses a 'failed' event on its retry. Instead it calls
--   public.claim_stripe_webhook_event(...) which atomically inserts-if-new
--   and then transitions received | failed | STALE-processing -> processing
--   in a single UPDATE ... RETURNING (concurrent callers serialize on the
--   row lock; exactly one wins). It returns (result, claim_token):
--     ('claimed', <new uuid>)        -> run business effects, then call
--                                       complete_/fail_ WITH that token
--     ('already_processed', NULL)    -> return 2xx, do NOT run effects
--     ('already_in_progress', NULL)  -> another worker holds a fresh claim;
--                                       return 2xx (Stripe redelivers if
--                                       that worker dies) -- do NOT run effects
--
--   CLAIM OWNERSHIP (claim_token): EVERY successful transition into
--   'processing' -- first claim, retry-after-failure, AND stale reclaim --
--   generates a NEW claim_token (gen_random_uuid()) in the same atomic
--   UPDATE, which invalidates any prior worker's token. complete_ and
--   fail_ require the caller to present a token that still matches the
--   row, so a slow worker whose claim was stolen by a stale reclaim gets
--   FALSE and cannot overwrite the new claimant's result. "status =
--   'processing' AND claim_token = <mine>" is real ownership; "status =
--   'processing'" alone is not.
--
--   CRASH / STALE CLAIM: a 'processing' row whose last_attempt_at is older
--   than the caller-supplied p_stale_after (default 15 min) is reclaimable
--   by claim_stripe_webhook_event -- recovery needs no manual row deletion.
--   The single atomic UPDATE guarantees two fresh workers can never both
--   claim the same event, and rotates the token so the crashed worker's
--   token is dead.
--
--   Invariant: claim_token IS NOT NULL  <=>  status = 'processing'
--   (enforced by stripe_webhook_events_claim_token_shape). It is cleared
--   on both terminal transitions ('processed' and 'failed') so a terminal
--   row unambiguously has no live owner.
--
--   PAYLOAD: written exactly once, on first receipt (INSERT ... ON CONFLICT
--   (stripe_event_id) DO NOTHING). No retry -- failed or processed -- ever
--   rewrites it; the original verified Stripe event is preserved for audit.
--
-- PLATFORM INTERNAL: tenants must not read or write webhook rows. RLS is
-- enabled with NO policies, table privileges are revoked from public /
-- anon / authenticated, and the PART 6 claim/retry functions are
-- service-role only. service_role (used by the handler, bypasses RLS) is
-- deliberately left with its normal access.
-- -----------------------------------------------------------------------------
create table public.stripe_webhook_events (
  id uuid primary key default gen_random_uuid(),

  -- Stripe Event.id -- the idempotency key. Opaque; NOT a credential.
  stripe_event_id text not null unique check (btrim(stripe_event_id) <> ''),
  -- Stripe Event.type, e.g. 'customer.subscription.updated'.
  type text not null,
  -- Stripe Event.api_version, for forward-compat debugging.
  api_version text,
  -- The verified Stripe event payload (webhook signature checked before
  -- insert). Platform-internal SENSITIVE operational data: a Stripe event
  -- may carry customer / business / contact / billing metadata (names,
  -- emails, addresses, card brand + last4, amounts). It does NOT contain
  -- our Stripe API secret -- but it is never tenant-accessible and is not
  -- "non-secret". Written exactly once on first receipt; never rewritten
  -- by a retry (original verified event preserved for audit).
  payload jsonb not null,

  -- Best-effort resolved tenant (client_reference_id / metadata /
  -- stripe_customer_id lookup). NOT required at initial receipt -- stays
  -- null until resolution succeeds, and is re-nulled if the org is later
  -- deleted (ON DELETE SET NULL) so the event row + its idempotency
  -- guarantee survive organization deletion.
  organization_id uuid references public.organizations (id) on delete set null,

  -- State machine -- see PART 5 contract above and the PART 6 functions.
  --   received -> processing -> processed (terminal) | failed (retryable);
  --   failed -> processing (reclaim);  stale processing -> processing (reclaim).
  status text not null default 'received'
    check (status in ('received', 'processing', 'processed', 'failed')),

  -- Ownership token for the CURRENT 'processing' claim. claim_stripe_webhook_event
  -- generates a fresh gen_random_uuid() on EVERY successful transition into
  -- 'processing' (first claim, retry-after-failure, stale reclaim), in the
  -- same atomic UPDATE -- so a prior worker's token is invalidated the
  -- instant a reclaim commits. complete_/fail_ require this exact token to
  -- match, which is what makes a stale worker unable to overwrite the new
  -- claimant. Invariant (enforced below): non-null iff status='processing';
  -- cleared on 'processed' and on 'failed'.
  claim_token uuid,

  -- Error text from the most recent failed attempt. Set by
  -- fail_stripe_webhook_event and RETAINED on the failed row for
  -- debugging; cleared when the event is next (re)claimed and on
  -- successful completion.
  error text,
  -- Count of processing attempts actually STARTED. default 0 = row
  -- persisted but never claimed; claim_stripe_webhook_event increments it
  -- by exactly one on each successful transition into 'processing'
  -- (including a stale reclaim).
  attempts integer not null default 0,
  -- Set by claim_stripe_webhook_event on every claim. A 'processing' row
  -- whose last_attempt_at is older than the caller's p_stale_after is
  -- treated as a crashed worker and may be reclaimed.
  last_attempt_at timestamptz,

  -- Stripe Event.created (converted from unix seconds). Used for
  -- last-writer-wins ordering when Stripe redelivers out of order.
  stripe_created_at timestamptz,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Ownership-token integrity: a token exists exactly while the row is
  -- claimed. Every PART 6 transition maintains this; the CHECK is the
  -- backstop against a future handler bug.
  constraint stripe_webhook_events_claim_token_shape
    check ((claim_token is not null) = (status = 'processing'))
);

comment on table public.stripe_webhook_events is
  'Platform-internal Stripe webhook idempotency / replay protection + operational audit. One row per Stripe Event.id; state machine received->processing->processed|failed driven by the service-role-only claim_/complete_/fail_stripe_webhook_event functions. NOT tenant-accessible (RLS on, no policies; privileges revoked from public/anon/authenticated). Written only by the service-role webhook handler. The payload is the verified Stripe event and is SENSITIVE operational data -- it may contain customer/business/contact/billing metadata; it is never tenant-accessible and is not "non-secret" (it does not, however, contain our Stripe API secret).';

create index stripe_webhook_events_status_idx on public.stripe_webhook_events (status);
create index stripe_webhook_events_type_idx on public.stripe_webhook_events (type);
create index stripe_webhook_events_org_idx on public.stripe_webhook_events (organization_id);
create index stripe_webhook_events_received_at_idx on public.stripe_webhook_events (received_at);
-- Supports the stale-claim sweep / ops "stuck events" view:
--   where status = 'processing' and last_attempt_at < now() - <threshold>
create index stripe_webhook_events_stale_claim_idx
  on public.stripe_webhook_events (status, last_attempt_at);

drop trigger if exists set_updated_at on public.stripe_webhook_events;
create trigger set_updated_at before update on public.stripe_webhook_events
  for each row execute function public.set_updated_at();

-- RLS on, NO policies at all -> no authenticated/anon row is ever visible
-- or writable. service_role bypasses RLS and is how the handler writes.
alter table public.stripe_webhook_events enable row level security;

-- Belt-and-suspenders on top of "no policies": remove the table privileges
-- Supabase's default grants would otherwise give anon + authenticated.
-- service_role keeps its normal full access (not named here).
revoke all on public.stripe_webhook_events from public, anon, authenticated;
-- No grant back to anon / authenticated: this table is service-role only.


-- -----------------------------------------------------------------------------
-- PART 6 -- atomic webhook claim / retry primitives. SERVICE-ROLE ONLY.
--
-- These freeze the exactly-once-business-effect contract in the database:
-- the raceable state transitions happen inside a single UPDATE ... RETURNING
-- (callers serialize on the row lock), never as a client-visible
-- read-then-write. SECURITY DEFINER + fixed search_path; each asserts the
-- caller is service_role, and EXECUTE is revoked from public/anon/
-- authenticated. Mirrors the hardened-RPC pattern from 0116.
-- -----------------------------------------------------------------------------

-- Private guard -- raises 42501 unless the caller's JWT role is service_role.
-- Not granted to anyone; the SECURITY DEFINER functions below invoke it as
-- their owner.
create or replace function public._stripe_assert_service_role()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'stripe_webhook_events primitives are service-role only'
      using errcode = '42501';
  end if;
end;
$$;

-- Atomically insert-if-new and claim an event for processing.
-- Returns exactly one row:
--   ('claimed',             <new uuid>)  -- caller now owns the claim; it
--                                           MUST pass this token to
--                                           complete_/fail_ when done.
--   ('already_processed',   NULL)        -- terminal; do NOT run effects.
--   ('already_in_progress', NULL)        -- another worker holds a FRESH
--                                           claim; do NOT run effects.
--   p_stale_after: how old a 'processing' row's last_attempt_at must be
--                  before this call treats it as a crashed worker and
--                  reclaims it. Must be a positive interval >= 1 minute
--                  (NULL / zero / negative / smaller is RAISEd, before any
--                  row is touched); default and production value 15 min.
create or replace function public.claim_stripe_webhook_event(
  p_stripe_event_id text,
  p_type text,
  p_api_version text,
  p_payload jsonb,
  p_stripe_created_at timestamptz,
  p_stale_after interval default interval '15 minutes'
)
returns table (result text, claim_token uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token   uuid := gen_random_uuid();  -- the token THIS call would install
  v_claimed boolean := false;
  v_status  text;
begin
  perform public._stripe_assert_service_role();

  if p_stripe_event_id is null or btrim(p_stripe_event_id) = '' then
    raise exception 'p_stripe_event_id is required';
  end if;
  if p_payload is null then
    raise exception 'p_payload is required';
  end if;
  -- Stale-claim threshold sanity. A NULL / zero / negative / too-small
  -- value would let this call reclaim a HEALTHY in-flight claim
  -- immediately -- and while claim_token still stops the displaced worker
  -- from completing, it does NOT stop two workers running business
  -- effects concurrently. So a bad threshold is rejected OUTRIGHT (never
  -- silently coerced), and -- like the checks above -- BEFORE the INSERT
  -- and the claim UPDATE, so an invalid call has zero webhook-row side
  -- effects. 1 minute is the conservative floor; 15 minutes stays the
  -- default and the production value.
  if p_stale_after is null or p_stale_after < interval '1 minute' then
    raise exception 'p_stale_after must be a positive interval of at least 1 minute (got %)', p_stale_after
      using errcode = '22023';  -- invalid_parameter_value
  end if;

  -- (1) First delivery only: persist the VERIFIED event exactly once.
  --     Redeliveries hit ON CONFLICT DO NOTHING -- the stored payload is
  --     NEVER rewritten, so the original verified event is preserved.
  insert into public.stripe_webhook_events
    (stripe_event_id, type, api_version, payload, stripe_created_at, status, attempts)
  values
    (p_stripe_event_id, p_type, p_api_version, p_payload, p_stripe_created_at, 'received', 0)
  on conflict (stripe_event_id) do nothing;

  -- (2) Atomic claim. Exactly one transition of
  --     received | failed | stale-processing  ->  processing  can win;
  --     concurrent callers serialize on the row lock. The SET installs a
  --     BRAND NEW claim_token, atomically invalidating any prior owner's.
  update public.stripe_webhook_events
     set status          = 'processing',
         claim_token      = v_token,
         attempts         = attempts + 1,
         last_attempt_at   = now(),
         error            = null            -- belongs to the prior attempt
   where stripe_event_id = p_stripe_event_id
     and (
           status in ('received', 'failed')
        or (status = 'processing'
            and (last_attempt_at is null
                 or last_attempt_at < now() - p_stale_after))
         )
  returning true into v_claimed;

  if coalesce(v_claimed, false) then
    result := 'claimed';
    claim_token := v_token;
    return next;
    return;
  end if;

  -- (3) Not claimable -- distinguish terminal success from a fresh in-flight
  --     worker so the handler knows whether Stripe should keep retrying.
  select s.status into v_status
  from public.stripe_webhook_events s
  where s.stripe_event_id = p_stripe_event_id;

  if v_status = 'processed' then
    result := 'already_processed';
  else
    result := 'already_in_progress';
  end if;
  claim_token := null;
  return next;
  return;
end;
$$;

-- Mark a claimed event as terminally processed. Succeeds ONLY for the
-- current claim owner: stripe_event_id + status='processing' + matching
-- claim_token. A stale worker whose token was rotated by a reclaim gets
-- FALSE. Clears claim_token so a terminal row has no live owner.
create or replace function public.complete_stripe_webhook_event(
  p_stripe_event_id text,
  p_claim_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_done boolean := false;
begin
  perform public._stripe_assert_service_role();

  if p_claim_token is null then
    raise exception 'p_claim_token is required';
  end if;

  update public.stripe_webhook_events
     set status        = 'processed',
         processed_at   = now(),
         error          = null,
         claim_token    = null
   where stripe_event_id = p_stripe_event_id
     and status          = 'processing'
     and claim_token     = p_claim_token
  returning true into v_done;

  return coalesce(v_done, false);
end;
$$;

-- Mark a claimed event as failed (retryable). Same claim-owner guard as
-- complete_. Does NOT delete the row and does NOT touch the payload.
-- Clears claim_token (the failed row has no live owner; the next claim
-- installs a fresh token).
create or replace function public.fail_stripe_webhook_event(
  p_stripe_event_id text,
  p_claim_token uuid,
  p_error text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_done boolean := false;
begin
  perform public._stripe_assert_service_role();

  if p_claim_token is null then
    raise exception 'p_claim_token is required';
  end if;

  update public.stripe_webhook_events
     set status          = 'failed',
         error            = left(coalesce(p_error, ''), 2000),
         last_attempt_at   = now(),
         claim_token      = null
   where stripe_event_id = p_stripe_event_id
     and status          = 'processing'
     and claim_token     = p_claim_token
  returning true into v_done;

  return coalesce(v_done, false);
end;
$$;

revoke execute on function public._stripe_assert_service_role() from public, anon, authenticated;
revoke execute on function public.claim_stripe_webhook_event(text, text, text, jsonb, timestamptz, interval) from public, anon, authenticated;
revoke execute on function public.complete_stripe_webhook_event(text, uuid) from public, anon, authenticated;
revoke execute on function public.fail_stripe_webhook_event(text, uuid, text) from public, anon, authenticated;

grant execute on function public.claim_stripe_webhook_event(text, text, text, jsonb, timestamptz, interval) to service_role;
grant execute on function public.complete_stripe_webhook_event(text, uuid) to service_role;
grant execute on function public.fail_stripe_webhook_event(text, uuid, text) to service_role;
-- _stripe_assert_service_role() is internal: granted to no one; the
-- SECURITY DEFINER functions above call it as their owner.
