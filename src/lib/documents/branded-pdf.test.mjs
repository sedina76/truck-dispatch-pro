// Branded invoice / statement / billing-packet PDFs.
// Pure layout code, so these render real PDFs from fixtures (no DB) and
// check both the decisions (who gets paid, what's on the page) and that
// nothing a user can type crashes pdf-lib's WinAnsi-only fonts.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PDFDocument } from "pdf-lib";
import {
  buildInvoiceDoc,
  drawInvoice,
  drawPacketCover,
  embedBrandFonts,
  formatDate,
  formatMoney,
  pdfSafe,
  renderInvoicePdf,
  renderStatementDocument,
  statementCards,
  termsLabel,
  PAGE_W,
  PAGE_H,
} from "./branded-pdf.ts";

const org = {
  name: "Kali Freights LLC",
  mc_number: "123456",
  dot_number: "3456789",
  business_phone: "(312) 555-0142",
  business_email: "billing@example.com",
  address_line1: "1200 W Lake St",
  city: "Chicago",
  state: "IL",
  postal_code: "60607",
};

const invoice = {
  invoice_number: "INV-1041",
  issue_date: "2026-09-24",
  due_date: "2026-10-24",
  bill_to_name: "Sample Broker Logistics LLC",
  bill_to_email: "ap@example.com",
  bill_to_address: "500 Commerce Dr\nDallas, TX 75201",
  subtotal_amount: 3063.02,
  discount_amount: 0,
  tax_amount: 0,
  total_amount: 3063.02,
  amount_paid: 0,
  balance_due: 3063.02,
  notes: null,
};

const load = {
  load_number: "LD-100041",
  total_miles: 781,
  equipment_type: "dry_van",
  weight_lbs: 38500,
  rate_confirmation_number: "RC-558213",
  stops: [
    { stop_type: "delivery", stop_sequence: 2, facility_name: "Receiver Inc.", city: "Atlanta", state: "GA", scheduled_at: "2026-09-23T18:30:00Z", timezone: "America/New_York", reference_number: "BOL-77410" },
    { stop_type: "pickup", stop_sequence: 1, facility_name: "Shipper Co.", city: "Dallas", state: "TX", scheduled_at: "2026-09-22T13:00:00Z", timezone: "America/Chicago", reference_number: "PO-30915" },
  ],
};

const base = {
  invoice,
  org,
  lineItems: [
    { description: "Line haul", quantity: 1, unit_price: 2450, line_total: 2450 },
    { description: "Fuel surcharge", quantity: 781, unit_price: 0.42, line_total: 328.02 },
  ],
  load,
  driverName: "Marcus Hill",
  truckUnit: "12",
};

const factoring = {
  companyName: "Apex Capital Factoring",
  remittanceInstructions: "PO Box 961029\nFort Worth, TX 76161",
  address: null,
  phone: "(800) 555-0199",
  email: "verify@example.com",
};

async function pageCount(bytes) {
  return (await PDFDocument.load(bytes)).getPageCount();
}

test("pdfSafe folds Intl's narrow no-break space and never leaves un-encodable characters", () => {
  assert.equal(pdfSafe("8:00 AM"), "8:00 AM");
  assert.equal(pdfSafe("Dallas → Atlanta"), "Dallas -> Atlanta");
  assert.equal(pdfSafe("Detention \u{1F600} ok"), "Detention  ok");
  assert.equal(pdfSafe("Café — “quoted”"), "Café — “quoted”");
  assert.equal(pdfSafe("東京"), "??");
  assert.equal(pdfSafe(null), "");
});

test("money, dates and terms format the way the invoice shows them", () => {
  assert.equal(formatMoney(3063.02), "$3,063.02");
  assert.equal(formatMoney(-500), "-$500.00");
  assert.equal(formatMoney("2450", { symbol: false }), "2,450.00");
  // calendar dates are never shifted by the server's timezone
  assert.equal(formatDate("2026-10-01"), "Oct 1, 2026");
  assert.equal(formatDate(null), "--");
  assert.equal(termsLabel("2026-09-24", "2026-10-24"), "Net 30");
  assert.equal(termsLabel("2026-09-24", "2026-09-24"), "Due on receipt");
  assert.equal(termsLabel("2026-09-24", null), null);
});

test("direct invoice: payment goes to the carrier, no notice of assignment", () => {
  const doc = buildInvoiceDoc(base);
  assert.equal(doc.remitTo.name, "Kali Freights LLC");
  assert.deepEqual(doc.remitTo.lines, ["1200 W Lake St", "Chicago, IL 60607", "Ref: INV-1041"]);
  assert.equal(doc.noa, null);
  assert.equal(doc.org.authority, "MC 123456 · USDOT 3456789");
  assert.deepEqual(
    doc.grid.map(([l, v]) => [l, v]),
    [
      ["Invoice #", "INV-1041"],
      ["Invoice date", "Sep 24, 2026"],
      ["Due date", "Oct 24, 2026"],
      ["Terms", "Net 30"],
      ["Load #", "LD-100041"],
    ]
  );
  assert.equal(doc.totalDue, "$3,063.02");
});

test("explicit remittance instructions win over the address for direct payment", () => {
  const doc = buildInvoiceDoc({ ...base, org: { ...org, remittance_instructions: "Lockbox 77\nChicago, IL 60690", mailing_address_line1: "PO Box 1" } });
  assert.deepEqual(doc.remitTo.lines, ["Lockbox 77", "Chicago, IL 60690", "Ref: INV-1041"]);
  const mail = buildInvoiceDoc({ ...base, org: { ...org, mailing_address_line1: "PO Box 1", mailing_city: "Chicago", mailing_state: "IL", mailing_postal_code: "60690" } });
  assert.deepEqual(mail.remitTo.lines, ["PO Box 1", "Chicago, IL 60690", "Ref: INV-1041"]);
});

test("factored invoice: remit to the factor and print the notice of assignment", () => {
  const doc = buildInvoiceDoc({ ...base, factoring });
  assert.equal(doc.remitTo.name, "Apex Capital Factoring");
  assert.deepEqual(doc.remitTo.lines, ["PO Box 961029", "Fort Worth, TX 76161", "Ref: Kali Freights LLC"]);
  assert.ok(doc.noa);
  assert.match(doc.noa.body, /must be paid only to Apex Capital Factoring, PO Box 961029, Fort Worth, TX 76161\./);
  assert.match(doc.noa.body, /\(800\) 555-0199/);
});

test("references, route and totals come from the load and invoice", () => {
  const doc = buildInvoiceDoc({ ...base, invoice: { ...invoice, discount_amount: 63.02, tax_amount: 10, total_amount: 3010, amount_paid: 1000, balance_due: 2010 } });
  assert.deepEqual(doc.references, [
    ["Rate con", "RC-558213"],
    ["Pickup #", "PO-30915"],
    ["Delivery #", "BOL-77410"],
    ["Driver", "Marcus Hill"],
    ["Truck", "Unit 12"],
  ]);
  // stops are ordered by stop_sequence, not by row order
  assert.equal(doc.route.pickup.name, "Shipper Co.");
  assert.equal(doc.route.delivery.name, "Receiver Inc.");
  assert.equal(doc.route.middleTop, "781 mi");
  assert.equal(doc.route.middleBottom, "Dry Van · 38,500 lb");
  assert.deepEqual(doc.totals, [
    ["Subtotal", "$3,063.02"],
    ["Discount", "-$63.02"],
    ["Tax", "$10.00"],
    ["Invoice total", "$3,010.00"],
    ["Payments & credits", "-$1,000.00"],
  ]);
  assert.equal(doc.totalDue, "$2,010.00");
});

test("an invoice with no load still renders (no route strip, no references)", async () => {
  const doc = buildInvoiceDoc({ ...base, load: null, driverName: null, truckUnit: null });
  assert.equal(doc.route, null);
  assert.deepEqual(doc.references, []);
  assert.equal(await pageCount(await renderInvoicePdf({ ...base, load: null })), 1);
});

test("hostile text (emoji, CJK, U+202F, very long words) never crashes the invoice", async () => {
  const nasty = "Detention \u{1F69A} 東京 8:00 AM " + "X".repeat(300);
  const bytes = await renderInvoicePdf({
    ...base,
    invoice: { ...invoice, bill_to_name: nasty, notes: nasty, bill_to_address: nasty },
    org: { ...org, name: nasty },
    lineItems: [{ description: nasty, quantity: 1, unit_price: 1, line_total: 1 }],
    factoring: { ...factoring, companyName: nasty },
    formatStopTime: () => "Sep 22, 2026, 8:00 AM CDT",
  });
  assert.equal(await pageCount(bytes), 1);
});

test("a long list of charges continues onto more pages instead of running off the page", async () => {
  const lineItems = Array.from({ length: 45 }, (_, i) => ({ description: `Accessorial ${i + 1} with a description long enough to wrap onto a second line in the column`, quantity: 1, unit_price: 10, line_total: 10 }));
  const pdf = await PDFDocument.create();
  const pages = drawInvoice(buildInvoiceDoc({ ...base, lineItems, factoring }), await embedBrandFonts(pdf), () => pdf.addPage([PAGE_W, PAGE_H]));
  assert.ok(pages.length >= 3, `expected >= 3 pages, got ${pages.length}`);
  assert.equal(pdf.getPageCount(), pages.length);
});

test("packet cover lists included and skipped documents", async () => {
  const pdf = await PDFDocument.create();
  const fonts = await embedBrandFonts(pdf);
  const doc = buildInvoiceDoc({ ...base, documentsIncluded: ["Proof of Delivery (Verified)"] });
  assert.deepEqual(doc.documentsIncluded, ["Proof of Delivery (Verified)"]);
  drawPacketCover(pdf.addPage([PAGE_W, PAGE_H]), doc, fonts, ["Invoice", "Proof of Delivery (Verified)"], [{ label: "Bill of Lading", filename: "bol \u{1F4C4}.pdf", reason: "could not parse the PDF" }]);
  assert.equal(await pageCount(await pdf.save()), 1);
});

const statement = {
  organization: { name: "Kali Freights LLC", address: "1200 W Lake St · Chicago, IL 60607", phone: "(312) 555-0142", email: "billing@example.com", authority: "MC 123456", footer: null, remitLines: ["PO Box 1", "Chicago, IL 60690"] },
  party: { company_name: "Sample Broker Logistics LLC", email: "ap@example.com", address: "500 Commerce Dr, Dallas, TX", paymentTermsDays: 30 },
  statementType: "open_balance",
  statementDate: "2026-10-01",
  periodStart: null,
  periodEnd: null,
  asOfDate: "2026-10-01",
  openingBalance: 0,
  closingBalance: 5410,
  periodCharges: 0,
  periodPayments: 0,
  transactions: [],
  openInvoices: [
    { invoice_number: "INV-1041", load_number: "LD-1", issue_date: "2026-09-24", due_date: "2026-10-24", total_amount: 3000, amount_paid: 0, balance_due: 3000, days_past_due: 0 },
    { invoice_number: "INV-1002", load_number: null, issue_date: "2026-07-02", due_date: "2026-08-01", total_amount: 3010, amount_paid: 600, balance_due: 2410, days_past_due: 61 },
  ],
  aging: { current: 3000, bucket_1_30: 0, bucket_31_60: 0, bucket_61_90: 2410, bucket_90_plus: 0, total_outstanding: 5410 },
  bankInstructions: { bankName: "Chase", accountNickname: null, accountType: "checking", routingLast4: "0021", accountLast4: "4417" },
};

test("statement summary cards: invoiced, paid, balance with the past-due part", () => {
  const cards = statementCards(statement);
  assert.deepEqual(
    cards.map((c) => [c.label, c.value, c.sub]),
    [
      ["Total invoiced", "$6,010.00", "2 open invoices"],
      ["Payments", "$600.00", "Applied to 1 invoice"],
      ["Balance due", "$5,410.00", "$2,410.00 past due"],
    ]
  );
});

test("statements render for every type, including empty and multi-page ledgers", async () => {
  assert.equal(await pageCount(await renderStatementDocument(statement, "ST-1")), 1);
  assert.equal(await pageCount(await renderStatementDocument({ ...statement, statementType: "aging", openInvoices: [], closingBalance: 0, aging: { current: 0, bucket_1_30: 0, bucket_31_60: 0, bucket_61_90: 0, bucket_90_plus: 0, total_outstanding: 0 } }, "ST-2")), 1);
  const transactions = Array.from({ length: 60 }, (_, i) => ({ txn_date: "2026-09-01", txn_type: i % 2 ? "invoice" : "payment", reference: `R-${i}`, load_number: null, charge_amount: i % 2 ? 100 : 0, payment_amount: i % 2 ? 0 : 50, is_voided: i === 4, running_balance: i * 50 }));
  const period = { ...statement, statementType: "period", periodStart: "2026-09-01", periodEnd: "2026-09-30", transactions };
  assert.ok((await pageCount(await renderStatementDocument(period, "ST-3"))) >= 2);
  // a statement without the newer org fields (older callers) still renders
  const legacyOrg = { name: "Kali Freights LLC", address: null, phone: null, email: null };
  assert.equal(await pageCount(await renderStatementDocument({ ...statement, organization: legacyOrg, bankInstructions: null }, "ST-4")), 1);
});

// ---- wiring: the app's three generators all go through this layout -------------

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("standalone invoice PDF and billing packet share one data loader and one layout", () => {
  const pdf = src("../invoices/pdf.ts");
  assert.match(pdf, /export async function loadInvoiceSource/);
  assert.match(pdf, /return renderInvoicePdf\(await loadInvoiceSource\(/);
  // rejected/cancelled factoring submissions must not redirect payment to the factor
  assert.match(pdf, /INACTIVE_FACTORING_STATUSES = \["rejected", "cancelled"\]/);
  assert.match(pdf, /\.not\("status", "in"/);

  const packet = src("../billing-packet/generate.ts");
  assert.match(packet, /loadInvoiceSource\(supabase, invoice, invoiceId\)/);
  assert.match(packet, /packet\.insertPage\(0, \[PAGE_W, PAGE_H\]\)/);
  assert.match(packet, /drawPacketCover\(cover, invoiceDoc, fonts, includedLabels, skippedDocuments\)/);
  assert.match(packet, /drawInvoice\(invoiceDoc, fonts, \(\) => packet\.insertPage\(insertAt\+\+/);
  assert.doesNotMatch(packet, /StandardFonts/);
});

test("statement PDF renders through the branded layout", () => {
  const gen = src("../statements/generate.ts");
  assert.match(gen, /return renderStatementDocument\(data, statementNumber\)/);
  assert.doesNotMatch(gen, /StandardFonts/);
});

test("the invoice screen's Download PDF / Print button serves the branded PDF", () => {
  const route = src("../../app/invoices/[id]/pdf/route.ts");
  assert.match(route, /requireRoleForApi\(FINANCIAL_ROLES\)/);
  assert.match(route, /await renderInvoiceOnlyPdf\(id\)/);
  assert.match(route, /"Content-Type": "application\/pdf"/);
});

test("MC / USDOT numbers never print their prefix twice", async () => {
  const { authorityLine } = await import("./branded-pdf.ts");
  assert.equal(authorityLine("MC-778812", "DOT-2934821"), "MC 778812 · USDOT 2934821");
  assert.equal(authorityLine("mc 778812", "USDOT 2934821"), "MC 778812 · USDOT 2934821");
  assert.equal(authorityLine("778812", null), "MC 778812");
  assert.equal(authorityLine(" ", ""), null);
});

test("PDFs use the design's IBM Plex Sans + Mono fonts (shipped unmodified, with the OFL license)", async () => {
  const pdf = await PDFDocument.create();
  const fonts = await embedBrandFonts(pdf);
  assert.equal(fonts.plex, true);
  for (const k of ["reg", "med", "semi", "bold", "mono", "monoMed"]) assert.ok(fonts[k], k);
  const license = src("./fonts/OFL-LICENSE.txt");
  assert.match(license, /SIL Open Font License, Version 1\.1/);
  // file tracing ships the font files with every server function on Vercel
  assert.match(src("../../../next.config.ts"), /outputFileTracingIncludes:[\s\S]*src\/lib\/documents\/fonts\/\*\.woff/);
});

test("stops saved with a date only print the date, not 12:00 AM", () => {
  const pdf = src("../invoices/pdf.ts");
  assert.match(pdf, /startsWith\("12:00 AM"\)/);
  assert.match(pdf, /dateOnly: true, includeYear: true/);
});
