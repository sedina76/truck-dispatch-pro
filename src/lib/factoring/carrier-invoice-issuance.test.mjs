// Proposal 0157 (D-57) -- EXECUTABLE tests of the application-side issuance/reissue logic (pure module, zero DB, zero network) and its contract with the SQL.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  ISSUANCE_CODE_MESSAGES, ISSUANCE_GENERIC_FAILURE, issuanceMessage, newWorkflowKey, isValidWorkflowKey, isUuid, validateIssuanceInput, lifecycleActions, issuanceConfirmationLines,
  dispatchFeeLine, driftSentence, outcomeFromWorkflow, tryBegin, DRIFT_LABELS, isCarrierInvoicePilotOperator,
} from "./carrier-invoice-issuance.ts";

const SQL = readFileSync(new URL("../../../supabase/proposals/0157/proposed_0157.sql", import.meta.url), "utf8").replace(/^\s*--.*$/gm, "");
const U1 = "10ad2000-0000-0000-0000-000000000001", U2 = "10ad2000-0000-0000-0000-000000000002", C = "a1a1a1a1-0000-0000-0000-000000000001", B = "a0b00000-0000-0000-0000-000000000001";

const FACTORED = { success: true, eligible: true, carrier_name: "Carrier A1", recipient_type: "broker", recipient_name: "Broker A", billing_mode: "factored", currency: "USD", freight_total: 1500,
  loads: [{ load_id: U1, load_number: "W-1", amount: 1000 }, { load_id: U2, load_number: "W-2", amount: 500 }],
  factoring: { factoring_company_name: "FactorA", relationship_name: "Default", advance_percentage: 80, factoring_fee_percentage: 3, reserve_percentage: 20, expected_advance_amount: 1200, factoring_fee_amount: 45, reserve_amount: 300, noa_reference: "NOA-1", submission_method: "internal_queue", remittance_instructions: "Remit to FactorA lockbox" },
  dispatch_fee: { status: "agreement_effective", estimated_total: 150, currency: "USD", fee_method: "percentage_of_freight" } };
const DIRECT = { ...FACTORED, billing_mode: "direct_billing", factoring: null, dispatch_fee: { status: "no_effective_agreement", estimated_total: null } };

test("every code the issuance/reissue SQL can return has a fixed safe message (the UI can never show 'undefined' or a database error)", () => {
  const codes = new Set([...SQL.matchAll(/'code', '([A-Z_]+)'/g)].map((m) => m[1]).concat([...SQL.matchAll(/_cif_refuse_0157\([^;]*?, '([A-Z_]{4,})', '/g)].map((m) => m[1])));
  assert.ok(codes.has("LOAD_ALREADY_INVOICED") && codes.has("SUBMISSION_EXISTS") && codes.has("STALE_INVOICE"));
  const relayed = ["GATE_ENABLED", "GATE_DISABLED", "SUBMITTED", "WITHDRAWN", "SUBMITTER_GRANTED", "SUBMITTER_REVOKED", "NOT_APPLICABLE", "DRAFT_CREATED", "MARKED_READY", "ISSUED", "REISSUED", "DRAFT_DISCARDED", "ISSUE_FAILED",
    // submission-path codes are covered by carrier-invoice-submission.test.mjs
    "FEATURE_DISABLED", "INVOICE_AMOUNT_INVALID", "DISPATCH_FEE_ON_INVOICE", "SNAPSHOT_MISSING", "SNAPSHOT_MISMATCH", "ISSUED_AS_DIRECT_BILLING", "DIRECT_BILLING", "NOT_FACTORING_ELIGIBLE", "NEGATIVE_FUNDING", "ALREADY_SUBMITTED", "RELATIONSHIP_DRIFT_REISSUE_REQUIRED", "ISSUANCE_RECORD_MISSING_REISSUE_REQUIRED"];
  const missing = [...codes].filter((c) => !ISSUANCE_CODE_MESSAGES[c] && !relayed.includes(c));
  assert.deepEqual(missing, [], `codes without a UI message: ${missing}`);
});

test("issuanceMessage prefers the RPC's own message, then the code's fixed message, then a generic one", () => {
  assert.equal(issuanceMessage({ code: "LOAD_ALREADY_INVOICED", message: "custom" }), "custom");
  assert.equal(issuanceMessage({ code: "LOAD_ALREADY_INVOICED" }), ISSUANCE_CODE_MESSAGES.LOAD_ALREADY_INVOICED);
  assert.equal(issuanceMessage({ code: "SOMETHING_NEW" }), ISSUANCE_GENERIC_FAILURE);
  assert.equal(issuanceMessage(null), ISSUANCE_GENERIC_FAILURE);
});

test("idempotency keys are per confirmation, prefixed and validated", () => {
  const a = newWorkflowKey(), b = newWorkflowKey();
  assert.notEqual(a, b);
  assert.ok(isValidWorkflowKey(a));
  for (const bad of ["", "cif-", "cif-zz", "x-1234567890", undefined, null, 42, "cif-" + "a".repeat(70)]) assert.equal(isValidWorkflowKey(bad), false, String(bad));
});

test("validateIssuanceInput: one carrier, 1-200 DISTINCT loads, a broker or customer recipient; anything else is refused before any request", () => {
  const ok = { carrierId: C, loadIds: [U1, U2], recipientType: "broker", recipientId: B };
  assert.equal(validateIssuanceInput(ok), null);
  assert.equal(validateIssuanceInput({ ...ok, recipientType: "customer" }), null);
  assert.equal(validateIssuanceInput({ ...ok, carrierId: "nope" }), "INVALID_REQUEST");
  assert.equal(validateIssuanceInput({ ...ok, recipientId: "" }), "INVALID_REQUEST");
  assert.equal(validateIssuanceInput({ ...ok, recipientType: "carrier" }), "INVALID_REQUEST");
  assert.equal(validateIssuanceInput({ ...ok, loadIds: [] }), "LOAD_SELECTION_INVALID");
  assert.equal(validateIssuanceInput({ ...ok, loadIds: [U1, U1] }), "LOAD_SELECTION_INVALID");
  assert.equal(validateIssuanceInput({ ...ok, loadIds: [U1, "x"] }), "LOAD_SELECTION_INVALID");
  assert.equal(validateIssuanceInput({ ...ok, loadIds: Array.from({ length: 201 }, (_, i) => `10ad2000-0000-0000-0000-${String(i).padStart(12, "0")}`) }), "LOAD_SELECTION_INVALID");
  assert.equal(validateIssuanceInput(null), "INVALID_REQUEST");
  assert.ok(isUuid(U1) && !isUuid("10ad2000"));
});

test("lifecycle controls: prepare = owner/admin/dispatcher; ISSUE and REISSUE = owner/admin only; accountant/driver/viewer/none get nothing; hidden controls are a convenience (the RPCs enforce)", () => {
  const draft = { issuance_status: "draft", payment_status: "unpaid", invoice_document_type: "carrier_freight_invoice" };
  const ready = { ...draft, issuance_status: "ready_for_issue" };
  const issued = { ...draft, issuance_status: "issued" };
  const o = { workflowDraft: true, hasSubmission: false };
  for (const r of ["owner", "admin", "dispatcher"]) assert.deepEqual([lifecycleActions(draft, r, o).markReady, lifecycleActions(draft, r, o).discard], [true, true], r);
  for (const r of ["owner", "admin"]) assert.deepEqual([lifecycleActions(ready, r, o).issue, lifecycleActions(issued, r, o).reissue], [true, true], r);
  assert.equal(lifecycleActions(ready, "dispatcher", o).issue, false);
  assert.equal(lifecycleActions(issued, "dispatcher", o).reissue, false);
  for (const role of ["owner", "admin", "dispatcher", "accountant", "driver", "viewer", "", null, undefined]) {
    const allowed = role === "owner" || role === "admin";
    assert.equal(isCarrierInvoicePilotOperator(role), allowed);
    assert.equal(lifecycleActions(issued, role, o).factoringPanel, allowed);
  }
  for (const r of ["accountant", "driver", "viewer", "", null, undefined]) {
    const a = lifecycleActions(ready, r, o), b = lifecycleActions(issued, r, o), c = lifecycleActions(draft, r, o);
    assert.deepEqual([a.markReady, a.discard, a.issue, b.reissue, c.markReady, c.discard], [false, false, false, false, false, false], String(r));
  }
});

test("lifecycle controls follow the STATE: no issue on a draft, no reissue once a submission exists or the invoice has a payment, no controls on a voided or dispatch-service invoice or a non-workflow draft", () => {
  const base = { issuance_status: "draft", payment_status: "unpaid", invoice_document_type: "carrier_freight_invoice" };
  const o = { workflowDraft: true, hasSubmission: false };
  assert.equal(lifecycleActions(base, "owner", o).issue, false);
  assert.equal(lifecycleActions({ ...base, issuance_status: "ready_for_issue" }, "owner", o).markReady, false);
  assert.equal(lifecycleActions({ ...base, issuance_status: "issued" }, "owner", { ...o, hasSubmission: true }).reissue, false);
  for (const ps of ["partially_paid", "paid"]) assert.equal(lifecycleActions({ ...base, issuance_status: "issued", payment_status: ps }, "owner", o).reissue, false, ps);
  assert.deepEqual(Object.values(lifecycleActions({ ...base, issuance_status: "voided" }, "owner", o)), [false, false, false, false, false]);
  assert.deepEqual(Object.values(lifecycleActions({ ...base, invoice_document_type: "dispatch_service_invoice" }, "owner", o)), [false, false, false, false, false]);
  assert.equal(lifecycleActions(base, "owner", { workflowDraft: false, hasSubmission: false }).markReady, false);
});

test("the FACTORING PANEL is offered only for a correctly ISSUED freight invoice (never draft / ready / voided / dispatch-service)", () => {
  const f = (st, dt = "carrier_freight_invoice") => lifecycleActions({ issuance_status: st, payment_status: "unpaid", invoice_document_type: dt }, "owner", { workflowDraft: true, hasSubmission: false }).factoringPanel;
  assert.equal(f("issued"), true);
  for (const st of ["draft", "ready_for_issue", "voided"]) assert.equal(f(st), false, st);
  assert.equal(f("issued", "dispatch_service_invoice"), false);
});

test("the confirmation shows carrier, broker/customer, billing mode, loads, totals, factor/routing/terms and the SEPARATE dispatch fee (factored)", () => {
  const text = issuanceConfirmationLines(FACTORED).map((l) => `${l.label}: ${l.value}`).join("\n");
  for (const need of ["Carrier: Carrier A1", "Broker (bill to): Broker A", "Billing mode (server-resolved): Factored", "W-1 (USD 1,000.00), W-2 (USD 500.00)", "Freight total: USD 1,500.00", "FactorA", "NOA-1", "Remit to FactorA lockbox", "80% / 3% / 20%", "USD 1,200.00 / USD 45.00 / USD 300.00"]) assert.ok(text.includes(need), need);
  const fee = issuanceConfirmationLines(FACTORED).find((l) => l.label.startsWith("Dispatch-service fee"));
  assert.ok(fee && /separate receivable/.test(fee.label) && /NOT part of this invoice or the factored amount/.test(fee.label) && fee.value.includes("USD 150.00"));
  assert.ok(!issuanceConfirmationLines(FACTORED).some((l) => /Freight total/.test(l.label) && l.value.includes("150.00") && !l.value.includes("1,500.00")));
});

test("direct billing: no factoring instructions are shown; a customer recipient is labelled; the dispatch fee explains why it is not billed", () => {
  const lines = issuanceConfirmationLines({ ...DIRECT, recipient_type: "customer" });
  const text = lines.map((l) => `${l.label}: ${l.value}`).join("\n");
  assert.ok(text.includes("Customer (bill to)") && text.includes("Direct billing") && text.includes("no factoring instructions"));
  assert.ok(!/Factoring company|NOA|Remit to|Advance/.test(text));
  assert.match(dispatchFeeLine(DIRECT.dispatch_fee).value, /no approved, effective dispatch-service agreement/);
  assert.match(dispatchFeeLine({ status: "currency_mismatch" }).value, /currency differs/);
  assert.equal(dispatchFeeLine(undefined).value, "--");
});

test("drift wording names every drifted dimension; a no-drift reissue says so", () => {
  assert.equal(driftSentence([]), "No change since issuance.");
  assert.equal(driftSentence(undefined), "No change since issuance.");
  const s = driftSentence(["factor", "noa", "routing", "terms", "relationship", "recipient", "billing_mode", "issuance_record_missing"]);
  for (const d of Object.values(DRIFT_LABELS)) assert.ok(s.includes(d), d);
  assert.equal(driftSentence(["mystery"]), "Changed since issuance: mystery.");
});

test("outcomeFromWorkflow: success needs success=true + invoice id + status; refusals keep the SAFE code/message; transport errors never leak the database message", () => {
  assert.deepEqual(outcomeFromWorkflow({ success: true, invoice_id: "i1", status: "draft" }, null), { ok: true, invoiceId: "i1", replacementInvoiceId: undefined, status: "draft", replay: false, updatedAt: undefined, dispatchFeeStatus: undefined });
  const r = outcomeFromWorkflow({ success: true, invoice_id: "n1", original_invoice_id: "o1", replacement_invoice_id: "n1", status: "issued", idempotent_replay: true, dispatch_fee: { status: "carried_over" }, updated_at: "2026-01-01T00:00:00Z" }, null);
  assert.ok(r.ok && r.replay && r.replacementInvoiceId === "n1" && r.dispatchFeeStatus === "carried_over" && r.updatedAt);
  const bad = outcomeFromWorkflow({ success: false, code: "LOAD_ALREADY_INVOICED" }, null);
  assert.ok(!bad.ok && bad.code === "LOAD_ALREADY_INVOICED" && bad.error === ISSUANCE_CODE_MESSAGES.LOAD_ALREADY_INVOICED);
  const t = outcomeFromWorkflow(null, { message: 'duplicate key value violates unique constraint "secret_index"' });
  assert.ok(!t.ok && t.code === "TRANSPORT" && !/secret_index|duplicate key/.test(t.error));
  assert.ok(!outcomeFromWorkflow({ success: true }, null).ok);
  assert.ok(!outcomeFromWorkflow(undefined, null).ok);
});

test("duplicate clicks: only the first tryBegin wins until the in-flight flag is cleared", () => {
  const s = { inFlight: false };
  assert.equal(tryBegin(s), true);
  assert.equal(tryBegin(s), false);
  s.inFlight = false;
  assert.equal(tryBegin(s), true);
});

test("the SQL codes the UI branches on exist (contract): drift, reissue, duplicate-billable, stale, paid/partial, submission-exists", () => {
  for (const c of ["RELATIONSHIP_DRIFT_REISSUE_REQUIRED", "LOAD_ALREADY_INVOICED", "STALE_INVOICE", "INVOICE_PAID_OR_PARTIAL", "SUBMISSION_EXISTS", "REISSUE_TOTAL_CHANGED", "INVOICE_NOT_READY", "NOT_AUTHORIZED_FOR_CARRIER"]) assert.ok(SQL.includes(`'${c}'`), c);
});
