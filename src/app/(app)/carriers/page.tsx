import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

type Carrier = {
  id: string;
  legal_name: string;
  dba_name: string | null;
  mc_number: string | null;
  dot_number: string | null;
  contact_name: string | null;
  phone: string | null;
  dispatch_fee_percentage?: number;
  is_active: boolean;
};

// Phase 2G.10 (item 6 full search): same missed-list-page gap as Brokers/
// Customers -- Carriers is Business, open to every role, no layout guard.
export default async function CarriersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  // Phase 2G.12: dispatch_fee_percentage dropped from this select --
  // 2G.10's writer cutover moved it to carrier_financials; carriers' own
  // copy is stale the moment it's edited. Merged in below from a separate
  // query, issued only when canSeeFinancials.
  let query = supabase
    .from("carriers")
    .select("id, legal_name, dba_name, mc_number, dot_number, contact_name, phone, is_active")
    .order("legal_name");

  if (q) query = query.ilike("legal_name", `%${q}%`);

  const { data } = await query;
  const carriersRaw = (data ?? []) as unknown as Omit<Carrier, "dispatch_fee_percentage">[];

  const carrierIds = carriersRaw.map((c) => c.id);
  const feeByCarrierId = new Map<string, number>();
  if (canSeeFinancials && carrierIds.length > 0) {
    const { data: financialsRows } = await supabase.from("carrier_financials").select("carrier_id, dispatch_fee_percentage").in("carrier_id", carrierIds);
    for (const row of financialsRows ?? []) feeByCarrierId.set(row.carrier_id, Number(row.dispatch_fee_percentage));
  }
  const carriers: Carrier[] = carriersRaw.map((c) => ({ ...c, dispatch_fee_percentage: feeByCarrierId.get(c.id) }));

  const { count: totalCount } = await supabase
    .from("carriers")
    .select("id", { count: "exact", head: true });
  const { count: activeCount } = await supabase
    .from("carriers")
    .select("id", { count: "exact", head: true })
    .eq("is_active", true);

  const avgFee =
    canSeeFinancials && carriers.length > 0
      ? (
          carriers.reduce((sum, c) => sum + Number(c.dispatch_fee_percentage ?? 0), 0) /
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
    ...(canSeeFinancials ? [{ header: "Fee %", cell: (row: Carrier) => `${Number(row.dispatch_fee_percentage ?? 0).toFixed(2)}%` }] : []),
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
        {canSeeFinancials && <KpiCard label="Avg Dispatch Fee" value={`${avgFee}%`} />}
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
