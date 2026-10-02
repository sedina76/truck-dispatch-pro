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
