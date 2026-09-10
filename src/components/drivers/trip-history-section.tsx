import { createClient } from "@/lib/supabase/server";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { TripDateRangeFilter } from "@/components/drivers/trip-date-range-filter";
import {
  resolveDateRange,
  computeTripMetrics,
  type DateRangeKey,
  type TripRow,
  type TripLoadStop,
} from "@/lib/drivers/trip-metrics";
import { computePodStatus } from "@/lib/documents/pod-status";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import { formatStopDateTime } from "@/lib/timezone/format";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

type DispatchQueryRow = {
  id: string;
  status: string;
  dispatched_at: string;
  loads: {
    id: string;
    load_number: string;
    status: string;
    total_miles: number | null;
    brokers: { company_name: string } | null;
    customers: { company_name: string } | null;
    load_stops: TripLoadStop[];
  } | null;
  trucks: { unit_number: string } | null;
  trailers: { unit_number: string } | null;
};

function fmtMoney(n: number) {
  return `$${Math.round(n).toLocaleString()}`;
}

export async function DriverTripHistorySection({
  driverId,
  organizationId,
  range,
  customFrom,
  customTo,
}: {
  driverId: string;
  organizationId: string;
  range: DateRangeKey;
  customFrom?: string;
  customTo?: string;
}) {
  const supabase = await createClient();
  const { start, end } = resolveDateRange(range, customFrom, customTo);

  // Phase 2G.11: load_rate/carrier_net_amount dropped from this select
  // (dead `loads.rate` dropped too -- confirmed unused by any render path
  // in this file) -- 0068's writer cutover stopped populating them on
  // `dispatches`; dispatch_financials is authoritative now, fetched
  // separately below and merged in by dispatch id. This component is only
  // ever rendered for canSeeFinancials callers (see drivers/[id]/page.tsx),
  // so no additional role gating is added here -- consistent with how
  // every other leaf component in this app is gated at its call site, not
  // re-checked redundantly inside.
  let query = supabase
    .from("dispatches")
    .select(
      `id, status, dispatched_at,
       loads:loads!dispatches_load_id_fkey(id, load_number, status, total_miles,
             brokers(company_name), customers(company_name),
             load_stops(stop_type, scheduled_at, arrived_at, departed_at, timezone)),
       trucks(unit_number),
       trailers(unit_number)`
    )
    .eq("driver_id", driverId)
    .order("dispatched_at", { ascending: false });

  if (start) query = query.gte("dispatched_at", start.toISOString());
  if (end) query = query.lt("dispatched_at", end.toISOString());

  // Separate query -- org.timezone is only ever used to backfill legacy
  // stops with no timezone of their own (see resolveStopTimezone()), and
  // fetching it independently keeps the dispatches/loads/load_stops select
  // above immune to this column ever going missing (bundled-select risk,
  // see src/lib/timezone/resolve.ts callers elsewhere in the app).
  const { data: org } = await supabase.from("organizations").select("timezone").eq("id", organizationId).maybeSingle();

  const { data } = await query;
  const dispatchRows = (data ?? []) as unknown as DispatchQueryRow[];
  const loadIds = dispatchRows.filter((d) => d.loads !== null).map((d) => d.loads!.id);
  const dispatchIds = dispatchRows.map((d) => d.id);

  const { data: financialsRows } = dispatchIds.length > 0
    ? await supabase.from("dispatch_financials").select("dispatch_id, carrier_net_amount").in("dispatch_id", dispatchIds)
    : { data: [] as { dispatch_id: string; carrier_net_amount: number }[] };
  const netAmountByDispatch = new Map((financialsRows ?? []).map((r) => [r.dispatch_id, Number(r.carrier_net_amount)]));

  // Same canonical "latest document per load" helper used everywhere else
  // POD status is shown (load page, invoice page, dashboard, loads list) --
  // see src/lib/documents/latest-document.ts.
  const podByLoadId = await getLatestDocumentsByEntity(supabase, "load", "pod", loadIds);

  const trips: TripRow[] = dispatchRows
    .filter((d) => d.loads !== null)
    .map((d) => {
      const load = d.loads!;
      const pickupStop = load.load_stops.find((s) => s.stop_type === "pickup");
      const deliveryStop = load.load_stops.find((s) => s.stop_type === "delivery");
      return {
        dispatch_id: d.id,
        dispatch_status: d.status,
        dispatched_at: d.dispatched_at,
        load_id: load.id,
        load_number: load.load_number,
        load_status: load.status,
        total_miles: load.total_miles,
        carrier_net_amount: netAmountByDispatch.get(d.id) ?? 0,
        truck_unit: d.trucks?.unit_number ?? null,
        trailer_unit: d.trailers?.unit_number ?? null,
        partner_name: load.brokers?.company_name ?? load.customers?.company_name ?? null,
        pickup_date: pickupStop?.scheduled_at ?? null,
        pickup_date_timezone: resolveStopTimezone(pickupStop?.timezone ?? null, org?.timezone ?? null).timezone,
        delivery_date: deliveryStop?.scheduled_at ?? null,
        delivery_date_timezone: resolveStopTimezone(deliveryStop?.timezone ?? null, org?.timezone ?? null).timezone,
        delivery_actual_at: deliveryStop?.arrived_at ?? null,
        pod_status: computePodStatus(podByLoadId.get(load.id) ?? null),
      };
    });

  const metrics = computeTripMetrics(trips);

  const columns: Column<TripRow>[] = [
    { header: "Load #", cell: (t) => <span className="font-medium">{t.load_number}</span> },
    { header: "Pickup Date", cell: (t) => formatStopDateTime(t.pickup_date, t.pickup_date_timezone, { dateOnly: true, includeYear: true }) },
    { header: "Delivery Date", cell: (t) => formatStopDateTime(t.delivery_date, t.delivery_date_timezone, { dateOnly: true, includeYear: true }) },
    { header: "Miles", cell: (t) => (t.total_miles != null ? t.total_miles.toLocaleString() : "--") },
    { header: "Rate", cell: (t) => fmtMoney(t.carrier_net_amount) },
    { header: "Status", cell: (t) => <StatusBadge status={t.load_status} /> },
    { header: "POD", cell: (t) => <StatusBadge status={t.pod_status} /> },
    { header: "Truck", cell: (t) => t.truck_unit ?? "--" },
    { header: "Trailer", cell: (t) => t.trailer_unit ?? "--" },
    { header: "Customer / Broker", cell: (t) => t.partner_name ?? "--" },
  ];

  return (
    <Card>
      <CardHeader>
        <CardTitle>Trip History</CardTitle>
        <CardDescription>
          Every load this driver has been dispatched on, derived from dispatches -- not a separately stored count.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        <TripDateRangeFilter current={range} />

        <KpiRow>
          <KpiCard label="Total Trips" value={metrics.totalTrips} />
          <KpiCard label="Completed Trips" value={metrics.completedTrips} tone="success" />
          <KpiCard label="Active Trips" value={metrics.activeTrips} tone={metrics.activeTrips ? "warning" : "neutral"} />
          <KpiCard label="Total Miles" value={metrics.totalMiles.toLocaleString()} />
          <KpiCard label="Total Revenue" value={fmtMoney(metrics.totalRevenue)} tone="success" />
        </KpiRow>

        <div className="grid grid-cols-2 gap-4 rounded-lg border border-border p-4 sm:grid-cols-4">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Avg Revenue / Trip</p>
            <p className="mt-0.5 text-sm font-semibold">{fmtMoney(metrics.avgRevenuePerTrip)}</p>
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Avg Miles / Trip</p>
            <p className="mt-0.5 text-sm font-semibold">{Math.round(metrics.avgMilesPerTrip).toLocaleString()}</p>
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Revenue / Mile</p>
            <p className="mt-0.5 text-sm font-semibold">
              {metrics.revenuePerMile != null ? `$${metrics.revenuePerMile.toFixed(2)}` : "--"}
            </p>
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Completion Rate</p>
            <p className="mt-0.5 text-sm font-semibold">{metrics.completionRate.toFixed(0)}%</p>
          </div>
        </div>

        <div>
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Delivery Performance
            {metrics.deliveriesWithTimestampsCount === 0 && (
              <span className="ml-2 normal-case text-muted-foreground/70">
                (no scheduled + actual delivery timestamps recorded yet -- shown once check-call data exists)
              </span>
            )}
          </p>
          <div className="grid grid-cols-2 gap-4 sm:grid-cols-2">
            <div>
              <p className="text-xs text-muted-foreground">On-Time Deliveries</p>
              <p className="text-sm font-semibold text-success">{metrics.onTimeCount}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Late Deliveries</p>
              <p className="text-sm font-semibold text-danger">{metrics.lateCount}</p>
            </div>
          </div>
        </div>

        {trips.length === 0 ? (
          <EmptyState title="No trips in this range" description="Dispatch a load to this driver to see it here." />
        ) : (
          <DataTable columns={columns} rows={trips.map((t) => ({ ...t, id: t.dispatch_id }))} getDetailHref={(t) => `/loads/${t.load_id}`} />
        )}
      </CardContent>
    </Card>
  );
}
