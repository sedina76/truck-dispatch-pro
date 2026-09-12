-- ============================================================================
-- ROLLBACK_0135_dispatch_resource_reassignment_and_carrier_lockdown.sql
--
-- Reverses 0135 ONLY: drops reassign_dispatch_resources(),
-- dispatch_resource_reassignments, and restores the dispatches UPDATE grant
-- to the pre-0135 (broader, effectively unrestricted) table-level state.
--
-- IMPORTANT: restoring the pre-0135 grant re-opens direct authenticated
-- UPDATE to carrier_id/load_id/driver_id/truck_id/trailer_id/status on
-- dispatches -- exactly the tampering surface this migration exists to
-- close. Only run this rollback if 0135 itself must be reversed (e.g. a
-- defect in the RPC), and re-apply 0135 promptly afterward. See the Phase
-- 3A.2 report's deployment/rollback order for the coordinated sequence
-- with the application deploy.
--
-- STRUCTURE: explicit BEGIN/COMMIT.
-- ============================================================================

begin;

do $mig$
begin
  if to_regprocedure('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)') is null then
    raise exception 'ROLLBACK 0135 precondition: reassign_dispatch_resources(...) does not exist -- 0135 was never applied, or already rolled back. STOP.';
  end if;
end
$mig$;

drop function if exists public.reassign_dispatch_resources(uuid, uuid, uuid, uuid, text, text, timestamptz);
drop table if exists public.dispatch_resource_reassignments;

-- restore the pre-0135 (0010 blanket) table-level grant
grant update on public.dispatches to authenticated;

do $mig$
begin
  if to_regprocedure('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)') is not null then
    raise exception 'ROLLBACK 0135 postcondition: reassign_dispatch_resources(...) still exists.';
  end if;
  if to_regclass('public.dispatch_resource_reassignments') is not null then
    raise exception 'ROLLBACK 0135 postcondition: dispatch_resource_reassignments still exists.';
  end if;
  raise notice 'ROLLBACK 0135 complete: reassign_dispatch_resources(...) + dispatch_resource_reassignments removed; dispatches UPDATE grant restored to the pre-0135 table-level state. guard_dispatch_org()/cancel_dispatch()/guard_dispatch_carrier_scope()/transition_dispatch_status() (0055/0129/0132/0134) untouched throughout.';
end
$mig$;

commit;
