// Where a stop's map point (load_stops.latitude/longitude) came from, and what
// it may be used for. Pure -- shared by the lookup, the geofences, the ETA and
// every screen that shows a stop.
//
//   load_stops.geocode_source
//     'manual'          typed in by a dispatcher (Set Coordinates)
//     'census'          looked up from the street address (US Census geocoder)
//     'nominatim'       looked up from the street address (OpenStreetMap)
//     'city_center'     the stop has no findable street address; the point is
//                       the city's center -- good enough for an approximate
//                       ETA, NEVER for a geofence (a 300 m circle around a
//                       city center would fire arrivals at the wrong place)
//     'lookup_failed'   tried, nothing found (latitude stays null); retried
//                       after LOOKUP_RETRY_MS, or right away on Refresh ETA

export const CITY_CENTER = "city_center";
export const LOOKUP_FAILED = "lookup_failed";
export const LOOKUP_RETRY_MS = 6 * 60 * 60 * 1000;

export type StopPointRow = {
  latitude: number | null;
  longitude: number | null;
  geocode_source?: string | null;
};

/** Any point at all -- enough for an (approximate) ETA. */
export function hasStopPoint(row: StopPointRow): boolean {
  return row.latitude != null && row.longitude != null;
}

/** The stop's exact location -- required for geofences (automatic arrived/departed). */
export function hasExactStopPoint(row: StopPointRow): boolean {
  return hasStopPoint(row) && row.geocode_source !== CITY_CENTER;
}

/** "Facility" or "City, ST", marked when the ETA aims at the city center. */
export function stopLabel(row: { facility_name: string | null; city: string | null; state: string | null; geocode_source?: string | null }): string | null {
  const base = row.facility_name || [row.city, row.state].filter(Boolean).join(", ") || null;
  if (!base) return null;
  return row.geocode_source === CITY_CENTER ? `${base} (approx. -- city center)` : base;
}

/** Does this stop still need a lookup? (Never touches a typed-in or found point.) */
export function needsLookup(row: StopPointRow & { geocoded_at?: string | null; address_line1?: string | null }, now: number, force: boolean): boolean {
  if (hasStopPoint(row)) {
    // A city-center point is upgraded when the stop has a street address and
    // someone asks (Refresh ETA / Find on map).
    return force && row.geocode_source === CITY_CENTER && !!row.address_line1?.trim();
  }
  if (force) return true;
  if (row.geocode_source === LOOKUP_FAILED && row.geocoded_at) return now - new Date(row.geocoded_at).getTime() >= LOOKUP_RETRY_MS;
  return true;
}

/** What to tell the dispatcher about a stop's address, from the last lookup. */
export function addressProblem(geocodeSource: string | null, addressLine1: string | null): "not_found" | "city_only" | null {
  if (geocodeSource === LOOKUP_FAILED) return "not_found";
  if (geocodeSource === CITY_CENTER && addressLine1?.trim()) return "city_only";
  return null;
}
