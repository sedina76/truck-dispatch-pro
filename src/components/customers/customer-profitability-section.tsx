import Link from "next/link";
import { TrendingUp } from "lucide-react";
import { createClient } from "@/lib/supabase/server";

function money(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function pct(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `${Number(n).toFixed(1)}%`;
}

// Customer Profile -> Profitability. get_profitability_by_customer()
// (0037_profitability.sql), filtered to this one customer's row.
export async function CustomerProfitabilitySection({ customerId }: { customerId: string }) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_profitability_by_customer", {}).eq("customer_id", customerId).maybeSingle();
  const p = data as {
    load_count: number; total_revenue: number; total_transportation_cost: number;
    total_gross_profit: number; avg_margin_percent: number | null;
  } | null;

  return (
    <div className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface)] p-4">
      <p className="flex items-center gap-2 text-sm font-medium">
        <TrendingUp className="size-4 text-primary" />
        Profitability
      </p>
      {!p || p.load_count === 0 ? (
        <p className="mt-2 text-sm text-[var(--color-text-muted)]">No delivered loads with resolvable revenue yet.</p>
      ) : (
        <div className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
          <span className="text-[var(--color-text-muted)]">Loads</span>
          <span className="text-right">{p.load_count}</span>
          <span className="text-[var(--color-text-muted)]">Revenue</span>
          <span className="text-right">{money(p.total_revenue)}</span>
          <span className="text-[var(--color-text-muted)]">Transportation Cost</span>
          <span className="text-right">{money(p.total_transportation_cost)}</span>
          <span className="font-medium">Gross Profit</span>
          <span className={`text-right font-semibold ${p.total_gross_profit >= 0 ? "text-desktop-success" : "text-desktop-danger"}`}>{money(p.total_gross_profit)}</span>
          <span className="text-[var(--color-text-muted)]">Margin %</span>
          <span className="text-right">{pct(p.avg_margin_percent)}</span>
        </div>
      )}
      <Link href={`/reports/profit-by-broker?dim=customer`} className="mt-2 inline-block text-xs font-medium text-[var(--color-brand)]">
        View full report &rarr;
      </Link>
    </div>
  );
}
