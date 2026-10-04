// Live Tracking's truck list: worst first, filters and counts agree.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { sortFleet, matchesFilter, fleetCounts, isGpsQuiet, agoLabel, urgency } from "./fleet.ts";

const now = Date.parse("2026-10-04T06:00:00Z");
const ago = (m) => new Date(now - m * 60_000).toISOString();
const row = (o) => ({
  driverId: o.id, driverName: o.id, dispatchId: "dispatchId" in o ? o.dispatchId : `d-${o.id}`, loadNumber: null, truckUnit: null, dispatchStatus: "in_transit",
  recordedAt: ago(o.age ?? 1), speedMph: null, nextStop: null, milesLeftMeters: null, drivingSeconds: null, etaAt: o.eta ?? null,
  appointmentAt: null, appointmentWindowEnd: null, stopTimezone: "UTC", risk: o.risk ?? "on_time", varianceMinutes: o.var ?? null, calcStatus: o.calc ?? "ok",
});

const rows = [
  row({ id: "ontime", risk: "on_time", var: 120 }),
  row({ id: "idle", dispatchId: null, age: 600 }),
  row({ id: "late-small", risk: "late", var: -30 }),
  row({ id: "quiet", risk: "on_time", age: 60 }),
  row({ id: "late-big", risk: "late", var: -1860 }),
  row({ id: "atrisk", risk: "at_risk", var: 5 }),
  row({ id: "nocoords", risk: "unknown", calc: "no_coordinates" }),
];

test("worst first: most late, late, at risk, GPS quiet, no ETA, on time, no load", () => {
  assert.deepEqual(sortFleet(rows, now).map((r) => r.driverId), ["late-big", "late-small", "atrisk", "quiet", "nocoords", "ontime", "idle"]);
  assert.ok(urgency(rows[0], now) > urgency(rows[2], now));
});

test("filters and counts agree", () => {
  const c = fleetCounts(rows, now);
  assert.deepEqual(c, { onLoad: 6, late: 2, atRisk: 1, quiet: 1, idle: 1, reportingLive: 5 });
  assert.equal(rows.filter((r) => matchesFilter(r, "late", now)).length, c.late);
  assert.equal(rows.filter((r) => matchesFilter(r, "idle", now)).length, 1);
  assert.ok(isGpsQuiet(rows[3], now) && !isGpsQuiet(rows[1], now), "an idle truck is never 'GPS quiet'");
  assert.equal(agoLabel(ago(0.2), now), "just now");
  assert.equal(agoLabel(ago(12), now), "12 min ago");
  assert.equal(agoLabel(ago(180), now), "3 h ago");
});

test("page and board wiring", () => {
  const page = readFileSync(new URL("../../app/(app)/tracking/page.tsx", import.meta.url), "utf8");
  assert.match(page, /<TrackingBoard/);
  assert.match(page, /from\("dispatch_route_intelligence"\)/);
  const board = readFileSync(new URL("../../components/tracking/tracking-board.tsx", import.meta.url), "utf8");
  assert.match(board, /sendDispatchMessage\(dispatchId, REOPEN_APP_MESSAGE\)/);
  assert.match(board, /focus=\{focus\}/);
  assert.match(board, /setInterval\(\(\) => router\.refresh\(\), 60_000\)/);
  const map = readFileSync(new URL("../../components/tracking/live-map.tsx", import.meta.url), "utf8");
  assert.match(map, /map\.flyTo\(\{ center: marker\.getLngLat\(\)/);
  assert.match(map, /etaIncludesRest\(info\.routeDurationSeconds\)/);
});

test("one slim filter row replaces the big count cards and the duplicate chips", () => {
  const board = readFileSync(new URL("../../components/tracking/tracking-board.tsx", import.meta.url), "utf8");
  assert.equal((board.match(/role="tablist"/g) ?? []).length, 1, "one set of filters");
  assert.ok(!/text-2xl/.test(board), "no big number cards");
  assert.match(board, /\{counts\.reportingLive\} of \{rows\.length\} reporting live/);
});
