// Regression coverage for the false "Assignment just changed" dispatch
// conflict (LD-100024 / Kali Freights LLC).
//
// Root cause: migration 0125 added loads.financial_dispatch_id ->
// dispatches.id, giving PostgREST TWO dispatches<->loads relationships, so
// the conflict lookup's `loads(load_number)` embed returned PGRST201 and
// the old code read the error as "no conflict". The pre-check then let a
// genuine clash through, the 0054 unique index rejected the INSERT, and the
// re-derivation hit the same broken embed -> generic CONCURRENT_UPDATE
// message even though driver Fuaad Ahmed + truck T-112 were plainly on the
// still-active dispatch for that same load.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  ACTIVE_DISPATCH_STATUSES,
  isActiveDispatchStatus,
  classifyAssignmentConflict,
  conflictMessage,
  CONFLICT_CODE,
  LOAD_ALREADY_DISPATCHED_CODE,
} from "./conflicts.ts";

const D = (over) => ({
  id: over.id ?? "d-existing",
  status: over.status ?? "assigned",
  load_id: over.load_id ?? "load-A",
  load_number: over.load_number ?? "LD-100024",
  driver_id: over.driver_id ?? null,
  truck_id: over.truck_id ?? null,
  trailer_id: over.trailer_id ?? null,
  driver_name: over.driver_name ?? null,
  truck_unit: over.truck_unit ?? null,
  trailer_unit: over.trailer_unit ?? null,
});

// (a) available driver + available truck succeeds
test("a) all resources free + load has no active dispatch -> no conflict", () => {
  const rows = [D({ id: "d1", load_id: "other", driver_id: "drv-9", truck_id: "trk-9" })];
  const c = classifyAssignmentConflict(rows, {
    loadId: "load-A", driverId: "drv-1", truckId: "trk-1", trailerId: null,
  });
  assert.equal(c, null);
});

// (b) busy driver -> names the driver and the conflicting load
test("b) busy driver -> resource_busy names driver + load", () => {
  const rows = [D({ id: "d-drv", load_id: "load-B", load_number: "LD-100077", driver_id: "drv-1", driver_name: "Fuaad Ahmed" })];
  const c = classifyAssignmentConflict(rows, { driverId: "drv-1", truckId: "trk-1", trailerId: null });
  assert.deepEqual(c, {
    kind: "resource_busy", resource: "driver", dispatchId: "d-drv",
    loadNumber: "LD-100077", resourceLabel: "Fuaad Ahmed",
  });
  assert.equal(conflictMessage(c), "Fuaad Ahmed is already assigned to active load LD-100077.");
  assert.equal(CONFLICT_CODE.driver, "DRIVER_ACTIVE_DISPATCH");
});

// (c) busy truck -> names the truck and the conflicting load
test("c) busy truck -> resource_busy names truck unit + load", () => {
  const rows = [D({ id: "d-trk", load_id: "load-C", load_number: "LD-100088", truck_id: "trk-1", truck_unit: "T-112" })];
  const c = classifyAssignmentConflict(rows, { driverId: "drv-1", truckId: "trk-1", trailerId: null });
  assert.equal(c.resource, "truck");
  assert.equal(c.dispatchId, "d-trk");
  assert.equal(conflictMessage(c), "Truck T-112 is already assigned to active load LD-100088.");
});

// (d) completed / cancelled dispatch does not block assignment
test("d) terminal dispatch (delivered/completed/cancelled) never blocks", () => {
  for (const status of ["delivered", "completed", "cancelled"]) {
    assert.equal(isActiveDispatchStatus(status), false, `${status} must not be active`);
    const rows = [D({ id: "d-old", status, load_id: "load-A", driver_id: "drv-1", truck_id: "trk-1" })];
    const c = classifyAssignmentConflict(rows, {
      loadId: "load-A", driverId: "drv-1", truckId: "trk-1", trailerId: null,
    });
    assert.equal(c, null, `${status} dispatch should not block`);
  }
});

// (e) duplicate load dispatch is prevented clearly
test("e) load already has an active dispatch -> load_already_dispatched (not a resource/race message)", () => {
  const rows = [D({ id: "ff50462b", load_id: "load-A", load_number: "LD-100024", driver_id: "drv-1", truck_id: "trk-1" })];
  const c = classifyAssignmentConflict(rows, {
    loadId: "load-A", driverId: "drv-1", truckId: "trk-1", trailerId: null,
  });
  assert.equal(c.kind, "load_already_dispatched");
  assert.equal(c.dispatchId, "ff50462b");
  assert.equal(LOAD_ALREADY_DISPATCHED_CODE, "LOAD_ALREADY_DISPATCHED");
  assert.match(conflictMessage(c), /already has an active dispatch/i);
  // and it is NOT reported as a generic "just taken by another dispatch"
  assert.doesNotMatch(conflictMessage(c), /just taken by another dispatch/i);
});

// (f) timezone boundaries do not produce false overlap
test("f) no time-window logic exists -> pickup/delivery timezones cannot fabricate an overlap", () => {
  // The rule keys purely off dispatches.status + resource ids; there is no
  // scheduled-window comparison to mis-convert. A dispatch on a DIFFERENT
  // load/resource never conflicts regardless of any stop times.
  const rows = [D({ id: "d-tz", load_id: "other-load", load_number: "LD-9999", driver_id: "drv-x", truck_id: "trk-x" })];
  const c = classifyAssignmentConflict(rows, {
    loadId: "load-A", driverId: "drv-1", truckId: "trk-1", trailerId: null,
  });
  assert.equal(c, null);
});

test("edit: excludeDispatchId drops self-conflict (same driver/truck on the row being edited)", () => {
  const rows = [D({ id: "self", load_id: "load-A", driver_id: "drv-1", truck_id: "trk-1" })];
  assert.equal(
    classifyAssignmentConflict(rows, { driverId: "drv-1", truckId: "trk-1", trailerId: null, excludeDispatchId: "self" }),
    null
  );
});

test("first conflict wins in order: load -> driver -> truck -> trailer", () => {
  const rows = [
    D({ id: "d-load", load_id: "load-A", load_number: "LD-1" }),
    D({ id: "d-drv", load_id: "load-B", load_number: "LD-2", driver_id: "drv-1" }),
  ];
  const c = classifyAssignmentConflict(rows, { loadId: "load-A", driverId: "drv-1", truckId: "trk-1", trailerId: null });
  assert.equal(c.kind, "load_already_dispatched");
});

test("ACTIVE_DISPATCH_STATUSES mirrors the 0054 partial-unique-index WHERE clause", () => {
  assert.deepEqual([...ACTIVE_DISPATCH_STATUSES], [
    "assigned", "accepted", "en_route_to_pickup", "at_pickup", "loaded",
    "en_route_to_delivery", "at_delivery",
  ]);
});

// Guards the exact regression: the conflict lookup embed MUST name the
// dispatches->loads FK, or it silently 500s again once 0125 is live.
test("actions.ts conflict query disambiguates the loads embed (loads!dispatches_load_id_fkey)", () => {
  const src = readFileSync(new URL("../../app/(app)/dispatch/actions.ts", import.meta.url), "utf8");
  const code = src.replace(/^[ \t]*\/\/.*$/gm, "");
  assert.match(code, /loads:loads!dispatches_load_id_fkey\(load_number\)/,
    "fetchConflictCandidates must use the named FK embed");
  assert.doesNotMatch(code, /\bselect\([^)]*[^!]loads\(load_number\)/,
    "no bare ambiguous `loads(load_number)` embed from dispatches");
  // the query error is surfaced, not swallowed
  assert.match(code, /dispatch conflict lookup failed/);
});
