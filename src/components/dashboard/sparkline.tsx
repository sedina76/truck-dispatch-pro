"use client";

import { Area, AreaChart, ResponsiveContainer } from "recharts";

const TONE_COLORS = {
  neutral: "var(--primary)",
  success: "var(--success)",
  warning: "var(--warning)",
  danger: "var(--danger)",
} as const;

export function Sparkline({
  data,
  tone = "neutral",
}: {
  data: number[];
  tone?: keyof typeof TONE_COLORS;
}) {
  const color = TONE_COLORS[tone];
  const points = data.map((value, i) => ({ i, value }));
  const gradientId = `spark-${tone}-${data.length}-${data[0] ?? 0}`;

  return (
    <div className="h-9 w-full">
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart data={points} margin={{ top: 2, right: 0, left: 0, bottom: 0 }}>
          <defs>
            <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity={0.35} />
              <stop offset="100%" stopColor={color} stopOpacity={0} />
            </linearGradient>
          </defs>
          <Area
            type="monotone"
            dataKey="value"
            stroke={color}
            strokeWidth={1.75}
            fill={`url(#${gradientId})`}
            isAnimationActive={false}
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
