-- ============================================================================
-- 0128 PRE-APPLY PREFLIGHT  --  100% READ-ONLY. SELECT + catalog introspection.
-- Never calls apply_stripe_subscription_state / _stripe_upsert_billing_record
-- / any claim/complete/fail webhook RPC. No ALTER/CREATE/DROP/INSERT/UPDATE/
-- DELETE/TRUNCATE/GRANT/REVOKE. No transaction control. No DO block.
--
-- Run BEFORE applying 0128_fix_stripe_plan_uuid_aggregate.sql.
-- Every row of the matrix must show ok = true to proceed.
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
    -- whitespace collapsed, so a body comment that spells out an expression
    -- can never satisfy a code check. "count(*), min(" occurs ONLY in the
    -- P10/P11 plan-resolution statement.
    regexp_replace(regexp_replace(
      pg_get_functiondef((select apply_oid from c)), '--[^\n]*', '', 'g'), '\s+', ' ', 'g') as apply_code
)
select check_no, label,
       case when ok then 'PASS' else 'FAIL -- STOP' end as result,
       ok
from c, d, lateral (values

  -- ---- 0127 must ALREADY be applied (0128 only repairs its function) ----
  ( 1, '0127 applied: apply_stripe_subscription_state(18-arg) exists',
    to_regprocedure('public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)') is not null),
  ( 2, '0127 applied: _stripe_upsert_billing_record(uuid,uuid,jsonb) exists',
    to_regprocedure('public._stripe_upsert_billing_record(uuid,uuid,jsonb)') is not null),
  ( 3, '0127 applied: organization_subscriptions has all 3 reconciliation_* columns',
    (select count(*) from information_schema.columns
      where table_schema='public' and table_name='organization_subscriptions'
        and column_name in ('reconciliation_required_at','reconciliation_reason','reconciliation_context')) = 3),
  ( 4, '0127 applied: billing_records hardened (authenticated has NO INSERT)',
    not has_table_privilege('authenticated','public.billing_records','INSERT')),

  -- ---- the live function currently carries the defect (repair is needed) ----
  --      Checks run on apply_code (comments stripped) so a body comment
  --      mentioning either expression cannot flip the result.
  ( 5, 'live P10/P11 statement IS "select count(*), min(sp.id) ..." (the uuid-aggregate defect)',
    d.apply_code like '%count(*), min(sp.id)%'),
  ( 6, 'live P10/P11 statement is NOT yet "count(*), min(sp.id::text)::uuid" (fix not applied)',
    d.apply_code not like '%count(*), min(sp.id::text)::uuid%'),

  -- ---- posture 0128 must preserve exactly ----
  ( 7, 'live apply is SECURITY DEFINER + search_path=public',
    exists (select 1 from pg_proc p
            where p.oid = c.apply_oid and p.prosecdef
              and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%')),
  ( 8, 'live apply EXECUTE = exactly {service_role} (not anon/authenticated)',
    has_function_privilege('service_role', c.apply_oid, 'EXECUTE')
    and not has_function_privilege('authenticated', c.apply_oid, 'EXECUTE')
    and not has_function_privilege('anon', c.apply_oid, 'EXECUTE')),
  ( 9, 'live apply returns text',
    (select prorettype from pg_proc where oid = c.apply_oid) = 'text'::regtype),
  (10, 'live _stripe_upsert_billing_record EXECUTE denied to anon, authenticated AND service_role (D.1B.2)',
    not has_function_privilege('anon', c.upsert_oid, 'EXECUTE')
    and not has_function_privilege('authenticated', c.upsert_oid, 'EXECUTE')
    and not has_function_privilege('service_role', c.upsert_oid, 'EXECUTE')),

  -- ---- dependencies the repaired function needs at run time ----
  (11, '0119: _stripe_assert_service_role() / claim / complete / fail RPCs all exist',
    to_regprocedure('public._stripe_assert_service_role()') is not null
    and to_regprocedure('public.claim_stripe_webhook_event(text,text,text,jsonb,timestamptz,interval)') is not null
    and to_regprocedure('public.complete_stripe_webhook_event(text,uuid)') is not null
    and to_regprocedure('public.fail_stripe_webhook_event(text,uuid,text)') is not null),
  (12, '0122: exactly 2 public+active subscription_plans (the query being repaired reads this)',
    (select count(*) from public.subscription_plans where is_public and is_active) = 2),
  (13, 'subscription_plans.id is type uuid (the column min() chokes on)',
    (select data_type from information_schema.columns
      where table_schema='public' and table_name='subscription_plans' and column_name='id') = 'uuid'),
  (14, 'no min(uuid) aggregate exists in this database (root-cause confirmation)',
    not exists (
      select 1 from pg_proc p
      join pg_aggregate a on a.aggfnoid = p.oid
      where p.proname = 'min' and p.proargtypes::text = 'uuid'::regtype::oid::text))

) as t(check_no, label, ok);

-- Eyeball: the exact P10/P11 aggregate expression, from the comment-stripped
-- live definition (so an explanatory body comment is not what is shown).
select 'live apply_stripe_subscription_state -- P10/P11 plan-resolution aggregate' as note,
       (regexp_match(
          regexp_replace(regexp_replace(
            pg_get_functiondef('public.apply_stripe_subscription_state(text,uuid,uuid,text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,boolean,timestamptz,timestamptz,text,jsonb)'::regprocedure),
            '--[^\n]*', '', 'g'), '\s+', ' ', 'g'),
          '(count\(\*\), min\(sp\.id[^ ]*)'
        ))[1] as offending_expression;
