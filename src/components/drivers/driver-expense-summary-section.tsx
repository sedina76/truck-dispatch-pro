import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Driver Profile -> Company-paid expenses (spec section 12/34). scope='driver'
// only -- company reimbursements/company-paid costs, NEVER a payroll
// deduction (those live in Driver Pay / Driver Settlement, a different
// financial concept entirely -- get_driver_expense_summary(), 0040).
export async function DriverExpenseSummarySection({ driverId }: { driverId: string }) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_driver_expense_summary", { p_driver_id: driverId }).maybeSingle();
  const s = data as { expense_count: number; total_amount: number } | null;
  if (!s || s.expense_count === 0) return null;

  return (
    <DesktopPanel>
      <DesktopPanelHeader
        title="Company-Paid Expenses"
        actions={<Link href={`/expenses?driver_id=${driverId}`} className="text-[11px] text-desktop-header-text/80 hover:underline">View Expenses</Link>}
      />
      <DesktopPanelBody>
        <p className="text-[13px] text-muted-foreground">
          {s.expense_count} approved/paid expense{s.expense_count === 1 ? "" : "s"} totaling <span className="font-semibold text-desktop-text">{money(s.total_amount)}</span>.
          Separate from Driver Pay / Driver Settlement.
        </p>
      </DesktopPanelBody>
    </DesktopPanel>
  );
}
