// Phase 2H.8 -- shared types/constants for the /factoring operational
// workspace. Kept separate from the query-building logic in workspace.ts
// per the approved architecture (spec section 25: avoid one giant page
// component/module mixing types, queries, and calculations).

// ---------------------------------------------------------------------------
// Terminal status set -- derived directly from
// guard_factored_invoice_status_transition() (0071, unchanged through
// 0078): these four statuses never appear as a FROM-state anywhere in the
// live transition graph, confirmed by inspection, not guessed. 'draft' is
// excluded from every set in this file -- confirmed unreachable in
// practice: submit_invoice_to_factor() (0073) always inserts directly
// with status='submitted'. ONE shared definition, reused everywhere a
// terminal/open distinction is needed (KPI RPCs mirror this same list in
// SQL -- see 0079's header comment -- so the two can never drift).
// ---------------------------------------------------------------------------
export const TERMINAL_FACTORED_INVOICE_STATUSES = ["rejected", "cancelled", "chargeback", "closed"] as const;
export type TerminalFactoredInvoiceStatus = (typeof TERMINAL_FACTORED_INVOICE_STATUSES)[number];

export function isTerminalFactoredInvoiceStatus(status: string): boolean {
  return (TERMINAL_FACTORED_INVOICE_STATUSES as readonly string[]).includes(status);
}

// ---------------------------------------------------------------------------
// Needs Attention -- deterministic rule (approved Phase 2H.8 design),
// mirrored exactly in get_factoring_workspace_kpis() (0079). "Needs an
// action now" is deliberately narrower than "exception/history requiring
// awareness": chargeback is terminal (no RPC accepts it as a source
// status) so it's excluded even though it stays financially visible via
// its own KPI/tab; rejected/cancelled are historical (any resubmission is
// an Invoice Detail action on the invoice, not a further action on this
// transaction row).
// ---------------------------------------------------------------------------
const NEEDS_ATTENTION_STATUSES = ["submitted", "pending", "approved", "disputed", "recourse"] as const;
const SETTLEMENT_STATUSES = ["funded", "partially_settled"] as const;

export function needsAttention(row: { status: string; reconciliationStatus: string }): boolean {
  if ((NEEDS_ATTENTION_STATUSES as readonly string[]).includes(row.status)) return true;
  return (SETTLEMENT_STATUSES as readonly string[]).includes(row.status) && row.reconciliationStatus !== "reconciled";
}

// ---------------------------------------------------------------------------
// Work queue / tab definitions -- mapped precisely to the live status
// graph and reconciliation model, not guessed from the label text. Each
// `apply` function narrows an already-built Supabase query builder.
// ---------------------------------------------------------------------------
export type WorkspaceView =
  | "all"
  | "submitted"
  | "pending"
  | "awaiting-funding"
  | "funded"
  | "settlement-needed"
  | "disputed"
  | "recourse"
  | "chargeback"
  | "closed"
  | "rejected-cancelled";

export const WORKSPACE_VIEWS: { value: WorkspaceView; label: string }[] = [
  { value: "all", label: "All" },
  { value: "submitted", label: "Submitted" },
  { value: "pending", label: "Pending Review" },
  { value: "awaiting-funding", label: "Awaiting Funding" },
  { value: "funded", label: "Funded" },
  { value: "settlement-needed", label: "Settlement Needed" },
  { value: "disputed", label: "Disputed" },
  { value: "recourse", label: "Recourse" },
  { value: "chargeback", label: "Chargeback" },
  { value: "closed", label: "Closed" },
  { value: "rejected-cancelled", label: "Rejected / Cancelled" },
];

export function isWorkspaceView(value: string | undefined): value is WorkspaceView {
  return !!value && WORKSPACE_VIEWS.some((v) => v.value === value);
}

// ---------------------------------------------------------------------------
// Sorting -- deterministic (every option gets `id asc` as a secondary key
// in workspace.ts, never left to rely on insertion order).
//
// Phase 2H.8A: "Factor (A-Z)" (`factor_asc`) was removed after live
// verification found it didn't actually work -- ordering by a referenced
// table's column (factoring_companies.name) does not compose with a
// subsequent top-level `id` tie-break the way this app's every other sort
// does; PostgREST/postgrest-js treats the plain top-level `order=id.asc`
// as authoritative for parent-row order once both are present, silently
// discarding the referenced-table order. This is a genuine composition
// limit of plain PostgREST embedding (the same category of limit that
// already kept a Customer sort/filter out of scope in 2H.8's own design),
// not something worth an RPC/view/migration to work around. Every
// remaining sort orders directly on factored_invoices' OWN columns, so
// none of them are affected.
// ---------------------------------------------------------------------------
export type WorkspaceSort = "submitted_desc" | "submitted_asc" | "face_value_desc" | "reserve_desc" | "recourse_desc" | "funded_desc";

export const WORKSPACE_SORTS: { value: WorkspaceSort; label: string }[] = [
  { value: "submitted_desc", label: "Newest Submitted" },
  { value: "submitted_asc", label: "Oldest Submitted" },
  { value: "face_value_desc", label: "Highest Face Value" },
  { value: "reserve_desc", label: "Highest Outstanding Reserve" },
  { value: "recourse_desc", label: "Highest Recourse Exposure" },
  { value: "funded_desc", label: "Newest Funded" },
];

export function isWorkspaceSort(value: string | undefined): value is WorkspaceSort {
  return !!value && WORKSPACE_SORTS.some((s) => s.value === value);
}

// ---------------------------------------------------------------------------
// Filters -- everything lives in URL search params (bookmarkable), per
// the approved design.
// ---------------------------------------------------------------------------
export type WorkspaceFilters = {
  view: WorkspaceView;
  q: string;
  factoringCompanyId: string | null;
  reconciliationStatus: string | null;
  customerId: string | null;
  submittedFrom: string | null;
  submittedTo: string | null;
  fundedFrom: string | null;
  fundedTo: string | null;
  outstandingReserveOnly: boolean;
  sort: WorkspaceSort;
  page: number;
};

export const PAGE_SIZE = 25;

// Shared by page.tsx (searchParams) and export/route.ts (URLSearchParams)
// so the two can never parse the same query string into two different
// filter sets.
export function parseWorkspaceFilters(sp: {
  view?: string;
  q?: string;
  factor?: string;
  reconciliation?: string;
  submittedFrom?: string;
  submittedTo?: string;
  fundedFrom?: string;
  fundedTo?: string;
  reserveOnly?: string;
  sort?: string;
  page?: string;
}): WorkspaceFilters {
  return {
    view: isWorkspaceView(sp.view) ? sp.view : "all",
    q: sp.q ?? "",
    factoringCompanyId: sp.factor || null,
    reconciliationStatus: sp.reconciliation || null,
    customerId: null,
    submittedFrom: sp.submittedFrom || null,
    submittedTo: sp.submittedTo || null,
    fundedFrom: sp.fundedFrom || null,
    fundedTo: sp.fundedTo || null,
    outstandingReserveOnly: sp.reserveOnly === "1",
    sort: isWorkspaceSort(sp.sort) ? sp.sort : "submitted_desc",
    page: sp.page ? Math.max(1, Number(sp.page) || 1) : 1,
  };
}

// ---------------------------------------------------------------------------
// Row/KPI/exposure shapes -- match the SELECT in workspace.ts and the two
// 0079 RPCs' RETURNS TABLE shapes exactly.
// ---------------------------------------------------------------------------
export type WorkspaceRow = {
  id: string;
  status: string;
  reconciliationStatus: string;
  submittedAt: string | null;
  fundedAt: string | null;
  closedAt: string | null;
  updatedAt: string;
  invoiceFaceValue: number;
  expectedFundingAmount: number;
  actualFundedAmount: number | null;
  reserveAmount: number;
  reserveReleasedAmount: number;
  outstandingReserve: number;
  factoringFeeAmount: number;
  recourseAmount: number;
  chargebackAmount: number;
  externalReference: string | null;
  invoiceId: string;
  invoiceNumber: string;
  customerName: string;
  factoringCompanyId: string;
  factoringCompanyName: string;
};

export type WorkspaceKpis = {
  activeFaceValue: number;
  cumulativeFunded: number;
  outstandingReserve: number;
  cumulativeFees: number;
  openTransactions: number;
  needsAttention: number;
  recourseExposure: number;
  chargebackExposure: number;
};

export type FactorExposureRow = {
  factoringCompanyId: string;
  companyName: string;
  activeFaceValue: number;
  actualFunding: number;
  outstandingReserve: number;
  fees: number;
  openTransactions: number;
  disputedCount: number;
  recourseExposure: number;
  chargebackExposure: number;
};

// ---------------------------------------------------------------------------
// Aging -- submitted_at is the fixed start point. Open rows: age runs
// against "now." Terminal rows: age FREEZES at updated_at (the row's own
// last-modified timestamp, auto-maintained by the existing set_updated_at
// trigger) rather than a per-status column, because two of the four
// terminal statuses (cancelled, chargeback) have NO dedicated timestamp
// column at all (confirmed absent from the live schema) -- updated_at is
// the one column that correctly and uniformly freezes "when this row
// reached its final state" for all four terminal statuses without
// per-status special-casing, since no RPC ever touches a terminal row's
// fields again after it gets there. Documented assumption, not an
// invented accounting concept: if a future phase ever adds a non-status
// edit to a terminal row, this freeze point would need revisiting.
// ---------------------------------------------------------------------------
export function factoredInvoiceAgeDays(row: { status: string; submittedAt: string | null; updatedAt: string }): number | null {
  if (!row.submittedAt) return null;
  const endIso = isTerminalFactoredInvoiceStatus(row.status) ? row.updatedAt : new Date().toISOString();
  const ms = new Date(endIso).getTime() - new Date(row.submittedAt).getTime();
  return Math.max(0, Math.floor(ms / 86_400_000));
}

// Reuses the exact bucket KEYS/boundaries this app already established for
// AR/Collections/Statements aging (src/lib/invoices/effective-status.ts),
// for visual consistency only -- this is submission-age, NOT the same
// concept as AR due-date aging, and must never be presented as one.
export type AgingBucket = "current" | "1_30" | "31_60" | "61_90" | "90_plus";

export function factoredInvoiceAgingBucket(days: number | null): AgingBucket | null {
  if (days === null) return null;
  if (days <= 0) return "current";
  if (days <= 30) return "1_30";
  if (days <= 60) return "31_60";
  if (days <= 90) return "61_90";
  return "90_plus";
}
