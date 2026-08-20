import { distanceMeters } from "@/lib/geo/distance";

// ---------------------------------------------------------------------------
// Point-to-route-geometry distance (Phase 2D). Reuses the existing Haversine
// helper (distance.ts) for the single-point case; adds only what deviation
// detection needs beyond it: distance from a GPS point to the nearest point
// on the CALCULATED route polyline (not a straight line to the destination
// -- spec section 3).
//
// This is deliberately NOT full road-network map matching (spec section 5):
// each segment of the stored, decimated route_geometry (up to 200 points,
// see osrm-provider.ts) is treated as a straight line, and the perpendicular
// distance from the GPS point to each segment is computed using a local
// flat-earth (equirectangular) projection centered on that segment. This is
// the standard lightweight approximation for "how far off this line is a
// point," and is accurate to well under 1% at the few-mile segment lengths
// a decimated long-haul route produces -- more than sufficient precision for
// a threshold measured in tenths of a mile. It answers "materially away from
// the expected route?", not "which lane is the truck in?" (spec section 5).
//
// Known limitation (documented, not silently claimed away -- spec section
// 52): a decimated route's consecutive points can be a few miles apart on a
// long, mostly-straight highway. If the real road curves meaningfully
// between two stored points, the straight-line segment between them is a
// slight underestimate of how "on-route" a point near that curve actually
// is. This does not affect correctness at the accuracy this feature needs,
// but it is not true map matching.
// ---------------------------------------------------------------------------

/** [lon, lat] pairs, matching the stored route_geometry / OSRM GeoJSON order. */
export type RouteGeometryPoint = [number, number];

function metersPerDegreeAt(latitude: number): { lat: number; lon: number } {
  const metersPerDegLat = 111320;
  const metersPerDegLon = 111320 * Math.cos((latitude * Math.PI) / 180);
  return { lat: metersPerDegLat, lon: metersPerDegLon };
}

// Perpendicular distance (meters) from a point to a line segment, via a
// local equirectangular projection with the segment's own midpoint latitude
// as the reference (keeps the longitude scale factor accurate for that
// specific segment, rather than one global reference for the whole route).
function distancePointToSegmentMeters(pLat: number, pLon: number, aLat: number, aLon: number, bLat: number, bLon: number): number {
  const refLat = (aLat + bLat) / 2;
  const scale = metersPerDegreeAt(refLat);
  const toXY = (lat: number, lon: number) => ({ x: (lon - aLon) * scale.lon, y: (lat - aLat) * scale.lat });

  const a = { x: 0, y: 0 }; // aLat/aLon is the projection origin by construction
  const b = toXY(bLat, bLon);
  const p = toXY(pLat, pLon);

  const abx = b.x - a.x;
  const aby = b.y - a.y;
  const lengthSq = abx * abx + aby * aby;
  // Degenerate (zero-length) segment -- just the distance to point A.
  let t = lengthSq > 0 ? ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSq : 0;
  t = Math.max(0, Math.min(1, t)); // clamp to the segment, not the infinite line
  const closestX = a.x + t * abx;
  const closestY = a.y + t * aby;
  const dx = p.x - closestX;
  const dy = p.y - closestY;
  return Math.sqrt(dx * dx + dy * dy);
}

export type NearestRoutePoint = {
  distanceMeters: number;
  /** Index of the segment's start point in the geometry array. */
  segmentIndex: number;
};

// Linear scan over every segment. Deliberately not bounding-box-optimized
// (spec section 45 allows this "if useful") -- route_geometry is already
// capped at 200 points (osrm-provider.ts's MAX_GEOMETRY_POINTS), so this is
// at most ~199 cheap arithmetic segment checks per GPS ping, well under a
// millisecond. Add a bounding-box pre-filter only if real measurement ever
// shows this matters; it would be premature complexity today.
export function nearestPointOnRoute(latitude: number, longitude: number, geometry: RouteGeometryPoint[] | null): NearestRoutePoint | null {
  if (!geometry || geometry.length === 0) return null;
  if (geometry.length === 1) {
    return { distanceMeters: distanceMeters(latitude, longitude, geometry[0][1], geometry[0][0]), segmentIndex: 0 };
  }

  let best = Infinity;
  let bestIndex = 0;
  for (let i = 0; i < geometry.length - 1; i++) {
    const [aLon, aLat] = geometry[i];
    const [bLon, bLat] = geometry[i + 1];
    const d = distancePointToSegmentMeters(latitude, longitude, aLat, aLon, bLat, bLon);
    if (d < best) {
      best = d;
      bestIndex = i;
    }
  }
  return { distanceMeters: best, segmentIndex: bestIndex };
}

// Convenience wrapper for callers that only need the number. Returns null
// for missing/empty geometry -- the caller (evaluate-route-deviation.ts)
// is responsible for turning that into an honest "unavailable" status, not
// a fabricated on-route/off-route answer (spec section 18).
export function distancePointToRoute(latitude: number, longitude: number, geometry: RouteGeometryPoint[] | null): number | null {
  return nearestPointOnRoute(latitude, longitude, geometry)?.distanceMeters ?? null;
}
