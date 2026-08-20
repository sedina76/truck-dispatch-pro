import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /accounts-receivable. /accounts-receivable/export is a route.ts,
// guarded separately with requireRoleForApi().
export default async function AccountsReceivableLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
