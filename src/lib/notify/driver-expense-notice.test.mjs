// A driver's expense (fuel, lumper, toll, ...) reaches the office right away:
// a bell notification + chime that opens the expense to approve, and the
// Expenses page shows who submitted it and what is waiting for approval.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { driverExpenseNotice } from "./document-notice.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("bell text", () => {
  assert.deepEqual(driverExpenseNotice("fuel", 85, "LD-000001", "Ali Salah", "Pilot Flying J"), {
    title: "Fuel expense $85.00 -- Load LD-000001",
    body: "Ali Salah submitted it (Pilot Flying J). Check the receipt and approve it.",
  });
  assert.equal(driverExpenseNotice("lumper", 1250.5, null, null, null).title, "Lumper expense $1,250.50 -- a load");
  assert.equal(driverExpenseNotice("lumper", 10, null, null, null).body, "The driver submitted it. Check the receipt and approve it.");
});

test("wired: submit notifies, bell and chime open the expense, Expenses page shows it", () => {
  const actions = src("../../app/driver-portal/actions.ts");
  const submit = actions.slice(actions.indexOf("export async function submitDriverExpense"), actions.indexOf("export async function uploadDriverExpenseReceipt"));
  assert.match(submit, /await notifyOfficeOfDriverExpense\(supabase, \{/);
  assert.match(submit, /revalidatePath\("\/expenses"\)/);
  assert.match(src("./office-notify.ts"), /entity_type: "expense" as const,\s+entity_id: p\.expenseId/);
  assert.match(src("../../components/nav/notifications-menu.tsx"), /n\.entity_type === "expense" && n\.entity_id \? \(\s+\/\/[^\n]*\n\s+<Link\s+key=\{n\.id\}\s+href=\{`\/expenses\/\$\{n\.entity_id\}`\}/);
  assert.match(src("../../app/(app)/dispatch/message-alert-actions.ts"), /row\.entity_type === "expense" \? `\/expenses\/\$\{row\.entity_id\}`/);
  const page = src("../../app/(app)/expenses/page.tsx");
  assert.match(page, /if \(status === "pending"\) query = query\.in\("status", \["draft", "submitted"\]\)/);
  assert.match(page, /href="\/expenses\?status=pending"/);
  assert.match(page, /\(driver app\)/);
});
