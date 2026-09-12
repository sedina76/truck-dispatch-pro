-- ============================================================================
-- ROLLBACK_0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
--
-- Reverses 0134 ONLY: drops transition_dispatch_status(), is_valid_dispatch_
-- status_transition(), dispatch_status_sequence_rank() (Phase 3A.2, item 8),
-- dispatch_status_transitions, and restores the trailers UPDATE grant to
-- 0132's original (broader) column list.
--
-- IMPORTANT: restoring 0132's original grant re-opens the id/organization_id/
-- created_at/updated_at over-grant this hotfix exists to close. Only run
-- this rollback if 0134 itself must be reversed (e.g. a defect in the RPC) --
-- NOT as a routine operation, and re-apply 0134 promptly afterward.
--
-- Safe to run even if the application has already been updated to call
-- transition_dispatch_status() -- that RPC will simply stop existing and
-- the application will fail closed (the hotfix's own application-side
-- design point: no unsafe fallback to a raw UPDATE). Rolling back the
-- database WITHOUT also rolling back the application deploy will make the
-- dispatch board's status-change action fail outright until either the
-- application is also rolled back or 0134 is re-applied -- see the
-- Phase 3A.1 report's deployment/rollback order for the coordinated sequence.
--
-- STRUCTURE: explicit BEGIN/COMMIT.
-- ============================================================================

begin;

do $mig$
begin
  if to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is null then
    raise exception 'ROLLBACK 0134 precondition: transition_dispatch_status(...) does not exist -- 0134 was never applied, or already rolled back. STOP.';
  end if;
end
$mig$;

drop function if exists public.transition_dispatch_status(uuid, public.dispatch_status, text, text);
drop function if exists public.is_valid_dispatch_status_transition(public.dispatch_status, public.dispatch_status);
drop function if exists public.dispatch_status_sequence_rank(public.dispatch_status);
drop table if exists public.dispatch_status_transitions;

-- restore 0132's original (broader) grant -- see that migration's section F
revoke update on public.trailers from authenticated;
grant update (
  id, organization_id, unit_number, vin, trailer_type, length_ft,
  license_plate, license_state, ownership_type, status,
  registration_expiry_date, annual_inspection_expiry_date, notes,
  created_at, updated_at
) on public.trailers to authenticated;

do $mig$
begin
  if to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is not null then
    raise exception 'ROLLBACK 0134 postcondition: transition_dispatch_status(...) still exists.';
  end if;
  if to_regclass('public.dispatch_status_transitions') is not null then
    raise exception 'ROLLBACK 0134 postcondition: dispatch_status_transitions still exists.';
  end if;
  if to_regprocedure('public.dispatch_status_sequence_rank(public.dispatch_status)') is not null then
    raise exception 'ROLLBACK 0134 postcondition: dispatch_status_sequence_rank(...) still exists.';
  end if;
  raise notice 'ROLLBACK 0134 complete: transition_dispatch_status(...) + is_valid_dispatch_status_transition(...) + dispatch_status_sequence_rank(...) + dispatch_status_transitions removed; trailers UPDATE grant restored to 0132''s original (broader) column list. cancel_dispatch()/guard_dispatch_carrier_scope() (0129/0132) untouched throughout.';
end
$mig$;

commit;
