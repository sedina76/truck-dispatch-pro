import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { PageHeader } from "@/components/ui/page-header";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

function money(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function pct(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `${Number(n).toFixed(1)}%`;
}

type Row = {
  load_id: string;
  load_number: string;
  delivery_date: string | null;
  origin_city: string | null;
  origin_state: string | null;
  destination_city: string | null;
  destination_state: string | null;
  miles: number | null;
  revenue: number | null;
  revenue_source: string | null;
  transportation_cost: number | null;
  transportation_cost_source: string | null;
  gross_profit: number | null;
  margin_percent: number | null;
  profitability_status: string;
};

// Reports -> Load Margin: every delivered load, one row, straight from
// get_load_profitability(null) (0037_profitability.sql) -- a single
// set-based query, not one RPC call per load.
export default async function LoadMarginReportPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; start?: string; end?: string }>;
}) {
  const { status, start, end } = await searchParams;
  const supabase = await createClient();

  // Filters are pushed down to Postgres (PostgREST filters a table-valued
  // RPC's result set same as a real table) -- this stays one set-based
  // query, never a fetch-everything-then-filter-in-Node pass.
  let query = supabase.rpc("get_load_profitability", { p_load_id: null }).neq("profitability_status", "NOT_DELIVERED");
  if (status) query = query.eq("profitability_status", status);
  if (start) query = query.gte("delivery_date", start);
  if (end) query = query.lte("delivery_date", end);
  const { data } = await query.order("delivery_date", { ascending: false, nullsFirst: false });
  const rows = (data ?? []) as Row[];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Reports", href: "/reports" }, { label: "Profitability", href: "/reports/profitability" }, { label: "Load Margin", href: "/reports/load-margin" }]} />
      <RegisterDesktopActions
        title="Load Margin Report"
        printInPlace
        exportOptions={[
          {
            label: "Export CSV (Filtered)",
            href: `/reports/load-margin/export?${new URLSearchParams({ ...(status ? { status } : {}), ...(start ? { start } : {}), ...(end ? { end } : {}) }).toString()}`,
          },
        ]}
      />
      <PageHeader title="Load Margin" description="Revenue, transportation cost, and margin for every delivered load." />

      <DesktopFilterBar>
        <form className="flex flex-wrap items-end gap-2" action="/reports/load-margin">
          <DesktopFilterField label="Status">
            <select name="status" defaultValue={status ?? ""} className={desktopInputClass}>
              <option value="">All</option>
              <option value="COMPLETE">Complete</option>
              <option value="ESTIMATED">Estimated</option>
              <option value="MISSING_COST">Missing Cost</option>
              <option value="MISSING_REVENUE">Missing Revenue</option>
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Delivered From">
            <input type="date" name="start" defaultValue={start} className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="Delivered To">
            <input type="date" name="end" defaultValue={end} className={desktopInputClass} />
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">
            Apply
          </button>
          {(status || start || end) && (
            <Link href="/reports/load-margin" className="flex h-7 items-center rounded-sm px-2 text-[12px] font-medium text-muted-foreground hover:bg-desktop-muted">
              Clear
            </Link>
          )}
        </form>
      </DesktopFilterBar>

      <DesktopPanel>
        <DesktopPanelHeader title={`Loads (${rows.length})`} />
        <DesktopPanelBody className="overflow-auto p-0">
          {rows.length === 0 ? (
            <div className="p-4"><EmptyState title="No matching loads" description="Adjust filters or check back once loads are delivered." /></div>
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pl-3 pr-3">Load #</th>
                  <th className="py-1.5 pr-3">Delivered</th>
                  <th className="py-1.5 pr-3">Lane</th>
                  <th className="py-1.5 pr-3 text-right">Miles</th>
                  <th className="py-1.5 pr-3 text-right">Revenue</th>
                  <th className="py-1.5 pr-3 text-right">Transportation Cost</th>
                  <th className="py-1.5 pr-3 text-right">Gross Profit</th>
                  <th className="py-1.5 pr-3 text-right">Margin %</th>
                  <th className="py-1.5 pr-3">Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.load_id} className="border-b border-desktop-border last:border-0 hover:bg-desktop-muted/50">
                    <td className="py-1.5 pl-3 pr-3 font-medium">
                      <Link href={`/loads/${r.load_id}`} className="text-primary hover:underline">{r.load_number}</Link>
                    </td>
                    <td className="py-1.5 pr-3 text-muted-foreground">{r.delivery_date ? new Date(r.delivery_date + "T00:00:00").toLocaleDateString() : "--"}</td>
                    <td className="py-1.5 pr-3 text-muted-foreground">
                      {r.origin_city ? `${r.origin_city}, ${r.origin_state}` : "--"} &rarr; {r.destination_city ? `${r.destination_city}, ${r.destination_state}` : "--"}
                    </td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{r.miles ?? "--"}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.revenue)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">
                      {money(r.transportation_cost)}
                      {r.transportation_cost_source && <span className="ml-1 text-[10px] text-muted-foreground">({r.transportation_cost_source.includes("estimated") ? "est." : "final"})</span>}
                    </td>
                    <td className={`py-1.5 pr-3 text-right tabular-nums font-medium ${(r.gross_profit ?? 0) >= 0 ? "text-desktop-success" : "text-desktop-danger"}`}>{money(r.gross_profit)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{pct(r.margin_percent)}</td>
                    <td className="py-1.5 pr-3"><StatusBadge status={r.profitability_status} /></td>
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
