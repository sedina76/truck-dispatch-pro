-- =============================================================================
-- VERIFY_0069_DEPENDENCIES.sql
-- READ-ONLY. Checks the LIVE database for any current function, view,
-- trigger, index, constraint, or generated-column expression that still
-- depends on the 16 legacy columns 0069 intends to drop:
--   loads: rate, detention_rate, layover_rate
--   dispatches: dispatch_fee_percentage, load_rate, dispatch_fee_amount,
--               carrier_net_amount, notes
--   carriers: dispatch_fee_percentage, payment_terms_days,
--             factoring_company_name
--   customers: payment_terms_days
--   brokers: payment_terms_days, credit_rating, average_days_to_pay
--   drivers: pay_type, pay_rate
--
-- Run this in the Supabase SQL editor BEFORE ever applying 0069. Nothing
-- here modifies schema or data.
-- =============================================================================

-- 1. Every live function whose body still references any of these columns
--    by name (a heuristic, not a formal dependency graph -- pg_get_functiondef
--    text-searched for the column names; false positives from comments/
--    unrelated columns of the same name are possible and should be read,
--    not just counted).
select
  p.proname,
  pg_get_functiondef(p.oid) ilike '%dispatch_fee_percentage%' as refs_dispatch_fee_percentage,
  pg_get_functiondef(p.oid) ilike '%load_rate%' as refs_load_rate,
  pg_get_functiondef(p.oid) ilike '%carrier_net_amount%' as refs_carrier_net_amount,
  pg_get_functiondef(p.oid) ilike '%factoring_company_name%' as refs_factoring_company_name,
  pg_get_functiondef(p.oid) ilike '%average_days_to_pay%' as refs_average_days_to_pay
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (
    pg_get_functiondef(p.oid) ilike '%dispatch_fee_percentage%'
    or pg_get_functiondef(p.oid) ilike '%load_rate%'
    or pg_get_functiondef(p.oid) ilike '%dispatch_fee_amount%'
    or pg_get_functiondef(p.oid) ilike '%carrier_net_amount%'
    or pg_get_functiondef(p.oid) ilike '%factoring_company_name%'
    or pg_get_functiondef(p.oid) ilike '%average_days_to_pay%'
    or pg_get_functiondef(p.oid) ilike '%credit_rating%'
  )
order by p.proname;
-- Expected after this phase: only the 4 reporting functions redefined by
-- 0068 (get_load_profitability, calculate_driver_load_pay,
-- calculate_carrier_load_settlement, get_ready_to_bill_loads) should
-- appear, and ONLY as fallback references inside their own already-
-- reviewed coalesce()s reading dispatch_financials/load_financials --
-- verify each hit's actual context, don't just count rows.

-- 2. Any trigger currently attached to loads/dispatches/carriers/
--    customers/brokers/drivers -- confirms whether any 0067 mirror
--    trigger (should already be dropped by 0068) or an unexpected new one
--    still exists.
select event_object_table, trigger_name, action_timing, event_manipulation
from information_schema.triggers
where event_object_schema = 'public'
  and event_object_table in ('loads', 'dispatches', 'carriers', 'customers', 'brokers', 'drivers')
order by event_object_table, trigger_name;
-- Expected: no mirror_* triggers remain (dropped in 0068). auto-invoice
-- and any operational (non-financial) triggers are expected and fine.

-- 3. Any view whose definition references these columns.
select table_name, view_definition
from information_schema.views
where table_schema = 'public'
  and (
    view_definition ilike '%dispatch_fee_percentage%'
    or view_definition ilike '%load_rate%'
    or view_definition ilike '%carrier_net_amount%'
    or view_definition ilike '%factoring_company_name%'
    or view_definition ilike '%average_days_to_pay%'
    or view_definition ilike '%credit_rating%'
  );
-- Expected: zero rows (no views reference these columns at all, based on
-- source inspection this phase -- confirm live).

-- 4. Any index defined directly on one of these 16 columns (0069's
--    ALTER TABLE ... DROP COLUMN would need a matching DROP INDEX first
--    if any exist and weren't already accounted for).
select
  t.relname as table_name,
  i.relname as index_name,
  pg_get_indexdef(ix.indexrelid) as index_def
from pg_index ix
join pg_class i on i.oid = ix.indexrelid
join pg_class t on t.oid = ix.indrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname in ('loads', 'dispatches', 'carriers', 'customers', 'brokers', 'drivers')
  and (
    pg_get_indexdef(ix.indexrelid) ilike '%dispatch_fee_percentage%'
    or pg_get_indexdef(ix.indexrelid) ilike '%load_rate%'
    or pg_get_indexdef(ix.indexrelid) ilike '%carrier_net_amount%'
    or pg_get_indexdef(ix.indexrelid) ilike '%rate%'
    or pg_get_indexdef(ix.indexrelid) ilike '%pay_type%'
    or pg_get_indexdef(ix.indexrelid) ilike '%pay_rate%'
  );
-- Expected: zero rows.

-- 5. Any CHECK/generated-column expression on these tables that
--    references the columns (e.g. a generated column deriving from
--    dispatch_fee_percentage).
select
  conrelid::regclass as table_name,
  conname,
  pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid::regclass::text in ('public.loads', 'public.dispatches', 'public.carriers', 'public.customers', 'public.brokers', 'public.drivers')
  and contype in ('c') -- check constraints
  and (
    pg_get_constraintdef(oid) ilike '%dispatch_fee_percentage%'
    or pg_get_constraintdef(oid) ilike '%load_rate%'
    or pg_get_constraintdef(oid) ilike '%carrier_net_amount%'
    or pg_get_constraintdef(oid) ilike '%pay_type%'
    or pg_get_constraintdef(oid) ilike '%pay_rate%'
  );
-- Expected: zero rows.

select
  attrelid::regclass as table_name,
  attname as column_name,
  pg_get_expr(adbin, adrelid) as generated_expression
from pg_attribute
join pg_attrdef on pg_attrdef.adrelid = pg_attribute.attrelid and pg_attrdef.adnum = pg_attribute.attnum
where attgenerated = 's' -- STORED generated columns
  and attrelid::regclass::text in ('public.loads', 'public.dispatches', 'public.carriers', 'public.customers', 'public.brokers', 'public.drivers');
-- Expected: zero rows (none of these 6 tables have generated columns
-- derived from the legacy fields, confirmed by source inspection of
-- every CREATE TABLE / ALTER TABLE ADD COLUMN statement touching them).

-- 6. Sanity: confirm the extension tables actually have rows for every
--    parent row (i.e. the 0067 backfill + ongoing writer cutover have
--    kept pace) -- a genuinely EMPTY extension table for an org with real
--    parent rows would mean 0069 turns "stale" into "silently blank" for
--    that org.
select 'carriers' as parent, count(*) as parent_rows, (select count(*) from public.carrier_financials) as ext_rows from public.carriers
union all
select 'customers', count(*), (select count(*) from public.customer_financials) from public.customers
union all
select 'brokers', count(*), (select count(*) from public.broker_financials) from public.brokers
union all
select 'drivers', count(*), (select count(*) from public.driver_compensation) from public.drivers
union all
select 'loads', count(*), (select count(*) from public.load_financials) from public.loads
union all
select 'dispatches', count(*), (select count(*) from public.dispatch_financials) from public.dispatches;
-- Expected: ext_rows >= parent_rows for every row (0067's backfill covers
-- everything that existed at migration time, and every writer since has
-- upserted on save -- a parent row that was NEVER edited since 0067 and
-- pre-dates it will still have a row from the backfill). A meaningful gap
-- here is worth investigating before 0069, not assumed away.
