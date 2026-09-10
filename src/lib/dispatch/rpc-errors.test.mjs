// 0129: translating create_dispatch / cancel_dispatch RPC errors into the
// app's DispatchConflictError shape. Pure -- no DB, no network.

import test from "node:test";
import assert from "node:assert/strict";
import { rpcDispatchConflict, CONFLICT_CODE, LOAD_ALREADY_DISPATCHED_CODE } from "./conflicts.ts";

const UUID = "ff50462b-735b-48ae-ac83-d43886b605b8";

test("TDDUP -> load_already_dispatched, carries the conflicting dispatch id", () => {
  const c = rpcDispatchConflict({
    code: "TDDUP",
    message: "This load already has an active dispatch. Open it from the Dispatch Board to make changes, or cancel that dispatch first.",
    details: UUID,
  });
  assert.equal(c.code, LOAD_ALREADY_DISPATCHED_CODE);
  assert.equal(c.field, null);
  assert.equal(c.conflictDispatchId, UUID);
  assert.match(c.message, /already has an active dispatch/i);
});

test("TDDRV / TDTRK / TDTRL -> resource codes + field + dispatch id from details", () => {
  for (const [code, appCode, field] of [
    ["TDDRV", CONFLICT_CODE.driver, "driver"],
    ["TDTRK", CONFLICT_CODE.truck, "truck"],
    ["TDTRL", CONFLICT_CODE.trailer, "trailer"],
  ]) {
    const c = rpcDispatchConflict({ code, message: "X is already assigned to active load LD-1.", details: UUID });
    assert.equal(c.code, appCode);
    assert.equal(c.field, field);
    assert.equal(c.conflictDispatchId, UUID);
  }
});

test("non-uuid / empty details -> conflictDispatchId null", () => {
  assert.equal(rpcDispatchConflict({ code: "TDLND", message: "no", details: "booked" }).conflictDispatchId, null);
  assert.equal(rpcDispatchConflict({ code: "TDDRV", message: "no", details: "" }).conflictDispatchId, null);
  assert.equal(rpcDispatchConflict({ code: "TDDRV", message: "no" }).conflictDispatchId, null);
});

test("TDLND / TDLNF / TDCNF / TDTRM / TDROL / TDAUT map to distinct app codes, field null", () => {
  const cases = {
    TDLND: "LOAD_NOT_DISPATCHABLE",
    TDLNF: "LOAD_NOT_FOUND",
    TDCNF: "DISPATCH_NOT_FOUND",
    TDTRM: "DISPATCH_TERMINAL",
    TDROL: "forbidden",
    TDAUT: "not_authenticated",
  };
  for (const [code, appCode] of Object.entries(cases)) {
    const c = rpcDispatchConflict({ code, message: "m" });
    assert.equal(c.code, appCode);
    assert.equal(c.field, null);
  }
});

test("unknown / missing code -> null (caller falls back to generic handling)", () => {
  assert.equal(rpcDispatchConflict({ code: "23505", message: "dup key" }), null);
  assert.equal(rpcDispatchConflict({ code: "P0001", message: "x" }), null);
  assert.equal(rpcDispatchConflict({ message: "x" }), null);
  assert.equal(rpcDispatchConflict(null), null);
  assert.equal(rpcDispatchConflict(undefined), null);
});

test("blank message -> a safe generic fallback string", () => {
  const c = rpcDispatchConflict({ code: "TDDUP", message: "   ", details: UUID });
  assert.equal(typeof c.message, "string");
  assert.ok(c.message.length > 0);
  assert.doesNotMatch(c.message, /^\s*$/);
});
