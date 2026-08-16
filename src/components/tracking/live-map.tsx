"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import { Loader2, RefreshCw } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { getRouteIntelligenceForDispatch, refreshDispatchEta, type LiveTrackingRouteInfo } from "@/app/(app)/dispatch/route-actions";
import { formatMiles, formatLateLabel, formatMarginLabel } from "@/lib/routing/risk";
import { formatStopDateTime } from "@/lib/timezone/format";
import { cn } from "@/lib/utils";

export type DriverMarker = {
  driverId: string;
  driverName: string;
  latitude: number;
  longitude: number;
  recordedAt: string;
  accuracyMeters: number | null;
  speedKph: number | null;
  loadNumber: string | null;
  truckUnit: string | null;
  dispatchStatus: string | null;
  dispatchId: string | null;
};

export type DispatchStopCoords = {
  pickup: { latitude: number; longitude: number } | null;
  delivery: { latitude: number; longitude: number } | null;
};

// Approximates a circle as a 64-point polygon in [lon, lat] order (GeoJSON
// winding) -- no turf/geo library dependency for one shape. Meters-per-
// degree for longitude is latitude-corrected; for latitude it's constant.
function circlePolygon(lat: number, lon: number, radiusMeters: number, points = 64): [number, number][] {
  const coords: [number, number][] = [];
  const metersPerDegLat = 111320;
  const metersPerDegLon = 111320 * Math.cos((lat * Math.PI) / 180);
  for (let i = 0; i <= points; i++) {
    const angle = (i / points) * 2 * Math.PI;
    const dLat = (radiusMeters * Math.sin(angle)) / metersPerDegLat;
    const dLon = (radiusMeters * Math.cos(angle)) / metersPerDegLon;
    coords.push([lon + dLon, lat + dLat]);
  }
  return coords;
}

// Free OpenStreetMap raster tiles -- no API key or account required. Fine
// for a demo/moderate-traffic dispatch app; a production deployment at scale
// should move to a paid tile provider per OSM's usage policy.
const OSM_STYLE: maplibregl.StyleSpecification = {
  version: 8,
  sources: {
    osm: {
      type: "raster",
      tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
      tileSize: 256,
      attribution: "&copy; OpenStreetMap contributors",
    },
  },
  layers: [{ id: "osm", type: "raster", source: "osm" }],
};

// Matches STALE_LOCATION_MINUTES in board-actions.ts (Dispatch Drawer) --
// this was inherited as 15 from before Phase 2A's explicit 5-minute
// threshold and left inconsistent between the two surfaces until caught
// live during verification (a 10-minute-old ping showed "stale" in the
// drawer but still green/fresh on this map).
const STALE_MINUTES = 5;

function markerColor(marker: DriverMarker) {
  const ageMinutes = (Date.now() - new Date(marker.recordedAt).getTime()) / 60_000;
  if (ageMinutes > STALE_MINUTES) return "#94a3b8"; // stale ping
  return marker.dispatchStatus ? "#0ea472" : "#2f5be0";
}

const STATUS_LABEL: Record<string, string> = {
  assigned: "Assigned",
  accepted: "Assigned",
  en_route_to_pickup: "En Route to Pickup",
  at_pickup: "At Pickup",
  loaded: "Loaded",
  en_route_to_delivery: "In Transit",
  at_delivery: "At Delivery",
  delivered: "Delivered",
  completed: "Delivered",
  cancelled: "Cancelled",
};

function popupHtml(marker: DriverMarker) {
  const minutesAgo = Math.round((Date.now() - new Date(marker.recordedAt).getTime()) / 60_000);
  const agoLabel = minutesAgo <= 0 ? "just now" : minutesAgo < 60 ? `${minutesAgo}m ago` : `${Math.round(minutesAgo / 60)}h ago`;
  const speedLabel = marker.speedKph != null ? `${Math.round(marker.speedKph * 0.621371)} mph` : "--";
  const accuracyLabel = marker.accuracyMeters != null ? `${Math.round(marker.accuracyMeters)} m` : "--";
  const statusLabel = marker.dispatchStatus ? STATUS_LABEL[marker.dispatchStatus] ?? marker.dispatchStatus : null;

  return `
    <div style="font: 500 12px Inter, sans-serif; min-width: 170px;">
      <div style="font-weight:600; margin-bottom:2px;">${marker.driverName}</div>
      ${marker.truckUnit ? `<div>Truck ${marker.truckUnit}</div>` : ""}
      ${marker.loadNumber ? `<div style="margin-top:4px;font-weight:600;">${marker.loadNumber}</div>` : "<div style='margin-top:4px;'>No active dispatch</div>"}
      ${statusLabel ? `<div>${statusLabel}</div>` : ""}
      <div style="margin-top:4px;">Speed: ${speedLabel}</div>
      <div>Accuracy: ${accuracyLabel}</div>
      <div style="color:#94a3b8; margin-top:2px;">Last update: ${agoLabel}</div>
      ${
        marker.dispatchId
          ? `<a href="/dispatch/${marker.dispatchId}" style="display:inline-block;margin-top:6px;font-weight:600;color:#2f5be0;text-decoration:none;">Open Dispatch &rarr;</a>`
          : ""
      }
    </div>
  `;
}

export function LiveMap({
  initialMarkers,
  organizationId,
  initialDispatchStops = {},
  geofenceRadii = { pickup: 300, delivery: 300 },
}: {
  initialMarkers: DriverMarker[];
  organizationId: string;
  /** Pickup/delivery stop coordinates keyed by dispatchId, for the markers
   * that have an active dispatch with geofence-eligible stops. Circles are
   * drawn once per dispatchId and never recomputed on every ping (spec
   * section 21: don't display all historical pings, geometry is static). */
  initialDispatchStops?: Record<string, DispatchStopCoords>;
  geofenceRadii?: { pickup: number; delivery: number };
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const markersRef = useRef<Map<string, maplibregl.Marker>>(new Map());
  const dispatchStopsRef = useRef<Record<string, DispatchStopCoords>>(initialDispatchStops);
  const drawnGeofencesRef = useRef<Set<string>>(new Set());
  const markerDispatchIdRef = useRef<Map<string, string | null>>(new Map());

  // Selected-truck panel (spec section 19) + calculated route line (spec
  // section 20) -- one route line on the map at a time, for whichever
  // truck is currently selected, never full route-history playback.
  const [selectedDispatchId, setSelectedDispatchId] = useState<string | null>(null);
  const [selectedInfo, setSelectedInfo] = useState<LiveTrackingRouteInfo | null>(null);
  const [selectedLoading, setSelectedLoading] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const ROUTE_LINE_SOURCE_ID = "calculated-route-line";

  function drawRouteLine(geometry: [number, number][] | null) {
    const map = mapRef.current;
    if (!map || !map.isStyleLoaded()) return;
    if (!geometry || geometry.length < 2) {
      if (map.getLayer(`${ROUTE_LINE_SOURCE_ID}-line`)) map.removeLayer(`${ROUTE_LINE_SOURCE_ID}-line`);
      if (map.getSource(ROUTE_LINE_SOURCE_ID)) map.removeSource(ROUTE_LINE_SOURCE_ID);
      return;
    }
    const data = { type: "Feature" as const, properties: {}, geometry: { type: "LineString" as const, coordinates: geometry } };
    const source = map.getSource(ROUTE_LINE_SOURCE_ID) as maplibregl.GeoJSONSource | undefined;
    if (source) {
      source.setData(data);
    } else {
      map.addSource(ROUTE_LINE_SOURCE_ID, { type: "geojson", data });
      map.addLayer({
        id: `${ROUTE_LINE_SOURCE_ID}-line`,
        type: "line",
        source: ROUTE_LINE_SOURCE_ID,
        layout: { "line-cap": "round", "line-join": "round" },
        // Solid, distinct from the dashed geofence circles and from
        // driver marker dots -- this is the CALCULATED route, never raw
        // GPS breadcrumb history (spec section 20 -- no route playback).
        paint: { "line-color": "#7c3aed", "line-width": 4, "line-opacity": 0.85 },
      });
    }
  }

  async function onSelectDispatch(dispatchId: string) {
    setSelectedDispatchId(dispatchId);
    setSelectedLoading(true);
    const result = await getRouteIntelligenceForDispatch(dispatchId);
    setSelectedLoading(false);
    if ("error" in result) {
      setSelectedInfo(null);
      drawRouteLine(null);
      return;
    }
    setSelectedInfo(result);
    drawRouteLine(result.routeGeometry);
  }

  async function handleRefreshSelected() {
    if (!selectedDispatchId) return;
    setRefreshing(true);
    const result = await refreshDispatchEta(selectedDispatchId);
    setRefreshing(false);
    if (result.ok) await onSelectDispatch(selectedDispatchId);
  }

  // Spec section 21: pickup/delivery geofence circles + stop markers, only
  // when a stop actually has coordinates -- omitted gracefully otherwise.
  // Drawn once per dispatchId (never redrawn on every ping for the same
  // dispatch) using two GeoJSON fill+outline layers per stop.
  function drawGeofenceCircles(dispatchId: string) {
    const map = mapRef.current;
    if (!map || drawnGeofencesRef.current.has(dispatchId)) return;
    const stops = dispatchStopsRef.current[dispatchId];
    if (!stops) return;

    (["pickup", "delivery"] as const).forEach((kind) => {
      const stop = stops[kind];
      if (!stop) return;
      const sourceId = `geofence-${dispatchId}-${kind}`;
      if (map.getSource(sourceId)) return;
      const radius = geofenceRadii[kind];
      const polygon = circlePolygon(stop.latitude, stop.longitude, radius);
      map.addSource(sourceId, {
        type: "geojson",
        data: { type: "Feature", properties: {}, geometry: { type: "Polygon", coordinates: [polygon] } },
      });
      map.addLayer({
        id: `${sourceId}-fill`,
        type: "fill",
        source: sourceId,
        paint: { "fill-color": kind === "pickup" ? "#2f5be0" : "#0ea472", "fill-opacity": 0.08 },
      });
      map.addLayer({
        id: `${sourceId}-line`,
        type: "line",
        source: sourceId,
        paint: { "line-color": kind === "pickup" ? "#2f5be0" : "#0ea472", "line-width": 1.5, "line-dasharray": [2, 2] },
      });

      const stopMarkerEl = document.createElement("div");
      stopMarkerEl.style.width = "10px";
      stopMarkerEl.style.height = "10px";
      stopMarkerEl.style.borderRadius = "2px";
      stopMarkerEl.style.border = "2px solid white";
      stopMarkerEl.style.boxShadow = "0 1px 3px rgba(0,0,0,0.4)";
      stopMarkerEl.style.backgroundColor = kind === "pickup" ? "#2f5be0" : "#0ea472";
      new maplibregl.Marker({ element: stopMarkerEl })
        .setLngLat([stop.longitude, stop.latitude])
        .setPopup(new maplibregl.Popup({ offset: 10 }).setText(kind === "pickup" ? "Pickup" : "Delivery"))
        .addTo(map);
    });
    drawnGeofencesRef.current.add(dispatchId);
  }

  function upsertMarker(marker: DriverMarker) {
    const map = mapRef.current;
    if (!map) return;
    // Kept current on every update so the click handler (attached once,
    // below) always resolves the CURRENT dispatchId for this driver, even
    // after a realtime update swaps which dispatch they're on.
    markerDispatchIdRef.current.set(marker.driverId, marker.dispatchId);

    const existing = markersRef.current.get(marker.driverId);
    if (existing) {
      existing.setLngLat([marker.longitude, marker.latitude]);
      existing.getPopup()?.setHTML(popupHtml(marker));
      const el = existing.getElement();
      el.style.backgroundColor = markerColor(marker);
      return;
    }
    const el = document.createElement("div");
    el.style.width = "16px";
    el.style.height = "16px";
    el.style.borderRadius = "50%";
    el.style.border = "2px solid white";
    el.style.boxShadow = "0 1px 4px rgba(0,0,0,0.4)";
    el.style.backgroundColor = markerColor(marker);
    el.style.cursor = "pointer";
    // Selecting a truck (spec section 19) is separate from the popup --
    // the popup is a quick glance, the side panel is the full route-
    // intelligence detail. Reads from the ref, not the closed-over
    // `marker`, so it's never stale.
    el.addEventListener("click", () => {
      const dispatchId = markerDispatchIdRef.current.get(marker.driverId);
      if (dispatchId) onSelectDispatch(dispatchId);
    });

    const popup = new maplibregl.Popup({ offset: 12 }).setHTML(popupHtml(marker));
    const mapMarker = new maplibregl.Marker({ element: el })
      .setLngLat([marker.longitude, marker.latitude])
      .setPopup(popup)
      .addTo(map);
    markersRef.current.set(marker.driverId, mapMarker);
  }

  useEffect(() => {
    if (!containerRef.current || mapRef.current) return;

    const center: [number, number] =
      initialMarkers.length > 0
        ? [initialMarkers[0].longitude, initialMarkers[0].latitude]
        : [-98.5795, 39.8283]; // continental US fallback

    const map = new maplibregl.Map({
      container: containerRef.current,
      style: OSM_STYLE,
      center,
      zoom: initialMarkers.length > 0 ? 6 : 3.2,
      attributionControl: { compact: true },
    });
    map.addControl(new maplibregl.NavigationControl(), "top-right");
    mapRef.current = map;

    initialMarkers.forEach(upsertMarker);
    // Circles need the style loaded before addSource/addLayer -- markers
    // above don't (they're DOM overlays), so they draw immediately.
    map.on("load", () => {
      initialMarkers.forEach((m) => {
        if (m.dispatchId) drawGeofenceCircles(m.dispatchId);
      });
    });
    const markers = markersRef.current;

    return () => {
      map.remove();
      mapRef.current = null;
      markers.clear();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Subscribes to driver_latest_locations (0058_driver_phone_gps.sql)
  // rather than driver_locations INSERTs -- each driver's row is upserted
  // in place, so this needs both INSERT (first ping ever) and UPDATE
  // (every ping after) to keep markers current. RLS on that table already
  // scopes SELECT to org staff of the caller's own organization_id; the
  // filter here is an additional, explicit narrowing, not the only guard.
  //
  // driver_latest_locations has RLS enabled, so the Realtime server only
  // forwards a given change to a subscriber if THAT subscriber's own JWT
  // passes the row's RLS policy -- the channel/filter registration above
  // succeeds either way, but individual postgres_changes events are
  // silently withheld unless the realtime SOCKET itself carries a valid
  // access token (separate from the token normal REST/PostgREST calls
  // already use via cookies). createBrowserClient() doesn't wire this up
  // automatically for every timing case, so it's set explicitly here --
  // confirmed live: without this, the channel reaches "SUBSCRIBED" and
  // looks fully healthy, but zero events ever arrive.
  useEffect(() => {
    const supabase = createClient();
    let channel: ReturnType<typeof supabase.channel> | null = null;

    supabase.auth.getSession().then(({ data: { session } }) => {
      if (session) supabase.realtime.setAuth(session.access_token);

      channel = supabase
        .channel(`driver-latest-locations-${organizationId}`)
        .on(
          "postgres_changes",
          { event: "*", schema: "public", table: "driver_latest_locations", filter: `organization_id=eq.${organizationId}` },
          async (payload) => {
            const row = payload.new as {
              driver_id: string;
              latitude: number;
              longitude: number;
              recorded_at: string;
              accuracy_meters: number | null;
              speed_kph: number | null;
              dispatch_id: string | null;
            };
            if (!row?.driver_id) return;

            const { data: driver } = await supabase
              .from("drivers")
              .select("first_name, last_name")
              .eq("id", row.driver_id)
              .maybeSingle();

            let loadNumber: string | null = null;
            let truckUnit: string | null = null;
            let dispatchStatus: string | null = null;
            if (row.dispatch_id) {
              const { data: dispatch } = await supabase
                .from("dispatches")
                .select("status, load_id, loads(load_number), trucks(unit_number)")
                .eq("id", row.dispatch_id)
                .maybeSingle();
              const d = dispatch as unknown as {
                status: string;
                load_id: string;
                loads: { load_number: string } | null;
                trucks: { unit_number: string } | null;
              } | null;
              loadNumber = d?.loads?.load_number ?? null;
              truckUnit = d?.trucks?.unit_number ?? null;
              dispatchStatus = d?.status ?? null;

              // Geofence circles (spec section 21) -- fetched once per
              // dispatchId, not on every ping. A dispatch's stop
              // coordinates don't change mid-trip, so this is a one-time
              // lookup gated by drawnGeofencesRef, not a per-ping query.
              if (d?.load_id && !drawnGeofencesRef.current.has(row.dispatch_id) && !dispatchStopsRef.current[row.dispatch_id]) {
                const { data: stopRows } = await supabase
                  .from("load_stops")
                  .select("stop_type, stop_sequence, latitude, longitude")
                  .eq("load_id", d.load_id)
                  .order("stop_sequence");
                const rows = (stopRows ?? []) as { stop_type: string; latitude: number | null; longitude: number | null }[];
                const p = rows.filter((s) => s.stop_type === "pickup")[0] ?? null;
                const dl = rows.filter((s) => s.stop_type === "delivery").slice(-1)[0] ?? null;
                dispatchStopsRef.current[row.dispatch_id] = {
                  pickup: p?.latitude != null && p?.longitude != null ? { latitude: p.latitude, longitude: p.longitude } : null,
                  delivery: dl?.latitude != null && dl?.longitude != null ? { latitude: dl.latitude, longitude: dl.longitude } : null,
                };
              }
              if (row.dispatch_id) drawGeofenceCircles(row.dispatch_id);
            }

            upsertMarker({
              driverId: row.driver_id,
              driverName: driver ? `${driver.first_name} ${driver.last_name}` : "Driver",
              latitude: row.latitude,
              longitude: row.longitude,
              recordedAt: row.recorded_at,
              accuracyMeters: row.accuracy_meters,
              speedKph: row.speed_kph,
              loadNumber,
              truckUnit,
              dispatchStatus,
              dispatchId: row.dispatch_id,
            });
          }
        )
        .subscribe();
    });

    return () => {
      if (channel) supabase.removeChannel(channel);
    };
    // drawGeofenceCircles/upsertMarker intentionally omitted -- both read
    // from refs and are stable in effect across renders; including them
    // would resubscribe the realtime channel on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [organizationId]);

  return (
    <div className="relative">
      <div ref={containerRef} className="h-[560px] w-full rounded-2xl border border-border" />
      {selectedDispatchId && (
        <SelectedTruckPanel
          loading={selectedLoading}
          info={selectedInfo}
          dispatchId={selectedDispatchId}
          refreshing={refreshing}
          onRefresh={handleRefreshSelected}
          onClose={() => {
            setSelectedDispatchId(null);
            setSelectedInfo(null);
            drawRouteLine(null);
          }}
        />
      )}
    </div>
  );
}

const RISK_LABEL: Record<string, string> = { unknown: "ETA UNKNOWN", on_time: "ON TIME", at_risk: "AT RISK", late: "LATE", arrived: "ARRIVED" };
const RISK_TONE: Record<string, string> = {
  unknown: "border-desktop-border bg-desktop-muted/50 text-muted-foreground",
  on_time: "border-success/40 bg-success/10 text-success",
  at_risk: "border-warning/40 bg-warning/10 text-warning",
  late: "border-danger/40 bg-danger/10 text-danger",
  arrived: "border-success/40 bg-success/10 text-success",
};
const STATUS_LABEL_PANEL: Record<string, string> = {
  assigned: "Assigned",
  accepted: "Assigned",
  en_route_to_pickup: "En Route to Pickup",
  at_pickup: "At Pickup",
  loaded: "Loaded",
  en_route_to_delivery: "In Transit",
  at_delivery: "At Delivery",
  delivered: "Delivered",
  completed: "Delivered",
  cancelled: "Cancelled",
};

// Spec section 19's mockup panel. A dispatcher clicks a truck marker to
// open this -- separate from the marker's own quick-glance popup.
function SelectedTruckPanel({
  loading,
  info,
  dispatchId,
  refreshing,
  onRefresh,
  onClose,
}: {
  loading: boolean;
  info: LiveTrackingRouteInfo | null;
  dispatchId: string;
  refreshing: boolean;
  onRefresh: () => void;
  onClose: () => void;
}) {
  return (
    <div className="absolute right-3 top-3 z-10 w-72 rounded-xl border border-desktop-border bg-desktop-panel p-3 shadow-elevation-2">
      <div className="flex items-start justify-between">
        <p className="text-sm font-semibold">{loading ? "Loading..." : (info?.loadNumber ?? "--")}</p>
        <button type="button" onClick={onClose} className="text-muted-foreground hover:text-desktop-text" aria-label="Close">
          &times;
        </button>
      </div>
      {loading ? (
        <div className="flex items-center justify-center py-6">
          <Loader2 className="size-5 animate-spin text-muted-foreground" />
        </div>
      ) : !info ? (
        <p className="mt-2 text-xs text-muted-foreground">Could not load route intelligence for this truck.</p>
      ) : (
        <div className="mt-2 space-y-2 text-[12.5px]">
          <p className="text-muted-foreground">
            {info.driverName} &middot; Truck {info.truckUnit}
          </p>
          <p className="font-medium">{STATUS_LABEL_PANEL[info.status] ?? info.status}</p>

          {info.riskStatus === "arrived" ? (
            <div className="rounded-sm border border-success/40 bg-success/10 px-2 py-1.5 font-semibold text-success">ARRIVED</div>
          ) : info.calculationStatus === "no_coordinates" ? (
            <p className="text-muted-foreground">Route ETA unavailable -- stop coordinates missing.</p>
          ) : info.estimatedArrivalAt ? (
            <>
              <div className="border-t border-desktop-border pt-2">
                <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">Next Stop</p>
                <p className="font-medium">{info.targetStopLabel ?? "--"}</p>
              </div>
              <div className="grid grid-cols-2 gap-y-1">
                <span className="text-muted-foreground">Miles Remaining</span>
                <span className="text-right font-medium">{formatMiles(info.routeDistanceMeters)}</span>
                <span className="text-muted-foreground">ETA</span>
                <span className="text-right font-medium">{formatStopDateTime(info.estimatedArrivalAt, info.targetStopTimezone, { timeOnly: true })}</span>
                <span className="text-muted-foreground">Appointment</span>
                <span className="text-right font-medium">{info.appointmentAt ? formatStopDateTime(info.appointmentAt, info.targetStopTimezone, { timeOnly: true }) : "Not set"}</span>
              </div>
              <div className={cn("rounded-sm border px-2 py-1.5 font-semibold", RISK_TONE[info.riskStatus])}>
                {RISK_LABEL[info.riskStatus]}
                {info.riskStatus === "late" && ` -- ${formatLateLabel(info.scheduleVarianceMinutes)}`}
                {info.riskStatus === "on_time" && formatMarginLabel(info.scheduleVarianceMinutes) && ` -- ${formatMarginLabel(info.scheduleVarianceMinutes)}`}
              </div>
              <p className="text-[11px] text-muted-foreground">Route Updated {info.calculatedAt ? `${Math.round((Date.now() - new Date(info.calculatedAt).getTime()) / 60000)} min ago` : "--"}</p>
            </>
          ) : (
            <p className="text-muted-foreground">Route ETA unavailable.</p>
          )}

          <div className="flex gap-2 border-t border-desktop-border pt-2">
            <Link href={`/dispatch/${dispatchId}`} className="flex-1 rounded-sm border border-desktop-border px-2 py-1.5 text-center text-[12px] font-medium hover:bg-desktop-muted">
              Open Dispatch
            </Link>
            <button
              type="button"
              onClick={onRefresh}
              disabled={refreshing}
              className="flex flex-1 items-center justify-center gap-1 rounded-sm border border-desktop-border px-2 py-1.5 text-[12px] font-medium hover:bg-desktop-muted disabled:opacity-50"
            >
              <RefreshCw className={cn("size-3", refreshing && "animate-spin")} /> Refresh ETA
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
