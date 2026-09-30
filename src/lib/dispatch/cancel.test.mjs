// Blocker F1: Cancel action goes through transition_dispatch_status (pure helpers + static source checks).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { cancelDispatchErrorMessage, cancelIdempotencyKey, CANCEL_FALLBACK_MESSAGE } from "./cancel.ts";

const ACTIONS = readFileSync(new URL("../../app/(app)/dispatch/actions.ts", import.meta.url), "utf8");
const FORM = readFileSync(new URL("../../components/dispatch/cancel-dispatch-form.tsx", import.meta.url), "utf8");

function cancelDispatchBody() {
  const start = ACTIONS.indexOf("export async function cancelDispatch(");
  assert.notEqual(start, -1, "cancelDispatch() not found");
  const next = ACTIONS.indexOf("\nexport async function", start + 1);
  const raw = next === -1 ? ACTIONS.slice(start) : ACTIONS.slice(start, next);
  return raw.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n"); // code only, not comments
}

test("known cancel error codes map to fixed, user-safe messages", () => {
  assert.match(cancelDispatchErrorMessage({ code: "TSROL" }), /owner, admin, or dispatcher/i);
  assert.match(cancelDispatchErrorMessage({ code: "TDROL" }), /owner, admin, or dispatcher/i);
  assert.match(cancelDispatchErrorMessage({ code: "TSAUT" }), /signed in/i);
  assert.match(cancelDispatchErrorMessage({ code: "TSDNF" }), /could not be found/i);
  assert.match(cancelDispatchErrorMessage({ code: "TDTRM" }), /delivered or completed/i);
  assert.match(cancelDispatchErrorMessage({ code: "TSINV" }), /current status/i);
});

test("unknown / missing codes get the generic fallback -- never the database's own text", () => {
  for (const err of [{ code: "42501" }, { code: "42883" }, { code: "P0001" }, { code: null }, {}, null, undefined]) {
    assert.equal(cancelDispatchErrorMessage(err), CANCEL_FALLBACK_MESSAGE);
  }
  const leaky = { code: "TSDNF", message: "transition_dispatch_status: dispatch ff50462b-735b-48ae-ac83-d43886b605b8 not found.", details: "secret", hint: "h" };
  const msg = cancelDispatchErrorMessage(leaky);
  assert.ok(!/transition_dispatch_status|ff50462b|secret/.test(msg), msg);
  for (const m of [msg, CANCEL_FALLBACK_MESSAGE, cancelDispatchErrorMessage({ code: "TSROL" })]) {
    assert.ok(!/(public\.|_dispatch|sqlstate|permission denied|operator does not exist)/i.test(m), m);
  }
});

test("idempotency key: accepts a UUID / url-safe token, rejects everything else", () => {
  const uuid = "3f6d2c1e-8a4b-4c7d-9e0f-1a2b3c4d5e6f";
  assert.equal(cancelIdempotencyKey(uuid), uuid);
  for (const bad of [null, "", "short", "x".repeat(65), "has space in it....", "semi;colon;semi;colon", "quote'quote'quote'q", new File(["a"], "a.txt")]) {
    assert.equal(cancelIdempotencyKey(bad), null);
  }
});

test("cancelDispatch() calls transition_dispatch_status with status 'cancelled', the reason and the form's key -- never cancel_dispatch or a direct UPDATE", () => {
  const body = cancelDispatchBody();
  const rpcs = [...body.matchAll(/supabase\.rpc\(\s*"([a-z_]+)"/g)].map((m) => m[1]);
  assert.deepEqual(rpcs, ["transition_dispatch_status"]);
  assert.ok(!/rpc\(\s*"cancel_dispatch"/.test(body), "must not call cancel_dispatch directly (SECURITY INVOKER; refused since 0135)");
  assert.ok(!/\.update\(|updateRecordInPlace/.test(body), "must not write dispatches directly");
  assert.ok(/p_new_status:\s*"cancelled"/.test(body));
  assert.ok(/p_reason:\s*reason/.test(body), "the reason must be forwarded unchanged");
  assert.ok(/p_idempotency_key:\s*cancelIdempotencyKey\(formData\.get\("idempotency_key"\)\)/.test(body));
});

test("cancelDispatch() keeps the paywall + DISPATCH_WRITES_DISABLED kill switch ahead of any write, and never surfaces raw DB text", () => {
  const body = cancelDispatchBody();
  const paywall = body.indexOf("requireOperationalAccess()");
  const kill = body.indexOf('process.env.DISPATCH_WRITES_DISABLED === "1"');
  const rpc = body.indexOf('supabase.rpc("transition_dispatch_status"');
  assert.ok(paywall !== -1 && kill !== -1 && rpc !== -1);
  assert.ok(paywall < kill && kill < rpc, "paywall, then kill switch, then the RPC");
  assert.ok(/throw new DispatchConflictError\(DISPATCH_MAINTENANCE_MESSAGE/.test(body));
  assert.ok(/throw new Error\(cancelDispatchErrorMessage\(error\)\)/.test(body));
  assert.ok(!/error\.message/.test(body), "the raw database message must never be thrown to the UI");
});

test("cancel form posts one idempotency key per form instance (useState initialiser, hidden input)", () => {
  assert.ok(/const \[idempotencyKey\] = useState\(\(\) => crypto\.randomUUID\(\)\)/.test(FORM), "key generated once per mounted form, not per render");
  assert.ok(/<input type="hidden" name="idempotency_key" value=\{idempotencyKey\} \/>/.test(FORM));
  assert.ok(/name="reason"/.test(FORM), "reason input retained");
});
