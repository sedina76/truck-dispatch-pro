// 0152: RRIDK (reassign_dispatch_resources) and FPIDK (set_carrier_factoring_policy) map to ONE fixed, safe message; nothing from the database reaches the UI.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { rpcDispatchConflict, IDEMPOTENCY_KEY_REUSED_MESSAGE } from "./conflicts.ts";
import { resolveStructuredRpcResult, FPIDK_MESSAGE } from "../factoring/rpc-result.ts";

const LEAKY = "reassign_dispatch_resources: this idempotency key was already used for a different request. dispatch_resource_reassignments_dispatch_id_idempotency_key_key ff50462b-735b-48ae-ac83-d43886b605b8";
const FORBIDDEN = /reassign_dispatch_resources|set_carrier_factoring_policy|dispatch_resource_reassignments|_key|idempotency_key|ff50462b|public\.|constraint|SQLSTATE|RRIDK|FPIDK/i;

test("RRIDK -> stable app code + fixed safe message (the database text is never used)", () => {
  const c = rpcDispatchConflict({ code: "RRIDK", message: LEAKY, details: "ff50462b-735b-48ae-ac83-d43886b605b8" });
  assert.equal(c.code, "IDEMPOTENCY_KEY_REUSED");
  assert.equal(c.field, null);
  assert.equal(c.message, IDEMPOTENCY_KEY_REUSED_MESSAGE);
  assert.doesNotMatch(c.message, FORBIDDEN);
  assert.match(c.message, /different details/i);
  assert.match(c.message, /try again/i);
});

test("FPIDK -> fixed safe message from the structured-RPC resolver; other errors keep their existing behaviour", () => {
  const r = resolveStructuredRpcResult(null, { code: "FPIDK", message: "set_carrier_factoring_policy: this idempotency key was already used for a different request. factoring_policy_idempotency_pkey" });
  assert.deepEqual(r, { ok: false, error: FPIDK_MESSAGE });
  assert.doesNotMatch(FPIDK_MESSAGE, FORBIDDEN);
  assert.match(FPIDK_MESSAGE, /different details/i);
  assert.match(FPIDK_MESSAGE, /try again/i);
  assert.deepEqual(resolveStructuredRpcResult(null, { code: "FPROL", message: "only an owner or admin" }), { ok: false, error: "only an owner or admin" });
  assert.deepEqual(resolveStructuredRpcResult({ success: true }, null), { ok: true, data: { success: true } });
});

test("both messages are identical wording, and the dispatch alert has a heading for the new app code", () => {
  assert.equal(IDEMPOTENCY_KEY_REUSED_MESSAGE, FPIDK_MESSAGE);
  const alert = readFileSync(new URL("../../components/dispatch/dispatch-conflict-alert.tsx", import.meta.url), "utf8");
  assert.match(alert, /IDEMPOTENCY_KEY_REUSED:\s*"Request already submitted"/);
});

test("the reassign caller routes RRIDK through rpcDispatchConflict (fixed message), the factoring caller through resolveStructuredRpcResult", () => {
  const dispatch = readFileSync(new URL("../../app/(app)/dispatch/actions.ts", import.meta.url), "utf8");
  assert.match(dispatch, /const conflict = rpcDispatchConflict\(resourceError\);\s*throw conflict \? new DispatchConflictError\(conflict\.message/);
  const fact = readFileSync(new URL("../../app/(app)/settings/factoring/actions.ts", import.meta.url), "utf8");
  // The factoring settings actions hand the RAW Supabase error (which carries
  // .code) straight to resolveStructuredRpcResult, so FPIDK reaches the
  // fixed-message mapping in rpc-result.ts.
  assert.match(fact, /resolveStructuredRpcResult\(data as StructuredRpcResult \| null, error\)/);
  const rpc = readFileSync(new URL("../factoring/rpc-result.ts", import.meta.url), "utf8");
  assert.match(rpc, /error\.code === "FPIDK" \? FPIDK_MESSAGE : error\.message/);
});
