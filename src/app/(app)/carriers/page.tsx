import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type Carrier = {
  id: string;
  legal_name: string;
  dba_name: string | null;
  mc_number: string | null;
  dot_number: string | null;
  contact_name: string | null;
  phone: string | null;
  dispatch_fee_percentage: number;
  is_active: boolean;
};

export default async function CarriersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("carriers")
    .select(
      "id, legal_name, dba_name, mc_number, dot_number, contact_name, phone, dispatch_fee_percentage, is_active"
    )
    .order("legal_name");

  if (q) query = query.ilike("legal_name", `%${q}%`);

  const { data } = await query;
  const carriers = (data ?? []) as Carrier[];

  const { count: totalCount } = await supabase
    .from("carriers")
    .select("id", { count: "exact", head: true });
  const { count: activeCount } = await supabase
    .from("carriers")
    .select("id", { count: "exact", head: true })
    .eq("is_active", true);

  const avgFee =
    carriers.length > 0
      ? (
          carriers.reduce((sum, c) => sum + Number(c.dispatch_fee_percentage), 0) /
          carriers.length
        ).toFixed(1)
      : "0.0";

  const columns: Column<Carrier>[] = [
    {
      header: "Carrier",
      cell: (row) => (
        <div>
          <p className="font-medium">{row.legal_name}</p>
          {row.dba_name && (
            <p className="text-xs text-[var(--color-text-muted)]">dba {row.dba_name}</p>
          )}
        </div>
      ),
    },
    { header: "MC / DOT", cell: (row) => `${row.mc_number ?? "--"} / ${row.dot_number ?? "--"}` },
    { header: "Contact", cell: (row) => row.contact_name ?? "--" },
    { header: "Phone", cell: (row) => row.phone ?? "--" },
    { header: "Fee %", cell: (row) => `${Number(row.dispatch_fee_percentage).toFixed(2)}%` },
    {
      header: "Status",
      cell: (row) => <StatusBadge status={row.is_active ? "active" : "inactive"} />,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Carriers"
        description="Manage the trucking companies you dispatch for."
        primaryAction={{ label: "Add Carrier", href: "/carriers/new" }}
      />

      <KpiRow>
        <KpiCard label="Total Carriers" value={totalCount ?? 0} />
        <KpiCard label="Active" value={activeCount ?? 0} />
        <KpiCard label="Inactive" value={(totalCount ?? 0) - (activeCount ?? 0)} />
        <KpiCard label="Avg Dispatch Fee" value={`${avgFee}%`} />
      </KpiRow>

      <SearchBar placeholder="Search carriers by name..." />

      {carriers.length === 0 ? (
        <EmptyState
          title={q ? "No carriers match your search" : "No carriers yet"}
          description={
            q
              ? "Try a different search term."
              : "Add your first carrier to start assigning loads and dispatches."
          }
          action={{ label: "Add Carrier", href: "/carriers/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={carriers}
          getDetailHref={(row) => `/carriers/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "carriers", row.id, "/carriers")}
        />
      )}
    </div>
  );
}
