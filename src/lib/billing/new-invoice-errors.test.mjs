// Creating a broker invoice never shows the generic "Application error"
// screen: every refusal returns to the form with the reason, and "broker
// pays the carrier" loads are not offered / explained up front.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("createInvoice redirects back with the reason instead of throwing", () => {
  const actions = src("../../app/(app)/invoices/actions.ts");
  const create = actions.slice(actions.indexOf("export async function createInvoice"), actions.indexOf("export async function updateInvoice"));
  assert.ok(!/throw new Error/.test(create), "no thrown errors in createInvoice");
  assert.match(create, /supabase\.rpc\("load_bills_broker", \{ p_load_id: values\.load_id \}\)/);
  assert.match(create, /backToNewInvoice\(error\.message, values\.load_id\)/);
  assert.match(actions, /redirect\(`\/invoices\/new\?\$\{params\.toString\(\)\}`\)/);
});

test("the new-invoice page shows the reason and handles broker-pays-carrier loads", () => {
  const page = src("../../app/(app)/invoices/new/page.tsx");
  assert.match(page, /error: saveError/);
  assert.equal((page.match(/\{errorBanner\}/g) ?? []).length, 2);
  assert.match(page, /\.eq\("proceeds_model", "carrier_paid_directly"\)/);
  assert.match(page, /if \(billsBroker === false\)/);
});
