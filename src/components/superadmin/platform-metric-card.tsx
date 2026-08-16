import type { ComponentType } from "react";
import { cn } from "@/lib/utils";

// Dark navy premium palette, scoped to the Platform Console only (does not
// touch the shared --primary/--success/etc tokens the rest of the app's
// light/dark toggle relies on -- this console always looks like this,
// regardless of the tenant app's theme, same "own consistent look"
// convention already used by the Driver Portal / desktop ERP shells).
const TONE = {
  blue: { icon: "bg-blue-500/10 text-blue-400", value: "text-slate-50" },
  emerald: { icon: "bg-emerald-500/10 text-emerald-400", value: "text-emerald-400" },
  purple: { icon: "bg-purple-500/10 text-purple-400", value: "text-slate-50" },
  amber: { icon: "bg-amber-500/10 text-amber-400", value: "text-amber-400" },
  red: { icon: "bg-red-500/10 text-red-400", value: "text-red-400" },
  neutral: { icon: "bg-slate-500/10 text-slate-400", value: "text-slate-50" },
} as const;

export function PlatformMetricCard({
  label,
  value,
  icon: Icon,
  tone = "neutral",
  sub,
}: {
  label: string;
  value: string | number;
  icon?: ComponentType<{ className?: string }>;
  tone?: keyof typeof TONE;
  /** Small secondary line -- only ever real derived context, never a fabricated trend. */
  sub?: string;
}) {
  const t = TONE[tone];
  return (
    <div className="rounded-xl border border-slate-800 bg-slate-900/60 p-4 shadow-[0_1px_0_0_rgba(255,255,255,0.02)]">
      <div className="flex items-start justify-between gap-2">
        <p className="text-[11px] font-medium uppercase tracking-wide text-slate-400">{label}</p>
        {Icon && (
          <div className={cn("flex size-7 shrink-0 items-center justify-center rounded-lg", t.icon)}>
            <Icon className="size-3.5" />
          </div>
        )}
      </div>
      <p className={cn("mt-2 text-2xl font-semibold leading-none tracking-tight tabular-nums", t.value)}>{value}</p>
      {sub && <p className="mt-1.5 text-[11px] text-slate-500">{sub}</p>}
    </div>
  );
}
