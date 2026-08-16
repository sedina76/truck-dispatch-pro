import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatMoney, formatDate } from "@/lib/export/csv";

type Row = {
  load_number: string;
  delivery_date: string | null;
  origin_city: string | null;
  origin_state: string | null;
  destination_city: string | null;
  destination_state: string | null;
  miles: number | null;
  revenue: number | null;
  transportation_cost: number | null;
  gross_profit: number | null;
  margin_percent: number | null;
  profitability_status: string;
};

// Mirrors reports/load-margin/page.tsx's own filters exactly, pushed down
// to Postgres via the same get_load_profitability(null) RPC (0037/0038) --
// one set-based query, not a per-load loop, same canonical source every
// other profitability surface reads.
export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const status = searchParams.get("status");
  const start = searchParams.get("start");
  const end = searchParams.get("end");

  const supabase = await createClient();
  let query = supabase.rpc("get_load_profitability", { p_load_id: null }).neq("profitability_status", "NOT_DELIVERED");
  if (status) query = query.eq("profitability_status", status);
  if (start) query = query.gte("delivery_date", start);
  if (end) query = query.lte("delivery_date", end);
  const { data } = await query.order("delivery_date", { ascending: false, nullsFirst: false });
  const rows = (data ?? []) as Row[];

  const csv = toCsv(rows, [
    { header: "Load #", value: (r) => r.load_number },
    { header: "Delivered", value: (r) => formatDate(r.delivery_date) },
    { header: "Origin", value: (r) => (r.origin_city ? `${r.origin_city}, ${r.origin_state}` : "") },
    { header: "Destination", value: (r) => (r.destination_city ? `${r.destination_city}, ${r.destination_state}` : "") },
    { header: "Miles", value: (r) => r.miles ?? "" },
    { header: "Revenue", value: (r) => formatMoney(r.revenue) },
    { header: "Transportation Cost", value: (r) => formatMoney(r.transportation_cost) },
    { header: "Gross Profit", value: (r) => formatMoney(r.gross_profit) },
    { header: "Margin %", value: (r) => (r.margin_percent === null ? "" : Math.round(r.margin_percent * 100) / 100) },
    { header: "Status", value: (r) => r.profitability_status },
  ]);

  return csvResponse(csv, "load-margin");
}
