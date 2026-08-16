import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function pct(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `${Number(n).toFixed(1)}%`;
}

// Carrier Profile -> Company Profitability. Deliberately distinct from
// CarrierSettlementSummarySection just above it: that panel shows what
// the CARRIER earned (Carrier Settlements); this one shows the COMPANY's
// own margin on loads run by this carrier (revenue minus what the
// carrier was paid) -- get_profitability_by_carrier()
// (0037_profitability.sql), a GROUP BY over the canonical
// get_load_profitability() result, filtered to this carrier's row.
export async function CarrierCompanyProfitabilitySection({ carrierId }: { carrierId: string }) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_profitability_by_carrier", {}).eq("carrier_id", carrierId).maybeSingle();
  const p = data as {
    load_count: number; total_revenue: number; total_transportation_cost: number;
    total_gross_profit: number; avg_margin_percent: number | null;
  } | null;

  return (
    <DesktopPanel>
      <DesktopPanelHeader
        title="Company Profitability"
        actions={
          <Link href="/reports/profit-by-carrier" className="text-[11px] text-desktop-header-text/80 hover:underline">
            View Report
          </Link>
        }
      />
      <DesktopPanelBody>
        {!p || p.load_count === 0 ? (
          <p className="text-[13px] text-muted-foreground">No delivered loads with resolvable revenue yet.</p>
        ) : (
          <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px] sm:grid-cols-5">
            <Field label="Delivered Loads" value={String(p.load_count)} />
            <Field label="Company Revenue" value={money(p.total_revenue)} />
            <Field label="Carrier Cost" value={money(p.total_transportation_cost)} />
            <Field label="Gross Profit" value={money(p.total_gross_profit)} strong />
            <Field label="Margin %" value={pct(p.avg_margin_percent)} />
          </div>
        )}
      </DesktopPanelBody>
    </DesktopPanel>
  );
}

function Field({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={`font-medium text-desktop-text ${strong ? "font-semibold text-primary" : ""}`}>{value}</p>
    </div>
  );
}
