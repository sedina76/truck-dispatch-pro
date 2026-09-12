// Phase 3A.4 static-source-pattern coverage for updateDispatch()'s
// transactional-safety fixes (items 2-4 of the "resolve two final
// transactional-safety issues" round). These are grep-style checks against
// the actual TS source, matching the convention already established by
// src/lib/billing/operational-access.test.mjs's D.2.11 checks -- actions.ts
// is a "use server" file with real Supabase/DB calls, so this is the
// fastest, most direct way to prove a structural property (a call ordering,
// a guard, an import) without standing up a live database for a unit test.
// The disposable-Postgres suite (supabase/TEST_0135_...sql) exercises the
// actual RPC behavior these guards rely on.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ACTIONS = readFileSync(new URL("./actions.ts", import.meta.url), "utf8");
const BOARD_ACTIONS = readFileSync(new URL("./board-actions.ts", import.meta.url), "utf8");
const PAGE = readFileSync(new URL("./[id]/page.tsx", import.meta.url), "utf8");
const IDEMPOTENCY_LIB = readFileSync(new URL("../../../lib/dispatch/reassignment-idempotency.ts", import.meta.url), "utf8");

// Isolates updateDispatch()'s own body so assertions can't accidentally
// match some other exported function in the same file (createDispatch,
// cancelDispatch, updateDispatchStatus, etc.).
function updateDispatchBody() {
  const start = ACTIONS.indexOf("export async function updateDispatch(");
  assert.notEqual(start, -1, "updateDispatch() not found in actions.ts");
  const nextExport = ACTIONS.indexOf("\nexport async function", start + 1);
  return nextExport === -1 ? ACTIONS.slice(start) : ACTIONS.slice(start, nextExport);
}

test("Phase 3A.4 item 2: updateDispatch() never calls transition_dispatch_status -- status editing was removed from this form entirely", () => {
  const body = updateDispatchBody();
  assert.ok(!body.includes("transition_dispatch_status"), "updateDispatch() must not call transition_dispatch_status -- status changes belong exclusively to the Dispatch Board / a dedicated action");
  // Confirm it wasn't just renamed/obscured -- there is no formData read of
  // a "status" field in this function either.
  assert.ok(!body.includes('formData.get("status")'), "updateDispatch() must not read a status field from the form at all");
});

test("Phase 3A.4 item 2: updateDispatch() contains at most ONE call into reassign_dispatch_resources, and no OTHER dispatches-mutating RPC alongside it", () => {
  const body = updateDispatchBody();
  const rpcCalls = [...body.matchAll(/supabase\.rpc\(\s*"([a-z_]+)"/g)].map((m) => m[1]);
  const mutatingDispatchRpcs = rpcCalls.filter((name) => name === "reassign_dispatch_resources" || name === "transition_dispatch_status");
  assert.equal(mutatingDispatchRpcs.length, 1, `expected exactly one dispatches-mutating RPC call in updateDispatch(), found: ${JSON.stringify(mutatingDispatchRpcs)}`);
  assert.equal(mutatingDispatchRpcs[0], "reassign_dispatch_resources");
});

test("Phase 3A.4 item 3: updateDispatch() only calls reassign_dispatch_resources inside a resourcesChanged guard", () => {
  const body = updateDispatchBody();
  assert.ok(/const resourcesChanged\s*=/.test(body), "updateDispatch() must compute a resourcesChanged flag");
  const guardIdx = body.indexOf("if (resourcesChanged)");
  assert.notEqual(guardIdx, -1, "updateDispatch() must gate the resource RPC behind `if (resourcesChanged)`");
  const rpcIdx = body.indexOf('supabase.rpc("reassign_dispatch_resources"');
  assert.notEqual(rpcIdx, -1, "reassign_dispatch_resources call not found");
  assert.ok(rpcIdx > guardIdx, "reassign_dispatch_resources must be called AFTER the resourcesChanged guard opens, not before it");
  // And the comparison driving that flag reads the CURRENTLY SAVED
  // assignment from the database, not merely echoed/trusted form state.
  assert.ok(/currentDispatch\.driver_id/.test(body) && /currentDispatch\.truck_id/.test(body) && /currentDispatch\.trailer_id/.test(body), "resourcesChanged must compare against the database-read currentDispatch row, not a client-trusted value");
});

test("Phase 3A.4 item 3: financials/notes writes happen UNCONDITIONALLY (a notes-only or unchanged-resource save must still persist them)", () => {
  const body = updateDispatchBody();
  const guardIdx = body.indexOf("if (resourcesChanged)");
  // Find the matching closing brace of the `if (resourcesChanged) { ... }`
  // block by simple depth counting from its opening brace.
  const openBrace = body.indexOf("{", guardIdx);
  let depth = 0;
  let closeBrace = -1;
  for (let i = openBrace; i < body.length; i++) {
    if (body[i] === "{") depth++;
    else if (body[i] === "}") {
      depth--;
      if (depth === 0) {
        closeBrace = i;
        break;
      }
    }
  }
  assert.notEqual(closeBrace, -1, "could not locate the end of the resourcesChanged block");
  const afterGuard = body.slice(closeBrace);
  assert.ok(afterGuard.includes("writeDispatchFinancials"), "writeDispatchFinancials must run OUTSIDE (after) the resourcesChanged block, not be skipped for a notes-only save");
  assert.ok(afterGuard.includes("writeDispatchNotes"), "writeDispatchNotes must run OUTSIDE (after) the resourcesChanged block, not be skipped for a notes-only save");
});

test("Phase 3A.4 item 4: the idempotency key passed to reassign_dispatch_resources is SERVER-GENERATED, never read directly from formData", () => {
  const body = updateDispatchBody();
  assert.ok(body.includes("buildReassignmentIdempotencyKey("), "updateDispatch() must call buildReassignmentIdempotencyKey() to produce the idempotency key");
  assert.ok(!/p_idempotency_key:\s*formData\.get/.test(body), "p_idempotency_key must never be assigned directly from formData.get(...) -- that would let the browser supply an arbitrary key");
  assert.ok(!/formData\.get\(\s*["']idempotency_key["']/.test(body), "updateDispatch() must not read any client-supplied idempotency_key field at all");
});

test("Phase 3A.4 item 4: buildReassignmentIdempotencyKey is a deterministic, organization+operation-scoped hash (no randomUUID/Math.random)", () => {
  assert.ok(IDEMPOTENCY_LIB.includes("createHash"), "the idempotency key must be derived via a deterministic hash (node:crypto createHash)");
  assert.ok(!/randomUUID|Math\.random/.test(IDEMPOTENCY_LIB), "the idempotency key must not use any source of randomness -- it must be reproducible for a byte-identical retry");
  assert.ok(IDEMPOTENCY_LIB.includes("organizationId"), "the key must be scoped by organization");
  assert.ok(IDEMPOTENCY_LIB.includes("reassign_dispatch_resources"), "the key must be scoped to this specific operation (folded into the hash input)");
});

test("Phase 3A.4 item 2: status transitions remain exclusively on the Dispatch Board, via transition_dispatch_status()", () => {
  assert.ok(BOARD_ACTIONS.includes('supabase.rpc("transition_dispatch_status"'), "updateDispatchBoardStatus() must still route status changes through transition_dispatch_status()");
});

test("Phase 3A.4 item 2: the dispatch edit page no longer renders a status <select> / STATUS_OPTIONS control", () => {
  assert.ok(!/const STATUS_OPTIONS/.test(PAGE), "dispatch/[id]/page.tsx must not define a STATUS_OPTIONS list -- status editing was removed from this form (a mention in a comment explaining the removal is fine)");
  assert.ok(!/name="status"/.test(PAGE), "dispatch/[id]/page.tsx must not submit a status field from the edit form");
  assert.ok(!/<FormSelect/.test(PAGE), "dispatch/[id]/page.tsx must not render a FormSelect at all (it was only ever used for the removed status field)");
});
