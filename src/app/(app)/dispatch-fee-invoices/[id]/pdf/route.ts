import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { requireRoleForApi, BILLING_ROLES } from "@/lib/auth/require-role";
import { renderDispatchFeeInvoicePdfById } from "@/lib/dispatch-fee-invoices/pdf";

// Branded Dispatch Fee Invoice PDF -- the same file the carrier email
// attaches. Route handlers are not wrapped by the segment layout, so the
// role check is repeated here; RLS (0165) scopes the invoice to the
// caller's org, so another org's id simply 404s.
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const denied = await requireRoleForApi(BILLING_ROLES);
  if (denied) return denied;

  const { id } = await params;
  const supabase = await createClient();
  let pdf: Awaited<ReturnType<typeof renderDispatchFeeInvoicePdfById>>;
  try {
    pdf = await renderDispatchFeeInvoicePdfById(supabase, id);
  } catch (err) {
    console.error("[dispatch-fee-invoice-pdf] could not render:", { invoice_id: id, error: err instanceof Error ? err.message : String(err) });
    return new NextResponse("Could not generate the invoice PDF.", { status: 500 });
  }
  if (!pdf) return new NextResponse("Invoice not found.", { status: 404 });

  const download = new URL(req.url).searchParams.get("download") === "1";
  const safeName = pdf.invoiceNumber.replace(/[^A-Za-z0-9-]/g, "");
  return new NextResponse(Buffer.from(pdf.bytes), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `${download ? "attachment" : "inline"}; filename="dispatch-fee-invoice-${safeName}.pdf"`,
      "Cache-Control": "private, no-store",
    },
  });
}
