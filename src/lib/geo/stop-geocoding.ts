import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { censusUrl, parseCensus, nominatimUrl, parseNominatim, nominatimReverseUrl, parseNominatimReverse, NOMINATIM_DEFAULT, type GeoPoint, type StopAddress } from "./geocode-providers";
import { needsLookup, hasStopPoint, CITY_CENTER, LOOKUP_FAILED } from "./stop-point";

// Fills in the map point (latitude/longitude) of a load's stops from their
// addresses, so the ETA and the geofences (automatic arrived/departed) work
// without anyone typing coordinates. Runs:
//   - right after a load is created (in the background),
//   - on a GPS ping for a stop that still has no point (in the background),
//   - on Refresh ETA and "Find on map" (right away, retrying failures).
// A point is never overwritten once found or typed in (Set Coordinates wins),
// except a city-center point, which is upgraded when the street is found.
// The caller must already have checked the load belongs to the caller's
// organization -- this uses the service role, like the GPS pipeline does.

const REQUEST_TIMEOUT_MS = 6000;
const NOMINATIM_GAP_MS = 1100; // OSM policy: at most one request per second
const USER_AGENT = "TruckDispatchPro/1.0 (load stop geocoding)";
let lastNominatimAt = 0;

async function getJson(url: string, timeoutMs = REQUEST_TIMEOUT_MS): Promise<unknown> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" }, signal: ctrl.signal, cache: "no-store" });
    if (!res.ok) {
      console.warn(`[geocode] ${new URL(url).host} answered ${res.status}`);
      return null;
    }
    return await res.json();
  } catch (err) {
    console.warn(`[geocode] ${new URL(url).host} did not answer:`, err instanceof Error ? err.name : err);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function nominatim(a: StopAddress, street: boolean): Promise<GeoPoint | null> {
  const url = nominatimUrl(process.env.NOMINATIM_BASE_URL || NOMINATIM_DEFAULT, a, street);
  if (!url) return null;
  const wait = lastNominatimAt + NOMINATIM_GAP_MS - Date.now();
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  lastNominatimAt = Date.now();
  return parseNominatim(await getJson(url), street);
}

export type LookupOutcome = { point: GeoPoint; source: "census" | "nominatim" | typeof CITY_CENTER } | null;

/** Street address first (Census, then OpenStreetMap); the city center only as a last resort. */
export async function lookUpAddress(a: StopAddress, allowCityCenter = true): Promise<LookupOutcome> {
  if (process.env.GEOCODER === "none") return null;
  const census = censusUrl(a);
  if (census) {
    const p = parseCensus(await getJson(census));
    if (p) return { point: p, source: "census" };
  }
  const street = await nominatim(a, true);
  if (street) return { point: street, source: "nominatim" };
  if (!allowCityCenter) return null;
  const city = await nominatim(a, false);
  return city ? { point: city, source: CITY_CENTER } : null;
}

export type FillResult = { found: number; approximate: number; notFound: string[] };

type StopRow = StopAddress & {
  id: string;
  facility_name: string | null;
  latitude: number | null;
  longitude: number | null;
  geocode_source: string | null;
  geocoded_at: string | null;
};

export async function fillStopCoordinates(loadId: string, opts: { force?: boolean; stopIds?: string[] } = {}): Promise<FillResult> {
  const result: FillResult = { found: 0, approximate: 0, notFound: [] };
  if (process.env.GEOCODER === "none") return result;
  const supabase = createServiceRoleClient();
  let q = supabase
    .from("load_stops")
    .select("id, facility_name, address_line1, city, state, postal_code, country, latitude, longitude, geocode_source, geocoded_at")
    .eq("load_id", loadId)
    .order("stop_sequence");
  if (opts.stopIds?.length) q = q.in("id", opts.stopIds);
  const { data, error } = await q;
  if (error || !data) {
    if (error) console.warn("[geocode] could not read stops:", error.message);
    return result;
  }

  const now = Date.now();
  for (const stop of data as StopRow[]) {
    if (!needsLookup(stop, now, !!opts.force)) continue;
    const upgrading = hasStopPoint(stop); // a city-center point; only a street match replaces it
    const found = await lookUpAddress(stop, !upgrading);
    const label = stop.facility_name || [stop.city, stop.state].filter(Boolean).join(", ") || "stop";
    const stamp = new Date().toISOString();

    // Guarded writes: never overwrite a point someone typed in meanwhile.
    if (found && !(upgrading && found.source === CITY_CENTER)) {
      let w = supabase
        .from("load_stops")
        .update({ latitude: found.point.latitude, longitude: found.point.longitude, geocoded_at: stamp, geocode_source: found.source })
        .eq("id", stop.id);
      w = upgrading ? w.eq("geocode_source", CITY_CENTER) : w.is("latitude", null);
      const { error: e } = await w;
      if (e) console.warn("[geocode] could not save the stop's point:", e.message);
      else if (found.source === CITY_CENTER) result.approximate++;
      else result.found++;
    } else if (!upgrading) {
      const { error: e } = await supabase.from("load_stops").update({ geocoded_at: stamp, geocode_source: LOOKUP_FAILED }).eq("id", stop.id).is("latitude", null);
      if (e) console.warn("[geocode] could not record the failed lookup:", e.message);
      result.notFound.push(label);
    } else {
      result.notFound.push(label);
    }
  }
  return result;
}

/** Same, starting from a dispatch (GPS pipeline / Refresh ETA). */
export async function fillStopCoordinatesForDispatch(dispatchId: string, opts: { force?: boolean } = {}): Promise<FillResult | null> {
  const supabase = createServiceRoleClient();
  const { data } = await supabase.from("dispatches").select("load_id").eq("id", dispatchId).maybeSingle();
  if (!data?.load_id) return null;
  return fillStopCoordinates(String(data.load_id), opts);
}

// "Near Minneapolis, MN" for the truck's last GPS point. City level only, cached
// per ~1 km square for an hour, and given at most 2.5 s -- the panel shows the
// raw coordinates if the answer is slow or missing.
const placeCache = new Map<string, { name: string | null; at: number }>();
const PLACE_TTL_MS = 60 * 60 * 1000;

export async function nearPlace(latitude: number, longitude: number): Promise<string | null> {
  if (process.env.GEOCODER === "none") return null;
  const key = `${latitude.toFixed(2)},${longitude.toFixed(2)}`;
  const hit = placeCache.get(key);
  if (hit && Date.now() - hit.at < PLACE_TTL_MS) return hit.name;
  const wait = lastNominatimAt + NOMINATIM_GAP_MS - Date.now();
  if (wait > 1500) return hit?.name ?? null; // don't hold the panel up behind other lookups
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  lastNominatimAt = Date.now();
  const name = parseNominatimReverse(await getJson(nominatimReverseUrl(process.env.NOMINATIM_BASE_URL || NOMINATIM_DEFAULT, latitude, longitude), 2500));
  if (placeCache.size > 500) placeCache.clear();
  placeCache.set(key, { name, at: Date.now() });
  return name;
}
