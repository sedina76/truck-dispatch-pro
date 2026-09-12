// Phase 3B.1.3 (Section D/H) -- tests for structured RPC-result handling.
// Pure logic, zero DB, zero Supabase client -- imported directly (no
// "server-only"/framework dependency in rpc-result.ts).

import test from "node:test";
import assert from "node:assert/strict";
import { mapStructuredRpcFailure, resolveStructuredRpcResult } from "./rpc-result.ts";

// ==========================================================================
// H.8: a structured {success:false} RPC result is treated as a failure,
// never inferred as success merely because `error` is null.
// ==========================================================================
test("H.8: success:false with no transport error is still a failure", () => {
  const result = resolveStructuredRpcResult({ success: false, message: "This carrier is not ready for this change yet." }, null);
  assert.equal(result.ok, false);
  assert.equal(result.error, "This carrier is not ready for this change yet.");
});

test("H.8: success:true with no error is a genuine success", () => {
  const result = resolveStructuredRpcResult({ success: true, carrier_id: "c1" }, null);
  assert.equal(result.ok, true);
  assert.deepEqual(result.data, { success: true, carrier_id: "c1" });
});

test("H.8: a transport/Postgres exception (`error` non-null) is a failure even if `data` looks successful", () => {
  const result = resolveStructuredRpcResult({ success: true }, { message: "permission denied" });
  assert.equal(result.ok, false);
  assert.equal(result.error, "permission denied");
});

test("H.8: a null/undefined data with no error is a failure, not a silent success", () => {
  assert.equal(resolveStructuredRpcResult(null, null).ok, false);
  assert.equal(resolveStructuredRpcResult(undefined, null).ok, false);
});

// ==========================================================================
// H.9: an "incomplete" relationship result is never reported as success --
// this is the exact bug found in setDefaultFactoringRelationship() before
// Phase 3B.1.3 (0138 changed this case from a raised exception to a
// normal structured result, and the old action only checked `error`).
// ==========================================================================
test("H.9: incomplete:true is a failure with its own message", () => {
  const result = resolveStructuredRpcResult(
    { success: false, incomplete: true, relationship_id: "r1", carrier_id: "c1", message: "This relationship is missing remittance instructions..." },
    null
  );
  assert.equal(result.ok, false);
  assert.match(result.error, /missing remittance instructions/);
});

test("H.9: incomplete:true with no message still gets a specific, non-generic fallback", () => {
  const msg = mapStructuredRpcFailure({ success: false, incomplete: true });
  assert.match(msg, /missing required configuration/i);
});

// ==========================================================================
// Every other documented failure classification (Section D's exact list)
// maps to a clear, non-empty message -- never "undefined" or a blank
// string, with or without the RPC's own `message` present.
// ==========================================================================
test("every documented failure flag maps to a clear message when `message` is absent", () => {
  assert.match(mapStructuredRpcFailure({ success: false, expected_version_required: true }), /current version/i);
  assert.match(mapStructuredRpcFailure({ success: false, stale_record: true }), /changed by someone else/i);
  assert.match(mapStructuredRpcFailure({ success: false, not_ready: true }), /not ready/i);
  assert.match(mapStructuredRpcFailure({ success: false, blocked: true, reason: "open_factored_activity" }), /blocked/i);
  assert.match(mapStructuredRpcFailure({ success: false }), /could not be completed/i);
  assert.match(mapStructuredRpcFailure(null), /could not be completed/i);
});

test("the RPC's own `message` field is always preferred over the generic flag fallbacks", () => {
  const msg = mapStructuredRpcFailure({ success: false, stale_record: true, message: "custom precise sentence" });
  assert.equal(msg, "custom precise sentence");
});

test("a blank/whitespace-only `message` does not suppress the flag-based fallback", () => {
  const msg = mapStructuredRpcFailure({ success: false, not_ready: true, message: "   " });
  assert.match(msg, /not ready/i);
});

// ==========================================================================
// Phase 3B.1.5 (Section B/G) -- submit_invoice_to_factor() (0140) returns
// this EXACT shape for every legacy invoice today (no exception raised --
// a normal jsonb result), and it must be treated as a failure, never
// inferred as success merely because there is no transport `error`.
// ==========================================================================
test("3B.1.5: submit_invoice_to_factor's CARRIER_INVOICE_SNAPSHOT_REQUIRED result is a failure carrying the RPC's own message", () => {
  const result = resolveStructuredRpcResult(
    {
      success: false,
      code: "CARRIER_INVOICE_SNAPSHOT_REQUIRED",
      snapshot_required: true,
      message:
        "This invoice was created before carrier-specific financial snapshots were enabled. Review and reissue it through the new invoice workflow.",
    },
    null
  );
  assert.equal(result.ok, false);
  assert.equal(
    result.error,
    "This invoice was created before carrier-specific financial snapshots were enabled. Review and reissue it through the new invoice workflow."
  );
});
