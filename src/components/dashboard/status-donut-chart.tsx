"use client";

import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts";

export type DonutSlice = { name: string; value: number; color: string };

export function StatusDonutChart({ data }: { data: DonutSlice[] }) {
  const total = data.reduce((sum, d) => sum + d.value, 0);

  return (
    <div className="flex items-center gap-6">
      <div className="relative size-40 shrink-0">
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie data={data} dataKey="value" nameKey="name" innerRadius={48} outerRadius={72} paddingAngle={2} strokeWidth={0}>
              {data.map((slice) => (
                <Cell key={slice.name} fill={slice.color} />
              ))}
            </Pie>
            <Tooltip
              contentStyle={{
                background: "var(--popover)",
                border: "1px solid var(--border)",
                borderRadius: 10,
                fontSize: 12,
                color: "var(--popover-foreground)",
              }}
            />
          </PieChart>
        </ResponsiveContainer>
        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <p className="text-2xl font-semibold leading-none">{total}</p>
          <p className="text-[11px] text-muted-foreground">loads</p>
        </div>
      </div>
      <div className="flex-1 space-y-2">
        {data.map((slice) => (
          <div key={slice.name} className="flex items-center justify-between gap-2 text-sm">
            <span className="flex items-center gap-2 capitalize text-muted-foreground">
              <span className="size-2.5 shrink-0 rounded-full" style={{ background: slice.color }} />
              {slice.name}
            </span>
            <span className="font-medium">{slice.value}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
