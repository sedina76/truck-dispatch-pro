// "Reserve Still Due" -- what the factor still owes from the reserve.
import test from "node:test";
import assert from "node:assert/strict";
import { reserveStillDue } from "./reserve.ts";

const base = { invoiceFaceValue: 1000, factoringFeeAmount: 30, otherFees: 0, reserveAmount: 100 };

test("fee deducted from reserve: $70 due, and $0 once $70 is released (not a phantom $30)", () => {
  const fi = { ...base, actualFundedAmount: 900, expectedFundingAmount: 900 };
  assert.equal(reserveStillDue({ ...fi, reserveReleasedAmount: 0 }), 70);
  assert.equal(reserveStillDue({ ...fi, reserveReleasedAmount: 50 }), 20);
  assert.equal(reserveStillDue({ ...fi, reserveReleasedAmount: 70 }), 0);
});

test("fee deducted at funding: the full $100 reserve is due", () => {
  const fi = { ...base, actualFundedAmount: 870, expectedFundingAmount: 870 };
  assert.equal(reserveStillDue({ ...fi, reserveReleasedAmount: 0 }), 100);
  assert.equal(reserveStillDue({ ...fi, reserveReleasedAmount: 100 }), 0);
});

test("never more than what's left of the reserve, never negative, cent-exact", () => {
  assert.equal(reserveStillDue({ ...base, actualFundedAmount: 500, expectedFundingAmount: 900, reserveReleasedAmount: 0 }), 100);
  assert.equal(reserveStillDue({ ...base, actualFundedAmount: 990, expectedFundingAmount: 900, reserveReleasedAmount: 0 }), 0);
  assert.equal(reserveStillDue({ invoiceFaceValue: 1234.56, factoringFeeAmount: 37.04, otherFees: 0, reserveAmount: 123.46, actualFundedAmount: 1111.1, expectedFundingAmount: 1111.1, reserveReleasedAmount: 0.1 }), 86.32);
});

test("before funding, the expected funding amount is used", () => {
  assert.equal(reserveStillDue({ ...base, actualFundedAmount: null, expectedFundingAmount: 900, reserveReleasedAmount: 0 }), 70);
});

test("invoice screen uses 'Reserve Still Due' for the button, the stat and the release dialog", async () => {
  const { readFileSync } = await import("node:fs");
  const ui = readFileSync(new URL("../../components/invoices/factoring-section.tsx", import.meta.url), "utf8");
  assert.match(ui, /const reserveDue = reserveStillDue\(fi\);/);
  assert.match(ui, /label="Reserve Still Due" value=\{fmtMoney\(reserveDue\)\}/);
  assert.match(ui, /fi\.customerPaidFactorAt != null && reserveDue > 0/);
  assert.match(ui, /outstandingReserve=\{reserveDue\}/);
  assert.match(ui, /if \(parsed > invoiceFaceValue\)/);
});
