import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";

type Row = {
  id: string;
  company_name: string;
  loadCount: number;
  totalValue: number;
  average_days_to_pay: number | null;
};

export default async function BrokerPerformancePage() {
  const supabase = await createClient();

  const [{ data: brokers }, { data: loads }] = await Promise.all([
    supabase.from("brokers").select("id, company_name, average_days_to_pay"),
    supabase.from("loads").select("broker_id, rate"),
  ]);

  const rows: Row[] = (brokers ?? []).map((b) => {
    const brokerLoads = (loads ?? []).filter((l) => l.broker_id === b.id);
    return {
      id: b.id,
      company_name: b.company_name,
      loadCount: brokerLoads.length,
      totalValue: brokerLoads.reduce((sum, l) => sum + Number(l.rate), 0),
      average_days_to_pay: b.average_days_to_pay,
    };
  });
  rows.sort((a, b) => b.totalValue - a.totalValue);

  const columns: Column<Row>[] = [
    { header: "Broker", cell: (row) => <span className="font-medium">{row.company_name}</span> },
    { header: "Loads", cell: (row) => row.loadCount },
    { header: "Total Value", cell: (row) => `$${row.totalValue.toLocaleString()}` },
    { header: "Avg Days to Pay", cell: (row) => row.average_days_to_pay ?? "--" },
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="Broker Performance" description="Load volume and average days to pay by broker." />

      {rows.length === 0 ? (
        <EmptyState title="No broker data yet" description="Add brokers and loads to see performance here." />
      ) : (
        <DataTable columns={columns} rows={rows} />
      )}
    </div>
  );
}
