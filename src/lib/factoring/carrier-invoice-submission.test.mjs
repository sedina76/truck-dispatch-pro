// Proposal 0157 (F-08, carrier invoices) -- EXECUTABLE tests of the application-side logic (pure module, zero DB, zero network) and its contract with the SQL.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  FACTORING_CODE_MESSAGES, REISSUE_CODES, GENERIC_FAILURE, messageForResult, canOfferSubmit, panelStateFor, newIdempotencyKey, isValidIdempotencyKey, tryBeginSubmit, outcomeFromRpc, confirmationLines,
} from "./carrier-invoice-submission.ts";
import { ISSUANCE_CODE_MESSAGES } from "./carrier-invoice-issuance.ts";

const SQL = readFileSync(new URL("../../../supabase/proposals/0157/proposed_0157.sql", import.meta.url), "utf8").replace(/^\s*--.*$/gm, "");
const sqlCodes = new Set([...SQL.matchAll(/'code', '([A-Z_]+)'/g)].map((m) => m[1]).concat([...SQL.matchAll(/_cif_refuse_0157\([^;]*?, '([A-Z_]{4,})', '/g)].map((m) => m[1])));
sqlCodes.delete("GATE_ENABLED"); sqlCodes.delete("GATE_DISABLED");

const ELIGIBLE = { success: true, eligible: true, carrier_name: "Carrier A1", invoice_number: "CI-0001", currency: "USD", invoice_total: 2000, factoring_company_name: "FactorA", relationship_name: "Default", submission_method: "secure_email", submission_destination: "ap@factor.example", advance_percentage: 80, factoring_fee_percentage: 3, reserve_percentage: 20, expected_advance_amount: 1600, factoring_fee_amount: 60, reserve_amount: 400, expected_funding_amount: 1540, noa_reference: "NOA-1" };

test("every code the SQL can return has a fixed safe fallback message (the UI can never show 'undefined' or a database error)", () => {
  assert.ok(sqlCodes.size >= 25, `found ${sqlCodes.size} codes in the SQL`);
  const missing = [...sqlCodes].filter((c) => !FACTORING_CODE_MESSAGES[c] && !ISSUANCE_CODE_MESSAGES[c] && !["SUBMITTED", "WITHDRAWN", "SUBMITTER_GRANTED", "SUBMITTER_REVOKED", "NOT_APPLICABLE", "DRAFT_CREATED", "MARKED_READY", "ISSUED", "REISSUED", "DRAFT_DISCARDED", "ISSUE_FAILED"].includes(c));
  assert.deepEqual(missing, [], `codes without a UI message: ${missing}`);
});

test("messageForResult prefers the RPC's own message, then the code's fixed message, then a generic one", () => {
  assert.equal(messageForResult({ code: "INVOICE_VOIDED", message: "custom" }), "custom");
  assert.equal(messageForResult({ code: "INVOICE_VOIDED" }), FACTORING_CODE_MESSAGES.INVOICE_VOIDED);
  assert.equal(messageForResult({ code: "SOMETHING_NEW" }), GENERIC_FAILURE);
  assert.equal(messageForResult(null), GENERIC_FAILURE);
});

test("the submit control is offered ONLY for a server-eligible preview (never on a refusal, never without success=true)", () => {
  assert.equal(canOfferSubmit(ELIGIBLE), true);
  assert.equal(canOfferSubmit({ ...ELIGIBLE, eligible: false }), false);
  assert.equal(canOfferSubmit({ ...ELIGIBLE, success: false }), false);
  assert.equal(canOfferSubmit({ success: true }), false);
  assert.equal(canOfferSubmit(null), false);
  assert.equal(canOfferSubmit(undefined), false);
});

test("panel state: hidden for a disabled feature / legacy-like or foreign or unauthorized cases; a visible refusal (with code and message) for eligibility problems; ready only when eligible", () => {
  for (const code of ["FEATURE_DISABLED", "FORBIDDEN", "NOT_FOUND", "WRONG_DOCUMENT_TYPE", "NOT_AUTHORIZED_FOR_CARRIER"]) assert.deepEqual(panelStateFor({ success: false, eligible: false, code }), { kind: "hidden" }, code);
  for (const code of ["INVOICE_PAID_OR_PARTIAL", "INVOICE_VOIDED", "INVOICE_NOT_ISSUED", "DIRECT_BILLING", "NOT_FACTORING_ELIGIBLE", "NO_ACTIVE_DEFAULT_RELATIONSHIP", "MULTIPLE_DEFAULT_RELATIONSHIPS", "ALREADY_SUBMITTED", "DISPATCH_FEE_ON_INVOICE"]) {
    const s = panelStateFor({ success: false, eligible: false, code });
    assert.equal(s.kind, "blocked", code);
    assert.equal(s.code, code);
    assert.ok(s.message.length > 10);
  }
  // D-57c / D-57d: drift, direct-billing issuance and an uncontrolled issuance are cured ONLY by the controlled reissue workflow: a distinct state, never a submit control
  for (const code of ["RELATIONSHIP_DRIFT_REISSUE_REQUIRED", "ISSUED_AS_DIRECT_BILLING", "ISSUANCE_RECORD_MISSING_REISSUE_REQUIRED"]) {
    const s = panelStateFor({ success: false, eligible: false, code, drift_dimensions: ["terms", "noa"] });
    assert.equal(s.kind, "reissue_required", code);
    assert.deepEqual(s.dimensions, ["terms", "noa"]);
    assert.ok(REISSUE_CODES.has(code));
  }
  assert.equal(canOfferSubmit({ success: false, eligible: false, code: "RELATIONSHIP_DRIFT_REISSUE_REQUIRED" }), false);
  assert.equal(panelStateFor(ELIGIBLE).kind, "ready");
  assert.equal(panelStateFor(null).kind, "hidden");
});

test("duplicate clicks: only the first tryBeginSubmit wins until the in-flight flag is cleared", () => {
  const s = { inFlight: false };
  assert.equal(tryBeginSubmit(s), true);
  assert.equal(tryBeginSubmit(s), false);
  assert.equal(tryBeginSubmit(s), false);
  s.inFlight = false;
  assert.equal(tryBeginSubmit(s), true);
});

test("idempotency keys: generated per confirmation, prefixed, validated; malformed keys are rejected before any request", () => {
  const a = newIdempotencyKey(), b = newIdempotencyKey();
  assert.notEqual(a, b);
  assert.ok(isValidIdempotencyKey(a) && isValidIdempotencyKey(b));
  for (const bad of ["", "x", "cif-", "cif-<script>", 5, null, undefined, "cif-" + "a".repeat(80)]) assert.equal(isValidIdempotencyKey(bad), false, String(bad));
  assert.ok(isValidIdempotencyKey(newIdempotencyKey(() => "12345678-1234-1234-1234-123456789012")));
});

test("outcomeFromRpc: success only with success=true + submission_id + status; transport errors never leak the raw message; refusals carry the RPC code and message", () => {
  assert.deepEqual(outcomeFromRpc({ success: true, submission_id: "s1", status: "submitted" }, null), { ok: true, submissionId: "s1", status: "submitted", replay: false });
  assert.equal(outcomeFromRpc({ success: true, submission_id: "s1", status: "submitted", idempotent_replay: true }, null).replay, true);
  const t = outcomeFromRpc(null, { message: 'permission denied for function submit_carrier_invoice_to_factor' });
  assert.equal(t.ok, false); assert.equal(t.error, GENERIC_FAILURE); assert.ok(!/permission denied|function/.test(t.error));
  const r = outcomeFromRpc({ success: false, code: "INVOICE_PAID_OR_PARTIAL", message: "A paid or partially paid invoice cannot be factored." }, null);
  assert.deepEqual(r, { ok: false, code: "INVOICE_PAID_OR_PARTIAL", error: "A paid or partially paid invoice cannot be factored." });
  assert.equal(outcomeFromRpc({ success: true }, null).ok, false);              // success without a submission id is never trusted
  assert.equal(outcomeFromRpc({}, null).ok, false);
});

test("the confirmation shows the SERVER-selected destination and terms as read-only lines (no picker / no editable value exists in the model)", () => {
  const lines = confirmationLines(ELIGIBLE);
  const text = lines.map((l) => `${l.label}: ${l.value}`).join("\n");
  assert.match(text, /Factoring company \(server-selected\): FactorA/);
  assert.match(text, /Relationship \(carrier's active default\): Default/);
  assert.match(text, /secure_email -> ap@factor.example/);
  assert.match(text, /80% \/ 3% \/ 20%/);
  assert.match(text, /Expected funding: USD 1,540.00/);
  for (const l of lines) assert.deepEqual(Object.keys(l).sort(), ["label", "value"]);
});
