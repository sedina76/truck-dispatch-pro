// Carrier freight invoice (the carrier's own invoice to the broker, the one
// a factor buys) -> the branded invoice layout. Built ONLY from the
// immutable issuance snapshot (0144), so the PDF always shows exactly what
// was issued even if the carrier, broker or factor changes later. Pure.
import type { InvoiceSource, OrgRow } from "@/lib/documents/branded-pdf";

type Stop = { facility_name?: string | null; city?: string | null; state?: string | null; scheduled_at?: string | null; arrived_at?: string | null } | null;

export type CarrierInvoiceSnapshot = {
  invoice_number: string;
  issued_at?: string | null;
  due_date?: string | null;
  subtotal_amount?: number | string | null;
  tax_amount?: number | string | null;
  total_amount: number | string;
  line_items?: { description: string | null; quantity: number | string | null; unit_price: number | string | null; amount: number | string | null; source_load_id?: string | null }[];
  issuer: {
    legal_name?: string | null; dba_name?: string | null; mc_number?: string | null; dot_number?: string | null;
    address_line1?: string | null; city?: string | null; state?: string | null; postal_code?: string | null;
    phone?: string | null; email?: string | null;
    remittance?: {
      remittance_name?: string | null; remittance_address_line1?: string | null; remittance_city?: string | null; remittance_state?: string | null;
      remittance_postal_code?: string | null; remittance_email?: string | null; remittance_instructions?: string | null;
    } | null;
  };
  recipient: {
    legal_name?: string | null; email?: string | null; billing_email?: string | null;
    address_line1?: string | null; address_line2?: string | null; city?: string | null; state?: string | null; postal_code?: string | null;
  };
  loads?: { load_id: string; load_number: string; origin?: Stop; destination?: Stop }[];
  /** The name the issuance snapshot actually uses for its loads (schema_version 2, 0146). */
  source_loads?: { load_id: string; load_number: string; origin?: Stop; destination?: Stop }[];
  factoring?: {
    factoring_company_legal_name?: string | null;
    remittance_instructions?: string | null;
    noa_reference?: string | null;
    submission_method?: string | null;
    submission_destination?: string | null;
  } | null;
};

export type FactorContact = { address: string | null; phone: string | null; email: string | null } | null;

function cityLine(city?: string | null, state?: string | null, zip?: string | null): string {
  return [city, [state, zip].filter(Boolean).join(" ")].filter((s) => s && String(s).trim()).join(", ");
}

function place(s: Stop): string {
  return s ? cityLine(s.city, s.state) || s.facility_name || "" : "";
}

export function carrierInvoiceSource(snap: CarrierInvoiceSnapshot, factor: FactorContact, amountPaid: number | string = 0): InvoiceSource {
  const iss = snap.issuer ?? {};
  const rem = iss.remittance ?? null;
  const org: OrgRow = {
    name: iss.dba_name?.trim() || iss.legal_name || "Carrier",
    mc_number: iss.mc_number ?? null,
    dot_number: iss.dot_number ?? null,
    business_phone: iss.phone ?? null,
    business_email: rem?.remittance_email || iss.email || null,
    address_line1: iss.address_line1 ?? null,
    city: iss.city ?? null,
    state: iss.state ?? null,
    postal_code: iss.postal_code ?? null,
    mailing_address_line1: rem?.remittance_address_line1 ?? null,
    mailing_city: rem?.remittance_city ?? null,
    mailing_state: rem?.remittance_state ?? null,
    mailing_postal_code: rem?.remittance_postal_code ?? null,
    remittance_instructions: rem?.remittance_instructions ?? null,
    invoice_footer: null,
  };
  const r = snap.recipient ?? {};
  const loads = snap.loads ?? [];
  const byLoad = new Map(loads.map((l) => [l.load_id, l]));
  const single = loads.length === 1 ? loads[0] : null;
  const lineItems = (snap.line_items ?? []).map((li) => {
    const l = li.source_load_id ? byLoad.get(li.source_load_id) : undefined;
    const lane = l ? [place(l.origin ?? null), place(l.destination ?? null)].filter(Boolean).join(" -> ") : "";
    return {
      description: l && !single ? `${li.description ?? ""}${lane ? ` (${lane})` : ""}` : li.description,
      quantity: li.quantity,
      unit_price: li.unit_price,
      line_total: li.amount,
    };
  });
  const total = Number(snap.total_amount);
  const paid = Number(amountPaid) || 0;
  const f = snap.factoring ?? null;
  return {
    invoice: {
      invoice_number: snap.invoice_number,
      issue_date: snap.issued_at ? String(snap.issued_at).slice(0, 10) : null,
      due_date: snap.due_date ?? null,
      bill_to_name: r.legal_name ?? null,
      bill_to_email: r.billing_email || r.email || null,
      bill_to_address: [[r.address_line1, r.address_line2].filter(Boolean).join(" "), cityLine(r.city, r.state, r.postal_code)].filter((s) => s && s.trim()).join("\n") || null,
      subtotal_amount: snap.subtotal_amount ?? snap.total_amount,
      tax_amount: snap.tax_amount ?? 0,
      total_amount: snap.total_amount,
      amount_paid: paid,
      balance_due: Math.round((total - paid) * 100) / 100,
      notes: f?.noa_reference ? `Notice of Assignment reference: ${f.noa_reference}` : null,
    },
    org,
    lineItems,
    load: single
      ? {
          load_number: single.load_number,
          stops: [
            ...(single.origin ? [{ stop_type: "pickup", stop_sequence: 1, facility_name: single.origin.facility_name ?? null, city: single.origin.city ?? null, state: single.origin.state ?? null, scheduled_at: single.origin.scheduled_at ?? null }] : []),
            ...(single.destination ? [{ stop_type: "delivery", stop_sequence: 2, facility_name: single.destination.facility_name ?? null, city: single.destination.city ?? null, state: single.destination.state ?? null, scheduled_at: single.destination.scheduled_at ?? null }] : []),
          ],
        }
      : null,
    factoring: f?.factoring_company_legal_name
      ? { companyName: f.factoring_company_legal_name, remittanceInstructions: f.remittance_instructions ?? null, address: factor?.address ?? null, phone: factor?.phone ?? null, email: factor?.email ?? null }
      : null,
  };
}

export type PackageSender = "dispatcher" | "carrier";

/**
 * Where the factor package goes by default:
 *  - the carrier sends it themselves -> the carrier;
 *  - we send it, carrier factors -> the factor's submission email (if it
 *    takes email), else nobody (upload on the factor's website instead);
 *  - we send it, carrier doesn't factor -> the broker's billing email.
 */
export function packageRecipient(snap: CarrierInvoiceSnapshot, sender: PackageSender, carrierEmail: string | null): { to: string; who: "carrier" | "factor" | "broker" | "factor_portal"; label: string } {
  const f = snap.factoring ?? null;
  const factorName = f?.factoring_company_legal_name ?? null;
  if (sender === "carrier") return { to: carrierEmail ?? "", who: "carrier", label: "the carrier (they submit it)" };
  if (factorName) {
    if (f?.submission_method === "secure_email" && f.submission_destination) return { to: f.submission_destination, who: "factor", label: factorName };
    return { to: "", who: "factor_portal", label: `${factorName} (upload on their website)` };
  }
  return { to: snap.recipient?.billing_email || snap.recipient?.email || "", who: "broker", label: snap.recipient?.legal_name ?? "the broker" };
}

/** Default email text for the factor package (editable in the compose dialog). */
export function packageEmailBody(a: { who: "carrier" | "factor" | "broker" | "factor_portal"; carrierName: string; invoiceNumber: string; loadNumbers: string[]; total: string; orgName: string }): string {
  const loads = a.loadNumbers.length === 1 ? `load ${a.loadNumbers[0]}` : `loads ${a.loadNumbers.join(", ")}`;
  const intro =
    a.who === "carrier"
      ? `Hello ${a.carrierName},\n\nHere is your invoice package for ${loads}: invoice ${a.invoiceNumber} with the rate confirmation, bill of lading and proof of delivery, ready to submit to your factoring company.`
      : a.who === "broker"
        ? `Hello,\n\nOn behalf of ${a.carrierName}, please find attached invoice ${a.invoiceNumber} for ${loads} with the rate confirmation, bill of lading and proof of delivery.`
        : `Hello,\n\nOn behalf of our carrier ${a.carrierName}, please find attached invoice ${a.invoiceNumber} for ${loads} with the rate confirmation, bill of lading and proof of delivery for funding.`;
  return `${intro}\n\nInvoice total: ${a.total}\n\nThank you,\n${a.orgName}`;
}
