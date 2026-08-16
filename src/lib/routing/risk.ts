// ---------------------------------------------------------------------------
// Centralized risk classification, confidence, and formatting (spec
// section 10: "Do not scatter risk logic across UI components"). Every
// surface (Board, Drawer, Live Tracking, Driver Portal) renders off the
// SAME risk_status/schedule_variance_minutes this module computes and
// evaluate-route.ts stores -- none of them re-derive it independently.
//
// Thresholds are centralized here as constants specifically so they can
// later become an organization setting (spec section 10) without touching
// every call site.
// ---------------------------------------------------------------------------

export type RiskStatus = "unknown" | "on_time" | "at_risk" | "late" | "arrived";
export type Confidence = "high" | "medium" | "low";

export const RISK_THRESHOLDS = {
  ON_TIME_MARGIN_MINUTES: 30, // ETA at least this many minutes before the effective deadline
  LATE_MARGIN_MINUTES: 15, // ETA more than this many minutes after the effective deadline
};

// scheduleVarianceMinutes: positive = early (minutes of margin before the
// deadline), negative = late. Effective deadline is appointment_window_end
// when a window exists, else the single appointment_at (spec section 11 --
// an ETA inside a window is on time even if after the window START).
export function classifyRisk(
  etaAt: Date | null,
  appointmentAt: Date | null,
  appointmentWindowEnd: Date | null,
  arrived: boolean
): { status: RiskStatus; scheduleVarianceMinutes: number | null } {
  if (arrived) return { status: "arrived", scheduleVarianceMinutes: null };

  const deadline = appointmentWindowEnd ?? appointmentAt;
  if (!etaAt || !deadline) return { status: "unknown", scheduleVarianceMinutes: null };

  const varianceMinutes = Math.round((deadline.getTime() - etaAt.getTime()) / 60000);

  if (varianceMinutes >= RISK_THRESHOLDS.ON_TIME_MARGIN_MINUTES) return { status: "on_time", scheduleVarianceMinutes: varianceMinutes };
  if (varianceMinutes >= -RISK_THRESHOLDS.LATE_MARGIN_MINUTES) return { status: "at_risk", scheduleVarianceMinutes: varianceMinutes };
  return { status: "late", scheduleVarianceMinutes: varianceMinutes };
}

// Confidence (spec section 16): no invented "traffic confidence" -- OSRM's
// free routing has no live traffic data, so this only ever reflects how
// fresh/trustworthy the INPUTS to the ETA are, never traffic conditions.
export function classifyConfidence(params: {
  gpsAgeMinutes: number | null;
  gpsAccuracyMeters: number | null;
  routeAgeMinutes: number | null;
  distanceRemainingMeters: number | null;
}): Confidence {
  const { gpsAgeMinutes, gpsAccuracyMeters, routeAgeMinutes, distanceRemainingMeters } = params;
  if (gpsAgeMinutes == null || routeAgeMinutes == null || distanceRemainingMeters == null) return "low";
  if (gpsAgeMinutes > 5 || routeAgeMinutes > 15) return "low"; // matches the verified 5-min GPS stale threshold
  if ((gpsAccuracyMeters != null && gpsAccuracyMeters > 200) || routeAgeMinutes > 7 || distanceRemainingMeters < 500) return "medium";
  return "high";
}

// Route progress (spec section 18): only computed when a stable baseline
// (initial_distance_meters, set once per target stop -- see 0060's
// comment) exists. Never fabricated from an arbitrary straight-line
// position comparison.
export function computeRouteProgress(currentDistanceMeters: number | null, initialDistanceMeters: number | null): number | null {
  if (currentDistanceMeters == null || initialDistanceMeters == null || initialDistanceMeters <= 0) return null;
  const progress = 1 - currentDistanceMeters / initialDistanceMeters;
  return Math.max(0, Math.min(1, progress));
}

// Spec section 17: no false precision.
export function formatMiles(meters: number | null): string {
  if (meters == null) return "--";
  const miles = meters / 1609.344;
  if (miles >= 10) return `${Math.round(miles)} mi`;
  return `${miles.toFixed(1)} mi`;
}

export function formatLateLabel(scheduleVarianceMinutes: number | null): string {
  if (scheduleVarianceMinutes == null) return "";
  const lateBy = -scheduleVarianceMinutes;
  if (lateBy <= 0) return "";
  return `${lateBy}m LATE`;
}

export function formatMarginLabel(scheduleVarianceMinutes: number | null): string {
  if (scheduleVarianceMinutes == null || scheduleVarianceMinutes <= 0) return "";
  return `${scheduleVarianceMinutes} min margin`;
}
