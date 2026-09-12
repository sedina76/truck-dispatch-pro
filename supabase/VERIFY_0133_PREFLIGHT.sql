-- ============================================================================
-- 0133 PRE-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No DO block, no transaction control, no RPC execution. Safe on production.
--
-- Run BEFORE applying 0133_deterministic_carrier_backfill.sql. Requires 0132 live.
-- Every row of the matrix must show ok = true.
--
-- NO MAINTENANCE WINDOW IS REQUIRED before this migration: a load that
-- already has a non-NULL carrier_id (set by anything other than 0133, at any
-- time after 0132) is preserved untouched, not rejected. Checks 11-12 below
-- validate any such pre-existing assignment BEFORE you apply -- if either
-- fails, 0133 will abort with zero writes rather than silently overwrite or
-- guess. The bottom section previews the deterministic resolution plan
-- (which rule fires for each load, and which loads become 'unresolved').
-- Review it before applying: 0133 will NOT abort on ambiguity -- ambiguous
-- loads are recorded as 'unresolved' and blocked from automation, not
-- guessed.
-- ============================================================================
select * from ( values

  (1, '0132 landmark: loads.carrier_id present',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_id')),
  (2, '0132 landmark: type public.trailer_ownership_scope present',
      exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='trailer_ownership_scope')),
  (3, '0132 landmark: public.guard_load_carrier_change() present',
      to_regprocedure('public.guard_load_carrier_change()') is not null),
  (4, '0130 landmark: public.unresolved_carrier_records present',
      to_regclass('public.unresolved_carrier_records') is not null),
  (5, '0130 landmark: public.record_unresolved_carrier_record(...) present',
      to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)') is not null),
  (6, 'enum public.dispatch_status has a cancelled member',
      exists (select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
              where n.nspname='public' and t.typname='dispatch_status' and e.enumlabel='cancelled')),

  -- ---- rerun rejection (the ONLY rerun guard -- a pre-existing carrier_id
  --      is no longer a rejection condition, see header) ----
  (7, 'loads.carrier_id comment does NOT yet carry the 0133 backfill marker',
      coalesce(col_description('public.loads'::regclass,
        (select attnum from pg_attribute where attrelid='public.loads'::regclass and attname='carrier_id' and not attisdropped)),
        '') not ilike '%backfilled by migration 0133%'),

  -- ---- structural sanity (0133 aborts on these; confirm they are clean now) ----
  (8, 'NO load resolves (via financial_dispatch_id) to a carrier of a different org',
      not exists (
        select 1 from public.loads l
        join public.dispatches d on d.id = l.financial_dispatch_id and d.load_id = l.id
        join public.carriers c on c.id = d.carrier_id
        where c.organization_id <> l.organization_id)),
  (9, 'NO load has financial_dispatch_id pointing at another load''s dispatch',
      not exists (
        select 1 from public.loads l
        join public.dispatches d on d.id = l.financial_dispatch_id
        where d.load_id <> l.id)),
  (10, 'table public.carrier_backfill_0133_provenance does NOT exist yet',
      to_regclass('public.carrier_backfill_0133_provenance') is null),

  -- ---- 0132->0133 race: pre-existing carrier_id assignments (correction) ----
  (11, 'every PRE-EXISTING loads.carrier_id resolves to a carrier of the SAME organization',
      not exists (
        select 1 from public.loads l
        join public.carriers c on c.id = l.carrier_id
        where l.carrier_id is not null and c.organization_id <> l.organization_id)),
  (12, 'every PRE-EXISTING loads.carrier_id agrees with its financial_dispatch_id carrier AND every non-cancelled dispatch carrier (else 0133 will ABORT, not overwrite)',
      not exists (
        select 1 from public.loads l
        where l.carrier_id is not null
          and (
            (select d.carrier_id from public.dispatches d where d.id = l.financial_dispatch_id and d.load_id = l.id) is distinct from l.carrier_id
            and l.financial_dispatch_id is not null
          )
      )
      and not exists (
        select 1 from public.loads l
        join public.dispatches d on d.load_id = l.id and d.status <> 'cancelled'
        where l.carrier_id is not null and d.carrier_id <> l.carrier_id)),

  -- ---- C1 controller-conflict GATE (Phase 3A clarification round, item 2)
  -- ---- a load with NO pre-existing carrier_id whose financial_
  -- dispatch_id names a carrier CONTRADICTED by a currently non-cancelled
  -- dispatch of a DIFFERENT carrier. 0133 ABORTS THE ENTIRE MIGRATION
  -- (zero writes) if this check fails -- it never silently classifies such
  -- a load 'unresolved' while leaving financial_dispatch_id populated with
  -- the contested value. Correct each offending load manually (see the
  -- context query below for the exact list), then rerun this preflight
  -- until this check passes, before applying 0133.
  (13, 'NO load has a financial_dispatch_id CONTRADICTED by a currently non-cancelled dispatch of a different carrier (else 0133 will ABORT -- correct manually, then rerun this preflight)',
      not exists (
        select 1 from public.loads l
        join public.dispatches fd on fd.id = l.financial_dispatch_id and fd.load_id = l.id
        where l.carrier_id is null
          and exists (
            select 1 from public.dispatches d
            where d.load_id = l.id and d.status <> 'cancelled' and d.carrier_id <> fd.carrier_id
          )))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): how many loads already have a carrier_id -- these
-- will be PRESERVED untouched and excluded from rollback provenance.
select 'loads with a PRE-EXISTING carrier_id (preserved, not touched by 0133)' as note, count(*) as n
from public.loads where carrier_id is not null;

-- Context (not a gate, but THE required diagnostic if check 13 above shows
-- ok=false): the EXACT conflicting loads -- correct each one manually, then
-- rerun this preflight. 0133 will refuse to apply while this list is
-- non-empty.
select
  l.id as load_id, l.load_number, l.organization_id,
  l.financial_dispatch_id, fd.carrier_id as controller_carrier_id,
  (select array_agg(distinct d.carrier_id) from public.dispatches d
    where d.load_id = l.id and d.status <> 'cancelled' and d.carrier_id <> fd.carrier_id) as contradicting_live_carrier_ids
from public.loads l
join public.dispatches fd on fd.id = l.financial_dispatch_id and fd.load_id = l.id
where l.carrier_id is null
  and exists (
    select 1 from public.dispatches d
    where d.load_id = l.id and d.status <> 'cancelled' and d.carrier_id <> fd.carrier_id
  )
order by l.id;

-- ---------------------------------------------------------------------------
-- PLAN PREVIEW (context, not a gate) for loads that DO NOT yet have a
-- carrier_id. Same rule order as migration 0133. Pre-existing loads are
-- excluded from this preview (they are not touched).
--
-- IMPORTANT: if the C1_controller_conflict row below shows a non-zero count,
-- check 13 ABOVE is already ok=false and 0133 will ABORT THE ENTIRE
-- MIGRATION (zero writes anywhere, not just for these loads) until every
-- one is manually corrected. Unlike every other row in this preview
-- (resolved/backfilled/unresolved loads are all things 0133 WILL actually
-- write), a non-zero C1_controller_conflict count means 0133 will not run
-- at all -- treat it as a hard blocker, not a preview of an outcome.
-- ---------------------------------------------------------------------------
with per_load as (
  select
    l.id as load_id, l.organization_id as load_org, l.load_number,
    l.financial_dispatch_id as fdi,
    (select d.carrier_id from public.dispatches d where d.id = l.financial_dispatch_id and d.load_id = l.id) as fdi_carrier,
    coalesce((select array_agg(distinct d.carrier_id) from public.dispatches d where d.load_id = l.id), '{}'::uuid[]) as all_carriers,
    coalesce((select array_agg(distinct d.carrier_id) from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'), '{}'::uuid[]) as noncanc_carriers,
    coalesce((select count(*) from public.dispatches d where d.load_id = l.id), 0) as n_disp
  from public.loads l
  where l.carrier_id is null
),
-- c1_safe mirrors migration 0133's own gate exactly (correction: "correct
-- migration 0133 candidate rules" -- C1 may no longer blindly trust
-- financial_dispatch_id when a LIVE non-cancelled dispatch disagrees with
-- it): the controller is trusted only when there are NO non-cancelled
-- dispatches at all, or every one of them agrees with the controller's
-- carrier. A controller contradicted by a live, non-cancelled dispatch of a
-- different carrier falls through to the NEW C1_controller_conflict rule
-- (never silently resolved by trusting the controller alone).
per_load2 as (
  select p.*,
    (p.fdi_carrier is not null
     and (array_length(p.noncanc_carriers,1) is null
          or (array_length(p.noncanc_carriers,1) = 1 and p.noncanc_carriers[1] = p.fdi_carrier))
    ) as c1_safe
  from per_load p
)
select
  (case
     when c1_safe then 'C1_financial_controller'
     when fdi_carrier is not null then 'C1_controller_conflict'
     when array_length(noncanc_carriers,1) = 1 then 'C2_sole_noncancelled_carrier'
     when array_length(noncanc_carriers,1) is null and array_length(all_carriers,1) = 1 then 'C3_sole_cancelled_carrier'
     when n_disp = 0 then 'C4_zero_dispatch'
     else 'C4_conflicting_carriers'
   end) as rule_applied,
  (case
     when c1_safe then 'resolved'
     when fdi_carrier is not null then 'unresolved'
     when array_length(noncanc_carriers,1) = 1 then 'backfilled'
     when array_length(noncanc_carriers,1) is null and array_length(all_carriers,1) = 1 then 'backfilled'
     else 'unresolved'
   end) as resolution,
  count(*) as loads
from per_load2
group by 1, 2
order by 1;
