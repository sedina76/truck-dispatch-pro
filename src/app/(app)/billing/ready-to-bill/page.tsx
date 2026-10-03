import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable, type Column } from "@/components/ui/data-table";
import { EmptyState } from "@/components/ui/empty-state";
import { BillingSubnav } from "@/components/desktop/billing-subnav";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { canUseBilling } from "@/lib/auth/billing-access";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { carrierPaidLoadsToInvoice } from "@/lib/billing/carrier-paid-loads";

// Phase 2G: the one real gap identified in an otherwise mature, already-
// production invoicing/AR/collections system -- delivered loads awaiting
// invoicing had no dedicated operational view. This page is a thin
// presentation layer over the canonical get_ready_to_bill_loads() RPC
// (0065_billing_readiness.sql); it computes nothing itself, so it can
// never disagree with what /invoices/new's own load picker considers
// candidate loads. "Ready to Bill" here is informational, not a hard
// gate -- every row is still linkable straight into Create Invoice
// regardless of readiness, exactly matching today's real behavior where
// only a verified POD blocks *sending* an invoice
// (check_invoice_ready_to_send(), 0023), never creating one.
//
// Phase 2G.5: moved from /billing (now the Billing Overview) to
// /billing/ready-to-bill -- same page, same RPC, same behavior, just its
// own slot in the Billing workspace's subnav (BillingSubnav) instead of
// occupying the workspace's root route. /billing existed for one prior
// review round with no external references, so nothing depends on the old
// path.
type ReadyRow = {
  load_id: string;
  load_number: string;
  status: string;
  customer_name: string | null;
  broker_name: string | null;
  origin_city: string | null;
  origin_state: string | null;
  destination_city: string | null;
  destination_state: string | null;
  delivered_at: string | null;
  rate: number | null;
  has_verified_pod: boolean;
  has_bol: boolean;
  bol_required: boolean;
  has_rate_confirmation: boolean;
  rate_confirmation_required: boolean;
  ready_to_bill: boolean;
};

// carrierName set = "broker pays the carrier" load: its invoice is the carrier's.
type Row = ReadyRow & { id: string; carrierName?: string | null };

export default async function BillingReadyToBillPage() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_ready_to_bill_loads");
  const { data: roleData } = await supabase.rpc("current_role");
  // Dispatchers see what is ready; invoicing itself is owner/admin/accountant.
  const canInvoice = canUseBilling(roleData as string | null);
  // "Broker pays the carrier" loads (not in get_ready_to_bill_loads): same
  // Create Invoice button, which makes the invoice in the carrier's name.
  const carrierPaid = canInvoice ? await carrierPaidLoadsToInvoice(supabase) : [];
  const rows: Row[] = [
    ...((data ?? []) as ReadyRow[]).map((r) => ({ ...r, id: r.load_id })),
    ...carrierPaid.map((l) => ({
      id: l.loadId,
      load_id: l.loadId,
      load_number: l.loadNumber,
      status: "delivered",
      customer_name: null,
      broker_name: l.billToName,
      origin_city: l.origin,
      origin_state: null,
      destination_city: l.destination,
      destination_state: null,
      delivered_at: l.deliveredAt,
      rate: l.rate,
      has_verified_pod: l.hasVerifiedPod,
      has_bol: true,
      bol_required: false,
      has_rate_confirmation: true,
      rate_confirmation_required: false,
      ready_to_bill: l.hasVerifiedPod,
      carrierName: l.carrierName,
    })),
  ];

  const readyCount = rows.filter((r) => r.ready_to_bill).length;
  const notReadyCount = rows.length - readyCount;
  const totalValue = rows.reduce((sum, r) => sum + Number(r.rate ?? 0), 0);

  const columns: Column<Row>[] = [
    { header: "Load #", cell: (row) => <span className="font-medium">{row.load_number}</span> },
    {
      header: "Bill To",
      cell: (row) => (
        <span>
          {row.broker_name ?? row.customer_name ?? <span className="text-muted-foreground">--</span>}
          {row.carrierName !== undefined && (
            <span className="block text-[10.5px] text-muted-foreground">Carrier&apos;s invoice{row.carrierName ? ` -- ${row.carrierName}` : ""}</span>
          )}
        </span>
      ),
    },
    {
      header: "Route",
      cell: (row) =>
        row.origin_city && row.destination_city ? (
          <span className="tabular-nums">
            {[row.origin_city, row.origin_state].filter(Boolean).join(", ")} &rarr; {[row.destination_city, row.destination_state].filter(Boolean).join(", ")}
          </span>
        ) : (
          "--"
        ),
    },
    {
      header: "Delivered",
      cell: (row) => (row.delivered_at ? new Date(row.delivered_at).toLocaleDateString() : "--"),
      sortKey: "delivered_at",
    },
    {
      header: "Rate",
      cell: (row) => <span className="tabular-nums">${Number(row.rate ?? 0).toLocaleString()}</span>,
      className: "text-right",
      sortKey: "rate",
    },
    {
      header: "Documents",
      cell: (row) => {
        const missing: string[] = [];
        if (!row.has_verified_pod) missing.push("POD");
        if (row.bol_required && !row.has_bol) missing.push("BOL");
        if (row.rate_confirmation_required && !row.has_rate_confirmation) missing.push("Rate Con");
        if (missing.length === 0) {
          return (
            <span className="inline-flex items-center gap-1.5 text-[12px] font-medium text-desktop-success">
              <span className="size-1.5 shrink-0 bg-desktop-success" />
              Complete
            </span>
          );
        }
        return (
          <span className="inline-flex items-center gap-1.5 text-[12px] font-medium text-desktop-warning">
            <span className="size-1.5 shrink-0 bg-desktop-warning" />
            Missing {missing.join(", ")}
          </span>
        );
      },
    },
    {
      header: "Action",
      cell: (row) => canInvoice ? (
        <a
          href={`/invoices/new?load_id=${row.load_id}`}
          className="inline-flex h-6 items-center rounded-sm bg-primary px-2.5 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover"
        >
          Create Invoice
        </a>
      ) : (
        <span className="text-[11.5px] text-muted-foreground">Billing team</span>
      ),
    },
  ];

  return (
    <div className="space-y-3">
      <BillingSubnav />
      <RegisterDesktopActions title="Ready to Bill" />

      <PageHeader
        title="Ready to Bill"
        description="Delivered loads awaiting invoicing. Documents are informational -- only a verified POD blocks sending an invoice."
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Ready to Bill" value={readyCount} tone={readyCount ? "success" : "neutral"} />
        <DesktopKpiBox label="Missing Documents" value={notReadyCount} tone={notReadyCount ? "warning" : "neutral"} />
        <DesktopKpiBox label="Queue Value" value={`$${totalValue.toLocaleString()}`} />
        <DesktopKpiBox label="Total Loads" value={rows.length} />
      </DesktopKpiStrip>

      {rows.length === 0 ? (
        <EmptyState
          title="Nothing waiting to be billed"
          description="Delivered loads without an invoice yet will appear here."
        />
      ) : (
        <DataTable columns={columns} rows={rows} getDetailHref={(row) => `/loads/${row.load_id}`} />
      )}
    </div>
  );
}
