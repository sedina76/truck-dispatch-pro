import { Fragment } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopCollapsibleSection } from "@/components/desktop/collapsible-section";

function money(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function pct(n: number | null): string {
  if (n === null || n === undefined) return "--";
  return `${Number(n).toFixed(1)}%`;
}
function categoryLabel(c: string): string {
  return c.replace(/_/g, " ").replace(/\b\w/g, (ch) => ch.toUpperCase());
}

// Load Detail -> Profitability. Single row from get_load_profitability()
// (0037/0038/0040) -- the SAME canonical function every other
// profitability surface reads, just filtered to this one load instead of
// the whole org. other_direct_cost's category breakdown comes from
// get_load_direct_expenses() (0040_expense_cost_management.sql), the one
// other function allowed to feed this number (spec section 31).
export async function LoadProfitabilitySection({ loadId }: { loadId: string }) {
  const supabase = await createClient();
  const [{ data }, { data: expenseData }] = await Promise.all([
    supabase.rpc("get_load_profitability", { p_load_id: loadId }).maybeSingle(),
    supabase.rpc("get_load_direct_expenses", { p_load_id: loadId }).maybeSingle(),
  ]);
  const p = data as {
    revenue: number | null;
    revenue_source: string | null;
    carrier_cost: number | null;
    driver_cost: number | null;
    transportation_cost: number | null;
    transportation_cost_source: string | null;
    other_direct_cost: number | null;
    pending_direct_cost: number | null;
    total_direct_cost: number | null;
    gross_profit: number | null;
    margin_percent: number | null;
    revenue_per_mile: number | null;
    cost_per_mile: number | null;
    profit_per_mile: number | null;
    profitability_status: string;
  } | null;
  const dx = expenseData as { pending_expense_count: number; categories: Record<string, number> } | null;

  if (!p) return null;

  const categories = dx?.categories ?? {};
  const categoryEntries = Object.entries(categories).sort((a, b) => b[1] - a[1]);

  return (
    <DesktopCollapsibleSection
      id="profitability"
      title="Profitability"
      defaultOpen={false}
      badge={p.profitability_status.replace(/_/g, " ")}
      badgeTone={p.profitability_status === "PENDING_EXPENSES" ? "warning" : "neutral"}
    >
      {p.profitability_status === "NOT_DELIVERED" ? (
        <p className="mt-2 text-sm text-[var(--color-text-muted)]">Not delivered yet -- profitability is calculated once the load is marked delivered.</p>
      ) : (
        <>
          <div className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
            <span className="text-[var(--color-text-muted)]">Revenue</span>
            <span className="text-right font-medium">
              {money(p.revenue)}
              {p.revenue_source && <span className="ml-1 text-[10px] text-[var(--color-text-muted)]">({p.revenue_source === "invoice" ? "invoiced" : "estimated"})</span>}
            </span>
            <span className="text-[var(--color-text-muted)]">Transportation Cost</span>
            <span className="text-right">
              {money(p.transportation_cost)}
              {p.transportation_cost_source && (
                <span className="ml-1 text-[10px] text-[var(--color-text-muted)]">({p.transportation_cost_source.includes("estimated") ? "estimated" : "finalized"})</span>
              )}
            </span>
            {(p.carrier_cost ?? 0) > 0 && (
              <>
                <span className="pl-2 text-xs text-[var(--color-text-muted)]">-- Carrier</span>
                <span className="text-right text-xs">{money(p.carrier_cost)}</span>
              </>
            )}
            {(p.driver_cost ?? 0) > 0 && (
              <>
                <span className="pl-2 text-xs text-[var(--color-text-muted)]">-- Driver</span>
                <span className="text-right text-xs">{money(p.driver_cost)}</span>
              </>
            )}

            <span className="text-[var(--color-text-muted)]">Other Direct Costs</span>
            <span className="text-right">{money(p.other_direct_cost)}</span>
            {categoryEntries.map(([cat, amt]) => (
              <Fragment key={cat}>
                <span className="pl-2 text-xs text-[var(--color-text-muted)]">-- {categoryLabel(cat)}</span>
                <span className="text-right text-xs">{money(amt)}</span>
              </Fragment>
            ))}

            <span className="border-t border-[var(--color-border)] pt-1 font-medium">Gross Profit</span>
            <span className={`border-t border-[var(--color-border)] pt-1 text-right font-semibold ${(p.gross_profit ?? 0) >= 0 ? "text-desktop-success" : "text-desktop-danger"}`}>
              {money(p.gross_profit)}
            </span>
            <span className="text-[var(--color-text-muted)]">Margin %</span>
            <span className="text-right">{pct(p.margin_percent)}</span>
            <span className="text-[var(--color-text-muted)]">Revenue / Mile</span>
            <span className="text-right">{p.revenue_per_mile != null ? `$${Number(p.revenue_per_mile).toFixed(2)}` : "--"}</span>
            <span className="text-[var(--color-text-muted)]">Profit / Mile</span>
            <span className="text-right">{p.profit_per_mile != null ? `$${Number(p.profit_per_mile).toFixed(2)}` : "--"}</span>
          </div>

          {p.profitability_status === "PENDING_EXPENSES" && (
            <p className="mt-2 flex items-center justify-between rounded-sm border border-warning/30 bg-warning/5 px-2 py-1.5 text-[11px] text-warning">
              <span>{money(p.pending_direct_cost)} in draft/submitted load expenses not yet approved -- not counted in the total above.</span>
              <Link href={`/expenses?load_id=${loadId}&status=draft`} className="font-medium hover:underline">Review</Link>
            </p>
          )}
        </>
      )}
    </DesktopCollapsibleSection>
  );
}
