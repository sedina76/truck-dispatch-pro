import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Settlement Summary (spec section 25) -- entirely from
// get_driver_settlement_summary() (0031_driver_settlements.sql), never
// recomputed here. Company revenue (load_rate) and driver pay (gross_pay)
// are shown as clearly separate figures, never conflated (spec: "Do not
// confuse company revenue with driver pay").
export async function DriverSettlementSummarySection({ driverId }: { driverId: string }) {
  const supabase = await createClient();
  const { data: summary } = await supabase.rpc("get_driver_settlement_summary", { p_driver_id: driverId }).single();
  const s = summary as {
    ytd_gross_pay: number;
    ytd_deductions: number;
    ytd_advances: number;
    ytd_net_paid: number;
    unpaid_approved_count: number;
    unpaid_approved_balance: number;
    last_settlement_date: string | null;
    completed_trips: number;
    total_miles: number;
    total_load_revenue: number;
  } | null;

  return (
    <DesktopPanel>
      <DesktopPanelHeader
        title={`Settlement Summary (${new Date().getFullYear()} YTD)`}
        actions={
          <Link href={`/driver-settlements?driver_id=${driverId}`} className="text-[11px] text-desktop-header-text/80 hover:underline">
            View Settlements
          </Link>
        }
      />
      <DesktopPanelBody>
        <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px] sm:grid-cols-4">
          <Field label="YTD Gross Driver Pay" value={money(s?.ytd_gross_pay ?? 0)} />
          <Field label="YTD Deductions" value={money(s?.ytd_deductions ?? 0)} />
          <Field label="YTD Advances" value={money(s?.ytd_advances ?? 0)} />
          <Field label="YTD Net Paid" value={money(s?.ytd_net_paid ?? 0)} strong />
          <Field label="Unpaid Approved Settlements" value={String(s?.unpaid_approved_count ?? 0)} tone={s && s.unpaid_approved_count > 0 ? "warning" : undefined} />
          <Field label="Unpaid Approved Balance" value={money(s?.unpaid_approved_balance ?? 0)} tone={s && s.unpaid_approved_balance > 0 ? "warning" : undefined} />
          <Field label="Last Settlement" value={s?.last_settlement_date ? new Date(s.last_settlement_date + "T00:00:00").toLocaleDateString() : "None yet"} />
        </div>
        <div className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 border-t border-desktop-border pt-3 text-[13px] sm:grid-cols-4">
          <Field label="Completed Trips" value={String(s?.completed_trips ?? 0)} />
          <Field label="Total Miles" value={Number(s?.total_miles ?? 0).toLocaleString()} />
          <Field label="Load Revenue (company)" value={money(s?.total_load_revenue ?? 0)} />
          <Field label="Gross Driver Pay" value={money(s?.ytd_gross_pay ?? 0)} />
        </div>
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
