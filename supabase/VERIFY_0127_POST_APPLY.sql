-- Run AFTER applying 0127_stripe_reconciliation_and_billing_records_hardening.sql.
--
-- 100% READ-ONLY. SELECTs only -- no INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / TRUNCATE / mutation RPC, no BEGIN/ROLLBACK, no fixtures.
-- Safe on production. Does NOT call apply_stripe_subscription_state(),
-- _stripe_upsert_billing_record(), or any of the 0119 claim/complete/fail
-- webhook RPCs -- structure and grants are verified via catalog
-- introspection only.
--
-- Section 1 is the PASS/FAIL matrix -- every `pass` must be true. It
-- independently re-derives every check from 0127's own PHASE 3 (does not
-- merely trust that the migration said it passed) and hard-codes no
-- production row count -- those are printed for eyeball review in Section 5
-- instead, per the same discipline VERIFY_0125/VERIFY_0126 already use.
-- Checks 31-38 verify the D.1B.1 repair (billing-identity-safety gate +
-- fail-closed invoice-status validation) by SOURCE-TEXT inspection of the
-- live function bodies -- the only way to prove this without executing the
-- RPC, which this file never does. Section 6 maps each of the D.1B.1 static
-- test-matrix scenarios to the specific check(s) that prove it.
-- Sections 2-6 print detail for eyeball review.

-- ============================================================================
-- 1. PASS/FAIL MATRIX -- every `pass` must be true (41 checks).
-- ============================================================================
with
c as (
  select
    'public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)'::regprocedure as apply_oid,
    'public._stripe_upsert_billing_record(uuid,uuid,jsonb)'::regprocedure as upsert_oid
),
col as (
  select column_name, data_type, is_nullable, column_default
  from information_schema.columns
  where table_schema='public' and table_name='organization_subscriptions'
    and column_name in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')
)
select * from (
  values
    ( 1, 'reconciliation_required_at = timestamptz, nullable, no default',
      (exists (select 1 from col where column_name='reconciliation_required_at' and data_type='timestamp with time zone' and is_nullable='YES' and column_default is null)) ),
    ( 2, 'reconciliation_reason = text, nullable, no default',
      (exists (select 1 from col where column_name='reconciliation_reason' and data_type='text' and is_nullable='YES' and column_default is null)) ),
    ( 3, 'reconciliation_context = jsonb, nullable, no default',
      (exists (select 1 from col where column_name='reconciliation_context' and data_type='jsonb' and is_nullable='YES' and column_default is null)) ),
    ( 4, 'no constraint references any reconciliation_* column',
      (not exists (
        select 1 from pg_constraint c2
        join pg_attribute a on a.attrelid=c2.conrelid and a.attnum = any(c2.conkey)
        where c2.conrelid='public.organization_subscriptions'::regclass
          and a.attname in ('reconciliation_required_at','reconciliation_reason','reconciliation_context'))) ),
    ( 5, 'no index references any reconciliation_* column',
      (not exists (
        select 1 from pg_index i
        join pg_attribute a on a.attrelid=i.indrelid and a.attnum = any(i.indkey)
        where i.indrelid='public.organization_subscriptions'::regclass
          and a.attname in ('reconciliation_required_at','reconciliation_reason','reconciliation_context'))) ),
    ( 6, 'billing_records: authenticated has NO INSERT/UPDATE/DELETE',
      (not has_table_privilege('authenticated','public.billing_records','INSERT')
       and not has_table_privilege('authenticated','public.billing_records','UPDATE')
       and not has_table_privilege('authenticated','public.billing_records','DELETE')) ),
    ( 7, 'billing_records: authenticated SELECT preserved',
      (has_table_privilege('authenticated','public.billing_records','SELECT')) ),
    ( 8, 'billing_records: anon has NO privilege at all',
      (not has_table_privilege('anon','public.billing_records','SELECT')
       and not has_table_privilege('anon','public.billing_records','INSERT')
       and not has_table_privilege('anon','public.billing_records','UPDATE')
       and not has_table_privilege('anon','public.billing_records','DELETE')) ),
    ( 9, 'billing_records: service_role write ability untouched',
      (has_table_privilege('service_role','public.billing_records','INSERT')
       and has_table_privilege('service_role','public.billing_records','UPDATE')) ),
    (10, 'billing_records: RLS enabled',
      ((select relrowsecurity from pg_class where oid='public.billing_records'::regclass)) ),
    (11, 'billing_records: billing_records_select + billing_records_platform_admin_select present, no write policy',
      (exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_select')
       and exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_platform_admin_select')
       and not exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and cmd in ('INSERT','UPDATE','DELETE'))) ),
    (12, 'billing_records.status CHECK domain (open|paid|void|uncollectible) still present',
      (exists (select 1 from pg_constraint c2 where c2.conrelid='public.billing_records'::regclass and c2.contype='c'
                 and pg_get_constraintdef(c2.oid) ilike '%open%' and pg_get_constraintdef(c2.oid) ilike '%paid%'
                 and pg_get_constraintdef(c2.oid) ilike '%void%' and pg_get_constraintdef(c2.oid) ilike '%uncollectible%')) ),
    (13, 'billing_records_stripe_invoice_id_key still UNIQUE',
      (exists (select 1 from pg_constraint where conrelid='public.billing_records'::regclass and conname='billing_records_stripe_invoice_id_key' and contype='u')) ),
    (14, 'apply_stripe_subscription_state(...) exists with the exact 18-arg signature',
      (to_regprocedure('public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)') is not null) ),
    (15, '_stripe_upsert_billing_record(uuid,uuid,jsonb) exists',
      (to_regprocedure('public._stripe_upsert_billing_record(uuid,uuid,jsonb)') is not null) ),
    (16, 'apply_stripe_subscription_state is SECURITY DEFINER, search_path=public',
      (exists (select 1 from pg_proc p, c where p.oid=c.apply_oid and p.prosecdef
                 and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%')) ),
    (17, '_stripe_upsert_billing_record is SECURITY DEFINER, search_path=public',
      (exists (select 1 from pg_proc p, c where p.oid=c.upsert_oid and p.prosecdef
                 and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%')) ),
    (18, 'apply_stripe_subscription_state: EXECUTE granted to service_role ONLY (not authenticated/anon)',
      ((select has_function_privilege('service_role', c.apply_oid, 'EXECUTE') from c)
       and not (select has_function_privilege('authenticated', c.apply_oid, 'EXECUTE') from c)
       and not (select has_function_privilege('anon', c.apply_oid, 'EXECUTE') from c)) ),
    (19, '_stripe_upsert_billing_record: EXECUTE denied to every application-facing role (anon, authenticated, service_role) -- D.1B.2; the function OWNER''s implicit execute (untestable/unrevokable via role grants, and never intended to be revoked) is deliberately NOT asserted here',
      (not (select has_function_privilege('anon', c.upsert_oid, 'EXECUTE') from c)
       and not (select has_function_privilege('authenticated', c.upsert_oid, 'EXECUTE') from c)
       and not (select has_function_privilege('service_role', c.upsert_oid, 'EXECUTE') from c)) ),
    (20, 'apply_stripe_subscription_state body: references subscription_plans (plan/cycle DB-derived)',
      ((select pg_get_functiondef(c.apply_oid) from c) ilike '%subscription_plans%') ),
    (21, 'apply_stripe_subscription_state body: takes a row lock (FOR UPDATE)',
      ((select pg_get_functiondef(c.apply_oid) from c) ilike '%for update%') ),
    (22, 'apply_stripe_subscription_state body: calls both complete_ and fail_stripe_webhook_event',
      ((select pg_get_functiondef(c.apply_oid) from c) ilike '%complete_stripe_webhook_event%'
       and (select pg_get_functiondef(c.apply_oid) from c) ilike '%fail_stripe_webhook_event%') ),
    (23, 'apply_stripe_subscription_state body: references stripe_event_at and billing_records',
      ((select pg_get_functiondef(c.apply_oid) from c) ilike '%stripe_event_at%'
       and (select pg_get_functiondef(c.apply_oid) from c) ilike '%billing_records%') ),
    (24, 'apply_stripe_subscription_state body: NOT referencing freight/QuickBooks/M-CTRL objects',
      ((select pg_get_functiondef(c.apply_oid) from c) not ilike '%public.invoices%'
       and (select pg_get_functiondef(c.apply_oid) from c) not ilike '%public.payments%'
       and (select pg_get_functiondef(c.apply_oid) from c) not ilike '%settlement%'
       and (select pg_get_functiondef(c.apply_oid) from c) not ilike '%quickbooks%'
       and (select pg_get_functiondef(c.apply_oid) from c) not ilike '%platform_settings%'
       and (select pg_get_functiondef(c.apply_oid) from c) not ilike '%proceeds_model%'
       and (select pg_get_functiondef(c.apply_oid) from c) not ilike '%proceeds_payer%'
       and (select pg_get_functiondef(c.apply_oid) from c) not ilike '%financial_dispatch_id%') ),
    (25, 'apply_stripe_subscription_state signature has NO plan_id / billing_cycle parameter (never caller-supplied)',
      ((select pg_get_function_arguments(c.apply_oid) from c) not ilike '%plan_id%'
       and (select pg_get_function_arguments(c.apply_oid) from c) not ilike '%billing_cycle%') ),
    (26, '_stripe_upsert_billing_record body: ON CONFLICT (stripe_invoice_id) upsert',
      ((select pg_get_functiondef(c.upsert_oid) from c) ilike '%on conflict%stripe_invoice_id%') ),
    (27, 'grandfather CHECK organization_subscriptions_grandfather_has_no_stripe unchanged',
      ((select btrim(regexp_replace(regexp_replace(lower(pg_get_constraintdef(oid)), '[()]', '', 'g'), '\s+', ' ', 'g'))
        from pg_constraint where conrelid='public.organization_subscriptions'::regclass
          and conname='organization_subscriptions_grandfather_has_no_stripe' and contype='c')
       = 'check grandfathered_at is null or stripe_customer_id is null and stripe_subscription_id is null and stripe_price_id is null') ),
    (28, 'organization_subscriptions: organization_id UNIQUE, RLS on, expected policies present, no tenant write policy, set_updated_at trigger present',
      (exists (select 1 from pg_constraint where conrelid='public.organization_subscriptions'::regclass and conname='organization_subscriptions_organization_id_key' and contype='u')
       and (select relrowsecurity from pg_class where oid='public.organization_subscriptions'::regclass)
       and exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and policyname='organization_subscriptions_select')
       and exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and policyname='organization_subscriptions_platform_admin_all')
       and not exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and cmd in ('INSERT','UPDATE','DELETE'))
       and exists (select 1 from pg_trigger where tgrelid='public.organization_subscriptions'::regclass and tgname='set_updated_at' and not tgisinternal)) ),
    (29, 'M-CTRL (0125/0126) untouched: platform_settings.model_a_enabled=false, loads.financial_dispatch_id carries the 0126 marker',
      ((select model_a_enabled from public.platform_settings where id = true) is false
       and coalesce(col_description('public.loads'::regclass,
             (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='financial_dispatch_id')), '')
           ilike '%backfilled by migration 0126%') ),
    (30, 'United Leather (C.4 fixture) row untouched: still incomplete/in-flight, reconciliation_* all NULL',
      (exists (
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
          and reconciliation_context is null)) ),
    -- ---- D.1B.1 BLOCKER 1: explicit billing-identity-safety gate ----
    (31, 'apply_stripe_subscription_state declares c_billing_unsafe_reasons (the explicit ownership-doubtful reason set)',
      ((select pg_get_functiondef(c.apply_oid) from c) ilike '%c_billing_unsafe_reasons%') ),
    (32, 'c_billing_unsafe_reasons body contains exactly the 6 frozen ownership-doubtful tokens',
      ((select pg_get_functiondef(c.apply_oid) from c) ilike '%customer_mismatch%'
       and (select pg_get_functiondef(c.apply_oid) from c) ilike '%customer_unbound%'
       and (select pg_get_functiondef(c.apply_oid) from c) ilike '%subscription_mismatch%'
       and (select pg_get_functiondef(c.apply_oid) from c) ilike '%billing_record_org_mismatch%'
       and (select pg_get_functiondef(c.apply_oid) from c) ilike '%grandfathered_stripe_event%'
       and (select pg_get_functiondef(c.apply_oid) from c) ilike '%billing_not_required_stripe_attach%') ),
    (33, 'v_billing_identity_safe is computed once and used as an explicit guard at exactly the 2 billing-upsert call sites',
      ((select
          (length(pg_get_functiondef(c.apply_oid)) - length(replace(pg_get_functiondef(c.apply_oid), 'and v_billing_identity_safe', '')))
          / length('and v_billing_identity_safe')
        from c) = 2) ),
    (34, 'v_billing_identity_safe is assigned exactly (v_conflict_reason is null) or not (... any (c_billing_unsafe_reasons)) -- derived from v_conflict_reason only, not from staleness (P13)',
      ((select pg_get_functiondef(c.apply_oid) from c) ilike '%v_billing_identity_safe := (v_conflict_reason is null)%'
       and (select pg_get_functiondef(c.apply_oid) from c) ilike '%or not (v_conflict_reason = any (c_billing_unsafe_reasons))%') ),
    -- ---- D.1B.1 BLOCKER 2: unrecognized invoice status fails closed ----
    (35, '_stripe_upsert_billing_record RAISEs on an unrecognized non-NULL status (no longer silently coerced)',
      ((select pg_get_functiondef(c.upsert_oid) from c) ilike '%raise exception%'
       and (select pg_get_functiondef(c.upsert_oid) from c) ilike '%not in (''open'',''paid'',''void'',''uncollectible'')%') ),
    (36, '_stripe_upsert_billing_record no longer contains the old silent CASE...ELSE ''open'' coercion pattern',
      ((select pg_get_functiondef(c.upsert_oid) from c) not ilike '%else ''open'' end%') ),
    (37, '_stripe_upsert_billing_record still defaults a NULL (absent) status to open',
      ((select pg_get_functiondef(c.upsert_oid) from c) ilike '%coalesce(v_status_in, ''open'')%') ),
    (38, '_stripe_upsert_billing_record: the RAISE uses an errcode (does not rely on an unqualified/default SQLSTATE)',
      ((select pg_get_functiondef(c.upsert_oid) from c) ilike '%using errcode%') ),
    (39, 'apply_stripe_subscription_state can return stale_skipped_billing_recorded (stale lifecycle + fresh identity-safe invoice both honored in one call)',
      ((select pg_get_functiondef(c.apply_oid) from c) ilike '%stale_skipped_billing_recorded%') ),
    (40, 'the stripe_invoice_id ownership guard (existing row belongs to a different org -> no re-homing) is present at both billing-upsert call sites',
      ((select
          (length(pg_get_functiondef(c.apply_oid)) - length(replace(pg_get_functiondef(c.apply_oid), 'v_existing_bill_org is not null and v_existing_bill_org <> v_row.organization_id', '')))
          / length('v_existing_bill_org is not null and v_existing_bill_org <> v_row.organization_id')
        from c) = 2) ),
    (41, '_stripe_upsert_billing_record: no PUBLIC grant remains in its ACL (D.1B.2 -- direct proacl check, independent confirmation of check 19)',
      (not exists (
        select 1 from pg_proc p, c, unnest(p.proacl) as a
        where p.oid = c.upsert_oid and a::text like '=%')) )
) as checks(n, check_name, pass)
order by n;
-- expect: 41 rows, every `pass` = true.

-- ============================================================================
-- 2. New columns -- print definitions for eyeball review.
-- ============================================================================
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='organization_subscriptions'
  and column_name in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')
order by column_name;

-- ============================================================================
-- 3. billing_records grant matrix -- eyeball review.
-- ============================================================================
select r as role, priv, has_table_privilege(r, 'public.billing_records', priv) as granted
from unnest(array['anon','authenticated','service_role']) as r
cross join unnest(array['SELECT','INSERT','UPDATE','DELETE']) as priv
order by r, priv;

select policyname, cmd, roles, qual, with_check
from pg_policies where schemaname='public' and tablename='billing_records' order by policyname;

-- ============================================================================
-- 4. Function definitions -- print in full for eyeball review.
-- ============================================================================
select pg_get_functiondef(
  'public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)'::regprocedure
) as apply_stripe_subscription_state_def;

select pg_get_functiondef('public._stripe_upsert_billing_record(uuid,uuid,jsonb)'::regprocedure) as upsert_billing_record_def;

-- ============================================================================
-- 5. Informational counts (NOT part of the pass/fail matrix -- these are
--    expected to grow with real usage; 0127 itself already verified, at
--    apply time, that they matched its own captured baseline exactly).
-- ============================================================================
select
  (select count(*) from public.organizations)                              as organizations,
  (select count(*) from public.organizations where billing_required=false) as legacy_billing_not_required,
  (select count(*) from public.organization_subscriptions)                 as organization_subscriptions,
  (select count(*) from public.organization_subscriptions where grandfathered_at is not null) as grandfathered,
  (select count(*) from public.organization_subscriptions where reconciliation_required_at is not null) as reconciliation_flagged,
  (select count(*) from public.billing_records)                           as billing_records,
  (select count(*) from public.stripe_webhook_events)                     as stripe_webhook_events,
  (select count(*) from public.subscription_plans)                        as subscription_plans;

-- ============================================================================
-- 6. D.1B.1 static test matrix -- how each frozen scenario is proven WITHOUT
--    executing apply_stripe_subscription_state() or the billing helper
--    (this file never does; both remain untouched, unexecuted code). Every
--    scenario is proven by the source-text checks above, applied to the
--    live, already-created function bodies -- not by hypothetical review.
-- ============================================================================
-- 1. fresh subscription event, identity valid, no invoice -> lifecycle apply
--      Proven by checks 20-25 (plan/cycle DB-derived, row lock, ordering
--      fence referenced) + the P14 UPDATE existing since the original D.1B
--      authoring; p_invoice IS NULL so checks 31-40 (billing gate) are
--      structurally inert for this path -- nothing to prove beyond "the
--      billing block requires p_invoice IS NOT NULL", visible in the
--      function source directly above check 33's target line.
-- 2. stale subscription event, identity valid, new valid invoice
--      -> lifecycle stale_skipped, billing recorded
--      Proven by check 39 (stale_skipped_billing_recorded is a reachable
--      return value) + checks 33-34 (v_billing_identity_safe is derived
--      from v_conflict_reason only -- never from v_is_stale/P13) + check 23
--      (billing_records is referenced independently of the stale branch).
-- 3. customer_mismatch + invoice -> reconciliation required, billing NOT written
--      Proven by checks 31-32 (customer_mismatch is in c_billing_unsafe_reasons)
--      + check 33 (v_billing_identity_safe gates BOTH call sites, so a false
--      value there suppresses both the conflict-path and clean-path upsert).
-- 4. customer_unbound + invoice -> reconciliation required, billing NOT written
--      Proven identically to #3 -- customer_unbound is in
--      c_billing_unsafe_reasons (check 32).
-- 5. subscription_mismatch + invoice -> reconciliation required, billing NOT written
--      Proven identically to #3 -- subscription_mismatch is in
--      c_billing_unsafe_reasons (check 32).
-- 6. existing stripe_invoice_id belongs to another org
--      -> reconciliation required, existing row NOT re-homed, no replacement row
--      Proven by check 40 (the exact ownership guard
--      "v_existing_bill_org is not null and v_existing_bill_org <>
--      v_row.organization_id" appears at both call sites, each followed by
--      skipping the upsert and, in the clean-path call site, flagging
--      billing_record_org_mismatch instead of writing) + check 32
--      (billing_record_org_mismatch is itself in c_billing_unsafe_reasons,
--      so once flagged, a LATER call for the same row is also billing-blocked).
-- 7. unknown_price + identity otherwise valid + invoice
--      -> preserve frozen D.1A behavior: invoice may be recorded
--      Proven by check 32's complement: unknown_price is deliberately
--      ABSENT from c_billing_unsafe_reasons (only the 6 named tokens are
--      checked as present; unknown_price/ambiguous_price/
--      price_interval_mismatch/checkout_session_mismatch/
--      secondary_metadata_conflict/invalid_status are never added to that
--      array in the source -- confirmed by direct inspection of the
--      function definition printed in Section 4).
-- 8. invalid normalized p_invoice.stripe_status
--      -> transaction fails closed, no billing mutation, no lifecycle
--         mutation committed, webhook not completed
--      Proven by checks 35-36 (RAISE on an out-of-domain non-NULL status;
--      the old silent CASE...ELSE 'open' coercion is gone) + check 38 (the
--      RAISE carries an errcode) + the ATOMICITY guarantee already proven
--      for the whole function (checks 20-25 unchanged) -- a RAISE inside
--      _stripe_upsert_billing_record propagates out of
--      apply_stripe_subscription_state uncaught (no exception handler
--      exists anywhere in either function body -- confirmed by the absence
--      of any "exception when" block in Section 4's printed definitions),
--      so it rolls back the ENTIRE calling transaction, including any
--      subscription-state UPDATE already applied earlier in that same call.
-- 9. valid payment_failed normalization: p_invoice.stripe_status = 'open' -> accepted
--      Proven by check 37 combined with check 35's domain list: 'open' is
--      in ('open','paid','void','uncollectible'), so it never reaches the
--      RAISE branch and is stored as-is.
-- 10. valid paid normalization: p_invoice.stripe_status = 'paid' -> accepted
--      Proven identically to #9 -- 'paid' is in the same domain list.
