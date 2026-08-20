import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { ArAgingChart, type AgingBucketPoint } from "@/components/finance/ar-aging-chart";
import { AGING_BUCKETS, AGING_BUCKET_LABELS, AGING_BUCKET_COLORS } from "@/lib/invoices/effective-status";
import { BillingSubnav } from "@/components/desktop/billing-subnav";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";

type ArInvoiceRow = {
  id: string;
  invoice_number: string;
  load_id: string | null;
  load_number: string | null;
  broker_id: string | null;
  broker_name: string | null;
  customer_id: string | null;
  customer_name: string | null;
  bill_to_name: string;
  issue_date: string;
  due_date: string | null;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  status: string;
  effective_status: string;
  aging_bucket: string;
  days_past_due: number;
};

type ArSummary = {
  total_receivables: number;
  current_amount: number;
  bucket_1_30: number;
  bucket_31_60: number;
  bucket_61_90: number;
  bucket_90_plus: number;
  overdue_invoice_count: number;
  overdue_amount: number;
  collected_this_month: number;
};

// Finance -> Accounts Receivable. Every number on this page comes from
// get_ar_summary()/get_ar_invoices() (0026_accounts_receivable.sql) --
// the same two functions the main Dashboard, the plain Invoices list KPIs,
// and Reports -> A/R Aging all call, so this can never disagree with them.
// Nothing here is hard-coded or computed client-side.
export default async function AccountsReceivablePage() {
  const supabase = await createClient();

  const [{ data: summaryData }, { data: invoiceRows }] = await Promise.all([
    supabase.rpc("get_ar_summary").single(),
    supabase.rpc("get_ar_invoices"),
  ]);
  const summary = summaryData as ArSummary | null;
  const invoices = (invoiceRows ?? []) as ArInvoiceRow[];
  const outstanding = invoices.filter((i) => i.balance_due > 0);

  const bucketAmounts: Record<string, number> = {
    current: Number(summary?.current_amount ?? 0),
    "1_30": Number(summary?.bucket_1_30 ?? 0),
    "31_60": Number(summary?.bucket_31_60 ?? 0),
    "61_90": Number(summary?.bucket_61_90 ?? 0),
    "90_plus": Number(summary?.bucket_90_plus ?? 0),
  };
  const bucketCounts: Record<string, number> = Object.fromEntries(AGING_BUCKETS.map((b) => [b, 0]));
  for (const inv of outstanding) bucketCounts[inv.aging_bucket] = (bucketCounts[inv.aging_bucket] ?? 0) + 1;

  const chartData: AgingBucketPoint[] = AGING_BUCKETS.map((bucket) => ({
    bucket,
    label: AGING_BUCKET_LABELS[bucket],
    balance: bucketAmounts[bucket] ?? 0,
    count: bucketCounts[bucket] ?? 0,
    color: AGING_BUCKET_COLORS[bucket],
  }));

  const columns: Column<ArInvoiceRow>[] = [
    { header: "Invoice #", cell: (row) => <span className="font-medium">{row.invoice_number}</span> },
    { header: "Load #", cell: (row) => row.load_number ?? "--" },
    { header: "Broker / Customer", cell: (row) => row.broker_name ?? row.customer_name ?? row.bill_to_name },
    { header: "Invoice Date", cell: (row) => new Date(row.issue_date).toLocaleDateString() },
    { header: "Due Date", cell: (row) => (row.due_date ? new Date(row.due_date).toLocaleDateString() : "--") },
    { header: "Original", cell: (row) => `$${Number(row.total_amount).toLocaleString(undefined, { minimumFractionDigits: 2 })}` },
    { header: "Paid", cell: (row) => `$${Number(row.amount_paid).toLocaleString(undefined, { minimumFractionDigits: 2 })}` },
    { header: "Balance", cell: (row) => <span className="font-medium">${Number(row.balance_due).toLocaleString(undefined, { minimumFractionDigits: 2 })}</span> },
    { header: "Age", cell: (row) => (row.days_past_due > 0 ? `${row.days_past_due}d past due` : "Current") },
    { header: "Status", cell: (row) => <StatusBadge status={row.effective_status} /> },
    {
      header: "",
      cell: (row) => (
        <div className="flex items-center gap-2 whitespace-nowrap">
          <Link href={`/payments/new?invoice_id=${row.id}`} className="text-xs font-medium text-primary hover:underline">
            Record Payment
          </Link>
          <Link
            href={row.broker_id ? `/statements?party=broker:${row.broker_id}` : row.customer_id ? `/statements?party=customer:${row.customer_id}` : "/statements"}
            className="text-xs font-medium text-muted-foreground hover:underline"
          >
            Statement
          </Link>
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-3">
      <BillingSubnav />
      <RegisterDesktopActions title="Accounts Receivable" exportOptions={[{ label: "Export CSV", href: "/accounts-receivable/export" }]} />

      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Accounts Receivable</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">Outstanding customer/broker balances, aging, and collections.</p>
      </div>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Receivables" value={`$${Number(summary?.total_receivables ?? 0).toLocaleString(undefined, { minimumFractionDigits: 2 })}`} />
        <DesktopKpiBox label="Current" value={`$${bucketAmounts.current.toLocaleString(undefined, { minimumFractionDigits: 2 })}`} tone="success" />
        <DesktopKpiBox label="1-30 Days" value={`$${bucketAmounts["1_30"].toLocaleString(undefined, { minimumFractionDigits: 2 })}`} tone="warning" />
        <DesktopKpiBox label="31-60 Days" value={`$${bucketAmounts["31_60"].toLocaleString(undefined, { minimumFractionDigits: 2 })}`} tone="warning" />
        <DesktopKpiBox label="61-90 Days" value={`$${bucketAmounts["61_90"].toLocaleString(undefined, { minimumFractionDigits: 2 })}`} tone="danger" />
        <DesktopKpiBox label="90+ Days" value={`$${bucketAmounts["90_plus"].toLocaleString(undefined, { minimumFractionDigits: 2 })}`} tone="danger" />
        <DesktopKpiBox label="Collected This Mo." value={`$${Number(summary?.collected_this_month ?? 0).toLocaleString(undefined, { minimumFractionDigits: 2 })}`} tone="success" href="/payments" />
        <DesktopKpiBox label="Overdue Invoices" value={summary?.overdue_invoice_count ?? 0} tone={(summary?.overdue_invoice_count ?? 0) > 0 ? "danger" : "neutral"} href="/collections" />
      </DesktopKpiStrip>

      <DesktopPanel>
        <DesktopPanelHeader title="Aging Summary" />
        <DesktopPanelBody>
          <p className="mb-2 text-[11px] text-muted-foreground">Outstanding balance by age bucket. Bucket totals sum to Total Receivables above.</p>
          <ArAgingChart data={chartData} />
        </DesktopPanelBody>
      </DesktopPanel>

      {outstanding.length === 0 ? (
        <EmptyState title="No outstanding receivables" description="Every non-void invoice is fully paid." />
      ) : (
        <DataTable columns={columns} rows={outstanding} getDetailHref={(row) => `/invoices/${row.id}`} pageSize={15} />
      )}
    </div>
  );
}
