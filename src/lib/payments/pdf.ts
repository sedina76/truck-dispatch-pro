import "server-only";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";

const PAGE_WIDTH = 612; // US Letter, points
const PAGE_HEIGHT = 792;
const MARGIN = 54;

// Same field set as the existing browser-print view
// (src/app/payments/[id]/receipt/page.tsx): company, receipt # (the
// payment_number), invoice #, load #, bill-to, payment date/method/
// reference, amount received, remaining balance. No SSN/CDL/medical/HR
// data -- this query has no path to any of it (payments/invoices/loads/
// organizations only), same as the print page it mirrors.
export async function renderReceiptPdf(paymentId: string): Promise<Uint8Array> {
  const supabase = await createClient();

  const { data: payment, error } = await supabase
    .from("payments")
    .select("id, payment_number, amount, method, reference_number, check_number, bank_reference, received_at, status, invoice_id")
    .eq("id", paymentId)
    .single();
  if (error || !payment) throw new Error("Payment not found.");

  const { data: invoice } = await supabase
    .from("invoices")
    .select("invoice_number, bill_to_name, balance_due, organization_id, load_id")
    .eq("id", payment.invoice_id)
    .single();
  if (!invoice) throw new Error("Invoice not found for this payment.");

  const [{ data: org }, { data: load }] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code")
      .eq("id", invoice.organization_id)
      .single(),
    invoice.load_id ? supabase.from("loads").select("load_number").eq("id", invoice.load_id).single() : Promise.resolve({ data: null }),
  ]);

  const pdf = await PDFDocument.create();
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let y = PAGE_HEIGHT - MARGIN;

  page.drawText(org?.name ?? "Your Company", { x: MARGIN, y, size: 15, font: bold });
  page.drawText("RECEIPT", { x: PAGE_WIDTH - MARGIN - 140, y, size: 20, font: bold, color: rgb(0.1, 0.1, 0.15) });
  y -= 15;
  const orgLine = [org?.address_line1, [org?.city, org?.state, org?.postal_code].filter(Boolean).join(", "), org?.business_phone].filter(Boolean).join(" -- ");
  if (orgLine) page.drawText(orgLine, { x: MARGIN, y, size: 8.5, font, color: rgb(0.45, 0.45, 0.45) });
  page.drawText(payment.payment_number, { x: PAGE_WIDTH - MARGIN - 140, y, size: 10, font: bold });
  y -= 13;
  page.drawText(new Date(payment.received_at).toLocaleDateString(), { x: PAGE_WIDTH - MARGIN - 140, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
  if (payment.status === "voided") {
    y -= 13;
    page.drawText("VOIDED -- not valid", { x: PAGE_WIDTH - MARGIN - 140, y, size: 9, font: bold, color: rgb(0.75, 0.15, 0.15) });
  }
  y -= 30;

  page.drawText("Received From:", { x: MARGIN, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
  page.drawText("Applied To:", { x: 340, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
  y -= 14;
  page.drawText(invoice.bill_to_name, { x: MARGIN, y, size: 11, font: bold });
  page.drawText(`Invoice #: ${invoice.invoice_number}`, { x: 340, y, size: 9, font });
  y -= 13;
  if (load?.load_number) page.drawText(`Load #: ${load.load_number}`, { x: 340, y, size: 9, font });
  y -= 24;

  const row = (label: string, value: string) => {
    page.drawText(label, { x: MARGIN, y, size: 9.5, font, color: rgb(0.4, 0.4, 0.4) });
    page.drawText(value, { x: 400, y, size: 9.5, font: bold });
    y -= 16;
  };
  row("Payment Date", new Date(payment.received_at).toLocaleDateString());
  row("Payment Method", String(payment.method).replace(/_/g, " "));
  if (payment.reference_number) row("Reference / Confirmation #", payment.reference_number);
  if (payment.check_number) row("Check #", payment.check_number);
  if (payment.bank_reference) row("Bank Reference", payment.bank_reference);

  y -= 10;
  page.drawLine({ start: { x: 320, y: y + 12 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 12 }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  page.drawText("Amount Received", { x: 320, y, size: 12, font: bold });
  page.drawText(`$${Number(payment.amount).toLocaleString(undefined, { minimumFractionDigits: 2 })}`, { x: 480, y, size: 12, font: bold });
  y -= 16;
  page.drawText("Remaining Balance", { x: 320, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
  page.drawText(`$${Number(invoice.balance_due).toLocaleString(undefined, { minimumFractionDigits: 2 })}`, { x: 480, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });

  y -= 40;
  page.drawText("Thank you for your payment.", { x: MARGIN, y, size: 9.5, font, color: rgb(0.5, 0.5, 0.5) });

  return pdf.save();
}
