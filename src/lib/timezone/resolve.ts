import { isValidIanaTimezone } from "./iana";

export type ResolvedStopTimezone = {
  timezone: string;
  isFallback: boolean; // true when the stop has no timezone of its own (legacy row)
};

// Centralized priority order (spec section 3):
//   1. load_stops.timezone
//   2. (reserved) coordinate-derived timezone -- no provider configured
//      this phase, see geocodedTimezoneLookup() below
//   3. organizations.timezone
//   4. UTC, only if even the organization's own value is somehow invalid
// Never the server process's timezone, never the viewer's browser
// timezone -- both are explicitly excluded by construction: neither is
// ever passed into this function in the first place.
export function resolveStopTimezone(stopTimezone: string | null, organizationTimezone: string | null): ResolvedStopTimezone {
  if (stopTimezone && isValidIanaTimezone(stopTimezone)) {
    return { timezone: stopTimezone, isFallback: false };
  }
  if (organizationTimezone && isValidIanaTimezone(organizationTimezone)) {
    return { timezone: organizationTimezone, isFallback: true };
  }
  return { timezone: "UTC", isFallback: true };
}

// Architecture-ready boundary for a future coordinate -> timezone lookup
// (spec section 12). Deliberately does NOT infer timezone from US state
// text -- several states span multiple zones (FL, IN, KY, TN, TX, NE, SD,
// ID, OR among them), so a state-keyed lookup table would be silently
// wrong for a meaningful fraction of real addresses. No provider is
// configured; this always returns null today.
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- signature documents the intended future inputs even though no provider is wired up yet.
export function geocodedTimezoneLookup(latitude: number, longitude: number): string | null {
  return null;
}
