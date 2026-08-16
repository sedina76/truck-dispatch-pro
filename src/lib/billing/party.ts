// Canonical billing-party rule, application-side. ONE place that decides
// "Broker or Customer wins" for display/prefill purposes -- Invoice New,
// Payment New, A/R, Collections, and Broker/Customer profile pages all call
// this instead of independently re-deciding it, per the same rule the
// database's own auto_generate_invoice_from_delivered_load() trigger
// enforces authoritatively at invoice-creation time
// (0022_auto_invoice_on_delivery.sql, 0028_auto_invoice_dispatch_sync_fix.sql):
//
//   1. broker_id present -> Broker is the bill-to party.
//   2. else customer_id present -> Customer is the bill-to party.
//   3. else -> no billing party on file; do not guess.
//
// This module never decides anything the database doesn't already decide
// the same way for the automatic path -- it exists so the MANUAL paths
// (New Invoice, Record Payment, profile pages) present that same rule
// consistently instead of each screen inventing its own priority.

export type BillingPartyRef = { broker_id: string | null | undefined; customer_id: string | null | undefined };

export type BillingParty =
  | { type: "broker"; id: string }
  | { type: "customer"; id: string }
  | { type: "none"; id: null };

export function getBillingParty(ref: BillingPartyRef): BillingParty {
  if (ref.broker_id) return { type: "broker", id: ref.broker_id };
  if (ref.customer_id) return { type: "customer", id: ref.customer_id };
  return { type: "none", id: null };
}

// Resolves the same rule against already-joined broker/customer rows (as
// commonly returned by a Supabase `select` with `brokers(...)`/`customers(...)`
// embeds), producing the display fields a prefillable form needs. Company
// name/email/address field names intentionally mirror brokers/customers'
// own columns (0002_parties.sql) -- see the two call sites below for the
// exact select shape expected.
export type BillingPartyCompany = {
  company_name: string;
  email: string | null;
  address_line1?: string | null;
  billing_address_line1?: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  payment_terms_days: number | null;
} | null;

export function resolveBillingPartyDisplay(
  ref: BillingPartyRef,
  broker: BillingPartyCompany,
  customer: BillingPartyCompany
): {
  party: BillingParty;
  billToName: string;
  billToEmail: string | null;
  billToAddress: string | null;
  paymentTermsDays: number | null;
} {
  const party = getBillingParty(ref);
  const company = party.type === "broker" ? broker : party.type === "customer" ? customer : null;

  if (!company) {
    return { party, billToName: "", billToEmail: null, billToAddress: null, paymentTermsDays: null };
  }

  const addressLine = party.type === "broker" ? company.address_line1 : company.billing_address_line1;
  const billToAddress =
    [addressLine, company.city, company.state, company.postal_code].filter(Boolean).join(", ") || null;

  return {
    party,
    billToName: company.company_name,
    billToEmail: company.email,
    billToAddress,
    paymentTermsDays: company.payment_terms_days,
  };
}

// Same due-date rule as the DB trigger's fallback chain (party terms -> org
// default -> 30) -- used ONLY to suggest a value in a form the user can
// still review/edit before saving. Never treated as authoritative: what
// actually gets stored is whatever the submitted form field contains,
// exactly like every other prefilled-but-editable field on these forms.
export function suggestedDueDate(
  issueDateISO: string,
  paymentTermsDays: number | null,
  orgDefaultTermsDays: number | null
): string {
  const days = paymentTermsDays ?? orgDefaultTermsDays ?? 30;
  const d = new Date(issueDateISO + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
