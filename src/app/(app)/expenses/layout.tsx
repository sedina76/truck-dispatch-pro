import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /expenses, /expenses/new, /expenses/[id]. /expenses/export is a
// route.ts, guarded separately with requireRoleForApi().
export default async function ExpensesLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
