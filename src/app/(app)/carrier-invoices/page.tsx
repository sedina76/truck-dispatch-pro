import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { BillingSubnav } from "@/components/desktop/billing-subnav";

function money(n: number | string): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

// Carrier invoices: the carrier's own invoice to the broker for "broker pays
// the carrier" loads -- the one a factoring company buys. RLS-scoped; a
// different table from your own broker invoices.
export default async function CarrierInvoicesPage() {
  const supabase = await createClient();
  const { data: invoices } = await supabase
    .from("carrier_invoices")
    .select("id, invoice_number, invoice_document_type, issuance_status, payment_status, currency, total_amount, created_at, carriers(legal_name, dba_name), brokers:recipient_broker_id(company_name), customers:recipient_customer_id(company_name)")
    .eq("invoice_document_type", "carrier_freight_invoice")
    .order("created_at", { ascending: false })
    .limit(200);
  const rows = (invoices ?? []) as unknown as {
    id: string; invoice_number: string | null; issuance_status: string; payment_status: string; total_amount: number; created_at: string;
    carriers: { legal_name: string; dba_name: string | null } | null; brokers: { company_name: string } | null; customers: { company_name: string } | null;
  }[];
  return (
    <div className="space-y-3">
      <BillingSubnav />
      <div className="flex items-center justify-between gap-3">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Carrier Invoices</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            The carrier&apos;s own invoice to the broker for &quot;broker pays the carrier&quot; loads, with the paperwork package for their factoring company. Your dispatch fee goes on a Dispatch Fee Invoice.
          </p>
        </div>
        <Link href="/carrier-invoices/new" className="inline-flex h-8 shrink-0 items-center rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground hover:bg-primary-hover">
          New Carrier Invoice
        </Link>
      </div>
      <DesktopPanel>
        <DesktopPanelHeader title="Invoices" />
        <DesktopPanelBody className="overflow-auto">
          {rows.length === 0 ? (
            <EmptyState title="No carrier invoices yet" description="Create one from a carrier's delivered loads to send to their factoring company (or the broker)." action={{ label: "New Carrier Invoice", href: "/carrier-invoices/new" }} />
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Invoice #</th>
                  <th className="py-1.5 pr-3">Carrier</th>
                  <th className="py-1.5 pr-3">Bill to</th>
                  <th className="py-1.5 pr-3 text-right">Total</th>
                  <th className="py-1.5 pr-3">Status</th>
                  <th className="py-1.5 pr-3">Payment</th>
                  <th className="py-1.5"></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((i) => (
                  <tr key={i.id} className={"border-b border-desktop-border last:border-0" + (i.issuance_status === "voided" ? " opacity-60" : "")}>
                    <td className="py-1.5 pr-3 font-medium">{i.invoice_number ?? "(draft)"}</td>
                    <td className="py-1.5 pr-3">{i.carriers?.dba_name || i.carriers?.legal_name || "--"}</td>
                    <td className="py-1.5 pr-3">{i.brokers?.company_name ?? i.customers?.company_name ?? "--"}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(i.total_amount)}</td>
                    <td className="py-1.5 pr-3"><StatusBadge status={i.issuance_status} /></td>
                    <td className="py-1.5 pr-3"><StatusBadge status={i.payment_status} /></td>
                    <td className="py-1.5"><Link href={`/carrier-invoices/${i.id}`} className="text-xs font-medium text-primary hover:underline">View</Link></td>
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
