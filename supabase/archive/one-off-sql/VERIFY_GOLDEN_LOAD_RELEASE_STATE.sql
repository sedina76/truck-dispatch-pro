-- ============================================================================
-- VERIFY_GOLDEN_LOAD_RELEASE_STATE.sql
--
-- Determines whether the EFFECTS of migrations 0112 / 0113 / 0114 / 0115
-- exist in the connected (production) Supabase database.
--
-- 100% READ-ONLY. Inspects pg_catalog / information_schema only. Contains
-- no INSERT / UPDATE / DELETE / ALTER / CREATE / DROP / GRANT / REVOKE /
-- TRUNCATE, opens no transaction, and reads ZERO business rows (no
-- loads / invoices / payments / organizations data is touched). Safe to
-- run against production at any time.
--
-- HOW TO READ THE OUTPUT
--   * Result set 0  -- environment sanity (which DB, baseline objects).
--   * Result set 1  -- SUMMARY VERDICT, one row per migration. This is
--                      the answer: APPLIED / NOT APPLIED / PARTIAL /
--                      INDETERMINATE, plus a one-line reason.
--   * Result sets 2-5 -- per-object evidence the verdict is built from,
--                      for drill-down only if a summary row is PARTIAL
--                      or INDETERMINATE.
--   * Result set 6  -- raw function bodies for 0112 / 0113, last-resort
--                      manual confirmation only.
-- ============================================================================


-- ############################################################################
-- RESULT SET 0 -- ENVIRONMENT SANITY
-- ############################################################################
select
  current_database()                                                        as database,
  now()                                                                     as checked_at,
  (to_regclass('public.loads')            is not null)                      as has_loads_table,
  (to_regclass('public.load_financials')  is not null)                      as has_load_financials,          -- expect true (>= 0067)
  (to_regprocedure('public.auto_generate_invoice_from_delivered_load()') is not null) as has_auto_invoice_fn, -- expect true (>= 0022)
  (to_regprocedure('public.apply_payment_to_invoice()') is not null)        as has_apply_payment_fn;         -- expect true (>= 0026)


-- ############################################################################
-- RESULT SET 1 -- SUMMARY VERDICT (one row per migration)
-- ############################################################################
with
def_0112 as (
  select pg_get_functiondef(to_regprocedure('public.guard_invoice_party_organization()')) as def
),
trg_0112 as (
  select
    count(*)                                              as n,
    coalesce(bool_or(t.tgenabled = 'O'), false)           as enabled
  from pg_trigger t
  where t.tgname = 'invoices_guard_party_org'
    and t.tgrelid = 'public.invoices'::regclass
    and not t.tgisinternal
),
def_0113 as (
  select pg_get_functiondef(to_regprocedure('public.guard_payment_amount()')) as def
),
def_clws as (
  select pg_get_functiondef(to_regprocedure('public.create_load_with_stops(jsonb, jsonb)')) as def
),
obj_0114 as (
  select
    (to_regclass('public.load_number_counters')                      is not null) as has_counter_table,
    (to_regprocedure('public.allocate_load_number()')                is not null) as has_allocate_fn,
    (to_regprocedure('public.change_load_number(uuid, text, text)')  is not null) as has_change_fn,
    (select count(*) from pg_trigger
       where tgname = 'loads_guard_load_number_change'
         and tgrelid = 'public.loads'::regclass and not tgisinternal)            as has_new_trigger,
    (select count(*) from pg_trigger
       where tgname = 'loads_guard_load_number_immutable'
         and tgrelid = 'public.loads'::regclass and not tgisinternal)            as has_old_trigger
),
col_0115 as (
  select
    count(*) filter (where column_name = 'route_miles')               as route_miles,
    count(*) filter (where column_name = 'route_miles_calculated_at')  as route_miles_at,
    count(*) filter (where column_name = 'actual_miles')              as actual_miles,
    count(*) filter (where column_name = 'actual_miles_recorded_at')   as actual_miles_at
  from information_schema.columns
  where table_schema = 'public' and table_name = 'loads'
)
select
  '0112  invoice party + load_id guard'                                       as migration,
  case
    when (select def from def_0112) is null or (select n from trg_0112) = 0
      then 'NOT APPLIED'
    when (select enabled from trg_0112) = false
      then 'PARTIAL -- trigger present but DISABLED (tgenabled <> O); not enforcing'
    when (select def from def_0112) like '%linked load cannot be changed once set%'
     and (select def from def_0112) like '%is distinct from v_load_broker_id%'
      then 'APPLIED  (final revision: load_id immutability + load-party match both live)'
    else 'INDETERMINATE -- function+trigger exist but body lacks the load_id-immutability and/or party-match text; see RESULT SET 2 / 6'
  end                                                                          as live_state,
  'DB backstop only. createInvoice()/updateInvoice() already enforce the same rules in app code (shipped d96069d). Not a hard Gate-C blocker.' as impact
union all
select
  '0113  payment collectible-status guard',
  case
    when (select def from def_0113) is null
      then 'INDETERMINATE -- guard_payment_amount() not found (unexpected; 0026 defines it)'
    when (select def from def_0113) like '%new.invoice_id is distinct from old.invoice_id%'
     and (select def from def_0113) like '%not in (''sent'', ''viewed'', ''overdue'', ''partially_paid'')%'
      then 'APPLIED'
    else 'NOT APPLIED -- live body is the pre-0113 (0026) version: only excludes ''void'', no invoice_id-reassignment re-check'
  end,
  'DB backstop only. recordPayment() already pre-checks the 4 collectible statuses. Full-payment Golden Load path works with or without 0113.'
union all
select
  '0114  org-scoped automatic load numbers',
  case
    when (select has_counter_table from obj_0114)
     and (select has_allocate_fn   from obj_0114)
     and (select has_change_fn     from obj_0114)
     and (select has_new_trigger   from obj_0114) = 1
     and (select has_old_trigger   from obj_0114) = 0
     and (select def from def_clws) like '%allocate_load_number%'
     and (select def from def_clws) not like '%''load_number''%'
      then 'APPLIED'
    when not (select has_counter_table from obj_0114)
     and not (select has_allocate_fn   from obj_0114)
      then 'NOT APPLIED -- load_number_counters + allocate_load_number() absent; live create_load_with_stops() still expects a client load_number => UI New Load fails with 23502 and redirects to ?load_numbering_inactive=1'
    else 'PARTIAL / INDETERMINATE -- some 0114 objects present, some absent; see RESULT SET 4'
  end,
  'HARD PREREQUISITE for Golden Load Gate C. Committed app code has already cut over to server-side allocation.'
union all
select
  '0115  mileage concept separation',
  case
    when (select route_miles from col_0115) = 1 and (select actual_miles from col_0115) = 1
     and (select route_miles_at from col_0115) = 1 and (select actual_miles_at from col_0115) = 1
      then 'APPLIED'
    when (select route_miles from col_0115) = 0 and (select actual_miles from col_0115) = 0
     and (select route_miles_at from col_0115) = 0 and (select actual_miles_at from col_0115) = 0
      then 'NOT APPLIED'
    else 'PARTIAL / INDETERMINATE -- some new columns present, some absent; see RESULT SET 5'
  end,
  'Additive nullable columns only; nothing writes them; no app code references them. NOT a Golden Load dependency.'
;


-- ############################################################################
-- RESULT SET 2 -- 0112 per-object evidence
-- ############################################################################
select
  'function public.guard_invoice_party_organization()'                        as object,
  (to_regprocedure('public.guard_invoice_party_organization()') is not null)  as present,
  coalesce(pg_get_functiondef(to_regprocedure('public.guard_invoice_party_organization()'))
           like '%linked load cannot be changed once set%', false)            as has_loadid_immutability_check,
  coalesce(pg_get_functiondef(to_regprocedure('public.guard_invoice_party_organization()'))
           like '%is distinct from v_load_broker_id%', false)                 as has_load_party_match_check
union all
select
  'trigger invoices_guard_party_org ON public.invoices',
  exists (select 1 from pg_trigger
          where tgname = 'invoices_guard_party_org'
            and tgrelid = 'public.invoices'::regclass and not tgisinternal),
  coalesce((select tgenabled = 'O' from pg_trigger
            where tgname = 'invoices_guard_party_org'
              and tgrelid = 'public.invoices'::regclass and not tgisinternal), false),
  null::boolean;


-- ############################################################################
-- RESULT SET 3 -- 0113 per-object evidence
-- ############################################################################
select
  'function public.guard_payment_amount() -- body markers'                    as object,
  (to_regprocedure('public.guard_payment_amount()') is not null)              as present,
  coalesce(pg_get_functiondef(to_regprocedure('public.guard_payment_amount()'))
           like '%new.invoice_id is distinct from old.invoice_id%', false)    as has_invoice_reassign_recheck_0113,
  coalesce(pg_get_functiondef(to_regprocedure('public.guard_payment_amount()'))
           like '%not in (''sent'', ''viewed'', ''overdue'', ''partially_paid'')%', false) as has_collectible_allowlist_0113
union all
select
  'trigger payments_guard_amount ON public.payments',
  exists (select 1 from pg_trigger
          where tgname = 'payments_guard_amount'
            and tgrelid = 'public.payments'::regclass and not tgisinternal),
  coalesce((select tgenabled = 'O' from pg_trigger
            where tgname = 'payments_guard_amount'
              and tgrelid = 'public.payments'::regclass and not tgisinternal), false),
  null::boolean;


-- ############################################################################
-- RESULT SET 4 -- 0114 per-object evidence
-- ############################################################################
select 'table public.load_number_counters'                    as object, (to_regclass('public.load_number_counters') is not null)::text as state
union all
select 'function public.allocate_load_number()',                        (to_regprocedure('public.allocate_load_number()') is not null)::text
union all
select 'function public.change_load_number(uuid,text,text)',            (to_regprocedure('public.change_load_number(uuid, text, text)') is not null)::text
union all
select 'trigger loads_guard_load_number_change ON public.loads (NEW)',
  (exists (select 1 from pg_trigger where tgname = 'loads_guard_load_number_change'
             and tgrelid = 'public.loads'::regclass and not tgisinternal))::text
union all
select 'trigger loads_guard_load_number_immutable ON public.loads (OLD -- must be gone)',
  (exists (select 1 from pg_trigger where tgname = 'loads_guard_load_number_immutable'
             and tgrelid = 'public.loads'::regclass and not tgisinternal))::text
union all
select 'create_load_with_stops() body -- calls allocate_load_number  (0114 signature)',
  coalesce(pg_get_functiondef(to_regprocedure('public.create_load_with_stops(jsonb, jsonb)'))
           like '%allocate_load_number%', false)::text
union all
select 'create_load_with_stops() body -- still references a client ''load_number''  (pre-0114 => should be FALSE)',
  coalesce(pg_get_functiondef(to_regprocedure('public.create_load_with_stops(jsonb, jsonb)'))
           like '%''load_number''%', false)::text
union all
select 'create_load_with_stops() body -- SECURITY DEFINER  (0114 hardening => expect true)',
  coalesce((select p.prosecdef from pg_proc p
            where p.oid = to_regprocedure('public.create_load_with_stops(jsonb, jsonb)')), false)::text;


-- ############################################################################
-- RESULT SET 5 -- 0115 per-object evidence
-- ############################################################################
select column_name, data_type, numeric_precision, numeric_scale, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'loads'
  and column_name in ('total_miles', 'route_miles', 'route_miles_calculated_at',
                      'actual_miles', 'actual_miles_recorded_at')
order by column_name;
-- 0115 APPLIED  => 5 rows (total_miles + 4 new).
-- 0115 NOT APPLIED => 1 row (total_miles only). total_miles must ALWAYS
-- read numeric(8,2) / nullable, whether or not 0115 is applied.


-- ############################################################################
-- RESULT SET 6 -- RAW FUNCTION BODIES (last-resort manual confirmation only)
-- ############################################################################
select 'guard_invoice_party_organization (0112)' as fn,
       pg_get_functiondef(to_regprocedure('public.guard_invoice_party_organization()')) as body
union all
select 'guard_payment_amount (0113 vs 0026)',
       pg_get_functiondef(to_regprocedure('public.guard_payment_amount()'));
