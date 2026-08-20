import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /payments, /payments/new, /payments/[id]. /payments/export is a
// route.ts, guarded separately with requireRoleForApi().
export default async function PaymentsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
