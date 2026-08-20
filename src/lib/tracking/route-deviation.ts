import "server-only";
import { distancePointToRoute, type RouteGeometryPoint } from "@/lib/geo/route-distance";

// ---------------------------------------------------------------------------
// GPS route-deviation detection (Phase 2D). Same shape as Phase 2B's
// geofence state machine (src/lib/tracking/geofence.ts): a pure, side-
// effect-free step function (state + one ping in, updated state out),
// independently testable from the DB/notification plumbing around it. See
// migration 0062's dispatch_route_deviation_state comment for field
// meanings.
//
// FOUR DISTANCE ZONES (spec sections 8-9, validated recoveryM < warningM
// <= confirmedM):
//   <= recoveryM                    solidly on/recovered
//   recoveryM < d <= warningM       neutral -- comfortably on route still
//   warningM  < d <= confirmedM     soft "candidate" territory -- worth a
//                                   subtle UI signal, but can NEVER by
//                                   itself confirm a deviation (distance
//                                   never exceeds confirmedM in this zone)
//   > confirmedM                    hard deviation territory -- this is the
//                                   zone that actually drives the sustained-
//                                   confirmation counter toward OFF ROUTE
//                                   (spec section 9's worked example: 1.2mi,
//                                   1.3mi, 1.4mi -- all already > confirmedM)
// ---------------------------------------------------------------------------

export const DEVIATION_ACCURACY_LIMIT_M = 300; // spec section 6 -- looser than geofence's 200m (GEOFENCE_ACCURACY_LIMIT_M): geofence acts on ~300m radii, deviation acts on thresholds an order of magnitude larger (0.25-1.0mi), so a coarser accuracy gate is still well inside the finest threshold.
export const CANDIDATE_CONFIRMATION_COUNT = 3; // spec section 9
export const CANDIDATE_WINDOW_MS = 3 * 60 * 1000; // ~3 minutes, spec section 9
export const RECOVERY_CONFIRMATION_COUNT = 3; // spec section 12 ("2-3"); matches geofence.ts's own CONFIRMATION_COUNT for consistency across the app
export const RECOVERY_WINDOW_MS = 3 * 60 * 1000;

export type DeviationState = "on_route" | "candidate" | "off_route" | "recovering" | "recovered";

export type DeviationStateRow = {
  state: DeviationState;
  candidate_started_at: string | null;
  candidate_ping_count: number;
  confirmed_at: string | null;
  recovery_started_at: string | null;
  recovery_ping_count: number;
  recovered_at: string | null;
};

export type DeviationThresholds = { warningM: number; confirmedM: number; recoveryM: number };

export function validateDeviationThresholds(t: DeviationThresholds): string | null {
  if (t.recoveryM >= t.warningM) return "Recovery distance must be smaller than warning distance.";
  if (t.warningM > t.confirmedM) return "Warning distance must not exceed confirmed-deviation distance.";
  if (t.recoveryM <= 0 || t.warningM <= 0 || t.confirmedM <= 0) return "Thresholds must be positive.";
  return null;
}

export type DeviationEvalResult = DeviationStateRow & {
  distance_from_route_m: number;
  justConfirmedOffRoute: boolean;
  justRecovered: boolean;
};

const DEFAULT_ROW: DeviationStateRow = {
  state: "on_route",
  candidate_started_at: null,
  candidate_ping_count: 0,
  confirmed_at: null,
  recovery_started_at: null,
  recovery_ping_count: 0,
  recovered_at: null,
};

// Pure state-machine step. `distanceM` is already computed by the caller
// (nearestPointOnRoute against the current route geometry) -- this function
// only ever reasons about the number, never touches geometry itself, so it
// stays trivially unit-testable.
export function evaluateDeviationPing(existing: DeviationStateRow | null, distanceM: number, nowIso: string, thresholds: DeviationThresholds): DeviationEvalResult {
  const base = existing ?? DEFAULT_ROW;
  let { state, candidate_started_at, candidate_ping_count, confirmed_at, recovery_started_at, recovery_ping_count, recovered_at } = base;
  let justConfirmedOffRoute = false;
  let justRecovered = false;

  const now = nowIso;
  const { warningM, confirmedM, recoveryM } = thresholds;

  function cancelCandidate() {
    candidate_started_at = null;
    candidate_ping_count = 0;
  }
  function cancelRecoveryProgress() {
    recovery_started_at = null;
    recovery_ping_count = 0;
  }

  if (distanceM <= recoveryM) {
    // Zone A: solidly on/recovered.
    if (state === "off_route" || state === "recovering") {
      const withinWindow = state === "recovering" && recovery_started_at != null && new Date(now).getTime() - new Date(recovery_started_at).getTime() <= RECOVERY_WINDOW_MS;
      if (withinWindow) {
        recovery_ping_count += 1;
      } else {
        state = "recovering";
        recovery_ping_count = 1;
        recovery_started_at = now;
      }
      if (recovery_ping_count >= RECOVERY_CONFIRMATION_COUNT) {
        state = "recovered";
        recovered_at = now;
        justRecovered = true;
      }
    } else if (state === "candidate") {
      // Bounced back comfortably before ever confirming -- cancellation,
      // not an event (spec section 9's candidate-cancellation example).
      state = "on_route";
      cancelCandidate();
    } else {
      // on_route or recovered -- stays put.
      state = state === "recovered" ? "recovered" : "on_route";
    }
  } else if (distanceM > confirmedM) {
    // Zone D: hard deviation territory.
    if (state === "off_route") {
      cancelRecoveryProgress(); // dedup -- already confirmed, no new event
    } else if (state === "recovering") {
      state = "off_route"; // bounced back out of recovery before confirming it -- still meaningfully off route
      cancelRecoveryProgress();
    } else {
      // on_route, candidate, or recovered -- accumulate/continue the REAL
      // (hard) sustained-confirmation counter.
      const withinWindow = state === "candidate" && candidate_started_at != null && new Date(now).getTime() - new Date(candidate_started_at).getTime() <= CANDIDATE_WINDOW_MS;
      if (withinWindow) {
        candidate_ping_count += 1;
      } else {
        state = "candidate";
        candidate_ping_count = 1;
        candidate_started_at = now;
      }
      if (candidate_ping_count >= CANDIDATE_CONFIRMATION_COUNT) {
        state = "off_route";
        confirmed_at = now;
        justConfirmedOffRoute = true;
        // A fresh episode is starting -- clear the prior episode's recovery
        // markers so history reflects THIS confirmation, not a stale one.
        recovered_at = null;
        cancelRecoveryProgress();
      }
    }
  } else if (distanceM > warningM) {
    // Zone C: soft candidate territory. Can NEVER by itself trigger
    // confirmation (distance here never exceeds confirmedM) -- purely an
    // earlier, informational heads-up (spec section 30's "Route Check").
    if (state === "off_route" || state === "recovering") {
      // Meaningful movement back toward deviation while already off route
      // (or mid-recovery) -- cancel any recovery progress; still off route.
      cancelRecoveryProgress();
      if (state === "recovering") state = "off_route";
    } else if (state !== "candidate") {
      // on_route or recovered -> soft candidate. Deliberately does NOT set
      // candidate_started_at/ping_count -- those drive the HARD
      // confirmation counter, which this zone can never satisfy.
      state = "candidate";
    }
    // else: already candidate (soft or hard) -- no change.
  } else {
    // Zone B: neutral -- comfortably on route, just not tight enough to
    // count as "recovered" specifically.
    if (state === "candidate" && candidate_ping_count === 0) {
      // Only a SOFT candidate (zone C) cancels here -- a hard, actively-
      // confirming candidate (ping_count > 0) is left alone by a single
      // neutral-zone ping rather than thrown away (matches geofence.ts's
      // own "hysteresis band = no state change" philosophy for genuine
      // in-progress confirmations).
      state = "on_route";
    }
    // off_route/recovering/recovered/on_route/hard-candidate: no change.
  }

  return {
    state,
    candidate_started_at,
    candidate_ping_count,
    confirmed_at,
    recovery_started_at,
    recovery_ping_count,
    recovered_at,
    distance_from_route_m: distanceM,
    justConfirmedOffRoute,
    justRecovered,
  };
}

// Convenience combining distance calculation + the state step, for callers
// that have raw geometry rather than a pre-computed distance.
export function evaluateDeviationFromGeometry(
  existing: DeviationStateRow | null,
  ping: { latitude: number; longitude: number },
  geometry: RouteGeometryPoint[] | null,
  nowIso: string,
  thresholds: DeviationThresholds
): DeviationEvalResult | null {
  const distanceM = distancePointToRoute(ping.latitude, ping.longitude, geometry);
  if (distanceM == null) return null;
  return evaluateDeviationPing(existing, distanceM, nowIso, thresholds);
}
