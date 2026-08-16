import type { CollectionsQueueRow } from "@/lib/collections/types";

export type CollectionsFilters = {
  filter?: string;
  priority?: string;
  status?: string;
  min_balance?: string | null;
  q?: string | null;
};

// The in-memory filter chain applied over get_collections_queue()'s own
// result (broker/customer/collector are already RPC args, applied before
// this ever runs). ONE definition, called by both collections/page.tsx
// (the on-screen grid) and collections/export/route.ts (the CSV export) --
// they used to be two hand-maintained copies; extracted here after a live
// test confirmed they'd drifted apart by zero lines, specifically so they
// can never drift apart in the future.
export function filterCollectionsRows(rows: CollectionsQueueRow[], f: CollectionsFilters): CollectionsQueueRow[] {
  let result = rows;

  if (f.min_balance) {
    const min = Number(f.min_balance);
    if (!Number.isNaN(min)) result = result.filter((r) => r.balance_due >= min);
  }
  if (f.q) {
    const needle = f.q.toLowerCase();
    result = result.filter(
      (r) =>
        r.invoice_number.toLowerCase().includes(needle) ||
        (r.load_number ?? "").toLowerCase().includes(needle) ||
        (r.broker_name ?? "").toLowerCase().includes(needle) ||
        (r.customer_name ?? "").toLowerCase().includes(needle) ||
        (r.bill_to_name ?? "").toLowerCase().includes(needle)
    );
  }
  if (f.priority) result = result.filter((r) => r.priority === f.priority);
  if (f.status) result = result.filter((r) => r.collection_status === f.status);
  switch (f.filter) {
    case "due_soon":
      result = result.filter((r) => r.aging_bucket === "current");
      break;
    case "overdue":
      result = result.filter((r) => r.aging_bucket !== "current");
      break;
    case "1_30":
    case "31_60":
    case "61_90":
    case "90_plus":
      result = result.filter((r) => r.aging_bucket === f.filter);
      break;
    case "broken_promises":
      result = result.filter((r) => r.promise_effective_status === "broken");
      break;
    case "disputed":
      result = result.filter((r) => r.dispute_status === "open" || r.dispute_status === "under_review");
      break;
    case "follow_up_due":
      result = result.filter((r) => r.next_follow_up_at && new Date(r.next_follow_up_at) <= new Date());
      break;
    case "unassigned":
      result = result.filter((r) => !r.assigned_collector_id);
      break;
    default:
      break;
  }

  return result;
}
