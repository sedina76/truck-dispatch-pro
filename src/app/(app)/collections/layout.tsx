import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /collections. /collections/export is a route.ts, guarded
// separately with requireRoleForApi().
export default async function CollectionsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
