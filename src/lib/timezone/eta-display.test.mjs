// The Tracking box never hides the day, never prints minutes as "m", and
// says when an appointment has no time instead of showing 12:00 AM.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { formatStopDayTime, formatAppointment, isMidnightLocal } from "./format.ts";
import { formatDurationMinutes, formatLateLabel, formatMarginLabel } from "../routing/risk.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const DEN = "America/Denver";
const now = "2026-10-04T04:20:00Z"; // Sat Oct 3, 10:20 PM in Denver

test("late / spare time in days, hours and minutes", () => {
  assert.equal(formatDurationMinutes(45), "45 min");
  assert.equal(formatDurationMinutes(60), "1 h");
  assert.equal(formatDurationMinutes(312), "5 h 12 min");
  assert.equal(formatDurationMinutes(2656), "1 day 20 h");
  assert.equal(formatDurationMinutes(2 * 1440), "2 days");
  assert.equal(formatLateLabel(-2656), "by 1 day 20 h");
  assert.equal(formatLateLabel(10), "");
  assert.equal(formatMarginLabel(125), "2 h 5 min to spare");
});

test("ETA shows Today / Tomorrow / the date, in the stop's zone", () => {
  assert.equal(formatStopDayTime("2026-10-04T04:50:00Z", DEN, now), "Today, 10:50 PM MT");
  assert.equal(formatStopDayTime("2026-10-05T02:16:00Z", DEN, now), "Tomorrow, 8:16 PM MT");
  assert.equal(formatStopDayTime("2026-10-06T02:16:00Z", DEN, now), "Mon, Oct 5, 8:16 PM MT");
  assert.equal(formatStopDayTime(null, DEN, now), "--");
});

test("a date saved with no time says so; a window shows both ends", () => {
  const midnight = "2026-10-04T06:00:00Z"; // Oct 4 00:00 in Denver
  assert.ok(isMidnightLocal(midnight, DEN));
  assert.equal(formatAppointment(midnight, null, DEN, now), "Tomorrow (no time set)");
  assert.equal(formatAppointment("2026-10-04T15:00:00Z", "2026-10-04T17:00:00Z", DEN, now), "Tomorrow, 9:00 AM-11:00 AM MT");
  assert.equal(formatAppointment("2026-10-04T15:00:00Z", null, DEN, now), "Tomorrow, 9:00 AM MT");
  assert.equal(formatAppointment(null, null, DEN, now), "Not set");
});

test("every Tracking surface uses the new formats", () => {
  const drawer = src("../../components/dispatch/dispatch-drawer.tsx");
  assert.match(drawer, /<Row label="ETA" value=\{formatStopDayTime\(r\.estimatedArrivalAt, r\.targetStopTimezone\)\} \/>/);
  assert.match(drawer, /formatAppointment\(r\.appointmentAt, r\.appointmentWindowEnd, r\.targetStopTimezone\)/);
  assert.match(drawer, /t\.placeName \? `Near \$\{t\.placeName\}`/);
  assert.match(src("../../components/tracking/live-map.tsx"), /formatStopDayTime\(info\.estimatedArrivalAt/);
  assert.match(src("../../app/(app)/dispatch/board/kanban-board.tsx"), /ETA \$\{formatStopDayTime\(card\.eta_at/);
  assert.match(src("../../app/(app)/dispatch/board/page.tsx"), /LATE \$\{formatDurationMinutes\(/);
  assert.match(src("../routing/evaluate-route.ts"), /const etaLabel = formatStopDayTime\(/);
  assert.match(src("../../app/driver-portal/trip/page.tsx"), /appointmentLabel: formatAppointment\(/);
  assert.ok(!/m LATE`/.test(src("../../app/(app)/dispatch/board/page.tsx")));
});
