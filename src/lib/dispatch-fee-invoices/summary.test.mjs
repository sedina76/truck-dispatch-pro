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

test("flags loads that changed after billing", async () => {
  const { feeLineIssues } = await import("./summary.ts");
  const lines = [
    { id: "a", line_type: "dispatch_fee", amount: "800.00", dispatch_id: "d1", load_number: "L1", voided: false },
    { id: "b", line_type: "dispatch_fee", amount: 200, dispatch_id: "d2", load_number: "L2", voided: false },
    { id: "c", line_type: "advance", amount: 50, dispatch_id: null, load_number: null, voided: false },
    { id: "d", line_type: "dispatch_fee", amount: 100, dispatch_id: "d3", load_number: "L3", voided: false },
  ];
  const cur = new Map([
    ["d1", { fee: 900, dispatchStatus: "delivered", loadStatus: "delivered" }],
    ["d2", { fee: 200, dispatchStatus: "cancelled", loadStatus: "booked" }],
    ["d3", { fee: 100, dispatchStatus: "completed", loadStatus: "invoiced" }],
  ]);
  const sent = feeLineIssues("sent", lines, cur);
  assert.deepEqual(sent.map((i) => i.lineId), ["a", "b"]);
  assert.match(sent[0].message, /Billed \$800\.00, the fee is now \$900\.00/);
  assert.match(sent[1].message, /L2 was cancelled/);
  // drafts follow the fee themselves: only the cancellation is flagged
  assert.deepEqual(feeLineIssues("draft", lines, cur).map((i) => i.lineId), ["b"]);
  assert.deepEqual(feeLineIssues("void", lines, cur), []);
});
