import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type Trailer = {
  id: string;
  unit_number: string;
  trailer_type: string | null;
  length_ft: number | null;
  status: string;
  carriers: { legal_name: string } | null;
};

export default async function TrailersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("trailers")
    .select("id, unit_number, trailer_type, length_ft, status, carriers(legal_name)")
    .order("unit_number");
  if (q) query = query.ilike("unit_number", `%${q}%`);

  const { data } = await query;
  const trailers = (data ?? []) as unknown as Trailer[];

  const { count: totalCount } = await supabase.from("trailers").select("id", { count: "exact", head: true });
  const { count: activeCount } = await supabase
    .from("trailers")
    .select("id", { count: "exact", head: true })
    .eq("status", "active");

  const columns: Column<Trailer>[] = [
    { header: "Unit #", cell: (row) => <span className="font-medium">{row.unit_number}</span> },
    { header: "Carrier", cell: (row) => row.carriers?.legal_name ?? "Unassigned" },
    { header: "Type", cell: (row) => row.trailer_type ?? "--" },
    { header: "Length", cell: (row) => (row.length_ft ? `${row.length_ft} ft` : "--") },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Trailers"
        description="Fleet trailers across all carriers."
        primaryAction={{ label: "Add Trailer", href: "/trailers/new" }}
      />

      <KpiRow>
        <KpiCard label="Total Trailers" value={totalCount ?? 0} />
        <KpiCard label="Active" value={activeCount ?? 0} />
        <KpiCard label="Other" value={(totalCount ?? 0) - (activeCount ?? 0)} />
      </KpiRow>

      <SearchBar placeholder="Search trailers by unit number..." />

      {trailers.length === 0 ? (
        <EmptyState
          title={q ? "No trailers match your search" : "No trailers yet"}
          description={q ? "Try a different search term." : "Add a trailer to assign it to dispatches."}
          action={{ label: "Add Trailer", href: "/trailers/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={trailers}
          getDetailHref={(row) => `/trailers/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "trailers", row.id, "/trailers")}
        />
      )}
    </div>
  );
}
