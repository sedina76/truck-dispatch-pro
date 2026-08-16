import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { PageHeader } from "@/components/ui/page-header";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

function money(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function pct(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `${Number(n).toFixed(1)}%`;
}

// Analytics/Reports -> Profitability: the overview landing page. Every
// number here comes from get_profitability_summary()/get_profitability_
// by_period() (0037_profitability.sql) -- the same canonical
// get_load_profitability() source every other profitability surface in
// the app reads from. Nothing on this page recomputes revenue, cost, or
// margin independently.
export default async function ProfitabilityReportPage({
  searchParams,
}: {
  searchParams: Promise<{ start?: string; end?: string }>;
}) {
  const { start, end } = await searchParams;
  const supabase = await createClient();

  const [{ data: summary }, { data: monthly }] = await Promise.all([
    supabase.rpc("get_profitability_summary", { p_period_start: start || null, p_period_end: end || null }).single(),
    supabase.rpc("get_profitability_by_period", { p_granularity: "month", p_period_start: start || null, p_period_end: end || null }),
  ]);

  const s = summary as {
    load_count: number;
    complete_count: number;
    estimated_count: number;
    missing_cost_count: number;
    missing_revenue_count: number;
    total_revenue: number;
    total_transportation_cost: number;
    total_gross_profit: number;
    avg_margin_percent: number | null;
    total_miles: number;
    avg_revenue_per_mile: number | null;
    avg_profit_per_mile: number | null;
  } | null;

  const months = (monthly ?? []) as {
    period_start: string;
    load_count: number;
    total_revenue: number;
    total_transportation_cost: number;
    total_gross_profit: number;
    avg_margin_percent: number | null;
  }[];

  const REPORT_LINKS = [
    { title: "Load Margin", href: "/reports/load-margin", description: "Every delivered load, one row each, with the full revenue/cost/margin breakdown." },
    { title: "Profit by Broker / Customer", href: "/reports/profit-by-broker", description: "Aggregated margin by broker or customer." },
    { title: "Profit by Carrier", href: "/reports/profit-by-carrier", description: "Company margin on loads run by each carrier." },
    { title: "Profit by Driver", href: "/reports/profit-by-driver", description: "Company margin on loads run by each company driver. Internal staff only." },
    { title: "Lane Profitability", href: "/reports/lane-profitability", description: "Margin by origin/destination lane." },
  ];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Reports", href: "/reports" }, { label: "Profitability", href: "/reports/profitability" }]} />
      <RegisterDesktopActions
        title="Profitability Report"
        printInPlace
        exportOptions={[
          { label: "Export Load Detail (CSV)", href: `/reports/load-margin/export${start || end ? `?${new URLSearchParams({ ...(start ? { start } : {}), ...(end ? { end } : {}) }).toString()}` : ""}` },
        ]}
      />
      <PageHeader title="Profitability" description="Load-level margin, rolled up. One canonical source (get_load_profitability) feeds every figure on this page and every breakdown below." />

      <DesktopFilterBar>
        <form className="flex flex-wrap items-end gap-2" action="/reports/profitability">
          <DesktopFilterField label="Delivered From">
            <input type="date" name="start" defaultValue={start} className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="Delivered To">
            <input type="date" name="end" defaultValue={end} className={desktopInputClass} />
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">
            Apply
          </button>
          {(start || end) && (
            <Link href="/reports/profitability" className="h-7 rounded-sm px-2 text-[12px] font-medium text-muted-foreground hover:bg-desktop-muted flex items-center">
              Clear
            </Link>
          )}
        </form>
      </DesktopFilterBar>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Delivered Loads" value={s?.load_count ?? 0} />
        <DesktopKpiBox label="Total Revenue" value={money(s?.total_revenue ?? 0)} />
        <DesktopKpiBox label="Total Transportation Cost" value={money(s?.total_transportation_cost ?? 0)} tone="warning" />
        <DesktopKpiBox label="Gross Profit" value={money(s?.total_gross_profit ?? 0)} tone={(s?.total_gross_profit ?? 0) >= 0 ? "success" : "danger"} />
        <DesktopKpiBox label="Avg Margin %" value={pct(s?.avg_margin_percent ?? null)} tone="primary" />
        <DesktopKpiBox label="Avg Revenue / Mile" value={s?.avg_revenue_per_mile != null ? `$${Number(s.avg_revenue_per_mile).toFixed(2)}` : "--"} />
        <DesktopKpiBox label="Avg Profit / Mile" value={s?.avg_profit_per_mile != null ? `$${Number(s.avg_profit_per_mile).toFixed(2)}` : "--"} />
      </DesktopKpiStrip>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Complete" value={s?.complete_count ?? 0} tone="success" href="/reports/load-margin?status=COMPLETE" />
        <DesktopKpiBox label="Estimated" value={s?.estimated_count ?? 0} tone="primary" href="/reports/load-margin?status=ESTIMATED" />
        <DesktopKpiBox label="Missing Cost" value={s?.missing_cost_count ?? 0} tone="warning" href="/reports/load-margin?status=MISSING_COST" />
        <DesktopKpiBox label="Missing Revenue" value={s?.missing_revenue_count ?? 0} tone="warning" href="/reports/load-margin?status=MISSING_REVENUE" />
      </DesktopKpiStrip>

      <div className="grid grid-cols-1 gap-2 md:grid-cols-3">
        {REPORT_LINKS.map((r) => (
          <Link key={r.href} href={r.href} className="rounded-md border border-desktop-border bg-desktop-panel p-3 shadow-elevation-1 transition-colors hover:border-primary/40">
            <p className="text-[13px] font-medium">{r.title}</p>
            <p className="mt-0.5 text-xs text-muted-foreground">{r.description}</p>
          </Link>
        ))}
      </div>

      <DesktopPanel>
        <DesktopPanelHeader title="Revenue, Cost & Margin by Month" />
        <DesktopPanelBody className="overflow-auto">
          <table className="w-full text-[12.5px]">
            <thead>
              <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                <th className="py-1.5 pr-3">Month</th>
                <th className="py-1.5 pr-3 text-right">Loads</th>
                <th className="py-1.5 pr-3 text-right">Revenue</th>
                <th className="py-1.5 pr-3 text-right">Transportation Cost</th>
                <th className="py-1.5 pr-3 text-right">Gross Profit</th>
                <th className="py-1.5 text-right">Margin %</th>
              </tr>
            </thead>
            <tbody>
              {months.map((m) => (
                <tr key={m.period_start} className="border-b border-desktop-border last:border-0">
                  <td className="py-1.5 pr-3 font-medium">{new Date(m.period_start + "T00:00:00").toLocaleDateString(undefined, { year: "numeric", month: "short" })}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{m.load_count}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{money(m.total_revenue)}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">{money(m.total_transportation_cost)}</td>
                  <td className={`py-1.5 pr-3 text-right tabular-nums font-medium ${m.total_gross_profit >= 0 ? "text-desktop-success" : "text-desktop-danger"}`}>{money(m.total_gross_profit)}</td>
                  <td className="py-1.5 text-right tabular-nums">{pct(m.avg_margin_percent)}</td>
                </tr>
              ))}
              {months.length === 0 && (
                <tr><td colSpan={6} className="py-3 text-center text-muted-foreground">No delivered loads yet.</td></tr>
              )}
            </tbody>
          </table>
        </DesktopPanelBody>
      </DesktopPanel>
    </div>
  );
}
