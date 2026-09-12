-- ============================================================================
-- 0134 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0134. Requires 0133 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0133 landmark: public.carrier_backfill_0133_provenance present (0133 has been applied)',
      to_regclass('public.carrier_backfill_0133_provenance') is not null),
  (2, '0129 landmark: public.cancel_dispatch(uuid,text) present',
      to_regprocedure('public.cancel_dispatch(uuid,text)') is not null),
  (3, '0132 landmark: public.guard_dispatch_carrier_scope() present',
      to_regprocedure('public.guard_dispatch_carrier_scope()') is not null),
  (4, '0007/0046 landmark: public.log_activity(entity_type,uuid,text,jsonb,uuid) present',
      to_regprocedure('public.log_activity(public.entity_type,uuid,text,jsonb,uuid)') is not null),

  -- ---- objects 0134 CREATES must be ABSENT (rerun guard) ----
  (5, 'function public.transition_dispatch_status(...) does NOT yet exist',
      to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is null),
  (6, 'function public.is_valid_dispatch_status_transition(...) does NOT yet exist',
      to_regprocedure('public.is_valid_dispatch_status_transition(public.dispatch_status,public.dispatch_status)') is null),
  (7, 'table public.dispatch_status_transitions does NOT yet exist',
      to_regclass('public.dispatch_status_transitions') is null),

  -- ---- current trailer grant blast radius (context for item A) ----
  (8, 'no OTHER migration has already narrowed the trailers UPDATE grant (informational -- expect the CURRENT, over-broad 0132 grant here)',
      true)

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): the EXACT current trailers UPDATE grant, column by
-- column, for authenticated -- compare against 0134's intended final list
-- (unit_number, vin, trailer_type, length_ft, license_plate, license_state,
-- ownership_type, status, registration_expiry_date,
-- annual_inspection_expiry_date, notes) before applying.
select column_name
from information_schema.column_privileges
where table_schema='public' and table_name='trailers' and grantee='authenticated' and privilege_type='UPDATE'
order by column_name;

-- Context (not a gate): how many dispatches currently sit in each status --
-- informational only, to sanity-check the transition matrix will not need
-- to reject anything already in flight (it never touches existing rows;
-- this is purely for human review before apply).
select status, count(*) as dispatches from public.dispatches group by status order by status;
