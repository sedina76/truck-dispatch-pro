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
}: {
  label: string;
  value: string | number;
  tone?: Tone;
  href?: string;
  sub?: string;
}) {
  const content = (
    <div className="flex h-full flex-col justify-between rounded-md border border-desktop-border bg-desktop-panel px-3 py-2 transition-colors hover:border-primary/50">
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
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

export function DesktopKpiStrip({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-7">{children}</div>;
}
