import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import { KanbanBoard, type DispatchCard } from "./kanban-board";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { getLatestDocumentsByEntity } from "@/lib/documents/latest-document";
import { calculateDetention } from "@/lib/dispatch/detention";
import { resolveStopTimezone } from "@/lib/timezone/resolve";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";
import { boardRetentionOrFilter, boardHiddenByRetentionFilter } from "@/lib/dispatch/board-retention";

type DispatchRow = {
  id: string;
  status: string;
  load_id: string;
  delivered_at: string | null;
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

type RouteDeviationRow = {
  dispatch_id: string;
  state: string;
  calculation_status: string;
  distance_from_route_m: number | null;
  dismissed_at: string | null;
  updated_at: string;
};

const BEFORE_PICKUP = new Set(["assigned", "accepted", "en_route_to_pickup"]);
const BEFORE_DELIVERY = new Set(["assigned", "accepted", "en_route_to_pickup", "at_pickup", "loaded", "en_route_to_delivery"]);
const DELIVERED_LIKE = new Set(["delivered", "completed"]);

export default async function DispatchBoardPage({
  searchParams,
}: {
  searchParams: Promise<{ show_completed?: string }>;
}) {
  const { show_completed } = await searchParams;
  const showCompleted = show_completed === "1";
  const supabase = await createClient();

  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  // Phase 2G.11: carrier_net_amount dropped from this select -- 0068's
  // writer cutover stopped populating it on `dispatches`
  // (dispatch_financials is authoritative now), and this page previously
  // had NO role gating at all, so every role -- including driver/viewer --
  // was fetching and rendering it. Fixed both problems together: the
  // operational board query below never asks for a financial column, and
  // the real values are fetched from dispatch_financials in a SEPARATE
  // query issued only when canSeeFinancials.
  // Phase 2I.1 (Part A) + completed-dispatch retention workflow revision:
  // the ACTIVE Dispatch Board excludes delivered/completed/cancelled
  // dispatches once they're more than 24h past their respective
  // delivered_at/cancelled_at -- query-level only (see board-retention.ts's
  // own header comment for the full "fail open on null" reasoning). The
  // load/dispatch record itself is never touched, archived, or hidden
  // anywhere else -- Load Detail, Billing, Invoices, Reports, Driver
  // history, and Driver Portal all keep reading the exact same dispatches/
  // loads rows with no filter at all, unaffected by this query.
  //
  // "Show completed" (?show_completed=1): the SAME query, with the
  // retention filter simply omitted -- every dispatch in the organization
  // (still fully RLS-scoped) is fetched, regardless of age. Nothing about
  // the filter/query logic branches beyond this one .or() call being
  // present or absent -- search/carrier/driver/truck filtering
  // (kanban-board.tsx's FilterBar) already operates client-side over
  // whatever cards it's given, so it applies identically either way with
  // no separate wiring.
  let dispatchesQuery = supabase
    .from("dispatches")
    .select(
      "id, status, load_id, delivered_at, loads(load_number), carriers(legal_name), trucks(unit_number), drivers(first_name, last_name)"
    )
    .order("dispatched_at", { ascending: false });
  if (!showCompleted) dispatchesQuery = dispatchesQuery.or(boardRetentionOrFilter());

  const [{ data }, { data: org }, { count: hiddenCount }] = await Promise.all([
    dispatchesQuery,
    supabase.from("organizations").select("pickup_detention_free_minutes, delivery_detention_free_minutes").single(),
    // Requirement: "preserve a separate historical/completed count" --
    // only meaningful (and only queried) when the default, filtered view
    // is showing -- once show_completed is on, there is nothing hidden to
    // count. head:true -- count only, no rows fetched.
    showCompleted
      ? Promise.resolve({ count: null })
      : supabase.from("dispatches").select("id", { count: "exact", head: true }).or(boardHiddenByRetentionFilter()),
  ]);

  const dispatches = (data ?? []) as unknown as DispatchRow[];
  const loadIds = dispatches.map((d) => d.load_id);
  const dispatchIds = dispatches.map((d) => d.id);

  const netAmountByDispatch = new Map<string, number>();
  if (canSeeFinancials && dispatchIds.length > 0) {
    const { data: financialsRows, error: financialsError } = await supabase
      .from("dispatch_financials")
      .select("dispatch_id, carrier_net_amount")
      .in("dispatch_id", dispatchIds);
    if (financialsError) console.warn("[dispatch board] dispatch_financials unavailable:", financialsError);
    for (const row of (financialsRows ?? []) as { dispatch_id: string; carrier_net_amount: number }[]) {
      netAmountByDispatch.set(row.dispatch_id, Number(row.carrier_net_amount));
    }
  }

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

  // Phase 2D (0062_route_deviation.sql) -- same degradable/batched/dedup
  // pattern as route intelligence above, deliberately a SEPARATE query
  // (not bundled) so migration 0062 landing independently of 0060 can
  // never take the rest of the board down with it.
  const { data: deviationRowsRaw, error: deviationError } =
    dispatchIds.length > 0
      ? await supabase
          .from("dispatch_route_deviation_state")
          .select("dispatch_id, state, calculation_status, distance_from_route_m, dismissed_at, updated_at")
          .in("dispatch_id", dispatchIds)
          .order("updated_at", { ascending: false })
      : { data: [] as RouteDeviationRow[], error: null };
  if (deviationError) console.warn("[dispatch board] route deviation unavailable (likely migration 0062 not applied yet):", deviationError);
  const deviationByDispatch = new Map<string, RouteDeviationRow>();
  for (const row of (deviationRowsRaw ?? []) as RouteDeviationRow[]) {
    if (!deviationByDispatch.has(row.dispatch_id)) deviationByDispatch.set(row.dispatch_id, row);
  }

  // Phase 2E (0063_operational_exceptions.sql) -- same degradable/batched
  // pattern: a compact "active exception count" per dispatch, never a
  // second detection engine. If migration 0063 isn't applied yet, every
  // card simply shows 0 (no indicator) -- the rest of the board is
  // completely unaffected (spec section 41).
  const exceptionCountByDispatch = new Map<string, number>();
  if (dispatchIds.length > 0) {
    const { data: exceptionRows, error: exceptionError } = await supabase
      .from("operational_exceptions")
      .select("dispatch_id")
      .in("dispatch_id", dispatchIds)
      .neq("status", "resolved");
    if (exceptionError) console.warn("[dispatch board] operational exceptions unavailable (likely migration 0063 not applied yet):", exceptionError);
    for (const row of (exceptionRows ?? []) as { dispatch_id: string }[]) {
      exceptionCountByDispatch.set(row.dispatch_id, (exceptionCountByDispatch.get(row.dispatch_id) ?? 0) + 1);
    }
  }

  // Phase 2I.1A section F -- same degradable/batched pattern as the
  // exception count above: one query for every dispatch's unread driver
  // messages, never per-card. read_at on dispatch_messages stays the sole
  // source of truth (never derived from `notifications`).
  const unreadMessageCountByDispatch = new Map<string, number>();
  if (dispatchIds.length > 0) {
    const { data: unreadMessageRows, error: unreadMessageError } = await supabase
      .from("dispatch_messages")
      .select("dispatch_id")
      .in("dispatch_id", dispatchIds)
      .eq("sender_type", "driver")
      .is("read_at", null);
    if (unreadMessageError) console.warn("[dispatch board] unread driver messages unavailable:", unreadMessageError);
    for (const row of (unreadMessageRows ?? []) as { dispatch_id: string }[]) {
      unreadMessageCountByDispatch.set(row.dispatch_id, (unreadMessageCountByDispatch.get(row.dispatch_id) ?? 0) + 1);
    }
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

  // Both counts describe exactly what's in `dispatches` -- i.e. exactly
  // what's currently rendered as cards -- never a separate, unfiltered
  // total that could disagree with what's actually on screen. This was
  // already true before the retention/show-completed work (dispatches was
  // always the already-filtered result set); still true now that the
  // filter itself is conditional on showCompleted, since both branches
  // still just read from whatever `dispatches` ends up holding.
  const activeCount = dispatches.filter((d) => !["completed", "cancelled", "delivered"].includes(d.status)).length;
  const completedCount = dispatches.filter((d) => DELIVERED_LIKE.has(d.status)).length;
  const cancelledCount = dispatches.filter((d) => d.status === "cancelled").length;
  const totalNet = dispatches
    .filter((d) => d.status !== "cancelled")
    .reduce((sum, d) => sum + (netAmountByDispatch.get(d.id) ?? 0), 0);

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

    // Route deviation badge (Phase 2D, spec section 30). Only the
    // CONFIRMED state joins the board -- a soft "candidate" ping should not
    // dominate the board (spec section 30/31), it's drawer-only detail. A
    // dismissed exception (false positive, spec section 37) is also
    // suppressed here even though the underlying row is still 'off_route'.
    const deviation = deviationByDispatch.get(d.id) ?? null;
    if (deviation?.state === "off_route" && deviation.calculation_status === "ok" && !deviation.dismissed_at) {
      exceptions.unshift(deviation.distance_from_route_m != null ? `OFF ROUTE · ${Math.round(deviation.distance_from_route_m / 1609.344 * 10) / 10} mi` : "OFF ROUTE");
    }

    // Route-intelligence risk badge (spec section 22) -- a late load must
    // be easier to spot than an on-time one, so LATE/AT RISK also joins
    // the same exceptions array (not a second, competing badge system).
    // Placed AFTER the off-route unshift above so LATE/AT RISK ends up
    // visually first, OFF ROUTE second -- matches spec section 30's
    // suggested priority (LATE, OFF ROUTE, DETENTION, AT RISK, POD
    // MISSING). Route status and schedule risk are independent dimensions
    // (spec section 56) -- both can and do show at once.
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
      net_amount: canSeeFinancials ? (netAmountByDispatch.get(d.id) ?? 0) : null,
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
      // Independent of risk_status (spec section 56) -- drives its own
      // board filter (spec section 31), never overloaded onto `risk`.
      off_route: deviation?.state === "off_route" && deviation.calculation_status === "ok" && !deviation.dismissed_at,
      active_exception_count: exceptionCountByDispatch.get(d.id) ?? 0,
      unread_driver_message_count: unreadMessageCountByDispatch.get(d.id) ?? 0,
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
        <DesktopKpiBox label="Cancelled" value={cancelledCount} />
        {canSeeFinancials && <DesktopKpiBox label="Carrier Net Value" value={`$${totalNet.toLocaleString()}`} />}
      </DesktopKpiStrip>

      {/* Completed-dispatch retention workflow: delivered/completed/
          cancelled dispatches clear the active board 24h after their own
          delivered_at/cancelled_at (fail-open if that timestamp is
          somehow missing -- see board-retention.ts). This never deletes,
          archives, or changes any dispatch/load row -- it only changes
          what this one query fetches. "Show completed" fetches every
          dispatch in the organization regardless of age; existing search/
          carrier/driver/truck filters (below, in the board itself)
          continue to work unchanged on whatever set this toggle produces. */}
      <div className="flex flex-wrap items-center gap-3 text-[12.5px] text-desktop-text-muted">
        <Link
          href={showCompleted ? "/dispatch/board" : "/dispatch/board?show_completed=1"}
          className="inline-flex items-center gap-1.5 rounded-sm border border-desktop-border bg-desktop-panel px-2.5 py-1 font-medium text-desktop-text transition-colors hover:bg-muted"
        >
          <span
            className={`inline-block size-3 rounded-sm border ${showCompleted ? "border-primary bg-primary" : "border-desktop-border bg-transparent"}`}
            aria-hidden="true"
          />
          Show completed
        </Link>
        {showCompleted ? (
          <span>Showing every delivered/completed/cancelled dispatch, regardless of age.</span>
        ) : (
          hiddenCount != null &&
          hiddenCount > 0 && (
            <span>
              {hiddenCount} older delivered/cancelled dispatch{hiddenCount === 1 ? "" : "es"} hidden (24h+) --{" "}
              <Link href="/dispatch/board?show_completed=1" className="font-medium text-primary hover:underline">
                show them
              </Link>
              .
            </span>
          )
        )}
      </div>

      {/* key forces a clean remount when the toggle changes -- KanbanBoard
          seeds its own drag/drop card state from `initialCards` via
          useState on mount only (no prop-sync effect, by original design,
          since it also owns local optimistic updates); without a key
          change here, toggling "Show completed" would re-render this
          Server Component with a fresh `cards` array but the already-
          mounted client component would keep displaying its stale state. */}
      {dispatches.length === 0 ? (
        <EmptyState
          title="No dispatches yet"
          description="Assign a load to a carrier, truck, and driver to create your first dispatch."
          action={{ label: "New Dispatch", href: "/dispatch/new" }}
        />
      ) : (
        <KanbanBoard key={showCompleted ? "all" : "active"} initialCards={cards} />
      )}
    </div>
  );
}
