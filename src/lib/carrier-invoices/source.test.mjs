// Carrier freight invoice PDF source + where its factor package goes.
import test from "node:test";
import assert from "node:assert/strict";
import { carrierInvoiceSource, packageRecipient } from "./source.ts";

const base = {
  invoice_number: "RRT-2026-00001",
  issued_at: "2026-10-01T15:00:00Z",
  due_date: "2026-10-31",
  subtotal_amount: "3500.00",
  total_amount: "3500.00",
  line_items: [
    { description: "Freight charge - Load LD-1", quantity: 1, unit_price: "2000.00", amount: "2000.00", source_load_id: "l1" },
    { description: "Freight charge - Load LD-2", quantity: 1, unit_price: "1500.00", amount: "1500.00", source_load_id: "l2" },
  ],
  issuer: { legal_name: "Road Runner Trucking LLC", dba_name: null, mc_number: "123", dot_number: "456", email: "rr@x.test", remittance: { remittance_instructions: "ACH 111/222" } },
  recipient: { legal_name: "Big Broker", email: "ops@bb.test", billing_email: "ap@bb.test", city: "Dallas", state: "TX", postal_code: "75001" },
  loads: [
    { load_id: "l1", load_number: "LD-1", origin: { city: "Austin", state: "TX" }, destination: { city: "Tulsa", state: "OK" } },
    { load_id: "l2", load_number: "LD-2", origin: { city: "Waco", state: "TX" }, destination: { city: "Reno", state: "NV" } },
  ],
  factoring: null,
};

test("carrier is the issuer, broker the bill-to; multi-load lines show lanes", () => {
  const s = carrierInvoiceSource(base, null, 500);
  assert.equal(s.org.name, "Road Runner Trucking LLC");
  assert.equal(s.org.remittance_instructions, "ACH 111/222");
  assert.equal(s.invoice.bill_to_name, "Big Broker");
  assert.equal(s.invoice.bill_to_email, "ap@bb.test");
  assert.equal(s.invoice.issue_date, "2026-10-01");
  assert.equal(s.invoice.balance_due, 3000);
  assert.equal(s.lineItems[0].description, "Freight charge - Load LD-1 (Austin, TX -> Tulsa, OK)");
  assert.equal(s.load, null);
  assert.equal(s.factoring, null);
});

test("factored: pay-to is the factor with its NOA reference; single load shows its route", () => {
  const snap = { ...base, line_items: [base.line_items[0]], loads: [base.loads[0]], total_amount: 2000, subtotal_amount: 2000,
    factoring: { factoring_company_legal_name: "Fast Factor Inc", remittance_instructions: "PO Box 9, Dallas TX", noa_reference: "NOA-77", submission_method: "secure_email", submission_destination: "submit@ff.test" } };
  const s = carrierInvoiceSource(snap, { address: null, phone: "555", email: "help@ff.test" });
  assert.equal(s.factoring.companyName, "Fast Factor Inc");
  assert.equal(s.factoring.remittanceInstructions, "PO Box 9, Dallas TX");
  assert.match(s.invoice.notes, /NOA-77/);
  assert.equal(s.load.load_number, "LD-1");
  assert.equal(s.lineItems[0].description, "Freight charge - Load LD-1");
  assert.deepEqual(packageRecipient(snap, "dispatcher", "rr@x.test"), { to: "submit@ff.test", who: "factor", label: "Fast Factor Inc" });
  assert.equal(packageRecipient({ ...snap, factoring: { ...snap.factoring, submission_method: "portal_manual" } }, "dispatcher", null).who, "factor_portal");
  assert.deepEqual(packageRecipient(snap, "carrier", "rr@x.test"), { to: "rr@x.test", who: "carrier", label: "the carrier (they submit it)" });
});

test("not factored and we send it -> the broker's billing email", () => {
  assert.deepEqual(packageRecipient(base, "dispatcher", "rr@x.test"), { to: "ap@bb.test", who: "broker", label: "Big Broker" });
});

test("package email text", async () => {
  const { packageEmailBody } = await import("./source.ts");
  const args = { carrierName: "Road Runner", invoiceNumber: "RRT-2026-00001", loadNumbers: ["LD-1"], total: "$2,000.00", orgName: "Sedina Dispatch" };
  assert.match(packageEmailBody({ ...args, who: "factor" }), /On behalf of our carrier Road Runner, please find attached invoice RRT-2026-00001 for load LD-1 .* for funding\./);
  assert.match(packageEmailBody({ ...args, who: "carrier", loadNumbers: ["LD-1", "LD-2"] }), /^Hello Road Runner,\n\nHere is your billing packet for loads LD-1, LD-2/);
  assert.match(packageEmailBody({ ...args, who: "broker" }), /On behalf of Road Runner, please find attached invoice/);
  assert.match(packageEmailBody({ ...args, who: "factor" }), /Invoice total: \$2,000\.00\n\nThank you,\nSedina Dispatch$/);
});
