-- =============================================================================
-- 0070_post_0069_dependency_repairs.sql
-- Phase 2G.13: repairs the two live SQL functions the Phase 2G post-0069
-- verification found still referencing columns 0069 dropped. Both were
-- defined once (0021, 0033) and never touched by any of the 0067/0068/0069
-- financial-isolation work, since neither is one of the four reporting
-- RPCs that work targeted -- confirmed live broken (42703) this phase,
-- with a real disposable settlement used to prove
-- approve_carrier_settlement() specifically, not just inferred from
-- source. PROPOSED ONLY -- NOT APPLIED.
--
-- SCOPE: exactly these two functions' bodies. Both keep their EXACT
-- existing signature (same input types, same return shape) -- confirmed
-- by comparing against the live/latest definitions before writing this
-- file, so both are a plain `create or replace`, no `drop function`
-- needed and no risk of the 42P13 return-type-change failure 0068 hit
-- live earlier in this project. Every other rule, validation, and side
-- effect in both functions is reproduced verbatim; only the column SOURCE
-- changes.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- get_load_summary() (0021_load_summary_aggregate.sql): sum(rate) read
-- from `loads` directly, which no longer has a `rate` column at all.
-- load_financials is the sole authoritative source (0067/0068 cutover).
-- Signature unchanged: same single p_search text default null input,
-- same returns table (total_loads bigint, total_rate_value numeric).
-- Still deliberately NOT security definer -- same reasoning as the
-- original: it must run with the caller's own privileges so
-- public.loads' RLS (organization_id = current_org_id()) applies exactly
-- as it would to any other query, and the added load_financials join
-- carries the identical RLS scoping (organization_id = current_org_id()),
-- so this still cannot see another organization's loads or rates.
-- ---------------------------------------------------------------------------
create or replace function public.get_load_summary(p_search text default null)
returns table (total_loads bigint, total_rate_value numeric)
language sql
stable
as $$
  select
    count(*)::bigint,
    coalesce(sum(lf.rate), 0)::numeric
  from public.loads l
  join public.load_financials lf on lf.load_id = l.id
  where p_search is null or l.load_number ilike '%' || p_search || '%';
$$;

grant execute on function public.get_load_summary(text) to authenticated;

-- ---------------------------------------------------------------------------
-- approve_carrier_settlement() (0033_carrier_settlements.sql): the
-- `select legal_name, factoring_company_name into ... from public.carriers`
-- line read factoring_company_name from a column that no longer exists.
-- carrier_financials is the sole authoritative source for it now (2G.10
-- writer cutover, 0069 dropped the old column). legal_name (operational
-- carrier identity, never part of this financial-isolation work) stays
-- read from `carriers` unchanged. Signature unchanged: same single
-- p_settlement_id uuid input, still returns void, still security invoker.
-- Every status-transition rule, the line-item-count validation, the
-- settlement lock (`for update`), and the exact payee_name precedence
-- (factor name when payee_type = 'factor', else carrier name) are
-- reproduced verbatim -- only the two source selects for v_carrier_name/
-- v_factor_name are split across the two tables they actually live in now.
-- ---------------------------------------------------------------------------
create or replace function public.approve_carrier_settlement(p_settlement_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_status public.settlement_status;
  v_carrier_id uuid;
  v_item_count integer;
  v_payee_type public.settlement_payee_type;
  v_carrier_name text;
  v_factor_name text;
begin
  select status, carrier_id, payee_type into v_status, v_carrier_id, v_payee_type
  from public.settlements where id = p_settlement_id for update;
  if v_status is null then
    raise exception 'Settlement not found.';
  end if;
  if v_status not in ('draft', 'pending') then
    raise exception 'Only a draft settlement can be approved.';
  end if;

  select count(*) into v_item_count from public.settlement_line_items where settlement_id = p_settlement_id and item_type = 'load_pay';
  if v_item_count = 0 then
    raise exception 'Cannot approve a settlement with no loads.';
  end if;

  select legal_name into v_carrier_name from public.carriers where id = v_carrier_id;
  select factoring_company_name into v_factor_name from public.carrier_financials where carrier_id = v_carrier_id;

  update public.settlements
  set status = 'approved', approved_at = now(), approved_by = auth.uid(),
      payee_name = case when v_payee_type = 'factor' then coalesce(v_factor_name, v_carrier_name) else v_carrier_name end
  where id = p_settlement_id;
end;
$$;

grant execute on function public.approve_carrier_settlement(uuid) to authenticated;
