-- Run AFTER applying 0125_dispatch_proceeds_and_financial_controller.sql.
--
-- 100% READ-ONLY. SELECTs only -- no INSERT / UPDATE / DELETE / ALTER /
-- CREATE / DROP / TRUNCATE / mutation RPC, no BEGIN/ROLLBACK, no fixtures.
-- Safe on production.
--
-- Section 1 returns one row per named check with a boolean `pass`; every
-- `pass` must be true. Sections 2-4 print catalog detail for eyeball review.
-- Row-count deltas are verified by 0125's own PHASE 3 against its captured
-- baseline; this file verifies STRUCTURE, the RESOLVER contract, and the
-- "nothing classified / nothing controlled yet" invariants, which do not
-- depend on a hard-coded production count.

-- ============================================================================
-- 1. PASS/FAIL MATRIX -- every `pass` must be true (40 checks).
-- ============================================================================
with
col as (
  select table_name, column_name, data_type, udt_name, is_nullable, column_default
  from information_schema.columns
  where table_schema = 'public'
    and table_name in ('organizations','carriers','dispatches','loads','platform_settings')
)
select * from (
  values
    -- enums
    ( 1, 'enum public.proceeds_model exists with exact members',
      ((select string_agg(e.enumlabel, ',' order by e.enumsortorder)
        from pg_enum e join pg_type t on t.oid = e.enumtypid join pg_namespace n on n.oid = t.typnamespace
        where n.nspname='public' and t.typname='proceeds_model')
       = 'dispatcher_receives_funds,carrier_paid_directly') ),
    ( 2, 'enum public.proceeds_payer exists with exact members',
      ((select string_agg(e.enumlabel, ',' order by e.enumsortorder)
        from pg_enum e join pg_type t on t.oid = e.enumtypid join pg_namespace n on n.oid = t.typnamespace
        where n.nspname='public' and t.typname='proceeds_payer')
       = 'broker,factoring_company,shipper,dispatcher,other') ),
    -- platform_settings capability state
    ( 3, 'public.platform_settings table exists',
      (to_regclass('public.platform_settings') is not null) ),
    ( 4, 'platform_settings has exactly one row',
      ((select count(*) from public.platform_settings) = 1) ),
    ( 5, 'platform_settings.model_a_enabled IS FALSE',
      ((select model_a_enabled from public.platform_settings where id = true) is false) ),
    ( 6, 'platform_settings singleton CHECK present',
      (exists (select 1 from pg_constraint where conrelid='public.platform_settings'::regclass
                 and contype='c' and conname='platform_settings_singleton')) ),
    ( 7, 'RLS enabled on platform_settings',
      ((select relrowsecurity from pg_class where oid='public.platform_settings'::regclass)) ),
    ( 8, 'platform_settings has a SELECT policy and NO write policy',
      (exists (select 1 from pg_policies where schemaname='public' and tablename='platform_settings' and cmd='SELECT')
       and not exists (select 1 from pg_policies where schemaname='public' and tablename='platform_settings' and cmd in ('INSERT','UPDATE','DELETE','ALL'))) ),
    ( 9, 'platform_settings has a set_updated_at trigger',
      (exists (select 1 from pg_trigger where tgrelid='public.platform_settings'::regclass and tgname='set_updated_at' and not tgisinternal)) ),
    -- columns
    (10, 'organizations.load_proceeds_model = proceeds_model NOT NULL DEFAULT dispatcher_receives_funds',
      (exists (select 1 from col where table_name='organizations' and column_name='load_proceeds_model'
                 and udt_name='proceeds_model' and is_nullable='NO' and column_default like '%dispatcher_receives_funds%')) ),
    (11, 'carriers.load_proceeds_model = proceeds_model, nullable, no default',
      (exists (select 1 from col where table_name='carriers' and column_name='load_proceeds_model'
                 and udt_name='proceeds_model' and is_nullable='YES' and column_default is null)) ),
    (12, 'dispatches.proceeds_model = proceeds_model, nullable, no default',
      (exists (select 1 from col where table_name='dispatches' and column_name='proceeds_model'
                 and udt_name='proceeds_model' and is_nullable='YES' and column_default is null)) ),
    (13, 'dispatches.proceeds_payer = proceeds_payer, nullable, no default',
      (exists (select 1 from col where table_name='dispatches' and column_name='proceeds_payer'
                 and udt_name='proceeds_payer' and is_nullable='YES' and column_default is null)) ),
    (14, 'dispatches.proceeds_payer_note = text, nullable, no default',
      (exists (select 1 from col where table_name='dispatches' and column_name='proceeds_payer_note'
                 and data_type='text' and is_nullable='YES' and column_default is null)) ),
    (15, 'loads.financial_dispatch_id = uuid, nullable, no default',
      (exists (select 1 from col where table_name='loads' and column_name='financial_dispatch_id'
                 and data_type='uuid' and is_nullable='YES' and column_default is null)) ),
    -- FK + ON DELETE RESTRICT
    (16, 'loads.financial_dispatch_id FK -> dispatches(id) ON DELETE RESTRICT, on exactly that column',
      (exists (
        select 1 from pg_constraint c
        where c.conrelid='public.loads'::regclass and c.contype='f'
          and c.confrelid='public.dispatches'::regclass and c.confdeltype='r'
          and (select array_agg(a.attname order by k.ord)
               from unnest(c.conkey) with ordinality as k(attnum, ord)
               join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum)
              = array['financial_dispatch_id']::name[])) ),
    -- unique partial index
    (17, 'uq_loads_financial_dispatch_one_per_dispatch is a UNIQUE partial index on loads',
      (exists (select 1 from pg_index i join pg_class ic on ic.oid=i.indexrelid join pg_class tc on tc.oid=i.indrelid
                 where ic.relname='uq_loads_financial_dispatch_one_per_dispatch' and tc.relname='loads'
                   and i.indisunique and i.indpred is not null)) ),
    -- resolver
    (18, 'resolve_dispatch_proceeds_model(uuid) exists returning proceeds_model',
      (to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)') is not null
       and (select pg_get_function_result(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)'))) like '%proceeds_model') ),
    (19, 'resolver is STABLE, SECURITY DEFINER, search_path=public',
      (exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                 where n.nspname='public' and p.proname='resolve_dispatch_proceeds_model'
                   and p.provolatile='s' and p.prosecdef
                   and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%')) ),
    (20, 'resolver body reads ONLY dispatches.proceeds_model (no carriers/organizations/platform_settings/invoices/settlements refs)',
      ((select pg_get_functiondef(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)'))) ilike '%dispatches%'
       and (select pg_get_functiondef(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)'))) not ilike '%carriers%'
       and (select pg_get_functiondef(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)'))) not ilike '%organizations%'
       and (select pg_get_functiondef(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)'))) not ilike '%platform_settings%'
       and (select pg_get_functiondef(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)'))) not ilike '%invoices%'
       and (select pg_get_functiondef(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)'))) not ilike '%settlement%') ),
    (21, 'resolver: unstamped existing dispatch -> dispatcher_receives_funds',
      ( ((select count(*) from public.dispatches) = 0)
        or ((select public.resolve_dispatch_proceeds_model((select id from public.dispatches order by id limit 1)))
            = 'dispatcher_receives_funds'::public.proceeds_model) ) ),
    (22, 'resolver: missing dispatch id -> NULL',
      ((select public.resolve_dispatch_proceeds_model('00000000-0000-0000-0000-000000000000'::uuid)) is null) ),
    -- trigger functions
    (23, 'stamp_dispatch_proceeds_model() exists, security definer, search_path=public',
      (exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                 where n.nspname='public' and p.proname='stamp_dispatch_proceeds_model'
                   and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%')) ),
    (24, 'assign_load_financial_dispatch() exists, security definer, search_path=public',
      (exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                 where n.nspname='public' and p.proname='assign_load_financial_dispatch'
                   and p.prosecdef and array_to_string(coalesce(p.proconfig,'{}'::text[]),',') like '%search_path=public%')) ),
    (25, 'guard_load_financial_dispatch_ref() exists',
      (to_regprocedure('public.guard_load_financial_dispatch_ref()') is not null) ),
    (26, 'guard_org_load_proceeds_model() exists',
      (to_regprocedure('public.guard_org_load_proceeds_model()') is not null) ),
    (27, 'guard_carrier_load_proceeds_model() exists',
      (to_regprocedure('public.guard_carrier_load_proceeds_model()') is not null) ),
    -- BEFORE INSERT trigger does NOT touch loads.financial_dispatch_id
    (28, 'stamp_dispatch_proceeds_model() body does NOT reference loads.financial_dispatch_id',
      ((select pg_get_functiondef(to_regprocedure('public.stamp_dispatch_proceeds_model()'))) not ilike '%financial_dispatch_id%') ),
    -- BEFORE INSERT trigger DOES gate carrier_paid_directly
    (29, 'stamp_dispatch_proceeds_model() body references model_a_enabled and carrier_paid_directly and raises',
      ((select pg_get_functiondef(to_regprocedure('public.stamp_dispatch_proceeds_model()'))) ilike '%model_a_enabled%'
       and (select pg_get_functiondef(to_regprocedure('public.stamp_dispatch_proceeds_model()'))) ilike '%carrier_paid_directly%'
       and (select pg_get_functiondef(to_regprocedure('public.stamp_dispatch_proceeds_model()'))) ilike '%raise exception%') ),
    -- AFTER INSERT trigger locks loads FOR UPDATE and sets only when NULL
    (30, 'assign_load_financial_dispatch() body locks loads FOR UPDATE and sets only when financial_dispatch_id IS NULL',
      ((select pg_get_functiondef(to_regprocedure('public.assign_load_financial_dispatch()'))) ilike '%from public.loads where id = new.load_id%for update%'
       and (select pg_get_functiondef(to_regprocedure('public.assign_load_financial_dispatch()'))) ilike '%financial_dispatch_id is null%') ),
    -- triggers attached with correct timing/table
    (31, 'trigger dispatches_stamp_proceeds = BEFORE INSERT on public.dispatches',
      (exists (select 1 from pg_trigger where tgname='dispatches_stamp_proceeds' and tgrelid='public.dispatches'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT ON public.dispatches%')) ),
    (32, 'trigger dispatches_assign_financial_controller = AFTER INSERT on public.dispatches',
      (exists (select 1 from pg_trigger where tgname='dispatches_assign_financial_controller' and tgrelid='public.dispatches'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%AFTER INSERT ON public.dispatches%')) ),
    (33, 'trigger loads_financial_dispatch_ref_guard = BEFORE INSERT OR UPDATE on public.loads',
      (exists (select 1 from pg_trigger where tgname='loads_financial_dispatch_ref_guard' and tgrelid='public.loads'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE INSERT OR UPDATE ON public.loads%')) ),
    (34, 'trigger organizations_load_proceeds_model_guard = BEFORE UPDATE on public.organizations',
      (exists (select 1 from pg_trigger where tgname='organizations_load_proceeds_model_guard' and tgrelid='public.organizations'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE UPDATE ON public.organizations%')) ),
    (35, 'trigger carriers_load_proceeds_model_guard = BEFORE UPDATE on public.carriers',
      (exists (select 1 from pg_trigger where tgname='carriers_load_proceeds_model_guard' and tgrelid='public.carriers'::regclass
                 and not tgisinternal and pg_get_triggerdef(oid) ilike '%BEFORE UPDATE ON public.carriers%')) ),
    -- LEGACY invariants immediately after 0125
    (36, 'zero dispatch rows have a non-NULL proceeds_model / proceeds_payer / proceeds_payer_note',
      (not exists (select 1 from public.dispatches
                     where proceeds_model is not null or proceeds_payer is not null or proceeds_payer_note is not null)) ),
    (37, 'zero carrier rows have a non-NULL load_proceeds_model; every organization observes dispatcher_receives_funds',
      (not exists (select 1 from public.carriers where load_proceeds_model is not null)
       and not exists (select 1 from public.organizations where load_proceeds_model <> 'dispatcher_receives_funds')) ),
    (38, 'loads.financial_dispatch_id: 0 rows non-NULL, OR every non-NULL row is same-load + same-org (post-0125 dispatch), AND 0126 marker absent',
      ( ( (select count(*) from public.loads where financial_dispatch_id is not null) = 0
          or not exists (
               select 1 from public.loads l join public.dispatches d on d.id = l.financial_dispatch_id
               where l.financial_dispatch_id is not null and (d.load_id <> l.id or d.organization_id <> l.organization_id)) )
        and coalesce(col_description('public.loads'::regclass,
              (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='financial_dispatch_id')),'')
            not ilike '%backfilled by migration 0126%' ) ),
    -- protected objects untouched
    (39, '0124 landmark intact; auto-invoice trigger untouched; Stripe/QB tables present',
      (exists (select 1 from information_schema.columns where table_schema='public' and table_name='organization_subscriptions' and column_name='stripe_checkout_attempt_id')
       and exists (select 1 from pg_trigger where tgname='auto_generate_invoice_on_delivery' and tgrelid='public.loads'::regclass and not tgisinternal)
       and to_regclass('public.billing_records') is not null
       and to_regclass('public.subscription_plans') is not null
       and to_regclass('public.quickbooks_customer_mappings') is not null) ),
    (40, 'auto_generate_invoice_from_delivered_load() still sources rate from load_financials and was NOT changed to read financial_dispatch_id',
      ((select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) ilike '%load_financials%'
       and (select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) not ilike '%financial_dispatch_id%') )
) as checks(n, check_name, pass)
order by n;
-- expect: 40 rows, every `pass` = true.

-- ============================================================================
-- 2. New columns -- print definitions for eyeball review.
-- ============================================================================
select table_name, column_name, data_type, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and ( (table_name='organizations' and column_name='load_proceeds_model')
     or (table_name='carriers'      and column_name='load_proceeds_model')
     or (table_name='dispatches'    and column_name in ('proceeds_model','proceeds_payer','proceeds_payer_note'))
     or (table_name='loads'         and column_name='financial_dispatch_id') )
order by table_name, column_name;

-- ============================================================================
-- 3. platform_settings row + policies + FK/index detail.
-- ============================================================================
select id, model_a_enabled, created_at, updated_at from public.platform_settings;

select policyname, cmd, roles, qual, with_check
from pg_policies where schemaname='public' and tablename='platform_settings' order by policyname;

select c.conname, c.contype, c.confdeltype,
       pg_get_constraintdef(c.oid) as definition
from pg_constraint c
where c.conrelid = 'public.loads'::regclass and c.contype = 'f'
  and c.confrelid = 'public.dispatches'::regclass;

select indexname, indexdef from pg_indexes
where schemaname='public' and tablename='loads' and indexname='uq_loads_financial_dispatch_one_per_dispatch';

-- ============================================================================
-- 4. Trigger inventory on the five touched tables -- eyeball timing/order.
-- ============================================================================
select t.tgrelid::regclass::text as on_table, t.tgname,
       pg_get_triggerdef(t.oid) as definition
from pg_trigger t
where not t.tgisinternal
  and t.tgrelid in ('public.dispatches'::regclass,'public.loads'::regclass,
                    'public.organizations'::regclass,'public.carriers'::regclass,
                    'public.platform_settings'::regclass)
  and t.tgname in ('dispatches_stamp_proceeds','dispatches_assign_financial_controller',
                   'loads_financial_dispatch_ref_guard','organizations_load_proceeds_model_guard',
                   'carriers_load_proceeds_model_guard','set_updated_at')
order by on_table, t.tgname;

-- ============================================================================
-- 5. Resolver function -- print full definition.
-- ============================================================================
select pg_get_functiondef(to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)')) as resolver_def;
