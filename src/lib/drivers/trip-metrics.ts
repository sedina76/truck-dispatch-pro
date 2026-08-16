// Trip tracking is derived entirely from the existing loads/dispatches
// relationship -- there is no separate "trips" table and none is created
// here. A "trip" = one dispatch (a driver+truck+load assignment); loads has
// no driver_id of its own by design (see 0004_operations.sql), so driver
// assignment is always read through dispatches.driver_id, never stored
// redundantly.

import { isActiveLoadStatus, isCompletedLoadStatus } from "@/lib/loads/status";
import type { PodStatus } from "@/lib/documents/pod-status";

export type DateRangeKey = "today" | "week" | "month" | "year" | "all" | "custom";

export const DATE_RANGE_OPTIONS: { value: DateRangeKey; label: string }[] = [
  { value: "today", label: "Today" },
  { value: "week", label: "This Week" },
  { value: "month", label: "This Month" },
  { value: "year", label: "This Year" },
  { value: "all", label: "All Time" },
  { value: "custom", label: "Custom Range" },
];

function startOfDay(d: Date) {
  const copy = new Date(d);
  copy.setHours(0, 0, 0, 0);
  return copy;
}

// Resolves a range key (+ optional custom from/to) into a concrete
// [start, end) window, anchored to "now" at call time. Returns null start
// for "all" -- callers should treat that as "no lower bound."
export function resolveDateRange(
  range: DateRangeKey,
  customFrom?: string,
  customTo?: string
): { start: Date | null; end: Date | null } {
  const today = startOfDay(new Date());

  switch (range) {
    case "today":
      return { start: today, end: null };
    case "week": {
      const dayOfWeek = (today.getDay() + 6) % 7; // Monday = 0
      const start = new Date(today);
      start.setDate(start.getDate() - dayOfWeek);
      return { start, end: null };
    }
    case "month":
      return { start: new Date(today.getFullYear(), today.getMonth(), 1), end: null };
    case "year":
      return { start: new Date(today.getFullYear(), 0, 1), end: null };
    case "custom":
      return {
        start: customFrom ? startOfDay(new Date(customFrom)) : null,
        end: customTo ? new Date(new Date(customTo).getTime() + 86_400_000) : null, // inclusive end date
      };
    case "all":
    default:
      return { start: null, end: null };
  }
}

export type TripLoadStop = {
  stop_type: "pickup" | "delivery";
  scheduled_at: string | null;
  arrived_at: string | null;
  departed_at: string | null;
};

export type TripRow = {
  dispatch_id: string;
  dispatch_status: string;
  dispatched_at: string;
  load_id: string;
  load_number: string;
  load_status: string;
  total_miles: number | null;
  rate: number;
  carrier_net_amount: number;
  truck_unit: string | null;
  trailer_unit: string | null;
  partner_name: string | null;
  pickup_date: string | null;
  delivery_date: string | null;
  delivery_actual_at: string | null;
  pod_status: PodStatus;
};

export function computeTripMetrics(trips: TripRow[]) {
  const completed = trips.filter((t) => isCompletedLoadStatus(t.load_status));
  const active = trips.filter((t) => isActiveLoadStatus(t.load_status));
  const totalMiles = trips.reduce((sum, t) => sum + (t.total_miles ?? 0), 0);
  const totalRevenue = trips.reduce((sum, t) => sum + t.carrier_net_amount, 0);

  // On-time/late only computable for trips with BOTH a scheduled and actual
  // delivery timestamp -- never inferred or guessed for the rest.
  const deliveriesWithTimestamps = completed.filter((t) => t.delivery_date && t.delivery_actual_at);
  const onTime = deliveriesWithTimestamps.filter((t) => new Date(t.delivery_actual_at!) <= new Date(t.delivery_date!));
  const late = deliveriesWithTimestamps.filter((t) => new Date(t.delivery_actual_at!) > new Date(t.delivery_date!));

  return {
    totalTrips: trips.length,
    completedTrips: completed.length,
    activeTrips: active.length,
    totalMiles,
    totalRevenue,
    avgRevenuePerTrip: trips.length ? totalRevenue / trips.length : 0,
    avgMilesPerTrip: trips.length ? totalMiles / trips.length : 0,
    revenuePerMile: totalMiles > 0 ? totalRevenue / totalMiles : null,
    onTimeCount: onTime.length,
    lateCount: late.length,
    deliveriesWithTimestampsCount: deliveriesWithTimestamps.length,
    completionRate: trips.length ? (completed.length / trips.length) * 100 : 0,
  };
}
