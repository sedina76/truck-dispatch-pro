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

// Reports -> Carrier Pay: same settlements/settlement_line_items rows
// Finance -> Carrier Settlements shows, aggregated/filterable, with margin --
// customer revenue and carrier pay both sourced from the same load_pay
// line items every other page reads -- never an independent recalculation
// (spec section 33/34).
export default async function CarrierPayReportPage({
  searchParams,
}: {
  searchParams: Promise<{ carrier_id?: string; status?: string; start?: string; end?: string }>;
}) {
  const { carrier_id, status, start, end } = await searchParams;
  const supabase = await createClient();

  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").order("legal_name");

  let query = supabase
    .from("settlements")
    .select(
      "id, settlement_number, carrier_id, period_start, period_end, gross_amount, deductions_amount, advances_amount, quick_pay_fee_amount, net_amount, amount_paid, balance_due, status, carriers(legal_name)"
    )
    .order("period_start", { ascending: false });
  if (carrier_id) query = query.eq("carrier_id", carrier_id);
  if (status) query = query.eq("status", status);
  if (start) query = query.gte("period_start", start);
  if (end) query = query.lte("period_end", end);

  const { data: settlements } = await query;
  const rows = (settlements ?? []) as unknown as {
    id: string;
    settlement_number: string;
    carrier_id: string;
    period_start: string;
    period_end: string;
    gross_amount: number;
    deductions_amount: number;
    advances_amount: number;
    quick_pay_fee_amount: number;
    net_amount: number;
    amount_paid: number;
    balance_due: number;
    status: string;
    carriers: { legal_name: string } | null;
  }[];

  const settlementIds = rows.map((r) => r.id);
  const { data: loadItems } = settlementIds.length
    ? await supabase.from("settlement_line_items").select("settlement_id, customer_revenue").eq("item_type", "load_pay").in("settlement_id", settlementIds)
    : { data: [] };
  const revenueBySettlement = new Map<string, number>();
  const tripsBySettlement = new Map<string, number>();
  for (const li of loadItems ?? []) {
    revenueBySettlement.set(li.settlement_id, (revenueBySettlement.get(li.settlement_id) ?? 0) + Number(li.customer_revenue ?? 0));
    tripsBySettlement.set(li.settlement_id, (tripsBySettlement.get(li.settlement_id) ?? 0) + 1);
  }

  const totals = rows.reduce(
    (acc, r) => ({
      trips: acc.trips + (tripsBySettlement.get(r.id) ?? 0),
      revenue: acc.revenue + (revenueBySettlement.get(r.id) ?? 0),
      gross: acc.gross + Number(r.gross_amount),
      deductions: acc.deductions + Number(r.deductions_amount),
      advances: acc.advances + Number(r.advances_amount),
      quickPay: acc.quickPay + Number(r.quick_pay_fee_amount),
      net: acc.net + Number(r.net_amount),
      paid: acc.paid + Number(r.amount_paid),
      outstanding: acc.outstanding + Number(r.balance_due),
    }),
    { trips: 0, revenue: 0, gross: 0, deductions: 0, advances: 0, quickPay: 0, net: 0, paid: 0, outstanding: 0 }
  );
  const totalMargin = totals.revenue - totals.gross;
  const marginPercent = totals.revenue > 0 ? (totalMargin / totals.revenue) * 100 : 0;

  return (
    <div className="space-y-3">
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Carrier Pay Report</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">Loads, customer revenue, carrier pay, deductions, advances, Quick Pay fees, net pay, and margin by carrier settlement.</p>
      </div>

      <DesktopKpiStrip>
        <DesktopKpiBox label="Loads" value={totals.trips} />
        <DesktopKpiBox label="Customer Revenue" value={money(totals.revenue)} />
        <DesktopKpiBox label="Carrier Gross Pay" value={money(totals.gross)} />
        <DesktopKpiBox label="Gross Margin" value={`${money(totalMargin)} (${marginPercent.toFixed(1)}%)`} tone="success" />
        <DesktopKpiBox label="Deductions" value={money(totals.deductions)} tone="warning" />
        <DesktopKpiBox label="Advances" value={money(totals.advances)} tone="warning" />
        <DesktopKpiBox label="Quick Pay Fees" value={money(totals.quickPay)} tone="warning" />
        <DesktopKpiBox label="Net Pay" value={money(totals.net)} tone="primary" />
        <DesktopKpiBox label="Outstanding" value={money(totals.outstanding)} tone={totals.outstanding > 0 ? "warning" : "success"} />
      </DesktopKpiStrip>

      <DesktopFilterBar>
        <form method="GET" className="flex flex-wrap items-end gap-2">
          <DesktopFilterField label="Carrier">
            <select name="carrier_id" defaultValue={carrier_id ?? ""} className={desktopInputClass + " w-52"}>
              <option value="">All Carriers</option>
              {(carriers ?? []).map((c) => (<option key={c.id} value={c.id}>{c.legal_name}</option>))}
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
          <Link href="/reports/carrier-pay" className="h-7 rounded-sm border border-desktop-border px-3 text-[12px] font-medium leading-7 hover:bg-muted">Reset</Link>
        </form>
      </DesktopFilterBar>

      <DesktopPanel>
        <DesktopPanelHeader title="Settlements" />
        <DesktopPanelBody className="overflow-auto">
          {rows.length === 0 ? (
            <EmptyState title="No carrier settlements match these filters" description="Adjust the filters or create a new settlement." />
          ) : (
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pr-3">Settlement #</th>
                  <th className="py-1.5 pr-3">Carrier</th>
                  <th className="py-1.5 pr-3">Period</th>
                  <th className="py-1.5 pr-3 text-right">Loads</th>
                  <th className="py-1.5 pr-3 text-right">Revenue</th>
                  <th className="py-1.5 pr-3 text-right">Gross Pay</th>
                  <th className="py-1.5 pr-3 text-right">Margin</th>
                  <th className="py-1.5 pr-3 text-right">Net</th>
                  <th className="py-1.5 pr-3 text-right">Outstanding</th>
                  <th className="py-1.5 pr-3">Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const revenue = revenueBySettlement.get(r.id) ?? 0;
                  const margin = revenue - Number(r.gross_amount);
                  return (
                    <tr key={r.id} className="border-b border-desktop-border last:border-0">
                      <td className="py-1.5 pr-3 font-medium"><Link href={`/settlements/${r.id}`} className="text-primary hover:underline">{r.settlement_number}</Link></td>
                      <td className="py-1.5 pr-3">{r.carriers?.legal_name ?? "--"}</td>
                      <td className="py-1.5 pr-3 whitespace-nowrap">{new Date(r.period_start + "T00:00:00").toLocaleDateString()} - {new Date(r.period_end + "T00:00:00").toLocaleDateString()}</td>
                      <td className="py-1.5 pr-3 text-right">{tripsBySettlement.get(r.id) ?? 0}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{money(revenue)}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.gross_amount)}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{money(margin)}</td>
                      <td className="py-1.5 pr-3 text-right font-medium tabular-nums">{money(r.net_amount)}</td>
                      <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.balance_due)}</td>
                      <td className="py-1.5 pr-3"><StatusBadge status={r.status} /></td>
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
