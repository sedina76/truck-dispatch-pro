import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { computePodStatus } from "@/lib/documents/pod-status";
import type { DriverPortalIdentity } from "./session";

// Canonical dispatch "in progress" set -- the single source every page that
// needs "the driver's current trip" reads from (home dashboard, Trip page,
// nav counters, location sharing). Matches the set already used by
// driver-portal/page.tsx and /api/driver-portal/location before this pass.
export const ACTIVE_DISPATCH_STATUSES = [
  "assigned",
  "accepted",
  "en_route_to_pickup",
  "at_pickup",
  "loaded",
  "en_route_to_delivery",
  "at_delivery",
] as const;

// Forward-only progression the driver may move their own dispatch through.
// Not a new enum -- these are the existing public.dispatch_status values
// (0001_extensions_enums_helpers.sql). 'completed' is deliberately excluded
// as a driver-settable target: in this codebase it's used interchangeably
// with 'delivered' for load-sync purposes but reads as a
// settlement/back-office concept elsewhere, so the driver's own action is
// always "Delivered", never "Completed".
export const DISPATCH_STATUS_ORDER = [
  "assigned",
  "accepted",
  "en_route_to_pickup",
  "at_pickup",
  "loaded",
  "en_route_to_delivery",
  "at_delivery",
  "delivered",
] as const;

export type DispatchInfo = {
  id: string;
  status: string;
  dispatched_at: string;
  completed_at: string | null;
  truck_unit: string | null;
  trailer_unit: string | null;
  load_id: string;
  load_number: string;
  commodity: string | null;
  total_miles: number | null;
};

export type TripStop = {
  stop_type: string;
  stop_sequence: number;
  facility_name: string | null;
  city: string | null;
  state: string | null;
  scheduled_at: string | null;
  reference_number: string | null;
};

export type DashboardCounters = {
  hasActiveTrip: boolean;
  documentsNeeded: number;
  pendingExpenses: number;
  unpaidSettlements: number;
};

const DISPATCH_SELECT =
  "id, status, dispatched_at, completed_at, trucks(unit_number), trailers(unit_number), loads(id, load_number, commodity, total_miles)";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function mapDispatch(row: any): DispatchInfo {
  return {
    id: row.id,
    status: row.status,
    dispatched_at: row.dispatched_at,
    completed_at: row.completed_at,
    truck_unit: row.trucks?.unit_number ?? null,
    trailer_unit: row.trailers?.unit_number ?? null,
    load_id: row.loads?.id ?? "",
    load_number: row.loads?.load_number ?? "Load",
    commodity: row.loads?.commodity ?? null,
    total_miles: row.loads?.total_miles ?? null,
  };
}

// THE canonical "what is this driver's current trip" resolver. Active
// dispatch wins; falls back to the most recently delivered one (so the
// driver can still see/finish documents right after marking delivered)
// exactly like the original driver-portal/page.tsx behavior.
export async function getCurrentDispatch(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  supabase: any,
  driverId: string
): Promise<DispatchInfo | null> {
  const { data: active } = await supabase
    .from("dispatches")
    .select(DISPATCH_SELECT)
    .eq("driver_id", driverId)
    .in("status", ACTIVE_DISPATCH_STATUSES)
    .order("dispatched_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (active) return mapDispatch(active);

  const { data: fallback } = await supabase
    .from("dispatches")
    .select(DISPATCH_SELECT)
    .eq("driver_id", driverId)
    .in("status", ["delivered", "completed"])
    .order("dispatched_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  return fallback ? mapDispatch(fallback) : null;
}

export async function getTripStops(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  supabase: any,
  loadId: string
): Promise<TripStop[]> {
  const { data } = await supabase
    .from("load_stops")
    .select("stop_type, stop_sequence, facility_name, city, state, scheduled_at, reference_number")
    .eq("load_id", loadId)
    .order("stop_sequence");
  return data ?? [];
}

// One fixed, small set of queries -- never one query per trip/document/
// expense (spec section 39). Used by the home dashboard for both the
// Current Trip card and the four counter tiles in a single pass.
export async function getDashboardData(identity: DriverPortalIdentity) {
  const supabase = createServiceRoleClient();

  const [dispatch, expenseCounts, settlementRows] = await Promise.all([
    getCurrentDispatch(supabase, identity.driverId),
    supabase.from("expenses").select("id", { count: "exact", head: true }).eq("driver_id", identity.driverId).in("status", ["draft", "submitted"]),
    supabase
      .from("driver_settlements")
      .select("id, balance_due, status")
      .eq("driver_id", identity.driverId)
      .in("status", ["approved", "partially_paid"]),
  ]);

  let stops: TripStop[] = [];
  let documentsNeeded = 0;
  if (dispatch?.load_id) {
    const [stopsResult, pod] = await Promise.all([
      getTripStops(supabase, dispatch.load_id),
      getLatestDocument(supabase, "load", dispatch.load_id, "pod"),
    ]);
    stops = stopsResult;
    // Real requirement only: the one thing this codebase already treats as
    // "needed" for a delivered load -- a verified POD (see the exact same
    // rule on the staff Invoice page). Never a fabricated compliance list.
    if (computePodStatus(pod) !== "verified") documentsNeeded = 1;
  }

  const unpaidSettlements = (settlementRows.data ?? []).filter((s: { balance_due: number }) => Number(s.balance_due) > 0).length;

  const counters: DashboardCounters = {
    hasActiveTrip: !!dispatch && (ACTIVE_DISPATCH_STATUSES as readonly string[]).includes(dispatch.status),
    documentsNeeded,
    pendingExpenses: expenseCounts.count ?? 0,
    unpaidSettlements,
  };

  return { dispatch, stops, counters };
}
