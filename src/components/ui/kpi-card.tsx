import type { ComponentType } from "react";
import { ArrowDownRight, ArrowUpRight } from "lucide-react";
import { cn } from "@/lib/utils";

const TONE_ICON_CLASSES = {
  neutral: "bg-primary/10 text-primary",
  warning: "bg-warning/10 text-warning",
  danger: "bg-danger/10 text-danger",
  success: "bg-success/10 text-success",
} as const;

const TONE_VALUE_CLASSES = {
  neutral: "",
  warning: "text-warning",
  danger: "text-danger",
  success: "text-success",
} as const;

export function KpiCard({
  label,
  value,
  tone = "neutral",
  icon: Icon,
  delta,
  deltaLabel,
}: {
  label: string;
  value: string | number;
  tone?: "neutral" | "warning" | "danger" | "success";
  icon?: ComponentType<{ className?: string }>;
  /** Percentage change vs. the prior comparable period. Positive is framed as good. */
  delta?: number;
  deltaLabel?: string;
}) {
  return (
    <div className="rounded-md border border-desktop-border bg-card px-3 py-2 shadow-elevation-1">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
          <p className={cn("mt-1 text-lg font-semibold leading-tight tabular-nums tracking-tight", TONE_VALUE_CLASSES[tone])}>
            {value}
          </p>
          {typeof delta === "number" && (
            <p
              className={cn(
                "mt-1 flex items-center gap-1 text-[10.5px] font-medium",
                delta >= 0 ? "text-success" : "text-danger"
              )}
            >
              {delta >= 0 ? <ArrowUpRight className="size-3" /> : <ArrowDownRight className="size-3" />}
              {Math.abs(delta).toFixed(0)}% {deltaLabel}
            </p>
          )}
        </div>
        {Icon && (
          <div className={cn("flex size-6 shrink-0 items-center justify-center rounded-sm", TONE_ICON_CLASSES[tone])}>
            <Icon className="size-3.5" />
          </div>
        )}
      </div>
    </div>
  );
}

export function KpiRow({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6">{children}</div>;
}
