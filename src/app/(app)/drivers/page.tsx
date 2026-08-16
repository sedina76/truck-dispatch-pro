import Link from "next/link";
import { UserPlus } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { isActiveLoadStatus, isCompletedLoadStatus } from "@/lib/loads/status";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

type Driver = {
  id: string;
  first_name: string;
  last_name: string;
  phone: string | null;
  cdl_number: string | null;
  cdl_expiry_date: string | null;
  status: string;
  carriers: { legal_name: string } | null;
};

// Trip stats per driver -- derived from dispatches + loads (dispatches is
// the actual driver<->load relationship; loads has no driver_id of its
// own). Uses the same canonical status definitions (src/lib/loads/status.ts)
// as the driver detail page's Trip History, so the two always agree.
type DriverTripSummary = { completedTrips: number; activeTrips: number; totalMiles: number; revenue: number };

function complianceTone(expiry: string | null): "valid" | "expiring_soon" | "expired" | "missing" {
  if (!expiry) return "missing";
  const days = (new Date(expiry).getTime() - Date.now()) / 86_400_000;
  if (days < 0) return "expired";
  if (days <= 30) return "expiring_soon";
  return "valid";
}

export default async function DriversPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("drivers")
    .select("id, first_name, last_name, phone, cdl_number, cdl_expiry_date, status, carriers(legal_name)")
    .order("last_name");
  if (q) query = query.or(`first_name.ilike.%${q}%,last_name.ilike.%${q}%`);

  const { data } = await query;
  const drivers = (data ?? []) as unknown as Driver[];

  const { count: totalCount } = await supabase
    .from("drivers")
    .select("id", { count: "exact", head: true });
  const { count: activeCount } = await supabase
    .from("drivers")
    .select("id", { count: "exact", head: true })
    .eq("status", "active");
  const { count: newApplicationsCount } = await supabase
    .from("driver_applications")
    .select("id", { count: "exact", head: true })
    .eq("status", "submitted");

  const { data: dispatchRows } = await supabase
    .from("dispatches")
    .select("driver_id, carrier_net_amount, loads(status, total_miles)");

  const tripSummaryByDriver = new Map<string, DriverTripSummary>();
  for (const row of (dispatchRows ?? []) as unknown as {
    driver_id: string;
    carrier_net_amount: number;
    loads: { status: string; total_miles: number | null } | null;
  }[]) {
    if (!row.loads) continue;
    const summary = tripSummaryByDriver.get(row.driver_id) ?? {
      completedTrips: 0,
      activeTrips: 0,
      totalMiles: 0,
      revenue: 0,
    };
    if (isCompletedLoadStatus(row.loads.status)) summary.completedTrips += 1;
    if (isActiveLoadStatus(row.loads.status)) summary.activeTrips += 1;
    summary.totalMiles += row.loads.total_miles ?? 0;
    summary.revenue += Number(row.carrier_net_amount);
    tripSummaryByDriver.set(row.driver_id, summary);
  }

  const expiringSoon = drivers.filter((d) => complianceTone(d.cdl_expiry_date) === "expiring_soon").length;
  const expired = drivers.filter((d) => complianceTone(d.cdl_expiry_date) === "expired").length;

  const columns: Column<Driver>[] = [
    {
      header: "Driver",
      cell: (row) => (
        <span className="font-medium">
          {row.first_name} {row.last_name}
        </span>
      ),
    },
    { header: "Carrier", cell: (row) => row.carriers?.legal_name ?? "--" },
    { header: "Phone", cell: (row) => row.phone ?? "--" },
    { header: "CDL #", cell: (row) => row.cdl_number ?? "--" },
    {
      header: "CDL Expiry",
      cell: (row) => (
        <div className="flex items-center gap-2">
          <span>{row.cdl_expiry_date ?? "--"}</span>
          {row.cdl_expiry_date && <StatusBadge status={complianceTone(row.cdl_expiry_date)} />}
        </div>
      ),
    },
    { header: "Completed Trips", cell: (row) => tripSummaryByDriver.get(row.id)?.completedTrips ?? 0 },
    { header: "Active Trips", cell: (row) => tripSummaryByDriver.get(row.id)?.activeTrips ?? 0 },
    {
      header: "Total Miles",
      cell: (row) => (tripSummaryByDriver.get(row.id)?.totalMiles ?? 0).toLocaleString(),
    },
    {
      header: "Revenue",
      cell: (row) => `$${Math.round(tripSummaryByDriver.get(row.id)?.revenue ?? 0).toLocaleString()}`,
    },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Drivers", href: "/drivers" }]} />
      <RegisterDesktopActions title="Drivers" exportOptions={[{ label: "Export CSV (Filtered)", href: `/drivers/export${q ? `?q=${encodeURIComponent(q)}` : ""}` }]} />
      <PageHeader
        title="Drivers"
        description="Drivers across all carriers, with CDL and medical card status."
        primaryAction={{ label: "Add Driver", href: "/drivers/new" }}
      />

      <Link
        href="/drivers/applications"
        className="inline-flex items-center gap-1.5 text-[12.5px] font-medium text-primary hover:underline"
      >
        <UserPlus className="size-3.5" />
        Driver Applications
        {!!newApplicationsCount && (
          <span className="ml-1 rounded-sm bg-primary/10 px-1.5 py-0.5 text-[10.5px] font-semibold">
            {newApplicationsCount} new
          </span>
        )}
      </Link>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Drivers" value={totalCount ?? 0} />
        <DesktopKpiBox label="Active" value={activeCount ?? 0} tone="success" />
        <DesktopKpiBox label="CDL Expiring (30d)" value={expiringSoon} tone={expiringSoon ? "warning" : "neutral"} />
        <DesktopKpiBox label="CDL Expired" value={expired} tone={expired ? "danger" : "neutral"} />
      </DesktopKpiStrip>

      <SearchBar placeholder="Search drivers by name..." />

      {drivers.length === 0 ? (
        <EmptyState
          title={q ? "No drivers match your search" : "No drivers yet"}
          description={q ? "Try a different search term." : "Add a driver to assign them to trucks and dispatches."}
          action={{ label: "Add Driver", href: "/drivers/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={drivers}
          getDetailHref={(row) => `/drivers/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "drivers", row.id, "/drivers")}
        />
      )}
    </div>
  );
}
