// Every billing screen tells the same story:
//  - "Broker pays us": your invoice to the broker, carrier paid on a settlement.
//  - "Broker pays the carrier": the carrier's invoice (Billing -> Invoices),
//    your fee on a Dispatch Fee Invoice, factoring on the carrier's invoice.
//  - The merged PDF is a "billing packet" everywhere.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const root = new URL("../../", import.meta.url).pathname;
const src = (p) => readFileSync(join(root, p), "utf8");

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.(tsx?|mjs)$/.test(name) && !name.endsWith(".test.mjs")) out.push(p);
  }
  return out;
}
// user-facing strings only: drop line comments and block comments
const strip = (s) => s.replace(/^\s*\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");

test("no user-facing 'invoice package' / 'factor package' / 'the package is not ready' wording", () => {
  const bad = [];
  for (const f of walk(root)) {
    if (f.includes("/setup-packages/") || f.includes("/settings/factoring/")) continue;
    const s = strip(readFileSync(f, "utf8"));
    if (/invoice package|factor package|package is not ready|email them the package|download the package/i.test(s)) bad.push(f.replace(root, ""));
  }
  assert.deepEqual(bad, []);
});

test("nothing links to the removed Carrier Invoices list or old Factoring workspace", () => {
  const bad = [];
  for (const f of walk(root)) {
    const s = strip(readFileSync(f, "utf8"));
    if (/href[=:]\s*\{?["'`]\/carrier-invoices["'`]|href[=:]\s*\{?["'`]\/factoring["'`?]|href[=:]\s*\{?["'`]\/carrier-invoices\/new/.test(s)) bad.push(f.replace(root, ""));
  }
  assert.deepEqual(bad, []);
});

test("the load page shows the carrier's invoice and fee status for 'broker pays the carrier' loads", () => {
  const page = src("app/(app)/loads/[id]/page.tsx");
  assert.match(page, /carrierPaidBillingForLoad\(supabase, id\)/);
  assert.match(page, /data-testid="carrier-paid-billing"/);
  assert.match(page, /Your dispatch fee/);
  assert.match(page, /The broker pays the carrier for this load, so the next step is the carrier's invoice\./);
});

test("factor submission only shows for carriers that factor; your invoices show factoring only for older records", () => {
  assert.match(src("app/(app)/carrier-invoices/[id]/page.tsx"), /\{factors && <>\{actions\.factoringPanel \? <CarrierInvoiceFactoringPanel/);
  assert.match(src("app/(app)/invoices/[id]/page.tsx"), /\{activeFactoredInvoice && <FactoringSection/);
});

test("settlements and dispatch fee invoices say which loads they cover", () => {
  assert.match(src("app/(app)/settlements/new/page.tsx"), /Only "Broker pays us" loads are settled here/);
  assert.match(src("app/(app)/dispatch-fee-invoices/page.tsx"), /&quot;Broker pays the carrier&quot; load/);
});
