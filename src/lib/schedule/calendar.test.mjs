// Schedule calendar: weeks run Monday-Sunday, each appointment lands on the
// right day and gets an honest status, maintenance/compliance show due or
// overdue, and the page is reachable from the menus.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { visibleDays, shiftDay, validDay, stopStatus, dueStatus, dayKey, groupByDay } from "./calendar.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("week = Monday..Sunday containing the day; prev/next move a week or a day", () => {
  assert.deepEqual(visibleDays("2026-10-04", "week"), ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"]);
  assert.deepEqual(visibleDays("2026-10-05", "week")[0], "2026-10-05");
  assert.deepEqual(visibleDays("2026-10-07", "day"), ["2026-10-07"]);
  assert.equal(shiftDay("2026-10-04", "week", 1), "2026-10-11");
  assert.equal(shiftDay("2026-03-01", "day", -1), "2026-02-28");
  assert.equal(validDay("nonsense", "2026-10-04"), "2026-10-04");
  assert.equal(validDay("2026-10-09", "x"), "2026-10-09");
});

test("day follows the time zone (a late-evening Pacific appointment is still that day)", () => {
  assert.equal(dayKey("2026-10-06T05:30:00Z", "America/Los_Angeles"), "2026-10-05");
  assert.equal(dayKey("2026-10-06T05:30:00Z", "America/Chicago"), "2026-10-06");
});

test("appointment status: done > on site > projected late/at risk > missed > not dispatched > on time > scheduled", () => {
  const now = Date.parse("2026-10-04T18:00:00Z");
  const base = { scheduledAt: "2026-10-05T14:00:00Z", windowEnd: null, arrivedAt: null, departedAt: null, dispatched: true, routeRisk: null, dateOnly: false, now, timeZone: "America/Chicago" };
  assert.equal(stopStatus({ ...base, departedAt: "x", arrivedAt: "x" }), "done");
  assert.equal(stopStatus({ ...base, arrivedAt: "x" }), "on_site");
  assert.equal(stopStatus({ ...base, routeRisk: "late" }), "late");
  assert.equal(stopStatus({ ...base, routeRisk: "at_risk" }), "at_risk");
  assert.equal(stopStatus({ ...base, scheduledAt: "2026-10-04T15:00:00Z" }), "late", "time passed with no arrival");
  assert.equal(stopStatus({ ...base, scheduledAt: "2026-10-04T15:00:00Z", windowEnd: "2026-10-04T20:00:00Z" }), "scheduled", "still inside the window");
  assert.equal(stopStatus({ ...base, dispatched: false }), "not_dispatched");
  assert.equal(stopStatus({ ...base, routeRisk: "on_time" }), "on_time");
  assert.equal(stopStatus(base), "scheduled");
  // date-only: late only once that whole day is over
  assert.equal(stopStatus({ ...base, dateOnly: true, scheduledAt: "2026-10-04T05:00:00Z" }), "scheduled");
  assert.equal(stopStatus({ ...base, dateOnly: true, scheduledAt: "2026-10-03T05:00:00Z" }), "late");
});

test("maintenance / compliance: due, overdue once passed; all-day items first, then by time", () => {
  assert.equal(dueStatus("2026-10-03", "2026-10-04"), "overdue");
  assert.equal(dueStatus("2026-10-04", "2026-10-04"), "due");
  const it = (id, day, at, allDay) => ({ id, kind: "pickup", day, at, allDay, timeLabel: "", title: id, subtitle: "", href: "", status: "scheduled" });
  const g = groupByDay([it("b", "2026-10-04", "2026-10-04T15:00:00Z", false), it("a", "2026-10-04", "2026-10-04T13:00:00Z", false), it("z", "2026-10-04", null, true), it("x", "2026-11-01", null, true)], ["2026-10-04"]);
  assert.deepEqual(g.get("2026-10-04").map((i) => i.id), ["z", "a", "b"]);
  assert.equal(g.size, 1, "items outside the visible days are dropped");
});

test("page wiring: stops (no cancelled loads), maintenance, compliance; in the menus", () => {
  const page = src("../../app/(app)/schedule/page.tsx");
  assert.match(page, /\.neq\("loads\.status", "cancelled"\)/);
  assert.match(page, /from\("maintenance_records"\)[\s\S]*\.neq\("status", "cancelled"\)/);
  assert.match(page, /from\("compliance_items"\)[\s\S]*\.is\("resolved_at", null\)/);
  assert.match(src("../../components/nav/nav-config.ts"), /\{ label: "Schedule", href: "\/schedule", icon: CalendarDays \}/);
  assert.match(src("../../components/desktop/menu-bar.tsx"), /\{ label: "Schedule", href: "\/schedule" \}/);
});
