import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type Truck = {
  id: string;
  unit_number: string;
  make: string | null;
  model: string | null;
  year: number | null;
  status: string;
  current_odometer: number | null;
  carriers: { legal_name: string } | null;
};

export default async function TrucksPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("trucks")
    .select("id, unit_number, make, model, year, status, current_odometer, carriers(legal_name)")
    .order("unit_number");
  if (q) query = query.ilike("unit_number", `%${q}%`);

  const { data } = await query;
  const trucks = (data ?? []) as unknown as Truck[];

  const { count: totalCount } = await supabase.from("trucks").select("id", { count: "exact", head: true });
  const { count: activeCount } = await supabase
    .from("trucks")
    .select("id", { count: "exact", head: true })
    .eq("status", "active");
  const { count: maintenanceCount } = await supabase
    .from("trucks")
    .select("id", { count: "exact", head: true })
    .eq("status", "in_maintenance");

  const columns: Column<Truck>[] = [
    { header: "Unit #", cell: (row) => <span className="font-medium">{row.unit_number}</span> },
    { header: "Carrier", cell: (row) => row.carriers?.legal_name ?? "--" },
    {
      header: "Make / Model / Year",
      cell: (row) => [row.make, row.model, row.year].filter(Boolean).join(" ") || "--",
    },
    {
      header: "Odometer",
      cell: (row) => (row.current_odometer ? `${row.current_odometer.toLocaleString()} mi` : "--"),
    },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Trucks"
        description="Fleet trucks across all carriers."
        primaryAction={{ label: "Add Truck", href: "/trucks/new" }}
      />

      <KpiRow>
        <KpiCard label="Total Trucks" value={totalCount ?? 0} />
        <KpiCard label="Active" value={activeCount ?? 0} />
        <KpiCard label="In Maintenance" value={maintenanceCount ?? 0} tone={maintenanceCount ? "warning" : "neutral"} />
        <KpiCard label="Other" value={(totalCount ?? 0) - (activeCount ?? 0) - (maintenanceCount ?? 0)} />
      </KpiRow>

      <SearchBar placeholder="Search trucks by unit number..." />

      {trucks.length === 0 ? (
        <EmptyState
          title={q ? "No trucks match your search" : "No trucks yet"}
          description={q ? "Try a different search term." : "Add a truck to assign it to dispatches."}
          action={{ label: "Add Truck", href: "/trucks/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={trucks}
          getDetailHref={(row) => `/trucks/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "trucks", row.id, "/trucks")}
        />
      )}
    </div>
  );
}
