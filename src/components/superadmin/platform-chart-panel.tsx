"use client";

import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";

export type GrowthPoint = { month: string; count: number };

function money(cents: number): string {
  return `$${(cents / 100).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
}

// MRR & Company Growth panel. Company Growth is REAL historical data
// (organizations.created_at grouped by month). MRR itself has no
// snapshot/ledger table in this schema -- rather than fabricate a trend
// line for it, it's shown as a current-snapshot callout next to the one
// metric that genuinely does have history.
export function PlatformChartPanel({ mrrCents, arrCents, growth }: { mrrCents: number; arrCents: number; growth: GrowthPoint[] }) {
  return (
    <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-4">
      <div className="mb-2.5 flex flex-wrap items-start justify-between gap-4">
        <div>
          <p className="text-sm font-semibold text-slate-100">MRR & Company Growth</p>
          <p className="mt-0.5 text-xs text-slate-500">Company signups by month is real history. MRR is a live snapshot -- this schema has no historical MRR ledger yet, so no MRR trend line is shown.</p>
        </div>
        <div className="flex shrink-0 gap-6">
          <div>
            <p className="text-[10.5px] font-medium uppercase tracking-wide text-slate-500">MRR (current)</p>
            <p className="text-lg font-semibold text-purple-400">{money(mrrCents)}</p>
          </div>
          <div>
            <p className="text-[10.5px] font-medium uppercase tracking-wide text-slate-500">ARR (MRR &times; 12)</p>
            <p className="text-lg font-semibold text-purple-300">{money(arrCents)}</p>
          </div>
        </div>
      </div>

      {growth.length === 0 ? (
        <p className="py-6 text-center text-sm text-slate-500">No company signups yet.</p>
      ) : (
        <ResponsiveContainer width="100%" height={140}>
          <BarChart data={growth} margin={{ top: 4, right: 8, left: 0, bottom: 0 }}>
            <CartesianGrid vertical={false} stroke="#1e293b" />
            <XAxis dataKey="month" stroke="#64748b" fontSize={11} tickLine={false} axisLine={false} />
            <YAxis stroke="#64748b" fontSize={11} tickLine={false} axisLine={false} width={28} allowDecimals={false} />
            <Tooltip
              contentStyle={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: 10, fontSize: 12, color: "#e2e8f0" }}
              formatter={(value) => [`${value} companies`, "New signups"]}
            />
            <Bar dataKey="count" fill="#3b82f6" radius={[4, 4, 0, 0]} maxBarSize={36} />
          </BarChart>
        </ResponsiveContainer>
      )}
    </div>
  );
}
