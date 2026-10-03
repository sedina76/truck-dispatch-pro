-- ============================================================================
-- VERIFY_LD100024_DISPATCH_STATUS_REPAIR.sql
--   100% READ-ONLY.  SELECT + catalog only.
--   No ALTER/CREATE/DROP/INSERT/UPDATE/DELETE/TRUNCATE/GRANT/REVOKE.
--   No DO block.  No transaction control.  Never executes any function.
--   Safe to run on production, any number of times.
--
-- PURPOSE
--   Prove the exact pre-conditions for
--   supabase/REPAIR_LD100024_DISPATCH_STATUS.sql, which flips ONE load's
--   status from 'booked' to 'dispatched'. Run this FIRST. Every row of the
--   matrix must show ok = true. If any row is FAIL, do NOT run the repair.
--
-- CONTEXT
--   Load LD-100024 (463891ec-88fb-4a48-a010-6e2789f62faa) has an assigned
--   dispatch ff50462b-735b-48ae-ac83-d43886b605b8 and loads.
--   financial_dispatch_id already points at it, but loads.status was left
--   at 'booked' -- the pre-0129 non-atomic createDispatch path advanced the
--   dispatch + financial controller but not the load. 0129's create_dispatch
--   now does this atomically; this one historical row needs a manual nudge.
-- ============================================================================

with
L as (
  select * from public.loads
  where id = '463891ec-88fb-4a48-a010-6e2789f62faa'
),
D as (
  select * from public.dispatches
  where id = 'ff50462b-735b-48ae-ac83-d43886b605b8'
),
ORG as (
  select * from public.organizations
  where id = '11111111-0000-0000-0000-000000000001'
),
active_disp as (
  select d.id, d.status
  from public.dispatches d
  where d.load_id = '463891ec-88fb-4a48-a010-6e2789f62faa'
    and d.status::text = any (array['assigned','accepted','en_route_to_pickup',
                              'at_pickup','loaded','en_route_to_delivery','at_delivery'])
),
conflict_disp as (
  select d2.id
  from public.dispatches d2
  cross join D
  where d2.id <> D.id
    and d2.status::text = any (array['assigned','accepted','en_route_to_pickup',
                               'at_pickup','loaded','en_route_to_delivery','at_delivery'])
    and (   d2.driver_id  = D.driver_id
         or d2.truck_id   = D.truck_id
         or (D.trailer_id is not null and d2.trailer_id = D.trailer_id) )
)
select check_no, label, case when ok then 'PASS' else 'FAIL' end as result, ok
from (values

  ( 1, 'load id 463891ec-88fb-4a48-a010-6e2789f62faa exists and load_number = LD-100024',
    (select count(*) from L) = 1
    and (select load_number from L) = 'LD-100024'),

  ( 2, 'organization is Kali Freights LLC / 11111111-0000-0000-0000-000000000001',
    (select organization_id from L) = '11111111-0000-0000-0000-000000000001'::uuid
    and (select count(*) from ORG) = 1
    and lower((select name from ORG)) like 'kali freights%'),

  ( 3, 'current loads.status is booked',
    (select status from L)::text = 'booked'),

  ( 4, 'loads.financial_dispatch_id = ff50462b-735b-48ae-ac83-d43886b605b8',
    (select financial_dispatch_id from L) = 'ff50462b-735b-48ae-ac83-d43886b605b8'::uuid),

  ( 5, 'dispatch ff50462b exists and belongs to THIS load and THIS organization',
    (select count(*) from D) = 1
    and (select load_id from D)         = '463891ec-88fb-4a48-a010-6e2789f62faa'::uuid
    and (select organization_id from D) = '11111111-0000-0000-0000-000000000001'::uuid),

  ( 6, 'dispatch ff50462b status is assigned',
    (select status from D)::text = 'assigned'),

  ( 7, 'exactly ONE active dispatch exists for the load, and it is ff50462b',
    (select count(*) from active_disp) = 1
    and exists (select 1 from active_disp where id = 'ff50462b-735b-48ae-ac83-d43886b605b8'::uuid)),

  ( 8, 'driver (Fuaad Ahmed -- name matched on "ahmed") and truck T-112 are attached to the dispatch',
    exists (select 1 from public.drivers dr cross join D
            where dr.id = D.driver_id
              and (coalesce(dr.first_name,'') || ' ' || coalesce(dr.last_name,'')) ilike '%ahmed%')
    and exists (select 1 from public.trucks tk cross join D
                where tk.id = D.truck_id and tk.unit_number = 'T-112')),

  ( 9, 'no invoice exists for the load',
    not exists (select 1 from public.invoices where load_id = '463891ec-88fb-4a48-a010-6e2789f62faa')),

  (10, 'no conflicting active dispatch (this dispatch''s driver / truck / trailer are not on any OTHER active dispatch)',
    (select count(*) from conflict_disp) = 0),

  (11, 'migration 0129 functions present and wired (create_dispatch / cancel_dispatch / _generate_invoice_number_internal; auto-invoice + public generate_invoice_number both go through the internal helper)',
    to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)') is not null
    and to_regprocedure('public.cancel_dispatch(uuid,text)') is not null
    and to_regprocedure('public._generate_invoice_number_internal(uuid)') is not null
    and lower(regexp_replace(pg_get_functiondef('public.auto_generate_invoice_from_delivered_load()'::regprocedure), '\s+', ' ', 'g'))
        like '%public._generate_invoice_number_internal(new.organization_id)%'
    and lower(regexp_replace(pg_get_functiondef('public.generate_invoice_number(uuid)'::regprocedure), '\s+', ' ', 'g'))
        like '%public._generate_invoice_number_internal(p_organization_id)%')

) as t(check_no, label, ok)
order by check_no;

-- ---------------------------------------------------------------------------
-- Eyeball: the EXACT before-state the repair will act on.
-- ---------------------------------------------------------------------------
-- NOTE: loads.rate was removed by migration 0069 -- the financial amount now
-- lives in public.load_financials.rate. It is NOT a precondition of this
-- repair (which only touches loads.status); the line below shows it purely
-- for context, resolved explicitly by load_id and clearly labelled.
select 'BEFORE -- public.loads' as note,
       id, load_number, organization_id, status, financial_dispatch_id, updated_at
from public.loads
where id = '463891ec-88fb-4a48-a010-6e2789f62faa';

select 'BEFORE -- public.load_financials.rate for the load (context only -- NOT a repair precondition)' as note,
       lf.load_id, lf.rate as load_financials_rate
from public.load_financials lf
where lf.load_id = '463891ec-88fb-4a48-a010-6e2789f62faa';

select 'BEFORE -- public.dispatches (must be UNCHANGED by the repair)' as note,
       id, load_id, organization_id, status, carrier_id, driver_id, truck_id, trailer_id,
       dispatched_at, completed_at, cancelled_at, created_at
from public.dispatches
where id = 'ff50462b-735b-48ae-ac83-d43886b605b8';

select 'BEFORE -- driver + truck on the dispatch' as note,
       dr.id as driver_id, trim(coalesce(dr.first_name,'') || ' ' || coalesce(dr.last_name,'')) as driver_name,
       tk.id as truck_id, tk.unit_number as truck_unit
from public.dispatches d
left join public.drivers dr on dr.id = d.driver_id
left join public.trucks  tk on tk.id = d.truck_id
where d.id = 'ff50462b-735b-48ae-ac83-d43886b605b8';

select 'BEFORE -- invoices for the load (expect ZERO rows)' as note,
       id, invoice_number, status, load_id, dispatch_id, total_amount
from public.invoices
where load_id = '463891ec-88fb-4a48-a010-6e2789f62faa';

select 'BEFORE -- every dispatch for the load' as note,
       id, status, created_at, dispatched_at
from public.dispatches
where load_id = '463891ec-88fb-4a48-a010-6e2789f62faa'
order by created_at;

-- ---------------------------------------------------------------------------
-- Eyeball: every trigger currently attached to public.loads, so the repair
-- reviewer can confirm the set matches the analysis in
-- REPAIR_LD100024_DISPATCH_STATUS.sql (5 triggers; only set_updated_at does
-- anything on a status-only 'booked' -> 'dispatched' UPDATE).
-- ---------------------------------------------------------------------------
select 'trigger on public.loads' as note,
       t.tgname,
       case t.tgtype & 2 when 2 then 'BEFORE' else 'AFTER' end as timing,
       array_to_string(array[
         case when (t.tgtype & 4)  = 4  then 'INSERT' end,
         case when (t.tgtype & 8)  = 8  then 'DELETE' end,
         case when (t.tgtype & 16) = 16 then 'UPDATE' end
       ], ' / ') as events,
       p.proname as function,
       pg_get_triggerdef(t.oid) as definition
from pg_trigger t
join pg_proc p on p.oid = t.tgfoid
where t.tgrelid = 'public.loads'::regclass
  and not t.tgisinternal
order by t.tgname;
