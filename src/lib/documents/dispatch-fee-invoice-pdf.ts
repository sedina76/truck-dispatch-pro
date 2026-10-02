// Dispatch Fee Invoice (dispatch company -> carrier) as a branded PDF, in
// the same design as the customer invoice (branded-pdf.ts). Pure: the
// route loads the rows, this lays them out.
import { PDFDocument } from "pdf-lib";
import { buildInvoiceDoc, drawInvoice, embedBrandFonts, formatDate, pdfSafe, PAGE_H, PAGE_W, type InvoiceDoc, type OrgRow } from "./branded-pdf";

export type DispatchFeeInvoiceLine = { line_type: string; description: string; amount: number | string; service_date: string | null };

export type DispatchFeeInvoicePdfSource = {
  invoice: {
    invoice_number: string;
    status: string;
    issue_date: string | null;
    due_date: string | null;
    period_start: string;
    period_end: string;
    total_amount: number | string;
    amount_paid: number | string;
    balance_due: number | string;
    notes: string | null;
  };
  carrier: { legal_name: string; address_line1?: string | null; city?: string | null; state?: string | null; postal_code?: string | null; email?: string | null };
  org: OrgRow | null;
  lines: DispatchFeeInvoiceLine[];
};

const TYPE_LABEL: Record<string, string> = { dispatch_fee: "Dispatch fees", advance: "Advances paid for you", fuel: "Fuel paid for you", maintenance: "Repairs paid for you" };
const TYPE_ORDER = ["dispatch_fee", "advance", "fuel", "maintenance"];

export function dispatchFeeLineGroupLabel(type: string): string {
  return TYPE_LABEL[type] ?? type;
}

export function buildDispatchFeeInvoiceDoc(src: DispatchFeeInvoicePdfSource): InvoiceDoc {
  const c = src.carrier;
  const cityLine = [c.city, [c.state, c.postal_code].filter(Boolean).join(" ")].filter((s) => s && String(s).trim()).join(", ");
  const sorted = [...src.lines].sort((a, b) => TYPE_ORDER.indexOf(a.line_type) - TYPE_ORDER.indexOf(b.line_type));
  const doc = buildInvoiceDoc({
    invoice: {
      invoice_number: src.invoice.invoice_number,
      issue_date: src.invoice.issue_date,
      due_date: src.invoice.due_date,
      bill_to_name: c.legal_name,
      bill_to_email: c.email ?? null,
      bill_to_address: [c.address_line1, cityLine].filter((s) => s && String(s).trim()).join("\n") || null,
      subtotal_amount: src.invoice.total_amount,
      total_amount: src.invoice.total_amount,
      amount_paid: src.invoice.amount_paid,
      balance_due: src.invoice.balance_due,
      notes: src.invoice.notes,
    },
    org: src.org,
    lineItems: sorted.map((l) => ({
      // fuel/repair descriptions already carry their date
      description: l.service_date && (l.line_type === "dispatch_fee" || l.line_type === "advance") ? `${l.description} -- ${formatDate(l.service_date)}` : l.description,
      quantity: 1,
      unit_price: l.amount,
      line_total: l.amount,
    })),
    load: null,
  });
  const loads = src.lines.filter((l) => l.line_type === "dispatch_fee").length;
  doc.grid.splice(1, 0, ["Period", `${formatDate(src.invoice.period_start)} - ${formatDate(src.invoice.period_end)}`]);
  if (src.invoice.status === "draft") doc.grid.unshift(["Status", "DRAFT", "strong"]);
  if (src.invoice.status === "void") doc.grid.unshift(["Status", "VOID", "strong"]);
  doc.references = [["Loads", String(loads)], ["Items", String(src.lines.length)]];
  doc.footerReminder = `Please include ${src.invoice.invoice_number} with your payment.`;
  // the customer-invoice default footer talks about rate confirmations
  if (!doc.org.footer) doc.org.footer = "Questions about this invoice? Reply to the email it came with or call us.";
  return doc;
}

export async function renderDispatchFeeInvoicePdf(src: DispatchFeeInvoicePdfSource): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const fonts = await embedBrandFonts(pdf);
  drawInvoice(buildDispatchFeeInvoiceDoc(src), fonts, () => pdf.addPage([PAGE_W, PAGE_H]));
  pdf.setTitle(pdfSafe(`Dispatch Fee Invoice ${src.invoice.invoice_number}`));
  return pdf.save();
}
