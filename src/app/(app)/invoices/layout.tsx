import { requireRole, BILLING_ROLES } from "@/lib/auth/require-role";

// Guards /invoices, /invoices/new, /invoices/[id]. /invoices/export is a
// route.ts (not covered by a layout) and is guarded separately with
// requireRoleForApi().
export default async function InvoicesLayout({ children }: { children: React.ReactNode }) {
  await requireRole(BILLING_ROLES);
  return <>{children}</>;
}
