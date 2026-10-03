// "Broker pays the carrier" loads stay visible in the Billing workspace:
// the overview counts what still needs a fee invoice / carrier invoice, the
// Billing tabs include both invoice kinds, and every invoice kind shows up in
// Recent Financial Activity.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { carrierPaidQueue } from "./carrier-paid-queue.ts";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("counts loads still needing a fee invoice and a carrier invoice", () => {
  const delivered = [
    { id: "d1", load_id: "l1" },
    { id: "d2", load_id: "l2" },
    { id: "d3", load_id: "l3" },
  ];
  assert.deepEqual(carrierPaidQueue(delivered, ["d1"], ["l1", "l2"]), { needFeeInvoice: 2, needCarrierInvoice: 1 });
  assert.deepEqual(carrierPaidQueue(delivered, ["d1", "d2", "d3"], ["l1", "l2", "l3"]), { needFeeInvoice: 0, needCarrierInvoice: 0 });
  assert.deepEqual(carrierPaidQueue([], [], []), { needFeeInvoice: 0, needCarrierInvoice: 0 });
});

test("a load counts once even with two dispatches", () => {
  const delivered = [
    { id: "d1", load_id: "l1" },
    { id: "d2", load_id: "l1" },
  ];
  assert.deepEqual(carrierPaidQueue(delivered, [], []), { needFeeInvoice: 2, needCarrierInvoice: 1 });
});

test("Billing tabs include Dispatch Fee Invoices and Carrier Invoices", () => {
  const nav = src("../../components/desktop/billing-subnav.tsx");
  assert.match(nav, /label: "Dispatch Fee Invoices", href: "\/dispatch-fee-invoices"/);
  assert.match(nav, /label: "Carrier Invoices", href: "\/carrier-invoices"/);
  for (const page of ["../../app/(app)/dispatch-fee-invoices/page.tsx", "../../app/(app)/carrier-invoices/page.tsx"]) {
    assert.match(src(page), /<BillingSubnav \/>/, page);
  }
});

test("Billing Overview shows every invoice kind, but only to billing roles", () => {
  const page = src("../../app/(app)/billing/page.tsx");
  assert.match(page, /from\("carrier_fee_invoices"\)/);
  assert.match(page, /from\("carrier_invoices"\)/);
  assert.match(page, /canUseBilling\(role\)/);
  assert.match(page, /\/dispatch-fee-invoices\/\$\{/);
  assert.match(page, /\/carrier-invoices\/\$\{/);
});
