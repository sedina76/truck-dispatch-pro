import { requireRole } from "@/lib/auth/require-role";
import { FINANCIAL_ROLES } from "@/lib/auth/require-role";
import { loadFactoringWorkspaceRows, loadFactoringWorkspaceKpis, loadFactorExposure, loadFactoringCompanyOptions } from "@/lib/factoring/workspace";
import { parseWorkspaceFilters } from "@/lib/factoring/workspace-types";
import { FactoringWorkspace } from "./factoring-workspace";

// Phase 2H.8 -- thin server component: role guard, parse searchParams into
// a typed WorkspaceFilters, fetch (delegated entirely to
// src/lib/factoring/workspace.ts), hand already-fetched data to the
// presentational component. No query-building or calculation lives here.
// requireRole() redirects to /access-denied before any data fetch for
// driver/viewer -- the same real mechanism every other guarded financial
// page already uses (Billing, Reports, Email History, Expenses,
// Settlements), not a new one.
export default async function FactoringWorkspacePage({
  searchParams,
}: {
  searchParams: Promise<{
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
  }>;
}) {
  await requireRole(FINANCIAL_ROLES);

  const sp = await searchParams;
  const filters = parseWorkspaceFilters(sp);

  const [{ rows, total, page, pageSize }, kpis, exposure, factoringCompanyOptions] = await Promise.all([
    loadFactoringWorkspaceRows(filters),
    loadFactoringWorkspaceKpis(),
    loadFactorExposure(),
    loadFactoringCompanyOptions(),
  ]);

  return (
    <FactoringWorkspace
      filters={filters}
      rows={rows}
      total={total}
      page={page}
      pageSize={pageSize}
      kpis={kpis}
      exposure={exposure}
      factoringCompanyOptions={factoringCompanyOptions}
    />
  );
}
