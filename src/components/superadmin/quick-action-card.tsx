import Link from "next/link";
import type { ComponentType } from "react";

export function QuickActionCard({
  href,
  icon: Icon,
  label,
  description,
}: {
  href: string;
  icon: ComponentType<{ className?: string }>;
  label: string;
  description: string;
}) {
  return (
    <Link
      href={href}
      className="flex items-center gap-3 rounded-xl border border-slate-800 bg-slate-900/60 p-3.5 transition-colors hover:border-slate-700 hover:bg-slate-800/60"
    >
      <div className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-blue-500/10 text-blue-400">
        <Icon className="size-4" />
      </div>
      <div className="min-w-0">
        <p className="text-[13px] font-medium text-slate-100">{label}</p>
        <p className="truncate text-[11px] text-slate-500">{description}</p>
      </div>
    </Link>
  );
}
