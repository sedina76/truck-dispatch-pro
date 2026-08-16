import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DataTable, type Column } from "@/components/ui/data-table";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { getMaintenanceKpis, computePreventiveMaintenanceStatus } from "./maintenance-data";
import { resolveEquipmentCarrier } from "@/lib/equipment/carrier-derivation";
import { MaintenanceFilterBar, type EquipmentOption, type CarrierOption } from "@/components/maintenance/maintenance-filter-bar";

const TABS = [
  { key: "all", label: "Maintenance" },
  { key: "preventive", label: "Preventive Maintenance" },
  { key: "history", label: "Repair History" },
  { key: "upcoming", label: "Upcoming Service" },
  { key: "out_of_service", label: "Out of Service" },
  { key: "recoveries", label: "Recoveries" },
] as const;
type TabKey = (typeof TABS)[number]["key"];
const RECOVERY_TAB_STATUSES = ["pending", "partially_recovered", "recovered"] as const;

// Human-readable noun per tab, used to build a specific empty-state
// message (spec EMPTY STATES: "No maintenance records found for Truck
// T-112." / "No recovery records found for Carrier X.") rather than a
// blank table with no explanation.
const RECORD_NOUN: Record<TabKey, string> = {
  all: "maintenance records",
  preventive: "preventive maintenance records",
  history: "repair history records",
  upcoming: "upcoming service records",
  out_of_service: "equipment records",
  recoveries: "recovery records",
};

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 0 })}`;
}

const PM_STATUS_LABEL: Record<string, string> = { not_scheduled: "Not Scheduled", ok: "OK", due_soon: "Due Soon", due: "Due", overdue: "Overdue" };
const PM_STATUS_TONE: Record<string, "neutral" | "warning" | "danger"> = { not_scheduled: "neutral", ok: "neutral", due_soon: "warning", due: "warning", overdue: "danger" };

type MaintenanceRow = {
  id: string;
  service_type: string;
  cost: number;
  service_date: string;
  next_service_due_date: string | null;
  next_service_due_odometer: number | null;
  vendor_name: string | null;
  status: string;
  paid_by: string;
  recovery_type: string;
  recovery_status: string;
  recoverable_amount: number;
  recovered_amount: number;
  truck_id: string | null;
  trailer_id: string | null;
  trucks: { unit_number: string; current_odometer: number | null } | null;
  trailers: { unit_number: string } | null;
  carriers: { legal_name: string } | null;
};

// Builds "for Truck T-112" / "for Carrier X" / "for Truck T-112 and
// Trailer TR-9" -- appended into empty-state copy so a filtered-to-zero
// result always explains itself (spec EMPTY STATES). Falls back to
// nothing when the id in the URL doesn't resolve to a real, org-scoped
// unit (e.g. a cross-org id) -- never leaks another organization's data
// into this message.
function describeFilterContext(truck: EquipmentOption | null, trailer: EquipmentOption | null, carrierName: string | null): string {
  const parts: string[] = [];
  if (truck) parts.push(`Truck ${truck.unit_number}`);
  if (trailer) parts.push(`Trailer ${trailer.unit_number}`);
  if (parts.length === 0 && carrierName) parts.push(carrierName);
  if (parts.length === 0) return "";
  return ` for ${parts.join(" and ")}`;
}

export default async function MaintenancePage({
  searchParams,
}: {
  searchParams: Promise<{ view?: string; truck_id?: string; trailer_id?: string; carrier_id?: string; service_type?: string; status?: string; paid_by?: string; recovery_status?: string }>;
}) {
  const sp = await searchParams;
  const view = (TABS.find((t) => t.key === sp.view)?.key ?? "all") as TabKey;
  const supabase = await createClient();

  const kpis = await getMaintenanceKpis(supabase);

  // carrier_id/carrier name are fetched on trucks/trailers here (a
  // read-only addition to the existing SELECT) so BOTH the filter bar
  // (dependent dropdown restriction, spec CARRIER -> EQUIPMENT) and this
  // page's own server-side derivation/mismatch/security checks below can
  // work from real, already-org-scoped-by-RLS equipment data -- no new
  // query pattern, no financial/recovery table touched.
  const [{ data: trucksRaw }, { data: trailersRaw }, { data: carriers }] = await Promise.all([
    supabase.from("trucks").select("id, unit_number, carrier_id, carriers(legal_name)").order("unit_number"),
    supabase.from("trailers").select("id, unit_number, carrier_id, carriers(legal_name)").order("unit_number"),
    supabase.from("carriers").select("id, legal_name").order("legal_name"),
  ]);
  const trucks: EquipmentOption[] = (trucksRaw ?? []).map((t) => {
    const row = t as unknown as { id: string; unit_number: string; carrier_id: string | null; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null };
  });
  const trailers: EquipmentOption[] = (trailersRaw ?? []).map((t) => {
    const row = t as unknown as { id: string; unit_number: string; carrier_id: string | null; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null };
  });
  const carrierOptions: CarrierOption[] = carriers ?? [];

  // Truck/Trailer -> Carrier derivation, THE SAME shared rule already
  // live-verified for Log/Edit Maintenance (guard_maintenance_org, 0050)
  // -- resolveEquipmentCarrier() is the single implementation, reused
  // here for filtering rather than reinvented. A truck_id/trailer_id in
  // the URL that doesn't resolve to a real, org-scoped unit (deleted, or
  // a cross-org id under RLS) simply finds nothing here and is treated as
  // not selected for DERIVATION purposes -- the raw id is still passed to
  // the actual query below, where RLS/the existing guard triggers ensure
  // it can only ever match zero rows (spec SECURITY).
  const selectedTruck = sp.truck_id ? trucks.find((t) => t.id === sp.truck_id) ?? null : null;
  const selectedTrailer = sp.trailer_id ? trailers.find((t) => t.id === sp.trailer_id) ?? null : null;
  const derivation = resolveEquipmentCarrier(selectedTruck, selectedTrailer);

  // A client-supplied carrier_id is NEVER trusted once a truck or trailer
  // resolves its own canonical carrier (spec TRUCK -> CARRIER: "Do not
  // trust a client-supplied carrier ID if the selected truck has a
  // legitimate carrier") -- the derived carrier always wins for query
  // purposes; an independently-set carrier_id only applies when nothing
  // else resolves one.
  const effectiveCarrierId = derivation.kind === "resolved" ? derivation.carrierId : sp.carrier_id || null;
  const effectiveCarrierName = derivation.kind === "resolved" ? derivation.carrierName : carrierOptions.find((c) => c.id === effectiveCarrierId)?.legal_name ?? null;
  const filterContext = describeFilterContext(selectedTruck, selectedTrailer, effectiveCarrierName);

  // Tab links carry every current filter forward (spec TAB SWITCHING:
  // "still scoped to T-112") -- including Status/Recovery Status. That's
  // safe even when a value is meaningless for the destination tab
  // (History always means Completed; only the Recoveries tab's own fixed
  // set applies to recovery_status): the query-building logic below
  // already ignores/narrows those exact cases per-tab rather than ANDing
  // a contradictory condition, so a carried-over value is inert on a tab
  // where it doesn't apply -- never a silent zero-result trap.
  const preservedParams = new URLSearchParams();
  if (sp.truck_id) preservedParams.set("truck_id", sp.truck_id);
  if (sp.trailer_id) preservedParams.set("trailer_id", sp.trailer_id);
  if (derivation.kind !== "resolved" && sp.carrier_id) preservedParams.set("carrier_id", sp.carrier_id);
  if (sp.paid_by) preservedParams.set("paid_by", sp.paid_by);
  if (sp.status) preservedParams.set("status", sp.status);
  if (sp.recovery_status) preservedParams.set("recovery_status", sp.recovery_status);

  const kpiStrip = (
    <DesktopKpiStrip>
      <DesktopKpiBox label="Due Soon" value={kpis.dueSoon} tone={kpis.dueSoon ? "warning" : "neutral"} href="/maintenance?view=upcoming" />
      <DesktopKpiBox label="Overdue" value={kpis.overdue} tone={kpis.overdue ? "danger" : "neutral"} href="/maintenance?view=upcoming" />
      <DesktopKpiBox label="Out of Service" value={kpis.outOfService} tone={kpis.outOfService ? "danger" : "neutral"} href="/maintenance?view=out_of_service" />
      <DesktopKpiBox label="Open Repairs" value={kpis.openRepairs} tone={kpis.openRepairs ? "warning" : "neutral"} />
      <DesktopKpiBox label="Spend This Month" value={money(kpis.spendThisMonth)} />
      <DesktopKpiBox label="Pending Recoveries" value={money(kpis.pendingRecoveries)} tone={kpis.pendingRecoveries ? "warning" : "neutral"} href="/maintenance?view=recoveries" />
    </DesktopKpiStrip>
  );

  const filterBar = (
    <MaintenanceFilterBar
      view={view}
      trucks={trucks}
      trailers={trailers}
      carriers={carrierOptions}
      showMaintenanceFilters={view !== "out_of_service"}
    />
  );

  // A truck+trailer combination that resolves to two DIFFERENT real
  // carriers is contradictory -- spec TRUCK/TRAILER MISMATCH: "do not
  // issue a contradictory query... never silently choose one." No
  // maintenance_records/equipment query runs at all in this state; the
  // filter bar's own inline banner (same derivation) plus this message
  // are the only things rendered, on every one of the six tabs.
  if (derivation.kind === "mismatch") {
    return (
      <div className="space-y-6">
        <PageHeader title="Maintenance" description="Service history and preventive maintenance for trucks and trailers." primaryAction={{ label: "Log Maintenance", href: "/maintenance/new" }} />
        {kpiStrip}
        <TabBar active={view} queryString={preservedParams.toString()} />
        {filterBar}
        <EmptyState
          title="Truck and trailer belong to different carriers"
          description={`The selected truck belongs to ${derivation.truckCarrierName ?? "an unassigned carrier"} and the selected trailer belongs to ${derivation.trailerCarrierName ?? "an unassigned carrier"}. Change one selection to view results.`}
          action={{ label: "Log Maintenance", href: "/maintenance/new" }}
        />
      </div>
    );
  }

  // OUT OF SERVICE tab shows EQUIPMENT, not maintenance records -- a
  // deliberately different shape/query (spec PHASE 2 lists it as its own
  // workspace view). Truck/Trailer/Carrier filters now apply here too
  // (spec SIX-TAB CONSISTENCY) using the exact same derived carrier
  // computed above -- no second derivation rule.
  if (view === "out_of_service") {
    const showTrucks = !(sp.trailer_id && !sp.truck_id);
    const showTrailers = !(sp.truck_id && !sp.trailer_id);

    let oosTrucksQuery = supabase.from("trucks").select("id, unit_number, status, carriers(legal_name)").in("status", ["out_of_service", "in_maintenance"]).order("unit_number");
    if (sp.truck_id) oosTrucksQuery = oosTrucksQuery.eq("id", sp.truck_id);
    else if (effectiveCarrierId) oosTrucksQuery = oosTrucksQuery.eq("carrier_id", effectiveCarrierId);

    let oosTrailersQuery = supabase.from("trailers").select("id, unit_number, status, carriers(legal_name)").in("status", ["out_of_service", "in_maintenance"]).order("unit_number");
    if (sp.trailer_id) oosTrailersQuery = oosTrailersQuery.eq("id", sp.trailer_id);
    else if (effectiveCarrierId) oosTrailersQuery = oosTrailersQuery.eq("carrier_id", effectiveCarrierId);

    const [{ data: oosTrucks }, { data: oosTrailers }] = await Promise.all([
      showTrucks ? oosTrucksQuery : Promise.resolve({ data: [] }),
      showTrailers ? oosTrailersQuery : Promise.resolve({ data: [] }),
    ]);
    const units = [...(oosTrucks ?? []).map((t) => ({ ...t, kind: "Truck" })), ...(oosTrailers ?? []).map((t) => ({ ...t, kind: "Trailer" }))];

    return (
      <div className="space-y-6">
        <PageHeader title="Maintenance" description="Service history and preventive maintenance for trucks and trailers." primaryAction={{ label: "Log Maintenance", href: "/maintenance/new" }} />
        {kpiStrip}
        <TabBar active={view} queryString={preservedParams.toString()} />
        {filterBar}
        {units.length === 0 ? (
          <EmptyState
            title="No equipment out of service"
            description={filterContext ? `No equipment currently out of service or in maintenance${filterContext}.` : "No equipment currently out of service or in maintenance."}
            action={{ label: "Log Maintenance", href: "/maintenance/new" }}
          />
        ) : (
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            {units.map((u) => {
              const unit = u as unknown as { id: string; unit_number: string; status: string; kind: string; carriers: { legal_name: string } | null };
              return (
                <div key={`${unit.kind}-${unit.id}`} className="flex items-center justify-between rounded-md border border-desktop-border bg-desktop-panel px-3 py-2.5">
                  <div>
                    <p className="text-[13px] font-medium text-desktop-text">{unit.kind} {unit.unit_number}</p>
                    <p className="text-[11.5px] text-muted-foreground">{unit.carriers?.legal_name ?? "--"}</p>
                  </div>
                  <StatusBadge status={unit.status} />
                </div>
              );
            })}
          </div>
        )}
      </div>
    );
  }

  let query = supabase
    .from("maintenance_records")
    .select(
      "id, service_type, cost, service_date, next_service_due_date, next_service_due_odometer, vendor_name, status, paid_by, recovery_type, recovery_status, recoverable_amount, recovered_amount, truck_id, trailer_id, trucks(unit_number, current_odometer), trailers(unit_number), carriers(legal_name)"
    )
    .order("service_date", { ascending: false });

  if (sp.truck_id) query = query.eq("truck_id", sp.truck_id);
  if (sp.trailer_id) query = query.eq("trailer_id", sp.trailer_id);
  if (effectiveCarrierId) query = query.eq("carrier_id", effectiveCarrierId);
  if (sp.service_type) query = query.ilike("service_type", `%${sp.service_type}%`);
  if (sp.paid_by) query = query.eq("paid_by", sp.paid_by);

  // Status: the History tab pins status=completed itself below. Applying
  // the Status control ON TOP of that would AND two different values
  // together and always return zero rows -- a real, pre-existing
  // contradictory-filter bug (not something newly introduced here) --
  // so the Status control's own value is ignored on History, where the
  // tab already fixes it (spec TAB SWITCHING: "adjusted only if invalid
  // for that tab"). It applies normally on every other tab, unchanged.
  if (sp.status && view !== "history") query = query.eq("status", sp.status);

  // Recovery Status: the Recoveries tab already scopes to the three
  // "has a recovery" statuses below. If the user also picks one of those
  // same three, narrow to it instead of ANDing a second, possibly
  // conflicting condition on top of the tab's own default set -- same
  // contradictory-filter fix as Status/History above. Applies normally
  // (a plain equality filter) on every other tab, unchanged.
  if (sp.recovery_status && view !== "recoveries") query = query.eq("recovery_status", sp.recovery_status);

  if (view === "history") query = query.eq("status", "completed");
  if (view === "recoveries") {
    if (sp.recovery_status && (RECOVERY_TAB_STATUSES as readonly string[]).includes(sp.recovery_status)) {
      query = query.eq("recovery_status", sp.recovery_status);
    } else {
      query = query.in("recovery_status", RECOVERY_TAB_STATUSES as unknown as string[]);
    }
  }

  const { data } = await query;
  let records = (data ?? []) as unknown as MaintenanceRow[];

  if (view === "preventive" || view === "upcoming") {
    records = records.filter((r) => r.next_service_due_date || r.next_service_due_odometer);
    if (view === "upcoming") {
      records = records.filter((r) => {
        const status = computePreventiveMaintenanceStatus(r.next_service_due_date, r.next_service_due_odometer, r.trucks?.current_odometer ?? null);
        return status === "due_soon" || status === "due";
      });
    }
  }

  const columns: Column<MaintenanceRow>[] = [
    { header: "Service", cell: (row) => <span className="font-medium">{row.service_type}</span> },
    { header: "Unit", cell: (row) => row.trucks?.unit_number ?? row.trailers?.unit_number ?? "--" },
    { header: "Carrier", cell: (row) => row.carriers?.legal_name ?? "--" },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
    { header: "Paid By", cell: (row) => row.paid_by.replace(/_/g, " ") },
    { header: "Service Date", cell: (row) => new Date(row.service_date + "T00:00:00").toLocaleDateString() },
    ...(view === "preventive" || view === "upcoming"
      ? [
          {
            header: "PM Status",
            cell: (row: MaintenanceRow) => {
              const status = computePreventiveMaintenanceStatus(row.next_service_due_date, row.next_service_due_odometer, row.trucks?.current_odometer ?? null);
              return <span className={PM_STATUS_TONE[status] === "danger" ? "text-desktop-danger" : PM_STATUS_TONE[status] === "warning" ? "text-desktop-warning" : "text-muted-foreground"}>{PM_STATUS_LABEL[status]}</span>;
            },
          },
        ]
      : []),
    ...(view === "recoveries"
      ? [
          { header: "Recovery", cell: (row: MaintenanceRow) => <StatusBadge status={row.recovery_status} /> },
          { header: "Remaining", cell: (row: MaintenanceRow) => money(Number(row.recoverable_amount) - Number(row.recovered_amount)) },
        ]
      : [{ header: "Cost", cell: (row: MaintenanceRow) => money(row.cost) }]),
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="Maintenance" description="Service history and preventive maintenance for trucks and trailers." primaryAction={{ label: "Log Maintenance", href: "/maintenance/new" }} />

      {kpiStrip}

      <TabBar active={view} queryString={preservedParams.toString()} />

      {filterBar}

      {records.length === 0 ? (
        <EmptyState
          title={`No ${RECORD_NOUN[view]} found`}
          description={filterContext ? `No ${RECORD_NOUN[view]} found${filterContext}.` : "Try different filters, or log a new service event."}
          action={{ label: "Log Maintenance", href: "/maintenance/new" }}
        />
      ) : (
        <DataTable columns={columns} rows={records} getDetailHref={(row) => `/maintenance/${row.id}`} />
      )}
    </div>
  );
}

function TabBar({ active, queryString }: { active: TabKey; queryString: string }) {
  return (
    <div className="flex gap-1 overflow-x-auto border-b border-desktop-border">
      {TABS.map((t) => {
        const params = new URLSearchParams(queryString);
        params.set("view", t.key);
        return (
          <Link
            key={t.key}
            href={`/maintenance?${params.toString()}`}
            className={`shrink-0 whitespace-nowrap border-b-2 px-3 py-2 text-[13px] font-medium transition-colors ${
              active === t.key ? "border-primary text-primary" : "border-transparent text-muted-foreground hover:text-desktop-text"
            }`}
          >
            {t.label}
          </Link>
        );
      })}
    </div>
  );
}
