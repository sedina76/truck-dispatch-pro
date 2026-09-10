"use client";

import Link from "next/link";
import { ArrowDownRight, ArrowUpRight, Minus } from "lucide-react";
import { cn } from "@/lib/utils";
import { Sparkline } from "@/components/dashboard/sparkline";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

export type KpiTone = "neutral" | "success" | "warning" | "danger";

export type KpiTileData = {
  id: string;
  label: string;
  value: string;
  // A pre-rendered icon element (e.g. <DollarSign className="size-4" />),
  // not the component reference itself: this data is built in a server
  // module and handed to this Client Component, and RSC can only pass
  // already-rendered ReactNode across that boundary, not raw functions.
  icon: React.ReactNode;
  tone: KpiTone;
  href: string;
  delta?: { value: number; label: string };
  sparkline?: number[];
  tooltip?: string;
  updatedAt?: string;
};

const TONE_ICON_CLASSES: Record<KpiTone, string> = {
  neutral: "bg-primary/10 text-primary",
  success: "bg-success/10 text-success",
  warning: "bg-warning/10 text-warning",
  danger: "bg-danger/10 text-danger",
};

export function KpiTile({ data }: { data: KpiTileData }) {
  const delta = data.delta;
  const deltaTone = !delta || delta.value === 0 ? "neutral" : delta.value > 0 ? "success" : "danger";

  const card = (
    <Link
      href={data.href}
      className={cn(
        // Tightened padding so all 8 primary KPI cards fit one desktop row
        // (see KpiStrip). Every value stays text-base for readability.
        "flex h-full w-full flex-col justify-between rounded-md border border-desktop-border bg-card px-2 py-1.5",
        "shadow-elevation-1 transition-colors hover:border-primary/40"
      )}
    >
      <div className="flex items-start justify-between gap-1.5">
        <div className="min-w-0">
          {/* Full title always shown -- wraps to a 2nd line rather than
              truncating to "ACTIVE LO..." (never an ellipsis). Short labels
              are supplied by the dashboard so this stays one line on
              desktop. */}
          <p className="wrap-anywhere text-[10px] font-semibold uppercase leading-tight tracking-normal text-muted-foreground">{data.label}</p>
          <p className="mt-0.5 truncate text-base font-semibold leading-tight tabular-nums tracking-tight">{data.value}</p>
        </div>
        <div className={cn("flex size-4 shrink-0 items-center justify-center rounded-sm", TONE_ICON_CLASSES[data.tone])}>
          {data.icon}
        </div>
      </div>

      {delta && (
        <span
          className={cn(
            "inline-flex w-fit items-center gap-1 text-[10.5px] font-medium",
            deltaTone === "success" && "text-desktop-success",
            deltaTone === "danger" && "text-desktop-danger",
            deltaTone === "neutral" && "text-muted-foreground"
          )}
        >
          {deltaTone === "success" && <ArrowUpRight className="size-3" />}
          {deltaTone === "danger" && <ArrowDownRight className="size-3" />}
          {deltaTone === "neutral" && <Minus className="size-3" />}
          {Math.abs(delta.value).toFixed(0)}% {delta.label}
        </span>
      )}

      {data.sparkline && data.sparkline.length > 1 && (
        <Sparkline data={data.sparkline} tone={data.tone === "neutral" ? "neutral" : data.tone} />
      )}
    </Link>
  );

  return (
    // min-h (not a fixed h): in the single-row KpiStrip the flex row
    // stretches every card to the tallest, so if a label ever wraps the
    // whole row grows together -- equal-width, equal-height, no clipping.
    <div className="h-full min-h-20 w-full">
      {data.tooltip ? (
        <Tooltip>
          <TooltipTrigger asChild>{card}</TooltipTrigger>
          <TooltipContent side="bottom" className="max-w-55">
            {data.tooltip}
          </TooltipContent>
        </Tooltip>
      ) : (
        card
      )}
    </div>
  );
}
