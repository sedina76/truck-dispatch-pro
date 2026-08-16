"use client";

import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis, Cell } from "recharts";

export type AgingBucketPoint = { bucket: string; label: string; balance: number; count: number; color: string };

export function ArAgingChart({ data }: { data: AgingBucketPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height={220}>
      <BarChart data={data} margin={{ top: 8, right: 16, left: 8, bottom: 4 }}>
        <CartesianGrid vertical={false} stroke="var(--border)" />
        <XAxis dataKey="label" stroke="var(--muted-foreground)" fontSize={12} tickLine={false} axisLine={false} />
        <YAxis
          stroke="var(--muted-foreground)"
          fontSize={12}
          tickLine={false}
          axisLine={false}
          tickFormatter={(v) => `$${Number(v).toLocaleString()}`}
          width={70}
        />
        <Tooltip
          cursor={{ fill: "var(--muted)" }}
          formatter={(value, _name, item) => [
            `$${Number(value ?? 0).toLocaleString(undefined, { minimumFractionDigits: 2 })} (${item.payload.count} invoice${item.payload.count === 1 ? "" : "s"})`,
            "Outstanding",
          ]}
          contentStyle={{
            background: "var(--popover)",
            border: "1px solid var(--border)",
            borderRadius: 10,
            fontSize: 12,
            color: "var(--popover-foreground)",
          }}
        />
        <Bar dataKey="balance" radius={[6, 6, 0, 0]} maxBarSize={56}>
          {data.map((entry) => (
            <Cell key={entry.bucket} fill={entry.color} />
          ))}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}
