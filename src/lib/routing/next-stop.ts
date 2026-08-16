// ---------------------------------------------------------------------------
// getNextOperationalStop() -- the single source every route-intelligence
// call site uses to decide "which stop matters right now" (spec section 7).
// Deliberately data-driven off each stop's own arrived_at/departed_at
// rather than a status-keyed switch statement: dispatch_status is coarse
// (one value for the whole dispatch) and can't distinguish "at pickup 1"
// from "at pickup 2" on a true multi-stop load, but load_stops.arrived_at/
// departed_at already can, per stop, today (0057/board-actions.ts already
// writes them). This one rule works correctly for a simple 1-pickup/
// 1-delivery load AND for Pickup1 -> Pickup2 -> Delivery1 -> Delivery2
// without any special-casing, matching the architecture requirement even
// though current test loads are simpler.
// ---------------------------------------------------------------------------

const TERMINAL_STATUSES = new Set(["delivered", "completed", "cancelled"]);

export type OperationalStop = {
  id: string;
  stop_type: "pickup" | "delivery";
  stop_sequence: number;
  latitude: number | null;
  longitude: number | null;
  arrived_at: string | null;
  departed_at: string | null;
  scheduled_at: string | null;
  scheduled_window_end: string | null;
  timezone?: string | null;
};

export function getNextOperationalStop(dispatchStatus: string, stops: OperationalStop[]): OperationalStop | null {
  if (TERMINAL_STATUSES.has(dispatchStatus)) return null;
  if (stops.length === 0) return null;

  const sorted = [...stops].sort((a, b) => a.stop_sequence - b.stop_sequence);

  // The truck is physically AT a stop right now (arrived, not yet
  // departed) -- that's the operationally relevant destination, matching
  // "current pickup / current delivery" in spec section 7's at_pickup/
  // at_delivery examples.
  const current = sorted.find((s) => s.arrived_at && !s.departed_at);
  if (current) return current;

  // Otherwise, the next stop the truck hasn't reached yet, in sequence
  // order -- covers assigned/accepted/en_route_to_pickup (first pending
  // pickup), loaded/en_route_to_delivery (first pending delivery, or the
  // next pending pickup on a multi-pickup load that isn't fully loaded
  // yet), all from the same one rule.
  const next = sorted.find((s) => !s.arrived_at);
  return next ?? null; // null: every stop already arrived (trip effectively done, status just hasn't caught up)
}
