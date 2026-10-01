import { NextResponse } from "next/server";
import { requireRoleForApi, FINANCIAL_ROLES } from "@/lib/auth/require-role";
import { renderInvoiceOnlyPdf } from "@/lib/invoices/pdf";

// "Download PDF" / Print / Export target on the invoice screen and the
// load screen. Serves the same branded PDF the invoice email attaches
// (src/lib/invoices/pdf.ts -> src/lib/documents/branded-pdf.ts), so what
// the office downloads is exactly what the customer receives. Replaces the
// old browser-print HTML page that drew its own, separate layout.
//
// This route lives outside (app), so it is NOT covered by
// invoices/layout.tsx: guarded explicitly with the same FINANCIAL_ROLES tier
// as every other invoice surface (Phase 2G.7 finding). RLS still scopes the
// invoice itself -- another org's id simply 404s.
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const denied = await requireRoleForApi(FINANCIAL_ROLES);
  if (denied) return denied;

  const { id } = await params;
  let bytes: Uint8Array;
  try {
    bytes = await renderInvoiceOnlyPdf(id);
  } catch (err) {
    if (err instanceof Error && err.message === "Invoice not found.") {
      return new NextResponse("Invoice not found.", { status: 404 });
    }
    console.error("[invoice-pdf] could not render invoice PDF:", { invoice_id: id, error: err instanceof Error ? err.message : String(err) });
    return new NextResponse("Could not generate the invoice PDF.", { status: 500 });
  }

  const download = new URL(req.url).searchParams.get("download") === "1";
  return new NextResponse(Buffer.from(bytes), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `${download ? "attachment" : "inline"}; filename="invoice-${id}.pdf"`,
      "Cache-Control": "private, no-store",
    },
  });
}
