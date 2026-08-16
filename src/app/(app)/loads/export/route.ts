import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatMoney } from "@/lib/export/csv";

type Row = {
  load_number: string;
  status: string;
  equipment_type: string | null;
  rate: number;
  total_miles: number | null;
  brokers: { company_name: string } | null;
  customers: { company_name: string } | null;
};

// Mirrors loads/page.tsx's own query+filters exactly (q, pod_missing isn't
// filterable server-side there either -- it's a POD-verification lookup,
// not a plain column filter, so it's intentionally left out of the export
// scope note below rather than silently ignored).
export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const q = searchParams.get("q");

  const supabase = await createClient();
  let query = supabase
    .from("loads")
    .select("load_number, status, equipment_type, rate, total_miles, brokers(company_name), customers(company_name)")
    .order("created_at", { ascending: false });
  if (q) query = query.ilike("load_number", `%${q}%`);

  const { data } = await query;
  const rows = (data ?? []) as unknown as Row[];

  const csv = toCsv(rows, [
    { header: "Load #", value: (r) => r.load_number },
    { header: "Source", value: (r) => r.brokers?.company_name ?? r.customers?.company_name ?? "" },
    { header: "Equipment", value: (r) => r.equipment_type ?? "" },
    { header: "Miles", value: (r) => r.total_miles ?? "" },
    { header: "Rate", value: (r) => formatMoney(r.rate) },
    { header: "Status", value: (r) => r.status },
  ]);

  return csvResponse(csv, "loads");
}
