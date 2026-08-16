import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { ACTIVE_LOAD_STATUSES, COMPLETED_LOAD_STATUSES } from "@/lib/loads/status";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

type Load = {
  id: string;
  load_number: string;
  status: string;
  equipment_type: string | null;
  rate: number;
  total_miles: number | null;
  brokers: { company_name: string } | null;
  customers: { company_name: string } | null;
};

export default async function LoadsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; pod_missing?: string }>;
}) {
  const { q, pod_missing } = await searchParams;
  const podMissingOnly = pod_missing === "1";
  const supabase = await createClient();

  let query = supabase
    .from("loads")
    .select("id, load_number, status, equipment_type, rate, total_miles, brokers(company_name), customers(company_name)")
    .order("created_at", { ascending: false });
  if (q) query = query.ilike("load_number", `%${q}%`);
  if (podMissingOnly) query = query.eq("status", "delivered");

  const { data } = await query;
  let loads = (data ?? []) as unknown as Load[];

  // Delivered Loads Missing POD filter, linked from the dashboard alert.
  // Same canonical helper as everywhere else POD status is derived --
  // src/lib/documents/latest-document.ts -- so "missing" always means the
  // same thing: the load's MOST RECENT POD isn't verified.
  if (podMissingOnly && loads.length > 0) {
    const latestPodByLoadId = await getLatestDocumentsByEntity(supabase, "load", "pod", loads.map((l) => l.id));
    loads = loads.filter((l) => latestPodByLoadId.get(l.id)?.is_verified !== true);
  }

  // Total Loads and Total Rate Value both come from the same get_load_summary()
  // RPC call, scoped to the same search filter as the table below -- a plain
  // in-memory sum over `loads` only ever reflected the current page/search
  // result, which silently diverges from reality past PostgREST's default
  // row cap. The RPC computes SUM(rate) in Postgres over every matching row,
  // still scoped to the caller's own organization via the normal RLS policy
  // on public.loads (see 0021_load_summary_aggregate.sql).
  const [{ data: summaryData }, { count: activeCount }, { count: deliveredCount }] = await Promise.all([
    supabase.rpc("get_load_summary", { p_search: q ?? null }).single(),
    supabase.from("loads").select("id", { count: "exact", head: true }).in("status", ACTIVE_LOAD_STATUSES),
    supabase.from("loads").select("id", { count: "exact", head: true }).in("status", COMPLETED_LOAD_STATUSES),
  ]);
  const summary = summaryData as unknown as { total_loads: number; total_rate_value: number } | null;
  const totalCount = summary?.total_loads ?? 0;
  const totalRateValue = Number(summary?.total_rate_value ?? 0);

  const columns: Column<Load>[] = [
    { header: "Load #", cell: (row) => <span className="font-medium">{row.load_number}</span> },
    { header: "Source", cell: (row) => row.brokers?.company_name ?? row.customers?.company_name ?? "--" },
    { header: "Equipment", cell: (row) => row.equipment_type ?? "--" },
    { header: "Miles", cell: (row) => (row.total_miles ? Number(row.total_miles).toLocaleString() : "--") },
    { header: "Rate", cell: (row) => `$${Number(row.rate).toLocaleString()}` },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Loads", href: "/loads" }]} />
      <RegisterDesktopActions
        title="Loads"
        exportOptions={[{ label: "Export CSV (Filtered)", href: `/loads/export${q ? `?q=${encodeURIComponent(q)}` : ""}` }]}
      />
      <PageHeader
        title="Loads"
        description="All loads, filterable by status, broker, and equipment type."
        primaryAction={{ label: "Add Load", href: "/loads/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Loads" value={totalCount ?? 0} />
        <DesktopKpiBox label="Active" value={activeCount ?? 0} />
        <DesktopKpiBox label="Delivered" value={deliveredCount ?? 0} tone="success" />
        <DesktopKpiBox label="Total Rate Value" value={`$${totalRateValue.toLocaleString()}`} />
      </DesktopKpiStrip>

      <SearchBar placeholder="Search loads by load number..." />

      {podMissingOnly && (
        <div className="flex items-center justify-between rounded-lg border border-warning/30 bg-warning/5 px-3 py-2 text-sm">
          <span>Showing delivered loads missing a verified Proof of Delivery.</span>
          <Link href="/loads" className="text-xs font-medium text-primary hover:underline">
            Clear filter
          </Link>
        </div>
      )}

      {loads.length === 0 ? (
        <EmptyState
          title={podMissingOnly ? "No delivered loads are missing POD" : q ? "No loads match your search" : "No loads yet"}
          description={
            podMissingOnly
              ? "Every delivered load has a verified Proof of Delivery on file."
              : q
                ? "Try a different search term."
                : "Book your first load to start dispatching."
          }
          action={{ label: "Add Load", href: "/loads/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={loads}
          getDetailHref={(row) => `/loads/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "loads", row.id, "/loads")}
        />
      )}
    </div>
  );
}
