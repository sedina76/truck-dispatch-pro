import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatMoney, formatDate } from "@/lib/export/csv";

type Row = {
  invoice_number: string;
  load_number: string | null;
  broker_name: string | null;
  customer_name: string | null;
  bill_to_name: string;
  issue_date: string;
  due_date: string | null;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  status: string;
  aging_bucket: string;
  days_past_due: number;
};

// Same canonical get_ar_invoices() the on-screen A/R page reads -- no
// independent query, so the export can never disagree with the grid.
export async function GET() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_ar_invoices");
  const rows = ((data ?? []) as Row[]).filter((r) => r.balance_due > 0);

  const csv = toCsv(rows, [
    { header: "Invoice #", value: (r) => r.invoice_number },
    { header: "Load #", value: (r) => r.load_number ?? "" },
    { header: "Party", value: (r) => r.broker_name ?? r.customer_name ?? r.bill_to_name },
    { header: "Issue Date", value: (r) => formatDate(r.issue_date) },
    { header: "Due Date", value: (r) => formatDate(r.due_date) },
    { header: "Total", value: (r) => formatMoney(r.total_amount) },
    { header: "Paid", value: (r) => formatMoney(r.amount_paid) },
    { header: "Balance Due", value: (r) => formatMoney(r.balance_due) },
    { header: "Aging Bucket", value: (r) => r.aging_bucket },
    { header: "Days Past Due", value: (r) => r.days_past_due },
    { header: "Status", value: (r) => r.status },
  ]);

  return csvResponse(csv, "accounts-receivable");
}
