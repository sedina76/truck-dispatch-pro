-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0137_deterministic_factoring_carrier_    ##
-- ##  backfill.sql                                                         ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse the 0137        ##
-- ##  backfill. APPLY AS ONE TRANSACTION. Roll back 0138 FIRST if applied.  ##
-- ##                                                                        ##
-- ##  PROVENANCE-BASED, NOT BLANKET. Reverses ONLY the exact                ##
-- ##  (relationship_id, carrier_id) values 0137 itself wrote, as recorded   ##
-- ##  in the permanent public.carrier_backfill_0137_provenance table.       ##
-- ##  Since factoring_relationships.carrier_id was BRAND NEW when 0137 ran  ##
-- ##  (0136 added it NULL for every row, and nothing else can have written  ##
-- ##  to it before 0138, which never touches carrier_id), there is no      ##
-- ##  "pre-existing value written by something else" case to protect       ##
-- ##  around -- unlike 0133, this rollback needs no trigger-disable dance.  ##
-- ##                                                                        ##
-- ##  A row is reversed ONLY when its CURRENT carrier_id is still           ##
-- ##  byte-identical to what 0137 recorded (nothing has changed it since --##
-- ##  no manual correction, no later assignment). For an unresolved row,    ##
-- ##  its unresolved_carrier_records entry must still be OPEN (untouched)   ##
-- ##  for that row's exception to be cleaned up too.                       ##
-- ##                                                                        ##
-- ##  FAIL CLOSED: if any provenance row's live state disagrees with what   ##
-- ##  0137 recorded, this script prints the exact mismatched relationship  ##
-- ##  ids and ABORTS THE ENTIRE ROLLBACK with ZERO writes.                  ##
-- ############################################################################

begin;

do $rb$
begin
  if to_regclass('public.carrier_backfill_0137_provenance') is null then
    raise exception 'ROLLBACK 0137: public.carrier_backfill_0137_provenance is missing -- 0137 was never applied (or already rolled back). STOP.';
  end if;
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null then
    raise exception 'ROLLBACK 0137: 0138''s classifier still exists -- roll back 0138 FIRST. STOP.';
  end if;
end
$rb$;

-- Fail-closed check: every provenance row's carrier_id must still match
-- the live factoring_relationships row exactly.
do $rb$
declare v_n int; v_ids uuid[];
begin
  select count(*), array_agg(pv.relationship_id) into v_n, v_ids
  from public.carrier_backfill_0137_provenance pv
  join public.factoring_relationships fr on fr.id = pv.relationship_id
  where fr.carrier_id is distinct from pv.carrier_id;

  if v_n > 0 then
    raise exception 'ROLLBACK 0137 ABORT: % relationship(s) have changed carrier_id since 0137 ran (no longer match provenance) -- relationship_id(s): %. Resolve manually; this rollback never partially reverses. STOP.', v_n, v_ids;
  end if;
end
$rb$;

-- Clear carrier_id exactly where 0137 set it.
update public.factoring_relationships fr
set carrier_id = null
from public.carrier_backfill_0137_provenance pv
where pv.relationship_id = fr.id and pv.carrier_id is not null;

-- Resolve (archive, never delete -- decision 7's "never auto-delete"
-- posture from 0130) every OPEN unresolved_carrier_records row 0137
-- created, ONLY if still untouched since.
update public.unresolved_carrier_records u
set status = 'archived_legacy',
    resolution_note = 'Reverted by ROLLBACK_0137 -- migration 0137 itself was rolled back.'
from public.carrier_backfill_0137_provenance pv
where pv.unresolved_carrier_record_id = u.id
  and u.status = 'unresolved';

drop table public.carrier_backfill_0137_provenance;

do $rb$
begin
  if (select count(*) from public.factoring_relationships where carrier_id is not null) <> 0 then
    raise exception 'ROLLBACK 0137 postcondition: factoring_relationships.carrier_id is not all-NULL after rollback.';
  end if;
  if to_regclass('public.carrier_backfill_0137_provenance') is not null then
    raise exception 'ROLLBACK 0137 postcondition: carrier_backfill_0137_provenance still exists.';
  end if;
  raise notice 'ROLLBACK 0137 complete: every carrier_id this migration set has been cleared back to NULL; its unresolved_carrier_records rows archived; provenance table dropped. factoring_relationships'' columns (0136) and factored_invoices remain untouched.';
end
$rb$;

commit;
