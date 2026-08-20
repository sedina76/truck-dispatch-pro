// Shared types for the Phase 2E Exception Center. Mirrors the enum values
// in migration 0063 exactly -- if that migration hasn't been applied yet,
// nothing in this file itself breaks (it's just TypeScript), only the
// actual database calls that reference operational_exceptions do, and
// those all degrade gracefully (see src/lib/exceptions/sync.ts and
// src/app/(app)/dispatch/exceptions/actions.ts).

export type ExceptionType = "off_route" | "late" | "at_risk" | "detention" | "gps_stale" | "pod_missing" | "compliance";
export type ExceptionSeverity = "low" | "medium" | "high" | "critical";
export type ExceptionStatus = "open" | "acknowledged" | "resolved";

export const EXCEPTION_TYPE_LABEL: Record<ExceptionType, string> = {
  off_route: "Off Route",
  late: "Late",
  at_risk: "At Risk",
  detention: "Detention",
  gps_stale: "GPS Stale",
  pod_missing: "POD Missing",
  compliance: "Compliance",
};

export const SEVERITY_LABEL: Record<ExceptionSeverity, string> = {
  critical: "Critical",
  high: "High",
  medium: "Medium",
  low: "Low",
};

// Higher number = more urgent. Used for default sort (spec section 23:
// "severity descending") and for detecting escalation (section 10).
export const SEVERITY_RANK: Record<ExceptionSeverity, number> = { critical: 4, high: 3, medium: 2, low: 1 };

export const STATUS_LABEL: Record<ExceptionStatus, string> = {
  open: "Open",
  acknowledged: "Acknowledged",
  resolved: "Resolved",
};

// A row as rendered in the Exception Center's main table / KPI counts --
// one row per operational INCIDENT (spec review item 4), sourced from the
// operational_exceptions_grouped SQL view (migration 0063), not the raw
// operational_exceptions table. A dispatch with both an active OFF ROUTE
// and LATE episode is ONE row here, led by the higher-severity one;
// exceptionTypes carries every type contributing to it, deterministically
// computed at the query layer so pagination boundaries can never split or
// duplicate an incident. Deliberately flat/denormalized -- built by the
// list query in actions.ts, adding joined load/truck/driver labels the
// table needs without a client-side N+1.
export type ExceptionListRow = {
  // The LEADING (highest-severity) episode's own id -- Acknowledge/Assign/
  // Resolve/notes in the drawer act on this specific episode by default;
  // the drawer also surfaces the other contributing episodes (via
  // exceptionTypes) so a dispatcher isn't limited to only the primary one.
  id: string;
  exceptionType: ExceptionType; // the leading/primary type
  exceptionTypes: ExceptionType[]; // every active type in this incident, including the primary
  severity: ExceptionSeverity; // the leading episode's severity (== the max across the incident)
  status: ExceptionStatus;
  title: string;
  summary: string | null;
  dispatchId: string | null;
  loadNumber: string | null;
  truckUnit: string | null;
  driverName: string | null;
  firstDetectedAt: string;
  lastDetectedAt: string;
  assignedTo: string | null;
  assignedToName: string | null;
  acknowledgedAt: string | null;
};
