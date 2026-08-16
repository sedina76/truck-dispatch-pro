import "server-only";
import type { RouteRequest, RouteResult, RoutingProvider } from "./types";
import { RoutingProviderError } from "./types";

// ---------------------------------------------------------------------------
// OSRM HTTP API provider. OSRM's request/response shape is a de facto
// standard several self-hosted and commercial routing backends mirror, so
// this same provider works unmodified against:
//   - the free public demo server (the zero-config default below), or
//   - a self-hosted OSRM instance, or
//   - any other OSRM-API-compatible host,
// just by changing OSRM_BASE_URL. No inspection turned up any routing
// provider already configured in this app (only maplibre-gl, a map
// RENDERING library with no routing capability of its own, and free OSM
// raster tiles) -- this is a genuinely new integration, chosen as the
// lowest-friction option that pairs with the existing free-tile-server
// ethos and needs no signup to start using today.
//
// IMPORTANT: the public demo server (router.project-osrm.org) is free and
// requires no API key, but per OSRM's own usage policy it is explicitly
// NOT intended for production traffic (no SLA, no volume guarantee, can
// rate-limit or block). Exactly the same caveat this app already carries
// for its OSM raster tiles. For real production use, set OSRM_BASE_URL to
// a self-hosted OSRM instance or a commercial OSRM-compatible endpoint --
// no code change required, only the env var.
//
// TRUCK ROUTING LIMITATION (spec section 6): OSRM's default 'driving'
// profile is standard automobile routing. It does NOT account for truck
// height, weight, hazmat, or bridge/commercial-vehicle restrictions. Every
// route this provider returns is labeled "estimated road routing" in the
// UI and in this codebase -- never presented as truck-safe. A truck-aware
// profile (a custom OSRM car-hgv profile, or a different provider such as
// OpenRouteService's driving-hgv profile) can be added later as a second
// RoutingProvider implementation behind the same interface, with zero
// changes to any call site.
// ---------------------------------------------------------------------------

const DEFAULT_BASE_URL = "https://router.project-osrm.org";
const REQUEST_TIMEOUT_MS = 8000;
const MAX_GEOMETRY_POINTS = 200; // decimated for storage/network size, not route accuracy

function decimate(coords: [number, number][], maxPoints: number): [number, number][] {
  if (coords.length <= maxPoints) return coords;
  const stride = Math.ceil(coords.length / maxPoints);
  const out: [number, number][] = [];
  for (let i = 0; i < coords.length; i += stride) out.push(coords[i]);
  // Always keep the exact final point (route endpoint) even if the stride skipped past it.
  const last = coords[coords.length - 1];
  if (out[out.length - 1] !== last) out.push(last);
  return out;
}

export class OsrmProvider implements RoutingProvider {
  name = "osrm";
  private baseUrl: string;

  constructor(baseUrl?: string) {
    this.baseUrl = (baseUrl ?? process.env.OSRM_BASE_URL ?? DEFAULT_BASE_URL).replace(/\/$/, "");
  }

  async getRoute(request: RouteRequest): Promise<RouteResult> {
    // OSRM's own coordinate order is lon,lat (GeoJSON convention), the
    // opposite of this app's usual {latitude, longitude} shape -- swapped
    // right here, at the one boundary that needs to know about it.
    const coords = `${request.origin.longitude},${request.origin.latitude};${request.destination.longitude},${request.destination.latitude}`;
    const url = `${this.baseUrl}/route/v1/driving/${coords}?overview=full&geometries=geojson`;

    let res: Response;
    try {
      res = await fetch(url, { signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    } catch (err) {
      const timedOut = err instanceof Error && err.name === "TimeoutError";
      throw new RoutingProviderError(timedOut ? "timeout" : "network", timedOut ? "OSRM request timed out" : `OSRM request failed: ${err instanceof Error ? err.message : String(err)}`);
    }

    if (!res.ok) {
      throw new RoutingProviderError("provider_error", `OSRM returned HTTP ${res.status}`);
    }

    const body = (await res.json().catch(() => null)) as
      | { code: string; routes?: { distance: number; duration: number; geometry?: { coordinates: [number, number][] } }[] }
      | null;

    if (!body || body.code !== "Ok" || !body.routes || body.routes.length === 0) {
      throw new RoutingProviderError("no_route", `OSRM could not find a route (code: ${body?.code ?? "no response"})`);
    }

    const route = body.routes[0];
    const geometry = route.geometry?.coordinates ? decimate(route.geometry.coordinates, MAX_GEOMETRY_POINTS) : null;

    return {
      distanceMeters: route.distance,
      durationSeconds: route.duration,
      geometry,
      provider: this.name,
      calculatedAt: new Date().toISOString(),
    };
  }
}
