import Link from "next/link";
import { cn } from "@/lib/utils";

type Tone = "neutral" | "success" | "warning" | "danger" | "primary";

const VALUE_TONE: Record<Tone, string> = {
  neutral: "text-desktop-text",
  success: "text-desktop-success",
  warning: "text-desktop-warning",
  danger: "text-desktop-danger",
  primary: "text-primary",
};

// Compact operational KPI box -- the desktop-ERP replacement for the big
// rounded KpiCard. Small label, dense value, no icon badge, no giant
// padding. Every value is passed in as already-computed data (from a
// canonical RPC/helper) -- this component never calculates anything.
export function DesktopKpiBox({
  label,
  value,
  tone = "neutral",
  href,
  sub,
  dense,
}: {
  label: string;
  value: string | number;
  tone?: Tone;
  href?: string;
  sub?: string;
  // Dashboard-only knob (7-card financial row, see DesktopKpiStrip below)
  // -- every other one of this component's ~30 call sites across the app
  // omits this, so their padding/font sizing is byte-for-byte unchanged.
  // Slightly tighter padding and label size, same value size (kept
  // prominent), same borders/background/colors/tone map.
  dense?: boolean;
}) {
  const content = (
    <div
      className={cn(
        "flex h-full flex-col justify-between rounded-md border border-desktop-border bg-desktop-panel transition-colors hover:border-primary/50",
        dense ? "px-2 py-1.5" : "px-3 py-2"
      )}
    >
      <p className={cn("font-semibold uppercase tracking-wide text-muted-foreground", dense ? "text-[9.5px] leading-tight" : "text-[10.5px]")}>{label}</p>
      <p className={cn("mt-1 text-lg font-semibold leading-tight tabular-nums", VALUE_TONE[tone])}>{value}</p>
      {sub && <p className="mt-0.5 text-[10.5px] text-muted-foreground">{sub}</p>}
    </div>
  );

  if (href) {
    return (
      <Link href={href} className="block h-full">
        {content}
      </Link>
    );
  }
  return content;
}

export function DesktopKpiStrip({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={cn("grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-7", className)}>{children}</div>;
}
