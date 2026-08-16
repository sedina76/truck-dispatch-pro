import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { KpiRow, KpiCard } from "@/components/ui/kpi-card";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";

type AdvanceRow = {
  id: string;
  expense_type: string;
  description: string | null;
  amount: number;
  paid_date: string;
  status: string;
  carriers: { legal_name: string } | null;
};

export default async function AdvancesPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("dispatch_advances")
    .select("id, expense_type, description, amount, paid_date, status, carriers(legal_name)")
    .order("paid_date", { ascending: false });
  if (q) query = query.or(`description.ilike.%${q}%,expense_type.ilike.%${q}%`);

  const { data } = await query;
  const advances = (data ?? []) as unknown as AdvanceRow[];

  const { data: allAdvances } = await supabase.from("dispatch_advances").select("amount, status, updated_at");
  const pendingTotal = (allAdvances ?? [])
    .filter((a) => a.status === "pending")
    .reduce((sum, a) => sum + Number(a.amount), 0);
  const deductedThisMonth = (allAdvances ?? [])
    .filter((a) => a.status === "deducted" && new Date(a.updated_at).getMonth() === new Date().getMonth())
    .reduce((sum, a) => sum + Number(a.amount), 0);
  const reimbursedTotal = (allAdvances ?? [])
    .filter((a) => a.status === "reimbursed")
    .reduce((sum, a) => sum + Number(a.amount), 0);
  const pendingCount = (allAdvances ?? []).filter((a) => a.status === "pending").length;

  const columns: Column<AdvanceRow>[] = [
    { header: "Carrier", cell: (row) => <span className="font-medium">{row.carriers?.legal_name ?? "--"}</span> },
    { header: "Expense Type", cell: (row) => <span className="capitalize">{row.expense_type.replace(/_/g, " ")}</span> },
    { header: "Description", cell: (row) => row.description ?? "--" },
    { header: "Amount", cell: (row) => `$${Number(row.amount).toLocaleString()}` },
    { header: "Paid Date", cell: (row) => new Date(row.paid_date).toLocaleDateString() },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Dispatcher Advances"
        description="Fuel, lumper, and other expenses paid upfront for carriers -- tracked until reimbursed."
        primaryAction={{ label: "Add Advance", href: "/advances/new" }}
      />

      <KpiRow>
        <KpiCard label="Pending Total" value={`$${pendingTotal.toLocaleString()}`} tone={pendingCount ? "warning" : "neutral"} />
        <KpiCard label="Pending Count" value={pendingCount} />
        <KpiCard label="Deducted This Month" value={`$${deductedThisMonth.toLocaleString()}`} tone="success" />
        <KpiCard label="Reimbursed (all time)" value={`$${reimbursedTotal.toLocaleString()}`} />
      </KpiRow>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <SearchBar placeholder="Search by description or expense type..." />
        <div className="flex items-center gap-2 text-sm">
          <Link href="/advances/pending" className="font-medium text-primary hover:underline">
            Pending Deductions
          </Link>
          <span className="text-muted-foreground">&middot;</span>
          <Link href="/advances/by-carrier" className="font-medium text-primary hover:underline">
            By Carrier
          </Link>
          <span className="text-muted-foreground">&middot;</span>
          <Link href="/advances/deducted-history" className="font-medium text-primary hover:underline">
            Deducted History
          </Link>
        </div>
      </div>

      {advances.length === 0 ? (
        <EmptyState
          title={q ? "No advances match your search" : "No advances recorded yet"}
          description={q ? "Try a different search term." : "Record an advance when you pay an expense on a carrier's behalf."}
          action={{ label: "Add Advance", href: "/advances/new" }}
        />
      ) : (
        <DataTable
          columns={columns}
          rows={advances}
          getDetailHref={(row) => `/advances/${row.id}`}
          getDeleteAction={(row) => deleteRecord.bind(null, "dispatch_advances", row.id, "/advances")}
        />
      )}
    </div>
  );
}
