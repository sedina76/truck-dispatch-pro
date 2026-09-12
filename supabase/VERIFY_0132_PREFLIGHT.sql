-- ============================================================================
-- 0132 PRE-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No DO block, no transaction control, no RPC execution. Safe on production.
--
-- Run BEFORE applying 0132_load_carrier_and_trailer_scope.sql. Requires 0131 live.
-- Every row of the matrix must show ok = true.
--
-- IMPORTANT -- BEHAVIOR CHANGE BLAST RADIUS: 0132 backfills every carrier-less
-- trailer to ownership_scope = 'unresolved'. After apply, such a trailer can
-- no longer be assigned to a NEW dispatch or re-assigned onto an existing one
-- until an owner/admin classifies it. The two "context" queries at the bottom
-- quantify that. Review them before applying.
-- ============================================================================
select * from ( values

  (1, 'public.loads exists',      to_regclass('public.loads')      is not null),
  (2, 'public.dispatches exists', to_regclass('public.dispatches') is not null),
  (3, 'public.trailers exists',   to_regclass('public.trailers')   is not null),
  (4, 'public.carriers exists',   to_regclass('public.carriers')   is not null),
  (5, '0125 landmark: loads.financial_dispatch_id present',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='financial_dispatch_id')),
  (6, '0131 landmark: public.carrier_brokers present', to_regclass('public.carrier_brokers') is not null),
  (7, '0055 dispatches_guard_org trigger present (must survive 0132 untouched)',
      exists (select 1 from pg_trigger where tgname='dispatches_guard_org' and tgrelid='public.dispatches'::regclass and not tgisinternal)),
  (8, '0125 dispatches_assign_financial_controller trigger present',
      exists (select 1 from pg_trigger where tgname='dispatches_assign_financial_controller' and tgrelid='public.dispatches'::regclass and not tgisinternal)),

  -- ---- objects 0132 CREATES must be ABSENT ----
  (9,  'type public.trailer_ownership_scope does NOT exist yet',
      not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='trailer_ownership_scope')),
  (10, 'loads.carrier_id does NOT exist yet',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_id')),
  (11, 'loads.carrier_resolution does NOT exist yet',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_resolution')),
  (12, 'loads.carrier_locked_at does NOT exist yet',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_locked_at')),
  (13, 'trailers.ownership_scope does NOT exist yet',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='trailers' and column_name='ownership_scope')),
  (14, 'function public.guard_load_carrier_change() does NOT exist yet',
      to_regprocedure('public.guard_load_carrier_change()') is null),
  (15, 'function public.guard_dispatch_carrier_scope() does NOT exist yet',
      to_regprocedure('public.guard_dispatch_carrier_scope()') is null),
  (16, 'function public.trailers_derive_ownership_scope() does NOT exist yet',
      to_regprocedure('public.trailers_derive_ownership_scope()') is null),
  (17, 'table public.trailer_ownership_scope_audit does NOT exist yet',
      to_regclass('public.trailer_ownership_scope_audit') is null),
  (18, 'function public.approve_trailer_ownership_scope does NOT exist yet',
      not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public' and p.proname='approve_trailer_ownership_scope')),
  (19, 'function public.guard_trailer_ownership_scope_change() does NOT exist yet',
      to_regprocedure('public.guard_trailer_ownership_scope_change()') is null)

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): trailer ownership_scope backfill split.
select 'trailers with a carrier -> "carrier"'   as note, count(*) as n from public.trailers where carrier_id is not null
union all
select 'trailers with NO carrier -> "unresolved"' as note, count(*) as n from public.trailers where carrier_id is null;

-- Context (not a gate): existing dispatches whose trailer WILL become
-- 'unresolved'. Other UPDATEs on these dispatches are unaffected, but any
-- future re-assignment of that trailer (to this or another dispatch) is
-- blocked until the trailer is classified.
select 'dispatches referencing a soon-to-be-unresolved trailer' as note,
       count(*) as n
from public.dispatches d
join public.trailers tr on tr.id = d.trailer_id
where tr.carrier_id is null;

select 'ACTIVE dispatches referencing a soon-to-be-unresolved trailer' as note,
       count(*) as n
from public.dispatches d
join public.trailers tr on tr.id = d.trailer_id
where tr.carrier_id is null
  and d.status not in ('delivered','completed','cancelled');

-- Context (not a gate, but IMPORTANT to review): loads whose
-- financial_dispatch_id (controller) is CONTRADICTED by a currently
-- non-cancelled dispatch of a different carrier. This is exactly the
-- historical-conflict class 0133's corrected C1 rule now classifies
-- 'unresolved' rather than silently trusting the controller (correction:
-- "correct migration 0133 candidate rules"). Cannot happen for anything
-- created AFTER 0132's guard_dispatch_carrier_scope is live -- this query
-- can only ever find PRE-EXISTING (legacy) data.
select 'loads whose financial controller is contradicted by a live non-cancelled dispatch of a different carrier' as note,
       count(*) as n
from public.loads l
where l.financial_dispatch_id is not null
  and exists (
    select 1 from public.dispatches d
    where d.load_id = l.id and d.status <> 'cancelled'
      and d.carrier_id <> (select d2.carrier_id from public.dispatches d2 where d2.id = l.financial_dispatch_id)
  );
