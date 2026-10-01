// Factoring setup readiness checklist -- pure logic, zero DB.
// Mirrors the exact conditions set_default_factoring_relationship (0138) and
// set_carrier_factoring_policy (0139) enforce.

import test from "node:test";
import assert from "node:assert/strict";
import { relationshipReadinessSteps, canBecomeDefault, isFullyReady, notReadyMessage } from "./readiness.ts";

const TODAY = "2026-10-01";
const complete = {
  is_default: true,
  is_active: true,
  effective_from: "2026-01-01",
  effective_to: null,
  remittance_instructions: "Remit to ABC Factoring, PO Box 1",
  noa_approved: true,
  submission_method: "secure_email",
};
const missing = (rel, companyActive = true) => relationshipReadinessSteps(rel, companyActive, TODAY).filter((s) => !s.done).map((s) => s.key);

test("a complete default relationship is fully ready", () => {
  const steps = relationshipReadinessSteps(complete, true, TODAY);
  assert.deepEqual(missing(complete), []);
  assert.equal(isFullyReady(steps), true);
  assert.equal(canBecomeDefault(steps), true);
});

test("the live KALI FR. case: inactive, not default, no remittance/NOA/submission", () => {
  const rel = { is_default: false, is_active: false, effective_from: "2026-07-01", effective_to: null, remittance_instructions: null, noa_approved: false, submission_method: null };
  assert.deepEqual(missing(rel), ["active", "remittance", "submission_method", "noa", "default"]);
  assert.equal(canBecomeDefault(relationshipReadinessSteps(rel, true, TODAY)), false);
});

test("steps come back in the order they must be done; default is always last", () => {
  const keys = relationshipReadinessSteps(complete, true, TODAY).map((s) => s.key);
  assert.deepEqual(keys, ["active", "company_active", "dates", "remittance", "submission_method", "noa", "default"]);
});

test("whitespace-only remittance does not count (matches btrim(...) <> '')", () => {
  assert.deepEqual(missing({ ...complete, remittance_instructions: "   " }), ["remittance"]);
});

test("everything but default done -> can become default, not yet fully ready", () => {
  const steps = relationshipReadinessSteps({ ...complete, is_default: false }, true, TODAY);
  assert.equal(canBecomeDefault(steps), true);
  assert.equal(isFullyReady(steps), false);
});

test("an inactive default is not counted as the default", () => {
  assert.deepEqual(missing({ ...complete, is_active: false }), ["active", "default"]);
});

test("inactive factoring company blocks readiness", () => {
  assert.deepEqual(missing(complete, false), ["company_active"]);
});

test("future start date and past end date both block, with a date-specific fix", () => {
  const future = relationshipReadinessSteps({ ...complete, effective_from: "2026-12-01" }, true, TODAY).find((s) => s.key === "dates");
  assert.equal(future.done, false);
  assert.match(future.fix, /2026-12-01/);
  const ended = relationshipReadinessSteps({ ...complete, effective_to: "2026-09-30" }, true, TODAY).find((s) => s.key === "dates");
  assert.equal(ended.done, false);
  assert.match(ended.fix, /2026-09-30/);
  assert.equal(relationshipReadinessSteps({ ...complete, effective_to: TODAY }, true, TODAY).find((s) => s.key === "dates").done, true);
});

test("not-ready message names the carrier, the closest relationship, and every missing item", () => {
  const rel = { is_default: false, is_active: false, effective_from: "2026-07-01", effective_to: null, remittance_instructions: null, noa_approved: false, submission_method: null };
  const better = { ...rel, is_active: true, remittance_instructions: "x" };
  const msg = notReadyMessage("KALI FR.", [
    { name: "standard", steps: relationshipReadinessSteps(rel, true, TODAY), isDefault: false, isActive: false },
    { name: "Standard Recourse", steps: relationshipReadinessSteps(better, true, TODAY), isDefault: false, isActive: true },
  ]);
  assert.match(msg, /^KALI FR\. can't be switched to Factored yet\./);
  assert.match(msg, /"Standard Recourse"/);
  assert.match(msg, /still needs: a submission method, an approved Notice of Assignment, to be set as the default\./);
  assert.doesNotMatch(msg, /classify_carrier_factoring_readiness/);
});

test("not-ready message when the carrier has no relationship at all", () => {
  assert.match(notReadyMessage("KALI FR.", []), /has no factoring relationship yet/);
});
