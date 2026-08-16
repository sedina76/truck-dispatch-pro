"use client";

import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts";
import type { BreakdownSlice } from "@/lib/superadmin/platform-metrics";

const COLORS = ["#3b82f6", "#a855f7", "#10b981", "#f59e0b", "#64748b", "#ec4899"];

function money(cents: number): string {
  return `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
}

// Real distribution of organization_subscriptions grouped by plan/trial
// status (spec section "Subscription Breakdown"). Center shows the total
// company count the donut actually represents (sum of every slice) --
// showing just "activeCount" there was misleading when the donut visibly
// includes trialing/other slices too. Active/Trial counts underneath come
// from the same canonical totals the KPI row uses, never recomputed.
export function SubscriptionBreakdown({
  slices,
  activeCount,
  trialingCount,
  totalMrrCents,
}: {
  slices: BreakdownSlice[];
  activeCount: number;
  trialingCount: number;
  totalMrrCents: number;
}) {
  const chartData = slices.map((s, i) => ({ name: s.label, value: s.count, color: COLORS[i % COLORS.length] }));
  const totalCount = slices.reduce((sum, s) => sum + s.count, 0);

  return (
    <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-5">
      <p className="mb-4 text-sm font-semibold text-slate-100">Subscription Breakdown</p>

      {slices.length === 0 ? (
        <p className="py-10 text-center text-sm text-slate-500">No subscriptions yet.</p>
      ) : (
        <>
          <div className="relative mx-auto size-40">
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie data={chartData} dataKey="value" nameKey="name" innerRadius={50} outerRadius={76} paddingAngle={2} strokeWidth={0}>
                  {chartData.map((slice) => (
                    <Cell key={slice.name} fill={slice.color} />
                  ))}
                </Pie>
                <Tooltip contentStyle={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 10, fontSize: 12, color: "#e2e8f0" }} />
              </PieChart>
            </ResponsiveContainer>
            <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
              <p className="text-2xl font-semibold leading-none text-slate-50">{totalCount}</p>
              <p className="mt-1 text-[10px] uppercase tracking-wide text-slate-500">Companies</p>
            </div>
          </div>

          <p className="mt-3 text-center text-[12px] text-slate-400">
            <span className="font-medium text-emerald-400">{activeCount} Active</span>
            <span className="mx-1.5 text-slate-600">/</span>
            <span className="font-medium text-blue-400">{trialingCount} Trial</span>
          </p>

          <div className="mt-4 space-y-2">
            {slices.map((s, i) => (
              <div key={s.label} className="flex items-center justify-between gap-2 text-[12.5px]">
                <span className="flex min-w-0 items-center gap-2 text-slate-300">
                  <span className="size-2 shrink-0 rounded-full" style={{ background: COLORS[i % COLORS.length] }} />
                  <span className="truncate">{s.label}</span>
                </span>
                <span className="shrink-0 text-slate-500">
                  {s.count} &middot; {s.percent}%{s.mrrCents > 0 && <span className="text-purple-400"> &middot; {money(s.mrrCents)}</span>}
                </span>
              </div>
            ))}
          </div>

          <div className="mt-4 flex items-center justify-between border-t border-slate-800 pt-3">
            <span className="text-[11px] font-medium uppercase tracking-wide text-slate-500">Total MRR</span>
            <span className="text-sm font-semibold text-purple-400">{money(totalMrrCents)}</span>
          </div>
        </>
      )}
    </div>
  );
}
