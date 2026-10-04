// Stops get their map point from their address, so ETA and automatic
// arrival work without typing coordinates. Street matches drive geofences;
// a city-center fallback drives only an approximate ETA.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { censusUrl, parseCensus, nominatimUrl, parseNominatim, NOMINATIM_DEFAULT } from "./geocode-providers.ts";
import { hasStopPoint, hasExactStopPoint, stopLabel, needsLookup, LOOKUP_RETRY_MS } from "./stop-point.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const addr = { address_line1: "123 Main St", city: "Minneapolis", state: "MN", postal_code: "55401", country: "US" };

test("Census: street address only, US only; reads x = longitude, y = latitude", () => {
  const url = censusUrl(addr);
  assert.ok(url.startsWith("https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?"));
  assert.equal(new URL(url).searchParams.get("address"), "123 Main St, Minneapolis, MN 55401");
  assert.equal(censusUrl({ ...addr, address_line1: null }), null, "no street, no Census lookup");
  assert.equal(censusUrl({ ...addr, country: "CA" }), null);
  assert.deepEqual(parseCensus({ result: { addressMatches: [{ coordinates: { x: -93.2650, y: 44.9778 } }] } }), { latitude: 44.9778, longitude: -93.265 });
  assert.equal(parseCensus({ result: { addressMatches: [] } }), null);
  assert.equal(parseCensus(null), null);
  assert.equal(parseCensus({ result: { addressMatches: [{ coordinates: { x: 0, y: 0 } }] } }), null);
});

test("OpenStreetMap: a street match needs place_rank 26+; city fallback takes the city", () => {
  const street = new URL(nominatimUrl(NOMINATIM_DEFAULT, addr, true));
  assert.equal(street.searchParams.get("street"), "123 Main St");
  assert.equal(street.searchParams.get("countrycodes"), "us");
  const city = new URL(nominatimUrl(NOMINATIM_DEFAULT, { ...addr, address_line1: null }, false));
  assert.equal(city.searchParams.get("street"), null);
  assert.equal(city.searchParams.get("city"), "Minneapolis");
  assert.equal(nominatimUrl(NOMINATIM_DEFAULT, { ...addr, address_line1: null }, true), null);
  assert.equal(new URL(nominatimUrl(NOMINATIM_DEFAULT, { ...addr, country: "Canada" }, true)).searchParams.get("countrycodes"), "ca");
  assert.deepEqual(parseNominatim([{ lat: "44.97", lon: "-93.26", place_rank: 30 }], true), { latitude: 44.97, longitude: -93.26 });
  assert.equal(parseNominatim([{ lat: "44.97", lon: "-93.26", place_rank: 16 }], true), null, "a city is not the stop's exact spot");
  assert.deepEqual(parseNominatim([{ lat: "44.97", lon: "-93.26", place_rank: 16 }], false), { latitude: 44.97, longitude: -93.26 });
  assert.equal(parseNominatim([], false), null);
});

test("a city-center point feeds the ETA (labeled approximate), never a geofence", () => {
  const cc = { latitude: 44.97, longitude: -93.26, geocode_source: "city_center" };
  assert.ok(hasStopPoint(cc));
  assert.ok(!hasExactStopPoint(cc));
  assert.ok(hasExactStopPoint({ latitude: 1, longitude: 2, geocode_source: "census" }));
  assert.ok(hasExactStopPoint({ latitude: 1, longitude: 2, geocode_source: "manual" }));
  assert.equal(stopLabel({ facility_name: "Acme DC", city: "X", state: "MN", geocode_source: "city_center" }), "Acme DC (approx. -- city center)");
  assert.equal(stopLabel({ facility_name: null, city: "Fargo", state: "ND", geocode_source: "census" }), "Fargo, ND");
  const geofence = src("../tracking/geofence.ts");
  assert.match(geofence, /if \(stop\.geocode_source === "city_center"\) return null;/);
  assert.match(src("../tracking/evaluate-geofences.ts"), /latitude, longitude, geocode_source, arrived_at/);
});

test("lookups never overwrite a typed-in or found point, and failures aren't retried on every ping", () => {
  const now = Date.parse("2026-10-03T12:00:00Z");
  assert.equal(needsLookup({ latitude: 1, longitude: 2, geocode_source: "manual" }, now, true), false);
  assert.equal(needsLookup({ latitude: 1, longitude: 2, geocode_source: "census" }, now, true), false);
  assert.equal(needsLookup({ latitude: null, longitude: null, geocode_source: null }, now, false), true);
  const failedJustNow = { latitude: null, longitude: null, geocode_source: "lookup_failed", geocoded_at: new Date(now - 60_000).toISOString() };
  assert.equal(needsLookup(failedJustNow, now, false), false);
  assert.equal(needsLookup(failedJustNow, now, true), true, "Refresh ETA / Find on map retry right away");
  assert.equal(needsLookup({ ...failedJustNow, geocoded_at: new Date(now - LOOKUP_RETRY_MS).toISOString() }, now, false), true);
  assert.equal(needsLookup({ latitude: 1, longitude: 2, geocode_source: "city_center", address_line1: "1 Main" }, now, true), true, "upgrade city center when asked");
  assert.equal(needsLookup({ latitude: 1, longitude: 2, geocode_source: "city_center", address_line1: "1 Main" }, now, false), false);
  const lib = src("./stop-geocoding.ts");
  assert.match(lib, /upgrading \? w\.eq\("geocode_source", CITY_CENTER\) : w\.is\("latitude", null\)/, "guarded write");
  assert.match(lib, /"User-Agent": USER_AGENT/);
  assert.match(lib, /NOMINATIM_GAP_MS = 1100/);
});

test("wired in: new loads, GPS pings (in the background), Refresh ETA and Find on map", () => {
  assert.match(src("../../app/(app)/loads/create-actions.ts"), /after\(\(\) => lookup\)/);
  assert.match(src("../../app/api/driver-portal/location/route.ts"), /after\(\(\) => fillStopCoordinatesForDispatch\(dispatchId\)/);
  const refresh = src("../../app/(app)/dispatch/route-actions.ts");
  assert.match(refresh, /fillStopCoordinatesForDispatch\(dispatchId, \{ force: true \}\)/);
  assert.ok(refresh.indexOf("fillStopCoordinatesForDispatch(dispatchId") < refresh.indexOf("forceRefreshRouteIntelligence(dispatchId"), "look up before recalculating");
  const board = src("../../app/(app)/dispatch/board-actions.ts");
  assert.match(board, /export async function findStopCoordinates\(dispatchId: string, stopId: string\)/);
  assert.match(board, /\.eq\("id", stopId\)\.eq\("load_id", dispatch\.load_id\)/);
  assert.match(src("../../components/dispatch/dispatch-drawer.tsx"), /Find on map/);
});

test("the truck's GPS point shows as a town (city level, cached, short wait)", async () => {
  const { nominatimReverseUrl, parseNominatimReverse } = await import("./geocode-providers.ts");
  const u = new URL(nominatimReverseUrl("https://nominatim.openstreetmap.org", 45.05301, -93.24841));
  assert.equal(u.pathname, "/reverse");
  assert.equal(u.searchParams.get("zoom"), "10");
  assert.equal(u.searchParams.get("lat"), "45.0530");
  assert.equal(parseNominatimReverse({ address: { city: "Minneapolis", state: "Minnesota", "ISO3166-2-lvl4": "US-MN" } }), "Minneapolis, MN");
  assert.equal(parseNominatimReverse({ address: { town: "Fridley", state: "Minnesota" } }), "Fridley, Minnesota");
  assert.equal(parseNominatimReverse({ error: "Unable to geocode" }), null);
  const lib = src("./stop-geocoding.ts");
  assert.match(lib, /export async function nearPlace\(/);
  assert.match(lib, /PLACE_TTL_MS = 60 \* 60 \* 1000/);
  assert.match(lib, /, 2500\)\)/);
});

test("wrong addresses are flagged and fixable: Edit Address clears the old point and looks the new one up", async () => {
  const { addressProblem } = await import("./stop-point.ts");
  assert.equal(addressProblem("lookup_failed", "3500 Redwood Road"), "not_found");
  assert.equal(addressProblem("city_center", "3500 Redwood Road"), "city_only");
  assert.equal(addressProblem("city_center", null), null, "no street entered: city center is all there is");
  assert.equal(addressProblem("census", "x"), null);
  const board = src("../../app/(app)/dispatch/board-actions.ts");
  assert.match(board, /export async function updateStopAddress\(/);
  assert.match(board, /\.update\(\{ \.\.\.after, latitude: null, longitude: null, geocoded_at: null, geocode_source: null \}\)/);
  assert.match(board, /fillStopCoordinates\(String\(d\.load_id\), \{ force: true, stopIds: \[stopId\] \}\)/);
  assert.match(board, /p_action: "stop_address_updated"/);
  const drawer = src("../../components/dispatch/dispatch-drawer.tsx");
  assert.match(drawer, /<AddressEditor stop=\{stop\}/);
  assert.match(drawer, /Save Address/);
  assert.match(src("../../app/(app)/loads/[id]/page.tsx"), /data-testid="stop-address-problem"/);
  const create = src("../../app/(app)/loads/create-actions.ts");
  assert.match(create, /await Promise\.race\(\[lookup, new Promise\(\(resolve\) => setTimeout\(resolve, 6000\)\)\]\)/);
});
