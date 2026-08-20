import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatMoney } from "@/lib/export/csv";
import type { CollectionsQueueRow } from "@/lib/collections/types";
import { filterCollectionsRows } from "@/lib/collections/filter";
import { requireRoleForApi, FINANCIAL_ROLES } from "@/lib/auth/require-role";

// Same RPC call as collections/page.tsx, then the SAME shared filter
// function (src/lib/collections/filter.ts) -- not a second hand-maintained
// copy of the filter chain, so this can never drift from what's on screen.
// Minus internal collection notes (never selected in this query to begin
// with).
export async function GET(req: Request) {
  const denied = await requireRoleForApi(FINANCIAL_ROLES);
  if (denied) return denied;

  const { searchParams } = new URL(req.url);
  const filter = searchParams.get("filter") ?? "";
  const priority = searchParams.get("priority") ?? "";
  const status = searchParams.get("status") ?? "";
  const broker_id = searchParams.get("broker_id");
  const customer_id = searchParams.get("customer_id");
  const collector_id = searchParams.get("collector_id");
  const min_balance = searchParams.get("min_balance");
  const q = searchParams.get("q");
  const mine = searchParams.get("mine");

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: queueData } = await supabase.rpc("get_collections_queue", {
    p_broker_id: broker_id || null,
    p_customer_id: customer_id || null,
    p_collector_id: mine === "1" ? (user?.id ?? null) : collector_id || null,
  });
  const rows = filterCollectionsRows((queueData ?? []) as CollectionsQueueRow[], { filter: filter || undefined, priority: priority || undefined, status: status || undefined, min_balance, q });

  const csv = toCsv(rows, [
    { header: "Invoice #", value: (r) => r.invoice_number },
    { header: "Load #", value: (r) => r.load_number ?? "" },
    { header: "Party", value: (r) => r.broker_name ?? r.customer_name ?? r.bill_to_name },
    { header: "Balance Due", value: (r) => formatMoney(r.balance_due) },
    { header: "Aging Bucket", value: (r) => r.aging_bucket },
    { header: "Priority", value: (r) => r.priority },
    { header: "Collection Status", value: (r) => r.collection_status },
    { header: "Dispute Status", value: (r) => r.dispute_status ?? "" },
  ]);

  return csvResponse(csv, "collections");
}
