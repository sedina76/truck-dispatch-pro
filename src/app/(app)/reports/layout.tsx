import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /reports and all 13 report subpages in one place. Revenue,
// profitability, margin, and pay-by-driver/carrier are exactly the kind
// of "internal staff only" data the Financial Data Rule calls out.
// /reports/load-margin/export is a route.ts, guarded separately with
// requireRoleForApi().
export default async function ReportsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
