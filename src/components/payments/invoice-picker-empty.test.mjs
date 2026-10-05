// Record Payment: an empty invoice list explains why (drafts not sent yet,
// carrier's invoices paid on their own page) instead of a bare "none".
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("empty list shows drafts and carrier's invoices with links", () => {
  const ui = src("./invoice-picker.tsx");
  assert.match(ui, /<CommandEmpty>\{invoices\.length === 0 \? <EmptyHelp hints=\{hints\} \/> :/);
  assert.match(ui, /href=\{`\/invoices\/\$\{d\.id\}`\}/);
  assert.match(ui, /href=\{`\/carrier-invoices\/\$\{c\.id\}`\}/);
  const page = src("../../app/(app)/payments/new/page.tsx");
  assert.match(page, /\.eq\("status", "draft"\)/);
  assert.match(page, /\.eq\("issuance_status", "issued"\)/);
  assert.match(page, /<InvoicePicker invoices=\{pickerInvoices\} hints=\{pickerHints\} \/>/);
  // the payable list itself is unchanged
  assert.match(page, /\.in\("status", \["sent", "viewed", "overdue", "partially_paid"\]\)/);
});
