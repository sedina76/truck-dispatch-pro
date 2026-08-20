-- =============================================================================
-- 0079_factoring_workspace_reporting.sql
-- Phase 2H.8: read-only aggregation RPCs backing the /factoring operational
-- workspace's KPI strip and per-factor exposure section. PROPOSED ONLY --
-- NOT APPLIED.
--
-- Scope discipline (per the approved Phase 2H.8 design): this migration
-- contains ONLY the two reporting RPCs below. No schema change, no new
-- column, no new table, no index, no change to 0071-0078, no change to any
-- lifecycle RPC, status, transition, or formula. Both functions are pure
-- SELECT aggregates over the existing factored_invoices/factoring_companies
-- tables.
--
-- PRECEDENT: get_ar_summary() (0026_accounts_receivable.sql) is the
-- existing, established pattern this follows exactly -- `language sql
-- stable`, NO explicit security clause (Postgres defaults to SECURITY
-- INVOKER), and NO explicit organization_id filter anywhere in the body.
-- Both functions below rely entirely on factored_invoices'/
-- factoring_companies' own RLS (0071, unchanged) to scope every result to
-- the caller's organization AND role (FINANCIAL_ROLES) -- exactly like
-- get_ar_summary() relies on invoices'/payments' RLS. A driver/viewer
-- session, or a cross-org session, gets an all-zero/empty result from
-- these functions for the same reason a direct SELECT against
-- factored_invoices would -- the underlying row visibility, not anything
-- in this function body, is the security boundary. No service-role
-- bypass anywhere.
--
-- Every formula mirrors the Phase 2H.8 pre-implementation report's
-- approved definitions exactly (see that report for the full reasoning
-- behind each filter choice):
--
--   TERMINAL STATUSES -- confirmed from guard_factored_invoice_status_
--   transition() (0071, unchanged through 0078): rejected, cancelled,
--   chargeback, closed never appear as a FROM-state anywhere in the
--   transition graph. 'draft' is excluded from every filter below too --
--   confirmed unreachable in practice: submit_invoice_to_factor() (0073)
--   always inserts directly with status='submitted', never 'draft'.
--
--   "Active Factored Face Value" / "Open Transactions" -- status NOT IN
--   the terminal set above -- CURRENT, still-open exposure only, never
--   lifetime volume. Naturally excludes rejected/cancelled attempts (no
--   double-counting a superseded attempt alongside its resubmission).
--
--   "Cumulative Funded" / "Outstanding Reserve" / "Cumulative Factoring
--   Fees" -- filtered on actual_funded_amount IS NOT NULL, not a status
--   list: this column is only ever non-null on a row that reached
--   'funded' at least once (fund_factored_invoice(), 0076, always sets it
--   together with the status transition), so its own nullability already
--   and exactly encodes "was this transaction ever actually funded" with
--   no separate status enumeration needed. Deliberately CUMULATIVE/
--   lifetime (includes closed/chargeback rows) -- labeled as such in the
--   application layer, never presented as "current exposure." Outstanding
--   Reserve is naturally 0 on every well-formed closed row already
--   (close_factored_invoice(), 0077, requires reconciliation_status =
--   'reconciled', which requires outstanding_reserve = 0), so no
--   additional terminal-exclusion is needed there either.
--
--   "Needs Attention" -- status IN ('submitted','pending','approved',
--   'disputed','recourse') OR (status IN ('funded','partially_settled')
--   AND reconciliation_status <> 'reconciled'). Deliberately excludes
--   'chargeback' (terminal -- no RPC accepts it as a source status,
--   nothing further can be done, even though it remains financially
--   visible via its own KPI/tab) and 'rejected'/'cancelled' (historical;
--   any resubmission is an Invoice Detail action on the underlying
--   invoice, not a further action on this factoring transaction row).
--
--   "Current Recourse Exposure" -- sum(recourse_amount) WHERE status =
--   'recourse' ONLY, not merely recourse_amount > 0: recourse_amount is a
--   lifetime scalar that stays populated after resolution (via
--   record_factoring_chargeback() or record_factoring_buyback(), 0078),
--   so scoping to the live 'recourse' status is required to avoid
--   double-counting already-resolved cases as still "exposed."
--
--   "Chargeback Amount" -- sum(chargeback_amount) WHERE status =
--   'chargeback'. Structurally always equivalent to chargeback_amount > 0
--   (chargeback is terminal and set exactly once by
--   record_factoring_chargeback()), expressed explicitly for clarity/
--   self-documentation rather than because the filter changes anything.
--
-- LABELING (spec section 16/2): these are operational reporting figures,
-- not GL entries. Nothing here is called "Revenue," invoice_face_value is
-- never called "Cash," and recourse/chargeback are never netted into AR --
-- entirely an application-layer (component copy) concern, not a SQL
-- concern, but noted here since these two functions are the numbers that
-- copy will display.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- get_factoring_workspace_kpis -- org-wide KPI strip. One row, always
-- (aggregates with no matching rows still return a row of zeros/coalesced
-- defaults, never no rows -- no caller-side null-handling required).
-- Deliberately takes NO parameters and is NOT affected by the main
-- workspace table's own history/search/sort/pagination filters -- the
-- approved design requires KPI math to stay independent of the table's
-- "all attempts vs latest attempt" display toggle, using only its own
-- explicit status/economic predicates documented above.
-- ---------------------------------------------------------------------------
create or replace function public.get_factoring_workspace_kpis()
returns table (
  active_face_value numeric,
  cumulative_funded numeric,
  outstanding_reserve numeric,
  cumulative_fees numeric,
  open_transactions bigint,
  needs_attention bigint,
  recourse_exposure numeric,
  chargeback_exposure numeric
)
language sql
stable
as $$
  select
    coalesce(sum(fi.invoice_face_value) filter (
      where fi.status not in ('rejected', 'cancelled', 'chargeback', 'closed')
    ), 0) as active_face_value,
    coalesce(sum(fi.actual_funded_amount) filter (
      where fi.actual_funded_amount is not null
    ), 0) as cumulative_funded,
    coalesce(sum(fi.outstanding_reserve) filter (
      where fi.actual_funded_amount is not null
    ), 0) as outstanding_reserve,
    coalesce(sum(fi.factoring_fee_amount) filter (
      where fi.actual_funded_amount is not null
    ), 0) as cumulative_fees,
    count(*) filter (
      where fi.status not in ('rejected', 'cancelled', 'chargeback', 'closed')
    ) as open_transactions,
    count(*) filter (
      where fi.status in ('submitted', 'pending', 'approved', 'disputed', 'recourse')
         or (fi.status in ('funded', 'partially_settled') and fi.reconciliation_status <> 'reconciled')
    ) as needs_attention,
    coalesce(sum(fi.recourse_amount) filter (
      where fi.status = 'recourse'
    ), 0) as recourse_exposure,
    coalesce(sum(fi.chargeback_amount) filter (
      where fi.status = 'chargeback'
    ), 0) as chargeback_exposure
  from public.factored_invoices fi;
$$;

grant execute on function public.get_factoring_workspace_kpis() to authenticated;

-- ---------------------------------------------------------------------------
-- get_factoring_company_exposure -- one row per factoring company that has
-- at least one factored_invoices row (INNER JOIN, deliberate: a factor
-- configured in Settings but never actually used has nothing to expose --
-- it's already visible in Settings -> Factoring, this section is
-- specifically about transaction exposure). Same formulas as the KPI
-- function above, grouped by factor, using ONLY factored_invoices'
-- snapshot/actual columns -- never factoring_relationships' default
-- terms, per the approved design's explicit instruction that historical
-- transaction economics must come from the transaction rows themselves,
-- not today's negotiated relationship settings. Ordered by active face
-- value descending so the highest-exposure factor sorts first by default.
-- ---------------------------------------------------------------------------
create or replace function public.get_factoring_company_exposure()
returns table (
  factoring_company_id uuid,
  company_name text,
  active_face_value numeric,
  actual_funding numeric,
  outstanding_reserve numeric,
  fees numeric,
  open_transactions bigint,
  disputed_count bigint,
  recourse_exposure numeric,
  chargeback_exposure numeric
)
language sql
stable
as $$
  select
    fc.id as factoring_company_id,
    fc.name as company_name,
    coalesce(sum(fi.invoice_face_value) filter (
      where fi.status not in ('rejected', 'cancelled', 'chargeback', 'closed')
    ), 0) as active_face_value,
    coalesce(sum(fi.actual_funded_amount) filter (
      where fi.actual_funded_amount is not null
    ), 0) as actual_funding,
    coalesce(sum(fi.outstanding_reserve) filter (
      where fi.actual_funded_amount is not null
    ), 0) as outstanding_reserve,
    coalesce(sum(fi.factoring_fee_amount) filter (
      where fi.actual_funded_amount is not null
    ), 0) as fees,
    count(*) filter (
      where fi.status not in ('rejected', 'cancelled', 'chargeback', 'closed')
    ) as open_transactions,
    count(*) filter (
      where fi.status = 'disputed'
    ) as disputed_count,
    coalesce(sum(fi.recourse_amount) filter (
      where fi.status = 'recourse'
    ), 0) as recourse_exposure,
    coalesce(sum(fi.chargeback_amount) filter (
      where fi.status = 'chargeback'
    ), 0) as chargeback_exposure
  from public.factoring_companies fc
  join public.factored_invoices fi on fi.factoring_company_id = fc.id
  group by fc.id, fc.name
  order by coalesce(sum(fi.invoice_face_value) filter (
    where fi.status not in ('rejected', 'cancelled', 'chargeback', 'closed')
  ), 0) desc;
$$;

grant execute on function public.get_factoring_company_exposure() to authenticated;
