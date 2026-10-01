-- =============================================================================
-- preflight.sql
-- PROPOSAL 0150 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: applies AFTER 0130..0147 and 0149. Current proposal 0148 is unrelated and MUST be renumbered to 0153 or higher before promotion.
--
-- Run AFTER 0130..0147 and 0149 and BEFORE applying 0150. READ-ONLY: ONE select statement over catalogs and
-- public tables; no data-/schema-changing statement, no transaction control, no temporary object.
-- The evidence counts use query_to_xml() over a catalog-validated, identifier-quoted SELECT count(*).
-- RESULT: every row INFO or PASS and a final RESULT | PASS row; otherwise the statement RAISES
-- (invalid input syntax for type integer: "PREFLIGHT 0150 FAIL ...") whose text is the complete report.
-- To also check your approved count, replace the two marked null literals (same values as in proposed_0150.sql).
-- =============================================================================
with cfg as (
  select null::integer as expected_count,   -- <<< OWNER (optional here): approved candidate count
         null::text as expected_digest  -- <<< OWNER (optional here): approved digest
),
evtab(tbl, col, required) as (values
    ('public.invoices', 'load_id', false),
    ('public.dispatch_advances', 'load_id', false),
    ('public.settlement_line_items', 'load_id', false),
    ('public.driver_settlement_items', 'load_id', false),
    ('public.expenses', 'load_id', false),
    ('public.compliance_overrides', 'load_id', false),
    ('public.dispatch_resource_reassignments', 'load_id', false),
    ('public.carrier_invoice_loads', 'load_id', true),
    ('public.carrier_invoice_line_items', 'source_load_id', true),
    ('public.carrier_dispatch_service_billing_lines', 'load_id', true)
),
evlive as (
  select e.tbl, e.col, e.required, to_regclass(e.tbl) as rel,
         exists (select 1 from pg_attribute a where a.attrelid = to_regclass(e.tbl) and a.attname = e.col and not a.attisdropped) as has_col
  from evtab e
),
pool as (   -- every load 0133 left 'unresolved' that has NO dispatch of ANY status (cancelled included)
  select l.id as load_id, l.organization_id, l.load_number::text as load_number, l.status::text as load_status,
         l.carrier_id, l.carrier_locked_at, l.financial_dispatch_id
  from public.loads l
  where l.carrier_resolution = 'unresolved'
    and not exists (select 1 from public.dispatches d where d.load_id = l.id)
),
evn as (    -- carrier/financial evidence rows per pool load and evidence table (count(*) via a catalog-validated, identifier-quoted query)
  select p.load_id, e.tbl,
         case when e.rel is null or not e.has_col then 0
              else ((xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %s where %I = %L', e.rel, e.col, p.load_id), false, true, '')))[1])::text::integer
         end as n
  from pool p cross join evlive e
),
ex as (     -- the 0133 exception records for each pool load
  select p.load_id,
         (select count(*) from public.unresolved_carrier_records u where u.record_type = 'load' and u.record_id = p.load_id) as n_exc_all,
         (select count(*) from public.unresolved_carrier_records u
           where u.record_type = 'load' and u.record_id = p.load_id and u.status = 'unresolved'
             and u.organization_id = p.organization_id
             and u.reason = 'No dispatch on this load; a responsible carrier cannot be determined.'
             and u.detail = jsonb_build_object('rule', 'C4_zero_dispatch', 'dispatches', '[]'::jsonb)
             and u.resolved_by is null and u.resolved_at is null and u.resolution_note is null) as n_exc_exact,
         (select u.id from public.unresolved_carrier_records u
           where u.record_type = 'load' and u.record_id = p.load_id and u.status = 'unresolved'
             and u.organization_id = p.organization_id
             and u.reason = 'No dispatch on this load; a responsible carrier cannot be determined.'
             and u.detail = jsonb_build_object('rule', 'C4_zero_dispatch', 'dispatches', '[]'::jsonb)
             and u.resolved_by is null and u.resolved_at is null and u.resolution_note is null
           order by u.id limit 1) as exc_id
  from pool p
),
cls as (
  select p.*, x.n_exc_all, x.n_exc_exact, x.exc_id,
         (select count(*) from public.carrier_backfill_0133_provenance v where v.load_id = p.load_id) as n_pv,
         (select count(*) from public.carrier_backfill_0133_provenance v
           where v.load_id = p.load_id and v.organization_id = p.organization_id and v.carrier_id is null
             and v.carrier_resolution = 'unresolved' and v.carrier_locked_at is null
             and v.unresolved_carrier_record_id is not distinct from x.exc_id and x.exc_id is not null) as n_pv_exact,
         (select coalesce(sum(n.n), 0) from evn n where n.load_id = p.load_id)::integer as n_evidence,
         (select string_agg(n.tbl || '=' || n.n::text, ', ' order by n.tbl) from evn n where n.load_id = p.load_id and n.n > 0) as evidence_detail,
         exists (select 1 from public.organizations o where o.id = p.organization_id) as org_ok
  from pool p join ex x using (load_id)
),
verdict_rows as (
  select c.*,
         concat_ws('; ',
           case when c.carrier_id is not null then 'carrier_id is set' end,
           case when c.carrier_locked_at is not null then 'carrier_locked_at is set' end,
           case when c.financial_dispatch_id is not null then 'financial_dispatch_id is set' end,
           case when c.n_evidence > 0 then 'carrier/financial evidence: ' || coalesce(c.evidence_detail, '?') end,
           case when c.n_exc_all <> 1 then c.n_exc_all::text || ' exception record(s) for this load (expected exactly 1)' end,
           case when c.n_exc_all = 1 and c.n_exc_exact <> 1 then 'the exception record is not the exact open 0133 C4_zero_dispatch record' end,
           case when c.n_pv_exact <> 1 then '0133 provenance row missing or inconsistent (rows=' || c.n_pv::text || ')' end,
           case when not c.org_ok then 'organization missing' end) as problems
  from cls c
),
agg as (
  select count(*) as n_pool, count(*) filter (where problems = '') as n_cand, count(*) filter (where problems <> '') as n_bad,
         md5(coalesce(string_agg(load_id::text, ',' order by load_id) filter (where problems = ''), '')) as digest
  from verdict_rows
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
  select 300, '0133', 'carrier_backfill_0133_provenance and unresolved_carrier_records exist (0133 applied)',
         case when to_regclass('public.carrier_backfill_0133_provenance') is not null and to_regclass('public.unresolved_carrier_records') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all
  select 301, '0133', 'unresolved_record_status has the ''archived_legacy'' label',
         case when exists (select 1 from pg_enum e where e.enumtypid = to_regtype('public.unresolved_record_status') and e.enumlabel = 'archived_legacy') then 'PASS' else 'FAIL' end,
         coalesce((select string_agg(e.enumlabel::text, ',' order by e.enumsortorder) from pg_enum e where e.enumtypid = to_regtype('public.unresolved_record_status')), 'MISSING')
  union all
  select 302, '0132', 'loads_carrier_resolution_values permits NULL',
         case when exists (select 1 from pg_constraint where conrelid = to_regclass('public.loads') and conname = 'loads_carrier_resolution_values' and pg_get_constraintdef(oid) ilike '%carrier_resolution IS NULL%') then 'PASS' else 'FAIL' end,
         coalesce((select pg_get_constraintdef(oid) from pg_constraint where conrelid = to_regclass('public.loads') and conname = 'loads_carrier_resolution_values'), 'MISSING')
  union all
  select 303, '0150', '0150 not already applied (carrier_backfill_0150_provenance absent)',
         case when to_regclass('public.carrier_backfill_0150_provenance') is null then 'PASS' else 'FAIL' end, 'catalog'
  union all
  select 304, '0142-0145', 'required carrier-evidence tables exist (' || array_to_string(array['public.carrier_invoice_loads', 'public.carrier_invoice_line_items', 'public.carrier_dispatch_service_billing_lines']::text[], ', ') || ')',
         case when (select count(*) from evlive where required and rel is not null and has_col) = 3 then 'PASS' else 'FAIL' end,
         (select count(*) from evlive where rel is not null and has_col)::text || ' of ' || (select count(*) from evlive)::text || ' evidence tables present (absent tables contribute zero rows)'
  union all
  select 310, 'POOL', 'zero-dispatch loads currently carrier_resolution=''unresolved''', 'INFO', (select n_pool from agg)::text
  union all
  select 311, 'POOL', 'candidates (every condition met)', 'INFO', (select n_cand from agg)::text
  union all
  select 312, 'POOL', 'contradictory / unexpected evidence among the pool (must be 0)', case when (select n_bad from agg) = 0 then 'PASS' else 'FAIL' end, (select n_bad from agg)::text
  union all
  select 313, 'POOL', 'candidate digest', 'INFO', (select digest from agg)
  union all
  select 314, 'POOL', 'approved expected count (if supplied) equals the candidate count',
         case when (select expected_count from cfg) is null then 'INFO' when (select expected_count from cfg) = (select n_cand from agg) then 'PASS' else 'FAIL' end,
         coalesce((select expected_count from cfg)::text, 'not supplied to this verifier') || ' vs ' || (select n_cand from agg)::text
  union all
  select 315, 'POOL', 'approved expected digest (if supplied) equals the candidate digest',
         case when (select expected_digest from cfg) is null then 'INFO' when (select expected_digest from cfg) = (select digest from agg) then 'PASS' else 'FAIL' end,
         coalesce((select expected_digest from cfg), 'not supplied to this verifier')
  union all
  select 320, 'POOL', 'problem: ' || v.load_number || ' (' || v.load_id::text || ')', 'FAIL', v.problems from verdict_rows v where v.problems <> ''
  union all
  select 330, 'CONTEXT', 'unresolved loads that HAVE dispatches (left untouched by 0150)', 'INFO',
         (select count(*) from public.loads l where l.carrier_resolution = 'unresolved' and exists (select 1 from public.dispatches d where d.load_id = l.id))::text
  union all
  select 331, 'CONTEXT', 'loads with NULL carrier_resolution', 'INFO', (select count(*) from public.loads where carrier_resolution is null)::text
  union all
  select 332, 'CONTEXT', 'user triggers on public.loads (side effects of the 0150 write)', 'INFO',
         coalesce((select string_agg(t.tgname::text, ', ' order by t.tgname) from pg_trigger t where t.tgrelid = to_regclass('public.loads') and not t.tgisinternal), '(none)')
),
verdict as (
  select count(*) filter (where result = 'PASS') as n_pass,
         count(*) filter (where result = 'FAIL') as n_fail,
         count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ('PREFLIGHT 0150 FAIL: ' || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\n' order by ord))::int
         end as gate   -- a deliberate cast error: raises only when a check fails
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail
from rows r cross join verdict v
where v.gate = 0
union all
select 9000, 'RESULT', 'PREFLIGHT 0150: candidates are exactly the zero-evidence legacy unresolved loads', 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows'
from verdict v
where v.gate = 0
order by 1;
