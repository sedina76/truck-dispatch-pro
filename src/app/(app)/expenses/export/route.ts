import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatMoney, formatDate } from "@/lib/export/csv";

type Row = {
  expense_number: string;
  expense_date: string;
  scope: string;
  category: string;
  vendor_name: string | null;
  amount: number;
  tax_amount: number;
  total_amount: number;
  status: string;
  reference_number: string | null;
  loads: { load_number: string } | null;
  trucks: { unit_number: string } | null;
};

// Mirrors expenses/page.tsx's own query+filters exactly. No sensitive HR/
// driver PII in scope -- this table never carried any.
export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const start = searchParams.get("start");
  const end = searchParams.get("end");
  const scope = searchParams.get("scope");
  const category = searchParams.get("category");
  const status = searchParams.get("status");
  const load_id = searchParams.get("load_id");
  const truck_id = searchParams.get("truck_id");
  const driver_id = searchParams.get("driver_id");
  const carrier_id = searchParams.get("carrier_id");
  const q = searchParams.get("q");

  const supabase = await createClient();
  let query = supabase
    .from("expenses")
    .select("expense_number, expense_date, scope, category, vendor_name, amount, tax_amount, total_amount, status, reference_number, loads(load_number), trucks(unit_number)")
    .order("expense_date", { ascending: false });
  if (start) query = query.gte("expense_date", start);
  if (end) query = query.lte("expense_date", end);
  if (scope) query = query.eq("scope", scope);
  if (category) query = query.eq("category", category);
  if (status) query = query.eq("status", status);
  if (load_id) query = query.eq("load_id", load_id);
  if (truck_id) query = query.eq("truck_id", truck_id);
  if (driver_id) query = query.eq("driver_id", driver_id);
  if (carrier_id) query = query.eq("carrier_id", carrier_id);
  if (q) query = query.or(`expense_number.ilike.%${q}%,vendor_name.ilike.%${q}%,reference_number.ilike.%${q}%`);

  const { data } = await query;
  const rows = (data ?? []) as unknown as Row[];

  const csv = toCsv(rows, [
    { header: "Expense #", value: (r) => r.expense_number },
    { header: "Date", value: (r) => formatDate(r.expense_date) },
    { header: "Scope", value: (r) => r.scope },
    { header: "Category", value: (r) => r.category },
    { header: "Load #", value: (r) => r.loads?.load_number ?? "" },
    { header: "Truck", value: (r) => r.trucks?.unit_number ?? "" },
    { header: "Vendor", value: (r) => r.vendor_name ?? "" },
    { header: "Amount", value: (r) => formatMoney(r.amount) },
    { header: "Tax", value: (r) => formatMoney(r.tax_amount) },
    { header: "Total", value: (r) => formatMoney(r.total_amount) },
    { header: "Reference #", value: (r) => r.reference_number ?? "" },
    { header: "Status", value: (r) => r.status },
  ]);

  return csvResponse(csv, "expenses");
}
