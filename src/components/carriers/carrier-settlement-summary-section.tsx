import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { StatusBadge } from "@/components/ui/status-badge";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Settlement Summary + margin (spec sections 28/33) -- entirely from
// get_carrier_settlement_summary() (0033_carrier_settlements.sql), never
// recomputed here. Customer revenue (company income) and carrier pay
// (company expense) are shown as clearly separate figures alongside the
// derived margin, never conflated.
export async function CarrierSettlementSummarySection({ carrierId }: { carrierId: string }) {
  const supabase = await createClient();
  const [{ data: summary }, { data: recentSettlements }] = await Promise.all([
    supabase.rpc("get_carrier_settlement_summary", { p_carrier_id: carrierId }).single(),
    supabase
      .from("settlements")
      .select("id, settlement_number, period_start, period_end, net_amount, amount_paid, balance_due, status")
      .eq("carrier_id", carrierId)
      .order("created_at", { ascending: false })
      .limit(5),
  ]);
  const s = summary as {
    ytd_gross_pay: number;
    ytd_deductions: number;
    ytd_advances: number;
    ytd_quick_pay_fees: number;
    ytd_net_paid: number;
    unpaid_approved_count: number;
    unpaid_approved_balance: number;
    last_settlement_date: string | null;
    completed_loads: number;
    total_customer_revenue: number;
    total_carrier_pay: number;
    total_gross_margin: number;
  } | null;
  const marginPercent = s && s.total_customer_revenue > 0 ? (s.total_gross_margin / s.total_customer_revenue) * 100 : null;

  return (
    <DesktopPanel>
      <DesktopPanelHeader
        title={`Carrier Settlement Summary (${new Date().getFullYear()} YTD)`}
        actions={
          <Link href={`/settlements?carrier_id=${carrierId}`} className="text-[11px] text-desktop-header-text/80 hover:underline">
            View Settlements
          </Link>
        }
      />
      <DesktopPanelBody>
        <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px] sm:grid-cols-4">
          <Field label="YTD Gross Carrier Pay" value={money(s?.ytd_gross_pay ?? 0)} />
          <Field label="YTD Deductions" value={money(s?.ytd_deductions ?? 0)} />
          <Field label="YTD Advances" value={money(s?.ytd_advances ?? 0)} />
          <Field label="YTD Quick Pay Fees" value={money(s?.ytd_quick_pay_fees ?? 0)} />
          <Field label="YTD Net Paid" value={money(s?.ytd_net_paid ?? 0)} strong />
          <Field label="Unpaid Approved Settlements" value={String(s?.unpaid_approved_count ?? 0)} tone={s && s.unpaid_approved_count > 0 ? "warning" : undefined} />
          <Field label="Open Settlement Balance" value={money(s?.unpaid_approved_balance ?? 0)} tone={s && s.unpaid_approved_balance > 0 ? "warning" : undefined} />
          <Field label="Last Settlement" value={s?.last_settlement_date ? new Date(s.last_settlement_date + "T00:00:00").toLocaleDateString() : "None yet"} />
        </div>
        <div className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 border-t border-desktop-border pt-3 text-[13px] sm:grid-cols-4">
          <Field label="Completed Loads" value={String(s?.completed_loads ?? 0)} />
          <Field label="Customer Revenue" value={money(s?.total_customer_revenue ?? 0)} />
          <Field label="Carrier Pay" value={money(s?.total_carrier_pay ?? 0)} />
          <Field label="Gross Margin" value={`${money(s?.total_gross_margin ?? 0)}${marginPercent !== null ? ` (${marginPercent.toFixed(1)}%)` : ""}`} strong />
        </div>

        {recentSettlements && recentSettlements.length > 0 && (
          <div className="mt-3 border-t border-desktop-border pt-3">
            <p className="mb-1.5 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">Recent Settlements</p>
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1 pr-3">Settlement #</th>
                  <th className="py-1 pr-3">Period</th>
                  <th className="py-1 pr-3 text-right">Net Pay</th>
                  <th className="py-1 pr-3 text-right">Paid</th>
                  <th className="py-1 pr-3 text-right">Balance</th>
                  <th className="py-1 pr-3">Status</th>
                </tr>
              </thead>
              <tbody>
                {recentSettlements.map((r) => (
                  <tr key={r.id} className="border-b border-desktop-border last:border-0">
                    <td className="py-1 pr-3 font-medium">
                      <Link href={`/settlements/${r.id}`} className="text-primary hover:underline">{r.settlement_number}</Link>
                    </td>
                    <td className="py-1 pr-3 whitespace-nowrap text-muted-foreground">
                      {r.period_start ? new Date(r.period_start + "T00:00:00").toLocaleDateString() : "--"} - {r.period_end ? new Date(r.period_end + "T00:00:00").toLocaleDateString() : "--"}
                    </td>
                    <td className="py-1 pr-3 text-right tabular-nums">{money(r.net_amount)}</td>
                    <td className="py-1 pr-3 text-right tabular-nums">{money(r.amount_paid)}</td>
                    <td className="py-1 pr-3 text-right tabular-nums">{money(r.balance_due)}</td>
                    <td className="py-1 pr-3"><StatusBadge status={r.status} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </DesktopPanelBody>
    </DesktopPanel>
  );
}

function Field({ label, value, strong, tone }: { label: string; value: string; strong?: boolean; tone?: "warning" }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={`font-medium text-desktop-text ${strong ? "font-semibold text-primary" : ""} ${tone === "warning" ? "text-warning" : ""}`}>{value}</p>
    </div>
  );
}
