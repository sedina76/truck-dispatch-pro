import "server-only";
import { createClient } from "@/lib/supabase/server";
import { authorityLine, renderStatementDocument } from "@/lib/documents/branded-pdf";

export type StatementPartyType = "broker" | "customer";
export type StatementKind = "open_balance" | "period" | "aging";

export type StatementParty = { id: string; company_name: string; email: string | null; address: string | null; paymentTermsDays: number | null };

export type OpenInvoiceRow = {
  id: string;
  invoice_number: string;
  load_number: string | null;
  issue_date: string;
  due_date: string | null;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  days_past_due: number;
  aging_bucket: string;
  effective_status: string;
};

export type TransactionRow = {
  txn_date: string;
  txn_type: string;
  reference: string;
  load_number: string | null;
  description: string;
  charge_amount: number;
  payment_amount: number;
  is_voided: boolean;
  running_balance: number;
};

export type AgingSummary = {
  current: number;
  bucket_1_30: number;
  bucket_31_60: number;
  bucket_61_90: number;
  bucket_90_plus: number;
  total_outstanding: number;
};

export type StatementData = {
  organization: {
    name: string;
    address: string | null;
    phone: string | null;
    email: string | null;
    authority: string | null; // "MC 123456 · USDOT 1234567"
    footer: string | null; // organizations.invoice_footer
    remitLines: string[]; // remittance instructions, else mailing address, else address
  };
  party: StatementParty;
  partyType: StatementPartyType;
  statementType: StatementKind;
  statementDate: string;
  periodStart: string | null;
  periodEnd: string | null;
  asOfDate: string;
  openingBalance: number;
  closingBalance: number;
  periodCharges: number;
  periodPayments: number;
  transactions: TransactionRow[];
  openInvoices: OpenInvoiceRow[];
  aging: AgingSummary;
  bankInstructions: { bankName: string; accountNickname: string | null; accountType: string; routingLast4: string | null; accountLast4: string | null } | null;
  includedInvoiceIds: string[];
  includedPaymentReferences: string[];
};

// Gathers everything a statement needs, entirely through the caller's own
// RLS-scoped session (no service role) and the canonical A/R/statement
// functions -- get_ar_summary/get_ar_invoices (0026) for open-balance/
// aging data, get_statement_period_summary/get_statement_transactions
// (0029) for period data. Never recomputes balance/aging math itself.
export async function computeStatementData(params: {
  partyType: StatementPartyType;
  partyId: string;
  statementType: StatementKind;
  periodStart: string | null;
  periodEnd: string | null;
  asOfDate: string;
}): Promise<StatementData> {
  const supabase = await createClient();
  const { partyType, partyId, statementType, periodStart, periodEnd, asOfDate } = params;
  const brokerId = partyType === "broker" ? partyId : null;
  const customerId = partyType === "customer" ? partyId : null;

  // Phase 2G.12: `payment_terms_days` dropped from both selects below --
  // broker_financials/customer_financials are authoritative now (2G.10/
  // 2G.12 writer cutovers). This whole path is already layout-guarded to
  // FINANCIAL_ROLES (statements/layout.tsx, or requireRoleForApi() for
  // the PDF route), so no additional role gating is needed here.
  const [{ data: partyRow, error: partyError }, { data: partyFinancials }] =
    partyType === "broker"
      ? await Promise.all([
          supabase.from("brokers").select("id, company_name, email, address_line1, city, state, postal_code").eq("id", partyId).single(),
          supabase.from("broker_financials").select("payment_terms_days").eq("broker_id", partyId).maybeSingle(),
        ])
      : await Promise.all([
          supabase.from("customers").select("id, company_name, email, billing_address_line1, city, state, postal_code").eq("id", partyId).single(),
          supabase.from("customer_financials").select("payment_terms_days").eq("customer_id", partyId).maybeSingle(),
        ]);
  if (partyError || !partyRow) throw new Error("Party not found.");

  // Branding/remittance columns are best-effort: if this database predates
  // any of them, fall back to the basic columns rather than failing the
  // statement.
  type OrgRow = {
    name: string;
    address_line1: string | null;
    city: string | null;
    state: string | null;
    postal_code: string | null;
    business_phone: string | null;
    business_email: string | null;
    mc_number?: string | null;
    dot_number?: string | null;
    mailing_address_line1?: string | null;
    mailing_city?: string | null;
    mailing_state?: string | null;
    mailing_postal_code?: string | null;
    remittance_instructions?: string | null;
    invoice_footer?: string | null;
  };
  const orgFull = await supabase
    .from("organizations")
    .select(
      "name, address_line1, city, state, postal_code, business_phone, business_email, mc_number, dot_number, mailing_address_line1, mailing_city, mailing_state, mailing_postal_code, remittance_instructions, invoice_footer"
    )
    .single();
  const orgRow = (
    orgFull.error
      ? (await supabase.from("organizations").select("name, address_line1, city, state, postal_code, business_phone, business_email").single()).data
      : orgFull.data
  ) as OrgRow | null;
  const cityLine = (city?: string | null, state?: string | null, zip?: string | null) => [[city, state].filter(Boolean).join(", "), zip].filter(Boolean).join(" ") || null;
  const remitLines = orgRow?.remittance_instructions
    ? orgRow.remittance_instructions.split(/\n/).map((l) => l.trim()).filter(Boolean).slice(0, 3)
    : orgRow?.mailing_address_line1
      ? [orgRow.mailing_address_line1, cityLine(orgRow.mailing_city, orgRow.mailing_state, orgRow.mailing_postal_code)].filter((l): l is string => Boolean(l))
      : [orgRow?.address_line1, cityLine(orgRow?.city, orgRow?.state, orgRow?.postal_code)].filter((l): l is string => Boolean(l));

  const { data: bankRows } = await supabase
    .from("organization_bank_accounts")
    .select("bank_name, account_nickname, account_type, routing_number_last4, account_number_last4, is_primary")
    .order("is_primary", { ascending: false })
    .limit(1);
  const bank = bankRows?.[0] ?? null;

  const addressField = partyType === "broker" ? (partyRow as { address_line1?: string }).address_line1 : (partyRow as { billing_address_line1?: string }).billing_address_line1;
  const party: StatementParty = {
    id: partyRow.id,
    company_name: partyRow.company_name,
    email: partyRow.email,
    address: [addressField, partyRow.city, partyRow.state, partyRow.postal_code].filter(Boolean).join(", ") || null,
    paymentTermsDays: partyFinancials?.payment_terms_days ?? null,
  };

  const includedInvoiceIds: string[] = [];
  const includedPaymentReferences: string[] = [];

  let openingBalance = 0;
  let closingBalance = 0;
  let periodCharges = 0;
  let periodPayments = 0;
  let transactions: TransactionRow[] = [];
  let openInvoices: OpenInvoiceRow[] = [];

  if (statementType === "period") {
    const { data: summary } = await supabase
      .rpc("get_statement_period_summary", { p_broker_id: brokerId, p_customer_id: customerId, p_period_start: periodStart, p_period_end: periodEnd })
      .single();
    const s = summary as { opening_balance: number; period_charges: number; period_payments: number; closing_balance: number } | null;
    openingBalance = Number(s?.opening_balance ?? 0);
    periodCharges = Number(s?.period_charges ?? 0);
    periodPayments = Number(s?.period_payments ?? 0);
    closingBalance = Number(s?.closing_balance ?? 0);

    const { data: txnRows } = await supabase.rpc("get_statement_transactions", {
      p_broker_id: brokerId,
      p_customer_id: customerId,
      p_period_start: periodStart,
      p_period_end: periodEnd,
    });
    transactions = (txnRows ?? []) as TransactionRow[];
    const invoiceNumbers = transactions.filter((t) => t.txn_type === "invoice").map((t) => t.reference);
    // get_statement_transactions() returns invoice_number/payment_number as
    // the human-readable "reference" column (what the ledger displays), not
    // the row's real id -- the snapshot must freeze actual ids, so resolve
    // them here rather than snapshotting a display string as if it were one.
    // Scoped to the same party, so this can never resolve to another
    // organization's invoice sharing a coincidentally-similar number.
    if (invoiceNumbers.length > 0) {
      const { data: invoiceIdRows } = await supabase
        .from("invoices")
        .select("id, invoice_number")
        .in("invoice_number", invoiceNumbers)
        .eq(brokerId ? "broker_id" : "customer_id", brokerId ?? customerId);
      includedInvoiceIds.push(...(invoiceIdRows ?? []).map((r) => r.id));
    }
    for (const t of transactions) {
      if (t.txn_type !== "invoice") includedPaymentReferences.push(t.reference);
    }
  } else {
    // open_balance / aging: both driven by the same canonical row source,
    // get_ar_invoices() -- differ only in presentation (aging adds the
    // bucket summary panel, computed via get_ar_summary() so it can never
    // disagree with the same numbers on the A/R page).
    const { data: invRows } = await supabase.rpc("get_ar_invoices", { p_broker_id: brokerId, p_customer_id: customerId, p_as_of_date: asOfDate });
    openInvoices = ((invRows ?? []) as OpenInvoiceRow[]).filter((r) => Number(r.balance_due) > 0);
    closingBalance = openInvoices.reduce((sum, r) => sum + Number(r.balance_due), 0);
    includedInvoiceIds.push(...openInvoices.map((r) => r.id));
  }

  const { data: arSummary } = await supabase.rpc("get_ar_summary", { p_broker_id: brokerId, p_customer_id: customerId, p_as_of_date: asOfDate }).single();
  const s = arSummary as {
    current_amount: number;
    bucket_1_30: number;
    bucket_31_60: number;
    bucket_61_90: number;
    bucket_90_plus: number;
    total_receivables: number;
  } | null;
  const aging: AgingSummary = {
    current: Number(s?.current_amount ?? 0),
    bucket_1_30: Number(s?.bucket_1_30 ?? 0),
    bucket_31_60: Number(s?.bucket_31_60 ?? 0),
    bucket_61_90: Number(s?.bucket_61_90 ?? 0),
    bucket_90_plus: Number(s?.bucket_90_plus ?? 0),
    total_outstanding: Number(s?.total_receivables ?? 0),
  };
  if (statementType !== "period") closingBalance = aging.total_outstanding;

  return {
    organization: {
      name: orgRow?.name ?? "Your Company",
      address: [orgRow?.address_line1, cityLine(orgRow?.city, orgRow?.state, orgRow?.postal_code)].filter(Boolean).join(" \u00b7 ") || null,
      phone: orgRow?.business_phone ?? null,
      email: orgRow?.business_email ?? null,
      authority: authorityLine(orgRow?.mc_number, orgRow?.dot_number),
      footer: orgRow?.invoice_footer?.trim() || null,
      remitLines,
    },
    party,
    partyType,
    statementType,
    statementDate: new Date().toISOString().slice(0, 10),
    periodStart,
    periodEnd,
    asOfDate,
    openingBalance,
    closingBalance,
    periodCharges,
    periodPayments,
    transactions,
    openInvoices,
    aging,
    bankInstructions: bank
      ? {
          bankName: bank.bank_name,
          accountNickname: bank.account_nickname,
          accountType: bank.account_type,
          routingLast4: bank.routing_number_last4,
          accountLast4: bank.account_number_last4,
        }
      : null,
    includedInvoiceIds,
    includedPaymentReferences,
  };
}

// Renders the PDF through the shared branded layout
// (src/lib/documents/branded-pdf.ts -- same header/branding as invoices).
// Never touches SSN/CDL/medical/HR/collection-note data -- this file has no
// query path to any of it (organizations/brokers/customers/invoices/
// payments/loads only).
export async function renderStatementPdf(data: StatementData, statementNumber: string): Promise<Uint8Array> {
  return renderStatementDocument(data, statementNumber);
}
