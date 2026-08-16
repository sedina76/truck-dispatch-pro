// ---------------------------------------------------------------------------
// Routing provider abstraction (Phase 2C). The rest of Truck Dispatch Pro
// consumes only these normalized types -- no call site anywhere else in the
// app talks to a specific vendor's request/response shape. Swapping or
// adding a provider (a self-hosted OSRM instance, a commercial OSRM-
// compatible host, OpenRouteService, etc.) means writing one new file that
// implements RoutingProvider, not touching the app.
// ---------------------------------------------------------------------------

export type LatLon = { latitude: number; longitude: number };

export type RouteRequest = {
  origin: LatLon;
  destination: LatLon;
  /** Reserved for real multi-stop route requests; not used by Phase 2C's
   * single-leg (current position -> next operational stop) calculations. */
  waypoints?: LatLon[];
  /** 'truck' is accepted by the interface so a future provider can honor
   * it, but no provider wired up in this phase actually applies truck-
   * specific restrictions (height/weight/hazmat/bridge) -- see
   * osrm-provider.ts's own comment. Never claim truck-safe routing unless
   * the concrete provider genuinely supports it. */
  vehicleType?: "car" | "truck";
};

export type RouteResult = {
  distanceMeters: number;
  durationSeconds: number;
  /** [lon, lat] pairs, GeoJSON coordinate order, decimated to a bounded
   * point count. Null if the provider didn't return geometry. */
  geometry: [number, number][] | null;
  provider: string;
  calculatedAt: string; // ISO
};

export class RoutingProviderError extends Error {
  code: "timeout" | "network" | "no_route" | "provider_error";
  constructor(code: RoutingProviderError["code"], message: string) {
    super(message);
    this.code = code;
    this.name = "RoutingProviderError";
  }
}

export interface RoutingProvider {
  name: string;
  getRoute(request: RouteRequest): Promise<RouteResult>;
}
