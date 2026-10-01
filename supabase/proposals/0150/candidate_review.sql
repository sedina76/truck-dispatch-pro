-- =============================================================================
-- candidate_review.sql -- owner review of exactly which loads 0150 would change.
-- PROPOSAL 0150 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: applies AFTER 0130..0147 and 0149. Current proposal 0148 is unrelated and MUST be renumbered to 0153 or higher before promotion.
--
-- READ-ONLY: ONE select statement; changes nothing and never fails on findings (it REPORTS). Run after
-- 0133 (and 0147/0149), before applying 0150. It lists every zero-dispatch load that 0133 left 'unresolved':
--   disposition CANDIDATE -> 0150 would return it to pending carrier assignment (carrier_resolution NULL)
--   disposition BLOCKED   -> contradictory/unexpected evidence; 0150 would ABORT until it is resolved
-- Shown per load: load number, organization (id + name), load status, age, evidence counts, exception id.
-- Customer/broker names, rates and addresses are deliberately NOT selected.
-- The SUMMARY rows give the count and digest to paste into proposed_0150.sql.
-- =============================================================================
with
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
)
select 0 as ord, 'SUMMARY' as section, 'zero-dispatch loads left unresolved by 0133' as item, (select n_pool from agg)::text as value, null::text as detail
union all select 1, 'SUMMARY', 'CANDIDATES (approve this count)', (select n_cand from agg)::text, 'paste into v_expected_count in proposed_0150.sql'
union all select 2, 'SUMMARY', 'BLOCKED (contradictory evidence; 0150 aborts while > 0)', (select n_bad from agg)::text, null
union all select 3, 'SUMMARY', 'candidate digest (REQUIRED: paste into v_expected_digest)', (select digest from agg), 'md5 of the candidate load ids, sorted'
union all select 4, 'SUMMARY', 'unresolved loads WITH dispatches (never touched by 0150)',
       (select count(*) from public.loads l where l.carrier_resolution = 'unresolved' and exists (select 1 from public.dispatches d where d.load_id = l.id))::text, 'these still need a human decision'
union all
select 10 + row_number() over (order by v.load_number, v.load_id)::int, case when v.problems = '' then 'CANDIDATE' else 'BLOCKED' end,
       v.load_number || '  [' || v.load_id::text || ']',
       'org ' || coalesce((select o.name::text from public.organizations o where o.id = v.organization_id), '?') || ' [' || v.organization_id::text || '] | load status ' || v.load_status
         || ' | org carriers ' || (select count(*) from public.carriers c where c.organization_id = v.organization_id)::text,
       case when v.problems = '' then 'exception ' || v.exc_id::text || ' opened ' || coalesce((select u.created_at::date::text from public.unresolved_carrier_records u where u.id = v.exc_id), '?')
                                  || ' | no dispatch, no carrier/financial evidence | first dispatch will choose the carrier'
            else 'PROBLEM: ' || v.problems end
from verdict_rows v
order by 1;
