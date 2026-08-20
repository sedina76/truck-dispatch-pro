// Centralized severity classifier (spec section 9: "Create ONE centralized
// severity classifier. Do not scatter severity rules through React
// components."). Every place that opens/re-syncs an exception (sync.ts)
// calls this -- the UI never independently decides severity.
import type { ExceptionSeverity, ExceptionType } from "./types";

export type SeverityContext = {
  exceptionType: ExceptionType;
  // Compound awareness (spec section 8/9's explicit example: OFF ROUTE +
  // LATE together is CRITICAL, escalated from either type's own baseline).
  // "Sibling" = another active (non-resolved) exception on the SAME
  // dispatch right now.
  hasActiveOffRouteSibling?: boolean;
  hasActiveLateSibling?: boolean;
  detentionMinutesOver?: number | null;
  staleMinutes?: number | null;
  daysOverdue?: number | null; // compliance: positive = already expired
};

// Starting guidance from spec section 9, inspected against this org's
// actual detention-free-minutes/stale-GPS-threshold settings where a
// magnitude judgment is needed (rather than inventing arbitrary numbers):
//   CRITICAL - OFF ROUTE + LATE (or LATE + OFF ROUTE) compound
//   HIGH     - confirmed OFF ROUTE, LATE, severe GPS stale, extended detention
//   MEDIUM   - AT RISK, detention, GPS stale, POD missing
//   LOW      - informational (e.g. compliance expiring soon, not yet overdue)
export function classifyExceptionSeverity(ctx: SeverityContext): ExceptionSeverity {
  if (ctx.exceptionType === "off_route" && ctx.hasActiveLateSibling) return "critical";
  if (ctx.exceptionType === "late" && ctx.hasActiveOffRouteSibling) return "critical";

  switch (ctx.exceptionType) {
    case "off_route":
      return "high";
    case "late":
      return "high";
    case "at_risk":
      return "medium";
    case "detention":
      // "Extended detention" -- past double the free time is a simple,
      // defensible bar without inventing an unrequested new org setting.
      if (ctx.detentionMinutesOver != null && ctx.detentionMinutesOver >= 120) return "high";
      return "medium";
    case "gps_stale":
      // "Severe" GPS stale vs. a routine few-minute reporting gap. 30
      // minutes is 6x the existing 5-minute stale threshold (board-actions.ts
      // STALE_LOCATION_MINUTES) -- long enough to mean "probably not just a
      // signal blip."
      if (ctx.staleMinutes != null && ctx.staleMinutes >= 30) return "high";
      return "medium";
    case "pod_missing":
      return "medium";
    case "compliance":
      // Already expired (days overdue > 0) is operationally urgent; a
      // document merely approaching expiry is informational.
      if (ctx.daysOverdue != null && ctx.daysOverdue > 0) return "high";
      return "low";
    default:
      return "medium";
  }
}
