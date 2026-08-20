import "server-only";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { createClient } from "@/lib/supabase/server";

const PAGE_WIDTH = 612; // US Letter, points
const PAGE_HEIGHT = 792;
const MARGIN = 50;

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

  const { data: orgRow } = await supabase
    .from("organizations")
    .select("name, address_line1, city, state, postal_code, business_phone, business_email")
    .single();

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
      address: [orgRow?.address_line1, orgRow?.city, orgRow?.state, orgRow?.postal_code].filter(Boolean).join(", ") || null,
      phone: orgRow?.business_phone ?? null,
      email: orgRow?.business_email ?? null,
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

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

const AGING_LABELS: Record<string, string> = { current: "Current", "1_30": "1-30 Days", "31_60": "31-60 Days", "61_90": "61-90 Days", "90_plus": "90+ Days" };

// Renders the PDF. Never touches SSN/CDL/medical/HR/collection-note data --
// this file has no query path to any of it (organizations/brokers/
// customers/invoices/payments/loads only).
export async function renderStatementPdf(data: StatementData, statementNumber: string): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);

  let page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
  let y = PAGE_HEIGHT - MARGIN;

  const newPage = () => {
    page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
    y = PAGE_HEIGHT - MARGIN;
  };
  const ensureRoom = (needed: number) => {
    if (y - needed < MARGIN) newPage();
  };

  // ---- Header --------------------------------------------------------------
  page.drawText(data.organization.name, { x: MARGIN, y, size: 15, font: bold });
  page.drawText("STATEMENT", { x: PAGE_WIDTH - MARGIN - 140, y, size: 18, font: bold, color: rgb(0.1, 0.1, 0.15) });
  y -= 16;
  if (data.organization.address) {
    page.drawText(data.organization.address, { x: MARGIN, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
  }
  page.drawText(statementNumber, { x: PAGE_WIDTH - MARGIN - 140, y, size: 10, font: bold });
  y -= 13;
  const contactLine = [data.organization.phone, data.organization.email].filter(Boolean).join("  |  ");
  if (contactLine) page.drawText(contactLine, { x: MARGIN, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
  page.drawText(`Statement Date: ${new Date(data.statementDate + "T00:00:00").toLocaleDateString()}`, { x: PAGE_WIDTH - MARGIN - 200, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
  y -= 13;
  const periodLabel =
    data.statementType === "period"
      ? `Period: ${new Date(data.periodStart! + "T00:00:00").toLocaleDateString()} - ${new Date(data.periodEnd! + "T00:00:00").toLocaleDateString()}`
      : `As Of: ${new Date(data.asOfDate + "T00:00:00").toLocaleDateString()}`;
  page.drawText(periodLabel, { x: PAGE_WIDTH - MARGIN - 200, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
  y -= 26;

  page.drawText("Bill To:", { x: MARGIN, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
  y -= 13;
  page.drawText(data.party.company_name, { x: MARGIN, y, size: 12, font: bold });
  y -= 14;
  if (data.party.address) {
    page.drawText(data.party.address, { x: MARGIN, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  if (data.party.email) {
    page.drawText(data.party.email, { x: MARGIN, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  if (data.party.paymentTermsDays != null) {
    page.drawText(`Terms: Net ${data.party.paymentTermsDays}`, { x: MARGIN, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
    y -= 12;
  }
  y -= 12;

  // ---- Balance summary -------------------------------------------------------
  page.drawLine({ start: { x: MARGIN, y: y + 6 }, end: { x: PAGE_WIDTH - MARGIN, y: y + 6 }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
  if (data.statementType === "period") {
    drawSummaryRow(page, y, font, bold, "Opening Balance", money(data.openingBalance));
    y -= 15;
    drawSummaryRow(page, y, font, bold, "Charges This Period", money(data.periodCharges));
    y -= 15;
    drawSummaryRow(page, y, font, bold, "Payments This Period", `-${money(data.periodPayments)}`);
    y -= 17;
  }
  page.drawText("Closing Balance", { x: MARGIN, y, size: 12, font: bold });
  page.drawText(money(data.closingBalance), { x: PAGE_WIDTH - MARGIN - 100, y, size: 12, font: bold });
  y -= 24;

  // ---- Transaction ledger (Period) or Open Invoices (Open Balance / Aging) ---
  if (data.statementType === "period") {
    drawTableHeader(page, y, bold, ["Date", "Type", "Reference", "Load #", "Charges", "Payments", "Balance"], [MARGIN, 100, 165, 260, 330, 400, 470]);
    y -= 16;
    for (const t of data.transactions) {
      ensureRoom(16);
      if (y === PAGE_HEIGHT - MARGIN) drawTableHeader(page, y, bold, ["Date", "Type", "Reference", "Load #", "Charges", "Payments", "Balance"], [MARGIN, 100, 165, 260, 330, 400, 470]);
      const typeLabel = t.txn_type === "invoice" ? "Invoice" : t.is_voided ? "Payment (Voided)" : "Payment";
      const color = t.is_voided ? rgb(0.6, 0.6, 0.6) : rgb(0, 0, 0);
      page.drawText(new Date(t.txn_date + "T00:00:00").toLocaleDateString(), { x: MARGIN, y, size: 8.5, font, color });
      page.drawText(typeLabel, { x: 100, y, size: 8.5, font, color });
      page.drawText(t.reference, { x: 165, y, size: 8.5, font, color });
      page.drawText(t.load_number ?? "--", { x: 260, y, size: 8.5, font, color });
      page.drawText(t.charge_amount > 0 ? money(t.charge_amount) : "--", { x: 330, y, size: 8.5, font, color });
      page.drawText(t.payment_amount > 0 ? money(t.payment_amount) : t.is_voided ? "VOIDED" : "--", { x: 400, y, size: 8.5, font, color: t.is_voided ? rgb(0.7, 0.2, 0.2) : color });
      page.drawText(money(t.running_balance), { x: 470, y, size: 8.5, font: bold, color });
      y -= 14;
    }
    if (data.transactions.length === 0) {
      page.drawText("No activity during this period.", { x: MARGIN, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
      y -= 16;
    }
  } else {
    const cols = ["Invoice #", "Load #", "Invoice Date", "Due Date", "Original", "Balance", "Days Past Due", "Status"];
    const xs = [MARGIN, 95, 150, 210, 270, 330, 400, 470];
    drawTableHeader(page, y, bold, cols, xs);
    y -= 16;
    for (const inv of data.openInvoices) {
      ensureRoom(16);
      if (y === PAGE_HEIGHT - MARGIN) drawTableHeader(page, y, bold, cols, xs);
      page.drawText(inv.invoice_number, { x: MARGIN, y, size: 8.5, font });
      page.drawText(inv.load_number ?? "--", { x: 95, y, size: 8.5, font });
      page.drawText(new Date(inv.issue_date + "T00:00:00").toLocaleDateString(), { x: 150, y, size: 8.5, font });
      page.drawText(inv.due_date ? new Date(inv.due_date + "T00:00:00").toLocaleDateString() : "--", { x: 210, y, size: 8.5, font });
      page.drawText(money(inv.total_amount), { x: 270, y, size: 8.5, font });
      page.drawText(money(inv.balance_due), { x: 330, y, size: 8.5, font: bold });
      page.drawText(inv.days_past_due > 0 ? String(inv.days_past_due) : "--", { x: 400, y, size: 8.5, font });
      page.drawText(inv.effective_status.replace(/_/g, " "), { x: 470, y, size: 8, font });
      y -= 14;
    }
    if (data.openInvoices.length === 0) {
      page.drawText("No open invoices as of this date.", { x: MARGIN, y, size: 9, font, color: rgb(0.5, 0.5, 0.5) });
      y -= 16;
    }
  }

  // ---- Aging summary ---------------------------------------------------------
  ensureRoom(90);
  y -= 12;
  page.drawText("Aging Summary", { x: MARGIN, y, size: 10, font: bold });
  y -= 16;
  const bucketVals: [string, number][] = [
    [AGING_LABELS.current, data.aging.current],
    [AGING_LABELS["1_30"], data.aging.bucket_1_30],
    [AGING_LABELS["31_60"], data.aging.bucket_31_60],
    [AGING_LABELS["61_90"], data.aging.bucket_61_90],
    [AGING_LABELS["90_plus"], data.aging.bucket_90_plus],
  ];
  const bucketX = [MARGIN, MARGIN + 100, MARGIN + 200, MARGIN + 300, MARGIN + 400];
  bucketVals.forEach(([label], i) => page.drawText(label, { x: bucketX[i], y, size: 8, font, color: rgb(0.45, 0.45, 0.45) }));
  y -= 13;
  bucketVals.forEach(([, val], i) => page.drawText(money(val), { x: bucketX[i], y, size: 9.5, font: bold }));
  y -= 16;
  page.drawText(`Total Outstanding: ${money(data.aging.total_outstanding)}`, { x: MARGIN, y, size: 10, font: bold });
  y -= 22;

  // ---- Payment instructions (only if the org actually has one configured) ---
  if (data.bankInstructions) {
    ensureRoom(50);
    page.drawText("Payment Instructions", { x: MARGIN, y, size: 10, font: bold });
    y -= 14;
    const b = data.bankInstructions;
    page.drawText(`${b.bankName}${b.accountNickname ? ` (${b.accountNickname})` : ""} -- ${b.accountType}`, { x: MARGIN, y, size: 9, font });
    y -= 12;
    if (b.routingLast4 || b.accountLast4) {
      page.drawText(`Routing ...${b.routingLast4 ?? "----"}   Account ...${b.accountLast4 ?? "----"}`, { x: MARGIN, y, size: 9, font, color: rgb(0.45, 0.45, 0.45) });
      y -= 12;
    }
  }

  return pdf.save();
}

function drawSummaryRow(page: import("pdf-lib").PDFPage, y: number, font: import("pdf-lib").PDFFont, bold: import("pdf-lib").PDFFont, label: string, value: string) {
  page.drawText(label, { x: MARGIN, y, size: 9.5, font, color: rgb(0.4, 0.4, 0.4) });
  page.drawText(value, { x: PAGE_WIDTH - MARGIN - 100, y, size: 9.5, font: bold });
}

function drawTableHeader(page: import("pdf-lib").PDFPage, y: number, bold: import("pdf-lib").PDFFont, cols: string[], xs: number[]) {
  cols.forEach((c, i) => page.drawText(c, { x: xs[i], y, size: 8, font: bold, color: rgb(0.3, 0.3, 0.3) }));
  page.drawLine({ start: { x: MARGIN, y: y - 4 }, end: { x: PAGE_WIDTH - MARGIN, y: y - 4 }, thickness: 0.5, color: rgb(0.75, 0.75, 0.75) });
}
