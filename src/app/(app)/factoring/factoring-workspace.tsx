import Link from "next/link";
import { ChevronRight } from "lucide-react";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBar } from "@/components/ui/search-bar";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import {
  WORKSPACE_VIEWS,
  WORKSPACE_SORTS,
  factoredInvoiceAgeDays,
  factoredInvoiceAgingBucket,
  needsAttention,
  type WorkspaceFilters,
  type WorkspaceRow,
  type WorkspaceKpis,
  type FactorExposureRow,
} from "@/lib/factoring/workspace-types";

function fmtMoney(n: number) {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

// ---------------------------------------------------------------------------
// URL builder -- every tab/sort/pagination link and the filter form all
// produce/consume the exact same search-param shape page.tsx parses, so
// state always round-trips losslessly through the URL (bookmarkable, per
// the approved design). `overrides` values of `null` remove that param;
// `undefined` leaves the current value untouched.
// ---------------------------------------------------------------------------
function buildHref(filters: WorkspaceFilters, overrides: Record<string, string | null | undefined>): string {
  const current: Record<string, string | null | undefined> = {
    view: filters.view !== "all" ? filters.view : null,
    q: filters.q || null,
    factor: filters.factoringCompanyId,
    reconciliation: filters.reconciliationStatus,
    submittedFrom: filters.submittedFrom,
    submittedTo: filters.submittedTo,
    fundedFrom: filters.fundedFrom,
    fundedTo: filters.fundedTo,
    reserveOnly: filters.outstandingReserveOnly ? "1" : null,
    sort: filters.sort !== "submitted_desc" ? filters.sort : null,
    page: filters.page > 1 ? String(filters.page) : null,
  };
  const merged = { ...current, ...overrides };
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(merged)) if (v) params.set(k, v);
  const qs = params.toString();
  return `/factoring${qs ? `?${qs}` : ""}`;
}

export function FactoringWorkspace({
  filters,
  rows,
  total,
  page,
  pageSize,
  kpis,
  exposure,
  factoringCompanyOptions,
}: {
  filters: WorkspaceFilters;
  rows: WorkspaceRow[];
  total: number;
  page: number;
  pageSize: number;
  kpis: WorkspaceKpis;
  exposure: FactorExposureRow[];
  factoringCompanyOptions: { id: string; name: string }[];
}) {
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const exportHref = buildHref(filters, { page: null }).replace("/factoring", "/factoring/export");

  return (
    <div className="space-y-3">
      <RegisterDesktopActions title="Factoring" exportOptions={[{ label: "Export CSV (Filtered)", href: exportHref }]} />
      <PageHeader title="Factoring" description="Manage funded invoices, reserves, reconciliation, and factor exposure." />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Active Factored Face Value" value={fmtMoney(kpis.activeFaceValue)} href={buildHref(filters, { view: null, page: null })} />
        <DesktopKpiBox label="Cumulative Funded" value={fmtMoney(kpis.cumulativeFunded)} sub="Lifetime, incl. closed" />
        <DesktopKpiBox label="Outstanding Reserve" value={fmtMoney(kpis.outstandingReserve)} href={buildHref(filters, { view: null, reserveOnly: "1", page: null })} />
        <DesktopKpiBox label="Cumulative Factoring Fees" value={fmtMoney(kpis.cumulativeFees)} sub="Lifetime, incl. closed" />
        <DesktopKpiBox label="Open Transactions" value={kpis.openTransactions} href={buildHref(filters, { view: null, page: null })} />
        <DesktopKpiBox label="Needs Attention" value={kpis.needsAttention} tone={kpis.needsAttention ? "warning" : "neutral"} />
        <DesktopKpiBox
          label="Current Recourse Exposure"
          value={fmtMoney(kpis.recourseExposure)}
          tone={kpis.recourseExposure ? "danger" : "neutral"}
          href={buildHref(filters, { view: "recourse", page: null })}
        />
        <DesktopKpiBox
          label="Chargeback Amount"
          value={fmtMoney(kpis.chargebackExposure)}
          tone={kpis.chargebackExposure ? "danger" : "neutral"}
          href={buildHref(filters, { view: "chargeback", page: null })}
        />
      </DesktopKpiStrip>

      <WorkQueueTabs filters={filters} />
      <FilterBar filters={filters} factoringCompanyOptions={factoringCompanyOptions} />

      {rows.length === 0 ? (
        <EmptyState
          title={filters.q || hasActiveFilters(filters) ? "No factoring transactions match your filters" : "No factoring transactions yet"}
          description={filters.q || hasActiveFilters(filters) ? "Try different filters or clear them." : "Submit an invoice to a factor from Invoice Detail to get started."}
        />
      ) : (
        <>
          <DesktopTable rows={rows} />
          <MobileCards rows={rows} />
          <PaginationControls filters={filters} page={page} totalPages={totalPages} total={total} pageSize={pageSize} rowCount={rows.length} />
        </>
      )}

      <FactorExposureSection exposure={exposure} />
    </div>
  );
}

function hasActiveFilters(filters: WorkspaceFilters): boolean {
  return Boolean(
    filters.factoringCompanyId ||
      filters.reconciliationStatus ||
      filters.submittedFrom ||
      filters.submittedTo ||
      filters.fundedFrom ||
      filters.fundedTo ||
      filters.outstandingReserveOnly ||
      filters.view !== "all"
  );
}

function WorkQueueTabs({ filters }: { filters: WorkspaceFilters }) {
  return (
    <div className="flex flex-wrap gap-1 border-b border-border pb-2">
      {WORKSPACE_VIEWS.map((v) => {
        const active = filters.view === v.value;
        return (
          <Link
            key={v.value}
            href={buildHref(filters, { view: v.value === "all" ? null : v.value, page: null })}
            className={`rounded-sm px-2.5 py-1 text-[12.5px] font-medium transition-colors ${
              active ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-muted"
            }`}
          >
            {v.label}
          </Link>
        );
      })}
    </div>
  );
}

// GET form -- combines with the tab (hidden `view`) and the client
// SearchBar's own `q` (hidden, kept in sync with the server-parsed current
// value so submitting this form never drops an in-progress search).
// Submitting always drops `page` naturally (no hidden field for it),
// resetting to page 1 on any filter change -- deliberate.
function FilterBar({ filters, factoringCompanyOptions }: { filters: WorkspaceFilters; factoringCompanyOptions: { id: string; name: string }[] }) {
  return (
    <div className="flex flex-wrap items-end gap-2">
      <SearchBar placeholder="Search invoice #, customer, factor, or reference..." />
      <form method="get" className="flex flex-wrap items-end gap-2">
        {filters.view !== "all" && <input type="hidden" name="view" value={filters.view} />}
        {filters.q && <input type="hidden" name="q" value={filters.q} />}

        <FilterField label="Factor">
          <select name="factor" defaultValue={filters.factoringCompanyId ?? ""} className={selectClass}>
            <option value="">All Factors</option>
            {factoringCompanyOptions.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </FilterField>

        <FilterField label="Reconciliation">
          <select name="reconciliation" defaultValue={filters.reconciliationStatus ?? ""} className={selectClass}>
            <option value="">Any</option>
            <option value="unreconciled">Unreconciled</option>
            <option value="partially_reconciled">Partially Reconciled</option>
            <option value="reconciled">Reconciled</option>
          </select>
        </FilterField>

        <FilterField label="Submitted From">
          <input type="date" name="submittedFrom" defaultValue={filters.submittedFrom ?? ""} className={inputClass} />
        </FilterField>
        <FilterField label="Submitted To">
          <input type="date" name="submittedTo" defaultValue={filters.submittedTo ?? ""} className={inputClass} />
        </FilterField>
        <FilterField label="Funded From">
          <input type="date" name="fundedFrom" defaultValue={filters.fundedFrom ?? ""} className={inputClass} />
        </FilterField>
        <FilterField label="Funded To">
          <input type="date" name="fundedTo" defaultValue={filters.fundedTo ?? ""} className={inputClass} />
        </FilterField>

        <label className="flex h-8 items-center gap-1.5 text-xs text-muted-foreground">
          <input type="checkbox" name="reserveOnly" value="1" defaultChecked={filters.outstandingReserveOnly} className="size-3.5" />
          Outstanding reserve only
        </label>

        <FilterField label="Sort">
          <select name="sort" defaultValue={filters.sort} className={selectClass}>
            {WORKSPACE_SORTS.map((s) => (
              <option key={s.value} value={s.value}>
                {s.label}
              </option>
            ))}
          </select>
        </FilterField>

        <button type="submit" className="h-8 rounded-sm border border-border bg-card px-3 text-[13px] font-medium shadow-elevation-1 hover:bg-muted">
          Apply
        </button>
        {hasActiveFilters(filters) && (
          <Link href={buildHref(filters, { view: null, factor: null, reconciliation: null, submittedFrom: null, submittedTo: null, fundedFrom: null, fundedTo: null, reserveOnly: null, sort: null, page: null })} className="h-8 rounded-sm px-2 text-[12.5px] text-muted-foreground underline-offset-2 hover:underline">
            Clear
          </Link>
        )}
      </form>
    </div>
  );
}

const selectClass = "h-8 rounded-sm border border-desktop-border bg-card px-2 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const inputClass = selectClass + " w-[136px]";

function FilterField({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
      {label}
      {children}
    </label>
  );
}

function AgeCell({ row }: { row: WorkspaceRow }) {
  const days = factoredInvoiceAgeDays(row);
  if (days === null) return <span className="text-muted-foreground">--</span>;
  const bucket = factoredInvoiceAgingBucket(days);
  const tone = bucket === "current" || bucket === "1_30" ? "text-muted-foreground" : bucket === "31_60" ? "text-desktop-warning" : "text-desktop-danger";
  return (
    <span className={`tabular-nums ${tone}`}>
      {days}d
    </span>
  );
}

function DesktopTable({ rows }: { rows: WorkspaceRow[] }) {
  return (
    <div className="hidden overflow-x-auto rounded-md border border-border md:block">
      <table className="w-full text-sm">
        <thead className="bg-muted/40 text-left text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
          <tr>
            <th className="px-3 py-2">Invoice #</th>
            <th className="px-3 py-2">Customer</th>
            <th className="px-3 py-2">Factor</th>
            <th className="px-3 py-2">Status</th>
            <th className="px-3 py-2">Reconciliation</th>
            <th className="px-3 py-2 text-right">Face Value</th>
            <th className="px-3 py-2 text-right">Reserve Outstanding</th>
            <th className="px-3 py-2">Submitted</th>
            <th className="px-3 py-2 text-right">Age</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.id} className="border-t border-border hover:bg-muted/30">
              <td className="px-3 py-2">
                <Link href={`/invoices/${row.invoiceId}`} className="inline-flex items-center gap-1 font-medium text-primary hover:underline">
                  {row.invoiceNumber}
                  <ChevronRight className="size-3" />
                </Link>
                {needsAttention(row) && <span className="ml-1.5 inline-block size-1.5 rounded-full bg-desktop-warning align-middle" title="Needs attention" />}
              </td>
              <td className="px-3 py-2">{row.customerName}</td>
              <td className="px-3 py-2">{row.factoringCompanyName}</td>
              <td className="px-3 py-2">
                <StatusBadge status={row.status} />
              </td>
              <td className="px-3 py-2">
                <StatusBadge status={row.reconciliationStatus} />
              </td>
              <td className="px-3 py-2 text-right tabular-nums">{fmtMoney(row.invoiceFaceValue)}</td>
              <td className="px-3 py-2 text-right tabular-nums">{fmtMoney(row.outstandingReserve)}</td>
              <td className="px-3 py-2 text-xs text-muted-foreground">{row.submittedAt ? new Date(row.submittedAt).toLocaleDateString() : "--"}</td>
              <td className="px-3 py-2 text-right">
                <AgeCell row={row} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function MobileCards({ rows }: { rows: WorkspaceRow[] }) {
  return (
    <div className="space-y-2 md:hidden">
      {rows.map((row) => (
        <Link key={row.id} href={`/invoices/${row.invoiceId}`} className="block rounded-md border border-border bg-card p-3 shadow-elevation-1">
          <div className="flex items-center justify-between gap-2">
            <span className="font-medium text-primary">{row.invoiceNumber}</span>
            <StatusBadge status={row.status} />
          </div>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {row.customerName} &middot; {row.factoringCompanyName}
          </p>
          <div className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
            <span className="text-muted-foreground">Face Value</span>
            <span className="text-right tabular-nums">{fmtMoney(row.invoiceFaceValue)}</span>
            <span className="text-muted-foreground">Reserve Outstanding</span>
            <span className="text-right tabular-nums">{fmtMoney(row.outstandingReserve)}</span>
            <span className="text-muted-foreground">Reconciliation</span>
            <span className="text-right">
              <StatusBadge status={row.reconciliationStatus} />
            </span>
            <span className="text-muted-foreground">Age</span>
            <span className="text-right">
              <AgeCell row={row} />
            </span>
          </div>
        </Link>
      ))}
    </div>
  );
}

function PaginationControls({
  filters,
  page,
  totalPages,
  total,
  pageSize,
  rowCount,
}: {
  filters: WorkspaceFilters;
  page: number;
  totalPages: number;
  total: number;
  pageSize: number;
  rowCount: number;
}) {
  const start = (page - 1) * pageSize + 1;
  const end = start + rowCount - 1;
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
      <span>
        {start}-{end} of {total}
      </span>
      {totalPages > 1 && (
        <div className="flex gap-2">
          {page > 1 && (
            <Link href={buildHref(filters, { page: String(page - 1) })} className="rounded-sm border border-border bg-card px-2.5 py-1 shadow-elevation-1 hover:bg-muted">
              Previous
            </Link>
          )}
          <span className="px-1 py-1">
            Page {page} of {totalPages}
          </span>
          {page < totalPages && (
            <Link href={buildHref(filters, { page: String(page + 1) })} className="rounded-sm border border-border bg-card px-2.5 py-1 shadow-elevation-1 hover:bg-muted">
              Next
            </Link>
          )}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Factor exposure -- computed ONLY from factored_invoices snapshot/actual
// columns via get_factoring_company_exposure() (0079), never from
// factoring_relationships' default terms (approved design, spec section
// 12). Labels are deliberately literal ("Active Face Value," "Actual
// Funding") -- never "Revenue," never treating face value as cash (spec
// section 16).
// ---------------------------------------------------------------------------
function FactorExposureSection({ exposure }: { exposure: FactorExposureRow[] }) {
  if (exposure.length === 0) return null;
  return (
    <div className="space-y-1.5">
      <p className="text-[13px] font-semibold">Factor Exposure</p>
      <div className="overflow-x-auto rounded-md border border-border">
        <table className="w-full text-sm">
          <thead className="bg-muted/40 text-left text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
            <tr>
              <th className="px-3 py-2">Factor</th>
              <th className="px-3 py-2 text-right">Active Face Value</th>
              <th className="px-3 py-2 text-right">Actual Funding</th>
              <th className="px-3 py-2 text-right">Outstanding Reserve</th>
              <th className="px-3 py-2 text-right">Fees</th>
              <th className="px-3 py-2 text-right">Open Txns</th>
              <th className="px-3 py-2 text-right">Disputed</th>
              <th className="px-3 py-2 text-right">Recourse Exposure</th>
              <th className="px-3 py-2 text-right">Chargeback Amount</th>
            </tr>
          </thead>
          <tbody>
            {exposure.map((e) => (
              <tr key={e.factoringCompanyId} className="border-t border-border">
                <td className="px-3 py-2 font-medium">{e.companyName}</td>
                <td className="px-3 py-2 text-right tabular-nums">{fmtMoney(e.activeFaceValue)}</td>
                <td className="px-3 py-2 text-right tabular-nums">{fmtMoney(e.actualFunding)}</td>
                <td className="px-3 py-2 text-right tabular-nums">{fmtMoney(e.outstandingReserve)}</td>
                <td className="px-3 py-2 text-right tabular-nums">{fmtMoney(e.fees)}</td>
                <td className="px-3 py-2 text-right tabular-nums">{e.openTransactions}</td>
                <td className="px-3 py-2 text-right tabular-nums">{e.disputedCount}</td>
                <td className="px-3 py-2 text-right tabular-nums">{fmtMoney(e.recourseExposure)}</td>
                <td className="px-3 py-2 text-right tabular-nums">{fmtMoney(e.chargebackExposure)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
