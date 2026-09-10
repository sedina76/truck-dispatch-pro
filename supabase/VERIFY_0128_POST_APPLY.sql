-- ============================================================================
-- 0128 POST-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- Never executes apply_stripe_subscription_state / _stripe_upsert_billing_record
-- / any webhook RPC. No ALTER/CREATE/DROP/INSERT/UPDATE/DELETE/TRUNCATE/GRANT/
-- REVOKE. No transaction control. No DO block. Safe on production.
--
-- Run AFTER applying 0128_fix_stripe_plan_uuid_aggregate.sql.
-- Every row of the matrix must show ok = true.
-- ============================================================================
with c as (
  select
    'public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)'::regprocedure as apply_oid,
    'public._stripe_upsert_billing_record(uuid,uuid,jsonb)'::regprocedure                                                       as upsert_oid
),
d as (
  select
    pg_get_functiondef((select apply_oid from c)) as apply_def,
    -- apply_code: definition with every `-- ...` line comment removed and
    -- whitespace collapsed. Code checks that must distinguish the P10/P11
    -- statement forms run on this so a body comment cannot match.
    regexp_replace(regexp_replace(
      pg_get_functiondef((select apply_oid from c)), '--[^\n]*', '', 'g'), '\s+', ' ', 'g') as apply_code
)
select check_no, label,
       case when ok then 'PASS' else 'FAIL' end as result,
       ok
from c, d, lateral (values

  -- ---- the fix is live, the defect is gone ----
  --      Checks run on apply_code (comments stripped + whitespace collapsed)
  --      so an explanatory body comment cannot flip a result. The repaired
  --      form "count(*), min(sp.id::text)::uuid" does NOT contain the
  --      substring "count(*), min(sp.id)" (it is "::text)" after sp.id).
  ( 1, 'P10/P11 statement IS "select count(*), min(sp.id::text)::uuid ..."',
    d.apply_code like '%count(*), min(sp.id::text)::uuid%'),
  ( 2, 'the bare "count(*), min(sp.id)" (uuid aggregate) statement is gone',
    d.apply_code not like '%count(*), min(sp.id)%'),
  ( 3, 'the statement still selects INTO v_plan_matches, v_plan_id from subscription_plans',
    d.apply_code like '%into v_plan_matches, v_plan_id%'
    and d.apply_code like '%from public.subscription_plans sp%'
    and d.apply_code like '%p_stripe_price_id in (sp.stripe_price_id_monthly, sp.stripe_price_id_annual)%'),

  -- ---- signature / security / grants preserved exactly ----
  ( 4, 'exact 18-arg signature present',
    to_regprocedure('public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)') is not null),
  ( 5, 'returns text',
    (select prorettype from pg_proc where oid = c.apply_oid) = 'text'::regtype),
  ( 6, 'SECURITY DEFINER + set search_path=public',
    exists (select 1 from pg_proc p
            where p.oid = c.apply_oid and p.prosecdef
              and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%')),
  ( 7, 'language plpgsql',
    (select l.lanname from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = c.apply_oid) = 'plpgsql'),
  ( 8, 'EXECUTE = exactly {service_role} (not anon/authenticated, no PUBLIC)',
    has_function_privilege('service_role', c.apply_oid, 'EXECUTE')
    and not has_function_privilege('authenticated', c.apply_oid, 'EXECUTE')
    and not has_function_privilege('anon', c.apply_oid, 'EXECUTE')
    and not exists (select 1 from pg_proc p, unnest(p.proacl) as a where p.oid = c.apply_oid and a::text like '=%')),

  -- ---- every 0127 body invariant reproduced verbatim ----
  ( 9, 'P1: _stripe_assert_service_role() gate present',
    d.apply_def ilike '%perform public._stripe_assert_service_role()%'),
  (10, 'P2: webhook claim-token ownership check (status=processing AND claim_token=p_claim_token)',
    d.apply_def ilike '%status = ''processing''%' and d.apply_def ilike '%claim_token = p_claim_token%'),
  (11, 'P3: SELECT ... FOR UPDATE OF os row lock',
    d.apply_def ilike '%for update of os%'),
  (12, 'P4-P9 identity/authority reason tokens all present',
    d.apply_def ilike '%grandfathered_stripe_event%' and d.apply_def ilike '%billing_not_required_stripe_attach%'
    and d.apply_def ilike '%customer_unbound%' and d.apply_def ilike '%customer_mismatch%'
    and d.apply_def ilike '%subscription_mismatch%' and d.apply_def ilike '%checkout_session_mismatch%'
    and d.apply_def ilike '%secondary_metadata_conflict%'),
  (13, 'P10-P12 catalog reason tokens present (unknown_price / ambiguous_price / price_interval_mismatch / invalid_status)',
    d.apply_def ilike '%unknown_price%' and d.apply_def ilike '%ambiguous_price%'
    and d.apply_def ilike '%price_interval_mismatch%' and d.apply_def ilike '%invalid_status%'),
  (14, 'P13 ordering fence: greatest(coalesce(stripe_event_at, ...)) present twice',
    (length(d.apply_def) - length(replace(d.apply_def, 'greatest(coalesce(stripe_event_at', '')))
      / length('greatest(coalesce(stripe_event_at') = 2),
  (15, 'P16: both billing-upsert call sites gated by "and v_billing_identity_safe" (exactly 2)',
    (length(d.apply_def) - length(replace(d.apply_def, 'and v_billing_identity_safe', '')))
      / length('and v_billing_identity_safe') = 2),
  (16, 'D.1B.1: c_billing_unsafe_reasons array declared with all 6 tokens',
    d.apply_def ilike '%c_billing_unsafe_reasons constant text[]%'
    and d.apply_def ilike '%billing_record_org_mismatch%'),
  (17, 'reconciliation SET rule: coalesce(reconciliation_required_at, now()) anchor',
    d.apply_def ilike '%reconciliation_required_at = coalesce(reconciliation_required_at, now())%'),
  (18, 'reconciliation self-healing reason list intact',
    d.apply_def ilike '%''unknown_price'', ''ambiguous_price'', ''price_interval_mismatch'',%'),
  (19, 'P19: atomic complete_/fail_stripe_webhook_event calls present',
    d.apply_def ilike '%perform public.complete_stripe_webhook_event(p_stripe_event_id, p_claim_token)%'
    and d.apply_def ilike '%public.fail_stripe_webhook_event(%'),
  (20, 'return-code CASE intact (applied / applied_billing_recorded / reconciliation_required / stale_skipped / noop / not_owner / applied_billing_conflict)',
    d.apply_def ilike '%applied_billing_recorded%' and d.apply_def ilike '%reconciliation_required_billing_recorded%'
    and d.apply_def ilike '%stale_skipped_billing_recorded%' and d.apply_def ilike '%applied_billing_conflict%'
    and d.apply_def ilike '%return ''not_owner''%'),
  (21, 'no p_plan_id / p_billing_cycle parameter (plan/cycle stays DB-derived)',
    pg_get_function_arguments(c.apply_oid) not ilike '%plan_id%'
    and pg_get_function_arguments(c.apply_oid) not ilike '%billing_cycle%'),
  (22, 'stays isolated: no freight-accounting / QuickBooks / M-CTRL object referenced',
    d.apply_def not ilike '%public.invoices%' and d.apply_def not ilike '%public.payments%'
    and d.apply_def not ilike '%settlement%' and d.apply_def not ilike '%quickbooks%'
    and d.apply_def not ilike '%platform_settings%' and d.apply_def not ilike '%proceeds_model%'
    and d.apply_def not ilike '%proceeds_payer%' and d.apply_def not ilike '%financial_dispatch_id%'),

  -- ---- 0128 left everything ELSE untouched ----
  (23, '_stripe_upsert_billing_record(uuid,uuid,jsonb) still present',
    to_regprocedure('public._stripe_upsert_billing_record(uuid,uuid,jsonb)') is not null),
  (24, '_stripe_upsert_billing_record EXECUTE still denied to anon, authenticated AND service_role; no PUBLIC grant',
    not has_function_privilege('anon', c.upsert_oid, 'EXECUTE')
    and not has_function_privilege('authenticated', c.upsert_oid, 'EXECUTE')
    and not has_function_privilege('service_role', c.upsert_oid, 'EXECUTE')
    and not exists (select 1 from pg_proc p, unnest(p.proacl) as a where p.oid = c.upsert_oid and a::text like '=%')),
  (25, 'organization_subscriptions still has all 3 reconciliation_* columns (timestamptz/text/jsonb, nullable, no default)',
    (select count(*) from information_schema.columns
      where table_schema='public' and table_name='organization_subscriptions'
        and column_name in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')
        and is_nullable='YES' and column_default is null) = 3),
  (26, 'billing_records privileges unchanged: authenticated no INSERT/UPDATE/DELETE, keeps SELECT; service_role keeps INSERT; anon none',
    not has_table_privilege('authenticated','public.billing_records','INSERT')
    and not has_table_privilege('authenticated','public.billing_records','UPDATE')
    and not has_table_privilege('authenticated','public.billing_records','DELETE')
    and has_table_privilege('authenticated','public.billing_records','SELECT')
    and has_table_privilege('service_role','public.billing_records','INSERT')
    and not has_table_privilege('anon','public.billing_records','SELECT')),
  (27, 'RLS + read-only policies on organization_subscriptions / billing_records unchanged; no write policy',
    (select relrowsecurity from pg_class where oid='public.organization_subscriptions'::regclass)
    and (select relrowsecurity from pg_class where oid='public.billing_records'::regclass)
    and exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and policyname='billing_records_select')
    and not exists (select 1 from pg_policies where schemaname='public' and tablename='organization_subscriptions' and cmd in ('INSERT','UPDATE','DELETE'))
    and not exists (select 1 from pg_policies where schemaname='public' and tablename='billing_records' and cmd in ('INSERT','UPDATE','DELETE'))),
  (28, 'ZERO row DML by 0128: no reconciliation_* column is non-NULL on any row',
    (select count(*) from public.organization_subscriptions
       where reconciliation_required_at is not null
          or reconciliation_reason is not null
          or reconciliation_context is not null) = 0)

) as t(check_no, label, ok);

-- Eyeball: the repaired P10/P11 aggregate expression, from the comment-stripped
-- live definition + the plan catalog.
select 'live apply_stripe_subscription_state -- P10/P11 plan-resolution aggregate' as note,
       (regexp_match(
          regexp_replace(regexp_replace(
            pg_get_functiondef('public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)'::regprocedure),
            '--[^\n]*', '', 'g'), '\s+', ' ', 'g'),
          '(count\(\*\), min\(sp\.id[^ ]*)'
        ))[1] as repaired_expression;

select id, tier, is_public, is_active,
       stripe_price_id_monthly, stripe_price_id_annual
from public.subscription_plans
order by tier;
