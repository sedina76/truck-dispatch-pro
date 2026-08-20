import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards the whole Billing workspace (/billing, /billing/ready-to-bill)
// before any page under it fetches data -- see require-role.ts's header
// comment for why a layout-level check, not a per-page one.
export default async function BillingLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
