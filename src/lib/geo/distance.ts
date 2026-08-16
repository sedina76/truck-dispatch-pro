// Single shared distance helper (spec: "Do not duplicate distance math").
// Used by the driver-portal throttle logic (location-sharing.tsx) and the
// server-side geofence evaluator (lib/tracking/geofence.ts) -- both need
// the exact same Haversine calculation and must never quietly drift apart.
// No "server-only" import here on purpose: this file is safe to import from
// a "use client" component too.

export function distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371000; // meters
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}
