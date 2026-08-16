import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopFilterBar, DesktopFilterField, desktopInputClass } from "@/components/desktop/filter-bar";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Reports -> Driver Pay: same driver_settlements/driver_settlement_items
// rows Finance -> Driver Settlements shows, just aggregated/filterable by
// driver/period/status -- no independent recalculation.
export default async function DriverPayReportPage({
  searchParams,
}: {
  searchParams: Promise<{ driver_id?: string; status?: string; start?: string; end?: string }>;
}) {
  const { driver_id, status, start, end } = await searchParams;
  const supabase = await createClient();

  const { data: drivers } = await supabase.from("drivers").select("id, first_name, last_name").order("first_name");

  let query = supabase
    .from("driver_settlements")
    .select("id, settlement_number, driver_id, period_start, period_end, gross_pay, deductions_amount, advances_amount, net_pay, amount_paid, balance_due, status, drivers(first_name, last_name)")
    .order("period_start", { ascending: false });
  if (driver_id) query = query.eq("driver_id", driver_id);
  if (status) query = query.eq("status", status);
  if (start) query = query.gte("period_start", start);
  if (end) query = query.lte("period_end", end);

  const { data: settlements } = await query;
  const rows = (settlements ?? []) as unknown as {
    id: string;
    settlement_number: string;
    driver_id: string;
    period_start: string;
    period_end: string;
    gross_pay: number;
    deductions_amount: number;
    advances_amount: number;
    net_pay: number;
    amount_paid: number;
    balance_due: number;
    status: string;
    drivers: { first_name: string; last_name: string } | null;
  }[];

  const settlementIds = rows.map((r) => r.id);
  const { data: tripCounts } = settlementIds.length
    ? await supabase.from("driver_settlement_items").select("driver_settlement_id").in("driver_settlement_id", settlementIds)
    : { data: [] };
  const tripsBySettlement = new Map<string, number>();
  for (const t of tripCounts ?? []) tripsBySettlement.set(t.driver_settlement_id, (tripsBySettlement.get(t.driver_settlement_id) ?? 0) + 1);

  const totals = rows.reduce(
    (acc, r) => ({
      trips: acc.trips + (tripsBySettlement.get(r.id) ?? 0),
      gross: acc.gross + Number(r.gross_pay),
      deductions: acc.deductions + Number(r.deductions_amount),
      advances: acc.advances + Number(r.advances_amount),
      net: acc.net + Number(r.net_pay),
      paid: acc.paid + Number(r.amount_paid),
      outstanding: acc.outstanding + Number(r.balance_due),
    }),
    { trips: 0, gross: 0, deductions: 0, advances: 0, net: 0, paid: 0, outstanding: 0 }
  );

  return (
    <div className="space-y-3">
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Driver Pay Report</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">Trips, gross pay, deductions, advances, net pay, and outstanding balances by driver settlement.</p>
      </div>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Trips" value={totals.trips} />
        <DesktopKpiBox label="Gross Pay" value={money(totals.gross)} />
        <DesktopKpiBox label="Deductions" value={money(totals.deductions)} tone="warning" />
        <DesktopKpiBox label="Advances" value={money(totals.advances)} tone="warning" />
        <DesktopKpiBox label="Net Pay" value={money(totals.net)} tone="primary" />
        <DesktopKpiBox label="Paid" value={money(totals.paid)} tone="success" />
        <DesktopKpiBox label="Outstanding" value={money(totals.outstanding)} tone={totals.outstanding > 0 ? "warning" : "success"} />
      </DesktopKpiStrip>

      <DesktopFilterBar>
        <form method="GET" className="flex flex-wrap items-end gap-2">
          <DesktopFilterField label="Driver">
            <select name="driver_id" defaultValue={driver_id ?? ""} className={desktopInputClass + " w-52"}>
              <option value="">All Drivers</option>
              {(drivers ?? []).map((d) => (<option key={d.id} value={d.id}>{d.first_name} {d.last_name}</option>))}
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Status">
            <select name="status" defaultValue={status ?? ""} className={desktopInputClass + " w-40"}>
              <option value="">All Statuses</option>
              <option value="draft">Draft</option>
              <option value="approved">Approved</option>
              <option value="partially_paid">Partially Paid</option>
              <option value="paid">Paid</option>
              <option value="void">Void</option>
            </select>
          </DesktopFilterField>
          <DesktopFilterField label="Period Start">
            <input type="date" name="start" defaultValue={start} className={desktopInputClass} />
          </DesktopFilterField>
          <DesktopFilterField label="Period End">
            <input type="date" name="end" defaultValue={end} className={desktopInputClass} />
          </DesktopFilterField>
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">Filter</button>
          <Link href="/reports/driver-pay" className="h-7 rounded-sm border border-desktop-border px-3 text-[12px] font-medium leading-7 hover:bg-muted">Reset</Link>
        </form>
      </DesktopFilterBar>

      <DesktopPanel>
        <DesktopPanelHeader title="Settlements" />
        <DesktopPanelBody className="overflow-auto">
          {rows.length === 0 ? (
            <EmptyState title="No driver settlements match these filters" description="Adjust the filters or create a new settlement." />
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Settlement #</th>
                  <th className="py-1.5 pr-3">Driver</th>
                  <th className="py-1.5 pr-3">Period</th>
                  <th className="py-1.5 pr-3 text-right">Trips</th>
                  <th className="py-1.5 pr-3 text-right">Gross</th>
                  <th className="py-1.5 pr-3 text-right">Deductions</th>
                  <th className="py-1.5 pr-3 text-right">Advances</th>
                  <th className="py-1.5 pr-3 text-right">Net</th>
                  <th className="py-1.5 pr-3 text-right">Paid</th>
                  <th className="py-1.5 pr-3 text-right">Outstanding</th>
                  <th className="py-1.5 pr-3">Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className="border-b border-desktop-border last:border-0">
                    <td className="py-1.5 pr-3 font-medium"><Link href={`/driver-settlements/${r.id}`} className="text-primary hover:underline">{r.settlement_number}</Link></td>
                    <td className="py-1.5 pr-3">{r.drivers ? `${r.drivers.first_name} ${r.drivers.last_name}` : "--"}</td>
                    <td className="py-1.5 pr-3 whitespace-nowrap">{new Date(r.period_start + "T00:00:00").toLocaleDateString()} - {new Date(r.period_end + "T00:00:00").toLocaleDateString()}</td>
                    <td className="py-1.5 pr-3 text-right">{tripsBySettlement.get(r.id) ?? 0}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.gross_pay)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.deductions_amount)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.advances_amount)}</td>
                    <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{money(r.net_pay)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.amount_paid)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.balance_due)}</td>
                    <td className="py-1.5 pr-3"><StatusBadge status={r.status} /></td>
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
