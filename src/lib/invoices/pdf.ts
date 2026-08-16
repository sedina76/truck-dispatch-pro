import "server-only";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";

const PAGE_WIDTH = 612; // US Letter, points
const PAGE_HEIGHT = 792;
const MARGIN = 54;

// Standalone, single-page invoice PDF -- used as the email attachment ONLY
// for the "no billing packet generated yet" case (/api/email/resolve's
// invoice case already allows sending then, per its own comment: "the
// plain invoice PDF is still sendable as long as the invoice itself isn't
// blocked by POD readiness"). Once a billing packet exists, that stored
// PDF is attached instead (src/lib/billing-packet/generate.ts) -- this
// function is never used to bypass or duplicate the packet.
//
// Same field set/layout as the invoice page drawn inside
// generateBillingPacket() (org header, bill-to, line items, totals) --
// deliberately not "a different invoice PDF", just the same content
// available standalone before a packet is generated.
export async function renderInvoiceOnlyPdf(invoiceId: string): Promise<Uint8Array> {
  const supabase = await createClient();
  const { data: invoice, error } = await supabase.from("invoices").select("*").eq("id", invoiceId).single();
  if (error || !invoice) throw new Error("Invoice not found.");

  const [{ data: org }, { data: lineItems }, loadRes] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code")
      .eq("id", invoice.organization_id)
      .single(),
    supabase.from("invoice_line_items").select("*").eq("invoice_id", invoiceId).order("sort_order"),
    invoice.load_id ? supabase.from("loads").select("load_number, total_miles").eq("id", invoice.load_id).single() : Promise.resolve({ data: null }),
  ]);
  const load = loadRes.data as unknown as { load_number: string; total_miles: number | null } | null;

  const pdf = await PDFDocument.create();
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let y = PAGE_HEIGHT - MARGIN;

  page.drawText("INVOICE", { x: MARGIN, y, size: 20, font: bold });
  page.drawText(invoice.invoice_number, { x: PAGE_WIDTH - MARGIN - 140, y, size: 12, font: bold });
  y -= 26;
  page.drawText(org?.name ?? "Your Company", { x: MARGIN, y, size: 11, font: bold });
  y -= 13;
  const orgLine = [org?.address_line1, [org?.city, org?.state, org?.postal_code].filter(Boolean).join(", ")].filter(Boolean).join(" -- ");
  if (orgLine) {
    page.drawText(orgLine, { x: MARGIN, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  const orgContact = [org?.business_phone, org?.business_email].filter(Boolean).join("  |  ");
  if (orgContact) {
    page.drawText(orgContact, { x: MARGIN, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  y -= 16;

  page.drawText("Bill To:", { x: MARGIN, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
  page.drawText("Invoice Date:", { x: 380, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
  page.drawText(new Date(invoice.issue_date + "T00:00:00").toLocaleDateString(), { x: 470, y, size: 9, font: bold });
  y -= 14;
  page.drawText(invoice.bill_to_name, { x: MARGIN, y, size: 11, font: bold });
  page.drawText("Due Date:", { x: 380, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
  page.drawText(invoice.due_date ? new Date(invoice.due_date + "T00:00:00").toLocaleDateString() : "--", { x: 470, y, size: 9, font: bold });
  y -= 14;
  if (load?.load_number) {
    page.drawText(`Load ${load.load_number}`, { x: MARGIN, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  y -= 16;

  page.drawText("Description", { x: MARGIN, y, size: 9, font: bold });
  page.drawText("Qty", { x: 360, y, size: 9, font: bold });
  page.drawText("Unit Price", { x: 420, y, size: 9, font: bold });
  page.drawText("Amount", { x: 500, y, size: 9, font: bold });
  y -= 6;
  page.drawLine({ start: { x: MARGIN, y }, end: { x: PAGE_WIDTH - MARGIN, y }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  y -= 14;
  for (const li of lineItems ?? []) {
    page.drawText(String(li.description), { x: MARGIN, y, size: 9, font });
    page.drawText(String(Number(li.quantity)), { x: 360, y, size: 9, font });
    page.drawText(`$${Number(li.unit_price).toLocaleString()}`, { x: 420, y, size: 9, font });
    page.drawText(`$${Number(li.line_total).toLocaleString()}`, { x: 500, y, size: 9, font });
    y -= 16;
  }

  y -= 8;
  page.drawLine({ start: { x: 380, y: y + 10 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 10 }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  page.drawText("Subtotal", { x: 380, y, size: 10, font, color: rgb(0.4, 0.4, 0.4) });
  page.drawText(`$${Number(invoice.subtotal_amount).toLocaleString()}`, { x: 500, y, size: 10, font });
  y -= 16;
  page.drawText("TOTAL DUE", { x: 380, y, size: 12, font: bold });
  page.drawText(`$${Number(invoice.total_amount).toLocaleString()}`, { x: 500, y, size: 12, font: bold });
  y -= 16;
  page.drawText("Balance Due", { x: 380, y, size: 10, font, color: rgb(0.4, 0.4, 0.4) });
  page.drawText(`$${Number(invoice.balance_due).toLocaleString()}`, { x: 500, y, size: 10, font: bold });

  if (load?.total_miles) {
    y -= 30;
    page.drawText(`Miles: ${Number(load.total_miles).toLocaleString()}`, { x: MARGIN, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
  }

  return pdf.save();
}
