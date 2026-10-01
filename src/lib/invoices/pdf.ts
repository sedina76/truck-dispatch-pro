import "server-only";
import { createClient } from "@/lib/supabase/server";
import { renderInvoicePdf, type InvoiceSource } from "@/lib/documents/branded-pdf";
import { formatStopDateTime } from "@/lib/timezone/format";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

type Supabase = Awaited<ReturnType<typeof createClient>>;
type InvoiceRow = InvoiceSource["invoice"] & { organization_id: string; load_id: string | null; dispatch_id: string | null };

const ORG_COLUMNS_FULL =
  "name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone, mailing_address_line1, mailing_city, mailing_state, mailing_postal_code, remittance_instructions, invoice_footer";
const ORG_COLUMNS_BASIC = "name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone";

// Factoring submissions that no longer bind the invoice to the factor.
const INACTIVE_FACTORING_STATUSES = ["rejected", "cancelled"];

// Gathers everything the branded invoice layout needs, through the caller's
// own RLS-scoped session. Shared by the standalone invoice PDF (below) and
// the invoice page inside the billing packet, so the two can never drift
// apart. Optional pieces (factoring, driver/truck) degrade to "not shown"
// if the session can't read them -- they never block the invoice.
export async function loadInvoiceSource(supabase: Supabase, invoice: InvoiceRow, invoiceId: string): Promise<InvoiceSource & { orgTimezone: string | null }> {
  const fetchOrg = async () => {
    const full = await supabase.from("organizations").select(ORG_COLUMNS_FULL).eq("id", invoice.organization_id).single();
    if (!full.error) return full.data as Record<string, string | null>;
    const basic = await supabase.from("organizations").select(ORG_COLUMNS_BASIC).eq("id", invoice.organization_id).single();
    return (basic.data ?? null) as Record<string, string | null> | null;
  };

  const [org, { data: lineItems }, loadRes, dispatchRes, factoredRes] = await Promise.all([
    fetchOrg(),
    supabase.from("invoice_line_items").select("description, quantity, unit_price, line_total").eq("invoice_id", invoiceId).order("sort_order"),
    invoice.load_id
      ? supabase
          .from("loads")
          .select(
            "load_number, total_miles, equipment_type, weight_lbs, rate_confirmation_number, load_stops(stop_type, stop_sequence, facility_name, city, state, scheduled_at, timezone, reference_number)"
          )
          .eq("id", invoice.load_id)
          .single()
      : Promise.resolve({ data: null }),
    invoice.dispatch_id
      ? supabase.from("dispatches").select("drivers(first_name, last_name), trucks(unit_number)").eq("id", invoice.dispatch_id).single()
      : Promise.resolve({ data: null }),
    supabase
      .from("factored_invoices")
      .select("status, created_at, factoring_relationships(remittance_instructions), factoring_companies(name, phone, email, address_line1, city, state, postal_code)")
      .eq("invoice_id", invoiceId)
      .not("status", "in", `(${INACTIVE_FACTORING_STATUSES.join(",")})`)
      .order("created_at", { ascending: false })
      .limit(1),
  ]);

  const load = loadRes.data as unknown as {
    load_number: string;
    total_miles: number | null;
    equipment_type: string | null;
    weight_lbs: number | null;
    rate_confirmation_number: string | null;
    load_stops: NonNullable<NonNullable<InvoiceSource["load"]>["stops"]>;
  } | null;
  const dispatchInfo = dispatchRes.data as unknown as { drivers: { first_name: string; last_name: string } | null; trucks: { unit_number: string } | null } | null;
  const factored = ((factoredRes.data ?? []) as unknown as {
    factoring_relationships: { remittance_instructions: string | null } | null;
    factoring_companies: { name: string; phone: string | null; email: string | null; address_line1: string | null; city: string | null; state: string | null; postal_code: string | null } | null;
  }[])[0];
  const company = factored?.factoring_companies ?? null;

  const orgTimezone = org?.timezone ?? null;
  return {
    invoice,
    org,
    orgTimezone,
    lineItems: lineItems ?? [],
    load: load ? { ...load, stops: load.load_stops ?? [] } : null,
    driverName: dispatchInfo?.drivers ? `${dispatchInfo.drivers.first_name} ${dispatchInfo.drivers.last_name}`.trim() : null,
    truckUnit: dispatchInfo?.trucks?.unit_number ?? null,
    factoring: company
      ? {
          companyName: company.name,
          remittanceInstructions: factored?.factoring_relationships?.remittance_instructions ?? null,
          address: [company.address_line1, [company.city, company.state].filter(Boolean).join(", "), company.postal_code].filter(Boolean).join("\n") || null,
          phone: company.phone,
          email: company.email,
        }
      : null,
    formatStopTime: (iso, tz) => {
      const zone = resolveStopTimezone(tz, orgTimezone).timezone;
      // A stop saved with a date but no appointment time is stored as local
      // midnight -- print just the date instead of a misleading "12:00 AM".
      const time = formatStopDateTime(iso, zone, { timeOnly: true });
      return time.replace(/\s/g, " ").startsWith("12:00 AM")
        ? formatStopDateTime(iso, zone, { dateOnly: true, includeYear: true })
        : formatStopDateTime(iso, zone, { includeYear: true });
    },
  };
}

// Standalone invoice PDF -- used as the email attachment ONLY for the "no
// billing packet generated yet" case (/api/email/resolve's invoice case
// already allows sending then: "the plain invoice PDF is still sendable as
// long as the invoice itself isn't blocked by POD readiness"). Once a
// billing packet exists, that stored PDF is attached instead
// (src/lib/billing-packet/generate.ts) -- this function is never used to
// bypass or duplicate the packet.
//
// Same layout as the invoice page inside generateBillingPacket(): both draw
// through src/lib/documents/branded-pdf.ts.
export async function renderInvoiceOnlyPdf(invoiceId: string): Promise<Uint8Array> {
  const supabase = await createClient();
  const { data: invoice, error } = await supabase.from("invoices").select("*").eq("id", invoiceId).single();
  if (error || !invoice) throw new Error("Invoice not found.");

  return renderInvoicePdf(await loadInvoiceSource(supabase, invoice as InvoiceRow, invoiceId));
}
