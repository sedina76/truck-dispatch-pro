-- =============================================================================
-- 0128_fix_stripe_plan_uuid_aggregate.sql
--
-- PRE-APPLY -- APPLY AS ONE TRANSACTION. REQUIRES 0119-0127 live.
--
-- TARGETED REPAIR of a single runtime defect in 0127's
-- public.apply_stripe_subscription_state(): its P10-P11 plan-resolution query
-- aggregates a uuid column with min(), and PostgreSQL has NO min(uuid) /
-- max(uuid) aggregate, so every live webhook / reconcile call that reaches
-- that branch fails with:
--
--   ERROR 42883: function min(uuid) does not exist
--   (0127 line 776:  select count(*), min(sp.id) into v_plan_matches, v_plan_id)
--
-- surfaced by the D.2 webhook runtime as
--   {"ok":false,"error":"rpc_exception","detail":"42883"}
-- and leaving organization_subscriptions stuck at status='incomplete' /
-- stripe_subscription_id=NULL even when a valid Stripe subscription exists.
--
-- WHAT THIS MIGRATION DOES
--   * CREATE OR REPLACE public.apply_stripe_subscription_state(<18 args>) with
--     the EXACT 0127 definition, changing ONE expression:
--         min(sp.id)            (0127)
--       ->  min(sp.id::text)::uuid   (here)
--     min(text) is a native aggregate; the ::uuid cast restores the uuid
--     result. Behaviourally identical: that branch only USES v_plan_id when
--     exactly one plan matched (count = 1), and min() of a one-element set is
--     that element; the count > 1 ('ambiguous_price') branch never reads
--     v_plan_id. The signature, SECURITY DEFINER, `set search_path = public`,
--     _stripe_assert_service_role() P1 gate, webhook claim-token ownership
--     (P2), row lock (P3), P4-P12 identity/authority/catalog gates,
--     reconciliation set/clear rules (P17/P18), the D.1B.1 v_billing_identity_safe
--     billing-safety gate (used verbatim at both upsert call sites), the
--     ordering fence, and the atomic complete_/fail_ webhook-claim completion
--     are all reproduced byte-for-byte from 0127.
--   * re-asserts the exact 0127 comment + `revoke execute ... from public,
--     anon, authenticated` + `grant execute ... to service_role` for the
--     function (idempotent; identical to 0127).
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * ZERO row DML. Only CREATE OR REPLACE FUNCTION + COMMENT + REVOKE/GRANT.
--     The function BODY's DML runs only when a service-role caller invokes it.
--   * does NOT modify or rerun 0127.
--   * does NOT touch public._stripe_upsert_billing_record (unchanged: still
--     EXECUTE-denied to anon, authenticated AND service_role -- D.1B.2).
--   * does NOT touch organization_subscriptions.reconciliation_required_at /
--     _reason / _context, the billing_records privilege hardening,
--     billing_records / stripe_webhook_events / subscription_plans /
--     organizations / organization_subscriptions rows, RLS, policies, the
--     grandfather CHECK, the 0119 claim/complete/fail RPCs, or any
--     0115-0126 / M-CTRL / freight-accounting / QuickBooks object.
--
-- STRUCTURE: leading DO block = PHASE 1 read-only preconditions. Plain
-- top-level DDL = PHASE 2. Trailing DO block = PHASE 3 postconditions. One
-- transaction; any RAISE rolls everything back. Re-runnable ONLY in the sense
-- that CREATE OR REPLACE is idempotent -- but PHASE 1 RAISEs once the fixed
-- expression is already live (nothing to repair).
-- =============================================================================

-- ======================= PHASE 1 -- READ-ONLY PRECONDITIONS ==================
do $mig$
declare
  c_apply_regproc constant regprocedure :=
    'public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)'::regprocedure;
  v_def  text;
  v_code text;   -- v_def with SQL line comments removed + whitespace collapsed
begin
  -- 0119-0127 landmarks the repaired function depends on.
  if to_regclass('public.organization_subscriptions') is null then raise exception '0128 precondition: public.organization_subscriptions missing. STOP.'; end if;
  if to_regclass('public.subscription_plans')          is null then raise exception '0128 precondition: public.subscription_plans missing. STOP.'; end if;
  if to_regclass('public.billing_records')             is null then raise exception '0128 precondition: public.billing_records missing. STOP.'; end if;
  if to_regclass('public.stripe_webhook_events')       is null then raise exception '0128 precondition: public.stripe_webhook_events missing. STOP.'; end if;
  if to_regprocedure('public._stripe_assert_service_role()') is null then raise exception '0128 precondition: public._stripe_assert_service_role() missing -- apply 0119. STOP.'; end if;
  if to_regprocedure('public.complete_stripe_webhook_event(text,uuid)') is null then raise exception '0128 precondition: public.complete_stripe_webhook_event(text,uuid) missing -- apply 0119. STOP.'; end if;
  if to_regprocedure('public.fail_stripe_webhook_event(text,uuid,text)') is null then raise exception '0128 precondition: public.fail_stripe_webhook_event(text,uuid,text) missing -- apply 0119. STOP.'; end if;

  -- 0127 must ALREADY be applied: the private helper, the reconciliation
  -- columns, and the (buggy) apply RPC must all be present.
  if to_regprocedure('public._stripe_upsert_billing_record(uuid,uuid,jsonb)') is null then
    raise exception '0128 precondition: public._stripe_upsert_billing_record(uuid,uuid,jsonb) missing -- apply 0127 first. STOP.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions'
      and column_name in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')
    having count(*) = 3
  ) then
    raise exception '0128 precondition: organization_subscriptions is missing a reconciliation_* column -- apply 0127 first. STOP.';
  end if;
  if to_regprocedure('public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)') is null then
    raise exception '0128 precondition: apply_stripe_subscription_state(18-arg) missing -- apply 0127 first. STOP.';
  end if;

  -- The live function body must still carry the 0127 defect and NOT already
  -- carry the fix (proves this repair is needed and not already applied).
  --
  -- IMPORTANT: test the ACTUAL SQL STATEMENT, not raw pg_get_functiondef()
  -- text. Strip every `-- ...` line comment and collapse whitespace first, so
  -- an explanatory comment that happens to spell out "min(sp.id)" or
  -- "count(*), min(sp.id::text)::uuid" can never satisfy a code check. (An
  -- earlier 0128 apply rolled back precisely because a body comment matched
  -- `min(\s*sp\.id\s*\)`.) The P10/P11 plan-resolution statement is the only
  -- place "count(*), min(" occurs in this function.
  v_def  := pg_get_functiondef(c_apply_regproc);
  v_code := regexp_replace(regexp_replace(v_def, '--[^\n]*', '', 'g'), '\s+', ' ', 'g');
  if v_code not like '%count(*), min(sp.id)%' then
    raise exception '0128 precondition: the live P10/P11 statement is not "select count(*), min(sp.id) ..." -- the 0127 body is not the frozen definition this repair targets. STOP and inspect.';
  end if;
  if v_code like '%count(*), min(sp.id::text)::uuid%' then
    raise exception '0128 precondition: the "count(*), min(sp.id::text)::uuid" fix is ALREADY live -- 0128 (or an equivalent) has been applied. Nothing to do. STOP.';
  end if;

  -- Function currently SECURITY DEFINER + search_path=public + service_role-only
  -- EXECUTE -- 0128 must preserve exactly this posture.
  if not exists (
    select 1 from pg_proc p
    where p.oid = c_apply_regproc and p.prosecdef
      and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%'
  ) then
    raise exception '0128 precondition: live apply_stripe_subscription_state is not (security definer, search_path=public). STOP.';
  end if;
  if not (select has_function_privilege('service_role', c_apply_regproc, 'EXECUTE'))
     or (select has_function_privilege('authenticated', c_apply_regproc, 'EXECUTE'))
     or (select has_function_privilege('anon', c_apply_regproc, 'EXECUTE')) then
    raise exception '0128 precondition: live apply_stripe_subscription_state EXECUTE grants are not exactly {service_role}. STOP.';
  end if;

  -- 0122 catalog anchors (the query being repaired reads subscription_plans).
  if (select count(*) from public.subscription_plans where is_public and is_active) <> 2 then
    raise exception '0128 precondition: expected exactly 2 public+active subscription_plans rows. STOP.';
  end if;

  raise notice '0128 PHASE 1 preconditions passed -- live apply_stripe_subscription_state carries the min(uuid) defect; replacing with the min(sp.id::text)::uuid fix.';
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ================================
-- EXACT 0127 definition of public.apply_stripe_subscription_state, with the
-- SINGLE change:  min(sp.id)  ->  min(sp.id::text)::uuid  (marked "0128 FIX").
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
  -- 0128: this line is the ONLY change from 0127's frozen definition --
  --   0127:  select count(*), min(sp.id)
  --   0128:  select count(*), min(sp.id::text)::uuid
  -- PostgreSQL has no min(uuid)/max(uuid) aggregate; min(text) is native and
  -- the ::uuid cast restores the result type. Behaviourally identical: this
  -- value is read only when exactly one plan matched (min of a 1-element set
  -- = that element); the count>1 'ambiguous_price' branch never reads it.
  if v_conflict_reason is null and p_mode <> 'deleted' then
    select count(*), min(sp.id::text)::uuid
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
  c_apply_regproc constant regprocedure :=
    'public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)'::regprocedure;
  c_upsert_regproc constant regprocedure :=
    'public._stripe_upsert_billing_record(uuid,uuid,jsonb)'::regprocedure;
  v_def  text;
  v_code text;   -- v_def with SQL line comments removed + whitespace collapsed
begin
  -- --- the fix is live, the defect is gone ---
  -- Test the ACTUAL SQL statement: strip `-- ...` comments + collapse
  -- whitespace so a body comment mentioning either expression cannot match.
  -- "count(*), min(" occurs only in the P10/P11 plan-resolution statement;
  -- the repaired form "count(*), min(sp.id::text)::uuid" does not contain the
  -- substring "count(*), min(sp.id)" (there is "::text)" after sp.id, not ")").
  v_def  := pg_get_functiondef(c_apply_regproc);
  v_code := regexp_replace(regexp_replace(v_def, '--[^\n]*', '', 'g'), '\s+', ' ', 'g');
  if v_code not like '%count(*), min(sp.id::text)::uuid%' then
    raise exception '0128 postcondition: the P10/P11 statement is not "select count(*), min(sp.id::text)::uuid ...".';
  end if;
  if v_code like '%count(*), min(sp.id)%' then
    raise exception '0128 postcondition: the bare "count(*), min(sp.id)" (uuid aggregate) statement is still present.';
  end if;

  -- --- signature, security, grants preserved exactly ---
  if to_regprocedure('public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)') is null then
    raise exception '0128 postcondition: the exact 18-arg apply_stripe_subscription_state signature is missing.';
  end if;
  if not exists (
    select 1 from pg_proc p
    where p.oid = c_apply_regproc and p.prosecdef
      and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%'
  ) then
    raise exception '0128 postcondition: apply_stripe_subscription_state is not (security definer, search_path=public).';
  end if;
  if not has_function_privilege('service_role', c_apply_regproc, 'EXECUTE')
     or has_function_privilege('authenticated', c_apply_regproc, 'EXECUTE')
     or has_function_privilege('anon', c_apply_regproc, 'EXECUTE') then
    raise exception '0128 postcondition: apply_stripe_subscription_state EXECUTE grants are not exactly {service_role}.';
  end if;

  -- --- every 0127 body invariant reproduced verbatim ---
  if v_def not ilike '%_stripe_assert_service_role%' then
    raise exception '0128 postcondition: P1 _stripe_assert_service_role() gate missing.';
  end if;
  if v_def not ilike '%claim_token = p_claim_token%' or v_def not ilike '%status = ''processing''%' then
    raise exception '0128 postcondition: P2 webhook claim-token ownership check missing.';
  end if;
  if v_def not ilike '%for update of os%' then
    raise exception '0128 postcondition: P3 row lock (FOR UPDATE OF os) missing.';
  end if;
  if v_def not ilike '%subscription_plans%' then
    raise exception '0128 postcondition: DB-derived plan/cycle (subscription_plans) reference missing.';
  end if;
  if v_def not ilike '%stripe_event_at%'
     or v_def not ilike '%greatest(coalesce(stripe_event_at%' then
    raise exception '0128 postcondition: the stripe_event_at ordering fence is missing.';
  end if;
  if v_def not ilike '%complete_stripe_webhook_event%' or v_def not ilike '%fail_stripe_webhook_event%' then
    raise exception '0128 postcondition: atomic complete_/fail_stripe_webhook_event calls missing.';
  end if;
  if v_def not ilike '%c_billing_unsafe_reasons%'
     or v_def not ilike '%customer_mismatch%' or v_def not ilike '%customer_unbound%'
     or v_def not ilike '%subscription_mismatch%' or v_def not ilike '%billing_record_org_mismatch%'
     or v_def not ilike '%grandfathered_stripe_event%' or v_def not ilike '%billing_not_required_stripe_attach%' then
    raise exception '0128 postcondition: the D.1B.1 c_billing_unsafe_reasons gate is missing a token.';
  end if;
  if (length(v_def) - length(replace(v_def, 'and v_billing_identity_safe', '')))
       / length('and v_billing_identity_safe') <> 2 then
    raise exception '0128 postcondition: v_billing_identity_safe is not used as an explicit guard at exactly the 2 billing-upsert call sites.';
  end if;
  if v_def not ilike '%reconciliation_required_at = coalesce(reconciliation_required_at, now())%' then
    raise exception '0128 postcondition: the reconciliation SET rule (coalesce anchor) is missing.';
  end if;
  if v_def not ilike '%reconciliation_reason      = null%' or v_def not ilike '%''unknown_price'', ''ambiguous_price'', ''price_interval_mismatch''%' then
    raise exception '0128 postcondition: the reconciliation CLEAR rules / self-healing reason list drifted.';
  end if;
  if v_def ilike '%public.invoices%' or v_def ilike '%public.payments%' or v_def ilike '%settlement%'
     or v_def ilike '%quickbooks%' or v_def ilike '%platform_settings%' or v_def ilike '%proceeds_model%'
     or v_def ilike '%proceeds_payer%' or v_def ilike '%financial_dispatch_id%' then
    raise exception '0128 postcondition: apply_stripe_subscription_state now references a freight-accounting / QuickBooks / M-CTRL object -- must stay isolated.';
  end if;
  if pg_get_function_arguments(c_apply_regproc) ilike '%plan_id%'
     or pg_get_function_arguments(c_apply_regproc) ilike '%billing_cycle%' then
    raise exception '0128 postcondition: apply_stripe_subscription_state accepts a plan_id/billing_cycle parameter -- must be DB-derived only.';
  end if;

  -- --- _stripe_upsert_billing_record left completely untouched ---
  if to_regprocedure('public._stripe_upsert_billing_record(uuid,uuid,jsonb)') is null then
    raise exception '0128 postcondition: _stripe_upsert_billing_record(uuid,uuid,jsonb) disappeared -- 0128 must not touch it.';
  end if;
  if has_function_privilege('anon', c_upsert_regproc, 'EXECUTE')
     or has_function_privilege('authenticated', c_upsert_regproc, 'EXECUTE')
     or has_function_privilege('service_role', c_upsert_regproc, 'EXECUTE') then
    raise exception '0128 postcondition: _stripe_upsert_billing_record EXECUTE grant changed -- must remain denied to anon, authenticated AND service_role (D.1B.2).';
  end if;
  if exists (select 1 from pg_proc p, unnest(p.proacl) as a where p.oid = c_upsert_regproc and a::text like '=%') then
    raise exception '0128 postcondition: _stripe_upsert_billing_record gained a PUBLIC grant -- 0128 must not touch it.';
  end if;

  -- --- 0127 structural state untouched ---
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions'
      and column_name in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')
    having count(*) = 3
  ) then
    raise exception '0128 postcondition: a reconciliation_* column disappeared -- 0128 must not touch them.';
  end if;
  if has_table_privilege('authenticated', 'public.billing_records', 'INSERT')
     or has_table_privilege('authenticated', 'public.billing_records', 'UPDATE')
     or has_table_privilege('authenticated', 'public.billing_records', 'DELETE') then
    raise exception '0128 postcondition: authenticated regained a write privilege on billing_records -- 0128 must not touch grants.';
  end if;
  if not has_table_privilege('authenticated', 'public.billing_records', 'SELECT')
     or not has_table_privilege('service_role', 'public.billing_records', 'INSERT') then
    raise exception '0128 postcondition: billing_records SELECT/service_role INSERT posture changed -- 0128 must not touch grants.';
  end if;

  -- --- ZERO row DML by this migration ---
  if (select count(*) from public.organization_subscriptions
        where reconciliation_required_at is not null
           or reconciliation_reason is not null
           or reconciliation_context is not null) <> 0 then
    raise exception '0128 postcondition: a reconciliation_* column is non-NULL -- 0128 must write ZERO row data.';
  end if;
  if (select count(*) from public.billing_records) <> 0 then
    raise notice '0128 note: billing_records has % row(s) -- not written by this migration (informational).',
      (select count(*) from public.billing_records);
  end if;

  raise notice '0128 complete: public.apply_stripe_subscription_state replaced with the exact 0127 definition, min(sp.id) -> min(sp.id::text)::uuid. Signature, SECURITY DEFINER, search_path, EXECUTE grants (service_role only), P1-P19 gates, reconciliation set/clear rules, D.1B.1 billing-identity-safety gate, ordering fence, and atomic webhook-claim completion all unchanged. _stripe_upsert_billing_record, reconciliation_* columns, and billing_records privileges untouched. ZERO rows written.';
end
$mig$;
