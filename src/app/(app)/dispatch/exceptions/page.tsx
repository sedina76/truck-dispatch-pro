import { requireRole } from "@/lib/auth/require-role";
import { getExceptionCenterData, type ExceptionFilters } from "./actions";
import { ExceptionCenterClient } from "./exception-center-client";

// Server component wrapper -- resolves the FIRST page's data server-side
// (from a URL-encoded filter state, same convention as /loads' searchParams
// filtering) so the page has real content on first paint; all subsequent
// filter/sort/page interactions happen client-side via the same server
// action (see exception-center-client.tsx). Auth/org-membership is already
// enforced by the (app) route group's layout, same as every other page
// under it.
//
// Phase 2P.5B -- explicit role guard, defense-in-depth alongside the
// database RLS boundary (0063's SELECT policy + 0106's security_invoker
// repair), which remains authoritative either way. Before this, an
// authenticated Accountant/Viewer/Driver reaching this URL directly would
// have received a real page shell whose data queries simply returned
// nothing -- correct in outcome, but not the project's standard
// unauthorized-access UX (requireRole() redirects to /access-denied, the
// same convention Billing/Reports/Email History/Expenses/Settlements
// already use -- see require-role.ts's own header comment).
export default async function ExceptionCenterPage({
  searchParams,
}: {
  searchParams: Promise<{ severity?: string; status?: string; type?: string; assignment?: string; q?: string; page?: string; sort?: string; exception?: string }>;
}) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const sp = await searchParams;
  const initialFilters: ExceptionFilters = {
    severity: (sp.severity as ExceptionFilters["severity"]) ?? "all",
    status: (sp.status as ExceptionFilters["status"]) ?? "all",
    type: (sp.type as ExceptionFilters["type"]) ?? "all",
    assignment: (sp.assignment as ExceptionFilters["assignment"]) ?? "all",
    q: sp.q ?? "",
    page: sp.page ? Number(sp.page) : 1,
    sort: (sp.sort as ExceptionFilters["sort"]) ?? "severity",
  };

  const initialData = await getExceptionCenterData(initialFilters);

  return <ExceptionCenterClient initialData={initialData} initialFilters={initialFilters} initialOpenExceptionId={sp.exception ?? null} />;
}
