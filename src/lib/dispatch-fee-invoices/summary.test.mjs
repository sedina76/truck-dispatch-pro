// Dispatch Fee Invoice helpers: cents-exact grouping, period checks and
// which buttons show for each status (the database enforces the same rules).
import test from "node:test";
import assert from "node:assert/strict";
import { defaultFeePeriod, feeInvoiceActions, feeLineTypeLabel, feePeriodError, summarizeFeeLines } from "./summary.ts";

test("groups lines in fixed order with cents-exact totals", () => {
  const s = summarizeFeeLines([
    { line_type: "fuel", amount: "100.10" },
    { line_type: "dispatch_fee", amount: 0.1 },
    { line_type: "dispatch_fee", amount: 0.2 },
    { line_type: "advance", amount: 250 },
    { line_type: "maintenance", amount: "1549.60" },
  ]);
  assert.deepEqual(s.groups.map((g) => g.type), ["dispatch_fee", "advance", "fuel", "maintenance"]);
  assert.equal(s.groups[0].total, 0.3); // not 0.30000000000000004
  assert.equal(s.groups[0].count, 2);
  assert.equal(s.total, 1900);
  assert.deepEqual(summarizeFeeLines([]), { groups: [], total: 0 });
  assert.equal(feeLineTypeLabel("maintenance"), "Repairs paid for the carrier");
});

test("period validation", () => {
  assert.equal(feePeriodError("2026-09-01", "2026-09-07"), null);
  assert.equal(feePeriodError("2026-09-07", "2026-09-07"), null);
  assert.match(feePeriodError("2026-09-08", "2026-09-07"), /on or after/);
  assert.match(feePeriodError("", "2026-09-07"), /Pick/);
  assert.match(feePeriodError("09/01/2026", "2026-09-07"), /valid/);
  const p = defaultFeePeriod(new Date(2026, 0, 3));
  assert.deepEqual(p, { start: "2025-12-28", end: "2026-01-03" });
});

test("buttons follow the invoice status", () => {
  assert.deepEqual(feeInvoiceActions("draft", 100, 0), { canRemoveLines: true, canSend: true, canRecordPayment: false, canVoid: true });
  assert.deepEqual(feeInvoiceActions("sent", 100, 0), { canRemoveLines: false, canSend: false, canRecordPayment: true, canVoid: true });
  assert.equal(feeInvoiceActions("partially_paid", 40, 1).canVoid, false);
  assert.equal(feeInvoiceActions("paid", 0, 1).canRecordPayment, false);
  assert.deepEqual(feeInvoiceActions("void", 0, 0), { canRemoveLines: false, canSend: false, canRecordPayment: false, canVoid: false });
});
