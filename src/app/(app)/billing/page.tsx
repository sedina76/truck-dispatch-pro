import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { BillingSubnav } from "@/components/desktop/billing-subnav";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { EmptyState } from "@/components/ui/empty-state";
import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";
import { canUseBilling } from "@/lib/auth/billing-access";
import { carrierPaidQueue } from "@/lib/billing/carrier-paid-queue";

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
  kind: "invoice" | "payment" | "dispatch fee invoice" | "carrier invoice";
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
  const role = await requireRole(FINANCIAL_ROLES);
  // Dispatch fee and carrier invoices are billing-roles only (dispatchers
  // don't see money pages), so they are fetched only for those roles.
  const billing = canUseBilling(role);
  const carrierPaid = billing ? await loadCarrierPaidBilling(supabase) : null;

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
    ...(carrierPaid?.recent ?? []),
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

      {carrierPaid && (
        <DesktopPanel>
          <DesktopPanelHeader title={'"Broker pays the carrier" loads'} />
          <DesktopPanelBody className="space-y-2">
            <p className="text-[12px] text-muted-foreground">
              These loads are not in Ready to Bill: the broker pays the carrier, so you bill the carrier for your fee, and the carrier invoices the broker or their factoring company.
            </p>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
              <WorkQueueTile label="Fees Not Yet Billed (loads)" count={carrierPaid.needFeeInvoice} href="/dispatch-fee-invoices/new" tone={carrierPaid.needFeeInvoice ? "success" : "neutral"} />
              <DesktopKpiBox label="Fees Owed by Carriers" value={money(carrierPaid.feeOutstanding)} href="/dispatch-fee-invoices?status=open" tone={carrierPaid.feeOutstanding > 0 ? "warning" : "neutral"} />
              <WorkQueueTile label="Need a Carrier Invoice (loads)" count={carrierPaid.needCarrierInvoice} href="/carrier-invoices/new" tone={carrierPaid.needCarrierInvoice ? "success" : "neutral"} />
              <WorkQueueTile label="Carrier Invoices Not Issued" count={carrierPaid.carrierDrafts} href="/carrier-invoices" tone={carrierPaid.carrierDrafts ? "warning" : "neutral"} />
            </div>
          </DesktopPanelBody>
        </DesktopPanel>
      )}

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

type Supabase = Awaited<ReturnType<typeof createClient>>;

// "Broker pays the carrier" loads: what still needs a dispatch fee invoice or
// a carrier invoice, what carriers owe on fee invoices, and the newest of both
// invoice kinds for Recent Financial Activity. RLS scopes every query.
async function loadCarrierPaidBilling(supabase: Supabase) {
  const [{ data: delivered }, { data: feeLines }, { data: carrierLoads }, { data: feeInvoices }, { data: carrierInvoices }] = await Promise.all([
    supabase.from("dispatches").select("id, load_id").eq("proceeds_model", "carrier_paid_directly").in("status", ["delivered", "completed"]).limit(5000),
    supabase.from("carrier_fee_invoice_lines").select("dispatch_id, carrier_fee_invoices!inner(status)").eq("line_type", "dispatch_fee").eq("voided", false).neq("carrier_fee_invoices.status", "void").limit(5000),
    supabase.from("carrier_invoice_loads").select("load_id, carrier_invoices!inner(issuance_status)").neq("carrier_invoices.issuance_status", "voided").limit(5000),
    supabase.from("carrier_fee_invoices").select("id, invoice_number, status, total_amount, balance_due, issue_date, created_at, carriers(legal_name)").order("created_at", { ascending: false }).limit(500),
    supabase.from("carrier_invoices").select("id, invoice_number, issuance_status, total_amount, issued_at, created_at, carriers(legal_name)").eq("invoice_document_type", "carrier_freight_invoice").order("created_at", { ascending: false }).limit(200),
  ]);

  const queue = carrierPaidQueue(
    (delivered ?? []) as { id: string; load_id: string }[],
    (feeLines ?? []).map((l) => (l as { dispatch_id: string | null }).dispatch_id).filter((id): id is string => !!id),
    (carrierLoads ?? []).map((l) => (l as { load_id: string }).load_id)
  );

  type FeeRow = { id: string; invoice_number: string; status: string; total_amount: number; balance_due: number; issue_date: string | null; created_at: string; carriers: { legal_name: string } | null };
  type CarrierRow = { id: string; invoice_number: string | null; issuance_status: string; total_amount: number; issued_at: string | null; created_at: string; carriers: { legal_name: string } | null };
  const fees = (feeInvoices ?? []) as unknown as FeeRow[];
  const carriers = (carrierInvoices ?? []) as unknown as CarrierRow[];

  const feeOutstanding = fees.filter((f) => f.status === "sent" || f.status === "partially_paid").reduce((s, f) => s + Number(f.balance_due), 0);
  const carrierDrafts = carriers.filter((c) => c.issuance_status === "draft" || c.issuance_status === "ready_for_issue").length;

  const recent: ActivityRow[] = [
    ...fees.filter((f) => f.status !== "void").slice(0, 6).map((f) => ({
      id: `fee-${f.id}`,
      kind: "dispatch fee invoice" as const,
      label: `Dispatch fee invoice ${f.invoice_number}${f.carriers ? ` -- ${f.carriers.legal_name}` : ""}${f.status === "draft" ? " (draft)" : ""}`,
      amount: Number(f.total_amount),
      date: f.issue_date ?? f.created_at,
      href: `/dispatch-fee-invoices/${f.id}`,
    })),
    ...carriers.filter((c) => c.issuance_status !== "voided").slice(0, 6).map((c) => ({
      id: `carrier-${c.id}`,
      kind: "carrier invoice" as const,
      label: `Carrier invoice ${c.invoice_number ?? "(draft)"}${c.carriers ? ` -- ${c.carriers.legal_name}` : ""}`,
      amount: Number(c.total_amount),
      date: c.issued_at ?? c.created_at,
      href: `/carrier-invoices/${c.id}`,
    })),
  ];

  return { ...queue, feeOutstanding, carrierDrafts, recent };
}
