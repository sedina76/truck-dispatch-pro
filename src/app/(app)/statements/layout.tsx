import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Guards /statements, /statements/[id]. /statements/[id]/pdf is a
// route.ts (streams the PDF binary directly, unlike the settlement PDFs
// which are page.tsx print-views), so it is NOT covered by this layout --
// guarded separately with requireRoleForApi().
export default async function StatementsLayout({ children }: { children: React.ReactNode }) {
  await requireRole(FINANCIAL_ROLES);
  return <>{children}</>;
}
