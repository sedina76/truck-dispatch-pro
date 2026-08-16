"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { getLatestDocument, type DocumentRow } from "@/lib/documents/latest-document";
import { calculateDetention, type DetentionResult } from "@/lib/dispatch/detention";
import { zonedDateTimeToUtc, validateWindowOrder } from "@/lib/timezone/convert";
import { isValidIanaTimezone } from "@/lib/timezone/iana";
import { formatStopDateTime } from "@/lib/timezone/format";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

// ---------------------------------------------------------------------------
// updateDispatchBoardStatus -- the Dispatch Board's own status-move action,
// separate from updateDispatch() (the full-page edit form) because it has
// a different contract: no form/redirect, a typed {ok,error} result the
// kanban board uses to decide whether to keep or roll back its optimistic
// UI move, and it owns the per-status timestamp writes this feature adds.
// Same "expected error, never thrown into the route boundary" convention
// as src/lib/dispatch/errors.ts.
// ---------------------------------------------------------------------------

export type BoardStatusResult = { ok: true } | { ok: false; error: string };

const VALID_STATUSES = new Set([
  "assigned",
  "accepted",
  "en_route_to_pickup",
  "at_pickup",
  "loaded",
  "en_route_to_delivery",
  "at_delivery",
  "delivered",
  "completed",
  "cancelled",
]);

export async function updateDispatchBoardStatus(dispatchId: string, newStatus: string): Promise<BoardStatusResult> {
  if (!VALID_STATUSES.has(newStatus)) {
    return { ok: false, error: "Invalid status." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, error: "No organization on this account." };
  }

  // Re-read under RLS + an explicit organization_id check -- a cross-org
  // dispatchId is simply not found (RLS already guarantees this; the
  // explicit .eq is defense-in-depth, not the only guard). Split from the
  // 0057 timestamp columns below for the same reason as
  // getDispatchDrawerData(): these three fields existed before 0057 and
  // are all the status MOVE itself needs, so a not-yet-applied migration
  // must never block the core status update.
  const { data: dispatch, error: dispatchFetchError } = await supabase
    .from("dispatches")
    .select("id, status, load_id")
    .eq("id", dispatchId)
    .eq("organization_id", organizationId)
    .maybeSingle();

  // Same distinction as getDispatchDrawerData(): a real query failure
  // (e.g. a pending migration not yet applied) is not "no such dispatch."
  if (dispatchFetchError) {
    console.error(`[dispatch board] status lookup failed for dispatch ${dispatchId} (org ${organizationId}):`, dispatchFetchError);
    return { ok: false, error: "Unable to update status. Please try again." };
  }
  if (!dispatch) return { ok: false, error: "Dispatch not found." };

  const previousStatus = dispatch.status;
  if (previousStatus === newStatus) return { ok: true };

  // Optional/degradable, same as the drawer: if 0057 hasn't landed yet (or
  // this one query hits any other issue), the status move still goes
  // through -- it just can't apply "only set if still null" bookkeeping
  // for these five columns this time, so timestampsAvailable gates
  // writing to them below rather than attempting a doomed write against
  // columns that don't exist.
  const { data: existingTimestamps, error: timestampsReadError } = await supabase
    .from("dispatches")
    .select("en_route_pickup_at, loaded_at, in_transit_at, delivered_at, cancelled_at")
    .eq("id", dispatchId)
    .maybeSingle();
  const timestampsAvailable = !timestampsReadError;
  if (timestampsReadError) {
    console.warn(`[dispatch board] operational timestamps unavailable for dispatch ${dispatchId} (likely migration 0057 not applied yet) -- status will still update, timestamp bookkeeping skipped this time:`, timestampsReadError);
  }
  const priorTimestamps = (existingTimestamps ?? {}) as { en_route_pickup_at?: string | null; loaded_at?: string | null; in_transit_at?: string | null; delivered_at?: string | null; cancelled_at?: string | null };

  const now = new Date().toISOString();
  const dispatchUpdates: Record<string, string> = { status: newStatus };
  let pickupStopUpdate: Record<string, string> | null = null;
  let deliveryStopUpdate: Record<string, string> | null = null;

  // load_stops.arrived_at/departed_at already exist and are already read
  // elsewhere (Driver Profile trip history) but never written by any code
  // path -- reused here rather than duplicated onto dispatches (see
  // 0057_dispatch_board_upgrade.sql). Only fetched when actually needed,
  // to avoid an extra query on every drag.
  const loadId = dispatch.load_id;
  async function stopId(stopType: "pickup" | "delivery"): Promise<{ id: string; arrived_at: string | null; departed_at: string | null } | null> {
    const order = stopType === "pickup" ? { ascending: true } : { ascending: false };
    const { data } = await supabase
      .from("load_stops")
      .select("id, arrived_at, departed_at")
      .eq("load_id", loadId)
      .eq("stop_type", stopType)
      .order("stop_sequence", order)
      .limit(1)
      .maybeSingle();
    return data;
  }

  switch (newStatus) {
    case "en_route_to_pickup":
      if (timestampsAvailable && !priorTimestamps.en_route_pickup_at) dispatchUpdates.en_route_pickup_at = now;
      break;
    case "at_pickup": {
      const stop = await stopId("pickup");
      if (stop && !stop.arrived_at) pickupStopUpdate = { arrived_at: now };
      break;
    }
    case "loaded": {
      if (timestampsAvailable && !priorTimestamps.loaded_at) dispatchUpdates.loaded_at = now;
      const stop = await stopId("pickup");
      if (stop && !stop.departed_at) pickupStopUpdate = { ...(pickupStopUpdate ?? {}), departed_at: now };
      break;
    }
    case "en_route_to_delivery":
      if (timestampsAvailable && !priorTimestamps.in_transit_at) dispatchUpdates.in_transit_at = now;
      break;
    case "at_delivery": {
      const stop = await stopId("delivery");
      if (stop && !stop.arrived_at) deliveryStopUpdate = { arrived_at: now };
      break;
    }
    case "delivered": {
      if (timestampsAvailable && !priorTimestamps.delivered_at) dispatchUpdates.delivered_at = now;
      const stop = await stopId("delivery");
      if (stop && !stop.departed_at) deliveryStopUpdate = { ...(deliveryStopUpdate ?? {}), departed_at: now };
      break;
    }
    case "cancelled":
      if (timestampsAvailable && !priorTimestamps.cancelled_at) dispatchUpdates.cancelled_at = now;
      break;
    // assigned/accepted/completed: no dedicated timestamp column -- see
    // migration comment (dispatched_at already covers "assigned", and
    // these two statuses fold visually into the Assigned/Delivered
    // columns respectively).
  }

  const { error } = await supabase.from("dispatches").update(dispatchUpdates).eq("id", dispatchId);
  if (error) {
    console.error("[dispatch board] status update failed:", error);
    return { ok: false, error: "Unable to update status. Please try again." };
  }

  // Stop-timestamp writes are secondary to the status change itself -- a
  // failure here is logged, not surfaced as a failed status move (the
  // primary fact the user cares about, "did the card move", already
  // succeeded).
  if (pickupStopUpdate) {
    const pickup = await stopId("pickup");
    if (pickup) {
      const { error: stopErr } = await supabase.from("load_stops").update(pickupStopUpdate).eq("id", pickup.id);
      if (stopErr) console.error("[dispatch board] pickup stop timestamp update failed:", stopErr);
    }
  }
  if (deliveryStopUpdate) {
    const delivery = await stopId("delivery");
    if (delivery) {
      const { error: stopErr } = await supabase.from("load_stops").update(deliveryStopUpdate).eq("id", delivery.id);
      if (stopErr) console.error("[dispatch board] delivery stop timestamp update failed:", stopErr);
    }
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "dispatch",
    p_entity_id: dispatchId,
    p_action: "status_changed",
    p_changes: { field: "status", old_value: previousStatus, new_value: newStatus },
    p_organization_id: organizationId,
  });

  // Auto-stop tracking on Delivered (spec section 8): additive only, never
  // touches dispatch/load status logic itself -- this only ever closes an
  // ACTIVE driver_tracking_sessions row for THIS dispatch, after the real
  // status change above already succeeded. A failure here is logged, not
  // surfaced as a failed status move, matching the same "secondary write"
  // convention as the stop-timestamp writes above.
  //
  // Uses the service-role client, not the caller's RLS-scoped one, on
  // purpose -- driver_tracking_sessions (0058_driver_phone_gps.sql) has no
  // UPDATE policy for staff at all (only driver-portal server actions,
  // via service-role, are allowed to write it), so the RLS-scoped client
  // silently updates zero rows here otherwise (no error, just a no-op --
  // caught live during verification). Safe here specifically because the
  // dispatch's own organization_id was already verified against the
  // caller's org above before this point is ever reached.
  if (newStatus === "delivered") {
    const serviceRole = createServiceRoleClient();
    const { error: stopSessionError } = await serviceRole
      .from("driver_tracking_sessions")
      .update({ status: "completed", stopped_at: now })
      .eq("dispatch_id", dispatchId)
      .eq("status", "active");
    if (stopSessionError) console.error("[dispatch board] auto-stop tracking session on delivery failed:", stopSessionError);
  }

  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${dispatchId}`);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// getDispatchDrawerData -- loaded on demand when a card is clicked, never
// upfront for every card (spec section 9). Financial fields are filtered
// out server-side for role='driver' (the one org_role a real staff
// account can be assigned that this spec calls out) -- never left in the
// response for the client to merely hide. There is no 'carrier' org_role
// at all in this schema (carriers aren't staff-app users), so that half
// of the requirement is structurally satisfied already.
// ---------------------------------------------------------------------------

export type DrawerDocument = {
  type: string;
  label: string;
  doc: DocumentRow | null;
};

export type DrawerActivity = {
  id: string;
  action: string;
  changes: unknown;
  actorName: string | null;
  createdAt: string;
};

export type DispatchDrawerData = {
  dispatch: {
    id: string;
    status: string;
    dispatchedAt: string;
    notes: string | null;
    enRoutePickupAt: string | null;
    loadedAt: string | null;
    inTransitAt: string | null;
    deliveredAt: string | null;
    cancelledAt: string | null;
  };
  load: {
    id: string;
    loadNumber: string;
    commodity: string | null;
    weightLbs: number | null;
    equipmentType: string | null;
    totalMiles: number | null;
    specialInstructions: string | null;
    brokerName: string | null;
    customerName: string | null;
  };
  financials: {
    loadRate: number;
    carrierCost: number;
    dispatchFeePercentage: number;
    dispatchFeeAmount: number;
    carrierNetAmount: number;
    estimatedProfit: number | null;
  } | null;
  driver: { id: string; name: string; phone: string | null; status: string } | null;
  carrier: { id: string; name: string };
  truck: { unitNumber: string; make: string | null; model: string | null; year: number | null } | null;
  trailer: { unitNumber: string } | null;
  pickup: StopDetail | null;
  delivery: StopDetail | null;
  geofence: {
    automationMode: "off" | "suggest" | "automatic";
    pickup: StopGeofenceInfo | null;
    delivery: StopGeofenceInfo | null;
  };
  tracking: {
    available: boolean;
    reason: string;
    currentLocation: string | null;
    lastGpsUpdate: string | null;
    speedMph: number | null;
    accuracyMeters: number | null;
    lowAccuracy: boolean;
    stale: boolean;
  };
  routeIntelligence: RouteIntelligenceInfo | null;
  documents: DrawerDocument[];
  activity: DrawerActivity[];
};

// Phase 2C (0060_route_intelligence.sql). Road-route ETA/miles/risk for the
// dispatch's current operational target stop -- distinct from `tracking`
// above (raw GPS) and from `geofence` (arrival/departure confirmation).
// Null when the migration isn't applied yet or no row exists at all
// (degrades the same way geofence/tracking already do -- see the fetch
// below).
export type RouteIntelligenceInfo = {
  targetStopLabel: string | null;
  // Phase 2C.1 (spec section 28): ETA/appointment are always displayed in
  // the TARGET stop's own timezone -- not the origin, not the viewer's.
  targetStopTimezone: string;
  routeDistanceMeters: number | null;
  routeDurationSeconds: number | null;
  routeGeometry: [number, number][] | null;
  progress: number | null;
  estimatedArrivalAt: string | null;
  appointmentAt: string | null;
  appointmentWindowEnd: string | null;
  scheduleVarianceMinutes: number | null;
  riskStatus: "unknown" | "on_time" | "at_risk" | "late" | "arrived";
  confidence: "high" | "medium" | "low";
  calculationStatus: "ok" | "provider_unavailable" | "no_coordinates" | "no_target_stop";
  provider: string | null;
  calculatedAt: string | null;
};

type StopDetail = {
  id: string;
  companyName: string | null;
  addressLine1: string | null;
  city: string | null;
  state: string | null;
  scheduledAt: string | null;
  scheduledWindowEnd: string | null;
  referenceNumber: string | null;
  contactName: string | null;
  contactPhone: string | null;
  arrivedAt: string | null;
  departedAt: string | null;
  detention: DetentionResult | null;
  hasCoordinates: boolean;
  // Phase 2C.1: the zone actually used to render this stop (its own, or
  // the organization's fallback -- see resolveStopTimezone()), plus
  // whether that's a fallback (legacy row with no timezone of its own).
  timezone: string;
  timezoneIsFallback: boolean;
};

// Phase 2B (0059_gps_geofence_detention.sql). Degrades to all-null the same
// way tracking/detention already do if that migration isn't applied yet --
// never bundled into the same .select() as the load_stops core fields
// above it (the "one bad column fails the whole query" lesson from
// board-actions.ts's own history, see the drawer/board split further down).
export type StopGeofenceInfo = {
  hasCoordinates: boolean;
  state: "outside" | "candidate_inside" | "inside" | "candidate_outside" | "exited" | null;
  distanceM: number | null;
  accuracyM: number | null;
  radiusM: number;
  lastUpdateAt: string | null;
  arrivalConfirmedAt: string | null;
  statusApplied: boolean;
};

const DOC_TYPES: { type: string; label: string }[] = [
  { type: "rate_confirmation", label: "Rate Confirmation" },
  { type: "bol", label: "Bill of Lading" },
  { type: "pod", label: "Proof of Delivery" },
  { type: "lumper_receipt", label: "Lumper Receipt" },
  { type: "scale_ticket", label: "Scale Ticket" },
  { type: "fuel_receipt", label: "Fuel Receipt" },
  { type: "other", label: "Other" },
];

const STALE_LOCATION_MINUTES = 5;
const LOW_ACCURACY_METERS = 200;

// Real driver-phone GPS (0058_driver_phone_gps.sql), not a fake/placeholder
// telematics feed. Only trusted as THIS dispatch's location if the latest
// row's own dispatch_id still matches -- a driver whose tracking session
// has since moved to a different dispatch has, correctly, no current
// location for this one. No reverse geocoding is configured anywhere in
// this app (no Nominatim/Google/Mapbox geocoding call exists) -- rather
// than fabricate a "Near <City>, <State>" label, the real coordinates are
// shown as-is.
function buildTrackingInfo(
  latest: { latitude: number; longitude: number; accuracy_meters: number | null; speed_kph: number | null; dispatch_id: string | null; recorded_at: string } | null,
  dispatchId: string
): DispatchDrawerData["tracking"] {
  if (!latest || latest.dispatch_id !== dispatchId) {
    return {
      available: false,
      reason: "Driver location not available.",
      currentLocation: null,
      lastGpsUpdate: null,
      speedMph: null,
      accuracyMeters: null,
      lowAccuracy: false,
      stale: false,
    };
  }

  const ageMinutes = (Date.now() - new Date(latest.recorded_at).getTime()) / 60_000;
  const stale = ageMinutes > STALE_LOCATION_MINUTES;
  const lowAccuracy = latest.accuracy_meters != null && latest.accuracy_meters > LOW_ACCURACY_METERS;

  return {
    available: true,
    reason: stale ? `Location stale -- last update ${Math.round(ageMinutes)} min ago.` : "",
    currentLocation: `${latest.latitude.toFixed(4)}, ${latest.longitude.toFixed(4)}`,
    lastGpsUpdate: latest.recorded_at,
    speedMph: latest.speed_kph != null ? Math.round(latest.speed_kph * 0.621371) : null,
    accuracyMeters: latest.accuracy_meters,
    lowAccuracy,
    stale,
  };
}

export async function getDispatchDrawerData(dispatchId: string): Promise<DispatchDrawerData | { error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { error: "No organization on this account." };
  }

  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  const role = profile?.role ?? null;
  // The one org_role this spec explicitly excludes from financial data.
  // Every other staff role (owner/admin/dispatcher/accountant/viewer) can
  // see it, matching how internal financials are already treated
  // everywhere else in this app (Load Detail profitability, Carrier
  // Settlement's "Internal Revenue -- Staff Only" section, etc.).
  const canSeeFinancials = role !== "driver";

  // Split into two queries on purpose. Everything in this first one
  // existed before 0057 -- a valid, real dispatch must always be able to
  // render off of just this, so any failure here is a genuine error, not
  // a "not found". The five 0057 operational timestamp columns are
  // fetched separately below and degrade to null on failure instead of
  // taking the whole drawer down with them -- the same "an optional piece
  // failing must never make a valid dispatch unusable" principle already
  // applied to documents/activity/detention settings, just applied at the
  // column level instead of the relation level (one bad/renamed/not-yet-
  // migrated column bundled into a single .select() string fails the
  // ENTIRE query, even though the core dispatch/load/driver/truck/carrier
  // data is completely healthy).
  const { data: dispatch, error: dispatchError } = await supabase
    .from("dispatches")
    .select(
      "id, status, load_id, carrier_id, truck_id, trailer_id, driver_id, dispatched_at, notes, load_rate, dispatch_fee_percentage, dispatch_fee_amount, carrier_net_amount, carriers(legal_name), trucks(unit_number, make, model, year), trailers(unit_number), drivers(first_name, last_name, phone, status)"
    )
    .eq("id", dispatchId)
    .eq("organization_id", organizationId)
    .maybeSingle();

  // A real query failure (bad column, connection issue, etc.) is NOT the
  // same thing as "no such dispatch" -- collapsing the two previously
  // disguised a missing-migration schema error as "Dispatch not found.",
  // which sent a real bug down the wrong debugging path. The full error is
  // logged here (server-side dev/console only, never sent to the client);
  // the client gets a generic, honest "couldn't load" message instead.
  if (dispatchError) {
    console.error(`[dispatch drawer] query failed for dispatch ${dispatchId} (org ${organizationId}):`, dispatchError);
    return { error: "Unable to load dispatch details." };
  }

  // No error, but no row either: this is genuinely either (a) no dispatch
  // with this id exists, or (b) it belongs to another organization. RLS
  // (plus the explicit organization_id filter above) makes these two
  // cases indistinguishable ON PURPOSE -- every other cross-org check in
  // this app (loads, invoices, fuel logs, ...) returns the same generic
  // "not found" for both rather than confirming "that id exists, just not
  // in your org," which would itself leak information to a caller holding
  // a foreign id. Telling them apart would require a query that ignores
  // organization_id, i.e. weakening tenant isolation -- not done here.
  if (!dispatch) return { error: "Dispatch not found." };

  // Optional/degradable: the 0057 operational timestamps. If this
  // specific migration hasn't landed yet (or any other issue hits just
  // this query), the drawer still renders the real dispatch -- these
  // fields just come back null, same as "not reached that stage yet".
  // Logged as a warning (not silently swallowed) so it's visible in
  // server logs without failing the request.
  const { data: timestamps, error: timestampsError } = await supabase
    .from("dispatches")
    .select("en_route_pickup_at, loaded_at, in_transit_at, delivered_at, cancelled_at")
    .eq("id", dispatchId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (timestampsError) {
    console.warn(`[dispatch drawer] operational timestamps unavailable for dispatch ${dispatchId} (likely migration 0057 not applied yet):`, timestampsError);
  }
  const ts = (timestamps ?? {}) as { en_route_pickup_at?: string | null; loaded_at?: string | null; in_transit_at?: string | null; delivered_at?: string | null; cancelled_at?: string | null };

  const d = {
    ...(dispatch as unknown as {
      id: string;
      status: string;
      load_id: string;
      driver_id: string;
      dispatched_at: string;
      notes: string | null;
      load_rate: number;
      dispatch_fee_percentage: number;
      dispatch_fee_amount: number;
      carrier_net_amount: number;
      carriers: { legal_name: string } | null;
      trucks: { unit_number: string; make: string | null; model: string | null; year: number | null } | null;
      trailers: { unit_number: string } | null;
      drivers: { first_name: string; last_name: string; phone: string | null; status: string } | null;
    }),
    en_route_pickup_at: ts.en_route_pickup_at ?? null,
    loaded_at: ts.loaded_at ?? null,
    in_transit_at: ts.in_transit_at ?? null,
    delivered_at: ts.delivered_at ?? null,
    cancelled_at: ts.cancelled_at ?? null,
  };

  const [
    { data: load, error: loadError },
    { data: stops, error: stopsError },
    { data: org, error: orgError },
    { data: activityRows, error: activityError },
    { data: latestLocation, error: locationError },
    docs,
    { data: orgTz, error: orgTzError },
    { data: stopTimezones, error: stopTzError },
  ] = await Promise.all([
    supabase
      .from("loads")
      .select("id, load_number, commodity, weight_lbs, equipment_type, total_miles, special_instructions, brokers(company_name), customers(company_name)")
      .eq("id", d.load_id)
      .single(),
    supabase
      .from("load_stops")
      .select("id, stop_type, stop_sequence, facility_name, address_line1, city, state, scheduled_at, scheduled_window_end, reference_number, contact_name, contact_phone, arrived_at, departed_at")
      .eq("load_id", d.load_id)
      .order("stop_sequence"),
    supabase.from("organizations").select("pickup_detention_free_minutes, delivery_detention_free_minutes").eq("id", organizationId).single(),
    supabase
      .from("activity_logs")
      .select("id, action, changes, created_at, profiles!activity_logs_actor_id_fkey(full_name)")
      .eq("entity_type", "dispatch")
      .eq("entity_id", dispatchId)
      .order("created_at", { ascending: false })
      .limit(30),
    // driver_latest_locations (0058_driver_phone_gps.sql) -- only trusted
    // as THIS dispatch's location if its own dispatch_id still matches;
    // if the driver has since started tracking a different trip, that's a
    // different dispatch's location, not this one's, so it's treated the
    // same as "not available" below rather than shown as if it were current.
    d.driver_id
      ? supabase
          .from("driver_latest_locations")
          .select("latitude, longitude, accuracy_meters, speed_kph, dispatch_id, recorded_at")
          .eq("driver_id", d.driver_id)
          .maybeSingle()
      : Promise.resolve({ data: null, error: null }),
    Promise.all(DOC_TYPES.map((dt) => getLatestDocument(supabase, "load", d.load_id, dt.type))),
    // Phase 2C.1: organizations.timezone predates everything (0002) so
    // this single-column query can never fail for schema reasons, but is
    // still a SEPARATE query from the 0057-dependent detention settings
    // above -- bundling them would mean a 0057 regression (has happened
    // live before, see board-actions.ts history) breaks timezone fallback
    // too, for no reason.
    supabase.from("organizations").select("timezone").eq("id", organizationId).maybeSingle(),
    // Stop timezone/timezone_source (0061) -- separate, degradable query,
    // same reasoning as geofence/route-intel's own splits: a not-yet-
    // applied migration must never take the Pickup/Delivery sections down
    // with it.
    supabase.from("load_stops").select("id, timezone, timezone_source").eq("load_id", d.load_id),
  ]);

  // The load itself is required -- everything below it (stops, detention
  // settings, activity, documents) is optional/supplementary and must
  // never take the whole drawer down with it (spec section 5), so only
  // this one is a hard failure. All four are still logged, though, so a
  // real schema/query problem in any of them is visible in server logs
  // instead of silently degrading to an empty section forever.
  if (loadError) console.error(`[dispatch drawer] load query failed for dispatch ${dispatchId}:`, loadError);
  if (stopsError) console.error(`[dispatch drawer] load_stops query failed for dispatch ${dispatchId}:`, stopsError);
  if (orgError) console.error(`[dispatch drawer] organization detention settings query failed for org ${organizationId}:`, orgError);
  if (activityError) console.error(`[dispatch drawer] activity_logs query failed for dispatch ${dispatchId}:`, activityError);
  if (locationError) console.warn(`[dispatch drawer] driver_latest_locations query failed for dispatch ${dispatchId}:`, locationError);
  if (orgTzError) console.warn(`[dispatch drawer] organization timezone query failed for org ${organizationId}:`, orgTzError);
  if (stopTzError) console.warn(`[dispatch drawer] stop timezone query failed for dispatch ${dispatchId} (likely migration 0061 not applied yet):`, stopTzError);

  const loadRow = load as unknown as {
    id: string;
    load_number: string;
    commodity: string | null;
    weight_lbs: number | null;
    equipment_type: string | null;
    total_miles: number | null;
    special_instructions: string | null;
    brokers: { company_name: string } | null;
    customers: { company_name: string } | null;
  } | null;
  if (!loadRow) return { error: loadError ? "Unable to load dispatch details." : "Load not found." };

  const stopRows = (stops ?? []) as {
    id: string;
    stop_type: string;
    stop_sequence: number;
    facility_name: string | null;
    address_line1: string | null;
    city: string | null;
    state: string | null;
    scheduled_at: string | null;
    scheduled_window_end: string | null;
    reference_number: string | null;
    contact_name: string | null;
    contact_phone: string | null;
    arrived_at: string | null;
    departed_at: string | null;
  }[];
  const pickupStop = stopRows.filter((s) => s.stop_type === "pickup")[0] ?? null;
  const deliveryStop = stopRows.filter((s) => s.stop_type === "delivery").slice(-1)[0] ?? null;

  const pickupFreeMinutes = org?.pickup_detention_free_minutes ?? 120;
  const deliveryFreeMinutes = org?.delivery_detention_free_minutes ?? 120;

  const organizationTimezone = orgTz?.timezone ?? null;
  const stopTimezoneById = new Map((stopTimezones ?? []).map((row) => [row.id, row.timezone as string | null]));

  // Phase 2B geofence data (0059_gps_geofence_detention.sql) -- entirely
  // separate, degradable queries, same reasoning as the 0057/0058 splits
  // above: a not-yet-applied migration must never take the whole drawer
  // (or even the Pickup/Delivery sections above this) down with it.
  const stopIdsForGeofence = [pickupStop?.id, deliveryStop?.id].filter((v): v is string => !!v);
  let geofenceAutomationMode: DispatchDrawerData["geofence"]["automationMode"] = "off";
  const coordsByStopId = new Map<string, boolean>();
  const geofenceByStopId = new Map<
    string,
    { state: string; last_distance_m: number | null; last_accuracy_m: number | null; last_location_at: string | null; confirmed_inside_at: string | null; status_applied_at: string | null }
  >();
  let pickupRadiusM = 300;
  let deliveryRadiusM = 300;

  const [{ data: geoOrg, error: geoOrgError }, { data: stopCoords, error: stopCoordsError }, { data: geofenceRows, error: geofenceRowsError }] = await Promise.all([
    supabase.from("organizations").select("pickup_geofence_radius_m, delivery_geofence_radius_m, gps_automation_mode").eq("id", organizationId).maybeSingle(),
    stopIdsForGeofence.length > 0 ? supabase.from("load_stops").select("id, latitude, longitude").in("id", stopIdsForGeofence) : Promise.resolve({ data: [], error: null }),
    stopIdsForGeofence.length > 0
      ? supabase
          .from("dispatch_geofence_state")
          .select("load_stop_id, state, last_distance_m, last_accuracy_m, last_location_at, confirmed_inside_at, status_applied_at")
          .eq("dispatch_id", dispatchId)
          .in("load_stop_id", stopIdsForGeofence)
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (geoOrgError) console.warn(`[dispatch drawer] geofence org settings unavailable for dispatch ${dispatchId} (likely migration 0059 not applied yet):`, geoOrgError);
  if (stopCoordsError) console.warn(`[dispatch drawer] stop coordinates unavailable for dispatch ${dispatchId}:`, stopCoordsError);
  if (geofenceRowsError) console.warn(`[dispatch drawer] geofence state unavailable for dispatch ${dispatchId}:`, geofenceRowsError);

  if (geoOrg) {
    geofenceAutomationMode = (geoOrg.gps_automation_mode ?? "off") as DispatchDrawerData["geofence"]["automationMode"];
    pickupRadiusM = geoOrg.pickup_geofence_radius_m ?? 300;
    deliveryRadiusM = geoOrg.delivery_geofence_radius_m ?? 300;
  }
  for (const row of (stopCoords ?? []) as { id: string; latitude: number | null; longitude: number | null }[]) {
    coordsByStopId.set(row.id, row.latitude != null && row.longitude != null);
  }
  type GeofenceRow = { load_stop_id: string; state: string; last_distance_m: number | null; last_accuracy_m: number | null; last_location_at: string | null; confirmed_inside_at: string | null; status_applied_at: string | null };
  for (const row of (geofenceRows ?? []) as GeofenceRow[]) {
    geofenceByStopId.set(row.load_stop_id, row);
  }

  const toGeofenceInfo = (stop: typeof pickupStop, radiusM: number): StopGeofenceInfo | null => {
    if (!stop) return null;
    const hasCoordinates = coordsByStopId.get(stop.id) ?? false;
    const g = geofenceByStopId.get(stop.id);
    return {
      hasCoordinates,
      state: (g?.state as StopGeofenceInfo["state"]) ?? null,
      distanceM: g?.last_distance_m ?? null,
      accuracyM: g?.last_accuracy_m ?? null,
      radiusM,
      lastUpdateAt: g?.last_location_at ?? null,
      arrivalConfirmedAt: g?.confirmed_inside_at ?? null,
      statusApplied: !!g?.status_applied_at,
    };
  };

  const toStopDetail = (stop: typeof pickupStop, freeMinutes: number): StopDetail | null => {
    if (!stop) return null;
    const resolved = resolveStopTimezone(stopTimezoneById.get(stop.id) ?? null, organizationTimezone);
    return {
      id: stop.id,
      companyName: stop.facility_name,
      addressLine1: stop.address_line1,
      city: stop.city,
      state: stop.state,
      scheduledAt: stop.scheduled_at,
      scheduledWindowEnd: stop.scheduled_window_end,
      referenceNumber: stop.reference_number,
      contactName: stop.contact_name,
      contactPhone: stop.contact_phone,
      arrivedAt: stop.arrived_at,
      departedAt: stop.departed_at,
      detention: calculateDetention(stop.arrived_at, stop.departed_at, freeMinutes),
      hasCoordinates: coordsByStopId.get(stop.id) ?? false,
      timezone: resolved.timezone,
      timezoneIsFallback: resolved.isFallback,
    };
  };

  const activity: DrawerActivity[] = ((activityRows ?? []) as unknown as { id: string; action: string; changes: unknown; created_at: string; profiles: { full_name: string } | null }[]).map((a) => ({
    id: a.id,
    action: a.action,
    changes: a.changes,
    actorName: a.profiles?.full_name ?? null,
    createdAt: a.created_at,
  }));

  // Staff drawer always shows real availability -- documents.visibility
  // (0057) governs what a driver/carrier-facing surface may return, not
  // what an authenticated staff user sees here.
  const documents: DrawerDocument[] = DOC_TYPES.map((dt, i) => ({
    type: dt.type,
    label: dt.label,
    doc: docs[i] as DocumentRow | null,
  }));

  const grossRevenue = Number(d.load_rate);
  const carrierCost = Number(d.carrier_net_amount);
  const estimatedProfit = grossRevenue - carrierCost;

  // Phase 2C (0060_route_intelligence.sql) -- degradable, same pattern as
  // geofence/detention above: a not-yet-applied migration means this
  // section is simply null, never a broken drawer. The most recently
  // updated row for this dispatch is always the current operational
  // target's row (older rows, from stops already completed, stop being
  // touched -- see evaluate-route.ts).
  let routeIntelligence: RouteIntelligenceInfo | null = null;
  const { data: routeRow, error: routeError } = await supabase
    .from("dispatch_route_intelligence")
    .select(
      "target_stop_id, route_distance_meters, route_duration_seconds, route_geometry, initial_distance_meters, estimated_arrival_at, appointment_at, appointment_window_end, schedule_variance_minutes, risk_status, confidence, calculation_status, provider, calculated_at"
    )
    .eq("dispatch_id", dispatchId)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (routeError) {
    console.warn(`[dispatch drawer] route intelligence unavailable for dispatch ${dispatchId} (likely migration 0060 not applied yet):`, routeError);
  } else if (routeRow) {
    const { data: targetStopRow } = await supabase.from("load_stops").select("facility_name, city, state, timezone").eq("id", routeRow.target_stop_id).maybeSingle();
    const progress =
      routeRow.route_distance_meters != null && routeRow.initial_distance_meters != null && routeRow.initial_distance_meters > 0
        ? Math.max(0, Math.min(1, 1 - routeRow.route_distance_meters / routeRow.initial_distance_meters))
        : null;
    routeIntelligence = {
      targetStopLabel: targetStopRow ? targetStopRow.facility_name || [targetStopRow.city, targetStopRow.state].filter(Boolean).join(", ") || null : null,
      targetStopTimezone: resolveStopTimezone(targetStopRow?.timezone ?? null, organizationTimezone).timezone,
      routeDistanceMeters: routeRow.route_distance_meters,
      routeDurationSeconds: routeRow.route_duration_seconds,
      routeGeometry: (routeRow.route_geometry as [number, number][] | null) ?? null,
      progress,
      estimatedArrivalAt: routeRow.estimated_arrival_at,
      appointmentAt: routeRow.appointment_at,
      appointmentWindowEnd: routeRow.appointment_window_end,
      scheduleVarianceMinutes: routeRow.schedule_variance_minutes,
      riskStatus: routeRow.risk_status,
      confidence: routeRow.confidence,
      calculationStatus: routeRow.calculation_status,
      provider: routeRow.provider,
      calculatedAt: routeRow.calculated_at,
    };
  }

  return {
    dispatch: {
      id: d.id,
      status: d.status,
      dispatchedAt: d.dispatched_at,
      notes: d.notes,
      enRoutePickupAt: d.en_route_pickup_at,
      loadedAt: d.loaded_at,
      inTransitAt: d.in_transit_at,
      deliveredAt: d.delivered_at,
      cancelledAt: d.cancelled_at,
    },
    load: {
      id: loadRow.id,
      loadNumber: loadRow.load_number,
      commodity: loadRow.commodity,
      weightLbs: loadRow.weight_lbs,
      equipmentType: loadRow.equipment_type,
      totalMiles: loadRow.total_miles,
      specialInstructions: loadRow.special_instructions,
      brokerName: loadRow.brokers?.company_name ?? null,
      customerName: loadRow.customers?.company_name ?? null,
    },
    financials: canSeeFinancials
      ? {
          loadRate: grossRevenue,
          carrierCost,
          dispatchFeePercentage: Number(d.dispatch_fee_percentage),
          dispatchFeeAmount: Number(d.dispatch_fee_amount),
          carrierNetAmount: carrierCost,
          estimatedProfit,
        }
      : null,
    driver: d.drivers ? { id: dispatch.driver_id, name: `${d.drivers.first_name} ${d.drivers.last_name}`, phone: d.drivers.phone, status: d.drivers.status } : null,
    carrier: { id: dispatch.carrier_id, name: d.carriers?.legal_name ?? "--" },
    truck: d.trucks ? { unitNumber: d.trucks.unit_number, make: d.trucks.make, model: d.trucks.model, year: d.trucks.year } : null,
    trailer: d.trailers ? { unitNumber: d.trailers.unit_number } : null,
    pickup: toStopDetail(pickupStop, pickupFreeMinutes),
    delivery: toStopDetail(deliveryStop, deliveryFreeMinutes),
    geofence: {
      automationMode: geofenceAutomationMode,
      pickup: toGeofenceInfo(pickupStop, pickupRadiusM),
      delivery: toGeofenceInfo(deliveryStop, deliveryRadiusM),
    },
    tracking: buildTrackingInfo(latestLocation, dispatchId),
    routeIntelligence,
    documents,
    activity,
  };
}

// ---------------------------------------------------------------------------
// addDispatchQuickNote -- the drawer's "Add Note" quick action. Appends,
// never overwrites, exactly like cancelDispatch()'s own note-append
// convention in dispatch/actions.ts, so the two can never disagree about
// how a dispatch's notes accumulate. Logged to the same activity trail as
// every other dispatch action.
// ---------------------------------------------------------------------------
export async function addDispatchQuickNote(dispatchId: string, note: string): Promise<BoardStatusResult> {
  const trimmed = note.trim();
  if (!trimmed) return { ok: false, error: "Note cannot be empty." };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, error: "No organization on this account." };
  }

  const { data: dispatch } = await supabase.from("dispatches").select("id, notes").eq("id", dispatchId).eq("organization_id", organizationId).maybeSingle();
  if (!dispatch) return { ok: false, error: "Dispatch not found." };

  const { data: profile } = await supabase.from("profiles").select("full_name").eq("id", user.id).maybeSingle();
  const stamp = `[${new Date().toLocaleString()}${profile?.full_name ? ` -- ${profile.full_name}` : ""}] ${trimmed}`;
  const newNotes = dispatch.notes ? `${dispatch.notes}\n${stamp}` : stamp;

  const { error } = await supabase.from("dispatches").update({ notes: newNotes }).eq("id", dispatchId);
  if (error) {
    console.error("[dispatch board] add note failed:", error);
    return { ok: false, error: "Unable to save note. Please try again." };
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "dispatch",
    p_entity_id: dispatchId,
    p_action: "note_added",
    p_changes: { field: "notes", new_value: trimmed },
    p_organization_id: organizationId,
  });

  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${dispatchId}`);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// setStopCoordinates -- manual coordinate entry (spec section 3/4: "support
// manually entered coordinates", "do not silently fabricate coordinates
// from city/state only"). Most existing loads were entered before this
// migration and have no lat/lon at all; this is how a dispatcher turns
// geofence automation on for a specific stop without waiting on a
// geocoding integration this phase deliberately doesn't add. Org-scoped
// via the same dispatchId ownership check every other drawer action uses.
// ---------------------------------------------------------------------------
export async function setStopCoordinates(dispatchId: string, stopId: string, latitude: number, longitude: number): Promise<BoardStatusResult> {
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90) return { ok: false, error: "Latitude must be between -90 and 90." };
  if (!Number.isFinite(longitude) || longitude < -180 || longitude > 180) return { ok: false, error: "Longitude must be between -180 and 180." };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false, error: "No organization on this account." };
  }

  // The stop must belong to THIS dispatch's load, in THIS caller's org --
  // never trust a stopId the client sent on its own.
  const { data: dispatch } = await supabase.from("dispatches").select("id, load_id").eq("id", dispatchId).eq("organization_id", organizationId).maybeSingle();
  if (!dispatch) return { ok: false, error: "Dispatch not found." };

  const { data: stop } = await supabase.from("load_stops").select("id").eq("id", stopId).eq("load_id", dispatch.load_id).maybeSingle();
  if (!stop) return { ok: false, error: "Stop not found on this load." };

  const { error } = await supabase
    .from("load_stops")
    .update({ latitude, longitude, geocoded_at: new Date().toISOString(), geocode_source: "manual" })
    .eq("id", stopId);
  if (error) {
    console.error("[dispatch drawer] setStopCoordinates failed:", error);
    return { ok: false, error: "Could not save coordinates. Please try again." };
  }

  revalidatePath(`/dispatch/${dispatchId}`);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Stop appointment editing (Phase 2C.1, spec sections 13/20/21). Two
// distinct actions, deliberately never conflated:
//
//   setStopAppointment() -- "reinterpret" (mode B): the dispatcher is
//   changing the actual appointment date/time/timezone. Recomputes the
//   stored UTC instant from scratch via the same DST-aware conversion
//   used at load creation.
//
//   setStopTimezone() -- "set display timezone only" (mode A): for a
//   legacy stop with timezone IS NULL. Attaches timezone metadata WITHOUT
//   touching scheduled_at/scheduled_window_end at all -- the historical
//   instant is never silently reinterpreted just because someone finally
//   labeled what zone it's shown in.
//
// Both are org-scoped exactly like setStopCoordinates above, and both
// write a human-readable activity_logs entry (spec section 31) rather
// than a raw UTC diff.
// ---------------------------------------------------------------------------

async function requireStopOwnership(dispatchId: string, stopId: string) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { ok: false as const, error: "No organization on this account." };
  }

  const { data: dispatch } = await supabase.from("dispatches").select("id, load_id").eq("id", dispatchId).eq("organization_id", organizationId).maybeSingle();
  if (!dispatch) return { ok: false as const, error: "Dispatch not found." };

  const { data: stop } = await supabase
    .from("load_stops")
    .select("id, stop_type, scheduled_at, scheduled_window_end, timezone")
    .eq("id", stopId)
    .eq("load_id", dispatch.load_id)
    .maybeSingle();
  if (!stop) return { ok: false as const, error: "Stop not found on this load." };

  return { ok: true as const, supabase, organizationId, stop };
}

export async function setStopAppointment(
  dispatchId: string,
  stopId: string,
  input: { date: string; time: string; windowEndTime: string | null; timezone: string }
): Promise<BoardStatusResult> {
  const owned = await requireStopOwnership(dispatchId, stopId);
  if (!owned.ok) return owned;
  const { supabase, organizationId, stop } = owned;

  if (!isValidIanaTimezone(input.timezone)) return { ok: false, error: "Please select a valid timezone for this stop." };

  const scheduledResult = zonedDateTimeToUtc(input.date, input.time, input.timezone);
  if (!scheduledResult.ok) return { ok: false, error: scheduledResult.error };

  let windowEndIso: string | null = null;
  if (input.windowEndTime) {
    const windowResult = zonedDateTimeToUtc(input.date, input.windowEndTime, input.timezone);
    if (!windowResult.ok) return { ok: false, error: windowResult.error };
    windowEndIso = windowResult.iso;
  }
  const orderCheck = validateWindowOrder(scheduledResult.iso, windowEndIso);
  if (!orderCheck.ok) return orderCheck;

  const { error } = await supabase
    .from("load_stops")
    .update({ scheduled_at: scheduledResult.iso, scheduled_window_end: windowEndIso, timezone: input.timezone, timezone_source: "manual" })
    .eq("id", stopId);
  if (error) {
    console.error("[dispatch drawer] setStopAppointment failed:", error);
    return { ok: false, error: "Could not save the appointment. Please try again." };
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "dispatch",
    p_entity_id: dispatchId,
    p_action: "stop_appointment_changed",
    p_changes: {
      stop_type: stop.stop_type,
      from: formatStopDateTime(stop.scheduled_at, stop.timezone),
      to: formatStopDateTime(scheduledResult.iso, input.timezone),
      ambiguous_dst: scheduledResult.ambiguous || undefined,
    },
    p_organization_id: organizationId,
  });

  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${dispatchId}`);
  return { ok: true };
}

export async function setStopTimezone(dispatchId: string, stopId: string, timezone: string): Promise<BoardStatusResult> {
  const owned = await requireStopOwnership(dispatchId, stopId);
  if (!owned.ok) return owned;
  const { supabase, organizationId, stop } = owned;

  if (!isValidIanaTimezone(timezone)) return { ok: false, error: "Please select a valid timezone for this stop." };

  // Mode A: metadata only. scheduled_at/scheduled_window_end are
  // deliberately absent from this update -- the historical instant this
  // stop was actually entered with is preserved exactly, spec section 19/
  // 21's explicit requirement.
  const { error } = await supabase.from("load_stops").update({ timezone, timezone_source: "legacy" }).eq("id", stopId);
  if (error) {
    console.error("[dispatch drawer] setStopTimezone failed:", error);
    return { ok: false, error: "Could not save the timezone. Please try again." };
  }

  await supabase.rpc("log_activity", {
    p_entity_type: "dispatch",
    p_entity_id: dispatchId,
    p_action: "stop_timezone_set",
    p_changes: { stop_type: stop.stop_type, timezone, note: "Display timezone only -- the stored appointment instant was not changed." },
    p_organization_id: organizationId,
  });

  revalidatePath("/dispatch/board");
  revalidatePath(`/dispatch/${dispatchId}`);
  return { ok: true };
}
