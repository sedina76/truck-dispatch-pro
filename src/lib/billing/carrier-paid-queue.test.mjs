// One Invoices tab: "broker pays the carrier" loads are invoiced from
// Invoices -> Create Invoice (in the carrier's name), listed in the Invoices
// table, counted in Ready to Bill; there is no separate Carrier Invoices tab.
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

test("no separate Carrier Invoices tab: Billing's Invoices tab covers the carrier's invoices", () => {
  const nav = src("../../components/desktop/billing-subnav.tsx");
  assert.match(nav, /label: "Invoices", href: "\/invoices", alsoActiveFor: \["\/carrier-invoices"\]/);
  assert.ok(!/label: "Carrier Invoices"/.test(nav));
  for (const f of ["../../components/nav/nav-config.ts", "../../components/desktop/menu-bar.tsx", "../../components/nav/command-palette.tsx"]) {
    assert.ok(!/label: "Carrier Invoices"/.test(src(f)), f);
  }
  assert.match(src("../../app/(app)/carrier-invoices/page.tsx"), /redirect\("\/invoices"\)/);
  // the carrier's invoice page has the same layout as yours: Invoices > number tabs, tiles, terms, documents, billing packet
  const detail = src("../../app/(app)/carrier-invoices/[id]/page.tsx");
  assert.match(detail, /<DesktopWorkspaceTabs tabs=\{\[\{ label: "Invoices", href: "\/invoices" \}/);
  for (const part of ['label="Subtotal"', 'label="Balance Due"', "Payment Terms", "Billing Documents", "<CarrierBillingPacketSection", "Download PDF", "Billing Party"]) assert.ok(detail.includes(part), part);
  // same Billing Packet box as your invoice: checklist, status, "Generate Billing Packet" (shown, greyed out until ready)
  const packet = src("../../components/carrier-invoices/carrier-billing-packet-section.tsx");
  for (const part of ["<CardTitle>Billing Packet</CardTitle>", "Generate Billing Packet", "Download Packet", "Billing Packet Not Ready", "Rate Confirmation — Optional", "BOL — Optional"]) assert.ok(packet.includes(part), part);
  assert.ok((packet.match(/>\s*Generate Billing Packet\s*</g) ?? []).length === 2, "the button shows whether or not the packet is ready");
  // and /invoices/<id> forwards a carrier's invoice to its page
  assert.match(src("../../app/(app)/invoices/[id]/page.tsx"), /if \(carriersInvoice\) redirect\(`\/carrier-invoices\/\$\{id\}`\)/);
});

test("the Invoices list includes the carrier's invoices, marked, opening their own page, never deletable from the list", () => {
  const page = src("../../app/(app)/invoices/page.tsx");
  assert.match(page, /from\("carrier_invoices"\)/);
  assert.match(page, /\.eq\("invoice_document_type", "carrier_freight_invoice"\)/);
  assert.match(page, /Carrier&apos;s invoice/);
  assert.match(page, /row\.kind === "carrier" \? `\/carrier-invoices\/\$\{row\.id\}`/);
  assert.match(page, /row\.kind === "carrier" \? undefined : deleteRecord/);
});

test("Create Invoice for a broker-pays-carrier load goes through the reviewed draft action with the load's own carrier and broker", () => {
  const act = src("../../app/(app)/invoices/carrier-invoice-actions.ts");
  assert.match(act, /createCarrierInvoiceDraft\(/);
  assert.match(act, /carrierId: String\(load\.carrier_id\), loadIds: \[loadId\]/);
  assert.ok(!/formData\.get\("(carrier_id|broker_id|amount|rate)"\)/.test(act), "only the load id comes from the form");
  assert.match(act, /redirect\(`\/carrier-invoices\/\$\{outcome\.invoiceId\}`\)/);
});

test("Ready to Bill and the overview count broker-pays-carrier loads; billing roles only", () => {
  const ready = src("../../app/(app)/billing/ready-to-bill/page.tsx");
  assert.match(ready, /canInvoice \? await carrierPaidLoadsToInvoice\(supabase\) : \[\]/);
  const overview = src("../../app/(app)/billing/page.tsx");
  assert.match(overview, /canUseBilling\(role\)/);
  assert.match(overview, /carrierPaid\?\.toInvoiceReady/);
  assert.match(overview, /from\("carrier_fee_invoices"\)/);
});

test("issuing: one click for owner/admin on a draft, prefilled note, plain wording", () => {
  const panel = src("../../components/carrier-invoices/carrier-invoice-lifecycle-panel.tsx");
  assert.match(panel, /issueDraftCarrierInvoice\(invoiceId, updatedAt, reason, key\)/);
  assert.match(panel, /const ISSUE_REASON = "Load delivered, ready to bill"/);
  const quick = src("../../app/(app)/carrier-invoices/quick-issue-actions.ts");
  assert.match(quick, /await markCarrierInvoiceReady\(invoiceId, expectedUpdatedAt, idempotencyKey\)/);
  assert.match(quick, /issueCarrierInvoice\(invoiceId, updatedAt, reason, newWorkflowKey\(\)\)/);
  assert.ok(!/supabase\.rpc\(/.test(quick), "only the reviewed actions touch the workflow");
  const detail = src("../../app/(app)/carrier-invoices/[id]/page.tsx");
  assert.match(detail, /canIssueDraft=\{actions\.markReady && isCarrierInvoicePilotOperator\(role\)\}/);
});

test("the carrier's billing packet is saved to storage and opened by signed link (large phone photos never hit the response size cap)", () => {
  const route = src("../../app/(app)/carrier-invoices/[id]/package/route.ts");
  assert.match(route, /requireRoleForApi\(BILLING_ROLES\)/);
  assert.match(route, /storage\.from\("billing-packets"\)\.upload\(path, bytes/);
  assert.match(route, /const folder = `\$\{org\}\/carrier-invoices\/\$\{id\}`/, "org folder first: the bucket's RLS scopes by it");
  assert.match(route, /createSignedUrl\(path, 300/);
  assert.match(route, /NextResponse\.redirect\(signed\.signedUrl, 303\)/);
});
