import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";

type PendingAdvance = {
  id: string;
  expense_type: string;
  description: string | null;
  amount: number;
  paid_date: string;
  carriers: { id: string; legal_name: string } | null;
};

export default async function PendingDeductionsPage() {
  const supabase = await createClient();

  const { data } = await supabase
    .from("dispatch_advances")
    .select("id, expense_type, description, amount, paid_date, carriers(id, legal_name)")
    .eq("status", "pending")
    .order("paid_date", { ascending: true });

  const advances = (data ?? []) as unknown as PendingAdvance[];
  const total = advances.reduce((sum, a) => sum + Number(a.amount), 0);
  const oldestDays =
    advances.length > 0 ? Math.floor((Date.now() - new Date(advances[0].paid_date).getTime()) / 86_400_000) : 0;

  const columns: Column<PendingAdvance>[] = [
    { header: "Carrier", cell: (row) => <span className="font-medium">{row.carriers?.legal_name ?? "--"}</span> },
    { header: "Expense Type", cell: (row) => <span className="capitalize">{row.expense_type.replace(/_/g, " ")}</span> },
    { header: "Description", cell: (row) => row.description ?? "--" },
    { header: "Paid Date", cell: (row) => new Date(row.paid_date).toLocaleDateString() },
    { header: "Amount", cell: (row) => `$${Number(row.amount).toLocaleString()}` },
    {
      header: "",
      cell: (row) => (
        <a href={`/settlements/new?carrier_id=${row.carriers?.id ?? ""}`} className="text-xs font-medium text-primary hover:underline">
          Create settlement &rarr;
        </a>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Pending Deductions"
        description="Advances not yet recouped from any carrier settlement or invoice."
      />

      <KpiRow>
        <KpiCard label="Total Pending" value={`$${total.toLocaleString()}`} tone={advances.length ? "warning" : "neutral"} />
        <KpiCard label="Pending Advances" value={advances.length} />
        <KpiCard label="Oldest Unresolved" value={advances.length ? `${oldestDays}d` : "--"} />
      </KpiRow>

      {advances.length === 0 ? (
        <EmptyState title="Nothing pending" description="Every recorded advance has been deducted, reimbursed, or waived." />
      ) : (
        <DataTable columns={columns} rows={advances} getDetailHref={(row) => `/advances/${row.id}`} />
      )}
    </div>
  );
}
