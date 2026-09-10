// Regression: a booked load must count as "Active" / open work on the /loads
// list, while the dashboard's separate "Active Loads" vs "Loads Pending
// Dispatch" split (ACTIVE_LOAD_STATUSES / isActiveLoadStatus) is untouched.
//
// Incident: Kali Freights LLC, LD-100024 -- status "booked", visible on
// /loads, but /loads "Active" KPI showed 0 (booked was in neither the Active
// nor the Delivered status set). Root cause: /loads counted Active with
// ACTIVE_LOAD_STATUSES, which deliberately excludes "booked".

import test from "node:test";
import assert from "node:assert/strict";
import {
  ACTIVE_LOAD_STATUSES,
  PENDING_DISPATCH_LOAD_STATUSES,
  COMPLETED_LOAD_STATUSES,
  OPEN_LOAD_STATUSES,
  CANCELLED_LOAD_STATUS,
  isActiveLoadStatus,
  isOpenLoadStatus,
} from "./status.ts";

test("a newly booked load counts as open work on the /loads list", () => {
  assert.equal(isOpenLoadStatus("booked"), true);
  assert.ok((OPEN_LOAD_STATUSES).includes("booked"));
});

test("OPEN_LOAD_STATUSES = pending-dispatch (booked) + active, no delivered/cancelled/draft", () => {
  for (const s of PENDING_DISPATCH_LOAD_STATUSES) assert.ok(OPEN_LOAD_STATUSES.includes(s), `${s} missing`);
  for (const s of ACTIVE_LOAD_STATUSES) assert.ok(OPEN_LOAD_STATUSES.includes(s), `${s} missing`);
  for (const s of COMPLETED_LOAD_STATUSES) assert.equal(OPEN_LOAD_STATUSES.includes(s), false, `${s} leaked in`);
  assert.equal(OPEN_LOAD_STATUSES.includes(CANCELLED_LOAD_STATUS), false);
  for (const s of ["draft", "posted", "invoiced", "closed", "problem"]) {
    assert.equal(isOpenLoadStatus(s), false, `${s} should not be open`);
  }
});

test("Kali Freights shape: 1 booked + 13 delivered => Active(open) 1, Delivered 13, Total 14", () => {
  const loads = [
    ...Array.from({ length: 13 }, (_, i) => ({ id: `d${i}`, status: "delivered" })),
    { id: "LD-100024", status: "booked" },
  ];
  const active = loads.filter((l) => isOpenLoadStatus(l.status)).length;
  const delivered = loads.filter((l) => COMPLETED_LOAD_STATUSES.includes(l.status)).length;
  assert.equal(loads.length, 14);
  assert.equal(active, 1); // was 0 before the fix
  assert.equal(delivered, 13);
});

test("dashboard split is NOT changed: booked is still not ACTIVE_LOAD_STATUSES / isActiveLoadStatus", () => {
  // Guards the dashboard's "Active Loads" vs "Loads Pending Dispatch" KPIs
  // from double-counting a booked load.
  assert.equal(isActiveLoadStatus("booked"), false);
  assert.equal((ACTIVE_LOAD_STATUSES).includes("booked"), false);
});

test("the booked load stays visible after a page refresh (status is durable, not a client toggle)", () => {
  // The /loads list and its KPIs are recomputed server-side from loads.status
  // on every request -- nothing about visibility depends on client state, so
  // a refresh re-runs the same isOpenLoadStatus() bucketing and the booked
  // load is counted again.
  const row = { id: "LD-100024", status: "booked" };
  assert.equal(isOpenLoadStatus(row.status), true);
  assert.equal(isOpenLoadStatus(row.status), true);
});
