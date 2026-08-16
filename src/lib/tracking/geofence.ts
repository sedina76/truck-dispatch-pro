import "server-only";
import { distanceMeters } from "@/lib/geo/distance";

// ---------------------------------------------------------------------------
// GPS geofencing + arrival/departure automation (Phase 2B). Server-only:
// the driver's phone only ever submits raw location (spec section 9) -- all
// geofence evaluation and every status transition it can trigger happens
// here, called from the trusted location-ping route after a ping is
// accepted, never in the browser.
// ---------------------------------------------------------------------------

export const GEOFENCE_ACCURACY_LIMIT_M = 200; // spec section 6
export const EXIT_BUFFER_M = 150; // exit radius = enter radius + this (hysteresis, spec section 7)
export const CONFIRMATION_COUNT = 3; // spec section 7
export const CONFIRMATION_WINDOW_MS = 2 * 60 * 1000; // ~2 minutes, spec section 7

export type StopCoordinates = { latitude: number; longitude: number };

// Architecture-ready boundary for a real geocoding provider (spec section
// 4). Today this only ever returns coordinates already on the row --
// nothing here calls an external service, and none is configured anywhere
// in this app. A future geocoding integration plugs in as a second branch
// inside this one function, not a new call site scattered across the app.
export function resolveStopCoordinates(stop: { latitude: number | null; longitude: number | null }): StopCoordinates | null {
  if (stop.latitude == null || stop.longitude == null) return null;
  return { latitude: stop.latitude, longitude: stop.longitude };
}

export type GeofenceStateRow = {
  id?: string;
  state: "outside" | "candidate_inside" | "inside" | "candidate_outside" | "exited";
  inside_confirmations: number;
  outside_confirmations: number;
  first_inside_at: string | null;
  confirmed_inside_at: string | null;
  confirmed_outside_at: string | null;
};

export type GeofenceEvalResult = {
  state: GeofenceStateRow["state"];
  inside_confirmations: number;
  outside_confirmations: number;
  first_inside_at: string | null;
  confirmed_inside_at: string | null;
  confirmed_outside_at: string | null;
  last_distance_m: number;
  last_accuracy_m: number | null;
  last_location_at: string;
  justConfirmedInside: boolean;
  justConfirmedOutside: boolean;
};

const DEFAULT_ROW: Omit<GeofenceStateRow, "id"> = {
  state: "outside",
  inside_confirmations: 0,
  outside_confirmations: 0,
  first_inside_at: null,
  confirmed_inside_at: null,
  confirmed_outside_at: null,
};

// Pure state-machine step -- one ping in, one updated row out. Kept
// side-effect-free and independently testable from the DB/audit-log
// plumbing around it. See migration 0059's dispatch_geofence_state comment
// for the field meanings.
export function evaluateGeofencePing(
  existing: GeofenceStateRow | null,
  ping: { latitude: number; longitude: number; accuracyMeters: number | null; recordedAt: string },
  stop: StopCoordinates,
  enterRadiusM: number
): GeofenceEvalResult {
  const now = ping.recordedAt;
  const distance = distanceMeters(ping.latitude, ping.longitude, stop.latitude, stop.longitude);
  const exitRadiusM = enterRadiusM + EXIT_BUFFER_M;
  const base = existing ?? DEFAULT_ROW;

  // Once a stop is exited, its lifecycle is done -- a truck's GPS wandering
  // back near an already-departed stop's coordinates later is not a new
  // event. Distance/accuracy are still recorded for observability.
  if (base.state === "exited") {
    return { ...base, last_distance_m: distance, last_accuracy_m: ping.accuracyMeters, last_location_at: now, justConfirmedInside: false, justConfirmedOutside: false };
  }

  // Spec section 6: a low-accuracy reading keeps tracking (the raw ping is
  // still recorded elsewhere) but must never move the geofence state
  // machine. Distance/accuracy are still surfaced for the drawer, just not
  // trusted for automation.
  const accuracyEligible = ping.accuracyMeters == null || ping.accuracyMeters <= GEOFENCE_ACCURACY_LIMIT_M;
  if (!accuracyEligible) {
    return { ...base, last_distance_m: distance, last_accuracy_m: ping.accuracyMeters, last_location_at: now, justConfirmedInside: false, justConfirmedOutside: false };
  }

  let state: GeofenceStateRow["state"] = base.state;
  let { inside_confirmations, outside_confirmations, first_inside_at, confirmed_inside_at, confirmed_outside_at } = base;
  let justConfirmedInside = false;
  let justConfirmedOutside = false;

  if (distance <= enterRadiusM) {
    if (state === "inside") {
      outside_confirmations = 0; // stable inside, exit progress resets
    } else if (state === "candidate_outside") {
      // Bounced back inside before an exit was ever confirmed -- this is
      // not a new arrival (confirmed_inside_at is already set), just a
      // return to the stable inside state (spec section 7: hysteresis
      // must never toggle repeatedly).
      state = "inside";
      outside_confirmations = 0;
    } else {
      const withinWindow =
        state === "candidate_inside" && first_inside_at != null && new Date(now).getTime() - new Date(first_inside_at).getTime() <= CONFIRMATION_WINDOW_MS;
      if (withinWindow) {
        inside_confirmations += 1;
      } else {
        state = "candidate_inside";
        inside_confirmations = 1;
        first_inside_at = now;
      }
      if (inside_confirmations >= CONFIRMATION_COUNT) {
        state = "inside";
        if (!confirmed_inside_at) {
          confirmed_inside_at = now;
          justConfirmedInside = true;
        }
      }
    }
  } else if (distance > exitRadiusM) {
    if (state === "inside") {
      state = "candidate_outside";
      outside_confirmations = 1;
    } else if (state === "candidate_outside") {
      outside_confirmations += 1;
      if (outside_confirmations >= CONFIRMATION_COUNT) {
        state = "exited";
        if (!confirmed_outside_at) {
          confirmed_outside_at = now;
          justConfirmedOutside = true;
        }
      }
    } else {
      // Far outside while still only a candidate (or already outside) --
      // reset candidate-inside progress rather than letting a stale
      // first_inside_at eventually confirm off unrelated pings.
      state = "outside";
      inside_confirmations = 0;
      first_inside_at = null;
    }
  }
  // else: inside the hysteresis band (between enter and exit radius) --
  // deliberately no state change at all (spec section 7).

  return {
    state,
    inside_confirmations,
    outside_confirmations,
    first_inside_at,
    confirmed_inside_at,
    confirmed_outside_at,
    last_distance_m: distance,
    last_accuracy_m: ping.accuracyMeters,
    last_location_at: now,
    justConfirmedInside,
    justConfirmedOutside,
  };
}
