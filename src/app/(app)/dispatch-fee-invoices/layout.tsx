import { requireRole, BILLING_ROLES } from "@/lib/auth/require-role";

// Guards /dispatch-fee-invoices, /new and /[id]. The PDF route.ts under
// [id]/pdf is a route handler (layouts don't wrap those), so it checks the
// same roles itself. The database also refuses every other role (0165 RLS).
export default async function DispatchFeeInvoicesLayout({ children }: { children: React.ReactNode }) {
  await requireRole(BILLING_ROLES);
  return <>{children}</>;
}
