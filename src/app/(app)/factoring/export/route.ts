import { toCsv, csvResponse, formatMoney, formatDate } from "@/lib/export/csv";
import { requireRoleForApi, FINANCIAL_ROLES } from "@/lib/auth/require-role";
import { loadFactoringWorkspaceExportRows } from "@/lib/factoring/workspace";
import { parseWorkspaceFilters, type WorkspaceRow } from "@/lib/factoring/workspace-types";

// Mirrors /factoring's own filters exactly (parseWorkspaceFilters is
// shared with page.tsx so the two can never parse the same query string
// two different ways) -- "Export current filtered factoring view to CSV,"
// per the approved design. Same requireRoleForApi(FINANCIAL_ROLES) guard
// every other */export route in this app already uses.
export async function GET(req: Request) {
  const denied = await requireRoleForApi(FINANCIAL_ROLES);
  if (denied) return denied;

  const { searchParams } = new URL(req.url);
  const filters = parseWorkspaceFilters({
    view: searchParams.get("view") ?? undefined,
    q: searchParams.get("q") ?? undefined,
    factor: searchParams.get("factor") ?? undefined,
    reconciliation: searchParams.get("reconciliation") ?? undefined,
    submittedFrom: searchParams.get("submittedFrom") ?? undefined,
    submittedTo: searchParams.get("submittedTo") ?? undefined,
    fundedFrom: searchParams.get("fundedFrom") ?? undefined,
    fundedTo: searchParams.get("fundedTo") ?? undefined,
    reserveOnly: searchParams.get("reserveOnly") ?? undefined,
    sort: searchParams.get("sort") ?? undefined,
  });

  const rows = await loadFactoringWorkspaceExportRows(filters);

  const csv = toCsv(rows, [
    { header: "Invoice #", value: (r: WorkspaceRow) => r.invoiceNumber },
    { header: "Customer", value: (r: WorkspaceRow) => r.customerName },
    { header: "Factor", value: (r: WorkspaceRow) => r.factoringCompanyName },
    { header: "Status", value: (r: WorkspaceRow) => r.status },
    { header: "Reconciliation", value: (r: WorkspaceRow) => r.reconciliationStatus },
    { header: "Face Value", value: (r: WorkspaceRow) => formatMoney(r.invoiceFaceValue) },
    { header: "Expected Funding", value: (r: WorkspaceRow) => formatMoney(r.expectedFundingAmount) },
    { header: "Actual Funded", value: (r: WorkspaceRow) => formatMoney(r.actualFundedAmount) },
    { header: "Reserve Outstanding", value: (r: WorkspaceRow) => formatMoney(r.outstandingReserve) },
    { header: "Factoring Fee", value: (r: WorkspaceRow) => formatMoney(r.factoringFeeAmount) },
    { header: "Recourse Amount", value: (r: WorkspaceRow) => formatMoney(r.recourseAmount) },
    { header: "Chargeback Amount", value: (r: WorkspaceRow) => formatMoney(r.chargebackAmount) },
    { header: "External Reference", value: (r: WorkspaceRow) => r.externalReference },
    { header: "Submitted", value: (r: WorkspaceRow) => formatDate(r.submittedAt) },
    { header: "Funded", value: (r: WorkspaceRow) => formatDate(r.fundedAt) },
  ]);

  return csvResponse(csv, "factoring");
}
