-- =============================================================================
-- rollback.sql -- EMERGENCY reversal of proposal 0150 (returns the loads to carrier_resolution='unresolved').
-- PROPOSAL 0150 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: applies AFTER 0130..0147 and 0149. Current proposal 0148 is unrelated and MUST be renumbered to 0153 or higher before promotion.
--
-- Acts STRICTLY off public.carrier_backfill_0150_provenance and REFUSES (changing nothing) unless every
-- normalised load is still exactly as 0150 left it: carrier_id NULL, carrier_resolution NULL, carrier_locked_at
-- and financial_dispatch_id NULL, ZERO dispatches; its exception record still archived_legacy with the 0150
-- note and no newer open record for the load. If ANY load has since been claimed by a first dispatch the whole
-- rollback refuses (a claimed load must never be re-blocked): stop dispatching with DISPATCH_WRITES_DISABLED=1
-- instead, or resolve individually. Restores the loads' carrier_resolution, the exception records' status/
-- resolved_*/note, then drops the provenance table. updated_at is not restorable (set_updated_at trigger).
-- Must be rolled back BEFORE ROLLBACK_0133 (which refuses while any provenance load has changed).
-- Single transaction; run once.
-- =============================================================================
begin;

do $mig$
declare v_n integer; v_rows integer; v_list text;
begin
  if to_regclass('public.carrier_backfill_0150_provenance') is null then raise exception 'ROLLBACK 0150: provenance table missing -- nothing to roll back (or already rolled back). STOP.'; end if;
  select count(*) into v_rows from public.carrier_backfill_0150_provenance;

  -- lock in the same deterministic order as the migration
  perform 1 from public.loads l where l.id in (select load_id from public.carrier_backfill_0150_provenance) order by l.id for update;
  perform 1 from public.unresolved_carrier_records u where u.record_type = 'load' and u.record_id in (select load_id from public.carrier_backfill_0150_provenance) order by u.id for update;

  create temp table _rb0150_bad on commit drop as
    select v.load_number, v.load_id,
           concat_ws('; ',
             case when l.id is null then 'load missing' end,
             case when l.id is not null and (l.carrier_id is not null or l.carrier_resolution is not null or l.carrier_locked_at is not null or l.financial_dispatch_id is not null)
                  then 'load changed since 0150 (carrier_id=' || coalesce(l.carrier_id::text, 'NULL') || ', carrier_resolution=' || coalesce(l.carrier_resolution, 'NULL') || ')' end,
             case when exists (select 1 from public.dispatches d where d.load_id = v.load_id) then 'now has dispatch(es)' end,
             case when not exists (select 1 from public.unresolved_carrier_records u where u.id = v.exception_record_id and u.record_type = 'load' and u.record_id = v.load_id
                                      and u.status = v.closed_exception_status and u.resolution_note = v.closed_exception_note) then 'exception record changed since 0150' end,
             case when exists (select 1 from public.unresolved_carrier_records u where u.record_type = 'load' and u.record_id = v.load_id and u.status = 'unresolved') then 'a newer OPEN exception record exists' end) as problem
    from public.carrier_backfill_0150_provenance v
    left join public.loads l on l.id = v.load_id;
  select count(*) into v_n from _rb0150_bad where problem <> '';
  if v_n > 0 then
    select string_agg(load_number || ' [' || problem || ']', E'\n' order by load_number) into v_list from _rb0150_bad where problem <> '';
    raise exception E'ROLLBACK 0150 REFUSED: % of % normalised load(s) changed since 0150 -- nothing was changed:\n%', v_n, v_rows, v_list;
  end if;

  update public.loads l set carrier_resolution = 'unresolved'
   from public.carrier_backfill_0150_provenance v
   where l.id = v.load_id and l.carrier_resolution is null and l.carrier_id is null;
  get diagnostics v_n = row_count;
  if v_n <> v_rows then raise exception 'ROLLBACK 0150: restored % load(s), expected %.', v_n, v_rows; end if;

  update public.unresolved_carrier_records u
     set status = v.prior_exception_status, resolved_by = v.prior_exception_resolved_by,
         resolved_at = v.prior_exception_resolved_at, resolution_note = v.prior_exception_resolution_note
    from public.carrier_backfill_0150_provenance v
   where u.id = v.exception_record_id and u.status = v.closed_exception_status and u.resolution_note = v.closed_exception_note;
  get diagnostics v_n = row_count;
  if v_n <> v_rows then raise exception 'ROLLBACK 0150: restored % exception record(s), expected %.', v_n, v_rows; end if;

  drop table public.carrier_backfill_0150_provenance;

  if exists (select 1 from public.loads l where l.carrier_resolution = 'unresolved' and not exists (select 1 from public.dispatches d where d.load_id = l.id)
               and not exists (select 1 from public.unresolved_carrier_records u where u.record_type = 'load' and u.record_id = l.id and u.status = 'unresolved')) then
    raise exception 'ROLLBACK 0150 postcondition: a restored unresolved load has no open exception record.';
  end if;
  raise notice 'ROLLBACK 0150 complete: % load(s) restored to carrier_resolution=unresolved; exception records reopened; provenance dropped.', v_rows;
end
$mig$;

commit;
