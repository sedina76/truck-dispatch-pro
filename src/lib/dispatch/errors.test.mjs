// translateDispatchError() -- the ONE place that decides whether an error
// from createDispatch/updateDispatch is expected business feedback or a
// genuine bug. Pure -- no DB, no network, no React.
//
// This file specifically regression-tests the CARRIER_SCOPE_GUARD_MESSAGES
// addition: public.guard_dispatch_carrier_scope() (0132, a BEFORE INSERT/
// UPDATE trigger on public.dispatches) raises five conditions with plain
// Postgres SQLSTATEs (23503/23514), which rpcDispatchConflict() (conflicts.ts)
// never recognises (it only knows this app's own TDxxx/TSxxx/RRxxx codes) --
// before this fix, all five fell through to the generic UNKNOWN message.
// The fix matches on exact message SHAPE, never on the bare SQLSTATE, since
// 23503/23514 are also raised by unrelated constraint violations elsewhere.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { translateDispatchError, DispatchConflictError } from "./errors.ts";

const U1 = "11111111-1111-1111-1111-111111111111";
const U2 = "22222222-2222-2222-2222-222222222222";
const U3 = "33333333-3333-3333-3333-333333333333";
const V1 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const V2 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
const V3 = "cccccccc-cccc-cccc-cccc-cccccccccccc";

test("0132 LOAD_NOT_FOUND: 'dispatch load <uuid> does not exist.' -> stable code + safe message", () => {
  for (const id of [U1, V1]) {
    const r = translateDispatchError({ code: "23503", message: `dispatch load ${id} does not exist.` });
    assert.equal(r.code, "LOAD_NOT_FOUND");
    assert.match(r.error, /could not be found/i);
    assert.doesNotMatch(r.error, new RegExp(id));
  }
});

test("0132 CARRIER_UNRESOLVED: unresolved-carrier message -> stable code + safe message", () => {
  for (const id of [U1, V1]) {
    const r = translateDispatchError({
      code: "23514",
      message: `load ${id} has an unresolved carrier (see unresolved_carrier_records) -- no dispatch may be created or reactivated on it until the carrier is resolved.`,
    });
    assert.equal(r.code, "CARRIER_UNRESOLVED");
    assert.match(r.error, /carrier.*not.*resolved|resolve the carrier/i);
    assert.doesNotMatch(r.error, /unresolved_carrier_records/);
    assert.doesNotMatch(r.error, new RegExp(id));
  }
});

test("0132 MULTIPLE_CARRIERS: conflicting-carriers message (array content varies) -> stable code + safe message", () => {
  const arrays = [`{${U1},${U2}}`, `{${V1},${V2},${V3}}`];
  for (const arr of arrays) {
    const r = translateDispatchError({
      code: "23514",
      message: `load ${U3} already has multiple conflicting non-cancelled dispatch carriers (${arr}) -- cannot add/reactivate dispatch ${U1} until this is manually resolved.`,
    });
    assert.equal(r.code, "MULTIPLE_CARRIERS");
    assert.match(r.error, /more than one conflicting carrier/i);
    assert.doesNotMatch(r.error, /\{/); // no raw pg array literal leaks through
    assert.doesNotMatch(r.error, new RegExp(U3));
  }
});

test("0132 CARRIER_MISMATCH: dispatch-carrier-vs-load-carrier message -> stable code + safe message, no UUIDs leaked", () => {
  for (const [a, b, c] of [
    [U1, U2, U3],
    [V1, V2, V3],
  ]) {
    const r = translateDispatchError({
      code: "23514",
      message: `dispatch carrier ${a} does not match load ${b} carrier ${c} -- a conflicting carrier can never coexist with an existing carrier/live-dispatch assignment on the same load.`,
    });
    assert.equal(r.code, "CARRIER_MISMATCH");
    assert.match(r.error, /already committed to a different carrier/i);
    assert.doesNotMatch(r.error, new RegExp(a));
    assert.doesNotMatch(r.error, new RegExp(b));
    assert.doesNotMatch(r.error, new RegExp(c));
  }
});

test("0132 TRAILER_UNRESOLVED: unresolved trailer-ownership message -> stable code + safe message", () => {
  for (const id of [U1, V1]) {
    const r = translateDispatchError({
      code: "23514",
      message: `trailer ${id} has unresolved ownership; an owner/admin must classify it as carrier or organization_shared before it can be dispatched.`,
    });
    assert.equal(r.code, "TRAILER_UNRESOLVED");
    assert.match(r.error, /ownership.*hasn't been classified|classify it/i);
    assert.doesNotMatch(r.error, new RegExp(id));
  }
});

test("unrelated 23503 (FK violation elsewhere in the schema) stays UNKNOWN, not misclassified as LOAD_NOT_FOUND", () => {
  const r = translateDispatchError({
    code: "23503",
    message: 'insert or update on table "dispatches" violates foreign key constraint "dispatches_driver_id_fkey"',
  });
  assert.equal(r.code, "UNKNOWN");
  assert.equal(r.error, "Unable to save this dispatch. Please try again.");
});

test("unrelated 23514 (unrelated check constraint) stays UNKNOWN, not misclassified as one of the five guard codes", () => {
  const r = translateDispatchError({
    code: "23514",
    message: 'new row for relation "trucks" violates check constraint "trucks_status_check"',
  });
  assert.equal(r.code, "UNKNOWN");
  assert.equal(r.error, "Unable to save this dispatch. Please try again.");
});

test("a message that merely mentions 'carrier' and 'does not match' without the full 0132 shape stays UNKNOWN (no accidental broad match)", () => {
  const r = translateDispatchError({
    code: "23514",
    message: "some unrelated carrier field does not match another unrelated value in a totally different check.",
  });
  assert.equal(r.code, "UNKNOWN");
});

test("DispatchConflictError instances pass through unchanged", () => {
  const err = new DispatchConflictError("This driver is already assigned to active load LD-9.", {
    code: "DRIVER_ACTIVE_DISPATCH",
    field: "driver",
    conflictDispatchId: U1,
    conflictLoadNumber: "LD-9",
  });
  const r = translateDispatchError(err);
  assert.deepEqual(r, {
    error: "This driver is already assigned to active load LD-9.",
    code: "DRIVER_ACTIVE_DISPATCH",
    field: "driver",
    conflictDispatchId: U1,
    conflictLoadNumber: "LD-9",
    maintenanceId: null,
  });
});

test("23505 unique_violation fallback is unchanged", () => {
  const r = translateDispatchError({ code: "23505", message: 'duplicate key value violates unique constraint "dispatches_active_driver_uidx"' });
  assert.equal(r.code, "CONCURRENT_UPDATE");
  assert.match(r.error, /just taken by another dispatch/i);
});

test("lock-timeout / serialization / deadlock codes are unchanged", () => {
  for (const code of ["55P03", "57014", "40P01", "40001"]) {
    const r = translateDispatchError({ code, message: "canceling statement due to statement timeout" });
    assert.equal(r.code, "LOCK_TIMEOUT");
    assert.match(r.error, /busy under another in-flight request|please wait a moment/i);
  }
});

test("required-field validation errors are unchanged", () => {
  assert.deepEqual(translateDispatchError(new Error("Carrier is required.")), { error: "Carrier is required.", code: "VALIDATION_ERROR" });
  assert.deepEqual(translateDispatchError(new Error("Truck is required.")), { error: "Truck is required.", code: "VALIDATION_ERROR" });
  assert.deepEqual(translateDispatchError(new Error("Driver is required.")), { error: "Driver is required.", code: "VALIDATION_ERROR" });
  assert.deepEqual(translateDispatchError(new Error("Select a load first.")), { error: "Select a load first.", code: "VALIDATION_ERROR" });
});

test("pre-existing GUARD_ORG_PATTERNS (0048/0055) carrier-mismatch wording still maps correctly (regression: new block must not shadow it)", () => {
  const r = translateDispatchError({ code: "23514", message: "this driver does not belong to the selected carrier." });
  assert.equal(r.code, "CARRIER_MISMATCH");
  assert.match(r.error, /driver, truck, or trailer isn't valid/i);
});

test("a genuinely unexpected error still falls through to the safe generic UNKNOWN message", () => {
  const r = translateDispatchError(new Error("connection terminated unexpectedly"));
  assert.equal(r.code, "UNKNOWN");
  assert.equal(r.error, "Unable to save this dispatch. Please try again.");
});

test("no CARRIER_SCOPE_GUARD_MESSAGES safe message leaks a raw SQL/table/constraint name", () => {
  const messages = [
    `dispatch load ${U1} does not exist.`,
    `load ${U1} has an unresolved carrier (see unresolved_carrier_records) -- no dispatch may be created or reactivated on it until the carrier is resolved.`,
    `load ${U1} already has multiple conflicting non-cancelled dispatch carriers ({${U1},${U2}}) -- cannot add/reactivate dispatch ${U1} until this is manually resolved.`,
    `dispatch carrier ${U1} does not match load ${U2} carrier ${U3} -- a conflicting carrier can never coexist with an existing carrier/live-dispatch assignment on the same load.`,
    `trailer ${U1} has unresolved ownership; an owner/admin must classify it as carrier or organization_shared before it can be dispatched.`,
  ];
  for (const message of messages) {
    const r = translateDispatchError({ code: "23514", message });
    assert.doesNotMatch(r.error, /unresolved_carrier_records|public\.|dispatches_|_fkey|_check|constraint/i);
    assert.doesNotMatch(r.error, /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  }
});

// dispatch-conflict-alert.tsx is a "use client" component with JSX, which
// the plain `node --test` runner used by this repo (see package.json's
// `test` script) cannot import directly. Following the same static
// source-text convention already used by
// src/lib/billing/operational-access.test.mjs, read the file and assert its
// HEADING_BY_CODE table maps each new/reused code to the intended heading.
const ALERT_SRC = readFileSync(new URL("../../components/dispatch/dispatch-conflict-alert.tsx", import.meta.url), "utf8");

test("dispatch-conflict-alert.tsx has a heading for every 0132 guard code", () => {
  const expected = {
    LOAD_NOT_FOUND: "Load not found",
    CARRIER_UNRESOLVED: "Carrier not resolved",
    MULTIPLE_CARRIERS: "Multiple carriers on this load",
    CARRIER_MISMATCH: "Assignment not valid",
    TRAILER_UNRESOLVED: "Trailer ownership not resolved",
  };
  for (const [code, heading] of Object.entries(expected)) {
    const re = new RegExp(`${code}:\\s*"${heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`);
    assert.match(ALERT_SRC, re, `expected HEADING_BY_CODE.${code} === ${JSON.stringify(heading)}`);
  }
});
