-- =============================================================================
-- 0127_stripe_reconciliation_and_billing_records_hardening.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0119-0126 live (Stripe SaaS billing foundation + M-CTRL). Frozen
-- by the D.1 / D.1A design review; implements exactly that contract.
--
-- WHAT THIS MIGRATION DOES
--   * columns  organization_subscriptions.reconciliation_required_at timestamptz NULL
--              organization_subscriptions.reconciliation_reason      text        NULL
--              organization_subscriptions.reconciliation_context     jsonb       NULL
--     -- ONE durable, fail-closed marker. NO index (reviewer decision).
--   * privilege hardening on public.billing_records:
--       REVOKE INSERT, UPDATE, DELETE ON billing_records FROM authenticated;
--       REVOKE ALL ON billing_records FROM anon, public;
--     authenticated keeps SELECT (its existing RLS-scoped read path,
--     unchanged); service_role keeps its independent direct grant (Supabase
--     provisions service_role separately from the anon/public/authenticated
--     grant chain -- same reasoning 0119 already documents for
--     stripe_webhook_events).
--   * function public._stripe_upsert_billing_record(uuid, uuid, jsonb)
--     -- private helper: EXECUTE explicitly revoked from PUBLIC, anon,
--     authenticated, AND service_role (D.1B.2 -- Supabase's schema-level
--     default privileges grant EXECUTE on every new function to
--     anon/authenticated/service_role at CREATE time, so service_role must
--     be revoked explicitly rather than merely never granted; the first
--     0127 apply attempt omitted it, failed its own PHASE 3 postcondition,
--     and rolled back cleanly with zero side effects -- see the REVOKE
--     statements below for the fix). Called internally only, same pattern
--     as public._stripe_assert_service_role() from 0119. Idempotent
--     upsert-by-stripe_invoice_id into billing_records. NULL
--     p_invoice.stripe_status defaults to 'open'; any NON-NULL value outside
--     the (open|paid|void|uncollectible) CHECK domain FAILS CLOSED (RAISE,
--     rolling back the whole calling transaction) rather than being
--     silently coerced -- D.1B.1 BLOCKER 2.
--   * function public.apply_stripe_subscription_state(18 args) -- SERVICE
--     ROLE ONLY. The single atomic business-effect RPC for D.2's webhook +
--     reconciliation code paths. Implements the frozen D.1A contract in one
--     transaction: identity gates, DB-derived plan/cycle, ordering fence,
--     subscription-state apply, past_due_since continuous-episode anchor,
--     an EXPLICIT identity-safety gate (v_billing_identity_safe, D.1B.1
--     BLOCKER 1) that a stale lifecycle event alone can never make false --
--     billing_records is upserted independently of subscription-state
--     staleness, but ONLY while ownership itself is not in doubt --,
--     reconciliation-required set/clear, and webhook-claim completion. Full
--     behavioral contract in the header comment above the function body
--     below.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * ZERO row DML. No INSERT/UPDATE/DELETE against any table executes
--     during this migration -- only DDL (ALTER TABLE ADD COLUMN, CREATE
--     FUNCTION, REVOKE/GRANT). The DML inside the two new function BODIES
--     never runs until a service-role caller invokes them later; that is
--     D.2, not this migration.
--   * does NOT call Stripe, configure STRIPE_WEBHOOK_SECRET, or create a
--     webhook route/endpoint
--   * does NOT touch invoices, invoice_line_items, payments, settlements,
--     settlement_line_items, carrier_settlement_payments, dispatch_financials,
--     load_financials, carrier_financials, QuickBooks (0115-0118), any
--     M-CTRL object (0125/0126: platform_settings, proceeds_model,
--     proceeds_payer, loads.financial_dispatch_id and its triggers), Model A
--     state, middleware, or entitlement enforcement
--   * does NOT modify organization_subscriptions_select,
--     organization_subscriptions_platform_admin_all, billing_records_select,
--     or billing_records_platform_admin_select (all four RLS policies are
--     read-only policies and are left exactly as-is)
--   * does NOT change the 0119 claim_/complete_/fail_stripe_webhook_event
--     RPCs or _stripe_assert_service_role() -- reused as-is
--   * does NOT touch migrations 0115-0126 or their objects
--
-- STRUCTURE: leading DO block = PHASE 1 read-only preconditions. Plain
-- top-level DDL = PHASE 2 mutation (columns, grants, two functions). Trailing
-- DO block = PHASE 3 postconditions. One transaction; any RAISE rolls
-- everything back. NOT idempotent: a re-run RAISEs in PHASE 1 at "column /
-- function already exists".
-- =============================================================================

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
declare
  v_missing          text;
  v_cols             name[];
  v_def              text;
  v_norm             text;
  v_status_labels    text[];
  c_expected_gf_check constant text :=
    'check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null';
begin
  -- --- required existing objects ---
  if to_regclass('public.organization_subscriptions') is null then raise exception '0127 precondition: public.organization_subscriptions is missing. STOP.'; end if;
  if to_regclass('public.billing_records')            is null then raise exception '0127 precondition: public.billing_records is missing. STOP.'; end if;
  if to_regclass('public.stripe_webhook_events')       is null then raise exception '0127 precondition: public.stripe_webhook_events is missing. STOP.'; end if;
  if to_regclass('public.subscription_plans')          is null then raise exception '0127 precondition: public.subscription_plans is missing. STOP.'; end if;
  if to_regclass('public.organizations')               is null then raise exception '0127 precondition: public.organizations is missing. STOP.'; end if;

  -- --- objects this migration CREATES must be ABSENT (fail closed) ---
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions'
      and column_name in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')
  ) then
    raise exception '0127 precondition: a reconciliation_* column already exists on organization_subscriptions -- 0127 partially applied? STOP.';
  end if;
  if to_regprocedure('public._stripe_upsert_billing_record(uuid,uuid,jsonb)') is not null then
    raise exception '0127 precondition: function public._stripe_upsert_billing_record(uuid,uuid,jsonb) already exists. STOP.';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='apply_stripe_subscription_state'
  ) then
    raise exception '0127 precondition: a function public.apply_stripe_subscription_state(...) already exists. STOP.';
  end if;

  -- --- organization_subscriptions: the 21 columns the D.1/D.1A design depends on ---
  select string_agg(c, ', ') into v_missing
  from unnest(array[
    'id','organization_id','plan_id','status','billing_cycle',
    'stripe_customer_id','stripe_subscription_id','stripe_price_id',
    'current_period_start','current_period_end','cancel_at_period_end','canceled_at',
    'trial_end','checkout_pending_since','grandfathered_at',
    'past_due_since','stripe_event_at','stripe_checkout_session_id','stripe_checkout_attempt_id',
    'created_at','updated_at'
  ]) as c
  where not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions' and column_name=c
  );
  if v_missing is not null then
    raise exception '0127 precondition: organization_subscriptions is missing expected column(s): %. STOP.', v_missing;
  end if;

  -- organization_id / stripe_customer_id / stripe_subscription_id UNIQUE (0119).
  select array_agg(a.attname order by k.ord) into v_cols
  from pg_constraint c cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
  join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum
  where c.conrelid='public.organization_subscriptions'::regclass
    and c.conname='organization_subscriptions_organization_id_key' and c.contype='u';
  if v_cols is null or cardinality(v_cols)<>1 or v_cols[1]<>'organization_id' then
    raise exception '0127 precondition: organization_subscriptions_organization_id_key is missing or not UNIQUE on exactly {organization_id}. STOP.';
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.organization_subscriptions'::regclass and conname='organization_subscriptions_stripe_customer_id_key' and contype='u') then
    raise exception '0127 precondition: organization_subscriptions_stripe_customer_id_key (UNIQUE) is missing. STOP.';
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.organization_subscriptions'::regclass and conname='organization_subscriptions_stripe_subscription_id_key' and contype='u') then
    raise exception '0127 precondition: organization_subscriptions_stripe_subscription_id_key (UNIQUE) is missing. STOP.';
  end if;

  -- Grandfather CHECK (0121), normalized -- must be exact and untouched.
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid='public.organization_subscriptions'::regclass
    and c.conname='organization_subscriptions_grandfather_has_no_stripe' and c.contype='c';
  if v_def is null then
    raise exception '0127 precondition: CHECK organization_subscriptions_grandfather_has_no_stripe is missing. STOP.';
  end if;
  v_norm := btrim(regexp_replace(regexp_replace(lower(v_def), '[()]', '', 'g'), '\s+', ' ', 'g'));
  if v_norm <> c_expected_gf_check then
    raise exception '0127 precondition: grandfather CHECK predicate has drifted. Expected (normalized): "%". Actual: "%". STOP.', c_expected_gf_check, v_def;
  end if;

  -- RLS + tenant policies on organization_subscriptions (0010/0016) intact;
  -- no tenant write policy.
  if not (select relrowsecurity from pg_class where oid='public.organization_subscriptions'::regclass) then
    raise exception '0127 precondition: RLS not enabled on organization_subscriptions. STOP.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and policyname='organization_subscriptions_select') then
    raise exception '0127 precondition: policy organization_subscriptions_select is missing. STOP.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and policyname='organization_subscriptions_platform_admin_all') then
    raise exception '0127 precondition: policy organization_subscriptions_platform_admin_all is missing. STOP.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and cmd in ('INSERT','UPDATE','DELETE')) then
    raise exception '0127 precondition: an INSERT/UPDATE/DELETE-scoped tenant policy exists on organization_subscriptions. STOP.';
  end if;

  -- billing_records: columns, status CHECK domain, UNIQUE(stripe_invoice_id),
  -- RLS + policies, and the CURRENT (pre-hardening) privilege state.
  select string_agg(c, ', ') into v_missing
  from unnest(array[
    'id','organization_id','organization_subscription_id','stripe_invoice_id',
    'amount_cents','currency','status','invoice_pdf_url','period_start','period_end',
    'paid_at','created_at','updated_at'
  ]) as c
  where not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='billing_records' and column_name=c
  );
  if v_missing is not null then
    raise exception '0127 precondition: billing_records is missing expected column(s): %. STOP.', v_missing;
  end if;
  if not exists (
    select 1 from pg_constraint c
    where c.conrelid='public.billing_records'::regclass and c.contype='c'
      and pg_get_constraintdef(c.oid) ilike '%open%' and pg_get_constraintdef(c.oid) ilike '%paid%'
      and pg_get_constraintdef(c.oid) ilike '%void%' and pg_get_constraintdef(c.oid) ilike '%uncollectible%'
  ) then
    raise exception '0127 precondition: billing_records.status CHECK domain (open|paid|void|uncollectible) not found as expected. STOP.';
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.billing_records'::regclass and conname='billing_records_stripe_invoice_id_key' and contype='u') then
    raise exception '0127 precondition: billing_records_stripe_invoice_id_key (UNIQUE) is missing. STOP.';
  end if;
  if not (select relrowsecurity from pg_class where oid='public.billing_records'::regclass) then
    raise exception '0127 precondition: RLS not enabled on billing_records. STOP.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_select') then
    raise exception '0127 precondition: policy billing_records_select is missing. STOP.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_platform_admin_select') then
    raise exception '0127 precondition: policy billing_records_platform_admin_select is missing. STOP.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and cmd in ('INSERT','UPDATE','DELETE')) then
    raise exception '0127 precondition: an INSERT/UPDATE/DELETE-scoped tenant policy already exists on billing_records (unexpected). STOP.';
  end if;
  -- Confirm we are hardening a genuinely weaker CURRENT state (else this
  -- migration would be redundant / possibly already partially applied by
  -- some other means).
  if not has_table_privilege('authenticated', 'public.billing_records', 'INSERT') then
    raise exception '0127 precondition: authenticated already lacks INSERT on billing_records -- hardening already applied? STOP.';
  end if;

  -- stripe_webhook_events: RLS + no policies (0119) + claim_token shape CHECK.
  if not (select relrowsecurity from pg_class where oid='public.stripe_webhook_events'::regclass) then
    raise exception '0127 precondition: RLS not enabled on stripe_webhook_events. STOP.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='stripe_webhook_events') then
    raise exception '0127 precondition: stripe_webhook_events unexpectedly has a policy (should be RLS-on/no-policies). STOP.';
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.stripe_webhook_events'::regclass and conname='stripe_webhook_events_claim_token_shape' and contype='c') then
    raise exception '0127 precondition: CHECK stripe_webhook_events_claim_token_shape is missing. STOP.';
  end if;

  -- The three 0119 webhook RPCs + the private guard must exist (reused, not redefined).
  if to_regprocedure('public._stripe_assert_service_role()') is null then raise exception '0127 precondition: public._stripe_assert_service_role() missing. STOP.'; end if;
  if to_regprocedure('public.claim_stripe_webhook_event(text,text,text,jsonb,timestamptz,interval)') is null then raise exception '0127 precondition: public.claim_stripe_webhook_event(...) missing. STOP.'; end if;
  if to_regprocedure('public.complete_stripe_webhook_event(text,uuid)') is null then raise exception '0127 precondition: public.complete_stripe_webhook_event(...) missing. STOP.'; end if;
  if to_regprocedure('public.fail_stripe_webhook_event(text,uuid,text)') is null then raise exception '0127 precondition: public.fail_stripe_webhook_event(...) missing. STOP.'; end if;

  -- subscription_plans: exactly 2 public+active rows (Essential/Pro), the
  -- exact 0122 catalog anchors, 4 distinct price ids.
  if (select count(*) from public.subscription_plans where is_public and is_active) <> 2 then
    raise exception '0127 precondition: expected exactly 2 public+active subscription_plans rows. STOP.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where id='f54f87ae-556d-4ae4-8db6-0fbbbac4b798' and tier='essential'
      and stripe_product_id='prod_VBimjDJ5rSyvx5'
      and stripe_price_id_monthly='price_1UBLLMKvkXN4pgdED3H0zeNs'
      and stripe_price_id_annual='price_1UBLb6KvkXN4pgdEL1Orixr0'
      and is_public and is_active
  ) then
    raise exception '0127 precondition: Essential plan Stripe catalog mapping is not the expected 0122 value. STOP.';
  end if;
  if not exists (
    select 1 from public.subscription_plans
    where id='2a9138f2-0514-4e32-a178-2171776e69a3' and tier='pro'
      and stripe_product_id='prod_VBjAx1MTHvWdCu'
      and stripe_price_id_monthly='price_1UBLhuKvkXN4pgdERSZvfTmV'
      and stripe_price_id_annual='price_1UBLuQKvkXN4pgdEwGxao6YC'
      and is_public and is_active
  ) then
    raise exception '0127 precondition: Pro plan Stripe catalog mapping is not the expected 0122 value. STOP.';
  end if;

  -- subscription_status enum -- exact 8-label set (order-independent compare).
  select array_agg(e.enumlabel::text order by e.enumlabel) into v_status_labels
  from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
  where n.nspname='public' and t.typname='subscription_status';
  if v_status_labels is distinct from array['active','canceled','incomplete','incomplete_expired','past_due','paused','trialing','unpaid']::text[] then
    raise exception '0127 precondition: subscription_status labels are %, expected exactly the 8-value Stripe-aligned set. STOP.', v_status_labels;
  end if;

  -- organizations.billing_required present.
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organizations' and column_name='billing_required'
      and data_type='boolean' and is_nullable='NO'
  ) then
    raise exception '0127 precondition: organizations.billing_required (boolean NOT NULL) missing. STOP.';
  end if;

  -- Helper functions this migration's RPC relies on.
  if to_regprocedure('public.current_org_id()') is null then raise exception '0127 precondition: public.current_org_id() missing. STOP.'; end if;
  if to_regprocedure('public.has_role(public.org_role[])') is null then raise exception '0127 precondition: public.has_role(org_role[]) missing. STOP.'; end if;
  if to_regprocedure('public.is_platform_admin()') is null then raise exception '0127 precondition: public.is_platform_admin() missing. STOP.'; end if;

  -- M-CTRL (0125/0126) landmark -- proves correct baseline order; NOT touched
  -- by this migration.
  if to_regclass('public.platform_settings') is null then
    raise exception '0127 precondition: public.platform_settings (0125) missing -- apply 0125/0126 first. STOP.';
  end if;
  if (select model_a_enabled from public.platform_settings where id = true) is not false then
    raise exception '0127 precondition: platform_settings.model_a_enabled is not FALSE. STOP.';
  end if;
  if coalesce(col_description('public.loads'::regclass,
        (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='financial_dispatch_id')), '')
     not ilike '%backfilled by migration 0126%' then
    raise exception '0127 precondition: loads.financial_dispatch_id does not carry the 0126 backfill marker -- apply 0126 first. STOP.';
  end if;

  -- ---- Data-state preconditions (fail closed on drift) ----
  if (select count(*) from public.organizations) <> 64 then
    raise exception '0127 precondition: expected 64 organizations, found %. STOP.', (select count(*) from public.organizations);
  end if;
  if (select count(*) from public.organizations where billing_required = false) <> 63 then
    raise exception '0127 precondition: expected 63 organizations with billing_required=false, found %. STOP.',
      (select count(*) from public.organizations where billing_required = false);
  end if;
  if (select count(*) from public.organization_subscriptions) <> 4 then
    raise exception '0127 precondition: expected 4 organization_subscriptions rows, found %. STOP.',
      (select count(*) from public.organization_subscriptions);
  end if;
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0127 precondition: expected 3 grandfathered subscription rows, found %. STOP.',
      (select count(*) from public.organization_subscriptions where grandfathered_at is not null);
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null or stripe_subscription_id is not null or stripe_price_id is not null)
  ) then
    raise exception '0127 precondition: a grandfathered subscription row has a non-NULL Stripe id. STOP.';
  end if;
  if (select count(*) from public.billing_records) <> 0 then
    raise exception '0127 precondition: billing_records is not empty. STOP.';
  end if;
  if (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0127 precondition: stripe_webhook_events is not empty. STOP.';
  end if;
  if (select count(*) from public.subscription_plans) <> 5 then
    raise exception '0127 precondition: expected 5 subscription_plans rows, found %. STOP.', (select count(*) from public.subscription_plans);
  end if;

  -- United Leather (C.4 sandbox fixture) landmark -- soft protection: proves
  -- the live in-flight Checkout attempt this migration must never disturb is
  -- exactly where D.1/D.1B left it. Nothing in the current codebase (no
  -- webhook runtime exists yet) can move this state between now and apply.
  -- (reconciliation_required_at does not exist yet at this point in PHASE 1
  -- -- it is added in PHASE 2 -- so this check is necessarily limited to the
  -- columns that already exist. PHASE 3 re-checks the same row including the
  -- new column, once it exists, as the authoritative post-ALTER assertion.)
  if not exists (
    select 1 from public.organization_subscriptions
    where organization_id = 'ca6457e6-8ae8-4e85-adc9-4a0dabb2386e'
      and status = 'incomplete'
      and grandfathered_at is null
      and stripe_customer_id is not null
      and stripe_checkout_session_id is not null
      and stripe_checkout_attempt_id is not null
      and stripe_subscription_id is null
      and stripe_price_id is null
  ) then
    raise exception '0127 precondition: the United Leather (ca6457e6-8ae8-4e85-adc9-4a0dabb2386e) organization_subscriptions row is not in the expected C.4 in-flight-checkout shape. STOP and inspect before proceeding -- this migration must never run against a moved fixture.';
  end if;

  raise notice '0127 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================

-- A. Reconciliation columns -------------------------------------------------
-- Nullable, no default. Every existing row observes NULL (no backfill). NO
-- index (reviewer decision -- access is always via the org's already-unique
-- organization_subscriptions row; an ops query over 4-N rows needs no index
-- at this scale, and one can be added later without another migration if it
-- ever does).
alter table public.organization_subscriptions
  add column reconciliation_required_at timestamptz;
alter table public.organization_subscriptions
  add column reconciliation_reason text;
alter table public.organization_subscriptions
  add column reconciliation_context jsonb;

comment on column public.organization_subscriptions.reconciliation_required_at is
  'Durable fail-closed marker: non-NULL means a Stripe identity/catalog conflict was detected and NO subscription-state write occurred for the offending fact. Anchored ONCE per distinct conflict (coalesce), never bumped by a repeat of the same conflict. Cleared only per the deterministic rules in apply_stripe_subscription_state() -- never by an unrelated clean event. NULL = no known conflict.';
comment on column public.organization_subscriptions.reconciliation_reason is
  'Short machine token naming the current/last conflict (e.g. unknown_price, customer_mismatch, subscription_mismatch, grandfathered_stripe_event). Overwritten on every (re)detection; meaningful only while reconciliation_required_at is non-NULL.';
comment on column public.organization_subscriptions.reconciliation_context is
  'Minimal jsonb evidence for the current reconciliation_reason (expected vs seen ids, offending event id). Overwritten, not appended -- this is a single durable marker, not an incident log.';

-- B. billing_records privilege hardening ------------------------------------
-- authenticated keeps its existing RLS-scoped SELECT (billing_records_select,
-- 0010); loses the blanket INSERT/UPDATE/DELETE that 0010's schema-wide
-- `grant ... to authenticated` conferred (RLS already blocked all tenant
-- writes in practice -- no INSERT/UPDATE/DELETE policy exists -- this is
-- defense-in-depth so the block does not depend on "RLS enabled + no
-- policy" alone, matching the explicit-revoke posture 0119 already uses for
-- stripe_webhook_events). anon loses everything (this product has no
-- unauthenticated read surface -- 0010's own stated intent; anon's SELECT
-- came only from Supabase's hosted-platform default privileges, never from
-- an explicit grant in this schema). service_role is UNTOUCHED: Supabase
-- provisions service_role with its own direct table grants, independent of
-- anon/authenticated/public -- same reasoning 0119 documents.
revoke insert, update, delete on public.billing_records from authenticated;
revoke all on public.billing_records from anon, public;

-- C. Private helper: idempotent billing_records upsert ----------------------
-- Not tenant-reachable; granted to no one (called internally by
-- apply_stripe_subscription_state, which runs as this function's owner under
-- SECURITY DEFINER -- same pattern as public._stripe_assert_service_role()).
create or replace function public._stripe_upsert_billing_record(
  p_organization_id               uuid,
  p_organization_subscription_id  uuid,
  p_invoice                       jsonb
)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_id          text := p_invoice ->> 'stripe_invoice_id';
  v_status_in   text := p_invoice ->> 'stripe_status';
  v_status      text;
  v_existing_id uuid;
begin
  if v_id is null or btrim(v_id) = '' then
    return 'not_provided';
  end if;

  -- D.1B.1 BLOCKER 2 -- FAIL CLOSED on an unrecognized normalized status.
  -- billing_records.status CHECK domain (0002) is exactly
  -- open|paid|void|uncollectible. The TypeScript handler is responsible for
  -- normalizing Stripe's richer invoice.status (which also includes 'draft')
  -- down to this domain BEFORE calling in -- invoice.paid -> 'paid',
  -- invoice.payment_failed -> 'open' (Stripe reports the invoice itself as
  -- still open/collectible when a payment attempt fails). A non-NULL value
  -- OUTSIDE that domain is therefore a handler/schema disagreement, not an
  -- organization-identity problem, and must never be silently coerced to
  -- 'open' -- doing so would hide the disagreement in the stored data. RAISE
  -- here rolls back the ENTIRE calling apply_stripe_subscription_state()
  -- transaction (including any subscription-state UPDATE already applied
  -- earlier in that same call), leaving the stripe_webhook_events row
  -- exactly as it was ('processing', reclaimable) -- no billing mutation, no
  -- lifecycle mutation committed, webhook not completed. NULL is the only
  -- accepted "no normalized status supplied" case and still defaults to
  -- 'open' (still-collectible / needs attention).
  if v_status_in is not null and v_status_in not in ('open','paid','void','uncollectible') then
    raise exception 'unsupported billing_records.status normalization: %; expected NULL or one of open|paid|void|uncollectible', v_status_in
      using errcode = '22023';
  end if;
  v_status := coalesce(v_status_in, 'open');

  select id into v_existing_id from public.billing_records where stripe_invoice_id = v_id;

  insert into public.billing_records (
    organization_id, organization_subscription_id, stripe_invoice_id,
    amount_cents, currency, status, invoice_pdf_url, period_start, period_end, paid_at
  ) values (
    p_organization_id, p_organization_subscription_id, v_id,
    coalesce((p_invoice ->> 'amount_cents')::integer, 0),
    coalesce(p_invoice ->> 'currency', 'usd'),
    v_status,
    p_invoice ->> 'invoice_pdf_url',
    (p_invoice ->> 'period_start')::timestamptz,
    (p_invoice ->> 'period_end')::timestamptz,
    (p_invoice ->> 'paid_at')::timestamptz
  )
  on conflict (stripe_invoice_id) do update
    set organization_id              = excluded.organization_id,
        organization_subscription_id = excluded.organization_subscription_id,
        amount_cents                 = excluded.amount_cents,
        currency                     = excluded.currency,
        status                       = excluded.status,
        invoice_pdf_url              = excluded.invoice_pdf_url,
        period_start                 = excluded.period_start,
        period_end                   = excluded.period_end,
        paid_at                      = excluded.paid_at;

  return case when v_existing_id is null then 'inserted' else 'updated' end;
end;
$fn$;

comment on function public._stripe_upsert_billing_record(uuid, uuid, jsonb) is
  'Private helper: idempotent upsert into billing_records by stripe_invoice_id, called only from apply_stripe_subscription_state(). Not directly callable by any application-facing role -- EXECUTE explicitly revoked from PUBLIC, anon, authenticated, AND service_role (D.1B.2: Supabase''s schema-level default privileges grant EXECUTE on every new function to anon/authenticated/service_role at CREATE time, so service_role must be revoked explicitly, not merely omitted from a grant). Reachable only via the internal call from apply_stripe_subscription_state(), which succeeds with zero grant of its own because both functions share the same owner and SECURITY DEFINER runs the call as that owner -- an owner always retains implicit EXECUTE on its own objects; no REVOKE targeting another role can remove it. NULL p_invoice.stripe_status defaults to open; any NON-NULL value outside the (open|paid|void|uncollectible) CHECK domain RAISEs (fail closed) and rolls back the entire calling transaction rather than being silently coerced.';

-- D.1B.2 ROOT-CAUSE FIX -- the FIRST attempt to apply 0127 (never committed;
-- fully rolled back -- see PHASE 3's own RAISE) revoked EXECUTE from only
-- public/anon/authenticated and OMITTED service_role. Supabase's project
-- bootstrap runs `ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON
-- FUNCTIONS TO anon, authenticated, service_role` (independent of Postgres's
-- own "PUBLIC gets EXECUTE by default" rule) -- so EVERY function created in
-- this schema, including this private helper, is granted EXECUTE to
-- service_role automatically AT CREATE TIME, exactly like anon/authenticated
-- are. Omitting service_role from the REVOKE left it directly executable by
-- service_role, which the PHASE 3 postcondition correctly caught and
-- aborted on (proof the fail-closed design worked as intended). Fixed here
-- by listing service_role explicitly, and by an explicit `FROM PUBLIC`
-- REVOKE ALL as a second, redundant belt-and-suspenders statement -- neither
-- statement affects this function's OWNER (the role that ran this
-- migration): ownership grants implicit EXECUTE that no REVOKE targeting
-- another role can remove, which is precisely how
-- apply_stripe_subscription_state() -- SECURITY DEFINER, owned by that same
-- role -- can still invoke this helper internally with zero direct grant to
-- any application-facing role.
revoke all on function public._stripe_upsert_billing_record(uuid, uuid, jsonb) from public;
revoke execute on function public._stripe_upsert_billing_record(uuid, uuid, jsonb) from anon, authenticated, service_role;
-- Deliberately NOT re-granted to service_role: this is an internal
-- implementation detail of apply_stripe_subscription_state(), never called
-- directly by the webhook handler, the reconcile action, or any other
-- caller -- the outer RPC (below) is the only supported entry point and is
-- the only one of the two granted directly to service_role.

-- D. apply_stripe_subscription_state -- the single atomic business-effect RPC
-- =============================================================================
-- SERVICE ROLE ONLY. Implements the frozen D.1 / D.1A contract for D.2's
-- webhook handler AND the owner/admin/platform-admin reconciliation action --
-- both call this SAME function so business logic can never diverge between
-- the two paths.
--
-- CALLING MODES (p_mode):
--   'apply'     a webhook customer.subscription.created/updated or
--               checkout.session.completed / invoice.paid / invoice.
--               payment_failed event, canonical state freshly retrieved from
--               Stripe by the caller. REQUIRES p_stripe_event_id +
--               p_claim_token (the caller's live claim_stripe_webhook_event
--               ownership).
--   'deleted'   a webhook customer.subscription.deleted event, OR a
--               '.created'/'.updated' whose canonical retrieve came back
--               Stripe's definitive resource_missing (404) signal -- see the
--               header comment on the caller-side classification contract.
--               REQUIRES p_stripe_event_id + p_claim_token.
--   'reconcile' an explicit server-side reconciliation call (owner/admin's
--               own org, or platform-admin), re-evaluating every gate
--               against freshly retrieved canonical state. REQUIRES
--               p_stripe_event_id AND p_claim_token to both be NULL. This is
--               the ONLY mode that may clear an "identity/authority" class
--               reconciliation_reason (see CLEAR rules below).
--
-- ORGANIZATION IDENTITY -- NO METADATA-BASED ADOPTION. The caller resolves
-- p_organization_subscription_id BEFORE calling this function, using ONLY a
-- durable stored TDP mapping (organization_subscriptions.stripe_subscription_id,
-- .stripe_checkout_session_id, or .stripe_customer_id -- all persisted by
-- TDP's own controlled Checkout/customer-creation flow, never by a webhook).
-- If no stored mapping resolves an organization, the caller must NOT invoke
-- this function at all -- it fails the webhook claim directly
-- ('org_unresolved:...') and stops; there is no row to mark, so no
-- reconciliation marker is written for that case. Once THIS function has a
-- concrete p_organization_subscription_id (already resolved from a stored
-- mapping), p_stripe_customer_id / p_stripe_subscription_id /
-- p_stripe_checkout_session_id are used ONLY to CONFIRM that mapping (P6-P8
-- below) -- a mismatch is a conflict, never a re-adoption. p_secondary_conflict
-- is a single pre-computed token (or NULL) representing the caller's
-- metadata.organization_id / client_reference_id equality checks against the
-- ALREADY-resolved organization_id -- this function never reads Stripe
-- metadata itself and never uses it to choose or create a binding.
--
-- PLAN / CYCLE AUTHORITY. The caller NEVER supplies plan_id or billing_cycle
-- -- there are no such parameters. p_stripe_price_id (plus p_price_interval
-- as a consistency assertion) is looked up against public.subscription_plans
-- (is_public AND is_active) INSIDE this transaction; zero or more-than-one
-- match is a fail-closed reconciliation conflict (unknown_price /
-- ambiguous_price), never a silent guess.
--
-- P1-P19 IMPLEMENTATION (frozen D.1A matrix):
--   P1  verify caller is service_role                         (_stripe_assert_service_role)
--   P2  verify stripe_webhook_events claim ownership           ('apply'/'deleted' only)
--   P3  lock the target organization_subscriptions row         (SELECT ... FOR UPDATE)
--   P4  refuse a grandfathered row                             -> grandfathered_stripe_event
--   P5  refuse a billing_required=false org                    -> billing_not_required_stripe_attach
--   P6  validate stored Stripe Customer identity                -> customer_mismatch / customer_unbound
--   P7  enforce write-once stripe_subscription_id               -> subscription_mismatch
--   P8  enforce write-once stripe_checkout_session_id            -> checkout_session_mismatch
--   P9  apply the caller's SECONDARY metadata assertion          -> secondary_metadata_conflict
--   P10 derive plan_id from stripe_price_id (DB catalog only)    -> unknown_price / ambiguous_price
--   P11 cross-check price_interval against the derived cycle     -> price_interval_mismatch
--   P12 validate p_status is a legal subscription_status member  -> invalid_status
--   P13 ordering fence: is this event/state stale?               (stripe_event_at)
--   P14 apply canonical subscription-state columns                (skipped if stale or conflicted)
--   P15 past_due_since continuous-episode anchor/preserve/clear
--   P16 upsert billing_records (stripe_invoice_id-keyed)          -- gated on v_billing_identity_safe, NEVER on P13 staleness alone
--   P17 SET reconciliation_required_at/_reason/_context on any P4-P12 conflict, or a re-affirmed unresolved prior conflict
--   P18 CLEAR reconciliation_* -- self-healing reasons on any clean pass; identity/authority reasons ONLY in 'reconcile' mode
--   P19 complete_/fail_ the webhook claim; return the outcome
--
-- RECONCILIATION SET/CLEAR (frozen):
--   SELF-HEALING reasons (clear on ANY subsequent clean pass, any mode):
--     unknown_price, ambiguous_price, price_interval_mismatch,
--     checkout_session_mismatch, secondary_metadata_conflict
--   IDENTITY/AUTHORITY reasons (clear ONLY via an explicit p_mode='reconcile'
--   call that then passes every gate cleanly):
--     customer_mismatch, customer_unbound, subscription_mismatch,
--     billing_not_required_stripe_attach, grandfathered_stripe_event,
--     billing_record_org_mismatch, invalid_status
--   A conflict that is still unresolved when a DIFFERENT, otherwise-clean
--   event arrives is RE-AFFIRMED (same reconciliation_required_at anchor,
--   reason kept, context updated with the latest event id) rather than
--   silently left stale or cleared -- subscription-state columns are still
--   NOT written while a reason ineligible for this call's mode remains set.
--
-- BILLING IDENTITY SAFETY (D.1B.1 BLOCKER 1 -- a SEPARATE axis from the
-- CLEAR classification above): v_billing_identity_safe is false ONLY for
-- c_billing_unsafe_reasons = {customer_mismatch, customer_unbound,
-- subscription_mismatch, billing_record_org_mismatch,
-- grandfathered_stripe_event, billing_not_required_stripe_attach} -- every
-- reason where the org/subscription OWNERSHIP itself is not authoritatively
-- established, or (for grandfathered / billing_required=false) where this
-- org must never carry Stripe billing at all. It is TRUE whenever there is
-- no conflict, AND whenever the only conflict is unknown_price,
-- ambiguous_price, price_interval_mismatch, checkout_session_mismatch,
-- secondary_metadata_conflict, or invalid_status -- every one of those fires
-- only AFTER customer/subscription/session identity already agreed (P6-P8
-- passed), so ownership is safe and a billing fact may still be recorded.
--
-- STALE SUBSCRIPTION STATE NEVER SUPPRESSES A FRESH, IDENTITY-SAFE BILLING
-- FACT: P16 (the billing_records upsert) runs whenever p_invoice is provided
-- AND v_billing_identity_safe, independently of whether P13 found the
-- subscription-state portion of this event stale -- a stale event alone can
-- never make v_billing_identity_safe false (staleness and identity-safety
-- are orthogonal; P13 is computed after and does not feed back into
-- v_billing_identity_safe). The webhook claim still completes in that case
-- -- there is nothing left to retry once the invoice fact is durably
-- recorded. Conversely, when ownership itself is in doubt, NO billing fact
-- is written regardless of staleness, and the webhook is failed (retryable)
-- via the frozen reconciliation contract, not completed.
--
-- ATOMICITY: every write above happens in this ONE function invocation --
-- one transaction. Any exception raised anywhere rolls back everything
-- (including the reconciliation marker, the billing upsert, and the webhook
-- claim transition), leaving the stripe_webhook_events row exactly as it was
-- (still 'processing', reclaimable by the 0119 stale-claim path). This
-- function never partially updates organization_subscriptions and then
-- separately marks the webhook complete -- the two conflict-path branches
-- explicitly call fail_stripe_webhook_event() as their LAST statement (not a
-- raised exception), and the clean-path branch explicitly calls
-- complete_stripe_webhook_event() as ITS last statement -- both inside this
-- same transaction, so the event-row state and the subscription-row state
-- can never disagree after this function returns.
-- =============================================================================
create or replace function public.apply_stripe_subscription_state(
  p_stripe_event_id               text,
  p_claim_token                   uuid,
  p_organization_subscription_id  uuid,
  p_mode                          text,             -- 'apply' | 'deleted' | 'reconcile'
  p_stripe_customer_id            text,
  p_stripe_subscription_id        text,
  p_stripe_checkout_session_id    text,
  p_stripe_price_id               text,
  p_price_interval                text,             -- 'month' | 'year' | NULL
  p_status                        text,              -- raw Stripe subscription.status (ignored in 'deleted' mode)
  p_trial_end                     timestamptz,
  p_current_period_start          timestamptz,
  p_current_period_end            timestamptz,
  p_cancel_at_period_end          boolean,
  p_canceled_at                   timestamptz,
  p_event_at                      timestamptz,       -- ordering fence value (Stripe event.created)
  p_secondary_conflict            text,              -- NULL = caller's metadata/client_reference_id assertions agreed
  p_invoice                       jsonb              -- NULL unless invoice.paid / invoice.payment_failed
)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_row                    record;
  v_claim_ok               boolean;
  v_conflict_reason        text := null;
  v_conflict_context       jsonb := null;
  v_plan_matches           integer;
  v_plan_id                uuid;
  v_cycle                  text;
  v_status_ok              boolean;
  v_is_stale               boolean;
  v_new_past_due_since     timestamptz;
  v_sub_outcome            text;
  v_bill_outcome           text := 'not_provided';
  v_bill_invoice_id        text;
  v_existing_bill_org      uuid;
  -- D.1B.1 BLOCKER 1: reasons where the org/subscription OWNERSHIP itself is
  -- not authoritatively established -- writing a billing_records fact under
  -- ANY of these would risk attributing a Stripe invoice to the wrong
  -- tenant, or to a tenant that must never carry Stripe billing at all
  -- (grandfathered / billing_required=false). Every other reason
  -- (unknown_price, ambiguous_price, price_interval_mismatch,
  -- checkout_session_mismatch, secondary_metadata_conflict, invalid_status)
  -- fires only AFTER customer/subscription/session identity already agreed
  -- (P6-P8 passed) -- ownership is safe, so a stale-but-identity-valid
  -- invoice fact may still be recorded even while one of those is flagged.
  c_billing_unsafe_reasons constant text[] := array[
    'customer_mismatch', 'customer_unbound', 'subscription_mismatch',
    'billing_record_org_mismatch', 'grandfathered_stripe_event',
    'billing_not_required_stripe_attach'
  ];
  v_billing_identity_safe  boolean;
begin
  -- P1 -------------------------------------------------------------------
  perform public._stripe_assert_service_role();

  if p_mode not in ('apply', 'deleted', 'reconcile') then
    raise exception 'apply_stripe_subscription_state: p_mode must be apply|deleted|reconcile, got %', p_mode
      using errcode = '22023';
  end if;
  if p_organization_subscription_id is null then
    raise exception 'apply_stripe_subscription_state: p_organization_subscription_id is required'
      using errcode = '22023';
  end if;

  -- P2 -- webhook-claim ownership. 'reconcile' calls carry no event/claim at
  -- all; 'apply'/'deleted' calls always must, and are re-verified here
  -- (never trusted merely because the caller says so).
  if p_mode = 'reconcile' then
    if p_stripe_event_id is not null or p_claim_token is not null then
      raise exception 'apply_stripe_subscription_state: p_mode=reconcile must not supply p_stripe_event_id/p_claim_token'
        using errcode = '22023';
    end if;
  else
    if p_stripe_event_id is null or p_claim_token is null then
      raise exception 'apply_stripe_subscription_state: p_stripe_event_id and p_claim_token are required when p_mode <> reconcile'
        using errcode = '22023';
    end if;
    select true into v_claim_ok
    from public.stripe_webhook_events
    where stripe_event_id = p_stripe_event_id
      and status = 'processing'
      and claim_token = p_claim_token;
    if not coalesce(v_claim_ok, false) then
      return 'not_owner';
    end if;
  end if;

  -- P3 -- lock the target row (and its org's billing_required flag).
  select os.*, o.billing_required as org_billing_required
    into v_row
  from public.organization_subscriptions os
  join public.organizations o on o.id = os.organization_id
  where os.id = p_organization_subscription_id
  for update of os;

  -- NOTE: a `record` variable that matched zero rows is left unassigned in
  -- plpgsql -- referencing v_row.<field> in that state raises "record is not
  -- assigned yet" rather than behaving like a NULL field. FOUND is the
  -- correct zero-rows test here.
  if not found then
    if p_mode <> 'reconcile' then
      perform public.fail_stripe_webhook_event(p_stripe_event_id, p_claim_token, 'target_row_missing');
    end if;
    return 'not_owner';
  end if;

  -- P4-P9 -- identity / authority gates. First one that fires wins.
  if v_row.grandfathered_at is not null then
    v_conflict_reason  := 'grandfathered_stripe_event';
    v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id,
      'seen_customer', p_stripe_customer_id, 'seen_subscription', p_stripe_subscription_id);
  elsif v_row.org_billing_required is not true then
    v_conflict_reason  := 'billing_not_required_stripe_attach';
    v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id,
      'seen_customer', p_stripe_customer_id, 'seen_subscription', p_stripe_subscription_id);
  elsif v_row.stripe_customer_id is null and p_stripe_customer_id is not null then
    v_conflict_reason  := 'customer_unbound';
    v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id, 'seen_customer', p_stripe_customer_id);
  elsif v_row.stripe_customer_id is not null and p_stripe_customer_id is not null
        and v_row.stripe_customer_id <> p_stripe_customer_id then
    v_conflict_reason  := 'customer_mismatch';
    v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id,
      'expected_customer', v_row.stripe_customer_id, 'seen_customer', p_stripe_customer_id);
  elsif v_row.stripe_subscription_id is not null and p_stripe_subscription_id is not null
        and v_row.stripe_subscription_id <> p_stripe_subscription_id then
    v_conflict_reason  := 'subscription_mismatch';
    v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id,
      'expected_subscription', v_row.stripe_subscription_id, 'seen_subscription', p_stripe_subscription_id);
  elsif v_row.stripe_checkout_session_id is not null and p_stripe_checkout_session_id is not null
        and v_row.stripe_checkout_session_id <> p_stripe_checkout_session_id then
    v_conflict_reason  := 'checkout_session_mismatch';
    v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id,
      'expected_session', v_row.stripe_checkout_session_id, 'seen_session', p_stripe_checkout_session_id);
  elsif p_secondary_conflict is not null then
    v_conflict_reason  := 'secondary_metadata_conflict';
    v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id, 'detail', p_secondary_conflict);
  end if;

  -- P10-P11 -- DB-derived plan/cycle from stripe_price_id (skipped in
  -- 'deleted' mode -- a canceled subscription keeps its last-known plan).
  if v_conflict_reason is null and p_mode <> 'deleted' then
    select count(*), min(sp.id)
      into v_plan_matches, v_plan_id
    from public.subscription_plans sp
    where sp.is_public and sp.is_active
      and p_stripe_price_id in (sp.stripe_price_id_monthly, sp.stripe_price_id_annual);

    if coalesce(v_plan_matches, 0) = 0 then
      v_conflict_reason  := 'unknown_price';
      v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id, 'seen_price', p_stripe_price_id);
    elsif v_plan_matches > 1 then
      v_conflict_reason  := 'ambiguous_price';
      v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id, 'seen_price', p_stripe_price_id);
    else
      select case when sp.stripe_price_id_monthly = p_stripe_price_id then 'monthly'
                  when sp.stripe_price_id_annual  = p_stripe_price_id then 'annual' end
        into v_cycle
      from public.subscription_plans sp
      where sp.id = v_plan_id;

      if p_price_interval is not null
         and not ((v_cycle = 'monthly' and p_price_interval = 'month')
               or (v_cycle = 'annual'  and p_price_interval = 'year')) then
        v_conflict_reason  := 'price_interval_mismatch';
        v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id, 'seen_price', p_stripe_price_id,
          'derived_cycle', v_cycle, 'seen_interval', p_price_interval);
      end if;
    end if;
  end if;

  -- P12 -- status must be a legal subscription_status enum member (skipped
  -- in 'deleted' mode -- status is forced to 'canceled' below).
  if v_conflict_reason is null and p_mode <> 'deleted' then
    select (p_status in (
      select e.enumlabel from pg_enum e
      join pg_type t on t.oid = e.enumtypid
      where t.typname = 'subscription_status'
    )) into v_status_ok;
    if not coalesce(v_status_ok, false) then
      v_conflict_reason  := 'invalid_status';
      v_conflict_context := jsonb_build_object('event_id', p_stripe_event_id, 'seen_status', p_status);
    end if;
  end if;

  -- If nothing fired above but the row is ALREADY flagged, decide whether
  -- THIS call is allowed to touch it at all. Self-healing reasons are
  -- eligible from any caller once a clean pass proves the specific problem
  -- no longer exists; identity/authority reasons require an explicit
  -- p_mode='reconcile' call. If ineligible, treat it as a re-affirmed
  -- conflict on the ORIGINAL reason (never invent a new one here).
  if v_conflict_reason is null
     and v_row.reconciliation_required_at is not null
     and not (
       p_mode = 'reconcile'
       or v_row.reconciliation_reason in (
            'unknown_price', 'ambiguous_price', 'price_interval_mismatch',
            'checkout_session_mismatch', 'secondary_metadata_conflict'
          )
     )
  then
    v_conflict_reason  := v_row.reconciliation_reason;
    v_conflict_context := coalesce(v_row.reconciliation_context, '{}'::jsonb)
                           || jsonb_build_object('last_seen_event_id', p_stripe_event_id);
  end if;

  -- D.1B.1 BLOCKER 1 -- the explicit billing-identity-safety gate. Computed
  -- ONCE, from the FINAL v_conflict_reason (post re-affirm), and reused
  -- verbatim at BOTH billing-upsert call sites below (conflict path and
  -- clean path) so the rule can never drift between them. A stale lifecycle
  -- event alone (P13) never appears in c_billing_unsafe_reasons and
  -- therefore never makes this false by itself.
  v_billing_identity_safe := (v_conflict_reason is null)
    or not (v_conflict_reason = any (c_billing_unsafe_reasons));

  -- ==========================================================================
  -- CONFLICT PATH (P17 SET). No subscription-state column is written; the
  -- ordering fence (stripe_event_at) is NOT advanced. A provided invoice fact
  -- is recorded ONLY when v_billing_identity_safe -- i.e. ownership itself
  -- was never in doubt and the conflict is a harmless catalog/provenance
  -- issue (unknown_price, ambiguous_price, price_interval_mismatch,
  -- checkout_session_mismatch, secondary_metadata_conflict, invalid_status).
  -- ==========================================================================
  if v_conflict_reason is not null then
    update public.organization_subscriptions
       set reconciliation_required_at = coalesce(reconciliation_required_at, now()),
           reconciliation_reason      = v_conflict_reason,
           reconciliation_context     = v_conflict_context
     where id = v_row.id;

    v_sub_outcome := 'skipped_conflict';

    if p_invoice is not null and v_billing_identity_safe then
      v_bill_invoice_id := p_invoice ->> 'stripe_invoice_id';
      if v_bill_invoice_id is not null then
        select organization_id into v_existing_bill_org
        from public.billing_records where stripe_invoice_id = v_bill_invoice_id;
        if v_existing_bill_org is not null and v_existing_bill_org <> v_row.organization_id then
          v_bill_outcome := 'skipped_conflict';
        else
          v_bill_outcome := public._stripe_upsert_billing_record(v_row.organization_id, v_row.id, p_invoice);
        end if;
      end if;
    end if;

    if p_mode <> 'reconcile' then
      perform public.fail_stripe_webhook_event(
        p_stripe_event_id, p_claim_token, 'reconciliation_required:' || v_conflict_reason);
    end if;

    return case when v_bill_outcome in ('inserted', 'updated')
                then 'reconciliation_required_billing_recorded'
                else 'reconciliation_required' end;
  end if;

  -- ==========================================================================
  -- CLEAN PATH. v_conflict_reason is null here -- either nothing was ever
  -- flagged, or this call is eligible to clear it (P18 CLEAR).
  -- ==========================================================================

  -- P13 -- ordering fence. A 'reconcile' call always applies (it carries
  -- freshly retrieved canonical state, by definition never stale).
  v_is_stale := (p_mode <> 'reconcile')
                and p_event_at is not null
                and v_row.stripe_event_at is not null
                and v_row.stripe_event_at > p_event_at;

  if v_is_stale then
    v_sub_outcome := 'stale_skipped';
    -- Reconciliation columns (if any were set) are left exactly as-is --
    -- stale data proves nothing about whether the flagged conflict resolved.
  else
    if p_mode = 'deleted' then
      -- P14 (deleted) -- terminal state. plan_id/billing_cycle/stripe_price_id
      -- are left as historical provenance (not touched).
      update public.organization_subscriptions
         set status                  = 'canceled',
             cancel_at_period_end    = false,
             canceled_at             = coalesce(p_canceled_at, now()),
             stripe_customer_id      = coalesce(stripe_customer_id, p_stripe_customer_id),
             stripe_subscription_id  = coalesce(stripe_subscription_id, p_stripe_subscription_id),
             checkout_pending_since  = null,
             past_due_since          = null,
             stripe_event_at         = greatest(coalesce(stripe_event_at, '-infinity'::timestamptz),
                                                 coalesce(p_event_at, now())),
             reconciliation_required_at = null,
             reconciliation_reason      = null,
             reconciliation_context     = null
       where id = v_row.id;
    else
      -- P15 -- past_due_since: set once per continuous delinquency episode,
      -- preserved while continuously delinquent, cleared on recovery. Only
      -- reached when NOT stale, so a replayed/older event can never restart
      -- or disturb the clock (see P13).
      if p_status in ('past_due', 'unpaid') then
        v_new_past_due_since := coalesce(
          v_row.past_due_since,
          (p_invoice ->> 'delinquency_anchor')::timestamptz,
          p_event_at,
          now()
        );
      else
        v_new_past_due_since := null;
      end if;

      -- P14 -- apply canonical subscription state. stripe_price_id / plan_id
      -- / billing_cycle always reflect the current price (never write-once --
      -- a plan/price change is a legitimate lifecycle event); stripe_customer_id
      -- / stripe_subscription_id / stripe_checkout_session_id are write-once
      -- (coalesce: only fill when currently NULL -- P6-P8 already proved any
      -- non-NULL stored value agrees with what was just seen).
      update public.organization_subscriptions
         set status                     = p_status::public.subscription_status,
             stripe_customer_id         = coalesce(stripe_customer_id, p_stripe_customer_id),
             stripe_subscription_id     = coalesce(stripe_subscription_id, p_stripe_subscription_id),
             stripe_checkout_session_id = coalesce(stripe_checkout_session_id, p_stripe_checkout_session_id),
             stripe_price_id            = p_stripe_price_id,
             plan_id                    = v_plan_id,
             billing_cycle              = v_cycle,
             trial_end                  = p_trial_end,
             current_period_start       = p_current_period_start,
             current_period_end         = p_current_period_end,
             cancel_at_period_end       = coalesce(p_cancel_at_period_end, false),
             canceled_at                = p_canceled_at,
             past_due_since             = v_new_past_due_since,
             checkout_pending_since     = case when p_stripe_subscription_id is not null then null
                                                else checkout_pending_since end,
             stripe_event_at            = greatest(coalesce(stripe_event_at, '-infinity'::timestamptz),
                                                    coalesce(p_event_at, now())),
             reconciliation_required_at = null,
             reconciliation_reason      = null,
             reconciliation_context     = null
       where id = v_row.id;
    end if;
    v_sub_outcome := 'applied';
  end if;

  -- P16 -- billing_records upsert. Runs regardless of v_sub_outcome (never
  -- gated on P13 staleness) -- a fresh invoice fact is never suppressed by a
  -- stale subscription-state portion of the same or a different event.
  -- Reached only when v_conflict_reason was null (CONFLICT PATH above
  -- returned already otherwise), so v_billing_identity_safe is always true
  -- here in practice -- the explicit condition is kept anyway (D.1B.1
  -- BLOCKER 1) so this call site can never silently diverge from the
  -- conflict-path gate if either branch is refactored later.
  if p_invoice is not null and v_billing_identity_safe then
    v_bill_invoice_id := p_invoice ->> 'stripe_invoice_id';
    if v_bill_invoice_id is not null then
      select organization_id into v_existing_bill_org
      from public.billing_records where stripe_invoice_id = v_bill_invoice_id;
      if v_existing_bill_org is not null and v_existing_bill_org <> v_row.organization_id then
        v_bill_outcome := 'skipped_conflict';
        -- Newly discovered conflict (only visible at invoice-upsert time,
        -- i.e. the stripe_invoice_id ownership check itself failing): flag
        -- it without disturbing the subscription-state just written.
        update public.organization_subscriptions
           set reconciliation_required_at = coalesce(reconciliation_required_at, now()),
               reconciliation_reason      = 'billing_record_org_mismatch',
               reconciliation_context     = jsonb_build_object(
                 'event_id', p_stripe_event_id, 'stripe_invoice_id', v_bill_invoice_id,
                 'expected_org', v_row.organization_id, 'seen_org', v_existing_bill_org)
         where id = v_row.id;
      else
        v_bill_outcome := public._stripe_upsert_billing_record(v_row.organization_id, v_row.id, p_invoice);
      end if;
    end if;
  end if;

  -- P19 -- complete the webhook claim (reconcile calls have none to complete).
  if p_mode <> 'reconcile' then
    perform public.complete_stripe_webhook_event(p_stripe_event_id, p_claim_token);
  end if;

  return case
    when v_bill_outcome = 'skipped_conflict' then 'applied_billing_conflict'
    when v_sub_outcome = 'applied' and v_bill_outcome in ('inserted', 'updated') then 'applied_billing_recorded'
    when v_sub_outcome = 'applied' then 'applied'
    when v_sub_outcome = 'stale_skipped' and v_bill_outcome in ('inserted', 'updated') then 'stale_skipped_billing_recorded'
    when v_sub_outcome = 'stale_skipped' then 'stale_skipped'
    else 'noop'
  end;
end;
$fn$;

comment on function public.apply_stripe_subscription_state(
  text, uuid, uuid, text, text, text, text, text, text, text,
  timestamptz, timestamptz, timestamptz, boolean, timestamptz, timestamptz, text, jsonb
) is
  'SERVICE ROLE ONLY. The single atomic business-effect RPC for Stripe SaaS-subscription reconciliation (D.2 webhook handler + explicit reconcile action). No metadata-based organization adoption -- p_organization_subscription_id must already be resolved by the caller from a stored TDP mapping. Derives plan_id/billing_cycle from stripe_price_id against subscription_plans inside this transaction; never trusts a caller-supplied plan/cycle. Applies the ordering fence (stripe_event_at) to subscription-state columns only. billing_records is upserted independently of subscription-state staleness, but ONLY while the explicit v_billing_identity_safe gate holds -- ownership (customer/subscription/org) must never be in doubt, though harmless catalog/provenance conflicts (unknown price, ambiguous price, price interval mismatch, checkout-session pointer mismatch, secondary metadata disagreement, invalid subscription status) do not block it. Sets/clears reconciliation_required_at/_reason/_context per the frozen D.1A rules. Completes or fails the stripe_webhook_events claim as its last statement, atomically with every other write in this call.';

revoke execute on function public.apply_stripe_subscription_state(
  text, uuid, uuid, text, text, text, text, text, text, text,
  timestamptz, timestamptz, timestamptz, boolean, timestamptz, timestamptz, text, jsonb
) from public, anon, authenticated;
grant execute on function public.apply_stripe_subscription_state(
  text, uuid, uuid, text, text, text, text, text, text, text,
  timestamptz, timestamptz, timestamptz, boolean, timestamptz, timestamptz, text, jsonb
) to service_role;

-- ======================= PHASE 3 -- POSTCONDITIONS =========================
do $mig$
declare
  v_n    integer;
  v_def  text;
  v_norm text;
  v_cols name[];
  c_expected_gf_check constant text :=
    'check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null';
  c_apply_regproc constant regprocedure :=
    'public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)'::regprocedure;
  c_upsert_regproc constant regprocedure :=
    'public._stripe_upsert_billing_record(uuid,uuid,jsonb)'::regprocedure;
begin
  -- --- new columns: shape + NULL on every existing row ---
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions' and column_name='reconciliation_required_at'
      and data_type='timestamp with time zone' and is_nullable='YES' and column_default is null
  ) then
    raise exception '0127 postcondition: reconciliation_required_at is not (timestamptz, nullable, no default).';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions' and column_name='reconciliation_reason'
      and data_type='text' and is_nullable='YES' and column_default is null
  ) then
    raise exception '0127 postcondition: reconciliation_reason is not (text, nullable, no default).';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions' and column_name='reconciliation_context'
      and data_type='jsonb' and is_nullable='YES' and column_default is null
  ) then
    raise exception '0127 postcondition: reconciliation_context is not (jsonb, nullable, no default).';
  end if;

  execute 'select count(*) from public.organization_subscriptions where reconciliation_required_at is not null or reconciliation_reason is not null or reconciliation_context is not null'
    into v_n;
  if v_n <> 0 then
    raise exception '0127 postcondition: % row(s) have a non-NULL reconciliation_* column -- 0127 must write ZERO row data.', v_n;
  end if;

  -- --- no index / constraint attached to the 3 new columns ---
  if exists (
    select 1 from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    where c.conrelid = 'public.organization_subscriptions'::regclass
      and a.attname in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')
  ) then
    raise exception '0127 postcondition: a constraint references a reconciliation_* column (expected none).';
  end if;
  if exists (
    select 1 from pg_index i
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
    where i.indrelid = 'public.organization_subscriptions'::regclass
      and a.attname in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')
  ) then
    raise exception '0127 postcondition: an index references a reconciliation_* column (expected none -- reviewer decision).';
  end if;

  -- --- billing_records privilege hardening ---
  if has_table_privilege('authenticated', 'public.billing_records', 'INSERT')
     or has_table_privilege('authenticated', 'public.billing_records', 'UPDATE')
     or has_table_privilege('authenticated', 'public.billing_records', 'DELETE') then
    raise exception '0127 postcondition: authenticated still has INSERT/UPDATE/DELETE on billing_records.';
  end if;
  if not has_table_privilege('authenticated', 'public.billing_records', 'SELECT') then
    raise exception '0127 postcondition: authenticated lost SELECT on billing_records (must be preserved).';
  end if;
  if has_table_privilege('anon', 'public.billing_records', 'SELECT')
     or has_table_privilege('anon', 'public.billing_records', 'INSERT')
     or has_table_privilege('anon', 'public.billing_records', 'UPDATE')
     or has_table_privilege('anon', 'public.billing_records', 'DELETE') then
    raise exception '0127 postcondition: anon still has a privilege on billing_records.';
  end if;
  if not has_table_privilege('service_role', 'public.billing_records', 'INSERT') then
    raise exception '0127 postcondition: service_role lost INSERT on billing_records -- its independent grant must be untouched.';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.billing_records'::regclass) then
    raise exception '0127 postcondition: RLS no longer enabled on billing_records.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_select') then
    raise exception '0127 postcondition: billing_records_select policy is gone.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_platform_admin_select') then
    raise exception '0127 postcondition: billing_records_platform_admin_select policy is gone.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and cmd in ('INSERT','UPDATE','DELETE')) then
    raise exception '0127 postcondition: an INSERT/UPDATE/DELETE-scoped policy appeared on billing_records.';
  end if;

  -- --- functions: existence, security, grants ---
  if to_regprocedure('public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)') is null then
    raise exception '0127 postcondition: apply_stripe_subscription_state(...) with the exact 18-arg signature is missing.';
  end if;
  if to_regprocedure('public._stripe_upsert_billing_record(uuid,uuid,jsonb)') is null then
    raise exception '0127 postcondition: _stripe_upsert_billing_record(uuid,uuid,jsonb) is missing.';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.oid = c_apply_regproc
      and p.prosecdef
      and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%'
  ) then
    raise exception '0127 postcondition: apply_stripe_subscription_state is not (security definer, search_path=public).';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid = c_upsert_regproc
      and p.prosecdef
      and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%'
  ) then
    raise exception '0127 postcondition: _stripe_upsert_billing_record is not (security definer, search_path=public).';
  end if;

  if has_function_privilege('authenticated', c_apply_regproc, 'EXECUTE')
     or has_function_privilege('anon', c_apply_regproc, 'EXECUTE') then
    raise exception '0127 postcondition: apply_stripe_subscription_state is EXECUTE-able by authenticated/anon -- must be service_role only.';
  end if;
  if not has_function_privilege('service_role', c_apply_regproc, 'EXECUTE') then
    raise exception '0127 postcondition: apply_stripe_subscription_state is NOT EXECUTE-able by service_role.';
  end if;
  -- D.1B.2: explicit per-application-role assertions (NOT an attempt to
  -- prove "no database role whatsoever can execute this" -- the function
  -- OWNER retains implicit EXECUTE by virtue of ownership, which no REVOKE
  -- targeting another role can remove, and is never tested here; that is
  -- exactly what lets apply_stripe_subscription_state(), owned by the same
  -- role and running SECURITY DEFINER, keep invoking this helper
  -- internally). What MUST be false is EXECUTE for every application-facing
  -- role that could otherwise reach this function directly via PostgREST.
  if has_function_privilege('anon', c_upsert_regproc, 'EXECUTE') then
    raise exception '0127 postcondition: _stripe_upsert_billing_record is EXECUTE-able by anon.';
  end if;
  if has_function_privilege('authenticated', c_upsert_regproc, 'EXECUTE') then
    raise exception '0127 postcondition: _stripe_upsert_billing_record is EXECUTE-able by authenticated.';
  end if;
  if has_function_privilege('service_role', c_upsert_regproc, 'EXECUTE') then
    raise exception '0127 postcondition: _stripe_upsert_billing_record is EXECUTE-able by service_role -- D.1B.2 root cause (Supabase''s schema-level default privileges grant EXECUTE on every new function to service_role at CREATE time; it must be explicitly revoked, not merely omitted from a grant).';
  end if;
  -- Direct ACL check: no PUBLIC grant remains. A PUBLIC entry in proacl is
  -- an aclitem whose grantee is empty (rendered as a leading "=", e.g.
  -- "=X/postgres") -- this is independent confirmation of (and would, if it
  -- ever failed, explain) the three has_function_privilege checks above,
  -- since every role implicitly inherits whatever PUBLIC is granted.
  if exists (
    select 1 from pg_proc p, unnest(p.proacl) as a
    where p.oid = c_upsert_regproc and a::text like '=%'
  ) then
    raise exception '0127 postcondition: _stripe_upsert_billing_record still has a PUBLIC grant in its ACL.';
  end if;

  -- --- function body static assertions (no metadata adoption, DB-derived
  --     plan/cycle, atomic ownership of complete_/fail_, M-CTRL / freight
  --     isolation) ---
  select pg_get_functiondef(c_apply_regproc) into v_def;
  if v_def not ilike '%subscription_plans%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state does not reference subscription_plans (plan/cycle must be DB-derived).';
  end if;
  if v_def not ilike '%for update%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state does not take a row lock (FOR UPDATE).';
  end if;
  if v_def not ilike '%complete_stripe_webhook_event%' or v_def not ilike '%fail_stripe_webhook_event%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state does not call both complete_/fail_stripe_webhook_event.';
  end if;
  if v_def not ilike '%stripe_event_at%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state does not reference the stripe_event_at ordering fence.';
  end if;
  if v_def not ilike '%billing_records%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state does not reference billing_records.';
  end if;
  if v_def ilike '%public.invoices%' or v_def ilike '%public.payments%' or v_def ilike '%settlement%'
     or v_def ilike '%quickbooks%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state references a freight-accounting or QuickBooks object -- must stay isolated.';
  end if;
  if v_def ilike '%platform_settings%' or v_def ilike '%proceeds_model%' or v_def ilike '%proceeds_payer%'
     or v_def ilike '%financial_dispatch_id%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state references an M-CTRL object -- must stay isolated.';
  end if;
  -- The signature itself is the proof there is no p_plan_id / p_billing_cycle
  -- input: pg_get_function_arguments lists every parameter name.
  if pg_get_function_arguments(c_apply_regproc) ilike '%plan_id%'
     or pg_get_function_arguments(c_apply_regproc) ilike '%billing_cycle%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state accepts a plan_id/billing_cycle parameter -- plan/cycle must be DB-derived only, never caller-supplied.';
  end if;

  -- --- D.1B.1 BLOCKER 1: the explicit billing-identity-safety gate exists
  --     and is used at BOTH billing-upsert call sites (conflict path +
  --     clean path), not merely implied by control flow. ---
  select pg_get_functiondef(c_apply_regproc) into v_def;  -- re-fetch: harmless, keeps this block self-contained
  if v_def not ilike '%c_billing_unsafe_reasons%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state does not declare c_billing_unsafe_reasons (D.1B.1 BLOCKER 1 gate missing).';
  end if;
  if v_def not ilike '%customer_mismatch%' or v_def not ilike '%customer_unbound%'
     or v_def not ilike '%subscription_mismatch%' or v_def not ilike '%billing_record_org_mismatch%'
     or v_def not ilike '%grandfathered_stripe_event%' or v_def not ilike '%billing_not_required_stripe_attach%' then
    raise exception '0127 postcondition: apply_stripe_subscription_state is missing one of the six c_billing_unsafe_reasons tokens.';
  end if;
  if (length(v_def) - length(replace(v_def, 'and v_billing_identity_safe', '')))
       / length('and v_billing_identity_safe') <> 2 then
    raise exception '0127 postcondition: v_billing_identity_safe is not used as an explicit guard at exactly the 2 expected billing-upsert call sites.';
  end if;

  select pg_get_functiondef(c_upsert_regproc) into v_def;
  if v_def not ilike '%on conflict%stripe_invoice_id%' then
    raise exception '0127 postcondition: _stripe_upsert_billing_record is not an ON CONFLICT (stripe_invoice_id) upsert.';
  end if;
  -- --- D.1B.1 BLOCKER 2: unrecognized non-NULL invoice status FAILS CLOSED
  --     (RAISE), never silently coerced. ---
  if v_def not ilike '%raise exception%' then
    raise exception '0127 postcondition: _stripe_upsert_billing_record does not RAISE on an unrecognized status (BLOCKER 2 fix missing).';
  end if;
  if v_def ilike '%else ''open'' end%' or v_def ilike '%else ''open''end%' then
    raise exception '0127 postcondition: _stripe_upsert_billing_record still silently coerces an unrecognized status to open (old CASE...ELSE ''open'' pattern found).';
  end if;
  if v_def not ilike '%coalesce(v_status_in, ''open'')%' then
    raise exception '0127 postcondition: _stripe_upsert_billing_record no longer defaults a NULL (absent) status to open.';
  end if;

  -- --- organization_subscriptions structural invariants unchanged ---
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conrelid='public.organization_subscriptions'::regclass
    and c.conname='organization_subscriptions_grandfather_has_no_stripe' and c.contype='c';
  if v_def is null then
    raise exception '0127 postcondition: the grandfather CHECK is gone.';
  end if;
  v_norm := btrim(regexp_replace(regexp_replace(lower(v_def), '[()]', '', 'g'), '\s+', ' ', 'g'));
  if v_norm <> c_expected_gf_check then
    raise exception '0127 postcondition: the grandfather CHECK predicate changed. Actual: "%".', v_def;
  end if;

  select array_agg(a.attname order by k.ord) into v_cols
  from pg_constraint c cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
  join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum
  where c.conrelid='public.organization_subscriptions'::regclass
    and c.conname='organization_subscriptions_organization_id_key' and c.contype='u';
  if v_cols is null or cardinality(v_cols)<>1 or v_cols[1]<>'organization_id' then
    raise exception '0127 postcondition: organization_subscriptions_organization_id_key is no longer UNIQUE on exactly {organization_id}.';
  end if;

  if not exists (
    select 1 from pg_trigger where tgrelid='public.organization_subscriptions'::regclass and tgname='set_updated_at' and not tgisinternal
  ) then
    raise exception '0127 postcondition: the set_updated_at trigger on organization_subscriptions is gone.';
  end if;
  if not (select relrowsecurity from pg_class where oid='public.organization_subscriptions'::regclass) then
    raise exception '0127 postcondition: RLS no longer enabled on organization_subscriptions.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and policyname='organization_subscriptions_select')
     or not exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and policyname='organization_subscriptions_platform_admin_all') then
    raise exception '0127 postcondition: an expected policy on organization_subscriptions is gone.';
  end if;
  if exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and cmd in ('INSERT','UPDATE','DELETE')) then
    raise exception '0127 postcondition: an INSERT/UPDATE/DELETE-scoped tenant policy appeared on organization_subscriptions.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions' and column_name='stripe_checkout_attempt_id'
  ) then
    raise exception '0127 postcondition: 0124 landmark stripe_checkout_attempt_id disappeared.';
  end if;

  -- --- counts unchanged (ZERO row DML proof) ---
  if (select count(*) from public.organizations) <> 64 then
    raise exception '0127 postcondition: organizations count changed.';
  end if;
  if (select count(*) from public.organizations where billing_required=false) <> 63 then
    raise exception '0127 postcondition: organizations billing_required=false count changed.';
  end if;
  if (select count(*) from public.organization_subscriptions) <> 4 then
    raise exception '0127 postcondition: organization_subscriptions count changed.';
  end if;
  if (select count(*) from public.organization_subscriptions where grandfathered_at is not null) <> 3 then
    raise exception '0127 postcondition: grandfathered subscription count changed.';
  end if;
  if exists (
    select 1 from public.organization_subscriptions
    where grandfathered_at is not null
      and (stripe_customer_id is not null or stripe_subscription_id is not null or stripe_price_id is not null)
  ) then
    raise exception '0127 postcondition: a grandfathered subscription row gained a Stripe id.';
  end if;
  if (select count(*) from public.billing_records) <> 0 then
    raise exception '0127 postcondition: billing_records is no longer empty.';
  end if;
  if (select count(*) from public.stripe_webhook_events) <> 0 then
    raise exception '0127 postcondition: stripe_webhook_events is no longer empty.';
  end if;
  if (select count(*) from public.subscription_plans) <> 5 then
    raise exception '0127 postcondition: subscription_plans count changed.';
  end if;

  -- --- United Leather (C.4 fixture) landmark, re-checked including the new columns ---
  if not exists (
    select 1 from public.organization_subscriptions
    where organization_id = 'ca6457e6-8ae8-4e85-adc9-4a0dabb2386e'
      and status = 'incomplete'
      and grandfathered_at is null
      and stripe_customer_id is not null
      and stripe_checkout_session_id is not null
      and stripe_checkout_attempt_id is not null
      and stripe_subscription_id is null
      and stripe_price_id is null
      and reconciliation_required_at is null
      and reconciliation_reason is null
      and reconciliation_context is null
  ) then
    raise exception '0127 postcondition: the United Leather organization_subscriptions row is no longer in its expected untouched C.4 shape.';
  end if;

  -- --- M-CTRL (0125/0126) landmark untouched ---
  if (select model_a_enabled from public.platform_settings where id = true) is not false then
    raise exception '0127 postcondition: platform_settings.model_a_enabled is not FALSE.';
  end if;
  if coalesce(col_description('public.loads'::regclass,
        (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='financial_dispatch_id')), '')
     not ilike '%backfilled by migration 0126%' then
    raise exception '0127 postcondition: loads.financial_dispatch_id lost its 0126 backfill marker.';
  end if;

  raise notice '0127 complete: reconciliation_required_at/_reason/_context added to organization_subscriptions (NULL on every row, no index); billing_records tenant write privileges revoked (SELECT preserved for authenticated, service_role untouched); _stripe_upsert_billing_record() and apply_stripe_subscription_state() (18-arg, service_role only) created. ZERO rows written by this migration. Grandfather CHECK, RLS, policies, 0124 landmark, United Leather C.4 fixture, and M-CTRL (0125/0126) state all verified unchanged.';
end
$mig$;
