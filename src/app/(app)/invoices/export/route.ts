import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatMoney, formatDate } from "@/lib/export/csv";

type Row = {
  invoice_number: string;
  bill_to_name: string;
  status: string;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  issue_date: string;
  due_date: string | null;
  loads: { load_number: string } | null;
};

// Mirrors invoices/page.tsx's own query+filter exactly.
export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const q = searchParams.get("q");

  const supabase = await createClient();
  let query = supabase
    .from("invoices")
    .select("invoice_number, bill_to_name, status, total_amount, amount_paid, balance_due, issue_date, due_date, loads(load_number)")
    .order("issue_date", { ascending: false });
  if (q) query = query.or(`invoice_number.ilike.%${q}%,bill_to_name.ilike.%${q}%`);

  const { data } = await query;
  const rows = (data ?? []) as unknown as Row[];

  const csv = toCsv(rows, [
    { header: "Invoice #", value: (r) => r.invoice_number },
    { header: "Bill To", value: (r) => r.bill_to_name },
    { header: "Load #", value: (r) => r.loads?.load_number ?? "" },
    { header: "Issue Date", value: (r) => formatDate(r.issue_date) },
    { header: "Due Date", value: (r) => formatDate(r.due_date) },
    { header: "Total", value: (r) => formatMoney(r.total_amount) },
    { header: "Paid", value: (r) => formatMoney(r.amount_paid) },
    { header: "Balance Due", value: (r) => formatMoney(r.balance_due) },
    { header: "Status", value: (r) => r.status },
  ]);

  return csvResponse(csv, "invoices");
}
