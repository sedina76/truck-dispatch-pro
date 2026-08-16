import "server-only";
import { createClient } from "@/lib/supabase/server";

// Simple future-ready query over driver_locations history (spec section
// 13) -- route playback / stop detection / mileage verification /
// geofencing are explicitly NOT built this phase; this is only the read
// path they'll eventually need. RLS on driver_locations already scopes
// this to the caller's own organization (org staff, owner/admin/
// dispatcher) -- no separate org check needed here.
export type LocationHistoryPoint = {
  latitude: number;
  longitude: number;
  accuracyMeters: number | null;
  speedKph: number | null;
  heading: number | null;
  altitude: number | null;
  recordedAt: string;
};

export async function getDriverLocationHistory(params: {
  driverId: string;
  dispatchId?: string;
  startTime: string;
  endTime: string;
  limit?: number;
}): Promise<LocationHistoryPoint[]> {
  const supabase = await createClient();
  let query = supabase
    .from("driver_locations")
    .select("latitude, longitude, accuracy_meters, speed_kph, heading, altitude, recorded_at")
    .eq("driver_id", params.driverId)
    .gte("recorded_at", params.startTime)
    .lte("recorded_at", params.endTime)
    .order("recorded_at", { ascending: true })
    .limit(params.limit ?? 2000);

  if (params.dispatchId) query = query.eq("dispatch_id", params.dispatchId);

  const { data, error } = await query;
  if (error) {
    console.error("[tracking] getDriverLocationHistory failed:", error);
    return [];
  }

  return (data ?? []).map((row) => ({
    latitude: row.latitude,
    longitude: row.longitude,
    accuracyMeters: row.accuracy_meters,
    speedKph: row.speed_kph,
    heading: row.heading,
    altitude: row.altitude,
    recordedAt: row.recorded_at,
  }));
}
