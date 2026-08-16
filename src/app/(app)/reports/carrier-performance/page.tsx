import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";

type Row = {
  id: string;
  legal_name: string;
  dispatchCount: number;
  completedCount: number;
  netTotal: number;
};

export default async function CarrierPerformancePage() {
  const supabase = await createClient();

  const [{ data: carriers }, { data: dispatches }] = await Promise.all([
    supabase.from("carriers").select("id, legal_name"),
    supabase.from("dispatches").select("carrier_id, status, carrier_net_amount"),
  ]);

  const rows: Row[] = (carriers ?? []).map((c) => {
    const carrierDispatches = (dispatches ?? []).filter((d) => d.carrier_id === c.id);
    return {
      id: c.id,
      legal_name: c.legal_name,
      dispatchCount: carrierDispatches.length,
      completedCount: carrierDispatches.filter((d) => ["completed", "delivered"].includes(d.status)).length,
      netTotal: carrierDispatches.reduce((sum, d) => sum + Number(d.carrier_net_amount), 0),
    };
  });
  rows.sort((a, b) => b.dispatchCount - a.dispatchCount);

  const columns: Column<Row>[] = [
    { header: "Carrier", cell: (row) => <span className="font-medium">{row.legal_name}</span> },
    { header: "Dispatches", cell: (row) => row.dispatchCount },
    { header: "Completed", cell: (row) => row.completedCount },
    {
      header: "Completion Rate",
      cell: (row) => (row.dispatchCount ? `${Math.round((row.completedCount / row.dispatchCount) * 100)}%` : "--"),
    },
    { header: "Net Paid", cell: (row) => `$${row.netTotal.toLocaleString()}` },
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="Carrier Performance" description="Dispatch volume and payout by carrier." />

      {rows.length === 0 ? (
        <EmptyState title="No carrier data yet" description="Add carriers and dispatches to see performance here." />
      ) : (
        <DataTable columns={columns} rows={rows} />
      )}
    </div>
  );
}
