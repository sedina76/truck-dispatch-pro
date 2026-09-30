-- =============================================================================
-- post_apply.sql
-- PROPOSAL 0150 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: applies AFTER 0130..0147 and 0149. Current proposal 0148 is unrelated and MUST be renumbered to 0153 or higher before promotion.
--
-- Run AFTER applying 0150 (and any time later). READ-ONLY: ONE select statement. Every normalised load must
-- be in state A (still pending: carrier_id NULL, carrier_resolution NULL, no dispatch) or state B (claimed
-- since by its first dispatch: carrier_id set, carrier_resolution 'resolved', at least one dispatch, carrier
-- in the load's organization). Anything else fails. RESULT: rows INFO/PASS + a final RESULT | PASS row, or a
-- raised error whose text is the complete report.
-- =============================================================================
with pv as (
  select v.*, l.id as l_id, l.organization_id as l_org, l.carrier_id as l_carrier, l.carrier_resolution as l_res, l.carrier_locked_at as l_locked,
         (select count(*) from public.dispatches d where d.load_id = v.load_id) as n_disp,
         (select c.organization_id from public.carriers c where c.id = l.carrier_id) as carrier_org,
         u.status::text as u_status, u.resolution_note as u_note, u.record_type as u_type, u.record_id as u_rid, u.resolved_by as u_by, u.resolved_at as u_at
  from public.carrier_backfill_0150_provenance v
  left join public.loads l on l.id = v.load_id
  left join public.unresolved_carrier_records u on u.id = v.exception_record_id
),
st as (
  select pv.*,
         case when l_id is null then 'X-load-missing'
              when l_org is distinct from organization_id then 'X-org-changed'
              when l_carrier is null and l_res is null and n_disp = 0 then 'A'
              when l_carrier is not null and l_res = 'resolved' and n_disp > 0 and carrier_org = l_org then 'B'
              else 'X-unexpected-state' end as state
  from pv
),
rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 101, 'SERVER', 'version()', 'INFO', version()::text
  union all
  select 200, 'GUARD', '0132 guard_dispatch_carrier_scope() is the reviewed definition',
         case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_dispatch_carrier_scope()')) = 'f9ae250c3e01e4a6317c6c7fd751586e' then 'PASS' else 'FAIL' end,
         coalesce((select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_dispatch_carrier_scope()')), 'MISSING')
  union all
  select 201, 'GUARD', '0132 guard_load_carrier_change() is the reviewed definition',
         case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_load_carrier_change()')) = 'c6ecf184de849411d32eee8b0cce3a4b' then 'PASS' else 'FAIL' end,
         coalesce((select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_load_carrier_change()')), 'MISSING')
  union all
  select 202, 'GUARD', 'trigger dispatches_guard_carrier_scope present and enabled (BEFORE, row-level, both row-writing events)',
         case when exists (select 1 from pg_trigger t where t.tgrelid = to_regclass('public.dispatches') and t.tgname = 'dispatches_guard_carrier_scope' and not t.tgisinternal
                            and t.tgenabled in ('O','A') and (t.tgtype::int & 1) <> 0 and (t.tgtype::int & 2) <> 0 and (t.tgtype::int & 4) <> 0 and (t.tgtype::int & 16) <> 0
                            and t.tgfoid = to_regprocedure('public.guard_dispatch_carrier_scope()')::oid) then 'PASS' else 'FAIL' end,
         (select count(*) from pg_trigger t where t.tgrelid = to_regclass('public.dispatches') and not t.tgisinternal)::text || ' user triggers on dispatches'
  union all
  select 203, 'GUARD', 'proposal 0149 live: create_dispatch and cancel_dispatch declare the enum-typed c_active',
         case when (select count(*) from pg_proc x where x.oid in (to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'), to_regprocedure('public.cancel_dispatch(uuid,text)'))
                     and regexp_replace(x.prosrc, '\s+', '', 'g') like '%c\_activeconstantpublic.dispatch\_status[]%') = 2 then 'PASS' else 'FAIL' end,
         'live function bodies inspected'
  union all
  select 300, 'PROVENANCE', 'carrier_backfill_0150_provenance exists', case when to_regclass('public.carrier_backfill_0150_provenance') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all
  select 301, 'PROVENANCE', 'provenance rows (loads normalised by 0150)', 'INFO', (select count(*) from pv)::text
  union all
  select 302, 'PROVENANCE', 'approved count / digest recorded', 'INFO',
         coalesce((select min(expected_candidate_count)::text || ' / ' || min(candidate_digest) from pv), 'no rows')
  union all
  select 303, 'PROVENANCE', 'every row records the same count, digest and count = number of rows',
         case when (select count(distinct expected_candidate_count) from pv) <= 1 and (select count(distinct candidate_digest) from pv) <= 1
                   and coalesce((select min(expected_candidate_count) from pv), 0) = (select count(*) from pv) then 'PASS' else 'FAIL' end,
         (select count(*) from pv)::text
  union all
  select 310, 'LOADS', 'still pending (state A: carrier_id NULL, carrier_resolution NULL, no dispatch)', 'INFO', (select count(*) from st where state = 'A')::text
  union all
  select 311, 'LOADS', 'claimed since by their first dispatch (state B)', 'INFO', (select count(*) from st where state = 'B')::text
  union all
  select 312, 'LOADS', 'every normalised load is in state A or B', case when not exists (select 1 from st where state not in ('A','B')) then 'PASS' else 'FAIL' end,
         coalesce((select string_agg(load_number || ':' || state, ', ' order by load_number) from st where state not in ('A','B')), 'none')
  union all
  select 313, 'LOADS', 'no state-A load carries a carrier_locked_at or financial_dispatch_id',
         case when not exists (select 1 from st join public.loads l on l.id = st.load_id where st.state = 'A' and (l.carrier_locked_at is not null or l.financial_dispatch_id is not null)) then 'PASS' else 'FAIL' end, 'loads'
  union all
  select 314, 'LOADS', 'no zero-dispatch load remains carrier_resolution=''unresolved''',
         case when not exists (select 1 from public.loads l where l.carrier_resolution = 'unresolved' and not exists (select 1 from public.dispatches d where d.load_id = l.id)) then 'PASS' else 'FAIL' end,
         (select count(*) from public.loads l where l.carrier_resolution = 'unresolved' and not exists (select 1 from public.dispatches d where d.load_id = l.id))::text
  union all
  select 320, 'EXCEPTIONS', 'every closed exception record is the archived_legacy record with the 0150 note, no resolver, still record_type=load for this load',
         case when not exists (select 1 from pv where u_status is distinct from closed_exception_status::text or u_note is distinct from closed_exception_note
                                or u_type is distinct from 'load' or u_rid is distinct from load_id or u_by is not null or u_at is null) then 'PASS' else 'FAIL' end,
         (select count(*) from pv where u_status is distinct from closed_exception_status::text or u_note is distinct from closed_exception_note or u_type is distinct from 'load' or u_rid is distinct from load_id or u_by is not null or u_at is null)::text || ' inconsistent'
  union all
  select 321, 'EXCEPTIONS', 'no normalised load has an open exception record',
         case when not exists (select 1 from public.unresolved_carrier_records u join pv on pv.load_id = u.record_id where u.record_type = 'load' and u.status = 'unresolved') then 'PASS' else 'FAIL' end, 'unresolved_carrier_records'
  union all
  select 322, 'EXCEPTIONS', 'prior exception state recorded (open, unresolved status, exact 0133 reason)',
         case when not exists (select 1 from pv where prior_exception_status::text <> 'unresolved' or prior_exception_reason <> 'No dispatch on this load; a responsible carrier cannot be determined.'
                                or prior_exception_detail <> jsonb_build_object('rule', 'C4_zero_dispatch', 'dispatches', '[]'::jsonb)) then 'PASS' else 'FAIL' end, 'provenance'
  union all
  select 330, 'LOAD', v.load_number || ' (' || v.load_id::text || ')', 'INFO', 'state ' || v.state || ', organization ' || v.organization_id::text from st v
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass,
         count(*) filter (where result = 'FAIL') as n_fail,
         count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('POST-APPLY 0150 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate   -- a deliberate cast error: raises only when a check fails
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail
from rows r cross join verdict v
where v.gate = 0
union all
select 9000, 'RESULT', 'POST-APPLY 0150: normalised loads and exception records are consistent', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows'
from verdict v
where v.gate = 0
order by 1;
