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

  // Phase 2G.12: average_days_to_pay dropped from the brokers select and
  // rate from the loads select -- broker_financials/load_financials are
  // authoritative now. No additional role gating needed here -- this
  // whole route is already layout-guarded to FINANCIAL_ROLES (see
  // reports/layout.tsx).
  const [{ data: brokers }, { data: loads }, { data: brokerFinancials }, { data: loadFinancials }] = await Promise.all([
    supabase.from("brokers").select("id, company_name"),
    supabase.from("loads").select("id, broker_id"),
    supabase.from("broker_financials").select("broker_id, average_days_to_pay"),
    supabase.from("load_financials").select("load_id, rate"),
  ]);

  const daysToPayByBroker = new Map((brokerFinancials ?? []).map((r) => [r.broker_id, r.average_days_to_pay]));
  const rateByLoadId = new Map((loadFinancials ?? []).map((r) => [r.load_id, Number(r.rate)]));

  const rows: Row[] = (brokers ?? []).map((b) => {
    const brokerLoads = (loads ?? []).filter((l) => l.broker_id === b.id);
    return {
      id: b.id,
      company_name: b.company_name,
      loadCount: brokerLoads.length,
      totalValue: brokerLoads.reduce((sum, l) => sum + (rateByLoadId.get(l.id) ?? 0), 0),
      average_days_to_pay: daysToPayByBroker.get(b.id) ?? null,
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
