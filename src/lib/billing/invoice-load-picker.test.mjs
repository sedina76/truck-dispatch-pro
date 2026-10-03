// New Invoice -> "Search a delivered load": loads are auto-invoiced on
// delivery (0022), so a delivered load usually already has an invoice.
// Searching for one must find it and link to that invoice instead of
// looking like the load doesn't exist.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const page = src("../../app/(app)/invoices/new/page.tsx");
const picker = src("../../components/invoices/load-picker.tsx");

test("the eligible-load window is applied wide enough before invoiced loads are filtered out", () => {
  assert.doesNotMatch(page, /\.limit\(100\)/);
  assert.match(page, /\.limit\(1000\)/);
  assert.match(page, /invoices!left\(id, invoice_number, status\)/);
});

test("already-invoiced delivered loads are passed to the picker with their invoice", () => {
  assert.match(page, /const alreadyInvoiced: AlreadyInvoicedLoad\[\] = allEligibleRows\s*\.filter\(\(load\) => load\.invoices\?\.length\)/);
  assert.match(page, /<LoadPicker loads=\{pickerLoads\} alreadyInvoiced=\{alreadyInvoiced\} \/>/);
});

test("searching shows matching invoiced loads under 'Already invoiced' and opens the existing invoice", () => {
  assert.match(picker, /if \(!q\) return \[\];/); // only while searching
  assert.match(picker, /l\.invoiceNumber\.toLowerCase\(\)\.includes\(q\)/);
  assert.match(picker, /<CommandGroup heading="Already invoiced -- open the existing invoice">/);
  // a carrier's invoice opens at its own address
  assert.match(picker, /router\.push\(l\.href \?\? `\/invoices\/\$\{l\.invoiceId\}`\)/);
});
