import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Carrier Profile -> Company expenses explicitly associated with this
// carrier (spec section 34). scope='carrier' only -- distinct from Carrier
// Pay (Carrier Settlements). get_carrier_expense_summary(), 0040.
export async function CarrierExpenseSummarySection({ carrierId }: { carrierId: string }) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_carrier_expense_summary", { p_carrier_id: carrierId }).maybeSingle();
  const s = data as { expense_count: number; total_amount: number } | null;
  if (!s || s.expense_count === 0) return null;

  return (
    <DesktopPanel>
      <DesktopPanelHeader
        title="Expenses"
        actions={<Link href={`/expenses?carrier_id=${carrierId}`} className="text-[11px] text-desktop-header-text/80 hover:underline">View Expenses</Link>}
      />
      <DesktopPanelBody>
        <p className="text-[13px] text-muted-foreground">
          {s.expense_count} approved/paid expense{s.expense_count === 1 ? "" : "s"} totaling <span className="font-semibold text-desktop-text">{money(s.total_amount)}</span>.
          Separate from Carrier Pay / Carrier Settlements.
        </p>
      </DesktopPanelBody>
    </DesktopPanel>
  );
}
