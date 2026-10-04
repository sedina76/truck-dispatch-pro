// Dashboard "Profit This Month" = dispatch fees (not cancelled) - approved/paid
// expenses - waived advances. A voided or unapproved expense never counts.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const kpi = readFileSync(new URL("./kpi-data.tsx", import.meta.url), "utf8");

test("only approved/paid expenses, no cancelled-dispatch fees", () => {
  assert.match(kpi, /from\("expenses"\)\.select\("amount, expense_date"\)\.in\("status", \["approved", "paid"\]\)/);
  assert.match(kpi, /const feeDispatches = dispatches\.filter\(\(d\) => d\.status !== "cancelled"\)/);
  assert.match(kpi, /sumWhere\(feeDispatches, "dispatched_at", startOfThisMonth, undefined, "dispatch_fee_amount"\)/);
});
