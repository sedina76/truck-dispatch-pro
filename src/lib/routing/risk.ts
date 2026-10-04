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

/** 45 -> "45 min", 312 -> "5 h 12 min", 2656 -> "1 day 20 h" (minutes, never "m", which reads as meters). */
export function formatDurationMinutes(minutes: number): string {
  const m = Math.max(0, Math.round(minutes));
  if (m < 60) return `${m} min`;
  if (m < 24 * 60) {
    const h = Math.floor(m / 60);
    const rest = m % 60;
    return rest ? `${h} h ${rest} min` : `${h} h`;
  }
  const d = Math.floor(m / (24 * 60));
  const h = Math.floor((m % (24 * 60)) / 60);
  return `${d} ${d === 1 ? "day" : "days"}${h ? ` ${h} h` : ""}`;
}

export function formatLateLabel(scheduleVarianceMinutes: number | null): string {
  if (scheduleVarianceMinutes == null) return "";
  const lateBy = -scheduleVarianceMinutes;
  if (lateBy <= 0) return "";
  return `by ${formatDurationMinutes(lateBy)}`;
}

export function formatMarginLabel(scheduleVarianceMinutes: number | null): string {
  if (scheduleVarianceMinutes == null || scheduleVarianceMinutes <= 0) return "";
  return `${formatDurationMinutes(scheduleVarianceMinutes)} to spare`;
}

// ---------------------------------------------------------------------------
// Required rest for a SOLO property-carrying driver (FMCSA hours of service),
// applied to the routing provider's pure driving time so a long-haul ETA is
// realistic rather than "drives non-stop":
//   - at most 11 h driving per shift, then a 10 h off-duty rest,
//   - a 30 min break once 8 h of driving have accumulated in a shift.
// Simplifications (stated in the UI as "includes required rest, solo"):
// assumes the driver starts the leg with a fresh clock (the app does not
// know hours already used today or the 60/70-hour week), and ignores the
// 14 h window (11 h driving + 30 min break always fits inside it).
// Team drivers are not modelled -- nothing in the app records them yet.
// ---------------------------------------------------------------------------
export const HOS = {
  MAX_DRIVING_PER_SHIFT_S: 11 * 3600,
  BREAK_AFTER_DRIVING_S: 8 * 3600,
  BREAK_S: 30 * 60,
  OFF_DUTY_RESET_S: 10 * 3600,
} as const;

/** Driving seconds -> elapsed seconds including the required breaks and rests. */
export function addRequiredRest(drivingSeconds: number): number {
  let remaining = Math.max(0, drivingSeconds);
  let elapsed = 0;
  while (remaining > 0) {
    const shiftDriving = Math.min(remaining, HOS.MAX_DRIVING_PER_SHIFT_S);
    elapsed += shiftDriving + (shiftDriving > HOS.BREAK_AFTER_DRIVING_S ? HOS.BREAK_S : 0);
    remaining -= shiftDriving;
    if (remaining > 0) elapsed += HOS.OFF_DUTY_RESET_S;
  }
  return elapsed;
}

/** Whether the ETA for this much driving includes any break or rest (for the UI note). */
export function etaIncludesRest(drivingSeconds: number | null): boolean {
  return drivingSeconds != null && drivingSeconds > HOS.BREAK_AFTER_DRIVING_S;
}

/** Geofence distance: feet when close (under a quarter mile), miles otherwise. 1593991 -> "990 mi", 120 -> "394 ft". */
export function formatDistance(meters: number | null): string {
  if (meters == null) return "--";
  const feet = meters * 3.28084;
  if (feet < 1320) return `${Math.round(feet).toLocaleString("en-US")} ft`;
  const miles = meters / 1609.344;
  return miles >= 10 ? `${Math.round(miles).toLocaleString("en-US")} mi` : `${miles.toFixed(1)} mi`;
}
