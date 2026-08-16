import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

export default async function ExpenseReportsPage({
  searchParams,
}: {
  searchParams: Promise<{ start?: string; end?: string }>;
}) {
  const { start, end } = await searchParams;
  const supabase = await createClient();

  const [{ data: summary }, { data: byCategory }, { data: trend }, { data: trucks }] = await Promise.all([
    supabase.rpc("get_expense_summary", { p_period_start: start || null, p_period_end: end || null }).single(),
    supabase.rpc("get_expense_by_category", { p_period_start: start || null, p_period_end: end || null }),
    supabase.rpc("get_expense_monthly_trend", { p_period_start: start || null, p_period_end: end || null }),
    supabase.from("trucks").select("id, unit_number").order("unit_number"),
  ]);

  const s = summary as {
    total_count: number; total_amount: number; direct_load_total: number;
    truck_fleet_total: number; general_overhead_total: number; pending_count: number; pending_amount: number;
  } | null;
  const categories = (byCategory ?? []) as { category: string; expense_count: number; total_amount: number; percent_of_total: number | null }[];
  const months = (trend ?? []) as { month: string; direct_load_total: number; truck_fleet_total: number; general_overhead_total: number; total_amount: number }[];

  // Cost by Truck (spec section 37): one RPC call per truck would be an
  // N+1 -- instead call get_truck_expense_summary(null, ...) once and let
  // Postgres aggregate across every truck in a single query.
  const { data: byTruckRaw } = await supabase.rpc("get_truck_expense_summary", { p_truck_id: null, p_period_start: start || null, p_period_end: end || null });
  const byTruck = (byTruckRaw ?? []) as { truck_id: string; expense_count: number; total_amount: number }[];
  const truckNameById = new Map((trucks ?? []).map((t) => [t.id, t.unit_number]));

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Reports", href: "/reports" }, { label: "Expenses", href: "/reports/expenses" }]} />
      <RegisterDesktopActions title="Expense Reports" printInPlace exportOptions={[{ label: "Export All Expenses (CSV)", href: `/expenses/export?${start ? `start=${start}&` : ""}${end ? `end=${end}` : ""}` }]} />
      <PageHeader title="Expenses" description="Direct load costs, fleet/truck costs, and general overhead -- by category, by truck, and over time." />

      <DesktopFilterBar>
        <form className="flex flex-wrap items-end gap-2" action="/reports/expenses">
          <DesktopFilterField label="From">
            <input type="date" name="start" defaultValue={start} className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="To">
            <input type="date" name="end" defaultValue={end} className={desktopInputClass} />
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">Apply</button>
          <Link href="/expenses" className="flex h-7 items-center rounded-sm px-2 text-[12px] font-medium text-muted-foreground hover:bg-desktop-muted">Open Expense List</Link>
          <Link href="/reports/load-margin" className="flex h-7 items-center rounded-sm px-2 text-[12px] font-medium text-muted-foreground hover:bg-desktop-muted">Cost by Load (Load Margin) &rarr;</Link>
        </form>
      </DesktopFilterBar>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Expenses" value={money(s?.total_amount ?? 0)} />
        <DesktopKpiBox label="Direct Load Costs" value={money(s?.direct_load_total ?? 0)} />
        <DesktopKpiBox label="Truck / Fleet Costs" value={money(s?.truck_fleet_total ?? 0)} />
        <DesktopKpiBox label="General Overhead" value={money(s?.general_overhead_total ?? 0)} />
        <DesktopKpiBox label="Unapproved" value={`${s?.pending_count ?? 0} (${money(s?.pending_amount ?? 0)})`} tone={s && s.pending_count > 0 ? "warning" : "neutral"} />
      </DesktopKpiStrip>

      <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
        <DesktopPanel>
          <DesktopPanelHeader title="Cost by Category" />
          <DesktopPanelBody className="overflow-auto p-0">
            {categories.length === 0 ? (
              <div className="p-4"><EmptyState title="No expenses" description="No approved/paid expenses in this period." /></div>
            ) : (
              <table className="w-full text-[12.5px]">
                <thead>
                  <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                    <th className="py-1.5 pl-3 pr-3">Category</th>
                    <th className="py-1.5 pr-3 text-right">Count</th>
                    <th className="py-1.5 pr-3 text-right">Amount</th>
                    <th className="py-1.5 pr-3 text-right">% of Total</th>
                  </tr>
                </thead>
                <tbody>
                  {categories.map((c) => (
                    <tr key={c.category} className="border-b border-desktop-border last:border-0">
                      <td className="py-1.5 pl-3 pr-3 capitalize">{c.category.replace(/_/g, " ")}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{c.expense_count}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums font-medium">{money(c.total_amount)}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{c.percent_of_total != null ? `${Number(c.percent_of_total).toFixed(1)}%` : "--"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </DesktopPanelBody>
        </DesktopPanel>

        <DesktopPanel>
          <DesktopPanelHeader title="Cost by Truck" />
          <DesktopPanelBody className="overflow-auto p-0">
            {byTruck.length === 0 ? (
              <div className="p-4"><EmptyState title="No truck expenses" description="No approved/paid truck-scoped expenses in this period." /></div>
            ) : (
              <table className="w-full text-[12.5px]">
                <thead>
                  <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                    <th className="py-1.5 pl-3 pr-3">Truck</th>
                    <th className="py-1.5 pr-3 text-right">Count</th>
                    <th className="py-1.5 pr-3 text-right">Total</th>
                  </tr>
                </thead>
                <tbody>
                  {byTruck.map((t) => (
                    <tr key={t.truck_id} className="border-b border-desktop-border last:border-0">
                      <td className="py-1.5 pl-3 pr-3 font-medium">
                        <Link href={`/trucks/${t.truck_id}`} className="text-primary hover:underline">{truckNameById.get(t.truck_id) ?? t.truck_id}</Link>
                      </td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{t.expense_count}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums font-medium">{money(t.total_amount)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </DesktopPanelBody>
        </DesktopPanel>
      </div>

      <DesktopPanel>
        <DesktopPanelHeader title="Monthly Expense Trend" />
        <DesktopPanelBody className="overflow-auto p-0">
          {months.length === 0 ? (
            <div className="p-4"><EmptyState title="No data" description="No approved/paid expenses yet." /></div>
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pl-3 pr-3">Month</th>
                  <th className="py-1.5 pr-3 text-right">Direct Load Costs</th>
                  <th className="py-1.5 pr-3 text-right">Truck / Fleet Costs</th>
                  <th className="py-1.5 pr-3 text-right">General Overhead</th>
                  <th className="py-1.5 pr-3 text-right">Total</th>
                </tr>
              </thead>
              <tbody>
                {months.map((m) => (
                  <tr key={m.month} className="border-b border-desktop-border last:border-0">
                    <td className="py-1.5 pl-3 pr-3 font-medium">{new Date(m.month + "T00:00:00").toLocaleDateString(undefined, { year: "numeric", month: "short" })}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(m.direct_load_total)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(m.truck_fleet_total)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(m.general_overhead_total)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums font-medium">{money(m.total_amount)}</td>
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
