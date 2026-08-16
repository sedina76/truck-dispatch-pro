// Mirrors the return shape of public.get_collections_queue()
// (0027_collections.sql) exactly -- the one canonical row source for both
// the Collections queue table and the Invoice Detail Collections section.
export type CollectionsQueueRow = {
  id: string;
  invoice_number: string;
  load_id: string | null;
  load_number: string | null;
  broker_id: string | null;
  broker_name: string | null;
  customer_id: string | null;
  customer_name: string | null;
  bill_to_name: string;
  issue_date: string;
  due_date: string | null;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  status: string;
  effective_status: string;
  aging_bucket: string;
  days_past_due: number;
  collection_status: string;
  assigned_collector_id: string | null;
  assigned_collector_name: string | null;
  last_contact_at: string | null;
  last_contact_method: string | null;
  next_follow_up_at: string | null;
  promise_id: string | null;
  promise_amount: number | null;
  promise_expected_date: string | null;
  promise_effective_status: string | null;
  dispute_status: string | null;
  disputed_amount: number;
  undisputed_amount: number;
  priority: "urgent" | "high" | "normal" | "low";
};

export const COLLECTION_STATUS_OPTIONS = [
  { value: "not_started", label: "Not Started" },
  { value: "contacted", label: "Contacted" },
  { value: "follow_up", label: "Follow-Up" },
  { value: "promise_to_pay", label: "Promise to Pay" },
  { value: "disputed", label: "Disputed" },
  { value: "escalated", label: "Escalated" },
  { value: "resolved", label: "Resolved" },
] as const;

export const CONTACT_METHOD_OPTIONS = [
  { value: "phone", label: "Phone" },
  { value: "email", label: "Email" },
  { value: "sms", label: "SMS" },
  { value: "portal", label: "Portal" },
  { value: "other", label: "Other" },
] as const;

export const DISPUTE_REASON_OPTIONS = [
  { value: "rate_discrepancy", label: "Rate Discrepancy" },
  { value: "missing_pod", label: "Missing POD" },
  { value: "missing_rate_confirmation", label: "Missing Rate Confirmation" },
  { value: "lumper", label: "Lumper" },
  { value: "detention", label: "Detention" },
  { value: "shortage", label: "Shortage" },
  { value: "damage", label: "Damage" },
  { value: "late_delivery", label: "Late Delivery" },
  { value: "duplicate_invoice", label: "Duplicate Invoice" },
  { value: "billing_error", label: "Billing Error" },
  { value: "other", label: "Other" },
] as const;

export const PRIORITY_LABELS: Record<string, string> = {
  urgent: "Urgent",
  high: "High",
  normal: "Normal",
  low: "Low",
};

export const AGING_FILTER_OPTIONS = [
  { value: "", label: "All" },
  { value: "due_soon", label: "Due Soon" },
  { value: "overdue", label: "Overdue" },
  { value: "1_30", label: "1-30 Days" },
  { value: "31_60", label: "31-60 Days" },
  { value: "61_90", label: "61-90 Days" },
  { value: "90_plus", label: "90+ Days" },
  { value: "broken_promises", label: "Broken Promises" },
  { value: "disputed", label: "Disputed" },
  { value: "follow_up_due", label: "Follow-Up Due" },
  { value: "unassigned", label: "Unassigned" },
] as const;

export function formatMoney(n: number | null | undefined): string {
  return `$${Number(n ?? 0).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
