// Dispatch Fee Invoices (dispatch company -> carrier): small pure helpers
// shared by the screens and their tests. The database (0165) owns every
// amount; these only group and label what it returns.

export type FeeLineType = "dispatch_fee" | "advance" | "fuel" | "maintenance";

export const FEE_LINE_TYPES: FeeLineType[] = ["dispatch_fee", "advance", "fuel", "maintenance"];

const LABELS: Record<FeeLineType, string> = {
  dispatch_fee: "Dispatch fees",
  advance: "Advances paid for the carrier",
  fuel: "Fuel paid for the carrier",
  maintenance: "Repairs paid for the carrier",
};

export function feeLineTypeLabel(type: string): string {
  return LABELS[type as FeeLineType] ?? type;
}

export type FeeLineLike = { line_type: string; amount: number | string };

/** Cents-exact totals per line type plus the grand total, in display order. */
export function summarizeFeeLines(lines: FeeLineLike[]): { groups: { type: FeeLineType; label: string; count: number; total: number }[]; total: number } {
  const cents = new Map<FeeLineType, { count: number; cents: number }>();
  let all = 0;
  for (const l of lines) {
    const c = Math.round(Number(l.amount) * 100);
    if (!Number.isFinite(c)) continue;
    all += c;
    const t = l.line_type as FeeLineType;
    const g = cents.get(t) ?? { count: 0, cents: 0 };
    g.count += 1;
    g.cents += c;
    cents.set(t, g);
  }
  const groups = FEE_LINE_TYPES.filter((t) => cents.has(t)).map((t) => ({ type: t, label: LABELS[t], count: cents.get(t)!.count, total: cents.get(t)!.cents / 100 }));
  return { groups, total: all / 100 };
}

function iso(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

/** Default billing period: the last 7 days ending today (local date). */
export function defaultFeePeriod(today: Date = new Date()): { start: string; end: string } {
  const start = new Date(today);
  start.setDate(start.getDate() - 6);
  return { start: iso(start), end: iso(today) };
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** Validates a period from a form or URL; returns an error message or null. */
export function feePeriodError(start: string | null | undefined, end: string | null | undefined): string | null {
  if (!start || !end) return "Pick a period start and end.";
  if (!ISO_DATE.test(start) || !ISO_DATE.test(end) || Number.isNaN(Date.parse(start)) || Number.isNaN(Date.parse(end))) return "Enter valid dates.";
  if (end < start) return "The period end must be on or after its start.";
  return null;
}

/** Who can be billed what: status rules mirrored from the database for button visibility only. */
export function feeInvoiceActions(status: string, balanceDue: number, postedPayments: number) {
  return {
    canRemoveLines: status === "draft",
    canSend: status === "draft",
    canRecordPayment: (status === "sent" || status === "partially_paid") && balanceDue > 0,
    canVoid: status !== "void" && postedPayments === 0,
  };
}

export type FeeLineCurrent = { fee: number; dispatchStatus: string; loadStatus: string | null };
export type FeeLineForCheck = { id: string; line_type: string; amount: number | string; dispatch_id: string | null; load_number: string | null; voided: boolean };

/**
 * Lines whose load changed after billing: the load or dispatch was
 * cancelled, or (once the invoice is sent -- drafts follow the fee on their
 * own) the dispatch fee no longer matches what was billed.
 */
export function feeLineIssues(invoiceStatus: string, lines: FeeLineForCheck[], current: Map<string, FeeLineCurrent>): { lineId: string; message: string }[] {
  if (invoiceStatus === "void") return [];
  const out: { lineId: string; message: string }[] = [];
  for (const l of lines) {
    if (l.voided || l.line_type !== "dispatch_fee" || !l.dispatch_id) continue;
    const c = current.get(l.dispatch_id);
    const load = l.load_number ?? "this load";
    if (!c) continue;
    if (c.dispatchStatus === "cancelled" || c.loadStatus === "cancelled") {
      out.push({ lineId: l.id, message: `Load ${load} was cancelled after it was billed.` });
      continue;
    }
    const billed = Math.round(Number(l.amount) * 100);
    const now = Math.round(Number(c.fee) * 100);
    if (invoiceStatus !== "draft" && billed !== now) {
      out.push({ lineId: l.id, message: `Load ${load}: the rate changed after this invoice was sent. Billed $${(billed / 100).toFixed(2)}, the fee is now $${(now / 100).toFixed(2)}.` });
    }
  }
  return out;
}

/** Default email text sent with a Dispatch Fee Invoice (editable in the compose dialog). */
export function dispatchFeeInvoiceEmailBody(a: { carrierName: string | null; invoiceNumber: string; periodLabel: string; balanceDue: string; dueDate: string; orgName: string }): string {
  return `Hello${a.carrierName ? ` ${a.carrierName}` : ""},\n\nPlease find attached Dispatch Fee Invoice ${a.invoiceNumber} for loads delivered ${a.periodLabel}: our dispatch fees plus any advances, fuel or repairs we paid for you.\n\nAmount due: ${a.balanceDue}${a.dueDate ? `\nDue date: ${a.dueDate}` : ""}\n\nPlease include ${a.invoiceNumber} with your payment.\n\nThank you,\n${a.orgName}`;
}
