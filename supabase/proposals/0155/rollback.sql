-- rollback.sql -- EMERGENCY removal of proposal 0155's objects
-- PROPOSAL 0155 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0152 -> 0154 -> 0155 (this) -> 0156; unrelated 0148 -> 0153 or 0157+ (never 0154-0156). Finding F-01.
-- REFUSES (nothing changed) if ANY owner/admin decision has been recorded (assigned / confirmed / retired: those decisions changed carriers or closed exception records and cannot be silently undone) or if
-- proposal 0156 (which depends on the evidence functions) is applied. Otherwise drops only the 0155 objects. Exception records opened by 0155 are RETAINED (exception history is never deleted).
begin;
set local lock_timeout = '15s';
do $mig$
begin
  if to_regclass('public.carrier_inference_review_0155') is null then raise exception 'ROLLBACK 0155 REFUSED: review table missing (0155 not applied or already rolled back). Nothing changed.'; end if;
  if exists (select 1 from public.carrier_inference_review_0155 where decision_status in ('assigned', 'confirmed', 'retired')) then raise exception 'ROLLBACK 0155 REFUSED: owner/admin decisions have been recorded -- they changed carriers/exception records. Nothing changed.'; end if;
  if to_regclass('public.factoring_submission_gate') is not null then raise exception 'ROLLBACK 0155 REFUSED: proposal 0156 is applied and depends on the evidence functions -- roll back 0156 first. Nothing changed.'; end if;
end
$mig$;
drop function public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid);
drop function public._carrier_inference_apply_0155(text);
drop function public.carrier_evidence_for_relationship(uuid);
drop function public.carrier_evidence_for_invoice(uuid);
drop table public.carrier_inference_review_0155;
drop table public.carrier_inference_run_0155;
do $mig$
begin
  if to_regclass('public.carrier_inference_review_0155') is not null or to_regclass('public.carrier_inference_run_0155') is not null or to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is not null then raise exception 'ROLLBACK 0155 postcondition: objects remain.'; end if;
  raise notice 'ROLLBACK 0155 complete: the 0155 objects are removed; no carrier assignment was ever changed by 0155 itself; exception records it opened are retained.';
end
$mig$;
commit;
