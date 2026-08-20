import { getExceptionCenterData, type ExceptionFilters } from "./actions";
import { ExceptionCenterClient } from "./exception-center-client";

// Server component wrapper -- resolves the FIRST page's data server-side
// (from a URL-encoded filter state, same convention as /loads' searchParams
// filtering) so the page has real content on first paint; all subsequent
// filter/sort/page interactions happen client-side via the same server
// action (see exception-center-client.tsx). Auth/org-membership is already
// enforced by the (app) route group's layout, same as every other page
// under it.
export default async function ExceptionCenterPage({
  searchParams,
}: {
  searchParams: Promise<{ severity?: string; status?: string; type?: string; assignment?: string; q?: string; page?: string; sort?: string }>;
}) {
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

  return <ExceptionCenterClient initialData={initialData} initialFilters={initialFilters} />;
}
