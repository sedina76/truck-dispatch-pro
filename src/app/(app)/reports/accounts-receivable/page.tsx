import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { StatusBadge } from "@/components/ui/status-badge";
import { ArAgingChart, type AgingBucketPoint } from "@/components/finance/ar-aging-chart";
import { AGING_BUCKETS, AGING_BUCKET_LABELS, AGING_BUCKET_COLORS } from "@/lib/invoices/effective-status";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";

type ArInvoiceRow = {
  id: string;
  invoice_number: string;
  load_number: string | null;
  broker_name: string | null;
  customer_name: string | null;
  bill_to_name: string;
  issue_date: string;
  due_date: string | null;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
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
};

const money = (n: number) => `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;

// Reports -> Accounts Receivable Aging. Same get_ar_summary()/get_ar_invoices()
// RPCs as Finance -> Accounts Receivable and the main Dashboard, with an
// explicit "as of" date threaded through both so a report run for a past
// date ages every invoice/bucket relative to that date, not today --
// exercising the same p_as_of_date parameter those functions expose.
export default async function AccountsReceivableAgingReportPage({
  searchParams,
}: {
  searchParams: Promise<{ as_of?: string; broker_id?: string; customer_id?: string; status?: string }>;
}) {
  const { as_of, broker_id, customer_id, status } = await searchParams;
  const asOfDate = as_of || new Date().toISOString().slice(0, 10);
  const supabase = await createClient();

  const [{ data: brokers }, { data: customers }] = await Promise.all([
    supabase.from("brokers").select("id, company_name").order("company_name"),
    supabase.from("customers").select("id, company_name").order("company_name"),
  ]);

  const rpcArgs = {
    p_broker_id: broker_id || null,
    p_customer_id: customer_id || null,
    p_as_of_date: asOfDate,
  };
  const [{ data: summaryData }, { data: invoiceRows }] = await Promise.all([
    supabase.rpc("get_ar_summary", rpcArgs).single(),
    supabase.rpc("get_ar_invoices", { ...rpcArgs, p_status: status || null }),
  ]);
  const summary = summaryData as ArSummary | null;
  const invoices = ((invoiceRows ?? []) as ArInvoiceRow[]).filter((i) => i.balance_due > 0);

  const bucketAmounts: Record<string, number> = {
    current: Number(summary?.current_amount ?? 0),
    "1_30": Number(summary?.bucket_1_30 ?? 0),
    "31_60": Number(summary?.bucket_31_60 ?? 0),
    "61_90": Number(summary?.bucket_61_90 ?? 0),
    "90_plus": Number(summary?.bucket_90_plus ?? 0),
  };
  const bucketCounts: Record<string, number> = Object.fromEntries(AGING_BUCKETS.map((b) => [b, 0]));
  for (const inv of invoices) bucketCounts[inv.aging_bucket] = (bucketCounts[inv.aging_bucket] ?? 0) + 1;

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
    { header: "Due Date", cell: (row) => (row.due_date ? new Date(row.due_date).toLocaleDateString() : "--") },
    { header: "Balance", cell: (row) => <span className="font-medium">{money(row.balance_due)}</span> },
    { header: "Bucket", cell: (row) => AGING_BUCKET_LABELS[row.aging_bucket] },
    { header: "Status", cell: (row) => <StatusBadge status={row.effective_status} /> },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Reports", href: "/reports" }, { label: "A/R Aging", href: "/reports/accounts-receivable" }]} />
      <PageHeader title="Accounts Receivable Aging" description="Outstanding balances by age, as of a given date." />

      <form method="get">
        <DesktopFilterBar>
          <DesktopFilterField label="As of Date">
            <input type="date" name="as_of" defaultValue={asOfDate} className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="Broker">
            <select name="broker_id" defaultValue={broker_id ?? ""} className={`${desktopInputClass} min-w-36`}>
              <option value="">All brokers</option>
              {(brokers ?? []).map((b) => (
                <option key={b.id} value={b.id}>{b.company_name}</option>
              ))}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Customer">
            <select name="customer_id" defaultValue={customer_id ?? ""} className={`${desktopInputClass} min-w-36`}>
              <option value="">All customers</option>
              {(customers ?? []).map((c) => (
                <option key={c.id} value={c.id}>{c.company_name}</option>
              ))}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Status">
            <select name="status" defaultValue={status ?? ""} className={`${desktopInputClass} min-w-32`}>
              <option value="">All statuses</option>
              <option value="sent">Sent</option>
              <option value="viewed">Viewed</option>
              <option value="partially_paid">Partially Paid</option>
              <option value="overdue">Overdue</option>
              <option value="disputed">Disputed</option>
            </select>
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">
            Apply
          </button>
          {(as_of || broker_id || customer_id || status) && (
            <Link href="/reports/accounts-receivable" className="inline-flex h-7 items-center text-[12px] font-medium text-muted-foreground hover:text-foreground">
              Clear
            </Link>
          )}
        </DesktopFilterBar>
      </form>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Current" value={money(bucketAmounts.current)} tone="success" />
        <DesktopKpiBox label="1-30" value={money(bucketAmounts["1_30"])} tone="warning" />
        <DesktopKpiBox label="31-60" value={money(bucketAmounts["31_60"])} tone="warning" />
        <DesktopKpiBox label="61-90" value={money(bucketAmounts["61_90"])} tone="danger" />
        <DesktopKpiBox label="90+" value={money(bucketAmounts["90_plus"])} tone="danger" />
        <DesktopKpiBox label="Total Outstanding" value={money(summary?.total_receivables ?? 0)} />
      </DesktopKpiStrip>

      <DesktopPanel>
        <DesktopPanelHeader title={`Aging as of ${new Date(asOfDate + "T00:00:00").toLocaleDateString()}`} />
        <DesktopPanelBody>
          <ArAgingChart data={chartData} />
        </DesktopPanelBody>
      </DesktopPanel>

      {invoices.length === 0 ? (
        <EmptyState title="No outstanding invoices match these filters" description="Adjust the filters above, or clear them to see the full picture." />
      ) : (
        <DataTable columns={columns} rows={invoices} getDetailHref={(row) => `/invoices/${row.id}`} pageSize={20} />
      )}
    </div>
  );
}
