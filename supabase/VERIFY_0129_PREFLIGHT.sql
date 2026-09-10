-- ============================================================================
-- 0129 PRE-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No ALTER/CREATE/DROP/INSERT/UPDATE/DELETE/TRUNCATE/GRANT/REVOKE. No DO
-- block. No transaction control. Never executes any RPC. Safe on production.
--
-- Run BEFORE applying 0129_atomic_dispatch_lifecycle.sql.
-- Every row of the matrix must show ok = true.
-- ============================================================================
with
inv as (
  select regexp_replace(lower(pg_get_functiondef(
           'public.auto_generate_invoice_from_delivered_load()'::regprocedure)), '\s+', ' ', 'g') as def
),
gin as (
  select regexp_replace(lower(pg_get_functiondef(
           'public.generate_invoice_number(uuid)'::regprocedure)), '\s+', ' ', 'g') as def
),
-- 0054 partial unique indexes -- rendering-INDEPENDENT semantic view.
-- IDENTICAL logic to migration 0129 PHASE 1 (and POST_APPLY / ROLLBACK
-- verifiers): pg_get_expr always reconstructs `x IN (a,b,c)` as
-- `x = ANY (ARRAY[a::dispatch_status, ...])`, so we normalize (lowercase,
-- drop ::dispatch_status casts, drop whitespace) and compare the SET of
-- status literals + catalog facts, not the raw text.
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
    pred_norm,
    (select coalesce(array_agg(distinct m[1] order by m[1]), array[]::text[])
       from regexp_matches(pred_norm, '''([a-z_]+)''', 'g') as m) as status_set,
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
),
-- static self-test rows: feed the EXACT production-rendered predicate
-- (and a tampered copy) through the same normalizer + rule.
ix054_regress as (
  select
    regexp_replace(regexp_replace(lower(src),
      '::[a-z_.]*dispatch_status', '', 'g'), '\s+', '', 'g') as p,
    tag
  from (values
    ('(status = ANY (ARRAY[''assigned''::dispatch_status, ''accepted''::dispatch_status, ''en_route_to_pickup''::dispatch_status, ''at_pickup''::dispatch_status, ''loaded''::dispatch_status, ''en_route_to_delivery''::dispatch_status, ''at_delivery''::dispatch_status]))', 'prod_exact'),
    ('(status = ANY (ARRAY[''assigned''::dispatch_status, ''accepted''::dispatch_status, ''en_route_to_pickup''::dispatch_status, ''at_pickup''::dispatch_status, ''loaded''::dispatch_status, ''en_route_to_delivery''::dispatch_status, ''at_delivery''::dispatch_status, ''delivered''::dispatch_status]))', 'tampered_extra_terminal')
  ) as s(src, tag)
),
ix054_regress_eval as (
  select
    tag, p,
    ( p like '%status=any(array[%'
      and (select coalesce(array_agg(distinct m[1] order by m[1]), array[]::text[])
             from regexp_matches(p, '''([a-z_]+)''', 'g') as m)
          = array['accepted','assigned','at_delivery','at_pickup',
                  'en_route_to_delivery','en_route_to_pickup','loaded']::text[]
      and p not like '%''delivered''%'
      and p not like '%''completed''%'
      and p not like '%''cancelled''%'
    ) as accepts
  from ix054_regress
)
select check_no, label, case when ok then 'PASS' else 'FAIL' end as result, ok
from (values

  -- ---- objects 0129 CREATES must be ABSENT ----
  ( 1, 'public.create_dispatch(...) does NOT exist yet',
    to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is null),
  ( 2, 'public.cancel_dispatch(...) does NOT exist yet',
    to_regprocedure('public.cancel_dispatch(uuid,text)') is null),

  -- ---- required existing tables / helpers ----
  ( 3, 'loads, dispatches, dispatch_financials, dispatch_internal_notes, invoices, invoice_line_items all present',
    to_regclass('public.loads') is not null and to_regclass('public.dispatches') is not null
    and to_regclass('public.dispatch_financials') is not null and to_regclass('public.dispatch_internal_notes') is not null
    and to_regclass('public.invoices') is not null and to_regclass('public.invoice_line_items') is not null),
  ( 4, 'has_role(org_role[]) / current_org_id() / log_activity(5-arg) / generate_invoice_number(uuid) all present',
    to_regprocedure('public.has_role(public.org_role[])') is not null
    and to_regprocedure('public.current_org_id()') is not null
    and to_regprocedure('public.log_activity(public.entity_type,uuid,text,jsonb,uuid)') is not null
    and to_regprocedure('public.generate_invoice_number(uuid)') is not null),

  -- ---- dispatch_status enum: exact 10 labels ----
  ( 5, 'public.dispatch_status enum = the expected 10-value set',
    (select array_agg(e.enumlabel::text order by e.enumlabel)
     from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
     where n.nspname='public' and t.typname='dispatch_status')
    = array['accepted','assigned','at_delivery','at_pickup','cancelled','completed','delivered','en_route_to_delivery','en_route_to_pickup','loaded']::text[]),

  -- ---- 0054 partial unique indexes -- semantic (rendering-independent) ----
  ( 6, '0054 dispatches_active_driver_unique: UNIQUE + partial + keys driver_id + predicate = exactly the 7 frozen active statuses (no terminal), rendering-independent',
    (select semantic_ok from ix054_ok where relname='dispatches_active_driver_unique')),
  ( 7, '0054 dispatches_active_truck_unique: UNIQUE + partial + keys truck_id + predicate = exactly the 7 frozen active statuses (no terminal)',
    (select semantic_ok from ix054_ok where relname='dispatches_active_truck_unique')),
  ( 8, '0054 dispatches_active_trailer_unique: UNIQUE + partial + keys trailer_id + `trailer_id is not null` guard + predicate = exactly the 7 frozen active statuses (no terminal)',
    (select semantic_ok from ix054_ok where relname='dispatches_active_trailer_unique')),
  ( 9, '0054: all three partial unique indexes present AND semantically valid (count = 3)',
    (select count(*) from ix054_ok where semantic_ok) = 3
    and (select count(*) from ix054_ok) = 3),
  (10, '0054 regression (positive): the EXACT production-rendered predicate `status = ANY (ARRAY[..::dispatch_status])` is accepted by the semantic rule',
    (select accepts from ix054_regress_eval where tag='prod_exact')),
  (11, '0054 regression (negative): a predicate with an extra terminal status (delivered) is REJECTED by the semantic rule',
    (select not accepts from ix054_regress_eval where tag='tampered_extra_terminal')),

  -- ---- triggers create_dispatch / cancel_dispatch rely on ----
  (12, 'trigger dispatches_guard_org (BEFORE INSERT OR UPDATE on public.dispatches, 0055) is attached',
    exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_guard_org'
              and not tgisinternal and pg_get_triggerdef(oid) ilike '%before insert or update on public.dispatches%')),
  (13, 'trigger dispatches_stamp_proceeds (0125, BEFORE INSERT) is attached',
    exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_stamp_proceeds' and not tgisinternal)),
  (14, 'trigger dispatches_assign_financial_controller (0125, AFTER INSERT) is attached',
    exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_assign_financial_controller' and not tgisinternal)),

  -- ---- auto-invoice: trigger bound, function still the LIVE 0068 shape ----
  (15, 'trigger auto_generate_invoice_on_delivery (0022) on public.loads is attached',
    exists (select 1 from pg_trigger where tgrelid='public.loads'::regclass and tgname='auto_generate_invoice_on_delivery' and not tgisinternal)),
  (16, 'auto_generate_invoice_from_delivered_load() still carries the vulnerable `select id ... limit 1` dispatch selection this migration replaces',
    (select def from inv) like '%select id into v_dispatch_id from public.dispatches where load_id = new.id limit 1%'),
  (17, 'auto_generate_invoice_from_delivered_load() does NOT already reference financial_dispatch_id (0129 not applied / equivalent)',
    (select def from inv) not like '%financial_dispatch_id%'),
  (18, 'auto_generate_invoice_from_delivered_load() is the LIVE 0068 form: reads load_financials / broker_financials / customer_financials, has NO NEW.rate, keeps `on conflict (load_id)`',
    (select def from inv) like '%from public.load_financials where load_id = new.id%'
    and (select def from inv) like '%public.broker_financials%'
    and (select def from inv) like '%public.customer_financials%'
    and (select def from inv) not like '%new.rate%'
    and (select def from inv) like '%on conflict (load_id)%'),
  (19, 'auto_generate_invoice_from_delivered_load() is SECURITY DEFINER (behavior to preserve)',
    exists (select 1 from pg_proc p where p.oid='public.auto_generate_invoice_from_delivered_load()'::regprocedure and p.prosecdef)),

  -- ---- the NULL-linked-invoice fallback depends on this ----
  (20, 'invoices.dispatch_id is NULLABLE',
    not exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='invoices' and column_name='dispatch_id' and is_nullable='NO')),
  (21, 'invoices has the one-invoice-per-load unique index (invoices_load_id_unique_idx, 0022)',
    exists (select 1 from pg_class where relname='invoices_load_id_unique_idx' and relkind='i' and relnamespace='public'::regnamespace)),

  -- ---- dispatches has the columns the new functions write ----
  (22, 'dispatches has cancelled_at (0057) and notes (0004)',
    exists (select 1 from information_schema.columns where table_schema='public' and table_name='dispatches' and column_name='cancelled_at')
    and exists (select 1 from information_schema.columns where table_schema='public' and table_name='dispatches' and column_name='notes')),
  (23, 'loads.financial_dispatch_id (0125) present -- the safe auto-invoice selection prefers it',
    exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id')),

  -- ---- invoice-number split: pre-migration state ----
  (24, 'public._generate_invoice_number_internal(uuid) does NOT exist yet',
    to_regprocedure('public._generate_invoice_number_internal(uuid)') is null),
  (25, 'public.generate_invoice_number(uuid) is still the 0065 body: owner/admin/accountant guard + inline counter upsert, NOT delegating to a helper',
    (select def from gin) like '%has_role(array[''owner'', ''admin'', ''accountant'']::public.org_role[])%'
    and (select def from gin) like '%insert into public.invoice_number_counters%'
    and (select def from gin) not like '%_generate_invoice_number_internal%'),
  (26, 'public.generate_invoice_number(uuid) is SECURITY DEFINER and authenticated has EXECUTE (privileges to preserve)',
    exists (select 1 from pg_proc p where p.oid='public.generate_invoice_number(uuid)'::regprocedure and p.prosecdef)
    and has_function_privilege('authenticated','public.generate_invoice_number(uuid)'::regprocedure,'EXECUTE')),
  (27, 'auto_generate_invoice_from_delivered_load() still calls the role-guarded public.generate_invoice_number(NEW.organization_id) (pre-migration state)',
    (select def from inv) like '%public.generate_invoice_number(new.organization_id)%'),

  -- ---- explicit "production is still pre-0129" proof (the aborted apply left nothing) ----
  (28, 'PRE-0129 STATE: all three 0129-created objects absent AND both replaced functions still at their pre-0129 bodies (a partial apply is impossible / did not happen)',
    to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is null
    and to_regprocedure('public.cancel_dispatch(uuid,text)') is null
    and to_regprocedure('public._generate_invoice_number_internal(uuid)') is null
    and (select def from inv) like '%public.generate_invoice_number(new.organization_id)%'
    and (select def from inv) not like '%_generate_invoice_number_internal%'
    and (select def from inv) not like '%financial_dispatch_id%'
    and (select def from gin) like '%insert into public.invoice_number_counters%'
    and (select def from gin) not like '%_generate_invoice_number_internal%'
    and (select def from gin) not like '%current_org_id%')

) as t(check_no, label, ok)
order by check_no;

-- Eyeball: the exact vulnerable line 0129 replaces.
select 'auto_generate_invoice_from_delivered_load() -- current dispatch selection' as note,
       (regexp_match(pg_get_functiondef('public.auto_generate_invoice_from_delivered_load()'::regprocedure),
        '(select id into v_dispatch_id[^;]*;)'))[1] as current_selection;
