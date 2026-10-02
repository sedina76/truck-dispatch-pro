import "server-only";
import { createClient } from "@/lib/supabase/server";
import { renderDispatchFeeInvoicePdf, type DispatchFeeInvoicePdfSource } from "@/lib/documents/dispatch-fee-invoice-pdf";
import type { OrgRow } from "@/lib/documents/branded-pdf";

type Supabase = Awaited<ReturnType<typeof createClient>>;

const ORG_COLUMNS_FULL =
  "name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone, mailing_address_line1, mailing_city, mailing_state, mailing_postal_code, remittance_instructions, invoice_footer";
const ORG_COLUMNS_BASIC = "name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone";

/**
 * The branded Dispatch Fee Invoice PDF, read through the caller's own
 * RLS-scoped session (billing roles only; another org's id is "not found").
 * Shared by the PDF download route and the email attachment, so what the
 * office downloads is exactly what the carrier receives.
 */
export async function renderDispatchFeeInvoicePdfById(supabase: Supabase, id: string): Promise<{ bytes: Uint8Array; invoiceNumber: string } | null> {
  const { data: inv } = await supabase
    .from("carrier_fee_invoices")
    .select("organization_id, invoice_number, status, issue_date, due_date, period_start, period_end, total_amount, amount_paid, balance_due, notes, carriers(legal_name, address_line1, city, state, postal_code, email)")
    .eq("id", id)
    .maybeSingle();
  if (!inv) return null;
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
  if (linesError) throw new Error("Could not load the invoice lines.");

  const bytes = await renderDispatchFeeInvoicePdf({ invoice: row, carrier: row.carriers ?? { legal_name: "Carrier" }, org, lines: lines ?? [] });
  return { bytes, invoiceNumber: row.invoice_number };
}
