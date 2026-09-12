-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0133_deterministic_carrier_backfill.sql  ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse the 0133        ##
-- ##  backfill. APPLY AS ONE TRANSACTION.                                   ##
-- ##                                                                        ##
-- ##  PROVENANCE-BASED, NOT BLANKET. This script reverses ONLY the exact    ##
-- ##  (load_id, carrier_id, carrier_resolution, carrier_locked_at) values   ##
-- ##  migration 0133 itself wrote, as recorded in the permanent             ##
-- ##  public.carrier_backfill_0133_provenance table 0133 created.           ##
-- ##                                                                        ##
-- ##  0132->0133 RACE SAFETY: 0133 deliberately EXCLUDES any load whose     ##
-- ##  carrier_id was already non-NULL before it ran (a pre-existing         ##
-- ##  assignment made by anything else between 0132 and 0133) from          ##
-- ##  provenance. Because this script's classification and clearing UPDATE  ##
-- ##  both operate STRICTLY off provenance rows, a pre-existing assignment  ##
-- ##  has NO row to match and is therefore STRUCTURALLY UNREACHABLE by this ##
-- ##  rollback -- no special-case code is needed here to protect it.        ##
-- ##                                                                        ##
-- ##  A row is reversed ONLY when ALL of the following hold:                ##
-- ##    1. the load's CURRENT carrier_id / carrier_resolution /            ##
-- ##       carrier_locked_at are byte-identical to what 0133 recorded       ##
-- ##       (nothing -- manual correction, a later assignment RPC, anything  ##
-- ##       -- has touched it since)                                        ##
-- ##    2. NO dispatch for that load was created after 0133's applied_at    ##
-- ##       (no new dependent activity has been built on top of the value)   ##
-- ##    3. for an unresolved load, its exception row is STILL open,         ##
-- ##       untouched (status='unresolved', no resolved_at/resolution_note)  ##
-- ##       -- i.e. nobody has manually resolved it since                    ##
-- ##                                                                        ##
-- ##  FAIL CLOSED: if ANY provenance row fails that test, this script       ##
-- ##  prints the exact counts and up to 20 sample load_ids and ABORTS THE   ##
-- ##  ENTIRE ROLLBACK with ZERO writes. It never partially reverses.        ##
-- ##                                                                        ##
-- ##  Run ONLY if the app is not yet live on multi-carrier loads and no     ##
-- ##  manual exception-resolution work has begun. Leaves 0130/0131/0132     ##
-- ##  structures in place; only 0133's own writes (+ its provenance table)  ##
-- ##  are removed.                                                          ##
-- ##                                                                        ##
-- ##  TRIGGER SAFETY: the 0132 guard_load_carrier_change trigger            ##
-- ##  deliberately REJECTS clearing an already-assigned loads.carrier_id    ##
-- ##  (that is the whole point of the guard). This script disables that ONE ##
-- ##  trigger for the single clearing UPDATE below and re-enables it        ##
-- ##  immediately after, inside the SAME transaction -- and ONLY after the  ##
-- ##  fail-closed classification above has already passed with zero        ##
-- ##  writes. `ALTER TABLE ... DISABLE/ENABLE TRIGGER` is ordinary          ##
-- ##  transactional DDL: if anything between the DISABLE and the ENABLE     ##
-- ##  raises, PostgreSQL rolls the disable back too -- the trigger can      ##
-- ##  never be left disabled by a failed run of this script. Demonstrated   ##
-- ##  in TEST_0133_ROLLBACK_TRIGGER_SAFETY.sql. Requires table-owner        ##
-- ##  privileges.                                                          ##
-- ############################################################################

begin;

-- --- Guard 0: this exact provenance-tracking version of 0133 was applied ---
do $rb$
begin
  if to_regclass('public.carrier_backfill_0133_provenance') is null then
    raise exception 'ROLLBACK 0133: public.carrier_backfill_0133_provenance is missing. Either 0133 was never applied, or it was applied by an older pre-provenance version of this migration that cannot be safely auto-reversed by this script. STOP -- resolve manually.';
  end if;
end
$rb$;

-- --- Classification: SAFE (identical to what 0133 wrote, no activity since)
-- vs UNSAFE (anything has changed). Read-only; writes nothing yet.
create temp table _rb0133_classification on commit drop as
select
  pv.load_id, pv.organization_id, pv.applied_at,
  pv.carrier_id                as prov_carrier_id,
  pv.carrier_resolution        as prov_resolution,
  pv.carrier_locked_at         as prov_locked_at,
  pv.unresolved_carrier_record_id,
  l.carrier_id                 as cur_carrier_id,
  l.carrier_resolution         as cur_resolution,
  l.carrier_locked_at          as cur_locked_at,
  (select count(*) from public.dispatches d
     where d.load_id = pv.load_id and d.created_at > pv.applied_at)         as n_new_dispatches,
  (case when pv.unresolved_carrier_record_id is not null then
     coalesce((select u.status is distinct from 'unresolved'
                      or u.resolved_at is not null
                      or u.resolution_note is not null
               from public.unresolved_carrier_records u
               where u.id = pv.unresolved_carrier_record_id), true)  -- exception row itself gone -> treat as worked/unsafe
   else false end)                                                          as exception_worked_or_missing,
  (
       l.carrier_id         is distinct from pv.carrier_id
    or l.carrier_resolution is distinct from pv.carrier_resolution
    or l.carrier_locked_at  is distinct from pv.carrier_locked_at
    or (select count(*) from public.dispatches d
          where d.load_id = pv.load_id and d.created_at > pv.applied_at) > 0
    or (pv.unresolved_carrier_record_id is not null and coalesce(
          (select u.status is distinct from 'unresolved'
                  or u.resolved_at is not null
                  or u.resolution_note is not null
           from public.unresolved_carrier_records u
           where u.id = pv.unresolved_carrier_record_id), true))
  )                                                                          as is_unsafe
from public.carrier_backfill_0133_provenance pv
join public.loads l on l.id = pv.load_id;

-- --- Report counts + samples BEFORE any write; abort on any unsafe row ---
do $rb$
declare
  v_total  integer;
  v_unsafe integer;
  v_safe   integer;
  v_sample text;
begin
  select count(*) into v_total  from _rb0133_classification;
  select count(*) into v_unsafe from _rb0133_classification where is_unsafe;
  v_safe := v_total - v_unsafe;

  raise notice 'ROLLBACK 0133 classification: % provenance row(s) total -- % SAFE to reverse, % UNSAFE (modified since 0133 ran).',
    v_total, v_safe, v_unsafe;

  if v_unsafe > 0 then
    select string_agg(
      format('load %s: carrier %s->%s, resolution %s->%s, locked_at %s->%s, new_dispatches_since=%s, exception_worked_or_missing=%s',
             load_id, prov_carrier_id, cur_carrier_id, prov_resolution, cur_resolution,
             prov_locked_at, cur_locked_at, n_new_dispatches, exception_worked_or_missing),
      E'\n' order by load_id)
    into v_sample
    from (select * from _rb0133_classification where is_unsafe order by load_id limit 20) s;

    raise exception E'ROLLBACK 0133 ABORTED -- % of % load(s) have changed since migration 0133 ran (a value no longer matches what 0133 wrote, a NEW dispatch was created after the backfill, or the load''s exception row has been manually resolved). Reversing would destroy legitimate post-backfill state. THE ENTIRE ROLLBACK IS REFUSED -- ZERO WRITES PERFORMED. Investigate and resolve these specific loads manually; do not re-run this script until it reports 0 unsafe rows. Sample (up to 20):\n%',
      v_unsafe, v_total, v_sample
      using errcode = '55000';
  end if;

  raise notice 'ROLLBACK 0133: all % provenance row(s) are SAFE. Proceeding.', v_total;
end
$rb$;

-- --- Reached only when EVERY provenance row is SAFE (0 unsafe). ---------
-- 1. clear exactly the loads this migration set, and nothing else. The 0132
-- guard intentionally rejects clearing an already-assigned carrier_id, so
-- this ONE statement runs with it disabled and re-enables it immediately
-- after, in the same transaction (see the TRIGGER SAFETY note above).
alter table public.loads disable trigger loads_guard_carrier_change;

update public.loads l
set carrier_id = null,
    carrier_resolution = null,
    carrier_locked_at = null
from _rb0133_classification c
where l.id = c.load_id;

alter table public.loads enable trigger loads_guard_carrier_change;

-- 2. remove exactly the OPEN load exception rows 0133 created (and only
-- those still open -- a worked one would already have failed the safety
-- gate above and this script would not have reached here).
delete from public.unresolved_carrier_records u
using _rb0133_classification c
where u.id = c.unresolved_carrier_record_id
  and u.status = 'unresolved';

-- 3. the provenance table itself has now been fully consumed -- drop it so
-- a future re-apply of 0133 can recreate and repopulate it from scratch
-- (0133's own PHASE 0 requires it to be ABSENT).
drop table public.carrier_backfill_0133_provenance;

-- 4. restore the 0132 comment on loads.carrier_id
comment on column public.loads.carrier_id is
  'The single responsible carrier for this load. Set for new loads by the load-creation RPC (later slice); legacy loads backfilled deterministically by migration 0133 (financial_dispatch_id -> dispatch carrier, else unambiguous dispatch carrier, else NULL + unresolved_carrier_records). Once set, immutable while the load has dispatches / financial activity -- see guard_load_carrier_change().';

do $rb$
begin
  if exists (select 1 from public.loads l join _rb0133_classification c on c.load_id = l.id
             where l.carrier_id is not null or l.carrier_resolution is not null or l.carrier_locked_at is not null) then
    raise exception 'ROLLBACK 0133 incomplete -- a reversed load still has carrier_id/carrier_resolution/carrier_locked_at set.';
  end if;
  if exists (select 1 from public.unresolved_carrier_records u join _rb0133_classification c
               on c.unresolved_carrier_record_id = u.id) then
    raise exception 'ROLLBACK 0133 incomplete -- a load exception row this rollback should have removed still exists.';
  end if;
  if to_regclass('public.carrier_backfill_0133_provenance') is not null then
    raise exception 'ROLLBACK 0133 incomplete -- carrier_backfill_0133_provenance still exists.';
  end if;
  raise notice 'ROLLBACK 0133 complete: % load(s) reversed to carrier_id/carrier_resolution/carrier_locked_at = NULL; their exception rows removed; provenance table dropped. % load(s) with a pre-existing (non-0133) carrier_id, if any, were structurally untouched (they were never in provenance). 0130/0131/0132 structures left intact. Re-apply 0133 to redo the backfill.',
    (select count(*) from _rb0133_classification),
    (select count(*) from public.loads where carrier_id is not null);
end
$rb$;

commit;
