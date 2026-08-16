import { Fragment } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function categoryLabel(c: string): string {
  return c.replace(/_/g, " ").replace(/\b\w/g, (ch) => ch.toUpperCase());
}

// Truck Profile -> Cost view (spec section 33). scope='truck' expenses
// only, via get_truck_expense_summary() (0040) -- never mixed automatically
// into any load's margin. fuel_logs totals shown alongside as a separate,
// clearly-labeled figure (operational fuel detail, not an expenses row --
// spec section 15) rather than merged into one number.
export async function TruckExpenseSummarySection({ truckId }: { truckId: string }) {
  const supabase = await createClient();
  const [{ data }, { data: fuelRows }] = await Promise.all([
    supabase.rpc("get_truck_expense_summary", { p_truck_id: truckId }).maybeSingle(),
    supabase.from("fuel_logs").select("total_amount").eq("truck_id", truckId),
  ]);
  const s = data as { expense_count: number; total_amount: number; categories: Record<string, number> } | null;
  const fuelTotal = (fuelRows ?? []).reduce((sum, r) => sum + Number(r.total_amount), 0);
  const categories = Object.entries(s?.categories ?? {}).sort((a, b) => b[1] - a[1]);

  return (
    <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
      <div className="flex items-center justify-between">
        <p className="text-sm font-medium">Truck / Fleet Costs</p>
        <Link href={`/expenses?truck_id=${truckId}`} className="text-xs font-medium text-primary hover:underline">View Expenses</Link>
      </div>
      <div className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
        <span className="text-[var(--color-text-muted)]">Fuel Log Total (all-time)</span>
        <span className="text-right">{money(fuelTotal)}</span>
        <span className="text-[var(--color-text-muted)]">Expense Records (approved/paid)</span>
        <span className="text-right">{s?.expense_count ?? 0}</span>
        {categories.map(([cat, amt]) => (
          <Fragment key={cat}>
            <span className="pl-2 text-xs text-[var(--color-text-muted)]">-- {categoryLabel(cat)}</span>
            <span className="text-right text-xs">{money(amt)}</span>
          </Fragment>
        ))}
        <span className="border-t border-[var(--color-border)] pt-1 font-medium">Total Truck Expenses</span>
        <span className="border-t border-[var(--color-border)] pt-1 text-right font-semibold">{money(s?.total_amount ?? 0)}</span>
      </div>
      <p className="mt-2 text-[11px] text-[var(--color-text-muted)]">Truck-scoped costs never feed a single load&apos;s margin automatically.</p>
    </div>
  );
}
