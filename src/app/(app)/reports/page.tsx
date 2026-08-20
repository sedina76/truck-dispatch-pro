import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { ChevronRight } from "lucide-react";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";

const REPORTS = [
  { title: "Revenue", href: "/reports/revenue", description: "Revenue booked and collected over time." },
  { title: "Accounts Receivable Aging", href: "/reports/accounts-receivable", description: "Outstanding balances by age, with broker/customer/status filters and drill-down." },
  { title: "Carrier Performance", href: "/reports/carrier-performance", description: "Dispatch volume and payout by carrier." },
  { title: "Broker Performance", href: "/reports/broker-performance", description: "Load volume and average days to pay by broker." },
  { title: "Driver Pay", href: "/reports/driver-pay", description: "Trips, gross pay, deductions, advances, and net pay by driver settlement." },
  { title: "Carrier Pay", href: "/reports/carrier-pay", description: "Loads, customer revenue, carrier pay, deductions, Quick Pay fees, net pay, and margin by carrier settlement." },
  { title: "Profitability", href: "/reports/profitability", description: "Company-wide revenue, transportation cost, and margin overview." },
  { title: "Load Margin", href: "/reports/load-margin", description: "Revenue, cost, and margin for every delivered load." },
  { title: "Profit by Broker / Customer", href: "/reports/profit-by-broker", description: "Company margin aggregated by who booked the load." },
  { title: "Profit by Carrier", href: "/reports/profit-by-carrier", description: "Company margin on loads run by each carrier." },
  { title: "Profit by Driver", href: "/reports/profit-by-driver", description: "Company margin on loads run by each company driver. Internal staff only." },
  { title: "Lane Profitability", href: "/reports/lane-profitability", description: "Margin by origin/destination lane." },
  { title: "Expenses", href: "/reports/expenses", description: "Direct load costs, truck/fleet costs, and general overhead -- by category, by truck, and over time." },
];

export default async function ReportsPage() {
  const supabase = await createClient();

  // Phase 2G.12 (found during the final legacy-column search): `rate`
  // dropped from this select -- load_financials is authoritative now
  // (0068 writer cutover). No additional role gating needed -- this whole
  // route is already layout-guarded to FINANCIAL_ROLES (reports/layout.tsx).
  const [{ data: loads }, { data: invoices }, { data: settlements }, { data: loadFinancials }] = await Promise.all([
    supabase.from("loads").select("id, status"),
    supabase.from("invoices").select("total_amount, amount_paid"),
    supabase.from("settlements").select("net_amount, status"),
    supabase.from("load_financials").select("load_id, rate"),
  ]);
  const rateByLoadId = new Map((loadFinancials ?? []).map((r) => [r.load_id, Number(r.rate)]));

  const totalBooked = (loads ?? []).reduce((sum, l) => sum + (rateByLoadId.get(l.id) ?? 0), 0);
  const totalCollected = (invoices ?? []).reduce((sum, i) => sum + Number(i.amount_paid), 0);
  const totalPayouts = (settlements ?? [])
    .filter((s) => s.status === "paid")
    .reduce((sum, s) => sum + Number(s.net_amount), 0);

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Reports", href: "/reports" }]} />
      <PageHeader
        title="Reports"
        description="Revenue, carrier performance, and broker performance reporting."
      />

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Revenue Booked" value={`$${totalBooked.toLocaleString()}`} />
        <DesktopKpiBox label="Total Collected" value={`$${totalCollected.toLocaleString()}`} tone="success" />
        <DesktopKpiBox label="Total Carrier Payouts" value={`$${totalPayouts.toLocaleString()}`} />
      </DesktopKpiStrip>

      <div className="grid grid-cols-1 gap-2 md:grid-cols-3">
        {REPORTS.map((report) => (
          <Link
            key={report.href}
            href={report.href}
            className="flex items-center justify-between rounded-md border border-desktop-border bg-card p-3 shadow-elevation-1 transition-colors hover:border-primary/40"
          >
            <div>
              <p className="text-[13px] font-medium">{report.title}</p>
              <p className="mt-0.5 text-xs text-muted-foreground">{report.description}</p>
            </div>
            <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
          </Link>
        ))}
      </div>
    </div>
  );
}
