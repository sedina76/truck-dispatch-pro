import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import { cn } from "@/lib/utils";

function money(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function pct(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `${Number(n).toFixed(1)}%`;
}

type Row = {
  load_count: number;
  total_revenue: number;
  total_transportation_cost: number;
  total_gross_profit: number;
  avg_margin_percent: number | null;
};

// Reports -> Profit by Broker/Customer: both dimensions on one page (a
// toggle, not two independently-written pages) since they're the same
// aggregation shape -- get_profitability_by_broker() / _by_customer()
// (0037_profitability.sql), each just a GROUP BY over the canonical
// get_load_profitability() result.
export default async function ProfitByBrokerPage({
  searchParams,
}: {
  searchParams: Promise<{ dim?: string; start?: string; end?: string }>;
}) {
  const { dim, start, end } = await searchParams;
  const dimension = dim === "customer" ? "customer" : "broker";
  const supabase = await createClient();

  const { data } = await supabase.rpc(
    dimension === "customer" ? "get_profitability_by_customer" : "get_profitability_by_broker",
    { p_period_start: start || null, p_period_end: end || null }
  );

  const rows = (data ?? []) as (Row & { broker_id?: string; broker_name?: string; customer_id?: string; customer_name?: string })[];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Reports", href: "/reports" }, { label: "Profitability", href: "/reports/profitability" }, { label: "Profit by Broker/Customer", href: "/reports/profit-by-broker" }]} />
      <PageHeader title="Profit by Broker / Customer" description="Company margin aggregated by who booked the load." />

      <DesktopFilterBar>
        <div className="flex items-center gap-1 rounded-sm border border-desktop-border p-0.5">
          <Link href={{ pathname: "/reports/profit-by-broker", query: { dim: "broker", start, end } }} className={cn("rounded-sm px-2.5 py-1 text-[12px] font-medium", dimension === "broker" ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-desktop-muted")}>
            Broker
          </Link>
          <Link href={{ pathname: "/reports/profit-by-broker", query: { dim: "customer", start, end } }} className={cn("rounded-sm px-2.5 py-1 text-[12px] font-medium", dimension === "customer" ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-desktop-muted")}>
            Customer
          </Link>
        </div>
        <form className="flex flex-wrap items-end gap-2" action="/reports/profit-by-broker">
          <input type="hidden" name="dim" value={dimension} />
          <DesktopFilterField label="Delivered From">
            <input type="date" name="start" defaultValue={start} className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="Delivered To">
            <input type="date" name="end" defaultValue={end} className={desktopInputClass} />
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">
            Apply
          </button>
        </form>
      </DesktopFilterBar>

      <DesktopPanel>
        <DesktopPanelHeader title={dimension === "broker" ? "By Broker" : "By Customer"} />
        <DesktopPanelBody className="overflow-auto p-0">
          {rows.length === 0 ? (
            <div className="p-4"><EmptyState title="No data" description="No delivered loads with revenue for this period yet." /></div>
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pl-3 pr-3">{dimension === "broker" ? "Broker" : "Customer"}</th>
                  <th className="py-1.5 pr-3 text-right">Loads</th>
                  <th className="py-1.5 pr-3 text-right">Revenue</th>
                  <th className="py-1.5 pr-3 text-right">Transportation Cost</th>
                  <th className="py-1.5 pr-3 text-right">Gross Profit</th>
                  <th className="py-1.5 pr-3 text-right">Margin %</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const id = dimension === "broker" ? r.broker_id : r.customer_id;
                  const name = (dimension === "broker" ? r.broker_name : r.customer_name) ?? "Unassigned";
                  return (
                    <tr key={id ?? "none"} className="border-b border-desktop-border last:border-0 hover:bg-desktop-muted/50">
                      <td className="py-1.5 pl-3 pr-3 font-medium">
                        {id ? <Link href={`/${dimension === "broker" ? "brokers" : "customers"}/${id}`} className="text-primary hover:underline">{name}</Link> : name}
                      </td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{r.load_count}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{money(r.total_revenue)}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{money(r.total_transportation_cost)}</td>
                      <td className={`py-1.5 pr-3 text-right tabular-nums font-medium ${r.total_gross_profit >= 0 ? "text-desktop-success" : "text-desktop-danger"}`}>{money(r.total_gross_profit)}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{pct(r.avg_margin_percent)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </DesktopPanelBody>
      </DesktopPanel>
    </div>
  );
}
