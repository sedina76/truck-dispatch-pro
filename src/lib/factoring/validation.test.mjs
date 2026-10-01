// Billing & Submission and Approve-NOA form validation -- pure, zero DB.
// Mirrors 0136's factoring_relationships_submission_email_present CHECK and
// approve_factoring_relationship_noa's (0140) own input rules.

import test from "node:test";
import assert from "node:assert/strict";
import { validateSubmissionSetup, validateNoaApproval } from "./validation.ts";

const base = { remittance_instructions: "Remit to ABC Factoring", remittance_reference: "", submission_method: "portal_manual", submission_destination_email: "", submission_notes: "" };

test("valid portal setup trims and nulls empties", () => {
  const r = validateSubmissionSetup({ ...base, remittance_instructions: "  Remit to ABC  " }, null);
  assert.equal(r.ok, true);
  assert.deepEqual(r.values, { remittance_instructions: "Remit to ABC", remittance_reference: null, submission_method: "portal_manual", submission_destination_email: null, submission_notes: null });
});

test("secure_email requires a valid destination email (mirrors the DB CHECK)", () => {
  assert.equal(validateSubmissionSetup({ ...base, submission_method: "secure_email" }, null).ok, false);
  assert.equal(validateSubmissionSetup({ ...base, submission_method: "secure_email", submission_destination_email: "not-an-email" }, null).ok, false);
  const ok = validateSubmissionSetup({ ...base, submission_method: "secure_email", submission_destination_email: "invoices@abcfactor.com" }, null);
  assert.equal(ok.ok, true);
  assert.equal(ok.values.submission_destination_email, "invoices@abcfactor.com");
});

test("destination email is cleared when the method is not secure_email", () => {
  const r = validateSubmissionSetup({ ...base, submission_destination_email: "stale@x.com" }, null);
  assert.equal(r.values.submission_destination_email, null);
});

test("api cannot be chosen here, but an existing api method is kept", () => {
  assert.equal(validateSubmissionSetup({ ...base, submission_method: "api" }, "secure_email").ok, false);
  assert.equal(validateSubmissionSetup({ ...base, submission_method: "api" }, "api").values.submission_method, "api");
});

test("unknown method is rejected; empty method is allowed (null)", () => {
  assert.equal(validateSubmissionSetup({ ...base, submission_method: "fax" }, null).ok, false);
  assert.equal(validateSubmissionSetup({ ...base, submission_method: "" }, null).values.submission_method, null);
});

test("over-long remittance is rejected", () => {
  assert.equal(validateSubmissionSetup({ ...base, remittance_instructions: "x".repeat(2001) }, null).ok, false);
});

test("NOA approval needs reference, date, and template text or a document", () => {
  const good = { noa_reference: "ABC NOA v1", noa_effective_date: "2026-10-01", noa_template_text: "Pay ABC Factoring...", noa_document_id: "" };
  assert.deepEqual(validateNoaApproval(good), { ok: true, values: { reference: "ABC NOA v1", effectiveDate: "2026-10-01", templateText: "Pay ABC Factoring...", documentId: null } });
  assert.equal(validateNoaApproval({ ...good, noa_reference: " " }).ok, false);
  assert.equal(validateNoaApproval({ ...good, noa_effective_date: "" }).ok, false);
  assert.equal(validateNoaApproval({ ...good, noa_template_text: "" }).ok, false);
  assert.equal(validateNoaApproval({ ...good, noa_template_text: "", noa_document_id: "11111111-1111-1111-1111-111111111111" }).ok, true);
});
