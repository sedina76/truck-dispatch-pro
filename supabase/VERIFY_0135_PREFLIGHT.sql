-- ============================================================================
-- 0135 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0135. Requires 0134 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0134 landmark: public.transition_dispatch_status(...) present',
      to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is not null),
  (2, '0055 landmark: public.guard_dispatch_org() present',
      to_regprocedure('public.guard_dispatch_org()') is not null),
  (3, '0132 landmark: public.guard_dispatch_carrier_scope() present',
      to_regprocedure('public.guard_dispatch_carrier_scope()') is not null),
  (4, '0054 landmark: dispatches_active_driver_unique index present',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='dispatches' and indexname='dispatches_active_driver_unique')),
  (5, '0054 landmark: dispatches_active_truck_unique index present',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='dispatches' and indexname='dispatches_active_truck_unique')),
  (6, '0054 landmark: dispatches_active_trailer_unique index present',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='dispatches' and indexname='dispatches_active_trailer_unique')),

  -- ---- objects 0135 CREATES must be ABSENT (rerun guard) ----
  (7, 'function public.reassign_dispatch_resources(...) does NOT yet exist',
      to_regprocedure('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)') is null),
  (8, 'table public.dispatch_resource_reassignments does NOT yet exist',
      to_regclass('public.dispatch_resource_reassignments') is null)

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): the EXACT current dispatches UPDATE grant, column by
-- column, for authenticated -- expect the CURRENT (pre-0135), over-broad
-- table-level grant here; compare against 0135's intended final list
-- (notes only) before applying.
select column_name
from information_schema.column_privileges
where table_schema='public' and table_name='dispatches' and grantee='authenticated' and privilege_type='UPDATE'
order by column_name;

-- Context: any load/dispatch pair whose carrier already disagrees BEFORE
-- this migration even runs (would make reassign_dispatch_resources's own
-- "derive carrier, reject mismatch" check fire on the very first call for
-- that dispatch -- not a defect, but worth knowing about ahead of time).
select l.id as load_id, d.id as dispatch_id, l.carrier_id as load_carrier, d.carrier_id as dispatch_carrier
from public.loads l
join public.dispatches d on d.load_id = l.id
where l.carrier_id is not null and d.carrier_id is distinct from l.carrier_id;
