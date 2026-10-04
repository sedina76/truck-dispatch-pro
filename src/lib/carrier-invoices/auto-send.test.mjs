// Until factoring APIs are connected, the billing packet is emailed to the
// factor automatically once it's complete -- only for factored carriers whose
// paperwork we send by email, and never twice.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { shouldAutoSendToFactor } from "./auto-send-rules.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const base = { issuanceStatus: "issued", who: "factor", to: "submit@apexfactor.com", alreadySent: false };

test("who gets it automatically", () => {
  assert.deepEqual(shouldAutoSendToFactor(base), { send: true, reason: "ok" });
  assert.equal(shouldAutoSendToFactor({ ...base, issuanceStatus: "draft" }).send, false);
  assert.equal(shouldAutoSendToFactor({ ...base, who: "carrier" }).send, false, "carrier sends its own");
  assert.equal(shouldAutoSendToFactor({ ...base, who: "broker" }).send, false, "not factored: no auto email to brokers");
  assert.equal(shouldAutoSendToFactor({ ...base, who: "factor_portal" }).send, false, "portal upload stays manual");
  assert.equal(shouldAutoSendToFactor({ ...base, to: " " }).send, false);
  assert.equal(shouldAutoSendToFactor({ ...base, alreadySent: true }).send, false, "never twice");
});

test("wired: issue, reissue (replacement) and POD verify try it; packet readiness re-checked; same email pipeline", () => {
  const issue = src("../../app/(app)/carrier-invoices/issuance-actions.ts");
  assert.match(issue, /after\(\(\) => autoSendFactorPacket\(invoiceId\)/);
  assert.match(issue, /if \(replacement\) after\(\(\) => autoSendFactorPacket\(replacement\)/);
  const pod = src("../../app/(app)/loads/pod-actions.ts");
  const verify = pod.slice(pod.indexOf("export async function verifyPod"), pod.indexOf("export async function rejectPod"));
  assert.match(verify, /after\(\(\) => autoSendFactorPacketsForLoad\(loadId\)/);
  const lib = src("./auto-send.ts");
  assert.match(lib, /if \(resolved\.blocked\) return \{ sent: false, reason: "packet not ready" \}/);
  assert.match(lib, /emailPurpose: "billing_packet"/);
  assert.match(lib, /entityType: "carrier_invoice"/);
  assert.match(src("../../components/carrier-invoices/carrier-billing-packet-section.tsx"), /goes to the factor automatically as soon as the packet is ready/);
});
