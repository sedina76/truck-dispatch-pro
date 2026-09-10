-- P1 Load-Rate Integrity Investigation -- Phase A. Entirely read-only.
--
-- SCHEMA-DRIFT CORRECTION: the first version of this file assumed
-- public.loads still carried a `rate` column mirrored into
-- load_financials.rate by a trigger (mirror_load_financials(), 0067) --
-- that description was only ever accurate for the TRANSITIONAL period
-- between 0067 and 0068/0069. Live execution failed with
-- "column l.rate does not exist", proving 0069_financial_column_removal.sql
-- (which drops public.loads.rate/detention_rate/layover_rate) is applied
-- in this production database. Queries below are corrected to match: no
-- query references loads.rate anywhere. Query 0 (new) introspects the
-- live schema directly rather than assuming it, so any FUTURE drift is
-- caught explicitly instead of silently producing a wrong query again.

-- ---------------------------------------------------------------------------
-- 0. Schema-drift introspection -- run this block FIRST, always, before
--    trusting any query below. If loads_rate_column_exists is ever true
--    again, or load_financials_writers/rate_mirror_trigger_exists show
--    something unexpected, STOP and re-derive the rest of this file rather
--    than assume it still matches production.
-- ---------------------------------------------------------------------------
select
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'loads' and column_name = 'rate') as loads_rate_column_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'load_financials' and column_name = 'rate') as load_financials_rate_column_exists,
  exists (select 1 from pg_proc where proname = 'mirror_load_financials' and pronamespace = 'public'::regnamespace) as mirror_load_financials_function_exists,
  exists (select 1 from pg_trigger where tgname = 'loads_mirror_financials') as rate_mirror_trigger_exists;
-- expected on current (post-0069) production: false, true, false, false.
-- If loads_rate_column_exists is true, this database predates 0069 and
-- EVERY query in this file needs re-deriving against that older schema
-- instead -- do not proceed on the assumption below.

-- Enumerate every trigger actually attached to public.loads and
-- public.load_financials right now, rather than assuming from migration
-- history which ones survived. This is the authoritative answer to "is
-- there still a DB-level writer/mirror for this value."
select tgname, tgrelid::regclass as table_name, tgenabled
from pg_trigger
where tgrelid in ('public.loads'::regclass, 'public.load_financials'::regclass) and not tgisinternal;
-- expected: 0 rows for load_financials (no trigger writes it); whatever
-- unrelated triggers remain on loads (status/updated_at, etc.) for loads.

-- Confirm the two known application-code writers still exist and inspect
-- their current live bodies directly -- do not trust the static source
-- tree's description of them without cross-checking against what's
-- actually deployed to the database for the RPC (create_load_with_stops
-- is a database function; writeLoadFinancials()/loads/actions.ts is
-- application code and has no live-database equivalent to introspect).
select pg_get_functiondef(oid) like '%insert into public.load_financials%' as inserts_load_financials_directly
from pg_proc where proname = 'create_load_with_stops' and pronamespace = 'public'::regnamespace;
-- expected: true

-- ---------------------------------------------------------------------------
-- 1. Full organization-scoped inventory (Section A.5's exact requested
--    columns) -- every load, its stored rate (load_financials.rate is now
--    the ONLY source; there is no second loads.rate column to compare
--    against or to disagree with), its existing invoice (if any), its
--    most recent rate-confirmation document's metadata, and a
--    non-zero-cents flag. Ordered so non-round-cents loads surface first,
--    but see query 4 before treating that ordering as a corruption list.
-- ---------------------------------------------------------------------------
select
  o.name as organization_name,
  l.organization_id,
  l.id as load_id,
  l.load_number,
  l.status as load_status,
  case when l.broker_id is not null then 'broker' when l.customer_id is not null then 'customer' else 'none' end as party_type,
  coalesce(b.company_name, c.company_name) as billing_party_name,
  lf.rate as load_financials_rate,
  (lf.load_id is null) as missing_load_financials_row,
  i.id as invoice_id,
  i.invoice_number,
  i.status as invoice_status,
  i.total_amount as invoice_total_amount,
  rc.id as rate_confirmation_document_id,
  rc.file_name as rate_confirmation_file_name,
  rc.created_at as rate_confirmation_uploaded_at,
  l.rate_confirmation_number,
  l.created_at as load_created_at,
  l.updated_at as load_updated_at,
  (lf.rate is not null and round(lf.rate * 100)::bigint % 100 <> 0) as has_nonzero_cents
from public.loads l
join public.organizations o on o.id = l.organization_id
left join public.brokers b on b.id = l.broker_id
left join public.customers c on c.id = l.customer_id
left join public.load_financials lf on lf.load_id = l.id
left join public.invoices i on i.load_id = l.id
left join lateral (
  select d.id, d.file_name, d.created_at
  from public.documents d
  where d.entity_type = 'load' and d.entity_id = l.id and d.document_type = 'rate_confirmation'
  order by d.created_at desc
  limit 1
) rc on true
order by has_nonzero_cents desc, o.name, l.load_number;

-- ---------------------------------------------------------------------------
-- 2. 1:1 coverage check (replaces the invalid loads.rate-vs-load_financials
--    comparison this file previously ran). Without a mirror trigger, the
--    ONLY thing guaranteeing every load has exactly one load_financials
--    row is application-code discipline at exactly two call sites
--    (writeLoadFinancials() in loads/actions.ts, and
--    create_load_with_stops()'s own direct insert) -- there is no
--    database-level backstop anymore. A load with zero or more than one
--    load_financials row is the real analogous integrity question now.
-- ---------------------------------------------------------------------------
select l.id as load_id, l.load_number, l.organization_id, count(lf.load_id) as load_financials_row_count
from public.loads l
left join public.load_financials lf on lf.load_id = l.id
group by l.id, l.load_number, l.organization_id
having count(lf.load_id) <> 1
order by load_financials_row_count desc;
-- expect: 0 rows (load_financials.load_id is PRIMARY KEY, so >1 is
-- actually impossible at the schema level -- this can only ever surface
-- the "0" case: a load with no load_financials row at all, e.g. one
-- created through a path other than the two known writers).

-- ---------------------------------------------------------------------------
-- 3. Cents-value histogram: if many DIFFERENT loads across the
--    organization independently show non-round cents, that is consistent
--    with real freight (mileage-rate math, fuel surcharges, negotiated
--    figures) -- normal, not corruption. If many loads cluster on the
--    SAME unusual cent value (e.g. many loads all ending in .41, or all
--    off from a round number by the same fixed amount), that is the
--    pattern an actual systemic bug (a fixed subtraction/fee applied
--    somewhere) would produce -- investigate that specific shared value's
--    origin, don't assume from this list alone.
-- ---------------------------------------------------------------------------
select
  round((lf.rate - floor(lf.rate)) * 100)::int as cents,
  count(*) as load_count,
  array_agg(l.load_number order by l.load_number) as load_numbers
from public.loads l
join public.load_financials lf on lf.load_id = l.id
where round(lf.rate * 100)::bigint % 100 <> 0
group by 1
order by load_count desc;

-- ---------------------------------------------------------------------------
-- 4. LD-10033 specifically, full detail, including every activity_log
--    entry ever recorded against it (created/updated) to help establish
--    when its stored rate last changed and by whom -- narrows "earliest
--    common code path or timestamp" (Section A.8) for this one load
--    without guessing.
-- ---------------------------------------------------------------------------
select l.id, l.organization_id, l.load_number, l.status, l.broker_id, l.customer_id, l.rate_confirmation_number,
  l.created_at, l.updated_at, lf.rate as load_financials_rate
from public.loads l
left join public.load_financials lf on lf.load_id = l.id
where l.load_number = 'LD-10033';

select * from public.activity_logs
where entity_type = 'load' and entity_id = (select id from public.loads where load_number = 'LD-10033')
order by created_at;

-- ---------------------------------------------------------------------------
-- 5. Any OTHER load sharing LD-10033's exact cents value (.41) -- a
--    cross-check specific to the example given, complementing query 3's
--    general histogram.
-- ---------------------------------------------------------------------------
select l.load_number, l.organization_id, lf.rate
from public.loads l
join public.load_financials lf on lf.load_id = l.id
where round((lf.rate - floor(lf.rate)) * 100)::int = 41
order by l.organization_id, l.load_number;
