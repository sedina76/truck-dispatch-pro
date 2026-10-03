// The issued carrier-invoice snapshot names its loads "source_loads" (0146,
// schema 2). The billing packet, invoice PDF and email read "loads" -- the
// loader must map one to the other, or the packet has no documents.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { normalizeIssuedSnapshot } from "./source.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("the issued invoice loader maps the saved shape (source_loads, nested factoring)", () => {
  assert.match(src("./pdf.ts"), /const payload = normalizeIssuedSnapshot\(snap\.snapshot_payload as CarrierInvoiceSnapshot\);/);
  // exactly what issue_carrier_invoice (0146) saves -- see TEST_INVOICE_FACTORING_SETUP F7
  const saved = {
    invoice_number: "KF-1", issuer: {}, recipient: {}, total_amount: 100,
    source_loads: [{ load_id: "l1", load_number: "LD-1" }],
    factoring: { mode: "factored", company: { id: "co1", name: "Apex Funding", legal_name: "Apex Funding LLC" }, noa: { approved: true, reference: "Apex NOA" },
      submission: { method: "secure_email", destination: "ops@apex.test" }, remittance_instructions: "Apex, 1 Main St" },
  };
  const n = normalizeIssuedSnapshot(saved);
  assert.deepEqual(n.loads, [{ load_id: "l1", load_number: "LD-1" }]);
  assert.deepEqual(n.factoring, { factoring_company_id: "co1", factoring_company_legal_name: "Apex Funding LLC", remittance_instructions: "Apex, 1 Main St", noa_reference: "Apex NOA", submission_method: "secure_email", submission_destination: "ops@apex.test" });
  // a carrier that doesn't factor: no factoring block on the invoice
  assert.equal(normalizeIssuedSnapshot({ ...saved, factoring: { mode: "direct", company: null } }).factoring, null);
  assert.equal(normalizeIssuedSnapshot({ ...saved, factoring: null }).factoring, null);
});

test("a packet is refused (not silently invoice-only) when the invoice has no loads", () => {
  const pdf = src("./pdf.ts");
  assert.match(pdf, /if \(\(inv\.snapshot\.loads \?\? \[\]\)\.length === 0\) return \[/);
});

test("the database really stores them as source_loads (so this mapping stays needed)", () => {
  const sql = src("../../../supabase/migrations/0146_carrier_invoice_payments_and_balance_rollups.sql");
  assert.match(sql, /'source_loads', v_loads_payload,/);
});
