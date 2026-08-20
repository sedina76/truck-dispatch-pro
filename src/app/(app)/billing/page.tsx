import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { BillingSubnav } from "@/components/desktop/billing-subnav";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { EmptyState } from "@/components/ui/empty-state";

// Phase 2G.5: Billing Overview -- the financial command center the spec
// asks for. Every number here is read from the SAME canonical RPCs the
// individual workspace pages already use (get_ar_summary(),
// get_collections_summary(), get_ready_to_bill_loads()) -- nothing is
// computed independently, so this page can never disagree with Invoices,
// Accounts Receivable, or Collections about what's owed, overdue, or
// collected. No new SQL was added for this page.
type ArSummary = {
  total_receivables: number;
  overdue_invoice_count: number;
  overdue_amount: number;
  collected_this_month: number;
};

type CollectionsSummary = {
  total_overdue: number;
  overdue_invoices: number;
  avg_days_to_pay: number | null;
};

type ActivityRow = {
  id: string;
  kind: "invoice" | "payment";
  label: string;
  amount: number;
  date: string;
  href: string;
};

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
}

export default async function BillingOverviewPage() {
  const supabase = await createClient();

  const [
    { data: arSummaryData },
    { data: collectionsSummaryData },
    { data: readyRows },
    { count: partialPaymentCount },
    { data: recentInvoices },
    { data: recentPayments },
  ] = await Promise.all([
    supabase.rpc("get_ar_summary").single(),
    supabase.rpc("get_collections_summary").single(),
    supabase.rpc("get_ready_to_bill_loads"),
    supabase.from("invoices").select("id", { count: "exact", head: true }).eq("status", "partially_paid"),
    supabase
      .from("invoices")
      .select("id, invoice_number, total_amount, issue_date")
      .order("issue_date", { ascending: false })
      .limit(6),
    supabase
      .from("payments")
      .select("id, amount, received_at, invoice_id, invoices(invoice_number)")
      .eq("status", "posted")
      .order("received_at", { ascending: false })
      .limit(6),
  ]);

  const ar = arSummaryData as ArSummary | null;
  const collections = collectionsSummaryData as CollectionsSummary | null;
  const readyToBillRows = (readyRows ?? []) as { ready_to_bill: boolean }[];
  const readyCount = readyToBillRows.filter((r) => r.ready_to_bill).length;
  const missingDocsCount = readyToBillRows.length - readyCount;

  const activity: ActivityRow[] = [
    ...(recentInvoices ?? []).map((inv) => ({
      id: `invoice-${inv.id}`,
      kind: "invoice" as const,
      label: `Invoice ${inv.invoice_number} created`,
      amount: Number(inv.total_amount),
      date: inv.issue_date,
      href: `/invoices/${inv.id}`,
    })),
    ...(recentPayments ?? []).map((p) => {
      const row = p as unknown as { id: string; amount: number; received_at: string; invoice_id: string; invoices: { invoice_number: string } | null };
      return {
        id: `payment-${row.id}`,
        kind: "payment" as const,
        label: `Payment received${row.invoices ? ` -- ${row.invoices.invoice_number}` : ""}`,
        amount: Number(row.amount),
        date: row.received_at,
        href: `/invoices/${row.invoice_id}`,
      };
    }),
  ]
    .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
    .slice(0, 8);

  return (
    <div className="space-y-3">
      <BillingSubnav />
      <RegisterDesktopActions title="Billing" />

      <PageHeader
        title="Billing Overview"
        description="What's owed, what's overdue, what needs to be invoiced, and what was collected."
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Outstanding A/R" value={money(ar?.total_receivables ?? 0)} href="/accounts-receivable" />
        <DesktopKpiBox label="Overdue" value={money(collections?.total_overdue ?? 0)} tone={(collections?.overdue_invoices ?? 0) ? "danger" : "neutral"} sub={`${collections?.overdue_invoices ?? 0} invoices`} href="/collections" />
        <DesktopKpiBox label="Ready to Bill" value={readyCount} tone={readyCount ? "success" : "neutral"} href="/billing/ready-to-bill" />
        <DesktopKpiBox label="Paid This Month" value={money(ar?.collected_this_month ?? 0)} tone="success" />
        <DesktopKpiBox label="Avg Days to Pay" value={collections?.avg_days_to_pay != null ? `${collections.avg_days_to_pay}d` : "--"} />
      </DesktopKpiStrip>

      <DesktopPanel>
        <DesktopPanelHeader title="Work Queue" />
        <DesktopPanelBody className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-5">
          <WorkQueueTile label="Ready to Bill" count={readyCount} href="/billing/ready-to-bill" tone={readyCount ? "success" : "neutral"} />
          <WorkQueueTile label="Missing Billing Documents" count={missingDocsCount} href="/billing/ready-to-bill" tone={missingDocsCount ? "warning" : "neutral"} />
          <WorkQueueTile label="Overdue Invoices" count={ar?.overdue_invoice_count ?? 0} href="/accounts-receivable" tone={(ar?.overdue_invoice_count ?? 0) ? "danger" : "neutral"} />
          <WorkQueueTile label="Partial Payments" count={partialPaymentCount ?? 0} href="/invoices" tone={(partialPaymentCount ?? 0) ? "warning" : "neutral"} />
          <WorkQueueTile label="Collections Follow-Up" count={collections?.overdue_invoices ?? 0} href="/collections" tone={(collections?.overdue_invoices ?? 0) ? "danger" : "neutral"} />
        </DesktopPanelBody>
      </DesktopPanel>

      <DesktopPanel>
        <DesktopPanelHeader title="Recent Financial Activity" />
        <DesktopPanelBody>
          {activity.length === 0 ? (
            <EmptyState title="No recent activity" description="Invoices and payments will appear here as they happen." />
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Date</th>
                  <th className="py-1.5 pr-3">Activity</th>
                  <th className="py-1.5 pr-3 text-right">Amount</th>
                  <th className="py-1.5">Type</th>
                </tr>
              </thead>
              <tbody>
                {activity.map((row) => (
                  <tr key={row.id} className="border-b border-desktop-border last:border-0">
                    <td className="py-1.5 pr-3 whitespace-nowrap">{new Date(row.date).toLocaleDateString()}</td>
                    <td className="py-1.5 pr-3">
                      <Link href={row.href} className="font-medium text-primary hover:underline">
                        {row.label}
                      </Link>
                    </td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(row.amount)}</td>
                    <td className="py-1.5 capitalize text-muted-foreground">{row.kind}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </DesktopPanelBody>
      </DesktopPanel>
    </div>
  );
}

function WorkQueueTile({ label, count, href, tone }: { label: string; count: number; href: string; tone: "neutral" | "success" | "warning" | "danger" }) {
  return <DesktopKpiBox label={label} value={count} href={href} tone={tone} />;
}
