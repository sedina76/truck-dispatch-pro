// Mirrors public.invoice_effective_status() exactly (0026_accounts_receivable.sql).
// "Overdue" is never stored in invoices.status -- no cron/trigger ever
// writes it, so it can't go stale from a job not running. It's derived
// here, and in the DB function of the same name, from due_date + balance
// on every read. Any page showing an invoice's status for a human should
// go through this (or the SQL function, via get_ar_invoices/get_ar_summary)
// rather than rendering the raw stored status directly, or "overdue" will
// never show up there.
export type InvoiceStatus = "draft" | "sent" | "viewed" | "partially_paid" | "paid" | "overdue" | "void" | "disputed";

const NEVER_OVERRIDDEN = new Set(["paid", "void", "disputed", "draft"]);

export function invoiceEffectiveStatus(
  status: string,
  dueDate: string | null,
  balanceDue: number,
  asOf: Date = new Date()
): InvoiceStatus {
  if (NEVER_OVERRIDDEN.has(status)) return status as InvoiceStatus;
  if (dueDate) {
    const due = new Date(dueDate + "T00:00:00");
    const today = new Date(asOf.getFullYear(), asOf.getMonth(), asOf.getDate());
    if (due < today && balanceDue > 0) return "overdue";
  }
  return status as InvoiceStatus;
}

export const AGING_BUCKETS = ["current", "1_30", "31_60", "61_90", "90_plus"] as const;

export const AGING_BUCKET_LABELS: Record<string, string> = {
  current: "Current",
  "1_30": "1-30 Days",
  "31_60": "31-60 Days",
  "61_90": "61-90 Days",
  "90_plus": "90+ Days",
};

export const AGING_BUCKET_COLORS: Record<string, string> = {
  current: "#0ea472",
  "1_30": "#60a5fa",
  "31_60": "#d68a04",
  "61_90": "#f0883e",
  "90_plus": "#dc3545",
};
