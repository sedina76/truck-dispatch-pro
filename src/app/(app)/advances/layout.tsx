import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /advances and every nested page (by-carrier, deducted-history,
// new, [id]) -- all real page.tsx files, all covered by this one layout.
export default async function AdvancesLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
