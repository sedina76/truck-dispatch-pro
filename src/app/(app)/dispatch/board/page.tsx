import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import { KanbanBoard, type DispatchCard } from "./kanban-board";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import { calculateDetention } from "@/lib/dispatch/detention";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

type DispatchRow = {
  id: string;
  status: string;
  load_id: string;
  carrier_net_amount: number;
  loads: { load_number: string } | null;
  carriers: { legal_name: string } | null;
  trucks: { unit_number: string } | null;
  drivers: { first_name: string; last_name: string } | null;
};

type StopRow = {
  load_id: string;
  stop_type: string;
  stop_sequence: number;
  city: string | null;
  state: string | null;
  scheduled_at: string | null;
  arrived_at: string | null;
  departed_at: string | null;
};

type RouteIntelRow = {
  dispatch_id: string;
  route_distance_meters: number | null;
  estimated_arrival_at: string | null;
  schedule_variance_minutes: number | null;
  risk_status: string;
  calculation_status: string;
  updated_at: string;
};

const BEFORE_PICKUP = new Set(["assigned", "accepted", "en_route_to_pickup"]);
const BEFORE_DELIVERY = new Set(["assigned", "accepted", "en_route_to_pickup", "at_pickup", "loaded", "en_route_to_delivery"]);
const DELIVERED_LIKE = new Set(["delivered", "completed"]);

export default async function DispatchBoardPage() {
  const supabase = await createClient();

  const [{ data }, { data: org }] = await Promise.all([
    supabase
      .from("dispatches")
      .select(
        "id, status, load_id, carrier_net_amount, loads(load_number), carriers(legal_name), trucks(unit_number), drivers(first_name, last_name)"
      )
      .order("dispatched_at", { ascending: false }),
    supabase.from("organizations").select("pickup_detention_free_minutes, delivery_detention_free_minutes").single(),
  ]);

  const dispatches = (data ?? []) as unknown as DispatchRow[];
  const loadIds = dispatches.map((d) => d.load_id);
  const dispatchIds = dispatches.map((d) => d.id);

  // Phase 2C (0060_route_intelligence.sql) -- batched, degradable: a
  // not-yet-applied migration just means every card shows no ETA badge,
  // never a broken board. Ordered newest-first and deduped client-side to
  // the single most-recently-updated row per dispatch (its current
  // operational target stop -- see evaluate-route.ts).
  const { data: routeRowsRaw, error: routeError } =
    dispatchIds.length > 0
      ? await supabase
          .from("dispatch_route_intelligence")
          .select("dispatch_id, route_distance_meters, estimated_arrival_at, schedule_variance_minutes, risk_status, calculation_status, updated_at")
          .in("dispatch_id", dispatchIds)
          .order("updated_at", { ascending: false })
      : { data: [] as RouteIntelRow[], error: null };
  if (routeError) console.warn("[dispatch board] route intelligence unavailable (likely migration 0060 not applied yet):", routeError);
  const routeByDispatch = new Map<string, RouteIntelRow>();
  for (const row of (routeRowsRaw ?? []) as RouteIntelRow[]) {
    if (!routeByDispatch.has(row.dispatch_id)) routeByDispatch.set(row.dispatch_id, row);
  }

  // Batched, not per-card -- one query for every load's stops, one for POD
  // presence, matching the existing getLatestDocumentsByEntity() pattern
  // already used by the dashboard/loads-list/driver-trip-history for
  // exactly this "many entities at once" case.
  const [{ data: stopsRawUntyped }, podByLoad, { data: stopTzRows, error: stopTzError }, { data: orgTz }] = await Promise.all([
    loadIds.length > 0
      ? supabase
          .from("load_stops")
          .select("load_id, stop_type, stop_sequence, city, state, scheduled_at, arrived_at, departed_at")
          .in("load_id", loadIds)
          .order("stop_sequence")
      : Promise.resolve({ data: [] as StopRow[] }),
    getLatestDocumentsByEntity(supabase, "load", "pod", loadIds),
    // Phase 2C.1 -- deliberately a SEPARATE query from the core stop
    // fields above (not bundled into that same .select()): a not-yet-
    // applied 0061 must never take the whole board's stop data down with
    // it, same reasoning as every other degradable split in this app.
    loadIds.length > 0
      ? supabase.from("load_stops").select("load_id, stop_type, stop_sequence, timezone").in("load_id", loadIds)
      : Promise.resolve({ data: [] as { load_id: string; stop_type: string; stop_sequence: number; timezone: string | null }[], error: null }),
    supabase.from("organizations").select("timezone").single(),
  ]);
  if (stopTzError) console.warn("[dispatch board] stop timezone unavailable (likely migration 0061 not applied yet):", stopTzError);
  const stopsRaw = (stopsRawUntyped ?? []) as unknown as StopRow[];
  const organizationTimezone = orgTz?.timezone ?? null;

  // Same pickup/delivery selection rule as stopsByLoad below (first
  // pickup, LAST delivery by sequence) applied to the timezone-only rows.
  const stopTzByLoad = new Map<string, { pickup: string | null; delivery: string | null }>();
  for (const loadId of loadIds) {
    const rows = (stopTzRows ?? []).filter((s) => s.load_id === loadId);
    const pickupRows = rows.filter((s) => s.stop_type === "pickup").sort((a, b) => a.stop_sequence - b.stop_sequence);
    const deliveryRows = rows.filter((s) => s.stop_type === "delivery").sort((a, b) => a.stop_sequence - b.stop_sequence);
    stopTzByLoad.set(loadId, {
      pickup: pickupRows[0]?.timezone ?? null,
      delivery: deliveryRows[deliveryRows.length - 1]?.timezone ?? null,
    });
  }

  const stopsByLoad = new Map<string, { pickup: StopRow | null; delivery: StopRow | null }>();
  for (const loadId of loadIds) {
    const rows = stopsRaw.filter((s) => s.load_id === loadId);
    stopsByLoad.set(loadId, {
      pickup: rows.filter((s) => s.stop_type === "pickup")[0] ?? null,
      delivery: rows.filter((s) => s.stop_type === "delivery").slice(-1)[0] ?? null,
    });
  }

  const pickupFreeMinutes = org?.pickup_detention_free_minutes ?? 120;
  const deliveryFreeMinutes = org?.delivery_detention_free_minutes ?? 120;
  const now = new Date();

  const activeCount = dispatches.filter((d) => !["completed", "cancelled", "delivered"].includes(d.status)).length;
  const completedCount = dispatches.filter((d) => DELIVERED_LIKE.has(d.status)).length;
  const totalNet = dispatches
    .filter((d) => d.status !== "cancelled")
    .reduce((sum, d) => sum + Number(d.carrier_net_amount), 0);

  const cards: DispatchCard[] = dispatches.map((d) => {
    const stops = stopsByLoad.get(d.load_id);
    const pickup = stops?.pickup ?? null;
    const delivery = stops?.delivery ?? null;

    const exceptions: string[] = [];
    if (DELIVERED_LIKE.has(d.status) && !podByLoad.has(d.load_id)) exceptions.push("POD Missing");
    if (pickup?.scheduled_at && BEFORE_PICKUP.has(d.status) && new Date(pickup.scheduled_at) < now) exceptions.push("Late Pickup");
    if (delivery?.scheduled_at && BEFORE_DELIVERY.has(d.status) && new Date(delivery.scheduled_at) < now) exceptions.push("Late Delivery");
    const pickupDetention = pickup ? calculateDetention(pickup.arrived_at, pickup.departed_at, pickupFreeMinutes, now) : null;
    const deliveryDetention = delivery ? calculateDetention(delivery.arrived_at, delivery.departed_at, deliveryFreeMinutes, now) : null;
    if (pickupDetention?.inDetention || deliveryDetention?.inDetention) {
      exceptions.push("Detention");
    } else {
      // Spec section 17/18: a compact "Detention in Xm" pre-warning, only
      // while a truck is actually sitting at a stop (arrived, not departed)
      // and free time is running out -- never for a stop already departed.
      const remaining = (stop: StopRow | null, freeMinutes: number): number | null => {
        if (!stop?.arrived_at || stop.departed_at) return null;
        const elapsedMinutes = Math.floor((now.getTime() - new Date(stop.arrived_at).getTime()) / 60000);
        return freeMinutes - elapsedMinutes;
      };
      const pickupRemaining = remaining(pickup, pickupFreeMinutes);
      const deliveryRemaining = remaining(delivery, deliveryFreeMinutes);
      const soonest = [pickupRemaining, deliveryRemaining].filter((v): v is number => v != null && v > 0 && v <= 30).sort((a, b) => a - b)[0];
      if (soonest != null) exceptions.push(`Detention in ${soonest}m`);
    }

    // Route-intelligence risk badge (spec section 22) -- a late load must
    // be easier to spot than an on-time one, so LATE/AT RISK also joins
    // the same exceptions array (not a second, competing badge system).
    const route = routeByDispatch.get(d.id) ?? null;
    const riskStatus = route?.risk_status ?? null;
    if (riskStatus === "late" && route?.schedule_variance_minutes != null) {
      exceptions.unshift(`${-route.schedule_variance_minutes}m LATE`);
    } else if (riskStatus === "at_risk") {
      exceptions.unshift("AT RISK");
    }

    return {
      id: d.id,
      status: d.status,
      load_number: d.loads?.load_number ?? "Load",
      carrier_name: d.carriers?.legal_name ?? "--",
      truck_unit: d.trucks?.unit_number ?? "--",
      driver_name: d.drivers ? `${d.drivers.first_name} ${d.drivers.last_name}` : "--",
      net_amount: Number(d.carrier_net_amount),
      pickup_city: pickup?.city ?? null,
      pickup_state: pickup?.state ?? null,
      delivery_city: delivery?.city ?? null,
      delivery_state: delivery?.state ?? null,
      pickup_time: pickup?.scheduled_at ?? null,
      pickup_timezone: resolveStopTimezone(stopTzByLoad.get(d.load_id)?.pickup ?? null, organizationTimezone).timezone,
      exceptions,
      eta_at: route?.estimated_arrival_at ?? null,
      // The route target may be either the pickup or delivery stop
      // depending on where the truck is in the trip -- the delivery
      // timezone is the safer general default for the ETA badge (most of
      // a dispatch's active lifetime is spent en route to delivery), and
      // this is display-only (never affects the real risk math, which
      // stays in UTC end-to-end).
      eta_timezone: resolveStopTimezone(stopTzByLoad.get(d.load_id)?.delivery ?? stopTzByLoad.get(d.load_id)?.pickup ?? null, organizationTimezone).timezone,
      miles_remaining_meters: route?.route_distance_meters ?? null,
      risk_status: (riskStatus as DispatchCard["risk_status"]) ?? (route ? "unknown" : null),
    };
  });


  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Dispatch Board", href: "/dispatch/board" }]} />
      <PageHeader
        title="Dispatch Board"
        description="Drag a card between columns to update its status in real time."
        primaryAction={{ label: "New Dispatch", href: "/dispatch/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Dispatches" value={dispatches.length} />
        <DesktopKpiBox label="Active" value={activeCount} />
        <DesktopKpiBox label="Delivered" value={completedCount} tone="success" />
        <DesktopKpiBox label="Carrier Net Value" value={`$${totalNet.toLocaleString()}`} />
      </DesktopKpiStrip>

      {dispatches.length === 0 ? (
        <EmptyState
          title="No dispatches yet"
          description="Assign a load to a carrier, truck, and driver to create your first dispatch."
          action={{ label: "New Dispatch", href: "/dispatch/new" }}
        />
      ) : (
        <KanbanBoard initialCards={cards} />
      )}
    </div>
  );
}
