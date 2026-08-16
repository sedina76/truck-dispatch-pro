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

export default async function DriverSettlementsPage({
  searchParams,
}: {
  searchParams: Promise<{ driver_id?: string; status?: string }>;
}) {
  const { driver_id, status } = await searchParams;
  const supabase = await createClient();

  const { data: drivers } = await supabase.from("drivers").select("id, first_name, last_name").order("first_name");

  let query = supabase
    .from("driver_settlements")
    .select("id, settlement_number, driver_id, period_start, period_end, gross_pay, deductions_amount, advances_amount, net_pay, amount_paid, balance_due, status, created_at, drivers(first_name, last_name)")
    .order("created_at", { ascending: false });
  if (driver_id) query = query.eq("driver_id", driver_id);
  if (status) query = query.eq("status", status);

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
    created_at: string;
    drivers: { first_name: string; last_name: string } | null;
  }[];

  const totalNet = rows.reduce((sum, r) => sum + Number(r.net_pay), 0);
  const totalOutstanding = rows.filter((r) => r.status !== "void").reduce((sum, r) => sum + Number(r.balance_due), 0);
  const draftCount = rows.filter((r) => r.status === "draft").length;
  const approvedCount = rows.filter((r) => r.status === "approved" || r.status === "partially_paid").length;

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Driver Settlements</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">Driver pay by period -- gross pay, deductions, advances, net pay, and payments.</p>
        </div>
        <Link href="/driver-settlements/new" className="inline-flex h-8 items-center rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground hover:bg-primary-hover">
          New Settlement
        </Link>
      </div>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Total Net Pay" value={money(totalNet)} />
        <DesktopKpiBox label="Outstanding Balance" value={money(totalOutstanding)} tone={totalOutstanding > 0 ? "warning" : "success"} />
        <DesktopKpiBox label="Draft" value={draftCount} />
        <DesktopKpiBox label="Approved / Partially Paid" value={approvedCount} tone={approvedCount > 0 ? "warning" : "neutral"} />
      </DesktopKpiStrip>

      <DesktopFilterBar>
        <form method="GET" className="flex flex-wrap items-end gap-2">
          <DesktopFilterField label="Driver">
            <select name="driver_id" defaultValue={driver_id ?? ""} className={desktopInputClass + " w-52"}>
              <option value="">All Drivers</option>
              {(drivers ?? []).map((d) => (
                <option key={d.id} value={d.id}>{d.first_name} {d.last_name}</option>
              ))}
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
          <button type="submit" className="h-7 rounded-sm bg-primary px-3 text-[12px] font-medium text-primary-foreground hover:bg-primary-hover">Filter</button>
          <Link href="/driver-settlements" className="h-7 rounded-sm border border-desktop-border px-3 text-[12px] font-medium leading-7 hover:bg-muted">Reset</Link>
        </form>
      </DesktopFilterBar>

      <DesktopPanel>
        <DesktopPanelHeader title="Settlements" />
        <DesktopPanelBody className="overflow-auto">
          {rows.length === 0 ? (
            <EmptyState title="No driver settlements yet" description="Create a settlement to start paying a driver for their completed loads." action={{ label: "New Settlement", href: "/driver-settlements/new" }} />
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Settlement #</th>
                  <th className="py-1.5 pr-3">Driver</th>
                  <th className="py-1.5 pr-3">Period</th>
                  <th className="py-1.5 pr-3 text-right">Gross</th>
                  <th className="py-1.5 pr-3 text-right">Deductions</th>
                  <th className="py-1.5 pr-3 text-right">Advances</th>
                  <th className="py-1.5 pr-3 text-right">Net</th>
                  <th className="py-1.5 pr-3 text-right">Paid</th>
                  <th className="py-1.5 pr-3 text-right">Balance</th>
                  <th className="py-1.5 pr-3">Status</th>
                  <th className="py-1.5"></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className="border-b border-desktop-border last:border-0">
                    <td className="py-1.5 pr-3 font-medium">{r.settlement_number}</td>
                    <td className="py-1.5 pr-3">{r.drivers ? `${r.drivers.first_name} ${r.drivers.last_name}` : "--"}</td>
                    <td className="py-1.5 pr-3 whitespace-nowrap">{new Date(r.period_start + "T00:00:00").toLocaleDateString()} - {new Date(r.period_end + "T00:00:00").toLocaleDateString()}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.gross_pay)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.deductions_amount)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.advances_amount)}</td>
                    <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{money(r.net_pay)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.amount_paid)}</td>
                    <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.balance_due)}</td>
                    <td className="py-1.5 pr-3"><StatusBadge status={r.status} /></td>
                    <td className="py-1.5">
                      <Link href={`/driver-settlements/${r.id}`} className="text-xs font-medium text-primary hover:underline">View</Link>
                    </td>
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
