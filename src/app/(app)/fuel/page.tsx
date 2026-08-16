import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DataTable, type Column } from "@/components/ui/data-table";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { SearchBar } from "@/components/ui/search-bar";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider } from "@/components/desktop/collapsible-section";
import { FuelFilterBar } from "@/components/fuel/fuel-filter-bar";
import { resolveEquipmentCarrier } from "@/lib/equipment/carrier-derivation";
import { getFuelKpis, groupFuelSpend, type FuelBreakdownRow } from "./fuel-data";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 0 })}`;
}

type FuelLogRow = {
  id: string;
  gallons: number;
  total_amount: number;
  station_name: string | null;
  state: string | null;
  purchased_at: string;
  paid_by: string;
  recovery_type: string;
  recovery_status: string;
  trucks: { unit_number: string } | null;
  drivers: { first_name: string; last_name: string } | null;
  carriers: { legal_name: string } | null;
};

type ReportRow = { gallons: number; total_amount: number; truck_id: string | null; carrier_id: string | null; driver_id: string | null; state: string | null; station_name: string | null; purchased_at: string };

export default async function FuelPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; truck_id?: string; carrier_id?: string }>;
}) {
  const sp = await searchParams;
  const supabase = await createClient();

  const kpis = await getFuelKpis(supabase);

  const [{ data: trucksRaw }, { data: carriers }] = await Promise.all([
    supabase.from("trucks").select("id, unit_number, carrier_id, carriers(legal_name)").order("unit_number"),
    supabase.from("carriers").select("id, legal_name").order("legal_name"),
  ]);
  const trucks = (trucksRaw ?? []).map((t) => {
    const row = t as unknown as { id: string; unit_number: string; carrier_id: string | null; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null };
  });

  // Truck -> Carrier derivation for the list filters (spec FUEL LOG
  // FILTERS / CARRIER -> TRUCK), same shared rule as Log/Edit Fuel
  // Purchase and Maintenance -- never a second implementation. A client-
  // supplied carrier_id is never trusted once a selected truck resolves
  // its own canonical carrier (spec SERVER-SIDE AUTHORITY): the derived
  // carrier always wins for the actual query below.
  const selectedTruck = sp.truck_id ? trucks.find((t) => t.id === sp.truck_id) ?? null : null;
  const derivation = resolveEquipmentCarrier(selectedTruck, null);
  const effectiveCarrierId = derivation.kind === "resolved" ? derivation.carrierId : sp.carrier_id || null;

  let query = supabase
    .from("fuel_logs")
    // drivers!fuel_logs_driver_id_fkey -- explicit relationship hint
    // required as of 0051: fuel_logs now has TWO FKs into drivers
    // (driver_id "who purchased fuel" and responsible_driver_id "who
    // owes for it"), so a bare drivers(...) embed is ambiguous to
    // PostgREST (confirmed live -- PGRST201, "more than one relationship
    // was found"). This embed is specifically the purchaser, driver_id.
    .select("id, gallons, total_amount, station_name, state, purchased_at, paid_by, recovery_type, recovery_status, trucks(unit_number), drivers!fuel_logs_driver_id_fkey(first_name, last_name), carriers(legal_name)")
    .order("purchased_at", { ascending: false });
  if (sp.q) query = query.ilike("station_name", `%${sp.q}%`);
  if (sp.truck_id) query = query.eq("truck_id", sp.truck_id);
  if (effectiveCarrierId) query = query.eq("carrier_id", effectiveCarrierId);

  const { data } = await query;
  const logs = (data ?? []) as unknown as FuelLogRow[];

  // Reporting breakdowns (spec section 20) -- one full-org fetch, grouped
  // client-side in several ways, rather than five separate GROUP BY
  // round-trips. Not filtered by the list's own q/truck/carrier params --
  // these are fleet-wide operating metrics, matching how the KPI strip
  // above is also unfiltered.
  const { data: reportRows } = await supabase.from("fuel_logs").select("gallons, total_amount, truck_id, carrier_id, driver_id, state, station_name, purchased_at, trucks(unit_number), carriers(legal_name), drivers!fuel_logs_driver_id_fkey(first_name, last_name)");
  const rr = (reportRows ?? []) as unknown as (ReportRow & { trucks: { unit_number: string } | null; carriers: { legal_name: string } | null; drivers: { first_name: string; last_name: string } | null })[];

  const byTruck = groupFuelSpend(rr, (r) => r.trucks?.unit_number ?? null);
  const byCarrier = groupFuelSpend(rr, (r) => r.carriers?.legal_name ?? null);
  const byDriver = groupFuelSpend(rr, (r) => (r.drivers ? `${r.drivers.first_name} ${r.drivers.last_name}` : null));
  const byState = groupFuelSpend(rr, (r) => r.state);
  const byStation = groupFuelSpend(rr, (r) => r.station_name);

  const monthlyMap = new Map<string, { gallons: number; totalAmount: number }>();
  for (const r of rr) {
    const month = r.purchased_at.slice(0, 7);
    const existing = monthlyMap.get(month) ?? { gallons: 0, totalAmount: 0 };
    existing.gallons += Number(r.gallons);
    existing.totalAmount += Number(r.total_amount);
    monthlyMap.set(month, existing);
  }
  const monthlyTrend = [...monthlyMap.entries()].sort((a, b) => b[0].localeCompare(a[0])).slice(0, 12);

  const columns: Column<FuelLogRow>[] = [
    { header: "Truck", cell: (row) => <span className="font-medium">{row.trucks?.unit_number ?? "--"}</span> },
    { header: "Carrier", cell: (row) => row.carriers?.legal_name ?? "--" },
    { header: "Driver", cell: (row) => (row.drivers ? `${row.drivers.first_name} ${row.drivers.last_name}` : "--") },
    { header: "Station", cell: (row) => row.station_name ?? "--" },
    { header: "Gallons", cell: (row) => Number(row.gallons).toFixed(1) },
    { header: "Total", cell: (row) => money(row.total_amount) },
    { header: "Paid By", cell: (row) => row.paid_by.replace(/_/g, " ") },
    { header: "Recovery", cell: (row) => <StatusBadge status={row.recovery_status} /> },
    { header: "Date", cell: (row) => new Date(row.purchased_at).toLocaleDateString() },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Fuel Logs"
        description="Fuel purchases across your fleet -- who paid, and what's recoverable from a carrier or driver."
        primaryAction={{ label: "Log Fuel Purchase", href: "/fuel/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Gross Fuel Spend" value={money(kpis.grossFuelSpend)} />
        <DesktopKpiBox label="Carrier Recovery" value={money(kpis.carrierFuelRecovery)} tone={kpis.carrierFuelRecovery ? "success" : "neutral"} />
        <DesktopKpiBox label="Driver Recovery" value={money(kpis.driverFuelRecovery)} tone={kpis.driverFuelRecovery ? "success" : "neutral"} />
        <DesktopKpiBox label="Net Fuel Cost" value={money(kpis.netFuelCost)} tone="primary" />
        <DesktopKpiBox label="Gallons Purchased" value={kpis.gallonsPurchased.toLocaleString(undefined, { maximumFractionDigits: 0 })} />
        <DesktopKpiBox label="Avg $/Gallon" value={`$${kpis.avgPricePerGallon.toFixed(2)}`} />
        <DesktopKpiBox label="Fleet Avg MPG" value={kpis.fleetAvgMpg != null ? kpis.fleetAvgMpg.toFixed(1) : "--"} />
      </DesktopKpiStrip>

      {/* URL-driven, auto-applying filters -- no separate Filter button
          (spec AUTO-APPLY FILTERS), same idiom as the Maintenance
          workspace filter bar and the existing SearchBar. Truck/Carrier
          are dependent (FuelFilterBar); Station search stays the
          existing, already-proven SearchBar component, unchanged. */}
      <div className="flex flex-wrap items-end gap-2 rounded-md border border-desktop-border bg-desktop-panel p-3">
        <SearchBar placeholder="Search by station name..." />
        <FuelFilterBar trucks={trucks} carriers={carriers ?? []} />
      </div>

      {logs.length === 0 ? (
        <EmptyState
          title={sp.q || sp.truck_id || sp.carrier_id ? "No fuel logs match your filters" : "No fuel logs yet"}
          description={
            derivation.kind === "resolved" && selectedTruck
              ? `No fuel logs found for Truck ${selectedTruck.unit_number}.`
              : sp.q || sp.truck_id || sp.carrier_id
                ? "Try different filters."
                : "Log a fuel purchase to start tracking fleet fuel costs and recovery."
          }
          action={{ label: "Log Fuel Purchase", href: "/fuel/new" }}
        />
      ) : (
        <DataTable columns={columns} rows={logs} getDetailHref={(row) => `/fuel/${row.id}`} />
      )}

      <CollapsibleSectionsProvider defaults={{ reporting: false }}>
        <DesktopCollapsibleSection id="reporting" title="Reporting">
          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <BreakdownTable title="Spend by Truck" rows={byTruck} />
            <BreakdownTable title="Spend by Carrier" rows={byCarrier} />
            <BreakdownTable title="Spend by Driver" rows={byDriver} />
            <BreakdownTable title="Spend by State" rows={byState} />
            <BreakdownTable title="Spend by Station" rows={byStation} />
            <div>
              <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Monthly Trend</p>
              <table className="w-full text-[12.5px]">
                <thead>
                  <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                    <th className="py-1.5 pr-3">Month</th>
                    <th className="py-1.5 pr-3 text-right">Gallons</th>
                    <th className="py-1.5 pr-3 text-right">Total</th>
                  </tr>
                </thead>
                <tbody>
                  {monthlyTrend.map(([month, v]) => (
                    <tr key={month} className="border-b border-desktop-border last:border-0">
                      <td className="py-1.5 pr-3">{month}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{v.gallons.toFixed(0)}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums font-medium">{money(v.totalAmount)}</td>
                    </tr>
                  ))}
                  {monthlyTrend.length === 0 && <tr><td colSpan={3} className="py-3 text-center text-muted-foreground">No data yet.</td></tr>}
                </tbody>
              </table>
            </div>
          </div>
        </DesktopCollapsibleSection>
      </CollapsibleSectionsProvider>
    </div>
  );
}

function BreakdownTable({ title, rows }: { title: string; rows: FuelBreakdownRow[] }) {
  return (
    <div>
      <p className="mb-1.5 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{title}</p>
      <table className="w-full text-[12.5px]">
        <thead>
          <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
            <th className="py-1.5 pr-3">Label</th>
            <th className="py-1.5 pr-3 text-right">Gallons</th>
            <th className="py-1.5 pr-3 text-right">Total</th>
          </tr>
        </thead>
        <tbody>
          {rows.slice(0, 10).map((r) => (
            <tr key={r.label} className="border-b border-desktop-border last:border-0">
              <td className="py-1.5 pr-3">{r.label}</td>
              <td className="py-1.5 pr-3 text-right tabular-nums">{r.gallons.toFixed(0)}</td>
              <td className="py-1.5 pr-3 text-right tabular-nums font-medium">{money(r.totalAmount)}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={3} className="py-3 text-center text-muted-foreground">No data yet.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}
