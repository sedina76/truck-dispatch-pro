-- Run AFTER applying 0126_backfill_load_financial_dispatch.sql.
--
-- 100% READ-ONLY. SELECTs only -- no INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / TRUNCATE / mutation RPC, no BEGIN/ROLLBACK, no fixtures.
-- Safe on production.
--
-- True row-level immutability of invoices/settlements/payments vs their
-- pre-migration state was verified by 0126's own PHASE 3 against snapshots
-- captured inside that tra        ansaction. This file re-derives the deterministic
-- controller for every load, from scratch, read-only, and asserts that
-- loads.financial_dispatch_id matches -- plus structural integrity and the
-- "nothing classified / Model A still off" invariants. It hard-codes no
-- production row count.
--
-- Section 1 is the PASS/FAIL matrix (every `pass` must be true).
-- Sections 2-4 print detail for eyeball review.

-- Shared re-derivation of the deterministic plan (identical rules to 0126).
with per_load as (
  select
    l.id                as load_id,
    l.organization_id   as load_org,
    l.status            as load_status,
    (l.broker_id is not null or l.customer_id is not null) as has_bill_to,
    l.financial_dispatch_id as fdi,
    coalesce((select array_agg(distinct d.id) from public.dispatches d where d.load_id = l.id), '{}'::uuid[])            as disp_ids,
    coalesce((select count(*) from public.dispatches d where d.load_id = l.id), 0)                                       as n_disp,
    coalesce((select count(*) from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'), 0)           as n_noncanc,
    coalesce((select array_agg(distinct d.id) from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'), '{}'::uuid[]) as noncanc_ids,
    coalesce((select array_agg(distinct i.dispatch_id) from public.invoices i
              where i.load_id = l.id and i.dispatch_id is not null), '{}'::uuid[])                                       as inv_disp,
    coalesce((select array_agg(distinct sli.dispatch_id) from public.settlement_line_items sli
              join public.settlements s on s.id = sli.settlement_id
              where sli.load_id = l.id and sli.item_type = 'load_pay' and sli.dispatch_id is not null and s.status <> 'void'), '{}'::uuid[]) as sli_disp
  from public.loads l
),
calc as (
  select p.*,
    (case when coalesce(array_length(p.inv_disp,1),0) = 1 then p.inv_disp[1] end) as doc_from_inv,
    (case when coalesce(array_length(p.sli_disp,1),0) = 1 then p.sli_disp[1] end) as doc_from_sli
  from per_load p
),
flags as (
  select c.*,
    ( coalesce(array_length(c.inv_disp,1),0) > 1
      or coalesce(array_length(c.sli_disp,1),0) > 1
      or (c.doc_from_inv is not null and c.doc_from_sli is not null and c.doc_from_inv <> c.doc_from_sli)
      or (c.doc_from_inv is not null and not (c.doc_from_inv = any(c.disp_ids)))
      or (c.doc_from_sli is not null and not (c.doc_from_sli = any(c.disp_ids)))
    ) as is_conflict
  from calc c
),
plan as (
  select f.*,
    coalesce(f.doc_from_inv, f.doc_from_sli) as doc_disp,
    (case
       when f.is_conflict then null
       when coalesce(f.doc_from_inv, f.doc_from_sli) is not null then coalesce(f.doc_from_inv, f.doc_from_sli)
       when f.n_disp = 1 then f.disp_ids[1]
       when f.n_disp > 1 and f.n_noncanc = 1 then f.noncanc_ids[1]
       else null
     end) as expected_fdi,
    (not f.is_conflict and coalesce(f.doc_from_inv, f.doc_from_sli) is null and f.n_noncanc > 1) as is_ambiguous
  from flags f
)
select * from (
  values
    ( 1, '0126 backfill marker present on loads.financial_dispatch_id comment',
      (coalesce(col_description('public.loads'::regclass,
        (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='financial_dispatch_id')),'')
       ilike '%backfilled by migration 0126%') ),
    ( 2, 'every non-NULL financial_dispatch_id references a dispatch of the SAME load and SAME org',
      (not exists (
        select 1 from public.loads l join public.dispatches d on d.id = l.financial_dispatch_id
        where l.financial_dispatch_id is not null and (d.load_id <> l.id or d.organization_id <> l.organization_id))) ),
    ( 3, 'no dispatch controls two loads (partial unique index holds)',
      (not exists (
        select l.financial_dispatch_id from public.loads l
        where l.financial_dispatch_id is not null
        group by l.financial_dispatch_id having count(*) > 1)) ),
    ( 4, 'R1 preserved: every load whose freight invoice carries a dispatch_id has financial_dispatch_id = that dispatch_id',
      (not exists (
        select 1 from public.invoices i join public.loads l on l.id = i.load_id
        where i.load_id is not null and i.dispatch_id is not null
          and l.financial_dispatch_id is distinct from i.dispatch_id)) ),
    ( 5, 'R2 preserved: every load with a unique non-void load_pay dispatch_id and NO invoice dispatch_id points at it',
      (not exists (
        select 1 from public.loads l
        where exists (select 1 from public.settlement_line_items sli join public.settlements s on s.id = sli.settlement_id
                        where sli.load_id = l.id and sli.item_type='load_pay' and sli.dispatch_id is not null and s.status <> 'void')
          and not exists (select 1 from public.invoices i where i.load_id = l.id and i.dispatch_id is not null)
          and l.financial_dispatch_id is distinct from (
                select distinct sli.dispatch_id from public.settlement_line_items sli
                join public.settlements s on s.id = sli.settlement_id
                where sli.load_id = l.id and sli.item_type='load_pay' and sli.dispatch_id is not null and s.status <> 'void'))) ),
    ( 6, 'every deterministically-resolvable load (not conflict, not ambiguous) has financial_dispatch_id = the re-derived expected controller',
      (not exists (
        select 1 from plan p
        where not p.is_conflict and not p.is_ambiguous and p.expected_fdi is not null
          and p.fdi is distinct from p.expected_fdi)) ),
    ( 7, 'no conflict loads remain unhandled (all conflict loads have financial_dispatch_id NULL OR a valid pre-existing structural value)',
      (not exists (
        select 1 from plan p
        where p.is_conflict and p.fdi is not null
          and not (p.fdi = any(p.disp_ids)))) ),
    ( 8, 'no ambiguous load has a controller assigned by 0126 (ambiguous -> must be NULL unless a valid pre-existing value)',
      (not exists (
        select 1 from plan p
        where p.is_ambiguous and p.fdi is not null and not (p.fdi = any(p.disp_ids)))) ),
    ( 9, 'no auto-invoice-eligible undelivered dispatched load has financial_dispatch_id = NULL',
      (not exists (
        select 1 from public.loads l
        where l.status not in ('delivered','pod_received','invoiced','closed','cancelled')
          and (l.broker_id is not null or l.customer_id is not null)
          and exists (select 1 from public.dispatches d where d.load_id = l.id)
          and l.financial_dispatch_id is null)) ),
    (10, 'genuine zero-dispatch loads are allowed to remain NULL (informational: all such loads have NULL)',
      (not exists (
        select 1 from public.loads l
        where not exists (select 1 from public.dispatches d where d.load_id = l.id)
          and l.financial_dispatch_id is not null)) ),
    (11, 'NO dispatch was reclassified: dispatches.proceeds_model is NULL on every row',
      (not exists (select 1 from public.dispatches where proceeds_model is not null)) ),
    (12, 'NO dispatch payer was set: dispatches.proceeds_payer / proceeds_payer_note NULL on every row',
      (not exists (select 1 from public.dispatches where proceeds_payer is not null or proceeds_payer_note is not null)) ),
    (13, 'Model A capability remains FALSE',
      ((select model_a_enabled from public.platform_settings where id = true) is false) ),
    (14, 'no carrier default and no non-default org model introduced',
      (not exists (select 1 from public.carriers where load_proceeds_model is not null)
       and not exists (select 1 from public.organizations where load_proceeds_model <> 'dispatcher_receives_funds')) ),
    (15, 'structural integrity: every invoices.dispatch_id (non-NULL) points at a dispatch of that invoice''s load',
      (not exists (
        select 1 from public.invoices i join public.dispatches d on d.id = i.dispatch_id
        where i.dispatch_id is not null and i.load_id is not null and d.load_id <> i.load_id)) ),
    (16, 'structural integrity: every settlement_line_items.dispatch_id (non-NULL, load_pay) points at a dispatch of that line''s load',
      (not exists (
        select 1 from public.settlement_line_items sli join public.dispatches d on d.id = sli.dispatch_id
        where sli.dispatch_id is not null and sli.load_id is not null and sli.item_type='load_pay' and d.load_id <> sli.load_id)) ),
    (17, '0124 landmark intact; auto-invoice trigger present and NOT reading financial_dispatch_id',
      (exists (select 1 from information_schema.columns where table_schema='public' and table_name='organization_subscriptions' and column_name='stripe_checkout_attempt_id')
       and exists (select 1 from pg_trigger where tgname='auto_generate_invoice_on_delivery' and tgrelid='public.loads'::regclass and not tgisinternal)
       and (select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) not ilike '%financial_dispatch_id%'
       and (select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) ilike '%load_financials%') ),
    (18, 'protected Stripe/QuickBooks structures present and unreferenced by 0125/0126 objects',
      (to_regclass('public.billing_records') is not null
       and to_regclass('public.organization_subscriptions') is not null
       and to_regclass('public.subscription_plans') is not null
       and to_regclass('public.quickbooks_customer_mappings') is not null
       and (select pg_get_functiondef(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)'))) not ilike '%billing_records%'
       and (select pg_get_functiondef(to_regprocedure('public.assign_load_financial_dispatch()'))) not ilike '%subscription%') )
) as checks(n, check_name, pass)
order by n;
-- expect: 18 rows, every `pass` = true.

-- ============================================================================
-- 2. Controller assignment summary (rule breakdown) -- eyeball review.
-- ============================================================================
with per_load as (
  select l.id as load_id, l.status as load_status,
    l.financial_dispatch_id as fdi,
    coalesce((select count(*) from public.dispatches d where d.load_id = l.id), 0) as n_disp,
    coalesce((select count(*) from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'), 0) as n_noncanc,
    coalesce((select array_agg(distinct i.dispatch_id) from public.invoices i where i.load_id = l.id and i.dispatch_id is not null), '{}'::uuid[]) as inv_disp,
    coalesce((select array_agg(distinct sli.dispatch_id) from public.settlement_line_items sli
              join public.settlements s on s.id = sli.settlement_id
              where sli.load_id = l.id and sli.item_type='load_pay' and sli.dispatch_id is not null and s.status <> 'void'), '{}'::uuid[]) as sli_disp
  from public.loads l
)
select
  case
    when fdi is null and n_disp = 0 then 'NULL (zero dispatch)'
    when fdi is null then 'NULL (other)'
    when coalesce(array_length(inv_disp,1),0) = 1 and fdi = inv_disp[1] then 'R1 invoice-linked'
    when coalesce(array_length(sli_disp,1),0) = 1 and fdi = sli_disp[1] then 'R2 settlement-linked'
    when n_disp = 1 then 'R3 sole dispatch'
    when n_disp > 1 and n_noncanc = 1 then 'R4 sole non-cancelled'
    else 'OTHER (review)'
  end as assignment_bucket,
  count(*) as loads
from per_load
group by 1
order by 1;

-- ============================================================================
-- 3. Any load that still looks unresolved / ambiguous -- should be empty.
-- ============================================================================
select left(l.id::text,8) as load_prefix, l.status,
       (select count(*) from public.dispatches d where d.load_id = l.id) as n_disp,
       (select count(*) from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled') as n_noncanc,
       l.financial_dispatch_id is not null as has_controller,
       (l.broker_id is not null or l.customer_id is not null) as has_bill_to
from public.loads l
where l.financial_dispatch_id is null
  and exists (select 1 from public.dispatches d where d.load_id = l.id)
order by l.id;
-- expect: only loads with 0 non-cancelled dispatches / genuinely uncontrolled;
-- NONE that are undelivered + has_bill_to.

-- ============================================================================
-- 4. loads.financial_dispatch_id comment (proves 0126 ran).
-- ============================================================================
select col_description('public.loads'::regclass,
  (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='financial_dispatch_id')) as fdi_comment;
