-- ============================================================================
-- 0129 POST-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- Never executes create_dispatch / cancel_dispatch / the auto-invoice
-- function. No ALTER/CREATE/DROP/INSERT/UPDATE/DELETE/TRUNCATE/GRANT/REVOKE.
-- No DO block. No transaction control. Safe on production.
--
-- Run AFTER applying 0129_atomic_dispatch_lifecycle.sql.
-- Every row of the matrix must show ok = true.
-- ============================================================================
with
c as (
  select
    'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure as create_oid,
    'public.cancel_dispatch(uuid,text)'::regprocedure                             as cancel_oid,
    'public.auto_generate_invoice_from_delivered_load()'::regprocedure            as inv_oid,
    'public.generate_invoice_number(uuid)'::regprocedure                          as gin_oid,
    'public._generate_invoice_number_internal(uuid)'::regprocedure                as gin_i_oid
),
d as (
  select
    lower(regexp_replace(pg_get_functiondef((select create_oid from c)), '\s+', ' ', 'g')) as create_def,
    lower(regexp_replace(pg_get_functiondef((select cancel_oid from c)), '\s+', ' ', 'g')) as cancel_def,
    lower(regexp_replace(pg_get_functiondef((select inv_oid    from c)), '\s+', ' ', 'g')) as inv_def,
    lower(regexp_replace(pg_get_functiondef((select gin_oid    from c)), '\s+', ' ', 'g')) as gin_def,
    lower(regexp_replace(pg_get_functiondef((select gin_i_oid  from c)), '\s+', ' ', 'g')) as gin_i_def
),
-- 0054 partial unique indexes -- rendering-INDEPENDENT semantic view.
-- IDENTICAL logic to migration 0129 PHASE 1 / PHASE 3 and the other
-- verifiers (normalize predicate; compare the SET of status literals +
-- catalog facts, never the raw `IN (...)` vs `= ANY (ARRAY[...])` text).
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
ix054_regress_eval as (
  select
    tag,
    ( p like '%status=any(array[%'
      and (select coalesce(array_agg(distinct m[1] order by m[1]), array[]::text[])
             from regexp_matches(p, '''([a-z_]+)''', 'g') as m)
          = array['accepted','assigned','at_delivery','at_pickup',
                  'en_route_to_delivery','en_route_to_pickup','loaded']::text[]
      and p not like '%''delivered''%' and p not like '%''completed''%' and p not like '%''cancelled''%'
    ) as accepts
  from (
    select tag,
      regexp_replace(regexp_replace(lower(src), '::[a-z_.]*dispatch_status', '', 'g'), '\s+', '', 'g') as p
    from (values
      ('prod_exact', '(status = ANY (ARRAY[''assigned''::dispatch_status, ''accepted''::dispatch_status, ''en_route_to_pickup''::dispatch_status, ''at_pickup''::dispatch_status, ''loaded''::dispatch_status, ''en_route_to_delivery''::dispatch_status, ''at_delivery''::dispatch_status]))'),
      ('tampered_extra_terminal', '(status = ANY (ARRAY[''assigned''::dispatch_status, ''accepted''::dispatch_status, ''en_route_to_pickup''::dispatch_status, ''at_pickup''::dispatch_status, ''loaded''::dispatch_status, ''en_route_to_delivery''::dispatch_status, ''at_delivery''::dispatch_status, ''completed''::dispatch_status]))')
    ) as s(tag, src)
  ) q
)
select check_no, label, case when ok then 'PASS' else 'FAIL' end as result, ok
from c, d, lateral (values

  -- ---- existence + exact signatures ----
  ( 1, 'create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text) exists',
    to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is not null),
  ( 2, 'cancel_dispatch(uuid,text) exists',
    to_regprocedure('public.cancel_dispatch(uuid,text)') is not null),
  ( 3, 'create_dispatch returns uuid; cancel_dispatch returns void',
    (select prorettype from pg_proc where oid = c.create_oid) = 'uuid'::regtype
    and (select prorettype from pg_proc where oid = c.cancel_oid) = 'void'::regtype),
  ( 4, 'both new functions are language plpgsql',
    (select count(*) from pg_proc p join pg_language l on l.oid=p.prolang
      where p.oid in (c.create_oid, c.cancel_oid) and l.lanname='plpgsql') = 2),

  -- ---- security model: INVOKER (NOT definer), fixed search_path ----
  ( 5, 'create_dispatch is SECURITY INVOKER (not definer)',
    not exists (select 1 from pg_proc p where p.oid = c.create_oid and p.prosecdef)),
  ( 6, 'cancel_dispatch is SECURITY INVOKER (not definer)',
    not exists (select 1 from pg_proc p where p.oid = c.cancel_oid and p.prosecdef)),
  ( 7, 'both new functions set search_path = public',
    (select count(*) from pg_proc p where p.oid in (c.create_oid, c.cancel_oid)
      and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%') = 2),
  ( 8, 'neither new function signature mentions organization (org id comes from the load, never a param)',
    lower(pg_get_function_arguments(c.create_oid)) not like '%organization%'
    and lower(pg_get_function_arguments(c.cancel_oid)) not like '%organization%'),

  -- ---- privileges: authenticated ONLY ----
  ( 9, 'create_dispatch EXECUTE: authenticated yes; anon/service_role no; no PUBLIC acl entry',
    has_function_privilege('authenticated', c.create_oid, 'EXECUTE')
    and not has_function_privilege('anon', c.create_oid, 'EXECUTE')
    and not has_function_privilege('service_role', c.create_oid, 'EXECUTE')
    and not exists (select 1 from pg_proc p, unnest(p.proacl) as a where p.oid = c.create_oid and a::text like '=%')),
  (10, 'cancel_dispatch EXECUTE: authenticated yes; anon/service_role no; no PUBLIC acl entry',
    has_function_privilege('authenticated', c.cancel_oid, 'EXECUTE')
    and not has_function_privilege('anon', c.cancel_oid, 'EXECUTE')
    and not has_function_privilege('service_role', c.cancel_oid, 'EXECUTE')
    and not exists (select 1 from pg_proc p, unnest(p.proacl) as a where p.oid = c.cancel_oid and a::text like '=%')),

  -- ---- create_dispatch body invariants ----
  (11, 'create_dispatch: unauthenticated gate (auth.uid() is null -> raise)',
    d.create_def like '%auth.uid() is null%'),
  (12, 'create_dispatch: role gate = owner/admin/dispatcher',
    d.create_def like '%public.has_role(array[''owner'',''admin'',''dispatcher'']::public.org_role[])%'),
  (13, 'create_dispatch: locks the load FOR UPDATE and derives org from that row',
    d.create_def like '%from public.loads l%for update%'
    and d.create_def like '%into v_org, v_load_status%'),
  (14, 'create_dispatch: dispatchable-status gate (draft/posted/booked only)',
    d.create_def like '%v_load_status not in (''draft'',''posted'',''booked'')%'),
  (15, 'create_dispatch: one-active-dispatch-per-load check with a row lock',
    d.create_def like '%where d.load_id = p_load_id and d.status = any(c_active)%for update%'),
  (16, 'create_dispatch: all 5 writes present (dispatch / financials / notes / load-status / activity)',
    d.create_def like '%into public.dispatches %'
    and d.create_def like '%into public.dispatch_financials %'
    and d.create_def like '%into public.dispatch_internal_notes %'
    and d.create_def like '%update public.loads set status = ''dispatched''%'
    and d.create_def like '%log_activity(%'),
  (17, 'create_dispatch: 0054 race backstop handled (exception when unique_violation)',
    d.create_def like '%exception%when unique_violation then%'),
  (18, 'create_dispatch: driver/truck/trailer active-conflict checks present',
    d.create_def like '%d.driver_id = p_driver_id and d.status = any(c_active)%'
    and d.create_def like '%d.truck_id = p_truck_id and d.status = any(c_active)%'
    and d.create_def like '%d.trailer_id = p_trailer_id and d.status = any(c_active)%'),

  -- ---- cancel_dispatch body invariants ----
  (19, 'cancel_dispatch: auth + role gate (owner/admin/dispatcher)',
    d.cancel_def like '%auth.uid() is null%'
    and d.cancel_def like '%public.has_role(array[''owner'',''admin'',''dispatcher'']::public.org_role[])%'),
  (20, 'cancel_dispatch: idempotent no-op when already cancelled',
    d.cancel_def like '%if v_status = ''cancelled'' then return%'),
  (21, 'cancel_dispatch: refuses delivered/completed',
    d.cancel_def like '%v_status in (''delivered'',''completed'')%'),
  (22, 'cancel_dispatch: locks load then dispatch FOR UPDATE (deadlock-safe order)',
    d.cancel_def like '%from public.loads where id = v_load_id for update%'
    and d.cancel_def like '%from public.dispatches d where d.id = p_dispatch_id for update%'),
  (23, 'cancel_dispatch: returns load to booked only when NO other active dispatch, and never regresses a terminal load',
    d.cancel_def like '%status not in (''delivered'',''pod_received'',''invoiced'',''closed'',''cancelled'')%'
    and d.cancel_def like '%d.id <> p_dispatch_id and d.status = any(c_active)%'),
  (24, 'cancel_dispatch: does NOT write financial_dispatch_id (history preserved) -- matches an actual assignment, not the body comment that mentions it',
    d.cancel_def !~ 'financial_dispatch_id\s*='),
  (25, 'cancel_dispatch: sets cancelled_at and appends the reason to notes',
    d.cancel_def like '%cancelled_at = coalesce(cancelled_at, now())%'
    and d.cancel_def like '%[cancelled%'),

  -- ---- auto-invoice: safe selection in, vulnerable line out, 0028 rest intact ----
  (26, 'auto_generate_invoice_from_delivered_load(): the vulnerable 0028 `select id ... limit 1` line is GONE',
    d.inv_def not like '%select id into v_dispatch_id from public.dispatches where load_id = new.id limit 1%'),
  (27, 'auto-invoice: prefers NEW.financial_dispatch_id when same-load + not cancelled',
    d.inv_def like '%v_dispatch_id := new.financial_dispatch_id%'
    and d.inv_def like '%d.id = v_dispatch_id and d.load_id = new.id and d.status <> ''cancelled''%'),
  (28, 'auto-invoice: fallback is the newest NON-CANCELLED dispatch, deterministic order',
    d.inv_def like '%where d.load_id = new.id and d.status <> ''cancelled''%'
    and d.inv_def like '%order by d.dispatched_at desc nulls last, d.created_at desc, d.id desc%'),
  (29, 'auto-invoice: never selects a cancelled dispatch (no branch omits the <> ''cancelled'' filter)',
    (length(d.inv_def) - length(replace(d.inv_def, 'd.status <> ''cancelled''', ''))) / length('d.status <> ''cancelled''') = 2),
  (30, 'auto-invoice: LIVE 0068 invariants preserved (amount from load_financials, terms from broker_financials/customer_financials, NO NEW.rate, on conflict (load_id), SECURITY DEFINER, still trigger-bound)',
    d.inv_def like '%from public.load_financials where load_id = new.id%'
    and d.inv_def like '%public.broker_financials%'
    and d.inv_def like '%public.customer_financials%'
    and d.inv_def not like '%new.rate%'
    and d.inv_def like '%on conflict (load_id)%'
    and exists (select 1 from pg_proc p where p.oid = c.inv_oid and p.prosecdef)
    and exists (select 1 from pg_trigger where tgrelid='public.loads'::regclass and tgname='auto_generate_invoice_on_delivery' and not tgisinternal)),

  -- ---- protected objects untouched -- 0054 re-validated SEMANTICALLY ----
  (31, '0054: all three partial unique indexes present AND semantically valid (UNIQUE + partial + right key column + exactly the 7 frozen active statuses, no terminal; trailer index NULL-guarded) -- rendering-independent',
    (select count(*) from ix054_ok where semantic_ok) = 3
    and (select count(*) from ix054_ok) = 3),
  (32, '0054 regression (positive): the EXACT production-rendered predicate `status = ANY (ARRAY[..::dispatch_status])` is accepted by the semantic rule',
    (select accepts from ix054_regress_eval where tag='prod_exact')),
  (33, '0054 regression (negative): a predicate with an extra terminal status (completed) is REJECTED by the semantic rule',
    (select not accepts from ix054_regress_eval where tag='tampered_extra_terminal')),
  (34, 'guard_dispatch_org (0055) + dispatches_assign_financial_controller (0125) triggers still attached',
    exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_guard_org' and not tgisinternal)
    and exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_assign_financial_controller' and not tgisinternal)),
  (35, 'sync_load_status_from_dispatch (0028) trigger dispatches_sync_load_status still attached',
    exists (select 1 from pg_trigger where tgrelid='public.dispatches'::regclass and tgname='dispatches_sync_load_status' and not tgisinternal)),

  -- ---- invoice-number split: private mechanism + guarded public entry ----
  (36, 'auto-invoice mints via public._generate_invoice_number_internal(NEW.organization_id), NOT the role-guarded public.generate_invoice_number()',
    d.inv_def like '%public._generate_invoice_number_internal(new.organization_id)%'
    and d.inv_def not like '%public.generate_invoice_number(%'),
  (37, '_generate_invoice_number_internal(uuid) exists, language plpgsql, returns text',
    to_regprocedure('public._generate_invoice_number_internal(uuid)') is not null
    and (select prorettype from pg_proc where oid = c.gin_i_oid) = 'text'::regtype
    and exists (select 1 from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = c.gin_i_oid and l.lanname = 'plpgsql')),
  (38, '_generate_invoice_number_internal is SECURITY DEFINER, set search_path = public, and mechanism-only (no has_role / current_org_id)',
    exists (select 1 from pg_proc p where p.oid = c.gin_i_oid and p.prosecdef
            and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%')
    and d.gin_i_def not like '%has_role%'
    and d.gin_i_def not like '%current_org_id%'),
  (39, '_generate_invoice_number_internal: NO EXECUTE for anon / authenticated / service_role, and no PUBLIC acl entry',
    not has_function_privilege('anon',          c.gin_i_oid, 'EXECUTE')
    and not has_function_privilege('authenticated', c.gin_i_oid, 'EXECUTE')
    and not has_function_privilege('service_role',  c.gin_i_oid, 'EXECUTE')
    and not exists (select 1 from pg_proc p, unnest(p.proacl) as a where p.oid = c.gin_i_oid and a::text like '=%')),
  (40, '_generate_invoice_number_internal keeps the atomic per-org/year counter upsert and INV-YYYY-NNNNN format',
    d.gin_i_def like '%on conflict (organization_id, year) do update set last_number = invoice_number_counters.last_number + 1%'
    and d.gin_i_def like '%''inv-'' || v_year || ''-'' || lpad(v_number::text, 5, ''0'')%'),
  (41, 'public.generate_invoice_number(uuid): keeps owner/admin/accountant guard, ADDS tenant-ownership check, delegates to the helper, still SECURITY DEFINER, authenticated keeps EXECUTE',
    d.gin_def like '%has_role(array[''owner'', ''admin'', ''accountant'']::public.org_role[])%'
    and d.gin_def like '%current_org_id()%'
    and d.gin_def like '%p_organization_id <> v_caller_org%'
    and d.gin_def like '%public._generate_invoice_number_internal(p_organization_id)%'
    and exists (select 1 from pg_proc p where p.oid = c.gin_oid and p.prosecdef)
    and has_function_privilege('authenticated', c.gin_oid, 'EXECUTE')),
  (42, 'public.generate_invoice_number(uuid): the raw counter upsert is GONE from it (mechanism now lives only in the helper)',
    d.gin_def not like '%insert into public.invoice_number_counters%')

) as t(check_no, label, ok);

-- Eyeball: the new dispatch-selection block + the two function comments.
select 'auto_generate_invoice_from_delivered_load() -- new dispatch selection' as note,
       (regexp_match(pg_get_functiondef('public.auto_generate_invoice_from_delivered_load()'::regprocedure),
        '(v_dispatch_id := NEW\.financial_dispatch_id;[\s\S]*?limit 1;)'))[1] as new_selection;

select p.proname, obj_description(p.oid, 'pg_proc') as comment
from pg_proc p
where p.oid in (
  'public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'::regprocedure,
  'public.cancel_dispatch(uuid,text)'::regprocedure)
order by p.proname;

-- Eyeball: the invoice-number split -- the guarded public entry point and
-- the private mechanism, plus their EXECUTE grantees.
select 'public.generate_invoice_number(uuid) body' as note,
       pg_get_functiondef('public.generate_invoice_number(uuid)'::regprocedure) as def;

select 'public._generate_invoice_number_internal(uuid) grantees' as note,
       coalesce(nullif(array_to_string(p.proacl::text[], ' | '), ''), '(no ACL rows -- owner-only)') as acl
from pg_proc p
where p.oid = 'public._generate_invoice_number_internal(uuid)'::regprocedure;
