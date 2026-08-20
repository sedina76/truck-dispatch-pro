import { NextRequest, NextResponse } from "next/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { evaluateGeofencesForDispatch } from "@/lib/tracking/evaluate-geofences";
import { evaluateRouteIntelligence } from "@/lib/routing/evaluate-route";
import { evaluateRouteDeviation } from "@/lib/tracking/evaluate-route-deviation";

const ACTIVE_DISPATCH_STATUSES = [
  "assigned",
  "accepted",
  "en_route_to_pickup",
  "at_pickup",
  "loaded",
  "en_route_to_delivery",
  "at_delivery",
];

export async function POST(request: NextRequest) {
  const identity = await getDriverPortalSession();
  if (!identity) {
    return NextResponse.json({ error: "Not logged in." }, { status: 401 });
  }

  const body = await request.json().catch(() => null);
  const latitude = Number(body?.latitude);
  const longitude = Number(body?.longitude);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
    return NextResponse.json({ error: "A valid latitude and longitude are required." }, { status: 400 });
  }
  // Friendly pre-check ahead of the DB's own check constraint
  // (0015_driver_portal.sql) -- same rule, just a clearer message than a
  // raw Postgres constraint-violation would give a phone browser.
  if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
    return NextResponse.json({ error: "Location coordinates are out of range." }, { status: 400 });
  }

  const accuracy = Number.isFinite(Number(body?.accuracy)) ? Number(body.accuracy) : null;
  const heading = Number.isFinite(Number(body?.heading)) ? Number(body.heading) : null;
  const speedKph = Number.isFinite(Number(body?.speedKph)) ? Number(body.speedKph) : null;
  const altitude = Number.isFinite(Number(body?.altitude)) ? Number(body.altitude) : null;

  const supabase = createServiceRoleClient();

  const { data: activeDispatch } = await supabase
    .from("dispatches")
    .select("id, truck_id")
    .eq("driver_id", identity.driverId)
    .in("status", ACTIVE_DISPATCH_STATUSES)
    .order("dispatched_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const recordedAt = new Date().toISOString();
  const basePing = {
    organization_id: identity.organizationId,
    driver_id: identity.driverId,
    dispatch_id: activeDispatch?.id ?? null,
    latitude,
    longitude,
    accuracy_meters: accuracy,
    heading,
    speed_kph: speedKph,
    recorded_at: recordedAt,
  };

  // truck_id/altitude are new (0058_driver_phone_gps.sql). Try the insert
  // with them first; if that migration isn't applied yet, PostgREST fails
  // the ENTIRE insert over one unknown column -- so on that specific
  // failure, retry without them rather than breaking the core, previously-
  // working "record a location" path that predates this migration. A
  // request that fails for any other reason is not retried.
  //
  // PGRST204 ("Could not find the '<col>' column ... in the schema
  // cache") is PostgREST's own code for an insert/update payload
  // referencing an unknown column -- distinct from 42703 (Postgres' raw
  // "column does not exist", what a SELECT against a missing column
  // returns). Both are treated as the same "migration not applied yet"
  // signal here.
  let { error } = await supabase.from("driver_locations").insert({
    ...basePing,
    truck_id: activeDispatch?.truck_id ?? null,
    altitude,
  });

  if (error?.code === "42703" || error?.code === "PGRST204") {
    console.warn("[driver-portal] driver_locations.truck_id/altitude not available yet (migration 0058 pending) -- inserting without them:", error.message);
    ({ error } = await supabase.from("driver_locations").insert(basePing));
  }

  if (error) {
    console.error("[driver-portal] location insert failed:", error);
    return NextResponse.json({ error: "Failed to record location." }, { status: 500 });
  }
  // driver_latest_locations is kept in sync by the sync_driver_latest_location
  // trigger (0058_driver_phone_gps.sql) -- no second write needed here.

  // Best-effort session heartbeat -- a ping that arrives without an active
  // Start Trip session (e.g. a stray late request right after Stop Trip),
  // or before driver_tracking_sessions exists at all, still gets recorded
  // above; there's just no session row to stamp.
  await supabase
    .from("driver_tracking_sessions")
    .update({ last_location_at: recordedAt })
    .eq("driver_id", identity.driverId)
    .eq("status", "active");

  // Phase 2B: geofence evaluation happens here, server-side, off the ping
  // that was JUST accepted above -- never in the browser (spec section 9).
  // Only meaningful when this ping belongs to an active dispatch. Fully
  // best-effort: evaluateGeofencesForDispatch() never throws, so a
  // migration-0059-not-applied-yet database or any other issue here can
  // never turn a successful location ping into a failed request.
  if (activeDispatch?.id) {
    await evaluateGeofencesForDispatch({
      dispatchId: activeDispatch.id,
      organizationId: identity.organizationId,
      latitude,
      longitude,
      accuracyMeters: accuracy,
      recordedAt,
    });

    // Phase 2C: route intelligence runs AFTER geofence evaluation, off the
    // same already-accepted ping (spec section 14's architecture -- GPS
    // saved, latest location updated, geofence evaluated, THEN route
    // intelligence attempted). Equally best-effort: a routing-provider
    // failure or missing configuration must never turn a successful GPS
    // ping into a failed request.
    await evaluateRouteIntelligence({
      dispatchId: activeDispatch.id,
      organizationId: identity.organizationId,
      latitude,
      longitude,
      accuracyMeters: accuracy,
      recordedAt,
    });

    // Phase 2D: route deviation runs LAST, after route intelligence, so it
    // always evaluates against whatever geometry is current as of THIS
    // ping (spec section 17's pipeline) -- including geometry route
    // intelligence may have just recalculated a moment ago. Equally
    // best-effort: never turns a successful GPS ping into a failed request.
    await evaluateRouteDeviation({
      dispatchId: activeDispatch.id,
      organizationId: identity.organizationId,
      latitude,
      longitude,
      accuracyMeters: accuracy,
      recordedAt,
    });
  }

  return NextResponse.json({ ok: true });
}
