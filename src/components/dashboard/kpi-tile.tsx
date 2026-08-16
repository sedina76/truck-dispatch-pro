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
        "flex h-full w-full flex-col justify-between rounded-md border border-desktop-border bg-card px-2.5 py-2",
        "shadow-elevation-1 transition-colors hover:border-primary/40"
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{data.label}</p>
          <p className="mt-0.5 truncate text-base font-semibold leading-tight tabular-nums tracking-tight">{data.value}</p>
        </div>
        <div className={cn("flex size-5 shrink-0 items-center justify-center rounded-sm", TONE_ICON_CLASSES[data.tone])}>
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
    <div className="h-20 w-full">
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
