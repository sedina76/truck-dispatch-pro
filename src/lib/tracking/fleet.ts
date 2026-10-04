// Live Tracking's truck list: what each truck needs from the dispatcher,
// worst first. Pure (no I/O) -- the page builds the rows, this ranks and
// filters them, so the same rules drive the counts, the list and the tests.

export type FleetRisk = "late" | "at_risk" | "on_time" | "arrived" | "unknown";

export type FleetRow = {
  driverId: string;
  driverName: string;
  dispatchId: string | null;
  loadNumber: string | null;
  truckUnit: string | null;
  dispatchStatus: string | null;
  recordedAt: string;
  speedMph: number | null;
  nextStop: string | null;
  milesLeftMeters: number | null;
  drivingSeconds: number | null;
  etaAt: string | null;
  appointmentAt: string | null;
  appointmentWindowEnd: string | null;
  stopTimezone: string | null;
  risk: FleetRisk;
  varianceMinutes: number | null;
  calcStatus: string | null;
  /** Active NWS driving-hazard alerts on this truck's route / stops. */
  weather?: { event: string; where: string; area: string; severity: string }[];
};

/** No GPS for this long while on a load = "GPS quiet" (the driver app is probably closed). */
export const GPS_QUIET_MINUTES = 15;

export type FleetFilter = "all" | "late" | "at_risk" | "quiet" | "weather" | "on_load" | "idle";

export function minutesSince(iso: string, now: number): number {
  return Math.max(0, (now - new Date(iso).getTime()) / 60_000);
}

export function isGpsQuiet(row: FleetRow, now: number): boolean {
  return !!row.dispatchId && minutesSince(row.recordedAt, now) > GPS_QUIET_MINUTES;
}

/** Lower = needs attention sooner. */
export function urgency(row: FleetRow, now: number): number {
  if (!row.dispatchId) return 6;
  if (row.risk === "late") return 0;
  if (row.risk === "at_risk") return 1;
  if (isGpsQuiet(row, now)) return 2;
  if (row.calcStatus === "no_coordinates" || row.risk === "unknown") return 3;
  if (row.risk === "on_time") return 4;
  return 5; // arrived
}

export function sortFleet(rows: FleetRow[], now: number): FleetRow[] {
  return [...rows].sort((a, b) => {
    const u = urgency(a, now) - urgency(b, now);
    if (u !== 0) return u;
    // within a group: most late first, then soonest ETA, then name
    const va = a.varianceMinutes ?? Infinity;
    const vb = b.varianceMinutes ?? Infinity;
    if (va !== vb) return va - vb;
    const ea = a.etaAt ? Date.parse(a.etaAt) : Infinity;
    const eb = b.etaAt ? Date.parse(b.etaAt) : Infinity;
    if (ea !== eb) return ea - eb;
    return a.driverName.localeCompare(b.driverName);
  });
}

export function matchesFilter(row: FleetRow, filter: FleetFilter, now: number): boolean {
  switch (filter) {
    case "late":
      return !!row.dispatchId && row.risk === "late";
    case "at_risk":
      return !!row.dispatchId && row.risk === "at_risk";
    case "quiet":
      return isGpsQuiet(row, now);
    case "weather":
      return !!row.dispatchId && (row.weather?.length ?? 0) > 0;
    case "on_load":
      return !!row.dispatchId;
    case "idle":
      return !row.dispatchId;
    default:
      return true;
  }
}

export function fleetCounts(rows: FleetRow[], now: number) {
  return {
    onLoad: rows.filter((r) => r.dispatchId).length,
    late: rows.filter((r) => matchesFilter(r, "late", now)).length,
    atRisk: rows.filter((r) => matchesFilter(r, "at_risk", now)).length,
    quiet: rows.filter((r) => matchesFilter(r, "quiet", now)).length,
    weather: rows.filter((r) => matchesFilter(r, "weather", now)).length,
    idle: rows.filter((r) => !r.dispatchId).length,
    reportingLive: rows.filter((r) => minutesSince(r.recordedAt, now) <= GPS_QUIET_MINUTES).length,
  };
}

/** "just now", "12 min ago", "3 h ago", "2 days ago". */
export function agoLabel(iso: string, now: number): string {
  const m = Math.round(minutesSince(iso, now));
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h} h ago`;
  return `${Math.round(h / 24)} days ago`;
}

export const REOPEN_APP_MESSAGE = "We can't see your location right now. Please open the Truck Dispatch Pro driver app and keep the trip running so we can track your ETA. Thanks!";
