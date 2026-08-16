import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";

function money(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function pct(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `${Number(n).toFixed(1)}%`;
}

// Reports -> Profit by Driver: company margin on loads run by each
// company driver. Internal staff report only, under (app) -- the Driver
// Portal (a completely separate route tree/auth scope) never calls this
// or any other profitability RPC.
export default async function ProfitByDriverPage({
  searchParams,
}: {
  searchParams: Promise<{ start?: string; end?: string }>;
}) {
  const { start, end } = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_profitability_by_driver", { p_period_start: start || null, p_period_end: end || null });
  const rows = (data ?? []) as {
    driver_id: string; driver_name: string; load_count: number; total_revenue: number;
    total_transportation_cost: number; total_gross_profit: number; avg_margin_percent: number | null;
  }[];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Reports", href: "/reports" }, { label: "Profitability", href: "/reports/profitability" }, { label: "Profit by Driver", href: "/reports/profit-by-driver" }]} />
      <PageHeader title="Profit by Driver" description="Company margin on loads run by each company driver (internal only -- never shown in the Driver Portal)." />

      <DesktopFilterBar>
        <form className="flex flex-wrap items-end gap-2" action="/reports/profit-by-driver">
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
        <DesktopPanelHeader title="By Driver" />
        <DesktopPanelBody className="overflow-auto p-0">
          {rows.length === 0 ? (
            <div className="p-4"><EmptyState title="No data" description="No delivered loads run by a driver with a resolvable transportation cost yet." /></div>
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pl-3 pr-3">Driver</th>
                  <th className="py-1.5 pr-3 text-right">Loads</th>
                  <th className="py-1.5 pr-3 text-right">Revenue</th>
                  <th className="py-1.5 pr-3 text-right">Transportation Cost</th>
                  <th className="py-1.5 pr-3 text-right">Gross Profit</th>
                  <th className="py-1.5 pr-3 text-right">Margin %</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.driver_id} className="border-b border-desktop-border last:border-0 hover:bg-desktop-muted/50">
                    <td className="py-1.5 pl-3 pr-3 font-medium">
                      <Link href={`/drivers/${r.driver_id}`} className="text-primary hover:underline">{r.driver_name}</Link>
                    </td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{r.load_count}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{money(r.total_revenue)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{money(r.total_transportation_cost)}</td>
                    <td className={`py-1.5 pr-3 text-right tabular-nums font-medium ${r.total_gross_profit >= 0 ? "text-desktop-success" : "text-desktop-danger"}`}>{money(r.total_gross_profit)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{pct(r.avg_margin_percent)}</td>
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
