import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatDate } from "@/lib/export/csv";

type Row = {
  first_name: string;
  last_name: string;
  phone: string | null;
  cdl_number: string | null;
  cdl_expiry_date: string | null;
  status: string;
  carriers: { legal_name: string } | null;
};

// Operational fields only -- matches exactly what drivers/page.tsx's own
// grid already shows. No SSN, no DOB, no medical card number, no
// background-check/drug-test detail, no direct-deposit info -- none of
// that is even in this query, so there's nothing sensitive to accidentally
// leak into the CSV.
export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const q = searchParams.get("q");

  const supabase = await createClient();
  let query = supabase
    .from("drivers")
    .select("first_name, last_name, phone, cdl_number, cdl_expiry_date, status, carriers(legal_name)")
    .order("last_name");
  if (q) query = query.or(`first_name.ilike.%${q}%,last_name.ilike.%${q}%`);

  const { data } = await query;
  const rows = (data ?? []) as unknown as Row[];

  const csv = toCsv(rows, [
    { header: "First Name", value: (r) => r.first_name },
    { header: "Last Name", value: (r) => r.last_name },
    { header: "Phone", value: (r) => r.phone ?? "" },
    { header: "Carrier", value: (r) => r.carriers?.legal_name ?? "" },
    { header: "CDL Number", value: (r) => r.cdl_number ?? "" },
    { header: "CDL Expiry", value: (r) => formatDate(r.cdl_expiry_date) },
    { header: "Status", value: (r) => r.status },
  ]);

  return csvResponse(csv, "drivers");
}
