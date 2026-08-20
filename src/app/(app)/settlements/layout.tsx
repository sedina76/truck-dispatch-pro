import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /settlements, /settlements/new, /settlements/[id], and
// /settlements/[id]/pdf (a page.tsx print-view nested under this segment,
// so it inherits this guard automatically). Carrier settlement amounts
// are exactly the "settlements belonging to others" the Financial Data
// Rule says a driver must never see.
export default async function SettlementsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
