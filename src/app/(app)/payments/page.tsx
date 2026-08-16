import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBar } from "@/components/ui/search-bar";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

type Payment = {
  id: string;
  payment_number: string;
  amount: number;
  method: string;
  status: string;
  reference_number: string | null;
  received_at: string;
  invoices: { invoice_number: string } | null;
};

export default async function PaymentsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const { q } = await searchParams;
  const supabase = await createClient();

  let query = supabase
    .from("payments")
    .select("id, payment_number, amount, method, status, reference_number, received_at, invoices(invoice_number)")
    .order("received_at", { ascending: false });
  if (q) query = query.or(`reference_number.ilike.%${q}%,payment_number.ilike.%${q}%`);

  const { data } = await query;
  const payments = (data ?? []) as unknown as Payment[];

  // Total Collected / Collected This Month: same canonical rule used by
  // Finance -> Accounts Receivable and the main Dashboard --
  // status = 'posted' only (a voided payment never counted as collected)
  // -- via the same get_ar_summary() RPC so this can never disagree with
  // those pages. Collected This Month here intentionally covers the whole
  // org (no broker/customer scope), matching what this page shows.
  const { data: summary } = await supabase.rpc("get_ar_summary").single();
  const collectedThisMonth = Number((summary as { collected_this_month?: number } | null)?.collected_this_month ?? 0);

  const { count: totalPostedCount } = await supabase
    .from("payments")
    .select("id", { count: "exact", head: true })
    .eq("status", "posted");
  const { data: allPosted } = await supabase.from("payments").select("amount").eq("status", "posted");
  const totalCollected = (allPosted ?? []).reduce((sum, p) => sum + Number(p.amount), 0);

  const columns: Column<Payment>[] = [
    { header: "Payment #", cell: (row) => <span className="font-medium">{row.payment_number}</span> },
    { header: "Invoice #", cell: (row) => row.invoices?.invoice_number ?? "--" },
    { header: "Date", cell: (row) => new Date(row.received_at).toLocaleDateString() },
    { header: "Method", cell: (row) => <span className="capitalize">{row.method.replace(/_/g, " ")}</span> },
    { header: "Reference", cell: (row) => row.reference_number ?? "--" },
    { header: "Amount", cell: (row) => <span className="tabular-nums font-medium">${Number(row.amount).toLocaleString(undefined, { minimumFractionDigits: 2 })}</span>, className: "text-right" },
    { header: "Status", cell: (row) => <StatusBadge status={row.status} /> },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Payments", href: "/payments" }]} />
      <RegisterDesktopActions title="Payments" exportOptions={[{ label: "Export CSV (Filtered)", href: `/payments/export${q ? `?q=${encodeURIComponent(q)}` : ""}` }]} />

      <PageHeader
        title="Payments"
        description="Payments received against invoices."
        primaryAction={{ label: "Record Payment", href: "/payments/new" }}
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Collected" value={`$${totalCollected.toLocaleString(undefined, { minimumFractionDigits: 2 })}`} tone="success" />
        <DesktopKpiBox label="Collected This Month" value={`$${collectedThisMonth.toLocaleString(undefined, { minimumFractionDigits: 2 })}`} tone="success" />
        <DesktopKpiBox label="Posted Payments" value={totalPostedCount ?? 0} />
      </DesktopKpiStrip>

      <SearchBar placeholder="Search by payment # or reference number..." />

      {payments.length === 0 ? (
        <EmptyState
          title={q ? "No payments match your search" : "No payments recorded yet"}
          description={q ? "Try a different search term." : "Record a payment against an outstanding invoice."}
          action={{ label: "Record Payment", href: "/payments/new" }}
        />
      ) : (
        <DataTable columns={columns} rows={payments} getDetailHref={(row) => `/payments/${row.id}`} />
      )}
    </div>
  );
}
