import "server-only";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import {
  PAGE_SIZE,
  type WorkspaceFilters,
  type WorkspaceRow,
  type WorkspaceKpis,
  type FactorExposureRow,
} from "@/lib/factoring/workspace-types";

// ---------------------------------------------------------------------------
// Phase 2H.8 -- all query-building for the /factoring workspace's main
// table lives here, kept separate from page.tsx (thin server component)
// and factoring-workspace.tsx (presentational only, receives already-
// fetched data as props). Plain PostgREST joins, never a dedicated RPC --
// matches this app's own established precedent for a comparably complex
// filtered/sorted/paginated operational list (getExceptionCenterData(),
// src/app/(app)/dispatch/exceptions/actions.ts) rather than the
// aggregation RPCs (0079), which exist ONLY because PostgREST cannot do
// server-side SUM/GROUP BY.
//
// HISTORICAL ATTEMPTS: the main table shows EVERY factored_invoices row
// by default (approved design) -- rejected/cancelled attempts are
// legitimate operational history and are never filtered out here except
// by an explicit view/filter the user chose. A true "latest attempt per
// invoice" mode would require either a dedicated view or an RPC (DISTINCT
// ON with correct server-side pagination isn't expressible through plain
// PostgREST filters) -- out of 0079's locked scope (two approved RPCs
// only), so it is deliberately NOT implemented in this phase. Documented
// deferral, not an oversight.
// ---------------------------------------------------------------------------

const VIEW_STATUS_FILTER: Record<string, string[] | null> = {
  all: null,
  submitted: ["submitted"],
  pending: ["pending"],
  "awaiting-funding": ["approved"],
  funded: ["funded", "partially_settled"],
  "settlement-needed": ["funded", "partially_settled"], // + reconciliation_status <> reconciled, applied separately below
  disputed: ["disputed"],
  recourse: ["recourse"],
  chargeback: ["chargeback"],
  closed: ["closed"],
  "rejected-cancelled": ["rejected", "cancelled"],
};

export type WorkspaceQueryResult = {
  rows: WorkspaceRow[];
  total: number;
  page: number;
  pageSize: number;
};

// Row shape returned by the shared query builder below -- kept as `any`-ish
// via the Supabase client's own inferred type (not hand-typed) since it's
// only ever passed straight into mapWorkspaceRow().
type RawFactoredInvoiceRow = {
  id: string;
  status: string;
  reconciliation_status: string;
  submitted_at: string | null;
  funded_at: string | null;
  closed_at: string | null;
  updated_at: string;
  invoice_face_value: number;
  expected_funding_amount: number;
  actual_funded_amount: number | null;
  reserve_amount: number;
  reserve_released_amount: number;
  outstanding_reserve: number;
  factoring_fee_amount: number;
  recourse_amount: number;
  chargeback_amount: number;
  external_reference: string | null;
  invoices: { id: string; invoice_number: string; customer_id: string; customers: { company_name: string } | null };
  factoring_companies: { id: string; name: string };
};

function mapWorkspaceRow(fi: RawFactoredInvoiceRow): WorkspaceRow {
  return {
    id: fi.id,
    status: fi.status,
    reconciliationStatus: fi.reconciliation_status,
    submittedAt: fi.submitted_at,
    fundedAt: fi.funded_at,
    closedAt: fi.closed_at,
    updatedAt: fi.updated_at,
    invoiceFaceValue: Number(fi.invoice_face_value),
    expectedFundingAmount: Number(fi.expected_funding_amount),
    actualFundedAmount: fi.actual_funded_amount !== null ? Number(fi.actual_funded_amount) : null,
    reserveAmount: Number(fi.reserve_amount),
    reserveReleasedAmount: Number(fi.reserve_released_amount),
    outstandingReserve: Number(fi.outstanding_reserve),
    factoringFeeAmount: Number(fi.factoring_fee_amount),
    recourseAmount: Number(fi.recourse_amount),
    chargebackAmount: Number(fi.chargeback_amount),
    externalReference: fi.external_reference,
    invoiceId: fi.invoices.id,
    invoiceNumber: fi.invoices.invoice_number,
    customerName: fi.invoices.customers?.company_name ?? "--",
    factoringCompanyId: fi.factoring_companies.id,
    factoringCompanyName: fi.factoring_companies.name,
  };
}

// ---------------------------------------------------------------------------
// Shared filtered-query builder -- everything both loadFactoringWorkspaceRows
// (paginated, PAGE_SIZE) and loadFactoringWorkspaceExportRows (capped,
// unpaginated CSV) need: table/view filter, combinable filters, search,
// sort. Neither caller applies `.range()` -- that's the one thing that
// differs between the two, added by each caller itself.
//
// Returns `{ query }` (a plain object WRAPPING the builder) rather than
// the builder itself: a PostgrestFilterBuilder is a thenable, and
// returning one directly from an `async function` makes TypeScript (and
// JS's own await machinery) collapse the function's resolved type down to
// the AWAITED response, silently losing every further chainable method
// (`.range()` included) both at the type level and at runtime. Wrapping
// it in `{ query }` -- a non-thenable object -- avoids that entirely.
// ---------------------------------------------------------------------------
async function buildFilteredWorkspaceQuery(filters: WorkspaceFilters) {
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();

  // `invoices!inner` is deliberate and safe (invoice_id is a NOT NULL FK
  // on every factored_invoices row, so an inner join never drops a
  // legitimate row) -- required so filtering by invoices.customer_id
  // below actually restricts the parent rows (a plain, non-inner embed
  // filter only nulls out the embedded object rather than excluding the
  // row). `factoring_companies` is a PLAIN embed (no `!inner`) --
  // Phase 2H.8A removed the one reason it was ever `!inner` (ordering
  // parent rows by factoring_companies.name, which never actually worked
  // -- see workspace-types.ts's WORKSPACE_SORTS comment); nothing else
  // filters or orders through this embed, so a plain embed is sufficient
  // and correct (factoring_company_id is also a NOT NULL FK, so the
  // result set is identical either way -- this is a no-op behavior
  // change, just removing now-pointless join intent).
  let query = supabase
    .from("factored_invoices")
    .select(
      `id, status, reconciliation_status, submitted_at, funded_at, closed_at, updated_at,
       invoice_face_value, expected_funding_amount, actual_funded_amount, reserve_amount,
       reserve_released_amount, outstanding_reserve, factoring_fee_amount, recourse_amount,
       chargeback_amount, external_reference, invoice_id, factoring_company_id,
       invoices!inner(id, invoice_number, customer_id, customers(company_name)),
       factoring_companies(id, name)`,
      { count: "exact" }
    )
    .eq("organization_id", orgId);

  // --- work-queue / tab ------------------------------------------------
  const statusList = VIEW_STATUS_FILTER[filters.view];
  if (statusList) query = query.in("status", statusList);
  if (filters.view === "settlement-needed") query = query.neq("reconciliation_status", "reconciled");

  // --- filters (combine) ------------------------------------------------
  if (filters.factoringCompanyId) query = query.eq("factoring_company_id", filters.factoringCompanyId);
  if (filters.reconciliationStatus) query = query.eq("reconciliation_status", filters.reconciliationStatus);
  if (filters.customerId) query = query.eq("invoices.customer_id", filters.customerId);
  if (filters.submittedFrom) query = query.gte("submitted_at", filters.submittedFrom);
  if (filters.submittedTo) query = query.lte("submitted_at", `${filters.submittedTo}T23:59:59.999`);
  if (filters.fundedFrom) query = query.gte("funded_at", filters.fundedFrom);
  if (filters.fundedTo) query = query.lte("funded_at", `${filters.fundedTo}T23:59:59.999`);
  if (filters.outstandingReserveOnly) query = query.gt("outstanding_reserve", 0);

  // --- search -------------------------------------------------------------
  // Four target fields span three different tables (invoice number on
  // invoices, customer name on customers, factor name on
  // factoring_companies, external_reference on factored_invoices itself).
  // Rather than risk an unverified multi-level-nested `.or()` embed filter
  // (this codebase has no existing precedent for filtering more than one
  // level deep through an embed), matching invoice/customer/company ids
  // are resolved first via small, bounded, indexed lookups, then combined
  // into one `.or()` against the main (already paginated) query -- still
  // fully server-side, never fetches the full factored_invoices set.
  if (filters.q) {
    const q = filters.q;
    const [invoiceNumberMatches, customerNameMatches, companyMatches] = await Promise.all([
      supabase.from("invoices").select("id").eq("organization_id", orgId).ilike("invoice_number", `%${q}%`),
      supabase.from("invoices").select("id, customers!inner(company_name)").eq("organization_id", orgId).ilike("customers.company_name", `%${q}%`),
      supabase.from("factoring_companies").select("id").eq("organization_id", orgId).ilike("name", `%${q}%`),
    ]);
    const invoiceIds = new Set<string>([...(invoiceNumberMatches.data ?? []).map((r) => r.id), ...(customerNameMatches.data ?? []).map((r) => r.id)]);
    const companyIds = new Set<string>((companyMatches.data ?? []).map((r) => r.id));

    const orClauses = [`external_reference.ilike.%${q}%`];
    if (invoiceIds.size > 0) orClauses.push(`invoice_id.in.(${[...invoiceIds].join(",")})`);
    if (companyIds.size > 0) orClauses.push(`factoring_company_id.in.(${[...companyIds].join(",")})`);
    query = query.or(orClauses.join(","));
  }

  // --- sort (deterministic: every branch gets `id asc` as a tie-break) ---
  switch (filters.sort) {
    case "submitted_asc":
      query = query.order("submitted_at", { ascending: true, nullsFirst: true });
      break;
    case "face_value_desc":
      query = query.order("invoice_face_value", { ascending: false });
      break;
    case "reserve_desc":
      query = query.order("outstanding_reserve", { ascending: false });
      break;
    case "recourse_desc":
      query = query.order("recourse_amount", { ascending: false });
      break;
    case "funded_desc":
      query = query.order("funded_at", { ascending: false, nullsFirst: false });
      break;
    default:
      query = query.order("submitted_at", { ascending: false, nullsFirst: false });
  }
  query = query.order("id", { ascending: true });

  return { query };
}

// PAGE_SIZE-paginated, for the on-screen table.
export async function loadFactoringWorkspaceRows(filters: WorkspaceFilters): Promise<WorkspaceQueryResult> {
  const page = Math.max(1, filters.page);
  const from = (page - 1) * PAGE_SIZE;
  const to = from + PAGE_SIZE - 1;

  const { query } = await buildFilteredWorkspaceQuery(filters);
  const { data, count, error } = await query.range(from, to);
  if (error) {
    console.error("[factoring workspace] list query failed:", error);
    return { rows: [], total: 0, page, pageSize: PAGE_SIZE };
  }

  return { rows: (data ?? []).map((fi) => mapWorkspaceRow(fi as unknown as RawFactoredInvoiceRow)), total: count ?? 0, page, pageSize: PAGE_SIZE };
}

// Same filters, no pagination -- capped at a sane maximum (still bounded,
// still server-side) rather than truly unbounded, for CSV export. Ignores
// `filters.page`.
const EXPORT_ROW_CAP = 5000;

export async function loadFactoringWorkspaceExportRows(filters: WorkspaceFilters): Promise<WorkspaceRow[]> {
  const { query } = await buildFilteredWorkspaceQuery(filters);
  const { data, error } = await query.range(0, EXPORT_ROW_CAP - 1);
  if (error) {
    console.error("[factoring workspace] export query failed:", error);
    return [];
  }
  return (data ?? []).map((fi) => mapWorkspaceRow(fi as unknown as RawFactoredInvoiceRow));
}

// ---------------------------------------------------------------------------
// KPIs + factor exposure -- both from the two 0079 RPCs, org/role-scoped
// entirely by factored_invoices'/factoring_companies' own RLS (SECURITY
// INVOKER, no explicit org filter in the SQL) -- same reliance pattern as
// get_ar_summary(). Deliberately independent of every table filter above
// (view/search/sort/page/history) -- the approved design requires KPI
// math to use only its own explicit status/economic predicates, never the
// table's current display filter.
// ---------------------------------------------------------------------------
type RawWorkspaceKpis = {
  active_face_value: number;
  cumulative_funded: number;
  outstanding_reserve: number;
  cumulative_fees: number;
  open_transactions: number;
  needs_attention: number;
  recourse_exposure: number;
  chargeback_exposure: number;
};

// Cast, not generated-type inference -- this codebase has no generated
// Supabase types file at all (confirmed by inspection); every existing
// RPC call (e.g. get_ar_summary() in invoices/page.tsx) casts its result
// explicitly the same way.
export async function loadFactoringWorkspaceKpis(): Promise<WorkspaceKpis> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_factoring_workspace_kpis").single();
  const row = data as RawWorkspaceKpis | null;
  if (error || !row) {
    console.error("[factoring workspace] kpi rpc failed:", error?.message);
    return { activeFaceValue: 0, cumulativeFunded: 0, outstandingReserve: 0, cumulativeFees: 0, openTransactions: 0, needsAttention: 0, recourseExposure: 0, chargebackExposure: 0 };
  }
  return {
    activeFaceValue: Number(row.active_face_value),
    cumulativeFunded: Number(row.cumulative_funded),
    outstandingReserve: Number(row.outstanding_reserve),
    cumulativeFees: Number(row.cumulative_fees),
    openTransactions: Number(row.open_transactions),
    needsAttention: Number(row.needs_attention),
    recourseExposure: Number(row.recourse_exposure),
    chargebackExposure: Number(row.chargeback_exposure),
  };
}

type RawFactorExposureRow = {
  factoring_company_id: string;
  company_name: string;
  active_face_value: number;
  actual_funding: number;
  outstanding_reserve: number;
  fees: number;
  open_transactions: number;
  disputed_count: number;
  recourse_exposure: number;
  chargeback_exposure: number;
};

export async function loadFactorExposure(): Promise<FactorExposureRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_factoring_company_exposure");
  if (error) {
    console.error("[factoring workspace] exposure rpc failed:", error.message);
    return [];
  }
  return ((data ?? []) as RawFactorExposureRow[]).map((r) => ({
    factoringCompanyId: r.factoring_company_id,
    companyName: r.company_name,
    activeFaceValue: Number(r.active_face_value),
    actualFunding: Number(r.actual_funding),
    outstandingReserve: Number(r.outstanding_reserve),
    fees: Number(r.fees),
    openTransactions: Number(r.open_transactions),
    disputedCount: Number(r.disputed_count),
    recourseExposure: Number(r.recourse_exposure),
    chargebackExposure: Number(r.chargeback_exposure),
  }));
}

// ---------------------------------------------------------------------------
// Filter dropdown option sources -- factors and customers that actually
// have at least one factored_invoices row, so the dropdowns never list
// irrelevant options. Small, bounded, cheap.
// ---------------------------------------------------------------------------
export async function loadFactoringCompanyOptions(): Promise<{ id: string; name: string }[]> {
  const supabase = await createClient();
  const { data } = await supabase.from("factoring_companies").select("id, name").order("name", { ascending: true });
  return data ?? [];
}
