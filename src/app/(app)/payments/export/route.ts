import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatMoney, formatDate } from "@/lib/export/csv";
import { requireRoleForApi, FINANCIAL_ROLES } from "@/lib/auth/require-role";

type Row = {
  payment_number: string;
  amount: number;
  method: string;
  status: string;
  reference_number: string | null;
  received_at: string;
  invoices: { invoice_number: string } | null;
};

// Mirrors payments/page.tsx's own query+filter exactly.
export async function GET(req: Request) {
  const denied = await requireRoleForApi(FINANCIAL_ROLES);
  if (denied) return denied;

  const { searchParams } = new URL(req.url);
  const q = searchParams.get("q");

  const supabase = await createClient();
  let query = supabase
    .from("payments")
    .select("payment_number, amount, method, status, reference_number, received_at, invoices(invoice_number)")
    .order("received_at", { ascending: false });
  if (q) query = query.or(`reference_number.ilike.%${q}%,payment_number.ilike.%${q}%`);

  const { data } = await query;
  const rows = (data ?? []) as unknown as Row[];

  const csv = toCsv(rows, [
    { header: "Payment #", value: (r) => r.payment_number },
    { header: "Invoice #", value: (r) => r.invoices?.invoice_number ?? "" },
    { header: "Received", value: (r) => formatDate(r.received_at) },
    { header: "Amount", value: (r) => formatMoney(r.amount) },
    { header: "Method", value: (r) => r.method },
    { header: "Reference #", value: (r) => r.reference_number ?? "" },
    { header: "Status", value: (r) => r.status },
  ]);

  return csvResponse(csv, "payments");
}
