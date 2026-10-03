// The issued carrier-invoice snapshot names its loads "source_loads" (0146,
// schema 2). The billing packet, invoice PDF and email read "loads" -- the
// loader must map one to the other, or the packet has no documents.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("the issued invoice loader maps source_loads to loads", () => {
  const pdf = src("./pdf.ts");
  assert.match(pdf, /const payload = \{ \.\.\.raw, loads: raw\.loads \?\? raw\.source_loads \?\? \[\] \};/);
});

test("a packet is refused (not silently invoice-only) when the invoice has no loads", () => {
  const pdf = src("./pdf.ts");
  assert.match(pdf, /if \(\(inv\.snapshot\.loads \?\? \[\]\)\.length === 0\) return \[/);
});

test("the database really stores them as source_loads (so this mapping stays needed)", () => {
  const sql = src("../../../supabase/migrations/0146_carrier_invoice_payments_and_balance_rollups.sql");
  assert.match(sql, /'source_loads', v_loads_payload,/);
});
