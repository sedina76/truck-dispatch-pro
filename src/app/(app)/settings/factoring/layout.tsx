import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Same "deny before rendering" layout guard as the Billing-family
// workspaces (billing/layout.tsx, invoices/layout.tsx, etc.) -- spec
// section 14 requires driver/viewer to fail direct URL access, not just
// have the nav link hidden. RLS on factoring_companies/
// factoring_relationships (0071) is the real, unconditional backstop
// underneath this; this layout is the same UX/defense-in-depth layer
// every other financial workspace already has.
export default async function FactoringSettingsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
