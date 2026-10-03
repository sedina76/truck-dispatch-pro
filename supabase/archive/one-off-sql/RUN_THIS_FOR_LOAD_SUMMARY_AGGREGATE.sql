-- ---------------------------------------------------------------------------
-- get_load_summary: replaces loads/page.tsx's in-memory sum of an
-- unpaginated select("rate") result (correct today at a handful of rows,
-- but silently wrong past PostgREST's default row cap once the table
-- grows) with a real SUM(rate) computed in Postgres.
--
-- Deliberately NOT security definer: it runs with the caller's own
-- privileges, so the existing RLS policy on public.loads
-- (organization_id = current_org_id()) applies exactly as it would to any
-- other query against the table -- this function does not, and cannot,
-- see another organization's loads. No new privilege is being granted here,
-- just a server-side aggregate over rows the caller could already read.
-- ---------------------------------------------------------------------------
create or replace function public.get_load_summary(p_search text default null)
returns table (total_loads bigint, total_rate_value numeric)
language sql
stable
as $$
  select
    count(*)::bigint,
    coalesce(sum(rate), 0)::numeric
  from public.loads
  where p_search is null or load_number ilike '%' || p_search || '%';
$$;

grant execute on function public.get_load_summary(text) to authenticated;
