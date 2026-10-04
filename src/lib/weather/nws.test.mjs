// Weather alerts on routes (NWS): only driving hazards, each alert once,
// worst first, a handful of check points per truck, and wired into the
// dispatch panel, the map panel and the truck list without ever blocking.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parseNwsAlerts, mergeAlerts, routeCheckPoints, isDrivingHazard, alertLine, alertTone } from "./nws.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

// shape of a real api.weather.gov /alerts/active?point= answer (trimmed)
const nws = {
  type: "FeatureCollection",
  features: [
    { properties: { id: "urn:oid:1", event: "Winter Storm Warning", severity: "Severe", status: "Actual", messageType: "Alert", areaDesc: "Laramie County, WY; Albany County, WY", ends: "2026-10-05T12:00:00Z" } },
    { properties: { id: "urn:oid:2", event: "Special Weather Statement", severity: "Moderate", status: "Actual", messageType: "Alert", areaDesc: "Laramie County, WY" } },
    { properties: { id: "urn:oid:3", event: "Heat Advisory", severity: "Moderate", status: "Actual", areaDesc: "X" } },
    { properties: { id: "urn:oid:4", event: "High Wind Watch", severity: "Moderate", status: "Actual", areaDesc: "Albany County, WY", expires: "2026-10-05T06:00:00Z" } },
    { properties: { id: "urn:oid:5", event: "Tornado Warning", severity: "Extreme", status: "Test", areaDesc: "Y" } },
    { properties: { id: "urn:oid:6", event: "Flood Warning", severity: "Severe", status: "Actual", messageType: "Cancel", areaDesc: "Z" } },
  ],
};

test("keeps driving hazards only (no statements, heat, tests, cancels)", () => {
  const a = parseNwsAlerts(nws, "on route");
  assert.deepEqual(a.map((x) => x.event), ["Winter Storm Warning", "High Wind Watch"]);
  assert.equal(a[0].area, "Laramie County, WY");
  assert.equal(a[0].ends, "2026-10-05T12:00:00Z");
  assert.equal(a[1].ends, "2026-10-05T06:00:00Z", "falls back to expires");
  assert.ok(isDrivingHazard("Blizzard Warning") && isDrivingHazard("Dense Fog Advisory") && !isDrivingHazard("Air Quality Alert"));
  assert.deepEqual(parseNwsAlerts(null, "x"), []);
  assert.deepEqual(parseNwsAlerts({ title: "error" }, "x"), []);
});

test("each alert once (first place seen), worst first, warnings before watches", () => {
  const at = parseNwsAlerts(nws, "at the truck");
  const route = parseNwsAlerts(nws, "on route");
  const extreme = [{ id: "t", event: "Tornado Warning", severity: "Extreme", area: "A", where: "at delivery (Market)", ends: null }];
  const m = mergeAlerts([at, route, extreme]);
  assert.deepEqual(m.map((x) => [x.event, x.where]), [["Tornado Warning", "at delivery (Market)"], ["Winter Storm Warning", "at the truck"], ["High Wind Watch", "at the truck"]]);
  assert.equal(alertLine(m[1], "America/Denver"), "Winter Storm Warning -- at the truck, Laramie County, WY (until Mon 6:00 AM)");
  assert.equal(alertTone(m[2]), "warning");
  assert.equal(alertTone(m[1]), "danger");
});

test("a few spread-out check points per truck: truck, along the route, stops; close ones merged", () => {
  const route = Array.from({ length: 200 }, (_, i) => [-93.25 - i * 0.06, 45.05 - i * 0.02]); // MN -> west
  const pts = routeCheckPoints({ truck: { lat: 45.05, lon: -93.25 }, route, stops: [{ lat: 40.69, lon: -111.97, label: "pickup (4BS)" }] });
  assert.ok(pts.length <= 10 && pts.length >= 8);
  assert.equal(pts[0].where, "at the truck");
  assert.equal(pts.at(-1).where, "at pickup (4BS)");
  assert.ok(pts.some((p) => p.where === "on route"));
  const close = routeCheckPoints({ truck: { lat: 45.05, lon: -93.25 }, route: null, stops: [{ lat: 45.06, lon: -93.26, label: "pickup" }] });
  assert.equal(close.length, 1, "a stop next to the truck is checked once");
  assert.deepEqual(routeCheckPoints({ truck: null, route: null, stops: [] }), []);
});

test("wired: free NWS with a User-Agent, cached, time-capped; shown in three places", () => {
  const lib = src("./route-alerts.ts");
  assert.match(lib, /https:\/\/api\.weather\.gov\/alerts\/active/);
  assert.match(lib, /"User-Agent": UA/);
  assert.match(lib, /TTL_MS = 10 \* 60 \* 1000/);
  assert.match(lib, /process\.env\.WEATHER_ALERTS !== "off"/);
  assert.match(src("../../app/(app)/dispatch/board-actions.ts"), /Promise\.race\(\[weatherAlertsForDispatch\(supabase, dispatchId\), new Promise<WeatherAlert\[\]>\(\(r\) => setTimeout\(\(\) => r\(\[\]\), 4500\)\)\]\)/);
  assert.match(src("../../components/dispatch/dispatch-drawer.tsx"), /<WeatherAlerts alerts=\{data\.weatherAlerts\}/);
  assert.match(src("../../components/tracking/live-map.tsx"), /<WeatherAlerts alerts=\{info\.weatherAlerts\}/);
  assert.match(src("../../app/(app)/tracking/page.tsx"), /setTimeout\(\(\) => resolve\(new Map\(\)\), 5000\)/);
  assert.match(src("../../components/tracking/tracking-board.tsx"), /\{ key: "weather", label: "Weather" \}/);
});
