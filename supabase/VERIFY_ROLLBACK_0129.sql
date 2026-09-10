-- ============================================================================
-- VERIFY_ROLLBACK_0129.sql  --  100% READ-ONLY. SELECT + catalog only.
-- No ALTER/CREATE/DROP/INSERT/UPDATE/DELETE/GRANT/REVOKE. No DO block. No
-- transaction control. Never executes any function. Safe on production.
--
-- Run AFTER supabase/ROLLBACK_0129_atomic_dispatch_lifecycle.sql.
-- Every row of the matrix must show ok = true.
--
-- NOT a migration -- lives outside supabase/migrations/ so no runner picks
-- it up.
-- ============================================================================
with
inv as (
  select lower(regexp_replace(pg_get_functiondef(
           'public.auto_generate_invoice_from_delivered_load()'::regprocedure), '\s+', ' ', 'g')) as def
),
gin as (
  select lower(regexp_replace(pg_get_functiondef(
           'public.generate_invoice_number(uuid)'::regprocedure), '\s+', ' ', 'g')) as def
),
-- 0054 partial unique indexes -- rendering-INDEPENDENT semantic view.
-- IDENTICAL logic to migration 0129 PHASE 1 and the other verifiers.
ix054 as (
  select
    ic.relname,
    i.indisunique,
    (i.indpred is not null) as is_partial,
    i.indnkeyatts           as nkeys,
    (select a.attname from pg_attribute a
       where a.attrelid = i.indrelid and a.attnum = i.indkey[0]) as key_col,
    regexp_replace(
      regexp_replace(lower(coalesce(pg_get_expr(i.indpred, i.indrelid), '')),
        '::[a-z_.]*dispatch_status', '', 'g'),
      '\s+', '', 'g') as pred_norm
  from pg_class ic
  join pg_index i on i.indexrelid = ic.oid
  where ic.relkind = 'i' and ic.relnamespace = 'public'::regnamespace
    and ic.relname in ('dispatches_active_driver_unique','dispatches_active_truck_unique','dispatches_active_trailer_unique')
),
ix054_ok as (
  select
    relname,
    (
          indisunique
      and is_partial
      and nkeys = 1
      and key_col = case relname
                      when 'dispatches_active_driver_unique'  then 'driver_id'
                      when 'dispatches_active_truck_unique'   then 'truck_id'
                      when 'dispatches_active_trailer_unique' then 'trailer_id'
                    end
      and (pred_norm like '%status=any(array[%' or pred_norm like '%statusin(%')
      and (select coalesce(array_agg(distinct m[1] order by m[1]), array[]::text[])
             from regexp_matches(pred_norm, '''([a-z_]+)''', 'g') as m)
          = array['accepted','assigned','at_delivery','at_pickup',
                  'en_route_to_delivery','en_route_to_pickup','loaded']::text[]
      and pred_norm not like '%''delivered''%'
      and pred_norm not like '%''completed''%'
      and pred_norm not like '%''cancelled''%'
      and (relname <> 'dispatches_active_trailer_unique' or pred_norm like '%trailer_idisnotnull%')
    ) as semantic_ok
  from ix054
)
select check_no, label, case when ok then 'PASS' else 'FAIL' end as result, ok
from inv, gin, lateral (values

  -- ---- the two 0129 dispatch RPCs are gone ----
  ( 1, 'create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text) no longer exists',
    to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is null),
  ( 2, 'cancel_dispatch(uuid,text) no longer exists',
    to_regprocedure('public.cancel_dispatch(uuid,text)') is null),
  ( 3, 'no function named create_dispatch / cancel_dispatch remains under ANY signature',
    not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                where n.nspname='public' and p.proname in ('create_dispatch','cancel_dispatch'))),

  -- ---- auto-invoice restored to the EXACT LIVE 0068 shape ----
  ( 4, 'auto_generate_invoice_from_delivered_load() carries the 0068 `select id ... limit 1` selection again',
    inv.def like '%select id into v_dispatch_id from public.dispatches where load_id = new.id limit 1%'),
  ( 5, 'auto-invoice no longer references financial_dispatch_id',
    inv.def not like '%financial_dispatch_id%'),
  ( 6, 'auto-invoice no longer has the 0129 order-by / non-cancelled fallback',
    inv.def not like '%order by d.dispatched_at desc nulls last%'
    and (length(inv.def) - length(replace(inv.def, 'd.status <> ''cancelled''', ''))) = 0),
  ( 7, 'auto-invoice 0068 invariants intact (NO new.rate, amount from load_financials, terms from broker_financials, on conflict (load_id), SECURITY DEFINER)',
    inv.def not like '%new.rate%'
    and inv.def like '%from public.load_financials where load_id = new.id%'
    and inv.def like '%public.broker_financials%'
    and inv.def like '%on conflict (load_id)%'
    and exists (select 1 from pg_proc p where p.oid='public.auto_generate_invoice_from_delivered_load()'::regprocedure and p.prosecdef)),
  ( 8, 'auto-invoice trigger auto_generate_invoice_on_delivery still bound to public.loads',
    exists (select 1 from pg_trigger where tgrelid='public.loads'::regclass and tgname='auto_generate_invoice_on_delivery' and not tgisinternal)),

  -- ---- protected objects untouched by the rollback ----
  ( 9, '0054: all three partial unique indexes present AND semantically valid (UNIQUE + partial + right key column + exactly the 7 frozen active statuses, no terminal; trailer index NULL-guarded) -- rendering-independent, same rule as 0129 PHASE 1',
    (select count(*) from ix054_ok where semantic_ok) = 3
    and (select count(*) from ix054_ok) = 3),
  (10, 'guard_dispatch_org (0055) + dispatches_assign_financial_controller (0125) triggers still attached',
    exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_guard_org' and not tgisinternal)
    and exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_assign_financial_controller' and not tgisinternal)),
  (11, '0125 columns/objects intact (loads.financial_dispatch_id, dispatches.proceeds_model, resolve_dispatch_proceeds_model)',
    exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id')
    and exists (select 1 from information_schema.columns where table_schema='public' and table_name='dispatches' and column_name='proceeds_model')
    and to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)') is not null),

  -- ---- the invoice-number split is fully unwound ----
  (12, 'public._generate_invoice_number_internal(uuid) no longer exists',
    to_regprocedure('public._generate_invoice_number_internal(uuid)') is null),
  (13, 'public.generate_invoice_number(uuid) restored to the 0065 body: owner/admin/accountant guard + inline counter upsert, NO helper delegation, NO tenant check, SECURITY DEFINER, authenticated has EXECUTE',
    gin.def like '%has_role(array[''owner'', ''admin'', ''accountant'']::public.org_role[])%'
    and gin.def like '%insert into public.invoice_number_counters%'
    and gin.def not like '%_generate_invoice_number_internal%'
    and gin.def not like '%current_org_id%'
    and exists (select 1 from pg_proc p where p.oid='public.generate_invoice_number(uuid)'::regprocedure and p.prosecdef)
    and has_function_privilege('authenticated','public.generate_invoice_number(uuid)'::regprocedure,'EXECUTE')),
  (14, 'auto-invoice mints via the role-guarded public.generate_invoice_number(NEW.organization_id) again, not the (dropped) helper',
    inv.def like '%public.generate_invoice_number(new.organization_id)%'
    and inv.def not like '%_generate_invoice_number_internal%')

) as t(check_no, label, ok);

-- Eyeball: the restored selection statement + the restored invoice-number call.
select 'auto_generate_invoice_from_delivered_load() -- restored dispatch selection' as note,
       (regexp_match(pg_get_functiondef('public.auto_generate_invoice_from_delivered_load()'::regprocedure),
        '(select id into v_dispatch_id[^;]*;)'))[1] as restored_selection;

select 'public.generate_invoice_number(uuid) body (restored 0065)' as note,
       pg_get_functiondef('public.generate_invoice_number(uuid)'::regprocedure) as def;
