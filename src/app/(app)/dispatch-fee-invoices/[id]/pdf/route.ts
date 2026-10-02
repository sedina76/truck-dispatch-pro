import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { requireRoleForApi, BILLING_ROLES } from "@/lib/auth/require-role";
import { renderDispatchFeeInvoicePdf, type DispatchFeeInvoicePdfSource } from "@/lib/documents/dispatch-fee-invoice-pdf";
import type { OrgRow } from "@/lib/documents/branded-pdf";

// Branded Dispatch Fee Invoice PDF (same design as the customer invoice).
// Route handlers are not wrapped by the segment layout, so the role check
// is repeated here; RLS (0165) scopes the invoice to the caller's org, so
// another org's id simply 404s.
const ORG_COLUMNS_FULL =
  "name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone, mailing_address_line1, mailing_city, mailing_state, mailing_postal_code, remittance_instructions, invoice_footer";
const ORG_COLUMNS_BASIC = "name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone";

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const denied = await requireRoleForApi(BILLING_ROLES);
  if (denied) return denied;

  const { id } = await params;
  const supabase = await createClient();
  const { data: inv } = await supabase
    .from("carrier_fee_invoices")
    .select("organization_id, invoice_number, status, issue_date, due_date, period_start, period_end, total_amount, amount_paid, balance_due, notes, carriers(legal_name, address_line1, city, state, postal_code, email)")
    .eq("id", id)
    .maybeSingle();
  if (!inv) return new NextResponse("Invoice not found.", { status: 404 });
  const row = inv as unknown as DispatchFeeInvoicePdfSource["invoice"] & { organization_id: string; carriers: DispatchFeeInvoicePdfSource["carrier"] | null };

  const fetchOrg = async (): Promise<OrgRow | null> => {
    const full = await supabase.from("organizations").select(ORG_COLUMNS_FULL).eq("id", row.organization_id).single();
    if (!full.error) return full.data as unknown as OrgRow;
    const basic = await supabase.from("organizations").select(ORG_COLUMNS_BASIC).eq("id", row.organization_id).single();
    return (basic.data ?? null) as unknown as OrgRow | null;
  };
  const [org, { data: lines, error: linesError }] = await Promise.all([
    fetchOrg(),
    supabase.from("carrier_fee_invoice_lines").select("line_type, description, amount, service_date").eq("invoice_id", id).order("sort_order").order("service_date"),
  ]);
  if (linesError) return new NextResponse("Could not load the invoice lines.", { status: 500 });

  let bytes: Uint8Array;
  try {
    bytes = await renderDispatchFeeInvoicePdf({
      invoice: row,
      carrier: row.carriers ?? { legal_name: "Carrier" },
      org,
      lines: lines ?? [],
    });
  } catch (err) {
    console.error("[dispatch-fee-invoice-pdf] could not render:", { invoice_id: id, error: err instanceof Error ? err.message : String(err) });
    return new NextResponse("Could not generate the invoice PDF.", { status: 500 });
  }

  const download = new URL(req.url).searchParams.get("download") === "1";
  const safeName = row.invoice_number.replace(/[^A-Za-z0-9-]/g, "");
  return new NextResponse(Buffer.from(bytes), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `${download ? "attachment" : "inline"}; filename="dispatch-fee-invoice-${safeName}.pdf"`,
      "Cache-Control": "private, no-store",
    },
  });
}
