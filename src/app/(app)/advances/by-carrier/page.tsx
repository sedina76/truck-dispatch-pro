import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";

type Row = {
  carrier_id: string;
  carrier_name: string;
  pending: number;
  deducted: number;
  reimbursed: number;
  waived: number;
};

export default async function CarrierAdvancesPage() {
  const supabase = await createClient();

  const { data } = await supabase
    .from("dispatch_advances")
    .select("carrier_id, amount, status, carriers(legal_name)");

  const rows = new Map<string, Row>();
  for (const r of (data ?? []) as unknown as { carrier_id: string; amount: number; status: string; carriers: { legal_name: string } | null }[]) {
    const key = r.carrier_id;
    if (!rows.has(key)) {
      rows.set(key, {
        carrier_id: key,
        carrier_name: r.carriers?.legal_name ?? "Unknown",
        pending: 0,
        deducted: 0,
        reimbursed: 0,
        waived: 0,
      });
    }
    const row = rows.get(key)!;
    if (r.status === "pending") row.pending += Number(r.amount);
    else if (r.status === "deducted") row.deducted += Number(r.amount);
    else if (r.status === "reimbursed") row.reimbursed += Number(r.amount);
    else if (r.status === "waived") row.waived += Number(r.amount);
  }

  const carriers = Array.from(rows.values()).sort((a, b) => b.pending - a.pending);

  return (
    <div className="space-y-6">
      <PageHeader title="Carrier Advances" description="Advance totals grouped by carrier, by status." />

      {carriers.length === 0 ? (
        <EmptyState title="No advances yet" description="Record an advance to see carrier totals here." />
      ) : (
        <div className="overflow-hidden rounded-xl border border-border bg-card shadow-elevation-1">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/40 text-left text-xs font-medium uppercase tracking-wide text-muted-foreground">
                <th className="px-4 py-3">Carrier</th>
                <th className="px-4 py-3 text-right">Pending</th>
                <th className="px-4 py-3 text-right">Deducted</th>
                <th className="px-4 py-3 text-right">Reimbursed</th>
                <th className="px-4 py-3 text-right">Waived</th>
              </tr>
            </thead>
            <tbody>
              {carriers.map((row) => (
                <tr key={row.carrier_id} className="border-b border-border last:border-0 hover:bg-muted/40">
                  <td className="px-4 py-3 font-medium">
                    <Link href={`/carriers/${row.carrier_id}`} className="hover:underline">
                      {row.carrier_name}
                    </Link>
                  </td>
                  <td className={`px-4 py-3 text-right ${row.pending > 0 ? "font-medium text-warning" : ""}`}>
                    ${row.pending.toLocaleString()}
                  </td>
                  <td className="px-4 py-3 text-right">${row.deducted.toLocaleString()}</td>
                  <td className="px-4 py-3 text-right">${row.reimbursed.toLocaleString()}</td>
                  <td className="px-4 py-3 text-right">${row.waived.toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
