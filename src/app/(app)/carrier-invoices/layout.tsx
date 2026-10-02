import { requireRole, BILLING_ROLES } from "@/lib/auth/require-role";

// Carrier invoices are money pages: owner/admin/accountant (the database
// enforces its own role rules on every action as well). The PDF/package
// route handlers under [id] check the same roles themselves.
export default async function CarrierInvoicesLayout({ children }: { children: React.ReactNode }) {
  await requireRole(BILLING_ROLES);
  return <>{children}</>;
}
