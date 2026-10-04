// Settlement creation is all-or-nothing; invoice "sent" records sent_at; line-item errors surface.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const CARRIER = read("../../app/(app)/settlements/actions.ts");
const DRIVER = read("../../app/(app)/driver-settlements/actions.ts");
const INVOICE = read("../../app/(app)/invoices/actions.ts");

for (const [name, src, table, rpc] of [
  ["carrier", CARRIER, "settlement_line_items", "void_carrier_settlement"],
  ["driver", DRIVER, "driver_settlement_items", "void_driver_settlement"],
]) {
  test(`${name} settlement: payable loads inserted in ONE statement, errors never ignored`, () => {
    const fn = src.slice(src.indexOf(name === "carrier" ? "export async function createCarrierSettlement" : "export async function createDriverSettlement"));
    const body = fn.slice(0, fn.indexOf("\nexport async function", 10));
    assert.doesNotMatch(body, /for \(const row of payable/, "no per-row insert loop");
    assert.match(body, new RegExp(`from\\("${table}"\\)\\.insert\\(items\\)`));
    assert.match(body, /payableError/);
    assert.match(body, /if \(itemsError\)/);
    assert.match(body, new RegExp(`rpc\\("${rpc}"`), "half-built settlement is voided");
    assert.match(body, /throw new Error\(`Could not add the payable loads|return \{ error: [^\n]*Could not add the loads/, "a failed insert is reported, never ignored");
  });
}

test("invoice marked sent from the edit form records sent_at once", () => {
  assert.match(INVOICE, /const sentAt = values\.status === "sent" && !current\.sent_at \? new Date\(\)\.toISOString\(\) : undefined;/);
  assert.match(INVOICE, /\.\.\.\(sentAt \? \{ sent_at: sentAt \} : \{\}\)/);
});

test("adding an invoice line item surfaces database errors", () => {
  const fn = INVOICE.slice(INVOICE.indexOf("export async function addInvoiceLineItem"));
  assert.match(fn.slice(0, 900), /const \{ error \} = await supabase\.from\("invoice_line_items"\)\.insert\([\s\S]*?if \(error\) throw new Error\(error\.message\);/);
});
