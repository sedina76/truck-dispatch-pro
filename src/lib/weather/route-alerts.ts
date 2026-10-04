import "server-only";
import { parseNwsAlerts, mergeAlerts, routeCheckPoints, type WeatherAlert } from "./nws";

// Asks api.weather.gov which alerts are active at each check point of a
// truck's trip. Free, no key; NWS asks for a User-Agent naming the app.
// Answers are cached ~10 minutes per ~2 km spot, every request is capped at
// 4 s, and any failure simply means "no alerts shown" -- weather never
// blocks a page. Set WEATHER_ALERTS=off to turn it off.

const NWS = "https://api.weather.gov/alerts/active";
const UA = "TruckDispatchPro/1.0 (dispatch weather alerts)";
const TTL_MS = 10 * 60 * 1000;
const TIMEOUT_MS = 4000;
const cache = new Map<string, { at: number; body: unknown }>();

async function alertsAt(lat: number, lon: number): Promise<unknown> {
  const key = `${lat.toFixed(2)},${lon.toFixed(2)}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < TTL_MS) return hit.body;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${NWS}?point=${lat.toFixed(4)},${lon.toFixed(4)}`, {
      headers: { "User-Agent": UA, Accept: "application/geo+json" },
      signal: ctrl.signal,
      cache: "no-store",
    });
    // Outside the US (or a point at sea) the NWS answers 400/404: no alerts there.
    const body = res.ok ? await res.json() : null;
    if (cache.size > 2000) cache.clear();
    cache.set(key, { at: Date.now(), body });
    return body;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export function weatherEnabled(): boolean {
  return process.env.WEATHER_ALERTS !== "off";
}

/** Driving-hazard alerts for one trip (truck position, route to the next stop, its stops). */
export async function weatherAlertsForTrip(input: Parameters<typeof routeCheckPoints>[0]): Promise<WeatherAlert[]> {
  if (!weatherEnabled()) return [];
  const points = routeCheckPoints(input);
  if (points.length === 0) return [];
  const answers = await Promise.all(points.map(async (p) => parseNwsAlerts(await alertsAt(p.lat, p.lon), p.where)));
  return mergeAlerts(answers);
}

type Supabase = { from: (t: string) => any }; // eslint-disable-line @typescript-eslint/no-explicit-any

/** Everything weatherAlertsForTrip needs, read for one dispatch (route, stops, latest GPS). */
export async function weatherAlertsForDispatch(supabase: Supabase, dispatchId: string): Promise<WeatherAlert[]> {
  if (!weatherEnabled()) return [];
  try {
    const { data: d } = await supabase.from("dispatches").select("load_id, driver_id, status").eq("id", dispatchId).maybeSingle();
    if (!d || ["delivered", "completed", "cancelled"].includes(d.status)) return [];
    const [{ data: route }, { data: stops }, { data: gps }] = await Promise.all([
      supabase.from("dispatch_route_intelligence").select("route_geometry, updated_at").eq("dispatch_id", dispatchId).order("updated_at", { ascending: false }).limit(1).maybeSingle(),
      supabase.from("load_stops").select("stop_type, stop_sequence, facility_name, city, latitude, longitude, departed_at").eq("load_id", d.load_id).order("stop_sequence"),
      supabase.from("driver_latest_locations").select("latitude, longitude, dispatch_id").eq("driver_id", d.driver_id).maybeSingle(),
    ]);
    const remaining = ((stops ?? []) as { stop_type: string; facility_name: string | null; city: string | null; latitude: number | null; longitude: number | null; departed_at: string | null }[])
      .filter((s) => !s.departed_at && s.latitude != null && s.longitude != null)
      .map((s) => ({ lat: s.latitude as number, lon: s.longitude as number, label: `${s.stop_type} (${s.facility_name || s.city || "stop"})` }));
    return await weatherAlertsForTrip({
      truck: gps && gps.dispatch_id === dispatchId ? { lat: gps.latitude, lon: gps.longitude } : null,
      route: (route?.route_geometry as [number, number][] | null) ?? null,
      stops: remaining,
    });
  } catch (err) {
    console.warn("[weather] lookup failed:", err instanceof Error ? err.message : err);
    return [];
  }
}
