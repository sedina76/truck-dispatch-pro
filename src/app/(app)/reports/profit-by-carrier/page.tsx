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

// Reports -> Profit by Carrier: the COMPANY's margin on loads run by each
// carrier -- distinct from Reports -> Carrier Pay (what the carrier
// itself earned). Same canonical source (get_profitability_by_carrier,
// 0037_profitability.sql), a GROUP BY over get_load_profitability().
export default async function ProfitByCarrierPage({
  searchParams,
}: {
  searchParams: Promise<{ start?: string; end?: string }>;
}) {
  const { start, end } = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_profitability_by_carrier", { p_period_start: start || null, p_period_end: end || null });
  const rows = (data ?? []) as {
    carrier_id: string; carrier_name: string; load_count: number; total_revenue: number;
    total_transportation_cost: number; total_gross_profit: number; avg_margin_percent: number | null;
  }[];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Reports", href: "/reports" }, { label: "Profitability", href: "/reports/profitability" }, { label: "Profit by Carrier", href: "/reports/profit-by-carrier" }]} />
      <PageHeader title="Profit by Carrier" description="Company margin on loads run by each carrier -- revenue minus what the carrier was paid, not the carrier's own settlement figures." />

      <DesktopFilterBar>
        <form className="flex flex-wrap items-end gap-2" action="/reports/profit-by-carrier">
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
        <DesktopPanelHeader title="By Carrier" />
        <DesktopPanelBody className="overflow-auto p-0">
          {rows.length === 0 ? (
            <div className="p-4"><EmptyState title="No data" description="No delivered loads with a carrier assigned yet." /></div>
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pl-3 pr-3">Carrier</th>
                  <th className="py-1.5 pr-3 text-right">Loads</th>
                  <th className="py-1.5 pr-3 text-right">Revenue</th>
                  <th className="py-1.5 pr-3 text-right">Carrier Cost</th>
                  <th className="py-1.5 pr-3 text-right">Gross Profit</th>
                  <th className="py-1.5 pr-3 text-right">Margin %</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.carrier_id} className="border-b border-desktop-border last:border-0 hover:bg-desktop-muted/50">
                    <td className="py-1.5 pl-3 pr-3 font-medium">
                      <Link href={`/carriers/${r.carrier_id}`} className="text-primary hover:underline">{r.carrier_name}</Link>
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
